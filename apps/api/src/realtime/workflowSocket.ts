import type { IncomingMessage, Server as HttpServer } from 'node:http';
import { isIP } from 'node:net';
import { WebSocketServer, type RawData, type WebSocket } from 'ws';
import { query } from '../config/database';
import type { EnvConfig } from '../config/env';
import { publicVisibleStatuses } from '../lib/projectLifecycle';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { isContactAssuranceSatisfied } from '../services/contactAssurancePolicy.service';
import { isSessionCurrent } from '../services/authSession.service';
import { verifyAccessToken } from '../services/authToken.service';
import type { user_role } from '../types/roles';
import {
  getScopeRevisions,
  subscribeRealtimeChanges,
} from './realtimeEvents';
import { realtimeMetrics } from './realtimeMetrics';
import {
  assertRealtimePayloadSize,
  parseKnownRevisions,
  realtimeProtocolVersion,
  realtimeScopeKey,
  type RealtimeAudience,
  type RealtimeClientEvent,
  type RealtimeDomainEvent,
  type RealtimeKnownRevision,
  type RealtimeScope,
} from './realtimeProtocol';
import { subscribeWorkflowChanges, type WorkflowChangeEvent } from './workflowEvents';
const logger = require('../utils/logger');

type ProjectAccess = 'admin' | 'project_admin' | 'member' | 'public' | 'none';

interface WorkflowSocketUser {
  id: string;
  role: user_role;
  sessionId: string;
  authVersion: number;
  tokenExpiresAt: number;
  protectedSuperAdmin: boolean;
}

interface AuthenticatedClient {
  user: WorkflowSocketUser;
  ipAddress: string;
  projectAccess: Map<string, ProjectAccess>;
  scopeProjects: Map<string, string>;
  subscribedScopes: Map<string, RealtimeScope>;
  alive: boolean;
}

interface AuthenticationMessage {
  token: string;
  knownRevisions: RealtimeKnownRevision[];
  scopes: RealtimeScope[];
}

interface WorkflowSocketOptions {
  enabled?: boolean;
  v2Enabled?: boolean;
  legacyEnabled?: boolean;
  allowedOrigins?: string[];
  allowedHosts?: string[];
  nodeEnv?: string;
  authenticationTimeoutMs?: number;
  heartbeatIntervalMs?: number;
  maxConnectionsPerUser?: number;
  maxConnectionsPerIp?: number;
  maxBufferedBytes?: number;
  trustProxy?: boolean;
  trustProxyHops?: number;
}

const defaultOptions: Required<WorkflowSocketOptions> = {
  enabled: true,
  v2Enabled: true,
  legacyEnabled: true,
  allowedOrigins: [],
  allowedHosts: [],
  nodeEnv: process.env.NODE_ENV ?? 'development',
  authenticationTimeoutMs: 5000,
  heartbeatIntervalMs: 30000,
  maxConnectionsPerUser: 5,
  maxConnectionsPerIp: 30,
  maxBufferedBytes: 262144,
  trustProxy: false,
  trustProxyHops: 1,
};

const socketOptionsFromEnv = (env?: EnvConfig): WorkflowSocketOptions => {
  if (!env) {
    return {};
  }
  const allowedOrigins = env.CORS_ORIGIN.split(',').map((origin) => origin.trim()).filter(Boolean);
  const allowedHosts = [env.APP_PUBLIC_API_URL, ...allowedOrigins].flatMap((value) => {
    try {
      return [new URL(value).host.toLowerCase()];
    } catch {
      return [];
    }
  });
  return {
    v2Enabled: env.REALTIME_V2_ENABLED,
    legacyEnabled: env.REALTIME_LEGACY_BROADCAST_ENABLED,
    allowedOrigins,
    allowedHosts: [...new Set(allowedHosts)],
    nodeEnv: env.NODE_ENV,
    authenticationTimeoutMs: env.REALTIME_AUTH_TIMEOUT_MS,
    heartbeatIntervalMs: env.REALTIME_HEARTBEAT_INTERVAL_MS,
    maxConnectionsPerUser: env.REALTIME_MAX_CONNECTIONS_PER_USER,
    maxConnectionsPerIp: env.REALTIME_MAX_CONNECTIONS_PER_IP,
    maxBufferedBytes: env.REALTIME_MAX_BUFFERED_BYTES,
    trustProxy: env.TRUST_PROXY,
    trustProxyHops: env.TRUST_PROXY_HOPS,
  };
};

const clientIpForRequest = (
  request: IncomingMessage,
  options: Pick<Required<WorkflowSocketOptions>, 'trustProxy' | 'trustProxyHops'>,
): string => {
  const peerAddress = request.socket.remoteAddress ?? 'unknown';
  if (!options.trustProxy) {
    return peerAddress;
  }
  const forwarded = String(request.headers['x-forwarded-for'] ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  const index = forwarded.length - options.trustProxyHops;
  const candidate = index >= 0 ? forwarded[index] : '';
  return isIP(candidate) !== 0 ? candidate : peerAddress;
};

const authenticateSocket = async (token: string): Promise<WorkflowSocketUser> => {
  const decoded = verifyAccessToken(token);
  const result = await query(
    `SELECT id, email, role, is_active, auth_version, email_verified_at, phone_verified_at,
            phone_format_validated_at, contact_verification_exempted_at
     FROM "user"
     WHERE id = $1`,
    [decoded.userId],
  );
  const user = result.rows[0];
  if (
    !user ||
    !user.is_active ||
    !isContactAssuranceSatisfied(user) ||
    decoded.authVersion !== Number(user.auth_version) ||
    !(await isSessionCurrent({
      sessionId: decoded.sessionId,
      userId: decoded.userId,
      authVersion: decoded.authVersion,
    }))
  ) {
    throw new Error('Realtime user session is not active');
  }

  return {
    id: user.id,
    role: user.role,
    sessionId: decoded.sessionId,
    authVersion: decoded.authVersion,
    tokenExpiresAt: Number(decoded.exp) * 1000,
    protectedSuperAdmin: isProtectedSuperAdminEmail(user.email),
  };
};

const coarseWorkflowPath = (rawPath: string): string => {
  const segments = rawPath.split('?')[0].split('/').filter(Boolean);
  const apiIndex = segments.findIndex((segment) => /^v\d+$/i.test(segment));
  const resourceIndex = apiIndex >= 0 ? apiIndex + 1 : 0;
  const resource = segments[resourceIndex] ?? 'workflow';
  return `/${segments.slice(0, resourceIndex).join('/')}/${resource}`.replace(/\/+/g, '/');
};

const eventForUser = (
  event: WorkflowChangeEvent,
  user: WorkflowSocketUser,
): Record<string, unknown> | null => {
  const path = coarseWorkflowPath(event.path);
  const isActor = event.actorUserId === user.id;
  const isTarget = event.targetUserId === user.id;
  const isAdmin = user.role === 'admin';

  if ((path.endsWith('/users') || path.endsWith('/notifications')) && !isAdmin && !isActor && !isTarget) {
    return null;
  }

  return {
    type: event.type,
    id: event.id,
    occurredAt: event.occurredAt,
    method: event.method,
    path,
    actorUserId: isActor ? user.id : null,
    targetUserId: isTarget || isAdmin ? (event.targetUserId ?? null) : null,
    targetAction: isTarget || isAdmin ? (event.targetAction ?? null) : null,
  };
};

const parseAuthenticationPayload = (raw: RawData): AuthenticationMessage => {
  const parsed = JSON.parse(raw.toString()) as Record<string, unknown>;
  if (
    !parsed ||
    typeof parsed !== 'object' ||
    parsed.type !== 'authenticate' ||
    typeof parsed.token !== 'string' ||
    parsed.token.trim().length === 0
  ) {
    throw new Error('Invalid realtime authentication message');
  }
  const knownRevisions = parseKnownRevisions(parsed.knownRevisions);
  const scopes = parseKnownRevisions(
    Array.isArray(parsed.scopes)
      ? parsed.scopes.map((scope) => ({
          ...(scope as Record<string, unknown>),
          revision: 0,
        }))
      : [],
  ).map(({ scopeType, scopeId }) => ({ scopeType, scopeId }));
  return { token: parsed.token.trim(), knownRevisions, scopes };
};

const parseAuthenticationMessage = (raw: RawData): string => parseAuthenticationPayload(raw).token;

const accessAllowsAudience = (
  access: ProjectAccess,
  required: Extract<RealtimeAudience, { kind: 'project' }>['access'],
): boolean => {
  if (access === 'admin') {
    return true;
  }
  if (required === 'readers') {
    return access !== 'none';
  }
  if (required === 'members') {
    return access === 'member' || access === 'project_admin';
  }
  return access === 'project_admin';
};

const resolveProjectAccess = async (
  projectId: string,
  user: WorkflowSocketUser,
): Promise<ProjectAccess> => {
  if (user.role === 'admin') {
    return 'admin';
  }
  const visibilityColumn = user.role === 'viewer' ? 'visible_to_viewers' : 'visible_to_contributors';
  const result = await query(
    `SELECT
       (SELECT role
        FROM project_assignment
        WHERE project_id = $1
          AND user_id = $2
          AND status = 'approved'
        LIMIT 1) AS assignment_role,
       EXISTS (
         SELECT 1
         FROM project
         WHERE id = $1
           AND ${visibilityColumn} = TRUE
           AND status::text = ANY($3::text[])
       ) AS is_public_project`,
    [projectId, user.id, publicVisibleStatuses],
  );
  const role = result.rows[0]?.assignment_role;
  if (role === 'admin') {
    return 'project_admin';
  }
  if (role) {
    return 'member';
  }
  return result.rows[0]?.is_public_project === true ? 'public' : 'none';
};

const scopeProjectId = (
  scope: RealtimeScope,
  client?: AuthenticatedClient,
): string | null => {
  if (['project', 'features', 'reviews', 'imports_project', 'ai'].includes(scope.scopeType)) {
    return scope.scopeId;
  }
  if (['feature', 'ai_run', 'import', 'export'].includes(scope.scopeType)) {
    return client?.scopeProjects.get(realtimeScopeKey(scope)) ?? null;
  }
  return null;
};

const authorizeScope = async (
  scope: RealtimeScope,
  client: AuthenticatedClient,
): Promise<boolean> => {
  const { user } = client;
  if (scope.scopeType === 'notifications') {
    return scope.scopeId === user.id;
  }
  if (scope.scopeType === 'session') {
    return scope.scopeId === user.sessionId;
  }
  if (scope.scopeType === 'user') {
    return scope.scopeId === user.id;
  }
  if (['privacy_requests', 'content_reports'].includes(scope.scopeType)) {
    return scope.scopeId === user.id;
  }
  if (['privacy_admin_queue', 'moderation_admin_queue'].includes(scope.scopeType)) {
    return user.protectedSuperAdmin && scope.scopeId === 'all';
  }
  if (scope.scopeType === 'settings') {
    return scope.scopeId === 'support' || (user.role === 'admin' && scope.scopeId === 'all');
  }
  if (scope.scopeType === 'assignments') {
    return scope.scopeId === user.id || (user.role === 'admin' && scope.scopeId === 'all');
  }
  if (scope.scopeType === 'users') {
    return user.role === 'admin' && scope.scopeId === 'all';
  }
  if (scope.scopeType === 'reviews' && scope.scopeId === 'all') {
    return user.role === 'admin';
  }
  if (['imports', 'exports'].includes(scope.scopeType)) {
    return scope.scopeId === user.id || (user.role === 'admin' && scope.scopeId === 'all');
  }
  if (['projects', 'categories', 'offline_map'].includes(scope.scopeType)) {
    return scope.scopeId === 'all';
  }
  if (scope.scopeType === 'feature') {
    const featureResult = await query(
      'SELECT project_id FROM spatial_feature WHERE id = $1',
      [scope.scopeId],
    );
    const featureProjectId = featureResult.rows[0]?.project_id as string | undefined;
    if (!featureProjectId) {
      return false;
    }
    client.scopeProjects.set(realtimeScopeKey(scope), featureProjectId);
    const cached = client.projectAccess.get(featureProjectId);
    const access = cached ?? (await resolveProjectAccess(featureProjectId, user));
    client.projectAccess.set(featureProjectId, access);
    return access !== 'none';
  }
  if (scope.scopeType === 'ai_run') {
    const runResult = await query('SELECT project_id FROM ai_run WHERE id = $1', [scope.scopeId]);
    const runProjectId = runResult.rows[0]?.project_id as string | undefined;
    if (!runProjectId) {
      return false;
    }
    client.scopeProjects.set(realtimeScopeKey(scope), runProjectId);
    const cached = client.projectAccess.get(runProjectId);
    const access = cached ?? (await resolveProjectAccess(runProjectId, user));
    client.projectAccess.set(runProjectId, access);
    return access !== 'none';
  }
  if (scope.scopeType === 'import') {
    const importResult = await query(
      'SELECT project_id, uploaded_by_user_id FROM gis_import_job WHERE id = $1',
      [scope.scopeId],
    );
    const importJob = importResult.rows[0] as
      | { project_id: string; uploaded_by_user_id: string }
      | undefined;
    if (!importJob) {
      return false;
    }
    client.scopeProjects.set(realtimeScopeKey(scope), importJob.project_id);
    if (user.role === 'admin' || importJob.uploaded_by_user_id === user.id) {
      return true;
    }
    const cached = client.projectAccess.get(importJob.project_id);
    const access = cached ?? (await resolveProjectAccess(importJob.project_id, user));
    client.projectAccess.set(importJob.project_id, access);
    return access === 'project_admin';
  }
  if (scope.scopeType === 'export') {
    const exportResult = await query(
      'SELECT project_id, requested_by_user_id FROM shapefile_export WHERE id = $1',
      [scope.scopeId],
    );
    const exportJob = exportResult.rows[0] as
      | { project_id: string; requested_by_user_id: string }
      | undefined;
    if (!exportJob) {
      return false;
    }
    client.scopeProjects.set(realtimeScopeKey(scope), exportJob.project_id);
    return user.role === 'admin' || exportJob.requested_by_user_id === user.id;
  }
  const projectId = scopeProjectId(scope);
  if (!projectId) {
    return false;
  }
  const cached = client.projectAccess.get(projectId);
  const access = cached ?? (await resolveProjectAccess(projectId, user));
  client.projectAccess.set(projectId, access);
  return access !== 'none';
};

const isLocalDevelopmentOrigin = (origin: string): boolean => {
  try {
    const url = new URL(origin);
    return (
      (url.protocol === 'http:' || url.protocol === 'https:') &&
      ['localhost', '127.0.0.1', '[::1]', '::1'].includes(url.hostname)
    );
  } catch {
    return false;
  }
};

const originAllowed = (
  request: IncomingMessage,
  options: Required<WorkflowSocketOptions>,
): boolean => {
  const origin = String(request.headers.origin ?? '').trim();
  if (!origin) {
    return true;
  }
  if (options.allowedOrigins.includes(origin)) {
    return true;
  }
  return options.nodeEnv !== 'production' && isLocalDevelopmentOrigin(origin);
};

const hostAllowed = (
  request: IncomingMessage,
  options: Required<WorkflowSocketOptions>,
): boolean => {
  const host = String(request.headers.host ?? '').trim().toLowerCase();
  if (!host) {
    return false;
  }
  if (options.allowedHosts.includes(host)) {
    return true;
  }
  return options.nodeEnv !== 'production';
};

const addToIndex = <T>(index: Map<string, Set<T>>, key: string, value: T): void => {
  const values = index.get(key) ?? new Set<T>();
  values.add(value);
  index.set(key, values);
};

const removeFromIndex = <T>(index: Map<string, Set<T>>, key: string, value: T): void => {
  const values = index.get(key);
  values?.delete(value);
  if (values?.size === 0) {
    index.delete(key);
  }
};

export const attachWorkflowSocket = (
  server: HttpServer,
  apiPrefix: string,
  envOrOptions?: EnvConfig | WorkflowSocketOptions,
): (() => void) => {
  const supplied = envOrOptions && 'NODE_ENV' in envOrOptions
    ? socketOptionsFromEnv(envOrOptions as EnvConfig)
    : (envOrOptions as WorkflowSocketOptions | undefined) ?? {};
  const options = { ...defaultOptions, ...supplied };
  if (!options.enabled) {
    return () => undefined;
  }

  const path = `${apiPrefix.replace(/\/+$/, '')}/realtime/workflow`;
  const socketServer = new WebSocketServer({
    server,
    path,
    maxPayload: 4096,
    perMessageDeflate: false,
    verifyClient: ({ req }) => originAllowed(req, options) && hostAllowed(req, options),
  });
  const clients = new Map<WebSocket, AuthenticatedClient>();
  const connectionsByUser = new Map<string, Set<WebSocket>>();
  const connectionsBySession = new Map<string, Set<WebSocket>>();
  const connectionsByIp = new Map<string, Set<WebSocket>>();
  const connectionsByScope = new Map<string, Set<WebSocket>>();
  const projectConnections = new Map<string, Set<WebSocket>>();
  const adminConnections = new Set<WebSocket>();
  const protectedAdminConnections = new Set<WebSocket>();

  const closeForBackpressure = (socket: WebSocket): void => {
    realtimeMetrics.dropped();
    realtimeMetrics.slowClientClosed();
    socket.close(1013, 'resync_required');
  };

  const sendJson = (socket: WebSocket, payload: unknown): boolean => {
    if (socket.readyState !== socket.OPEN) {
      return false;
    }
    if (socket.bufferedAmount > options.maxBufferedBytes) {
      closeForBackpressure(socket);
      return false;
    }
    try {
      assertRealtimePayloadSize(payload);
      socket.send(JSON.stringify(payload));
      return true;
    } catch (error) {
      realtimeMetrics.dropped();
      logger.warn('Realtime payload was not delivered', {
        message: error instanceof Error ? error.message : String(error),
      });
      return false;
    }
  };

  const unregisterScopeSubscriptions = (socket: WebSocket, client: AuthenticatedClient): void => {
    for (const key of client.subscribedScopes.keys()) {
      removeFromIndex(connectionsByScope, key, socket);
    }
    const projectIds = new Set(
      [...client.subscribedScopes.values()]
        .map((scope) => scopeProjectId(scope, client))
        .filter((value): value is string => value != null),
    );
    for (const projectId of projectIds) {
      removeFromIndex(projectConnections, projectId, socket);
    }
  };

  const updateSubscriptions = async (
    socket: WebSocket,
    client: AuthenticatedClient,
    scopes: RealtimeScope[],
    knownRevisions: RealtimeKnownRevision[],
  ): Promise<void> => {
    const requested = new Map<string, RealtimeScope>();
    for (const scope of scopes) {
      if (await authorizeScope(scope, client)) {
        requested.set(realtimeScopeKey(scope), scope);
      }
    }
    for (const known of knownRevisions) {
      if (await authorizeScope(known, client)) {
        requested.set(realtimeScopeKey(known), {
          scopeType: known.scopeType,
          scopeId: known.scopeId,
        });
      }
    }

    unregisterScopeSubscriptions(socket, client);
    client.subscribedScopes = requested;
    for (const scope of requested.values()) {
      addToIndex(connectionsByScope, realtimeScopeKey(scope), socket);
      const projectId = scopeProjectId(scope, client);
      if (projectId) {
        addToIndex(projectConnections, projectId, socket);
      }
    }

    const authorizedKnown = knownRevisions.filter((known) => requested.has(realtimeScopeKey(known)));
    const current = await getScopeRevisions({ query }, authorizedKnown);
    const knownByKey = new Map(authorizedKnown.map((item) => [realtimeScopeKey(item), item.revision]));
    const staleScopes = current.filter(
      (item) => item.revision > (knownByKey.get(realtimeScopeKey(item)) ?? 0),
    );
    realtimeMetrics.reconciled(staleScopes.length);
    sendJson(socket, {
      type: 'realtime_scopes_ready',
      protocolVersion: realtimeProtocolVersion,
      revisions: current,
      staleScopes,
      occurredAt: new Date().toISOString(),
    });
  };

  const socketsForAudience = (event: RealtimeDomainEvent): Set<WebSocket> => {
    const audience = event.audience;
    if (audience.kind === 'all_authenticated') {
      return new Set(clients.keys());
    }
    if (audience.kind === 'admins') {
      return new Set(adminConnections);
    }
    if (audience.kind === 'protected_admins') {
      return new Set(protectedAdminConnections);
    }
    if (audience.kind === 'scope_subscribers') {
      return new Set(connectionsByScope.get(realtimeScopeKey(event)) ?? []);
    }
    if (audience.kind === 'user') {
      return new Set(connectionsByUser.get(audience.userId) ?? []);
    }
    if (audience.kind === 'users') {
      const result = new Set<WebSocket>();
      for (const userId of audience.userIds) {
        for (const socket of connectionsByUser.get(userId) ?? []) {
          result.add(socket);
        }
      }
      return result;
    }
    if (audience.kind === 'session') {
      return new Set(connectionsBySession.get(audience.sessionId) ?? []);
    }
    return new Set(projectConnections.get(audience.projectId) ?? []);
  };

  const refreshProjectAuthorization = (
    event: RealtimeDomainEvent,
    audienceSockets: Set<WebSocket>,
  ): void => {
    if (!event.projectId || !['assignment', 'project'].includes(event.entityType)) {
      return;
    }
    if (
      event.entityType === 'assignment' &&
      event.audience.kind !== 'user' &&
      event.audience.kind !== 'users'
    ) {
      return;
    }
    const candidates = event.entityType === 'project'
      ? new Set(projectConnections.get(event.projectId) ?? [])
      : audienceSockets;
    for (const socket of candidates) {
      const client = clients.get(socket);
      if (!client || !projectConnections.get(event.projectId)?.has(socket)) {
        continue;
      }
      client.projectAccess.delete(event.projectId);
      void resolveProjectAccess(event.projectId, client.user)
        .then(async (access) => {
          if (clients.get(socket) !== client) {
            return;
          }
          client.projectAccess.set(event.projectId!, access);
          if (access !== 'none') {
            return;
          }
          let removedAnyScope = false;
          for (const [key, scope] of client.subscribedScopes) {
            if (scopeProjectId(scope, client) === event.projectId) {
              if (await authorizeScope(scope, client)) {
                continue;
              }
              client.subscribedScopes.delete(key);
              removeFromIndex(connectionsByScope, key, socket);
              removedAnyScope = true;
            }
          }
          removeFromIndex(projectConnections, event.projectId!, socket);
          if (!removedAnyScope) {
            return;
          }
          sendJson(socket, {
            type: 'realtime_subscription_revoked',
            protocolVersion: realtimeProtocolVersion,
            projectId: event.projectId,
            occurredAt: new Date().toISOString(),
          });
        })
        .catch((error) => {
          logger.warn('Realtime project authorization refresh failed', {
            message: error instanceof Error ? error.message : String(error),
          });
        });
    }
  };

  const unsubscribeRealtime = subscribeRealtimeChanges((event) => {
    if (!options.v2Enabled) {
      return;
    }
    const audienceSockets = socketsForAudience(event);
    for (const socket of audienceSockets) {
      const client = clients.get(socket);
      if (!client) {
        continue;
      }
      if (!client.subscribedScopes.has(realtimeScopeKey(event))) {
        continue;
      }
      if (event.audience.kind === 'project') {
        const access = client.projectAccess.get(event.audience.projectId) ?? 'none';
        if (!accessAllowsAudience(access, event.audience.access)) {
          continue;
        }
      }
      const safeEvent: RealtimeClientEvent = {
        protocolVersion: event.protocolVersion,
        type: event.type,
        eventId: event.eventId,
        action: event.action,
        entityType: event.entityType,
        entityId: event.entityId,
        projectId: event.projectId,
        scopeType: event.scopeType,
        scopeId: event.scopeId,
        revision: event.revision,
        occurredAt: event.occurredAt,
        originatedByCurrentSession: event.originSessionId === client.user.sessionId,
      };
      if (sendJson(socket, safeEvent)) {
        realtimeMetrics.delivered();
        realtimeMetrics.deliveryLatency(Date.now() - Date.parse(event.occurredAt));
      }
    }
    refreshProjectAuthorization(event, audienceSockets);

    if (
      event.entityType === 'user' &&
      ['blocked', 'deactivated', 'session_revoked', 'role_changed', 'account_deletion_completed'].includes(event.action)
    ) {
      const targets = socketsForAudience(event);
      for (const socket of targets) {
        const client = clients.get(socket);
        if (
          event.action === 'session_revoked' &&
          event.originSessionId != null &&
          event.originSessionId === client?.user.sessionId
        ) {
          continue;
        }
        socket.close(1008, event.action);
      }
    }
  });

  const unsubscribeLegacy = subscribeWorkflowChanges((event) => {
    if (!options.legacyEnabled) {
      return;
    }
    for (const [socket, client] of clients) {
      const safeEvent = eventForUser(event, client.user);
      if (safeEvent) {
        sendJson(socket, safeEvent);
      }
    }
  });

  const heartbeat = setInterval(() => {
    let bufferedSockets = 0;
    for (const [socket, client] of clients) {
      if (socket.readyState !== socket.OPEN) {
        continue;
      }
      if (socket.bufferedAmount > 0) {
        bufferedSockets += 1;
      }
      if (client.user.tokenExpiresAt <= Date.now()) {
        socket.close(1008, 'token_expired');
        continue;
      }
      if (!client.alive) {
        socket.terminate();
        continue;
      }
      client.alive = false;
      socket.ping();
    }
    realtimeMetrics.bufferedSocketCount(bufferedSockets);
  }, options.heartbeatIntervalMs);
  heartbeat.unref?.();

  socketServer.on('connection', (socket, request) => {
    realtimeMetrics.connectionAttempt();
    const ipAddress = clientIpForRequest(request, options);
    const ipConnections = connectionsByIp.get(ipAddress) ?? new Set<WebSocket>();
    if (ipConnections.size >= options.maxConnectionsPerIp) {
      socket.close(1013, 'ip_connection_limit');
      return;
    }
    addToIndex(connectionsByIp, ipAddress, socket);

    const authenticationTimeout = setTimeout(() => {
      if (!clients.has(socket)) {
        socket.close(1008, 'authentication_timeout');
      }
    }, options.authenticationTimeoutMs);
    authenticationTimeout.unref?.();

    const onAuthenticationMessage = async (raw: RawData): Promise<void> => {
      if (clients.has(socket)) {
        return;
      }
      try {
        const message = parseAuthenticationPayload(raw);
        const user = await authenticateSocket(message.token);
        if (message.knownRevisions.some((known) => known.revision > 0)) {
          realtimeMetrics.reconnected();
        }
        const userConnections = connectionsByUser.get(user.id) ?? new Set<WebSocket>();
        if (userConnections.size >= options.maxConnectionsPerUser) {
          socket.close(1013, 'user_connection_limit');
          return;
        }
        clearTimeout(authenticationTimeout);
        const client: AuthenticatedClient = {
          user,
          ipAddress,
          projectAccess: new Map(),
          scopeProjects: new Map(),
          subscribedScopes: new Map(),
          alive: true,
        };
        clients.set(socket, client);
        addToIndex(connectionsByUser, user.id, socket);
        addToIndex(connectionsBySession, user.sessionId, socket);
        if (user.role === 'admin') {
          adminConnections.add(socket);
        }
        if (user.protectedSuperAdmin) {
          protectedAdminConnections.add(socket);
        }
        realtimeMetrics.connected();
        sendJson(socket, {
          type: 'workflow_realtime_ready',
          protocolVersion: realtimeProtocolVersion,
          userId: user.id,
          occurredAt: new Date().toISOString(),
        });
        if (options.v2Enabled) {
          await updateSubscriptions(socket, client, message.scopes, message.knownRevisions);
        }
      } catch (error) {
        realtimeMetrics.authenticationFailed();
        const closeReason =
          error instanceof Error && error.name === 'TokenExpiredError'
            ? 'token_expired'
            : 'unauthorized';
        logger.warn('Workflow realtime authentication failed', {
          message: error instanceof Error ? error.message : String(error),
        });
        socket.close(1008, closeReason);
      }
    };

    socket.once('message', (raw) => void onAuthenticationMessage(raw));
    socket.on('message', (raw) => {
      const client = clients.get(socket);
      if (!client) {
        return;
      }
      try {
        const message = JSON.parse(raw.toString()) as Record<string, unknown>;
        if (message.type !== 'subscribe') {
          return;
        }
        const knownRevisions = parseKnownRevisions(message.knownRevisions);
        const scopes = parseKnownRevisions(
          Array.isArray(message.scopes)
            ? message.scopes.map((scope) => ({
                ...(scope as Record<string, unknown>),
                revision: 0,
              }))
            : [],
        ).map(({ scopeType, scopeId }) => ({ scopeType, scopeId }));
        void updateSubscriptions(socket, client, scopes, knownRevisions).catch((error) => {
          logger.warn('Realtime scope subscription failed', {
            message: error instanceof Error ? error.message : String(error),
          });
          socket.close(1011, 'subscription_failed');
        });
      } catch {
        socket.close(1008, 'invalid_subscription');
      }
    });
    socket.on('pong', () => {
      const client = clients.get(socket);
      if (client) {
        client.alive = true;
      }
    });
    socket.on('close', (_code, reason) => {
      clearTimeout(authenticationTimeout);
      removeFromIndex(connectionsByIp, ipAddress, socket);
      const client = clients.get(socket);
      if (!client) {
        return;
      }
      unregisterScopeSubscriptions(socket, client);
      removeFromIndex(connectionsByUser, client.user.id, socket);
      removeFromIndex(connectionsBySession, client.user.sessionId, socket);
      adminConnections.delete(socket);
      protectedAdminConnections.delete(socket);
      clients.delete(socket);
      realtimeMetrics.disconnected(reason.toString() || 'closed');
    });
    socket.on('error', (error) => {
      const client = clients.get(socket);
      logger.warn('Workflow realtime socket error', {
        authenticated: client != null,
        message: error instanceof Error ? error.message : String(error),
      });
    });
  });

  logger.info('Workflow realtime socket attached', {
    path,
    protocolVersion: realtimeProtocolVersion,
    v2Enabled: options.v2Enabled,
    legacyEnabled: options.legacyEnabled,
  });
  return () => {
    clearInterval(heartbeat);
    unsubscribeRealtime();
    unsubscribeLegacy();
    for (const socket of clients.keys()) {
      socket.close(1001, 'server_shutting_down');
    }
    clients.clear();
    connectionsByUser.clear();
    connectionsBySession.clear();
    connectionsByIp.clear();
    connectionsByScope.clear();
    projectConnections.clear();
    adminConnections.clear();
    protectedAdminConnections.clear();
    socketServer.close();
  };
};

export {
  authenticateSocket,
  authorizeScope,
  clientIpForRequest,
  coarseWorkflowPath,
  eventForUser,
  parseAuthenticationMessage,
  parseAuthenticationPayload,
  hostAllowed,
  originAllowed,
  resolveProjectAccess,
};
