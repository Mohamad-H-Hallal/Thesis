const {
  API_PREFIX,
  app,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  createAdminUser,
  registerUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  loginUser,
  collectPlanNodes,
} = require('./helpers/api-test-helpers');

const BBOX_FEATURE_COUNT = Number(process.env.PERF_BBOX_FEATURE_COUNT ?? 2500);
const BBOX_MAX_MS = Number(process.env.PERF_BBOX_MAX_MS ?? 2000);
const INSIDE_BBOX_FEATURE_COUNT = Math.max(150, Math.floor(BBOX_FEATURE_COUNT * 0.12));

jest.setTimeout(90000);

describe('Phase 10 performance: bbox query', () => {
  let contributorToken;
  let projectId;
  let reviewerId;

  beforeAll(async () => {
    await resetDb();

    const admin = await createAdminUser({
      fullName: 'BBox Perf Admin',
      emailPrefix: 'bbox-admin',
    });
    reviewerId = admin.user.id;
    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'BBox Perf Contributor',
      emailPrefix: 'bbox-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `BBox Category ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `BBox Project ${Date.now()}`,
    });
    projectId = project.id;
    await request(app)
      .put(`${API_PREFIX}/projects/${projectId}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);

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
             CASE
               WHEN g <= $3 THEN 35.12 + ((g % 35)::double precision / 180.0)
               ELSE 36.25 + ((g % 120)::double precision / 80.0)
             END,
             CASE
               WHEN g <= $3 THEN 33.12 + ((g % 28)::double precision / 180.0)
               ELSE 34.35 + ((g % 110)::double precision / 90.0)
             END
           ),
           4326
         ),
         jsonb_build_object('idx', g, 'species', 'olive'),
         'approved'::feature_status,
         NOW() - (g || ' seconds')::interval,
         NOW() - (g || ' seconds')::interval,
         $5
       FROM generate_series(1, $4) AS g`,
      [projectId, contributor.user.id, INSIDE_BBOX_FEATURE_COUNT, BBOX_FEATURE_COUNT, reviewerId],
    );
    await pool.query('ANALYZE spatial_feature');
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test(`bbox query returns under ${BBOX_MAX_MS}ms and uses indexed access`, async () => {
    const durations = [];

    for (let i = 0; i < 3; i += 1) {
      const start = process.hrtime.bigint();
      const response = await request(app)
        .get(`${API_PREFIX}/features/bbox`)
        .query({
          minLon: 35.0,
          minLat: 33.0,
          maxLon: 35.5,
          maxLat: 33.5,
          page: 1,
          limit: 100,
          project_id: projectId,
          status: 'approved',
        })
        .set(authHeader(contributorToken));
      const end = process.hrtime.bigint();

      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.data.type).toBe('FeatureCollection');
      expect(response.body.pagination.total).toBeGreaterThanOrEqual(INSIDE_BBOX_FEATURE_COUNT);

      durations.push(Number(end - start) / 1e6);
    }

    const averageDurationMs = durations.reduce((sum, value) => sum + value, 0) / durations.length;
    expect(averageDurationMs).toBeLessThanOrEqual(BBOX_MAX_MS);

    const explainResult = await pool.query(
      `EXPLAIN (FORMAT JSON)
       SELECT sf.id
       FROM spatial_feature sf
       WHERE sf.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
         AND sf.project_id = $5
         AND sf.status = 'approved'
       ORDER BY sf.collected_at DESC
       LIMIT 100`,
      [35.0, 33.0, 35.5, 33.5, projectId],
    );

    const planRoot = explainResult.rows[0]['QUERY PLAN'][0].Plan;
    const nodes = collectPlanNodes(planRoot);
    const indexNodes = nodes.filter((node) => typeof node['Index Name'] === 'string');
    const hasSequentialScan = nodes.some((node) => node['Node Type'] === 'Seq Scan');

    expect(indexNodes.length).toBeGreaterThan(0);
    expect(hasSequentialScan).toBe(false);
  });
});
