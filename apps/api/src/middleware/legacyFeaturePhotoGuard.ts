import type { NextFunction, Request, Response } from 'express';
import { query } from '../config/database';

const safeStorageName =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:jpe?g|png|gif|hei[cf]s?)$/i;

const guardLegacyFeaturePhotoDirectory =
  (directory: 'photos' | 'thumbnails') =>
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const requestedName = req.path.replace(/^\/+/, '');
      if (
        !safeStorageName.test(requestedName) ||
        requestedName.includes('/') ||
        requestedName.includes('\\')
      ) {
        res.status(404).end();
        return;
      }

      if (directory === 'thumbnails') {
        res.status(404).end();
        return;
      }

      const aiEvidence = await query(
        `SELECT 1
         FROM legacy_ai_validation_media_snapshot
         WHERE storage_name = $1
         LIMIT 1`,
        [requestedName],
      );
      if (aiEvidence.rows.length === 0) {
        // Deny by default. A missing feature-photo row (for example after a
        // cascade or failed unlink) must never turn an orphan into public media.
        res.status(404).end();
        return;
      }
      next();
    } catch (error: unknown) {
      // Fail closed: a database outage must not make private legacy feature
      // media publicly reachable through the compatibility static mount.
      next(error);
    }
  };

export { guardLegacyFeaturePhotoDirectory };
