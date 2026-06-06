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
    expect(pipelineService.probeProject).toHaveBeenCalledWith(project.id, 'L4_descr');
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
    );
    expect(pipelineService.evaluateRegionalModel).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
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
    );
    expect(pipelineService.prepareRegionalVectorArtifacts).toHaveBeenCalledWith(
      project.id,
      'L4_descr',
      regionalRunId,
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
