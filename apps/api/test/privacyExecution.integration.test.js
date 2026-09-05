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
const { stopWorkloadWorker, waitForWorkloadWorkerIdle } = require('../src/jobs/workloadWorker');
const {
  processPersonalDataExport,
  renderPersonalDataHtml,
} = require('../src/services/privacyExport.service');
const { processAccountDeletion } = require('../src/services/accountDeletion.service');
const { storageAdapter } = require('../src/services/storageAdapter.service');

describe('privacy execution pipelines', () => {
  let protectedAdmin;
  let previousProtectedEmail;

  const startPrivacyReview = async (requestId) => {
    const response = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${requestId}`)
      .set(authHeader(protectedAdmin.token))
      .send({ status: 'in_review' });
    expect(response.status).toBe(200);
    expect(response.body.data.status).toBe('in_review');
  };

  test('renders a self-contained readable report without executable user markup', () => {
    const hiddenUuid = '9a5f1ea7-1df1-4b56-9d73-682a829c86f8';
    const html = renderPersonalDataHtml({
      manifest: {
        generated_at: '2026-08-24T12:00:00.000Z',
        record_counts: { profile: 1, submitted_content_reports: 0 },
      },
      data: {
        profile: {
          id: hiddenUuid,
          full_name: '<script>alert("unsafe")</script>',
          role: 'viewer',
          metadata: { project_id: hiddenUuid, project_name: 'Readable project' },
        },
        submitted_content_reports: [],
      },
    });

    expect(html).toContain('<!doctype html>');
    expect(html).toContain('TerraLeb personal data report');
    expect(html).toContain('&lt;script&gt;alert(&quot;unsafe&quot;)&lt;/script&gt;');
    expect(html).not.toContain('<script>');
    expect(html).not.toMatch(/<script\b/i);
    expect(html).toContain('Readable project');
    expect(html).not.toContain(hiddenUuid);
    expect(html).not.toContain('Technical details');
    expect(html).not.toMatch(/<summary>/i);
  });

  beforeAll(async () => {
    await resetDb();
    stopWorkloadWorker();
    await waitForWorkloadWorkerIdle();
    protectedAdmin = await createAdminUser({ emailPrefix: 'privacy-execution-admin' });
    previousProtectedEmail = process.env.SUPER_ADMIN_EMAIL;
    process.env.SUPER_ADMIN_EMAIL = protectedAdmin.email;
  });

  afterAll(async () => {
    if (previousProtectedEmail === undefined) {
      delete process.env.SUPER_ADMIN_EMAIL;
    } else {
      process.env.SUPER_ADMIN_EMAIL = previousProtectedEmail;
    }
    const artifacts = await pool.query(
      `SELECT encrypted_file_path FROM privacy_export_artifact
       WHERE encrypted_file_path IS NOT NULL`,
    );
    for (const artifact of artifacts.rows) {
      await storageAdapter.remove(artifact.encrypted_file_path).catch(() => undefined);
    }
    await shutdown();
  });

  test('applies only allowlisted profile corrections through the reviewed workflow', async () => {
    const subject = await registerUser({
      role: 'viewer',
      fullName: 'Original Name',
      emailPrefix: 'privacy-correction-subject',
    });
    const session = await loginUser(subject);

    const rejected = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(session.token))
      .send({
        request_type: 'correction',
        details: { field: 'role', requested_value: 'admin' },
      });
    expect(rejected.status).toBe(422);
    expect(rejected.body.error.code).toBe('CORRECTION_FIELD_NOT_SUPPORTED');

    const created = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(session.token))
      .send({
        request_type: 'correction',
        details: { field: 'full_name', requested_value: '  Updated   Name  ' },
      });
    expect(created.status).toBe(201);
    await startPrivacyReview(created.body.data.id);

    const completed = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token))
      .send({ status: 'approved', user_message: 'Your correction was approved and applied.' });
    expect(completed.status).toBe(200);
    expect(completed.body.data.status).toBe('completed');

    const stored = await pool.query(`SELECT full_name, role FROM "user" WHERE id = $1`, [
      subject.user.id,
    ]);
    expect(stored.rows[0]).toEqual({ full_name: 'Updated Name', role: 'viewer' });
  });

  test('generates an encrypted requester-isolated export before completion', async () => {
    const subject = await registerUser({ role: 'viewer', emailPrefix: 'privacy-export-subject' });
    const other = await registerUser({ role: 'viewer', emailPrefix: 'privacy-export-other' });
    const subjectSession = await loginUser(subject);
    const otherSession = await loginUser(other);

    const category = await createCategory({
      token: protectedAdmin.token,
      name: 'Privacy export activity',
    });
    const project = await createProject({
      token: protectedAdmin.token,
      categoryId: category.id,
      name: 'Privacy export activity project',
    });
    await pool.query(
      `INSERT INTO content_report
         (reporter_user_id, project_id, entity_type, entity_id, reason_code, description, status)
       VALUES ($1, $2, 'project', $2, 'privacy', $3, 'submitted')`,
      [subject.user.id, project.id, 'Include this activity in the export workflow test.'],
    );

    const importJob = await pool.query(
      `INSERT INTO gis_import_job
         (project_id, uploaded_by_user_id, original_filename, stored_filename,
          file_path, file_size_bytes, file_checksum_sha256, file_type, status,
          geometry_count, pending_feature_count)
       VALUES ($1, $2, 'personal.geojson', 'personal.geojson',
               'test/personal.geojson', 128, $3, 'geojson', 'pending_review', 1, 1)
       RETURNING id`,
      [project.id, subject.user.id, 'a'.repeat(64)],
    );
    await pool.query(
      `INSERT INTO gis_import_feature
         (import_job_id, source_index, display_title, geometry_type, geom, attributes)
       VALUES ($1, 0, 'Imported contribution', 'Point',
               ST_SetSRID(ST_MakePoint(35.51, 33.91), 4326),
               '{"source":"privacy-import-test"}'::JSONB)`,
      [importJob.rows[0].id],
    );
    await pool.query(
      `INSERT INTO spatial_feature
         (project_id, collected_by_user_id, geom, attributes, status,
          reviewed_by_user_id, reviewed_at)
       VALUES ($1, $2, ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326),
               '{"source":"privacy-export-test"}'::JSONB, 'approved', $3,
               CURRENT_TIMESTAMP)`,
      [project.id, subject.user.id, protectedAdmin.user.id],
    );
    const created = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(subjectSession.token))
      .send({ request_type: 'access_export', current_password: subject.password });
    expect(created.status).toBe(201);
    await startPrivacyReview(created.body.data.id);

    const premature = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token))
      .send({ status: 'completed' });
    expect(premature.status).toBe(400);
    expect(premature.body.message).toBe('Validation failed');

    const scheduled = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token))
      .send({ status: 'approved' });
    expect(scheduled.status).toBe(200);
    expect(scheduled.body.data.status).toBe('scheduled');

    const artifact = await pool.query(
      `SELECT id FROM privacy_export_artifact WHERE privacy_request_id = $1`,
      [created.body.data.id],
    );
    const orphanedReference = storageAdapter.reference(
      'exports',
      `privacy-data/${artifact.rows[0].id}-interrupted.html.enc`,
    );
    await storageAdapter.writeExclusive(orphanedReference, Buffer.from('interrupted-attempt'));
    await pool.query(
      `UPDATE privacy_export_artifact
       SET status = 'generating', encrypted_file_path = $2
       WHERE id = $1`,
      [artifact.rows[0].id, orphanedReference],
    );
    await processPersonalDataExport(artifact.rows[0].id);

    const ready = await pool.query(
      `SELECT status, encrypted_file_path, encryption_iv, encryption_auth_tag,
              plaintext_sha256, record_counts, format_version, content_type
       FROM privacy_export_artifact WHERE id = $1`,
      [artifact.rows[0].id],
    );
    expect(ready.rows[0]).toEqual(
      expect.objectContaining({
        status: 'ready',
        encrypted_file_path: expect.any(String),
        encryption_iv: expect.any(Buffer),
        encryption_auth_tag: expect.any(Buffer),
        plaintext_sha256: expect.stringMatching(/^[a-f0-9]{64}$/),
        format_version: 'terraleb-personal-data-v3',
        content_type: 'text/html; charset=utf-8',
      }),
    );
    expect(ready.rows[0].encrypted_file_path).toMatch(/^storage:\/\/exports\/privacy-data\//);
    expect(ready.rows[0].encrypted_file_path).not.toBe(orphanedReference);
    await expect(storageAdapter.exists(orphanedReference, ['exports'])).resolves.toBe(false);

    const isolated = await request(app)
      .post(`${API_PREFIX}/privacy/requests/${created.body.data.id}/export-grant`)
      .set(authHeader(otherSession.token))
      .send({ current_password: other.password });
    expect(isolated.status).toBe(409);

    const grant = await request(app)
      .post(`${API_PREFIX}/privacy/requests/${created.body.data.id}/export-grant`)
      .set(authHeader(subjectSession.token))
      .send({ current_password: subject.password });
    expect(grant.status).toBe(201);

    const download = await request(app)
      .get(grant.body.data.download_path)
      .set('X-Privacy-Export-Grant', grant.body.data.grant_token)
      .set(authHeader(subjectSession.token));
    expect(download.status).toBe(200);
    expect(download.headers['content-type']).toContain('text/html');
    expect(download.headers['content-disposition']).toContain('.html');
    expect(download.text).toContain('TerraLeb personal data report');
    expect(download.text).toContain(subject.email);
    expect(download.text).toContain('Imported contribution');
    expect(download.text).toContain('Privacy export activity project');
    expect(download.text).not.toContain(other.email);
    expect(download.text).not.toContain(subject.user.id);
    expect(download.text).not.toContain(project.id);
    expect(download.text).not.toContain(created.body.data.id);
    expect(download.text).not.toContain(importJob.rows[0].id);
    expect(download.text).not.toContain('Technical details');
    expect(download.text).not.toMatch(
      /\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i,
    );
    expect(download.headers['content-disposition']).not.toContain(created.body.data.id);

    const replay = await request(app)
      .get(grant.body.data.download_path)
      .set('X-Privacy-Export-Grant', grant.body.data.grant_token)
      .set(authHeader(subjectSession.token));
    expect(replay.status).toBe(403);

    const grantCreatedBeforeLegacyDowngrade = await request(app)
      .post(`${API_PREFIX}/privacy/requests/${created.body.data.id}/export-grant`)
      .set(authHeader(subjectSession.token))
      .send({ current_password: subject.password });
    expect(grantCreatedBeforeLegacyDowngrade.status).toBe(201);

    await pool.query(
      `UPDATE privacy_export_artifact SET format_version = 'terraleb-personal-data-v2'
       WHERE id = $1`,
      [artifact.rows[0].id],
    );

    const legacyDownload = await request(app)
      .get(grantCreatedBeforeLegacyDowngrade.body.data.download_path)
      .set('X-Privacy-Export-Grant', grantCreatedBeforeLegacyDowngrade.body.data.grant_token)
      .set(authHeader(subjectSession.token));
    expect(legacyDownload.status).toBe(403);

    const legacyGrant = await request(app)
      .post(`${API_PREFIX}/privacy/requests/${created.body.data.id}/export-grant`)
      .set(authHeader(subjectSession.token))
      .send({ current_password: subject.password });
    expect(legacyGrant.status).toBe(409);
  });

  test('pseudonymizes a completed administrator deletion without changing project attribution', async () => {
    const subject = await createAdminUser({ emailPrefix: 'privacy-deletion-admin' });
    const category = await createCategory({
      token: protectedAdmin.token,
      name: 'Admin deletion category',
    });
    const project = await createProject({
      token: subject.token,
      categoryId: category.id,
      name: 'Admin deletion project',
    });

    const created = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(subject.token))
      .send({ request_type: 'deletion', current_password: subject.password });
    expect(created.status).toBe(201);
    await startPrivacyReview(created.body.data.id);

    const scheduled = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token))
      .send({
        status: 'approved',
        user_message: 'Your deletion request was approved and scheduled.',
        unfinished_work_decision: 'require_resolution',
        responsibility_decision: 'release',
      });
    expect(scheduled.status).toBe(200);
    expect(scheduled.body.data.status).toBe('scheduled');

    const execution = await pool.query(
      `SELECT id FROM account_deletion_execution WHERE privacy_request_id = $1`,
      [created.body.data.id],
    );
    await processAccountDeletion(execution.rows[0].id);

    const attribution = await pool.query(`SELECT created_by_user_id FROM project WHERE id = $1`, [
      project.id,
    ]);
    expect(attribution.rows[0].created_by_user_id).toBe(subject.user.id);
    const deleted = await pool.query(
      `SELECT account_status, email, full_name, masked_contributor_label FROM "user" WHERE id = $1`,
      [subject.user.id],
    );
    expect(deleted.rows[0]).toEqual(
      expect.objectContaining({
        account_status: 'deleted',
        email: null,
        full_name: null,
        masked_contributor_label: 'P. A.',
      }),
    );

    const redactedRequest = await request(app)
      .get(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token));
    expect(redactedRequest.status).toBe(200);
    expect(redactedRequest.body.data.request).toEqual(
      expect.objectContaining({
        requester_label: 'P. A.',
        requester_contact: null,
      }),
    );
    expect(JSON.stringify(redactedRequest.body)).not.toContain(subject.email);
    expect(JSON.stringify(redactedRequest.body)).not.toContain(subject.user.full_name);
  });

  test('tombstones a contributor while retaining institutional GIS relationships', async () => {
    const category = await createCategory({
      token: protectedAdmin.token,
      name: 'Deletion integrity category',
    });
    const project = await createProject({
      token: protectedAdmin.token,
      categoryId: category.id,
      name: 'Deletion integrity project',
    });
    const subject = await registerUser({
      role: 'contributor',
      fullName: 'علي حسن',
      emailPrefix: 'privacy-deletion-subject',
    });
    await pool.query(
      `UPDATE "user" SET is_active = TRUE, account_status = 'active' WHERE id = $1`,
      [subject.user.id],
    );
    const session = await loginUser(subject);
    const contribution = await pool.query(
      `INSERT INTO spatial_feature
         (project_id, collected_by_user_id, geom, attributes, status, submitted_at,
          reviewed_at, reviewed_by_user_id)
       VALUES ($1, $2, ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326),
               '{"source":"field"}'::JSONB, 'approved', CURRENT_TIMESTAMP,
               CURRENT_TIMESTAMP, $3)
       RETURNING id`,
      [project.id, subject.user.id, protectedAdmin.user.id],
    );
    const unfinishedContribution = await pool.query(
      `INSERT INTO spatial_feature
         (project_id, collected_by_user_id, geom, attributes, status)
       VALUES ($1, $2, ST_SetSRID(ST_MakePoint(35.51, 33.91), 4326),
               '{"source":"unfinished"}'::JSONB, 'draft')
       RETURNING id`,
      [project.id, subject.user.id],
    );
    await pool.query(
      `INSERT INTO photo (feature_id, file_path, status)
       VALUES ($1, $2, 'pending')`,
      [
        unfinishedContribution.rows[0].id,
        `storage://uploads/.private/feature-photos/${unfinishedContribution.rows[0].id}.jpg`,
      ],
    );
    await pool.query(`UPDATE spatial_feature SET review_notes = $2 WHERE id = $1`, [
      contribution.rows[0].id,
      `Reviewed contribution by ${subject.user.full_name}`,
    ]);
    const structuredCorrection = await pool.query(
      `INSERT INTO privacy_request
         (user_id, request_type, status, request_details, identity_verified_at,
          completed_at, resolution_summary)
       VALUES ($1, 'correction', 'completed', $2::JSONB, CURRENT_TIMESTAMP,
               CURRENT_TIMESTAMP, 'Completed before account deletion.')
       RETURNING id`,
      [
        subject.user.id,
        JSON.stringify({ field: 'full_name', requested_value: subject.user.full_name }),
      ],
    );
    const identityAudit = await pool.query(
      `INSERT INTO audit_log
         (user_id, action_type, entity_type, entity_id, new_values)
       VALUES ($1, 'update', 'user', $1, $2::JSONB)
       RETURNING id`,
      [
        subject.user.id,
        JSON.stringify({
          full_name: subject.user.full_name,
          email: subject.email,
          note: `Profile for ${subject.user.full_name}`,
        }),
      ],
    );
    const relatedNotification = await pool.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES ($1, 'account_event', $2, $3, $4::JSONB)
       RETURNING id`,
      [
        protectedAdmin.user.id,
        `Contribution from ${subject.user.full_name}`,
        `Contact ${subject.email}`,
        JSON.stringify({ user_id: subject.user.id, full_name: subject.user.full_name }),
      ],
    );

    const created = await request(app)
      .post(`${API_PREFIX}/privacy/requests`)
      .set(authHeader(session.token))
      .send({
        request_type: 'deletion',
        current_password: subject.password,
        details: { offline_data_resolved: true },
      });
    expect(created.status).toBe(201);
    await startPrivacyReview(created.body.data.id);

    const noDecision = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token))
      .send({ status: 'approved' });
    expect(noDecision.status).toBe(422);

    const resolveFirst = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token))
      .send({
        status: 'approved',
        unfinished_work_decision: 'require_resolution',
        responsibility_decision: 'release',
      });
    expect(resolveFirst.status).toBe(409);

    const scheduled = await request(app)
      .patch(`${API_PREFIX}/privacy/admin/requests/${created.body.data.id}`)
      .set(authHeader(protectedAdmin.token))
      .send({
        status: 'approved',
        unfinished_work_decision: 'discard_unapproved',
        responsibility_decision: 'release',
      });
    expect(scheduled.status).toBe(200);
    expect(scheduled.body.data.status).toBe('scheduled');

    const execution = await pool.query(
      `SELECT id FROM account_deletion_execution WHERE privacy_request_id = $1`,
      [created.body.data.id],
    );
    await processAccountDeletion(execution.rows[0].id);

    const tombstone = await pool.query(
      `SELECT email, phone, phone_e164, full_name, password_hash, account_status,
              is_active, permanently_deleted_at, masked_contributor_label
       FROM "user" WHERE id = $1`,
      [subject.user.id],
    );
    expect(tombstone.rows[0]).toEqual(
      expect.objectContaining({
        email: null,
        phone: null,
        phone_e164: null,
        full_name: null,
        password_hash: null,
        account_status: 'deleted',
        is_active: false,
        permanently_deleted_at: expect.any(Date),
        masked_contributor_label: 'ع. ح.',
      }),
    );

    const retained = await pool.query(
      `SELECT collected_by_user_id, status FROM spatial_feature WHERE id = $1`,
      [contribution.rows[0].id],
    );
    expect(retained.rows[0]).toEqual({
      collected_by_user_id: subject.user.id,
      status: 'approved',
    });
    expect(
      Number(
        (
          await pool.query(`SELECT COUNT(*) FROM spatial_feature WHERE id = $1`, [
            unfinishedContribution.rows[0].id,
          ])
        ).rows[0].count,
      ),
    ).toBe(0);
    const deletionEvidence = await pool.query(
      `SELECT unfinished_work_decision, responsibility_decision, discard_counts,
              artifact_cleanup_completed_at
         FROM account_deletion_execution WHERE privacy_request_id = $1`,
      [created.body.data.id],
    );
    expect(deletionEvidence.rows[0]).toEqual(
      expect.objectContaining({
        unfinished_work_decision: 'discard_unapproved',
        responsibility_decision: 'release',
        artifact_cleanup_completed_at: expect.any(Date),
      }),
    );
    expect(Number(deletionEvidence.rows[0].discard_counts.unapproved_features)).toBe(1);
    expect(
      Number(
        (
          await pool.query(`SELECT COUNT(*) FROM auth_session WHERE user_id = $1`, [
            subject.user.id,
          ])
        ).rows[0].count,
      ),
    ).toBe(0);
    expect(
      Number(
        (
          await pool.query(
            `SELECT COUNT(*) FROM backup_account_deletion_schedule WHERE user_id = $1`,
            [subject.user.id],
          )
        ).rows[0].count,
      ),
    ).toBe(1);

    const scrubbedCorrection = await pool.query(
      `SELECT request_details FROM privacy_request WHERE id = $1`,
      [structuredCorrection.rows[0].id],
    );
    expect(scrubbedCorrection.rows[0].request_details.requested_value).toBe('ع. ح.');
    const scrubbedAudit = await pool.query(`SELECT new_values FROM audit_log WHERE id = $1`, [
      identityAudit.rows[0].id,
    ]);
    expect(JSON.stringify(scrubbedAudit.rows[0].new_values)).not.toContain(subject.email);
    expect(JSON.stringify(scrubbedAudit.rows[0].new_values)).not.toContain(subject.user.full_name);
    const scrubbedNotification = await pool.query(
      `SELECT title, message, metadata FROM notification WHERE id = $1`,
      [relatedNotification.rows[0].id],
    );
    expect(JSON.stringify(scrubbedNotification.rows[0])).not.toContain(subject.email);
    expect(JSON.stringify(scrubbedNotification.rows[0])).not.toContain(subject.user.full_name);
    expect(
      Number(
        (
          await pool.query(
            `SELECT COUNT(*) FROM privacy_free_text_review_task
             WHERE privacy_request_id = $1 AND record_table = 'spatial_feature'`,
            [created.body.data.id],
          )
        ).rows[0].count,
      ),
    ).toBeGreaterThan(0);

    const login = await request(app)
      .post(`${API_PREFIX}/auth/login`)
      .send({ email: subject.email, password: subject.password });
    expect(login.status).not.toBe(200);
  });
});
