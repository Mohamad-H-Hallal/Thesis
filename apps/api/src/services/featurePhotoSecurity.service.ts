import { createHash } from 'node:crypto';
import path from 'node:path';
import type { Request } from 'express';
import { assertCurrentOfflineAuthorization } from './offlineSyncSecurity.service';
import {
  requireAcceptableMalwareScan,
  scanBufferForMalware,
  type MalwareScanResult,
} from './malwareScanner.service';
import { storageAdapter } from './storageAdapter.service';
const sharp = require('sharp');
const { AppError, permanentOfflineSyncError } = require('../middleware/error');

export interface QueryExecutor {
  query: (sql: string, params?: unknown[]) => Promise<{ rows: any[]; rowCount?: number | null }>;
}

export interface OfflinePhotoBinding {
  userId: string;
  projectId: string;
  idempotencyKeyHash: string;
}

export interface AuthorizedPhotoParent {
  id: string;
  projectId: string;
  maxPhotos: number;
  collectedOffline: boolean;
  status: string;
  offlineBinding: OfflinePhotoBinding | null;
}

export interface PreparedPhoto {
  sourceHash: string;
  encodedImage: Buffer;
  thumbnail: Buffer;
  metadata: {
    width: number;
    height: number;
    format: string;
    source_sha256: string;
    malware_scan_status: 'clean' | 'skipped';
    malware_scanner: 'clamav' | 'disabled';
  };
}

export interface MemoryPhotoFile {
  buffer: Buffer;
  originalname: string;
  mimetype: string;
}

export interface PhotoMetadataFields {
  latitude: number | null;
  longitude: number | null;
  accuracyMeters: number | null;
}

const positiveIntegerSetting = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};
const MAX_IMAGE_WIDTH = positiveIntegerSetting(process.env.PHOTO_MAX_WIDTH, 10000);
const MAX_IMAGE_HEIGHT = positiveIntegerSetting(process.env.PHOTO_MAX_HEIGHT, 10000);
const MAX_IMAGE_PIXELS = positiveIntegerSetting(process.env.PHOTO_MAX_PIXELS, 40000000);
const MAX_ENCODED_SIZE = positiveIntegerSetting(process.env.PHOTO_MAX_SIZE, 5 * 1024 * 1024);
const SAFE_IDEMPOTENCY_KEY = /^[A-Za-z0-9][A-Za-z0-9._:-]{15,127}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const API_PREFIX = String(process.env.API_VERSION_PREFIX ?? '/api/v1').replace(/\/+$/, '');
const ALLOWED_PHOTO_KEY_PREFIXES = [
  'photos/',
  'thumbnails/',
  '.private/feature-photos/',
  '.private/feature-thumbnails/',
];

export const photoResponse = (row: any): any => {
  const exifData =
    row.exif_data && typeof row.exif_data === 'object' && !Array.isArray(row.exif_data)
      ? { ...row.exif_data }
      : row.exif_data;
  if (exifData && typeof exifData === 'object') {
    delete exifData.source_sha256;
    delete exifData.malware_scan_status;
    delete exifData.malware_scanner;
  }
  return {
    ...row,
    exif_data: exifData,
    file_path: `${API_PREFIX}/photos/${row.id}`,
    thumbnail_path:
      row.thumbnail_path === null || row.thumbnail_path === undefined
        ? null
        : `${API_PREFIX}/photos/${row.id}?thumbnail=true`,
  };
};

export const resolveStoredPhotoPath = (filePath: unknown): string | null => {
  if (typeof filePath !== 'string' || filePath.trim().length === 0) {
    return null;
  }
  const resolved = storageAdapter.resolve(filePath, ['uploads']);
  return resolved &&
    ALLOWED_PHOTO_KEY_PREFIXES.some((prefix) => resolved.key.startsWith(prefix))
    ? resolved.localPath
    : null;
};

export const hasOfflineHeaders = (req: Request): boolean =>
  ['x-offline-owner-id', 'x-offline-project-id', 'idempotency-key'].some((name) => {
    const value = req.headers[name];
    return typeof value === 'string' && value.trim().length > 0;
  });

const targetsOfflineOrigin = (req: Request): boolean =>
  (req as Request & { offlineOriginPhoto?: boolean }).offlineOriginPhoto === true;

export const attachmentRejected = (req: Request, message: string, statusCode = 422): Error =>
  hasOfflineHeaders(req) || targetsOfflineOrigin(req)
    ? permanentOfflineSyncError(message, 'OFFLINE_SYNC_ATTACHMENT_REJECTED', statusCode)
    : new AppError(message, statusCode);

const readSingleHeader = (req: Request, name: string): string | null => {
  const value = req.headers[name.toLowerCase()];
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
};

export const validateOfflinePhotoBinding = (
  req: Request,
  userId: string,
  projectId: string,
): OfflinePhotoBinding => {
  const ownerId = readSingleHeader(req, 'X-Offline-Owner-Id');
  const assertedProjectId = readSingleHeader(req, 'X-Offline-Project-Id');
  const idempotencyKey = readSingleHeader(req, 'Idempotency-Key');

  if (!ownerId || !UUID_PATTERN.test(ownerId) || ownerId !== userId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because it belongs to another account.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }
  if (
    !assertedProjectId ||
    !UUID_PATTERN.test(assertedProjectId) ||
    assertedProjectId !== projectId
  ) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its project does not match.',
      'OFFLINE_SYNC_PROJECT_MISMATCH',
    );
  }
  if (!idempotencyKey || !SAFE_IDEMPOTENCY_KEY.test(idempotencyKey)) {
    throw permanentOfflineSyncError(
      'Offline attachment idempotency key is invalid.',
      'OFFLINE_SYNC_ATTACHMENT_REJECTED',
      422,
    );
  }

  return {
    userId,
    projectId,
    idempotencyKeyHash: createHash('sha256').update(idempotencyKey).digest('hex'),
  };
};

export const authorizePhotoParent = async (
  executor: QueryExecutor,
  req: Request,
  featureId: string,
  lock: boolean,
): Promise<AuthorizedPhotoParent> => {
  const userId = req.user?.id;
  if (!userId) {
    throw new AppError('Not authenticated', 401);
  }

  const userResult = await executor.query(
    `SELECT id, role, is_active
     FROM "user"
     WHERE id = $1
     ${lock ? 'FOR SHARE' : ''}`,
    [userId],
  );
  const currentUser = userResult.rows[0];
  if (!currentUser || currentUser.is_active !== true) {
    if (hasOfflineHeaders(req)) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because this account is no longer active.',
        'OFFLINE_SYNC_ACCOUNT_INACTIVE',
      );
    }
    throw new AppError('User account is inactive', 401);
  }

  const featureResult = await executor.query(
    `SELECT sf.id,
            sf.project_id,
            sf.collected_by_user_id,
            sf.collected_offline,
            sf.status,
            p.status AS project_status,
            (
              p.status = 'active'
              AND (p.start_date IS NULL OR p.start_date <= CURRENT_DATE)
              AND (p.end_date IS NULL OR p.end_date > CURRENT_DATE)
            ) AS project_accepts_contributions,
            p.max_photos
     FROM spatial_feature sf
     JOIN project p ON p.id = sf.project_id
     WHERE sf.id = $1
     ${lock ? 'FOR UPDATE OF sf, p' : ''}`,
    [featureId],
  );
  const feature = featureResult.rows[0];
  if (!feature) {
    if (hasOfflineHeaders(req)) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because its parent feature is unavailable.',
        'OFFLINE_SYNC_PARENT_INACCESSIBLE',
      );
    }
    throw new AppError('Feature not found', 404);
  }

  const collectedOffline = feature.collected_offline === true;
  const hasBinding = hasOfflineHeaders(req);
  let offlineBinding: OfflinePhotoBinding | null = null;
  if (hasBinding) {
    offlineBinding = validateOfflinePhotoBinding(req, userId, feature.project_id);
    if (!collectedOffline) {
      throw permanentOfflineSyncError(
        'Offline attachment parent record is not an offline contribution.',
        'OFFLINE_SYNC_PARENT_INACCESSIBLE',
      );
    }
  }

  if (collectedOffline) {
    if (currentUser.role !== 'admin' && feature.collected_by_user_id !== userId) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because it belongs to another account.',
        'OFFLINE_SYNC_OWNER_MISMATCH',
      );
    }
    const currentRole = await assertCurrentOfflineAuthorization({
      executor,
      userId,
      projectId: feature.project_id,
      allowAdmin: !hasBinding,
    });
    if (currentRole !== 'admin' && feature.collected_by_user_id !== userId) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because it belongs to another account.',
        'OFFLINE_SYNC_OWNER_MISMATCH',
      );
    }
    if (!offlineBinding && feature.status !== 'draft') {
      throw permanentOfflineSyncError(
        'Offline submission parent record is no longer editable.',
        'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        409,
      );
    }
  } else if (currentUser.role !== 'admin') {
    if (feature.collected_by_user_id !== userId) {
      throw new AppError('You can only add photos to your own features', 403);
    }
    if (currentUser.role !== 'contributor') {
      throw new AppError('Your current role cannot upload feature photos', 403);
    }
    if (feature.project_accepts_contributions !== true) {
      throw new AppError('This project is no longer accepting contributions', 403);
    }
    const assignmentResult = await executor.query(
      `SELECT role, status
       FROM project_assignment
       WHERE project_id = $1 AND user_id = $2
       ${lock ? 'FOR SHARE' : ''}`,
      [feature.project_id, userId],
    );
    const assignment = assignmentResult.rows[0];
    if (!assignment || assignment.status !== 'approved' || assignment.role !== 'contributor') {
      throw new AppError('You no longer have permission to upload photos to this project', 403);
    }
  }

  return {
    id: feature.id,
    projectId: feature.project_id,
    maxPhotos: Number(feature.max_photos),
    collectedOffline,
    status: feature.status,
    offlineBinding,
  };
};

const expectedFormatFor = (file: MemoryPhotoFile): 'jpeg' | 'png' | 'heif' | null => {
  const extension = path.extname(file.originalname).toLowerCase();
  const mime = file.mimetype.toLowerCase();
  if ((extension === '.jpg' || extension === '.jpeg') && mime === 'image/jpeg') {
    return 'jpeg';
  }
  if (extension === '.png' && mime === 'image/png') {
    return 'png';
  }
  if (
    (extension === '.heic' || extension === '.heif') &&
    (mime === 'image/heic' || mime === 'image/heif')
  ) {
    return 'heif';
  }
  return null;
};

export const preparePhoto = async (
  req: Request,
  file: MemoryPhotoFile,
  completedMalwareScan?: MalwareScanResult,
): Promise<PreparedPhoto> => {
  if (!Buffer.isBuffer(file.buffer) || file.buffer.length === 0) {
    throw attachmentRejected(req, 'The attachment is empty or unreadable.');
  }

  const expectedFormat = expectedFormatFor(file);
  if (!expectedFormat) {
    throw attachmentRejected(req, 'The attachment filename and declared image type do not match.');
  }

  const malwareScan = completedMalwareScan ?? (await scanBufferForMalware(file.buffer));
  requireAcceptableMalwareScan(malwareScan);

  try {
    const inputOptions = {
      failOn: 'error' as const,
      limitInputPixels: MAX_IMAGE_PIXELS,
      animated: false,
    };
    const metadata = await sharp(file.buffer, inputOptions).metadata();
    const width = Number(metadata.width);
    const height = Number(metadata.height);
    const pages = Number(metadata.pages ?? 1);
    if (
      metadata.format !== expectedFormat ||
      !Number.isInteger(width) ||
      !Number.isInteger(height) ||
      width < 1 ||
      height < 1 ||
      width > MAX_IMAGE_WIDTH ||
      height > MAX_IMAGE_HEIGHT ||
      width * height > MAX_IMAGE_PIXELS ||
      pages !== 1
    ) {
      throw attachmentRejected(
        req,
        'The attachment signature, dimensions, or image structure is not allowed.',
      );
    }

    const encodedImage = await sharp(file.buffer, inputOptions)
      .rotate()
      .flatten({ background: '#ffffff' })
      .jpeg({ quality: 90, mozjpeg: true })
      .toBuffer();
    if (encodedImage.length === 0 || encodedImage.length > MAX_ENCODED_SIZE) {
      throw attachmentRejected(req, 'The normalized attachment exceeds the allowed file size.');
    }
    const thumbnail = await sharp(encodedImage, {
      failOn: 'error',
      limitInputPixels: MAX_IMAGE_PIXELS,
    })
      .resize(300, 300, { fit: 'cover', position: 'center' })
      .jpeg({ quality: 80, mozjpeg: true })
      .toBuffer();
    const sourceHash = createHash('sha256').update(file.buffer).digest('hex');

    return {
      sourceHash,
      encodedImage,
      thumbnail,
      metadata: {
        width,
        height,
        format: expectedFormat,
        source_sha256: sourceHash,
        malware_scan_status: malwareScan.status as 'clean' | 'skipped',
        malware_scanner: malwareScan.scanner,
      },
    };
  } catch (error: unknown) {
    if (error instanceof AppError) {
      throw error;
    }
    throw attachmentRejected(req, 'The attachment is not a valid supported raster image.');
  }
};

const parseOptionalNumber = (
  req: Request,
  field: string,
  min: number,
  max: number,
): number | null => {
  const value = req.body?.[field];
  if (value === undefined) {
    return null;
  }
  if (typeof value !== 'string' || value.length === 0 || value.length > 32) {
    throw attachmentRejected(req, `Attachment ${field} is invalid.`);
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    throw attachmentRejected(req, `Attachment ${field} is outside its allowed range.`);
  }
  return parsed;
};

export const validatePhotoFields = (req: Request): PhotoMetadataFields => {
  const allowedFields = new Set(['latitude', 'longitude', 'accuracy_meters']);
  const body = req.body;
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw attachmentRejected(req, 'Attachment metadata must be a flat object.');
  }
  if (Object.keys(body).some((key) => !allowedFields.has(key))) {
    throw attachmentRejected(req, 'Unknown attachment metadata fields are not allowed.');
  }

  const latitude = parseOptionalNumber(req, 'latitude', -90, 90);
  const longitude = parseOptionalNumber(req, 'longitude', -180, 180);
  const accuracyMeters = parseOptionalNumber(req, 'accuracy_meters', 0, 100000);
  if ((latitude === null) !== (longitude === null)) {
    throw attachmentRejected(req, 'Attachment latitude and longitude must be supplied together.');
  }
  return { latitude, longitude, accuracyMeters };
};

export const hashPhotoPayload = (
  featureId: string,
  photos: PreparedPhoto[],
  fields: PhotoMetadataFields,
): string =>
  createHash('sha256')
    .update(
      JSON.stringify({
        feature_id: featureId,
        latitude: fields.latitude,
        longitude: fields.longitude,
        accuracy_meters: fields.accuracyMeters,
        photos: photos.map((photo) => photo.sourceHash),
      }),
    )
    .digest('hex');

export const writeNewPrivateFile = async (filePath: string, contents: Buffer): Promise<void> => {
  try {
    const resolved = storageAdapter.resolve(filePath, ['uploads']);
    if (
      !resolved ||
      !['.private/feature-photos/', '.private/feature-thumbnails/'].some((prefix) =>
        resolved.key.startsWith(prefix),
      )
    ) {
      throw new Error('Refusing to write outside private feature-media storage.');
    }
    await storageAdapter.writeExclusive(resolved.reference, contents);
  } catch (error: unknown) {
    if ((error as { code?: string }).code === 'EEXIST' && error && typeof error === 'object') {
      (error as { featureMediaPreexistingPath?: string }).featureMediaPreexistingPath = filePath;
    }
    throw error;
  }
};
