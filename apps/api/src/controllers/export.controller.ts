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
    geometry_types,
    include_photos = false,
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

  // Build export parameters
  const exportParams = {
    status_filter: Array.isArray(status_filter) ? status_filter : [status_filter],
    date_from: normalizedDateFrom,
    date_to: normalizedDateTo,
    bbox: normalizedBbox,
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

  if (exportParams.status_filter && exportParams.status_filter.length > 0) {
    availabilityQuery += ` AND sf.status = ANY($${availabilityParamIndex}::feature_status[])`;
    availabilityParams.push(exportParams.status_filter);
    availabilityParamIndex++;
  }

  if (exportParams.date_from) {
    availabilityQuery += ` AND sf.collected_at >= ($${availabilityParamIndex}::date)`;
    availabilityParams.push(exportParams.date_from);
    availabilityParamIndex++;
  }

  if (exportParams.date_to) {
    availabilityQuery += ` AND sf.collected_at < (($${availabilityParamIndex}::date) + INTERVAL '1 day')`;
    availabilityParams.push(exportParams.date_to);
    availabilityParamIndex++;
  }

  if (exportParams.bbox) {
    availabilityQuery += `
      AND ST_Intersects(
        sf.geom,
        ST_MakeEnvelope($${availabilityParamIndex}, $${availabilityParamIndex + 1}, $${availabilityParamIndex + 2}, $${availabilityParamIndex + 3}, 4326)
      )`;
    availabilityParams.push(
      exportParams.bbox.minLon,
      exportParams.bbox.minLat,
      exportParams.bbox.maxLon,
      exportParams.bbox.maxLat,
    );
    availabilityParamIndex += 4;
  }

  if (exportParams.geometry_types && exportParams.geometry_types.length > 0) {
    const geomTypes = exportParams.geometry_types.map((t) => `ST_${t}`);
    availabilityQuery += ` AND ST_GeometryType(sf.geom) = ANY($${availabilityParamIndex}::text[])`;
    availabilityParams.push(geomTypes);
  }

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
        u.full_name as collected_by
      FROM spatial_feature sf
      JOIN "user" u ON sf.collected_by_user_id = u.id
      WHERE sf.project_id = $1
    `;

    const queryParams = [projectId];
    let paramIndex = 2;

    // Filter by status
    if (params.status_filter && params.status_filter.length > 0) {
      featureQuery += ` AND sf.status = ANY($${paramIndex}::feature_status[])`;
      queryParams.push(params.status_filter);
      paramIndex++;
    }

    // Filter by date range
    if (params.date_from) {
      featureQuery += ` AND sf.collected_at >= ($${paramIndex}::date)`;
      queryParams.push(params.date_from);
      paramIndex++;
    }

    if (params.date_to) {
      featureQuery += ` AND sf.collected_at < (($${paramIndex}::date) + INTERVAL '1 day')`;
      queryParams.push(params.date_to);
      paramIndex++;
    }

    if (params.bbox) {
      featureQuery += `
        AND ST_Intersects(
          sf.geom,
          ST_MakeEnvelope($${paramIndex}, $${paramIndex + 1}, $${paramIndex + 2}, $${paramIndex + 3}, 4326)
        )`;
      queryParams.push(
        params.bbox.minLon,
        params.bbox.minLat,
        params.bbox.maxLon,
        params.bbox.maxLat,
      );
      paramIndex += 4;
    }

    // Filter by geometry types
    if (params.geometry_types && params.geometry_types.length > 0) {
      const geomTypes = params.geometry_types.map((t) => `ST_${t}`);
      featureQuery += ` AND ST_GeometryType(sf.geom) = ANY($${paramIndex}::text[])`;
      queryParams.push(geomTypes);
      paramIndex++;
    }

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
      export_date: new Date().toISOString(),
      feature_count: features.rows.length,
      geometry_types: Object.keys(featuresByType),
      coordinate_system: params.coordinate_system,
      format: format,
      filters: {
        status: params.status_filter,
        date_from: params.date_from,
        date_to: params.date_to,
        bbox: params.bbox,
      },
      files: generatedFiles,
      notes:
        format === 'shapefile'
          ? 'Shapefile format: Field names limited to 10 characters, strings to 254 characters (DBF limitations)'
          : 'GeoJSON format: Modern, web-friendly format compatible with all GIS software',
    };

    await fs.writeFile(path.join(exportPath, 'metadata.json'), JSON.stringify(metadata, null, 2));

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
      collect_at: f.collected_at ? new Date(f.collected_at).toISOString().substring(0, 10) : '',
      collect_by: f.collected_by ? f.collected_by.substring(0, 50) : '',
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
          collected_at: f.collected_at,
          collected_by: f.collected_by,
          ...sanitizeManagedFeatureAttributes(f.attributes),
        },
      };
    }),
  };
};

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
