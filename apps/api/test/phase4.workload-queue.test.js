const { Pool } = require('pg');
const { applyTestEnvDefaults } = require('../src/config/testEnv');
applyTestEnvDefaults();

const {
  claimWorkloadJobs,
  completeWorkloadJob,
  failWorkloadJob,
} = require('../src/services/workloadQueue.service');
const { finalizeDeadLetterEntity } = require('../src/jobs/workloadWorker');
const { closePool } = require('../src/config/database');

const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
});

const insertJob = async ({ maxAttempts = 3 } = {}) => {
  const result = await pool.query(
    `INSERT INTO workload_job (kind, entity_id, max_attempts)
     VALUES ('gis_import', uuid_generate_v4(), $1)
     RETURNING *`,
    [maxAttempts],
  );
  return result.rows[0];
};

describe('Phase 4 durable workload queue', () => {
  beforeEach(async () => {
    await pool.query('TRUNCATE TABLE workload_job');
  });

  afterAll(async () => {
    await pool.end();
    await closePool();
  });

  test('two worker replicas cannot claim the same job', async () => {
    await insertJob();

    const [first, second] = await Promise.all([
      claimWorkloadJobs({ workerId: 'replica-a', limit: 1, leaseMs: 30000 }),
      claimWorkloadJobs({ workerId: 'replica-b', limit: 1, leaseMs: 30000 }),
    ]);

    expect(first.length + second.length).toBe(1);
    const claimed = first[0] ?? second[0];
    const owner = first.length === 1 ? 'replica-a' : 'replica-b';
    await expect(completeWorkloadJob({ jobId: claimed.id, workerId: owner })).resolves.toBe(true);

    const stored = await pool.query(
      'SELECT status, attempt_count FROM workload_job WHERE id = $1',
      [claimed.id],
    );
    expect(stored.rows[0]).toMatchObject({ status: 'succeeded', attempt_count: 1 });
  });

  test('an expired lease is recovered after an interrupted worker', async () => {
    const inserted = await insertJob();
    const [firstClaim] = await claimWorkloadJobs({
      workerId: 'interrupted-worker',
      limit: 1,
      leaseMs: 20,
    });
    expect(firstClaim.id).toBe(inserted.id);

    await new Promise((resolve) => setTimeout(resolve, 40));
    const [recovered] = await claimWorkloadJobs({
      workerId: 'recovery-worker',
      limit: 1,
      leaseMs: 30000,
    });

    expect(recovered).toMatchObject({
      id: inserted.id,
      attempt_count: 2,
      worker_id: 'recovery-worker',
    });
    expect(recovered.last_error).toContain('expired worker lease');
    await expect(
      completeWorkloadJob({ jobId: recovered.id, workerId: 'recovery-worker' }),
    ).resolves.toBe(true);
  });

  test('bounded retries end in a dead-letter state', async () => {
    await insertJob({ maxAttempts: 2 });
    const [first] = await claimWorkloadJobs({
      workerId: 'retry-worker',
      limit: 1,
      leaseMs: 30000,
    });
    await expect(
      failWorkloadJob({
        job: first,
        workerId: 'retry-worker',
        error: new Error('transient failure'),
      }),
    ).resolves.toBe('queued');

    await pool.query(`UPDATE workload_job SET available_at = CURRENT_TIMESTAMP`);
    const [second] = await claimWorkloadJobs({
      workerId: 'retry-worker',
      limit: 1,
      leaseMs: 30000,
    });
    await expect(
      failWorkloadJob({
        job: second,
        workerId: 'retry-worker',
        error: new Error('persistent failure'),
      }),
    ).resolves.toBe('dead_letter');

    const stored = await pool.query(
      'SELECT status, attempt_count, last_error, completed_at FROM workload_job',
    );
    expect(stored.rows[0]).toMatchObject({
      status: 'dead_letter',
      attempt_count: 2,
      last_error: 'persistent failure',
    });
    expect(stored.rows[0].completed_at).not.toBeNull();
  });

  test('a dead-letter import notifies its uploader in-app without email delivery', async () => {
    const suffix = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
    const userResult = await pool.query(
      `INSERT INTO "user"
         (email, password_hash, full_name, role, is_active, account_status,
          email_verified_at, phone, phone_e164, phone_verified_at)
       VALUES ($1, 'unused-test-hash', 'Import Owner', 'admin', TRUE, 'active',
               CURRENT_TIMESTAMP, $2, $2, CURRENT_TIMESTAMP)
       RETURNING id`,
      [`dead-letter-${suffix}@example.com`, `+96171${String(Date.now()).slice(-6)}`],
    );
    const categoryResult = await pool.query(
      `INSERT INTO project_category (name) VALUES ($1) RETURNING id`,
      [`Dead Letter Category ${suffix}`],
    );
    const projectResult = await pool.query(
      `INSERT INTO project (category_id, created_by_user_id, name, status)
       VALUES ($1, $2, $3, 'draft')
       RETURNING id, name`,
      [categoryResult.rows[0].id, userResult.rows[0].id, `Dead Letter Project ${suffix}`],
    );
    const importResult = await pool.query(
      `INSERT INTO gis_import_job
         (project_id, uploaded_by_user_id, original_filename, stored_filename, file_path,
          file_size_bytes, file_checksum_sha256, file_type, status)
       VALUES ($1, $2, 'failed.geojson', 'failed.geojson', 'test/failed.geojson',
               1, $3, 'geojson', 'processing')
       RETURNING id`,
      [projectResult.rows[0].id, userResult.rows[0].id, 'a'.repeat(64)],
    );

    try {
      await finalizeDeadLetterEntity(
        { kind: 'gis_import', entity_id: importResult.rows[0].id },
        new Error('persistent parser failure'),
      );

      const storedImport = await pool.query(
        `SELECT status, processing_message FROM gis_import_job WHERE id = $1`,
        [importResult.rows[0].id],
      );
      expect(storedImport.rows[0].status).toBe('failed');
      expect(storedImport.rows[0].processing_message).toContain('dead-letter queue');

      const notifications = await pool.query(
        `SELECT title, metadata
         FROM notification
         WHERE user_id = $1
           AND type = 'import_event'
           AND metadata->>'import_job_id' = $2`,
        [userResult.rows[0].id, importResult.rows[0].id],
      );
      expect(notifications.rows).toEqual([
        expect.objectContaining({
          title: 'Import failed',
          metadata: expect.objectContaining({ status: 'failed', dead_letter: true }),
        }),
      ]);

      const emailDeliveries = await pool.query(
        `SELECT id FROM notification_delivery WHERE notification_id IN (
           SELECT id FROM notification WHERE user_id = $1
         )`,
        [userResult.rows[0].id],
      );
      expect(emailDeliveries.rows).toHaveLength(0);
    } finally {
      await pool.query(`DELETE FROM project WHERE id = $1`, [projectResult.rows[0].id]);
      await pool.query(`DELETE FROM project_category WHERE id = $1`, [categoryResult.rows[0].id]);
      await pool.query(`DELETE FROM "user" WHERE id = $1`, [userResult.rows[0].id]);
    }
  });
});
