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
       'project',
       1406,
       1394,
       12,
       $3,
       $4::jsonb
     )
     RETURNING id`,
    [projectId, labelField, userId, JSON.stringify(metadata)],
  );

  return result.rows[0].id;
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
        worker_phase: 'phase_e_bridge',
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
        failureReason: 'Mock Phase D worker failure at training.',
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
        failure_reason: 'Mock Phase D worker failure at training.',
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
    ).rejects.toThrow('Phase D AI worker only supports --mock or --dry-run execution.');

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
        pipeline_bridge_phase: 'phase_e',
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
    const runId = await insertQueuedRun({
      projectId: project.id,
      userId: admin.user.id,
      metadata: {
        test: 'ai-worker',
        execution_mode: 'local_ground_truth_export',
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
        failureReason: 'AI pipeline dry_run failed during Phase E safe bridge.',
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
      'AI pipeline dry_run failed during Phase E safe bridge.',
    );
    expect(runResult.rows[0].metadata.command_results).toHaveLength(2);
    expect(await countRows('spatial_feature')).toBe(0);
    expect(await countRows('ai_output_layer')).toBe(0);
  });
});
