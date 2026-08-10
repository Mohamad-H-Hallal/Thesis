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
  const result = await query(`SELECT status FROM shapefile_export WHERE id = $1`, [job.entity_id]);
  if (result.rowCount === 0) {
    return true;
  }
  return ['completed', 'failed'].includes(result.rows[0].status);
};

const processWorkloadJob = async (job: WorkloadJob): Promise<void> => {
  if (await workloadEntityIsTerminal(job)) {
    return;
  }

  if (job.kind === 'gis_import') {
    await processImportJob(job.entity_id);
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
