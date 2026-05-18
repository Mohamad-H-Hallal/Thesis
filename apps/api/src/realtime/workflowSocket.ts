import type { Server as HttpServer } from 'http';
import jwt, { type JwtPayload } from 'jsonwebtoken';
import { WebSocketServer, type WebSocket } from 'ws';
import { query } from '../config/database';
import { subscribeWorkflowChanges, type WorkflowChangeEvent } from './workflowEvents';
const logger = require('../utils/logger');

interface AccessTokenPayload extends JwtPayload {
  userId: string;
}

interface WorkflowSocketUser {
  id: string;
  role: string;
}

const getSecrets = (current: string, previousRaw?: string): string[] => {
  const previous = (previousRaw ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  return [current, ...previous].filter(Boolean);
};

const verifyToken = (token: string): AccessTokenPayload => {
  const secrets = getSecrets(
    process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET || '',
    process.env.JWT_SECRET_PREVIOUS,
  );
  let lastError: unknown = null;
  for (const secret of secrets) {
    try {
      return jwt.verify(token, secret) as AccessTokenPayload;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error('Token verification failed');
};

const authenticateSocket = async (token: string): Promise<WorkflowSocketUser> => {
  const decoded = verifyToken(token);
  const result = await query(
    'SELECT id, role FROM "user" WHERE id = $1 AND is_active = TRUE',
    [decoded.userId],
  );

  if (result.rows.length === 0) {
    throw new Error('Realtime user not found or inactive');
  }

  return {
    id: result.rows[0].id,
    role: result.rows[0].role,
  };
};

const sendJson = (socket: WebSocket, payload: unknown): void => {
  if (socket.readyState !== socket.OPEN) {
    return;
  }
  socket.send(JSON.stringify(payload));
};

export const attachWorkflowSocket = (
  server: HttpServer,
  apiPrefix: string,
): (() => void) => {
  const path = `${apiPrefix.replace(/\/+$/, '')}/realtime/workflow`;
  const socketServer = new WebSocketServer({ server, path });
  const heartbeat = setInterval(() => {
    for (const client of socketServer.clients) {
      if (client.readyState === client.OPEN) {
        client.ping();
      }
    }
  }, 30000);

  socketServer.on('connection', async (socket, request) => {
    const requestUrl = new URL(request.url ?? path, `http://${request.headers.host ?? 'localhost'}`);
    const token = requestUrl.searchParams.get('token')?.trim() ?? '';
    if (!token) {
      socket.close(1008, 'Missing token');
      return;
    }

    try {
      const user = await authenticateSocket(token);
      sendJson(socket, {
        type: 'workflow_realtime_ready',
        userId: user.id,
        occurredAt: new Date().toISOString(),
      });

      const unsubscribe = subscribeWorkflowChanges((event: WorkflowChangeEvent) => {
        sendJson(socket, event);
      });

      socket.on('close', unsubscribe);
      socket.on('error', (error) => {
        logger.warn('Workflow realtime socket error', {
          userId: user.id,
          message: error instanceof Error ? error.message : String(error),
        });
      });
    } catch (error) {
      logger.warn('Workflow realtime authentication failed', {
        message: error instanceof Error ? error.message : String(error),
      });
      socket.close(1008, 'Unauthorized');
    }
  });

  logger.info('Workflow realtime socket attached', { path });

  return () => {
    clearInterval(heartbeat);
    socketServer.close();
  };
};
