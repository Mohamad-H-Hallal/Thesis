require('dotenv').config();
const bcrypt = require('bcryptjs');
const request = require('supertest');
const { Pool } = require('pg');
const { buildApp } = require('../src/app');
const { closePool } = require('../src/config/database');
const { validateEnv } = require('../src/config/env');

const API_PREFIX = process.env.API_PREFIX || '/api/v1';

const pool = new Pool({
  host: process.env.DB_HOST ?? 'localhost',
  port: Number(process.env.DB_PORT ?? 5432),
  database: process.env.DB_NAME ?? 'gis_app',
  user: process.env.DB_USER ?? 'gis_user',
  password: process.env.DB_PASSWORD ?? '',
});

const testEnv = {
  ...validateEnv(),
  NODE_ENV: 'test',
  CORS_ORIGIN: '',
  CORS_STRICT: false,
  CORS_CREDENTIALS: true,
  API_VERSION_PREFIX: API_PREFIX,
  ENABLE_LEGACY_API_PREFIX: true,
  METRICS_ENABLED: false,
  RATE_LIMIT_WINDOW_MS: 15 * 60 * 1000,
  RATE_LIMIT_MAX_REQUESTS: 1000,
};

const app = buildApp(testEnv);

const resetDb = async () => {
  await pool.query(`
    TRUNCATE TABLE
      notification,
      audit_log,
      photo,
      spatial_feature,
      shapefile_export,
      project_assignment,
      project,
      project_category,
      "user"
    RESTART IDENTITY CASCADE
  `);
};

const setupAuthenticatedContext = async () => {
  const password = 'Passw0rd!123';
  const passwordHash = await bcrypt.hash(password, 12);

  const userResult = await pool.query(
    `INSERT INTO "user" (email, password_hash, full_name, role)
     VALUES ($1, $2, $3, 'contributor')
     RETURNING id, email`,
    ['phase3-user@example.com', passwordHash, 'Phase3 User']
  );

  const user = userResult.rows[0];

  const categoryResult = await pool.query(
    `INSERT INTO project_category (name, description)
     VALUES ('Fruit Trees', 'Phase3 test category')
     RETURNING id`
  );
  const categoryId = categoryResult.rows[0].id;

  const projectResult = await pool.query(
    `INSERT INTO project (
      category_id,
      created_by_user_id,
      name,
      description,
      collection_form_schema,
      status
    ) VALUES ($1, $2, 'Phase3 Project', 'Test project', '{}'::jsonb, 'draft')
    RETURNING id`,
    [categoryId, user.id]
  );
  const projectId = projectResult.rows[0].id;

  await pool.query(
    `UPDATE project
     SET status = 'active'
     WHERE id = $1`,
    [projectId]
  );

  await pool.query(
    `INSERT INTO project_assignment (
       project_id,
       user_id,
       role,
       status,
       approved_by_user_id,
       approved_date
     )
     VALUES ($1, $2, 'contributor', 'approved', $2, CURRENT_DATE)`,
    [projectId, user.id]
  );

  const loginResponse = await request(app).post(`${API_PREFIX}/auth/login`).send({
    email: user.email,
    password,
  });

  expect(loginResponse.status).toBe(200);
  expect(loginResponse.body?.data?.token).toBeTruthy();

  return {
    token: loginResponse.body.data.token,
    projectId,
    userId: user.id,
  };
};

const insertSpatialFeature = async ({ projectId, userId, lon, lat, status = 'approved', collectedAt }) => {
  const reviewedByUserId = ['approved', 'rejected'].includes(status) ? userId : null;
  const reviewedAt = ['approved', 'rejected'].includes(status) ? collectedAt : null;

  await pool.query(
    `INSERT INTO spatial_feature (
      project_id,
      collected_by_user_id,
      geom,
      attributes,
      status,
      collected_at,
      reviewed_by_user_id,
      reviewed_at
    )
    VALUES (
      $1,
      $2,
      ST_SetSRID(ST_MakePoint($3, $4), 4326),
      $5::jsonb,
      $6::feature_status,
      $7::timestamptz,
      $8::uuid,
      $9::timestamptz
    )`,
    [
      projectId,
      userId,
      lon,
      lat,
      JSON.stringify({ tree: 'olive' }),
      status,
      collectedAt,
      reviewedByUserId,
      reviewedAt,
    ]
  );
};

const collectPlanNodes = (planNode, nodes = []) => {
  nodes.push(planNode);
  if (Array.isArray(planNode.Plans)) {
    for (const child of planNode.Plans) {
      collectPlanNodes(child, nodes);
    }
  }
  return nodes;
};

describe('Phase 3 geospatial integration', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await pool.end();
    await closePool();
  });

  test('rejects invalid polygon geometry on feature create', async () => {
    const { token, projectId } = await setupAuthenticatedContext();

    const invalidPolygon = {
      type: 'Polygon',
      coordinates: [
        [
          [35.5, 33.9],
          [35.6, 33.9],
          [35.6, 34.0],
          [35.55, 34.1],
        ],
      ],
    };

    const response = await request(app)
      .post(`${API_PREFIX}/features`)
      .set('Authorization', `Bearer ${token}`)
      .send({
        project_id: projectId,
        geom: invalidPolygon,
        attributes: { tree_type: 'apple' },
      });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
    expect(response.body.message).toContain('Invalid geometry coordinates');
  });

  test('returns GeoJSON collection with pagination for BBOX query', async () => {
    const { token, projectId, userId } = await setupAuthenticatedContext();

    await insertSpatialFeature({
      projectId,
      userId,
      lon: 35.51,
      lat: 33.91,
      status: 'approved',
      collectedAt: '2026-02-01T08:00:00Z',
    });
    await insertSpatialFeature({
      projectId,
      userId,
      lon: 35.52,
      lat: 33.92,
      status: 'approved',
      collectedAt: '2026-02-02T08:00:00Z',
    });
    await insertSpatialFeature({
      projectId,
      userId,
      lon: 35.53,
      lat: 33.93,
      status: 'approved',
      collectedAt: '2026-02-03T08:00:00Z',
    });

    const response = await request(app)
      .get(`${API_PREFIX}/features/bbox`)
      .query({
        minLon: 35.0,
        minLat: 33.0,
        maxLon: 36.0,
        maxLat: 34.5,
        page: 1,
        limit: 2,
        project_id: projectId,
        status: 'approved',
      })
      .set('Authorization', `Bearer ${token}`);

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.data.type).toBe('FeatureCollection');
    expect(Array.isArray(response.body.data.features)).toBe(true);
    expect(response.body.data.features).toHaveLength(2);
    expect(response.body.pagination.total).toBe(3);
    expect(response.body.pagination.totalPages).toBe(2);
    expect(response.body.data.bbox).toEqual([35, 33, 36, 34.5]);
  });

  test('EXPLAIN plan uses geospatial index for bbox predicate', async () => {
    const { projectId, userId } = await setupAuthenticatedContext();

    await insertSpatialFeature({
      projectId,
      userId,
      lon: 35.55,
      lat: 33.95,
      status: 'approved',
      collectedAt: '2026-02-10T08:00:00Z',
    });

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL enable_seqscan = off');
      const explainResult = await client.query(
        `EXPLAIN (FORMAT JSON)
         SELECT sf.id
         FROM spatial_feature sf
         WHERE sf.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
           AND sf.status = 'approved'
         ORDER BY sf.collected_at DESC
         LIMIT 100 OFFSET 0`,
        [35.0, 33.0, 36.0, 34.5]
      );
      await client.query('COMMIT');

      const planRoot = explainResult.rows[0]['QUERY PLAN'][0].Plan;
      const nodes = collectPlanNodes(planRoot);
      const indexNode = nodes.find((node) => typeof node['Index Name'] === 'string');
      const indexName = indexNode?.['Index Name'] ?? '';

      expect(indexName).toMatch(/idx_spatial_feature_geom|idx_spatial_feature_geom_project_status/i);
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  });
});
