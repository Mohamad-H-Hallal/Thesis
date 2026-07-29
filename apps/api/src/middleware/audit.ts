import type { NextFunction, Request, Response } from 'express';
import { query } from '../config/database';
const logger = require('../utils/logger');

type AuditActionType =
  | 'create'
  | 'update'
  | 'delete'
  | 'approve'
  | 'reject'
  | 'export'
  | 'comment';

interface AuditActionOptions {
  actionType: AuditActionType;
  entityType: string;
  resolveEntityId: (req: Request, res: Response, responseBody: any) => string | null | undefined;
  resolveOldValues?: (req: Request, res: Response, responseBody: any) => Record<string, unknown> | null;
  resolveNewValues?: (req: Request, res: Response, responseBody: any) => Record<string, unknown> | null;
}

interface DynamicAuditActionOptions extends Omit<AuditActionOptions, 'actionType'> {
  resolveActionType: (
    req: Request,
    res: Response,
    responseBody: any
  ) => AuditActionType | null | undefined;
}

const SENSITIVE_KEY_PATTERN =
  /^(?:password|password_hash|token|refresh_token|refreshToken|authorization|cookie|secret|private_?key|geometry|coordinates|feature_collection|file_buffer|raw_content)$/i;

const sanitizeObject = (input: unknown): unknown => {
  if (Array.isArray(input)) {
    return input.map(sanitizeObject);
  }

  if (!input || typeof input !== 'object') {
    return input;
  }

  const obj = input as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (SENSITIVE_KEY_PATTERN.test(key)) {
      out[key] = '[REDACTED]';
      continue;
    }
    out[key] = sanitizeObject(value);
  }
  return out;
};

const isUuid = (value: string): boolean => {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
};

const writeAuditLog = async (
  req: Request,
  res: Response,
  options: AuditActionOptions,
  entityId: string,
  responseBody: any
): Promise<void> => {
  try {
    if (process.env.AUDIT_LOG_ENABLED === 'false') {
      return;
    }

    if (!isUuid(entityId)) {
      return;
    }

    const oldValues = options.resolveOldValues
      ? sanitizeObject(options.resolveOldValues(req, res, responseBody))
      : null;
    const newValues = options.resolveNewValues
      ? sanitizeObject(options.resolveNewValues(req, res, responseBody))
      : sanitizeObject(req.body ?? null);

    await query(
      `INSERT INTO audit_log (user_id, action_type, entity_type, entity_id, old_values, new_values, ip_address)
       VALUES ($1, $2, $3, $4, $5, $6, $7::inet)`,
      [
        req.user?.id ?? null,
        options.actionType,
        options.entityType,
        entityId,
        oldValues ? JSON.stringify(oldValues) : null,
        newValues ? JSON.stringify(newValues) : null,
        req.ip ?? null,
      ]
    );
  } catch (error) {
    logger.warn('Failed to write audit log', {
      requestId: req.requestId,
      entityType: options.entityType,
      entityId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
};

const sendJsonAfterAudit = (
  req: Request,
  res: Response,
  originalJson: Response['json'],
  body: any,
  options: AuditActionOptions,
  entityId: string
): Response => {
  void (async () => {
    await writeAuditLog(req, res, options, entityId, body);
    originalJson(body);
  })();

  return res;
};

const auditAction = (options: AuditActionOptions) => {
  return (req: Request, res: Response, next: NextFunction): void => {
    const originalJson = res.json.bind(res);

    res.json = ((body: any) => {
      if (res.statusCode >= 200 && res.statusCode < 400) {
        const entityId = options.resolveEntityId(req, res, body);
        if (entityId) {
          return sendJsonAfterAudit(req, res, originalJson, body, options, entityId);
        }
      }

      return originalJson(body);
    }) as Response['json'];

    next();
  };
};

const auditDynamicAction = (options: DynamicAuditActionOptions) => {
  return (req: Request, res: Response, next: NextFunction): void => {
    const originalJson = res.json.bind(res);

    res.json = ((body: any) => {
      if (res.statusCode >= 200 && res.statusCode < 400) {
        const actionType = options.resolveActionType(req, res, body);
        const entityId = options.resolveEntityId(req, res, body);
        if (actionType && entityId) {
          return sendJsonAfterAudit(req, res, originalJson, body, { ...options, actionType }, entityId);
        }
      }

      return originalJson(body);
    }) as Response['json'];

    next();
  };
};

export { auditAction, auditDynamicAction };
