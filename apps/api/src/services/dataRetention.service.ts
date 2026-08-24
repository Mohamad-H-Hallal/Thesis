import type { PoolClient, QueryResult } from 'pg';
import { query, transaction } from '../config/database';

interface ApprovedRetentionPolicy {
  data_category: string;
  retention_days: number;
  disposal_action: 'delete' | 'anonymize' | 'archive' | 'review';
  approval_reference: string;
}

interface RetentionCleanupSummary {
  runId: string | null;
  status: 'completed' | 'skipped_locked';
  affectedRows: number;
  policyCount: number;
}

interface CleanupDefinition {
  sql: string;
}

const cleanupDefinitions: Record<string, CleanupDefinition> = {
  auth_sessions: {
    sql: `DELETE FROM auth_session record
          WHERE COALESCE(record.revoked_at, record.refresh_expires_at) <
                CURRENT_TIMESTAMP - ($1::INTEGER * INTERVAL '1 day')
            AND NOT EXISTS (
              SELECT 1 FROM data_retention_hold hold
              WHERE hold.data_category = $2
                AND hold.released_at IS NULL
                AND (hold.expires_at IS NULL OR hold.expires_at > CURRENT_TIMESTAMP)
                AND (hold.record_table IS NULL OR
                     (hold.record_table = 'auth_session' AND hold.record_id = record.id::TEXT))
            )`,
  },
  password_reset_requests: {
    sql: `DELETE FROM password_reset_request record
          WHERE COALESCE(record.used_at, record.expires_at) <
                CURRENT_TIMESTAMP - ($1::INTEGER * INTERVAL '1 day')
            AND NOT EXISTS (
              SELECT 1 FROM data_retention_hold hold
              WHERE hold.data_category = $2
                AND hold.released_at IS NULL
                AND (hold.expires_at IS NULL OR hold.expires_at > CURRENT_TIMESTAMP)
                AND (hold.record_table IS NULL OR
                     (hold.record_table = 'password_reset_request' AND hold.record_id = record.id::TEXT))
            )`,
  },
  contact_verification: {
    sql: `DELETE FROM contact_verification_challenge record
          WHERE COALESCE(record.consumed_at, record.invalidated_at, record.expires_at) <
                CURRENT_TIMESTAMP - ($1::INTEGER * INTERVAL '1 day')
            AND NOT EXISTS (
              SELECT 1 FROM data_retention_hold hold
              WHERE hold.data_category = $2
                AND hold.released_at IS NULL
                AND (hold.expires_at IS NULL OR hold.expires_at > CURRENT_TIMESTAMP)
                AND (hold.record_table IS NULL OR
                     (hold.record_table = 'contact_verification_challenge' AND hold.record_id = record.id::TEXT))
            )`,
  },
  push_devices: {
    sql: `DELETE FROM push_device_registration record
          WHERE record.invalidated_at IS NOT NULL
            AND record.invalidated_at < CURRENT_TIMESTAMP - ($1::INTEGER * INTERVAL '1 day')
            AND NOT EXISTS (
              SELECT 1 FROM data_retention_hold hold
              WHERE hold.data_category = $2
                AND hold.released_at IS NULL
                AND (hold.expires_at IS NULL OR hold.expires_at > CURRENT_TIMESTAMP)
                AND (hold.record_table IS NULL OR
                     (hold.record_table = 'push_device_registration' AND hold.record_id = record.id::TEXT))
            )`,
  },
  notifications: {
    sql: `DELETE FROM notification record
          WHERE record.created_at < CURRENT_TIMESTAMP - ($1::INTEGER * INTERVAL '1 day')
            AND NOT EXISTS (
              SELECT 1 FROM data_retention_hold hold
              WHERE hold.data_category = $2
                AND hold.released_at IS NULL
                AND (hold.expires_at IS NULL OR hold.expires_at > CURRENT_TIMESTAMP)
                AND (hold.record_table IS NULL OR
                     (hold.record_table = 'notification' AND hold.record_id = record.id::TEXT))
            )`,
  },
};

const approvedPolicies = async (): Promise<ApprovedRetentionPolicy[]> => {
  const result = await query<ApprovedRetentionPolicy>(
    `SELECT data_category, retention_days, disposal_action, approval_reference
     FROM data_retention_policy
     WHERE automated_cleanup_enabled = TRUE
       AND approved_at IS NOT NULL
       AND retention_days IS NOT NULL
       AND disposal_action IS NOT NULL
       AND NULLIF(BTRIM(approval_reference), '') IS NOT NULL
     ORDER BY data_category`,
  );
  return result.rows;
};

const executePolicy = async (
  client: PoolClient,
  runId: string,
  policy: ApprovedRetentionPolicy,
): Promise<number> => {
  const definition = cleanupDefinitions[policy.data_category];
  if (!definition || policy.disposal_action !== 'delete') {
    throw new Error(`RETENTION_POLICY_IMPLEMENTATION_REQUIRED:${policy.data_category}`);
  }
  const result: QueryResult = await client.query(definition.sql, [
    policy.retention_days,
    policy.data_category,
  ]);
  const affected = result.rowCount ?? 0;
  await client.query(
    `INSERT INTO data_retention_cleanup_item
       (run_id, data_category, retention_days, disposal_action, approval_reference, affected_rows)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [
      runId,
      policy.data_category,
      policy.retention_days,
      policy.disposal_action,
      policy.approval_reference,
      affected,
    ],
  );
  return affected;
};

const runApprovedRetentionCleanup = async (
  initiatedBy: 'scheduled' | 'startup' | 'manual' = 'scheduled',
): Promise<RetentionCleanupSummary> => {
  const policies = await approvedPolicies();
  if (policies.length === 0) {
    return {
      runId: null,
      status: 'completed',
      affectedRows: 0,
      policyCount: 0,
    };
  }
  try {
    return await transaction(async (client) => {
    const lock = await client.query<{ acquired: boolean }>(
      `SELECT pg_try_advisory_xact_lock(hashtext('terraleb_retention_cleanup')) AS acquired`,
    );
    if (!lock.rows[0]?.acquired) {
      return {
        runId: null,
        status: 'skipped_locked',
        affectedRows: 0,
        policyCount: 0,
      };
    }
    const run = await client.query<{ id: string }>(
      `INSERT INTO data_retention_cleanup_run (status, initiated_by, policy_count)
       VALUES ('running', $1, $2)
       RETURNING id`,
      [initiatedBy, policies.length],
    );
    const runId = run.rows[0].id;
    let affectedRows = 0;
    for (const policy of policies) {
      affectedRows += await executePolicy(client, runId, policy);
    }
    await client.query(
      `UPDATE data_retention_cleanup_run
       SET status = 'completed', completed_at = CURRENT_TIMESTAMP,
           affected_rows = $2,
           summary = $3::JSONB
       WHERE id = $1`,
      [runId, affectedRows, JSON.stringify({ categories: policies.map((item) => item.data_category) })],
    );
    return {
      runId,
      status: 'completed',
      affectedRows,
      policyCount: policies.length,
    };
    });
  } catch (error) {
    const rawCode = error instanceof Error ? error.message.split(':')[0] : 'RETENTION_CLEANUP_FAILED';
    await query(
      `INSERT INTO data_retention_cleanup_run
         (status, initiated_by, completed_at, policy_count, error_code)
       VALUES ('failed', $1, CURRENT_TIMESTAMP, $2, $3)`,
      [initiatedBy, policies.length, rawCode.slice(0, 120)],
    ).catch(() => undefined);
    throw error;
  }
};

export { runApprovedRetentionCleanup };
export type { RetentionCleanupSummary };
