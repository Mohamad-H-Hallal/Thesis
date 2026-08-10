const fs = require('fs').promises;
const path = require('path');
const AdmZip = require('adm-zip');
const shpwrite = require('@mapbox/shp-write');

const {
  app,
  API_PREFIX,
  request,
  authHeader,
  pool,
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

jest.setTimeout(90000);

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

const createTempTextFile = async (name, extension, content) => {
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.${extension}`,
  );
  await fs.writeFile(filePath, content, 'utf8');
  tempFiles.push(filePath);
  return filePath;
};

const createTempBinaryFile = async (name, extension, content) => {
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.${extension}`,
  );
  await fs.writeFile(filePath, Buffer.isBuffer(content) ? content : Buffer.from(content));
  tempFiles.push(filePath);
  return filePath;
};

const createTempXlsxFile = async (name, rowsOrSheets) => {
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.xlsx`,
  );
  const sheets = Array.isArray(rowsOrSheets?.[0]?.rows)
    ? rowsOrSheets
    : [{ name: 'Sheet 1', rows: rowsOrSheets }];
  const columnName = (index) => String.fromCharCode('A'.charCodeAt(0) + index);
  const escapeXml = (value) =>
    String(value ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  const sheetXml = (rows) =>
    rows
      .map(
        (row, rowIndex) =>
          `<row r="${rowIndex + 1}">${row
            .map(
              (value, colIndex) =>
                `<c r="${columnName(colIndex)}${rowIndex + 1}" t="inlineStr"><is><t>${escapeXml(
                  value,
                )}</t></is></c>`,
            )
            .join('')}</row>`,
      )
      .join('');
  const zip = new AdmZip();
  zip.addFile(
    '[Content_Types].xml',
    Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  ${sheets
    .map(
      (_sheet, index) =>
        `<Override PartName="/xl/worksheets/sheet${index + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`,
    )
    .join('\n  ')}
</Types>`),
  );
  zip.addFile(
    '_rels/.rels',
    Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>`),
  );
  zip.addFile(
    'xl/workbook.xml',
    Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>${sheets
    .map(
      (sheet, index) =>
        `<sheet name="${escapeXml(sheet.name ?? `Sheet ${index + 1}`)}" sheetId="${index + 1}" r:id="rId${index + 1}"/>`,
    )
    .join('')}</sheets>
</workbook>`),
  );
  zip.addFile(
    'xl/_rels/workbook.xml.rels',
    Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  ${sheets
    .map(
      (_sheet, index) =>
        `<Relationship Id="rId${index + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${index + 1}.xml"/>`,
    )
    .join('\n  ')}
</Relationships>`),
  );
  for (const [index, sheet] of sheets.entries()) {
    zip.addFile(
      `xl/worksheets/sheet${index + 1}.xml`,
      Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>${sheetXml(sheet.rows)}</sheetData>
</worksheet>`),
    );
  }
  zip.writeZip(filePath);
  tempFiles.push(filePath);
  return filePath;
};

const createTempZipFile = async (name, entries, extension = 'zip') => {
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.${extension}`,
  );
  const zip = new AdmZip();
  for (const [entryName, content] of Object.entries(entries)) {
    zip.addFile(
      entryName,
      Buffer.isBuffer(content) ? content : Buffer.from(String(content), 'utf8'),
    );
  }
  zip.writeZip(filePath);
  tempFiles.push(filePath);
  return filePath;
};

const createTempShapefileZipFile = async (name, geojson) => {
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.zip`,
  );
  const zipped = await shpwrite.zip(geojson);
  await fs.writeFile(filePath, Buffer.from(zipped, 'base64'));
  tempFiles.push(filePath);
  return filePath;
};

const createTempShapefileZipWithout = async (name, geojson, omittedSuffixes) => {
  const filePath = await createTempShapefileZipFile(name, geojson);
  const zip = new AdmZip(filePath);
  for (const entry of zip.getEntries()) {
    if (omittedSuffixes.some((suffix) => entry.entryName.toLowerCase().endsWith(suffix))) {
      zip.deleteFile(entry.entryName);
    }
  }
  zip.writeZip(filePath);
  return filePath;
};

const waitForImportStatus = async ({
  importId,
  token,
  expectedStatuses,
  attempts = 40,
  delayMs = 250,
}) => {
  let lastStatus = 'unknown';
  let lastMessage = '';
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const response = await request(app)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(token));

    if (response.status !== 200) {
      throw new Error(`Unable to load import ${importId}: ${response.status}`);
    }

    const status = response.body.data?.job?.status;
    lastStatus = status ?? 'unknown';
    lastMessage = response.body.data?.job?.processing_message ?? '';
    if (expectedStatuses.includes(status)) {
      return response;
    }

    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }

  throw new Error(
    `Import ${importId} did not reach one of [${expectedStatuses.join(', ')}] in time. Last status: ${lastStatus}. Message: ${lastMessage}`,
  );
};

const l4DescriptorOptions = ['Olives', 'Fruit Trees', 'Citrus Fruit Trees', 'Vineyards'];

const l4DescriptorSchema = () => ({
  version: 'import-test-v1',
  fields: [
    {
      key: 'L4_descr',
      label: 'L4_descr',
      type: 'select',
      required: true,
      options: l4DescriptorOptions,
    },
  ],
});

const labeledFeatureTypeSchema = () => ({
  version: 'import-test-v1',
  fields: [
    {
      key: 'feature_type',
      label: 'L4_descr',
      type: 'select',
      required: true,
      options: l4DescriptorOptions,
    },
  ],
});

const schemaWithField = (field) => ({
  version: 'import-test-v1',
  fields: [field],
});

const pointFeatureCollection = (properties, coordinates = [35.5009, 33.9009]) => ({
  type: 'FeatureCollection',
  features: [
    {
      type: 'Feature',
      properties,
      geometry: { type: 'Point', coordinates },
    },
  ],
});

const kmlPoint = ({ title, fieldName, value }) => `<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>${title}</name>
      <ExtendedData><Data name="${fieldName}"><value>${value}</value></Data></ExtendedData>
      <Point><coordinates>35.501,33.901,0</coordinates></Point>
    </Placemark>
  </Document>
</kml>`;

const createActiveImportProject = async (emailPrefix, options = {}) => {
  const safePrefix = emailPrefix.toLowerCase().replace(/[^a-z0-9-]+/g, '-');
  const admin = await createAdminUser({
    fullName: `${emailPrefix} Admin`,
    emailPrefix: `${safePrefix}-admin`,
  });
  const contributorRegistration = await registerUser({
    role: 'contributor',
    fullName: `${emailPrefix} Contributor`,
    emailPrefix: `${safePrefix}-contributor`,
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
    name: `${emailPrefix} Category`,
  });
  const project = await createProject({
    token: admin.token,
    categoryId: category.id,
    name: `${emailPrefix} Project`,
    visibleToContributors: true,
  });
  if (options.collectionFormSchema) {
    await pool.query('UPDATE project SET collection_form_schema = $1::jsonb WHERE id = $2', [
      JSON.stringify(options.collectionFormSchema),
      project.id,
    ]);
  }
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
  return { admin, contributorLogin, contributorRegistration, project };
};

const uploadAndWaitForImport = async ({
  token,
  reviewerToken,
  projectId,
  filePath,
  status = 'pending_review',
}) => {
  const uploadResponse = await request(app)
    .post(`${API_PREFIX}/imports/project/${projectId}/upload`)
    .set(authHeader(token))
    .attach('file', filePath)
    .expect(202);

  return waitForImportStatus({
    importId: uploadResponse.body.data.id,
    token: reviewerToken,
    expectedStatuses: [status],
  });
};

const createStagedImportJob = async ({
  projectId,
  uploadedByUserId,
  originalFilename = 'direct-staged-import.geojson',
  features,
}) => {
  const jobResult = await pool.query(
    `INSERT INTO gis_import_job (
       project_id,
       uploaded_by_user_id,
       original_filename,
       stored_filename,
       file_path,
       file_size_bytes,
       file_checksum_sha256,
       file_type,
       status,
       file_metadata,
       validation_summary,
       processed_at
     ) VALUES (
       $1,
       $2,
       $3,
       $4,
       $5,
       $6,
       repeat('a', 64),
       'geojson',
       'pending_review',
       '{}'::jsonb,
       '{}'::jsonb,
       CURRENT_TIMESTAMP
     )
     RETURNING id`,
    [
      projectId,
      uploadedByUserId,
      originalFilename,
      `${originalFilename}-${Date.now()}`,
      `/tmp/${originalFilename}`,
      1024,
    ],
  );
  const importId = jobResult.rows[0].id;
  const batchSize = 250;
  for (let index = 0; index < features.length; index += batchSize) {
    const batch = features.slice(index, index + batchSize);
    const values = [];
    const params = [];
    for (const [batchIndex, feature] of batch.entries()) {
      const base = params.length;
      params.push(
        importId,
        index + batchIndex,
        feature.displayTitle,
        feature.geometryType ?? null,
        feature.geometry ? JSON.stringify(feature.geometry) : null,
        JSON.stringify(feature.attributes ?? {}),
        feature.status ?? 'pending_review',
        JSON.stringify(feature.validationWarnings ?? []),
        JSON.stringify(feature.validationErrors ?? []),
      );
      values.push(
        `(
          $${base + 1},
          $${base + 2},
          $${base + 3},
          $${base + 4},
          CASE WHEN $${base + 5}::text IS NULL THEN NULL ELSE ST_SetSRID(ST_GeomFromGeoJSON($${base + 5}), 4326) END,
          $${base + 6}::jsonb,
          $${base + 7}::gis_import_feature_status,
          $${base + 8}::jsonb,
          $${base + 9}::jsonb,
          '{}'::jsonb
        )`,
      );
    }
    await pool.query(
      `INSERT INTO gis_import_feature (
         import_job_id,
         source_index,
         display_title,
         geometry_type,
         geom,
         attributes,
         status,
         validation_warnings,
         validation_errors,
         validation_report
       ) VALUES ${values.join(',')}`,
      params,
    );
  }
  return importId;
};

describe('GIS import workflow', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    for (const filePath of tempFiles) {
      try {
        await fs.unlink(filePath);
      } catch (_error) {
        // ignore missing temp files
      }
    }
    await shutdown();
  });

  test('stages CSV latitude and longitude imports for review', async () => {
    const { admin, contributorLogin, project } =
      await createActiveImportProject('CSV LatLon Import');
    const csvPath = await createTempTextFile(
      'csv-latlon-import',
      'csv',
      'name,feature_type,latitude,longitude\nCSV point,olive,33.9001,35.5001\n',
    );

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', csvPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailResponse.body.data.job.file_type).toBe('csv');
    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].geometry_type).toBe('Point');
  });

  test('stages CSV WKT imports for review', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject('CSV WKT Import');
    const csvPath = await createTempTextFile(
      'csv-wkt-import',
      'csv',
      'name,feature_type,wkt\nWKT point,cedar,"POINT (35.5002 33.9002)"\n',
    );

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', csvPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].display_title).toBe('WKT point');
  });

  test('stages XLSX latitude and longitude imports for review', async () => {
    const { admin, contributorLogin, project } =
      await createActiveImportProject('XLSX LatLon Import');
    const xlsxPath = await createTempXlsxFile('xlsx-latlon-import', [
      ['name', 'feature_type', 'lat', 'lng'],
      ['Excel point', 'olive', '33.9003', '35.5003'],
    ]);

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', xlsxPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailResponse.body.data.job.file_type).toBe('xlsx');
    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].display_title).toBe('Excel point');
  });

  test('validates dynamic L4_descr required fields across supported import file types', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject(
      'Dynamic Required Field Imports',
      { collectionFormSchema: l4DescriptorSchema() },
    );

    const fixtures = [
      {
        label: 'GeoJSON',
        expectedFileType: 'geojson',
        value: 'Olives',
        createFile: () =>
          createTempGeoJsonFile(
            'dynamic-l4-geojson',
            pointFeatureCollection({ name: 'Dynamic GeoJSON', L4_descr: 'Olives' }),
          ),
      },
      {
        label: 'Shapefile ZIP',
        expectedFileType: 'shapefile_zip',
        value: 'Fruit Trees',
        createFile: () =>
          createTempShapefileZipFile(
            'dynamic-l4-shapefile',
            pointFeatureCollection({ name: 'Dynamic Shapefile', L4_descr: 'Fruit Trees' }),
          ),
      },
      {
        label: 'KML',
        expectedFileType: 'kml',
        value: 'Citrus Fruit Trees',
        createFile: () =>
          createTempTextFile(
            'dynamic-l4-kml',
            'kml',
            kmlPoint({
              title: 'Dynamic KML',
              fieldName: 'L4_descr',
              value: 'Citrus Fruit Trees',
            }),
          ),
      },
      {
        label: 'KMZ',
        expectedFileType: 'kmz',
        value: 'Vineyards',
        createFile: () =>
          createTempZipFile(
            'dynamic-l4-kmz',
            {
              'doc.kml': kmlPoint({
                title: 'Dynamic KMZ',
                fieldName: 'L4_descr',
                value: 'Vineyards',
              }),
            },
            'kmz',
          ),
      },
      {
        label: 'CSV',
        expectedFileType: 'csv',
        value: 'Olives',
        createFile: () =>
          createTempTextFile(
            'dynamic-l4-csv',
            'csv',
            'name,L4_descr,lat,lon\nDynamic CSV,Olives,33.902,35.502\n',
          ),
      },
      {
        label: 'XLSX',
        expectedFileType: 'xlsx',
        value: 'Fruit Trees',
        createFile: () =>
          createTempXlsxFile('dynamic-l4-xlsx', [
            ['name', 'L4_descr', 'lat', 'lon'],
            ['Dynamic XLSX', 'Fruit Trees', '33.903', '35.503'],
          ]),
      },
    ];

    for (const fixture of fixtures) {
      const detailResponse = await uploadAndWaitForImport({
        token: contributorLogin.token,
        reviewerToken: admin.token,
        projectId: project.id,
        filePath: await fixture.createFile(),
      });

      expect(detailResponse.body.data.job.file_type).toBe(fixture.expectedFileType);
      expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
      expect(detailResponse.body.data.job.failed_feature_count).toBe(0);
      expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual([]);
      expect(detailResponse.body.data.preview_features[0].attributes.L4_descr).toBe(fixture.value);
    }
  });

  test('matches field labels and stores canonical project field keys', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject(
      'Labeled Feature Type Import',
      { collectionFormSchema: labeledFeatureTypeSchema() },
    );
    const geojsonPath = await createTempGeoJsonFile(
      'label-matched-feature-type',
      pointFeatureCollection({ name: 'Label matched feature', L4_descr: 'Olives' }),
    );

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: geojsonPath,
    });

    const attributes = detailResponse.body.data.preview_features[0].attributes;
    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual([]);
    expect(attributes.L4_descr).toBe('Olives');
    expect(attributes.feature_type).toBe('Olives');
  });

  test('reports missing dynamic required fields clearly', async () => {
    const { contributorLogin, project } = await createActiveImportProject(
      'Missing Dynamic Required Field',
      { collectionFormSchema: l4DescriptorSchema() },
    );
    const geojsonPath = await createTempGeoJsonFile(
      'missing-l4-descr',
      pointFeatureCollection({ name: 'Missing L4 descriptor' }),
    );

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: contributorLogin.token,
      expectedStatuses: ['failed'],
    });

    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required field: L4_descr']),
    );
  });

  test('reports invalid dynamic select values per feature', async () => {
    const { contributorLogin, project } = await createActiveImportProject(
      'Invalid Dynamic Select Value',
      { collectionFormSchema: l4DescriptorSchema() },
    );
    const geojsonPath = await createTempGeoJsonFile(
      'invalid-l4-descr',
      pointFeatureCollection({ name: 'Invalid L4 descriptor', L4_descr: 'Bananas' }),
    );

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: contributorLogin.token,
      expectedStatuses: ['failed'],
    });

    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining([
        'Invalid value for L4_descr: Bananas. Allowed values: Olives, Fruit Trees, Citrus Fruit Trees, Vineyards.',
      ]),
    );
  });

  test('accepts arbitrary required text values across supported import file types', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject('ReqText', {
      collectionFormSchema: schemaWithField({
        key: 'notes',
        label: 'Notes',
        type: 'text',
        required: true,
        options: ['Not a real constraint'],
      }),
    });
    const randomText = 'any random text that is not in options';
    const fixtures = [
      {
        expectedFileType: 'geojson',
        createFile: () =>
          createTempGeoJsonFile(
            'required-text-geojson',
            pointFeatureCollection({ name: 'Text GeoJSON', notes: randomText }),
          ),
      },
      {
        expectedFileType: 'shapefile_zip',
        createFile: () =>
          createTempShapefileZipFile(
            'required-text-shapefile',
            pointFeatureCollection({ name: 'Text Shapefile', notes: randomText }),
          ),
      },
      {
        expectedFileType: 'kml',
        createFile: () =>
          createTempTextFile(
            'required-text-kml',
            'kml',
            kmlPoint({ title: 'Text KML', fieldName: 'notes', value: randomText }),
          ),
      },
      {
        expectedFileType: 'kmz',
        createFile: () =>
          createTempZipFile(
            'required-text-kmz',
            {
              'doc.kml': kmlPoint({
                title: 'Text KMZ',
                fieldName: 'notes',
                value: randomText,
              }),
            },
            'kmz',
          ),
      },
      {
        expectedFileType: 'csv',
        createFile: () =>
          createTempTextFile(
            'required-text-csv',
            'csv',
            `name,notes,lat,lon\nText CSV,"${randomText}",33.902,35.502\n`,
          ),
      },
      {
        expectedFileType: 'xlsx',
        createFile: () =>
          createTempXlsxFile('required-text-xlsx', [
            ['name', 'notes', 'lat', 'lon'],
            ['Text XLSX', randomText, '33.903', '35.503'],
          ]),
      },
    ];

    for (const fixture of fixtures) {
      const detailResponse = await uploadAndWaitForImport({
        token: contributorLogin.token,
        reviewerToken: admin.token,
        projectId: project.id,
        filePath: await fixture.createFile(),
      });

      expect(detailResponse.body.data.job.file_type).toBe(fixture.expectedFileType);
      expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
      expect(detailResponse.body.data.job.failed_feature_count).toBe(0);
      expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual([]);
      expect(detailResponse.body.data.preview_features[0].attributes.notes).toBe(randomText);
    }
  });

  test('reports missing required text fields clearly', async () => {
    const { contributorLogin, project } = await createActiveImportProject('MissText', {
      collectionFormSchema: schemaWithField({
        key: 'notes',
        label: 'Notes',
        type: 'textarea',
        required: true,
      }),
    });
    const geojsonPath = await createTempGeoJsonFile(
      'missing-required-text',
      pointFeatureCollection({ name: 'Missing text notes' }),
    );

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: contributorLogin.token,
      projectId: project.id,
      filePath: geojsonPath,
      status: 'failed',
    });

    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required field: Notes']),
    );
  });

  test('validates boolean import values with readable failures', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject('BoolField', {
      collectionFormSchema: schemaWithField({
        key: 'is_active',
        label: 'Active',
        type: 'boolean',
        required: true,
      }),
    });
    const values = [
      ['Boolean true', true],
      ['Boolean false', false],
      ['Boolean yes', 'yes'],
      ['Boolean no', 'no'],
      ['Boolean one', '1'],
      ['Boolean zero', '0'],
      ['Boolean maybe', 'maybe'],
    ];
    const geojsonPath = await createTempGeoJsonFile('boolean-field-import', {
      type: 'FeatureCollection',
      features: values.map(([name, value], index) => ({
        type: 'Feature',
        properties: { name, is_active: value },
        geometry: {
          type: 'Point',
          coordinates: [35.501 + index * 0.001, 33.901],
        },
      })),
    });

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: geojsonPath,
    });

    expect(detailResponse.body.data.job.pending_feature_count).toBe(6);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    const failedFeature = detailResponse.body.data.preview_features.find(
      (feature) => feature.attributes.name === 'Boolean maybe',
    );
    expect(failedFeature.validation_errors).toEqual(
      expect.arrayContaining([
        'Invalid boolean for Active: maybe. Use true/false, yes/no, or 1/0.',
      ]),
    );
  });

  test('validates number fields and min/max only when configured', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject('NumField', {
      collectionFormSchema: schemaWithField({
        key: 'sample_count',
        label: 'Sample Count',
        type: 'number',
        required: true,
        min: 0,
        max: 100,
      }),
    });
    const geojsonPath = await createTempGeoJsonFile('number-field-import', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { name: 'Valid number string', sample_count: '42' },
          geometry: { type: 'Point', coordinates: [35.501, 33.901] },
        },
        {
          type: 'Feature',
          properties: { name: 'Invalid number text', sample_count: 'many' },
          geometry: { type: 'Point', coordinates: [35.502, 33.901] },
        },
        {
          type: 'Feature',
          properties: { name: 'Too high number', sample_count: '101' },
          geometry: { type: 'Point', coordinates: [35.503, 33.901] },
        },
      ],
    });

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: geojsonPath,
    });

    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(2);
    const invalidText = detailResponse.body.data.preview_features.find(
      (feature) => feature.attributes.name === 'Invalid number text',
    );
    const tooHigh = detailResponse.body.data.preview_features.find(
      (feature) => feature.attributes.name === 'Too high number',
    );
    expect(invalidText.validation_errors).toEqual(
      expect.arrayContaining(['Invalid number for Sample Count: many.']),
    );
    expect(tooHigh.validation_errors).toEqual(
      expect.arrayContaining(['Invalid value for Sample Count: 101. Maximum value is 100.']),
    );
  });

  test('validates date fields only for parseable dates', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject('DateField', {
      collectionFormSchema: schemaWithField({
        key: 'observed_at',
        label: 'Observation Date',
        type: 'date',
        required: true,
      }),
    });
    const geojsonPath = await createTempGeoJsonFile('date-field-import', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { name: 'Valid date', observed_at: '2026-05-31' },
          geometry: { type: 'Point', coordinates: [35.501, 33.901] },
        },
        {
          type: 'Feature',
          properties: { name: 'Invalid date', observed_at: 'not-a-date' },
          geometry: { type: 'Point', coordinates: [35.502, 33.901] },
        },
      ],
    });

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: geojsonPath,
    });

    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    const failedFeature = detailResponse.body.data.preview_features.find(
      (feature) => feature.attributes.name === 'Invalid date',
    );
    expect(failedFeature.validation_errors).toEqual(
      expect.arrayContaining(['Invalid date for Observation Date: not-a-date.']),
    );
  });

  test('handles unknown field types as open unless explicit options are present', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject('UnkOpen', {
      collectionFormSchema: schemaWithField({
        key: 'misc_note',
        label: 'Misc Note',
        type: 'legacy-open-field',
        required: true,
      }),
    });
    const openPath = await createTempGeoJsonFile(
      'unknown-open-field',
      pointFeatureCollection({ name: 'Unknown open', misc_note: 'free text value' }),
    );

    const openDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: openPath,
    });

    expect(openDetail.body.data.job.pending_feature_count).toBe(1);
    expect(openDetail.body.data.preview_features[0].validation_errors).toEqual([]);

    const constrained = await createActiveImportProject('UnkOpt', {
      collectionFormSchema: schemaWithField({
        key: 'legacy_code',
        label: 'Legacy Code',
        type: 'legacy-code',
        required: true,
        options: ['A', 'B'],
      }),
    });
    const constrainedPath = await createTempGeoJsonFile(
      'unknown-option-field',
      pointFeatureCollection({ name: 'Unknown option', legacy_code: 'C' }),
    );

    const constrainedDetail = await uploadAndWaitForImport({
      token: constrained.contributorLogin.token,
      reviewerToken: constrained.admin.token,
      projectId: constrained.project.id,
      filePath: constrainedPath,
      status: 'failed',
    });

    expect(constrainedDetail.body.data.job.failed_feature_count).toBe(1);
    expect(constrainedDetail.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Invalid value for Legacy Code: C. Allowed values: A, B.']),
    );
  });

  test('marks CSV imports without geometry columns as failed clearly', async () => {
    const { contributorLogin, project } = await createActiveImportProject('CSV Missing Geometry');
    const csvPath = await createTempTextFile(
      'csv-missing-geometry',
      'csv',
      'name,feature_type\nNo geometry,olive\n',
    );

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', csvPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: contributorLogin.token,
      expectedStatuses: ['failed'],
    });

    expect(detailResponse.body.data.job.processing_message).toContain(
      'No supported geometry columns found',
    );
  });

  test('keeps invalid CSV coordinates as failed staged rows', async () => {
    const { admin, contributorLogin, project } =
      await createActiveImportProject('CSV Invalid Coordinates');
    const csvPath = await createTempTextFile(
      'csv-invalid-coordinates',
      'csv',
      'name,feature_type,lat,lon\nBad point,olive,200,35.5001\n',
    );

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', csvPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['failed'],
    });

    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Geometry is missing or unsupported.']),
    );
  });

  test('preserves GeoJSON photo reference attributes through approval', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject(
      'GeoJSON Photo References',
    );
    const geojsonPath = await createTempGeoJsonFile('geojson-photo-references', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: {
            feature_type: 'olive',
            name: 'Photo referenced feature',
            photo_url: 'https://example.com/photos/olive.jpg',
            image: '=not-a-formula.jpg',
          },
          geometry: { type: 'Point', coordinates: [35.5005, 33.9005] },
        },
      ],
    });

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: geojsonPath,
    });

    const stagedFeature = detailResponse.body.data.preview_features[0];
    expect(stagedFeature.attributes.photo_url).toBe('https://example.com/photos/olive.jpg');
    expect(stagedFeature.attributes.image).toBe("'=not-a-formula.jpg");

    await request(app)
      .post(`${API_PREFIX}/imports/${detailResponse.body.data.job.id}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved', feature_ids: [stagedFeature.id] })
      .expect(200);

    const official = await pool.query(
      `SELECT attributes, source
       FROM spatial_feature
       WHERE project_id = $1
       LIMIT 1`,
      [project.id],
    );
    expect(official.rows[0].attributes.photo_url).toBe('https://example.com/photos/olive.jpg');
    expect(official.rows[0].attributes.image).toBe("'=not-a-formula.jpg");
    expect(official.rows[0].source).toBe('import');
  });

  test('preserves Shapefile DBF photo reference attributes', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject(
      'Shapefile Photo References',
    );
    const shapefilePath = await createTempShapefileZipFile('shapefile-photo-references', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: {
            feature_type: 'olive',
            name: 'Shapefile photo',
            photo_url: 'https://example.com/shp.jpg',
          },
          geometry: { type: 'Point', coordinates: [35.501, 33.901] },
        },
      ],
    });

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: shapefilePath,
    });

    expect(detailResponse.body.data.preview_features[0].attributes.photo_url).toBe(
      'https://example.com/shp.jpg',
    );
  });

  test('preserves KML and KMZ extended photo reference attributes', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject(
      'KML KMZ Photo References',
    );
    const kml = `<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>KML photo</name>
      <ExtendedData>
        <Data name="feature_type"><value>olive</value></Data>
        <Data name="photo_url"><value>https://example.com/kml.jpg</value></Data>
      </ExtendedData>
      <Point><coordinates>35.502,33.902,0</coordinates></Point>
    </Placemark>
  </Document>
</kml>`;
    const kmlPath = await createTempTextFile('kml-photo-references', 'kml', kml);
    const kmzPath = await createTempZipFile('kmz-photo-references', { 'doc.kml': kml }, 'kmz');

    const kmlDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: kmlPath,
    });
    const kmzDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: kmzPath,
    });

    expect(kmlDetail.body.data.preview_features[0].attributes.photo_url).toBe(
      'https://example.com/kml.jpg',
    );
    expect(kmzDetail.body.data.preview_features[0].attributes.photo_url).toBe(
      'https://example.com/kml.jpg',
    );
  });

  test('handles malformed and unsupported GeoJSON content without backend errors', async () => {
    const { contributorLogin, project } =
      await createActiveImportProject('GeoJSON Robust Failures');
    const malformedPath = await createTempTextFile('geojson-malformed', 'geojson', '{"type":');
    const malformedDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: contributorLogin.token,
      projectId: project.id,
      filePath: malformedPath,
      status: 'failed',
    });
    expect(malformedDetail.body.data.job.processing_message).toContain(
      'The GeoJSON file could not be parsed.',
    );

    const nonGeoJsonPath = await createTempGeoJsonFile('geojson-non-feature', {
      report: 'not a GIS feature collection',
    });
    const nonGeoJsonDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: contributorLogin.token,
      projectId: project.id,
      filePath: nonGeoJsonPath,
      status: 'failed',
    });
    expect(nonGeoJsonDetail.body.data.job.processing_message).toContain(
      'GeoJSON must be a Feature or FeatureCollection.',
    );
  });

  test('stages unsupported GeoJSON geometries as failed feature rows', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject(
      'GeoJSON Geometry Failures',
    );
    const geojsonPath = await createTempGeoJsonFile('geojson-geometry-failures', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: {
            feature_type: 'olive',
            name: 'Lowercase point',
            photo_url: 'https://example.com/lower.jpg',
          },
          geometry: { type: 'point', coordinates: [35.5, 33.9] },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Null geometry' },
          geometry: null,
        },
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Geometry collection' },
          geometry: {
            type: 'GeometryCollection',
            geometries: [{ type: 'Point', coordinates: [35.5, 33.9] }],
          },
        },
      ],
    });

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: geojsonPath,
      status: 'failed',
    });

    expect(detailResponse.body.data.job.failed_feature_count).toBe(3);
    expect(detailResponse.body.data.preview_features).toHaveLength(3);
    expect(detailResponse.body.data.preview_features[0].attributes.photo_url).toBe(
      'https://example.com/lower.jpg',
    );
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Geometry is missing or unsupported.']),
    );
  });

  test('reports ring self-intersections without approving invalid polygons', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject('SelfX Polygon', {
      collectionFormSchema: l4DescriptorSchema(),
    });
    const geojsonPath = await createTempGeoJsonFile('geojson-ring-self-intersection', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          id: 'source-parcel-123',
          properties: {
            name: 'Self-intersecting polygon',
            OBJECTID_1: '123',
            L4_descr: 'Olives',
          },
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [35.5, 33.9],
                [35.6, 34.0],
                [35.6, 33.9],
                [35.5, 34.0],
                [35.5, 33.9],
              ],
            ],
          },
        },
      ],
    });

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: geojsonPath,
      status: 'failed',
    });

    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(detailResponse.body.data.job.pending_feature_count).toBe(0);
    expect(detailResponse.body.data.preview_features[0]).toEqual(
      expect.objectContaining({
        source_identifier: 'source-parcel-123',
        source_feature_name: 'Self-intersecting polygon',
      }),
    );
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining([
        'Invalid polygon geometry: ring self-intersection. Fix the geometry in GIS software or exclude this feature.',
      ]),
    );

    const approvedFeatures = await pool.query(
      `SELECT id
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(approvedFeatures.rows).toHaveLength(0);
  });

  test('handles Shapefile ZIP edge cases without backend errors', async () => {
    const { admin, contributorLogin, project } = await createActiveImportProject(
      'Shapefile Robust Failures',
    );
    const baseGeoJson = {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: {
            feature_type: 'olive',
            name: 'No projection file',
            photo_url: 'https://example.com/no-prj.jpg',
          },
          geometry: { type: 'Point', coordinates: [35.501, 33.901] },
        },
      ],
    };

    const noPrjPath = await createTempShapefileZipWithout('shapefile-no-prj', baseGeoJson, [
      '.prj',
    ]);
    const noPrjDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: noPrjPath,
    });
    expect(noPrjDetail.body.data.job.file_metadata.has_prj).toBe(false);
    expect(noPrjDetail.body.data.preview_features[0].attributes.photo_url).toBe(
      'https://example.com/no-prj.jpg',
    );

    const missingDbfPath = await createTempShapefileZipWithout(
      'shapefile-missing-dbf',
      baseGeoJson,
      ['.dbf'],
    );
    const missingDbfDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: missingDbfPath,
      status: 'failed',
    });
    expect(missingDbfDetail.body.data.job.processing_message).toContain(
      'A zipped shapefile must include .shp, .shx, and .dbf files.',
    );

    const unsafeZipPath = await createTempZipFile('shapefile-unsafe-names', {
      '../escape.shp': 'not a shapefile',
      'notes/readme.txt': 'hello',
    });
    const unsafeZipDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: unsafeZipPath,
      status: 'failed',
    });
    expect(unsafeZipDetail.body.data.job.processing_message).toContain(
      'A zipped shapefile must include .shp, .shx, and .dbf files.',
    );

    const corruptedZipPath = await createTempBinaryFile(
      'shapefile-corrupt',
      'zip',
      'not really a zip',
    );
    const corruptedZipResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', corruptedZipPath)
      .expect(422);
    expect(corruptedZipResponse.body.error.code).toBe('UPLOAD_SIGNATURE_REJECTED');
    const quarantinedCorruptZip = await pool.query(
      `SELECT disposition, scan_status, reason_code
       FROM upload_quarantine_record
       WHERE project_id = $1
         AND original_filename = $2`,
      [project.id, path.basename(corruptedZipPath)],
    );
    expect(quarantinedCorruptZip.rows).toEqual([
      {
        disposition: 'quarantined',
        scan_status: 'pending',
        reason_code: 'UPLOAD_SIGNATURE_REJECTED',
      },
    ]);
  });

  test('handles KML lines, polygons, malformed XML, and missing geometry safely', async () => {
    const { admin, contributorLogin, project } =
      await createActiveImportProject('KML Robust Import');
    const kml = `<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>KML line</name>
      <ExtendedData><Data name="feature_type"><value>olive</value></Data></ExtendedData>
      <LineString><coordinates>35.50,33.90,0 35.51,33.91,0</coordinates></LineString>
    </Placemark>
    <Placemark>
      <name>KML polygon</name>
      <ExtendedData>
        <Data name="feature_type"><value>cedar</value></Data>
        <Data name="media_url"><value>https://example.com/kml-polygon.jpg</value></Data>
      </ExtendedData>
      <Polygon><outerBoundaryIs><LinearRing><coordinates>35.50,33.90,0 35.51,33.90,0 35.51,33.91,0 35.50,33.90,0</coordinates></LinearRing></outerBoundaryIs></Polygon>
    </Placemark>
    <Placemark>
      <name>KML missing geometry</name>
      <ExtendedData><Data name="feature_type"><value>olive</value></Data></ExtendedData>
    </Placemark>
  </Document>
</kml>`;
    const kmlPath = await createTempTextFile('kml-lines-polygons', 'kml', kml);
    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: kmlPath,
    });
    expect(detailResponse.body.data.job.pending_feature_count).toBe(2);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(
      detailResponse.body.data.preview_features.find(
        (feature) => feature.display_title === 'KML polygon',
      ).attributes.media_url,
    ).toBe('https://example.com/kml-polygon.jpg');

    const malformedPath = await createTempTextFile('kml-malformed', 'kml', '<kml><Placemark>');
    const malformedDetail = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: malformedPath,
      status: 'failed',
    });
    expect(malformedDetail.body.data.job.processing_message).toContain(
      'The KML file could not be parsed.',
    );
  });

  test('handles KMZ nested KML, embedded files, missing KML, and corrupted archives safely', async () => {
    const { admin, contributorLogin, project } =
      await createActiveImportProject('KMZ Robust Import');
    const nestedKml = `<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Nested KMZ KML</name>
      <ExtendedData>
        <Data name="feature_type"><value>olive</value></Data>
        <Data name="picture"><value>images/photo.jpg</value></Data>
      </ExtendedData>
      <Point><coordinates>35.503,33.903,0</coordinates></Point>
    </Placemark>
  </Document>
</kml>`;
    const kmzPath = await createTempZipFile(
      'kmz-nested-kml',
      {
        'nested/doc.kml': nestedKml,
        'images/photo.jpg': Buffer.from('fake image content'),
      },
      'kmz',
    );
    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: kmzPath,
    });
    expect(detailResponse.body.data.job.file_metadata.source_entry).toBe('nested/doc.kml');
    expect(detailResponse.body.data.preview_features[0].attributes.picture).toBe(
      'images/photo.jpg',
    );

    const missingKmlPath = await createTempZipFile(
      'kmz-missing-kml',
      {
        'images/photo.jpg': Buffer.from('fake image content'),
      },
      'kmz',
    );
    const missingKmlResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', missingKmlPath)
      .expect(422);
    expect(missingKmlResponse.body.error.code).toBe('UPLOAD_ARCHIVE_REJECTED');

    const corruptedKmzPath = await createTempBinaryFile('kmz-corrupt', 'kmz', 'not really a kmz');
    const corruptedKmzResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', corruptedKmzPath)
      .expect(422);
    expect(corruptedKmzResponse.body.error.code).toBe('UPLOAD_SIGNATURE_REJECTED');
  });

  test('handles real-world CSV headers, delimiters, blanks, and photo references', async () => {
    const { admin, contributorLogin, project } =
      await createActiveImportProject('CSV Robust Import');
    const csvPath = await createTempTextFile(
      'csv-robust-import',
      'csv',
      ' Name ; Feature Type ; Latitude ; Long ; photo_url ; photo_url \n' +
        ' Robust CSV ; olive ; " 33.9006 " ; " 35.5006 " ; https://example.com/csv.jpg ; duplicate-kept.jpg\n' +
        '\n' +
        ' Bad CSV ; olive ; 200 ; 35.5007 ; https://example.com/bad.jpg ; \n',
    );

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: csvPath,
      status: 'pending_review',
    });

    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    const feature = detailResponse.body.data.preview_features.find(
      (item) => item.display_title === 'Robust CSV',
    );
    expect(feature.attributes.photo_url).toBe('https://example.com/csv.jpg');
    expect(feature.attributes.photo_url_2).toBe('duplicate-kept.jpg');
  });

  test('handles XLSX photo references, blank rows, and valid sheet auto-detection', async () => {
    const { admin, contributorLogin, project } =
      await createActiveImportProject('XLSX Robust Import');
    const xlsxPath = await createTempXlsxFile('xlsx-robust-import', [
      {
        name: 'Accounting',
        rows: [
          ['Invoice', 'Amount'],
          ['A-1', '120'],
        ],
      },
      {
        name: 'GIS',
        rows: [
          ['Name', 'Feature Type', 'Y', 'X', 'picture_url'],
          [],
          ['Robust Excel', 'cedar', '33.9007', '35.5007', 'https://example.com/xlsx.jpg'],
        ],
      },
    ]);

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: admin.token,
      projectId: project.id,
      filePath: xlsxPath,
    });

    expect(detailResponse.body.data.job.file_metadata.sheet_name).toBe('GIS');
    expect(detailResponse.body.data.preview_features[0].attributes.picture_url).toBe(
      'https://example.com/xlsx.jpg',
    );
  });

  test('fails non-GIS XLSX files gracefully without crashing', async () => {
    const { contributorLogin, project } = await createActiveImportProject('XLSX No Geometry');
    const xlsxPath = await createTempXlsxFile('xlsx-no-geometry', [
      ['Invoice', 'Amount'],
      ['A-1', '120'],
    ]);

    const detailResponse = await uploadAndWaitForImport({
      token: contributorLogin.token,
      reviewerToken: contributorLogin.token,
      projectId: project.id,
      filePath: xlsxPath,
      status: 'failed',
    });

    expect(detailResponse.body.data.job.processing_message).toContain(
      'No supported geometry columns found',
    );
  });

  test('stages uploaded GeoJSON and supports selected approve/reject review', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Admin',
      emailPrefix: 'import-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Contributor',
      emailPrefix: 'import-contributor',
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
      name: 'Import Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-selected-review', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Olive parcel' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
          },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'cedar', name: 'Cedar grove' },
          geometry: {
            type: 'Point',
            coordinates: [35.5015, 33.9015],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const importId = uploadResponse.body.data.id;
    const detailsResponse = await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailsResponse.status).toBe(200);
    expect(detailsResponse.body.data.job.pending_feature_count).toBe(2);
    expect(detailsResponse.body.data.preview_features).toHaveLength(2);
    const featureIds = detailsResponse.body.data.preview_features.map((item) => item.id);

    await request(app)
      .get(`${API_PREFIX}/imports/${importId}/download`)
      .set(authHeader(contributorLogin.token))
      .expect(403);

    const approveResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        feature_ids: [featureIds[0]],
      });

    expect(approveResponse.status).toBe(200);
    expect(approveResponse.body.data.status).toBe('pending_review');
    expect(approveResponse.body.data.approved_feature_count).toBe(1);
    expect(approveResponse.body.data.pending_feature_count).toBe(1);

    const interimNotificationCheck = await pool.query(
      `SELECT type, title, message
       FROM notification
       WHERE user_id = $1
         AND type = 'import_event'
       ORDER BY created_at DESC`,
      [contributorRegistration.user.id],
    );
    expect(interimNotificationCheck.rows).toHaveLength(0);

    const rejectResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'rejected',
        feature_ids: [featureIds[1]],
        reason: 'Duplicate field survey already exists.',
      });

    expect(rejectResponse.status).toBe(200);
    expect(rejectResponse.body.data.status).toBe('partially_approved');
    expect(rejectResponse.body.data.approved_feature_count).toBe(1);
    expect(rejectResponse.body.data.rejected_feature_count).toBe(1);

    const officialFeatures = await pool.query(
      `SELECT id, status
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(officialFeatures.rows).toHaveLength(1);
    expect(officialFeatures.rows[0].status).toBe('approved');

    const notificationCheck = await pool.query(
      `SELECT type, title, message
       FROM notification
       WHERE user_id = $1
         AND type = 'import_event'
       ORDER BY created_at DESC`,
      [contributorRegistration.user.id],
    );
    expect(notificationCheck.rows).toHaveLength(1);
    expect(notificationCheck.rows[0].title).toContain('Import partially approved');
    expect(notificationCheck.rows[0].message).toContain('Duplicate field survey already exists.');
  });

  test('approves supported single and multi geometries without geom constraint failures', async () => {
    const { admin, contributorRegistration, project } = await createActiveImportProject(
      'Import Multi Geometry Approval',
    );
    const importId = await createStagedImportJob({
      projectId: project.id,
      uploadedByUserId: contributorRegistration.user.id,
      features: [
        {
          displayTitle: 'Point feature',
          geometryType: 'Point',
          geometry: { type: 'Point', coordinates: [35.501, 33.901] },
        },
        {
          displayTitle: 'MultiPoint feature',
          geometryType: 'MultiPoint',
          geometry: {
            type: 'MultiPoint',
            coordinates: [
              [35.502, 33.902],
              [35.503, 33.903],
            ],
          },
        },
        {
          displayTitle: 'Line feature',
          geometryType: 'LineString',
          geometry: {
            type: 'LineString',
            coordinates: [
              [35.504, 33.904],
              [35.505, 33.905],
            ],
          },
        },
        {
          displayTitle: 'MultiLine feature',
          geometryType: 'MultiLineString',
          geometry: {
            type: 'MultiLineString',
            coordinates: [
              [
                [35.506, 33.906],
                [35.507, 33.907],
              ],
            ],
          },
        },
        {
          displayTitle: 'Polygon feature',
          geometryType: 'Polygon',
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [35.508, 33.908],
                [35.511, 33.908],
                [35.511, 33.911],
                [35.508, 33.911],
                [35.508, 33.908],
              ],
            ],
          },
        },
        {
          displayTitle: 'MultiPolygon feature',
          geometryType: 'MultiPolygon',
          geometry: {
            type: 'MultiPolygon',
            coordinates: [
              [
                [
                  [35.512, 33.912],
                  [35.515, 33.912],
                  [35.515, 33.915],
                  [35.512, 33.915],
                  [35.512, 33.912],
                ],
              ],
            ],
          },
        },
      ].map((feature) => ({
        ...feature,
        attributes: { name: feature.displayTitle },
      })),
    });

    const approveResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved' })
      .expect(200);

    expect(approveResponse.body.data.status).toBe('approved');
    expect(approveResponse.body.data.approved_feature_count).toBe(6);
    const storedTypes = await pool.query(
      `SELECT GeometryType(geom) AS geometry_type
       FROM spatial_feature
       WHERE project_id = $1
       ORDER BY geometry_type ASC`,
      [project.id],
    );
    expect(storedTypes.rows.map((row) => row.geometry_type).sort()).toEqual([
      'LINESTRING',
      'MULTILINESTRING',
      'MULTIPOINT',
      'MULTIPOLYGON',
      'POINT',
      'POLYGON',
    ]);
  });

  test('keeps invalid approval targets failed while approving valid features', async () => {
    const { admin, contributorRegistration, project } =
      await createActiveImportProject('Import Partial Approval');
    const importId = await createStagedImportJob({
      projectId: project.id,
      uploadedByUserId: contributorRegistration.user.id,
      features: [
        {
          displayTitle: 'Valid parcel',
          geometryType: 'Polygon',
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [35.52, 33.92],
                [35.523, 33.92],
                [35.523, 33.923],
                [35.52, 33.923],
                [35.52, 33.92],
              ],
            ],
          },
          attributes: { name: 'Valid parcel' },
        },
        {
          displayTitle: 'Unsupported geometry collection',
          geometryType: null,
          geometry: {
            type: 'GeometryCollection',
            geometries: [{ type: 'Point', coordinates: [35.525, 33.925] }],
          },
          attributes: { name: 'Unsupported geometry collection' },
        },
      ],
    });

    const approveResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved' })
      .expect(200);

    expect(approveResponse.body.data.status).toBe('partially_approved');
    expect(approveResponse.body.data.approved_feature_count).toBe(1);
    expect(approveResponse.body.data.failed_feature_count).toBe(1);
    const staged = await request(app)
      .get(`${API_PREFIX}/imports/${importId}/features?status=failed`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(staged.body.data[0].validation_errors).toEqual(
      expect.arrayContaining(['Unsupported geometry type: GEOMETRYCOLLECTION.']),
    );
    expect(JSON.stringify(staged.body.data[0].validation_errors)).not.toContain(
      'chk_spatial_feature_geom_type',
    );
  });

  test('approves all filtered reviewable features for large imports server-side', async () => {
    const { admin, contributorRegistration, project } = await createActiveImportProject(
      'Import Large Approve Filtered',
    );
    const features = Array.from({ length: 1401 }, (_, index) => ({
      displayTitle: `Bulk approve ${index + 1}`,
      geometryType: 'Point',
      geometry: {
        type: 'Point',
        coordinates: [35.2 + (index % 40) * 0.001, 33.2 + Math.floor(index / 40) * 0.001],
      },
      attributes: { name: `Bulk approve ${index + 1}` },
      validationWarnings: index < 1400 ? ['bulk approve filter'] : [],
    }));
    const importId = await createStagedImportJob({
      projectId: project.id,
      uploadedByUserId: contributorRegistration.user.id,
      features,
    });

    const quickMapResponse = await request(app)
      .get(`${API_PREFIX}/imports/${importId}/quick-map`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(quickMapResponse.body.data.total_feature_count).toBe(1401);
    expect(quickMapResponse.body.data.geometry_feature_count).toBe(1401);
    expect(quickMapResponse.body.data.rendered_feature_count).toBeLessThan(1401);
    expect(quickMapResponse.body.data.features).toHaveLength(
      quickMapResponse.body.data.rendered_feature_count,
    );
    expect(quickMapResponse.body.data.features[0].geometry.type).toBe('Point');
    expect(quickMapResponse.body.data.features[0].attributes).toEqual({});
    expect(
      quickMapResponse.body.data.features.reduce(
        (total, feature) => total + feature.cluster_count,
        0,
      ),
    ).toBe(1401);

    const approveResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        filters: { issue: 'bulk approve filter' },
      })
      .expect(200);

    expect(approveResponse.body.data.status).toBe('pending_review');
    expect(approveResponse.body.data.approved_feature_count).toBe(1400);
    expect(approveResponse.body.data.pending_feature_count).toBe(1);
    const approvedCount = await pool.query(
      `SELECT COUNT(*)::int AS total
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(approvedCount.rows[0].total).toBe(1400);
  });

  test('rejects all filtered reviewable features for large imports server-side', async () => {
    const { admin, contributorRegistration, project } = await createActiveImportProject(
      'Import Large Reject Filtered',
    );
    const features = Array.from({ length: 1401 }, (_, index) => ({
      displayTitle: `Bulk reject ${index + 1}`,
      geometryType: 'Point',
      geometry: {
        type: 'Point',
        coordinates: [35.3 + (index % 40) * 0.001, 33.3 + Math.floor(index / 40) * 0.001],
      },
      attributes: { name: `Bulk reject ${index + 1}` },
      validationWarnings: index < 1400 ? ['bulk reject filter'] : [],
    }));
    const importId = await createStagedImportJob({
      projectId: project.id,
      uploadedByUserId: contributorRegistration.user.id,
      features,
    });

    const rejectResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'rejected',
        reason: 'Not part of this review pass.',
        filters: { issue: 'bulk reject filter' },
      })
      .expect(200);

    expect(rejectResponse.body.data.status).toBe('pending_review');
    expect(rejectResponse.body.data.rejected_feature_count).toBe(1400);
    expect(rejectResponse.body.data.pending_feature_count).toBe(1);
  });

  test('duplicate warnings apply only to matching staged features', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Duplicate Admin',
      emailPrefix: 'import-duplicate-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Duplicate Contributor',
      emailPrefix: 'import-duplicate-contributor',
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
      name: 'Import Duplicate Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Duplicate Project',
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

    await pool.query(
      `INSERT INTO spatial_feature (
         project_id,
         collected_by_user_id,
         geom,
         attributes,
         status,
         submitted_at,
         reviewed_by_user_id,
         reviewed_at,
         collected_offline
       ) VALUES (
         $1,
         $2,
         ST_SetSRID(ST_GeomFromGeoJSON($3), 4326),
         $4::jsonb,
         'approved',
         CURRENT_TIMESTAMP,
         $2,
         CURRENT_TIMESTAMP,
         FALSE
       )`,
      [
        project.id,
        admin.user.id,
        JSON.stringify({
          type: 'Point',
          coordinates: [35.5001, 33.9001],
        }),
        JSON.stringify({ feature_type: 'olive' }),
      ],
    );

    const geojsonPath = await createTempGeoJsonFile('import-duplicate-warnings', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
          },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'cedar' },
          geometry: {
            type: 'Point',
            coordinates: [35.5201, 33.9201],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const detailsResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailsResponse.body.data.job.warning_count).toBe(1);
    expect(detailsResponse.body.data.job.validation_summary.top_warnings).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          message: 'Geometry matches an approved feature already present in this project.',
          count: 1,
        }),
      ]),
    );

    const warningCheck = await pool.query(
      `SELECT source_index, validation_warnings
       FROM gis_import_feature
       WHERE import_job_id = $1
       ORDER BY source_index ASC`,
      [uploadResponse.body.data.id],
    );

    expect(warningCheck.rows).toHaveLength(2);
    expect(warningCheck.rows[0].validation_warnings).toEqual(
      expect.arrayContaining([
        'Geometry matches an approved feature already present in this project.',
      ]),
    );
    expect(warningCheck.rows[1].validation_warnings).not.toEqual(
      expect.arrayContaining([
        'Geometry matches an approved feature already present in this project.',
      ]),
    );
  });

  test('import map data stays separated from official project features', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Map Admin',
      emailPrefix: 'import-map-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Map Contributor',
      emailPrefix: 'import-map-contributor',
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
      name: 'Import Map Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Map Project',
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

    const contextFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: {
          type: 'Point',
          coordinates: [35.51, 33.91],
        },
        attributes: {
          feature_type: 'pine',
          name: 'Existing project context feature',
        },
      })
      .expect(201);
    const contextFeatureId = contextFeatureResponse.body.data.id;
    await request(app)
      .post(`${API_PREFIX}/features/${contextFeatureId}/submit`)
      .set(authHeader(contributorLogin.token))
      .send()
      .expect(200);
    await request(app)
      .post(`${API_PREFIX}/features/${contextFeatureId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        review_notes: 'Approved project context for import map testing.',
      })
      .expect(200);

    const geojsonPath = await createTempGeoJsonFile('import-map-separation', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Pending import feature' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
          },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'cedar', name: 'Approved import feature' },
          geometry: {
            type: 'Point',
            coordinates: [35.5015, 33.9015],
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
    const detailsResponse = await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });
    const featureIds = detailsResponse.body.data.preview_features.map((item) => item.id);

    await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        feature_ids: [featureIds[1]],
      })
      .expect(200);

    const importMapResponse = await request(app)
      .get(
        `${API_PREFIX}/imports/${importId}/map?minLon=35.094&minLat=33.045&maxLon=36.645&maxLat=34.695&zoom=8`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(importMapResponse.body.data.staged_features).toHaveLength(2);
    expect(importMapResponse.body.data.staged_features.map((item) => item.status)).toEqual(
      expect.arrayContaining(['pending_review', 'approved']),
    );
    expect(importMapResponse.body.data.approved_project_features).toHaveLength(1);
    expect(importMapResponse.body.data.approved_project_features[0]).toEqual(
      expect.objectContaining({
        id: contextFeatureId,
        project_id: project.id,
      }),
    );

    const projectMapResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/features?limit=100`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(projectMapResponse.body.data).toHaveLength(2);
    expect(projectMapResponse.body.data.every((item) => item.status === 'approved')).toBe(true);
    expect(projectMapResponse.body.data.every((item) => item.project_id === project.id)).toBe(true);

    const importContextProjectFeaturesResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/features?limit=100&exclude_import_id=${importId}`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(importContextProjectFeaturesResponse.body.data).toHaveLength(1);
    expect(importContextProjectFeaturesResponse.body.data[0].id).toBe(contextFeatureId);
    expect(importContextProjectFeaturesResponse.body.pagination.total).toBe(1);
  });

  test('approved staged features can be rejected later and are removed from official project features', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Reversal Admin',
      emailPrefix: 'import-reversal-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Reversal Contributor',
      emailPrefix: 'import-reversal-contributor',
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
      name: 'Import Reversal Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Reversal Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-approved-rejected', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Reversible feature' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
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
    const detailsResponse = await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });
    const featureId = detailsResponse.body.data.preview_features[0].id;

    await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved', feature_ids: [featureId] })
      .expect(200);

    const approvedFeatures = await pool.query(
      `SELECT id
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(approvedFeatures.rows).toHaveLength(1);

    const rejectResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'rejected',
        feature_ids: [featureId],
        reason: 'Boundary correction required.',
      })
      .expect(200);

    expect(rejectResponse.body.data.status).toBe('rejected');

    const finalOfficialFeatures = await pool.query(
      `SELECT id
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(finalOfficialFeatures.rows).toHaveLength(0);

    const stagedFeature = await pool.query(
      `SELECT status, approved_feature_id, review_reason
       FROM gis_import_feature
       WHERE id = $1`,
      [featureId],
    );
    expect(stagedFeature.rows[0].status).toBe('rejected');
    expect(stagedFeature.rows[0].approved_feature_id).toBeNull();
    expect(stagedFeature.rows[0].review_reason).toBe('Boundary correction required.');
  });

  test('marks import as failed when staged features cannot pass required validation', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Failure Admin',
      emailPrefix: 'import-failure-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Failure Contributor',
      emailPrefix: 'import-failure-contributor',
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
      name: 'Import Failure Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Failure Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-failed-validation', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { name: 'Unnamed geometry without feature type' },
          geometry: {
            type: 'Point',
            coordinates: [35.505, 33.905],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: contributorLogin.token,
      expectedStatuses: ['failed'],
    });
    expect(detailResponse.status).toBe(200);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(detailResponse.body.data.job.pending_feature_count).toBe(0);
    expect(detailResponse.body.data.job.validation_summary.top_errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          message: 'Missing required field: Feature type',
          count: 1,
        }),
      ]),
    );
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required field: Feature type']),
    );

    const issueFilteredResponse = await request(app)
      .get(
        `${API_PREFIX}/imports/${uploadResponse.body.data.id}/features?page=1&limit=20&issue=${encodeURIComponent(
          'Missing required field: Feature type',
        )}`,
      )
      .set(authHeader(contributorLogin.token))
      .expect(200);

    expect(issueFilteredResponse.body.pagination.total).toBe(1);
    expect(issueFilteredResponse.body.data).toHaveLength(1);
    expect(issueFilteredResponse.body.data[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required field: Feature type']),
    );
  });

  test('contributors can only list and open their own import jobs', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Visibility Admin',
      emailPrefix: 'import-visibility-admin',
    });
    const contributorA = await registerUser({
      role: 'contributor',
      fullName: 'Import Owner Contributor',
      emailPrefix: 'import-owner-contributor',
    });
    const contributorB = await registerUser({
      role: 'contributor',
      fullName: 'Second Contributor',
      emailPrefix: 'import-second-contributor',
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorA.user.id,
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorB.user.id,
    });
    const contributorALogin = await loginUser({
      email: contributorA.email,
      password: contributorA.password,
    });
    const contributorBLogin = await loginUser({
      email: contributorB.email,
      password: contributorB.password,
    });

    const category = await createCategory({
      token: admin.token,
      name: 'Import Visibility Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Visibility Project',
      visibleToContributors: true,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);

    for (const userId of [contributorA.user.id, contributorB.user.id]) {
      const assignment = await createAssignment({
        token: admin.token,
        projectId: project.id,
        userId,
      });
      await updateAssignmentStatus({
        token: admin.token,
        assignmentId: assignment.id,
        status: 'approved',
      });
    }

    const geojsonPath = await createTempGeoJsonFile('import-own-history', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Owner import' },
          geometry: {
            type: 'Point',
            coordinates: [35.501, 33.901],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorALogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const importId = uploadResponse.body.data.id;
    await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    const listForContributorB = await request(app)
      .get(`${API_PREFIX}/imports?page=1&limit=20`)
      .set(authHeader(contributorBLogin.token))
      .expect(200);
    expect(listForContributorB.body.data).toEqual([]);
    expect(listForContributorB.body.pagination.total).toBe(0);

    await request(app)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(contributorBLogin.token))
      .expect(403);
  });

  test('admin-submitted imports require protected super admin review and support download/comments', async () => {
    const previousProtectedEmail = process.env.SUPER_ADMIN_EMAIL;
    const protectedAdmin = await createAdminUser({
      fullName: 'Protected Import Admin',
      emailPrefix: 'protected-import-admin',
    });
    process.env.SUPER_ADMIN_EMAIL = protectedAdmin.email;

    try {
      const standardAdmin = await createAdminUser({
        fullName: 'Standard Import Admin',
        emailPrefix: 'standard-import-admin',
      });

      const category = await createCategory({
        token: protectedAdmin.token,
        name: 'Admin Import Category',
      });
      const project = await createProject({
        token: protectedAdmin.token,
        categoryId: category.id,
        name: 'Admin Import Project',
        visibleToContributors: true,
      });
      await request(app)
        .put(`${API_PREFIX}/projects/${project.id}`)
        .set(authHeader(protectedAdmin.token))
        .send({ status: 'active' })
        .expect(200);

      const geojsonPath = await createTempGeoJsonFile('admin-import-review-scope', {
        type: 'FeatureCollection',
        features: [
          {
            type: 'Feature',
            properties: { feature_type: 'olive', name: 'Admin import feature' },
            geometry: {
              type: 'Point',
              coordinates: [35.5004, 33.9004],
            },
          },
        ],
      });

      await request(app)
        .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
        .set(authHeader(protectedAdmin.token))
        .attach('file', geojsonPath)
        .expect(403);

      const uploadResponse = await request(app)
        .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
        .set(authHeader(standardAdmin.token))
        .attach('file', geojsonPath)
        .expect(202);

      const importId = uploadResponse.body.data.id;
      const detailResponse = await waitForImportStatus({
        importId,
        token: protectedAdmin.token,
        expectedStatuses: ['pending_review'],
      });
      expect(detailResponse.body.data.job.review_scope).toBe('protected_super_admin');

      await request(app)
        .post(`${API_PREFIX}/imports/${importId}/review`)
        .set(authHeader(standardAdmin.token))
        .send({ status: 'approved' })
        .expect(403);

      await request(app)
        .get(`${API_PREFIX}/imports/${importId}/download`)
        .set(authHeader(standardAdmin.token))
        .expect(403);

      await request(app)
        .post(`${API_PREFIX}/imports/${importId}/comments`)
        .set(authHeader(protectedAdmin.token))
        .send({ comment: 'Please verify the imported admin dataset naming.' })
        .expect(201);

      const commentAuditCheck = await pool.query(
        `SELECT action_type, entity_type, entity_id
         FROM audit_log
         WHERE action_type = 'comment'
           AND entity_type = 'gis_import_job'
           AND entity_id = $1`,
        [importId],
      );
      expect(commentAuditCheck.rows).toHaveLength(1);

      const commentNotificationCheck = await pool.query(
        `SELECT type, title, metadata
         FROM notification
         WHERE user_id = $1
           AND type = 'import_event'
         ORDER BY created_at DESC`,
        [standardAdmin.user.id],
      );
      expect(commentNotificationCheck.rows).toHaveLength(1);
      expect(commentNotificationCheck.rows[0].title).toContain('Import comment added');

      const commentVisibleToUploader = await request(app)
        .get(`${API_PREFIX}/imports/${importId}`)
        .set(authHeader(standardAdmin.token))
        .expect(200);
      expect(commentVisibleToUploader.body.data.comments).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            comment_text: 'Please verify the imported admin dataset naming.',
          }),
        ]),
      );

      const downloadResponse = await request(app)
        .get(`${API_PREFIX}/imports/${importId}/download`)
        .set(authHeader(protectedAdmin.token))
        .expect(200);
      expect(downloadResponse.headers['content-disposition']).toContain(
        'admin-import-review-scope',
      );

      await request(app)
        .post(`${API_PREFIX}/imports/${importId}/review`)
        .set(authHeader(protectedAdmin.token))
        .send({ status: 'approved' })
        .expect(200);
    } finally {
      process.env.SUPER_ADMIN_EMAIL = previousProtectedEmail;
    }
  });

  test('accepts MultiPolygon geometries for staged review', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Multipolygon Admin',
      emailPrefix: 'import-multipolygon-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Multipolygon Contributor',
      emailPrefix: 'import-multipolygon-contributor',
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
      name: 'Import Multipolygon Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Multipolygon Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-multipolygon', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'cedar', name: 'MultiPolygon cedar area' },
          geometry: {
            type: 'MultiPolygon',
            coordinates: [
              [
                [
                  [35.48, 33.89],
                  [35.49, 33.89],
                  [35.49, 33.9],
                  [35.48, 33.9],
                  [35.48, 33.89],
                ],
              ],
            ],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(0);
    expect(detailResponse.body.data.preview_features[0].geometry_type).toBe('MultiPolygon');
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.not.arrayContaining(['Geometry is missing or unsupported.']),
    );

    const quickMapResponse = await request(app)
      .get(`${API_PREFIX}/imports/${uploadResponse.body.data.id}/quick-map`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(quickMapResponse.body.data.rendered_feature_count).toBe(1);
    expect(quickMapResponse.body.data.features[0].geometry.type).toBe('MultiPolygon');
    expect(quickMapResponse.body.data.features[0].cluster_count).toBe(1);
  }, 15000);

  test('accepts larger imports beyond the old 2000-feature cap', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Batch Admin',
      emailPrefix: 'import-batch-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Batch Contributor',
      emailPrefix: 'import-batch-contributor',
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
      name: 'Import Batch Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Batch Project',
      visibleToContributors: true,
    });
    await pool.query('UPDATE project SET collection_form_schema = $1::jsonb WHERE id = $2', [
      JSON.stringify(
        schemaWithField({
          key: 'feature_type',
          label: 'feature_type',
          type: 'select',
          required: true,
          options: ['olive', 'cedar'],
        }),
      ),
      project.id,
    ]);
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

    const features = Array.from({ length: 2105 }, (_, index) => ({
      type: 'Feature',
      properties: {
        feature_type: index % 2 === 0 ? 'olive' : 'cedar',
        name: `Imported feature ${index + 1}`,
        OBJECTID_1: index + 1,
        notes: `Long note ${index + 1} kept out of list summaries`,
      },
      geometry: {
        type: 'Point',
        coordinates: [35.2 + index * 0.0001, 33.1 + index * 0.0001],
      },
    }));

    const geojsonPath = await createTempGeoJsonFile('import-large-batch', {
      type: 'FeatureCollection',
      features,
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const detailsResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
      attempts: 80,
      delayMs: 250,
    });

    expect(detailsResponse.body.data.job.geometry_count).toBe(2105);
    expect(detailsResponse.body.data.job.pending_feature_count).toBe(2105);
    expect(detailsResponse.body.data.preview_features).toHaveLength(20);
    expect(detailsResponse.body.data.preview_summary.preview_feature_count).toBe(20);

    const featuresPage1 = await request(app)
      .get(`${API_PREFIX}/imports/${uploadResponse.body.data.id}/features?page=1&limit=20`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(featuresPage1.body.data).toHaveLength(20);
    expect(featuresPage1.body.pagination.total).toBe(2105);
    expect(featuresPage1.body.pagination.has_more).toBe(true);
    expect(featuresPage1.body.data[0].geometry).toBeNull();
    expect(featuresPage1.body.data[0].attributes).toEqual({
      feature_type: 'olive',
    });
    expect(featuresPage1.body.data[0].summary_attributes).toEqual({
      feature_type: 'olive',
    });
    expect(featuresPage1.body.data[0].attribute_count).toBe(4);
    expect(featuresPage1.body.data[0].attributes.notes).toBeUndefined();
    expect(featuresPage1.body.data[0].attributes.name).toBeUndefined();
    expect(featuresPage1.body.data[0].attributes.OBJECTID_1).toBeUndefined();
    expect(featuresPage1.body.data[0].is_summary).toBe(true);

    const featuresPage2 = await request(app)
      .get(`${API_PREFIX}/imports/${uploadResponse.body.data.id}/features?page=2&limit=20`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(featuresPage2.body.data).toHaveLength(20);
    expect(featuresPage2.body.pagination.total).toBe(2105);
    expect(featuresPage2.body.pagination.has_more).toBe(true);

    const quickMapResponse = await request(app)
      .get(`${API_PREFIX}/imports/${uploadResponse.body.data.id}/quick-map`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(quickMapResponse.body.data.total_feature_count).toBe(2105);
    expect(quickMapResponse.body.data.geometry_feature_count).toBe(2105);
    expect(quickMapResponse.body.data.rendered_feature_count).toBeLessThan(2105);
    expect(quickMapResponse.body.data.rendered_feature_count).toBeLessThanOrEqual(500);
    expect(quickMapResponse.body.data.is_clustered).toBe(true);
    expect(quickMapResponse.body.data.status_counts.pending_review).toBe(2105);
    expect(quickMapResponse.body.data.features).toHaveLength(
      quickMapResponse.body.data.rendered_feature_count,
    );
    expect(quickMapResponse.body.data.features[0].geometry.type).toBe('Point');
    expect(quickMapResponse.body.data.features[0].attributes).toEqual({});
    expect(
      quickMapResponse.body.data.features.reduce(
        (total, feature) => total + feature.cluster_count,
        0,
      ),
    ).toBe(2105);
    expect(quickMapResponse.body.data.bounds.min_lon).toBeCloseTo(35.2, 5);
    expect(quickMapResponse.body.data.bounds.min_lat).toBeCloseTo(33.1, 5);
    expect(quickMapResponse.body.data.bounds.max_lon).toBeCloseTo(35.4104, 5);
    expect(quickMapResponse.body.data.bounds.max_lat).toBeCloseTo(33.3104, 5);
    expect(JSON.stringify(quickMapResponse.body.data)).not.toContain('Long note');

    const importsPage = await request(app)
      .get(`${API_PREFIX}/imports?page=1&limit=20&project_id=${project.id}`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(importsPage.body.data).toHaveLength(1);
    expect(importsPage.body.pagination.total).toBe(1);
    expect(importsPage.body.pagination.has_more).toBe(false);
  }, 20000);

  test('rejects GeoJSON uploads with unsupported CRS before staging', async () => {
    const admin = await createAdminUser({
      fullName: 'Import CRS Admin',
      emailPrefix: 'import-crs-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import CRS Contributor',
      emailPrefix: 'import-crs-contributor',
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
      name: 'Import CRS Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import CRS Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-unsupported-crs', {
      type: 'FeatureCollection',
      crs: {
        type: 'name',
        properties: {
          name: 'EPSG:9999',
        },
      },
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Unsupported CRS feature' },
          geometry: {
            type: 'Point',
            coordinates: [35.51, 33.91],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const detailsResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: contributorLogin.token,
      expectedStatuses: ['failed'],
    });

    expect(detailsResponse.body.data.job.processing_message).toContain(
      'Unsupported coordinate reference system "EPSG:9999"',
    );

    const importJobs = await pool.query(
      `SELECT COUNT(*)::int AS total
       FROM gis_import_job
       WHERE status = 'failed'`,
    );
    expect(importJobs.rows[0].total).toBe(1);

    const stagedFeatures = await pool.query(
      `SELECT COUNT(*)::int AS total FROM gis_import_feature`,
    );
    expect(stagedFeatures.rows[0].total).toBe(0);
  });
});
