const sharp = require('sharp');
const path = require('path');
const fs = require('fs').promises;
const { query } = require('../config/database');
const { AppError } = require('../middleware/error');
const { thumbnailsDir } = require('../config/upload');
const logger = require('../utils/logger');

const hasProjectAccess = async (projectId, userId) => {
  const accessCheck = await query(
    `SELECT 1
     FROM project_assignment
     WHERE project_id = $1 AND user_id = $2 AND status = 'approved'
     LIMIT 1`,
    [projectId, userId]
  );
  return accessCheck.rows.length > 0;
};

// Upload photo(s) to feature
const uploadPhotos = async (req, res) => {
  const { featureId } = req.params;
  const files = (req.files as any[]) || (req.file ? [req.file] : []);

  if (!files || files.length === 0) {
    throw new AppError('No files uploaded', 400);
  }

  // Check if feature exists and user has access
  const featureCheck = await query(
    `SELECT sf.id, sf.collected_by_user_id, p.max_photos
     FROM spatial_feature sf
     JOIN project p ON sf.project_id = p.id
     WHERE sf.id = $1`,
    [featureId]
  );

  if (featureCheck.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  const feature = featureCheck.rows[0];

  // Check ownership (only owner can add photos)
  if (feature.collected_by_user_id !== req.user.id && req.user.role !== 'admin') {
    throw new AppError('You can only add photos to your own features', 403);
  }

  // Check photo count limit
  const currentPhotoCount = await query(
    'SELECT COUNT(*) as count FROM photo WHERE feature_id = $1',
    [featureId]
  );

  const currentCount = parseInt(currentPhotoCount.rows[0].count);
  const maxPhotos = feature.max_photos;

  if (currentCount + files.length > maxPhotos) {
    throw new AppError(
      `Maximum ${maxPhotos} photos allowed per feature. Current: ${currentCount}`,
      400
    );
  }

  // Process each photo
  const uploadedPhotos: any[] = [];

  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    const displayOrder = currentCount + i + 1;

    try {
      // Generate thumbnail
      const thumbnailFilename = `thumb_${path.basename(file.filename)}`;
      const thumbnailPath = path.join(thumbnailsDir, thumbnailFilename);

      await sharp(file.path)
        .resize(300, 300, {
          fit: 'cover',
          position: 'center',
        })
        .jpeg({ quality: 80 })
        .toFile(thumbnailPath);

      // Extract EXIF data
      const metadata = await sharp(file.path).metadata();
      const exifData = {
        width: metadata.width,
        height: metadata.height,
        format: metadata.format,
        space: metadata.space,
        channels: metadata.channels,
        hasAlpha: metadata.hasAlpha,
      };

      let latitude: number | null = null;
      let longitude: number | null = null;
      if (req.body.latitude && req.body.longitude) {
        latitude = Number(req.body.latitude);
        longitude = Number(req.body.longitude);

        if (Number.isNaN(latitude) || Number.isNaN(longitude)) {
          throw new AppError('Invalid latitude/longitude values', 400);
        }
      }

      // Insert photo record
      const result = await query(
        `INSERT INTO photo (
          feature_id, file_path, thumbnail_path, location,
          accuracy_meters, exif_data, file_size_bytes, display_order
        ) VALUES (
          $1,
          $2,
          $3,
          CASE
            WHEN $4 IS NULL OR $5 IS NULL THEN NULL
            ELSE ST_SetSRID(ST_MakePoint($5, $4), 4326)
          END,
          $6,
          $7,
          $8,
          $9
        )
        RETURNING id, file_path, thumbnail_path, display_order, uploaded_at`,
        [
          featureId,
          file.path,
          thumbnailPath,
          latitude,
          longitude,
          req.body.accuracy_meters || null,
          JSON.stringify(exifData),
          file.size,
          displayOrder,
        ]
      );

      uploadedPhotos.push(result.rows[0]);
    } catch (error: unknown) {
      logger.error('Error processing photo:', error);
      // Continue with other photos even if one fails
    }
  }

  logger.info('Photos uploaded:', {
    featureId,
    count: uploadedPhotos.length,
    userId: req.user.id,
  });

  res.status(201).json({
    success: true,
    message: `${uploadedPhotos.length} photo(s) uploaded successfully`,
    data: uploadedPhotos,
  });
};

// Get photos for a feature
const getFeaturePhotos = async (req, res) => {
  const { featureId } = req.params;

  const featureCheck = await query(
    `SELECT id, project_id, collected_by_user_id
     FROM spatial_feature
     WHERE id = $1`,
    [featureId]
  );

  if (featureCheck.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  const feature = featureCheck.rows[0];
  if (req.user.role !== 'admin') {
    const canAccessProject = await hasProjectAccess(feature.project_id, req.user.id);
    if (!canAccessProject && feature.collected_by_user_id !== req.user.id) {
      throw new AppError('You do not have access to this feature', 403);
    }
  }

  const result = await query(
    `SELECT id, file_path, thumbnail_path, 
            ST_X(location) as longitude, ST_Y(location) as latitude,
            accuracy_meters, taken_at, exif_data, file_size_bytes,
            status, display_order, uploaded_at
     FROM photo
     WHERE feature_id = $1
     ORDER BY display_order ASC`,
    [featureId]
  );

  res.json({
    success: true,
    data: result.rows,
  });
};

// Get single photo
const getPhoto = async (req, res) => {
  const { photoId } = req.params;
  const { thumbnail } = req.query;

  const result = await query(
    `SELECT p.file_path, p.thumbnail_path, sf.project_id, sf.collected_by_user_id
     FROM photo p
     JOIN spatial_feature sf ON p.feature_id = sf.id
     WHERE p.id = $1`,
    [photoId]
  );

  if (result.rows.length === 0) {
    throw new AppError('Photo not found', 404);
  }

  const photo = result.rows[0];
  if (req.user.role !== 'admin') {
    const canAccessProject = await hasProjectAccess(photo.project_id, req.user.id);
    if (!canAccessProject && photo.collected_by_user_id !== req.user.id) {
      throw new AppError('You do not have access to this photo', 403);
    }
  }

  const filePath = (thumbnail === 'true' ? photo.thumbnail_path : photo.file_path) as string;

  // Send file
  res.sendFile(path.resolve(filePath));
};

// Delete photo
const deletePhoto = async (req, res) => {
  const { photoId } = req.params;

  // Get photo details
  const photoCheck = await query(
    `SELECT p.id, p.file_path, p.thumbnail_path, sf.collected_by_user_id
     FROM photo p
     JOIN spatial_feature sf ON p.feature_id = sf.id
     WHERE p.id = $1`,
    [photoId]
  );

  if (photoCheck.rows.length === 0) {
    throw new AppError('Photo not found', 404);
  }

  const photo = photoCheck.rows[0];

  // Check ownership
  if (photo.collected_by_user_id !== req.user.id && req.user.role !== 'admin') {
    throw new AppError('You can only delete photos from your own features', 403);
  }

  // Delete files
  try {
    await fs.unlink(photo.file_path);
    await fs.unlink(photo.thumbnail_path);
  } catch (error: unknown) {
    logger.error('Error deleting photo files:', error);
  }

  // Delete database record
  await query('DELETE FROM photo WHERE id = $1', [photoId]);

  logger.info('Photo deleted:', { photoId, userId: req.user.id });

  res.json({
    success: true,
    message: 'Photo deleted successfully',
  });
};

// Update photo order
const updatePhotoOrder = async (req, res) => {
  const { photoId } = req.params;
  const { display_order } = req.body;

  if (typeof display_order !== 'number' || display_order < 0) {
    throw new AppError('Valid display order is required', 400);
  }

  const photoCheck = await query(
    `SELECT p.id, sf.collected_by_user_id
     FROM photo p
     JOIN spatial_feature sf ON p.feature_id = sf.id
     WHERE p.id = $1`,
    [photoId]
  );

  if (photoCheck.rows.length === 0) {
    throw new AppError('Photo not found', 404);
  }

  if (req.user.role !== 'admin' && photoCheck.rows[0].collected_by_user_id !== req.user.id) {
    throw new AppError('You can only update your own feature photos', 403);
  }

  await query('UPDATE photo SET display_order = $1 WHERE id = $2', [
    display_order,
    photoId,
  ]);

  res.json({
    success: true,
    message: 'Photo order updated successfully',
  });
};

module.exports = {
  uploadPhotos,
  getFeaturePhotos,
  getPhoto,
  deletePhoto,
  updatePhotoOrder,
};

export {};
