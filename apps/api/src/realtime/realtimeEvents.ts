import { EventEmitter } from 'node:events';
import type { QueryResult, QueryResultRow } from 'pg';
import { transaction } from '../config/database';
import {
  createRealtimeEvent,
  parseRealtimeDomainEvent,
  realtimeNotificationChannel,
  type RealtimeDomainEvent,
  type RealtimeKnownRevision,
  type RealtimePublishInput,
} from './realtimeProtocol';
import { realtimeMetrics } from './realtimeMetrics';
const logger = require('../utils/logger');

interface QueryExecutor {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: unknown[],
  ): Promise<QueryResult<T>>;
}

type RealtimeListener = (event: RealtimeDomainEvent) => void;

const events = new EventEmitter();
events.setMaxListeners(0);
const recentlySeenEventIds = new Set<string>();

const markSeen = (eventId: string): boolean => {
  if (recentlySeenEventIds.has(eventId)) {
    return false;
  }
  recentlySeenEventIds.add(eventId);
  setTimeout(() => recentlySeenEventIds.delete(eventId), 60_000).unref?.();
  return true;
};

export const emitRealtimeDomainEvent = (event: RealtimeDomainEvent): void => {
  if (!markSeen(event.eventId)) {
    return;
  }
  events.emit('domain_changed', event);
};

const publishBatchWithExecutor = async (
  executor: QueryExecutor,
  inputs: RealtimePublishInput[],
): Promise<RealtimeDomainEvent[]> => {
  if (inputs.length === 0) {
    return [];
  }
  const scopes = new Map<
    string,
    { scopeType: string; scopeId: string; count: number }
  >();
  for (const input of inputs) {
    const key = `${input.scopeType}:${input.scopeId}`;
    const existing = scopes.get(key);
    if (existing) {
      existing.count += 1;
    } else {
      scopes.set(key, {
        scopeType: input.scopeType,
        scopeId: input.scopeId,
        count: 1,
      });
    }
  }
  const scopeValues = [...scopes.values()];
  const revisionResult = await executor.query<{
    scope_type: string;
    scope_id: string;
    revision: string | number;
  }>(
    `INSERT INTO realtime_scope_revision (scope_type, scope_id, revision, updated_at)
     SELECT requested.scope_type, requested.scope_id, requested.increment, CURRENT_TIMESTAMP
     FROM UNNEST($1::text[], $2::text[], $3::bigint[])
       AS requested(scope_type, scope_id, increment)
     ON CONFLICT (scope_type, scope_id)
     DO UPDATE SET revision = realtime_scope_revision.revision + EXCLUDED.revision,
                   updated_at = CURRENT_TIMESTAMP
     RETURNING scope_type, scope_id, revision`,
    [
      scopeValues.map((scope) => scope.scopeType),
      scopeValues.map((scope) => scope.scopeId),
      scopeValues.map((scope) => scope.count),
    ],
  );
  const nextRevision = new Map<string, number>();
  for (const row of revisionResult.rows) {
    const key = `${row.scope_type}:${row.scope_id}`;
    nextRevision.set(key, Number(row.revision) - (scopes.get(key)?.count ?? 1) + 1);
  }
  const events = inputs.map((input) => {
    const key = `${input.scopeType}:${input.scopeId}`;
    const revision = nextRevision.get(key);
    if (revision == null) {
      throw new Error('Realtime revision increment did not return the requested scope');
    }
    nextRevision.set(key, revision + 1);
    return createRealtimeEvent(input, revision);
  });
  const payloads = events.map((event) => JSON.stringify(event));
  await executor.query(
    `SELECT pg_notify($1, payload)
     FROM UNNEST($2::text[]) AS notifications(payload)`,
    [realtimeNotificationChannel, payloads],
  );
  events.forEach((event, index) => {
    realtimeMetrics.published(event.entityType, Buffer.byteLength(payloads[index], 'utf8'));
  });
  return events;
};

export const publishRealtimeChange = async (
  input: RealtimePublishInput,
  executor?: QueryExecutor,
): Promise<RealtimeDomainEvent> => {
  if (executor) {
    return (await publishBatchWithExecutor(executor, [input]))[0];
  }
  return transaction(async (client) => (await publishBatchWithExecutor(client, [input]))[0]);
};

export const publishRealtimeChanges = async (
  inputs: RealtimePublishInput[],
  executor?: QueryExecutor,
): Promise<RealtimeDomainEvent[]> => {
  const unique = new Map<string, RealtimePublishInput>();
  for (const input of inputs) {
    const key = `${input.scopeType}:${input.scopeId}:${input.entityType}:${input.entityId ?? ''}:${input.action}`;
    unique.set(key, input);
  }
  realtimeMetrics.coalesced(Math.max(0, inputs.length - unique.size));
  const publishAll = (client: QueryExecutor): Promise<RealtimeDomainEvent[]> =>
    publishBatchWithExecutor(client, [...unique.values()]);
  if (executor) {
    return publishAll(executor);
  }
  return transaction(publishAll);
};

export const subscribeRealtimeChanges = (listener: RealtimeListener): (() => void) => {
  events.on('domain_changed', listener);
  return () => events.off('domain_changed', listener);
};

export const handleRealtimeNotification = (payload: string): void => {
  try {
    emitRealtimeDomainEvent(parseRealtimeDomainEvent(JSON.parse(payload)));
  } catch (error) {
    logger.warn('Invalid realtime domain notification payload', {
      message: error instanceof Error ? error.message : String(error),
    });
  }
};

export const getScopeRevisions = async (
  executor: QueryExecutor,
  known: RealtimeKnownRevision[],
): Promise<RealtimeKnownRevision[]> => {
  if (known.length === 0) {
    return [];
  }
  const scopeTypes = known.map((scope) => scope.scopeType);
  const scopeIds = known.map((scope) => scope.scopeId);
  const result = await executor.query<{
    scope_type: string;
    scope_id: string;
    revision: string | number;
  }>(
    `SELECT current.scope_type, current.scope_id, current.revision
     FROM realtime_scope_revision current
     JOIN UNNEST($1::text[], $2::text[]) requested(scope_type, scope_id)
       ON requested.scope_type = current.scope_type
      AND requested.scope_id = current.scope_id`,
    [scopeTypes, scopeIds],
  );
  return result.rows.map((row) => ({
    scopeType: row.scope_type,
    scopeId: row.scope_id,
    revision: Number(row.revision),
  }));
};
