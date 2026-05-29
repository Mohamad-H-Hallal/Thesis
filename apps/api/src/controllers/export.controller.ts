const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
const fs = require('fs').promises;
const path = require('path');
const AdmZip = require('adm-zip');
import { sanitizeManagedFeatureAttributes } from '../lib/featureAttributes';

// For shapefile generation
const shpwrite = require('@mapbox/shp-write');

// Export directory
const EXPORT_DIR = process.env.EXPORT_DIR ?? './exports';
const RETENTION_DAYS = Number.parseInt(process.env.EXPORT_RETENTION_DAYS ?? '7', 10);

// Ensure export directory exists
const ensureExportDir = async () => {
  try {
    await fs.mkdir(EXPORT_DIR, { recursive: true });
  } catch (error: unknown) {
    logger.error('Error creating export directory:', error);
  }
};

const normalizeOptionalString = (value: unknown) => {
  if (value === null || value === undefined) {
    return undefined;
  }
  const normalized = String(value).trim();
  return normalized.length === 0 ? undefined : normalized;
};

const parseBbox = (value: unknown) => {
  if (value === null || value === undefined) {
    return undefined;
  }

  const parts = Array.isArray(value) ? value : String(value).split(',');
  if (parts.length !== 4) {
    return undefined;
  }

  const numbers = parts.map((item) => Number.parseFloat(String(item).trim()));
  if (numbers.some((item) => Number.isNaN(item))) {
    return undefined;
  }

  const [minLon, minLat, maxLon, maxLat] = numbers;
  if (!(minLon < maxLon && minLat < maxLat)) {
    return undefined;
  }

  return {
    minLon,
    minLat,
    maxLon,
    maxLat,
  };
};

const sanitizeZipSegment = (value: unknown) =>
  String(value ?? 'file')
    .trim()
    .replace(/[^a-zA-Z0-9._-]/g, '_')
    .slice(0, 120) || 'file';

const LEBANON_TIME_ZONE = 'Asia/Beirut';

const lebanonDateTimeFormatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: LEBANON_TIME_ZONE,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
  timeZoneName: 'shortOffset',
});

const formatLebanonDateTime = (value: unknown): string | null => {
  if (!value) {
    return null;
  }
  const date = value instanceof Date ? value : new Date(String(value));
  if (Number.isNaN(date.getTime())) {
    return null;
  }
  const parts = Object.fromEntries(
    lebanonDateTimeFormatter.formatToParts(date).map((part) => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute} ${parts.timeZoneName} (${LEBANON_TIME_ZONE})`;
};

const formatLebanonDate = (value: unknown): string =>
  formatLebanonDateTime(value)?.slice(0, 10) ?? '';

const parsePolygonFilter = (value: unknown) => {
  if (value === null || value === undefined) {
    return undefined;
  }
  let parsed;
  try {
    parsed = typeof value === 'string' ? JSON.parse(value) : value;
  } catch (_error) {
    throw new AppError('export_polygon must be a valid GeoJSON Polygon.', 400);
  }
  if (
    !parsed ||
    typeof parsed !== 'object' ||
    parsed.type !== 'Polygon' ||
    !Array.isArray(parsed.coordinates)
  ) {
    throw new AppError('export_polygon must be a GeoJSON Polygon in EPSG:4326.', 400);
  }
  return parsed;
};

const normalizeFeatureType = (value: unknown) => {
  const normalized = normalizeOptionalString(value);
  return normalized && normalized.toLowerCase() !== 'all' ? normalized : undefined;
};

const appendExportFilters = ({ sql, params, paramIndex, filters, tableAlias = 'sf' }) => {
  let queryText = sql;
  let nextParamIndex = paramIndex;
  if (filters.status_filter && filters.status_filter.length > 0) {
    queryText += ` AND ${tableAlias}.status = ANY($${nextParamIndex}::feature_status[])`;
    params.push(filters.status_filter);
    nextParamIndex++;
  }
  if (filters.date_from) {
    queryText += ` AND ${tableAlias}.collected_at >= ($${nextParamIndex}::date)`;
    params.push(filters.date_from);
    nextParamIndex++;
  }
  if (filters.date_to) {
    queryText += ` AND ${tableAlias}.collected_at < (($${nextParamIndex}::date) + INTERVAL '1 day')`;
    params.push(filters.date_to);
    nextParamIndex++;
  }
  if (filters.bbox) {
    queryText += `
      AND ST_Intersects(
        ${tableAlias}.geom,
        ST_MakeEnvelope($${nextParamIndex}, $${nextParamIndex + 1}, $${nextParamIndex + 2}, $${nextParamIndex + 3}, 4326)
      )`;
    params.push(filters.bbox.minLon, filters.bbox.minLat, filters.bbox.maxLon, filters.bbox.maxLat);
    nextParamIndex += 4;
  }
  if (filters.export_polygon) {
    queryText += `
      AND ST_Intersects(
        ${tableAlias}.geom,
        ST_SetSRID(ST_GeomFromGeoJSON($${nextParamIndex}), 4326)
      )`;
    params.push(JSON.stringify(filters.export_polygon));
    nextParamIndex++;
  }
  if (filters.feature_type) {
    queryText += ` AND LOWER(BTRIM(COALESCE(${tableAlias}.attributes->>'feature_type', ${tableAlias}.attributes->>'type', ${tableAlias}.attributes->>'class', ''))) = LOWER($${nextParamIndex})`;
    params.push(filters.feature_type);
    nextParamIndex++;
  }
  if (filters.geometry_types && filters.geometry_types.length > 0) {
    const geomTypes = filters.geometry_types.map((t) => `ST_${t}`);
    queryText += ` AND ST_GeometryType(${tableAlias}.geom) = ANY($${nextParamIndex}::text[])`;
    params.push(geomTypes);
    nextParamIndex++;
  }
  return { sql: queryText, paramIndex: nextParamIndex };
};

const getPagination = (pageRaw: unknown, limitRaw: unknown) => {
  const page = Math.max(1, Number.parseInt(String(pageRaw ?? '1'), 10) || 1);
  const requestedLimit = Math.max(1, Number.parseInt(String(limitRaw ?? '20'), 10) || 20);
  const limit = Math.min(requestedLimit, 100);
  const offset = (page - 1) * limit;

  return { page, limit, offset };
};

// Request export for a project
const requestExport = async (req, res) => {
  const { projectId } = req.params;
  const {
    status_filter = ['approved'],
    date_from,
    date_to,
    bbox,
    export_polygon,
    feature_type,
    geometry_types,
    include_photos = true,
    coordinate_system = 'EPSG:4326',
    format = 'geojson', // Default to geojson
  } = req.body;

  // Validate format
  const validFormats = ['shapefile', 'geojson'];
  if (!validFormats.includes(format)) {
    throw new AppError(`Invalid format. Must be one of: ${validFormats.join(', ')}`, 400);
  }

  // Validate project exists and user has access
  const projectCheck = await query('SELECT id, name FROM project WHERE id = $1', [projectId]);

  if (projectCheck.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  const project = projectCheck.rows[0];

  const normalizedDateFrom = normalizeOptionalString(date_from);
  const normalizedDateTo = normalizeOptionalString(date_to);
  const normalizedBbox = parseBbox(bbox);
  const normalizedPolygon = parsePolygonFilter(export_polygon);
  const normalizedFeatureType = normalizeFeatureType(feature_type);

  // Build export parameters
  const exportParams = {
    status_filter: Array.isArray(status_filter) ? status_filter : [status_filter],
    date_from: normalizedDateFrom,
    date_to: normalizedDateTo,
    bbox: normalizedBbox,
    export_polygon: normalizedPolygon,
    feature_type: normalizedFeatureType,
    geometry_types,
    include_photos,
    coordinate_system,
    format, // Store user's format preference
  };

  let availabilityQuery = `
    SELECT COUNT(*)::int AS feature_count
    FROM spatial_feature sf
    WHERE sf.project_id = $1
  `;
  const availabilityParams: unknown[] = [projectId];
  let availabilityParamIndex = 2;

  const availabilityFilter = appendExportFilters({
    sql: availabilityQuery,
    params: availabilityParams,
    paramIndex: availabilityParamIndex,
    filters: exportParams,
  });
  availabilityQuery = availabilityFilter.sql;

  const availabilityResult = await query(availabilityQuery, availabilityParams);
  const featureCount = availabilityResult.rows[0]?.feature_count ?? 0;
  if (featureCount <= 0) {
    throw new AppError(
      'Exports can be requested after this project has at least one approved feature that matches the selected filters.',
      409,
    );
  }

  // Create export request
  const result = await query(
    `INSERT INTO shapefile_export (
      project_id, requested_by_user_id, export_parameters, status
    ) VALUES ($1, $2, $3, 'pending')
    RETURNING id, requested_at`,
    [projectId, req.user.id, JSON.stringify(exportParams)],
  );

  const exportId = result.rows[0].id;

  // Start async export process (don't wait for completion)
  processExport(exportId, project.name).catch((error) => {
    logger.error('Export processing error:', { exportId, error });
  });

  logger.info('Export requested:', {
    exportId,
    projectId,
    userId: req.user.id,
    format,
  });

  res.status(202).json({
    success: true,
    message: `Export request created (${format} format). Processing in background.`,
    data: {
      export_id: exportId,
      status: 'pending',
      format: format,
      requested_at: result.rows[0].requested_at,
    },
  });
};

// Process the export (background job)
const processExport = async (exportId, projectName) => {
  try {
    // Update status to processing
    await query(`UPDATE shapefile_export SET status = 'processing' WHERE id = $1`, [exportId]);

    logger.info('Starting export processing:', { exportId });

    // Get export details
    const exportDetails = await query(
      `SELECT se.*, p.collection_form_schema
       FROM shapefile_export se
       JOIN project p ON se.project_id = p.id
       WHERE se.id = $1`,
      [exportId],
    );

    if (exportDetails.rows.length === 0) {
      throw new Error('Export request not found');
    }

    const exportData = exportDetails.rows[0];
    const params = exportData.export_parameters;
    const projectId = exportData.project_id;
    const format = params.format || 'geojson';

    // Build query to get features
    let featureQuery = `
      SELECT 
        sf.id,
        ST_AsGeoJSON(sf.geom) as geojson_geometry,
        ST_GeometryType(sf.geom) as geometry_type,
        sf.attributes,
        sf.collected_at,
        u.full_name as collected_by,
        COALESCE(photo_rollup.photo_count, 0)::int AS photo_count,
        COALESCE(photo_rollup.photos, '[]'::json) AS photos
      FROM spatial_feature sf
      JOIN "user" u ON sf.collected_by_user_id = u.id
      LEFT JOIN LATERAL (
        SELECT
          COUNT(*)::int AS photo_count,
          json_agg(
            json_build_object(
              'id', ph.id,
              'feature_id', ph.feature_id,
              'file_path', ph.file_path,
              'thumbnail_path', ph.thumbnail_path,
              'status', ph.status,
              'display_order', ph.display_order,
              'taken_at', ph.taken_at,
              'uploaded_at', ph.uploaded_at,
              'file_size_bytes', ph.file_size_bytes
            )
            ORDER BY ph.display_order ASC, ph.uploaded_at ASC
          ) AS photos
        FROM photo ph
        WHERE ph.feature_id = sf.id
          AND ph.status <> 'rejected'
      ) photo_rollup ON TRUE
      WHERE sf.project_id = $1
    `;

    const queryParams = [projectId];
    let paramIndex = 2;

    const featureFilter = appendExportFilters({
      sql: featureQuery,
      params: queryParams,
      paramIndex,
      filters: params,
    });
    featureQuery = featureFilter.sql;

    logger.info('Querying features:', { exportId, format });

    const features = await query(featureQuery, queryParams);

    logger.info('Features found:', { exportId, count: features.rows.length, format });

    if (features.rows.length === 0) {
      throw new Error('No features found matching the export criteria');
    }

    // Create export directory for this request
    const exportTimestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const exportName = `${projectName.replace(/[^a-zA-Z0-9]/g, '_')}_${exportTimestamp}`;
    const exportPath = path.join(EXPORT_DIR, exportId);
    await fs.mkdir(exportPath, { recursive: true });

    logger.info('Created export directory:', { exportId, path: exportPath });

    const photoManifest = params.include_photos
      ? await attachExportPhotos(exportPath, features.rows)
      : [];

    // Group features by geometry type
    const featuresByType: Record<string, any[]> = {};
    features.rows.forEach((feature: any) => {
      const type = feature.geometry_type.replace('ST_', '');
      if (!featuresByType[type]) {
        featuresByType[type] = [];
      }
      featuresByType[type].push(feature);
    });

    logger.info('Features grouped by type:', {
      exportId,
      types: Object.keys(featuresByType),
      format,
    });

    // Generate files based on format
    const generatedFiles: Array<{ name: string; type: string; count: number; format: string }> = [];

    if (format === 'shapefile') {
      // Generate shapefiles
      for (const [geomType, typeFeatures] of Object.entries(featuresByType)) {
        const fileName = `${exportName}_${geomType}`;

        try {
          await createShapefile(exportPath, fileName, typeFeatures, geomType);

          logger.info('Created shapefile:', { exportId, file: fileName });

          generatedFiles.push({
            name: `${fileName}.shp`,
            type: geomType,
            count: typeFeatures.length,
            format: 'shapefile',
          });
        } catch (error: any) {
          logger.error('Shapefile creation error:', { exportId, geomType, error });
          throw error;
        }
      }
    } else {
      // Generate GeoJSON files
      for (const [geomType, typeFeatures] of Object.entries(featuresByType)) {
        const fileName = `${exportName}_${geomType}`;
        const geojsonPath = path.join(exportPath, `${fileName}.geojson`);
        const geojson = createGeoJSON(typeFeatures, projectName, geomType);

        await fs.writeFile(geojsonPath, JSON.stringify(geojson, null, 2));

        logger.info('Created GeoJSON:', { exportId, file: `${fileName}.geojson` });

        generatedFiles.push({
          name: `${fileName}.geojson`,
          type: geomType,
          count: typeFeatures.length,
          format: 'geojson',
        });
      }
    }

    // Create metadata file
    const metadata = {
      project_name: projectName,
      export_date: formatLebanonDateTime(new Date()),
      time_zone: LEBANON_TIME_ZONE,
      feature_count: features.rows.length,
      geometry_types: Object.keys(featuresByType),
      coordinate_system: params.coordinate_system,
      format: format,
      filters: {
        status: params.status_filter,
        date_from: params.date_from,
        date_to: params.date_to,
        bbox: params.bbox,
        export_polygon: params.export_polygon ? 'GeoJSON Polygon filter applied' : null,
        feature_type: params.feature_type,
        include_photos: params.include_photos === true,
      },
      files: generatedFiles,
      photo_manifest: photoManifest.length > 0 ? 'photos_manifest.json' : null,
      notes:
        format === 'shapefile'
          ? 'Shapefile format: Field names limited to 10 characters, strings to 254 characters (DBF limitations)'
          : 'GeoJSON format: Modern, web-friendly format compatible with all GIS software',
    };

    await fs.writeFile(path.join(exportPath, 'metadata.json'), JSON.stringify(metadata, null, 2));
    if (params.include_photos) {
      await fs.writeFile(
        path.join(exportPath, 'photos_manifest.json'),
        JSON.stringify(photoManifest, null, 2),
      );
      await fs.writeFile(
        path.join(exportPath, 'photos_manifest.csv'),
        createPhotoManifestCsv(photoManifest),
      );
      await fs.writeFile(path.join(exportPath, 'README_PHOTOS.txt'), generatePhotoReadme(format));
    }

    logger.info('Created metadata:', { exportId });

    // Create README
    const readme = generateReadme(metadata, projectName, format);
    await fs.writeFile(path.join(exportPath, 'README.txt'), readme);

    logger.info('Created README:', { exportId });

    // Zip everything
    const zipPath = path.join(EXPORT_DIR, `${exportName}.zip`);
    await zipDirectory(exportPath, zipPath);

    logger.info('Created ZIP:', { exportId, zipPath });

    // Get file size
    const stats = await fs.stat(zipPath);
    const fileSizeBytes = stats.size;

    await transaction(async (client) => {
      await client.query(
        `UPDATE shapefile_export 
         SET status = 'completed',
             completed_at = CURRENT_TIMESTAMP,
             file_path = $1,
             feature_count = $2,
             file_size_bytes = $3
         WHERE id = $4`,
        [zipPath, features.rows.length, fileSizeBytes, exportId],
      );

      await client.query(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'export_ready', 'Export ready for download',
                 $2, $3)`,
        [
          exportData.requested_by_user_id,
          `${projectName} export (${format.toUpperCase()}) is ready for download.`,
          JSON.stringify({
            export_id: exportId,
            project_id: projectId,
            project_name: projectName,
            format: format,
            status: 'completed',
          }),
        ],
      );
    });

    // Clean up temporary directory
    await fs.rm(exportPath, { recursive: true, force: true });

    logger.info('Export completed:', {
      exportId,
      featureCount: features.rows.length,
      fileSize: fileSizeBytes,
      format,
    });
  } catch (error: any) {
    logger.error('Export processing failed:', {
      exportId,
      error: error.message,
      stack: error.stack,
    });

    await transaction(async (client) => {
      await client.query(
        `UPDATE shapefile_export 
         SET status = 'failed',
             completed_at = CURRENT_TIMESTAMP,
             error_message = $1
         WHERE id = $2`,
        [error.message, exportId],
      );

      const exportDetails = await client.query(
        `SELECT se.requested_by_user_id, se.project_id, p.name AS project_name
         FROM shapefile_export se
         JOIN project p ON p.id = se.project_id
         WHERE se.id = $1`,
        [exportId],
      );

      if (exportDetails.rows.length > 0) {
        await client.query(
          `INSERT INTO notification (user_id, type, title, message, metadata)
           VALUES ($1, 'export_ready', 'Export failed',
                   $2, $3)`,
          [
            exportDetails.rows[0].requested_by_user_id,
            `${exportDetails.rows[0].project_name} export failed. ${error.message}`,
            JSON.stringify({
              export_id: exportId,
              project_id: exportDetails.rows[0].project_id,
              project_name: exportDetails.rows[0].project_name,
              status: 'failed',
              error: error.message,
            }),
          ],
        );
      }
    });
  }
};

// Create shapefile using shp-write
const createShapefile = async (outputDir, fileName, features, _geometryType) => {
  const geojsonFeatures = features.map((f) => {
    const geom = JSON.parse(f.geojson_geometry);

    const properties = {
      feat_id: f.id.substring(0, 10),
      collect_at: formatLebanonDate(f.collected_at),
      collect_by: f.collected_by ? f.collected_by.substring(0, 50) : '',
      photo_cnt: Number(f.photo_count ?? 0),
      photo_ref:
        Array.isArray(f.photo_paths) && f.photo_paths.length > 0
          ? String(f.photo_paths[0]).substring(0, 254)
          : '',
    };

    const sanitizedAttributes = sanitizeManagedFeatureAttributes(f.attributes);
    if (sanitizedAttributes) {
      Object.keys(sanitizedAttributes).forEach((key) => {
        const truncatedKey = key.substring(0, 10);
        let value = sanitizedAttributes[key];

        if (typeof value === 'string') {
          properties[truncatedKey] = value.substring(0, 254);
        } else if (typeof value === 'number') {
          properties[truncatedKey] = value;
        } else if (typeof value === 'boolean') {
          properties[truncatedKey] = value ? 1 : 0;
        } else if (value != null) {
          properties[truncatedKey] = String(value).substring(0, 254);
        }
      });
    }

    return {
      type: 'Feature',
      geometry: geom,
      properties,
    };
  });

  const geojson = {
    type: 'FeatureCollection',
    features: geojsonFeatures,
  };

  try {
    const zipBuffer = await shpwrite.zip(geojson, {
      outputType: 'nodebuffer',
    });

    // Write temp ZIP
    const tempZip = path.join(outputDir, `${fileName}_temp.zip`);
    await fs.writeFile(tempZip, zipBuffer);

    // Extract shapefile components
    const zip = new AdmZip(tempZip);
    zip.extractAllTo(outputDir, true);

    // Clean up
    await fs.unlink(tempZip);

    logger.info('Shapefile created:', { fileName, size: zipBuffer.length });
  } catch (error: any) {
    logger.error('Shapefile error:', error);
    throw new Error(`Shapefile creation failed: ${error.message}`);
  }
};

// Create GeoJSON from features
const createGeoJSON = (features, projectName, geometryType) => {
  return {
    type: 'FeatureCollection',
    name: `${projectName} - ${geometryType}`,
    crs: {
      type: 'name',
      properties: {
        name: 'urn:ogc:def:crs:OGC:1.3:CRS84',
      },
    },
    features: features.map((f) => {
      const geom = JSON.parse(f.geojson_geometry);
      return {
        type: 'Feature',
        geometry: geom,
        properties: {
          feature_id: f.id,
          collected_at: formatLebanonDateTime(f.collected_at),
          collected_by: f.collected_by,
          photo_count: Number(f.photo_count ?? 0),
          primary_photo_path:
            Array.isArray(f.photo_paths) && f.photo_paths.length > 0 ? f.photo_paths[0] : null,
          photo_paths: Array.isArray(f.photo_paths) ? f.photo_paths : [],
          photo_manifest_ref: Number(f.photo_count ?? 0) > 0 ? 'photos_manifest.json' : null,
          ...sanitizeManagedFeatureAttributes(f.attributes),
        },
      };
    }),
  };
};

const normalizePhotoRows = (feature: any): any[] => {
  if (Array.isArray(feature.photos)) {
    return feature.photos;
  }
  return [];
};

const attachExportPhotos = async (exportPath: string, features: any[]) => {
  const manifest: any[] = [];
  for (const feature of features) {
    const photoRows = normalizePhotoRows(feature);
    const paths: string[] = [];
    for (const photo of photoRows) {
      const sourcePath = path.resolve(String(photo.file_path ?? ''));
      const extension = path.extname(sourcePath).toLowerCase() || '.jpg';
      const fileName = `${sanitizeZipSegment(photo.id)}${extension}`;
      const relativePath = path.posix.join('photos', sanitizeZipSegment(feature.id), fileName);
      const destinationPath = path.join(
        exportPath,
        'photos',
        sanitizeZipSegment(feature.id),
        fileName,
      );
      try {
        await fs.mkdir(path.dirname(destinationPath), { recursive: true });
        await fs.copyFile(sourcePath, destinationPath);
        paths.push(relativePath);
        manifest.push({
          feature_id: feature.id,
          photo_id: photo.id,
          path: relativePath,
          display_order: photo.display_order,
          taken_at: formatLebanonDateTime(photo.taken_at),
          uploaded_at: formatLebanonDateTime(photo.uploaded_at),
          file_size_bytes: photo.file_size_bytes,
        });
      } catch (error: any) {
        logger.warn('Skipping export photo that could not be copied', {
          featureId: feature.id,
          photoId: photo.id,
          error: error.message,
        });
      }
    }
    feature.photo_paths = paths;
    feature.photo_count = paths.length;
  }
  return manifest;
};

const csvEscape = (value: unknown) => {
  const raw = String(value ?? '');
  return /[",\r\n]/.test(raw) ? `"${raw.replace(/"/g, '""')}"` : raw;
};

const createPhotoManifestCsv = (manifest: any[]) => {
  const headers = [
    'feature_id',
    'photo_id',
    'path',
    'display_order',
    'taken_at',
    'uploaded_at',
    'file_size_bytes',
  ];
  return [
    headers.join(','),
    ...manifest.map((row) => headers.map((header) => csvEscape(row[header])).join(',')),
  ].join('\n');
};

const generatePhotoReadme = (format: string) => `Exported Feature Photos
=======================

Photos are stored inside the photos/ folder using relative ZIP paths.

Photo linkage files:
- photos_manifest.json maps feature_id and photo_id to each exported photo path.
- photos_manifest.csv contains the same mapping in spreadsheet-friendly form.
- All timestamps are in Lebanon time (${LEBANON_TIME_ZONE}) and are converted only for exported/user-facing files.

GIS attributes:
${
  format === 'shapefile'
    ? '- Shapefile DBF attributes include photo_cnt and photo_ref. Use the manifest for full photo mapping.'
    : '- GeoJSON properties include photo_count, primary_photo_path, photo_paths, and photo_manifest_ref.'
}

The photo paths are relative to this extracted export package. In GIS software, inspect the attribute path or configure a hyperlink/action if you want one-click photo opening.
`;

// Generate README for export
const generateReadme = (metadata, projectName, format) => {
  const formatSpecificInfo =
    format === 'shapefile'
      ? `
Shapefile Components:
=====================
For each geometry type, you'll find 4 files:

1. .shp - Geometry data (shapes)
2. .dbf - Attribute data (feature properties)
3. .shx - Index file (links geometry to attributes)
4. .prj - Projection information

⚠️  ALL FOUR FILES ARE REQUIRED - Keep them together!

Shapefile Limitations:
- Field names: Maximum 10 characters (automatically truncated)
- Text fields: Maximum 254 characters
- Check metadata.json for full field names

How to Use Shapefiles:
======================
1. Open QGIS or ArcGIS
2. Add Data > Select the .shp file
3. All 4 files must be in the same folder
4. Features will display on the map
`
      : `
GeoJSON Format:
===============
Modern, web-friendly geospatial format.

Advantages:
- Single file (not 4 like shapefiles)
- No field name limitations
- No string length limitations
- Human-readable JSON format
- Works with web mapping libraries

How to Use GeoJSON:
===================
METHOD 1: Open in QGIS
1. Drag and drop .geojson file into QGIS
2. Features will display immediately

METHOD 2: Open in ArcGIS
1. Add Data > Select .geojson file
2. Features will display on the map

METHOD 3: Convert to Shapefile (if needed)
1. Open in QGIS
2. Right-click layer > Export > Save Features As...
3. Format: ESRI Shapefile
4. Click OK

METHOD 4: View Online
1. Go to http://geojson.io
2. Drag and drop .geojson file
3. View and edit in browser
`;

  return `Lebanese GIS Mobile Application - Data Export
=====================================

Project: ${projectName}
Export Date: ${metadata.export_date}
Time Zone: ${metadata.time_zone}
Total Features: ${metadata.feature_count}
Format: ${format.toUpperCase()}

Geometry Types:
${metadata.geometry_types.map((t) => `  - ${t}`).join('\n')}

Coordinate System: ${metadata.coordinate_system}

Filters Applied:
  - Status: ${metadata.filters.status.join(', ')}
  - Date From: ${metadata.filters.date_from || 'Not specified'}
  - Date To: ${metadata.filters.date_to || 'Not specified'}
  - BBOX: ${
    metadata.filters.bbox
      ? `${metadata.filters.bbox.minLon}, ${metadata.filters.bbox.minLat}, ${metadata.filters.bbox.maxLon}, ${metadata.filters.bbox.maxLat}`
      : 'Not specified'
  }

Files Included:
${metadata.files.map((f) => `  - ${f.name} (${f.count} features)`).join('\n')}

${formatSpecificInfo}

Format Information:
===================
You requested: ${format.toUpperCase()}

${
  format === 'shapefile'
    ? `
Shapefile is the traditional GIS format (1990s):
✓ Widely supported in all GIS software
✓ Industry standard
✗ Multiple files required
✗ Field name limitations (10 chars)
✗ String length limitations (254 chars)
`
    : `
GeoJSON is the modern web format (2016):
✓ Single file
✓ No field limitations
✓ Human-readable JSON
✓ Web-friendly
✓ Works in all modern GIS software
`
}

Attribute Information:
======================
${
  format === 'shapefile'
    ? `
DBF file contains feature attributes:
- feat_id: Feature identifier (truncated)
- collect_at: Collection date
- collect_by: Collector name (truncated to 50 chars)
- Plus all custom fields from your survey form (names truncated to 10 chars)

⚠️  Check metadata.json for full field names
`
    : `
GeoJSON contains all feature attributes:
- feature_id: Complete feature identifier
- collected_at: Full ISO timestamp
- collected_by: Complete collector name
- Plus all custom fields with full names (no truncation)
`
}

Technical Details:
==================
- Format: ${format === 'shapefile' ? 'ESRI Shapefile' : 'GeoJSON (RFC 7946)'}
- Coordinate System: ${metadata.coordinate_system}
- Geometry Types: Separated by type (${metadata.geometry_types.join(', ')})
- Encoding: UTF-8

Common GIS Software:
====================
✓ QGIS (free, open source): https://qgis.org
✓ ArcGIS Pro
✓ ArcGIS Desktop
✓ Google Earth Pro
✓ MapInfo
✓ GRASS GIS
✓ AutoCAD Map 3D

Web Mapping Libraries:
=======================
${
  format === 'geojson'
    ? `
✓ Leaflet
✓ Mapbox GL JS
✓ OpenLayers
✓ Google Maps API
✓ deck.gl
✓ Turf.js (for analysis)
`
    : `
For web use, convert to GeoJSON:
1. Open in QGIS
2. Export as GeoJSON
3. Use in web applications
`
}

Need Help?
==========
For questions or issues:
- Check metadata.json for export details
- Contact: Lebanese GIS Application Support
- Documentation: See project README

${
  format === 'shapefile'
    ? `
Common Shapefile Issues:
========================
Q: Why multiple .shp files?
A: Shapefiles can only contain one geometry type. Points, Lines, and 
   Polygons must be in separate files.

Q: Can I open just the .shp file?
A: No, you need ALL files (.shp, .dbf, .shx, .prj) in the same folder.

Q: Why are my field names truncated?
A: DBF format limits field names to 10 characters. Check metadata.json
   for full field names.

Q: How do I convert to GeoJSON?
A: Use QGIS: Right-click layer > Save As > GeoJSON
`
    : `
Common GeoJSON Questions:
=========================
Q: Can I open this in older GIS software?
A: Yes! QGIS, ArcGIS 10.1+, and most modern GIS software support GeoJSON.

Q: How do I convert to Shapefile?
A: Use QGIS: Right-click layer > Save As > ESRI Shapefile

Q: Can I edit GeoJSON in a text editor?
A: Yes! It's human-readable JSON. But use GIS software for complex edits.

Q: Is this compatible with web maps?
A: Absolutely! GeoJSON is the standard format for Leaflet, Mapbox, etc.
`
}

Export Configuration:
=====================
This export was generated with these settings:
- Status filter: ${metadata.filters.status.join(', ')}
- Date range: ${metadata.filters.date_from || 'All'} to ${metadata.filters.date_to || 'All'}
- BBOX: ${
    metadata.filters.bbox
      ? `${metadata.filters.bbox.minLon}, ${metadata.filters.bbox.minLat}, ${metadata.filters.bbox.maxLon}, ${metadata.filters.bbox.maxLat}`
      : 'All approved project features'
  }
- Format: ${format}
- Coordinate system: ${metadata.coordinate_system}

For different export options, request a new export with different parameters.
`;
};

// Zip directory
const zipDirectory = async (sourceDir, outPath) => {
  try {
    const zip = new AdmZip();
    zip.addLocalFolder(sourceDir);
    zip.writeZip(outPath);
    const stats = await fs.stat(outPath);
    logger.info('ZIP created:', { size: stats.size });
  } catch (error: any) {
    logger.error('ZIP creation error:', error);
    throw error;
  }
};

// Get all exports for current user
const getMyExports = async (req, res) => {
  const status = normalizeOptionalString(req.query.status);
  const format = normalizeOptionalString(req.query.format);
  const categoryId = normalizeOptionalString(req.query.category_id);
  const projectId = normalizeOptionalString(req.query.project_id);
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);
  const isAdmin = req.user?.role === 'admin';

  let queryText = `
    SELECT se.*, p.name as project_name
    FROM shapefile_export se
    JOIN project p ON se.project_id = p.id
    WHERE 1=1
  `;

  const params: unknown[] = [];
  let paramIndex = 1;

  if (!isAdmin) {
    queryText += ` AND se.requested_by_user_id = $${paramIndex}`;
    params.push(req.user.id);
    paramIndex++;
  }

  if (status) {
    queryText += ` AND se.status = $${paramIndex}`;
    params.push(status);
    paramIndex++;
  }

  if (format) {
    queryText += ` AND se.export_parameters->>'format' = $${paramIndex}`;
    params.push(format);
    paramIndex++;
  }

  if (categoryId) {
    queryText += ` AND p.category_id = $${paramIndex}`;
    params.push(categoryId);
    paramIndex++;
  }

  if (projectId) {
    queryText += ` AND se.project_id = $${paramIndex}`;
    params.push(projectId);
    paramIndex++;
  }

  queryText += ` ORDER BY se.requested_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  let countQuery = `
    SELECT COUNT(*)::int AS total
    FROM shapefile_export se
    JOIN project p ON se.project_id = p.id
    WHERE 1=1
  `;
  const countParams: unknown[] = [];
  let countParamIndex = 1;

  if (!isAdmin) {
    countQuery += ` AND se.requested_by_user_id = $${countParamIndex}`;
    countParams.push(req.user.id);
    countParamIndex++;
  }

  if (status) {
    countQuery += ` AND se.status = $${countParamIndex}`;
    countParams.push(status);
    countParamIndex++;
  }

  if (format) {
    countQuery += ` AND se.export_parameters->>'format' = $${countParamIndex}`;
    countParams.push(format);
    countParamIndex++;
  }

  if (categoryId) {
    countQuery += ` AND p.category_id = $${countParamIndex}`;
    countParams.push(categoryId);
    countParamIndex++;
  }

  if (projectId) {
    countQuery += ` AND se.project_id = $${countParamIndex}`;
    countParams.push(projectId);
    countParamIndex++;
  }

  const countResult = await query(countQuery, countParams);
  const total = countResult.rows[0]?.total ?? 0;

  let summaryQuery = `
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE se.status = 'pending')::int AS pending,
      COUNT(*) FILTER (WHERE se.status = 'processing')::int AS processing,
      COUNT(*) FILTER (WHERE se.status = 'completed')::int AS completed,
      COUNT(*) FILTER (WHERE se.status = 'failed')::int AS failed
    FROM shapefile_export se
    JOIN project p ON se.project_id = p.id
    WHERE 1=1
  `;
  const summaryParams: unknown[] = [];
  let summaryParamIndex = 1;

  if (!isAdmin) {
    summaryQuery += ` AND se.requested_by_user_id = $${summaryParamIndex}`;
    summaryParams.push(req.user.id);
    summaryParamIndex++;
  }

  if (status) {
    summaryQuery += ` AND se.status = $${summaryParamIndex}`;
    summaryParams.push(status);
    summaryParamIndex++;
  }

  if (format) {
    summaryQuery += ` AND se.export_parameters->>'format' = $${summaryParamIndex}`;
    summaryParams.push(format);
    summaryParamIndex++;
  }

  if (categoryId) {
    summaryQuery += ` AND p.category_id = $${summaryParamIndex}`;
    summaryParams.push(categoryId);
    summaryParamIndex++;
  }

  if (projectId) {
    summaryQuery += ` AND se.project_id = $${summaryParamIndex}`;
    summaryParams.push(projectId);
    summaryParamIndex++;
  }

  const summaryResult = await query(summaryQuery, summaryParams);
  const summary = summaryResult.rows[0] ?? {
    total: 0,
    pending: 0,
    processing: 0,
    completed: 0,
    failed: 0,
  };

  res.json({
    success: true,
    data: result.rows,
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + result.rows.length < total,
    },
    summary: {
      total: summary.total ?? 0,
      pending: summary.pending ?? 0,
      processing: summary.processing ?? 0,
      completed: summary.completed ?? 0,
      failed: summary.failed ?? 0,
    },
  });
};

// Get single export status
const getExportStatus = async (req, res) => {
  const { exportId } = req.params;
  const isAdmin = req.user?.role === 'admin';

  const result = await query(
    `SELECT se.*, p.name as project_name
     FROM shapefile_export se
     JOIN project p ON se.project_id = p.id
     WHERE se.id = $1
       AND ($2::boolean = TRUE OR se.requested_by_user_id = $3)`,
    [exportId, isAdmin, req.user.id],
  );

  if (result.rows.length === 0) {
    throw new AppError('Export not found', 404);
  }

  res.json({
    success: true,
    data: result.rows[0],
  });
};

// Download export file
const downloadExport = async (req, res) => {
  const { exportId } = req.params;
  const isAdmin = req.user?.role === 'admin';

  const result = await query(
    `SELECT file_path, status, project_id, export_parameters
     FROM shapefile_export
     WHERE id = $1
       AND ($2::boolean = TRUE OR requested_by_user_id = $3)`,
    [exportId, isAdmin, req.user.id],
  );

  if (result.rows.length === 0) {
    throw new AppError('Export not found', 404);
  }

  const exportData = result.rows[0];

  if (exportData.status !== 'completed') {
    throw new AppError(`Export is not ready. Current status: ${exportData.status}`, 400);
  }

  if (!exportData.file_path) {
    throw new AppError('Export file not found', 404);
  }

  // Check if file exists
  try {
    await fs.access(exportData.file_path);
  } catch (_error) {
    logger.error('Export file not accessible:', { exportId, path: exportData.file_path });
    throw new AppError('Export file no longer available', 404);
  }

  const format = exportData.export_parameters?.format || 'geojson';
  logger.info('Downloading export:', { exportId, path: exportData.file_path, format });

  // Send file
  res.download(exportData.file_path, (err) => {
    if (err) {
      logger.error('Download error:', { exportId, error: err });
    }
  });
};

// Delete old exports (cleanup job)
const cleanupOldExports = async () => {
  try {
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - RETENTION_DAYS);

    const tableCheck = await query(`SELECT to_regclass('public.shapefile_export') AS table_name`);
    if (!tableCheck.rows[0] || !tableCheck.rows[0].table_name) {
      logger.warn('Skipping export cleanup: shapefile_export table does not exist yet');
      return;
    }

    const oldExports = await query(
      `SELECT id, file_path FROM shapefile_export 
       WHERE completed_at < $1 AND status = 'completed'`,
      [cutoffDate],
    );

    for (const exp of oldExports.rows) {
      if (exp.file_path) {
        await fs.unlink(exp.file_path).catch((err) => {
          logger.error('Error deleting export file:', err);
        });
      }

      await query(
        `UPDATE shapefile_export 
         SET status = 'failed',
             file_path = NULL, 
             error_message = 'File deleted after retention period'
         WHERE id = $1`,
        [exp.id],
      );
    }

    logger.info('Old exports cleaned up:', { count: oldExports.rows.length });
  } catch (error: any) {
    logger.error('Export cleanup error:', error);
  }
};

module.exports = {
  requestExport,
  getMyExports,
  getExportStatus,
  downloadExport,
  cleanupOldExports,
  ensureExportDir,
};

export {};
