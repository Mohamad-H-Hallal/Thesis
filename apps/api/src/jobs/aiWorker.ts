import type { PoolClient, QueryResultRow } from 'pg';
import { query, transaction } from '../config/database';
const logger = require('../utils/logger');

type AiRunActiveStatus = 'extracting_features' | 'training' | 'evaluating';
type AiRunWorkerStatus = AiRunActiveStatus | 'ready_for_review';
type AiRunFinalStatus = AiRunWorkerStatus | 'failed' | 'queued';

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
};

type AiWorkerOnceResult = {
  processed: boolean;
  dryRun: boolean;
  mock: boolean;
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

const activeStatusSet = new Set<AiRunActiveStatus>([
  'extracting_features',
  'training',
  'evaluating',
]);

const createWorkerId = (): string => `phase-d-worker-${process.pid}-${Date.now().toString(36)}`;

const safeMetadata = (metadata: Record<string, unknown>): string => JSON.stringify(metadata);

const insertRunLog = async (
  client: PoolClient,
  runId: string,
  level: 'info' | 'warning' | 'error',
  message: string,
  metadata: Record<string, unknown>,
): Promise<void> => {
  await client.query(
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
        worker_phase: 'phase_d_mock',
        worker_id: workerId,
        real_ai_execution: false,
      }),
    ],
  );

  return result.rows[0] ?? null;
};

const updateRunStatus = async (
  client: PoolClient,
  runId: string,
  fromStatus: AiRunWorkerStatus,
  toStatus: AiRunWorkerStatus,
  workerId: string,
): Promise<AiRunRow> => {
  const result = await client.query<AiRunRow>(
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
        worker_phase: 'phase_d_mock',
        worker_id: workerId,
        real_ai_execution: false,
      }),
    ],
  );

  if (result.rows.length === 0) {
    throw new Error(`AI run ${runId} was not in expected status ${fromStatus}.`);
  }

  return result.rows[0];
};

const failRun = async (
  client: PoolClient,
  runId: string,
  fromStatus: AiRunActiveStatus,
  failureReason: string,
  workerId: string,
): Promise<AiRunRow> => {
  const result = await client.query<AiRunRow>(
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
        worker_phase: 'phase_d_mock',
        worker_id: workerId,
        real_ai_execution: false,
      }),
    ],
  );

  if (result.rows.length === 0) {
    throw new Error(`AI run ${runId} could not be failed from status ${fromStatus}.`);
  }

  return result.rows[0];
};

const emptyResult = (dryRun: boolean, mock: boolean): AiWorkerOnceResult => ({
  processed: false,
  dryRun,
  mock,
  runId: null,
  projectId: null,
  labelField: null,
  initialStatus: null,
  finalStatus: null,
  statuses: [],
  logsWritten: 0,
  failureReason: null,
});

const runAiWorkerOnce = async (options: AiWorkerOnceOptions = {}): Promise<AiWorkerOnceResult> => {
  const dryRun = Boolean(options.dryRun);
  const mock = options.mock ?? true;
  const workerId = options.workerId ?? createWorkerId();
  const failAtStatus = options.failAtStatus ?? null;

  if (!dryRun && !mock) {
    throw new Error('Phase D AI worker only supports --mock or --dry-run execution.');
  }

  if (failAtStatus && !activeStatusSet.has(failAtStatus)) {
    throw new Error(`Cannot fail mock AI run at unsupported status ${failAtStatus}.`);
  }

  if (dryRun) {
    const queuedRun = await peekQueuedAiRun();
    if (!queuedRun) {
      return emptyResult(true, mock);
    }

    return {
      processed: false,
      dryRun: true,
      mock,
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

  return transaction<AiWorkerOnceResult>(async (client) => {
    const claimedRun = await claimQueuedRun(client, workerId);
    if (!claimedRun) {
      return emptyResult(false, mock);
    }

    const statuses: AiRunWorkerStatus[] = ['extracting_features'];
    let logsWritten = 0;
    let currentRun = claimedRun;
    let currentStatus: AiRunWorkerStatus = 'extracting_features';

    await insertRunLog(
      client,
      claimedRun.id,
      'info',
      'AI worker mock step: extracting features. Real AI execution was not started.',
      {
        status: currentStatus,
        worker_phase: 'phase_d_mock',
        worker_id: workerId,
        real_ai_execution: false,
      },
    );
    logsWritten += 1;

    if (failAtStatus === currentStatus) {
      const failureReason = `Mock Phase D worker failure at ${currentStatus}.`;
      currentRun = await failRun(client, claimedRun.id, currentStatus, failureReason, workerId);
      await insertRunLog(client, claimedRun.id, 'error', failureReason, {
        status: 'failed',
        failed_from_status: currentStatus,
        worker_phase: 'phase_d_mock',
        worker_id: workerId,
        real_ai_execution: false,
      });
      return {
        processed: true,
        dryRun: false,
        mock,
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
      currentRun = await updateRunStatus(
        client,
        claimedRun.id,
        currentStatus,
        nextStatus,
        workerId,
      );
      currentStatus = nextStatus;
      statuses.push(nextStatus);

      await insertRunLog(
        client,
        claimedRun.id,
        'info',
        `AI worker mock step: ${nextStatus}. Real AI execution was not started.`,
        {
          status: nextStatus,
          worker_phase: 'phase_d_mock',
          worker_id: workerId,
          real_ai_execution: false,
        },
      );
      logsWritten += 1;

      if (failAtStatus === nextStatus && activeStatusSet.has(nextStatus as AiRunActiveStatus)) {
        const failureReason = `Mock Phase D worker failure at ${nextStatus}.`;
        currentRun = await failRun(client, claimedRun.id, nextStatus, failureReason, workerId);
        await insertRunLog(client, claimedRun.id, 'error', failureReason, {
          status: 'failed',
          failed_from_status: nextStatus,
          worker_phase: 'phase_d_mock',
          worker_id: workerId,
          real_ai_execution: false,
        });
        return {
          processed: true,
          dryRun: false,
          mock,
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
      mock,
      runId: currentRun.id,
      projectId: currentRun.project_id,
      labelField: currentRun.label_field,
      initialStatus: 'queued',
      finalStatus: 'ready_for_review',
      statuses,
      logsWritten,
      failureReason: null,
    };
  });
};

export {
  AI_WORKER_MOCK_STATUS_SEQUENCE,
  peekQueuedAiRun,
  runAiWorkerOnce,
  type AiRunActiveStatus,
  type AiWorkerOnceResult,
};
