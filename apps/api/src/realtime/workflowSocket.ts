import type { Server as HttpServer } from 'http';
import { WebSocketServer, type RawData, type WebSocket } from 'ws';
import { query } from '../config/database';
import { isContactAssuranceSatisfied } from '../services/contactAssurancePolicy.service';
import { isSessionCurrent } from '../services/authSession.service';
import { verifyAccessToken } from '../services/authToken.service';
import type { user_role } from '../types/roles';
import { subscribeWorkflowChanges, type WorkflowChangeEvent } from './workflowEvents';
const logger = require('../utils/logger');

interface WorkflowSocketUser {
  id: string;
  role: user_role;
  sessionId: string;
  authVersion: number;
  tokenExpiresAt: number;
}

const authenticateSocket = async (token: string): Promise<WorkflowSocketUser> => {
  const decoded = verifyAccessToken(token);
  const result = await query(
    `SELECT id, role, is_active, auth_version, email_verified_at, phone_verified_at,
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
  };
};

const sendJson = (socket: WebSocket, payload: unknown): void => {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
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

const parseAuthenticationMessage = (raw: RawData): string => {
  const parsed = JSON.parse(raw.toString());
  if (
    !parsed ||
    typeof parsed !== 'object' ||
    parsed.type !== 'authenticate' ||
    typeof parsed.token !== 'string' ||
    parsed.token.trim().length === 0
  ) {
    throw new Error('Invalid realtime authentication message');
  }
  return parsed.token.trim();
};

export const attachWorkflowSocket = (
  server: HttpServer,
  apiPrefix: string,
): (() => void) => {
  const path = `${apiPrefix.replace(/\/+$/, '')}/realtime/workflow`;
  const socketServer = new WebSocketServer({
    server,
    path,
    maxPayload: 4096,
    perMessageDeflate: false,
  });
  const authenticatedClients = new Map<WebSocket, WorkflowSocketUser>();

  const heartbeat = setInterval(() => {
    for (const [socket, user] of authenticatedClients) {
      if (socket.readyState !== socket.OPEN) {
        continue;
      }
      if (user.tokenExpiresAt <= Date.now()) {
        socket.close(1008, 'Session expired');
        continue;
      }
      void isSessionCurrent({
        sessionId: user.sessionId,
        userId: user.id,
        authVersion: user.authVersion,
      })
        .then((active) => {
          if (!active && socket.readyState === socket.OPEN) {
            socket.close(1008, 'Session revoked');
          } else if (active && socket.readyState === socket.OPEN) {
            socket.ping();
          }
        })
        .catch((error) => {
          logger.warn('Workflow realtime session revalidation failed', {
            userId: user.id,
            message: error instanceof Error ? error.message : String(error),
          });
          if (socket.readyState === socket.OPEN) {
            socket.close(1011, 'Session validation unavailable');
          }
        });
    }
  }, 30000);

  socketServer.on('connection', (socket) => {
    let unsubscribe: (() => void) | null = null;
    const authenticationTimeout = setTimeout(() => {
      if (!authenticatedClients.has(socket)) {
        socket.close(1008, 'Authentication timeout');
      }
    }, 5000);
    authenticationTimeout.unref?.();

    const onAuthenticationMessage = async (raw: RawData): Promise<void> => {
      if (authenticatedClients.has(socket)) {
        return;
      }
      try {
        const user = await authenticateSocket(parseAuthenticationMessage(raw));
        clearTimeout(authenticationTimeout);
        authenticatedClients.set(socket, user);
        sendJson(socket, {
          type: 'workflow_realtime_ready',
          userId: user.id,
          occurredAt: new Date().toISOString(),
        });
        unsubscribe = subscribeWorkflowChanges((event) => {
          const safeEvent = eventForUser(event, user);
          if (safeEvent) {
            sendJson(socket, safeEvent);
          }
        });
      } catch (error) {
        logger.warn('Workflow realtime authentication failed', {
          message: error instanceof Error ? error.message : String(error),
        });
        socket.close(1008, 'Unauthorized');
      }
    };

    socket.once('message', (raw) => {
      void onAuthenticationMessage(raw);
    });
    socket.on('close', () => {
      clearTimeout(authenticationTimeout);
      authenticatedClients.delete(socket);
      unsubscribe?.();
    });
    socket.on('error', (error) => {
      const user = authenticatedClients.get(socket);
      logger.warn('Workflow realtime socket error', {
        userId: user?.id,
        message: error instanceof Error ? error.message : String(error),
      });
    });
  });

  logger.info('Workflow realtime socket attached', { path });
  return () => {
    clearInterval(heartbeat);
    for (const socket of authenticatedClients.keys()) {
      socket.close(1001, 'Server shutting down');
    }
    authenticatedClients.clear();
    socketServer.close();
  };
};

export { authenticateSocket, coarseWorkflowPath, eventForUser, parseAuthenticationMessage };
