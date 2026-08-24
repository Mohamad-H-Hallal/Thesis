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
        expect(response.body.environment).toBeUndefined();
    });
    test(`GET ${API_PREFIX} returns API metadata`, async () => {
        const response = await request(app).get(API_PREFIX);
        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.documentation).toBe('/docs/');
        expect(response.body.openapi).toBe('/docs/openapi.json');
    });
    test('GET /docs/ serves interactive Swagger UI', async () => {
        const response = await request(app).get('/docs/');
        expect(response.status).toBe(200);
        expect(response.headers['content-type']).toContain('text/html');
        expect(response.text).toContain('TerraLeb API Documentation');
        expect(response.headers['content-security-policy']).toContain("default-src 'self'");
    });
    test('GET /docs/openapi.json serves the executable API contract', async () => {
        const response = await request(app).get('/docs/openapi.json');
        expect(response.status).toBe(200);
        expect(response.body.openapi).toBe('3.0.3');
        expect(response.body.servers).toEqual([expect.objectContaining({ url: '/' })]);
        expect(response.body.components.securitySchemes.bearerAuth).toEqual(
            expect.objectContaining({ type: 'http', scheme: 'bearer', bearerFormat: 'JWT' }),
        );
        expect(response.body.paths[`${API_PREFIX}/projects`].get.security).toEqual([
            { bearerAuth: [] },
        ]);
    });
    test('GET /docs/openapi.yaml serves OpenAPI spec', async () => {
        const response = await request(app).get('/docs/openapi.yaml');
        expect(response.status).toBe(200);
        expect(response.text).toContain('openapi: 3.0.3');
    });
    test.each([
        'privacy',
        'terms',
        'acceptable-use',
        'important-notices',
        'account-deletion',
        'subprocessors',
        'open-source',
    ])('GET /legal/%s serves a stable public legal page without authentication', async (slug) => {
        const response = await request(app).get(`/legal/${slug}`);
        expect(response.status).toBe(200);
        expect(response.headers['content-type']).toContain('text/html');
        expect(response.headers['content-security-policy']).toContain("default-src 'none'");
        expect(response.text).toContain('Version');
        expect(response.text).toContain('Legal-review draft');
    });
    test('GET /legal/account-deletion/request serves an accessible non-enumerating form', async () => {
        const response = await request(app).get('/legal/account-deletion/request');
        expect(response.status).toBe(200);
        expect(response.headers['cache-control']).toBe('no-store');
        expect(response.text).toContain('<label for="account-email">');
        expect(response.text).toContain('does not delete an account without identity verification');
        expect(response.text).not.toContain('checked');
    });
    test(`GET ${API_PREFIX}/legal/documents returns versioned mandatory policies without treating privacy as consent`, async () => {
        const response = await request(app)
            .get(`${API_PREFIX}/legal/documents`)
            .query({ format: 'json', locale: 'en' });
        expect(response.status).toBe(200);
        expect(response.body.data.mandatory_acceptance_types).toEqual([
            'terms',
            'acceptable_use',
        ]);
        expect(response.body.data.mandatory_acceptance_types).not.toContain('privacy');
        expect(response.body.data.documents).toEqual(
            expect.arrayContaining([
                expect.objectContaining({ type: 'terms', status: 'draft' }),
                expect.objectContaining({ type: 'privacy', status: 'draft' }),
            ]),
        );
    });
    test('can hide API documentation completely', async () => {
        const docsDisabledApp = buildApp({
            ...testEnv,
            API_DOCS_ENABLED: false,
        });
        const [uiResponse, specResponse] = await Promise.all([
            request(docsDisabledApp).get('/docs/'),
            request(docsDisabledApp).get('/docs/openapi.yaml'),
        ]);
        expect(uiResponse.status).toBe(404);
        expect(specResponse.status).toBe(404);
    });
    test('protects and serves Prometheus metrics without sensitive route queries', async () => {
        const metricsApp = buildApp({
            ...testEnv,
            METRICS_ENABLED: true,
            METRICS_TOKEN: 'metrics-token-for-test-only',
        });
        const unauthorized = await request(metricsApp).get('/metrics');
        expect(unauthorized.status).toBe(401);

        await request(metricsApp).get('/health?token=must-not-appear');
        const response = await request(metricsApp)
            .get('/metrics')
            .set('Authorization', 'Bearer metrics-token-for-test-only');
        expect(response.status).toBe(200);
        expect(response.headers['content-type']).toContain('text/plain');
        expect(response.text).toContain('# TYPE gis_api_http_requests_total counter');
        expect(response.text).toContain('gis_api_dependency_ready');
        expect(response.text).not.toContain('must-not-appear');
    });
    test('allows localhost browser origins on arbitrary ports outside production', async () => {
        const response = await request(app)
            .get('/health')
            .set('Origin', 'http://localhost:51680');
        expect(response.status).toBe(200);
        expect(response.headers['access-control-allow-origin']).toBe('http://localhost:51680');
    });
    test('blocks non-allowed external origins when CORS is strict', async () => {
        const strictApp = buildApp({
            ...testEnv,
            NODE_ENV: 'development',
            CORS_ORIGIN: 'http://localhost:3000',
            CORS_STRICT: true,
        });
        const response = await request(strictApp)
            .get('/health')
            .set('Origin', 'https://malicious.example.com');
        expect(response.status).toBe(403);
        expect(response.body.success).toBe(false);
        expect(response.body.message).toContain('Origin is not allowed by CORS');
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
