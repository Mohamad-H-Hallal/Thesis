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
const AdmZip = require('adm-zip');
const fs = require('fs').promises;
const path = require('path');
const sharp = require('sharp');

jest.setTimeout(90000);

const tempFiles = [];

const createTempPhotoFile = async (name, background = { r: 20, g: 120, b: 60 }) => {
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.png`,
  );
  await sharp({
    create: {
      width: 8,
      height: 8,
      channels: 3,
      background,
    },
  })
    .png()
    .toFile(filePath);
  tempFiles.push(filePath);
  return filePath;
};

const uploadFeaturePhoto = async ({ token, featureId, name, background }) => {
  const photoPath = await createTempPhotoFile(name, background);
  const response = await request(app)
    .post(`${API_PREFIX}/photos/feature/${featureId}`)
    .set(authHeader(token))
    .field('latitude', '33.8938')
    .field('longitude', '35.5018')
    .field('accuracy_meters', '2.5')
    .attach('photos', photoPath);

  expect(response.status).toBe(201);
  expect(response.body.success).toBe(true);
  expect(response.body.data).toHaveLength(1);
  return response.body.data[0];
};

const getZipEntry = (zip, entryName) => {
  const entry = zip.getEntries().find((item) => item.entryName === entryName);
  expect(entry).toBeTruthy();
  return entry;
};

const assertSafeRelativePhotoPath = (entryNames, relativePath) => {
  expect(relativePath).toMatch(
    /^photos\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\.(png|jpg|jpeg|heic|heif)$/i,
  );
  expect(relativePath).not.toContain('..');
  expect(path.isAbsolute(relativePath)).toBe(false);
  expect(entryNames).toContain(relativePath);
};

const assertZipImageIsOpenable = async (zip, relativePath) => {
  const imageBuffer = getZipEntry(zip, relativePath).getData();
  const metadata = await sharp(imageBuffer).metadata();
  expect(metadata.width).toBe(8);
  expect(metadata.height).toBe(8);
  expect(['png', 'jpeg', 'heif']).toContain(metadata.format);
};

const readDbf = (buffer) => {
  const recordCount = buffer.readUInt32LE(4);
  const headerLength = buffer.readUInt16LE(8);
  const recordLength = buffer.readUInt16LE(10);
  const fields = [];

  for (let offset = 32; offset < headerLength - 1; offset += 32) {
    if (buffer[offset] === 0x0d) {
      break;
    }
    const name = buffer
      .subarray(offset, offset + 11)
      .toString('ascii')
      .replace(/\0.*$/, '')
      .trim()
      .toLowerCase();
    fields.push({
      name,
      type: String.fromCharCode(buffer[offset + 11]),
      length: buffer[offset + 16],
    });
  }

  const records = [];
  for (let recordIndex = 0; recordIndex < recordCount; recordIndex++) {
    const start = headerLength + recordIndex * recordLength;
    let fieldOffset = start + 1;
    const record = {};
    for (const field of fields) {
      record[field.name] = buffer
        .subarray(fieldOffset, fieldOffset + field.length)
        .toString('utf8')
        .trim();
      fieldOffset += field.length;
    }
    records.push(record);
  }

  return { fields, records };
};

const exportedGeojsonFeatures = (zip) =>
  zip
    .getEntries()
    .filter((entry) => entry.entryName.toLowerCase().endsWith('.geojson'))
    .flatMap((entry) => JSON.parse(entry.getData().toString('utf8')).features);

const expectExportedFeatureNames = (features, expectedNames) => {
  expect(features.map((feature) => feature.properties.site_name).sort()).toEqual(
    [...expectedNames].sort(),
  );
};

describe('Phase 10 E2E workflow', () => {
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

    const polygonFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: {
          type: 'Polygon',
          coordinates: [
            [
              [35.5, 33.89],
              [35.502, 33.89],
              [35.502, 33.892],
              [35.5, 33.892],
              [35.5, 33.89],
            ],
          ],
        },
        attributes: {
          feature_type: 'olive',
          tree_type: 'olive',
          condition: 'fair',
          site_name: 'Photo polygon',
        },
        accuracy_meters: 4.4,
      });
    expect(polygonFeatureResponse.status).toBe(201);
    const polygonFeatureId = polygonFeatureResponse.body.data.id;

    const noPhotoFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: {
          type: 'Point',
          coordinates: [35.503, 33.894],
        },
        attributes: {
          feature_type: 'citrus',
          tree_type: 'citrus',
          condition: 'good',
          site_name: 'No photo point',
        },
        accuracy_meters: 5,
      });
    expect(noPhotoFeatureResponse.status).toBe(201);
    const noPhotoFeatureId = noPhotoFeatureResponse.body.data.id;

    await uploadFeaturePhoto({
      token: contributorLogin.token,
      featureId,
      name: 'geojson-export-point-photo',
      background: { r: 20, g: 120, b: 60 },
    });
    await uploadFeaturePhoto({
      token: contributorLogin.token,
      featureId: polygonFeatureId,
      name: 'geojson-export-polygon-photo',
      background: { r: 160, g: 80, b: 20 },
    });

    for (const id of [featureId, polygonFeatureId, noPhotoFeatureId]) {
      const submitResponse = await request(app)
        .post(`${API_PREFIX}/features/${id}/submit`)
        .set(authHeader(contributorLogin.token))
        .send();
      expect(submitResponse.status).toBe(200);

      const reviewResponse = await request(app)
        .post(`${API_PREFIX}/features/${id}/review`)
        .set(authHeader(admin.token))
        .send({
          status: 'approved',
          review_notes: 'Geometry and attributes validated.',
        });
      expect(reviewResponse.status).toBe(200);
    }

    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        status_filter: ['approved'],
        format: 'geojson',
        include_photos: true,
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

    const zip = new AdmZip(completedExport.file_path);
    const entryNames = zip.getEntries().map((entry) => entry.entryName);
    const geojsonEntries = zip
      .getEntries()
      .filter((entry) => entry.entryName.toLowerCase().endsWith('.geojson'));

    expect(geojsonEntries.length).toBeGreaterThanOrEqual(2);
    expect(entryNames).toContain('README_PHOTOS.txt');
    expect(entryNames).toContain('photos_manifest.json');
    expect(entryNames).toContain('photos_manifest.csv');

    const manifest = JSON.parse(
      getZipEntry(zip, 'photos_manifest.json').getData().toString('utf8'),
    );
    expect(manifest).toHaveLength(2);
    const pointManifestRow = manifest.find((row) => row.feature_id === featureId);
    const polygonManifestRow = manifest.find((row) => row.feature_id === polygonFeatureId);
    expect(pointManifestRow).toBeTruthy();
    expect(polygonManifestRow).toBeTruthy();
    expect(pointManifestRow).not.toHaveProperty('status');
    expect(pointManifestRow.uploaded_at).toMatch(/Asia\/Beirut/);
    expect(pointManifestRow.uploaded_at).not.toMatch(/\+00:00|Z$/);
    if (pointManifestRow.taken_at) {
      expect(pointManifestRow.taken_at).toMatch(/Asia\/Beirut/);
      expect(pointManifestRow.taken_at).not.toMatch(/\+00:00|Z$/);
    }
    assertSafeRelativePhotoPath(entryNames, pointManifestRow.path);
    assertSafeRelativePhotoPath(entryNames, polygonManifestRow.path);
    await assertZipImageIsOpenable(zip, pointManifestRow.path);
    await assertZipImageIsOpenable(zip, polygonManifestRow.path);

    const photoReadme = getZipEntry(zip, 'README_PHOTOS.txt').getData().toString('utf8');
    expect(photoReadme).toContain('All timestamps are in Lebanon time (Asia/Beirut)');
    const manifestCsvHeader = getZipEntry(zip, 'photos_manifest.csv')
      .getData()
      .toString('utf8')
      .split('\n')[0];
    expect(manifestCsvHeader).toBe(
      'feature_id,photo_id,path,display_order,taken_at,uploaded_at,file_size_bytes',
    );

    const exportedFeatures = geojsonEntries.flatMap((entry) => {
      const geojson = JSON.parse(entry.getData().toString('utf8'));
      return geojson.features;
    });
    const pointFeature = exportedFeatures.find(
      (feature) => feature.properties.feature_id === featureId,
    );
    const polygonFeature = exportedFeatures.find(
      (feature) => feature.properties.feature_id === polygonFeatureId,
    );
    const noPhotoFeature = exportedFeatures.find(
      (feature) => feature.properties.feature_id === noPhotoFeatureId,
    );
    expect(pointFeature.properties.photo_count).toBe(1);
    expect(pointFeature.properties.primary_photo_path).toBe(pointManifestRow.path);
    expect(pointFeature.properties.photo_paths).toEqual([pointManifestRow.path]);
    expect(pointFeature.properties.photo_manifest_ref).toBe('photos_manifest.json');
    expect(polygonFeature.properties.photo_count).toBe(1);
    expect(polygonFeature.properties.primary_photo_path).toBe(polygonManifestRow.path);
    expect(noPhotoFeature.properties.photo_count).toBe(0);
    expect(noPhotoFeature.properties.primary_photo_path).toBeNull();
    expect(noPhotoFeature.properties.photo_paths).toEqual([]);
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
    expect(geojson.features[0].properties.accuracy_meters).toBeUndefined();
    expect(Object.keys(geojson.features[0].properties)).not.toContain('accuracy_meters');
  });

  test('export supports drawn polygon and feature type filters together', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase10 Polygon Export Admin',
      emailPrefix: 'phase10-polygon-export-admin',
    });

    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Phase10 Polygon Export Contributor',
      emailPrefix: 'phase10-polygon-export-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Polygon Export Category ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Polygon Export Project ${Date.now()}`,
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

    const createAndApprove = async ({ geom, attributes }) => {
      const created = await request(app)
        .post(`${API_PREFIX}/features`)
        .set(authHeader(contributorLogin.token))
        .send({
          project_id: project.id,
          geom,
          attributes,
          accuracy_meters: 3.2,
        })
        .expect(201);

      await request(app)
        .post(`${API_PREFIX}/features/${created.body.data.id}/submit`)
        .set(authHeader(contributorLogin.token))
        .send()
        .expect(200);

      await request(app)
        .post(`${API_PREFIX}/features/${created.body.data.id}/review`)
        .set(authHeader(admin.token))
        .send({ status: 'approved', review_notes: 'Approved for polygon export.' })
        .expect(200);

      return created.body.data.id;
    };

    const oliveInsideId = await createAndApprove({
      geom: { type: 'Point', coordinates: [35.5018, 33.8938] },
      attributes: { feature_type: 'olive', site_name: 'Olive inside polygon' },
    });
    await createAndApprove({
      geom: { type: 'Point', coordinates: [35.502, 33.894] },
      attributes: { feature_type: 'citrus', site_name: 'Citrus inside polygon' },
    });
    await createAndApprove({
      geom: { type: 'Point', coordinates: [36.05, 34.55] },
      attributes: { feature_type: 'olive', site_name: 'Olive outside polygon' },
    });

    await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        format: 'geojson',
        export_polygon: JSON.stringify({ type: 'Point', coordinates: [35.5, 33.89] }),
      })
      .expect(400);

    const polygon = {
      type: 'Polygon',
      coordinates: [
        [
          [35.49, 33.88],
          [35.52, 33.88],
          [35.52, 33.91],
          [35.49, 33.91],
          [35.49, 33.88],
        ],
      ],
    };

    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        format: 'geojson',
        date_from: '2000-01-01',
        feature_type: 'olive',
        export_polygon: JSON.stringify(polygon),
      })
      .expect(202);

    const completedExport = await waitForExportCompletion({
      token: admin.token,
      exportId: exportRequestResponse.body.data.export_id,
      timeoutMs: 45000,
    });

    expect(completedExport.status).toBe('completed');
    expect(completedExport.feature_count).toBe(1);
    expect(completedExport.export_parameters.feature_type).toBe('olive');
    expect(completedExport.export_parameters.export_polygon).toEqual(polygon);

    const zip = new AdmZip(completedExport.file_path);
    const geojsonEntry = zip
      .getEntries()
      .find((entry) => entry.entryName.toLowerCase().endsWith('.geojson'));
    const geojson = JSON.parse(geojsonEntry.getData().toString('utf8'));

    expect(geojson.features).toHaveLength(1);
    expect(geojson.features[0].properties.feature_id).toBe(oliveInsideId);
    expect(geojson.features[0].properties.site_name).toBe('Olive inside polygon');
  });

  test('feature type export filter combines with bbox, date, polygon, photos, GeoJSON, and Shapefile', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase10 Combined Filter Admin',
      emailPrefix: 'phase10-combined-filter-admin',
    });

    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Phase10 Combined Filter Contributor',
      emailPrefix: 'phase10-combined-filter-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Combined Filter Category ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Combined Filter Project ${Date.now()}`,
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

    const createApprovedFeature = async ({
      name,
      featureType,
      coordinates,
      collectedAt,
      photo = false,
    }) => {
      const created = await request(app)
        .post(`${API_PREFIX}/features`)
        .set(authHeader(contributorLogin.token))
        .send({
          project_id: project.id,
          geom: { type: 'Point', coordinates },
          attributes: {
            feature_type: featureType,
            site_name: name,
          },
          accuracy_meters: 3,
        })
        .expect(201);

      const featureId = created.body.data.id;
      await pool.query('UPDATE spatial_feature SET collected_at = $1 WHERE id = $2', [
        collectedAt,
        featureId,
      ]);

      if (photo) {
        await uploadFeaturePhoto({
          token: contributorLogin.token,
          featureId,
          name: `combined-filter-${name.replace(/[^a-z0-9]/gi, '-').toLowerCase()}`,
          background: { r: 60, g: 110, b: 180 },
        });
      }

      await request(app)
        .post(`${API_PREFIX}/features/${featureId}/submit`)
        .set(authHeader(contributorLogin.token))
        .send()
        .expect(200);

      await request(app)
        .post(`${API_PREFIX}/features/${featureId}/review`)
        .set(authHeader(admin.token))
        .send({ status: 'approved', review_notes: 'Approved for combined filter export.' })
        .expect(200);

      return featureId;
    };

    const oliveInsideCurrentId = await createApprovedFeature({
      name: 'Olive inside current',
      featureType: 'olive',
      coordinates: [35.5018, 33.8938],
      collectedAt: '2024-05-10T09:00:00Z',
      photo: true,
    });
    await createApprovedFeature({
      name: 'Citrus inside current',
      featureType: 'citrus',
      coordinates: [35.503, 33.894],
      collectedAt: '2024-05-10T10:00:00Z',
    });
    await createApprovedFeature({
      name: 'Olive outside current',
      featureType: 'olive',
      coordinates: [36.05, 34.55],
      collectedAt: '2024-05-10T11:00:00Z',
    });
    await createApprovedFeature({
      name: 'Olive inside old',
      featureType: 'olive',
      coordinates: [35.504, 33.895],
      collectedAt: '2020-01-10T09:00:00Z',
    });
    await createApprovedFeature({
      name: 'Pine inside current',
      featureType: 'pine',
      coordinates: [35.506, 33.896],
      collectedAt: '2024-05-11T09:00:00Z',
    });

    const bbox = '35.49,33.88,35.52,33.91';
    const polygon = {
      type: 'Polygon',
      coordinates: [
        [
          [35.49, 33.88],
          [35.52, 33.88],
          [35.52, 33.91],
          [35.49, 33.91],
          [35.49, 33.88],
        ],
      ],
    };

    const requestExport = async (format, params) => {
      const response = await request(app)
        .post(`${API_PREFIX}/exports/project/${project.id}`)
        .set(authHeader(admin.token))
        .send({
          format,
          ...params,
        })
        .expect(202);

      const completed = await waitForExportCompletion({
        token: admin.token,
        exportId: response.body.data.export_id,
        timeoutMs: 45000,
      });
      expect(completed.status).toBe('completed');
      return completed;
    };

    const allWithBbox = await requestExport('geojson', { bbox });
    expectExportedFeatureNames(exportedGeojsonFeatures(new AdmZip(allWithBbox.file_path)), [
      'Olive inside current',
      'Citrus inside current',
      'Olive inside old',
      'Pine inside current',
    ]);

    const oliveWithBbox = await requestExport('geojson', {
      bbox,
      feature_type: 'olive',
    });
    expectExportedFeatureNames(exportedGeojsonFeatures(new AdmZip(oliveWithBbox.file_path)), [
      'Olive inside current',
      'Olive inside old',
    ]);

    const oliveWithDate = await requestExport('geojson', {
      feature_type: 'olive',
      date_from: '2024-05-01',
      date_to: '2024-05-31',
    });
    expectExportedFeatureNames(exportedGeojsonFeatures(new AdmZip(oliveWithDate.file_path)), [
      'Olive inside current',
      'Olive outside current',
    ]);

    const oliveWithPolygon = await requestExport('geojson', {
      feature_type: 'olive',
      export_polygon: JSON.stringify(polygon),
    });
    expectExportedFeatureNames(exportedGeojsonFeatures(new AdmZip(oliveWithPolygon.file_path)), [
      'Olive inside current',
      'Olive inside old',
    ]);

    const geojsonAllFilters = await requestExport('geojson', {
      bbox,
      feature_type: 'olive',
      date_from: '2024-05-01',
      date_to: '2024-05-31',
      export_polygon: JSON.stringify(polygon),
      include_photos: true,
    });
    const geojsonAllFiltersZip = new AdmZip(geojsonAllFilters.file_path);
    const geojsonAllFilterFeatures = exportedGeojsonFeatures(geojsonAllFiltersZip);
    expect(geojsonAllFilterFeatures).toHaveLength(1);
    expect(geojsonAllFilterFeatures[0].properties.feature_id).toBe(oliveInsideCurrentId);
    expect(geojsonAllFilterFeatures[0].properties.photo_count).toBe(1);
    expect(getZipEntry(geojsonAllFiltersZip, 'photos_manifest.json')).toBeTruthy();

    const shapefileAllFilters = await requestExport('shapefile', {
      bbox,
      feature_type: 'olive',
      date_from: '2024-05-01',
      date_to: '2024-05-31',
      export_polygon: JSON.stringify(polygon),
      include_photos: true,
    });
    expect(shapefileAllFilters.feature_count).toBe(1);
    const shapefileZip = new AdmZip(shapefileAllFilters.file_path);
    const manifest = JSON.parse(
      getZipEntry(shapefileZip, 'photos_manifest.json').getData().toString('utf8'),
    );
    expect(manifest).toHaveLength(1);
    expect(manifest[0].feature_id).toBe(oliveInsideCurrentId);
    const dbfEntry = shapefileZip
      .getEntries()
      .find((entry) => entry.entryName.toLowerCase().endsWith('.dbf'));
    expect(dbfEntry).toBeTruthy();
    const dbf = readDbf(dbfEntry.getData());
    expect(dbf.records).toHaveLength(1);
    expect(Number(dbf.records[0].photo_cnt)).toBe(1);
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

    await uploadFeaturePhoto({
      token: contributorLogin.token,
      featureId: approvedFeature.body.data.id,
      name: 'shapefile-export-photo',
      background: { r: 20, g: 80, b: 180 },
    });

    await uploadFeaturePhoto({
      token: contributorLogin.token,
      featureId: pendingFeature.body.data.id,
      name: 'shapefile-filtered-out-photo',
      background: { r: 180, g: 40, b: 40 },
    });

    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        format: 'shapefile',
        include_photos: true,
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

    const downloadResponse = await request(app)
      .get(`${API_PREFIX}/exports/${exportId}/download`)
      .set(authHeader(admin.token));
    expect(downloadResponse.status).toBe(200);
    expect(downloadResponse.headers['content-type']).toMatch(/zip|octet-stream/i);

    const zip = new AdmZip(completedExport.file_path);
    const entryNames = zip.getEntries().map((entry) => entry.entryName);

    expect(entryNames.some((name) => name.endsWith('.shp'))).toBe(true);
    expect(entryNames.some((name) => name.endsWith('.shx'))).toBe(true);
    expect(entryNames.some((name) => name.endsWith('.dbf'))).toBe(true);
    expect(entryNames.some((name) => name.endsWith('.prj'))).toBe(true);
    expect(entryNames).toContain('metadata.json');
    expect(entryNames).toContain('README.txt');
    expect(entryNames).toContain('README_PHOTOS.txt');
    expect(entryNames).toContain('photos_manifest.json');
    expect(entryNames).toContain('photos_manifest.csv');

    const readmeEntry = zip.getEntries().find((entry) => entry.entryName === 'README.txt');
    expect(readmeEntry).toBeTruthy();
    const readme = readmeEntry.getData().toString('utf8');
    expect(readme).not.toContain('accuracy_meters');
    expect(readme).not.toContain('accuracy:');

    const manifest = JSON.parse(
      getZipEntry(zip, 'photos_manifest.json').getData().toString('utf8'),
    );
    expect(manifest).toHaveLength(1);
    expect(manifest[0].feature_id).toBe(approvedFeature.body.data.id);
    expect(manifest[0]).not.toHaveProperty('status');
    expect(manifest[0].uploaded_at).toMatch(/Asia\/Beirut/);
    expect(manifest[0].uploaded_at).not.toMatch(/\+00:00|Z$/);
    if (manifest[0].taken_at) {
      expect(manifest[0].taken_at).toMatch(/Asia\/Beirut/);
      expect(manifest[0].taken_at).not.toMatch(/\+00:00|Z$/);
    }
    assertSafeRelativePhotoPath(entryNames, manifest[0].path);
    await assertZipImageIsOpenable(zip, manifest[0].path);
    expect(manifest.some((row) => row.feature_id === pendingFeature.body.data.id)).toBe(false);

    const dbfEntry = zip
      .getEntries()
      .find((entry) => entry.entryName.toLowerCase().endsWith('.dbf'));
    expect(dbfEntry).toBeTruthy();
    const dbf = readDbf(dbfEntry.getData());
    expect(dbf.fields.map((field) => field.name)).toEqual(
      expect.arrayContaining(['photo_cnt', 'photo_ref']),
    );
    expect(dbf.fields.every((field) => field.name.length <= 10)).toBe(true);
    const photoRefField = dbf.fields.find((field) => field.name === 'photo_ref');
    expect(photoRefField.length).toBeLessThanOrEqual(254);
    expect(Number(dbf.records[0].photo_cnt)).toBe(1);
    expect(dbf.records[0].photo_ref).toBe(manifest[0].path);
  });

  test('feature creation accepts free-text attributes like name when present in the collection schema', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase10 Admin Schema',
      emailPrefix: 'phase10-admin-schema',
    });

    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Phase10 Contributor Schema',
      emailPrefix: 'phase10-contributor-schema',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Schema Fields ${Date.now()}`,
    });

    const createProjectResponse = await request(app)
      .post(`${API_PREFIX}/projects`)
      .set(authHeader(admin.token))
      .send({
        category_id: category.id,
        name: `Schema Name Field ${Date.now()}`,
        description: 'Project with a free-text name field',
        collection_form_schema: {
          schemaVersion: '0.1.0',
          fields: [
            {
              key: 'feature_type',
              label: 'Feature type',
              type: 'select',
              required: true,
              options: ['olive', 'citrus'],
            },
            {
              key: 'name',
              label: 'Name',
              type: 'text',
              required: false,
            },
          ],
        },
        status: 'draft',
        requires_photos: false,
        min_photos: 0,
        max_photos: 3,
        visible_to_viewers: false,
        visible_to_contributors: true,
      });

    expect(createProjectResponse.status).toBe(201);
    const projectId = createProjectResponse.body.data.id;

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

    const createFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: projectId,
        geom: {
          type: 'Point',
          coordinates: [35.5018, 33.8938],
        },
        attributes: {
          feature_type: 'olive',
          name: 'Mazami',
        },
        accuracy_meters: 4.2,
      });

    expect(createFeatureResponse.status).toBe(201);

    const submitResponse = await request(app)
      .post(`${API_PREFIX}/features/${createFeatureResponse.body.data.id}/submit`)
      .set(authHeader(contributorLogin.token))
      .send();

    expect(submitResponse.status).toBe(200);
  });
});
