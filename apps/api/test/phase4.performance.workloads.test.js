const fs = require('fs').promises;
const path = require('path');
const {
  app,
  API_PREFIX,
  request,
  authHeader,
  pool,
  resetDb,
  shutdown,
  createAdminUser,
  registerUser,
  loginUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
} = require('./helpers/api-test-helpers');
const {
  claimWorkloadJobs,
} = require('../src/services/workloadQueue.service');
const {
  startWorkloadWorker,
  stopWorkloadWorker,
} = require('../src/jobs/workloadWorker');

jest.setTimeout(120000);

const tempFiles = [];

const createFixture = async (name, seed, featureCount = 25) => {
  const filePath = path.join(__dirname, `${name}-${Date.now()}-${seed}.geojson`);
  const features = Array.from({ length: featureCount }, (_, index) => ({
    type: 'Feature',
    geometry: {
      type: 'Point',
      coordinates: [35.5 + seed * 0.001 + index * 0.00001, 33.9 + index * 0.00001],
    },
    properties: {
      feature_type: index % 2 === 0 ? 'olive' : 'citrus',
      source_row: `${seed}-${index}`,
    },
  }));
  await fs.writeFile(
    filePath,
    JSON.stringify({ type: 'FeatureCollection', features }),
    'utf8',
  );
  tempFiles.push(filePath);
  return filePath;
};

const waitForImport = async (token, importId) => {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    const response = await request(app)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(token));
    const status = response.body?.data?.job?.status;
    if (['pending_review', 'failed'].includes(status)) {
      return status;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Import ${importId} did not finish`);
};

describe('Phase 4 bounded workload load', () => {
  beforeAll(async () => {
    await resetDb();
  });

  afterAll(async () => {
    for (const filePath of tempFiles) {
      await fs.unlink(filePath).catch(() => undefined);
    }
    await shutdown();
  });

  test('concurrent users process GIS files without duplicate or corrupted rows', async () => {
    const admin = await createAdminUser({ emailPrefix: 'phase4-load-admin' });
    const category = await createCategory({
      token: admin.token,
      name: `Phase4 load ${Date.now()}`,
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Phase4 workload ${Date.now()}`,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);

    const contributors = [];
    for (let index = 0; index < 3; index += 1) {
      const registered = await registerUser({
        role: 'contributor',
        emailPrefix: `phase4-load-user-${index}`,
      });
      await approveContributorRequest({
        token: admin.token,
        userId: registered.user.id,
      });
      const login = await loginUser({
        email: registered.email,
        password: registered.password,
      });
      const assignment = await createAssignment({
        token: admin.token,
        projectId: project.id,
        userId: registered.user.id,
      });
      await updateAssignmentStatus({
        token: admin.token,
        assignmentId: assignment.id,
        status: 'approved',
      });
      contributors.push(login);
    }

    const fixtures = await Promise.all(
      Array.from({ length: 6 }, (_, index) => createFixture('phase4-load', index)),
    );
    const startedAt = Date.now();
    const uploads = await Promise.all(
      fixtures.map((fixture, index) =>
        request(app)
          .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
          .set(authHeader(contributors[index % contributors.length].token))
          .attach('file', fixture),
      ),
    );
    expect(uploads.every((response) => response.status === 202)).toBe(true);

    const statuses = await Promise.all(
      uploads.map((response) => waitForImport(admin.token, response.body.data.id)),
    );
    expect(statuses).toEqual(Array(6).fill('pending_review'));

    const ids = uploads.map((response) => response.body.data.id);
    const result = await pool.query(
      `SELECT
         COUNT(*)::int AS feature_count,
         COUNT(DISTINCT import_job_id)::int AS import_count,
         COUNT(DISTINCT (import_job_id, source_index))::int AS unique_source_rows
       FROM gis_import_feature
       WHERE import_job_id = ANY($1::uuid[])`,
      [ids],
    );
    expect(result.rows[0]).toEqual({
      feature_count: 150,
      import_count: 6,
      unique_source_rows: 150,
    });

    const jobs = await pool.query(
      `SELECT status, COUNT(*)::int AS count
       FROM workload_job
       WHERE entity_id = ANY($1::uuid[])
       GROUP BY status`,
      [ids],
    );
    expect(jobs.rows).toEqual([{ status: 'succeeded', count: 6 }]);
    expect(Date.now() - startedAt).toBeLessThan(
      Number(process.env.PERF_WORKLOAD_MAX_MS ?? 30000),
    );
  });

  test('a crashed lease resumes exactly once after worker restart', async () => {
    stopWorkloadWorker();
    const admin = await createAdminUser({ emailPrefix: 'phase4-recovery-admin' });
    const category = await createCategory({
      token: admin.token,
      name: `Phase4 recovery ${Date.now()}`,
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Phase4 recovery ${Date.now()}`,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);
    const fixture = await createFixture('phase4-recovery', 50, 40);
    const upload = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(admin.token))
      .attach('file', fixture)
      .expect(202);

    const [claimed] = await claimWorkloadJobs({
      workerId: 'simulated-crashed-worker',
      limit: 1,
      leaseMs: 30000,
    });
    expect(claimed.entity_id).toBe(upload.body.data.id);
    await pool.query(
      `UPDATE workload_job
       SET lease_expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
       WHERE id = $1`,
      [claimed.id],
    );

    startWorkloadWorker();
    await expect(waitForImport(admin.token, upload.body.data.id)).resolves.toBe('pending_review');

    const evidence = await pool.query(
      `SELECT
         job.status,
         job.attempt_count,
         (SELECT COUNT(*)::int FROM gis_import_feature f WHERE f.import_job_id = job.entity_id) AS feature_count,
         (SELECT COUNT(DISTINCT source_index)::int FROM gis_import_feature f WHERE f.import_job_id = job.entity_id) AS unique_rows
       FROM workload_job job
       WHERE job.id = $1`,
      [claimed.id],
    );
    expect(evidence.rows[0]).toEqual({
      status: 'succeeded',
      attempt_count: 2,
      feature_count: 40,
      unique_rows: 40,
    });
  });
});
