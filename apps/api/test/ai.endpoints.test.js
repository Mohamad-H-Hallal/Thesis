const {
  app,
  API_PREFIX,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  createAdminUser,
  loginUser,
  approveContributorRequest,
  createCategory,
  createProject,
} = require('./helpers/api-test-helpers');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

const SUPER_ADMIN_EMAIL = 'ai-superadmin@gov.lb';
const ORIGINAL_AI_PIPELINE_ROOT = process.env.AI_PIPELINE_ROOT;
const ORIGINAL_AI_PIPELINE_OUTPUT_ROOT = process.env.AI_PIPELINE_OUTPUT_ROOT;
let tempAiPipelineRoot;

const activateProject = async ({ token, projectId }) => {
  const response = await request(app)
    .put(`${API_PREFIX}/projects/${projectId}`)
    .set(authHeader(token))
    .send({ status: 'active' });

  if (response.status !== 200) {
    throw new Error(
      `activateProject failed (${response.status}): ${JSON.stringify(response.body)}`,
    );
  }
};

const createProjectFixture = async (
  name = 'AI Endpoint Project',
  { protectedSuperAdmin = true } = {},
) => {
  const admin = await createAdminUser({
    fullName: `${name} Admin`,
    ...(protectedSuperAdmin ? { email: SUPER_ADMIN_EMAIL } : { emailPrefix: 'ai-endpoint-admin' }),
  });
  const category = await createCategory({
    token: admin.token,
    name: `${name} Category`,
  });
  const project = await createProject({
    token: admin.token,
    categoryId: category.id,
    name,
    visibleToViewers: true,
    visibleToContributors: true,
  });
  await activateProject({ token: admin.token, projectId: project.id });

  return {
    admin,
    category,
    project,
  };
};

const insertApprovedFeature = async ({
  projectId,
  userId,
  attributes,
  source = 'field',
  lon = 35.5,
  lat = 33.9,
}) => {
  const result = await pool.query(
    `INSERT INTO spatial_feature (
       project_id,
       collected_by_user_id,
       geom,
       attributes,
       status,
       submitted_at,
       reviewed_at,
       reviewed_by_user_id,
       source
     )
     VALUES (
       $1,
       $2,
       ST_SetSRID(ST_MakePoint($3, $4), 4326),
       $5::jsonb,
       'approved',
       CURRENT_TIMESTAMP,
       CURRENT_TIMESTAMP,
       $2,
       $6
     )
     RETURNING id`,
    [projectId, userId, lon, lat, JSON.stringify(attributes), source],
  );

  return result.rows[0].id;
};

const updateProjectSchema = async ({ projectId, fields }) => {
  await pool.query(
    `UPDATE project
     SET collection_form_schema = $2::jsonb
     WHERE id = $1`,
    [
      projectId,
      JSON.stringify({
        schemaVersion: 'phase-b-test',
        fields,
      }),
    ],
  );
};

const createReviewableAiRun = async ({ projectId, userId, layerStatus = 'ready_for_review' }) => {
  const runResult = await pool.query(
    `INSERT INTO ai_run (
       project_id,
       status,
       label_field,
       scope_type,
       training_feature_count,
       eligible_feature_count,
       excluded_feature_count,
       selected_model,
       started_by,
       metadata
     )
     VALUES (
       $1,
       'ready_for_review',
       'feature_type',
       'project',
       12,
       12,
       0,
       'random_forest',
       $2,
       '{"execution_mode":"regional_model_eval","phase":"phase_i_test"}'::jsonb
     )
     RETURNING id`,
    [projectId, userId],
  );
  const layerResult = await pool.query(
    `INSERT INTO ai_output_layer (
       ai_run_id,
       project_id,
       layer_type,
       status,
       name,
       description,
       storage_path,
       crs,
       style
     )
     VALUES (
       $1,
       $2,
       'statistics',
       $3,
       'Regional model statistics',
       'Unpublished regional statistics layer',
       'outputs/runs/phase-i-test/metrics.json',
       'EPSG:4326',
       '{}'::jsonb
     )
     RETURNING id`,
    [runResult.rows[0].id, projectId, layerStatus],
  );

  return {
    runId: runResult.rows[0].id,
    layerId: layerResult.rows[0].id,
  };
};

const createPreviewableAiLayer = async ({
  projectId,
  userId,
  layerType = 'classification',
  status = 'ready_for_review',
  storagePath = 'outputs/runs/phase-o-test/ai_classification_review.geojson',
}) => {
  const runResult = await pool.query(
    `INSERT INTO ai_run (
       project_id,
       status,
       label_field,
       scope_type,
       training_feature_count,
       eligible_feature_count,
       excluded_feature_count,
       selected_model,
       started_by,
       metadata
     )
     VALUES (
       $1,
       'ready_for_review',
       'L4_descr',
       'project',
       1406,
       1394,
       12,
       'random_forest',
       $2,
       '{"execution_mode":"regional_vectorization_artifacts","phase":"phase_o_preview_test"}'::jsonb
     )
     RETURNING id`,
    [projectId, userId],
  );
  const layerResult = await pool.query(
    `INSERT INTO ai_output_layer (
       ai_run_id,
       project_id,
       layer_type,
       status,
       name,
       description,
       storage_path,
       crs,
       style
     )
     VALUES (
       $1,
       $2,
       $3,
       $4,
       'Regional AI classification preview',
       'Unpublished AI map preview artifact.',
       $5,
       'EPSG:4326',
       '{}'::jsonb
     )
     RETURNING id`,
    [runResult.rows[0].id, projectId, layerType, status, storagePath],
  );

  return {
    runId: runResult.rows[0].id,
    layerId: layerResult.rows[0].id,
  };
};

const writePreviewGeoJson = async (
  relativePath = 'outputs/runs/phase-o-test/ai_classification_review.geojson',
  features = [
    {
      type: 'Feature',
      properties: {
        predicted_class: 'olives',
        confidence: 0.82,
        model_name: 'random_forest',
        source: 'ai_prediction',
        run_id: 'phase-o-test',
        area_ha: 1.4,
      },
      geometry: {
        type: 'Polygon',
        coordinates: [
          [
            [35.22, 33.2],
            [35.23, 33.2],
            [35.23, 33.21],
            [35.22, 33.21],
            [35.22, 33.2],
          ],
        ],
      },
    },
  ],
) => {
  const absolutePath = path.join(tempAiPipelineRoot, relativePath);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(
    absolutePath,
    JSON.stringify({
      type: 'FeatureCollection',
      features,
    }),
    'utf8',
  );
  return relativePath;
};

const createContributorToken = async ({ adminToken, emailPrefix = 'ai-endpoint-contributor' }) => {
  const registered = await registerUser({
    role: 'contributor',
    fullName: 'AI Endpoint Contributor',
    emailPrefix,
  });
  await approveContributorRequest({
    token: adminToken,
    userId: registered.user.id,
  });
  const login = await loginUser({
    email: registered.email,
    password: registered.password,
  });
  return {
    user: registered.user,
    token: login.token,
  };
};

const createViewerToken = async () => {
  const registered = await registerUser({
    role: 'viewer',
    fullName: 'AI Endpoint Viewer',
    emailPrefix: 'ai-endpoint-viewer',
  });
  const login = await loginUser({
    email: registered.email,
    password: registered.password,
  });
  return {
    user: registered.user,
    token: login.token,
  };
};

beforeEach(async () => {
  await resetDb();
  process.env.SUPER_ADMIN_EMAIL = SUPER_ADMIN_EMAIL;
  tempAiPipelineRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'gis-ai-phase-o-'));
  process.env.AI_PIPELINE_ROOT = tempAiPipelineRoot;
  delete process.env.AI_PIPELINE_OUTPUT_ROOT;
});

afterEach(async () => {
  await resetDb();
  if (tempAiPipelineRoot) {
    await fs.rm(tempAiPipelineRoot, { recursive: true, force: true });
    tempAiPipelineRoot = null;
  }
  if (ORIGINAL_AI_PIPELINE_ROOT === undefined) {
    delete process.env.AI_PIPELINE_ROOT;
  } else {
    process.env.AI_PIPELINE_ROOT = ORIGINAL_AI_PIPELINE_ROOT;
  }
  if (ORIGINAL_AI_PIPELINE_OUTPUT_ROOT === undefined) {
    delete process.env.AI_PIPELINE_OUTPUT_ROOT;
  } else {
    process.env.AI_PIPELINE_OUTPUT_ROOT = ORIGINAL_AI_PIPELINE_OUTPUT_ROOT;
  }
});

afterAll(async () => {
  delete process.env.SUPER_ADMIN_EMAIL;
  await shutdown();
});

describe('AI backend endpoints phase B', () => {
  test('readiness returns not_ready when a project has no approved samples', async () => {
    const { admin, project } = await createProjectFixture('AI Empty Readiness');

    const response = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(response.body.data.readiness.status).toBe('not_ready');
    expect(response.body.data.readiness.approved_feature_count).toBe(0);
    expect(response.body.data.readiness.blockers).toEqual(
      expect.arrayContaining(['Project has no approved field/import features available for AI.']),
    );
  });

  test('readiness counts labels, missing labels, sources, and minimum sample blockers', async () => {
    const { admin, project } = await createProjectFixture('AI Labeled Readiness');

    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
      source: 'import',
      lon: 35.4,
      lat: 33.8,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
      source: 'import',
      lon: 35.41,
      lat: 33.81,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Citrus' },
      source: 'field',
      lon: 35.42,
      lat: 33.82,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Citrus' },
      source: 'field',
      lon: 35.43,
      lat: 33.83,
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { notes: 'missing label' },
      source: 'field',
      lon: 35.44,
      lat: 33.84,
    });

    const warningResponse = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=2`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(warningResponse.body.data.readiness.status).toBe('warning');
    expect(warningResponse.body.data.readiness.approved_feature_count).toBe(5);
    expect(warningResponse.body.data.readiness.eligible_feature_count).toBe(4);
    expect(warningResponse.body.data.readiness.missing_label_count).toBe(1);
    expect(warningResponse.body.data.readiness.label_counts).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ class_label: 'Olives', sample_count: 2 }),
        expect.objectContaining({ class_label: 'Citrus', sample_count: 2 }),
      ]),
    );
    expect(warningResponse.body.data.readiness.source_counts).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ source: 'field', feature_count: 3 }),
        expect.objectContaining({ source: 'import', feature_count: 2 }),
      ]),
    );
    expect(warningResponse.body.data.readiness.candidate_label_fields).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          field: 'feature_type',
          labeled_feature_count: 4,
          class_count: 2,
          usable: true,
          selectable: true,
          recommended: true,
          aliases: [],
        }),
        expect.objectContaining({
          field: 'condition',
          labeled_feature_count: 0,
          class_count: 0,
          usable: false,
          selectable: false,
          diagnostic_only: true,
          recommended: false,
        }),
      ]),
    );

    const notReadyResponse = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=3`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(notReadyResponse.body.data.readiness.status).toBe('not_ready');
    expect(notReadyResponse.body.data.readiness.labeled_feature_count).toBe(4);
    expect(notReadyResponse.body.data.readiness.eligible_feature_count).toBe(0);
    expect(notReadyResponse.body.data.readiness.classes_below_minimum).toHaveLength(2);
  });

  test('readiness marks equivalent imported label fields as aliases and keeps only the schema classifier selectable', async () => {
    const { admin, project } = await createProjectFixture('AI Alias Labels');
    await updateProjectSchema({
      projectId: project.id,
      fields: [
        {
          key: 'feature_type',
          label: 'L4_descr',
          type: 'select',
          required: true,
          options: ['Olives', 'Citrus'],
        },
        {
          key: 'crop_type',
          label: 'Crop type',
          type: 'select',
          required: false,
          options: ['Olives', 'Citrus'],
        },
      ],
    });

    for (const [index, label] of ['Olives', 'Olives', 'Citrus', 'Citrus'].entries()) {
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes: {
          L4_descr: label,
          feature_type: label,
          level_4: label,
          L1_code: '1',
          L1_descr: 'Agriculture',
          L2_code: '10',
          L2_descr: 'Permanent crops',
          L3_code: label === 'Olives' ? '100' : '200',
          L4_code: label === 'Olives' ? '101' : '201',
          OBJECTID_1: `${label}-${index}`,
          OBJECTID_2: label === 'Olives' ? '1' : '2',
          Shape_Area: label === 'Olives' ? '123.45' : '234.56',
          Shape_Leng: label === 'Olives' ? '12.3' : '23.4',
        },
        source: 'import',
      });
    }

    const response = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=L4_descr&min_samples_per_class=2`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    const candidatesByField = Object.fromEntries(
      response.body.data.readiness.candidate_label_fields.map((candidate) => [
        candidate.field,
        candidate,
      ]),
    );

    expect(candidatesByField.L4_descr).toEqual(
      expect.objectContaining({
        field: 'L4_descr',
        usable: true,
        selectable: true,
        diagnostic_only: false,
        recommended: true,
        aliases: expect.arrayContaining(['feature_type']),
      }),
    );
    expect(candidatesByField.feature_type).toEqual(
      expect.objectContaining({
        field: 'feature_type',
        usable: true,
        selectable: false,
        diagnostic_only: true,
        alias_of: 'L4_descr',
        recommended: false,
      }),
    );
    expect(candidatesByField.crop_type).toEqual(
      expect.objectContaining({
        field: 'crop_type',
        labeled_feature_count: 0,
        class_count: 0,
        usable: false,
        selectable: false,
        diagnostic_only: true,
      }),
    );
    for (const rawField of [
      'OBJECTID_1',
      'OBJECTID_2',
      'Shape_Area',
      'Shape_Leng',
      'L1_code',
      'L1_descr',
      'L2_code',
      'L2_descr',
      'L3_code',
      'L4_code',
      'level_4',
    ]) {
      expect(candidatesByField[rawField]).toEqual(
        expect.objectContaining({
          selectable: false,
          diagnostic_only: true,
          recommended: false,
        }),
      );
    }
  });

  test('readiness keeps genuinely different label fields selectable', async () => {
    const { admin, project } = await createProjectFixture('AI Multiple Labels');
    await updateProjectSchema({
      projectId: project.id,
      fields: [
        {
          key: 'land_cover',
          label: 'Land cover',
          type: 'select',
          required: true,
          options: ['Forest', 'Orchard'],
        },
        {
          key: 'irrigation_type',
          label: 'Irrigation type',
          type: 'select',
          required: false,
          options: ['Drip', 'Rainfed'],
        },
      ],
    });

    for (const attributes of [
      { land_cover: 'Forest', irrigation_type: 'Drip' },
      { land_cover: 'Forest', irrigation_type: 'Rainfed' },
      { land_cover: 'Orchard', irrigation_type: 'Rainfed' },
      { land_cover: 'Orchard', irrigation_type: 'Rainfed' },
    ]) {
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes,
        source: 'field',
      });
    }

    const response = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=land_cover&min_samples_per_class=1`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    const candidatesByField = Object.fromEntries(
      response.body.data.readiness.candidate_label_fields.map((candidate) => [
        candidate.field,
        candidate,
      ]),
    );

    expect(candidatesByField.land_cover).toEqual(
      expect.objectContaining({
        selectable: true,
        recommended: true,
        aliases: [],
      }),
    );
    expect(candidatesByField.irrigation_type).toEqual(
      expect.objectContaining({
        selectable: true,
        recommended: false,
        alias_of: null,
      }),
    );
  });

  test('readiness warns and excludes low-count classes when enough classes remain', async () => {
    const { admin, project } = await createProjectFixture('AI Regional Warning');

    for (const featureType of [
      'Olives',
      'Olives',
      'Citrus',
      'Citrus',
      'Fruit Trees',
      'Fruit Trees',
      'Vineyards',
    ]) {
      await insertApprovedFeature({
        projectId: project.id,
        userId: admin.user.id,
        attributes: { feature_type: featureType },
        source: 'import',
      });
    }

    const response = await request(app)
      .get(
        `${API_PREFIX}/projects/${project.id}/ai/readiness?label_field=feature_type&min_samples_per_class=2`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(response.body.data.readiness.status).toBe('warning');
    expect(response.body.data.readiness.labeled_feature_count).toBe(7);
    expect(response.body.data.readiness.eligible_class_count).toBe(3);
    expect(response.body.data.readiness.eligible_feature_count).toBe(6);
    expect(response.body.data.readiness.excluded_feature_count).toBe(1);
    expect(response.body.data.readiness.classes_below_minimum).toEqual([
      expect.objectContaining({ class_label: 'Vineyards', sample_count: 1 }),
    ]);
    expect(response.body.data.readiness.blockers).toEqual([]);
    expect(response.body.data.readiness.warnings).toEqual(
      expect.arrayContaining([expect.stringContaining('Vineyards (1)')]),
    );
  });

  test('GET and PATCH project AI settings persist safe configuration only', async () => {
    const { admin, project } = await createProjectFixture('AI Settings');

    const defaultResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(defaultResponse.body.data.persisted).toBe(false);
    expect(defaultResponse.body.data.is_enabled).toBe(false);

    const updateResponse = await request(app)
      .patch(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 2,
        model_preferences: {
          models: ['random_forest'],
        },
      })
      .expect(200);

    expect(updateResponse.body.data.is_enabled).toBe(true);
    expect(updateResponse.body.data.label_field).toBe('feature_type');
    expect(updateResponse.body.data.min_samples_per_class).toBe(2);
    expect(updateResponse.body.data.model_preferences.models).toEqual(['random_forest']);
  });

  test('creates draft AI runs, lists runs, exposes placeholder child resources, and leaves spatial_feature untouched', async () => {
    const { admin, project } = await createProjectFixture('AI Run Draft');
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}/ai/settings`)
      .set(authHeader(admin.token))
      .send({
        is_enabled: true,
        label_field: 'feature_type',
        scope_type: 'project',
        min_samples_per_class: 1,
        model_preferences: {},
      })
      .expect(200);

    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Olives' },
    });
    await insertApprovedFeature({
      projectId: project.id,
      userId: admin.user.id,
      attributes: { feature_type: 'Citrus' },
      lon: 35.51,
      lat: 33.91,
    });
    const beforeCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature WHERE project_id = $1`,
      [project.id],
    );

    const createResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
      })
      .expect(201);

    expect(createResponse.body.data.status).toBe('draft');
    expect(createResponse.body.data.label_field).toBe('feature_type');
    expect(createResponse.body.data.eligible_feature_count).toBe(2);
    expect(createResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'mock',
        real_ai_execution: false,
      }),
    );

    const afterCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature WHERE project_id = $1`,
      [project.id],
    );
    expect(afterCount.rows[0].count).toBe(beforeCount.rows[0].count);

    const listResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(listResponse.body.data).toHaveLength(1);

    const runId = createResponse.body.data.id;
    await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}`)
      .set(authHeader(admin.token))
      .expect(200);

    const metricsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/metrics`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(metricsResponse.body.data).toEqual([]);

    const layersResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/layers`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(layersResponse.body.data).toEqual([]);

    const logsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/logs`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(logsResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          level: 'info',
          metadata: expect.objectContaining({
            execution_mode: 'mock',
            real_ai_execution: false,
          }),
        }),
      ]),
    );

    const dryRunResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
        execution_mode: 'dry_run',
      })
      .expect(201);
    expect(dryRunResponse.body.data.metadata.execution_mode).toBe('dry_run');

    const regionalResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_feature_extraction',
      })
      .expect(201);
    expect(regionalResponse.body.data.status).toBe('queued');
    expect(regionalResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_feature_extraction',
        regional_ai_execution_requested: true,
        real_ai_execution: false,
      }),
    );

    const regionalClassificationResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_classification',
      })
      .expect(201);
    expect(regionalClassificationResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_classification',
        regional_ai_execution_requested: true,
        real_ai_execution: false,
      }),
    );

    const vectorArtifactResponse = await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        execution_mode: 'regional_vectorization_artifacts',
      })
      .expect(201);
    expect(vectorArtifactResponse.body.data.metadata).toEqual(
      expect.objectContaining({
        execution_mode: 'regional_vectorization_artifacts',
        regional_ai_execution_requested: true,
        real_ai_execution: false,
      }),
    );

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'queued',
        scope_type: 'national',
        execution_mode: 'regional_vectorization_artifacts',
      })
      .expect(400);

    await request(app)
      .post(`${API_PREFIX}/projects/${project.id}/ai/runs`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
        execution_mode: 'full_training',
      })
      .expect(400);
  });

  test('protected super-admin can preview registered AI GeoJSON layer features only', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Preview');
    const storagePath = await writePreviewGeoJson();
    const { layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath,
    });
    const featureCountBefore = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );

    const response = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?zoom=12`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(response.body.data.layer.layer_type).toBe('classification');
    expect(response.body.data.layer.status).toBe('ready_for_review');
    expect(response.body.data.layer.viewer_published).toBe(false);
    expect(response.body.data.feature_count).toBe(1);
    expect(response.body.data.total_count).toBe(1);
    expect(response.body.data.matching_feature_count).toBe(1);
    expect(response.body.data.visible_count).toBe(1);
    expect(response.body.data.returned_feature_count).toBe(1);
    expect(response.body.data.returned_count).toBe(1);
    expect(response.body.data.capped).toBe(false);
    expect(response.body.data.cap).toBe(1800);
    expect(response.body.data.detail).toBe('overview');
    expect(response.body.data.geometry_mode).toBe('simplified');
    expect(response.body.data.optimized_preview).toBe(true);
    expect(response.body.data.class_counts).toEqual({ olives: 1 });
    expect(response.body.data.geometry_types).toEqual(['Polygon']);
    expect(response.body.data.feature_collection.type).toBe('FeatureCollection');
    expect(response.body.data.feature_collection.features[0].geometry.type).toBe('Polygon');
    expect(response.body.data.feature_collection.features[0].properties).toEqual(
      expect.objectContaining({
        predicted_class: 'olives',
        confidence: 0.82,
        model_name: 'random_forest',
        source: 'ai_prediction',
      }),
    );

    const fullResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(fullResponse.body.data.detail).toBe('full');
    expect(fullResponse.body.data.geometry_mode).toBe('full');
    expect(fullResponse.body.data.optimized_preview).toBe(false);
    expect(fullResponse.body.data.feature_collection.features[0].geometry.type).toBe('Polygon');

    const aggregateResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?zoom=8&geometry=aggregate`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(aggregateResponse.body.data.detail).toBe('overview');
    expect(aggregateResponse.body.data.geometry_mode).toBe('aggregate');
    expect(aggregateResponse.body.data.total_count).toBe(1);
    expect(aggregateResponse.body.data.visible_count).toBe(1);
    expect(aggregateResponse.body.data.returned_count).toBe(1);
    expect(aggregateResponse.body.data.feature_collection.features[0].geometry.type).toBe('Point');
    expect(aggregateResponse.body.data.feature_collection.features[0].properties).toEqual(
      expect.objectContaining({
        aggregate: true,
        aggregate_count: 1,
        dominant_class: 'olives',
      }),
    );

    const outsideBoundsResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?bounds=35.7,33.8,35.8,33.9`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(outsideBoundsResponse.body.data.feature_count).toBe(1);
    expect(outsideBoundsResponse.body.data.total_count).toBe(1);
    expect(outsideBoundsResponse.body.data.matching_feature_count).toBe(0);
    expect(outsideBoundsResponse.body.data.visible_count).toBe(0);
    expect(outsideBoundsResponse.body.data.returned_feature_count).toBe(0);
    expect(outsideBoundsResponse.body.data.capped).toBe(false);

    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=everything`)
      .set(authHeader(admin.token))
      .expect(400);
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?bounds=bad`)
      .set(authHeader(admin.token))
      .expect(400);

    const featureCountAfter = await pool.query(
      'SELECT COUNT(*)::int AS count FROM spatial_feature',
    );
    expect(featureCountAfter.rows[0].count).toBe(featureCountBefore.rows[0].count);
  });

  test('AI layer preview reports caps without changing total counts', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Preview Caps');
    const features = ['olives', 'fruit trees', 'citrus fruit trees'].map((label, index) => ({
      type: 'Feature',
      properties: {
        predicted_class: label,
        confidence: 0.7 + index / 100,
        model_name: 'random_forest',
        source: 'ai_prediction',
        run_id: 'phase-o-cap-test',
      },
      geometry: {
        type: 'Polygon',
        coordinates: [
          [
            [35.2 + index / 100, 33.2],
            [35.205 + index / 100, 33.2],
            [35.205 + index / 100, 33.205],
            [35.2 + index / 100, 33.205],
            [35.2 + index / 100, 33.2],
          ],
        ],
      },
    }));
    const storagePath = await writePreviewGeoJson(
      'outputs/runs/phase-o-test/ai_classification_many.geojson',
      features,
    );
    const { layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath,
    });

    const cappedResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&limit=1`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(cappedResponse.body.data.total_count).toBe(3);
    expect(cappedResponse.body.data.visible_count).toBe(3);
    expect(cappedResponse.body.data.returned_count).toBe(1);
    expect(cappedResponse.body.data.cap).toBe(1);
    expect(cappedResponse.body.data.capped).toBe(true);
    expect(cappedResponse.body.data.pagination).toEqual({
      page: 1,
      limit: 1,
      total: 3,
      pages: 3,
      has_more: true,
    });
    expect(cappedResponse.body.data.feature_collection.features[0].geometry.type).toBe('Polygon');
    expect(cappedResponse.body.data.class_counts).toEqual({
      olives: 1,
      'fruit trees': 1,
      'citrus fruit trees': 1,
    });

    const secondPageResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&limit=1&page=2`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(secondPageResponse.body.data.total_count).toBe(3);
    expect(secondPageResponse.body.data.visible_count).toBe(3);
    expect(secondPageResponse.body.data.returned_count).toBe(1);
    expect(secondPageResponse.body.data.pagination).toEqual({
      page: 2,
      limit: 1,
      total: 3,
      pages: 3,
      has_more: true,
    });
    expect(
      secondPageResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('fruit trees');

    const classFilterResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&class_label=citrus%20fruit%20trees&limit=20`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(classFilterResponse.body.data.total_count).toBe(3);
    expect(classFilterResponse.body.data.visible_count).toBe(1);
    expect(classFilterResponse.body.data.returned_count).toBe(1);
    expect(classFilterResponse.body.data.pagination).toEqual({
      page: 1,
      limit: 20,
      total: 1,
      pages: 1,
      has_more: false,
    });
    expect(
      classFilterResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('citrus fruit trees');

    const searchResponse = await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features?detail=full&geometry=full&q=fruit&limit=1`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(searchResponse.body.data.total_count).toBe(3);
    expect(searchResponse.body.data.visible_count).toBe(2);
    expect(searchResponse.body.data.returned_count).toBe(1);
    expect(searchResponse.body.data.pagination).toEqual({
      page: 1,
      limit: 1,
      total: 2,
      pages: 2,
      has_more: true,
    });

    const hiddenReferenceLabelStoragePath = await writePreviewGeoJson(
      'outputs/runs/phase-o-test/ai_classification_reference_labels.geojson',
      [
        {
          type: 'Feature',
          properties: {
            source_feature_id: 'exact-citrus-reference',
            predicted_class: 'olives',
            L4_descr: 'citrus fruit trees',
            model_name: 'random_forest',
          },
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [35.7, 33.3],
                [35.705, 33.3],
                [35.705, 33.305],
                [35.7, 33.305],
                [35.7, 33.3],
              ],
            ],
          },
        },
        {
          type: 'Feature',
          properties: {
            source_feature_id: 'exact-citrus-prediction',
            predicted_class: 'citrus fruit trees',
            L4_descr: 'olives',
            model_name: 'random_forest',
          },
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [35.71, 33.3],
                [35.715, 33.3],
                [35.715, 33.305],
                [35.71, 33.305],
                [35.71, 33.3],
              ],
            ],
          },
        },
      ],
    );
    const { layerId: hiddenReferenceLayerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath: hiddenReferenceLabelStoragePath,
    });
    const citrusSearchResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${hiddenReferenceLayerId}/features?detail=full&geometry=full&q=citr&limit=20`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(citrusSearchResponse.body.data.total_count).toBe(2);
    expect(citrusSearchResponse.body.data.visible_count).toBe(1);
    expect(
      citrusSearchResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('citrus fruit trees');

    const exactFeatureResponse = await request(app)
      .get(
        `${API_PREFIX}/ai/layers/${hiddenReferenceLayerId}/features?detail=full&geometry=full&feature_id=exact-citrus-reference&limit=1`,
      )
      .set(authHeader(admin.token))
      .expect(200);
    expect(exactFeatureResponse.body.data.visible_count).toBe(1);
    expect(exactFeatureResponse.body.data.feature_collection.features[0].id).toBe(
      'exact-citrus-reference',
    );
    expect(
      exactFeatureResponse.body.data.feature_collection.features[0].properties.predicted_class,
    ).toBe('olives');
  });

  test('AI layer preview denies non-protected users and unsafe artifact paths', async () => {
    const { admin, project } = await createProjectFixture('AI Layer Preview Safety');
    const storagePath = await writePreviewGeoJson();
    const { layerId } = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath,
    });
    const normalAdmin = await createAdminUser({
      fullName: 'Normal AI Admin',
      emailPrefix: 'normal-ai-admin',
    });
    const viewer = await createViewerToken();

    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features`)
      .set(authHeader(normalAdmin.token))
      .expect(403);
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${layerId}/features`)
      .set(authHeader(viewer.token))
      .expect(403);

    const traversal = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      storagePath: 'outputs/runs/phase-o-test/../secret.geojson',
    });
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${traversal.layerId}/features`)
      .set(authHeader(admin.token))
      .expect(400);

    const statistics = await createPreviewableAiLayer({
      projectId: project.id,
      userId: admin.user.id,
      layerType: 'statistics',
      storagePath: 'outputs/runs/phase-o-test/statistics_layer.json',
    });
    await request(app)
      .get(`${API_PREFIX}/ai/layers/${statistics.layerId}/features`)
      .set(authHeader(admin.token))
      .expect(400);
  });

  test('RBAC allows only protected super-admin users without cross-project leaks', async () => {
    const first = await createProjectFixture('AI RBAC First');
    const second = await createProjectFixture('AI RBAC Second', {
      protectedSuperAdmin: false,
    });
    const viewer = await createViewerToken();
    const contributor = await createContributorToken({
      adminToken: first.admin.token,
      emailPrefix: 'ai-endpoint-rbac-contributor',
    });
    const assignedProjectAdmin = await createContributorToken({
      adminToken: second.admin.token,
      emailPrefix: 'ai-endpoint-project-admin',
    });

    await pool.query(
      `INSERT INTO project_assignment (project_id, user_id, role, status, approved_by_user_id, approved_date)
       VALUES ($1, $2, 'admin', 'approved', $3, CURRENT_DATE)
       ON CONFLICT (project_id, user_id)
       DO UPDATE SET role = 'admin', status = 'approved', approved_by_user_id = $3, approved_date = CURRENT_DATE`,
      [second.project.id, assignedProjectAdmin.user.id, second.admin.user.id],
    );

    await request(app)
      .get(`${API_PREFIX}/projects/${first.project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(viewer.token))
      .expect(403);

    await request(app)
      .post(`${API_PREFIX}/projects/${first.project.id}/ai/runs`)
      .set(authHeader(contributor.token))
      .send({ label_field: 'feature_type' })
      .expect(403);

    await request(app)
      .get(`${API_PREFIX}/projects/${second.project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(assignedProjectAdmin.token))
      .expect(403);

    await request(app)
      .get(`${API_PREFIX}/projects/${first.project.id}/ai/readiness?label_field=feature_type`)
      .set(authHeader(second.admin.token))
      .expect(403);

    const runResponse = await request(app)
      .post(`${API_PREFIX}/projects/${first.project.id}/ai/runs`)
      .set(authHeader(first.admin.token))
      .send({
        label_field: 'feature_type',
      })
      .expect(201);

    await request(app)
      .get(`${API_PREFIX}/ai/runs/${runResponse.body.data.id}`)
      .set(authHeader(assignedProjectAdmin.token))
      .expect(403);
  });
});

describe('AI result review phase I', () => {
  test('protected super-admin approves AI output for future publication without publishing or touching spatial_feature', async () => {
    const { admin, project } = await createProjectFixture('AI Review Approve');
    const { runId, layerId } = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });
    const beforeFeatureCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature`,
    );

    const response = await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(admin.token))
      .send({
        action: 'approve_for_publication',
        reason: 'Metrics look acceptable for future publishing review.',
      })
      .expect(200);

    expect(response.body.data.viewer_published).toBe(false);
    expect(response.body.data.decision).toEqual(
      expect.objectContaining({
        ai_run_id: runId,
        decision: 'approved_for_publish',
        reason: 'Metrics look acceptable for future publishing review.',
      }),
    );
    expect(response.body.data.run.metadata.review).toEqual(
      expect.objectContaining({
        action: 'approve_for_publication',
        review_status: 'approved_for_publication',
        layer_status: 'approved',
        viewer_publication_enabled: false,
        spatial_feature_writes: false,
      }),
    );

    const layerResult = await pool.query(
      `SELECT status, published_at, published_by
       FROM ai_output_layer
       WHERE id = $1`,
      [layerId],
    );
    expect(layerResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'approved',
        published_at: null,
        published_by: null,
      }),
    );

    const decisionsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/reviews`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(decisionsResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          decision: 'approved_for_publish',
          reason: 'Metrics look acceptable for future publishing review.',
        }),
      ]),
    );

    const logsResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/logs`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(logsResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          message:
            'AI run approved for future publication. No viewer-facing AI layer was published.',
          metadata: expect.objectContaining({
            phase: 'phase_i_review',
            action: 'approve_for_publication',
            viewer_publication_enabled: false,
            spatial_feature_writes: false,
          }),
        }),
      ]),
    );

    const layersResponse = await request(app)
      .get(`${API_PREFIX}/ai/runs/${runId}/layers`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(layersResponse.body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: layerId,
          status: 'approved',
          published_at: null,
          published_by: null,
        }),
      ]),
    );

    const afterFeatureCount = await pool.query(
      `SELECT COUNT(*)::int AS count FROM spatial_feature`,
    );
    expect(afterFeatureCount.rows[0].count).toBe(beforeFeatureCount.rows[0].count);
  });

  test('reject and request-more-data require reasons and keep AI layers unpublished', async () => {
    const { admin, project } = await createProjectFixture('AI Review Reject');
    const rejectable = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });
    const moreData = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${rejectable.runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'reject' })
      .expect(400);

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${rejectable.runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'reject', reason: 'Regional metrics are not acceptable yet.' })
      .expect(200);

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${moreData.runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'request_more_data', reason: 'Need more samples outside South Lebanon.' })
      .expect(200);

    const layerResult = await pool.query(
      `SELECT ai_run_id, status, published_at
       FROM ai_output_layer
       WHERE ai_run_id = ANY($1::uuid[])
       ORDER BY ai_run_id`,
      [[rejectable.runId, moreData.runId]],
    );
    expect(layerResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          ai_run_id: rejectable.runId,
          status: 'rejected',
          published_at: null,
        }),
        expect.objectContaining({
          ai_run_id: moreData.runId,
          status: 'draft',
          published_at: null,
        }),
      ]),
    );

    const decisionResult = await pool.query(
      `SELECT decision, reason
       FROM ai_review_decision
       WHERE ai_run_id = ANY($1::uuid[])
       ORDER BY decided_at DESC`,
      [[rejectable.runId, moreData.runId]],
    );
    expect(decisionResult.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          decision: 'rejected',
          reason: 'Regional metrics are not acceptable yet.',
        }),
        expect.objectContaining({
          decision: 'needs_more_data',
          reason: 'Need more samples outside South Lebanon.',
        }),
      ]),
    );
  });

  test('keep draft records a review decision and moves prepared layers back to draft', async () => {
    const { admin, project } = await createProjectFixture('AI Review Draft');
    const { runId, layerId } = await createReviewableAiRun({
      projectId: project.id,
      userId: admin.user.id,
    });

    const response = await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(admin.token))
      .send({ action: 'keep_draft' })
      .expect(200);

    expect(response.body.data.decision.decision).toBe('keep_draft');
    expect(response.body.data.run.metadata.review.review_status).toBe('draft');

    const layerResult = await pool.query(
      `SELECT status, published_at
       FROM ai_output_layer
       WHERE id = $1`,
      [layerId],
    );
    expect(layerResult.rows[0]).toEqual(
      expect.objectContaining({
        status: 'draft',
        published_at: null,
      }),
    );
  });

  test('only protected super-admin can review AI runs', async () => {
    const first = await createProjectFixture('AI Review RBAC First');
    const second = await createProjectFixture('AI Review RBAC Second', {
      protectedSuperAdmin: false,
    });
    const viewer = await createViewerToken();
    const contributor = await createContributorToken({
      adminToken: first.admin.token,
      emailPrefix: 'ai-review-contributor',
    });
    const { runId } = await createReviewableAiRun({
      projectId: first.project.id,
      userId: first.admin.user.id,
    });

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(second.admin.token))
      .send({ action: 'approve_for_publication' })
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(viewer.token))
      .send({ action: 'approve_for_publication' })
      .expect(403);
    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(contributor.token))
      .send({ action: 'approve_for_publication' })
      .expect(403);

    await request(app)
      .post(`${API_PREFIX}/ai/runs/${runId}/review`)
      .set(authHeader(first.admin.token))
      .send({ action: 'approve_for_publication' })
      .expect(200);
  });
});
