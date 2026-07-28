import multer, { type FileFilterCallback } from 'multer';
import path from 'node:path';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { AppError, permanentOfflineSyncError } from '../middleware/error';

const positiveIntegerSetting = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};
const hasUnsafeFilenameCodePoint = (value: string): boolean =>
  Array.from(value).some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return (
      codePoint <= 0x1f ||
      codePoint === 0x7f ||
      (codePoint >= 0xfdd0 && codePoint <= 0xfdef) ||
      (codePoint & 0xffff) === 0xfffe ||
      (codePoint & 0xffff) === 0xffff ||
      codePoint === 0xfffd
    );
  });
const hasUnsafeUploadName = (originalName: string): boolean =>
  originalName.length === 0 ||
  Buffer.byteLength(originalName, 'utf8') > 255 ||
  hasUnsafeFilenameCodePoint(originalName) ||
  originalName.includes('/') ||
  originalName.includes('\\') ||
  path.basename(originalName) !== originalName;

// Ensure upload directories exist
const uploadDir = process.env.UPLOAD_DIR ?? './uploads';
const photosDir = path.join(uploadDir, 'photos');
const thumbnailsDir = path.join(uploadDir, 'thumbnails');
// Existing AI evidence remains readable from this compatibility directory.
const aiValidationPhotosDir = path.join(uploadDir, 'ai-validation');
// Feature photos are read through authenticated API routes. The controller
// stores them here with dot-prefixed generated names so the app's generic
// `/uploads` static mount will not serve them directly.
const privateFeaturePhotosDir = path.join(uploadDir, '.private', 'feature-photos');
const privateFeatureThumbnailsDir = path.join(uploadDir, '.private', 'feature-thumbnails');
const privateAiValidationPhotosDir = path.join(uploadDir, '.private', 'ai-validation');
const privateImportsDir = path.join(uploadDir, '.private', 'imports');
const quarantineImportsDir = path.join(uploadDir, '.quarantine', 'imports');
const quarantineImagesDir = path.join(uploadDir, '.quarantine', 'images');
const categoryIconsDir = path.join(uploadDir, 'category-icons');
const importsDir = path.join(uploadDir, 'imports');

[
  uploadDir,
  photosDir,
  thumbnailsDir,
  aiValidationPhotosDir,
  privateFeaturePhotosDir,
  privateFeatureThumbnailsDir,
  privateAiValidationPhotosDir,
  privateImportsDir,
  quarantineImportsDir,
  quarantineImagesDir,
  categoryIconsDir,
  importsDir,
].forEach((dir) => {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
});

// File filter
const fileFilter = (
  _req: Request,
  file: { originalname: string; mimetype: string },
  cb: FileFilterCallback,
): void => {
  // Accept only images
  const originalName = file.originalname ?? '';
  const extension = path.extname(originalName).toLowerCase();
  const stem = originalName.slice(0, Math.max(0, originalName.length - extension.length));
  const allowedTypes = /jpeg|jpg|png|heic|heif/;
  const extname = allowedTypes.test(extension);
  const mimetype = allowedTypes.test(file.mimetype);

  if (!hasUnsafeUploadName(originalName) && stem.length > 0 && !stem.includes('.') && mimetype && extname) {
    cb(null, true);
    return;
  }
  cb(new Error('Only image files are allowed (jpeg, jpg, png, heic, heif)'));
};

// Multer configuration
const upload = multer({
  // Hold images outside the webroot until the controller has completed
  // authorization, signature validation, normalization, and malware scanning.
  storage: multer.memoryStorage(),
  limits: {
    fileSize: positiveIntegerSetting(process.env.PHOTO_MAX_SIZE, 5242880), // 5MB default
  },
  fileFilter: fileFilter,
});

// Single photo upload
const uploadSingleMiddleware = upload.single('photo');

// Multiple photos upload (max 10)
const uploadMultipleMiddleware = upload.array('photos', 10);

const featurePhotoMimeTypes = new Set(['image/jpeg', 'image/png', 'image/heic', 'image/heif']);
const featurePhotoExtensions = new Set(['.jpg', '.jpeg', '.png', '.heic', '.heif']);
const FEATURE_PHOTO_MAX_COUNT = 10;
const OFFLINE_BUNDLE_PAYLOAD_MAX_SIZE = 256 * 1024;
const isOfflineMultipartRequest = (req: Request): boolean => {
  const owner = req.headers['x-offline-owner-id'];
  const project = req.headers['x-offline-project-id'];
  const key = req.headers['idempotency-key'];
  return (
    (req as Request & { offlineOriginPhoto?: boolean }).offlineOriginPhoto === true ||
    [owner, project, key].some((value) => typeof value === 'string' && value.trim().length > 0)
  );
};

const featurePhotoFileFilter =
  (alwaysPermanent: boolean) =>
  (
    req: Request,
    file: { originalname: string; mimetype: string },
    cb: FileFilterCallback,
  ): void => {
    const originalName = file.originalname ?? '';
    const byteLength = Buffer.byteLength(originalName, 'utf8');
    const extension = path.extname(originalName).toLowerCase();
    const stem = originalName.slice(0, Math.max(0, originalName.length - extension.length));
    const hasUnsafeName =
      originalName.length === 0 ||
      byteLength > 255 ||
      hasUnsafeFilenameCodePoint(originalName) ||
      originalName.includes('/') ||
      originalName.includes('\\') ||
      path.basename(originalName) !== originalName ||
      stem.length === 0 ||
      stem.includes('.');
    const declaredMime = (file.mimetype ?? '').toLowerCase();

    if (
      !hasUnsafeName &&
      featurePhotoExtensions.has(extension) &&
      featurePhotoMimeTypes.has(declaredMime)
    ) {
      cb(null, true);
      return;
    }

    const message = 'The attachment filename or declared image type is not allowed.';
    cb(
      alwaysPermanent || isOfflineMultipartRequest(req)
        ? permanentOfflineSyncError(message, 'OFFLINE_SYNC_ATTACHMENT_REJECTED', 422)
        : new AppError(message, 422),
    );
  };

const featurePhotoUpload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: positiveIntegerSetting(process.env.PHOTO_MAX_SIZE, 5242880),
    files: FEATURE_PHOTO_MAX_COUNT,
    fields: 3,
    fieldSize: 128,
    parts: 13,
    headerPairs: 100,
  },
  fileFilter: featurePhotoFileFilter(false),
}).array('photos', FEATURE_PHOTO_MAX_COUNT);

const offlineFeatureBundleUpload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: positiveIntegerSetting(process.env.PHOTO_MAX_SIZE, 5242880),
    files: FEATURE_PHOTO_MAX_COUNT,
    fields: 1,
    fieldSize: OFFLINE_BUNDLE_PAYLOAD_MAX_SIZE,
    // One extra part lets Multer report a precise file/field count error
    // before the broader aggregate part limit is reached.
    parts: FEATURE_PHOTO_MAX_COUNT + 2,
    headerPairs: 100,
  },
  fileFilter: featurePhotoFileFilter(true),
}).array('photos', FEATURE_PHOTO_MAX_COUNT);

type MultipartUpload = (req: Request, res: Response, callback: (error?: unknown) => void) => void;

const multipartError = (
  req: Request,
  error: unknown,
  alwaysPermanent: boolean,
  payloadAware: boolean,
): Error => {
  if (error instanceof AppError) {
    return error;
  }

  const uploadError = error as { code?: string; message?: string };
  const interruptionCode = String(uploadError.code ?? '').toUpperCase();
  const interruptionMessage = String(uploadError.message ?? '');
  if (
    ['ECONNABORTED', 'ECONNRESET', 'EPIPE', 'ERR_STREAM_PREMATURE_CLOSE'].includes(
      interruptionCode,
    ) ||
    /unexpected end|request aborted|premature close|socket hang up/i.test(interruptionMessage)
  ) {
    return new AppError('Offline attachment upload was interrupted. Please retry.', 503, {
      code: 'OFFLINE_SYNC_TEMPORARY_FAILURE',
      disposition: 'retry',
      retryable: true,
    });
  }
  const isAttachmentError =
    uploadError.code === 'LIMIT_FILE_SIZE' ||
    uploadError.code === 'LIMIT_FILE_COUNT' ||
    uploadError.code === 'LIMIT_UNEXPECTED_FILE';
  const message =
    uploadError.code === 'LIMIT_FILE_SIZE'
      ? 'An attachment exceeds the allowed file size.'
      : uploadError.code === 'LIMIT_FILE_COUNT' || uploadError.code === 'LIMIT_UNEXPECTED_FILE'
        ? 'Too many attachments were supplied.'
        : payloadAware
          ? 'The offline bundle payload is malformed or exceeds its limits.'
          : 'The multipart attachment request is malformed or exceeds its limits.';

  if (alwaysPermanent || isOfflineMultipartRequest(req)) {
    return permanentOfflineSyncError(
      message,
      payloadAware && !isAttachmentError
        ? 'OFFLINE_SYNC_PAYLOAD_REJECTED'
        : 'OFFLINE_SYNC_ATTACHMENT_REJECTED',
      422,
    );
  }
  return new AppError(message, 422);
};

const runMultipartUpload = (
  uploadMiddleware: MultipartUpload,
  req: Request,
  res: Response,
  next: NextFunction,
  options: { alwaysPermanent: boolean; payloadAware: boolean },
  onSuccess?: () => void,
): void => {
  uploadMiddleware(req, res, (error: unknown) => {
    if (error) {
      next(multipartError(req, error, options.alwaysPermanent, options.payloadAware));
      return;
    }
    if (onSuccess) {
      onSuccess();
      return;
    }
    next();
  });
};

const uploadFeaturePhotos = (req: Request, res: Response, next: NextFunction): void => {
  runMultipartUpload(featurePhotoUpload, req, res, next, {
    alwaysPermanent: false,
    payloadAware: false,
  });
};

const uploadOfflineFeatureBundle = (req: Request, res: Response, next: NextFunction): void => {
  runMultipartUpload(
    offlineFeatureBundleUpload,
    req,
    res,
    next,
    { alwaysPermanent: true, payloadAware: true },
    () => {
      const body = req.body;
      const payload = body?.payload;
      if (
        !body ||
        typeof body !== 'object' ||
        Array.isArray(body) ||
        Object.keys(body).length !== 1 ||
        typeof payload !== 'string' ||
        payload.length === 0 ||
        Buffer.byteLength(payload, 'utf8') > OFFLINE_BUNDLE_PAYLOAD_MAX_SIZE
      ) {
        next(
          permanentOfflineSyncError(
            'The offline bundle must contain exactly one valid payload field.',
            'OFFLINE_SYNC_PAYLOAD_REJECTED',
            422,
          ),
        );
        return;
      }

      try {
        const parsed = JSON.parse(payload);
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
          throw new SyntaxError('Offline bundle payload must be a JSON object.');
        }
      } catch {
        next(
          permanentOfflineSyncError(
            'The offline bundle payload must be a valid JSON object.',
            'OFFLINE_SYNC_PAYLOAD_REJECTED',
            422,
          ),
        );
        return;
      }
      next();
    },
  );
};

const uploadSingle = (req: Request, res: Response, next: NextFunction): void => {
  runMultipartUpload(uploadSingleMiddleware, req, res, next, {
    alwaysPermanent: false,
    payloadAware: false,
  });
};

const uploadMultiple = (req: Request, res: Response, next: NextFunction): void => {
  runMultipartUpload(uploadMultipleMiddleware, req, res, next, {
    alwaysPermanent: false,
    payloadAware: false,
  });
};

const categoryIconUpload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: positiveIntegerSetting(process.env.CATEGORY_ICON_MAX_SIZE, 3145728),
  },
  fileFilter: fileFilter,
}).single('icon');

const uploadCategoryIcon = (req: Request, res: Response, next: NextFunction): void => {
  runMultipartUpload(categoryIconUpload, req, res, next, {
    alwaysPermanent: false,
    payloadAware: false,
  });
};

const importStorage = multer.diskStorage({
  destination: (_req, _file, cb) => {
    cb(null, quarantineImportsDir);
  },
  filename: (_req, file, cb) => {
    const uniqueName = `${randomUUID()}${path.extname(file.originalname)}`;
    cb(null, uniqueName);
  },
});

const importFileFilter = (
  _req: Request,
  file: { originalname: string; mimetype: string },
  cb: FileFilterCallback,
): void => {
  const ext = path.extname(file.originalname).toLowerCase();
  const allowedExt = new Set(['.geojson', '.json', '.zip', '.kml', '.kmz', '.csv', '.xlsx']);
  if (!hasUnsafeUploadName(file.originalname) && allowedExt.has(ext)) {
    cb(null, true);
    return;
  }
  cb(
    new Error(
      'Only GeoJSON, zipped shapefile, KML, KMZ, CSV, and Excel .xlsx files are allowed for GIS imports',
    ),
  );
};

const importFileUpload = multer({
  storage: importStorage,
  limits: {
    fileSize: positiveIntegerSetting(process.env.IMPORT_MAX_SIZE, 26214400),
  },
  fileFilter: importFileFilter,
}).single('file');

const uploadImportFile = (req: Request, res: Response, next: NextFunction): void => {
  runMultipartUpload(importFileUpload, req, res, next, {
    alwaysPermanent: false,
    payloadAware: false,
  });
};

export {
  uploadSingle,
  uploadMultiple,
  uploadFeaturePhotos,
  uploadOfflineFeatureBundle,
  uploadCategoryIcon,
  uploadImportFile,
  photosDir,
  thumbnailsDir,
  aiValidationPhotosDir,
  privateFeaturePhotosDir,
  privateFeatureThumbnailsDir,
  privateAiValidationPhotosDir,
  privateImportsDir,
  quarantineImportsDir,
  quarantineImagesDir,
  categoryIconsDir,
  importsDir,
  multipartError as classifyMultipartUploadError,
};
