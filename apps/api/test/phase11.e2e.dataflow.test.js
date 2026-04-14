const fs = require('fs');
const os = require('os');
const path = require('path');
const sharp = require('sharp');
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
  loginUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  waitForExportCompletion,
} = require('./helpers/api-test-helpers');

jest.setTimeout(90000);

const imageFixturePath = path.join(os.tmpdir(), `phase11-photo-${Date.now()}.png`);

const writeImageFixture = async () => {
  await sharp({
    create: {
      width: 8,
      height: 8,
      channels: 3,
      background: { r: 20, g: 120, b: 60 },
    },
  })
    .png()
    .toFile(imageFixturePath);
};

describe('Phase 11 data-flow E2E', () => {
  beforeAll(async () => {
    await writeImageFixture();
  });

  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await cleanupExportFiles();
    await resetDb();
    if (fs.existsSync(imageFixturePath)) {
      fs.unlinkSync(imageFixturePath);
    }
    await shutdown();
  });

  test('admin->project->assignment->offline/online features->photos->review->export creates notifications and audit logs', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase11 Admin',
      emailPrefix: 'phase11-admin',
    });

    const contributor = await registerUser({
      fullName: 'Phase11 Contributor',
      emailPrefix: 'phase11-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Fruit Trees Phase11 ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `South Census ${Date.now()}`,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);

    const assignment = await createAssignment({
      token: admin.token,
      projectId: project.id,
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

    const offlineFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: { type: 'Point', coordinates: [35.49, 33.91] },
        attributes: {
          feature_type: 'olive',
          tree_type: 'olive',
          condition: 'good',
        },
        accuracy_meters: 5.3,
        collected_offline: true,
      });
    expect(offlineFeatureResponse.status).toBe(201);
    const offlineFeatureId = offlineFeatureResponse.body.data.id;

    const onlineFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: { type: 'Point', coordinates: [35.5, 33.9] },
        attributes: {
          feature_type: 'apple',
          tree_type: 'apple',
          condition: 'good',
        },
        accuracy_meters: 3.8,
        collected_offline: false,
      });
    expect(onlineFeatureResponse.status).toBe(201);

    const uploadPhotoResponse = await request(app)
      .post(`${API_PREFIX}/photos/feature/${offlineFeatureId}`)
      .set(authHeader(contributorLogin.token))
      .field('latitude', '33.91')
      .field('longitude', '35.49')
      .field('accuracy_meters', '2.5')
      .attach('photos', imageFixturePath);
    expect(uploadPhotoResponse.status).toBe(201);
    expect(uploadPhotoResponse.body.success).toBe(true);
    expect(uploadPhotoResponse.body.data.length).toBe(1);

    const submitResponse = await request(app)
      .post(`${API_PREFIX}/features/${offlineFeatureId}/submit`)
      .set(authHeader(contributorLogin.token));
    expect(submitResponse.status).toBe(200);

    const reviewResponse = await request(app)
      .post(`${API_PREFIX}/features/${offlineFeatureId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        review_notes: 'Phase11 validation complete.',
      });
    expect(reviewResponse.status).toBe(200);

    const exportRequest = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(contributorLogin.token))
      .send({
        status_filter: ['approved'],
        format: 'geojson',
      });
    expect(exportRequest.status).toBe(202);
    const exportId = exportRequest.body.data.export_id;

    const completedExport = await waitForExportCompletion({
      token: contributorLogin.token,
      exportId,
      timeoutMs: 45000,
    });
    expect(completedExport.status).toBe('completed');

    const featureRow = await pool.query(
      'SELECT collected_offline, status, version FROM spatial_feature WHERE id = $1',
      [offlineFeatureId]
    );
    expect(featureRow.rows[0].collected_offline).toBe(true);
    expect(featureRow.rows[0].status).toBe('approved');
    expect(featureRow.rows[0].version).toBeGreaterThanOrEqual(3);

    const photoRow = await pool.query(
      'SELECT id, file_size_bytes FROM photo WHERE feature_id = $1',
      [offlineFeatureId]
    );
    expect(photoRow.rows.length).toBe(1);
    expect(Number(photoRow.rows[0].file_size_bytes)).toBeGreaterThan(0);

    const notificationCount = await pool.query(
      `SELECT COUNT(*)::int AS total
       FROM notification
       WHERE metadata ? 'project_id'
          OR metadata ? 'feature_id'
          OR metadata ? 'assignment_id'
          OR metadata ? 'export_id'`
    );
    expect(notificationCount.rows[0].total).toBeGreaterThanOrEqual(4);

    const invalidMetadata = await pool.query(
      `SELECT COUNT(*)::int AS invalid_count
       FROM notification n
       WHERE n.metadata IS NULL
          OR jsonb_typeof(n.metadata) <> 'object'
          OR NOT EXISTS (
            SELECT 1
            FROM jsonb_object_keys(n.metadata) AS k(key_name)
            WHERE key_name ~* '(_id|_ids|_uuid|ids)$'
          )`
    );
    expect(invalidMetadata.rows[0].invalid_count).toBe(0);

    const auditRows = await pool.query(
      `SELECT action_type, entity_type
       FROM audit_log
       WHERE entity_type IN ('project', 'project_assignment', 'spatial_feature', 'shapefile_export')
       ORDER BY created_at ASC`
    );
    expect(auditRows.rows.length).toBeGreaterThanOrEqual(6);
    expect(
      auditRows.rows.some((row) => row.action_type === 'approve' && row.entity_type === 'spatial_feature')
    ).toBe(true);
    expect(
      auditRows.rows.some((row) => row.action_type === 'export' && row.entity_type === 'shapefile_export')
    ).toBe(true);
  });
});
