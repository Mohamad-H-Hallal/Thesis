const { randomUUID } = require('node:crypto');
const fs = require('node:fs').promises;
const path = require('node:path');
const sharp = require('sharp');

const {
  API_PREFIX,
  app,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  createAdminUser,
  registerUser,
  loginUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
} = require('./helpers/api-test-helpers');
const { privateFeaturePhotosDir, privateFeatureThumbnailsDir } = require('../src/config/upload');
const {
  makeFeatureMediaCleanupJobsAvailable,
  processFeatureMediaCleanupJobs,
} = require('../src/services/featureMediaCleanup.service');
const logger = require('../src/utils/logger');

jest.setTimeout(90000);

const cleanPrivatePhotoStorage = async () => {
  for (const directory of [privateFeaturePhotosDir, privateFeatureThumbnailsDir]) {
    const entries = await fs.readdir(directory, { withFileTypes: true });
    await Promise.all(
      entries
        .filter((entry) => entry.isFile())
        .map((entry) => fs.unlink(path.join(directory, entry.name))),
    );
  }
};

const listPrivatePhotoStorage = async () => {
  const files = [];
  for (const directory of [privateFeaturePhotosDir, privateFeatureThumbnailsDir]) {
    for (const name of await fs.readdir(directory)) {
      files.push(path.join(directory, name));
    }
  }
  return files.sort();
};

const createImage = async () =>
  sharp({
    create: {
      width: 32,
      height: 24,
      channels: 4,
      background: { r: 16, g: 120, b: 210, alpha: 0.7 },
    },
  })
    .png()
    .toBuffer();

const createFixture = async () => {
  const admin = await createAdminUser({
    emailPrefix: `bundle-admin-${randomUUID().slice(0, 8)}`,
  });
  const contributorA = await registerUser({
    emailPrefix: `bundle-a-${randomUUID().slice(0, 8)}`,
  });
  const contributorB = await registerUser({
    emailPrefix: `bundle-b-${randomUUID().slice(0, 8)}`,
  });
  await approveContributorRequest({ token: admin.token, userId: contributorA.user.id });
  await approveContributorRequest({ token: admin.token, userId: contributorB.user.id });

  const category = await createCategory({
    token: admin.token,
    name: `Offline bundle ${randomUUID()}`,
  });
  const projectA = await createProject({
    token: admin.token,
    categoryId: category.id,
    name: `Offline bundle A ${randomUUID()}`,
  });
  const projectB = await createProject({
    token: admin.token,
    categoryId: category.id,
    name: `Offline bundle B ${randomUUID()}`,
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

const bundlePayload = ({ ownerId, projectId, draftId = randomUUID(), ...overrides }) => ({
  draft_id: draftId,
  offline_owner_user_id: ownerId,
  project_id: projectId,
  operation: 'create',
  geom: { type: 'Point', coordinates: [35.5, 33.9] },
  attributes: { feature_type: 'olive', condition: 'good' },
  accuracy_meters: 5,
  submit_for_review: true,
  expected_version: overrides.operation === 'update' ? 1 : null,
  ...overrides,
});

const sendBundle = ({ token, ownerId, projectId, key = randomUUID(), payload, photos = [] }) => {
  let operation = request(app)
    .post(`${API_PREFIX}/features/offline-sync`)
    .set(authHeader(token))
    .set('X-Offline-Owner-Id', ownerId)
    .set('X-Offline-Project-Id', projectId)
    .set('Idempotency-Key', key)
    .field('payload', JSON.stringify(payload));

  for (const photo of photos) {
    operation = operation.attach('photos', photo.bytes, {
      filename: photo.filename,
      contentType: photo.contentType,
    });
  }
  return operation;
};

const expectPermanent = (response, code, status = 403) => {
  expect(response.status).toBe(status);
  expect(response.body.error).toEqual({
    code,
    disposition: 'permanent_rejection',
    retryable: false,
  });
};

const applicationCounts = async (draftId) => {
  const [features, photos, receipts, notifications] = await Promise.all([
    pool.query('SELECT COUNT(*)::int AS count FROM spatial_feature WHERE id = $1', [draftId]),
    pool.query('SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1', [draftId]),
    pool.query(
      `SELECT COUNT(*)::int AS count
       FROM offline_sync_receipt
       WHERE $1::uuid = ANY(entity_ids)`,
      [draftId],
    ),
    pool.query(
      `SELECT COUNT(*)::int AS count
       FROM notification
       WHERE metadata->>'feature_id' = $1`,
      [draftId],
    ),
  ]);
  return {
    features: features.rows[0].count,
    photos: photos.rows[0].count,
    receipts: receipts.rows[0].count,
    notifications: notifications.rows[0].count,
  };
};

const expectNoApplicationData = async (draftId) => {
  expect(await applicationCounts(draftId)).toEqual({
    features: 0,
    photos: 0,
    receipts: 0,
    notifications: 0,
  });
};

const expectNoAuditData = async (draftId) => {
  const result = await pool.query(
    `SELECT COUNT(*)::int AS count
     FROM audit_log
     WHERE entity_id = $1`,
    [draftId],
  );
  expect(result.rows[0].count).toBe(0);
};

describe('POST /features/offline-sync atomic security contract', () => {
  beforeEach(async () => {
    await resetDb();
    await cleanPrivatePhotoStorage();
  });

  afterEach(async () => {
    jest.restoreAllMocks();
    await pool.query('DROP TRIGGER IF EXISTS test_reject_offline_bundle_photo ON photo');
    await pool.query('DROP FUNCTION IF EXISTS test_reject_offline_bundle_photo()');
    await cleanPrivatePhotoStorage();
  });

  afterAll(async () => {
    await shutdown();
  });

  test('atomically creates, attaches, submits, and exactly replays without duplicates', async () => {
    const fixture = await createFixture();
    const image = await createImage();
    const key = randomUUID();
    const payload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
    });
    const requestOptions = {
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      key,
      payload,
      photos: [{ bytes: image, filename: 'field-photo.png', contentType: 'image/png' }],
    };

    const accepted = await sendBundle(requestOptions);
    expect(accepted.status).toBe(201);
    expect(accepted.body.data).toMatchObject({
      id: payload.draft_id,
      status: 'pending_review',
      outcome: 'accepted',
    });

    const firstCounts = await applicationCounts(payload.draft_id);
    expect(firstCounts).toMatchObject({ features: 1, photos: 1, receipts: 1 });
    expect(firstCounts.notifications).toBeGreaterThan(0);
    const storedPhoto = await pool.query(
      `SELECT file_path, thumbnail_path
       FROM photo
       WHERE feature_id = $1`,
      [payload.draft_id],
    );
    expect(storedPhoto.rows).toHaveLength(1);
    await expect(fs.access(storedPhoto.rows[0].file_path)).resolves.toBeUndefined();
    await expect(fs.access(storedPhoto.rows[0].thumbnail_path)).resolves.toBeUndefined();

    const originalPolicy = await pool.query(
      `SELECT collection_form_schema, max_photos
       FROM project WHERE id = $1`,
      [fixture.projectA.id],
    );
    await pool.query(
      `UPDATE project
       SET collection_form_schema = $1::jsonb, max_photos = 0
       WHERE id = $2`,
      [
        JSON.stringify({
          fields: [{ key: 'replacement_required', type: 'text', required: true }],
        }),
        fixture.projectA.id,
      ],
    );
    const replay = await sendBundle(requestOptions);
    expect(replay.status).toBe(200);
    expect(replay.body.data).toMatchObject({
      id: payload.draft_id,
      status: 'pending_review',
      outcome: 'already_synchronized',
    });
    expect(await applicationCounts(payload.draft_id)).toEqual(firstCounts);
    await pool.query(
      `UPDATE project
       SET collection_form_schema = $1::jsonb, max_photos = $2
       WHERE id = $3`,
      [
        JSON.stringify(originalPolicy.rows[0].collection_form_schema),
        originalPolicy.rows[0].max_photos,
        fixture.projectA.id,
      ],
    );
    const replayWithDifferentKey = await sendBundle({
      ...requestOptions,
      key: randomUUID(),
    });
    expectPermanent(replayWithDifferentKey, 'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH', 409);
    expect(await applicationCounts(payload.draft_id)).toEqual(firstCounts);
    const receipt = await pool.query(
      `SELECT outcome
       FROM offline_sync_receipt
       WHERE user_id = $1 AND project_id = $2 AND operation = 'offline_bundle'`,
      [fixture.contributorA.user.id, fixture.projectA.id],
    );
    expect(receipt.rows).toEqual([{ outcome: 'already_synchronized' }]);
  });

  test('rebased offline updates can atomically add only their new photos', async () => {
    const fixture = await createFixture();
    const draftId = randomUUID();
    const createPayload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      draftId,
      submit_for_review: false,
    });
    const created = await sendBundle({
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      payload: createPayload,
    });
    expect(created.status).toBe(201);
    expect(created.body.data).toMatchObject({ id: draftId, status: 'draft', version: 1 });

    const image = await createImage();
    const updateKey = randomUUID();
    const updatePayload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      draftId,
      operation: 'update',
      attributes: { feature_type: 'olive', condition: 'fair' },
      submit_for_review: false,
    });
    const updateRequest = {
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      key: updateKey,
      payload: updatePayload,
      photos: [{ bytes: image, filename: 'new-offline-photo.png', contentType: 'image/png' }],
    };

    const updated = await sendBundle(updateRequest);
    expect(updated.status).toBe(201);
    expect(updated.body.data).toMatchObject({ id: draftId, status: 'draft', version: 2 });
    expect(await applicationCounts(draftId)).toMatchObject({
      features: 1,
      photos: 1,
      receipts: 2,
      notifications: 0,
    });

    const replay = await sendBundle(updateRequest);
    expect(replay.status).toBe(200);
    expect(replay.body.data).toMatchObject({
      id: draftId,
      status: 'draft',
      version: 2,
      outcome: 'already_synchronized',
    });
    expect(await applicationCounts(draftId)).toMatchObject({
      features: 1,
      photos: 1,
      receipts: 2,
      notifications: 0,
    });

    const staleUpdate = await sendBundle({
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      payload: {
        ...updatePayload,
        attributes: { feature_type: 'olive', condition: 'healthy' },
      },
    });
    expect(staleUpdate.status).toBe(409);
    expect(staleUpdate.body.error).toEqual({
      code: 'OFFLINE_SYNC_VERSION_CONFLICT',
      disposition: 'conflict',
      retryable: false,
      current_version: 2,
    });
    const unchanged = await pool.query(
      `SELECT version, attributes->>'condition' AS condition
       FROM spatial_feature WHERE id = $1`,
      [draftId],
    );
    expect(unchanged.rows).toEqual([{ version: 2, condition: 'fair' }]);
  });

  test('revalidates revoked assignment, inactive account, assignment role, and project state', async () => {
    const fixture = await createFixture();
    const attempt = async () => {
      const payload = bundlePayload({
        ownerId: fixture.contributorA.user.id,
        projectId: fixture.projectA.id,
      });
      const response = await sendBundle({
        token: fixture.loginA.token,
        ownerId: fixture.contributorA.user.id,
        projectId: fixture.projectA.id,
        payload,
      });
      return { payload, response };
    };

    await pool.query(`UPDATE project_assignment SET status = 'rejected' WHERE id = $1`, [
      fixture.assignmentA.id,
    ]);
    let result = await attempt();
    expectPermanent(result.response, 'OFFLINE_SYNC_ACCESS_REVOKED');
    await expectNoApplicationData(result.payload.draft_id);
    await pool.query(`UPDATE project_assignment SET status = 'approved' WHERE id = $1`, [
      fixture.assignmentA.id,
    ]);

    await pool.query(`UPDATE "user" SET is_active = FALSE WHERE id = $1`, [
      fixture.contributorA.user.id,
    ]);
    result = await attempt();
    expectPermanent(result.response, 'OFFLINE_SYNC_ACCOUNT_INACTIVE');
    await expectNoApplicationData(result.payload.draft_id);
    const inactiveRefresh = await request(app)
      .post(`${API_PREFIX}/auth/refresh-token`)
      .send({ refresh_token: fixture.loginA.refreshToken });
    expectPermanent(inactiveRefresh, 'OFFLINE_SYNC_ACCOUNT_INACTIVE');
    await pool.query(`UPDATE "user" SET is_active = TRUE WHERE id = $1`, [
      fixture.contributorA.user.id,
    ]);

    await pool.query(`UPDATE project_assignment SET role = 'admin' WHERE id = $1`, [
      fixture.assignmentA.id,
    ]);
    result = await attempt();
    expectPermanent(result.response, 'OFFLINE_SYNC_ROLE_FORBIDDEN');
    await expectNoApplicationData(result.payload.draft_id);
    await pool.query(`UPDATE project_assignment SET role = 'contributor' WHERE id = $1`, [
      fixture.assignmentA.id,
    ]);

    await pool.query(`UPDATE project SET status = 'paused' WHERE id = $1`, [fixture.projectA.id]);
    result = await attempt();
    expectPermanent(result.response, 'OFFLINE_SYNC_PROJECT_UNAVAILABLE');
    await expectNoApplicationData(result.payload.draft_id);
  });

  test('rejects another account, body/header project tampering, and a cross-project draft ID', async () => {
    const fixture = await createFixture();

    const otherAccountPayload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
    });
    const otherAccount = await sendBundle({
      token: fixture.loginB.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      payload: otherAccountPayload,
    });
    expectPermanent(otherAccount, 'OFFLINE_SYNC_OWNER_MISMATCH');
    await expectNoApplicationData(otherAccountPayload.draft_id);

    const projectTamperPayload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectB.id,
    });
    const projectTamper = await sendBundle({
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      payload: projectTamperPayload,
    });
    expectPermanent(projectTamper, 'OFFLINE_SYNC_PROJECT_MISMATCH');
    await expectNoApplicationData(projectTamperPayload.draft_id);

    const crossProjectDraftId = randomUUID();
    await pool.query(
      `INSERT INTO spatial_feature (
         id, project_id, collected_by_user_id, geom, attributes, collected_offline, status
       ) VALUES (
         $1, $2, $3, ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326),
         $4::jsonb, TRUE, 'draft'
       )`,
      [
        crossProjectDraftId,
        fixture.projectB.id,
        fixture.contributorB.user.id,
        JSON.stringify({ feature_type: 'olive', condition: 'good' }),
      ],
    );
    const crossProjectPayload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      draftId: crossProjectDraftId,
      operation: 'update',
      submit_for_review: false,
    });
    const crossProject = await sendBundle({
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      payload: crossProjectPayload,
    });
    expectPermanent(crossProject, 'OFFLINE_SYNC_PROJECT_MISMATCH');
    expect(await applicationCounts(crossProjectDraftId)).toEqual({
      features: 1,
      photos: 0,
      receipts: 0,
      notifications: 0,
    });
  });

  test('rejects server-managed fields, unsafe text, deep data, oversize data, and invalid geometry', async () => {
    const fixture = await createFixture();
    const maliciousMarker = `OFFLINE_REJECTED_SECRET_${randomUUID()}`;
    const loggerSpies = ['error', 'warn', 'info'].map((level) =>
      jest.spyOn(logger, level).mockImplementation(() => undefined),
    );
    let deeplyNested = 'leaf';
    for (let depth = 0; depth < 1000; depth += 1) {
      deeplyNested = { nested: deeplyNested };
    }
    const pathologicalCoordinates = Array.from({ length: 10001 }, () => [35.5, 33.9]);
    const cases = [
      {
        name: 'server-managed fields',
        overrides: {
          status: 'approved',
          reviewer_id: fixture.admin.user.id,
          created_at: new Date().toISOString(),
          photo_id: randomUUID(),
        },
      },
      {
        name: 'script markup',
        overrides: {
          attributes: {
            feature_type: 'olive',
            condition: `<script>${maliciousMarker}</script>`,
          },
        },
      },
      {
        name: 'excessive nesting',
        overrides: {
          attributes: { feature_type: 'olive', nested: deeplyNested },
        },
      },
      {
        name: 'invalid longitude',
        overrides: { geom: { type: 'Point', coordinates: [181, 33.9] } },
      },
      {
        name: 'numeric coordinate strings',
        overrides: { geom: { type: 'Point', coordinates: ['35.5', '33.9'] } },
      },
      {
        name: 'non-string CRS name',
        overrides: {
          geom: {
            type: 'Point',
            coordinates: [35.5, 33.9],
            crs: { type: 'name', properties: { name: 4326 } },
          },
        },
      },
      {
        name: 'pathological vertex collection',
        overrides: { geom: { type: 'LineString', coordinates: pathologicalCoordinates } },
      },
    ];

    for (const testCase of cases) {
      const payload = bundlePayload({
        ownerId: fixture.contributorA.user.id,
        projectId: fixture.projectA.id,
        ...testCase.overrides,
      });
      const response = await sendBundle({
        token: fixture.loginA.token,
        ownerId: fixture.contributorA.user.id,
        projectId: fixture.projectA.id,
        payload,
      });
      expectPermanent(response, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
      await expectNoApplicationData(payload.draft_id);
      await expectNoAuditData(payload.draft_id);
    }

    const oversizedPayload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      attributes: { feature_type: 'olive', oversized: 'a'.repeat(256 * 1024) },
    });
    const oversized = await sendBundle({
      token: fixture.loginA.token,
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
      payload: oversizedPayload,
    });
    expectPermanent(oversized, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);
    await expectNoApplicationData(oversizedPayload.draft_id);
    await expectNoAuditData(oversizedPayload.draft_id);

    const capturedLogs = JSON.stringify(loggerSpies.flatMap((spy) => spy.mock.calls));
    loggerSpies.forEach((spy) => spy.mockRestore());
    expect(capturedLogs).not.toContain(maliciousMarker);
  });

  test('rejects invalid image signatures and unsafe filenames without leaving bundle data', async () => {
    const fixture = await createFixture();
    const validImage = await createImage();
    const cases = [
      {
        payload: bundlePayload({
          ownerId: fixture.contributorA.user.id,
          projectId: fixture.projectA.id,
        }),
        photo: {
          bytes: Buffer.from('<script>alert(1)</script>'),
          filename: 'field-photo.jpg',
          contentType: 'image/jpeg',
        },
      },
      {
        payload: bundlePayload({
          ownerId: fixture.contributorA.user.id,
          projectId: fixture.projectA.id,
        }),
        photo: {
          bytes: validImage,
          filename: 'field-photo.html.png',
          contentType: 'image/png',
        },
      },
    ];

    for (const testCase of cases) {
      const beforeFiles = await listPrivatePhotoStorage();
      const response = await sendBundle({
        token: fixture.loginA.token,
        ownerId: fixture.contributorA.user.id,
        projectId: fixture.projectA.id,
        payload: testCase.payload,
        photos: [testCase.photo],
      });
      expectPermanent(response, 'OFFLINE_SYNC_ATTACHMENT_REJECTED', 422);
      await expectNoApplicationData(testCase.payload.draft_id);
      expect(await listPrivatePhotoStorage()).toEqual(beforeFiles);
    }
  });

  test('rolls back all rows and removes files when the photo insert fails after file writes', async () => {
    const fixture = await createFixture();
    const payload = bundlePayload({
      ownerId: fixture.contributorA.user.id,
      projectId: fixture.projectA.id,
    });
    const image = await createImage();
    const beforeFiles = await listPrivatePhotoStorage();
    await pool.query(`
      CREATE OR REPLACE FUNCTION test_reject_offline_bundle_photo()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'injected offline bundle photo insert failure';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER test_reject_offline_bundle_photo
      BEFORE INSERT ON photo
      FOR EACH ROW EXECUTE FUNCTION test_reject_offline_bundle_photo();
    `);

    const unlinkSpy = jest
      .spyOn(fs, 'unlink')
      .mockRejectedValue(
        Object.assign(new Error('simulated sharing violation'), { code: 'EBUSY' }),
      );
    let response;
    try {
      response = await sendBundle({
        token: fixture.loginA.token,
        ownerId: fixture.contributorA.user.id,
        projectId: fixture.projectA.id,
        payload,
        photos: [{ bytes: image, filename: 'field-photo.png', contentType: 'image/png' }],
      });
    } finally {
      unlinkSpy.mockRestore();
    }

    expect(response.status).toBe(500);
    expect(response.body.error).toEqual({
      code: 'OFFLINE_SYNC_TEMPORARY_FAILURE',
      disposition: 'retry',
      retryable: true,
    });
    await expectNoApplicationData(payload.draft_id);
    const deferredJobs = await pool.query(
      `SELECT id, storage_path, attempt_count, last_error_code
       FROM feature_media_cleanup_job
       WHERE reason = 'upload_rollback'
       ORDER BY storage_path`,
    );
    expect(deferredJobs.rows).toHaveLength(2);
    expect(deferredJobs.rows.every((row) => row.attempt_count === 1)).toBe(true);
    expect(deferredJobs.rows.every((row) => row.last_error_code === 'EBUSY')).toBe(true);
    expect(await listPrivatePhotoStorage()).toHaveLength(beforeFiles.length + 2);

    const jobIds = deferredJobs.rows.map((row) => row.id);
    await makeFeatureMediaCleanupJobsAvailable({ jobIds });
    expect(await processFeatureMediaCleanupJobs({ jobIds })).toEqual({
      completed: 2,
      deferred: 0,
    });
    expect(await listPrivatePhotoStorage()).toEqual(beforeFiles);
    const cleanupJobs = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM feature_media_cleanup_job
       WHERE id = ANY($1::uuid[])`,
      [jobIds],
    );
    expect(cleanupJobs.rows[0].count).toBe(0);
  });
});
