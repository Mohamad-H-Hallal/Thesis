const {
  API_PREFIX,
  app,
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
const AdmZip = require('adm-zip');

jest.setTimeout(90000);

describe('Phase 10 E2E workflow', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await cleanupExportFiles();
    await resetDb();
    await shutdown();
  });

  test('auth -> project -> assignment -> feature review -> export download', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase10 Admin',
      emailPrefix: 'phase10-admin',
    });

    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Phase10 Contributor',
      emailPrefix: 'phase10-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Fruit Trees ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Bekaa Field Census ${Date.now()}`,
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

    const createFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: {
          type: 'Point',
          coordinates: [35.5018, 33.8938],
        },
        attributes: {
          feature_type: 'olive',
          tree_type: 'olive',
          condition: 'good',
        },
        accuracy_meters: 4.2,
      });

    expect(createFeatureResponse.status).toBe(201);
    expect(createFeatureResponse.body.success).toBe(true);
    const featureId = createFeatureResponse.body.data.id;
    expect(featureId).toBeTruthy();

    const submitResponse = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(authHeader(contributorLogin.token))
      .send();
    expect(submitResponse.status).toBe(200);

    const reviewResponse = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        review_notes: 'Geometry and attributes validated.',
      });
    expect(reviewResponse.status).toBe(200);

    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        status_filter: ['approved'],
        format: 'geojson',
      });

    expect(exportRequestResponse.status).toBe(202);
    const exportId = exportRequestResponse.body?.data?.export_id;
    expect(exportId).toBeTruthy();

    const completedExport = await waitForExportCompletion({
      token: admin.token,
      exportId,
      timeoutMs: 45000,
    });

    expect(completedExport.status).toBe('completed');
    expect(completedExport.feature_count).toBeGreaterThanOrEqual(1);
    expect(completedExport.file_path).toBeTruthy();
    expect(Number(completedExport.file_size_bytes)).toBeGreaterThan(0);

    const downloadResponse = await request(app)
      .get(`${API_PREFIX}/exports/${exportId}/download`)
      .set(authHeader(admin.token));

    expect(downloadResponse.status).toBe(200);
    expect(downloadResponse.headers['content-type']).toMatch(/zip|octet-stream/i);
  });

  test('mobile-style export request accepts blank optional fields and exports only approved features inside bbox', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase10 Export Admin',
      emailPrefix: 'phase10-export-admin',
    });

    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Phase10 Export Contributor',
      emailPrefix: 'phase10-export-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Export Filter Category ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Export Filter Project ${Date.now()}`,
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

    const approvedInside = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: { type: 'Point', coordinates: [35.5018, 33.8938] },
        attributes: {
          feature_type: 'olive',
          tree_type: 'olive',
          site_name: 'Inside bbox',
        },
        accuracy_meters: 3.1,
      })
      .expect(201);

    const approvedOutside = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: { type: 'Point', coordinates: [36.05, 34.55] },
        attributes: {
          feature_type: 'cedar',
          tree_type: 'cedar',
          site_name: 'Outside bbox',
        },
        accuracy_meters: 4.4,
      })
      .expect(201);

    const draftOnly = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: { type: 'Point', coordinates: [35.52, 33.91] },
        attributes: {
          feature_type: 'pine',
          tree_type: 'pine',
          site_name: 'Draft only',
        },
        accuracy_meters: 2.5,
      })
      .expect(201);

    await request(app)
      .post(`${API_PREFIX}/features/${approvedInside.body.data.id}/submit`)
      .set(authHeader(contributorLogin.token))
      .send()
      .expect(200);
    await request(app)
      .post(`${API_PREFIX}/features/${approvedOutside.body.data.id}/submit`)
      .set(authHeader(contributorLogin.token))
      .send()
      .expect(200);

    await request(app)
      .post(`${API_PREFIX}/features/${approvedInside.body.data.id}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved', review_notes: 'Inside bbox approved.' })
      .expect(200);
    await request(app)
      .post(`${API_PREFIX}/features/${approvedOutside.body.data.id}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved', review_notes: 'Outside bbox approved.' })
      .expect(200);

    expect(draftOnly.body.data.id).toBeTruthy();

    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        format: 'geojson',
        date_from: '',
        date_to: '',
        bbox: '35.45,33.84,35.58,33.95',
      });

    expect(exportRequestResponse.status).toBe(202);
    const exportId = exportRequestResponse.body?.data?.export_id;
    expect(exportId).toBeTruthy();

    const completedExport = await waitForExportCompletion({
      token: admin.token,
      exportId,
      timeoutMs: 45000,
    });

    expect(completedExport.status).toBe('completed');
    expect(completedExport.feature_count).toBe(1);

    const downloadResponse = await request(app)
      .get(`${API_PREFIX}/exports/${exportId}/download`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(downloadResponse.headers['content-type']).toMatch(/zip|octet-stream/i);

    const zip = new AdmZip(completedExport.file_path);
    const geojsonEntry = zip
      .getEntries()
      .find((entry) => entry.entryName.toLowerCase().endsWith('.geojson'));

    expect(geojsonEntry).toBeTruthy();

    const geojson = JSON.parse(geojsonEntry.getData().toString('utf8'));

    expect(geojson.type).toBe('FeatureCollection');
    expect(geojson.features).toHaveLength(1);
    expect(geojson.features[0].properties.site_name).toBe('Inside bbox');
    expect(geojson.features[0].properties.feature_id).toBe(approvedInside.body.data.id);
  });

  test('shapefile export completes with full component set for approved features', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase10 Shapefile Admin',
      emailPrefix: 'phase10-shapefile-admin',
    });

    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Phase10 Shapefile Contributor',
      emailPrefix: 'phase10-shapefile-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Shapefile Export Category ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Shapefile Export Project ${Date.now()}`,
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

    const approvedFeature = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: { type: 'Point', coordinates: [35.5018, 33.8938] },
        attributes: {
          feature_type: 'olive',
          tree_type: 'olive',
          site_name: 'Shapefile point',
        },
        accuracy_meters: 3.4,
      })
      .expect(201);

    const pendingFeature = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: { type: 'Point', coordinates: [35.53, 33.9] },
        attributes: {
          feature_type: 'apple',
          tree_type: 'apple',
          site_name: 'Pending point',
        },
        accuracy_meters: 5.1,
      })
      .expect(201);

    await request(app)
      .post(`${API_PREFIX}/features/${approvedFeature.body.data.id}/submit`)
      .set(authHeader(contributorLogin.token))
      .send()
      .expect(200);

    await request(app)
      .post(`${API_PREFIX}/features/${pendingFeature.body.data.id}/submit`)
      .set(authHeader(contributorLogin.token))
      .send()
      .expect(200);

    await request(app)
      .post(`${API_PREFIX}/features/${approvedFeature.body.data.id}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved', review_notes: 'Approved shapefile feature.' })
      .expect(200);

    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        format: 'shapefile',
        date_from: '',
        date_to: '',
      });

    expect(exportRequestResponse.status).toBe(202);
    const exportId = exportRequestResponse.body?.data?.export_id;
    expect(exportId).toBeTruthy();

    const completedExport = await waitForExportCompletion({
      token: admin.token,
      exportId,
      timeoutMs: 45000,
    });

    expect(completedExport.status).toBe('completed');
    expect(completedExport.feature_count).toBe(1);

    const zip = new AdmZip(completedExport.file_path);
    const entryNames = zip.getEntries().map((entry) => entry.entryName);

    expect(entryNames.some((name) => name.endsWith('.shp'))).toBe(true);
    expect(entryNames.some((name) => name.endsWith('.shx'))).toBe(true);
    expect(entryNames.some((name) => name.endsWith('.dbf'))).toBe(true);
    expect(entryNames.some((name) => name.endsWith('.prj'))).toBe(true);
    expect(entryNames).toContain('metadata.json');
    expect(entryNames).toContain('README.txt');
  });
});
