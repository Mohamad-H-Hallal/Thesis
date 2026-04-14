const {
  API_PREFIX,
  app,
  request,
  authHeader,
  resetDb,
  shutdown,
  createAdminUser,
  createCategory,
  pool,
} = require('./helpers/api-test-helpers');
const { deliverPendingNotificationEmails } = require('../src/lib/notificationDelivery');

describe('Project provisioning and lifecycle reminders', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('project creation requires a required feature type field and normalizes collection defaults', async () => {
    const admin = await createAdminUser({
      fullName: 'Reminder Admin',
      emailPrefix: 'reminder-admin',
    });

    const category = await createCategory({
      token: admin.token,
      name: `Reminder Category ${Date.now()}`,
    });

    const invalidResponse = await request(app)
      .post(`${API_PREFIX}/projects`)
      .set(authHeader(admin.token))
      .send({
        category_id: category.id,
        name: `Invalid Project ${Date.now()}`,
        description: 'Missing feature title field',
        collection_form_schema: {
          fields: [{ key: 'notes', label: 'Notes', type: 'text', required: false }],
        },
      });

    expect(invalidResponse.status).toBe(422);
    expect(invalidResponse.body.message).toContain('feature type field');

    const validResponse = await request(app)
      .post(`${API_PREFIX}/projects`)
      .set(authHeader(admin.token))
      .send({
        category_id: category.id,
        name: `Valid Project ${Date.now()}`,
        description: 'Valid schema',
        collection_form_schema: {
          fields: [
            {
              key: 'feature_type',
              label: 'Feature type',
              type: 'select',
              required: true,
              options: ['Olive', 'Orange'],
            },
          ],
        },
      });

    expect(validResponse.status).toBe(201);
    expect(validResponse.body.data.collection_form_schema.allowedGeometryTypes).toEqual([
      'Point',
      'LineString',
      'Polygon',
    ]);
    expect(validResponse.body.data.collection_form_schema.maxGpsAccuracyMeters).toBe(25);
  });

  test('project start, active end, and paused end reminders are created, queued, and cleaned up', async () => {
    const admin = await createAdminUser({
      fullName: 'Schedule Admin',
      emailPrefix: 'schedule-admin',
    });

    const category = await createCategory({
      token: admin.token,
      name: `Schedule Category ${Date.now()}`,
    });

    const datesResult = await pool.query(
      `SELECT
         TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD') AS today,
         TO_CHAR(CURRENT_DATE + INTERVAL '1 day', 'YYYY-MM-DD') AS tomorrow,
         TO_CHAR(CURRENT_DATE + INTERVAL '2 day', 'YYYY-MM-DD') AS day_after`
    );
    const { today, tomorrow, day_after } = datesResult.rows[0];

    const createResponse = await request(app)
      .post(`${API_PREFIX}/projects`)
      .set(authHeader(admin.token))
      .send({
        category_id: category.id,
        name: `Scheduled Project ${Date.now()}`,
        description: 'Schedule reminders',
        start_date: tomorrow,
        collection_form_schema: {
          fields: [
            {
              key: 'feature_type',
              label: 'Feature type',
              type: 'select',
              required: true,
              options: ['Olive', 'Orange'],
            },
          ],
        },
      });

    expect(createResponse.status).toBe(201);
    const projectId = createResponse.body.data.id;

    const startsReminder = await pool.query(
      `SELECT title
       FROM notification
       WHERE user_id = $1
         AND metadata->>'project_id' = $2
         AND metadata->>'schedule_reminder_kind' = 'starts_tomorrow'`,
      [admin.user.id, projectId],
    );
    expect(startsReminder.rows).toHaveLength(1);
    expect(startsReminder.rows[0].title).toBe('Project starts tomorrow');

    const startReminderDelivery = await pool.query(
      `SELECT status, recipient_email
       FROM notification_delivery nd
       JOIN notification n
         ON n.id = nd.notification_id
       WHERE n.user_id = $1
         AND n.metadata->>'project_id' = $2
         AND n.metadata->>'schedule_reminder_kind' = 'starts_tomorrow'`,
      [admin.user.id, projectId],
    );
    expect(startReminderDelivery.rows).toHaveLength(1);
    expect(startReminderDelivery.rows[0].status).toBe('pending');
    expect(startReminderDelivery.rows[0].recipient_email).toBe(admin.email);

    const startDeliveryRun = await deliverPendingNotificationEmails();
    expect(startDeliveryRun.attempted).toBeGreaterThanOrEqual(1);
    expect(startDeliveryRun.delivered).toBeGreaterThanOrEqual(1);

    await request(app)
      .put(`${API_PREFIX}/projects/${projectId}`)
      .set(authHeader(admin.token))
      .send({ start_date: day_after })
      .expect(200);

    const staleReminder = await pool.query(
      `SELECT COUNT(*)::int AS value
       FROM notification
       WHERE user_id = $1
         AND metadata->>'project_id' = $2
         AND metadata->>'schedule_reminder_kind' = 'starts_tomorrow'`,
      [admin.user.id, projectId],
    );
    expect(staleReminder.rows[0].value).toBe(0);

    await request(app)
      .put(`${API_PREFIX}/projects/${projectId}`)
      .set(authHeader(admin.token))
      .send({
        status: 'active',
        start_date: today,
        end_date: tomorrow,
      })
      .expect(200);

    const endReminder = await pool.query(
      `SELECT title, metadata->>'target_date' AS target_date
       FROM notification
       WHERE user_id = $1
         AND metadata->>'project_id' = $2
         AND metadata->>'schedule_reminder_kind' = 'ends_tomorrow'`,
      [admin.user.id, projectId],
    );
    expect(endReminder.rows).toHaveLength(1);
    expect(endReminder.rows[0].title).toBe('Project completes tomorrow');
    expect(endReminder.rows[0].target_date).toBe(tomorrow);

    await request(app)
      .put(`${API_PREFIX}/projects/${projectId}`)
      .set(authHeader(admin.token))
      .send({
        status: 'paused',
        end_date: tomorrow,
      })
      .expect(200);

    const pausedReminder = await pool.query(
      `SELECT title, message
       FROM notification
       WHERE user_id = $1
         AND metadata->>'project_id' = $2
         AND metadata->>'schedule_reminder_kind' = 'paused_ends_tomorrow'`,
      [admin.user.id, projectId],
    );
    expect(pausedReminder.rows).toHaveLength(1);
    expect(pausedReminder.rows[0].title).toBe(
      'Paused project reaches its end date tomorrow',
    );
    expect(pausedReminder.rows[0].message).toContain('is paused');

    const activeReminderAfterPause = await pool.query(
      `SELECT COUNT(*)::int AS value
       FROM notification
       WHERE user_id = $1
         AND metadata->>'project_id' = $2
         AND metadata->>'schedule_reminder_kind' = 'ends_tomorrow'`,
      [admin.user.id, projectId],
    );
    expect(activeReminderAfterPause.rows[0].value).toBe(0);
  });
});
