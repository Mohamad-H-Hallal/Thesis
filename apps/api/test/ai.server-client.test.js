const { createAiServerClient } = require('../src/services/aiServerClient.service');

const TRACKED_ENV_KEYS = [
  'AI_CALLBACK_BASE_URL',
  'AI_CALLBACK_SECRET',
  'AI_SERVER_TIMEOUT_MS',
  'AI_SERVER_URL',
  'API_VERSION_PREFIX',
  'APP_PUBLIC_API_URL',
  'PORT',
  'SUPER_ADMIN_EMAIL',
  'SUPER_ADMIN_FULL_NAME',
  'SUPER_ADMIN_PASSWORD',
];

const snapshotEnv = () =>
  TRACKED_ENV_KEYS.reduce((snapshot, key) => {
    snapshot[key] = process.env[key];
    return snapshot;
  }, {});

const restoreEnv = (snapshot) => {
  for (const key of TRACKED_ENV_KEYS) {
    if (snapshot[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = snapshot[key];
    }
  }
};

describe('AI server client environment config', () => {
  let originalEnv;

  beforeEach(() => {
    originalEnv = snapshotEnv();
    for (const key of TRACKED_ENV_KEYS) {
      delete process.env[key];
    }
  });

  afterEach(() => {
    restoreEnv(originalEnv);
  });

  test('ignores unrelated partial super admin env when building callback config', () => {
    process.env.SUPER_ADMIN_EMAIL = 'partial-superadmin@gov.lb';
    process.env.AI_SERVER_URL = ' http://ai-server.test/ ';
    process.env.APP_PUBLIC_API_URL = ' http://public-api.test/ ';
    process.env.AI_CALLBACK_SECRET = 'test-ai-callback-secret';
    process.env.AI_SERVER_TIMEOUT_MS = '5000';
    process.env.API_VERSION_PREFIX = 'api/v2/';

    const client = createAiServerClient();

    expect(client.isConfigured()).toBe(true);
    expect(client.callbackSecret()).toBe('test-ai-callback-secret');
    expect(client.callbackUrl('run-123')).toBe(
      'http://public-api.test/api/v2/ai/runs/run-123/callback',
    );
  });

  test('uses callback defaults when optional AI env values are missing', () => {
    process.env.PORT = '4100';

    const client = createAiServerClient();

    expect(client.isConfigured()).toBe(false);
    expect(client.callbackSecret()).toBe('dev-ai-callback-secret-change-me');
    expect(client.callbackUrl('run-456')).toBe(
      'http://localhost:4100/api/v1/ai/runs/run-456/callback',
    );
  });
});
