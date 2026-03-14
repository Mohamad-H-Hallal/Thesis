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

jest.setTimeout(90000);

describe('Phase 10 performance: bbox query', () => {
  let contributorToken;
  let projectId;

  beforeAll(async () => {
    await resetDb();

    const admin = await createAdminUser({
      fullName: 'BBox Perf Admin',
      emailPrefix: 'bbox-admin',
    });
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
         collected_at
       )
       SELECT
         $1,
         $2,
         ST_SetSRID(
           ST_MakePoint(
             35.0 + ((g % 200)::double precision / 200.0),
             33.0 + ((g % 120)::double precision / 120.0)
           ),
           4326
         ),
         jsonb_build_object('idx', g, 'species', 'olive'),
         'approved'::feature_status,
         NOW() - (g || ' seconds')::interval
       FROM generate_series(1, $3) AS g`,
      [projectId, contributor.user.id, BBOX_FEATURE_COUNT]
    );
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test(`bbox query returns under ${BBOX_MAX_MS}ms and uses geospatial index`, async () => {
    const durations = [];

    for (let i = 0; i < 3; i += 1) {
      const start = process.hrtime.bigint();
      const response = await request(app)
        .get(`${API_PREFIX}/features/bbox`)
        .query({
          minLon: 35.0,
          minLat: 33.0,
          maxLon: 36.0,
          maxLat: 34.0,
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
      expect(response.body.pagination.total).toBeGreaterThan(1000);

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
      [35.0, 33.0, 36.0, 34.0, projectId]
    );

    const planRoot = explainResult.rows[0]['QUERY PLAN'][0].Plan;
    const nodes = collectPlanNodes(planRoot);
    const indexNode = nodes.find((node) => typeof node['Index Name'] === 'string');
    const indexName = indexNode?.['Index Name'] ?? '';

    expect(indexName).toMatch(/idx_spatial_feature_geom|idx_spatial_feature_geom_project_status/i);
  });
});
