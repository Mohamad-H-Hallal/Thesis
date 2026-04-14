const {
  API_PREFIX,
  app,
  authHeader,
  pool,
  request,
  resetDb,
  shutdown,
  createAdminUser,
} = require('./helpers/api-test-helpers');

describe('Notification push device registration', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('registers a device token and enqueues push delivery rows for later notifications', async () => {
    const admin = await createAdminUser({
      fullName: 'Push Admin',
      emailPrefix: 'push-admin',
    });
    const deviceToken = `test-device-token-${'x'.repeat(140)}`;

    await request(app)
      .post(`${API_PREFIX}/notifications/devices/register`)
      .set(authHeader(admin.token))
      .send({
        token: deviceToken,
        platform: 'android',
        device_label: 'Pixel 8',
        app_version: '1.0.0',
      })
      .expect(201);

    const deviceResult = await pool.query(
      `SELECT user_id, platform, notifications_enabled
       FROM push_device_registration
       WHERE token = $1`,
      [deviceToken],
    );

    expect(deviceResult.rows).toHaveLength(1);
    expect(deviceResult.rows[0]).toMatchObject({
      user_id: admin.user.id,
      platform: 'android',
      notifications_enabled: true,
    });

    await pool.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES ($1, 'assignment', $2, $3, $4::jsonb)`,
      [
        admin.user.id,
        'Assignment updated',
        'A contributor assignment changed.',
        JSON.stringify({ project_id: 'project-1' }),
      ],
    );

    const pushDeliveryResult = await pool.query(
      `SELECT token_snapshot, status
       FROM notification_push_delivery`,
    );

    expect(pushDeliveryResult.rows).toHaveLength(1);
    expect(pushDeliveryResult.rows[0]).toMatchObject({
      token_snapshot: deviceToken,
      status: 'pending',
    });
  });

  test('unregistering a device prevents new push deliveries from being enqueued', async () => {
    const admin = await createAdminUser({
      fullName: 'Push Admin 2',
      emailPrefix: 'push-admin-2',
    });
    const deviceToken = `test-device-token-${'y'.repeat(140)}`;

    await request(app)
      .post(`${API_PREFIX}/notifications/devices/register`)
      .set(authHeader(admin.token))
      .send({
        token: deviceToken,
        platform: 'android',
      })
      .expect(201);

    await request(app)
      .post(`${API_PREFIX}/notifications/devices/unregister`)
      .set(authHeader(admin.token))
      .send({ token: deviceToken })
      .expect(200);

    await pool.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES ($1, 'assignment', $2, $3, $4::jsonb)`,
      [
        admin.user.id,
        'No push expected',
        'This notification should stay in-app/email only.',
        JSON.stringify({ project_id: 'project-2' }),
      ],
    );

    const pushDeliveryResult = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM notification_push_delivery`,
    );

    expect(pushDeliveryResult.rows[0].count).toBe(0);
  });
});
