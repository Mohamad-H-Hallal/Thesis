const { randomUUID } = require('crypto');
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.DB_HOST ?? 'localhost',
  port: Number(process.env.DB_PORT ?? 5432),
  database: process.env.DB_NAME ?? 'gis_app',
  user: process.env.DB_USER ?? 'gis_user',
  password: process.env.DB_PASSWORD ?? 'change_me',
});

const aiTables = [
  'ai_project_settings',
  'ai_run',
  'ai_run_metric',
  'ai_output_layer',
  'ai_class_statistic',
  'ai_uncertainty_area',
  'ai_run_log',
  'ai_review_decision',
];

const cleanupAiSchemaFixtures = async () => {
  await pool.query(`DELETE FROM project WHERE name LIKE 'AI Schema Phase A%'`);
  await pool.query(`DELETE FROM project_category WHERE name LIKE 'AI Schema Phase A%'`);
  await pool.query(`DELETE FROM "user" WHERE email LIKE 'ai-schema-%@example.com'`);
};

const createProjectFixture = async () => {
  const suffix = randomUUID();
  const userResult = await pool.query(
    `INSERT INTO "user" (email, password_hash, full_name, role)
     VALUES ($1, 'test-hash', 'AI Schema Admin', 'admin')
     RETURNING id`,
    [`ai-schema-${suffix}@example.com`],
  );
  const userId = userResult.rows[0].id;

  const categoryResult = await pool.query(
    `INSERT INTO project_category (name, description)
     VALUES ($1, 'AI schema phase A test category')
     RETURNING id`,
    [`AI Schema Phase A ${suffix}`],
  );
  const categoryId = categoryResult.rows[0].id;

  const projectResult = await pool.query(
    `INSERT INTO project (
       category_id,
       created_by_user_id,
       name,
       description,
       collection_form_schema
     )
     VALUES ($1, $2, $3, 'AI schema phase A test project', '{}'::jsonb)
     RETURNING id`,
    [categoryId, userId, `AI Schema Phase A Project ${suffix}`],
  );
  const projectId = projectResult.rows[0].id;

  await pool.query(
    `UPDATE project
     SET status = 'active'
     WHERE id = $1`,
    [projectId],
  );

  return {
    categoryId,
    projectId,
    userId,
  };
};

beforeEach(async () => {
  await cleanupAiSchemaFixtures();
});

afterEach(async () => {
  await cleanupAiSchemaFixtures();
});

afterAll(async () => {
  await pool.end();
});

describe('AI integration schema phase A', () => {
  test('creates the AI schema tables and workflow enums', async () => {
    const tableResult = await pool.query(
      `SELECT table_name
       FROM information_schema.tables
       WHERE table_schema = 'public'
         AND table_name = ANY($1::text[])`,
      [aiTables],
    );
    expect(tableResult.rows.map((row) => row.table_name).sort()).toEqual([...aiTables].sort());

    const enumResult = await pool.query(
      `SELECT t.typname, json_agg(e.enumlabel ORDER BY e.enumsortorder) AS labels
       FROM pg_type t
       JOIN pg_enum e ON e.enumtypid = t.oid
       WHERE t.typname IN (
         'ai_scope_type',
         'ai_run_status',
         'ai_output_layer_type',
         'ai_output_layer_status',
         'ai_uncertainty_area_status',
         'ai_run_log_level',
         'ai_review_decision_type'
       )
       GROUP BY t.typname`,
    );
    const enums = Object.fromEntries(
      enumResult.rows.map((row) => [row.typname, row.labels]),
    );

    expect(enums.ai_scope_type).toEqual([
      'project',
      'governorate',
      'district',
      'city',
      'custom_polygon',
      'national',
    ]);
    expect(enums.ai_run_status).toContain('ready_for_review');
    expect(enums.ai_run_status).toContain('cancelled');
    expect(enums.ai_output_layer_type).toEqual([
      'classification',
      'confidence',
      'uncertainty',
      'statistics',
    ]);
    expect(enums.ai_output_layer_status).toContain('approved');
    expect(enums.ai_review_decision_type).toContain('keep_draft');
  });

  test('adds source provenance to approved real spatial features', async () => {
    const columnResult = await pool.query(
      `SELECT column_name, column_default, is_nullable
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'spatial_feature'
         AND column_name = 'source'`,
    );
    expect(columnResult.rows).toHaveLength(1);
    expect(columnResult.rows[0].is_nullable).toBe('NO');
    expect(columnResult.rows[0].column_default).toContain("'field'");

    const constraintResult = await pool.query(
      `SELECT pg_get_constraintdef(oid) AS definition
       FROM pg_constraint
       WHERE conname = 'chk_spatial_feature_source'`,
    );
    expect(constraintResult.rows).toHaveLength(1);
    expect(constraintResult.rows[0].definition).toContain('ai_validation');
    expect(constraintResult.rows[0].definition).not.toContain('ai_prediction');

    const { projectId, userId } = await createProjectFixture();
    const insertedDefault = await pool.query(
      `INSERT INTO spatial_feature (
         project_id,
         collected_by_user_id,
         geom,
         attributes,
         status
       )
       VALUES (
         $1,
         $2,
         ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326),
         '{"feature_type":"olive"}'::jsonb,
         'draft'
       )
       RETURNING source`,
      [projectId, userId],
    );
    expect(insertedDefault.rows[0].source).toBe('field');

    const insertedValidation = await pool.query(
      `INSERT INTO spatial_feature (
         project_id,
         collected_by_user_id,
         geom,
         attributes,
         status,
         source
       )
       VALUES (
         $1,
         $2,
         ST_SetSRID(ST_MakePoint(35.51, 33.91), 4326),
         '{"feature_type":"olive"}'::jsonb,
         'draft',
         'ai_validation'
       )
       RETURNING source`,
      [projectId, userId],
    );
    expect(insertedValidation.rows[0].source).toBe('ai_validation');

    await expect(
      pool.query(
        `INSERT INTO spatial_feature (
           project_id,
           collected_by_user_id,
           geom,
           attributes,
           status,
           source
         )
         VALUES (
           $1,
           $2,
           ST_SetSRID(ST_MakePoint(35.52, 33.92), 4326),
           '{}'::jsonb,
           'draft',
           'ai_prediction'
         )`,
        [projectId, userId],
      ),
    ).rejects.toThrow();
  });

  test('stores AI outputs separately from spatial_feature', async () => {
    const { projectId, userId } = await createProjectFixture();

    const settingsResult = await pool.query(
      `INSERT INTO ai_project_settings (
         project_id,
         is_enabled,
         label_field,
         scope_type,
         scope_geometry,
         min_samples_per_class,
         model_preferences,
         created_by,
         updated_by
       )
       VALUES (
         $1,
         TRUE,
         'L4_descr',
         'custom_polygon',
         ST_GeomFromText('POLYGON((35.1 33.1,35.2 33.1,35.2 33.2,35.1 33.2,35.1 33.1))', 4326),
         50,
         '{"models":["random_forest","svm_rbf","xgboost"]}'::jsonb,
         $2,
         $2
       )
       RETURNING id`,
      [projectId, userId],
    );

    const runResult = await pool.query(
      `INSERT INTO ai_run (
         project_id,
         settings_id,
         status,
         label_field,
         scope_type,
         region_preset,
         training_feature_count,
         eligible_feature_count,
         excluded_feature_count,
         selected_model,
         started_by,
         started_at,
         metadata
       )
       VALUES (
         $1,
         $2,
         'ready_for_review',
         'L4_descr',
         'district',
         'south-lebanon',
         1406,
         1394,
         12,
         'svm_rbf',
         $3,
         CURRENT_TIMESTAMP,
         '{"source":"schema-test"}'::jsonb
       )
       RETURNING id`,
      [projectId, settingsResult.rows[0].id, userId],
    );
    const aiRunId = runResult.rows[0].id;

    await pool.query(
      `INSERT INTO ai_run_metric (
         ai_run_id,
         model_name,
         overall_accuracy,
         macro_f1,
         weighted_f1,
         metrics,
         confusion_matrix,
         feature_importance
       )
       VALUES (
         $1,
         'svm_rbf',
         0.7163,
         0.6168,
         0.7391,
         '{"evaluation":"spatial_group_holdout"}'::jsonb,
         '[[34,8,2],[11,19,10],[16,35,154]]'::jsonb,
         '{"NDRE":0.25,"EVI":0.2}'::jsonb
       )`,
      [aiRunId],
    );

    await pool.query(
      `INSERT INTO ai_output_layer (
         ai_run_id,
         project_id,
         layer_type,
         status,
         name,
         storage_path,
         crs,
         bounds,
         style
       )
       VALUES (
         $1,
         $2,
         'classification',
         'ready_for_review',
         'Regional AI Classification',
         'outputs/runs/schema-test/classification.geojson',
         'EPSG:4326',
         ST_GeomFromText('POLYGON((35.1 33.1,35.2 33.1,35.2 33.2,35.1 33.2,35.1 33.1))', 4326),
         '{"palette":["#2e7d32"]}'::jsonb
       )`,
      [aiRunId, projectId],
    );

    await pool.query(
      `INSERT INTO ai_class_statistic (
         ai_run_id,
         class_label,
         feature_count,
         area_ha,
         confidence_mean,
         statistics
       )
       VALUES ($1, 'olives', 940, 120.5, 0.82, '{"source":"schema-test"}'::jsonb)`,
      [aiRunId],
    );

    await pool.query(
      `INSERT INTO ai_uncertainty_area (
         ai_run_id,
         project_id,
         geom,
         uncertainty_score,
         suggested_class,
         status,
         assigned_to
       )
       VALUES (
         $1,
         $2,
         ST_GeomFromText('POLYGON((35.15 33.15,35.16 33.15,35.16 33.16,35.15 33.16,35.15 33.15))', 4326),
         0.88,
         'fruit trees',
         'assigned',
         $3
       )`,
      [aiRunId, projectId, userId],
    );

    await pool.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', 'Schema test run log', '{"safe":true}'::jsonb)`,
      [aiRunId],
    );

    await pool.query(
      `INSERT INTO ai_review_decision (ai_run_id, decision, reason, decided_by)
       VALUES ($1, 'needs_more_data', 'Schema test review decision', $2)`,
      [aiRunId, userId],
    );

    const fieldFeatureResult = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM spatial_feature
       WHERE project_id = $1`,
      [projectId],
    );
    expect(fieldFeatureResult.rows[0].count).toBe(0);
  });

  test('enforces AI constraints and project foreign keys', async () => {
    const { projectId } = await createProjectFixture();

    await expect(
      pool.query(
        `INSERT INTO ai_project_settings (
           project_id,
           min_samples_per_class,
           model_preferences
         )
         VALUES ($1, 0, '{}'::jsonb)`,
        [projectId],
      ),
    ).rejects.toThrow();

    await expect(
      pool.query(
        `INSERT INTO ai_run (
           project_id,
           status,
           label_field
         )
         VALUES ($1, 'failed', 'L4_descr')`,
        [projectId],
      ),
    ).rejects.toThrow();

    await expect(
      pool.query(
        `INSERT INTO ai_run (
           project_id,
           label_field
         )
         VALUES ($1, 'L4_descr')`,
        [randomUUID()],
      ),
    ).rejects.toThrow();
  });

  test('creates spatial indexes for AI layer bounds and uncertainty areas', async () => {
    const indexResult = await pool.query(
      `SELECT indexname
       FROM pg_indexes
       WHERE schemaname = 'public'
         AND indexname = ANY($1::text[])`,
      [
        [
          'idx_ai_project_settings_scope_geometry',
          'idx_ai_run_scope_geometry',
          'idx_ai_output_layer_bounds',
          'idx_ai_uncertainty_area_geom',
          'idx_spatial_feature_project_source_status',
        ],
      ],
    );

    expect(indexResult.rows.map((row) => row.indexname).sort()).toEqual([
      'idx_ai_output_layer_bounds',
      'idx_ai_project_settings_scope_geometry',
      'idx_ai_run_scope_geometry',
      'idx_ai_uncertainty_area_geom',
      'idx_spatial_feature_project_source_status',
    ]);
  });
});
