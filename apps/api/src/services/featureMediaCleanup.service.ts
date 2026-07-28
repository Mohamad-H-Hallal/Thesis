import { createHash } from 'node:crypto';
import type { PoolClient } from 'pg';
import { query, transaction } from '../config/database';
import { resolveStoredPhotoPath } from './featurePhotoSecurity.service';
import { storageAdapter } from './storageAdapter.service';

const logger = require('../utils/logger');

type CleanupReason = 'upload_rollback' | 'photo_deleted';

interface CleanupJob {
  id: string;
  storage_path: string;
  attempt_count: number;
}

interface CleanupResult {
  completed: number;
  deferred: number;
}

const uniqueStrings = (values: Iterable<string>): string[] => [
  ...new Set(Array.from(values).filter((value) => typeof value === 'string' && value.length > 0)),
];

const safeErrorCode = (error: unknown): string => {
  const code = String((error as { code?: unknown })?.code ?? 'FILESYSTEM_ERROR').toUpperCase();
  const sanitized = code.replace(/[^A-Z0-9_]/g, '_').slice(0, 64);
  return sanitized || 'FILESYSTEM_ERROR';
};

const pathHash = (storagePath: string): string =>
  createHash('sha256').update(storagePath).digest('hex');

export const reserveFeatureMediaCleanupJobs = async (
  paths: Iterable<string>,
  reason: CleanupReason = 'upload_rollback',
): Promise<string[]> => {
  const storagePaths = uniqueStrings(paths);
  if (storagePaths.length === 0) {
    return [];
  }
  if (storagePaths.some((storagePath) => resolveStoredPhotoPath(storagePath) === null)) {
    throw new Error('Refusing to reserve a feature-media path outside configured storage roots.');
  }

  const result = await query<{ id: string }>(
    `INSERT INTO feature_media_cleanup_job (storage_path, reason, available_at)
     SELECT storage_path, $2, NOW() + INTERVAL '10 minutes'
     FROM unnest($1::text[]) AS storage_path
     ON CONFLICT (storage_path) DO UPDATE
     SET reason = EXCLUDED.reason,
         available_at = EXCLUDED.available_at,
         last_error_code = NULL
     RETURNING id`,
    [storagePaths, reason],
  );
  if (result.rows.length !== storagePaths.length) {
    throw new Error('Feature-media cleanup reservations could not be created.');
  }
  return result.rows.map((row) => row.id);
};

export const withReservedFeatureMediaJobs = async <T>(
  client: PoolClient,
  jobIds: string[],
  callback: () => Promise<T>,
): Promise<T> => {
  const uniqueJobIds = uniqueStrings(jobIds);
  if (uniqueJobIds.length > 0) {
    const locked = await client.query<{ id: string }>(
      `SELECT id
       FROM feature_media_cleanup_job
       WHERE id = ANY($1::uuid[])
       ORDER BY id
       FOR UPDATE`,
      [uniqueJobIds],
    );
    if (locked.rows.length !== uniqueJobIds.length) {
      throw new Error('Feature-media cleanup reservation was lost before the write began.');
    }
  }

  const result = await callback();
  if (uniqueJobIds.length > 0) {
    await client.query('DELETE FROM feature_media_cleanup_job WHERE id = ANY($1::uuid[])', [
      uniqueJobIds,
    ]);
  }
  return result;
};

export const makeFeatureMediaCleanupJobsAvailable = async ({
  jobIds = [],
  paths = [],
}: {
  jobIds?: string[];
  paths?: string[];
}): Promise<void> => {
  const uniqueJobIds = uniqueStrings(jobIds);
  const storagePaths = uniqueStrings(paths);
  if (uniqueJobIds.length === 0 && storagePaths.length === 0) {
    return;
  }
  await query(
    `UPDATE feature_media_cleanup_job
     SET available_at = NOW()
     WHERE ($1::uuid[] = '{}'::uuid[] OR id = ANY($1::uuid[]))
       AND ($2::text[] = '{}'::text[] OR storage_path = ANY($2::text[]))`,
    [uniqueJobIds, storagePaths],
  );
};

export const cancelFeatureMediaCleanupJobs = async (paths: Iterable<string>): Promise<void> => {
  const storagePaths = uniqueStrings(paths);
  if (storagePaths.length === 0) {
    return;
  }
  await query('DELETE FROM feature_media_cleanup_job WHERE storage_path = ANY($1::text[])', [
    storagePaths,
  ]);
};

export const processFeatureMediaCleanupJobs = async ({
  jobIds = [],
  paths = [],
  limit = 100,
}: {
  jobIds?: string[];
  paths?: string[];
  limit?: number;
} = {}): Promise<CleanupResult> => {
  const uniqueJobIds = uniqueStrings(jobIds);
  const storagePaths = uniqueStrings(paths);
  const boundedLimit = Number.isSafeInteger(limit) ? Math.max(1, Math.min(limit, 500)) : 100;

  return transaction(async (client): Promise<CleanupResult> => {
    const selected = await client.query<CleanupJob>(
      `SELECT id, storage_path, attempt_count
       FROM feature_media_cleanup_job
       WHERE available_at <= NOW()
         AND ($1::uuid[] = '{}'::uuid[] OR id = ANY($1::uuid[]))
         AND ($2::text[] = '{}'::text[] OR storage_path = ANY($2::text[]))
       ORDER BY available_at, created_at
       LIMIT $3
       FOR UPDATE SKIP LOCKED`,
      [uniqueJobIds, storagePaths, boundedLimit],
    );

    let completed = 0;
    let deferred = 0;
    for (const job of selected.rows) {
      const resolvedPath = resolveStoredPhotoPath(job.storage_path);
      if (!resolvedPath) {
        logger.error('Discarded invalid feature-media cleanup job', {
          jobId: job.id,
          pathHash: pathHash(job.storage_path),
          errorCode: 'PATH_OUTSIDE_STORAGE',
        });
        await client.query('DELETE FROM feature_media_cleanup_job WHERE id = $1', [job.id]);
        completed += 1;
        continue;
      }

      const liveReference = await client.query(
        `SELECT 1
         FROM photo
         WHERE file_path = $1 OR thumbnail_path = $1
         LIMIT 1`,
        [job.storage_path],
      );
      if (liveReference.rows[0]) {
        await client.query('DELETE FROM feature_media_cleanup_job WHERE id = $1', [job.id]);
        completed += 1;
        continue;
      }

      try {
        await storageAdapter.remove(job.storage_path);
        await client.query('DELETE FROM feature_media_cleanup_job WHERE id = $1', [job.id]);
        completed += 1;
      } catch (error: unknown) {
        const errorCode = safeErrorCode(error);
        if (errorCode === 'ENOENT') {
          await client.query('DELETE FROM feature_media_cleanup_job WHERE id = $1', [job.id]);
          completed += 1;
          continue;
        }
        await client.query(
          `UPDATE feature_media_cleanup_job
           SET attempt_count = LEAST(attempt_count + 1, 1000000),
               last_attempted_at = NOW(),
               last_error_code = $2,
               available_at = NOW()
                 + LEAST(3600, POWER(2, LEAST(attempt_count + 1, 10))) * INTERVAL '1 second'
           WHERE id = $1`,
          [job.id, errorCode],
        );
        logger.error('Feature-media cleanup deferred', {
          jobId: job.id,
          pathHash: pathHash(job.storage_path),
          errorCode,
          attemptCount: Number(job.attempt_count) + 1,
        });
        deferred += 1;
      }
    }
    return { completed, deferred };
  });
};
