const fs = require('fs').promises;
const {
  API_PREFIX,
  app,
  pool,
  request,
  authHeader,
  resetDb,
  cleanupExportFiles,
  shutdown,
  createAdminUser,
  registerUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  loginUser,
  waitForExportCompletion,
} = require('./helpers/api-test-helpers');

const EXPORT_FEATURE_COUNT = Number(process.env.PERF_EXPORT_FEATURE_COUNT ?? 1200);
const EXPORT_MAX_MS = Number(process.env.PERF_EXPORT_MAX_MS ?? 30000);

jest.setTimeout(120000);

describe('Phase 10 performance: exports', () => {
  let contributor;
  let contributorToken;
  let projectId;
  let reviewerId;

  beforeAll(async () => {
    await resetDb();

    const admin = await createAdminUser({
      fullName: 'Export Perf Admin',
      emailPrefix: 'export-admin',
    });
    reviewerId = admin.user.id;
    contributor = await registerUser({
      role: 'contributor',
      fullName: 'Export Perf Contributor',
      emailPrefix: 'export-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Export Category ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Export Project ${Date.now()}`,
    });
    projectId = project.id;

    const assignment = await createAssignment({
      token: admin.token,
      projectId,
      userId: contributor.user.id,
      role: 'contributor',
    });
    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignment.id,
      status: 'approved',
    });

    const contributorLogin = await loginUser({
      email: contributor.email,
      password: contributor.password,
    });
    contributorToken = contributorLogin.token;

    await pool.query(
      `INSERT INTO spatial_feature (
         project_id,
         collected_by_user_id,
         geom,
         attributes,
         status,
         collected_at,
         reviewed_at,
         reviewed_by_user_id
       )
       SELECT
         $1,
         $2,
         ST_SetSRID(
           ST_MakePoint(
             35.2 + ((g % 300)::double precision / 500.0),
             33.4 + ((g % 300)::double precision / 500.0)
           ),
           4326
         ),
         jsonb_build_object('idx', g, 'species', 'apple', 'source', 'phase10-perf'),
         'approved'::feature_status,
         NOW() - (g || ' seconds')::interval,
         NOW() - (g || ' seconds')::interval,
         $4
       FROM generate_series(1, $3) AS g`,
      [projectId, contributor.user.id, EXPORT_FEATURE_COUNT, reviewerId]
    );
  });

  afterAll(async () => {
    await cleanupExportFiles();
    await resetDb();
    await shutdown();
  });

  test(`export completes under ${EXPORT_MAX_MS}ms with downloadable artifact`, async () => {
    const start = process.hrtime.bigint();
    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${projectId}`)
      .set(authHeader(contributorToken))
      .send({
        format: 'geojson',
        status_filter: ['approved'],
      });
    expect(exportRequestResponse.status).toBe(202);

    const exportId = exportRequestResponse.body?.data?.export_id;
    expect(exportId).toBeTruthy();

    const completedExport = await waitForExportCompletion({
      token: contributorToken,
      exportId,
      timeoutMs: Number(process.env.PERF_EXPORT_TIMEOUT_MS ?? 60000),
    });
    const end = process.hrtime.bigint();
    const exportDurationMs = Number(end - start) / 1e6;

    expect(completedExport.status).toBe('completed');
    expect(completedExport.feature_count).toBe(EXPORT_FEATURE_COUNT);
    expect(completedExport.file_path).toBeTruthy();
    expect(Number(completedExport.file_size_bytes)).toBeGreaterThan(0);
    expect(exportDurationMs).toBeLessThanOrEqual(EXPORT_MAX_MS);

    await fs.access(completedExport.file_path);

    const downloadResponse = await request(app)
      .get(`${API_PREFIX}/exports/${exportId}/download`)
      .set(authHeader(contributorToken));
    expect(downloadResponse.status).toBe(200);
  });
});
