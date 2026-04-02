const request = require('supertest');
const { buildApp } = require('../src/app');
const { closePool } = require('../src/config/database');
const { validateEnv } = require('../src/config/env');

const API_PREFIX = process.env.API_PREFIX || '/api/v1';

const testEnv = {
    ...validateEnv(),
    NODE_ENV: 'test',
    CORS_ORIGIN: '',
    CORS_STRICT: false,
    CORS_CREDENTIALS: true,
    API_VERSION_PREFIX: API_PREFIX,
    ENABLE_LEGACY_API_PREFIX: true,
    METRICS_ENABLED: false,
    RATE_LIMIT_WINDOW_MS: 15 * 60 * 1000,
    RATE_LIMIT_MAX_REQUESTS: 1000,
};
describe('API smoke tests', () => {
  const app = buildApp(testEnv);

  afterAll(async () => {
    await closePool();
  });
    test('GET /health returns service status', async () => {
        const response = await request(app).get('/health');
        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.environment).toBe('test');
    });
    test(`GET ${API_PREFIX} returns API metadata`, async () => {
        const response = await request(app).get(API_PREFIX);
        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.documentation).toBe('/docs/openapi.yaml');
    });
    test('GET /docs/openapi.yaml serves OpenAPI spec', async () => {
        const response = await request(app).get('/docs/openapi.yaml');
        expect(response.status).toBe(200);
        expect(response.text).toContain('openapi: 3.0.3');
    });
    test(`POST ${API_PREFIX}/auth/login validates required fields`, async () => {
        const response = await request(app).post(`${API_PREFIX}/auth/login`).send({});
        expect(response.status).toBe(400);
        expect(response.body.success).toBe(false);
        expect(response.body.message).toBe('Validation failed');
    });
    test(`POST ${API_PREFIX}/auth/refresh-token validates token format`, async () => {
        const response = await request(app)
            .post(`${API_PREFIX}/auth/refresh-token`)
            .send({ refresh_token: 'not-a-jwt' });
        expect(response.status).toBe(400);
        expect(response.body.success).toBe(false);
        expect(response.body.message).toBe('Validation failed');
    });
});
