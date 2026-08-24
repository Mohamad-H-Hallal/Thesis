const eventCounts = new Map<string, number>();
const disconnectCounts = new Map<string, number>();
const payloadBucketBounds = [256, 512, 1024, 2048, 4096];
const payloadBucketCounts = payloadBucketBounds.map(() => 0);
const allowedDisconnectReasons = new Set([
  'closed',
  'authentication_timeout',
  'unauthorized',
  'token_expired',
  'ip_connection_limit',
  'user_connection_limit',
  'resync_required',
  'subscription_failed',
  'invalid_subscription',
  'server_shutting_down',
  'blocked',
  'deactivated',
  'session_revoked',
  'role_changed',
]);

const metrics = {
  connections: 0,
  connectionAttempts: 0,
  reconnects: 0,
  authenticationFailures: 0,
  eventsDelivered: 0,
  eventsDropped: 0,
  eventsCoalesced: 0,
  slowClientClosures: 0,
  revisionReconciliations: 0,
  listenerReady: false,
  payloadBytesTotal: 0,
  payloadCount: 0,
  deliveryLatencyMsTotal: 0,
  deliveryLatencyCount: 0,
  bufferedSockets: 0,
};

export const realtimeMetrics = {
  connectionAttempt(): void {
    metrics.connectionAttempts += 1;
  },
  connected(): void {
    metrics.connections += 1;
  },
  reconnected(): void {
    metrics.reconnects += 1;
  },
  disconnected(reason: string): void {
    metrics.connections = Math.max(0, metrics.connections - 1);
    const boundedReason = allowedDisconnectReasons.has(reason) ? reason : 'other';
    disconnectCounts.set(boundedReason, (disconnectCounts.get(boundedReason) ?? 0) + 1);
  },
  authenticationFailed(): void {
    metrics.authenticationFailures += 1;
  },
  published(entityType: string, payloadBytes: number): void {
    eventCounts.set(entityType, (eventCounts.get(entityType) ?? 0) + 1);
    metrics.payloadBytesTotal += payloadBytes;
    metrics.payloadCount += 1;
    payloadBucketBounds.forEach((bound, index) => {
      if (payloadBytes <= bound) {
        payloadBucketCounts[index] += 1;
      }
    });
  },
  delivered(): void {
    metrics.eventsDelivered += 1;
  },
  dropped(): void {
    metrics.eventsDropped += 1;
  },
  coalesced(count = 1): void {
    metrics.eventsCoalesced += Math.max(0, count);
  },
  slowClientClosed(): void {
    metrics.slowClientClosures += 1;
  },
  reconciled(count: number): void {
    metrics.revisionReconciliations += Math.max(0, count);
  },
  deliveryLatency(durationMs: number): void {
    if (!Number.isFinite(durationMs) || durationMs < 0) {
      return;
    }
    metrics.deliveryLatencyMsTotal += durationMs;
    metrics.deliveryLatencyCount += 1;
  },
  bufferedSocketCount(count: number): void {
    metrics.bufferedSockets = Math.max(0, count);
  },
  listenerState(ready: boolean): void {
    metrics.listenerReady = ready;
  },
};

export const getRealtimeMetricsSnapshot = () => ({
  ...metrics,
  eventCounts: Object.fromEntries(eventCounts),
  disconnectCounts: Object.fromEntries(disconnectCounts),
  payloadBucketBounds,
  payloadBucketCounts,
});
