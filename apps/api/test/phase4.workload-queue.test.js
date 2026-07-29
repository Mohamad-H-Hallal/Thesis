const { Pool } = require('pg');
const { applyTestEnvDefaults } = require('../src/config/testEnv');
applyTestEnvDefaults();

const {
  claimWorkloadJobs,
  completeWorkloadJob,
  failWorkloadJob,
} = require('../src/services/workloadQueue.service');
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

    const stored = await pool.query('SELECT status, attempt_count FROM workload_job WHERE id = $1', [
      claimed.id,
    ]);
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
});
