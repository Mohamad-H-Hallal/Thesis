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
const {
  privateAiValidationPhotosDir,
  categoryIconsDir,
  importsDir,
  photosDir,
  privateFeaturePhotosDir,
  privateFeatureThumbnailsDir,
} = require('../src/config/upload');
const { photoResponse } = require('../src/services/featurePhotoSecurity.service');
const {
  makeFeatureMediaCleanupJobsAvailable,
  processFeatureMediaCleanupJobs,
} = require('../src/services/featureMediaCleanup.service');
const { storageAdapter } = require('../src/services/storageAdapter.service');
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
  const entries = [];
  for (const directory of [privateFeaturePhotosDir, privateFeatureThumbnailsDir]) {
    for (const name of await fs.readdir(directory)) {
      entries.push(path.join(directory, name));
    }
  }
  return entries.sort();
};

const localStoragePath = (reference) => {
  const resolved = storageAdapter.resolve(reference, ['uploads']);
  if (!resolved) throw new Error(`Invalid test storage reference: ${reference}`);
  return resolved.localPath;
};

const createImage = async ({ width = 32, height = 24, format = 'png' } = {}) => {
  const pipeline = sharp({
    create: {
      width,
      height,
      channels: 4,
      background: { r: 16, g: 120, b: 210, alpha: 0.7 },
    },
  });
  return format === 'jpeg' ? pipeline.jpeg().toBuffer() : pipeline.png().toBuffer();
};

const insertMutableAiLegacyReference = async ({ projectId, userId, legacyUrl }) => {
  const run = await pool.query(
    `INSERT INTO ai_run (project_id, label_field, started_by)
     VALUES ($1, 'feature_type', $2)
     RETURNING id`,
    [projectId, userId],
  );
  const layer = await pool.query(
    `INSERT INTO ai_output_layer (ai_run_id, project_id, layer_type, name)
     VALUES ($1, $2, 'classification', 'Legacy media guard test')
     RETURNING id`,
    [run.rows[0].id, projectId],
  );
  const prediction = await pool.query(
    `INSERT INTO ai_prediction_feature (
       project_id, ai_run_id, ai_output_layer_id, artifact_feature_id,
       geom, geometry_type
     ) VALUES (
       $1, $2, $3, $4,
       ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326), 'Point'
     )
     RETURNING id`,
    [projectId, run.rows[0].id, layer.rows[0].id, randomUUID()],
  );
  await pool.query(
    `INSERT INTO ai_prediction_feature_validation (
       project_id, ai_run_id, ai_prediction_feature_id,
       contributor_user_id, validation_result, photo_media_ids
     ) VALUES ($1, $2, $3, $4, 'correct', $5::jsonb)`,
    [projectId, run.rows[0].id, prediction.rows[0].id, userId, JSON.stringify([legacyUrl])],
  );
};

const mutateLegacyAiSnapshotForFixture = async (callback) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `ALTER TABLE legacy_ai_validation_media_snapshot
       DISABLE TRIGGER trg_legacy_ai_validation_media_snapshot_immutable`,
    );
    const result = await callback(client);
    await client.query(
      `ALTER TABLE legacy_ai_validation_media_snapshot
       ENABLE TRIGGER trg_legacy_ai_validation_media_snapshot_immutable`,
    );
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
};

const provisionOfflineFeature = async () => {
  const admin = await createAdminUser({ emailPrefix: 'photo-security-admin' });
  const contributor = await registerUser({ emailPrefix: 'photo-security-contributor' });
  await approveContributorRequest({ token: admin.token, userId: contributor.user.id });
  const category = await createCategory({
    token: admin.token,
    name: `Photo security ${Date.now()}-${Math.random()}`,
  });
  const project = await createProject({
    token: admin.token,
    categoryId: category.id,
    name: `Photo security project ${Date.now()}-${Math.random()}`,
  });
  await request(app)
    .put(`${API_PREFIX}/projects/${project.id}`)
    .set(authHeader(admin.token))
    .send({ status: 'active' })
    .expect(200);
  await pool.query(
    `UPDATE project
     SET start_date = CURRENT_DATE - INTERVAL '1 day', end_date = NULL
     WHERE id = $1`,
    [project.id],
  );
  const assignment = await createAssignment({
    token: admin.token,
    projectId: project.id,
    userId: contributor.user.id,
  });
  await updateAssignmentStatus({
    token: admin.token,
    assignmentId: assignment.id,
    status: 'approved',
  });
  const contributorLogin = await loginUser({
    email: contributor.email,
    password: contributor.password,
  });
  const featureId = randomUUID();
  const createResponse = await request(app)
    .post(`${API_PREFIX}/features`)
    .set(authHeader(contributorLogin.token))
    .set('X-Offline-Owner-Id', contributor.user.id)
    .set('X-Offline-Project-Id', project.id)
    .set('Idempotency-Key', randomUUID())
    .send({
      id: featureId,
      client_offline_id: featureId,
      offline_owner_user_id: contributor.user.id,
      project_id: project.id,
      geom: { type: 'Point', coordinates: [35.5, 33.9] },
      attributes: { feature_type: 'olive' },
      collected_offline: true,
    });
  expect(createResponse.status).toBe(201);

  return {
    admin,
    contributor,
    contributorLogin,
    project,
    assignment,
    featureId,
  };
};

const securePhotoRequest = ({ token, userId, projectId, featureId, key = randomUUID() }) =>
  request(app)
    .post(`${API_PREFIX}/photos/feature/${featureId}`)
    .set(authHeader(token))
    .set('X-Offline-Owner-Id', userId)
    .set('X-Offline-Project-Id', projectId)
    .set('Idempotency-Key', key);

describe('offline feature photo synchronization security', () => {
  beforeEach(async () => {
    await resetDb();
    await cleanPrivatePhotoStorage();
  });

  afterEach(async () => {
    await pool.query('DROP TRIGGER IF EXISTS test_reject_photo_insert ON photo');
    await pool.query('DROP FUNCTION IF EXISTS test_reject_photo_insert()');
    await cleanPrivatePhotoStorage();
  });

  afterAll(async () => {
    await shutdown();
  });

  test('does not invent a thumbnail URL for legacy rows without a thumbnail', () => {
    const photoId = randomUUID();
    expect(
      photoResponse({
        id: photoId,
        file_path: 'legacy/photo.jpg',
        thumbnail_path: null,
      }),
    ).toMatchObject({
      id: photoId,
      file_path: `${API_PREFIX}/photos/${photoId}`,
      thumbnail_path: null,
    });
  });

  test('re-encodes accepted images privately and makes an exact retry idempotent', async () => {
    const context = await provisionOfflineFeature();
    const source = await createImage();
    const key = randomUUID();

    const first = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
      key,
    }).attach('photos', source, { filename: 'field-photo.png', contentType: 'image/png' });

    expect(first.status).toBe(201);
    expect(first.body.idempotent_replay).toBe(false);
    expect(first.body.data).toHaveLength(1);
    expect(first.body.data[0].file_path).toBe(`${API_PREFIX}/photos/${first.body.data[0].id}`);
    expect(JSON.stringify(first.body)).not.toContain('.private');

    const stored = await pool.query(
      'SELECT id, file_path, thumbnail_path, exif_data FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(stored.rows).toHaveLength(1);
    const storedLocation = storageAdapter.resolve(stored.rows[0].file_path, ['uploads']);
    expect(storedLocation).not.toBeNull();
    const normalizedMetadata = await sharp(storedLocation.localPath).metadata();
    expect(normalizedMetadata.format).toBe('jpeg');
    expect(normalizedMetadata.exif).toBeUndefined();
    expect(stored.rows[0].file_path).toMatch(
      /^storage:\/\/uploads\/\.private\/feature-photos\/\.[0-9a-f-]+\.jpg$/,
    );

    const staticAttempt = await request(app).get(
      `/uploads/${storedLocation.key}`,
    );
    expect(staticAttempt.status).toBe(404);

    const authenticatedRead = await request(app)
      .get(first.body.data[0].file_path)
      .set(authHeader(context.contributorLogin.token));
    expect(authenticatedRead.status).toBe(200);
    expect(authenticatedRead.headers['content-type']).toMatch(/^image\/jpeg/);
    expect(authenticatedRead.headers['cache-control']).toBe('private, no-store');
    expect(authenticatedRead.headers['x-content-type-options']).toBe('nosniff');
    expect(authenticatedRead.headers['content-disposition']).toMatch(/^inline;/);
    const photoList = await request(app)
      .get(`${API_PREFIX}/photos/feature/${context.featureId}`)
      .set(authHeader(context.contributorLogin.token));
    expect(photoList.status).toBe(200);
    expect(photoList.body.data[0].exif_data.source_sha256).toBeUndefined();

    const replay = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
      key,
    }).attach('photos', source, { filename: 'field-photo.png', contentType: 'image/png' });

    expect(replay.status).toBe(200);
    expect(replay.body.idempotent_replay).toBe(true);
    expect(replay.body.data).toHaveLength(1);
    expect(replay.body.data[0].id).toBe(first.body.data[0].id);
    const count = await pool.query(
      'SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(count.rows[0].count).toBe(1);
  });

  test('deduplicates identical offline photo content across regenerated idempotency keys', async () => {
    const context = await provisionOfflineFeature();
    const source = await createImage();

    const first = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    })
      .attach('photos', source, { filename: 'first.png', contentType: 'image/png' })
      .attach('photos', source, { filename: 'duplicate.png', contentType: 'image/png' });
    expect(first.status).toBe(201);
    expect(first.body.data).toHaveLength(1);

    const retriedWithNewKey = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'renamed.png', contentType: 'image/png' });
    expect(retriedWithNewKey.status).toBe(200);
    expect(retriedWithNewKey.body.idempotent_replay).toBe(true);
    expect(retriedWithNewKey.body.data).toHaveLength(1);
    expect(retriedWithNewKey.body.data[0].id).toBe(first.body.data[0].id);

    const changedMetadata = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    })
      .field('latitude', '33.9')
      .field('longitude', '35.5')
      .attach('photos', source, { filename: 'relocated.png', contentType: 'image/png' });
    expect(changedMetadata.status).toBe(409);
    expect(changedMetadata.body.error.code).toBe('OFFLINE_SYNC_IDEMPOTENCY_MISMATCH');

    const count = await pool.query(
      'SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(count.rows[0].count).toBe(1);
    expect(await listPrivatePhotoStorage()).toHaveLength(2);
  });

  test('preserves normal online uploads to an offline-origin draft', async () => {
    const context = await provisionOfflineFeature();
    const source = await createImage();
    const response = await request(app)
      .post(`${API_PREFIX}/photos/feature/${context.featureId}`)
      .set(authHeader(context.contributorLogin.token))
      .attach('photos', source, { filename: 'online-edit.png', contentType: 'image/png' });

    expect(response.status).toBe(201);
    expect(response.body.success).toBe(true);
    expect(response.body.data).toHaveLength(1);

    const exactRetry = await request(app)
      .post(`${API_PREFIX}/photos/feature/${context.featureId}`)
      .set(authHeader(context.contributorLogin.token))
      .attach('photos', source, { filename: 'online-edit.png', contentType: 'image/png' });
    expect(exactRetry.status).toBe(200);
    expect(exactRetry.body.idempotent_replay).toBe(true);
    expect(exactRetry.body.data).toHaveLength(1);

    const unsafeHeaderless = await request(app)
      .post(`${API_PREFIX}/photos/feature/${context.featureId}`)
      .set(authHeader(context.contributorLogin.token))
      .attach('photos', source, { filename: 'online-edit.html.png', contentType: 'image/png' });
    expect(unsafeHeaderless.status).toBe(422);
    expect(unsafeHeaderless.body.error).toEqual({
      code: 'OFFLINE_SYNC_ATTACHMENT_REJECTED',
      disposition: 'permanent_rejection',
      retryable: false,
    });

    const persisted = await pool.query(
      'SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(persisted.rows[0].count).toBe(1);
    expect(await listPrivatePhotoStorage()).toHaveLength(2);
  });

  test('headerless photo deletion and reordering revalidate current offline-origin access', async () => {
    const context = await provisionOfflineFeature();
    const uploaded = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', await createImage(), {
      filename: 'destructive-authorization.png',
      contentType: 'image/png',
    });
    expect(uploaded.status).toBe(201);
    const photoId = uploaded.body.data[0].id;
    const storedPaths = await listPrivatePhotoStorage();
    expect(storedPaths).toHaveLength(2);

    await pool.query(`UPDATE project_assignment SET status = 'rejected' WHERE id = $1`, [
      context.assignment.id,
    ]);
    const revokedOrder = await request(app)
      .put(`${API_PREFIX}/photos/${photoId}/order`)
      .set(authHeader(context.contributorLogin.token))
      .send({ display_order: 7 });
    const revokedDelete = await request(app)
      .delete(`${API_PREFIX}/photos/${photoId}`)
      .set(authHeader(context.contributorLogin.token));
    for (const response of [revokedOrder, revokedDelete]) {
      expect(response.status).toBe(403);
      expect(response.body.error).toMatchObject({
        code: 'OFFLINE_SYNC_ACCESS_REVOKED',
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }

    await pool.query(
      `UPDATE project_assignment SET status = 'approved', role = 'admin' WHERE id = $1`,
      [context.assignment.id],
    );
    const removedPermissionOrder = await request(app)
      .put(`${API_PREFIX}/photos/${photoId}/order`)
      .set(authHeader(context.contributorLogin.token))
      .send({ display_order: 8 });
    const removedPermissionDelete = await request(app)
      .delete(`${API_PREFIX}/photos/${photoId}`)
      .set(authHeader(context.contributorLogin.token));
    for (const response of [removedPermissionOrder, removedPermissionDelete]) {
      expect(response.status).toBe(403);
      expect(response.body.error).toMatchObject({
        code: 'OFFLINE_SYNC_ROLE_FORBIDDEN',
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }

    const retained = await pool.query(
      'SELECT display_order FROM photo WHERE id = $1 AND feature_id = $2',
      [photoId, context.featureId],
    );
    expect(retained.rows).toHaveLength(1);
    expect(retained.rows[0].display_order).not.toBe(7);
    expect(retained.rows[0].display_order).not.toBe(8);
    expect(await listPrivatePhotoStorage()).toEqual(storedPaths);
  });

  test('durably retries feature-photo deletion cleanup without logging raw paths', async () => {
    const context = await provisionOfflineFeature();
    const uploaded = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', await createImage(), {
      filename: 'durable-delete.png',
      contentType: 'image/png',
    });
    expect(uploaded.status).toBe(201);
    const photoId = uploaded.body.data[0].id;
    const stored = await pool.query('SELECT file_path, thumbnail_path FROM photo WHERE id = $1', [
      photoId,
    ]);
    const storedPaths = [stored.rows[0].file_path, stored.rows[0].thumbnail_path];
    const cleanupLog = jest.spyOn(logger, 'error').mockImplementation(() => undefined);
    const unlinkFailure = Object.assign(new Error('simulated sharing violation'), {
      code: 'EBUSY',
    });
    const unlinkSpy = jest.spyOn(storageAdapter, 'remove').mockRejectedValue(unlinkFailure);
    let deleted;
    try {
      deleted = await request(app)
        .delete(`${API_PREFIX}/photos/${photoId}`)
        .set(authHeader(context.contributorLogin.token));
    } finally {
      unlinkSpy.mockRestore();
    }
    expect(deleted.status).toBe(200);
    const pending = await pool.query(
      `SELECT reason, attempt_count, last_error_code
       FROM feature_media_cleanup_job
       WHERE storage_path = ANY($1::text[])
       ORDER BY storage_path`,
      [storedPaths],
    );
    expect(pending.rows).toEqual([
      { reason: 'photo_deleted', attempt_count: 1, last_error_code: 'EBUSY' },
      { reason: 'photo_deleted', attempt_count: 1, last_error_code: 'EBUSY' },
    ]);
    const serializedLogs = JSON.stringify(cleanupLog.mock.calls);
    for (const storedPath of storedPaths) expect(serializedLogs).not.toContain(storedPath);
    cleanupLog.mockRestore();

    await makeFeatureMediaCleanupJobsAvailable({ paths: storedPaths });
    const cleanup = await processFeatureMediaCleanupJobs({ paths: storedPaths });
    expect(cleanup).toEqual({ completed: 2, deferred: 0 });
    expect(await listPrivatePhotoStorage()).toEqual([]);
    const remaining = await pool.query(
      'SELECT COUNT(*)::int AS count FROM feature_media_cleanup_job WHERE storage_path = ANY($1::text[])',
      [storedPaths],
    );
    expect(remaining.rows[0].count).toBe(0);
  });

  test('cleanup never unlinks live or out-of-root feature media paths', async () => {
    const context = await provisionOfflineFeature();
    const uploaded = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', await createImage(), {
      filename: 'live-reference.png',
      contentType: 'image/png',
    });
    expect(uploaded.status).toBe(201);
    const stored = await pool.query('SELECT file_path FROM photo WHERE id = $1', [
      uploaded.body.data[0].id,
    ]);
    const livePath = stored.rows[0].file_path;
    const unsafePath = path.resolve(privateFeaturePhotosDir, '..', '..', 'outside.jpg');
    await pool.query(
      `INSERT INTO feature_media_cleanup_job (storage_path, reason, available_at)
       VALUES ($1, 'upload_rollback', NOW()), ($2, 'upload_rollback', NOW())`,
      [livePath, unsafePath],
    );

    const cleanupLog = jest.spyOn(logger, 'error').mockImplementation(() => undefined);
    const unlinkSpy = jest.spyOn(storageAdapter, 'remove');
    const result = await processFeatureMediaCleanupJobs({ paths: [livePath, unsafePath] });
    expect(result).toEqual({ completed: 2, deferred: 0 });
    expect(unlinkSpy).not.toHaveBeenCalled();
    expect(await fs.access(localStoragePath(livePath))).toBeUndefined();
    expect(JSON.stringify(cleanupLog.mock.calls)).not.toContain(unsafePath);
    unlinkSpy.mockRestore();
    cleanupLog.mockRestore();
  });

  test('feature cascades queue and remove every private photo file', async () => {
    const context = await provisionOfflineFeature();
    const secondImage = await sharp({
      create: {
        width: 20,
        height: 20,
        channels: 3,
        background: { r: 200, g: 40, b: 10 },
      },
    })
      .png()
      .toBuffer();
    const uploaded = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    })
      .attach('photos', await createImage(), {
        filename: 'cascade-one.png',
        contentType: 'image/png',
      })
      .attach('photos', secondImage, { filename: 'cascade-two.png', contentType: 'image/png' });
    expect(uploaded.status).toBe(201);
    expect(await listPrivatePhotoStorage()).toHaveLength(4);

    const deleted = await request(app)
      .delete(`${API_PREFIX}/features/${context.featureId}`)
      .set(authHeader(context.contributorLogin.token));
    expect(deleted.status).toBe(200);
    expect(await listPrivatePhotoStorage()).toEqual([]);
    const afterApiDelete = await pool.query(
      `SELECT
         (SELECT COUNT(*)::int FROM photo WHERE feature_id = $1) AS photos,
         (SELECT COUNT(*)::int FROM feature_media_cleanup_job) AS cleanup_jobs`,
      [context.featureId],
    );
    expect(afterApiDelete.rows[0]).toEqual({ photos: 0, cleanup_jobs: 0 });

    const directDeleteFeatureId = randomUUID();
    const created = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(context.contributorLogin.token))
      .set('X-Offline-Owner-Id', context.contributor.user.id)
      .set('X-Offline-Project-Id', context.project.id)
      .set('Idempotency-Key', randomUUID())
      .send({
        id: directDeleteFeatureId,
        client_offline_id: directDeleteFeatureId,
        offline_owner_user_id: context.contributor.user.id,
        project_id: context.project.id,
        geom: { type: 'Point', coordinates: [35.51, 33.91] },
        attributes: { feature_type: 'olive' },
        collected_offline: true,
      });
    expect(created.status).toBe(201);
    await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: directDeleteFeatureId,
    })
      .attach('photos', await createImage(), {
        filename: 'direct-cascade.png',
        contentType: 'image/png',
      })
      .expect(201);
    const directPathsResult = await pool.query(
      'SELECT file_path, thumbnail_path FROM photo WHERE feature_id = $1',
      [directDeleteFeatureId],
    );
    const directPaths = [
      directPathsResult.rows[0].file_path,
      directPathsResult.rows[0].thumbnail_path,
    ];
    await pool.query('DELETE FROM spatial_feature WHERE id = $1', [directDeleteFeatureId]);
    const queued = await pool.query(
      'SELECT COUNT(*)::int AS count FROM feature_media_cleanup_job WHERE storage_path = ANY($1::text[])',
      [directPaths],
    );
    expect(queued.rows[0].count).toBe(2);
    await processFeatureMediaCleanupJobs({ paths: directPaths });
    expect(await listPrivatePhotoStorage()).toEqual([]);
  });

  test('keeps private draft media scoped to the currently authorized feature owner', async () => {
    const context = await provisionOfflineFeature();
    const uploaded = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', await createImage(), {
      filename: 'private-draft.png',
      contentType: 'image/png',
    });
    expect(uploaded.status).toBe(201);
    const photoUrl = uploaded.body.data[0].file_path;

    const other = await registerUser({ emailPrefix: 'photo-security-assigned-other' });
    await approveContributorRequest({ token: context.admin.token, userId: other.user.id });
    const otherAssignment = await createAssignment({
      token: context.admin.token,
      projectId: context.project.id,
      userId: other.user.id,
    });
    await updateAssignmentStatus({
      token: context.admin.token,
      assignmentId: otherAssignment.id,
      status: 'approved',
    });
    const otherLogin = await loginUser({ email: other.email, password: other.password });

    await request(app).get(photoUrl).set(authHeader(otherLogin.token)).expect(403);
    await pool.query('DELETE FROM project_assignment WHERE id = $1', [context.assignment.id]);
    await request(app)
      .get(`${API_PREFIX}/photos/feature/${context.featureId}`)
      .set(authHeader(context.contributorLogin.token))
      .expect(403);
    await request(app).get(photoUrl).set(authHeader(context.contributorLogin.token)).expect(403);
    await request(app).get(photoUrl).set(authHeader(context.admin.token)).expect(200);
  });

  test('does not expose an orphaned legacy feature file through the static media mount', async () => {
    const admin = await createAdminUser({ emailPrefix: 'photo-security-orphan-admin' });
    const orphanName = `${randomUUID()}.jpg`;
    const orphanPath = path.join(photosDir, orphanName);
    await fs.writeFile(orphanPath, await createImage({ format: 'jpeg' }));
    try {
      await request(app).get(`/uploads/photos/${orphanName}`).expect(401);
      await request(app)
        .get(`/uploads/photos/${orphanName}`)
        .set(authHeader(admin.token))
        .expect(404);
    } finally {
      await fs.unlink(orphanPath).catch(() => undefined);
    }
  });

  test('keeps the one-time legacy AI media snapshot immutable', async () => {
    const existingName = `${randomUUID()}.jpg`;
    const insertedName = `${randomUUID()}.jpg`;
    await mutateLegacyAiSnapshotForFixture((client) =>
      client.query('INSERT INTO legacy_ai_validation_media_snapshot (storage_name) VALUES ($1)', [
        existingName,
      ]),
    );

    try {
      for (const operation of [
        () =>
          pool.query('INSERT INTO legacy_ai_validation_media_snapshot (storage_name) VALUES ($1)', [
            insertedName,
          ]),
        () =>
          pool.query(
            'UPDATE legacy_ai_validation_media_snapshot SET storage_name = $1 WHERE storage_name = $2',
            [insertedName, existingName],
          ),
        () =>
          pool.query('DELETE FROM legacy_ai_validation_media_snapshot WHERE storage_name = $1', [
            existingName,
          ]),
        () => pool.query('TRUNCATE TABLE legacy_ai_validation_media_snapshot'),
      ]) {
        await expect(operation()).rejects.toMatchObject({ code: '55000' });
      }
    } finally {
      await mutateLegacyAiSnapshotForFixture((client) =>
        client.query('DELETE FROM legacy_ai_validation_media_snapshot WHERE storage_name = $1', [
          existingName,
        ]),
      );
    }
  });

  test('serves only authorized, migration-snapshotted legacy AI evidence', async () => {
    const context = await provisionOfflineFeature();
    const grandfatheredName = `${randomUUID()}.heic`;
    const injectedName = `${randomUUID()}.heif`;
    const grandfatheredPath = path.join(photosDir, grandfatheredName);
    const injectedPath = path.join(photosDir, injectedName);
    const image = await createImage({ format: 'jpeg' });
    await Promise.all([fs.writeFile(grandfatheredPath, image), fs.writeFile(injectedPath, image)]);

    try {
      // Simulate the one-time row populated by migration 0038 for evidence that
      // existed before the static compatibility mount was restricted.
      await mutateLegacyAiSnapshotForFixture((client) =>
        client.query(
          `INSERT INTO legacy_ai_validation_media_snapshot (storage_name)
           VALUES ($1)`,
          [grandfatheredName],
        ),
      );
      await insertMutableAiLegacyReference({
        projectId: context.project.id,
        userId: context.contributor.user.id,
        legacyUrl: `/uploads/photos/${grandfatheredName}`,
      });
      await insertMutableAiLegacyReference({
        projectId: context.project.id,
        userId: context.contributor.user.id,
        legacyUrl: `/uploads/photos/${injectedName}`,
      });

      await request(app).get(`/uploads/photos/${grandfatheredName}`).expect(401);
      await request(app)
        .get(`/uploads/photos/${grandfatheredName}`)
        .set(authHeader(context.contributorLogin.token))
        .expect(200)
        .expect('Cache-Control', 'private, no-store')
        .expect('X-Content-Type-Options', 'nosniff');
      await request(app)
        .get(`/uploads/photos/${injectedName}`)
        .set(authHeader(context.contributorLogin.token))
        .expect(404);
    } finally {
      await mutateLegacyAiSnapshotForFixture((client) =>
        client.query('DELETE FROM legacy_ai_validation_media_snapshot WHERE storage_name = $1', [
          grandfatheredName,
        ]),
      );
      await Promise.all([
        fs.unlink(grandfatheredPath).catch(() => undefined),
        fs.unlink(injectedPath).catch(() => undefined),
      ]);
    }
  });

  test('keeps current AI evidence private and preserves only the public category-icon mount', async () => {
    const context = await provisionOfflineFeature();
    const unrelated = await registerUser({
      emailPrefix: 'photo-security-unrelated-contributor',
    });
    await approveContributorRequest({
      token: context.admin.token,
      userId: unrelated.user.id,
    });
    const unrelatedLogin = await loginUser({
      email: unrelated.email,
      password: unrelated.password,
    });
    await pool.query(
      `UPDATE project
       SET visible_to_contributors = FALSE,
           visible_to_viewers = FALSE
       WHERE id = $1`,
      [context.project.id],
    );
    const evidenceName = `${randomUUID()}.jpg`;
    const iconName = `${randomUUID()}.png`;
    const importName = `${randomUUID()}.geojson`;
    const evidencePath = path.join(privateAiValidationPhotosDir, evidenceName);
    const iconPath = path.join(categoryIconsDir, iconName);
    const importPath = path.join(importsDir, importName);
    await Promise.all([
      fs.writeFile(evidencePath, await createImage({ format: 'jpeg' })),
      fs.writeFile(iconPath, await createImage()),
      fs.writeFile(importPath, '{"type":"FeatureCollection","features":[]}'),
    ]);
    await insertMutableAiLegacyReference({
      projectId: context.project.id,
      userId: context.contributor.user.id,
      legacyUrl: `/uploads/ai-validation/${evidenceName}`,
    });

    try {
      await request(app).get(`/uploads/ai-validation/${evidenceName}`).expect(401);
      await request(app)
        .get(`/uploads/ai-validation/${evidenceName}`)
        .set(authHeader(context.contributorLogin.token))
        .expect(200)
        .expect('Cache-Control', 'private, no-store')
        .expect('X-Content-Type-Options', 'nosniff');
      await request(app)
        .get(`/uploads/ai-validation/${evidenceName}`)
        .set(authHeader(unrelatedLogin.token))
        .expect(403);
      await request(app).get(`/uploads/category-icons/${iconName}`).expect(200);
      await request(app).get(`/uploads/imports/${importName}`).expect(404);
      await request(app).get(`/uploads/thumbnails/${iconName}`).expect(404);
    } finally {
      await Promise.all([
        fs.unlink(evidencePath).catch(() => undefined),
        fs.unlink(iconPath).catch(() => undefined),
        fs.unlink(importPath).catch(() => undefined),
      ]);
    }
  });

  test('scans, normalizes, and atomically releases public category icons', async () => {
    const context = await provisionOfflineFeature();
    const source = await createImage();
    const response = await request(app)
      .post(`${API_PREFIX}/categories/icon`)
      .set(authHeader(context.admin.token))
      .attach('icon', source, { filename: 'category.png', contentType: 'image/png' })
      .expect(201);

    const iconUrl = response.body.data.icon_url;
    expect(iconUrl).toMatch(/^\/uploads\/category-icons\/[0-9a-f-]+\.jpg$/);
    const filename = path.basename(iconUrl);
    const iconPath = path.join(categoryIconsDir, filename);
    try {
      const metadata = await sharp(iconPath).metadata();
      expect(metadata.format).toBe('jpeg');
      await request(app)
        .get(iconUrl)
        .expect(200)
        .expect('X-Content-Type-Options', 'nosniff');

      await request(app)
        .post(`${API_PREFIX}/categories/icon`)
        .set(authHeader(context.admin.token))
        .attach('icon', Buffer.from('<script>alert(1)</script>'), {
          filename: 'fake.png',
          contentType: 'image/png',
        })
        .expect(422);

      const quarantineRecords = await pool.query(
        `SELECT original_filename, storage_path, scan_status, disposition, reason_code
         FROM upload_quarantine_record
         WHERE uploaded_by_user_id = $1
           AND upload_kind = 'category_icon'
           AND original_filename = ANY($2::text[])
         ORDER BY original_filename`,
        [context.admin.user.id, ['category.png', 'fake.png']],
      );
      expect(
        quarantineRecords.rows.map(({ storage_path: _storagePath, ...record }) => record),
      ).toEqual([
        {
          original_filename: 'category.png',
          scan_status: 'skipped',
          disposition: 'released',
          reason_code: null,
        },
        {
          original_filename: 'fake.png',
          scan_status: 'skipped',
          disposition: 'quarantined',
          reason_code: 'UPLOAD_IMAGE_CONTENT_REJECTED',
        },
      ]);
      const rejectedPath = quarantineRecords.rows.find(
        (record) => record.original_filename === 'fake.png',
      )?.storage_path;
      if (rejectedPath) {
        await fs.unlink(rejectedPath).catch(() => undefined);
      }
    } finally {
      await fs.unlink(iconPath).catch(() => undefined);
    }
  });

  test('scopes attachment idempotency to the authenticated owner and project', async () => {
    const context = await provisionOfflineFeature();
    const category = await createCategory({
      token: context.admin.token,
      name: `Photo idempotency ${Date.now()}-${Math.random()}`,
    });
    const projectB = await createProject({
      token: context.admin.token,
      categoryId: category.id,
      name: `Photo idempotency B ${Date.now()}-${Math.random()}`,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${projectB.id}`)
      .set(authHeader(context.admin.token))
      .send({ status: 'active' })
      .expect(200);
    await pool.query(
      `UPDATE project
       SET start_date = CURRENT_DATE - INTERVAL '1 day', end_date = NULL
       WHERE id = $1`,
      [projectB.id],
    );
    const assignmentB = await createAssignment({
      token: context.admin.token,
      projectId: projectB.id,
      userId: context.contributor.user.id,
    });
    await updateAssignmentStatus({
      token: context.admin.token,
      assignmentId: assignmentB.id,
      status: 'approved',
    });
    const featureB = randomUUID();
    await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(context.contributorLogin.token))
      .set('X-Offline-Owner-Id', context.contributor.user.id)
      .set('X-Offline-Project-Id', projectB.id)
      .set('Idempotency-Key', randomUUID())
      .send({
        id: featureB,
        client_offline_id: featureB,
        offline_owner_user_id: context.contributor.user.id,
        project_id: projectB.id,
        geom: { type: 'Point', coordinates: [35.6, 33.8] },
        attributes: { feature_type: 'olive' },
        collected_offline: true,
      })
      .expect(201);

    const source = await createImage();
    const sharedKey = randomUUID();
    const projectAUpload = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
      key: sharedKey,
    }).attach('photos', source, { filename: 'project-a.png', contentType: 'image/png' });
    const projectBUpload = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: projectB.id,
      featureId: featureB,
      key: sharedKey,
    }).attach('photos', source, { filename: 'project-b.png', contentType: 'image/png' });

    expect(projectAUpload.status).toBe(201);
    expect(projectBUpload.status).toBe(201);
  });

  test.each([
    {
      name: 'invalid signature',
      bytes: Buffer.from('<script>alert(1)</script>'),
      filename: 'field-photo.jpg',
      contentType: 'image/jpeg',
    },
    {
      name: 'disguised signature',
      bytes: null,
      filename: 'field-photo.jpg',
      contentType: 'image/jpeg',
    },
    {
      name: 'double extension',
      bytes: null,
      filename: 'field-photo.html.png',
      contentType: 'image/png',
    },
  ])('rejects $name without persisting a record or file', async (fixture) => {
    const context = await provisionOfflineFeature();
    const validPng = await createImage();
    const beforeFiles = await listPrivatePhotoStorage();
    const response = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', fixture.bytes ?? validPng, {
      filename: fixture.filename,
      contentType: fixture.contentType,
    });

    expect(response.status).toBe(422);
    expect(response.body.error).toEqual({
      code: 'OFFLINE_SYNC_ATTACHMENT_REJECTED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
    const count = await pool.query(
      'SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(count.rows[0].count).toBe(0);
    expect(await listPrivatePhotoStorage()).toEqual(beforeFiles);
  });

  test('rejects oversized and pathological-dimension images', async () => {
    const context = await provisionOfflineFeature();
    const oversized = Buffer.alloc(5 * 1024 * 1024 + 1, 0x41);
    const oversizedResponse = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', oversized, { filename: 'huge.jpg', contentType: 'image/jpeg' });
    expect(oversizedResponse.status).toBe(422);
    expect(oversizedResponse.body.error.code).toBe('OFFLINE_SYNC_ATTACHMENT_REJECTED');

    const tooWide = await createImage({ width: 10001, height: 1 });
    const dimensionResponse = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', tooWide, { filename: 'wide.png', contentType: 'image/png' });
    expect(dimensionResponse.status).toBe(422);
    expect(dimensionResponse.body.error.code).toBe('OFFLINE_SYNC_ATTACHMENT_REJECTED');

    let tooManyRequest = securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    });
    for (let index = 0; index < 4; index += 1) {
      tooManyRequest = tooManyRequest.attach(
        'photos',
        await createImage({ width: 32 + index, height: 24 }),
        {
          filename: `count-${index}.png`,
          contentType: 'image/png',
        },
      );
    }
    const tooManyResponse = await tooManyRequest;
    expect(tooManyResponse.status).toBe(422);
    expect(tooManyResponse.body.error.code).toBe('OFFLINE_SYNC_ATTACHMENT_REJECTED');

    const unknownFieldResponse = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    })
      .field('status', 'approved')
      .attach('photos', await createImage(), {
        filename: 'unknown-field.png',
        contentType: 'image/png',
      });
    expect(unknownFieldResponse.status).toBe(422);
    expect(unknownFieldResponse.body.error.code).toBe('OFFLINE_SYNC_ATTACHMENT_REJECTED');
    expect(await listPrivatePhotoStorage()).toEqual([]);
  });

  test('revalidates assignment, owner, and asserted project before writing files', async () => {
    const context = await provisionOfflineFeature();
    const source = await createImage();
    await pool.query('DELETE FROM project_assignment WHERE id = $1', [context.assignment.id]);

    const revoked = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'revoked.png', contentType: 'image/png' });
    expect(revoked.status).toBe(403);
    expect(revoked.body.error.code).toBe('OFFLINE_SYNC_ACCESS_REVOKED');

    const omittedHeaders = await request(app)
      .post(`${API_PREFIX}/photos/feature/${context.featureId}`)
      .set(authHeader(context.contributorLogin.token))
      .attach('photos', source, { filename: 'omitted-binding.png', contentType: 'image/png' });
    expect(omittedHeaders.status).toBe(403);
    expect(omittedHeaders.body.error).toEqual({
      code: 'OFFLINE_SYNC_ACCESS_REVOKED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
    const rowsAfterRevocation = await pool.query(
      'SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(rowsAfterRevocation.rows[0].count).toBe(0);
    expect(await listPrivatePhotoStorage()).toEqual([]);

    const restoredAssignment = await createAssignment({
      token: context.admin.token,
      projectId: context.project.id,
      userId: context.contributor.user.id,
    });
    await updateAssignmentStatus({
      token: context.admin.token,
      assignmentId: restoredAssignment.id,
      status: 'approved',
    });
    await pool.query(
      `UPDATE project
       SET status = 'active',
           start_date = CURRENT_DATE - INTERVAL '2 days',
           end_date = CURRENT_DATE - INTERVAL '1 day'
       WHERE id = $1`,
      [context.project.id],
    );
    const expiredProject = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'expired.png', contentType: 'image/png' });
    expect(expiredProject.status).toBe(403);
    expect(expiredProject.body.error.code).toBe('OFFLINE_SYNC_PROJECT_UNAVAILABLE');

    await pool.query(
      `UPDATE project
       SET status = 'active', start_date = CURRENT_DATE - INTERVAL '1 day', end_date = NULL
       WHERE id = $1`,
      [context.project.id],
    );
    await pool.query(`UPDATE project_assignment SET role = 'admin' WHERE id = $1`, [
      restoredAssignment.id,
    ]);
    const wrongRole = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'wrong-role.png', contentType: 'image/png' });
    expect(wrongRole.status).toBe(403);
    expect(wrongRole.body.error.code).toBe('OFFLINE_SYNC_ROLE_FORBIDDEN');
    await pool.query(`UPDATE project_assignment SET role = 'contributor' WHERE id = $1`, [
      restoredAssignment.id,
    ]);

    const onlineFeature = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(context.contributorLogin.token))
      .send({
        project_id: context.project.id,
        geom: { type: 'Point', coordinates: [35.51, 33.91] },
        attributes: { feature_type: 'olive' },
      });
    expect(onlineFeature.status).toBe(201);
    const mismatchedParent = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: onlineFeature.body.data.id,
    }).attach('photos', source, { filename: 'offline-to-online.png', contentType: 'image/png' });
    expect(mismatchedParent.status).toBe(403);
    expect(mismatchedParent.body.error.code).toBe('OFFLINE_SYNC_PARENT_INACCESSIBLE');

    const differentUser = await registerUser({ emailPrefix: 'photo-security-other' });
    await approveContributorRequest({ token: context.admin.token, userId: differentUser.user.id });
    const differentLogin = await loginUser({
      email: differentUser.email,
      password: differentUser.password,
    });
    const wrongOwner = await securePhotoRequest({
      token: differentLogin.token,
      userId: differentUser.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'other.png', contentType: 'image/png' });
    expect(wrongOwner.status).toBe(403);
    expect(wrongOwner.body.error.code).toBe('OFFLINE_SYNC_OWNER_MISMATCH');

    const wrongProject = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: randomUUID(),
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'wrong-project.png', contentType: 'image/png' });
    expect(wrongProject.status).toBe(403);
    expect(wrongProject.body.error.code).toBe('OFFLINE_SYNC_PROJECT_MISMATCH');

    await pool.query(`UPDATE spatial_feature SET status = 'pending_review' WHERE id = $1`, [
      context.featureId,
    ]);
    const noLongerDraft = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'pending-review.png', contentType: 'image/png' });
    expect(noLongerDraft.status).toBe(403);
    expect(noLongerDraft.body.error.code).toBe('OFFLINE_SYNC_PARENT_INACCESSIBLE');

    expect(await listPrivatePhotoStorage()).toEqual([]);
  });

  test('rolls back database work and removes files when insertion fails', async () => {
    const context = await provisionOfflineFeature();
    const source = await createImage();
    await pool.query(`
      CREATE OR REPLACE FUNCTION test_reject_photo_insert()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'injected photo insert failure';
      END;
      $$ LANGUAGE plpgsql
    `);
    await pool.query(`
      CREATE TRIGGER test_reject_photo_insert
      BEFORE INSERT ON photo
      FOR EACH ROW EXECUTE FUNCTION test_reject_photo_insert()
    `);

    const response = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
    }).attach('photos', source, { filename: 'rollback.png', contentType: 'image/png' });

    expect(response.status).toBe(500);
    expect(response.body.error).toEqual({
      code: 'OFFLINE_SYNC_TEMPORARY_FAILURE',
      disposition: 'retry',
      retryable: true,
    });
    const count = await pool.query(
      'SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(count.rows[0].count).toBe(0);
    expect(await listPrivatePhotoStorage()).toEqual([]);
    const cleanupJobs = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM feature_media_cleanup_job
       WHERE reason = 'upload_rollback'`,
    );
    expect(cleanupJobs.rows[0].count).toBe(0);
  });

  test('rejects a reused idempotency key with changed attachment content', async () => {
    const context = await provisionOfflineFeature();
    const firstImage = await createImage();
    const secondImage = await sharp({
      create: {
        width: 32,
        height: 24,
        channels: 3,
        background: { r: 220, g: 30, b: 40 },
      },
    })
      .png()
      .toBuffer();
    const key = randomUUID();

    await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
      key,
    })
      .attach('photos', firstImage, { filename: 'first.png', contentType: 'image/png' })
      .expect(201);

    const mismatch = await securePhotoRequest({
      token: context.contributorLogin.token,
      userId: context.contributor.user.id,
      projectId: context.project.id,
      featureId: context.featureId,
      key,
    }).attach('photos', secondImage, { filename: 'second.png', contentType: 'image/png' });

    expect(mismatch.status).toBe(409);
    expect(mismatch.body.error.code).toBe('OFFLINE_SYNC_IDEMPOTENCY_MISMATCH');
    const count = await pool.query(
      'SELECT COUNT(*)::int AS count FROM photo WHERE feature_id = $1',
      [context.featureId],
    );
    expect(count.rows[0].count).toBe(1);
  });
});
