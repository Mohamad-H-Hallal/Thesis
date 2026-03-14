const { resetDb, shutdown, pool } = require('./helpers/api-test-helpers');
const { ensureSuperAdminExists } = require('../src/lib/userWorkflow');

describe('Super admin bootstrap', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('creates the configured super admin once and keeps it active as admin', async () => {
    const env = {
      NODE_ENV: 'test',
      SUPER_ADMIN_EMAIL: 'bootstrap.superadmin@gov.lb',
      SUPER_ADMIN_PASSWORD: 'Passw0rd!123',
      SUPER_ADMIN_FULL_NAME: 'Bootstrap Super Admin',
    };

    await ensureSuperAdminExists(env);
    await ensureSuperAdminExists(env);

    const result = await pool.query(
      `SELECT email, full_name, role, is_active, password_hash
       FROM "user"
       WHERE email = $1`,
      [env.SUPER_ADMIN_EMAIL]
    );

    expect(result.rows).toHaveLength(1);
    expect(result.rows[0].role).toBe('admin');
    expect(result.rows[0].is_active).toBe(true);
    expect(result.rows[0].full_name).toBe(env.SUPER_ADMIN_FULL_NAME);
    expect(result.rows[0].password_hash).not.toBe(env.SUPER_ADMIN_PASSWORD);
  });
});
