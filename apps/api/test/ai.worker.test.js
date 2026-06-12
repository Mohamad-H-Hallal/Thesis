const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {
  app,
  API_PREFIX,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  createAdminUser,
  createCategory,
  createProject,
} = require('./helpers/api-test-helpers');
const { registerAiRunArtifactsForReview } = require('../src/services/aiArtifactRegistration.service');
const {
  AI_WORKER_MOCK_STATUS_SEQUENCE,
  AI_WORKER_PIPELINE_STATUS_SEQUENCE,
  AI_WORKER_REGIONAL_ARTIFACT_STATUS_SEQUENCE,
  AI_WORKER_REGIONAL_FULL_REVIEW_STATUS_SEQUENCE,
  AI_WORKER_REGIONAL_MODEL_STATUS_SEQUENCE,
  runAiWorkerOnce,
} = require('../src/jobs/aiWorker');

const tempArtifactRoots = [];

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

const createProjectFixture = async (name = 'AI Worker Project') => {
  const admin = await createAdminUser({
    fullName: `${name} Admin`,
    emailPrefix: 'ai-worker-admin',
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
    project,
  };
};

const insertQueuedRun = async ({
  projectId,
  userId,
  labelField = 'L4_descr',
  scopeType = 'project',
  metadata = { test: 'ai-worker' },
}) => {
  const result = await pool.query(
    `INSERT INTO ai_run (
       project_id,
       status,
       label_field,
       scope_type,
       training_feature_count,
       eligible_feature_count,
       excluded_feature_count,
       started_by,
       metadata
     )
     VALUES (
       $1,
       'queued',
       $2,
       $5,
       1406,
       1394,
       12,
       $3,
       $4::jsonb
     )
     RETURNING id`,
    [projectId, labelField, userId, JSON.stringify(metadata), scopeType],
  );

  return result.rows[0].id;
};

const insertApprovedFeature = async ({
  projectId,
  userId,
  labelField = 'L4_descr',
  label,
  source = 'import',
  lon = 35.5,
  lat = 33.9,
}) => {
  await pool.query(
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
     )`,
    [
      projectId,
      userId,
      lon,
      lat,
      JSON.stringify({ [labelField]: label }),
      source,
    ],
  );
};

const insertReadyRegionalFeatures = async ({ projectId, userId, labelField = 'L4_descr' }) => {
  for (const [index, label] of ['Olives', 'Olives', 'Citrus', 'Citrus'].entries()) {
    await insertApprovedFeature({
      projectId,
      userId,
      labelField,
      label,
      lon: 35.4 + index * 0.01,
      lat: 33.7 + index * 0.01,
    });
  }
};

const countRows = async (tableName) => {
  const result = await pool.query(`SELECT COUNT(*)::int AS count FROM ${tableName}`);
  return Number(result.rows[0].count);
};

const pipelineConfig = (overrides = {}) => ({
  enabled: true,
  root: 'configured',
  pythonBin: 'python',
  timeoutMs: 60000,
  mode: 'dry_run',
  ...overrides,
});

const pipelineResult = (command, overrides = {}) => ({
  command,
  success: true,
  exitCode: 0,
  durationMs: 5,
  timedOut: false,
  sanitizedLog: `${command} ok`,
  outputPaths: [],
  ...overrides,
});

const regionalRunIdForTest = (runId) => `app-ai-${runId.replace(/-/g, '').slice(0, 24)}`;

const createMockPipelineService = ({ config = pipelineConfig(), overrides = {} } = {}) => ({
  getConfig: jest.fn(() => config),
  checkConfig: jest.fn(async () => pipelineResult('config_check')),
  dryRun: jest.fn(async () => pipelineResult('dry_run')),
  probeProject: jest.fn(async () => pipelineResult('probe_project')),
  exportGroundTruthLocal: jest.fn(async () =>
    pipelineResult('export_ground_truth_local', {
      outputPaths: ['outputs/projects/test-project/ground_truth.geojson'],
    }),
  ),
  extractRegionalFeatures: jest.fn(async () =>
    pipelineResult('regional_feature_extraction', {
      outputPaths: [
        'outputs/runs/app-ai-test-run/feature_table.csv',
        'outputs/runs/app-ai-test-run/feature_extraction_summary.json',
      ],
    }),
  ),
  evaluateRegionalModel: jest.fn(async () =>
    pipelineResult('regional_model_eval', {
      outputPaths: [
        'outputs/runs/app-ai-test-run/metrics.json',
        'outputs/runs/app-ai-test-run/model_metadata.json',
      ],
    }),
  ),
  classifyRegional: jest.fn(async () =>
    pipelineResult('regional_classification', {
      outputPaths: [
        'outputs/runs/app-ai-test-run/regional_classification_summary.json',
      ],
    }),
  ),
  prepareRegionalVectorArtifacts: jest.fn(async () =>
    pipelineResult('regional_vectorization_artifacts', {
      outputPaths: [
        'outputs/runs/app-ai-test-run/classification_polygons.geojson',
        'outputs/runs/app-ai-test-run/confidence_polygons.geojson',
        'outputs/runs/app-ai-test-run/uncertainty_areas.geojson',
        'outputs/runs/app-ai-test-run/vectorization_summary.json',
      ],
    }),
  ),
  ...overrides,
});

const createTempArtifactRoot = async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gis-ai-artifacts-test-'));
  tempArtifactRoots.push(root);
  return root;
};

const writeJsonArtifact = async (root, relativePath, payload) => {
  const filePath = path.join(root, relativePath);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), 'utf8');
};

const writeCsvArtifact = async (root, relativePath, rows) => {
  const filePath = path.join(root, relativePath);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const headers = Array.from(
    rows.reduce((set, row) => {
      Object.keys(row).forEach((key) => set.add(key));
      return set;
    }, new Set()),
  );
  const escapeCell = (value) => {
    const text = String(value ?? '');
    return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  };
  const content = [
    headers.join(','),
    ...rows.map((row) => headers.map((header) => escapeCell(row[header])).join(',')),
  ].join('\n');
  await fs.writeFile(filePath, content, 'utf8');
};

const writeRegionalModelArtifacts = async ({ root, projectId, regionalRunId }) => {
  const runDir = `outputs/runs/${regionalRunId}`;
  const projectDir = `outputs/projects/${projectId}`;
  await writeJsonArtifact(root, `${projectDir}/ground_truth_summary.json`, {
    project_id: projectId,
    label_field: 'L4_descr',
    feature_count: 4,
    class_counts: {
      Citrus: 2,
      Olives: 2,
    },
    db_write: false,
  });
  await writeJsonArtifact(root, `${runDir}/feature_extraction_summary.json`, {
    run_id: regionalRunId,
    feature_table: `${runDir}/feature_table.csv`,
    class_counts: {
      citrus: 2,
      olives: 2,
    },
    total_null_feature_values: 0,
    db_write: false,
    national_classification: false,
  });
  await writeJsonArtifact(root, `${runDir}/metrics.json`, {
    run_id: regionalRunId,
    project_id: projectId,
    label_field: 'L4_descr',
    regional_only: true,
    not_national_accuracy: true,
    models: {
      random_forest: {
        accuracy: 0.72,
        macro_f1: 0.65,
        weighted_f1: 0.7,
      },
      svm_rbf: {
        accuracy: 0.75,
        macro_f1: 0.7,
        weighted_f1: 0.74,
      },
      xgboost: {
        accuracy: 0.68,
        macro_f1: 0.62,
        weighted_f1: 0.66,
      },
    },
    best_model: 'svm_rbf',
    classes: ['citrus', 'olives'],
    sample_count: 4,
    train_count: 3,
    test_count: 1,
    class_counts: {
      citrus: 2,
      olives: 2,
    },
    evaluation_method: 'spatial_group_shuffle',
    runtime_seconds: 1.23,
    warnings: ['Regional proof-of-concept only.'],
  });
  await writeJsonArtifact(root, `${runDir}/model_metadata.json`, {
    run_id: regionalRunId,
    best_model: 'svm_rbf',
    no_app_db_writes: true,
    no_national_classification: true,
  });
  await writeCsvArtifact(root, `${runDir}/confusion_matrix.csv`, [
    { actual: 'citrus', citrus: 1, olives: 0 },
    { actual: 'olives', citrus: 0, olives: 1 },
  ]);
  await writeCsvArtifact(root, `${runDir}/classification_report.csv`, [
    { label: 'citrus', precision: 1, recall: 1, 'f1-score': 1, support: 1 },
    { label: 'olives', precision: 1, recall: 1, 'f1-score': 1, support: 1 },
    { label: 'macro avg', precision: 1, recall: 1, 'f1-score': 1, support: 2 },
  ]);
  await writeCsvArtifact(root, `${runDir}/feature_importance.csv`, [
    { model: 'random_forest', feature: 'ndvi', importance: 0.45 },
    { model: 'xgboost', feature: 'b4', importance: 0.22 },
  ]);
};

const writeRegionalClassificationArtifacts = async ({ root, regionalRunId }) => {
  const runDir = `outputs/runs/${regionalRunId}`;
  const emptyFeatureCollection = {
    type: 'FeatureCollection',
    features: [],
  };
  await writeJsonArtifact(root, `${runDir}/regional_classification_summary.json`, {
    run_id: regionalRunId,
    regional_only: true,
    national_classification: false,
    class_counts: {
      Citrus: 2,
      Olives: 2,
    },
    outputs: {
      classification_polygons: `${runDir}/classification_polygons.geojson`,
      confidence_polygons: `${runDir}/confidence_polygons.geojson`,
      uncertainty_areas: `${runDir}/uncertainty_areas.geojson`,
    },
  });
  await writeJsonArtifact(root, `${runDir}/vectorization_summary.json`, {
    run_id: regionalRunId,
    regional_only: true,
    no_spatial_feature_writes: true,
    class_counts: {
      Citrus: 2,
      Olives: 2,
    },
    polygon_count: 4,
  });
  await writeJsonArtifact(root, `${runDir}/classification_polygons.geojson`, emptyFeatureCollection);
  await writeJsonArtifact(root, `${runDir}/confidence_polygons.geojson`, emptyFeatureCollection);
  await writeJsonArtifact(root, `${runDir}/uncertainty_areas.geojson`, emptyFeatureCollection);
};

const writePhaseMReviewArtifacts = async ({ root, regionalRunId, projectId }) => {
  const runDir = `outputs/runs/${regionalRunId}`;
  const emptyFeatureCollection = {
    type: 'FeatureCollection',
    features: [],
  };
  const confidenceSummary = {
    min: 0.336667,
    mean: 0.753197,
    max: 0.996667,
    threshold: 0.6,
    uncertain_feature_count: 279,
  };

  await writeJsonArtifact(root, `${runDir}/regional_classification_summary.json`, {
    run_id: regionalRunId,
    project_id: projectId,
    label_field: 'L4_descr',
    execution_mode: 'regional_classification',
    classification_model: 'random_forest',
    classification_output_model: 'random_forest',
    metrics_selected_model: 'svm_rbf',
    highest_accuracy_model: 'xgboost',
    model_mismatch_reason:
      'SVM RBF was selected by metrics, but Random Forest generated the review layer.',
    regional_only: true,
    national_classification: false,
    viewer_publishing: false,
    spatial_feature_insert: false,
    class_counts: {
      'citrus fruit trees': 181,
      'fruit trees': 66,
      olives: 1147,
    },
    excluded_classes: {
      vineyards: 12,
    },
    confidence_summary: confidenceSummary,
    uncertainty_feature_count: 279,
    scope: {
      type: 'south_lebanon',
      bounds: [35.300811634, 33.383710169, 35.645209556, 33.67100595],
      project_id: projectId,
      label_field: 'L4_descr',
      not_national: true,
    },
    limitations: [
      'Phase M produces regional review predictions only.',
      'No AI predictions were inserted into spatial_feature.',
    ],
    output_paths: {
      ai_classification_review: `${runDir}/ai_classification_review.geojson`,
      ai_confidence_review: `${runDir}/ai_confidence_review.geojson`,
      ai_uncertainty_areas: `${runDir}/ai_uncertainty_areas.geojson`,
      ai_class_statistics_json: `${runDir}/ai_class_statistics.json`,
    },
  });
  await writeJsonArtifact(root, `${runDir}/vectorization_summary.json`, {
    run_id: regionalRunId,
    project_id: projectId,
    label_field: 'L4_descr',
    execution_mode: 'regional_vectorization_artifacts',
    regional_only: true,
    national_classification: false,
    viewer_publishing: false,
    spatial_feature_insert: false,
    class_counts: {
      'citrus fruit trees': 181,
      'fruit trees': 66,
      olives: 1147,
    },
    excluded_classes: {
      vineyards: 12,
    },
    classification_output_model: 'random_forest',
    metrics_selected_model: 'svm_rbf',
    review_artifacts: {
      ai_classification_review: `${runDir}/ai_classification_review.geojson`,
      ai_confidence_review: `${runDir}/ai_confidence_review.geojson`,
      ai_uncertainty_areas: `${runDir}/ai_uncertainty_areas.geojson`,
    },
  });
  await writeJsonArtifact(root, `${runDir}/metadata.json`, {
    run_id: regionalRunId,
    project_id: projectId,
    label_field: 'L4_descr',
    regional_only: true,
    national_classification: false,
    classification_model: 'random_forest',
    metrics_best_macro_f1_model: 'svm_rbf',
    highest_accuracy_model: 'xgboost',
    model_mismatch_reason:
      'SVM RBF was selected by metrics, but Random Forest generated the review layer.',
    db_write: false,
    viewer_publishing: false,
    spatial_feature_insert: false,
  });
  await writeJsonArtifact(root, `${runDir}/ai_class_statistics.json`, {
    run_id: regionalRunId,
    project_id: projectId,
    label_field: 'L4_descr',
    regional_only: true,
    classification_model: 'random_forest',
    predicted_class_counts: {
      'citrus fruit trees': 181,
      'fruit trees': 66,
      olives: 1147,
    },
    approved_class_counts: {
      'citrus fruit trees': 201,
      'fruit trees': 253,
      olives: 940,
    },
    class_statistics: [
      {
        class_label: 'citrus fruit trees',
        predicted_feature_count: 181,
        approved_feature_count: 201,
        area_ha: 2340.146694,
        confidence_mean: 0.660203,
        confidence_min: 0.363333,
        confidence_max: 0.986667,
      },
      {
        class_label: 'fruit trees',
        predicted_feature_count: 66,
        approved_feature_count: 253,
        area_ha: 449.331633,
        confidence_mean: 0.513687,
        confidence_min: 0.363333,
        confidence_max: 0.743333,
      },
      {
        class_label: 'olives',
        predicted_feature_count: 1147,
        approved_feature_count: 940,
        area_ha: 10208.522072,
        confidence_mean: 0.781654,
        confidence_min: 0.336667,
        confidence_max: 0.996667,
      },
    ],
    confidence_available: true,
    confidence_summary: confidenceSummary,
  });
  await writeCsvArtifact(root, `${runDir}/ai_class_statistics.csv`, [
    { class_label: 'citrus fruit trees', predicted_feature_count: 181 },
    { class_label: 'fruit trees', predicted_feature_count: 66 },
    { class_label: 'olives', predicted_feature_count: 1147 },
  ]);
  await writeJsonArtifact(root, `${runDir}/ai_classification_review.geojson`, emptyFeatureCollection);
  await writeJsonArtifact(root, `${runDir}/ai_confidence_review.geojson`, emptyFeatureCollection);
  await writeJsonArtifact(root, `${runDir}/ai_uncertainty_areas.geojson`, emptyFeatureCollection);
};

beforeEach(async () => {
  await resetDb();
});

afterEach(async () => {
  await resetDb();
});

afterAll(async () => {
  await Promise.all(
    tempArtifactRoots.map((root) => fs.rm(root, { recursive: true, force: true })),
  );
  await shutdown();
});

describe('AI worker skeleton phase D', () => {
  test('picks a queued run, advances mock statuses, and writes logs', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Happy Path');
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    const spatialFeatureCountBefore = await countRows('spatial_feature');
    const outputLayerCountBefore = await countRows('ai_output_layer');

    const result = await runAiWorkerOnce({
      mock: true,
      workerId: 'phase-d-test-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        dryRun: false,
        mock: true,
        runId,
        projectId: project.id,
        labelField: 'L4_descr',
        initialStatus: 'queued',
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_MOCK_STATUS_SEQUENCE,
        logsWritten: AI_WORKER_MOCK_STATUS_SEQUENCE.length,
        failureReason: null,
      }),
    );

    const runResult = await pool.query(
      `SELECT status,
              started_at,
              completed_at,
              failed_at,
              failure_reason,
              metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'ready_for_review',
        failed_at: null,
        failure_reason: null,
      }),
    );
    expect(runResult.rows[0].started_at).toBeTruthy();
    expect(runResult.rows[0].completed_at).toBeTruthy();
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        worker_phase: 'phase_f_regional_worker',
        real_ai_execution: false,
      }),
    );

    const logResult = await pool.query(
      `SELECT level, message, metadata
       FROM ai_run_log
       WHERE ai_run_id = $1
       ORDER BY array_position(
         ARRAY['extracting_features', 'training', 'evaluating', 'ready_for_review']::text[],
         metadata ->> 'status'
       ) ASC`,
      [runId],
    );
    expect(logResult.rows).toHaveLength(AI_WORKER_MOCK_STATUS_SEQUENCE.length);
    expect(logResult.rows.map((row) => row.metadata.status)).toEqual(
      AI_WORKER_MOCK_STATUS_SEQUENCE,
    );
    expect(logResult.rows.every((row) => row.level === 'info')).toBe(true);
    expect(
      logResult.rows.every((row) => row.message.includes('Real AI execution was not started')),
    ).toBe(true);

    expect(await countRows('spatial_feature')).toBe(spatialFeatureCountBefore);
    expect(await countRows('ai_output_layer')).toBe(outputLayerCountBefore);
    expect(await countRows('ai_run_metric')).toBe(0);
    expect(await countRows('ai_class_statistic')).toBe(0);
    expect(await countRows('ai_uncertainty_area')).toBe(0);
  });

  test('records a failure reason when mock execution fails in an active state', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Failure Path');
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    const result = await runAiWorkerOnce({
      mock: true,
      workerId: 'phase-d-failure-worker',
      failAtStatus: 'training',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        runId,
        finalStatus: 'failed',
        statuses: ['extracting_features', 'training'],
        failureReason: 'Mock AI worker failure at training.',
      }),
    );

    const runResult = await pool.query(
      `SELECT status, failed_at, completed_at, failure_reason
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'failed',
        completed_at: null,
        failure_reason: 'Mock AI worker failure at training.',
      }),
    );
    expect(runResult.rows[0].failed_at).toBeTruthy();

    const errorLogResult = await pool.query(
      `SELECT level, message, metadata
       FROM ai_run_log
       WHERE ai_run_id = $1
         AND level = 'error'`,
      [runId],
    );
    expect(errorLogResult.rows).toHaveLength(1);
    expect(errorLogResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        status: 'failed',
        failed_from_status: 'training',
        real_ai_execution: false,
      }),
    );
  });

  test('does not let two workers process the same queued run', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Concurrent Claim');
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    const results = await Promise.all([
      runAiWorkerOnce({ mock: true, workerId: 'phase-d-worker-a' }),
      runAiWorkerOnce({ mock: true, workerId: 'phase-d-worker-b' }),
    ]);

    expect(results.filter((result) => result.processed)).toHaveLength(1);
    expect(results.filter((result) => !result.processed)).toHaveLength(1);

    const runResult = await pool.query(
      `SELECT status
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('ready_for_review');

    const logResult = await pool.query(
      `SELECT metadata ->> 'status' AS status
       FROM ai_run_log
       WHERE ai_run_id = $1
         AND metadata ->> 'status' = 'extracting_features'`,
      [runId],
    );
    expect(logResult.rows).toHaveLength(1);
  });

  test('dry-run reports the queued run without mutating it', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Dry Run');
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    const result = await runAiWorkerOnce({
      dryRun: true,
      mock: true,
      workerId: 'phase-d-dry-run-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: false,
        dryRun: true,
        runId,
        finalStatus: 'queued',
        logsWritten: 0,
      }),
    );

    const runResult = await pool.query(
      `SELECT status, started_at, completed_at, failed_at
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'queued',
        started_at: null,
        completed_at: null,
        failed_at: null,
      }),
    );
    expect(await countRows('ai_run_log')).toBe(0);
  });

  test('refuses non-mock execution so Python, GEE, and model training cannot start', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Non Mock Guard');
    await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    await expect(
      runAiWorkerOnce({
        mock: false,
        workerId: 'phase-d-real-worker',
      }),
    ).rejects.toThrow('AI worker direct calls should use --mock, --pipeline-bridge, or --dry-run.');

    expect(await countRows('ai_run_log')).toBe(0);
    expect(await countRows('ai_output_layer')).toBe(0);
    expect(await countRows('spatial_feature')).toBe(0);
  });

  test('uses the mock path when the AI pipeline is disabled', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Disabled Pipeline');
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'dry_run',
      },
    });
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        enabled: false,
        mode: 'disabled',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-e-disabled-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        mock: true,
        executionMode: 'mock',
        pipelineEnabled: false,
        runId,
        finalStatus: 'ready_for_review',
      }),
    );
    expect(pipelineService.checkConfig).not.toHaveBeenCalled();
    expect(pipelineService.dryRun).not.toHaveBeenCalled();
    expect(pipelineService.probeProject).not.toHaveBeenCalled();
    expect(pipelineService.exportGroundTruthLocal).not.toHaveBeenCalled();
  });

  test('runs the enabled dry-run pipeline bridge and stores command metadata', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Dry Pipeline');
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'dry_run',
      },
    });
    const pipelineService = createMockPipelineService();

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-e-dry-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        mock: false,
        executionMode: 'dry_run',
        pipelineEnabled: true,
        runId,
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_PIPELINE_STATUS_SEQUENCE,
      }),
    );
    expect(pipelineService.checkConfig).toHaveBeenCalledTimes(1);
    expect(pipelineService.dryRun).toHaveBeenCalledTimes(1);
    expect(pipelineService.dryRun).toHaveBeenCalledWith(expect.stringMatching(/\.json$/));
    expect(pipelineService.probeProject).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.exportGroundTruthLocal).not.toHaveBeenCalled();

    const runResult = await pool.query(
      `SELECT status, metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('ready_for_review');
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'dry_run',
        pipeline_bridge_phase: 'phase_f',
        real_ai_execution: false,
        run_config_path: expect.stringMatching(/\.json$/),
        run_config: expect.objectContaining({
          training_samples_area_type: 'project_area',
          prediction_area_type: 'project_area',
          national_scope_enabled: false,
          allow_spatial_feature_writes: false,
          publish_outputs: false,
        }),
      }),
    );
    expect(runResult.rows[0].metadata.command_results).toHaveLength(3);

    const logResult = await pool.query(
      `SELECT message, metadata
       FROM ai_run_log
       WHERE ai_run_id = $1
       ORDER BY created_at ASC`,
      [runId],
    );
    expect(logResult.rows.map((row) => row.message)).toEqual(
      expect.arrayContaining([
        'AI pipeline config check started.',
        'AI pipeline config check completed.',
        'AI pipeline dry-run started.',
        'AI pipeline dry-run completed.',
        'AI pipeline project readiness probe started.',
        'AI pipeline project readiness probe completed.',
      ]),
    );
    expect(logResult.rows.every((row) => row.metadata.real_ai_execution === false)).toBe(true);
    expect(await countRows('spatial_feature')).toBe(0);
    expect(await countRows('ai_output_layer')).toBe(0);
  });

  test('runs local-only ground-truth export only when that safe mode is requested', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Local Export Pipeline');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'local_ground_truth_export',
        min_samples_per_class: 2,
      },
    });
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        mode: 'local_ground_truth_export',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-e-export-worker',
    });

    expect(result.finalStatus).toBe('ready_for_review');
    expect(pipelineService.exportGroundTruthLocal).toHaveBeenCalledWith(project.id, 'L4_descr');
    expect(pipelineService.dryRun).toHaveBeenCalledWith(expect.stringMatching(/\.json$/));

    const runResult = await pool.query(
      `SELECT metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].metadata.output_paths).toEqual([
      'outputs/projects/test-project/ground_truth.geojson',
    ]);
  });

  test('runs regional feature extraction mode with safety checks, logs, and output metadata', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Regional Extraction');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_feature_extraction',
        min_samples_per_class: 2,
      },
    });
    const beforeSpatialCount = await countRows('spatial_feature');
    const beforeLayerCount = await countRows('ai_output_layer');
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        mode: 'regional_feature_extraction',
      }),
    });
    const regionalRunId = regionalRunIdForTest(runId);

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-f-extraction-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        mock: false,
        executionMode: 'regional_feature_extraction',
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_PIPELINE_STATUS_SEQUENCE,
      }),
    );
    expect(pipelineService.exportGroundTruthLocal).toHaveBeenCalledWith(project.id, 'L4_descr');
    expect(pipelineService.extractRegionalFeatures).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.evaluateRegionalModel).not.toHaveBeenCalled();

    const runResult = await pool.query(
      `SELECT status, metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('ready_for_review');
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_feature_extraction',
        pipeline_bridge_phase: 'phase_f',
        ai_pipeline_run_id: regionalRunId,
        real_ai_execution: true,
        feature_table_path: `outputs/runs/${regionalRunId}/feature_table.csv`,
        run_config_path: expect.stringMatching(/\.json$/),
      }),
    );
    expect(runResult.rows[0].metadata.pipeline_execution_support).toEqual(
      expect.objectContaining({
        python_pipeline_config_consumed: true,
        effective_pipeline_settings: expect.arrayContaining([
          'satellite_source',
          'date_range',
          'feature_inputs',
          'preferred_model',
          'training_samples_area_type',
          'prediction_area_type',
        ]),
      }),
    );
    expect(runResult.rows[0].metadata.class_counts).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ class_label: 'Olives', sample_count: 2 }),
        expect.objectContaining({ class_label: 'Citrus', sample_count: 2 }),
      ]),
    );
    expect(runResult.rows[0].metadata.scientific_limitations).toEqual(
      expect.arrayContaining(['Regional proof-of-concept only; not a national model.']),
    );

    const logResult = await pool.query(
      `SELECT message, metadata
       FROM ai_run_log
       WHERE ai_run_id = $1
       ORDER BY created_at ASC`,
      [runId],
    );
    expect(logResult.rows.map((row) => row.message)).toEqual(
      expect.arrayContaining([
        'AI regional safety checks completed.',
        'AI regional Sentinel-2 feature extraction started.',
        'AI regional Sentinel-2 feature extraction completed.',
      ]),
    );
    expect(await countRows('spatial_feature')).toBe(beforeSpatialCount);
    expect(await countRows('ai_output_layer')).toBe(beforeLayerCount);
  });

  test('writes settings-driven run config JSON from the run snapshot', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Phase Q Config');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const customPolygon = {
      type: 'Polygon',
      coordinates: [
        [
          [35.2, 33.5],
          [35.8, 33.5],
          [35.8, 34.0],
          [35.2, 34.0],
          [35.2, 33.5],
        ],
      ],
    };
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      scopeType: 'custom_polygon',
      metadata: {
        test: 'ai-worker-phase-q',
        execution_mode: 'regional_feature_extraction',
        min_samples_per_class: 2,
        training_samples_area_type: 'custom_ai_area',
        prediction_area_type: 'custom_ai_area',
        ai_settings: {
          satellite_source: 'sentinel2',
          target_year: 2025,
          season: 'dry',
          date_from: '2025-06-01',
          date_to: '2025-08-31',
          feature_inputs: ['B2', 'B3', 'NDVI'],
          preferred_model: 'random_forest',
          scope_type: 'custom_polygon',
          training_samples_area_type: 'custom_ai_area',
          prediction_area_type: 'custom_ai_area',
        },
      },
    });
    await pool.query(
      `UPDATE ai_run
       SET scope_geometry = ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)
       WHERE id = $1`,
      [runId, JSON.stringify(customPolygon)],
    );
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        mode: 'regional_feature_extraction',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-q-config-worker',
    });

    expect(result.finalStatus).toBe('ready_for_review');
    const runResult = await pool.query(
      `SELECT metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    const metadata = runResult.rows[0].metadata;
    expect(metadata.run_config_path).toEqual(expect.stringMatching(/\.json$/));
    expect(metadata.pipeline_execution_support).toEqual(
      expect.objectContaining({
        python_pipeline_config_consumed: true,
        pending_pipeline_settings: [],
      }),
    );
    const runConfig = JSON.parse(
      await fs.readFile(path.resolve(metadata.run_config_path), 'utf8'),
    );
    expect(runConfig).toEqual(
      expect.objectContaining({
        run_id: runId,
        project_id: project.id,
        label_field: 'L4_descr',
        execution_mode: 'regional_feature_extraction',
        satellite_source: 'sentinel2',
        year: 2025,
        season: 'dry',
        from_date: '2025-06-01',
        to_date: '2025-08-31',
        selected_extracted_features: ['B2', 'B3', 'NDVI'],
        preferred_model: 'random_forest',
        training_samples_area_type: 'custom_ai_area',
        prediction_area_type: 'custom_ai_area',
        custom_polygon: expect.objectContaining({ type: 'Polygon' }),
        output_directory: expect.stringMatching(/^outputs\/runs\//),
        safety_flags: {
          national_scope_enabled: false,
          allow_spatial_feature_writes: false,
          publish_outputs: false,
        },
      }),
    );
    expect(pipelineService.extractRegionalFeatures).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      expect.any(String),
      path.resolve(metadata.run_config_path),
    );
  });

  test('runs regional model evaluation through training and evaluating statuses', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Regional Model Eval');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_model_eval',
        min_samples_per_class: 2,
      },
    });
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        mode: 'regional_model_eval',
      }),
    });
    const regionalRunId = regionalRunIdForTest(runId);

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-f-model-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        executionMode: 'regional_model_eval',
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_REGIONAL_MODEL_STATUS_SEQUENCE,
      }),
    );
    expect(pipelineService.extractRegionalFeatures).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.evaluateRegionalModel).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      undefined,
      expect.stringMatching(/\.json$/),
    );

    const runResult = await pool.query(
      `SELECT metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_model_eval',
        metrics_path: `outputs/runs/${regionalRunId}/metrics.json`,
        real_ai_execution: true,
      }),
    );

    const statusLogs = await pool.query(
      `SELECT metadata ->> 'status' AS status
       FROM ai_run_log
       WHERE ai_run_id = $1
       ORDER BY created_at ASC`,
      [runId],
    );
    expect(statusLogs.rows.map((row) => row.status)).toEqual(
      expect.arrayContaining(['extracting_features', 'training', 'evaluating', 'ready_for_review']),
    );
    expect(await countRows('ai_output_layer')).toBe(0);
    expect(await countRows('ai_run_metric')).toBe(0);
  });

  test('prepares regional classification artifacts without publishing or writing spatial features', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Regional Classification');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_classification',
        min_samples_per_class: 2,
      },
    });
    const regionalRunId = regionalRunIdForTest(runId);
    const beforeSpatialCount = await countRows('spatial_feature');
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        mode: 'regional_classification',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-k-classification-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        executionMode: 'regional_classification',
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_REGIONAL_ARTIFACT_STATUS_SEQUENCE,
      }),
    );
    expect(pipelineService.extractRegionalFeatures).not.toHaveBeenCalled();
    expect(pipelineService.evaluateRegionalModel).not.toHaveBeenCalled();
    expect(pipelineService.classifyRegional).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      `outputs/runs/${regionalRunId}/model_metadata.json`,
      undefined,
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.prepareRegionalVectorArtifacts).not.toHaveBeenCalled();

    const runResult = await pool.query(
      `SELECT status, metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('ready_for_review');
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_classification',
        pipeline_bridge_phase: 'phase_k',
        ai_pipeline_run_id: regionalRunId,
        regional_classification_summary_path:
          `outputs/runs/${regionalRunId}/regional_classification_summary.json`,
        real_ai_execution: true,
      }),
    );
    expect(await countRows('spatial_feature')).toBe(beforeSpatialCount);
    expect(await countRows('ai_output_layer')).toBe(0);

    const statusLogs = await pool.query(
      `SELECT metadata ->> 'status' AS status
       FROM ai_run_log
       WHERE ai_run_id = $1
       ORDER BY created_at ASC`,
      [runId],
    );
    expect(statusLogs.rows.map((row) => row.status)).toEqual(
      expect.arrayContaining(['extracting_features', 'classifying', 'ready_for_review']),
    );
    expect(statusLogs.rows.map((row) => row.status)).not.toEqual(
      expect.arrayContaining(['training', 'evaluating']),
    );
  });

  test('registers regional vectorization artifacts as unpublished review layers only', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Regional Vector Artifacts');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_vectorization_artifacts',
        min_samples_per_class: 2,
        source_model_run_id: 'app-ai-phase-f-model-run',
      },
    });
    const regionalRunId = regionalRunIdForTest(runId);
    const artifactRoot = await createTempArtifactRoot();
    await writeRegionalModelArtifacts({
      root: artifactRoot,
      projectId: project.id,
      regionalRunId,
    });
    await writeRegionalClassificationArtifacts({
      root: artifactRoot,
      regionalRunId,
    });
    const beforeSpatialCount = await countRows('spatial_feature');
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        root: artifactRoot,
        mode: 'regional_vectorization_artifacts',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-k-vector-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        executionMode: 'regional_vectorization_artifacts',
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_REGIONAL_ARTIFACT_STATUS_SEQUENCE,
      }),
    );
    expect(pipelineService.extractRegionalFeatures).not.toHaveBeenCalled();
    expect(pipelineService.evaluateRegionalModel).not.toHaveBeenCalled();
    expect(pipelineService.classifyRegional).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      'outputs/runs/app-ai-phase-f-model-run/model_metadata.json',
      undefined,
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.prepareRegionalVectorArtifacts).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      undefined,
      undefined,
      expect.stringMatching(/\.json$/),
    );

    const runResult = await pool.query(
      `SELECT status, metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('ready_for_review');
    expect(runResult.rows[0].metadata.artifact_registration).toEqual(
      expect.objectContaining({
        phase: 'phase_h_artifact_registration',
        execution_mode: 'regional_vectorization_artifacts',
        output_layers_registered: 4,
        unpublished_only: true,
        review_only: true,
        no_spatial_feature_writes: true,
      }),
    );
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        source_model_run_id: 'app-ai-phase-f-model-run',
        source_model_metadata_path: 'outputs/runs/app-ai-phase-f-model-run/model_metadata.json',
      }),
    );

    const layersResult = await pool.query(
      `SELECT layer_type, status, storage_path, published_at
       FROM ai_output_layer
       WHERE ai_run_id = $1
       ORDER BY layer_type ASC`,
      [runId],
    );
    expect(layersResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          layer_type: 'classification',
          status: 'ready_for_review',
          storage_path: `outputs/runs/${regionalRunId}/classification_polygons.geojson`,
          published_at: null,
        }),
        expect.objectContaining({
          layer_type: 'confidence',
          status: 'ready_for_review',
          storage_path: `outputs/runs/${regionalRunId}/confidence_polygons.geojson`,
          published_at: null,
        }),
        expect.objectContaining({
          layer_type: 'statistics',
          status: 'ready_for_review',
          storage_path: `outputs/runs/${regionalRunId}/metrics.json`,
          published_at: null,
        }),
        expect.objectContaining({
          layer_type: 'uncertainty',
          status: 'ready_for_review',
          storage_path: `outputs/runs/${regionalRunId}/uncertainty_areas.geojson`,
          published_at: null,
        }),
      ]),
    );
    expect(await countRows('spatial_feature')).toBe(beforeSpatialCount);
  });

  test('runs the full regional review workflow from one queued app run', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Full Regional Review');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_full_review_artifacts',
        min_samples_per_class: 2,
      },
    });
    const regionalRunId = regionalRunIdForTest(runId);
    const artifactRoot = await createTempArtifactRoot();
    await writeRegionalModelArtifacts({
      root: artifactRoot,
      projectId: project.id,
      regionalRunId,
    });
    await writeRegionalClassificationArtifacts({
      root: artifactRoot,
      regionalRunId,
    });
    const beforeSpatialCount = await countRows('spatial_feature');
    const beforePublishedLayerCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM ai_output_layer WHERE status = 'published'`,
    );
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        root: artifactRoot,
        mode: 'regional_full_review_artifacts',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-r-full-regional-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        executionMode: 'regional_full_review_artifacts',
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_REGIONAL_FULL_REVIEW_STATUS_SEQUENCE,
      }),
    );
    expect(pipelineService.exportGroundTruthLocal).toHaveBeenCalledWith(project.id, 'L4_descr');
    expect(pipelineService.extractRegionalFeatures).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.evaluateRegionalModel).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      undefined,
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.classifyRegional).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      `outputs/runs/${regionalRunId}/model_metadata.json`,
      undefined,
      expect.stringMatching(/\.json$/),
    );
    expect(pipelineService.prepareRegionalVectorArtifacts).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
      undefined,
      undefined,
      expect.stringMatching(/\.json$/),
    );

    const runResult = await pool.query(
      `SELECT status, metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('ready_for_review');
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_full_review_artifacts',
        pipeline_bridge_phase: 'phase_r_full_regional_review',
        metrics_path: `outputs/runs/${regionalRunId}/metrics.json`,
        regional_classification_summary_path:
          `outputs/runs/${regionalRunId}/regional_classification_summary.json`,
        vectorization_summary_path: `outputs/runs/${regionalRunId}/vectorization_summary.json`,
        real_ai_execution: true,
      }),
    );

    const layersResult = await pool.query(
      `SELECT layer_type, status, published_at
       FROM ai_output_layer
       WHERE ai_run_id = $1
       ORDER BY layer_type ASC`,
      [runId],
    );
    expect(layersResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ layer_type: 'classification', status: 'ready_for_review' }),
        expect.objectContaining({ layer_type: 'confidence', status: 'ready_for_review' }),
        expect.objectContaining({ layer_type: 'statistics', status: 'ready_for_review' }),
        expect.objectContaining({ layer_type: 'uncertainty', status: 'ready_for_review' }),
      ]),
    );
    expect(layersResult.rows.every((row) => row.published_at === null)).toBe(true);
    const registrationLogs = await pool.query(
      `SELECT level, metadata
       FROM ai_run_log
       WHERE ai_run_id = $1
         AND message = 'AI artifacts registered for review.'
       ORDER BY created_at ASC`,
      [runId],
    );
    expect(registrationLogs.rows).toHaveLength(1);
    expect(registrationLogs.rows[0].level).toBe('info');
    expect(registrationLogs.rows[0].metadata).toEqual(
      expect.objectContaining({
        output_layers_registered: 4,
        warnings: [],
      }),
    );
    const afterPublishedLayerCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM ai_output_layer WHERE status = 'published'`,
    );
    expect(afterPublishedLayerCount.rows[0].count).toBe(beforePublishedLayerCount.rows[0].count);
    expect(await countRows('spatial_feature')).toBe(beforeSpatialCount);
  });

  test('registers real Phase M review artifact filenames and predicted class statistics', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Phase M Artifact Registration');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_vectorization_artifacts',
        ai_pipeline_run_id: 'phase-m-real-regional-proof',
        output_paths: {
          ai_classification_review:
            'outputs/runs/phase-m-real-regional-proof/ai_classification_review.geojson',
          ai_confidence_review:
            'outputs/runs/phase-m-real-regional-proof/ai_confidence_review.geojson',
          ai_uncertainty_areas:
            'outputs/runs/phase-m-real-regional-proof/ai_uncertainty_areas.geojson',
          ai_class_statistics_json:
            'outputs/runs/phase-m-real-regional-proof/ai_class_statistics.json',
        },
      },
    });
    const artifactRoot = await createTempArtifactRoot();
    await writePhaseMReviewArtifacts({
      root: artifactRoot,
      regionalRunId: 'phase-m-real-regional-proof',
      projectId: project.id,
    });
    const beforeSpatialCount = await countRows('spatial_feature');

    const result = await registerAiRunArtifactsForReview({
      runId,
      projectId: project.id,
      labelField: 'L4_descr',
      metadata: {
        execution_mode: 'regional_vectorization_artifacts',
        ai_pipeline_run_id: 'phase-m-real-regional-proof',
        output_paths: {
          ai_classification_review:
            'outputs/runs/phase-m-real-regional-proof/ai_classification_review.geojson',
          ai_confidence_review:
            'outputs/runs/phase-m-real-regional-proof/ai_confidence_review.geojson',
          ai_uncertainty_areas:
            'outputs/runs/phase-m-real-regional-proof/ai_uncertainty_areas.geojson',
          ai_class_statistics_json:
            'outputs/runs/phase-m-real-regional-proof/ai_class_statistics.json',
          ai_class_statistics_csv:
            'outputs/runs/phase-m-real-regional-proof/ai_class_statistics.csv',
        },
      },
      pipelineConfig: pipelineConfig({
        root: artifactRoot,
        mode: 'regional_vectorization_artifacts',
      }),
    });

    expect(result).toEqual(
      expect.objectContaining({
        success: true,
        skipped: false,
        metricsRegistered: 0,
        classStatisticsRegistered: 4,
        outputLayersRegistered: 4,
      }),
    );
    expect(result.metadataPatch).toEqual(
      expect.objectContaining({
        classification_model: 'random_forest',
        metrics_best_macro_f1_model: 'svm_rbf',
        highest_accuracy_model: 'xgboost',
        model_mismatch_reason:
          'SVM RBF was selected by metrics, but Random Forest generated the review layer.',
        uncertainty_feature_count: 279,
        confidence_summary: expect.objectContaining({
          uncertain_feature_count: 279,
          threshold: 0.6,
        }),
        artifact_registration: expect.objectContaining({
          output_layers_registered: 4,
          unpublished_only: true,
          review_only: true,
          no_spatial_feature_writes: true,
        }),
        class_counts: [
          { class_label: 'citrus fruit trees', feature_count: 181 },
          { class_label: 'fruit trees', feature_count: 66 },
          { class_label: 'olives', feature_count: 1147 },
        ],
        excluded_classes: [
          { class_label: 'vineyards', feature_count: 12 },
        ],
      }),
    );
    expect(result.artifactPaths).toEqual(
      expect.objectContaining({
        ai_classification_review:
          'outputs/runs/phase-m-real-regional-proof/ai_classification_review.geojson',
        ai_confidence_review:
          'outputs/runs/phase-m-real-regional-proof/ai_confidence_review.geojson',
        ai_uncertainty_areas:
          'outputs/runs/phase-m-real-regional-proof/ai_uncertainty_areas.geojson',
        ai_class_statistics_json:
          'outputs/runs/phase-m-real-regional-proof/ai_class_statistics.json',
      }),
    );

    const layersResult = await pool.query(
      `SELECT layer_type, status, storage_path, published_at
       FROM ai_output_layer
       WHERE ai_run_id = $1
       ORDER BY layer_type ASC`,
      [runId],
    );
    expect(layersResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          layer_type: 'classification',
          status: 'ready_for_review',
          storage_path:
            'outputs/runs/phase-m-real-regional-proof/ai_classification_review.geojson',
          published_at: null,
        }),
        expect.objectContaining({
          layer_type: 'confidence',
          status: 'ready_for_review',
          storage_path: 'outputs/runs/phase-m-real-regional-proof/ai_confidence_review.geojson',
          published_at: null,
        }),
        expect.objectContaining({
          layer_type: 'statistics',
          status: 'ready_for_review',
          storage_path: 'outputs/runs/phase-m-real-regional-proof/ai_class_statistics.json',
          published_at: null,
        }),
        expect.objectContaining({
          layer_type: 'uncertainty',
          status: 'ready_for_review',
          storage_path: 'outputs/runs/phase-m-real-regional-proof/ai_uncertainty_areas.geojson',
          published_at: null,
        }),
      ]),
    );

    const classStatsResult = await pool.query(
      `SELECT class_label, feature_count, area_ha, confidence_mean, statistics
       FROM ai_class_statistic
       WHERE ai_run_id = $1
       ORDER BY class_label ASC`,
      [runId],
    );
    expect(classStatsResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          class_label: 'citrus fruit trees',
          feature_count: 181,
          confidence_mean: 0.660203,
        }),
        expect.objectContaining({
          class_label: 'fruit trees',
          feature_count: 66,
          confidence_mean: 0.513687,
        }),
        expect.objectContaining({
          class_label: 'olives',
          feature_count: 1147,
          confidence_mean: 0.781654,
        }),
        expect.objectContaining({
          class_label: 'vineyards',
          feature_count: 12,
        }),
      ]),
    );
    expect(
      classStatsResult.rows.find((row) => row.class_label === 'fruit trees').statistics,
    ).toEqual(
      expect.objectContaining({
        predicted_feature_count: 66,
        approved_feature_count: 253,
        phase_m_review_artifact: true,
      }),
    );
    expect(
      classStatsResult.rows.find((row) => row.class_label === 'vineyards').statistics,
    ).toEqual(
      expect.objectContaining({
        excluded: true,
        exclusion_reason: 'below_minimum_samples',
      }),
    );
    expect(await countRows('spatial_feature')).toBe(beforeSpatialCount);
  });

  test('registers regional model artifacts as unpublished review data', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Artifact Registration');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      labelField: 'L4_descr',
      label: 'Vineyards',
      source: 'import',
      lon: 35.6,
      lat: 33.95,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_model_eval',
        min_samples_per_class: 2,
      },
    });
    const regionalRunId = regionalRunIdForTest(runId);
    const artifactRoot = await createTempArtifactRoot();
    await writeRegionalModelArtifacts({
      root: artifactRoot,
      projectId: project.id,
      regionalRunId,
    });
    const beforeSpatialCount = await countRows('spatial_feature');
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        root: artifactRoot,
        mode: 'regional_model_eval',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-h-registration-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        executionMode: 'regional_model_eval',
        finalStatus: 'ready_for_review',
        statuses: AI_WORKER_REGIONAL_MODEL_STATUS_SEQUENCE,
      }),
    );

    const runResult = await pool.query(
      `SELECT status, selected_model, metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('ready_for_review');
    expect(runResult.rows[0].selected_model).toBe('svm_rbf');
    expect(runResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        selected_model: 'svm_rbf',
        artifact_registration: expect.objectContaining({
          phase: 'phase_h_artifact_registration',
          metrics_registered: 3,
          class_statistics_registered: 3,
          output_layers_registered: 1,
          unpublished_only: true,
          no_spatial_feature_writes: true,
        }),
        model_metrics_summary: expect.objectContaining({
          best_model: 'svm_rbf',
          best_balanced_model: 'svm_rbf',
          highest_accuracy_model: 'svm_rbf',
          not_national_accuracy: true,
        }),
      }),
    );

    const metricsResult = await pool.query(
      `SELECT model_name, overall_accuracy, macro_f1, weighted_f1, metrics, confusion_matrix,
              feature_importance
       FROM ai_run_metric
       WHERE ai_run_id = $1
       ORDER BY model_name ASC`,
      [runId],
    );
    expect(metricsResult.rows).toHaveLength(3);
    expect(metricsResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          model_name: 'random_forest',
          overall_accuracy: 0.72,
          macro_f1: 0.65,
          weighted_f1: 0.7,
        }),
        expect.objectContaining({
          model_name: 'svm_rbf',
          overall_accuracy: 0.75,
          macro_f1: 0.7,
          weighted_f1: 0.74,
        }),
        expect.objectContaining({
          model_name: 'xgboost',
          overall_accuracy: 0.68,
          macro_f1: 0.62,
          weighted_f1: 0.66,
        }),
      ]),
    );
    expect(metricsResult.rows[0].confusion_matrix.rows).toEqual(
      expect.arrayContaining([expect.objectContaining({ actual: 'citrus', citrus: 1 })]),
    );
    expect(metricsResult.rows.find((row) => row.model_name === 'random_forest').feature_importance)
      .toEqual(expect.arrayContaining([expect.objectContaining({ feature: 'ndvi' })]));

    const classStatsResult = await pool.query(
      `SELECT class_label, feature_count, statistics
       FROM ai_class_statistic
       WHERE ai_run_id = $1
       ORDER BY class_label ASC`,
      [runId],
    );
    expect(classStatsResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ class_label: 'Citrus', feature_count: 2 }),
        expect.objectContaining({ class_label: 'Olives', feature_count: 2 }),
        expect.objectContaining({ class_label: 'Vineyards', feature_count: 1 }),
      ]),
    );
    expect(
      classStatsResult.rows.find((row) => row.class_label === 'Vineyards').statistics,
    ).toEqual(
      expect.objectContaining({
        excluded: true,
        exclusion_reason: 'below_minimum_samples',
      }),
    );

    const layersResult = await pool.query(
      `SELECT layer_type, status, storage_path, published_at
       FROM ai_output_layer
       WHERE ai_run_id = $1`,
      [runId],
    );
    expect(layersResult.rows).toEqual([
      expect.objectContaining({
        layer_type: 'statistics',
        status: 'ready_for_review',
        storage_path: `outputs/runs/${regionalRunId}/metrics.json`,
        published_at: null,
      }),
    ]);

    const logsResult = await pool.query(
      `SELECT level, message, metadata
       FROM ai_run_log
       WHERE ai_run_id = $1
         AND message = 'AI artifacts registered for review.'`,
      [runId],
    );
    expect(logsResult.rows).toHaveLength(1);
    expect(logsResult.rows[0].metadata).toEqual(
      expect.objectContaining({
        registration_phase: 'phase_h_artifact_registration',
        metrics_registered: 3,
        output_layers_registered: 1,
        no_spatial_feature_writes: true,
      }),
    );

    process.env.SUPER_ADMIN_EMAIL = admin.email;
    const metricsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/metrics`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(metricsResponse.body.data).toHaveLength(3);
    expect(metricsResponse.body.data.map((row) => row.model_name)).toEqual(
      expect.arrayContaining(['random_forest', 'svm_rbf', 'xgboost']),
    );

    const layersResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/layers`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(layersResponse.body.data).toEqual([
      expect.objectContaining({
        layer_type: 'statistics',
        status: 'ready_for_review',
        published_at: null,
      }),
    ]);

    expect(await countRows('spatial_feature')).toBe(beforeSpatialCount);
    expect(await countRows('ai_uncertainty_area')).toBe(0);
  });

  test('rejects AI artifact path traversal before reading files', async () => {
    const artifactRoot = await createTempArtifactRoot();

    await expect(
      registerAiRunArtifactsForReview({
        runId: '00000000-0000-4000-8000-000000000001',
        projectId: '00000000-0000-4000-8000-000000000002',
        labelField: 'L4_descr',
        metadata: {
          execution_mode: 'regional_model_eval',
          metrics_path: 'outputs/runs/app-ai-safe/../secrets/metrics.json',
        },
        pipelineConfig: pipelineConfig({
          root: artifactRoot,
          mode: 'regional_model_eval',
        }),
      }),
    ).rejects.toThrow('AI artifact path traversal is not allowed');

    await expect(
      registerAiRunArtifactsForReview({
        runId: '00000000-0000-4000-8000-000000000001',
        projectId: '00000000-0000-4000-8000-000000000002',
        labelField: 'L4_descr',
        metadata: {
          execution_mode: 'regional_vectorization_artifacts',
          classification_polygons_path:
            'outputs/runs/app-ai-safe/../secrets/classification_polygons.geojson',
        },
        pipelineConfig: pipelineConfig({
          root: artifactRoot,
          mode: 'regional_vectorization_artifacts',
        }),
      }),
    ).rejects.toThrow('AI artifact path traversal is not allowed');
  });

  test('rejects unsafe national regional execution before pipeline commands run', async () => {
    const { admin, project } = await createProjectFixture('AI Worker National Guard');
    await insertReadyRegionalFeatures({
      projectId: project.id,
      userId: admin.user.id,
    });
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      scopeType: 'national',
      metadata: {
        test: 'ai-worker',
        execution_mode: 'regional_feature_extraction',
        min_samples_per_class: 2,
      },
    });
    const beforeSpatialCount = await countRows('spatial_feature');
    const pipelineService = createMockPipelineService({
      config: pipelineConfig({
        mode: 'regional_feature_extraction',
      }),
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-f-national-guard-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        finalStatus: 'failed',
        failureReason: 'National classification is not allowed in regional AI worker execution.',
      }),
    );
    expect(pipelineService.checkConfig).not.toHaveBeenCalled();
    expect(pipelineService.extractRegionalFeatures).not.toHaveBeenCalled();

    const runResult = await pool.query(
      `SELECT status, failure_reason
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('failed');
    expect(runResult.rows[0].failure_reason).toBe(
      'National classification is not allowed in regional AI worker execution.',
    );
    expect(await countRows('spatial_feature')).toBe(beforeSpatialCount);
    expect(await countRows('ai_output_layer')).toBe(0);
  });

  test('marks the run failed when a safe pipeline command fails', async () => {
    const { admin, project } = await createProjectFixture('AI Worker Pipeline Failure');
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'dry_run',
      },
    });
    const pipelineService = createMockPipelineService({
      overrides: {
        dryRun: jest.fn(async () =>
          pipelineResult('dry_run', {
            success: false,
            exitCode: 2,
            sanitizedLog: 'dry-run failed without secrets',
          }),
        ),
      },
    });

    const result = await runAiWorkerOnce({
      pipelineService,
      workerId: 'phase-e-failing-worker',
    });

    expect(result).toEqual(
      expect.objectContaining({
        processed: true,
        mock: false,
        executionMode: 'dry_run',
        finalStatus: 'failed',
        failureReason:
          'AI pipeline dry_run failed during regional AI worker execution.',
      }),
    );

    const runResult = await pool.query(
      `SELECT status, failure_reason, metadata
       FROM ai_run
       WHERE id = $1`,
      [runId],
    );
    expect(runResult.rows[0].status).toBe('failed');
    expect(runResult.rows[0].failure_reason).toBe(
      'AI pipeline dry_run failed during regional AI worker execution.',
    );
    expect(runResult.rows[0].metadata.command_results).toHaveLength(2);
    expect(await countRows('spatial_feature')).toBe(0);
    expect(await countRows('ai_output_layer')).toBe(0);
  });
});
