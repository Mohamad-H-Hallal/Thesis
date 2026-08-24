import type { PoolClient, QueryResult } from 'pg';
import { query, transaction } from '../config/database';

type WorkloadJobKind =
  | 'gis_import'
  | 'project_export'
  | 'privacy_access_export'
  | 'account_deletion';
type WorkloadJobStatus = 'queued' | 'running' | 'succeeded' | 'dead_letter';

interface WorkloadJob {
  id: string;
  kind: WorkloadJobKind;
  entity_id: string;
  status: WorkloadJobStatus;
  attempt_count: number;
  max_attempts: number;
  available_at: Date;
  lease_expires_at: Date | null;
  worker_id: string | null;
  last_error: string | null;
}

interface QueryExecutor {
  query: (sql: string, params?: unknown[]) => Promise<QueryResult>;
}

const enqueueWorkloadJob = async (
  executor: QueryExecutor | PoolClient,
  {
    kind,
    entityId,
    maxAttempts,
  }: {
    kind: WorkloadJobKind;
    entityId: string;
    maxAttempts: number;
  },
): Promise<string> => {
  const result = await executor.query(
    `INSERT INTO workload_job (kind, entity_id, max_attempts)
     VALUES ($1::workload_job_kind, $2, $3)
     ON CONFLICT (kind, entity_id) DO UPDATE
       SET status = CASE
             WHEN workload_job.status = 'dead_letter' THEN 'queued'::workload_job_status
             ELSE workload_job.status
           END,
           available_at = CASE
             WHEN workload_job.status = 'dead_letter' THEN CURRENT_TIMESTAMP
             ELSE workload_job.available_at
           END,
           completed_at = CASE
             WHEN workload_job.status = 'dead_letter' THEN NULL
             ELSE workload_job.completed_at
           END,
           attempt_count = CASE
             WHEN workload_job.status = 'dead_letter' THEN 0
             ELSE workload_job.attempt_count
           END,
           last_error = CASE
             WHEN workload_job.status = 'dead_letter' THEN NULL
             ELSE workload_job.last_error
           END
     RETURNING id`,
    [kind, entityId, maxAttempts],
  );
  return result.rows[0].id;
};

const claimWorkloadJobs = async ({
  workerId,
  limit,
  leaseMs,
}: {
  workerId: string;
  limit: number;
  leaseMs: number;
}): Promise<WorkloadJob[]> =>
  transaction(async (client: PoolClient) => {
    const result = await client.query(
      `WITH candidates AS (
         SELECT id
         FROM workload_job
         WHERE attempt_count < max_attempts
           AND (
             (status = 'queued' AND available_at <= CURRENT_TIMESTAMP)
             OR
             (status = 'running' AND lease_expires_at <= CURRENT_TIMESTAMP)
           )
         ORDER BY available_at ASC, created_at ASC
         FOR UPDATE SKIP LOCKED
         LIMIT $1
       )
       UPDATE workload_job job
       SET status = 'running',
           attempt_count = job.attempt_count + 1,
           worker_id = $2,
           lease_expires_at = CURRENT_TIMESTAMP + ($3::int * INTERVAL '1 millisecond'),
           started_at = COALESCE(job.started_at, CURRENT_TIMESTAMP),
           last_error = CASE
             WHEN job.status = 'running' THEN 'Recovered after an expired worker lease'
             ELSE job.last_error
           END
       FROM candidates
       WHERE job.id = candidates.id
       RETURNING job.*`,
      [Math.max(1, Math.min(limit, 32)), workerId, leaseMs],
    );
    return result.rows as WorkloadJob[];
  });

const renewWorkloadLease = async ({
  jobId,
  workerId,
  leaseMs,
}: {
  jobId: string;
  workerId: string;
  leaseMs: number;
}): Promise<boolean> => {
  const result = await query(
    `UPDATE workload_job
     SET lease_expires_at = CURRENT_TIMESTAMP + ($3::int * INTERVAL '1 millisecond')
     WHERE id = $1
       AND status = 'running'
       AND worker_id = $2
     RETURNING id`,
    [jobId, workerId, leaseMs],
  );
  return result.rowCount === 1;
};

const completeWorkloadJob = async ({
  jobId,
  workerId,
}: {
  jobId: string;
  workerId: string;
}): Promise<boolean> => {
  const result = await query(
    `UPDATE workload_job
     SET status = 'succeeded',
         completed_at = CURRENT_TIMESTAMP,
         lease_expires_at = NULL,
         worker_id = NULL,
         last_error = NULL
     WHERE id = $1
       AND status = 'running'
       AND worker_id = $2
     RETURNING id`,
    [jobId, workerId],
  );
  return result.rowCount === 1;
};

const failWorkloadJob = async ({
  job,
  workerId,
  error,
}: {
  job: WorkloadJob;
  workerId: string;
  error: unknown;
}): Promise<'queued' | 'dead_letter' | 'lost_lease'> => {
  const message = String(error instanceof Error ? error.message : error).slice(0, 4000);
  const exhausted = job.attempt_count >= job.max_attempts;
  const retryDelaySeconds = Math.min(60, 2 ** Math.max(0, job.attempt_count - 1));
  const result = await query(
    `UPDATE workload_job
     SET status = $3::workload_job_status,
         available_at = CASE
           WHEN $3 = 'queued' THEN CURRENT_TIMESTAMP + ($4::int * INTERVAL '1 second')
           ELSE available_at
         END,
         completed_at = CASE WHEN $3 = 'dead_letter' THEN CURRENT_TIMESTAMP ELSE NULL END,
         lease_expires_at = NULL,
         worker_id = NULL,
         last_error = $5
     WHERE id = $1
       AND status = 'running'
       AND worker_id = $2
     RETURNING status`,
    [
      job.id,
      workerId,
      exhausted ? 'dead_letter' : 'queued',
      retryDelaySeconds,
      message,
    ],
  );
  if (result.rowCount !== 1) {
    return 'lost_lease';
  }
  return exhausted ? 'dead_letter' : 'queued';
};

const getWorkloadQueueSummary = async (): Promise<Record<WorkloadJobStatus, number>> => {
  const result = await query(
    `SELECT status, COUNT(*)::int AS count
     FROM workload_job
     GROUP BY status`,
  );
  const summary: Record<WorkloadJobStatus, number> = {
    queued: 0,
    running: 0,
    succeeded: 0,
    dead_letter: 0,
  };
  for (const row of result.rows) {
    summary[row.status as WorkloadJobStatus] = row.count;
  }
  return summary;
};

export {
  claimWorkloadJobs,
  completeWorkloadJob,
  enqueueWorkloadJob,
  failWorkloadJob,
  getWorkloadQueueSummary,
  renewWorkloadLease,
  type WorkloadJob,
  type WorkloadJobKind,
};
