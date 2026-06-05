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
const { AI_WORKER_MOCK_STATUS_SEQUENCE, runAiWorkerOnce } = require('../src/jobs/aiWorker');

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

const insertQueuedRun = async ({ projectId, userId, labelField = 'L4_descr' }) => {
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
       '{"test":"ai-worker"}'::jsonb
     )
     RETURNING id`,
    [projectId, labelField, userId],
  );

  return result.rows[0].id;
};

const countRows = async (tableName) => {
  const result = await pool.query(`SELECT COUNT(*)::int AS count FROM ${tableName}`);
  return Number(result.rows[0].count);
};

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
        worker_phase: 'phase_d_mock',
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
});
