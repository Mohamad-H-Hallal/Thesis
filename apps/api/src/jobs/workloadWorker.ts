import crypto from 'node:crypto';
import os from 'node:os';
import { query, transaction } from '../config/database';
import {
  claimWorkloadJobs,
  completeWorkloadJob,
  failWorkloadJob,
  renewWorkloadLease,
  type WorkloadJob,
} from '../services/workloadQueue.service';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import { processAccountDeletion } from '../services/accountDeletion.service';
import { processPersonalDataExport } from '../services/privacyExport.service';
const logger = require('../utils/logger');
const { processImportJob } = require('../controllers/import.controller');
const { processExport } = require('../controllers/export.controller');

const positiveInteger = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};

const workerId = `${os.hostname()}:${process.pid}:${crypto.randomUUID()}`;
const concurrency = Math.min(16, positiveInteger(process.env.WORKLOAD_WORKER_CONCURRENCY, 2));
const pollIntervalMs = positiveInteger(process.env.WORKLOAD_POLL_INTERVAL_MS, 1000);
const leaseMs = positiveInteger(process.env.WORKLOAD_LEASE_MS, 5 * 60 * 1000);
const jobTimeoutMs = positiveInteger(process.env.WORKLOAD_JOB_TIMEOUT_MS, 30 * 60 * 1000);

let workerInterval: NodeJS.Timeout | null = null;
let drainRunning = false;
let stopRequested = false;

const workloadEntityIsTerminal = async (job: WorkloadJob): Promise<boolean> => {
  if (job.kind === 'gis_import') {
    const result = await query(`SELECT status FROM gis_import_job WHERE id = $1`, [job.entity_id]);
    if (result.rowCount === 0) {
      return true;
    }
    return !['uploaded', 'processing'].includes(result.rows[0].status);
  }
  if (job.kind === 'project_export') {
    const result = await query(`SELECT status FROM shapefile_export WHERE id = $1`, [job.entity_id]);
    if (result.rowCount === 0) {
      return true;
    }
    return ['completed', 'failed'].includes(result.rows[0].status);
  }
  if (job.kind === 'privacy_access_export') {
    const result = await query(`SELECT status FROM privacy_export_artifact WHERE id = $1`, [job.entity_id]);
    return result.rowCount === 0 || ['ready', 'expired', 'deleted'].includes(result.rows[0].status);
  }
  const result = await query(`SELECT status FROM account_deletion_execution WHERE id = $1`, [job.entity_id]);
  return result.rowCount === 0 || result.rows[0].status === 'completed';
};

const processWorkloadJob = async (job: WorkloadJob): Promise<void> => {
  if (await workloadEntityIsTerminal(job)) {
    return;
  }

  if (job.kind === 'gis_import') {
    await processImportJob(job.entity_id);
    return;
  }

  if (job.kind === 'privacy_access_export') {
    await processPersonalDataExport(job.entity_id);
    return;
  }

  if (job.kind === 'account_deletion') {
    await processAccountDeletion(job.entity_id);
    return;
  }

  const result = await query(
    `SELECT p.name AS project_name
     FROM shapefile_export se
     JOIN project p ON p.id = se.project_id
     WHERE se.id = $1`,
    [job.entity_id],
  );
  if (result.rowCount === 0) {
    return;
  }
  await processExport(job.entity_id, result.rows[0].project_name);
};

const finalizeDeadLetterEntity = async (job: WorkloadJob, error: unknown): Promise<void> => {
  const message = String(error instanceof Error ? error.message : error).slice(0, 4000);
  if (job.kind === 'gis_import') {
    await transaction(async (client) => {
      const result = await client.query(
        `UPDATE gis_import_job
         SET status = 'failed',
             processed_at = CURRENT_TIMESTAMP,
             processing_heartbeat_at = CURRENT_TIMESTAMP,
             processing_message = $2
         WHERE id = $1
           AND status IN ('uploaded', 'processing')
         RETURNING uploaded_by_user_id, project_id`,
        [job.entity_id, `Import moved to the dead-letter queue after bounded retries: ${message}`],
      );
      if (result.rowCount === 0) {
        return;
      }
      const projectResult = await client.query(`SELECT name FROM project WHERE id = $1`, [
        result.rows[0].project_id,
      ]);
      const projectName = projectResult.rows[0]?.name ?? 'Project';
      await client.query(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'import_event', 'Import failed', $2, $3::jsonb)`,
        [
          result.rows[0].uploaded_by_user_id,
          `${projectName} import failed after bounded retries.`,
          JSON.stringify({
            import_job_id: job.entity_id,
            project_id: result.rows[0].project_id,
            project_name: projectName,
            status: 'failed',
            dead_letter: true,
          }),
        ],
      );
      await publishRealtimeChanges(
        [
          {
            scopeType: 'imports',
            scopeId: result.rows[0].uploaded_by_user_id,
            action: 'failed',
            entityType: 'import',
            entityId: job.entity_id,
            projectId: result.rows[0].project_id,
            audience: { kind: 'user', userId: result.rows[0].uploaded_by_user_id },
          },
          {
            scopeType: 'imports',
            scopeId: 'all',
            action: 'failed',
            entityType: 'import',
            entityId: job.entity_id,
            projectId: result.rows[0].project_id,
            audience: { kind: 'admins' },
          },
          {
            scopeType: 'notifications',
            scopeId: result.rows[0].uploaded_by_user_id,
            action: 'created',
            entityType: 'notification',
            entityId: job.entity_id,
            projectId: result.rows[0].project_id,
            audience: { kind: 'user', userId: result.rows[0].uploaded_by_user_id },
          },
        ],
        client,
      );
    });
    return;
  }

  if (job.kind === 'privacy_access_export') {
    await transaction(async (client) => {
      const artifact = await client.query(
        `UPDATE privacy_export_artifact
         SET status = 'failed', failure_code = 'WORKLOAD_RETRIES_EXHAUSTED',
             updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status NOT IN ('ready', 'expired', 'deleted')
           AND failure_code IS DISTINCT FROM 'WORKLOAD_RETRIES_EXHAUSTED'
         RETURNING privacy_request_id, user_id`,
        [job.entity_id],
      );
      if (!artifact.rows[0]) return;
      const request = await client.query<{ status: string }>(
        `SELECT status FROM privacy_request WHERE id = $1 FOR UPDATE`,
        [artifact.rows[0].privacy_request_id],
      );
      await client.query(
        `UPDATE privacy_request
         SET status = 'failed', failed_at = CURRENT_TIMESTAMP,
             failure_code = 'WORKLOAD_RETRIES_EXHAUSTED',
             last_user_visible_message = 'Your export needs privacy-team attention before it can be retried.',
             updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status <> 'completed'`,
        [artifact.rows[0].privacy_request_id],
      );
      if (request.rows[0]?.status !== 'failed') {
        await client.query(
          `INSERT INTO privacy_request_status_history
             (request_id, from_status, to_status, actor_kind, user_visible_message, internal_note)
           VALUES ($1, $2, 'failed', 'worker',
                   'Your export needs privacy-team attention before it can be retried.',
                   'Workload retries were exhausted.')`,
          [artifact.rows[0].privacy_request_id, request.rows[0]?.status ?? null],
        );
      }
      const notification = await client.query<{ id: string }>(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'account_event', 'Data export needs attention',
                 'Your data export could not be prepared. The privacy team can retry it.',
                 $2::JSONB)
         RETURNING id`,
        [
          artifact.rows[0].user_id,
          JSON.stringify({ privacy_request_id: artifact.rows[0].privacy_request_id }),
        ],
      );
      await publishRealtimeChanges(
        [
          {
            scopeType: 'privacy_requests', scopeId: artifact.rows[0].user_id,
            action: 'export_failed', entityType: 'privacy_request',
            entityId: artifact.rows[0].privacy_request_id,
            audience: { kind: 'user', userId: artifact.rows[0].user_id },
          },
          {
            scopeType: 'privacy_admin_queue', scopeId: 'all',
            action: 'request_failed', entityType: 'privacy_request',
            entityId: artifact.rows[0].privacy_request_id,
            audience: { kind: 'protected_admins' },
          },
          {
            scopeType: 'notifications', scopeId: artifact.rows[0].user_id,
            action: 'created', entityType: 'notification',
            entityId: notification.rows[0].id,
            audience: { kind: 'user', userId: artifact.rows[0].user_id },
          },
        ],
        client,
      );
    });
    return;
  }

  if (job.kind === 'account_deletion') {
    await transaction(async (client) => {
      const execution = await client.query(
        `UPDATE account_deletion_execution
         SET status = 'failed', failure_code = 'WORKLOAD_RETRIES_EXHAUSTED',
             updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status <> 'completed'
           AND failure_code IS DISTINCT FROM 'WORKLOAD_RETRIES_EXHAUSTED'
         RETURNING privacy_request_id, user_id`,
        [job.entity_id],
      );
      if (!execution.rows[0]) return;
      const request = await client.query<{ status: string }>(
        `SELECT status FROM privacy_request WHERE id = $1 FOR UPDATE`,
        [execution.rows[0].privacy_request_id],
      );
      await client.query(
        `UPDATE privacy_request
         SET status = 'failed', failed_at = CURRENT_TIMESTAMP,
             failure_code = 'WORKLOAD_RETRIES_EXHAUSTED',
             last_user_visible_message = 'Deletion is paused for privacy-team review. Your account remains unchanged.',
             updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status <> 'completed'`,
        [execution.rows[0].privacy_request_id],
      );
      if (request.rows[0]?.status !== 'failed') {
        await client.query(
          `INSERT INTO privacy_request_status_history
             (request_id, from_status, to_status, actor_kind, user_visible_message, internal_note)
           VALUES ($1, $2, 'failed', 'worker',
                   'Deletion is paused for privacy-team review. Your account remains unchanged.',
                   'Workload retries were exhausted.')`,
          [execution.rows[0].privacy_request_id, request.rows[0]?.status ?? null],
        );
      }
      const notification = await client.query<{ id: string }>(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'account_event', 'Deletion request needs attention',
                 'Your account is unchanged while the privacy team reviews the request.',
                 $2::JSONB)
         RETURNING id`,
        [
          execution.rows[0].user_id,
          JSON.stringify({ privacy_request_id: execution.rows[0].privacy_request_id }),
        ],
      );
      await publishRealtimeChanges(
        [
          {
            scopeType: 'privacy_requests', scopeId: execution.rows[0].user_id,
            action: 'deletion_failed', entityType: 'privacy_request',
            entityId: execution.rows[0].privacy_request_id,
            audience: { kind: 'user', userId: execution.rows[0].user_id },
          },
          {
            scopeType: 'privacy_admin_queue', scopeId: 'all',
            action: 'request_failed', entityType: 'privacy_request',
            entityId: execution.rows[0].privacy_request_id,
            audience: { kind: 'protected_admins' },
          },
          {
            scopeType: 'notifications', scopeId: execution.rows[0].user_id,
            action: 'created', entityType: 'notification',
            entityId: notification.rows[0].id,
            audience: { kind: 'user', userId: execution.rows[0].user_id },
          },
        ],
        client,
      );
    });
    return;
  }

  await transaction(async (client) => {
    const result = await client.query(
      `UPDATE shapefile_export se
       SET status = 'failed',
           file_status = 'missing',
           completed_at = CURRENT_TIMESTAMP,
           error_message = $2
       WHERE se.id = $1
         AND se.status IN ('pending', 'processing')
       RETURNING se.requested_by_user_id, se.project_id`,
      [job.entity_id, `Export moved to the dead-letter queue after bounded retries: ${message}`],
    );
    if (result.rowCount === 0) {
      return;
    }
    const projectResult = await client.query(`SELECT name FROM project WHERE id = $1`, [
      result.rows[0].project_id,
    ]);
    const projectName = projectResult.rows[0]?.name ?? 'Project';
    await client.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES ($1, 'export_ready', 'Export failed', $2, $3)`,
      [
        result.rows[0].requested_by_user_id,
        `${projectName} export failed after bounded retries.`,
        JSON.stringify({
          export_id: job.entity_id,
          project_id: result.rows[0].project_id,
          project_name: projectName,
          status: 'failed',
          dead_letter: true,
        }),
      ],
    );
    await publishRealtimeChanges(
      [
        {
          scopeType: 'exports',
          scopeId: result.rows[0].requested_by_user_id,
          action: 'failed',
          entityType: 'export',
          entityId: job.entity_id,
          projectId: result.rows[0].project_id,
          audience: { kind: 'user', userId: result.rows[0].requested_by_user_id },
        },
        {
          scopeType: 'exports',
          scopeId: 'all',
          action: 'failed',
          entityType: 'export',
          entityId: job.entity_id,
          projectId: result.rows[0].project_id,
          audience: { kind: 'admins' },
        },
        {
          scopeType: 'notifications',
          scopeId: result.rows[0].requested_by_user_id,
          action: 'created',
          entityType: 'notification',
          entityId: job.entity_id,
          projectId: result.rows[0].project_id,
          audience: { kind: 'user', userId: result.rows[0].requested_by_user_id },
        },
      ],
      client,
    );
  });
};

const executeClaimedJob = async (job: WorkloadJob): Promise<void> => {
  let timedOut = false;
  const hardTimeout = setTimeout(() => {
    timedOut = true;
    logger.error('Workload job exceeded its hard execution timeout', {
      jobId: job.id,
      kind: job.kind,
      timeoutMs: jobTimeoutMs,
    });
    if (process.env.WORKLOAD_HARD_EXIT_ON_TIMEOUT === 'true') {
      process.exit(70);
    }
  }, jobTimeoutMs);
  hardTimeout.unref();

  const heartbeat = setInterval(
    () => {
      void renewWorkloadLease({ jobId: job.id, workerId, leaseMs }).catch((error) => {
        logger.error('Failed to renew workload lease', {
          jobId: job.id,
          error: error instanceof Error ? error.message : String(error),
        });
      });
    },
    Math.max(1000, Math.floor(leaseMs / 3)),
  );
  heartbeat.unref();

  try {
    await processWorkloadJob(job);
    if (timedOut) {
      throw new Error(`Workload exceeded ${jobTimeoutMs}ms execution timeout`);
    }
    const completed = await completeWorkloadJob({ jobId: job.id, workerId });
    if (!completed) {
      throw new Error('Workload lease was lost before completion');
    }
  } catch (error) {
    const result = await failWorkloadJob({ job, workerId, error });
    if (result === 'dead_letter') {
      await finalizeDeadLetterEntity(job, error);
    }
    logger.error('Workload execution failed', {
      jobId: job.id,
      kind: job.kind,
      attempt: job.attempt_count,
      maxAttempts: job.max_attempts,
      disposition: result,
      error: error instanceof Error ? error.message : String(error),
    });
  } finally {
    clearInterval(heartbeat);
    clearTimeout(hardTimeout);
  }
};

const runWorkloadWorkerOnce = async (): Promise<number> => {
  const jobs = await claimWorkloadJobs({
    workerId,
    limit: concurrency,
    leaseMs,
  });
  await Promise.all(jobs.map(executeClaimedJob));
  return jobs.length;
};

const drainWorkloadQueue = async (): Promise<void> => {
  if (drainRunning || stopRequested) {
    return;
  }
  drainRunning = true;
  try {
    for (;;) {
      const processed = await runWorkloadWorkerOnce();
      if (processed === 0 || stopRequested) {
        break;
      }
    }
  } finally {
    drainRunning = false;
  }
};

const startWorkloadWorker = (): void => {
  if (workerInterval) {
    return;
  }
  stopRequested = false;
  workerInterval = setInterval(() => {
    void drainWorkloadQueue().catch((error) => {
      logger.error('Workload worker drain failed', {
        error: error instanceof Error ? error.message : String(error),
      });
    });
  }, pollIntervalMs);
  workerInterval.unref();
  void drainWorkloadQueue();
};

const stopWorkloadWorker = (): void => {
  stopRequested = true;
  if (workerInterval) {
    clearInterval(workerInterval);
    workerInterval = null;
  }
};

const waitForWorkloadWorkerIdle = async (): Promise<void> => {
  for (let attempt = 0; attempt < 400; attempt += 1) {
    if (!drainRunning) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error('Workload worker did not become idle');
};

export {
  drainWorkloadQueue,
  finalizeDeadLetterEntity,
  runWorkloadWorkerOnce,
  startWorkloadWorker,
  stopWorkloadWorker,
  waitForWorkloadWorkerIdle,
};
