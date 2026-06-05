import type { PoolClient, QueryResultRow } from 'pg';
import { query, transaction } from '../config/database';
import {
  createAiPipelineService,
  type AiPipelineCommandResult,
  type AiPipelineService,
} from '../services/aiPipeline.service';
const logger = require('../utils/logger');

type AiRunActiveStatus = 'extracting_features' | 'training' | 'evaluating';
type AiRunWorkerStatus = AiRunActiveStatus | 'ready_for_review';
type AiRunFinalStatus = AiRunWorkerStatus | 'failed' | 'queued';
type AiRunExecutionMode = 'mock' | 'dry_run' | 'local_ground_truth_export';

type AiRunRow = QueryResultRow & {
  id: string;
  project_id: string;
  status: string;
  label_field: string;
  metadata: Record<string, unknown> | null;
};

type AiWorkerOnceOptions = {
  workerId?: string;
  dryRun?: boolean;
  mock?: boolean;
  failAtStatus?: AiRunActiveStatus | null;
  pipelineService?: AiPipelineService;
};

type AiWorkerOnceResult = {
  processed: boolean;
  dryRun: boolean;
  mock: boolean;
  executionMode: AiRunExecutionMode | null;
  pipelineEnabled: boolean;
  runId: string | null;
  projectId: string | null;
  labelField: string | null;
  initialStatus: 'queued' | null;
  finalStatus: AiRunFinalStatus | null;
  statuses: AiRunWorkerStatus[];
  logsWritten: number;
  failureReason: string | null;
};

const AI_WORKER_MOCK_STATUS_SEQUENCE: AiRunWorkerStatus[] = [
  'extracting_features',
  'training',
  'evaluating',
  'ready_for_review',
];

const AI_WORKER_PIPELINE_STATUS_SEQUENCE: AiRunWorkerStatus[] = [
  'extracting_features',
  'ready_for_review',
];

const activeStatusSet = new Set<AiRunActiveStatus>([
  'extracting_features',
  'training',
  'evaluating',
]);

const executionModeSet = new Set<AiRunExecutionMode>([
  'mock',
  'dry_run',
  'local_ground_truth_export',
]);

const LOG_METADATA_MAX_CHARS = 4000;

const createWorkerId = (): string => `phase-e-worker-${process.pid}-${Date.now().toString(36)}`;

const safeMetadata = (metadata: Record<string, unknown>): string => JSON.stringify(metadata);

const truncateForMetadata = (value: string): string =>
  value.length > LOG_METADATA_MAX_CHARS
    ? `${value.slice(0, LOG_METADATA_MAX_CHARS)}\n[log truncated]`
    : value;

const insertRunLog = async (
  runId: string,
  level: 'info' | 'warning' | 'error',
  message: string,
  metadata: Record<string, unknown>,
): Promise<void> => {
  await query(
    `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
     VALUES ($1, $2, $3, $4::jsonb)`,
    [runId, level, message, safeMetadata(metadata)],
  );
};

const peekQueuedAiRun = async (): Promise<AiRunRow | null> => {
  const result = await query<AiRunRow>(
    `SELECT id, project_id, status, label_field, metadata
     FROM ai_run
     WHERE status = 'queued'
     ORDER BY created_at ASC
     LIMIT 1`,
  );

  return result.rows[0] ?? null;
};

const claimQueuedRun = async (client: PoolClient, workerId: string): Promise<AiRunRow | null> => {
  const result = await client.query<AiRunRow>(
    `WITH candidate AS (
       SELECT id
       FROM ai_run
       WHERE status = 'queued'
       ORDER BY created_at ASC
       FOR UPDATE SKIP LOCKED
       LIMIT 1
     )
     UPDATE ai_run run
     SET status = 'extracting_features',
         started_at = COALESCE(run.started_at, CURRENT_TIMESTAMP),
         metadata = COALESCE(run.metadata, '{}'::jsonb) || $1::jsonb,
         updated_at = CURRENT_TIMESTAMP
     FROM candidate
     WHERE run.id = candidate.id
     RETURNING run.id,
               run.project_id,
               run.status,
               run.label_field,
               run.metadata`,
    [
      safeMetadata({
        worker_phase: 'phase_e_bridge',
        worker_id: workerId,
        real_ai_execution: false,
      }),
    ],
  );

  return result.rows[0] ?? null;
};

const claimNextQueuedRun = async (workerId: string): Promise<AiRunRow | null> =>
  transaction(async (client: PoolClient) => claimQueuedRun(client, workerId));

const updateRunStatus = async (
  runId: string,
  fromStatus: AiRunWorkerStatus,
  toStatus: AiRunWorkerStatus,
  workerId: string,
  metadata: Record<string, unknown> = {},
): Promise<AiRunRow> => {
  const result = await query<AiRunRow>(
    `UPDATE ai_run
     SET status = $3,
         completed_at = CASE
           WHEN $3::ai_run_status = 'ready_for_review' THEN CURRENT_TIMESTAMP
           ELSE completed_at
         END,
         metadata = COALESCE(metadata, '{}'::jsonb) || $4::jsonb,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND status = $2
     RETURNING id, project_id, status, label_field, metadata`,
    [
      runId,
      fromStatus,
      toStatus,
      safeMetadata({
        worker_phase: 'phase_e_bridge',
        worker_id: workerId,
        real_ai_execution: false,
        ...metadata,
      }),
    ],
  );

  if (result.rows.length === 0) {
    throw new Error(`AI run ${runId} was not in expected status ${fromStatus}.`);
  }

  return result.rows[0];
};

const failRun = async (
  runId: string,
  fromStatus: AiRunActiveStatus,
  failureReason: string,
  workerId: string,
  metadata: Record<string, unknown> = {},
): Promise<AiRunRow> => {
  const result = await query<AiRunRow>(
    `UPDATE ai_run
     SET status = 'failed',
         failed_at = CURRENT_TIMESTAMP,
         failure_reason = $3,
         metadata = COALESCE(metadata, '{}'::jsonb) || $4::jsonb,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND status = $2
     RETURNING id, project_id, status, label_field, metadata`,
    [
      runId,
      fromStatus,
      failureReason,
      safeMetadata({
        worker_phase: 'phase_e_bridge',
        worker_id: workerId,
        real_ai_execution: false,
        ...metadata,
      }),
    ],
  );

  if (result.rows.length === 0) {
    throw new Error(`AI run ${runId} could not be failed from status ${fromStatus}.`);
  }

  return result.rows[0];
};

const emptyResult = (
  dryRun: boolean,
  mock: boolean,
  pipelineEnabled = false,
): AiWorkerOnceResult => ({
  processed: false,
  dryRun,
  mock,
  executionMode: null,
  pipelineEnabled,
  runId: null,
  projectId: null,
  labelField: null,
  initialStatus: null,
  finalStatus: null,
  statuses: [],
  logsWritten: 0,
  failureReason: null,
});

const metadataExecutionMode = (
  metadata: Record<string, unknown> | null,
): AiRunExecutionMode | null => {
  const value = metadata?.execution_mode;
  return typeof value === 'string' && executionModeSet.has(value as AiRunExecutionMode)
    ? (value as AiRunExecutionMode)
    : null;
};

const resolveExecutionMode = (
  run: AiRunRow,
  pipelineService: AiPipelineService,
  forceMock: boolean,
): { executionMode: AiRunExecutionMode; pipelineEnabled: boolean } => {
  const config = pipelineService.getConfig();
  if (forceMock || !config.enabled) {
    return {
      executionMode: 'mock',
      pipelineEnabled: config.enabled,
    };
  }

  const requestedMode = metadataExecutionMode(run.metadata);
  if (requestedMode) {
    return {
      executionMode: requestedMode,
      pipelineEnabled: config.enabled,
    };
  }

  if (config.mode === 'dry_run' || config.mode === 'local_ground_truth_export') {
    return {
      executionMode: config.mode,
      pipelineEnabled: config.enabled,
    };
  }

  return {
    executionMode: 'mock',
    pipelineEnabled: config.enabled,
  };
};

const commandSummary = (result: AiPipelineCommandResult): Record<string, unknown> => ({
  command: result.command,
  success: result.success,
  exit_code: result.exitCode,
  duration_ms: result.durationMs,
  timed_out: result.timedOut,
  output_paths: result.outputPaths,
});

const outputPathsFrom = (results: AiPipelineCommandResult[]): string[] =>
  Array.from(new Set(results.flatMap((result) => result.outputPaths)));

const runMockExecution = async ({
  claimedRun,
  workerId,
  failAtStatus,
  pipelineEnabled,
}: {
  claimedRun: AiRunRow;
  workerId: string;
  failAtStatus: AiRunActiveStatus | null;
  pipelineEnabled: boolean;
}): Promise<AiWorkerOnceResult> => {
  const statuses: AiRunWorkerStatus[] = ['extracting_features'];
  let logsWritten = 0;
  let currentRun = claimedRun;
  let currentStatus: AiRunWorkerStatus = 'extracting_features';

  await insertRunLog(
    claimedRun.id,
    'info',
    'AI worker mock step: extracting features. Real AI execution was not started.',
    {
      status: currentStatus,
      worker_phase: 'phase_e_bridge',
      execution_mode: 'mock',
      worker_id: workerId,
      real_ai_execution: false,
    },
  );
  logsWritten += 1;

  if (failAtStatus === currentStatus) {
    const failureReason = `Mock Phase D worker failure at ${currentStatus}.`;
    currentRun = await failRun(claimedRun.id, currentStatus, failureReason, workerId, {
      execution_mode: 'mock',
    });
    await insertRunLog(claimedRun.id, 'error', failureReason, {
      status: 'failed',
      failed_from_status: currentStatus,
      worker_phase: 'phase_e_bridge',
      execution_mode: 'mock',
      worker_id: workerId,
      real_ai_execution: false,
    });
    return {
      processed: true,
      dryRun: false,
      mock: true,
      executionMode: 'mock',
      pipelineEnabled,
      runId: currentRun.id,
      projectId: currentRun.project_id,
      labelField: currentRun.label_field,
      initialStatus: 'queued',
      finalStatus: 'failed',
      statuses,
      logsWritten: logsWritten + 1,
      failureReason,
    };
  }

  for (const nextStatus of AI_WORKER_MOCK_STATUS_SEQUENCE.slice(1)) {
    currentRun = await updateRunStatus(claimedRun.id, currentStatus, nextStatus, workerId, {
      execution_mode: 'mock',
    });
    currentStatus = nextStatus;
    statuses.push(nextStatus);

    await insertRunLog(
      claimedRun.id,
      'info',
      `AI worker mock step: ${nextStatus}. Real AI execution was not started.`,
      {
        status: nextStatus,
        worker_phase: 'phase_e_bridge',
        execution_mode: 'mock',
        worker_id: workerId,
        real_ai_execution: false,
      },
    );
    logsWritten += 1;

    if (failAtStatus === nextStatus && activeStatusSet.has(nextStatus as AiRunActiveStatus)) {
      const failureReason = `Mock Phase D worker failure at ${nextStatus}.`;
      currentRun = await failRun(
        claimedRun.id,
        nextStatus as AiRunActiveStatus,
        failureReason,
        workerId,
        {
          execution_mode: 'mock',
        },
      );
      await insertRunLog(claimedRun.id, 'error', failureReason, {
        status: 'failed',
        failed_from_status: nextStatus,
        worker_phase: 'phase_e_bridge',
        execution_mode: 'mock',
        worker_id: workerId,
        real_ai_execution: false,
      });
      return {
        processed: true,
        dryRun: false,
        mock: true,
        executionMode: 'mock',
        pipelineEnabled,
        runId: currentRun.id,
        projectId: currentRun.project_id,
        labelField: currentRun.label_field,
        initialStatus: 'queued',
        finalStatus: 'failed',
        statuses,
        logsWritten: logsWritten + 1,
        failureReason,
      };
    }
  }

  logger.info('AI worker mock run completed', {
    runId: currentRun.id,
    projectId: currentRun.project_id,
    statuses,
    realAiExecution: false,
  });

  return {
    processed: true,
    dryRun: false,
    mock: true,
    executionMode: 'mock',
    pipelineEnabled,
    runId: currentRun.id,
    projectId: currentRun.project_id,
    labelField: currentRun.label_field,
    initialStatus: 'queued',
    finalStatus: 'ready_for_review',
    statuses,
    logsWritten,
    failureReason: null,
  };
};

const runPipelineCommandWithLogs = async ({
  run,
  workerId,
  executionMode,
  message,
  commandRunner,
}: {
  run: AiRunRow;
  workerId: string;
  executionMode: AiRunExecutionMode;
  message: string;
  commandRunner: () => Promise<AiPipelineCommandResult>;
}): Promise<{ result: AiPipelineCommandResult; logsWritten: number }> => {
  await insertRunLog(run.id, 'info', `${message} started.`, {
    status: 'extracting_features',
    worker_phase: 'phase_e_bridge',
    execution_mode: executionMode,
    worker_id: workerId,
    real_ai_execution: false,
  });

  const result = await commandRunner();
  await insertRunLog(
    run.id,
    result.success ? 'info' : 'error',
    `${message} ${result.success ? 'completed' : 'failed'}.`,
    {
      status: 'extracting_features',
      worker_phase: 'phase_e_bridge',
      execution_mode: executionMode,
      worker_id: workerId,
      real_ai_execution: false,
      ...commandSummary(result),
      sanitized_log: truncateForMetadata(result.sanitizedLog),
    },
  );

  return {
    result,
    logsWritten: 2,
  };
};

const runPipelineExecution = async ({
  claimedRun,
  workerId,
  executionMode,
  pipelineService,
}: {
  claimedRun: AiRunRow;
  workerId: string;
  executionMode: Exclude<AiRunExecutionMode, 'mock'>;
  pipelineService: AiPipelineService;
}): Promise<AiWorkerOnceResult> => {
  const startedAt = Date.now();
  const commandResults: AiPipelineCommandResult[] = [];
  let logsWritten = 0;

  await insertRunLog(
    claimedRun.id,
    'info',
    'AI pipeline bridge started. Phase E runs only safe dry-run/local-readiness commands.',
    {
      status: 'extracting_features',
      worker_phase: 'phase_e_bridge',
      execution_mode: executionMode,
      worker_id: workerId,
      real_ai_execution: false,
    },
  );
  logsWritten += 1;

  const steps: Array<{
    message: string;
    run: () => Promise<AiPipelineCommandResult>;
  }> = [
    {
      message: 'AI pipeline config check',
      run: () => pipelineService.checkConfig(),
    },
    {
      message: 'AI pipeline dry-run',
      run: () => pipelineService.dryRun(),
    },
    {
      message: 'AI pipeline project readiness probe',
      run: () => pipelineService.probeProject(claimedRun.project_id, claimedRun.label_field),
    },
  ];

  if (executionMode === 'local_ground_truth_export') {
    steps.push({
      message: 'AI local-only ground truth export',
      run: () =>
        pipelineService.exportGroundTruthLocal(claimedRun.project_id, claimedRun.label_field),
    });
  }

  for (const step of steps) {
    const { result, logsWritten: stepLogsWritten } = await runPipelineCommandWithLogs({
      run: claimedRun,
      workerId,
      executionMode,
      message: step.message,
      commandRunner: step.run,
    });
    commandResults.push(result);
    logsWritten += stepLogsWritten;

    if (!result.success) {
      const failureReason = `AI pipeline ${result.command} failed during Phase E safe bridge.`;
      await failRun(claimedRun.id, 'extracting_features', failureReason, workerId, {
        execution_mode: executionMode,
        pipeline_bridge_phase: 'phase_e',
        command_results: commandResults.map(commandSummary),
        output_paths: outputPathsFrom(commandResults),
        duration_ms: Date.now() - startedAt,
      });
      return {
        processed: true,
        dryRun: false,
        mock: false,
        executionMode,
        pipelineEnabled: true,
        runId: claimedRun.id,
        projectId: claimedRun.project_id,
        labelField: claimedRun.label_field,
        initialStatus: 'queued',
        finalStatus: 'failed',
        statuses: ['extracting_features'],
        logsWritten,
        failureReason,
      };
    }
  }

  const completedRun = await updateRunStatus(
    claimedRun.id,
    'extracting_features',
    'ready_for_review',
    workerId,
    {
      execution_mode: executionMode,
      pipeline_bridge_phase: 'phase_e',
      command_results: commandResults.map(commandSummary),
      output_paths: outputPathsFrom(commandResults),
      duration_ms: Date.now() - startedAt,
    },
  );

  await insertRunLog(
    claimedRun.id,
    'info',
    'AI pipeline bridge completed. Run is ready for review of dry-run/local-readiness results only.',
    {
      status: 'ready_for_review',
      worker_phase: 'phase_e_bridge',
      execution_mode: executionMode,
      worker_id: workerId,
      real_ai_execution: false,
      output_paths: outputPathsFrom(commandResults),
    },
  );
  logsWritten += 1;

  logger.info('AI pipeline bridge run completed', {
    runId: completedRun.id,
    projectId: completedRun.project_id,
    executionMode,
    realAiExecution: false,
  });

  return {
    processed: true,
    dryRun: false,
    mock: false,
    executionMode,
    pipelineEnabled: true,
    runId: completedRun.id,
    projectId: completedRun.project_id,
    labelField: completedRun.label_field,
    initialStatus: 'queued',
    finalStatus: 'ready_for_review',
    statuses: AI_WORKER_PIPELINE_STATUS_SEQUENCE,
    logsWritten,
    failureReason: null,
  };
};

const runAiWorkerOnce = async (options: AiWorkerOnceOptions = {}): Promise<AiWorkerOnceResult> => {
  const dryRun = Boolean(options.dryRun);
  const forceMock = options.mock ?? false;
  const workerId = options.workerId ?? createWorkerId();
  const failAtStatus = options.failAtStatus ?? null;
  const pipelineService = options.pipelineService ?? createAiPipelineService();

  if (!dryRun && options.mock === false) {
    throw new Error('Phase D AI worker only supports --mock or --dry-run execution.');
  }

  if (failAtStatus && !activeStatusSet.has(failAtStatus)) {
    throw new Error(`Cannot fail mock AI run at unsupported status ${failAtStatus}.`);
  }

  const pipelineEnabled = pipelineService.getConfig().enabled;
  if (dryRun) {
    const queuedRun = await peekQueuedAiRun();
    if (!queuedRun) {
      return emptyResult(true, forceMock, pipelineEnabled);
    }

    const { executionMode } = resolveExecutionMode(queuedRun, pipelineService, forceMock);
    return {
      processed: false,
      dryRun: true,
      mock: executionMode === 'mock',
      executionMode,
      pipelineEnabled,
      runId: queuedRun.id,
      projectId: queuedRun.project_id,
      labelField: queuedRun.label_field,
      initialStatus: 'queued',
      finalStatus: 'queued',
      statuses: [],
      logsWritten: 0,
      failureReason: null,
    };
  }

  const claimedRun = await claimNextQueuedRun(workerId);
  if (!claimedRun) {
    return emptyResult(false, forceMock, pipelineEnabled);
  }

  const { executionMode, pipelineEnabled: effectivePipelineEnabled } = resolveExecutionMode(
    claimedRun,
    pipelineService,
    forceMock,
  );

  if (executionMode === 'mock') {
    return runMockExecution({
      claimedRun,
      workerId,
      failAtStatus,
      pipelineEnabled: effectivePipelineEnabled,
    });
  }

  return runPipelineExecution({
    claimedRun,
    workerId,
    executionMode,
    pipelineService,
  });
};

export {
  AI_WORKER_MOCK_STATUS_SEQUENCE,
  AI_WORKER_PIPELINE_STATUS_SEQUENCE,
  peekQueuedAiRun,
  runAiWorkerOnce,
  type AiRunActiveStatus,
  type AiRunExecutionMode,
  type AiWorkerOnceResult,
};
