import fs from 'node:fs/promises';
import path from 'node:path';
import type { Request, Response } from 'express';
import { query } from '../config/database';
import {
  aiValidationPhotosDir,
  photosDir,
} from '../config/upload';
import { publicVisibleStatuses, synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { AppError } from '../middleware/error';

type PrivateMediaDirectory = 'ai-validation' | 'photos';

const safeStorageName =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:jpe?g|png|gif|hei[cf]s?)$/i;

const mediaRoot = (directory: PrivateMediaDirectory): string =>
  path.resolve(directory === 'ai-validation' ? aiValidationPhotosDir : photosDir);

const referencedProjectIds = async (
  directory: PrivateMediaDirectory,
  storageName: string,
): Promise<string[]> => {
  if (directory === 'photos') {
    const snapshot = await query(
      `SELECT 1
       FROM legacy_ai_validation_media_snapshot
       WHERE storage_name = $1
       LIMIT 1`,
      [storageName],
    );
    if (snapshot.rows.length === 0) {
      return [];
    }
  }

  const urls = [
    `/uploads/${directory}/${storageName}`,
    `uploads/${directory}/${storageName}`,
  ];
  const result = await query(
    `WITH referenced_project AS (
       SELECT validation.project_id
       FROM ai_prediction_feature_validation AS validation
       CROSS JOIN LATERAL
         jsonb_array_elements_text(validation.photo_media_ids) AS media(media_url)
       WHERE media.media_url = ANY($1::text[])

       UNION

       SELECT task.project_id
       FROM ai_prediction_validation_submission AS submission
       JOIN ai_prediction_validation_task AS task
         ON task.id = submission.validation_task_id
       CROSS JOIN LATERAL jsonb_array_elements_text(
         CASE
           WHEN jsonb_typeof(submission.evidence->'photo_media_ids') = 'array'
             THEN submission.evidence->'photo_media_ids'
           WHEN jsonb_typeof(submission.evidence->'photos') = 'array'
             THEN submission.evidence->'photos'
           ELSE '[]'::jsonb
         END
       ) AS media(media_url)
       WHERE media.media_url = ANY($1::text[])
     )
     SELECT DISTINCT project_id
     FROM referenced_project`,
    [urls],
  );
  return result.rows
    .map((row: { project_id?: unknown }) => String(row.project_id ?? '').trim())
    .filter(Boolean);
};

const canReadAnyProject = async (req: Request, projectIds: string[]): Promise<boolean> => {
  const user = req.user as Express.UserContext;
  if (user.role === 'admin') {
    return true;
  }

  for (const projectId of projectIds) {
    await synchronizeProjectStatuses(projectId);
  }

  const result = await query(
    `SELECT EXISTS (
       SELECT 1
       FROM project AS project
       WHERE project.id = ANY($1::uuid[])
         AND (
           (
             $3::text = 'viewer'
             AND project.visible_to_viewers = TRUE
             AND project.status::text = ANY($4::text[])
           )
           OR
           (
             $3::text = 'contributor'
             AND (
               (
                 project.visible_to_contributors = TRUE
                 AND project.status::text = ANY($4::text[])
               )
               OR EXISTS (
                 SELECT 1
                 FROM project_assignment AS assignment
                 WHERE assignment.project_id = project.id
                   AND assignment.user_id = $2
                   AND assignment.status = 'approved'
               )
             )
           )
         )
     ) AS can_read`,
    [projectIds, user.id, user.role, publicVisibleStatuses],
  );
  return result.rows[0]?.can_read === true;
};

const servePrivateMedia = async (
  req: Request,
  res: Response,
  directory: PrivateMediaDirectory,
): Promise<void> => {
  const storageName = String(req.params.storageName ?? '');
  if (
    !safeStorageName.test(storageName) ||
    storageName.includes('/') ||
    storageName.includes('\\')
  ) {
    throw new AppError('Media file not found', 404);
  }

  const projectIds = await referencedProjectIds(directory, storageName);
  if (projectIds.length === 0) {
    throw new AppError('Media file not found', 404);
  }
  if (!(await canReadAnyProject(req, projectIds))) {
    throw new AppError('You do not have access to this media', 403);
  }

  const root = mediaRoot(directory);
  const filePath = path.resolve(root, storageName);
  if (path.dirname(filePath) !== root) {
    throw new AppError('Media file not found', 404);
  }
  try {
    const stat = await fs.stat(filePath);
    if (!stat.isFile()) {
      throw new AppError('Media file not found', 404);
    }
  } catch (error: unknown) {
    if (error instanceof AppError) {
      throw error;
    }
    if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
      throw new AppError('Media file not found', 404);
    }
    throw error;
  }

  res.set({
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Disposition': `inline; filename="${storageName}"`,
  });
  res.sendFile(filePath, { dotfiles: 'deny' });
};

const getAiValidationMedia = async (req: Request, res: Response): Promise<void> =>
  servePrivateMedia(req, res, 'ai-validation');

const getLegacyAiValidationMedia = async (req: Request, res: Response): Promise<void> =>
  servePrivateMedia(req, res, 'photos');

export { getAiValidationMedia, getLegacyAiValidationMedia };
