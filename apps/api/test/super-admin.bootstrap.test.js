const { resetDb, shutdown, pool } = require('./helpers/api-test-helpers');
const bcrypt = require('bcryptjs');
const { ensureSuperAdminExists } = require('../src/lib/userWorkflow');

describe('Super admin bootstrap', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('creates the configured super admin once and requires contact verification', async () => {
    const env = {
      NODE_ENV: 'test',
      SUPER_ADMIN_EMAIL: 'bootstrap.superadmin@gov.lb',
      SUPER_ADMIN_PASSWORD: 'Passw0rd!123',
      SUPER_ADMIN_FULL_NAME: 'Bootstrap Super Admin',
    };

    await ensureSuperAdminExists(env);
    await ensureSuperAdminExists(env);

    const result = await pool.query(
      `SELECT email, full_name, role, is_active, account_status,
              email_verified_at, phone_verified_at, password_hash
       FROM "user"
       WHERE email = $1`,
      [env.SUPER_ADMIN_EMAIL],
    );

    expect(result.rows).toHaveLength(1);
    expect(result.rows[0].role).toBe('admin');
    expect(result.rows[0].is_active).toBe(false);
    expect(result.rows[0].account_status).toBe('verification_required');
    expect(result.rows[0].email_verified_at).toBeNull();
    expect(result.rows[0].phone_verified_at).toBeNull();
    expect(result.rows[0].full_name).toBe(env.SUPER_ADMIN_FULL_NAME);
    expect(result.rows[0].password_hash).not.toBe(env.SUPER_ADMIN_PASSWORD);
    await expect(
      bcrypt.compare(env.SUPER_ADMIN_PASSWORD, result.rows[0].password_hash),
    ).resolves.toBe(true);
  });

  test('syncs an existing protected super admin password hash from environment', async () => {
    const env = {
      NODE_ENV: 'test',
      SUPER_ADMIN_EMAIL: 'bootstrap.superadmin@gov.lb',
      SUPER_ADMIN_PASSWORD: 'Passw0rd!123',
      SUPER_ADMIN_FULL_NAME: 'Bootstrap Super Admin',
    };
    const rotatedEnv = {
      ...env,
      SUPER_ADMIN_PASSWORD: 'Passw0rd!456',
    };

    await ensureSuperAdminExists(env);

    const before = await pool.query(
      `SELECT password_hash
       FROM "user"
       WHERE email = $1`,
      [env.SUPER_ADMIN_EMAIL],
    );
    await expect(
      bcrypt.compare(env.SUPER_ADMIN_PASSWORD, before.rows[0].password_hash),
    ).resolves.toBe(true);

    await ensureSuperAdminExists(rotatedEnv);

    const after = await pool.query(
      `SELECT email, full_name, role, is_active, account_status, password_hash
       FROM "user"
       WHERE email = $1`,
      [env.SUPER_ADMIN_EMAIL],
    );

    expect(after.rows).toHaveLength(1);
    expect(after.rows[0].role).toBe('admin');
    expect(after.rows[0].is_active).toBe(false);
    expect(after.rows[0].account_status).toBe('verification_required');
    await expect(
      bcrypt.compare(rotatedEnv.SUPER_ADMIN_PASSWORD, after.rows[0].password_hash),
    ).resolves.toBe(true);
    await expect(
      bcrypt.compare(env.SUPER_ADMIN_PASSWORD, after.rows[0].password_hash),
    ).resolves.toBe(false);
  });
});
