const {
  API_PREFIX,
  app,
  authHeader,
  createAdminUser,
  request,
  resetDb,
  shutdown,
} = require('./helpers/api-test-helpers');

const withTemporaryEnv = async (updates, fn) => {
  const previous = {};
  for (const key of Object.keys(updates)) {
    previous[key] = process.env[key];
    process.env[key] = updates[key];
  }

  try {
    return await fn();
  } finally {
    for (const key of Object.keys(updates)) {
      if (previous[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = previous[key];
      }
    }
  }
};

describe('Support settings', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('loads support contact settings without reading push notification configuration', async () => {
    const admin = await createAdminUser({
      fullName: 'Support Settings Admin',
      emailPrefix: 'support-settings-admin',
    });

    await withTemporaryEnv(
      {
        PUSH_NOTIFICATIONS_ENABLED: 'true',
        FIREBASE_SERVICE_ACCOUNT_JSON: '{invalid-json',
        FIREBASE_SERVICE_ACCOUNT_BASE64: '',
        FIREBASE_SERVICE_ACCOUNT_PATH: '',
      },
      async () => {
        const response = await request(app)
          .get(`${API_PREFIX}/settings/support`)
          .set(authHeader(admin.token))
          .expect(200);

        expect(response.body.success).toBe(true);
        expect(response.body.data).toHaveProperty('support_email');
        expect(response.body.meta).toEqual({
          persisted_in_app_notifications: true,
        });
        expect(response.body.meta).not.toHaveProperty('push_notifications');
        expect(response.body.meta).not.toHaveProperty('push_notifications_android');
        expect(response.body.meta).not.toHaveProperty('push_notifications_ios');
        expect(response.body.meta).not.toHaveProperty('email_notifications');
      },
    );
  });
});
