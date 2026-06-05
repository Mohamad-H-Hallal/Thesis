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

const SUPER_ADMIN_EMAIL = 'ai-superadmin@gov.lb';

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
});

afterEach(async () => {
  await resetDb();
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
        }),
      ]),
    );
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
