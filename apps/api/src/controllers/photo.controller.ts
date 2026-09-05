import { randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import type { NextFunction, Request, Response } from 'express';
const { query, transaction } = require('../config/database');
const { AppError, permanentOfflineSyncError } = require('../middleware/error');
const logger = require('../utils/logger');
const { publicVisibleStatuses, synchronizeProjectStatuses } = require('../lib/projectLifecycle');
import {
  attachmentRejected,
  authorizePhotoParent,
  hashPhotoPayload,
  hasOfflineHeaders,
  photoResponse,
  preparePhoto,
  resolveStoredPhotoPath,
  validatePhotoFields,
  writeNewPrivateFile,
  type MemoryPhotoFile,
  type PreparedPhoto,
  type QueryExecutor,
} from '../services/featurePhotoSecurity.service';
import { assertCurrentOfflineAuthorization } from '../services/offlineSyncSecurity.service';
import { storageAdapter } from '../services/storageAdapter.service';
import {
  cancelFeatureMediaCleanupJobs,
  makeFeatureMediaCleanupJobsAvailable,
  processFeatureMediaCleanupJobs,
  reserveFeatureMediaCleanupJobs,
  withReservedFeatureMediaJobs,
} from '../services/featureMediaCleanup.service';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import type { RealtimePublishInput } from '../realtime/realtimeProtocol';

const photoRealtimeInputs = ({
  projectId,
  featureId,
  photoId,
  action,
  originSessionId,
}: {
  projectId: string;
  featureId: string;
  photoId?: string | null;
  action: string;
  originSessionId?: string | null;
}): RealtimePublishInput[] => [
  {
    scopeType: 'features',
    scopeId: projectId,
    action: 'photo_changed',
    entityType: 'photo',
    entityId: photoId,
    projectId,
    originSessionId,
    audience: { kind: 'project', projectId, access: 'readers' },
  },
  {
    scopeType: 'feature',
    scopeId: featureId,
    action,
    entityType: 'photo',
    entityId: photoId,
    projectId,
    originSessionId,
    audience: { kind: 'project', projectId, access: 'readers' },
  },
];

interface PlannedPhoto extends PreparedPhoto {
  photoId: string;
  photoPath: string;
  thumbnailPath: string;
}

const assertPhotoFeatureReadable = async (
  req: Request,
  feature: {
    project_id: string;
    collected_by_user_id: string;
    status: string;
  },
): Promise<void> => {
  if (req.user?.role === 'admin') {
    return;
  }

  const visibilityColumn =
    req.user?.role === 'viewer' ? 'visible_to_viewers' : 'visible_to_contributors';
  const accessResult = await query(
    `SELECT
       (
         SELECT role
         FROM project_assignment
         WHERE project_id = $1
           AND user_id = $2
           AND status = 'approved'
         LIMIT 1
       ) AS assignment_role,
       EXISTS (
         SELECT 1
         FROM project
         WHERE id = $1
           AND ${visibilityColumn} = TRUE
           AND status::text = ANY($3::text[])
       ) AS is_public_project`,
    [feature.project_id, req.user?.id, publicVisibleStatuses],
  );
  const assignmentRole = accessResult.rows[0]?.assignment_role;
  const isPublicProject = accessResult.rows[0]?.is_public_project === true;
  const isApproved = feature.status === 'approved';
  const isOwner = feature.collected_by_user_id === req.user?.id;
  const canRead =
    (req.user?.role === 'viewer' && isApproved && (Boolean(assignmentRole) || isPublicProject)) ||
    (req.user?.role === 'contributor' &&
      (assignmentRole === 'admin' ||
        (assignmentRole === 'contributor' && (isApproved || isOwner)) ||
        (isPublicProject && isApproved)));

  if (!canRead) {
    throw new AppError('You do not have access to this feature media', 403);
  }
};

const preauthorizePhotoUpload = async (
  req: Request,
  _res: Response,
  next: NextFunction,
): Promise<void> => {
  const { featureId } = req.params;
  const initialParent = await query('SELECT project_id FROM spatial_feature WHERE id = $1', [
    featureId,
  ]);
  if (initialParent.rows[0]?.project_id && !hasOfflineHeaders(req)) {
    await synchronizeProjectStatuses(initialParent.rows[0].project_id);
  }
  const parent = await authorizePhotoParent({ query }, req, featureId, false);
  (req as Request & { offlineOriginPhoto?: boolean }).offlineOriginPhoto = parent.collectedOffline;
  next();
};

// Upload photo(s) to feature
const uploadPhotos = async (req: Request, res: Response): Promise<void> => {
  const { featureId } = req.params;
  const files = Array.isArray(req.files) ? (req.files.slice() as MemoryPhotoFile[]) : [];

  if (files.length === 0) {
    throw attachmentRejected(req, 'No attachments were uploaded.', 400);
  }

  const initialParent = await query('SELECT project_id FROM spatial_feature WHERE id = $1', [
    featureId,
  ]);
  if (initialParent.rows[0]?.project_id && !hasOfflineHeaders(req)) {
    await synchronizeProjectStatuses(initialParent.rows[0].project_id);
  }
  const preflightParent = await authorizePhotoParent({ query }, req, featureId, false);
  if (preflightParent.offlineBinding && preflightParent.status !== 'draft') {
    const binding = preflightParent.offlineBinding;
    const existingReceipt = binding
      ? await query(
          `SELECT 1
           FROM offline_sync_receipt
           WHERE user_id = $1
             AND project_id = $2
             AND operation = 'photo_upload'
             AND idempotency_key_hash = $3
           LIMIT 1`,
          [binding.userId, binding.projectId, binding.idempotencyKeyHash],
        )
      : { rows: [] };
    if (existingReceipt.rows.length === 0) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because its parent feature is no longer editable.',
        'OFFLINE_SYNC_PARENT_INACCESSIBLE',
      );
    }
  }

  const fields = validatePhotoFields(req);
  const preparedPhotos: PreparedPhoto[] = [];
  for (const file of files) {
    // Avoid decoding up to ten maximum-size rasters concurrently.
    preparedPhotos.push(await preparePhoto(req, file));
  }
  const plannedPhotos: PlannedPhoto[] = preparedPhotos.map((photo) => {
    const photoId = randomUUID();
    return {
      ...photo,
      photoId,
      photoPath: storageAdapter.reference('uploads', `.private/feature-photos/.${photoId}.jpg`),
      thumbnailPath: storageAdapter.reference(
        'uploads',
        `.private/feature-thumbnails/.${photoId}.jpg`,
      ),
    };
  });
  const payloadHash = hashPhotoPayload(featureId, plannedPhotos, fields);
  const reservedPaths = plannedPhotos.flatMap((photo) => [photo.photoPath, photo.thumbnailPath]);
  const cleanupJobIds = await reserveFeatureMediaCleanupJobs(reservedPaths);

  let result: { photos: any[]; replayed: boolean };
  try {
    result = await transaction(async (client) =>
      withReservedFeatureMediaJobs(client, cleanupJobIds, async () => {
        const parent = await authorizePhotoParent(client, req, featureId, true);
        const binding = parent.offlineBinding;
        if (binding) {
          await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [
            `${binding.userId}:${binding.projectId}:photo_upload:${binding.idempotencyKeyHash}`,
          ]);
          const receiptResult = await client.query(
            `SELECT project_id, payload_hash, entity_ids
           FROM offline_sync_receipt
           WHERE user_id = $1
             AND project_id = $2
             AND operation = 'photo_upload'
             AND idempotency_key_hash = $3
           FOR UPDATE`,
            [binding.userId, binding.projectId, binding.idempotencyKeyHash],
          );
          const receipt = receiptResult.rows[0];
          if (receipt) {
            if (receipt.project_id !== binding.projectId || receipt.payload_hash !== payloadHash) {
              throw permanentOfflineSyncError(
                'Offline attachment idempotency key does not match the original upload.',
                'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
                409,
              );
            }
            const entityIds = Array.isArray(receipt.entity_ids)
              ? receipt.entity_ids.map(String)
              : [];
            const replayResult =
              entityIds.length === 0
                ? { rows: [] }
                : await client.query(
                    `SELECT p.id, p.file_path, p.thumbnail_path, p.display_order, p.uploaded_at
                 FROM photo p
                 WHERE p.id = ANY($1::uuid[])
                   AND p.feature_id = $2
                 ORDER BY array_position($1::uuid[], p.id)`,
                    [entityIds, featureId],
                  );
            if (replayResult.rows.length !== entityIds.length) {
              throw permanentOfflineSyncError(
                'Offline attachment receipt does not match its parent feature.',
                'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
                409,
              );
            }
            await client.query(
              `UPDATE offline_sync_receipt
             SET outcome = 'already_synchronized'
             WHERE user_id = $1
               AND project_id = $2
               AND operation = 'photo_upload'
               AND idempotency_key_hash = $3`,
              [binding.userId, binding.projectId, binding.idempotencyKeyHash],
            );
            return { photos: replayResult.rows, replayed: true };
          }
        }

        if (binding && parent.status !== 'draft') {
          throw permanentOfflineSyncError(
            'Offline submission discarded because its parent feature is no longer editable.',
            'OFFLINE_SYNC_PARENT_INACCESSIBLE',
          );
        }

        const deduplicateOfflineOrigin = parent.collectedOffline;
        const currentPhotos = deduplicateOfflineOrigin
          ? await client.query(
              `SELECT id, file_path, thumbnail_path, display_order, uploaded_at,
                    exif_data->>'source_sha256' AS source_sha256,
                    ST_X(location) AS longitude,
                    ST_Y(location) AS latitude,
                    accuracy_meters
             FROM photo
             WHERE feature_id = $1
             ORDER BY display_order, uploaded_at, id
             FOR UPDATE`,
              [featureId],
            )
          : await client.query(
              `SELECT id, file_path, thumbnail_path, display_order, uploaded_at,
                    NULL::text AS source_sha256,
                    NULL::double precision AS longitude,
                    NULL::double precision AS latitude,
                    NULL::double precision AS accuracy_meters
             FROM photo
             WHERE feature_id = $1
             ORDER BY display_order, uploaded_at, id
             FOR UPDATE`,
              [featureId],
            );
        const currentCount = currentPhotos.rows.length;
        const existingBySourceHash = new Map<string, any>();
        if (deduplicateOfflineOrigin) {
          for (const photo of currentPhotos.rows) {
            if (typeof photo.source_sha256 === 'string' && photo.source_sha256.length > 0) {
              existingBySourceHash.set(photo.source_sha256, photo);
            }
          }
        }
        const photosToInsert: PlannedPhoto[] = [];
        const requestedSourceHashes = new Set<string>();
        const nullableNumberMatches = (stored: unknown, requested: number | null): boolean =>
          stored === null || stored === undefined
            ? requested === null
            : requested !== null && Number(stored) === requested;
        for (const prepared of plannedPhotos) {
          if (deduplicateOfflineOrigin && requestedSourceHashes.has(prepared.sourceHash)) {
            continue;
          }
          requestedSourceHashes.add(prepared.sourceHash);
          const reusedPhoto = existingBySourceHash.get(prepared.sourceHash);
          if (
            deduplicateOfflineOrigin &&
            reusedPhoto &&
            (!nullableNumberMatches(reusedPhoto.latitude, fields.latitude) ||
              !nullableNumberMatches(reusedPhoto.longitude, fields.longitude) ||
              !nullableNumberMatches(reusedPhoto.accuracy_meters, fields.accuracyMeters))
          ) {
            if (binding) {
              throw permanentOfflineSyncError(
                'Offline attachment content was already synchronized with different metadata.',
                'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
                409,
              );
            }
            throw new AppError(
              'This offline-origin attachment already exists with different metadata.',
              409,
            );
          }
          if (!deduplicateOfflineOrigin || !existingBySourceHash.has(prepared.sourceHash)) {
            photosToInsert.push(prepared);
          }
        }
        if (
          !Number.isInteger(parent.maxPhotos) ||
          parent.maxPhotos < 0 ||
          currentCount + photosToInsert.length > parent.maxPhotos
        ) {
          throw attachmentRejected(
            req,
            `The attachment count exceeds this project's current limit of ${parent.maxPhotos}.`,
          );
        }

        const uploadedBySourceHash = new Map(existingBySourceHash);
        const insertedPhotos: any[] = [];
        for (let index = 0; index < photosToInsert.length; index += 1) {
          const prepared = photosToInsert[index];
          await writeNewPrivateFile(prepared.photoPath, prepared.encodedImage);
          await writeNewPrivateFile(prepared.thumbnailPath, prepared.thumbnail);

          const inserted = await client.query(
            `INSERT INTO photo (
             id, feature_id, file_path, thumbnail_path, location,
             accuracy_meters, exif_data, file_size_bytes, display_order
           ) VALUES (
             $1,
             $2,
             $3,
             $4,
             CASE
               WHEN $5::double precision IS NULL OR $6::double precision IS NULL THEN NULL
               ELSE ST_SetSRID(ST_MakePoint($6::double precision, $5::double precision), 4326)
             END,
             $7::double precision,
             $8::jsonb,
             $9,
             $10
           )
           RETURNING id, file_path, thumbnail_path, display_order, uploaded_at`,
            [
              prepared.photoId,
              featureId,
              prepared.photoPath,
              prepared.thumbnailPath,
              fields.latitude,
              fields.longitude,
              fields.accuracyMeters,
              JSON.stringify(prepared.metadata),
              prepared.encodedImage.length,
              currentCount + index + 1,
            ],
          );
          insertedPhotos.push(inserted.rows[0]);
          uploadedBySourceHash.set(prepared.sourceHash, inserted.rows[0]);
        }

        const uploadedPhotos = deduplicateOfflineOrigin
          ? [...requestedSourceHashes]
              .map((sourceHash) => uploadedBySourceHash.get(sourceHash))
              .filter(Boolean)
          : insertedPhotos;

        if (binding) {
          await client.query(
            `INSERT INTO offline_sync_receipt (
             user_id, project_id, operation, idempotency_key_hash,
             payload_hash, entity_ids, outcome
           ) VALUES ($1, $2, 'photo_upload', $3, $4, $5::uuid[], 'accepted')`,
            [
              binding.userId,
              binding.projectId,
              binding.idempotencyKeyHash,
              payloadHash,
              uploadedPhotos.map((photo) => photo.id),
            ],
          );
        }

        if (insertedPhotos.length > 0) {
          await publishRealtimeChanges(
            photoRealtimeInputs({
              projectId: parent.projectId,
              featureId,
              action: 'uploaded',
              originSessionId: req.authSessionId,
            }),
            client,
          );
        }

        return {
          photos: uploadedPhotos,
          replayed: deduplicateOfflineOrigin && photosToInsert.length === 0,
        };
      }),
    );
  } catch (error: unknown) {
    try {
      const preexistingPath = (error as { featureMediaPreexistingPath?: unknown })
        ?.featureMediaPreexistingPath;
      if (typeof preexistingPath === 'string') {
        await cancelFeatureMediaCleanupJobs([preexistingPath]);
      }
      await makeFeatureMediaCleanupJobsAvailable({ jobIds: cleanupJobIds });
      await processFeatureMediaCleanupJobs({ jobIds: cleanupJobIds });
    } catch (cleanupError: unknown) {
      logger.error('Unable to run immediate feature-photo rollback cleanup', {
        jobCount: cleanupJobIds.length,
        errorCode: String((cleanupError as { code?: unknown })?.code ?? 'CLEANUP_DEFERRED'),
      });
    }
    throw error;
  }

  logger.info('Photos uploaded:', {
    featureId,
    count: result.photos.length,
    userId: req.user.id,
    replayed: result.replayed,
  });

  res.status(result.replayed ? 200 : 201).json({
    success: true,
    message: result.replayed
      ? 'Attachments were already synchronized.'
      : `${result.photos.length} photo(s) uploaded successfully`,
    data: result.photos.map(photoResponse),
    idempotent_replay: result.replayed,
  });
};

// Get photos for a feature
const getFeaturePhotos = async (req, res) => {
  const { featureId } = req.params;

  const featureCheck = await query(
    `SELECT id, project_id, collected_by_user_id, status
     FROM spatial_feature
     WHERE id = $1`,
    [featureId],
  );

  if (featureCheck.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  const feature = featureCheck.rows[0];
  await assertPhotoFeatureReadable(req, feature);

  const result = await query(
    `SELECT id, file_path, thumbnail_path, 
            ST_X(location) as longitude, ST_Y(location) as latitude,
            accuracy_meters, taken_at, exif_data, file_size_bytes,
            status, display_order, uploaded_at
     FROM photo
     WHERE feature_id = $1
     ORDER BY display_order ASC`,
    [featureId],
  );

  res.json({
    success: true,
    data: result.rows.map(photoResponse),
  });
};

// Get single photo
const getPhoto = async (req, res) => {
  const { photoId } = req.params;
  const { thumbnail } = req.query;

  const result = await query(
    `SELECT p.file_path, p.thumbnail_path, sf.project_id,
            sf.collected_by_user_id, sf.status
     FROM photo p
     JOIN spatial_feature sf ON p.feature_id = sf.id
     WHERE p.id = $1`,
    [photoId],
  );

  if (result.rows.length === 0) {
    throw new AppError('Photo not found', 404);
  }

  const photo = result.rows[0];
  await assertPhotoFeatureReadable(req, photo);

  const filePath = resolveStoredPhotoPath(
    thumbnail === 'true' ? photo.thumbnail_path : photo.file_path,
  );
  if (!filePath) {
    logger.error('Rejected photo path outside configured storage roots', {
      photoId,
      userId: req.user.id,
    });
    throw new AppError('Photo file is unavailable', 404);
  }
  let storedPhoto: Awaited<ReturnType<typeof storageAdapter.info>>;
  let photoStream: Awaited<ReturnType<typeof storageAdapter.openReadStream>>;
  try {
    [storedPhoto, photoStream] = await Promise.all([
      storageAdapter.info(filePath, ['uploads']),
      storageAdapter.openReadStream(filePath, ['uploads']),
    ]);
  } catch (error: unknown) {
    logger.error('Photo file failed managed-storage verification', {
      photoId,
      userId: req.user.id,
      errorCode: (error as NodeJS.ErrnoException)?.code ?? 'UNSAFE_STORAGE_OBJECT',
    });
    throw new AppError('Photo file is unavailable', 404);
  }

  // Send file
  res.set({
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Type': storedPhoto.contentType ?? 'image/jpeg',
    'Content-Length': String(storedPhoto.size),
    'Content-Disposition': `inline; filename="${photoId}${thumbnail === 'true' ? '-thumbnail' : ''}.jpg"`,
  });
  await pipeline(photoStream, res);
};

// Delete photo
const deletePhoto = async (req: Request, res: Response): Promise<void> => {
  const { photoId } = req.params;
  const user = req.user as Express.UserContext;
  const photo = await transaction(async (client: QueryExecutor) => {
    const photoCheck = await client.query(
      `SELECT p.id,
              p.feature_id,
              p.file_path,
              p.thumbnail_path,
              sf.project_id,
              sf.collected_by_user_id,
              sf.collected_offline
       FROM photo p
       JOIN spatial_feature sf ON p.feature_id = sf.id
       WHERE p.id = $1
       FOR UPDATE OF p, sf`,
      [photoId],
    );
    if (photoCheck.rows.length === 0) {
      throw new AppError('Photo not found', 404);
    }

    const lockedPhoto = photoCheck.rows[0];
    if (lockedPhoto.collected_offline === true) {
      const currentRole = await assertCurrentOfflineAuthorization({
        executor: client,
        userId: user.id,
        projectId: lockedPhoto.project_id,
        allowAdmin: true,
      });
      if (currentRole !== 'admin' && lockedPhoto.collected_by_user_id !== user.id) {
        throw permanentOfflineSyncError(
          'Offline-origin feature belongs to another account.',
          'OFFLINE_SYNC_OWNER_MISMATCH',
        );
      }
    } else if (lockedPhoto.collected_by_user_id !== user.id && user.role !== 'admin') {
      throw new AppError('You can only delete photos from your own features', 403);
    }

    await client.query('DELETE FROM photo WHERE id = $1', [photoId]);
    await publishRealtimeChanges(
      photoRealtimeInputs({
        projectId: lockedPhoto.project_id,
        featureId: lockedPhoto.feature_id,
        photoId,
        action: 'deleted',
        originSessionId: req.authSessionId,
      }),
      client,
    );
    return lockedPhoto;
  });

  const storedPaths = [photo.file_path, photo.thumbnail_path].filter(
    (filePath): filePath is string => typeof filePath === 'string' && filePath.length > 0,
  );
  try {
    await makeFeatureMediaCleanupJobsAvailable({ paths: storedPaths });
    await processFeatureMediaCleanupJobs({ paths: storedPaths });
  } catch (cleanupError: unknown) {
    logger.error('Feature-photo deletion cleanup deferred', {
      photoId,
      errorCode: String((cleanupError as { code?: unknown })?.code ?? 'CLEANUP_DEFERRED'),
    });
  }

  logger.info('Photo deleted:', { photoId, userId: user.id });

  res.json({
    success: true,
    message: 'Photo deleted successfully',
  });
};

// Update photo order
const updatePhotoOrder = async (req: Request, res: Response): Promise<void> => {
  const { photoId } = req.params;
  const { display_order } = req.body;
  const user = req.user as Express.UserContext;

  if (typeof display_order !== 'number' || display_order < 0) {
    throw new AppError('Valid display order is required', 400);
  }

  await transaction(async (client: QueryExecutor) => {
    const photoCheck = await client.query(
      `SELECT p.id,
              p.feature_id,
              sf.project_id,
              sf.collected_by_user_id,
              sf.collected_offline
       FROM photo p
       JOIN spatial_feature sf ON p.feature_id = sf.id
       WHERE p.id = $1
       FOR UPDATE OF p, sf`,
      [photoId],
    );
    if (photoCheck.rows.length === 0) {
      throw new AppError('Photo not found', 404);
    }

    const lockedPhoto = photoCheck.rows[0];
    if (lockedPhoto.collected_offline === true) {
      const currentRole = await assertCurrentOfflineAuthorization({
        executor: client,
        userId: user.id,
        projectId: lockedPhoto.project_id,
        allowAdmin: true,
      });
      if (currentRole !== 'admin' && lockedPhoto.collected_by_user_id !== user.id) {
        throw permanentOfflineSyncError(
          'Offline-origin feature belongs to another account.',
          'OFFLINE_SYNC_OWNER_MISMATCH',
        );
      }
    } else if (user.role !== 'admin' && lockedPhoto.collected_by_user_id !== user.id) {
      throw new AppError('You can only update your own feature photos', 403);
    }

    await client.query('UPDATE photo SET display_order = $1 WHERE id = $2', [
      display_order,
      photoId,
    ]);
    await publishRealtimeChanges(
      photoRealtimeInputs({
        projectId: lockedPhoto.project_id,
        featureId: lockedPhoto.feature_id,
        photoId,
        action: 'reordered',
        originSessionId: req.authSessionId,
      }),
      client,
    );
  });

  res.json({
    success: true,
    message: 'Photo order updated successfully',
  });
};

module.exports = {
  preauthorizePhotoUpload,
  uploadPhotos,
  getFeaturePhotos,
  getPhoto,
  deletePhoto,
  updatePhotoOrder,
};

export {};
