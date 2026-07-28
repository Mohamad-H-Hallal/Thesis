const {
  app,
  API_PREFIX,
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
} = require('./helpers/api-test-helpers');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const sharp = require('sharp');
const { storageAdapter } = require('../src/services/storageAdapter.service');

const SUPER_ADMIN_EMAIL = 'ai-superadmin@gov.lb';
const ORIGINAL_AI_PIPELINE_ROOT = process.env.AI_PIPELINE_ROOT;
const ORIGINAL_AI_PIPELINE_OUTPUT_ROOT = process.env.AI_PIPELINE_OUTPUT_ROOT;
const ORIGINAL_AI_SERVER_URL = process.env.AI_SERVER_URL;
const ORIGINAL_APP_PUBLIC_API_URL = process.env.APP_PUBLIC_API_URL;
const ORIGINAL_AI_CALLBACK_BASE_URL = process.env.AI_CALLBACK_BASE_URL;
const ORIGINAL_AI_CALLBACK_SECRET = process.env.AI_CALLBACK_SECRET;
const ORIGINAL_AI_SERVER_TIMEOUT_MS = process.env.AI_SERVER_TIMEOUT_MS;
let tempAiPipelineRoot;

const jsonFetchResponse = (payload, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  text: async () => JSON.stringify(payload),
});

const mockAiServerFetch = () => {
  if (!global.fetch) {
    global.fetch = async () => jsonFetchResponse({});
  }
  return jest.spyOn(global, 'fetch').mockImplementation(async (url, options = {}) => {
    const urlString = typeof url === 'string' ? url : url.url;
    const body = options.body ? JSON.parse(String(options.body)) : {};
    if (urlString === 'http://ai-server.test/health') {
      return jsonFetchResponse({
        status: 'ok',
        service: 'ai-pipeline',
        dry_run: true,
        checks: {
          server: true,
          outputs_dir: true,
          database: null,
          gee: null,
        },
        message: 'AI server is healthy in dry-run mode.',
      });
    }
    if (urlString === 'http://ai-server.test/api/runs/start') {
      return jsonFetchResponse({
        run_id: body.run_id,
        project_id: body.project_id,
        status: 'accepted',
        stage: 'accepted',
        progress: 0,
        message: 'Pipeline accepted by AI server.',
        counts: { accepted: true },
      });
    }
    if (urlString.endsWith('/status')) {
      const runId = urlString.split('/').at(-2);
      return jsonFetchResponse({
        run_id: runId,
        status: 'running',
        stage: 'training',
        progress: 0.42,
        message: 'Training model.',
      });
    }
    if (urlString.endsWith('/cancel')) {
      const runId = urlString.split('/').at(-2);
      return jsonFetchResponse({
        run_id: runId,
        status: 'cancelled',
        stage: 'cancelled',
        progress: 0.42,
        message: 'Run cancelled.',
      });
    }
    if (urlString.endsWith('/resume')) {
      const runId = urlString.split('/').at(-2);
      return jsonFetchResponse({
        run_id: runId,
        status: 'running',
        stage: 'resumed',
        progress: 0.42,
        message: 'Run resumed.',
      });
    }
    if (urlString.endsWith('/api/retrain/check')) {
      return jsonFetchResponse({
        recommended: false,
        reason: 'Validation feedback is below the retraining threshold.',
      });
    }
    return jsonFetchResponse({ message: `Unhandled AI server test URL: ${urlString}` }, 404);
  });
};

const activateProject = async ({ token, projectId }) => {
  const response = await request(app)
    .put(`${API_PREFIX}/projects/${projectId}`)
    .set(authHeader(token))
    .send({ status: 'active' });

  if (response.status !== 200) {
    throw new Error(
      `activateProject failed (${response.status}): ${JSON.stringify(response.body)}`,
    );
  }
};

const createProjectFixture = async (
  name = 'AI Endpoint Project',
  { protectedSuperAdmin = true } = {},
) => {
  const admin = await createAdminUser({
    fullName: `${name} Admin`,
    ...(protectedSuperAdmin ? { email: SUPER_ADMIN_EMAIL } : { emailPrefix: 'ai-endpoint-admin' }),
  });
  const category = await createCategory({
    token: admin.token,
    name: `${name} Category`,
  });
  const project = await createProject({
    token: admin.token,
    categoryId: category.id,
    name,
    visibleToViewers: true,
    visibleToContributors: true,
  });
  await activateProject({ token: admin.token, projectId: project.id });

  return {
    admin,
    category,
    project,
  };
};

const insertApprovedFeature = async ({
  projectId,
  userId,
  attributes,
  source = 'field',
  lon = 35.5,
  lat = 33.9,
}) => {
  const result = await pool.query(
    `INSERT INTO spatial_feature (
       project_id,
       collected_by_user_id,
       geom,
       attributes,
       status,
       submitted_at,
       reviewed_at,
       reviewed_by_user_id,
       source
     )
     VALUES (
       $1,
       $2,
       ST_SetSRID(ST_MakePoint($3, $4), 4326),
       $5::jsonb,
       'approved',
       CURRENT_TIMESTAMP,
       CURRENT_TIMESTAMP,
       $2,
       $6
     )
     RETURNING id`,
    [projectId, userId, lon, lat, JSON.stringify(attributes), source],
  );

  return result.rows[0].id;
};

const updateProjectSchema = async ({ projectId, fields }) => {
  await pool.query(
    `UPDATE project
     SET collection_form_schema = $2::jsonb
     WHERE id = $1`,
    [
      projectId,
      JSON.stringify({
        schemaVersion: 'phase-b-test',
        fields,
      }),
    ],
  );
};

const createReviewableAiRun = async ({ projectId, userId, layerStatus = 'ready_for_review' }) => {
  const runResult = await pool.query(
    `INSERT INTO ai_run (
       project_id,
       status,
       label_field,
       scope_type,
       training_feature_count,
       eligible_feature_count,
       excluded_feature_count,
       selected_model,
       started_by,
       metadata
     )
     VALUES (
       $1,
       'ready_for_review',
       'feature_type',
       'project',
       12,
       12,
       0,
       'random_forest',
       $2,
       '{"execution_mode":"regional_model_eval","phase":"phase_i_test"}'::jsonb
     )
     RETURNING id`,
    [projectId, userId],
  );
  const layerResult = await pool.query(
    `INSERT INTO ai_output_layer (
       ai_run_id,
       project_id,
       layer_type,
       status,
       name,
       description,
       storage_path,
       crs,
       style
     )
     VALUES (
       $1,
       $2,
       'classification',
       $3,
       'Regional AI classification review',
       'Unpublished regional classification review layer',
       'outputs/runs/phase-i-test/ai_classification_review.geojson',
       'EPSG:4326',
       '{}'::jsonb
     )
     RETURNING id`,
    [runResult.rows[0].id, projectId, layerStatus],
  );

  return {
    runId: runResult.rows[0].id,
    layerId: layerResult.rows[0].id,
  };
};

const enableProjectAiSettings = async ({ projectId, userId }) => {
  await pool.query(
    `INSERT INTO ai_project_settings (
       project_id,
       is_enabled,
       label_field,
       scope_type,
       min_samples_per_class,
       model_preferences,
       created_by,
       updated_by
     )
     VALUES ($1, true, 'L4_descr', 'project', 50, '{}'::jsonb, $2, $2)
     ON CONFLICT (project_id)
     DO UPDATE SET
       is_enabled = true,
       label_field = EXCLUDED.label_field,
       updated_by = EXCLUDED.updated_by`,
    [projectId, userId],
  );
};

const createPreviewableAiLayer = async ({
  projectId,
  userId,
  layerType = 'classification',
  status = 'ready_for_review',
  storagePath = 'outputs/runs/phase-o-test/ai_classification_review.geojson',
  withPrediction = false,
}) => {
  const runResult = await pool.query(
    `INSERT INTO ai_run (
       project_id,
       status,
       label_field,
       scope_type,
       training_feature_count,
       eligible_feature_count,
       excluded_feature_count,
       selected_model,
       started_by,
       metadata
     )
     VALUES (
       $1,
       'ready_for_review',
       'L4_descr',
       'project',
       1406,
       1394,
       12,
       'random_forest',
       $2,
       '{"execution_mode":"regional_vectorization_artifacts","phase":"phase_o_preview_test"}'::jsonb
     )
     RETURNING id`,
    [projectId, userId],
  );
  const layerResult = await pool.query(
    `INSERT INTO ai_output_layer (
       ai_run_id,
       project_id,
       layer_type,
       status,
       name,
       description,
       storage_path,
       crs,
       style
     )
     VALUES (
       $1,
       $2,
       $3,
       $4,
       'Regional AI classification preview',
       'Unpublished AI map preview artifact.',
       $5,
       'EPSG:4326',
       '{}'::jsonb
     )
     RETURNING id`,
    [runResult.rows[0].id, projectId, layerType, status, storagePath],
  );

  if (withPrediction) {
    await insertAiPredictionFeature({
      projectId,
      runId: runResult.rows[0].id,
      layerId: layerResult.rows[0].id,
      artifactFeatureId: `${layerResult.rows[0].id}-prediction-1`,
      status: status === 'published' ? 'published' : 'ready_for_review',
    });
  }

  return {
    runId: runResult.rows[0].id,
    layerId: layerResult.rows[0].id,
  };
};

const insertAiPredictionFeature = async ({
  projectId,
  runId,
  layerId,
  artifactFeatureId,
  predictedClass = 'olives',
  confidence = 0.82,
  uncertaintyScore = null,
  modelName = 'random_forest',
  status = 'ready_for_review',
  lon = 35.22,
  lat = 33.2,
}) => {
  const geometry = {
    type: 'Polygon',
    coordinates: [
      [
        [lon, lat],
        [lon + 0.01, lat],
        [lon + 0.01, lat + 0.01],
        [lon, lat + 0.01],
        [lon, lat],
      ],
    ],
  };
  const result = await pool.query(
    `INSERT INTO ai_prediction_feature (
       project_id,
       ai_run_id,
       ai_output_layer_id,
       artifact_feature_id,
       geom,
       geometry_type,
       predicted_class,
       confidence,
       uncertainty_score,
       model_name,
       source,
       status,
       metadata
     )
     VALUES (
       $1,
       $2,
       $3,
       $4,
       ST_SetSRID(ST_GeomFromGeoJSON($5), 4326),
       'Polygon',
       $6,
       $7,
       $8,
       $9,
       'ai_prediction',
       $10,
       $11::jsonb
     )
     RETURNING id`,
    [
      projectId,
      runId,
      layerId,
      artifactFeatureId,
      JSON.stringify(geometry),
      predictedClass,
      confidence,
      uncertaintyScore,
      modelName,
      status,
      JSON.stringify({
        properties: {
          source_feature_id: artifactFeatureId,
          predicted_class: predictedClass,
          confidence,
          uncertainty_score: uncertaintyScore,
          model_name: modelName,
          source: 'ai_prediction',
        },
        not_official_field_data: true,
        no_spatial_feature_writes: true,
      }),
    ],
  );
  return result.rows[0].id;
};

const insertAiClassStatistic = async ({ runId, classLabel, featureCount = 12 }) => {
  await pool.query(
    `INSERT INTO ai_class_statistic (
       ai_run_id,
       class_label,
       feature_count,
       statistics
     )
     VALUES ($1, $2, $3, '{}'::jsonb)
     ON CONFLICT (ai_run_id, class_label)
     DO UPDATE SET feature_count = EXCLUDED.feature_count`,
    [runId, classLabel, featureCount],
  );
};

const assignContributorToProject = async ({ projectId, userId, approvedBy }) => {
  await pool.query(
    `INSERT INTO project_assignment (
       project_id,
       user_id,
       role,
       status,
       approved_by_user_id,
       approved_date
     )
     VALUES ($1, $2, 'contributor', 'approved', $3, CURRENT_DATE)
     ON CONFLICT (project_id, user_id)
     DO UPDATE SET
       role = 'contributor',
       status = 'approved',
       approved_by_user_id = $3,
       approved_date = CURRENT_DATE`,
    [projectId, userId, approvedBy],
  );
};

const insertPendingSpatialFeature = async ({ projectId, userId }) => {
  const result = await pool.query(
    `INSERT INTO spatial_feature (
       project_id,
       collected_by_user_id,
       geom,
       attributes,
       status,
       submitted_at,
       source
     )
     VALUES (
       $1,
       $2,
       ST_SetSRID(ST_MakePoint(35.42, 33.82), 4326),
       '{"source":"ai_validation_test"}'::jsonb,
       'pending_review',
       NOW(),
       'ai_validation'
     )
     RETURNING id`,
    [projectId, userId],
  );
  return result.rows[0].id;
};

const writePreviewGeoJson = async (
  relativePath = 'outputs/runs/phase-o-test/ai_classification_review.geojson',
  features = [
    {
      type: 'Feature',
      properties: {
        predicted_class: 'olives',
        confidence: 0.82,
        model_name: 'random_forest',
        source: 'ai_prediction',
        run_id: 'phase-o-test',
        area_ha: 1.4,
      },
      geometry: {
        type: 'Polygon',
        coordinates: [
          [
            [35.22, 33.2],
            [35.23, 33.2],
            [35.23, 33.21],
            [35.22, 33.21],
            [35.22, 33.2],
          ],
        ],
      },
    },
  ],
) => {
  const absolutePath = path.join(tempAiPipelineRoot, relativePath);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(
    absolutePath,
    JSON.stringify({
      type: 'FeatureCollection',
      features,
    }),
    'utf8',
  );
  return relativePath;
};

const createContributorToken = async ({ adminToken, emailPrefix = 'ai-endpoint-contributor' }) => {
  const registered = await registerUser({
    role: 'contributor',
    fullName: 'AI Endpoint Contributor',
    emailPrefix,
  });
  await approveContributorRequest({
    token: adminToken,
    userId: registered.user.id,
  });
  const login = await loginUser({
    email: registered.email,
    password: registered.password,
  });
  return {
    user: registered.user,
    token: login.token,
  };
};

const createViewerToken = async () => {
  const registered = await registerUser({
    role: 'viewer',
    fullName: 'AI Endpoint Viewer',
    emailPrefix: 'ai-endpoint-viewer',
  });
  const login = await loginUser({
    email: registered.email,
    password: registered.password,
  });
  return {
    user: registered.user,
    token: login.token,
  };
};

const createStartableAiProjectFixture = async (name = 'AI Server Config Project') => {
  const fixture = await createProjectFixture(name);
  await request(app)
    .put(`${API_PREFIX}/projects/${fixture.project.id}/ai/settings`)
    .set(authHeader(fixture.admin.token))
    .send({
      is_enabled: true,
      label_field: 'feature_type',
      scope_type: 'project',
      min_samples_per_class: 1,
      model_preferences: {},
    })
    .expect(200);
  await insertApprovedFeature({
    projectId: fixture.project.id,
    userId: fixture.admin.user.id,
    attributes: { feature_type: 'Olives' },
  });
  await insertApprovedFeature({
    projectId: fixture.project.id,
    userId: fixture.admin.user.id,
    attributes: { feature_type: 'Citrus' },
    lon: 35.51,
    lat: 33.91,
  });
  return fixture;
};

const DATABASE_HOOK_TIMEOUT_MS = 30_000;

beforeEach(async () => {
  await resetDb();
  process.env.SUPER_ADMIN_EMAIL = SUPER_ADMIN_EMAIL;
  tempAiPipelineRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'gis-ai-phase-o-'));
  process.env.AI_PIPELINE_ROOT = tempAiPipelineRoot;
  delete process.env.AI_PIPELINE_OUTPUT_ROOT;
  process.env.AI_SERVER_URL = 'http://ai-server.test';
  process.env.APP_PUBLIC_API_URL = 'http://app-api.test';
  process.env.AI_CALLBACK_BASE_URL = 'http://callback-api.test';
  process.env.AI_CALLBACK_SECRET = 'test-ai-callback-secret';
  process.env.AI_SERVER_TIMEOUT_MS = '5000';
  mockAiServerFetch();
}, DATABASE_HOOK_TIMEOUT_MS);

afterEach(async () => {
  jest.restoreAllMocks();
  await resetDb();
  if (tempAiPipelineRoot) {
    await fs.rm(tempAiPipelineRoot, { recursive: true, force: true });
    tempAiPipelineRoot = null;
  }
  if (ORIGINAL_AI_PIPELINE_ROOT === undefined) {
    delete process.env.AI_PIPELINE_ROOT;
  } else {
    process.env.AI_PIPELINE_ROOT = ORIGINAL_AI_PIPELINE_ROOT;
  }
  if (ORIGINAL_AI_PIPELINE_OUTPUT_ROOT === undefined) {
    delete process.env.AI_PIPELINE_OUTPUT_ROOT;
  } else {
    process.env.AI_PIPELINE_OUTPUT_ROOT = ORIGINAL_AI_PIPELINE_OUTPUT_ROOT;
  }
  if (ORIGINAL_AI_SERVER_URL === undefined) {
    delete process.env.AI_SERVER_URL;
  } else {
    process.env.AI_SERVER_URL = ORIGINAL_AI_SERVER_URL;
  }
  if (ORIGINAL_APP_PUBLIC_API_URL === undefined) {
    delete process.env.APP_PUBLIC_API_URL;
  } else {
    process.env.APP_PUBLIC_API_URL = ORIGINAL_APP_PUBLIC_API_URL;
  }
  if (ORIGINAL_AI_CALLBACK_BASE_URL === undefined) {
    delete process.env.AI_CALLBACK_BASE_URL;
  } else {
    process.env.AI_CALLBACK_BASE_URL = ORIGINAL_AI_CALLBACK_BASE_URL;
  }
  if (ORIGINAL_AI_CALLBACK_SECRET === undefined) {
    delete process.env.AI_CALLBACK_SECRET;
  } else {
    process.env.AI_CALLBACK_SECRET = ORIGINAL_AI_CALLBACK_SECRET;
  }
  if (ORIGINAL_AI_SERVER_TIMEOUT_MS === undefined) {
    delete process.env.AI_SERVER_TIMEOUT_MS;
  } else {
    process.env.AI_SERVER_TIMEOUT_MS = ORIGINAL_AI_SERVER_TIMEOUT_MS;
  }
}, DATABASE_HOOK_TIMEOUT_MS);

afterAll(async () => {
  delete process.env.SUPER_ADMIN_EMAIL;
  await shutdown();
});

describe('AI backend endpoints phase B', () => {
  test('readiness returns not_ready when a project has no approved samples', async () => {
    const { admin, project } = await createProjectFixture('AI Empty Readiness');

    const response = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(response.body.data.readiness.status).toBe('not_ready');
    expect(response.body.data.readiness.approved_feature_count).toBe(0);
    expect(response.body.data.readiness.blockers).toEqual(
      expect.arrayContaining(['Project has no approved field/import features available for AI.']),
    );
    expect(response.body.data.readiness.ai_server).toEqual(
      expect.objectContaining({
        configured: true,
        available: true,
        status: 'ok',
        callback_secret_configured: true,
      }),
    );
  });

  test('AI_SERVER_URL missing is reported by readiness and fails start without a queued run', async () => {
    const { admin, project } = await createStartableAiProjectFixture('AI Missing Server URL');
    delete process.env.AI_SERVER_URL;

    const readinessResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(readinessResponse.body.data.readiness.status).toBe('not_ready');
    expect(readinessResponse.body.data.readiness.ai_server).toEqual(
      expect.objectContaining({
        configured: false,
        available: false,
        status: 'unconfigured',
      }),
    );
    expect(readinessResponse.body.data.readiness.blockers).toEqual(
      expect.arrayContaining([
        'AI server URL is not configured. Set AI_SERVER_URL before starting AI runs.',
      ]),
    );

    const startResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_feature_extraction',
      })
      .expect(503);

    expect(startResponse.body.message).toContain('AI_SERVER_URL');
    expect(startResponse.body.data).toEqual(
      expect.objectContaining({
        status: 'failed',
        failure_reason: expect.stringContaining('AI_SERVER_URL'),
      }),
    );
    const queuedCount = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM ai_run
       WHERE project_id = $1 AND status = 'queued'`,
      [project.id],
    );
    expect(queuedCount.rows[0].count).toBe(0);
  });

  test('unreachable AI server is reported by readiness and fails start clearly', async () => {
    const { admin, project } = await createStartableAiProjectFixture('AI Server Unreachable');
    global.fetch.mockImplementation(async (url) => {
      const urlString = typeof url === 'string' ? url : url.url;
      if (urlString === 'http://ai-server.test/health') {
        throw new Error('connect ECONNREFUSED 127.0.0.1:8000');
      }
      return jsonFetchResponse({ message: `Unhandled AI server test URL: ${urlString}` }, 404);
    });

    const readinessResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(readinessResponse.body.data.readiness.status).toBe('not_ready');
    expect(readinessResponse.body.data.readiness.ai_server).toEqual(
      expect.objectContaining({
        configured: true,
        available: false,
        status: 'unavailable',
      }),
    );
    expect(readinessResponse.body.data.readiness.blockers).toEqual(
      expect.arrayContaining([
        'AI server is unavailable. Please start the AI server and refresh readiness.',
      ]),
    );

    const startResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_feature_extraction',
      })
      .expect(503);

    expect(startResponse.body.message).toBe(
      'AI server is unavailable. Please start the AI server and refresh readiness.',
    );
    expect(startResponse.body.data).toEqual(
      expect.objectContaining({
        status: 'failed',
        failure_reason: expect.stringContaining('connect ECONNREFUSED'),
      }),
    );
  });

  test('readiness counts labels, missing labels, sources, and minimum sample blockers', async () => {
    const { admin, project } = await createProjectFixture('AI Labeled Readiness');

    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
      source: 'import',
      lon: 35.4,
      lat: 33.8,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
      source: 'import',
      lon: 35.41,
      lat: 33.81,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Citrus' },
      source: 'field',
      lon: 35.42,
      lat: 33.82,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Citrus' },
      source: 'field',
      lon: 35.43,
      lat: 33.83,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { notes: 'missing label' },
      source: 'field',
      lon: 35.44,
      lat: 33.84,
    });

    const warningResponse = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=2`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(warningResponse.body.data.readiness.status).toBe('warning');
    expect(warningResponse.body.data.readiness.approved_feature_count).toBe(5);
    expect(warningResponse.body.data.readiness.eligible_feature_count).toBe(4);
    expect(warningResponse.body.data.readiness.missing_label_count).toBe(1);
    expect(warningResponse.body.data.readiness.label_counts).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ class_label: 'Olives', sample_count: 2 }),
        expect.objectContaining({ class_label: 'Citrus', sample_count: 2 }),
      ]),
    );
    expect(warningResponse.body.data.readiness.source_counts).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ source: 'field', feature_count: 3 }),
        expect.objectContaining({ source: 'import', feature_count: 2 }),
      ]),
    );
    expect(warningResponse.body.data.readiness.candidate_label_fields).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          field: 'feature_type',
          labeled_feature_count: 4,
          class_count: 2,
          usable: true,
          selectable: true,
          recommended: true,
          aliases: [],
        }),
        expect.objectContaining({
          field: 'condition',
          labeled_feature_count: 0,
          class_count: 0,
          usable: false,
          selectable: false,
          diagnostic_only: true,
          recommended: false,
        }),
      ]),
    );

    const notReadyResponse = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=3`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(notReadyResponse.body.data.readiness.status).toBe('not_ready');
    expect(notReadyResponse.body.data.readiness.labeled_feature_count).toBe(4);
    expect(notReadyResponse.body.data.readiness.eligible_feature_count).toBe(0);
    expect(notReadyResponse.body.data.readiness.classes_below_minimum).toHaveLength(2);
  });

  test('readiness marks equivalent imported label fields as aliases and keeps only the schema classifier selectable', async () => {
    const { admin, project } = await createProjectFixture('AI Alias Labels');
    await updateProjectSchema({
      projectId: project.id,
      fields: [
        {
          key: 'feature_type',
          label: 'L4_descr',
          type: 'select',
          required: true,
          options: ['Olives', 'Citrus'],
        },
        {
          key: 'crop_type',
          label: 'Crop type',
          type: 'select',
          required: false,
          options: ['Olives', 'Citrus'],
        },
      ],
    });

    for (const [index, label] of ['Olives', 'Olives', 'Citrus', 'Citrus'].entries()) {
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes: {
          L4_descr: label,
          feature_type: label,
          level_4: label,
          L1_code: '1',
          L1_descr: 'Agriculture',
          L2_code: '10',
          L2_descr: 'Permanent crops',
          L3_code: label === 'Olives' ? '100' : '200',
          L4_code: label === 'Olives' ? '101' : '201',
          OBJECTID_1: `${label}-${index}`,
          OBJECTID_2: label === 'Olives' ? '1' : '2',
          Shape_Area: label === 'Olives' ? '123.45' : '234.56',
          Shape_Leng: label === 'Olives' ? '12.3' : '23.4',
        },
        source: 'import',
      });
    }

    const response = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=L4_descr&min_samples_per_class=2`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    const candidatesByField = Object.fromEntries(
      response.body.data.readiness.candidate_label_fields.map((candidate) => [
        candidate.field,
        candidate,
      ]),
    );

    expect(candidatesByField.L4_descr).toEqual(
      expect.objectContaining({
        field: 'L4_descr',
        usable: true,
        selectable: true,
        diagnostic_only: false,
        recommended: true,
        aliases: expect.arrayContaining(['feature_type']),
      }),
    );
    expect(candidatesByField.feature_type).toEqual(
      expect.objectContaining({
        field: 'feature_type',
        usable: true,
        selectable: false,
        diagnostic_only: true,
        alias_of: 'L4_descr',
        recommended: false,
      }),
    );
    expect(candidatesByField.crop_type).toEqual(
      expect.objectContaining({
        field: 'crop_type',
        labeled_feature_count: 0,
        class_count: 0,
        usable: false,
        selectable: false,
        diagnostic_only: true,
      }),
    );
    for (const rawField of [
      'OBJECTID_1',
      'OBJECTID_2',
      'Shape_Area',
      'Shape_Leng',
      'L1_code',
      'L1_descr',
      'L2_code',
      'L2_descr',
      'L3_code',
      'L4_code',
      'level_4',
    ]) {
      expect(candidatesByField[rawField]).toEqual(
        expect.objectContaining({
          selectable: false,
          diagnostic_only: true,
          recommended: false,
        }),
      );
    }
  });

  test('readiness keeps genuinely different label fields selectable', async () => {
    const { admin, project } = await createProjectFixture('AI Multiple Labels');
    await updateProjectSchema({
      projectId: project.id,
      fields: [
        {
          key: 'land_cover',
          label: 'Land cover',
          type: 'select',
          required: true,
          options: ['Forest', 'Orchard'],
        },
        {
          key: 'irrigation_type',
          label: 'Irrigation type',
          type: 'select',
          required: false,
          options: ['Drip', 'Rainfed'],
        },
      ],
    });

    for (const attributes of [
      { land_cover: 'Forest', irrigation_type: 'Drip' },
      { land_cover: 'Forest', irrigation_type: 'Rainfed' },
      { land_cover: 'Orchard', irrigation_type: 'Rainfed' },
      { land_cover: 'Orchard', irrigation_type: 'Rainfed' },
    ]) {
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes,
        source: 'field',
      });
    }

    const response = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=land_cover&min_samples_per_class=1`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    const candidatesByField = Object.fromEntries(
      response.body.data.readiness.candidate_label_fields.map((candidate) => [
        candidate.field,
        candidate,
      ]),
    );

    expect(candidatesByField.land_cover).toEqual(
      expect.objectContaining({
        selectable: true,
        recommended: true,
        aliases: [],
      }),
    );
    expect(candidatesByField.irrigation_type).toEqual(
      expect.objectContaining({
        selectable: true,
        recommended: false,
        alias_of: null,
      }),
    );
  });

  test('readiness warns and excludes low-count classes when enough classes remain', async () => {
    const { admin, project } = await createProjectFixture('AI Regional Warning');

    for (const featureType of [
      'Olives',
      'Olives',
      'Citrus',
      'Citrus',
      'Fruit Trees',
      'Fruit Trees',
      'Vineyards',
    ]) {
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes: { feature_type: featureType },
        source: 'import',
      });
    }

    const response = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=2`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(response.body.data.readiness.status).toBe('warning');
    expect(response.body.data.readiness.labeled_feature_count).toBe(7);
    expect(response.body.data.readiness.eligible_class_count).toBe(3);
    expect(response.body.data.readiness.eligible_feature_count).toBe(6);
    expect(response.body.data.readiness.excluded_feature_count).toBe(1);
    expect(response.body.data.readiness.classes_below_minimum).toEqual([
      expect.objectContaining({ class_label: 'Vineyards', sample_count: 1 }),
    ]);
    expect(response.body.data.readiness.blockers).toEqual([]);
    expect(response.body.data.readiness.warnings).toEqual(
      expect.arrayContaining([expect.stringContaining('Vineyards (1)')]),
    );
  });

  test('GET and PATCH project AI settings persist safe configuration only', async () => {
    const { admin, project } = await createProjectFixture('AI Settings');

    const defaultResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(defaultResponse.body.data.persisted).toBe(false);
    expect(defaultResponse.body.data.is_enabled).toBe(false);

    const updateResponse = await request(app)
      .patch(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 2,
        model_preferences: {
          models: ['random_forest'],
        },
      })
      .expect(200);

    expect(updateResponse.body.data.is_enabled).toBe(true);
    expect(updateResponse.body.data.label_field).toBe('feature_type');
    expect(updateResponse.body.data.min_samples_per_class).toBe(2);
    expect(updateResponse.body.data.model_preferences.models).toEqual(['random_forest']);
  });

  test('rejects MLP model preference for new AI settings', async () => {
    const { admin, project } = await createProjectFixture('AI Settings MLP Reject');

    const response = await request(app)
      .patch(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 2,
        model_preferences: {
          preferred_model: 'mlp',
        },
      })
      .expect(400);

    expect(response.body.message).toBe('Validation failed');
    expect(response.body.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          msg: 'preferred_model must be Auto, Random Forest, SVM, or Gradient Boosting',
        }),
      ]),
    );
  });

  test('rejects XGBoost model preference for new AI settings', async () => {
    const { admin, project } = await createProjectFixture('AI Settings XGBoost Reject');

    const response = await request(app)
      .patch(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 2,
        model_preferences: {
          preferred_model: 'xgboost',
        },
      })
      .expect(400);

    expect(response.body.message).toBe('Validation failed');
    expect(response.body.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          msg: 'preferred_model must be Auto, Random Forest, SVM, or Gradient Boosting',
        }),
      ]),
    );
  });

  test('rejects texture features without Sentinel-2 dry season', async () => {
    const { admin, project } = await createProjectFixture('AI Settings Texture Reject');

    const response = await request(app)
      .patch(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 2,
        model_preferences: {
          satellite_sources: ['sentinel2'],
          satellite_timeframes: {
            sentinel2: {
              map_year: 2025,
              seasons: [
                {
                  season: 'growing',
                  from_date: '2025-03-01',
                  to_date: '2025-06-30',
                },
              ],
            },
          },
          feature_inputs: ['NDVI', 'static_texture_pc1'],
        },
      })
      .expect(400);

    expect(response.body.message).toContain(
      'Texture features require Sentinel-2 NDVI from the dry season',
    );
  });

  test('custom polygon scope is saved for AI only and affects readiness and run metadata', async () => {
    const { admin, project } = await createProjectFixture('AI Custom Scope');
    const customScope = {
      type: 'Polygon',
      coordinates: [
        [
          [35.49, 33.89],
          [35.51, 33.89],
          [35.51, 33.91],
          [35.49, 33.91],
          [35.49, 33.89],
        ],
      ],
    };

    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
      lon: 35.5,
      lat: 33.9,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Citrus' },
      lon: 35.8,
      lat: 34.2,
    });
    const beforeCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature WHERE project_id = $1`,
      [project.id],
    );

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'custom_polygon',
        scope_geometry: customScope,
        min_samples_per_class: 1,
        model_preferences: {
          satellite_source: 'sentinel2',
          season: 'growing',
          date_from: '2026-03-01',
          date_to: '2026-10-31',
          feature_inputs: ['NDVI', 'EVI'],
        },
      })
      .expect(200);

    const scopedReadiness = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=1`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(scopedReadiness.body.data.readiness.approved_feature_count).toBe(1);
    expect(scopedReadiness.body.data.readiness.custom_scope_applied).toBe(true);
    expect(scopedReadiness.body.data.readiness.scope_type).toBe('custom_polygon');
    expect(scopedReadiness.body.data.readiness.training_samples_area_type).toBe('custom_ai_area');
    expect(scopedReadiness.body.data.readiness.prediction_area_type).toBe('custom_ai_area');
    expect(scopedReadiness.body.data.readiness.national_scope_enabled).toBe(false);
    expect(scopedReadiness.body.data.readiness.national_scope_eligibility).toEqual(
      expect.objectContaining({
        eligible: false,
        requirements: expect.arrayContaining([
          expect.objectContaining({ key: 'national_mode_allowed', passed: false }),
          expect.objectContaining({ key: 'lebanon_boundary_configured', passed: false }),
          expect.objectContaining({
            key: 'pipeline_supports_national_processing',
            passed: false,
          }),
        ]),
      }),
    );

    const runResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({ status: 'draft' })
      .expect(201);

    expect(runResponse.body.data.training_feature_count).toBe(1);
    expect(runResponse.body.data.scope_type).toBe('custom_polygon');
    expect(runResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        training_samples_area_type: 'custom_ai_area',
        prediction_area_type: 'custom_ai_area',
        national_scope_enabled: false,
        national_scope_eligibility: expect.objectContaining({
          eligible: false,
          requirements: expect.arrayContaining([
            expect.objectContaining({ key: 'national_mode_allowed', passed: false }),
          ]),
        }),
      }),
    );
    expect(runResponse.body.data.metadata.ai_settings).toEqual(
      expect.objectContaining({
        satellite_sources: ['sentinel2'],
        satellite_timeframes: {
          sentinel2: {
            map_year: 2026,
            seasons: [
              {
                season: 'growing',
                from_date: '2026-03-01',
                to_date: '2026-10-31',
              },
            ],
          },
        },
        satellite_source: 'sentinel2',
        season: 'growing',
        feature_groups: ['vegetation_indices'],
        feature_inputs: ['NDVI', 'EVI'],
        confidence_threshold: 0.6,
        training_samples_area_type: 'custom_ai_area',
        prediction_area_type: 'custom_ai_area',
        custom_scope_applied: true,
        custom_polygon_summary: expect.objectContaining({
          saved_for_run: true,
          geometry_type: 'Polygon',
        }),
      }),
    );
    expect(runResponse.body.data.metadata.pipeline_execution_support).toEqual(
      expect.objectContaining({
        settings_saved_for_run: true,
        backend_scope_applied: true,
        effective_pipeline_settings: expect.arrayContaining(['training_samples_area_type']),
        pending_pipeline_settings: expect.arrayContaining([
          'satellite_sources',
          'satellite_timeframes',
          'confidence_threshold',
          'date_range',
          'feature_groups',
          'feature_inputs',
          'prediction_area_type',
          'custom_area',
        ]),
      }),
    );

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        scope_geometry: customScope,
        min_samples_per_class: 1,
        model_preferences: {},
      })
      .expect(200);

    const projectReadiness = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=1`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(projectReadiness.body.data.readiness.approved_feature_count).toBe(2);
    expect(projectReadiness.body.data.readiness.custom_scope_applied).toBe(false);
    expect(projectReadiness.body.data.readiness.scope_type).toBe('project');
    expect(projectReadiness.body.data.readiness.training_samples_area_type).toBe('project_area');
    expect(projectReadiness.body.data.readiness.prediction_area_type).toBe('project_area');

    const afterCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature WHERE project_id = $1`,
      [project.id],
    );
    expect(afterCount.rows[0].count).toBe(beforeCount.rows[0].count);
  });

  test('National Lebanon AI scope is reported as locked until readiness requirements pass', async () => {
    const { admin, project } = await createProjectFixture('AI National Locked');
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
      lon: 35.5,
      lat: 33.9,
    });

    const readiness = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&scope_type=national&min_samples_per_class=1`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(readiness.body.data.readiness.scope_type).toBe('national');
    expect(readiness.body.data.readiness.training_samples_area_type).toBe('national_lebanon');
    expect(readiness.body.data.readiness.prediction_area_type).toBe('national_lebanon');
    expect(readiness.body.data.readiness.national_scope_enabled).toBe(false);
    expect(readiness.body.data.readiness.national_scope_eligibility).toEqual(
      expect.objectContaining({
        eligible: false,
        requirements: expect.arrayContaining([
          expect.objectContaining({ key: 'national_mode_allowed', passed: false }),
          expect.objectContaining({ key: 'lebanon_boundary_configured', passed: false }),
          expect.objectContaining({
            key: 'pipeline_supports_national_processing',
            passed: false,
          }),
          expect.objectContaining({ key: 'minimum_samples_per_class', passed: false }),
          expect.objectContaining({
            key: 'regional_coverage_configured',
            passed: false,
            message: 'Regional coverage check is not configured yet.',
          }),
        ]),
        warnings: expect.arrayContaining([
          'National Lebanon prediction is locked until national readiness requirements are met.',
        ]),
      }),
    );

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'national',
        min_samples_per_class: 1,
        model_preferences: {},
      })
      .expect(422);

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 1,
        model_preferences: { national_scope_enabled: true },
      })
      .expect(422);

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
        label_field: 'feature_type',
        scope_type: 'national',
      })
      .expect(422);
  });

  test('National Lebanon AI scope becomes eligible only when every backend requirement passes', async () => {
    const { admin, project } = await createProjectFixture('AI National Eligible');
    for (let index = 0; index < 50; index += 1) {
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes: { feature_type: 'Olives' },
        lon: 35.15 + (index % 10) * 0.15,
        lat: 33.05 + Math.floor(index / 10) * 0.36,
      });
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes: { feature_type: 'Citrus' },
        lon: 35.17 + (index % 10) * 0.15,
        lat: 33.07 + Math.floor(index / 10) * 0.36,
      });
    }

    const nationalPreferences = {
      national_mode_allowed: true,
      lebanon_boundary_configured: true,
      pipeline_supports_national_scope: true,
      backend_bridge_supports_national_scope: true,
      python_pipeline_supports_national_scope: true,
      national_regional_coverage_configured: true,
      national_sample_spread_confirmed: true,
      national_imbalance_review_supported: true,
      national_validation_plan_recorded: true,
    };

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 50,
        model_preferences: nationalPreferences,
      })
      .expect(200);

    const readiness = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&scope_type=national&min_samples_per_class=50`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(readiness.body.data.readiness.national_scope_enabled).toBe(false);
    expect(readiness.body.data.readiness.national_scope_eligibility).toEqual(
      expect.objectContaining({
        eligible: true,
        requirements: expect.arrayContaining([
          expect.objectContaining({ key: 'national_mode_allowed', passed: true }),
          expect.objectContaining({ key: 'minimum_samples_per_class', passed: true }),
          expect.objectContaining({ key: 'validation_plan_recorded', passed: true }),
        ]),
      }),
    );
    expect(
      readiness.body.data.readiness.national_scope_eligibility.requirements.every(
        (requirement) => requirement.passed === true,
      ),
    ).toBe(true);

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 50,
        model_preferences: {
          ...nationalPreferences,
          national_scope_enabled: true,
        },
      })
      .expect(200);

    const enabledReadiness = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&scope_type=national&min_samples_per_class=50`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(enabledReadiness.body.data.readiness.national_scope_enabled).toBe(true);
  });

  test('creates draft AI runs, lists runs, exposes empty child resources, and leaves spatial_feature untouched', async () => {
    const { admin, project } = await createProjectFixture('AI Run Draft');
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 1,
        model_preferences: {},
      })
      .expect(200);

    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Citrus' },
      lon: 35.51,
      lat: 33.91,
    });
    const beforeCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature WHERE project_id = $1`,
      [project.id],
    );

    const createResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
      })
      .expect(201);

    expect(createResponse.body.data.status).toBe('draft');
    expect(createResponse.body.data.label_field).toBe('feature_type');
    expect(createResponse.body.data.eligible_feature_count).toBe(2);
    expect(createResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_full_review_artifacts',
        real_ai_execution: false,
        worker_execution: 'replaced_by_ai_server',
      }),
    );

    const afterCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature WHERE project_id = $1`,
      [project.id],
    );
    expect(afterCount.rows[0].count).toBe(beforeCount.rows[0].count);

    const listResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(listResponse.body.data).toHaveLength(1);

    const runId = createResponse.body.data.id;
    await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}`)
      .set(authHeader(admin.token))
      .expect(200);

    const metricsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/metrics`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(metricsResponse.body.data).toEqual([]);

    const layersResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/layers`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(layersResponse.body.data).toEqual([]);

    const logsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/logs`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(logsResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          level: 'info',
          metadata: expect.objectContaining({
            execution_mode: 'regional_full_review_artifacts',
            real_ai_execution: false,
          }),
        }),
      ]),
    );

    const dryRunResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
        execution_mode: 'dry_run',
      })
      .expect(201);
    expect(dryRunResponse.body.data.metadata.execution_mode).toBe('dry_run');

    const regionalResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_feature_extraction',
      })
      .expect(201);
    expect(regionalResponse.body.data.status).toBe('starting');
    expect(regionalResponse.body.data.stage).toBe('accepted');
    expect(regionalResponse.body.data.progress).toBe(0);
    expect(regionalResponse.body.data.message).toBe('Pipeline accepted by AI server.');
    expect(regionalResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_feature_extraction',
        regional_ai_execution_requested: true,
        real_ai_execution: true,
        worker_execution: 'replaced_by_ai_server',
      }),
    );
    const startedRunId = regionalResponse.body.data.id;
    const startCall = global.fetch.mock.calls.find(
      ([url]) => String(url) === 'http://ai-server.test/api/runs/start',
    );
    expect(startCall).toBeTruthy();
    const startPayload = JSON.parse(String(startCall[1].body));
    expect(startPayload.callback_url).toBe(
      `http://callback-api.test/api/v1/ai/runs/${startedRunId}/callback`,
    );
    expect(startPayload.callback_secret).toBe('test-ai-callback-secret');

    const statusResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/runs/${startedRunId}/status`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(statusResponse.body.data).toEqual(
      expect.objectContaining({
        status: 'running',
        stage: 'training',
        progress: 0.42,
        message: 'Training model.',
      }),
    );

    const cancelResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs/${startedRunId}/cancel`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(cancelResponse.body.data).toEqual(
      expect.objectContaining({
        status: 'cancelled',
        stage: 'cancelled',
        can_resume: true,
      }),
    );

    const resumeResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs/${startedRunId}/resume`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(resumeResponse.body.data).toEqual(
      expect.objectContaining({
        status: 'running',
        stage: 'resumed',
        can_cancel: true,
      }),
    );

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${startedRunId}/callback`)
      .send({
        run_id: startedRunId,
        project_id: project.id,
        status: 'completed',
      })
      .expect(401);

    const callbackResponse = await request(app)
      .post(`${API_PREFIX}/ai/runs/${startedRunId}/callback`)
      .set('X-AI-Callback-Secret', 'test-ai-callback-secret')
      .send({
        run_id: startedRunId,
        project_id: project.id,
        status: 'completed',
        stage: 'finished',
        progress: 1,
        message: 'AI run completed.',
        counts: { prediction_count: 2 },
        artifacts: { classification: 'outputs/runs/test/ai_classification_review.geojson' },
        metrics: {
          model_name: 'random_forest',
          overall_accuracy: 0.8,
          macro_f1: 0.75,
          feature_importance: [{ feature: 'sentinel2_growing_ndvi_mean', importance: 0.42 }],
        },
      })
      .expect(200);
    expect(callbackResponse.body.data).toEqual(
      expect.objectContaining({
        status: 'completed',
        stage: 'finished',
        progress: 1,
        message: 'AI run completed.',
        callback_received_at: expect.any(String),
        counts: expect.objectContaining({ prediction_count: 2 }),
        artifacts: expect.objectContaining({
          classification: 'outputs/runs/test/ai_classification_review.geojson',
        }),
      }),
    );

    const regionalClassificationResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_classification',
      })
      .expect(201);
    expect(regionalClassificationResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_classification',
        regional_ai_execution_requested: true,
        real_ai_execution: true,
        worker_execution: 'replaced_by_ai_server',
      }),
    );
    await pool.query(`UPDATE ai_run SET status = 'completed' WHERE id = $1`, [
      regionalClassificationResponse.body.data.id,
    ]);

    const vectorArtifactResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_vectorization_artifacts',
      })
      .expect(201);
    expect(vectorArtifactResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_vectorization_artifacts',
        regional_ai_execution_requested: true,
        real_ai_execution: true,
        worker_execution: 'replaced_by_ai_server',
      }),
    );
    await pool.query(`UPDATE ai_run SET status = 'completed' WHERE id = $1`, [
      vectorArtifactResponse.body.data.id,
    ]);

    const fullRegionalResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_full_review_artifacts',
      })
      .expect(201);
    expect(fullRegionalResponse.body.data.status).toBe('starting');
    expect(fullRegionalResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_full_review_artifacts',
        regional_ai_execution_requested: true,
        real_ai_execution: true,
        worker_execution: 'replaced_by_ai_server',
      }),
    );

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        scope_type: 'national',
        execution_mode: 'regional_vectorization_artifacts',
      })
      .expect(422);

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
        execution_mode: 'full_training',
      })
      .expect(400);
  });

  test('AI callbacks sanitize raw prediction geometry insertion failures', async () => {
    const { admin, project } = await createProjectFixture('AI Geometry Failure Sanitizing');
    const rawGeometryFailure =
      'new row for relation "ai_prediction_feature" violates check constraint ' +
      '"chk_ai_prediction_feature_geom_valid" DETAIL: Failing row contains (... MultiPolygon ...).';
    const runResult = await pool.query(
      `INSERT INTO ai_run (
         project_id,
         status,
         label_field,
         scope_type,
         training_feature_count,
         eligible_feature_count,
         excluded_feature_count,
         selected_model,
         started_by,
         metadata
       )
       VALUES (
         $1,
         'running',
         'L4_descr',
         'project',
         12,
         12,
         0,
         'gradient_boosting',
         $2,
         '{}'::jsonb
       )
       RETURNING id`,
      [project.id, admin.user.id],
    );
    const runId = runResult.rows[0].id;

    const response = await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/callback`)
      .set('X-AI-Callback-Secret', 'test-ai-callback-secret')
      .send({
        run_id: runId,
        project_id: project.id,
        status: 'failed',
        stage: 'insertion_failed',
        progress: 1,
        message: rawGeometryFailure,
        error: {
          message: rawGeometryFailure,
          tail: [rawGeometryFailure],
        },
      })
      .expect(200);

    const safeMessage =
      'AI result insertion failed because some generated polygons were invalid. Please retry after processing cleanup.';
    expect(response.body.data).toEqual(
      expect.objectContaining({
        status: 'failed',
        stage: 'insertion_failed',
        progress: 0.96,
        message: safeMessage,
        failure_reason: safeMessage,
        error: expect.objectContaining({
          code: 'AI_GEOMETRY_INSERTION_FAILED',
          message: safeMessage,
        }),
      }),
    );
    expect(JSON.stringify(response.body.data)).not.toContain('Failing row contains');

    const storedFailure = await pool.query(
      `SELECT message,
              failure_reason,
              error_details->>'message' AS public_message,
              error_details->>'technical_message' AS technical_message
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(storedFailure.rows[0]).toEqual(
      expect.objectContaining({
        message: safeMessage,
        failure_reason: safeMessage,
        public_message: safeMessage,
      }),
    );
    expect(storedFailure.rows[0].technical_message).toContain(
      'chk_ai_prediction_feature_geom_valid',
    );
  });

  test('callback URL falls back to APP_PUBLIC_API_URL when AI_CALLBACK_BASE_URL is missing', async () => {
    const { admin, project } = await createStartableAiProjectFixture('AI Callback Fallback');
    delete process.env.AI_CALLBACK_BASE_URL;
    process.env.APP_PUBLIC_API_URL = 'http://public-api.test';

    const response = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_feature_extraction',
      })
      .expect(201);

    const startCall = global.fetch.mock.calls.find(
      ([url]) => String(url) === 'http://ai-server.test/api/runs/start',
    );
    expect(startCall).toBeTruthy();
    const startPayload = JSON.parse(String(startCall[1].body));
    expect(startPayload.callback_url).toBe(
      `http://public-api.test/api/v1/ai/runs/${response.body.data.id}/callback`,
    );
  });

  test('protected super-admin can preview registered AI GeoJSON layer features only', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Preview');
    const storagePath = await writePreviewGeoJson();
    const { layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath,
    });
    const featureCountBefore = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );

    const response = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?zoom=12`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(response.body.data.layer.layer_type).toBe('classification');
    expect(response.body.data.layer.status).toBe('ready_for_review');
    expect(response.body.data.layer.viewer_published).toBe(false);
    expect(response.body.data.feature_count).toBe(1);
    expect(response.body.data.total_count).toBe(1);
    expect(response.body.data.matching_feature_count).toBe(1);
    expect(response.body.data.visible_count).toBe(1);
    expect(response.body.data.returned_feature_count).toBe(1);
    expect(response.body.data.returned_count).toBe(1);
    expect(response.body.data.capped).toBe(false);
    expect(response.body.data.cap).toBe(1800);
    expect(response.body.data.detail).toBe('overview');
    expect(response.body.data.geometry_mode).toBe('simplified');
    expect(response.body.data.optimized_preview).toBe(true);
    expect(response.body.data.class_counts).toEqual({ olives: 1 });
    expect(response.body.data.geometry_types).toEqual(['Polygon']);
    expect(response.body.data.feature_collection.type).toBe('FeatureCollection');
    expect(response.body.data.feature_collection.features[0].geometry.type).toBe('Polygon');
    expect(response.body.data.feature_collection.features[0].properties).toEqual(
      expect.objectContaining({
        predicted_class: 'olives',
        confidence: 0.82,
        model_name: 'random_forest',
        source: 'ai_prediction',
      }),
    );

    const fullResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(fullResponse.body.data.detail).toBe('full');
    expect(fullResponse.body.data.geometry_mode).toBe('full');
    expect(fullResponse.body.data.optimized_preview).toBe(false);
    expect(fullResponse.body.data.feature_collection.features[0].geometry.type).toBe('Polygon');

    const aggregateResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?zoom=8&geometry=aggregate`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(aggregateResponse.body.data.detail).toBe('overview');
    expect(aggregateResponse.body.data.geometry_mode).toBe('aggregate');
    expect(aggregateResponse.body.data.total_count).toBe(1);
    expect(aggregateResponse.body.data.visible_count).toBe(1);
    expect(aggregateResponse.body.data.returned_count).toBe(1);
    expect(aggregateResponse.body.data.feature_collection.features[0].geometry.type).toBe('Point');
    expect(aggregateResponse.body.data.feature_collection.features[0].properties).toEqual(
      expect.objectContaining({
        aggregate: true,
        aggregate_count: 1,
        dominant_class: 'olives',
      }),
    );

    const outsideBoundsResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?bounds=35.7,33.8,35.8,33.9`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(outsideBoundsResponse.body.data.feature_count).toBe(1);
    expect(outsideBoundsResponse.body.data.total_count).toBe(1);
    expect(outsideBoundsResponse.body.data.matching_feature_count).toBe(0);
    expect(outsideBoundsResponse.body.data.visible_count).toBe(0);
    expect(outsideBoundsResponse.body.data.returned_feature_count).toBe(0);
    expect(outsideBoundsResponse.body.data.capped).toBe(false);

    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=everything`)
      .set(authHeader(admin.token))
      .expect(400);
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?bounds=bad`)
      .set(authHeader(admin.token))
      .expect(400);

    const featureCountAfter = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    expect(featureCountAfter.rows[0].count).toBe(featureCountBefore.rows[0].count);
  });

  test('AI layer preview reports caps without changing total counts', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Preview Caps');
    const features = ['olives', 'fruit trees', 'citrus fruit trees'].map((label, index) => ({
      type: 'Feature',
      properties: {
        predicted_class: label,
        confidence: 0.7 + index / 100,
        model_name: 'random_forest',
        source: 'ai_prediction',
        run_id: 'phase-o-cap-test',
      },
      geometry: {
        type: 'Polygon',
        coordinates: [
          [
            [35.2 + index / 100, 33.2],
            [35.205 + index / 100, 33.2],
            [35.205 + index / 100, 33.205],
            [35.2 + index / 100, 33.205],
            [35.2 + index / 100, 33.2],
          ],
        ],
      },
    }));
    const storagePath = await writePreviewGeoJson(
      'outputs/runs/phase-o-test/ai_classification_many.geojson',
      features,
    );
    const { layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath,
    });

    const cappedResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&limit=1`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(cappedResponse.body.data.total_count).toBe(3);
    expect(cappedResponse.body.data.visible_count).toBe(3);
    expect(cappedResponse.body.data.returned_count).toBe(1);
    expect(cappedResponse.body.data.cap).toBe(1);
    expect(cappedResponse.body.data.capped).toBe(true);
    expect(cappedResponse.body.data.pagination).toEqual({
      page: 1,
      limit: 1,
      total: 3,
      pages: 3,
      has_more: true,
    });
    expect(cappedResponse.body.data.feature_collection.features[0].geometry.type).toBe('Polygon');
    expect(cappedResponse.body.data.class_counts).toEqual({
      olives: 1,
      'fruit trees': 1,
      'citrus fruit trees': 1,
    });

    const secondPageResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&limit=1&page=2`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(secondPageResponse.body.data.total_count).toBe(3);
    expect(secondPageResponse.body.data.visible_count).toBe(3);
    expect(secondPageResponse.body.data.returned_count).toBe(1);
    expect(secondPageResponse.body.data.pagination).toEqual({
      page: 2,
      limit: 1,
      total: 3,
      pages: 3,
      has_more: true,
    });
    expect(
      secondPageResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('fruit trees');

    const classFilterResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&class_label=citrus%20fruit%20trees&limit=20`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(classFilterResponse.body.data.total_count).toBe(3);
    expect(classFilterResponse.body.data.visible_count).toBe(1);
    expect(classFilterResponse.body.data.returned_count).toBe(1);
    expect(classFilterResponse.body.data.pagination).toEqual({
      page: 1,
      limit: 20,
      total: 1,
      pages: 1,
      has_more: false,
    });
    expect(
      classFilterResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('citrus fruit trees');

    const searchResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&q=fruit&limit=1`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(searchResponse.body.data.total_count).toBe(3);
    expect(searchResponse.body.data.visible_count).toBe(2);
    expect(searchResponse.body.data.returned_count).toBe(1);
    expect(searchResponse.body.data.pagination).toEqual({
      page: 1,
      limit: 1,
      total: 2,
      pages: 2,
      has_more: true,
    });

    const hiddenReferenceLabelStoragePath = await writePreviewGeoJson(
      'outputs/runs/phase-o-test/ai_classification_reference_labels.geojson',
      [
        {
          type: 'Feature',
          properties: {
            source_feature_id: 'exact-citrus-reference',
            predicted_class: 'olives',
            L4_descr: 'citrus fruit trees',
            model_name: 'random_forest',
          },
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [35.7, 33.3],
                [35.705, 33.3],
                [35.705, 33.305],
                [35.7, 33.305],
                [35.7, 33.3],
              ],
            ],
          },
        },
        {
          type: 'Feature',
          properties: {
            source_feature_id: 'exact-citrus-prediction',
            predicted_class: 'citrus fruit trees',
            L4_descr: 'olives',
            model_name: 'random_forest',
          },
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [35.71, 33.3],
                [35.715, 33.3],
                [35.715, 33.305],
                [35.71, 33.305],
                [35.71, 33.3],
              ],
            ],
          },
        },
      ],
    );
    const { layerId: hiddenReferenceLayerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath: hiddenReferenceLabelStoragePath,
    });
    const citrusSearchResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${hiddenReferenceLayerId}/features?detail=full&geometry=full&q=citr&limit=20`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(citrusSearchResponse.body.data.total_count).toBe(2);
    expect(citrusSearchResponse.body.data.visible_count).toBe(1);
    expect(
      citrusSearchResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('citrus fruit trees');

    const exactFeatureResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${hiddenReferenceLayerId}/features?detail=full&geometry=full&feature_id=exact-citrus-reference&limit=1`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(exactFeatureResponse.body.data.visible_count).toBe(1);
    expect(exactFeatureResponse.body.data.feature_collection.features[0].id).toBe(
      'exact-citrus-reference',
    );
    expect(
      exactFeatureResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('olives');
  });

  test('AI prediction endpoint loads database prediction rows with filters and stable counts', async () => {
    const { admin, project } = await createProjectFixture('AI DB Predictions');
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath: 'outputs/runs/phase-r-test/../unsafe.geojson',
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'prediction-olives-high',
      predictedClass: 'olives',
      confidence: 0.91,
      uncertaintyScore: 0.09,
      lon: 35.2,
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'prediction-citrus-low',
      predictedClass: 'citrus fruit trees',
      confidence: 0.58,
      uncertaintyScore: 0.42,
      lon: 35.24,
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'prediction-fruit-mid',
      predictedClass: 'fruit trees',
      confidence: 0.74,
      uncertaintyScore: 0.26,
      lon: 35.28,
    });
    const spatialFeatureCountBefore = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );

    const filteredResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${layerId}/predictions?detail=full&geometry=full&confidence_min=0.7&confidence_max=0.8`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(filteredResponse.body.data.layer).toEqual(
      expect.objectContaining({
        id: layerId,
        status: 'ready_for_review',
        viewer_published: false,
        source: 'ai_prediction_feature',
      }),
    );
    expect(filteredResponse.body.data.layer.storage_path).toBeUndefined();
    expect(filteredResponse.body.data.total_count).toBe(1);
    expect(filteredResponse.body.data.visible_count).toBe(1);
    expect(filteredResponse.body.data.returned_count).toBe(1);
    expect(filteredResponse.body.data.class_counts).toEqual({
      'fruit trees': 1,
    });
    expect(filteredResponse.body.data.count_semantics).toBe(
      'authoritative_database_total_excludes_viewport_bounds',
    );
    expect(filteredResponse.body.data.feature_collection.features[0]).toEqual(
      expect.objectContaining({
        id: 'prediction-fruit-mid',
        properties: expect.objectContaining({
          prediction_feature_id: expect.any(String),
          artifact_feature_id: 'prediction-fruit-mid',
          predicted_class: 'fruit trees',
          confidence: 0.74,
          uncertainty_score: 0.26,
          source: 'ai_prediction',
          not_official_field_data: true,
          no_spatial_feature_writes: true,
        }),
      }),
    );

    const uncertaintyResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/predictions?uncertainty_min=0.4`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(uncertaintyResponse.body.data.total_count).toBe(1);
    expect(uncertaintyResponse.body.data.visible_count).toBe(1);
    expect(
      uncertaintyResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('citrus fruit trees');

    const compatibilityResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?feature_id=prediction-olives-high`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(compatibilityResponse.body.data.source).toBe('ai_prediction_feature');
    expect(compatibilityResponse.body.data.total_count).toBe(1);
    expect(compatibilityResponse.body.data.visible_count).toBe(1);

    const boundedResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${layerId}/predictions?bounds=35.19,33.19,35.22,33.22&detail=full&geometry=full`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(boundedResponse.body.data.total_count).toBe(3);
    expect(boundedResponse.body.data.visible_count).toBe(1);
    expect(boundedResponse.body.data.returned_count).toBe(1);
    expect(boundedResponse.body.data.loaded_feature_count).toBe(1);
    expect(
      boundedResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('olives');

    const spatialFeatureCountAfter = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    expect(spatialFeatureCountAfter.rows[0].count).toBe(spatialFeatureCountBefore.rows[0].count);
  });

  test('published AI prediction permissions expose only published database predictions', async () => {
    const { admin, project } = await createProjectFixture('AI DB Prediction Permissions');
    await enableProjectAiSettings({ projectId: project.id, userId: admin.user.id });
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'approved',
      storagePath: 'outputs/runs/phase-r-test/missing-file.geojson',
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'published-db-prediction',
      status: 'approved',
      confidence: 0.88,
    });
    const viewer = await createViewerToken();
    const normalAdmin = await createAdminUser({
      fullName: 'Normal DB Prediction Admin',
      emailPrefix: 'normal-db-prediction-admin',
    });
    const beforeFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );

    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/predictions`)
      .set(authHeader(viewer.token))
      .expect(403);
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/predictions`)
      .set(authHeader(normalAdmin.token))
      .expect(403);

    await request(app)
      .post(`${API_PREFIX}/ai/layers/${layerId}/publish`)
      .set(authHeader(admin.token))
      .expect(200);

    const viewerResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/predictions?detail=full&geometry=full`)
      .set(authHeader(viewer.token))
      .expect(200);
    expect(viewerResponse.body.data.layer).toEqual(
      expect.objectContaining({
        id: layerId,
        status: 'published',
        viewer_published: true,
      }),
    );
    expect(viewerResponse.body.data.layer.storage_path).toBeUndefined();
    expect(viewerResponse.body.data.total_count).toBe(1);
    expect(viewerResponse.body.data.feature_collection.features[0].properties).toEqual(
      expect.objectContaining({
        source: 'ai_prediction',
        status: 'approved',
        not_official_field_data: true,
      }),
    );

    const projectResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/published-predictions`)
      .set(authHeader(viewer.token))
      .expect(200);
    expect(projectResponse.body.data.layers).toHaveLength(1);
    expect(
      projectResponse.body.data.layers.every((layer) => layer.storage_path === undefined),
    ).toBe(true);
    expect(projectResponse.body.data.total_count).toBe(1);
    expect(projectResponse.body.data.primary_layer_type).toBe('classification');
    expect(projectResponse.body.data.primary_prediction_count).toBe(1);
    expect(projectResponse.body.data.total_prediction_row_count).toBe(1);
    expect(projectResponse.body.data.layer_counts).toEqual(
      expect.objectContaining({
        classification: 1,
      }),
    );
    expect(projectResponse.body.data.layer.layer_type).toBe('classification');
    expect(projectResponse.body.data.feature_collection.features).toHaveLength(1);
    expect(projectResponse.body.data.class_counts).toEqual(
      expect.objectContaining({
        olives: 1,
      }),
    );

    await request(app)
      .post(`${API_PREFIX}/ai/layers/${layerId}/unpublish`)
      .set(authHeader(admin.token))
      .expect(200);
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/predictions`)
      .set(authHeader(viewer.token))
      .expect(403);

    const predictionStatus = await pool.query(
      `SELECT status FROM ai_prediction_feature WHERE ai_output_layer_id = $1`,
      [layerId],
    );
    expect(predictionStatus.rows[0].status).toBe('approved');
    const afterFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    expect(afterFeatureCount.rows[0].count).toBe(beforeFeatureCount.rows[0].count);
  });

  test('published AI predictions support direct contributor validation and admin promotion', async () => {
    const { admin, project } = await createProjectFixture('AI Direct Prediction Validation');
    await enableProjectAiSettings({ projectId: project.id, userId: admin.user.id });
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'ready_for_review',
    });
    await insertAiClassStatistic({ runId, classLabel: 'olives' });
    await insertAiClassStatistic({ runId, classLabel: 'citrus fruit trees' });
    const predictionId = await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'direct-validation-prediction',
      predictedClass: 'olives',
      confidence: 0.37,
    });
    const contributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-direct-validation-contributor',
    });
    const secondContributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-direct-validation-second',
    });
    const unassignedContributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-direct-validation-unassigned',
    });
    const viewer = await createViewerToken();
    await assignContributorToProject({
      projectId: project.id,
      userId: contributor.user.id,
      approvedBy: admin.user.id,
    });
    await assignContributorToProject({
      projectId: project.id,
      userId: secondContributor.user.id,
      approvedBy: admin.user.id,
    });

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validations`)
      .set(authHeader(contributor.token))
      .send({ validation_result: 'correct' })
      .expect(403);

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs/${runId}/publish`)
      .set(authHeader(admin.token))
      .expect(200);

    const detailsResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/runs/${runId}/predictions/${predictionId}`)
      .set(authHeader(contributor.token))
      .expect(200);
    expect(detailsResponse.body.data).toEqual(
      expect.objectContaining({
        published: true,
        can_validate: true,
        confidence_is_attribute: true,
        standalone_confidence_layer: false,
        standalone_uncertainty_layer: false,
        prediction: expect.objectContaining({
          id: predictionId,
          confidence: 0.37,
        }),
      }),
    );

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validations`)
      .set(authHeader(viewer.token))
      .send({ validation_result: 'correct' })
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validations`)
      .set(authHeader(admin.token))
      .send({ validation_result: 'correct' })
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validations`)
      .set(authHeader(unassignedContributor.token))
      .send({ validation_result: 'correct' })
      .expect(403);

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validations`)
      .set(authHeader(contributor.token))
      .send({ validation_result: 'correct' })
      .expect(201);
    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validations`)
      .set(authHeader(contributor.token))
      .send({ validation_result: 'correct' })
      .expect(409);
    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validations`)
      .set(authHeader(secondContributor.token))
      .send({
        validation_result: 'incorrect',
        corrected_class: 'citrus fruit trees',
        note: 'Boundary includes citrus trees.',
      })
      .expect(201);

    const summaryResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/runs/${runId}/validation-summary`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(summaryResponse.body.data).toEqual(
      expect.objectContaining({
        total_ai_features: 1,
        published_features: 1,
        contributor_validations_submitted: 2,
        features_validated_by_contributor: 1,
        confidence_threshold_filters_validation: false,
      }),
    );

    const reviewResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/admin-review`)
      .set(authHeader(admin.token))
      .send({
        approval_status: 'approved',
        approved_class: 'citrus fruit trees',
        admin_note: 'Admin field review accepted contributor correction.',
      })
      .expect(200);
    const promotedFeatureId =
      reviewResponse.body.data.admin_review.promoted_spatial_feature_id;
    expect(promotedFeatureId).toEqual(expect.any(String));

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/admin-review`)
      .set(authHeader(admin.token))
      .send({
        approval_status: 'approved',
        approved_class: 'citrus fruit trees',
      })
      .expect(200);

    const promotedResult = await pool.query(
      `SELECT id,
              source,
              ai_prediction_feature_id,
              ai_run_id,
              ai_predicted_class,
              ai_confidence,
              ai_validated,
              ai_validation_status,
              use_for_future_training,
              promoted_from_ai,
              attributes
       FROM spatial_feature
       WHERE project_id = $1
         AND ai_prediction_feature_id = $2`,
      [project.id, predictionId],
    );
    expect(promotedResult.rows).toHaveLength(1);
    expect(promotedResult.rows[0]).toEqual(
      expect.objectContaining({
        id: promotedFeatureId,
        source: 'ai',
        ai_prediction_feature_id: predictionId,
        ai_run_id: runId,
        ai_predicted_class: 'olives',
        ai_confidence: 0.37,
        ai_validated: true,
        ai_validation_status: 'admin_approved',
        use_for_future_training: true,
        promoted_from_ai: true,
        attributes: expect.objectContaining({
          L4_descr: 'citrus fruit trees',
          source: 'ai',
          aiPredictionId: predictionId,
          aiPredictedClass: 'olives',
          aiApprovedClass: 'citrus fruit trees',
          useForFutureTraining: true,
          promotedFromAi: true,
        }),
      }),
    );
  });

  test('AI validation photos are normalized, audited, and retained coherently on batch failure', async () => {
    const { admin, project } = await createProjectFixture('AI Validation Photo Intake');
    await enableProjectAiSettings({ projectId: project.id, userId: admin.user.id });
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'ready_for_review',
    });
    const predictionId = await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'validation-photo-intake',
    });
    const contributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-validation-photo-contributor',
    });
    await assignContributorToProject({
      projectId: project.id,
      userId: contributor.user.id,
      approvedBy: admin.user.id,
    });
    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs/${runId}/publish`)
      .set(authHeader(admin.token))
      .expect(200);

    const validImage = await sharp({
      create: {
        width: 24,
        height: 16,
        channels: 4,
        background: { r: 20, g: 100, b: 180, alpha: 0.8 },
      },
    })
      .png()
      .toBuffer();
    const cleanupPaths = [];

    try {
      await request(app)
        .post(
          `${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validation-photos`,
        )
        .set(authHeader(contributor.token))
        .attach('photos', validImage, {
          filename: 'batch-valid.png',
          contentType: 'image/png',
        })
        .attach('photos', Buffer.from('<script>not an image</script>'), {
          filename: 'batch-invalid.png',
          contentType: 'image/png',
        })
        .expect(422);

      const rejectedBatch = await pool.query(
        `SELECT original_filename, storage_path, released_path, scan_status, disposition, reason_code
         FROM upload_quarantine_record
         WHERE uploaded_by_user_id = $1
           AND upload_kind = 'ai_validation_photo'
           AND original_filename = ANY($2::text[])
         ORDER BY original_filename`,
        [contributor.user.id, ['batch-valid.png', 'batch-invalid.png']],
      );
      expect(
        rejectedBatch.rows.map(
          ({ storage_path: _storagePath, released_path: _releasedPath, ...record }) => record,
        ),
      ).toEqual([
        {
          original_filename: 'batch-invalid.png',
          scan_status: 'skipped',
          disposition: 'quarantined',
          reason_code: 'UPLOAD_IMAGE_CONTENT_REJECTED',
        },
        {
          original_filename: 'batch-valid.png',
          scan_status: 'skipped',
          disposition: 'quarantined',
          reason_code: 'UPLOAD_BATCH_ABORTED',
        },
      ]);
      cleanupPaths.push(...rejectedBatch.rows.map((row) => row.storage_path));

      const successfulUpload = await request(app)
        .post(
          `${API_PREFIX}/projects/${project.id}/ai/predictions/${predictionId}/validation-photos`,
        )
        .set(authHeader(contributor.token))
        .attach('photos', validImage, {
          filename: 'released-evidence.png',
          contentType: 'image/png',
        })
        .expect(201);
      expect(successfulUpload.body.data.photos).toEqual([
        expect.objectContaining({
          file_name: 'released-evidence.png',
          mime_type: 'image/jpeg',
        }),
      ]);

      const releasedRecord = await pool.query(
        `SELECT storage_path, released_path, scan_status, disposition, reason_code
         FROM upload_quarantine_record
         WHERE uploaded_by_user_id = $1
           AND upload_kind = 'ai_validation_photo'
           AND original_filename = 'released-evidence.png'`,
        [contributor.user.id],
      );
      expect(releasedRecord.rows).toHaveLength(1);
      expect(releasedRecord.rows[0]).toEqual(
        expect.objectContaining({
          scan_status: 'skipped',
          disposition: 'released',
          reason_code: null,
          released_path: expect.stringMatching(/\.jpg$/),
        }),
      );
      const releasedLocation = storageAdapter.resolve(
        releasedRecord.rows[0].released_path,
        ['uploads'],
      );
      expect(releasedLocation).not.toBeNull();
      cleanupPaths.push(releasedRecord.rows[0].storage_path, releasedLocation.localPath);
      await expect(sharp(releasedLocation.localPath).metadata()).resolves.toEqual(
        expect.objectContaining({ format: 'jpeg' }),
      );
    } finally {
      await Promise.all(cleanupPaths.map((filePath) => fs.rm(filePath, { force: true })));
    }
  });

  test('AI prediction validation generation creates all-prediction tasks idempotently without spatial_feature writes', async () => {
    const { admin, project } = await createProjectFixture('AI Prediction Validation Generate');
    const tableCheck = await pool.query(
      `SELECT to_regclass('public.ai_prediction_validation_task') AS task_table,
              to_regclass('public.ai_prediction_validation_submission') AS submission_table`,
    );
    expect(tableCheck.rows[0]).toEqual(
      expect.objectContaining({
        task_table: 'ai_prediction_validation_task',
        submission_table: 'ai_prediction_validation_submission',
      }),
    );

    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'classification-high-confidence',
      confidence: 0.91,
      uncertaintyScore: 0.09,
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'classification-low-confidence',
      confidence: 0.52,
      uncertaintyScore: 0.48,
    });
    const beforeSpatialFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    const beforePredictionFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM ai_prediction_feature',
    );

    const firstGenerate = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/prediction-validation-tasks/generate`)
      .set(authHeader(admin.token))
      .send({ ai_run_id: runId })
      .expect(201);

    expect(firstGenerate.body.data).toEqual(
      expect.objectContaining({
        candidate_count: 2,
        created_count: 2,
        existing_active_count: 0,
        candidate_layer_type: 'classification',
        criterion: 'all_predictions',
        no_spatial_feature_writes: true,
      }),
    );
    expect(firstGenerate.body.data.task_ids).toHaveLength(2);

    const secondGenerate = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/prediction-validation-tasks/generate`)
      .set(authHeader(admin.token))
      .send({ ai_run_id: runId })
      .expect(201);
    expect(secondGenerate.body.data).toEqual(
      expect.objectContaining({
        candidate_count: 2,
        created_count: 0,
        existing_active_count: 2,
      }),
    );

    const listResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/prediction-validation-tasks`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(listResponse.body.data.status_counts.open).toBe(2);
    expect(listResponse.body.data.tasks).toHaveLength(2);
    expect(listResponse.body.data.tasks[0]).toEqual(
      expect.objectContaining({
        status: 'open',
        not_official_field_data: true,
        no_spatial_feature_writes: true,
        prediction: expect.objectContaining({
          source: 'ai_prediction',
          layer: expect.objectContaining({
            layer_type: 'classification',
          }),
        }),
      }),
    );

    const afterSpatialFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    const afterPredictionFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM ai_prediction_feature',
    );
    expect(afterSpatialFeatureCount.rows[0].count).toBe(beforeSpatialFeatureCount.rows[0].count);
    expect(afterPredictionFeatureCount.rows[0].count).toBe(
      beforePredictionFeatureCount.rows[0].count,
    );
  });

  test('AI prediction validation permissions expose project tasks to assigned contributors', async () => {
    const { admin, project } = await createProjectFixture('AI Prediction Validation RBAC');
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'validation-rbac-low-1',
      confidence: 0.51,
      uncertaintyScore: 0.49,
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'validation-rbac-low-2',
      predictedClass: 'citrus fruit trees',
      confidence: 0.42,
      uncertaintyScore: 0.58,
      lon: 35.3,
    });
    const contributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-validation-assigned-contributor',
    });
    const otherContributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-validation-other-contributor',
    });
    await assignContributorToProject({
      projectId: project.id,
      userId: contributor.user.id,
      approvedBy: admin.user.id,
    });
    await assignContributorToProject({
      projectId: project.id,
      userId: otherContributor.user.id,
      approvedBy: admin.user.id,
    });
    const viewer = await createViewerToken();

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/prediction-validation-tasks/generate`)
      .set(authHeader(admin.token))
      .send({ ai_run_id: runId, confidence_threshold: 0.6 })
      .expect(201);
    const taskResult = await pool.query(
      `SELECT id
       FROM ai_prediction_validation_task
       WHERE project_id = $1
       ORDER BY created_at ASC`,
      [project.id],
    );
    const assignedTaskId = taskResult.rows[0].id;
    const unassignedTaskId = taskResult.rows[1].id;

    await request(app)
      .patch(`${API_PREFIX}/ai/prediction-validation-tasks/${assignedTaskId}/assign`)
      .set(authHeader(admin.token))
      .send({ assigned_to: contributor.user.id })
      .expect(200);

    await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/prediction-validation-tasks`)
      .set(authHeader(viewer.token))
      .expect(403);
    await request(app)
      .get(`${API_PREFIX}/me/ai-validation-tasks`)
      .set(authHeader(viewer.token))
      .expect(403);
    await request(app)
      .patch(`${API_PREFIX}/ai/prediction-validation-tasks/${assignedTaskId}/assign`)
      .set(authHeader(contributor.token))
      .send({ assigned_to: otherContributor.user.id })
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${assignedTaskId}/review`)
      .set(authHeader(contributor.token))
      .send({ decision: 'accepted' })
      .expect(403);

    const assignedList = await request(app)
      .get(`${API_PREFIX}/me/ai-validation-tasks`)
      .set(authHeader(contributor.token))
      .expect(200);
    expect(assignedList.body.data.tasks.map((task) => task.id)).toEqual(
      expect.arrayContaining([assignedTaskId, unassignedTaskId]),
    );

    await request(app)
      .get(`${API_PREFIX}/ai/prediction-validation-tasks/${assignedTaskId}`)
      .set(authHeader(contributor.token))
      .expect(200);
    await request(app)
      .get(`${API_PREFIX}/ai/prediction-validation-tasks/${unassignedTaskId}`)
      .set(authHeader(contributor.token))
      .expect(200);

    const otherList = await request(app)
      .get(`${API_PREFIX}/me/ai-validation-tasks`)
      .set(authHeader(otherContributor.token))
      .expect(200);
    expect(otherList.body.data.tasks.map((task) => task.id)).toEqual([unassignedTaskId]);

    const otherProjectFixture = await createProjectFixture('AI Validation Other Project', {
      protectedSuperAdmin: false,
    });
    const { runId: otherRunId, layerId: otherLayerId } = await createPreviewableAiLayer({
      projectId: otherProjectFixture.project.id,
      userId: otherProjectFixture.admin.user.id,
    });
    await insertAiPredictionFeature({
      projectId: otherProjectFixture.project.id,
      runId: otherRunId,
      layerId: otherLayerId,
      artifactFeatureId: 'validation-rbac-other-project',
      confidence: 0.41,
      uncertaintyScore: 0.59,
      lon: 35.4,
    });
    await request(app)
      .post(
        `${API_PREFIX}/projects/${otherProjectFixture.project.id}/ai/prediction-validation-tasks/generate`,
      )
      .set(authHeader(otherProjectFixture.admin.token))
      .send({ ai_run_id: otherRunId, confidence_threshold: 0.6 })
      .expect(201);
    const otherProjectTaskResult = await pool.query(
      `SELECT id
       FROM ai_prediction_validation_task
       WHERE project_id = $1
       LIMIT 1`,
      [otherProjectFixture.project.id],
    );
    await request(app)
      .get(`${API_PREFIX}/ai/prediction-validation-tasks/${otherProjectTaskResult.rows[0].id}`)
      .set(authHeader(contributor.token))
      .expect(403);
  });

  test('AI prediction validation submissions require eligible classes and review without auto-approval', async () => {
    const { admin, project } = await createProjectFixture('AI Prediction Validation Submit');
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
    });
    await insertAiClassStatistic({ runId, classLabel: 'olives' });
    await insertAiClassStatistic({ runId, classLabel: 'citrus fruit trees' });
    const firstPredictionId = await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'validation-submit-low-1',
      confidence: 0.51,
      uncertaintyScore: 0.49,
    });
    await insertAiPredictionFeature({
      projectId: project.id,
      runId,
      layerId,
      artifactFeatureId: 'validation-submit-low-2',
      predictedClass: 'citrus fruit trees',
      confidence: 0.42,
      uncertaintyScore: 0.58,
      lon: 35.31,
    });
    const contributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-validation-submit-contributor',
    });
    const secondContributor = await createContributorToken({
      adminToken: admin.token,
      emailPrefix: 'ai-validation-submit-second-contributor',
    });
    await assignContributorToProject({
      projectId: project.id,
      userId: contributor.user.id,
      approvedBy: admin.user.id,
    });
    await assignContributorToProject({
      projectId: project.id,
      userId: secondContributor.user.id,
      approvedBy: admin.user.id,
    });

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/prediction-validation-tasks/generate`)
      .set(authHeader(admin.token))
      .send({
        ai_prediction_feature_id: firstPredictionId,
        priority: 3,
      })
      .expect(201);
    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/prediction-validation-tasks/generate`)
      .set(authHeader(admin.token))
      .send({ ai_run_id: runId, confidence_threshold: 0.6 })
      .expect(201);

    const taskResult = await pool.query(
      `SELECT id, ai_prediction_feature_id
       FROM ai_prediction_validation_task
       WHERE project_id = $1
       ORDER BY priority DESC, created_at ASC`,
      [project.id],
    );
    const reviewedTaskId = taskResult.rows[0].id;
    const notTargetTaskId = taskResult.rows.find(
      (row) => row.ai_prediction_feature_id !== firstPredictionId,
    ).id;

    await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${reviewedTaskId}/submissions`)
      .set(authHeader(contributor.token))
      .send({ result: 'wrong_class', note: 'Observed in the field.' })
      .expect(400);
    await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${reviewedTaskId}/submissions`)
      .set(authHeader(contributor.token))
      .send({
        result: 'wrong_class',
        corrected_class: 'banana',
        note: 'Observed a different trained class.',
      })
      .expect(400);

    const pendingFeatureId = await insertPendingSpatialFeature({
      projectId: project.id,
      userId: contributor.user.id,
    });
    const beforeSpatialFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    const beforePredictionFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM ai_prediction_feature',
    );

    const submitResponse = await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${reviewedTaskId}/submissions`)
      .set(authHeader(contributor.token))
      .send({
        result: 'wrong_class',
        corrected_class: 'citrus fruit trees',
        note: 'Field check found citrus fruit trees, not olives.',
        evidence: { field_visit: true },
        linked_feature_id: pendingFeatureId,
      })
      .expect(201);
    expect(submitResponse.body.data).toEqual(
      expect.objectContaining({
        submission_id: expect.any(String),
        no_spatial_feature_writes: true,
        no_auto_approval: true,
      }),
    );
    expect(submitResponse.body.data.task).toEqual(
      expect.objectContaining({
        status: 'submitted',
        latest_submission: expect.objectContaining({
          result: 'wrong_class',
          corrected_class: 'citrus fruit trees',
          linked_feature_id: pendingFeatureId,
        }),
      }),
    );

    await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${reviewedTaskId}/submissions`)
      .set(authHeader(contributor.token))
      .send({
        result: 'wrong_class',
        corrected_class: 'citrus fruit trees',
        note: 'Duplicate active evidence should be blocked.',
      })
      .expect(409);

    const secondSubmitResponse = await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${reviewedTaskId}/submissions`)
      .set(authHeader(secondContributor.token))
      .send({
        result: 'wrong_class',
        corrected_class: 'citrus fruit trees',
        note: 'Second project contributor confirmed the same correction.',
      })
      .expect(201);
    expect(secondSubmitResponse.body.data.task.latest_submission).toEqual(
      expect.objectContaining({
        result: 'wrong_class',
        corrected_class: 'citrus fruit trees',
      }),
    );

    const reviewResponse = await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${reviewedTaskId}/review`)
      .set(authHeader(admin.token))
      .send({
        decision: 'accepted',
        reason: 'Contributor evidence is clear.',
        submission_id: submitResponse.body.data.submission_id,
      })
      .expect(200);
    expect(reviewResponse.body.data.task).toEqual(
      expect.objectContaining({
        status: 'accepted',
        review_decision: 'accepted',
        review_reason: 'Contributor evidence is clear.',
      }),
    );
    expect(reviewResponse.body.data).toEqual(
      expect.objectContaining({
        linked_spatial_feature_id: pendingFeatureId,
        no_spatial_feature_writes: false,
        no_auto_approval: false,
      }),
    );

    await request(app)
      .post(`${API_PREFIX}/ai/prediction-validation-tasks/${notTargetTaskId}/submissions`)
      .set(authHeader(contributor.token))
      .send({
        result: 'not_target_class',
        note: 'This area is not part of the target class set.',
        evidence: { field_visit: true },
      })
      .expect(201);

    const pendingFeatureStatus = await pool.query(
      `SELECT status, source, attributes
       FROM spatial_feature
       WHERE id = $1`,
      [pendingFeatureId],
    );
    const predictionStatus = await pool.query(
      `SELECT status, metadata
       FROM ai_prediction_feature
       WHERE id = $1`,
      [firstPredictionId],
    );
    const afterSpatialFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    const afterPredictionFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM ai_prediction_feature',
    );
    expect(pendingFeatureStatus.rows[0]).toEqual(
      expect.objectContaining({
        status: 'approved',
        source: 'ai',
        attributes: expect.objectContaining({
          L4_descr: 'citrus fruit trees',
          source: 'ai',
          aiPredictionId: firstPredictionId,
          aiPredictedClass: 'olives',
          aiCorrectedClass: 'citrus fruit trees',
          aiValidated: true,
          aiValidationStatus: 'corrected',
          useForFutureTraining: true,
        }),
      }),
    );
    expect(predictionStatus.rows[0]).toEqual(
      expect.objectContaining({
        status: 'approved',
        metadata: expect.objectContaining({
          ai_validated: true,
          ai_validation_status: 'corrected',
          linked_spatial_feature_id: pendingFeatureId,
          use_for_future_training: true,
        }),
      }),
    );
    expect(afterSpatialFeatureCount.rows[0].count).toBe(beforeSpatialFeatureCount.rows[0].count);
    expect(afterPredictionFeatureCount.rows[0].count).toBe(
      beforePredictionFeatureCount.rows[0].count,
    );
  });

  test('AI layer preview denies non-protected users and unsafe artifact paths', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Preview Safety');
    const storagePath = await writePreviewGeoJson();
    const { layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath,
    });
    const normalAdmin = await createAdminUser({
      fullName: 'Normal AI Admin',
      emailPrefix: 'normal-ai-admin',
    });
    const viewer = await createViewerToken();

    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features`)
      .set(authHeader(normalAdmin.token))
      .expect(403);
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features`)
      .set(authHeader(viewer.token))
      .expect(403);

    const traversal = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath: 'outputs/runs/phase-o-test/../secret.geojson',
    });
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${traversal.layerId}/features`)
      .set(authHeader(admin.token))
      .expect(400);

    const statistics = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      layerType: 'statistics',
      storagePath: 'outputs/runs/phase-o-test/statistics_layer.json',
    });
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${statistics.layerId}/features`)
      .set(authHeader(admin.token))
      .expect(400);
  });

  test('protected super-admin publishes and unpublishes approved AI map layers without spatial_feature writes', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Publishing');
    await enableProjectAiSettings({ projectId: project.id, userId: admin.user.id });
    const storagePath = await writePreviewGeoJson(
      'outputs/runs/phase-p-test/ai_classification_review.geojson',
    );
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'approved',
      storagePath,
      withPrediction: true,
    });
    const viewer = await createViewerToken();
    const beforeFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );

    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features`)
      .set(authHeader(viewer.token))
      .expect(403);
    await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/published-layers`)
      .set(authHeader(viewer.token))
      .expect(200)
      .expect((response) => {
        expect(response.body.data).toEqual([]);
      });

    const publishResponse = await request(app)
      .post(`${API_PREFIX}/ai/layers/${layerId}/publish`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(publishResponse.body.data).toEqual(
      expect.objectContaining({
        id: layerId,
        project_id: project.id,
        layer_type: 'classification',
        status: 'published',
        storage_path: null,
        published_by: admin.user.id,
      }),
    );
    expect(publishResponse.body.data.published_at).toBeTruthy();

    const publishedLayersResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/published-layers`)
      .set(authHeader(viewer.token))
      .expect(200);
    expect(publishedLayersResponse.body.data).toEqual([
      expect.objectContaining({
        id: layerId,
        project_id: project.id,
        layer_type: 'classification',
        status: 'published',
        storage_path: null,
        published_by: admin.user.id,
      }),
    ]);

    const viewerFeaturesResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full`)
      .set(authHeader(viewer.token))
      .expect(200);
    expect(viewerFeaturesResponse.body.data.layer).toEqual(
      expect.objectContaining({
        id: layerId,
        status: 'published',
        viewer_published: true,
      }),
    );
    expect(viewerFeaturesResponse.body.data.feature_collection.features[0].properties).toEqual(
      expect.objectContaining({
        predicted_class: 'olives',
        source: 'ai_prediction',
      }),
    );

    const logAfterPublish = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/logs`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(logAfterPublish.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          message: 'AI output layer published for read-only viewer map access.',
          metadata: expect.objectContaining({
            phase: 'phase_p_publish',
            viewer_publication_enabled: true,
            spatial_feature_writes: false,
          }),
        }),
      ]),
    );

    const unpublishResponse = await request(app)
      .post(`${API_PREFIX}/ai/layers/${layerId}/unpublish`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(unpublishResponse.body.data).toEqual(
      expect.objectContaining({
        id: layerId,
        status: 'approved',
        published_at: null,
        published_by: null,
        storage_path: null,
      }),
    );

    await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/published-layers`)
      .set(authHeader(viewer.token))
      .expect(200)
      .expect((response) => {
        expect(response.body.data).toEqual([]);
      });
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features`)
      .set(authHeader(viewer.token))
      .expect(403);

    const afterFeatureCount = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    expect(afterFeatureCount.rows[0].count).toBe(beforeFeatureCount.rows[0].count);
  });

  test('AI layer publishing is protected and requires approved map layers', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Publish RBAC');
    await enableProjectAiSettings({ projectId: project.id, userId: admin.user.id });
    const draft = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'ready_for_review',
    });
    const approved = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'approved',
      storagePath: await writePreviewGeoJson(
        'outputs/runs/phase-p-test/rbac_classification.geojson',
      ),
      withPrediction: true,
    });
    const statistics = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      layerType: 'statistics',
      status: 'approved',
      storagePath: 'outputs/runs/phase-p-test/statistics.json',
    });
    const normalAdmin = await createAdminUser({
      fullName: 'Normal Publishing Admin',
      emailPrefix: 'normal-ai-publish-admin',
    });
    const viewer = await createViewerToken();

    await request(app)
      .post(`${API_PREFIX}/ai/layers/${approved.layerId}/publish`)
      .set(authHeader(normalAdmin.token))
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/ai/layers/${approved.layerId}/publish`)
      .set(authHeader(viewer.token))
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/ai/layers/${draft.layerId}/publish`)
      .set(authHeader(admin.token))
      .expect(409);
    await request(app)
      .post(`${API_PREFIX}/ai/layers/${statistics.layerId}/publish`)
      .set(authHeader(admin.token))
      .expect(400);
    await request(app)
      .post(`${API_PREFIX}/ai/layers/${approved.layerId}/unpublish`)
      .set(authHeader(admin.token))
      .expect(409);
  });

  test('published AI layers stay hidden while project AI is disabled', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Disabled Gate');
    const { layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'approved',
      storagePath: await writePreviewGeoJson('outputs/runs/phase-p-test/disabled_gate.geojson'),
      withPrediction: true,
    });
    const viewer = await createViewerToken();

    await request(app)
      .post(`${API_PREFIX}/ai/layers/${layerId}/publish`)
      .set(authHeader(admin.token))
      .expect(409);

    await enableProjectAiSettings({ projectId: project.id, userId: admin.user.id });
    await request(app)
      .post(`${API_PREFIX}/ai/layers/${layerId}/publish`)
      .set(authHeader(admin.token))
      .expect(200);

    await pool.query(
      `UPDATE ai_project_settings
       SET is_enabled = false
       WHERE project_id = $1`,
      [project.id],
    );

    await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/published-layers`)
      .set(authHeader(viewer.token))
      .expect(200)
      .expect((response) => {
        expect(response.body.data).toEqual([]);
      });
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features`)
      .set(authHeader(viewer.token))
      .expect(403);
  });

  test('RBAC allows only protected super-admin users without cross-project leaks', async () => {
    const first = await createProjectFixture('AI RBAC First');
    const second = await createProjectFixture('AI RBAC Second', {
      protectedSuperAdmin: false,
    });
    const viewer = await createViewerToken();
    const contributor = await createContributorToken({
      adminToken: first.admin.token,
      emailPrefix: 'ai-endpoint-rbac-contributor',
    });
    const assignedProjectAdmin = await createContributorToken({
      adminToken: second.admin.token,
      emailPrefix: 'ai-endpoint-project-admin',
    });

    await pool.query(
      `INSERT INTO project_assignment (project_id, user_id, role, status, approved_by_user_id, approved_date)
       VALUES ($1, $2, 'admin', 'approved', $3, CURRENT_DATE)
       ON CONFLICT (project_id, user_id)
       DO UPDATE SET role = 'admin', status = 'approved', approved_by_user_id = $3, approved_date = CURRENT_DATE`,
      [second.project.id, assignedProjectAdmin.user.id, second.admin.user.id],
    );

    await request(app)
      .get(`${API_PREFIX}/projects/${first.project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(viewer.token))
      .expect(403);

    await request(app)
      .post(`${API_PREFIX}/projects/${first.project.id}/ai/runs`)
      .set(authHeader(contributor.token))
      .send({ label_field: 'feature_type' })
      .expect(403);

    await request(app)
      .get(`${API_PREFIX}/projects/${second.project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(assignedProjectAdmin.token))
      .expect(403);

    await request(app)
      .get(`${API_PREFIX}/projects/${first.project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(second.admin.token))
      .expect(403);

    const runResponse = await request(app)
      .post(`${API_PREFIX}/projects/${first.project.id}/ai/runs`)
      .set(authHeader(first.admin.token))
      .send({
        status: 'draft',
        label_field: 'feature_type',
      })
      .expect(201);

    await request(app)
      .get(`${API_PREFIX}/ai/runs/${runResponse.body.data.id}`)
      .set(authHeader(assignedProjectAdmin.token))
      .expect(403);
  });
});

describe('AI result review phase I', () => {
  test('protected super-admin approves AI output for future publication without publishing or touching spatial_feature', async () => {
    const { admin, project } = await createProjectFixture('AI Review Approve');
    const { runId, layerId } = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });
    const beforeFeatureCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature`,
    );

    const response = await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(admin.token))
      .send({
        action: 'approve_for_publication',
        reason: 'Metrics look acceptable for future publishing review.',
      })
      .expect(200);

    expect(response.body.data.viewer_published).toBe(false);
    expect(response.body.data.decision).toEqual(
      expect.objectContaining({
        ai_run_id: runId,
        decision: 'approved_for_publish',
        reason: 'Metrics look acceptable for future publishing review.',
      }),
    );
    expect(response.body.data.run.metadata.review).toEqual(
      expect.objectContaining({
        action: 'approve_for_publication',
        review_status: 'approved_for_publication',
        layer_status: 'approved',
        viewer_publication_enabled: false,
        spatial_feature_writes: false,
      }),
    );

    const layerResult = await pool.query(
      `SELECT status, published_at, published_by
       FROM ai_output_layer
       WHERE id = $1`,
      [layerId],
    );
    expect(layerResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'approved',
        published_at: null,
        published_by: null,
      }),
    );

    const decisionsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/reviews`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(decisionsResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          decision: 'approved_for_publish',
          reason: 'Metrics look acceptable for future publishing review.',
        }),
      ]),
    );

    const logsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/logs`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(logsResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          message:
            'AI run approved for future publication. No viewer-facing AI layer was published.',
          metadata: expect.objectContaining({
            phase: 'phase_i_review',
            action: 'approve_for_publication',
            viewer_publication_enabled: false,
            spatial_feature_writes: false,
          }),
        }),
      ]),
    );

    const layersResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/layers`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(layersResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: layerId,
          status: 'approved',
          published_at: null,
          published_by: null,
        }),
      ]),
    );

    const afterFeatureCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature`,
    );
    expect(afterFeatureCount.rows[0].count).toBe(beforeFeatureCount.rows[0].count);
  });

  test('reject and request-more-data require reasons and keep AI layers unpublished', async () => {
    const { admin, project } = await createProjectFixture('AI Review Reject');
    const rejectable = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });
    const moreData = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${rejectable.runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'reject' })
      .expect(400);

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${rejectable.runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'reject', reason: 'Regional metrics are not acceptable yet.' })
      .expect(200);

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${moreData.runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'request_more_data', reason: 'Need more samples outside South Lebanon.' })
      .expect(200);

    const layerResult = await pool.query(
      `SELECT ai_run_id, status, published_at
       FROM ai_output_layer
       WHERE ai_run_id = ANY($1::uuid[])
       ORDER BY ai_run_id`,
      [[rejectable.runId, moreData.runId]],
    );
    expect(layerResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          ai_run_id: rejectable.runId,
          status: 'rejected',
          published_at: null,
        }),
        expect.objectContaining({
          ai_run_id: moreData.runId,
          status: 'draft',
          published_at: null,
        }),
      ]),
    );

    const decisionResult = await pool.query(
      `SELECT decision, reason
       FROM ai_review_decision
       WHERE ai_run_id = ANY($1::uuid[])
       ORDER BY decided_at DESC`,
      [[rejectable.runId, moreData.runId]],
    );
    expect(decisionResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          decision: 'rejected',
          reason: 'Regional metrics are not acceptable yet.',
        }),
        expect.objectContaining({
          decision: 'needs_more_data',
          reason: 'Need more samples outside South Lebanon.',
        }),
      ]),
    );
  });

  test('keep draft records a review decision and moves prepared layers back to draft', async () => {
    const { admin, project } = await createProjectFixture('AI Review Draft');
    const { runId, layerId } = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    const response = await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'keep_draft' })
      .expect(200);

    expect(response.body.data.decision.decision).toBe('keep_draft');
    expect(response.body.data.run.metadata.review.review_status).toBe('draft');

    const layerResult = await pool.query(
      `SELECT status, published_at
       FROM ai_output_layer
       WHERE id = $1`,
      [layerId],
    );
    expect(layerResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'draft',
        published_at: null,
      }),
    );
  });

  test('keep draft unpublishes previously published AI map layers', async () => {
    const { admin, project } = await createProjectFixture('AI Review Draft Published');
    await enableProjectAiSettings({ projectId: project.id, userId: admin.user.id });
    const { runId, layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      status: 'approved',
      storagePath: await writePreviewGeoJson('outputs/runs/phase-p-test/review_unpublish.geojson'),
      withPrediction: true,
    });
    const viewer = await createViewerToken();

    await request(app)
      .post(`${API_PREFIX}/ai/layers/${layerId}/publish`)
      .set(authHeader(admin.token))
      .expect(200);

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'keep_draft' })
      .expect(200);

    const layerResult = await pool.query(
      `SELECT status, published_at, published_by
       FROM ai_output_layer
       WHERE id = $1`,
      [layerId],
    );
    expect(layerResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'draft',
        published_at: null,
        published_by: null,
      }),
    );
    await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/published-layers`)
      .set(authHeader(viewer.token))
      .expect(200)
      .expect((response) => {
        expect(response.body.data).toEqual([]);
      });
  });

  test('only protected super-admin can review AI runs', async () => {
    const first = await createProjectFixture('AI Review RBAC First');
    const second = await createProjectFixture('AI Review RBAC Second', {
      protectedSuperAdmin: false,
    });
    const viewer = await createViewerToken();
    const contributor = await createContributorToken({
      adminToken: first.admin.token,
      emailPrefix: 'ai-review-contributor',
    });
    const { runId } = await createReviewableAiRun({
      projectId: first.project.id,
      userId: first.admin.user.id,
    });

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(second.admin.token))
      .send({ action: 'approve_for_publication' })
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(viewer.token))
      .send({ action: 'approve_for_publication' })
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(contributor.token))
      .send({ action: 'approve_for_publication' })
      .expect(403);

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(first.admin.token))
      .send({ action: 'approve_for_publication' })
      .expect(200);
  });
});
