const {
  API_PREFIX,
  app,
  authHeader,
  createAdminUser,
  createCategory,
  createProject,
  loginUser,
  pool,
  registerUser,
  request,
  resetDb,
  shutdown,
} = require('./helpers/api-test-helpers');

describe('privacy rights and account deletion requests', () => {
  beforeAll(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await shutdown();
  });

  test('reauthenticates destructive/export requests and isolates users', async () => {
    const first = await registerUser({ role: 'viewer', emailPrefix: 'privacy-first' });
    const second = await registerUser({ role: 'viewer', emailPrefix: 'privacy-second' });
    const firstSession = await loginUser(first);
    const secondSession = await loginUser(second);

    const missingPassword = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(firstSession.token))
      .send({ request_type: 'access_export' });
    expect(missingPassword.status).toBe(400);
    expect(missingPassword.body.error.code).toBe('REAUTHENTICATION_REQUIRED');

    const accountDataExport = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(secondSession.token))
      .send({ request_type: 'access_export', current_password: second.password });
    expect(accountDataExport.status).toBe(201);
    expect(accountDataExport.body.data.request_type).toBe('access_export');
    expect(accountDataExport.body.data.status).toBe('submitted');

    const wrongPassword = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(firstSession.token))
      .send({ request_type: 'deletion', current_password: 'incorrect-password' });
    expect(wrongPassword.status).toBe(403);
    expect(wrongPassword.body.error.code).toBe('REAUTHENTICATION_FAILED');

    const deletion = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(firstSession.token))
      .send({ request_type: 'deletion', current_password: first.password });
    expect(deletion.status).toBe(201);
    expect(deletion.body.data.request_type).toBe('deletion');
    expect(deletion.body.data.status).toBe('submitted');
    expect(deletion.body.message).toContain('account remains active');

    const firstList = await request(app)
      .get(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(firstSession.token));
    const secondList = await request(app)
      .get(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(secondSession.token));
    expect(firstList.body.data).toHaveLength(1);
    expect(secondList.body.data).toHaveLength(1);
    expect(secondList.body.data[0].request_type).toBe('access_export');
    expect(firstList.body.data[0]).not.toHaveProperty('user_email');
    expect(firstList.body.data[0]).not.toHaveProperty('retention_exceptions');
  });

  test('allows one active privacy request per type and loads the protected queue', async () => {
    const previousProtectedEmail = process.env.SUPER_ADMIN_EMAIL;
    const protectedAdmin = await createAdminUser({
      emailPrefix: 'privacy-queue-protected',
    });
    process.env.SUPER_ADMIN_EMAIL = protectedAdmin.email;
    try {
      const subject = await registerUser({
        role: 'viewer',
        fullName: 'Privacy Queue Subject',
        emailPrefix: 'privacy-queue-subject',
      });
      const session = await loginUser(subject);
      const correction = await request(app)
        .post(`${API_PREFIX}/privacy/requests`)
        .set(authHeader(session.token))
        .send({
          request_type: 'correction',
          details: { field: 'full_name', requested_value: 'Corrected Subject' },
        });
      expect(correction.status).toBe(201);

      const deletion = await request(app)
        .post(`${API_PREFIX}/privacy/requests`)
        .set(authHeader(session.token))
        .send({ request_type: 'deletion', current_password: subject.password });
      expect(deletion.status).toBe(201);

      const duplicateCorrection = await request(app)
        .post(`${API_PREFIX}/privacy/requests`)
        .set(authHeader(session.token))
        .send({
          request_type: 'correction',
          details: { field: 'full_name', requested_value: 'Another Subject' },
        });
      expect(duplicateCorrection.status).toBe(409);
      expect(duplicateCorrection.body.error.code).toBe('ACTIVE_PRIVACY_REQUEST_EXISTS');

      const duplicateDeletion = await request(app)
        .post(`${API_PREFIX}/privacy/requests`)
        .set(authHeader(session.token))
        .send({ request_type: 'deletion', current_password: subject.password });
      expect(duplicateDeletion.status).toBe(409);
      expect(duplicateDeletion.body.error.code).toBe('ACTIVE_PRIVACY_REQUEST_EXISTS');

      const queue = await request(app)
        .get(`${API_PREFIX}/privacy/admin/requests`)
        .query({ page: 1, limit: 20, q: correction.body.data.id })
        .set(authHeader(protectedAdmin.token));
      expect(queue.status).toBe(200);
      expect(queue.body.pagination.total).toBe(1);
      expect(queue.body.data[0]).toEqual(
        expect.objectContaining({
          id: correction.body.data.id,
          request_type: 'correction',
          status: 'submitted',
          requester_contact: subject.email,
        }),
      );

      await pool.query(`UPDATE privacy_request SET status = 'in_review' WHERE id = $1`, [
        correction.body.data.id,
      ]);

      const cancelled = await request(app)
        .post(`${API_PREFIX}/privacy/requests/${correction.body.data.id}/cancel`)
        .set(authHeader(session.token));
      expect(cancelled.status).toBe(200);
      expect(cancelled.body.data.status).toBe('cancelled');

      const replacementCorrection = await request(app)
        .post(`${API_PREFIX}/privacy/requests`)
        .set(authHeader(session.token))
        .send({
          request_type: 'correction',
          details: { field: 'full_name', requested_value: 'Replacement Subject' },
        });
      expect(replacementCorrection.status).toBe(201);
    } finally {
      process.env.SUPER_ADMIN_EMAIL = previousProtectedEmail;
    }
  });

  test('keeps deactivation behavior separate from deletion requests', async () => {
    const user = await registerUser({ role: 'viewer', emailPrefix: 'privacy-deactivate' });
    const session = await loginUser(user);
    const deletion = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(session.token))
      .send({ request_type: 'deletion', current_password: user.password });
    expect(deletion.status).toBe(201);

    const me = await request(app).get(`${API_PREFIX}/auth/me`).set(authHeader(session.token));
    expect(me.status).toBe(200);
    expect(me.body.data.account_status).toBe('active');

    const cancel = await request(app)
      .post(`${API_PREFIX}/privacy/requests/${deletion.body.data.id}/cancel`)
      .set(authHeader(session.token));
    expect(cancel.status).toBe(200);
    expect(cancel.body.data.status).toBe('cancelled');
  });

  test('reports contributor fulfillment blockers without preventing request initiation', async () => {
    const admin = await createAdminUser({ emailPrefix: 'privacy-eligibility-admin' });
    const category = await createCategory({
      token: admin.token,
      name: 'Privacy eligibility category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Privacy eligibility project',
    });
    const contributor = await registerUser({
      role: 'contributor',
      emailPrefix: 'privacy-eligibility-contributor',
    });
    await pool.query(
      `UPDATE "user"
          SET is_active = TRUE,
              account_status = 'active'
        WHERE id = $1`,
      [contributor.user.id],
    );
    await pool.query(
      `INSERT INTO project_assignment
         (project_id, user_id, role, status, approved_by_user_id, approved_date)
       VALUES ($1, $2, 'contributor', 'approved', $3, CURRENT_DATE)`,
      [project.id, contributor.user.id, admin.user.id],
    );
    await pool.query(
      `INSERT INTO spatial_feature
         (project_id, collected_by_user_id, geom, attributes, status, submitted_at)
       VALUES ($1, $2, ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326), '{}'::jsonb,
               'pending_review', CURRENT_TIMESTAMP)`,
      [project.id, contributor.user.id],
    );
    const session = await loginUser(contributor);

    const eligibility = await request(app)
      .get(`${API_PREFIX}/privacy/account-deletion/eligibility`)
      .set(authHeader(session.token));
    expect(eligibility.status).toBe(200);
    expect(eligibility.body.data).toEqual(
      expect.objectContaining({
        can_request: true,
        operationally_eligible: false,
        protected_account: false,
        role: 'contributor',
        manual_review_required: true,
      }),
    );
    expect(eligibility.body.data.blockers).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ code: 'ACTIVE_PROJECT_ASSIGNMENTS', count: 1 }),
        expect.objectContaining({ code: 'PENDING_CONTRIBUTION_REVIEWS', count: 1 }),
        expect.objectContaining({ code: 'OFFLINE_DATA_CONFIRMATION_REQUIRED', count: 1 }),
      ]),
    );

    const deletion = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(session.token))
      .send({ request_type: 'deletion', current_password: contributor.password });
    expect(deletion.status).toBe(201);
    expect(deletion.body.data.request_details.operational_eligibility_at_request).toEqual({
      eligible: false,
      blocker_codes: expect.arrayContaining([
        'ACTIVE_PROJECT_ASSIGNMENTS',
        'PENDING_CONTRIBUTION_REVIEWS',
        'OFFLINE_DATA_CONFIRMATION_REQUIRED',
      ]),
      blocker_counts: {
        ACTIVE_PROJECT_ASSIGNMENTS: 1,
        OFFLINE_DATA_CONFIRMATION_REQUIRED: 1,
        PENDING_CONTRIBUTION_REVIEWS: 1,
      },
    });
  });

  test('allows viewers to request deletion and protects the configured super administrator', async () => {
    const viewer = await registerUser({
      role: 'viewer',
      emailPrefix: 'privacy-eligibility-viewer',
    });
    const viewerSession = await loginUser(viewer);
    const viewerEligibility = await request(app)
      .get(`${API_PREFIX}/privacy/account-deletion/eligibility`)
      .set(authHeader(viewerSession.token));
    expect(viewerEligibility.status).toBe(200);
    expect(viewerEligibility.body.data).toEqual(
      expect.objectContaining({
        can_request: true,
        operationally_eligible: true,
        blockers: [],
        role: 'viewer',
      }),
    );

    const previousProtectedEmail = process.env.SUPER_ADMIN_EMAIL;
    const protectedAdmin = await createAdminUser({
      emailPrefix: 'privacy-protected-admin',
    });
    process.env.SUPER_ADMIN_EMAIL = protectedAdmin.email;
    try {
      const protectedEligibility = await request(app)
        .get(`${API_PREFIX}/privacy/account-deletion/eligibility`)
        .set(authHeader(protectedAdmin.token));
      expect(protectedEligibility.status).toBe(200);
      expect(protectedEligibility.body.data).toEqual(
        expect.objectContaining({
          can_request: false,
          operationally_eligible: false,
          protected_account: true,
          role: 'admin',
        }),
      );

      const deletion = await request(app)
        .post(`${API_PREFIX}/privacy/requests`)
        .set(authHeader(protectedAdmin.token))
        .send({ request_type: 'deletion', current_password: protectedAdmin.password });
      expect(deletion.status).toBe(409);
      expect(deletion.body.error.code).toBe('PROTECTED_ACCOUNT_DELETION_FORBIDDEN');
    } finally {
      if (previousProtectedEmail === undefined) {
        delete process.env.SUPER_ADMIN_EMAIL;
      } else {
        process.env.SUPER_ADMIN_EMAIL = previousProtectedEmail;
      }
    }
  });

  test('public deletion intake is generic and records only an existing account for verification', async () => {
    const user = await registerUser({ role: 'viewer', emailPrefix: 'privacy-public-delete' });
    const existing = await request(app)
      .post('/legal/account-deletion/request')
      .type('form')
      .send({ email: user.email });
    const missing = await request(app)
      .post('/legal/account-deletion/request')
      .type('form')
      .send({ email: 'no-such-account-public-delete@example.invalid' });

    expect(existing.status).toBe(202);
    expect(missing.status).toBe(202);
    expect(existing.text).toBe(missing.text);
    expect(existing.text).toContain('whether or not an account exists');

    const stored = await pool.query(
      `SELECT pr.status, pr.identity_verified_at, pr.request_details
       FROM privacy_request pr
       JOIN "user" u ON u.id = pr.user_id
       WHERE u.id = $1 AND pr.request_type = 'deletion'`,
      [user.user.id],
    );
    expect(stored.rows).toEqual([
      expect.objectContaining({
        status: 'pending_verification',
        identity_verified_at: null,
        request_details: { source: 'public_account_deletion_form' },
      }),
    ]);

    const session = await loginUser(user);
    const verified = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(session.token))
      .send({ request_type: 'deletion', current_password: user.password });
    expect(verified.status).toBe(200);
    expect(verified.body.data).toEqual(
      expect.objectContaining({
        id: expect.any(String),
        request_type: 'deletion',
        status: 'submitted',
      }),
    );
    const cases = await pool.query(
      `SELECT status, identity_verified_at FROM privacy_request WHERE user_id = $1`,
      [user.user.id],
    );
    expect(cases.rows).toHaveLength(1);
    expect(cases.rows[0].status).toBe('submitted');
    expect(cases.rows[0].identity_verified_at).not.toBeNull();
  });

  test('content reports require project access and a real in-scope target', async () => {
    const admin = await createAdminUser({ emailPrefix: 'privacy-report-admin' });
    const category = await createCategory({
      token: admin.token,
      name: 'Private report category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Private report project',
      visibleToViewers: false,
      visibleToContributors: false,
    });
    const viewer = await registerUser({ role: 'viewer', emailPrefix: 'privacy-report-viewer' });
    const viewerSession = await loginUser(viewer);

    const accepted = await request(app)
      .post(`${API_PREFIX}/privacy/content-reports`)
      .set(authHeader(admin.token))
      .send({
        project_id: project.id,
        entity_type: 'project',
        entity_id: project.id,
        reason_code: 'privacy',
        description: 'Review whether this project exposes sensitive information.',
      });
    expect(accepted.status).toBe(201);
    expect(accepted.body.data.status).toBe('submitted');

    const duplicate = await request(app)
      .post(`${API_PREFIX}/privacy/content-reports`)
      .set(authHeader(admin.token))
      .send({
        project_id: project.id,
        entity_type: 'project',
        entity_id: project.id,
        reason_code: 'privacy',
        description: 'A repeated report for the same project.',
      });
    expect(duplicate.status).toBe(409);
    expect(duplicate.body.error.code).toBe('ACTIVE_CONTENT_REPORT_EXISTS');

    const denied = await request(app)
      .post(`${API_PREFIX}/privacy/content-reports`)
      .set(authHeader(viewerSession.token))
      .send({
        project_id: project.id,
        entity_type: 'project',
        entity_id: project.id,
        reason_code: 'privacy',
      });
    expect(denied.status).toBe(403);

    const missingTarget = await request(app)
      .post(`${API_PREFIX}/privacy/content-reports`)
      .set(authHeader(admin.token))
      .send({
        project_id: project.id,
        entity_type: 'feature',
        entity_id: '00000000-0000-4000-8000-000000000099',
        reason_code: 'misleading_or_inaccurate',
      });
    expect(missingTarget.status).toBe(404);
  });

  test('records report decisions without silently mutating projects and notifies the reporter', async () => {
    const previousProtectedEmail = process.env.SUPER_ADMIN_EMAIL;
    const protectedAdmin = await createAdminUser({
      emailPrefix: 'privacy-moderation-protected',
    });
    const ordinaryAdmin = await createAdminUser({
      emailPrefix: 'privacy-moderation-ordinary',
    });
    process.env.SUPER_ADMIN_EMAIL = protectedAdmin.email;
    try {
      const category = await createCategory({
        token: protectedAdmin.token,
        name: 'Moderation workflow category',
      });
      const project = await createProject({
        token: protectedAdmin.token,
        categoryId: category.id,
        name: 'Moderation workflow project',
      });
      const report = await request(app)
        .post(`${API_PREFIX}/privacy/content-reports`)
        .set(authHeader(ordinaryAdmin.token))
        .send({
          project_id: project.id,
          entity_type: 'project',
          entity_id: project.id,
          reason_code: 'misleading_or_inaccurate',
          description: 'Please verify this project description.',
        });
      expect(report.status).toBe(201);

      const denied = await request(app)
        .get(`${API_PREFIX}/privacy/admin/content-reports`)
        .set(authHeader(ordinaryAdmin.token));
      expect(denied.status).toBe(403);

      const queue = await request(app)
        .get(`${API_PREFIX}/privacy/admin/content-reports`)
        .query({ page: 1, limit: 1, status: 'submitted', q: 'Moderation workflow project' })
        .set(authHeader(protectedAdmin.token));
      expect(queue.status).toBe(200);
      expect(queue.body.pagination).toEqual(
        expect.objectContaining({ page: 1, limit: 1, total: 1, has_more: false }),
      );
      expect(queue.body.data[0]).not.toHaveProperty('description');
      expect(queue.body.data[0].reporter_contact).toBe(ordinaryAdmin.email);
      expect(queue.body.data[0].project_title).toBe('Moderation workflow project');

      const skippedReview = await request(app)
        .patch(`${API_PREFIX}/privacy/admin/content-reports/${report.body.data.id}`)
        .set(authHeader(protectedAdmin.token))
        .send({ status: 'resolved', outcome_code: 'restricted_existing_workflow' });
      expect(skippedReview.status).toBe(409);
      expect(skippedReview.body.error.code).toBe('INVALID_CONTENT_REPORT_STATUS_TRANSITION');

      const counts = await request(app)
        .get(`${API_PREFIX}/privacy/admin/queue-counts`)
        .set(authHeader(protectedAdmin.token));
      expect(counts.status).toBe(200);
      expect(counts.body.data).toEqual(
        expect.objectContaining({
          open_content_reports: expect.any(Number),
          overdue_content_reports: expect.any(Number),
          open_privacy_requests: expect.any(Number),
          overdue_privacy_requests: expect.any(Number),
        }),
      );

      const reviewed = await request(app)
        .patch(`${API_PREFIX}/privacy/admin/content-reports/${report.body.data.id}`)
        .set(authHeader(protectedAdmin.token))
        .send({
          status: 'in_review',
          user_message: 'We are reviewing your report.',
        });
      expect(reviewed.status).toBe(200);

      const resolved = await request(app)
        .patch(`${API_PREFIX}/privacy/admin/content-reports/${report.body.data.id}`)
        .set(authHeader(protectedAdmin.token))
        .send({ status: 'resolved', outcome_code: 'restricted_existing_workflow' });
      expect(resolved.status).toBe(200);
      expect(resolved.body.data.status).toBe('resolved');
      expect(resolved.body.data.user_visible_message).toContain('restricted');

      const projectStillExists = await pool.query(`SELECT status FROM project WHERE id = $1`, [
        project.id,
      ]);
      expect(projectStillExists.rowCount).toBe(1);
      expect(projectStillExists.rows[0].status).toBe('draft');

      const reporterView = await request(app)
        .get(`${API_PREFIX}/privacy/content-reports`)
        .set(authHeader(ordinaryAdmin.token));
      expect(reporterView.status).toBe(200);
      expect(reporterView.body.data[0]).toEqual(
        expect.objectContaining({
          project_title: 'Moderation workflow project',
          status: 'resolved',
          user_visible_message:
            'Your report was confirmed. Access to the reported item was restricted.',
        }),
      );
      const reporterNotification = await pool.query(
        `SELECT title, message FROM notification
         WHERE user_id = $1 AND metadata->>'content_report_id' = $2`,
        [ordinaryAdmin.user.id, report.body.data.id],
      );
      expect(reporterNotification.rows.at(-1)).toEqual(
        expect.objectContaining({
          title: 'Content report updated',
          message: 'Your report was confirmed. Access to the reported item was restricted.',
        }),
      );
      const history = await pool.query(
        `SELECT to_status, internal_note, resolution_summary
         FROM content_report_status_history WHERE report_id = $1 ORDER BY id`,
        [report.body.data.id],
      );
      expect(history.rows.map((row) => row.to_status)).toEqual([
        'submitted',
        'in_review',
        'resolved',
      ]);
      expect(history.rows[1].internal_note).toBeNull();
      expect(history.rows[2].resolution_summary).toBe(
        'Your report was confirmed. Access to the reported item was restricted.',
      );
    } finally {
      if (previousProtectedEmail === undefined) {
        delete process.env.SUPER_ADMIN_EMAIL;
      } else {
        process.env.SUPER_ADMIN_EMAIL = previousProtectedEmail;
      }
    }
  });
});
