import { randomUUID } from 'node:crypto';

export const realtimeProtocolVersion = 1 as const;
export const realtimeNotificationChannel = 'realtime_domain_changed';
export const realtimeMaxPayloadBytes = 4096;

const identifierPattern = /^[A-Za-z0-9][A-Za-z0-9:_-]{0,119}$/;
const namePattern = /^[a-z][a-z0-9_]{0,39}$/;

export interface RealtimeScope {
  scopeType: string;
  scopeId: string;
}

export type RealtimeAudience =
  | { kind: 'all_authenticated' }
  | { kind: 'admins' }
  | { kind: 'protected_admins' }
  | { kind: 'scope_subscribers' }
  | { kind: 'user'; userId: string }
  | { kind: 'users'; userIds: string[] }
  | {
      kind: 'project';
      projectId: string;
      access: 'readers' | 'members' | 'project_admins';
    }
  | { kind: 'session'; sessionId: string };

export interface RealtimeDomainEvent extends RealtimeScope {
  protocolVersion: typeof realtimeProtocolVersion;
  type: 'domain_changed';
  eventId: string;
  action: string;
  entityType: string;
  entityId: string | null;
  projectId: string | null;
  revision: number;
  occurredAt: string;
  originSessionId: string | null;
  audience: RealtimeAudience;
}

export interface RealtimeClientEvent extends Omit<RealtimeDomainEvent, 'audience' | 'originSessionId'> {
  originatedByCurrentSession: boolean;
}

export interface RealtimePublishInput extends RealtimeScope {
  action: string;
  entityType: string;
  entityId?: string | null;
  projectId?: string | null;
  originSessionId?: string | null;
  audience: RealtimeAudience;
}

export interface RealtimeKnownRevision extends RealtimeScope {
  revision: number;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const assertName = (value: string, label: string): string => {
  const normalized = value.trim().toLowerCase();
  if (!namePattern.test(normalized)) {
    throw new Error(`${label} must be a lowercase realtime name`);
  }
  return normalized;
};

const assertIdentifier = (value: string, label: string): string => {
  const normalized = value.trim();
  if (!identifierPattern.test(normalized)) {
    throw new Error(`${label} contains unsupported characters or is too long`);
  }
  return normalized;
};

export const normalizeRealtimeScope = (scope: RealtimeScope): RealtimeScope => ({
  scopeType: assertName(scope.scopeType, 'scopeType'),
  scopeId: assertIdentifier(scope.scopeId, 'scopeId'),
});

const normalizeAudience = (audience: RealtimeAudience): RealtimeAudience => {
  if (!audience || typeof audience !== 'object' || typeof audience.kind !== 'string') {
    throw new Error('Realtime audience is required');
  }
  if (
    audience.kind === 'all_authenticated' ||
    audience.kind === 'admins' ||
    audience.kind === 'protected_admins' ||
    audience.kind === 'scope_subscribers'
  ) {
    return audience;
  }
  if (audience.kind === 'user') {
    return { kind: audience.kind, userId: assertIdentifier(audience.userId, 'audience userId') };
  }
  if (audience.kind === 'users') {
    const userIds = [...new Set(audience.userIds.map((id) => assertIdentifier(id, 'audience userId')))];
    if (userIds.length === 0 || userIds.length > 100) {
      throw new Error('users audience must contain between 1 and 100 distinct users');
    }
    return { kind: audience.kind, userIds };
  }
  if (audience.kind === 'session') {
    return {
      kind: audience.kind,
      sessionId: assertIdentifier(audience.sessionId, 'audience sessionId'),
    };
  }
  if (audience.kind === 'project') {
    if (!['readers', 'members', 'project_admins'].includes(audience.access)) {
      throw new Error('Unsupported realtime project audience access');
    }
    return {
      kind: audience.kind,
      projectId: assertIdentifier(audience.projectId, 'audience projectId'),
      access: audience.access,
    };
  }
  throw new Error('Unsupported realtime audience kind');
};

export const createRealtimeEvent = (
  input: RealtimePublishInput,
  revision: number,
): RealtimeDomainEvent => {
  const scope = normalizeRealtimeScope(input);
  if (!Number.isSafeInteger(revision) || revision <= 0) {
    throw new Error('revision must be a positive safe integer');
  }
  const event: RealtimeDomainEvent = {
    protocolVersion: realtimeProtocolVersion,
    type: 'domain_changed',
    eventId: randomUUID(),
    action: assertName(input.action, 'action'),
    entityType: assertName(input.entityType, 'entityType'),
    entityId:
      input.entityId == null ? null : assertIdentifier(input.entityId, 'entityId'),
    projectId:
      input.projectId == null ? null : assertIdentifier(input.projectId, 'projectId'),
    scopeType: scope.scopeType,
    scopeId: scope.scopeId,
    revision,
    occurredAt: new Date().toISOString(),
    originSessionId:
      input.originSessionId == null
        ? null
        : assertIdentifier(input.originSessionId, 'originSessionId'),
    audience: normalizeAudience(input.audience),
  };
  assertRealtimePayloadSize(event);
  return event;
};

export const assertRealtimePayloadSize = (payload: unknown): void => {
  const bytes = Buffer.byteLength(JSON.stringify(payload), 'utf8');
  if (bytes > realtimeMaxPayloadBytes) {
    throw new Error(`Realtime payload exceeds ${realtimeMaxPayloadBytes} bytes`);
  }
};

export const parseRealtimeDomainEvent = (value: unknown): RealtimeDomainEvent => {
  if (!isRecord(value) || value.protocolVersion !== realtimeProtocolVersion) {
    throw new Error('Unsupported realtime protocol version');
  }
  if (value.type !== 'domain_changed') {
    throw new Error('Unsupported realtime event type');
  }
  const revision = Number(value.revision);
  const eventId = assertIdentifier(String(value.eventId ?? ''), 'eventId');
  const occurredAt = String(value.occurredAt ?? '');
  if (!Number.isFinite(Date.parse(occurredAt))) {
    throw new Error('occurredAt must be an ISO timestamp');
  }
  if (!isRecord(value.audience) || typeof value.audience.kind !== 'string') {
    throw new Error('Realtime audience is required');
  }
  const audience = normalizeAudience(value.audience as unknown as RealtimeAudience);
  const scope = normalizeRealtimeScope({
    scopeType: String(value.scopeType ?? ''),
    scopeId: String(value.scopeId ?? ''),
  });
  const event: RealtimeDomainEvent = {
    protocolVersion: realtimeProtocolVersion,
    type: 'domain_changed',
    eventId,
    action: assertName(String(value.action ?? ''), 'action'),
    entityType: assertName(String(value.entityType ?? ''), 'entityType'),
    entityId:
      value.entityId == null ? null : assertIdentifier(String(value.entityId), 'entityId'),
    projectId:
      value.projectId == null ? null : assertIdentifier(String(value.projectId), 'projectId'),
    scopeType: scope.scopeType,
    scopeId: scope.scopeId,
    revision,
    occurredAt,
    originSessionId:
      value.originSessionId == null
        ? null
        : assertIdentifier(String(value.originSessionId), 'originSessionId'),
    audience,
  };
  if (!Number.isSafeInteger(event.revision) || event.revision <= 0) {
    throw new Error('revision must be a positive safe integer');
  }
  assertRealtimePayloadSize(event);
  return event;
};

export const parseKnownRevisions = (value: unknown): RealtimeKnownRevision[] => {
  if (value == null) {
    return [];
  }
  if (!Array.isArray(value) || value.length > 200) {
    throw new Error('knownRevisions must contain at most 200 scopes');
  }
  const revisions = new Map<string, RealtimeKnownRevision>();
  for (const item of value) {
    if (!isRecord(item)) {
      throw new Error('knownRevisions entries must be objects');
    }
    const scope = normalizeRealtimeScope({
      scopeType: String(item.scopeType ?? ''),
      scopeId: String(item.scopeId ?? ''),
    });
    const revision = Number(item.revision);
    if (!Number.isSafeInteger(revision) || revision < 0) {
      throw new Error('known revision must be a non-negative safe integer');
    }
    revisions.set(`${scope.scopeType}:${scope.scopeId}`, { ...scope, revision });
  }
  return [...revisions.values()];
};

export const realtimeScopeKey = (scope: RealtimeScope): string => {
  const normalized = normalizeRealtimeScope(scope);
  return `${normalized.scopeType}:${normalized.scopeId}`;
};
