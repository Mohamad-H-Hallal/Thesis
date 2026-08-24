import type { PoolClient, QueryResult, QueryResultRow } from 'pg';
import { query } from '../config/database';
import { publishRealtimeChange } from '../realtime/realtimeEvents';

type QueryExecutor = Pick<PoolClient, 'query'> | typeof query;

const runQuery = async <T extends QueryResultRow = QueryResultRow>(
  executor: QueryExecutor,
  text: string,
  params: unknown[] = [],
): Promise<QueryResult<T>> => {
  if (typeof executor === 'function') {
    return executor<T>(text, params);
  }
  return executor.query<T>(text, params);
};

const createWorkflowNotificationOnce = async (
  executor: QueryExecutor,
  {
    userId,
    type,
    eventKey,
    title,
    message,
    metadata,
  }: {
    userId: string;
    type: 'project_event' | 'account_event';
    eventKey: string;
    title: string;
    message: string;
    metadata: Record<string, unknown>;
  },
): Promise<string | null> => {
  const result = await runQuery<{ id: string }>(
    executor,
    `INSERT INTO notification (user_id, type, title, message, metadata)
     VALUES ($1, $2::notification_type, $3, $4, $5::jsonb)
     ON CONFLICT DO NOTHING
     RETURNING id`,
    [userId, type, title, message, JSON.stringify({ ...metadata, event_key: eventKey })],
  );
  return result.rows[0]?.id ?? null;
};

const publishNotificationChange = async (
  executor: QueryExecutor,
  userId: string,
  notificationId: string,
): Promise<void> => {
  const input = {
    scopeType: 'notifications',
    scopeId: userId,
    action: 'created',
    entityType: 'notification',
    entityId: notificationId,
    audience: { kind: 'user' as const, userId },
  };
  await publishRealtimeChange(input, typeof executor === 'function' ? undefined : executor);
};

const notifyProjectStatusChanged = async (
  executor: QueryExecutor,
  {
    projectId,
    projectName,
    previousStatus,
    status,
    actorUserId,
    eventKey,
  }: {
    projectId: string;
    projectName: string;
    previousStatus: string;
    status: string;
    actorUserId?: string | null;
    eventKey: string;
  },
): Promise<void> => {
  if (previousStatus === status) {
    return;
  }
  const recipients = await runQuery<{ user_id: string }>(
    executor,
    `SELECT DISTINCT recipients.user_id
     FROM project p
     CROSS JOIN LATERAL (
       SELECT p.created_by_user_id AS user_id
       UNION
       SELECT pa.user_id
       FROM project_assignment pa
       WHERE pa.project_id = p.id
         AND pa.status = 'approved'
     ) recipients
     JOIN "user" u ON u.id = recipients.user_id AND u.is_active = TRUE
     WHERE p.id = $1`,
    [projectId],
  );
  const statusLabel = status.replaceAll('_', ' ');
  for (const recipient of recipients.rows) {
    if (recipient.user_id === actorUserId) {
      continue;
    }
    const notificationId = await createWorkflowNotificationOnce(executor, {
      userId: recipient.user_id,
      type: 'project_event',
      eventKey: `${eventKey}:${recipient.user_id}`,
      title: `Project ${statusLabel}`,
      message: `${projectName} moved from ${previousStatus.replaceAll('_', ' ')} to ${statusLabel}.`,
      metadata: {
        project_id: projectId,
        project_name: projectName,
        previous_status: previousStatus,
        status,
      },
    });
    if (notificationId) {
      await publishNotificationChange(executor, recipient.user_id, notificationId);
    }
  }
};

const notifyAccountAccessChanged = async (
  executor: QueryExecutor,
  {
    userId,
    eventKey,
    title,
    message,
    accountState,
    role,
    changedByUserId,
  }: {
    userId: string;
    eventKey: string;
    title: string;
    message: string;
    accountState?: string | null;
    role?: string | null;
    changedByUserId?: string | null;
  },
): Promise<void> => {
  await createWorkflowNotificationOnce(executor, {
    userId,
    type: 'account_event',
    eventKey,
    title,
    message,
    metadata: {
      user_id: userId,
      account_state: accountState ?? null,
      role: role ?? null,
      changed_by_user_id: changedByUserId ?? null,
    },
  });
};

export { notifyAccountAccessChanged, notifyProjectStatusChanged };
