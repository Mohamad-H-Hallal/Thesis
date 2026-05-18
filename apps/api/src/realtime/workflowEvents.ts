import { randomUUID } from 'crypto';
import { EventEmitter } from 'events';
import { pool, query } from '../config/database';
const logger = require('../utils/logger');

export interface WorkflowChangeEvent {
  type: 'workflow_changed';
  id: string;
  occurredAt: string;
  method: string;
  path: string;
  actorUserId: string | null;
  requestId: string | null;
  targetUserId?: string | null;
  targetAction?: string | null;
}

type WorkflowChangeInput = Omit<WorkflowChangeEvent, 'type' | 'id' | 'occurredAt'>;
type WorkflowChangeListener = (event: WorkflowChangeEvent) => void;

interface WorkflowChangeNotificationPayload extends WorkflowChangeEvent {
  originInstanceId: string;
}

const workflowEvents = new EventEmitter();
workflowEvents.setMaxListeners(0);
const instanceId = randomUUID();
const recentlySeenEventIds = new Set<string>();

const markSeen = (eventId: string): boolean => {
  if (recentlySeenEventIds.has(eventId)) {
    return false;
  }
  recentlySeenEventIds.add(eventId);
  setTimeout(() => recentlySeenEventIds.delete(eventId), 60000).unref?.();
  return true;
};

const emitWorkflowChange = (event: WorkflowChangeEvent): void => {
  if (!markSeen(event.id)) {
    return;
  }
  workflowEvents.emit('workflow_changed', event);
};

export const publishWorkflowChange = (input: WorkflowChangeInput): WorkflowChangeEvent => {
  const event: WorkflowChangeEvent = {
    type: 'workflow_changed',
    id: randomUUID(),
    occurredAt: new Date().toISOString(),
    ...input,
  };
  emitWorkflowChange(event);
  const payload: WorkflowChangeNotificationPayload = {
    ...event,
    originInstanceId: instanceId,
  };
  void query('SELECT pg_notify($1, $2)', [
    'workflow_changed',
    JSON.stringify(payload),
  ]).catch((error) => {
    logger.warn('Unable to publish workflow realtime notification', {
      message: error instanceof Error ? error.message : String(error),
    });
  });
  return event;
};

export const subscribeWorkflowChanges = (listener: WorkflowChangeListener): (() => void) => {
  workflowEvents.on('workflow_changed', listener);
  return () => {
    workflowEvents.off('workflow_changed', listener);
  };
};

export const startWorkflowChangeListener = async (): Promise<() => void> => {
  const client = await pool.connect();
  await client.query('LISTEN workflow_changed');

  const onNotification = (message): void => {
    if (message.channel !== 'workflow_changed' || !message.payload) {
      return;
    }

    try {
      const payload = JSON.parse(message.payload) as WorkflowChangeNotificationPayload;
      if (payload.originInstanceId === instanceId) {
        return;
      }
      const event: WorkflowChangeEvent = {
        type: payload.type,
        id: payload.id,
        occurredAt: payload.occurredAt,
        method: payload.method,
        path: payload.path,
        actorUserId: payload.actorUserId,
        requestId: payload.requestId,
        targetUserId: payload.targetUserId,
        targetAction: payload.targetAction,
      };
      emitWorkflowChange(event);
    } catch (error) {
      logger.warn('Invalid workflow realtime notification payload', {
        message: error instanceof Error ? error.message : String(error),
      });
    }
  };

  client.on('notification', onNotification);
  logger.info('Workflow realtime database listener attached');

  return () => {
    client.off('notification', onNotification);
    client
      .query('UNLISTEN workflow_changed')
      .catch((error) =>
        logger.warn('Unable to unlisten workflow realtime channel', {
          message: error instanceof Error ? error.message : String(error),
        }),
      )
      .finally(() => client.release());
  };
};
