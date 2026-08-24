import type { NextFunction, Request, Response } from 'express';
import { publishWorkflowChange } from '../realtime/workflowEvents';

const mutationMethods = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
const ignoredMutationPaths = [
  /\/auth\/login$/i,
  /\/auth\/reactivate-login$/i,
  /\/auth\/refresh-token$/i,
  /\/notifications\/devices\/register$/i,
  /\/notifications\/devices\/unregister$/i,
];

const workflowPathForRequest = (req: Request): string =>
  (req.originalUrl || req.path).split('?')[0];

const userTargetForRequest = (
  req: Request,
): { targetUserId: string | null; targetAction: string | null } => {
  const path = workflowPathForRequest(req);
  const match = path.match(/\/users\/([^/]+)\/(block|deactivate|unblock)$/i);
  if (!match) {
    return { targetUserId: null, targetAction: null };
  }
  return {
    targetUserId: decodeURIComponent(match[1]),
    targetAction: match[2].toLowerCase(),
  };
};

const shouldBroadcastWorkflowChange = (req: Request, res: Response): boolean => {
  if (!/^(1|true)$/i.test(String(process.env.REALTIME_LEGACY_BROADCAST_ENABLED ?? 'true'))) {
    return false;
  }
  if (!mutationMethods.has(req.method.toUpperCase())) {
    return false;
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    return false;
  }
  const path = workflowPathForRequest(req);
  return !ignoredMutationPaths.some((pattern) => pattern.test(path));
};

export const broadcastWorkflowMutations = (
  req: Request,
  res: Response,
  next: NextFunction,
): void => {
  res.on('finish', () => {
    if (!shouldBroadcastWorkflowChange(req, res)) {
      return;
    }

    const target = userTargetForRequest(req);
    publishWorkflowChange({
      method: req.method.toUpperCase(),
      path: workflowPathForRequest(req),
      actorUserId: req.user?.id ?? null,
      requestId: req.requestId ?? null,
      targetUserId: target.targetUserId,
      targetAction: target.targetAction,
    });
  });

  next();
};
