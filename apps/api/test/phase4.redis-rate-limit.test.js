const express = require('express');
const rateLimit = require('express-rate-limit');
const request = require('supertest');
const { createClient } = require('redis');

const redisUrl = process.env.PHASE4_REDIS_URL;
const describeRedis = redisUrl ? describe : describe.skip;

describeRedis('Phase 4 shared Redis/Valkey rate limiting', () => {
  let backend;
  let cleanupClient;

  beforeAll(async () => {
    process.env.RATE_LIMIT_STORE = 'redis';
    process.env.REDIS_URL = redisUrl;
    jest.resetModules();
    backend = require('../src/services/sharedRateLimit.service');
    await backend.initializeRateLimitBackend({
      RATE_LIMIT_STORE: 'redis',
      REDIS_URL: redisUrl,
      REDIS_CONNECT_TIMEOUT_MS: 3000,
    });
    cleanupClient = createClient({ url: redisUrl });
    await cleanupClient.connect();
    const keys = await cleanupClient.keys('gis-rate-limit:phase4-two-replica:*');
    if (keys.length > 0) {
      await cleanupClient.del(keys);
    }
  });

  afterAll(async () => {
    if (cleanupClient?.isOpen) {
      await cleanupClient.quit();
    }
    await backend?.closeRateLimitBackend();
  });

  const buildReplica = () => {
    const app = express();
    app.use(
      rateLimit({
        windowMs: 60000,
        max: 3,
        standardHeaders: true,
        legacyHeaders: false,
        passOnStoreError: false,
        keyGenerator: (req) => req.headers['x-test-user'],
        store: backend.createSharedRateLimitStore('phase4-two-replica'),
      }),
    );
    app.get('/expensive', (_req, res) => res.json({ success: true }));
    app.use((error, _req, res, _next) => {
      res.status(error.statusCode ?? 500).json({
        success: false,
        code: error.errorCode ?? 'INTERNAL_ERROR',
      });
    });
    return app;
  };

  test('two API replicas enforce one shared counter', async () => {
    const replicaA = buildReplica();
    const replicaB = buildReplica();
    const header = { 'x-test-user': 'shared-user' };

    await request(replicaA).get('/expensive').set(header).expect(200);
    await request(replicaB).get('/expensive').set(header).expect(200);
    await request(replicaA).get('/expensive').set(header).expect(200);
    const limited = await request(replicaB).get('/expensive').set(header).expect(429);

    expect(Number(limited.headers['retry-after'])).toBeGreaterThan(0);
  });

  test('backend outage fails closed instead of allowing expensive work', async () => {
    const replica = buildReplica();
    await backend.closeRateLimitBackend();

    const response = await request(replica)
      .get('/expensive')
      .set('x-test-user', 'outage-user')
      .expect(503);
    expect(response.body.code).toBe('RATE_LIMIT_BACKEND_UNAVAILABLE');
  });
});
