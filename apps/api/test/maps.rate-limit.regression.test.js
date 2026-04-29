const fs = require('fs').promises;
const path = require('path');

const { applyTestEnvDefaults } = require('../src/config/testEnv');
applyTestEnvDefaults();

const { buildApp } = require('../src/app');
const { validateEnv } = require('../src/config/env');
const {
  app,
  API_PREFIX,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  createAdminUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  loginUser,
} = require('./helpers/api-test-helpers');

const tempFiles = [];

const createTempGeoJsonFile = async (name, payload) => {
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.geojson`,
  );
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), 'utf8');
  tempFiles.push(filePath);
  return filePath;
};

const waitForImportStatus = async ({
  importId,
  token,
  expectedStatuses,
  attempts = 40,
  delayMs = 250,
}) => {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const response = await request(app)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(token));

    if (response.status !== 200) {
      throw new Error(`Unable to load import ${importId}: ${response.status}`);
    }

    const status = response.body?.data?.job?.status;
    if (expectedStatuses.includes(status)) {
      return response;
    }

    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }

  throw new Error(
    `Import ${importId} did not reach one of [${expectedStatuses.join(', ')}] in time.`,
  );
};

jest.setTimeout(90000);

describe('Map read rate-limit regression', () => {
  const lowLimitApp = buildApp({
    ...validateEnv(),
    NODE_ENV: 'test',
    CORS_ORIGIN: '',
    CORS_STRICT: false,
    CORS_CREDENTIALS: true,
    TRUST_PROXY: false,
    ENFORCE_HTTPS: false,
    API_VERSION_PREFIX: API_PREFIX,
    ENABLE_LEGACY_API_PREFIX: true,
    RATE_LIMIT_WINDOW_MS: 15 * 60 * 1000,
    RATE_LIMIT_MAX_REQUESTS: 5,
    RATE_LIMIT_AUTH_MAX_REQUESTS: 1000,
    RATE_LIMIT_EXPORT_MAX_REQUESTS: 1000,
    AUDIT_LOG_ENABLED: true,
    METRICS_ENABLED: false,
  });

  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    for (const filePath of tempFiles) {
      try {
        await fs.unlink(filePath);
      } catch (_error) {
        // Ignore missing temp files
      }
    }
    await shutdown();
  });

  test('authenticated project/import map reads do not exhaust generic API limits', async () => {
    const admin = await createAdminUser({
      fullName: 'Rate Limit Admin',
      emailPrefix: 'rate-limit-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Rate Limit Contributor',
      emailPrefix: 'rate-limit-contributor',
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorRegistration.user.id,
    });
    const contributorLogin = await loginUser({
      email: contributorRegistration.email,
      password: contributorRegistration.password,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Rate Limit Category ${Date.now()}`,
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Rate Limit Project ${Date.now()}`,
      visibleToContributors: true,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);

    const assignment = await createAssignment({
      token: admin.token,
      projectId: project.id,
      userId: contributorRegistration.user.id,
    });
    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignment.id,
      status: 'approved',
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
          condition: 'good',
        },
      })
      .expect(201);

    const featureId = createFeatureResponse.body.data.id;
    await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(authHeader(contributorLogin.token))
      .send()
      .expect(200);
    await request(app)
      .post(`${API_PREFIX}/features/${featureId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        review_notes: 'Approved for rate-limit regression coverage.',
      })
      .expect(200);

    const geojsonPath = await createTempGeoJsonFile('rate-limit-import', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Import feature A' },
          geometry: {
            type: 'Point',
            coordinates: [35.5005, 33.9005],
          },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'cedar', name: 'Import feature B' },
          geometry: {
            type: 'Point',
            coordinates: [35.5025, 33.9025],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const importId = uploadResponse.body.data.id;
    await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review', 'failed'],
    });

    for (let index = 0; index < 12; index += 1) {
      const projectTileResponse = await request(lowLimitApp)
        .get(`${API_PREFIX}/features/tiles/10/612/399`)
        .set(authHeader(admin.token))
        .query({ project_id: project.id, status: 'approved' });
      expect(projectTileResponse.status).toBe(200);

      const importTileResponse = await request(lowLimitApp)
        .get(`${API_PREFIX}/imports/${importId}/tiles/10/612/399`)
        .set(authHeader(admin.token));
      expect(importTileResponse.status).toBe(200);
    }

    const featureDetailResponse = await request(lowLimitApp)
      .get(`${API_PREFIX}/features/${featureId}`)
      .set(authHeader(admin.token));
    expect(featureDetailResponse.status).toBe(200);

    const importsListResponse = await request(lowLimitApp)
      .get(`${API_PREFIX}/imports?page=1&limit=20`)
      .set(authHeader(admin.token));
    expect(importsListResponse.status).toBe(200);
    expect(importsListResponse.body.pagination.total).toBe(1);

    const importDetailResponse = await request(lowLimitApp)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(admin.token));
    expect(importDetailResponse.status).toBe(200);
  });
});
