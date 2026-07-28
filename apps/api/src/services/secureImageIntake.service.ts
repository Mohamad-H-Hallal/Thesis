import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import type { Request } from 'express';
import { transaction } from '../config/database';
import { quarantineImagesDir } from '../config/upload';
import {
  preparePhoto,
  type MemoryPhotoFile,
  type PreparedPhoto,
} from './featurePhotoSecurity.service';
import {
  requireAcceptableMalwareScan,
  scanBufferForMalware,
} from './malwareScanner.service';
import {
  keepUploadQuarantined,
  recordContentInspection,
  recordMalwareScan,
  recordQuarantinedUpload,
  releaseQuarantinedUpload,
} from './uploadQuarantine.service';
import {
  releaseNormalizedJpeg,
  removeReleasedImages,
  type ReleasedImage,
} from './secureImageStorage.service';
const logger = require('../utils/logger');

type SecureImageKind = 'ai_validation_photo' | 'category_icon';

interface QuarantinedPreparedImage {
  quarantineId: string;
  quarantinePath: string;
  originalFilename: string;
  prepared: PreparedPhoto;
}

interface PrepareQuarantinedImageOptions {
  kind: SecureImageKind;
  uploadedByUserId: string;
  projectId?: string | null;
}

interface ReleasedQuarantinedImage extends ReleasedImage {
  quarantineId: string;
  originalFilename: string;
}

const keepPreparedImagesQuarantined = async (
  images: QuarantinedPreparedImage[],
  reasonCode: string,
): Promise<void> => {
  const updates = await Promise.allSettled(
    images.map((image) => keepUploadQuarantined(image.quarantineId, reasonCode)),
  );
  updates.forEach((result, index) => {
    if (result.status === 'rejected') {
      logger.error('Failed to record an image quarantine disposition', {
        quarantineId: images[index]?.quarantineId,
        reasonCode,
      });
    }
  });
};

const rejectionCode = (error: unknown): string => {
  const candidate = error as { errorCode?: unknown };
  return typeof candidate.errorCode === 'string'
    ? candidate.errorCode
    : 'UPLOAD_IMAGE_CONTENT_REJECTED';
};

const prepareQuarantinedImage = async (
  req: Request,
  file: MemoryPhotoFile,
  options: PrepareQuarantinedImageOptions,
): Promise<QuarantinedPreparedImage> => {
  const quarantinePath = path.resolve(quarantineImagesDir, `${randomUUID()}.raw`);
  await fs.writeFile(quarantinePath, file.buffer, { flag: 'wx', mode: 0o600 });

  let quarantineId: string;
  try {
    quarantineId = await recordQuarantinedUpload({
      uploadKind: options.kind,
      storagePath: quarantinePath,
      originalFilename: file.originalname,
      uploadedByUserId: options.uploadedByUserId,
      projectId: options.projectId,
      fileSizeBytes: file.buffer.length,
      checksumSha256: createHash('sha256').update(file.buffer).digest('hex'),
      metadata: {
        declared_mime_type: file.mimetype,
      },
    });
  } catch (error) {
    await fs.rm(quarantinePath, { force: true });
    throw error;
  }

  try {
    const scan = await scanBufferForMalware(file.buffer);
    await recordMalwareScan(quarantineId, scan);
    requireAcceptableMalwareScan(scan);
    const prepared = await preparePhoto(req, file, scan);
    await recordContentInspection({
      quarantineId,
      detectedType: `image/${prepared.metadata.format}`,
      metadata: {
        image_width: prepared.metadata.width,
        image_height: prepared.metadata.height,
        normalized_mime_type: 'image/jpeg',
        normalized_size_bytes: prepared.encodedImage.length,
      },
    });
    return {
      quarantineId,
      quarantinePath,
      originalFilename: file.originalname,
      prepared,
    };
  } catch (error) {
    await keepUploadQuarantined(quarantineId, rejectionCode(error));
    throw error;
  }
};

const releaseQuarantinedImages = async (
  images: QuarantinedPreparedImage[],
  destinationDirectory: string,
): Promise<ReleasedQuarantinedImage[]> => {
  const released: ReleasedQuarantinedImage[] = [];
  try {
    for (const image of images) {
      const stored = await releaseNormalizedJpeg(
        image.prepared.encodedImage,
        destinationDirectory,
      );
      released.push({
        ...stored,
        quarantineId: image.quarantineId,
        originalFilename: image.originalFilename,
      });
    }

    await transaction(async (client) => {
      for (const image of released) {
        await releaseQuarantinedUpload({
          executor: client,
          quarantineId: image.quarantineId,
          releasedPath: image.storageReference,
        });
      }
    });
  } catch (error) {
    try {
      await removeReleasedImages(released.map((image) => image.filePath));
    } catch (cleanupError: unknown) {
      logger.error('Failed to remove an image after its quarantine release rolled back', {
        errorCode: (cleanupError as NodeJS.ErrnoException)?.code ?? 'UNKNOWN',
      });
    }
    await keepPreparedImagesQuarantined(images, 'UPLOAD_RELEASE_FAILED');
    throw error;
  }

  for (const image of images) {
    try {
      await fs.rm(image.quarantinePath, { force: true });
    } catch (error: unknown) {
      logger.warn('A released image source remains in private quarantine', {
        quarantineId: image.quarantineId,
        errorCode: (error as NodeJS.ErrnoException)?.code ?? 'UNKNOWN',
      });
    }
  }
  return released;
};

export {
  keepPreparedImagesQuarantined,
  prepareQuarantinedImage,
  releaseQuarantinedImages,
  type QuarantinedPreparedImage,
  type ReleasedQuarantinedImage,
};
