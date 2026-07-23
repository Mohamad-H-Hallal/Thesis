const { randomUUID } = require('node:crypto');
const {
  API_PREFIX,
  app,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  createAdminUser,
  loginUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
} = require('./helpers/api-test-helpers');
const { generateToken } = require('../src/middleware/auth');
const { looksLikeOfflineSync } = require('../src/middleware/offlineSyncRateLimit');
const logger = require('../src/utils/logger');
const {
  assertOfflinePayloadSize,
  validateAttributesAgainstSchema,
} = require('../src/services/offlineSyncSecurity.service');

jest.setTimeout(90000);

const expectPermanent = (response, code, status = 403) => {
  expect(response.status).toBe(status);
  expect(response.body.error).toEqual({
    code,
    disposition: 'permanent_rejection',
    retryable: false,
  });
};

const offlineHeaders = ({ token, ownerId, projectId, key = randomUUID() }) => ({
  ...authHeader(token),
  'Idempotency-Key': key,
  'X-Offline-Owner-Id': ownerId,
  'X-Offline-Project-Id': projectId,
});

const offlinePayload = ({ ownerId, projectId, id = randomUUID(), ...overrides }) => ({
  id,
  client_offline_id: id,
  offline_owner_user_id: ownerId,
  project_id: projectId,
  geom: { type: 'Point', coordinates: [35.5, 33.9] },
  attributes: { feature_type: 'olive', condition: 'good' },
  collected_offline: true,
  ...overrides,
});

const createFixture = async () => {
  const admin = await createAdminUser({
    fullName: 'Offline Security Admin',
    emailPrefix: `osa-${randomUUID().slice(0, 8)}`,
  });
  const contributorA = await registerUser({
    role: 'contributor',
    fullName: 'Offline Security Contributor A',
    emailPrefix: `osa-${randomUUID().slice(0, 8)}`,
  });
  const contributorB = await registerUser({
    role: 'contributor',
    fullName: 'Offline Security Contributor B',
    emailPrefix: `osb-${randomUUID().slice(0, 8)}`,
  });
  await approveContributorRequest({ token: admin.token, userId: contributorA.user.id });
  await approveContributorRequest({ token: admin.token, userId: contributorB.user.id });

  const category = await createCategory({
    token: admin.token,
    name: `Offline Security ${randomUUID()}`,
  });
  const projectA = await createProject({
    token: admin.token,
    categoryId: category.id,
    name: `Offline Security A ${randomUUID()}`,
  });
  const projectB = await createProject({
    token: admin.token,
    categoryId: category.id,
    name: `Offline Security B ${randomUUID()}`,
  });
  for (const project of [projectA, projectB]) {
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);
  }
  await pool.query(
    `UPDATE project
     SET start_date = CURRENT_DATE - INTERVAL '1 day', end_date = NULL
     WHERE id = ANY($1::uuid[])`,
    [[projectA.id, projectB.id]],
  );

  const assignmentA = await createAssignment({
    token: admin.token,
    projectId: projectA.id,
    userId: contributorA.user.id,
  });
  const assignmentB = await createAssignment({
    token: admin.token,
    projectId: projectB.id,
    userId: contributorB.user.id,
  });
  await updateAssignmentStatus({
    token: admin.token,
    assignmentId: assignmentA.id,
    status: 'approved',
  });
  await updateAssignmentStatus({
    token: admin.token,
    assignmentId: assignmentB.id,
    status: 'approved',
  });

  const loginA = await loginUser({
    email: contributorA.email,
    password: contributorA.password,
  });
  const loginB = await loginUser({
    email: contributorB.email,
    password: contributorB.password,
  });
  return {
    admin,
    contributorA,
    contributorB,
    loginA,
    loginB,
    projectA,
    projectB,
    assignmentA,
  };
};

describe('Offline synchronization security boundary', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('offline limiter recognizes legacy owner and client identifiers without headers', () => {
    for (const body of [
      { offline_owner_user_id: randomUUID() },
      { client_offline_id: randomUUID() },
      { expected_version: 1 },
      { features: [{ offline_owner_user_id: randomUUID() }] },
      { features: [{ client_offline_id: randomUUID() }] },
    ]) {
      expect(looksLikeOfflineSync({ body, headers: {} })).toBe(true);
    }
    expect(looksLikeOfflineSync({ body: {}, headers: {} })).toBe(false);
  });

  test('strictly validates normalized form field types and JSON-schema integers', () => {
    const schema = {
      properties: { tree_count: { type: 'integer' } },
      fields: [
        { key: 'notes', type: 'textarea' },
        { key: 'species', type: 'select', options: ['olive'] },
        { key: 'observed_on', type: 'date' },
      ],
    };

    for (const attributes of [
      { notes: { unsafe: true } },
      { species: 1 },
      { observed_on: 20260723 },
      { tree_count: 1.5 },
    ]) {
      expect(() =>
        validateAttributesAgainstSchema(attributes, schema, { strictOffline: true }),
      ).toThrow('Offline submission attribute type is invalid.');
    }

    for (const observedOn of ['2026-02-29', '2026-02-31', '2026-13-01', '2026-00-10']) {
      expect(() =>
        validateAttributesAgainstSchema({ observed_on: observedOn }, schema, {
          strictOffline: true,
        }),
      ).toThrow('Offline submission date attribute is invalid.');
    }

    expect(
      validateAttributesAgainstSchema(
        {
          notes: 'healthy grove',
          species: 'olive',
          observed_on: '2026-07-23',
          tree_count: 12,
        },
        schema,
        { strictOffline: true },
      ),
    ).toEqual({
      notes: 'healthy grove',
      species: 'olive',
      observed_on: '2026-07-23',
      tree_count: 12,
    });
    expect(
      validateAttributesAgainstSchema({ observed_on: '2028-02-29' }, schema, {
        strictOffline: true,
      }),
    ).toEqual({ observed_on: '2028-02-29' });

    let deeplyNested = 'leaf';
    for (let depth = 0; depth < 1000; depth += 1) {
      deeplyNested = { nested: deeplyNested };
    }
    expect(() => assertOfflinePayloadSize(deeplyNested)).toThrow(
      'Offline submission payload is nested too deeply.',
    );

    const legacyJsonSchema = {
      type: 'object',
      additionalProperties: false,
      required: ['observed_at', 'tags', 'details'],
      properties: {
        observed_at: { type: 'string', format: 'date-time' },
        tags: {
          type: 'array',
          minItems: 1,
          maxItems: 2,
          uniqueItems: true,
          items: { type: 'string', enum: ['olive', 'cedar'] },
        },
        details: {
          type: 'object',
          additionalProperties: false,
          required: ['healthy'],
          properties: {
            healthy: { type: 'boolean' },
            count: { type: 'integer', minimum: 0, maximum: 10 },
          },
        },
      },
    };
    expect(
      validateAttributesAgainstSchema(
        {
          observed_at: '2026-07-23T10:15:30Z',
          tags: ['olive', 'cedar'],
          details: { healthy: true, count: 2 },
        },
        legacyJsonSchema,
        { strictOffline: true },
      ),
    ).toEqual({
      observed_at: '2026-07-23T10:15:30Z',
      tags: ['olive', 'cedar'],
      details: { healthy: true, count: 2 },
    });

    for (const attributes of [
      {
        observed_at: '2025-02-31T00:00:00Z',
        tags: ['olive'],
        details: { healthy: true },
      },
      {
        observed_at: '2026-07-23T10:15:30Z',
        tags: ['olive', 'olive'],
        details: { healthy: true },
      },
      {
        observed_at: '2026-07-23T10:15:30Z',
        tags: ['olive'],
        details: { healthy: null },
      },
      {
        observed_at: '2026-07-23T10:15:30Z',
        tags: ['olive'],
        details: { healthy: true, unexpected: 'field' },
      },
      {
        observed_at: '2026-07-23T10:15:30Z',
        tags: ['olive'],
        details: { healthy: true, toString: 'prototype-chain field' },
      },
    ]) {
      expect(() =>
        validateAttributesAgainstSchema(attributes, legacyJsonSchema, { strictOffline: true }),
      ).toThrow(/Offline submission/);
    }

    for (const invalidServerSchema of [
      { properties: { value: { type: 'unsupported' } } },
      { properties: { value: { type: 'string', minLength: 5, maxLength: 2 } } },
      { properties: { status: { type: 'string' } } },
      { properties: { value: { type: 'string', pattern: '.*' } } },
    ]) {
      expect(() =>
        validateAttributesAgainstSchema({ value: 'test' }, invalidServerSchema, {
          strictOffline: true,
        }),
      ).toThrow('Project collection form schema is unsupported or invalid.');
    }
  });

  test('revalidates current role, project window, account, assignment, and deleted-account state', async () => {
    const fixture = await createFixture();
    const { contributorA, loginA, projectA, assignmentA } = fixture;
    const attempt = async () => {
      const payload = offlinePayload({ ownerId: contributorA.user.id, projectId: projectA.id });
      return request(app)
        .post(`${API_PREFIX}/features`)
        .set(
          offlineHeaders({
            token: loginA.token,
            ownerId: contributorA.user.id,
            projectId: projectA.id,
          }),
        )
        .send(payload);
    };

    await pool.query(`UPDATE "user" SET role = 'viewer' WHERE id = $1`, [contributorA.user.id]);
    expectPermanent(await attempt(), 'OFFLINE_SYNC_ROLE_FORBIDDEN');
    for (const tamperedOfflineMarker of [false, 'true']) {
      const tamperedPayload = offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        collected_offline: tamperedOfflineMarker,
      });
      const response = await request(app)
        .post(`${API_PREFIX}/features`)
        .set(
          offlineHeaders({
            token: loginA.token,
            ownerId: contributorA.user.id,
            projectId: projectA.id,
          }),
        )
        .send(tamperedPayload);
      expectPermanent(response, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
    }
    const omittedOfflineMarker = offlinePayload({
      ownerId: contributorA.user.id,
      projectId: projectA.id,
    });
    delete omittedOfflineMarker.collected_offline;
    const omittedMarkerResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectA.id,
        }),
      )
      .send(omittedOfflineMarker);
    expectPermanent(omittedMarkerResponse, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
    await pool.query(`UPDATE "user" SET role = 'contributor' WHERE id = $1`, [
      contributorA.user.id,
    ]);

    await pool.query(`UPDATE project SET status = 'paused' WHERE id = $1`, [projectA.id]);
    expectPermanent(await attempt(), 'OFFLINE_SYNC_PROJECT_UNAVAILABLE');
    await pool.query(`UPDATE project SET status = 'active' WHERE id = $1`, [projectA.id]);

    await pool.query(
      `UPDATE project
       SET status = 'active',
           start_date = CURRENT_DATE - INTERVAL '2 days',
           end_date = CURRENT_DATE - INTERVAL '1 day'
       WHERE id = $1`,
      [projectA.id],
    );
    expectPermanent(await attempt(), 'OFFLINE_SYNC_PROJECT_UNAVAILABLE');
    const endedProject = await pool.query('SELECT status FROM project WHERE id = $1', [
      projectA.id,
    ]);
    expect(endedProject.rows[0].status).toBe('active');
    await pool.query('UPDATE project SET start_date = NULL, end_date = NULL WHERE id = $1', [
      projectA.id,
    ]);

    await pool.query(`UPDATE "user" SET is_active = FALSE WHERE id = $1`, [contributorA.user.id]);
    expectPermanent(await attempt(), 'OFFLINE_SYNC_ACCOUNT_INACTIVE');
    await pool.query(`UPDATE "user" SET is_active = TRUE WHERE id = $1`, [contributorA.user.id]);

    await pool.query(`UPDATE project_assignment SET role = 'admin' WHERE id = $1`, [
      assignmentA.id,
    ]);
    expectPermanent(await attempt(), 'OFFLINE_SYNC_ROLE_FORBIDDEN');
    await pool.query(
      `UPDATE project_assignment SET role = 'contributor', status = 'rejected' WHERE id = $1`,
      [assignmentA.id],
    );
    expectPermanent(await attempt(), 'OFFLINE_SYNC_ACCESS_REVOKED');
    await pool.query(`UPDATE project_assignment SET status = 'approved' WHERE id = $1`, [
      assignmentA.id,
    ]);

    await pool.query('DELETE FROM project_assignment WHERE id = $1', [assignmentA.id]);
    expectPermanent(await attempt(), 'OFFLINE_SYNC_ACCESS_REVOKED');

    const missingUserToken = generateToken(randomUUID(), 'contributor');
    const missingUserPayload = offlinePayload({
      ownerId: randomUUID(),
      projectId: projectA.id,
    });
    const missingUserResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: missingUserToken,
          ownerId: missingUserPayload.offline_owner_user_id,
          projectId: projectA.id,
        }),
      )
      .send(missingUserPayload);
    expectPermanent(missingUserResponse, 'OFFLINE_SYNC_ACCOUNT_INACTIVE');

    const inserted = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM spatial_feature
       WHERE collected_by_user_id = $1`,
      [contributorA.user.id],
    );
    expect(inserted.rows[0].count).toBe(0);
  });

  test('enforces current role and assignment on ordinary collection requests', async () => {
    const fixture = await createFixture();
    const payload = {
      project_id: fixture.projectA.id,
      geom: { type: 'Point', coordinates: [35.5, 33.9] },
      attributes: { feature_type: 'olive', condition: 'good' },
    };
    const attempt = () =>
      request(app)
        .post(`${API_PREFIX}/features`)
        .set(authHeader(fixture.loginA.token))
        .send(payload);

    await pool.query(`UPDATE "user" SET role = 'viewer' WHERE id = $1`, [
      fixture.contributorA.user.id,
    ]);
    expect((await attempt()).status).toBe(403);
    await pool.query(`UPDATE "user" SET role = 'contributor' WHERE id = $1`, [
      fixture.contributorA.user.id,
    ]);

    await pool.query(`UPDATE project_assignment SET role = 'admin' WHERE id = $1`, [
      fixture.assignmentA.id,
    ]);
    expect((await attempt()).status).toBe(403);
    await pool.query(
      `UPDATE project_assignment SET role = 'contributor', status = 'rejected' WHERE id = $1`,
      [fixture.assignmentA.id],
    );
    expect((await attempt()).status).toBe(403);
    await pool.query('DELETE FROM project_assignment WHERE id = $1', [fixture.assignmentA.id]);
    expect((await attempt()).status).toBe(403);

    const inserted = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM spatial_feature
       WHERE collected_by_user_id = $1`,
      [fixture.contributorA.user.id],
    );
    expect(inserted.rows[0].count).toBe(0);
  });

  test('headerless online edits of offline-origin records cannot bypass current access or policy checks', async () => {
    const fixture = await createFixture();
    const { contributorA, loginA, projectA, assignmentA } = fixture;
    const featureId = randomUUID();
    const created = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectA.id,
        }),
      )
      .send(
        offlinePayload({
          ownerId: contributorA.user.id,
          projectId: projectA.id,
          id: featureId,
        }),
      );
    expect(created.status).toBe(201);

    const legitimateEdit = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token))
      .send({ attributes: { feature_type: 'olive', condition: 'fair' } });
    expect(legitimateEdit.status).toBe(200);

    const managedFieldEdit = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token))
      .send({ attributes: { feature_type: 'olive', condition: 'fair', status: 'approved' } });
    expectPermanent(managedFieldEdit, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

    const unsafeTextEdit = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token))
      .send({
        attributes: {
          feature_type: 'olive',
          condition: '<script>alert(1)</script>',
        },
      });
    expectPermanent(unsafeTextEdit, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

    const invalidGeometryEdit = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token))
      .send({
        geom: {
          type: 'Polygon',
          coordinates: [
            [
              [35, 33],
              [36, 34],
              [35, 34],
              [36, 33],
              [35, 33],
            ],
          ],
        },
      });
    expectPermanent(invalidGeometryEdit, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

    const oversizedEdit = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token))
      .send({
        attributes: {
          feature_type: 'olive',
          condition: 'a'.repeat(260 * 1024),
        },
      });
    expectPermanent(oversizedEdit, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

    await pool.query(`UPDATE project_assignment SET status = 'rejected' WHERE id = $1`, [
      assignmentA.id,
    ]);
    const revokedEdit = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token))
      .send({ attributes: { feature_type: 'olive', condition: 'good' } });
    expectPermanent(revokedEdit, 'OFFLINE_SYNC_ACCESS_REVOKED');

    const revokedSubmit = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(authHeader(loginA.token));
    expectPermanent(revokedSubmit, 'OFFLINE_SYNC_ACCESS_REVOKED');

    const revokedDelete = await request(app)
      .delete(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token));
    expectPermanent(revokedDelete, 'OFFLINE_SYNC_ACCESS_REVOKED');

    await pool.query(
      `UPDATE project_assignment SET status = 'approved', role = 'admin' WHERE id = $1`,
      [assignmentA.id],
    );
    const removedPermissionDelete = await request(app)
      .delete(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(loginA.token));
    expectPermanent(removedPermissionDelete, 'OFFLINE_SYNC_ROLE_FORBIDDEN');

    const retainedAfterRejectedDeletes = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature WHERE id = $1',
      [featureId],
    );
    expect(retainedAfterRejectedDeletes.rows[0].count).toBe(1);

    await pool.query(`UPDATE project_assignment SET role = 'contributor' WHERE id = $1`, [
      assignmentA.id,
    ]);
    await pool.query(
      `UPDATE project SET requires_photos = TRUE, min_photos = 1, max_photos = 3 WHERE id = $1`,
      [projectA.id],
    );
    const missingPhotoSubmit = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(authHeader(loginA.token));
    expect(missingPhotoSubmit.status).toBe(422);

    const managedSubmit = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(authHeader(loginA.token))
      .send({ status: 'approved' });
    expectPermanent(managedSubmit, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

    await pool.query('UPDATE "user" SET is_active = FALSE WHERE id = $1', [contributorA.user.id]);
    const inactiveLegacyRequests = [
      await request(app)
        .put(`${API_PREFIX}/features/${featureId}`)
        .set(authHeader(loginA.token))
        .send({ attributes: { feature_type: 'olive', condition: 'good' } }),
      await request(app)
        .post(`${API_PREFIX}/features/${featureId}/submit`)
        .set(authHeader(loginA.token)),
      await request(app)
        .post(`${API_PREFIX}/photos/feature/${featureId}`)
        .set(authHeader(loginA.token)),
    ];
    for (const response of inactiveLegacyRequests) {
      expectPermanent(response, 'OFFLINE_SYNC_ACCOUNT_INACTIVE', 403);
    }

    const state = await pool.query(
      `SELECT status, attributes, version,
              (SELECT COUNT(*)::int FROM notification
                WHERE metadata->>'feature_id' = $2) AS notification_count
       FROM spatial_feature
       WHERE id = $1`,
      [featureId, featureId],
    );
    expect(state.rows[0].status).toBe('draft');
    expect(state.rows[0].attributes).toEqual({ feature_type: 'olive', condition: 'fair' });
    expect(state.rows[0].version).toBe(2);
    expect(state.rows[0].notification_count).toBe(0);
  });

  test('rejects owner, project, parent, identifier, unknown-field, and managed-field tampering', async () => {
    const fixture = await createFixture();
    const { contributorA, contributorB, loginA, loginB, projectA, projectB } = fixture;

    const ownerTamper = offlinePayload({
      ownerId: contributorA.user.id,
      projectId: projectA.id,
    });
    const ownerResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: loginB.token,
          ownerId: contributorA.user.id,
          projectId: projectA.id,
        }),
      )
      .send(ownerTamper);
    expectPermanent(ownerResponse, 'OFFLINE_SYNC_OWNER_MISMATCH');

    const projectTamper = offlinePayload({
      ownerId: contributorA.user.id,
      projectId: projectA.id,
    });
    const projectResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectB.id,
        }),
      )
      .send(projectTamper);
    expectPermanent(projectResponse, 'OFFLINE_SYNC_PROJECT_MISMATCH');

    for (const overrides of [
      { status: 'approved' },
      { reviewed_by_user_id: contributorB.user.id },
      { task_id: randomUUID() },
      { collected_by_user_id: contributorB.user.id },
      { attributes: { feature_type: 'olive', status: 'approved' } },
      { unknown_field: 'unexpected' },
    ]) {
      const payload = offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        ...overrides,
      });
      const response = await request(app)
        .post(`${API_PREFIX}/features`)
        .set(
          offlineHeaders({
            token: loginA.token,
            ownerId: contributorA.user.id,
            projectId: projectA.id,
          }),
        )
        .send(payload);
      expectPermanent(response, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
    }

    const missingOwner = offlinePayload({
      ownerId: contributorA.user.id,
      projectId: projectA.id,
    });
    delete missingOwner.offline_owner_user_id;
    expectPermanent(
      await request(app)
        .post(`${API_PREFIX}/features`)
        .set(
          offlineHeaders({
            token: loginA.token,
            ownerId: contributorA.user.id,
            projectId: projectA.id,
          }),
        )
        .send(missingOwner),
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );

    const acceptedForB = offlinePayload({
      ownerId: contributorB.user.id,
      projectId: projectB.id,
    });
    await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: loginB.token,
          ownerId: contributorB.user.id,
          projectId: projectB.id,
        }),
      )
      .send(acceptedForB)
      .expect(201);
    const collision = offlinePayload({
      ownerId: contributorA.user.id,
      projectId: projectA.id,
      id: acceptedForB.id,
    });
    const collisionResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectA.id,
        }),
      )
      .send(collision);
    expectPermanent(collisionResponse, 'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH', 409);

    const parentResponse = await request(app)
      .post(`${API_PREFIX}/features/${acceptedForB.id}/submit`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectB.id,
        }),
      );
    expectPermanent(parentResponse, 'OFFLINE_SYNC_OWNER_MISMATCH');
  });

  test('rejects malformed, oversized, deeply nested, unsafe text, and pathological geometry', async () => {
    const fixture = await createFixture();
    const { contributorA, loginA, projectA } = fixture;
    const send = (payload) =>
      request(app)
        .post(`${API_PREFIX}/features`)
        .set(
          offlineHeaders({
            token: loginA.token,
            ownerId: contributorA.user.id,
            projectId: projectA.id,
          }),
        )
        .send(payload);

    const unsafeMarker = `offline-secret-${randomUUID()}`;
    const invalidPayloads = [
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        attributes: { feature_type: 'olive', condition: { invalid: true } },
      }),
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        attributes: {
          feature_type: 'olive',
          condition: `<script>${unsafeMarker}</script>`,
        },
      }),
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        attributes: { feature_type: 'olive', condition: `good\u0000${unsafeMarker}` },
      }),
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        attributes: { feature_type: 'olive', condition: 'x'.repeat(270000) },
      }),
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        geom: { type: 'Point', coordinates: [181, 33.9] },
      }),
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        geom: { type: 'Point', coordinates: [35.5, 33.9, 100] },
      }),
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        geom: {
          type: 'Polygon',
          coordinates: [
            [
              [35, 33],
              [36, 34],
              [35, 34],
              [36, 33],
              [35, 33],
            ],
          ],
        },
      }),
    ];

    let nested = 'good';
    for (let depth = 0; depth < 12; depth += 1) {
      nested = { nested };
    }
    invalidPayloads.push(
      offlinePayload({
        ownerId: contributorA.user.id,
        projectId: projectA.id,
        attributes: { feature_type: 'olive', condition: nested },
      }),
    );

    for (const payload of invalidPayloads) {
      expectPermanent(await send(payload), 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
    }

    const databaseCheck = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature WHERE collected_by_user_id = $1`,
      [contributorA.user.id],
    );
    expect(databaseCheck.rows[0].count).toBe(0);
    const auditCheck = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM audit_log
       WHERE user_id = $1 AND entity_type = 'spatial_feature'`,
      [contributorA.user.id],
    );
    expect(auditCheck.rows[0].count).toBe(0);
  });

  test('does not write rejected unsafe payload content to application logs or audit rows', async () => {
    const fixture = await createFixture();
    const marker = `rejected-sensitive-${randomUUID()}`;
    const spies = ['error', 'warn', 'info'].map((level) =>
      jest.spyOn(logger, level).mockImplementation(() => logger),
    );
    try {
      const response = await request(app)
        .post(`${API_PREFIX}/features`)
        .set(
          offlineHeaders({
            token: fixture.loginA.token,
            ownerId: fixture.contributorA.user.id,
            projectId: fixture.projectA.id,
          }),
        )
        .send(
          offlinePayload({
            ownerId: fixture.contributorA.user.id,
            projectId: fixture.projectA.id,
            attributes: {
              feature_type: 'olive',
              condition: `<script>${marker}</script>`,
            },
          }),
        );
      expectPermanent(response, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
      expect(JSON.stringify(spies.flatMap((spy) => spy.mock.calls))).not.toContain(marker);

      const auditRows = await pool.query(
        `SELECT COUNT(*)::int AS count
         FROM audit_log
         WHERE user_id = $1 AND entity_type = 'spatial_feature'`,
        [fixture.contributorA.user.id],
      );
      expect(auditRows.rows[0].count).toBe(0);
    } finally {
      for (const spy of spies) {
        spy.mockRestore();
      }
    }
  });

  test('permanently rejects deterministic legacy submit policy failures without partial writes', async () => {
    const fixture = await createFixture();
    const { contributorA, loginA, projectA } = fixture;
    const featureId = randomUUID();
    const createResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectA.id,
        }),
      )
      .send(
        offlinePayload({
          ownerId: contributorA.user.id,
          projectId: projectA.id,
          id: featureId,
        }),
      );
    expect(createResponse.status).toBe(201);
    await pool.query(
      `UPDATE project SET requires_photos = TRUE, min_photos = 1, max_photos = 3
       WHERE id = $1`,
      [projectA.id],
    );

    const submitResponse = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectA.id,
        }),
      );
    expectPermanent(submitResponse, 'OFFLINE_SYNC_ATTACHMENT_REJECTED', 422);

    const state = await pool.query(
      `SELECT
         (SELECT status FROM spatial_feature WHERE id = $1) AS status,
         (SELECT COUNT(*)::int FROM offline_sync_receipt
           WHERE project_id = $2 AND operation = 'submit') AS submit_receipts,
         (SELECT COUNT(*)::int FROM notification
           WHERE metadata->>'feature_id' = $1::text) AS notifications`,
      [featureId, projectA.id],
    );
    expect(state.rows[0]).toEqual({
      status: 'draft',
      submit_receipts: 0,
      notifications: 0,
    });
  });

  test('versions legacy updates and replays exact create, update, and batch requests before mutable policy checks', async () => {
    const fixture = await createFixture();
    const { contributorA, loginA, projectA, assignmentA } = fixture;
    const featureId = randomUUID();
    const createKey = randomUUID();
    const createHeaders = offlineHeaders({
      token: loginA.token,
      ownerId: contributorA.user.id,
      projectId: projectA.id,
      key: createKey,
    });
    const createBody = offlinePayload({
      ownerId: contributorA.user.id,
      projectId: projectA.id,
      id: featureId,
    });
    const created = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(createHeaders)
      .send(createBody);
    expect(created.status).toBe(201);
    expect(created.body.data.version).toBe(1);

    const updateKey = randomUUID();
    const updateHeaders = offlineHeaders({
      token: loginA.token,
      ownerId: contributorA.user.id,
      projectId: projectA.id,
      key: updateKey,
    });
    const updateBody = {
      attributes: { feature_type: 'olive', condition: 'fair' },
      expected_version: 1,
    };
    const updated = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(updateHeaders)
      .send(updateBody);
    expect(updated.status).toBe(200);
    expect(updated.body.data).toMatchObject({ version: 2, outcome: 'accepted' });

    const batchKey = randomUUID();
    const batchHeaders = offlineHeaders({
      token: loginA.token,
      ownerId: contributorA.user.id,
      projectId: projectA.id,
      key: batchKey,
    });
    const batchBody = {
      features: [randomUUID(), randomUUID()].map((id) =>
        offlinePayload({ ownerId: contributorA.user.id, projectId: projectA.id, id }),
      ),
    };
    const batchCreated = await request(app)
      .post(`${API_PREFIX}/features/batch`)
      .set(batchHeaders)
      .send(batchBody);
    expect(batchCreated.status).toBe(201);

    const originalPolicy = await pool.query(
      'SELECT collection_form_schema FROM project WHERE id = $1',
      [projectA.id],
    );
    const changedSchema = structuredClone(originalPolicy.rows[0].collection_form_schema);
    changedSchema.fields = changedSchema.fields.map((field) =>
      field.key === 'condition' ? { ...field, options: ['healthy'] } : field,
    );
    await pool.query('UPDATE project SET collection_form_schema = $1::jsonb WHERE id = $2', [
      JSON.stringify(changedSchema),
      projectA.id,
    ]);

    const createReplay = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(createHeaders)
      .send(createBody);
    const updateReplay = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(updateHeaders)
      .send(updateBody);
    const batchReplay = await request(app)
      .post(`${API_PREFIX}/features/batch`)
      .set(batchHeaders)
      .send(batchBody);
    expect(createReplay.status).toBe(200);
    expect(createReplay.body.data.outcome).toBe('already_synchronized');
    expect(updateReplay.status).toBe(200);
    expect(updateReplay.body.data.outcome).toBe('already_synchronized');
    expect(batchReplay.status).toBe(200);
    expect(batchReplay.body.outcome).toBe('already_synchronized');

    await pool.query(`UPDATE spatial_feature SET status = 'pending_review' WHERE id = $1`, [
      featureId,
    ]);
    const statusChangedReplay = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(updateHeaders)
      .send(updateBody);
    expect(statusChangedReplay.status).toBe(200);
    expect(statusChangedReplay.body.data.outcome).toBe('already_synchronized');
    await pool.query(`UPDATE spatial_feature SET status = 'draft' WHERE id = $1`, [featureId]);

    const changedKeyPayload = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(updateHeaders)
      .send({ ...updateBody, expected_version: 2 });
    expectPermanent(changedKeyPayload, 'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH', 409);

    const staleVersion = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(
        offlineHeaders({
          token: loginA.token,
          ownerId: contributorA.user.id,
          projectId: projectA.id,
        }),
      )
      .send(updateBody);
    expect(staleVersion.status).toBe(409);
    expect(staleVersion.body.error).toEqual({
      code: 'OFFLINE_SYNC_VERSION_CONFLICT',
      disposition: 'conflict',
      retryable: false,
      current_version: 2,
    });

    for (const invalidVersion of [undefined, 0, 1.5, '1']) {
      const invalidBody = { attributes: { feature_type: 'olive', condition: 'fair' } };
      if (invalidVersion !== undefined) invalidBody.expected_version = invalidVersion;
      const response = await request(app)
        .put(`${API_PREFIX}/features/${featureId}`)
        .set(
          offlineHeaders({
            token: loginA.token,
            ownerId: contributorA.user.id,
            projectId: projectA.id,
          }),
        )
        .send(invalidBody);
      expectPermanent(response, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
    }

    const managedReplayTamper = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(updateHeaders)
      .send({
        attributes: { feature_type: 'olive', condition: 'fair', status: 'approved' },
        expected_version: 1,
      });
    expectPermanent(managedReplayTamper, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

    const strippedOfflineLabels = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(loginA.token))
      .send({
        id: randomUUID(),
        project_id: projectA.id,
        geom: { type: 'Point', coordinates: [35.5, 33.9] },
        attributes: { feature_type: 'olive', condition: 'good', status: 'approved' },
      });
    expectPermanent(strippedOfflineLabels, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

    await pool.query(`UPDATE project_assignment SET status = 'rejected' WHERE id = $1`, [
      assignmentA.id,
    ]);
    const revokedReplay = await request(app)
      .put(`${API_PREFIX}/features/${featureId}`)
      .set(updateHeaders)
      .send(updateBody);
    expectPermanent(revokedReplay, 'OFFLINE_SYNC_ACCESS_REVOKED');

    const state = await pool.query(
      `SELECT version, attributes->>'condition' AS condition,
              (SELECT COUNT(*)::int FROM offline_sync_receipt
               WHERE user_id = $2 AND project_id = $3) AS receipt_count
       FROM spatial_feature
       WHERE id = $1`,
      [featureId, contributorA.user.id, projectA.id],
    );
    expect(state.rows[0]).toEqual({ version: 2, condition: 'fair', receipt_count: 3 });
  });

  test('classifies missing legacy update and submit parents as permanent', async () => {
    const fixture = await createFixture();
    const missingId = randomUUID();
    const headers = offlineHeaders({
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
    });

    expectPermanent(
      await request(app)
        .post(`${API_PREFIX}/features`)
        .set(authHeader(fixture.loginA.token))
        .set('Idempotency-Key', randomUUID())
        .send({ project_id: 'not-a-uuid' }),
      'OFFLINE_SYNC_PAYLOAD_REJECTED',
      422,
    );
    expectPermanent(
      await request(app)
        .put(`${API_PREFIX}/features/${missingId}`)
        .set(headers)
        .send({ attributes: { feature_type: 'olive' }, expected_version: 1 }),
      'OFFLINE_SYNC_PARENT_INACCESSIBLE',
    );
    expectPermanent(
      await request(app)
        .post(`${API_PREFIX}/features/${missingId}/submit`)
        .set(authHeader(fixture.loginA.token))
        .set('Idempotency-Key', randomUUID()),
      'OFFLINE_SYNC_PARENT_INACCESSIBLE',
    );
  });

  test('serializes concurrent replays and rejects reuse of a key with a different payload', async () => {
    const fixture = await createFixture();
    const { contributorA, loginA, projectA } = fixture;
    const id = randomUUID();
    const key = randomUUID();
    const payload = offlinePayload({ ownerId: contributorA.user.id, projectId: projectA.id, id });
    const headers = offlineHeaders({
      token: loginA.token,
      ownerId: contributorA.user.id,
      projectId: projectA.id,
      key,
    });

    const [first, second] = await Promise.all([
      request(app).post(`${API_PREFIX}/features`).set(headers).send(payload),
      request(app).post(`${API_PREFIX}/features`).set(headers).send(payload),
    ]);
    expect([first.status, second.status].sort()).toEqual([200, 201]);
    expect([first.body.data.outcome, second.body.data.outcome].sort()).toEqual([
      'accepted',
      'already_synchronized',
    ]);

    const changedPayload = {
      ...payload,
      attributes: { feature_type: 'olive', condition: 'fair' },
    };
    const mismatch = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(headers)
      .send(changedPayload);
    expectPermanent(mismatch, 'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH', 409);

    const submitHeaders = offlineHeaders({
      token: loginA.token,
      ownerId: contributorA.user.id,
      projectId: projectA.id,
      key,
    });
    const [submitA, submitB] = await Promise.all([
      request(app).post(`${API_PREFIX}/features/${id}/submit`).set(submitHeaders),
      request(app).post(`${API_PREFIX}/features/${id}/submit`).set(submitHeaders),
    ]);
    expect(submitA.status).toBe(200);
    expect(submitB.status).toBe(200);
    expect([submitA.body.data.outcome, submitB.body.data.outcome].sort()).toEqual([
      'accepted',
      'already_synchronized',
    ]);

    const rows = await pool.query(
      `SELECT
         (SELECT COUNT(*)::int FROM spatial_feature WHERE id = $1) AS feature_count,
         (SELECT COUNT(*)::int FROM notification WHERE metadata->>'feature_id' = $1::text) AS notification_count,
         (SELECT COUNT(DISTINCT user_id)::int
            FROM notification
           WHERE metadata->>'feature_id' = $1::text) AS notified_admin_count,
         (SELECT COUNT(*)::int
            FROM offline_sync_receipt
           WHERE user_id = $2 AND project_id = $3) AS receipt_count`,
      [id, contributorA.user.id, projectA.id],
    );
    expect(rows.rows[0].feature_count).toBe(1);
    expect(rows.rows[0].notification_count).toBeGreaterThan(0);
    expect(rows.rows[0].notification_count).toBe(rows.rows[0].notified_admin_count);
    expect(rows.rows[0].receipt_count).toBe(2);

    const submitTamper = await request(app)
      .post(`${API_PREFIX}/features/${id}/submit`)
      .set(submitHeaders)
      .send({ status: 'approved', reviewed_by_user_id: fixture.admin.user.id });
    expectPermanent(submitTamper, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
  });
});
