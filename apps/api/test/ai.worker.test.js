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
const {
  AI_WORKER_MOCK_STATUS_SEQUENCE,
  AI_WORKER_PIPELINE_STATUS_SEQUENCE,
  AI_WORKER_REGIONAL_MODEL_STATUS_SEQUENCE,
  runAiWorkerOnce,
} = require('../src/jobs/aiWorker');

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
  ...overrides,
});

beforeEach(async () => {
  await resetDb();
});

afterEach(async () => {
  await resetDb();
});

afterAll(async () => {
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
        failureReason: 'National classification is not allowed in Phase F regional worker execution.',
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
      'National classification is not allowed in Phase F regional worker execution.',
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
          'AI pipeline dry_run failed during Phase F regional worker execution.',
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
      'AI pipeline dry_run failed during Phase F regional worker execution.',
    );
    expect(runResult.rows[0].metadata.command_results).toHaveLength(2);
    expect(await countRows('spatial_feature')).toBe(0);
    expect(await countRows('ai_output_layer')).toBe(0);
  });
});
