import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import type { NextFunction, Request, Response } from 'express';

const { query, transaction } = require('../config/database');
const { privateFeaturePhotosDir, privateFeatureThumbnailsDir } = require('../config/upload');
const { offlineSyncConflictError, permanentOfflineSyncError } = require('../middleware/error');
const logger = require('../utils/logger');

import {
  attachmentRejected,
  preparePhoto,
  writeNewPrivateFile,
  type MemoryPhotoFile,
  type PreparedPhoto,
} from '../services/featurePhotoSecurity.service';
import {
  cancelFeatureMediaCleanupJobs,
  makeFeatureMediaCleanupJobsAvailable,
  processFeatureMediaCleanupJobs,
  reserveFeatureMediaCleanupJobs,
  withReservedFeatureMediaJobs,
} from '../services/featureMediaCleanup.service';
import {
  UUID_PATTERN,
  assertCurrentOfflineAuthorization,
  assertGeometryAcceptedByPostgis,
  assertMatchingOfflineReceipt,
  assertOfflineCollectionConstraints,
  assertOfflinePayloadSize,
  assertOfflineRequestBinding,
  assertOnlyAllowedKeys,
  assertPlainObject,
  assertSafeOfflineJson,
  getOfflineReceipt,
  insertOfflineReceipt,
  lockOfflineFeatureIds,
  offlinePayloadRejected,
  sha256Json,
  validateAttributesAgainstSchema,
  validateGeoJsonGeometry,
  type GeoJsonGeometry,
  type QueryExecutor,
} from '../services/offlineSyncSecurity.service';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import type { RealtimePublishInput } from '../realtime/realtimeProtocol';

const offlineBundleRealtimeInputs = ({
  projectId,
  featureId,
  action,
  submitted,
  originSessionId,
}: {
  projectId: string;
  featureId: string;
  action: string;
  submitted: boolean;
  originSessionId?: string | null;
}): RealtimePublishInput[] => [
  {
    scopeType: 'features',
    scopeId: projectId,
    action,
    entityType: 'feature',
    entityId: featureId,
    projectId,
    originSessionId,
    audience: { kind: 'project', projectId, access: 'readers' },
  },
  {
    scopeType: 'feature',
    scopeId: featureId,
    action,
    entityType: 'feature',
    entityId: featureId,
    projectId,
    originSessionId,
    audience: { kind: 'project', projectId, access: 'readers' },
  },
  ...(submitted
    ? [
        {
          scopeType: 'reviews',
          scopeId: projectId,
          action: 'submitted',
          entityType: 'feature',
          entityId: featureId,
          projectId,
          originSessionId,
          audience: { kind: 'project' as const, projectId, access: 'members' as const },
        },
        {
          scopeType: 'reviews',
          scopeId: 'all',
          action: 'submitted',
          entityType: 'feature',
          entityId: featureId,
          projectId,
          originSessionId,
          audience: { kind: 'admins' as const },
        },
      ]
    : []),
];

type OfflineBundleOperation = 'create' | 'update';

interface OfflineBundlePayload {
  draftId: string;
  ownerUserId: string;
  projectId: string;
  operation: OfflineBundleOperation;
  geometry: GeoJsonGeometry;
  attributes: Record<string, unknown>;
  accuracyMeters: number | null;
  submitForReview: boolean;
  expectedVersion: number | null;
}

interface ProjectCollectionPolicy {
  name: string;
  schema: Record<string, unknown>;
  requiresPhotos: boolean;
  minPhotos: number;
  maxPhotos: number;
}

interface BundleOutcome {
  row: {
    id: string;
    status: string;
    version: number;
    geometry: string;
    attributes: Record<string, unknown>;
  };
  alreadySynchronized: boolean;
}

interface PlannedPhoto extends PreparedPhoto {
  photoId: string;
  photoPath: string;
  thumbnailPath: string;
}

const OFFLINE_BUNDLE_KEYS = new Set([
  'draft_id',
  'offline_owner_user_id',
  'project_id',
  'operation',
  'geom',
  'attributes',
  'accuracy_meters',
  'submit_for_review',
  'expected_version',
]);

const preauthorizeOfflineFeatureBundle = async (
  req: Request,
  _res: Response,
  next: NextFunction,
): Promise<void> => {
  const userId = req.user?.id;
  if (!userId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its owner could not be verified.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }

  const projectHeader = req.headers['x-offline-project-id'];
  if (typeof projectHeader !== 'string' || !UUID_PATTERN.test(projectHeader)) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its project could not be verified.',
      'OFFLINE_SYNC_PROJECT_MISMATCH',
    );
  }

  // Bind and authorize the request before multipart buffering or image decode.
  // The controller repeats the binding against the parsed payload, and the
  // transaction repeats current authorization before any application writes.
  assertOfflineRequestBinding({ req, projectId: projectHeader, userId });
  await assertCurrentOfflineAuthorization({
    executor: { query },
    userId,
    projectId: projectHeader,
  });
  next();
};

const readBundlePayload = (req: Request): OfflineBundlePayload => {
  const rawPayload = req.body?.payload;
  if (typeof rawPayload !== 'string') {
    throw offlinePayloadRejected('Offline synchronization payload is missing.');
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawPayload);
  } catch {
    throw offlinePayloadRejected('Offline synchronization payload is malformed.');
  }

  const payload = assertPlainObject(parsed, 'Offline synchronization payload');
  assertOnlyAllowedKeys(payload, OFFLINE_BUNDLE_KEYS, 'Offline synchronization payload');
  assertOfflinePayloadSize(payload);

  const draftId = payload.draft_id;
  const ownerUserId = payload.offline_owner_user_id;
  const projectId = payload.project_id;
  const operation = payload.operation;
  const submitForReview = payload.submit_for_review;
  const expectedVersion = payload.expected_version;

  if (typeof draftId !== 'string' || !UUID_PATTERN.test(draftId)) {
    throw offlinePayloadRejected('Offline synchronization requires a valid stable draft ID.');
  }
  if (typeof ownerUserId !== 'string' || !UUID_PATTERN.test(ownerUserId)) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its owner could not be verified.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }
  if (typeof projectId !== 'string' || !UUID_PATTERN.test(projectId)) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its project could not be verified.',
      'OFFLINE_SYNC_PROJECT_MISMATCH',
    );
  }
  if (operation !== 'create' && operation !== 'update') {
    throw offlinePayloadRejected('Offline synchronization operation is invalid.');
  }
  if (typeof submitForReview !== 'boolean') {
    throw offlinePayloadRejected('Offline synchronization review intent is invalid.');
  }
  if (
    (operation === 'create' && expectedVersion !== undefined && expectedVersion !== null) ||
    (operation === 'update' &&
      (typeof expectedVersion !== 'number' ||
        !Number.isSafeInteger(expectedVersion) ||
        expectedVersion < 1))
  ) {
    throw offlinePayloadRejected('Offline synchronization version is invalid.');
  }
  const attributes = assertPlainObject(payload.attributes, 'Offline synchronization attributes');
  assertSafeOfflineJson(attributes);
  const accuracyMeters = payload.accuracy_meters;
  if (
    accuracyMeters !== undefined &&
    accuracyMeters !== null &&
    (typeof accuracyMeters !== 'number' || !Number.isFinite(accuracyMeters) || accuracyMeters < 0)
  ) {
    throw offlinePayloadRejected('Offline submission GPS accuracy is invalid.');
  }

  return {
    draftId,
    ownerUserId,
    projectId,
    operation,
    geometry: validateGeoJsonGeometry(payload.geom, { strictOffline: true }),
    attributes,
    accuracyMeters: accuracyMeters === undefined || accuracyMeters === null ? null : accuracyMeters,
    submitForReview,
    expectedVersion: operation === 'update' ? (expectedVersion as number) : null,
  };
};

const readProjectPolicy = async (
  executor: QueryExecutor,
  projectId: string,
): Promise<ProjectCollectionPolicy> => {
  const result = await executor.query(
    `SELECT name, collection_form_schema, requires_photos, min_photos, max_photos
     FROM project
     WHERE id = $1`,
    [projectId],
  );
  const project = result.rows[0];
  if (!project) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because this project is unavailable.',
      'OFFLINE_SYNC_PROJECT_UNAVAILABLE',
    );
  }
  const schema = project.collection_form_schema;
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    throw offlinePayloadRejected('The project collection form is invalid.');
  }
  const minPhotos = Number(project.min_photos);
  const maxPhotos = Number(project.max_photos);
  if (
    !Number.isSafeInteger(minPhotos) ||
    !Number.isSafeInteger(maxPhotos) ||
    minPhotos < 0 ||
    maxPhotos < minPhotos
  ) {
    throw offlinePayloadRejected('The project attachment policy is invalid.');
  }
  return {
    name: String(project.name),
    schema: schema as Record<string, unknown>,
    requiresPhotos: project.requires_photos === true,
    minPhotos,
    maxPhotos,
  };
};

const assertUniquePhotos = (req: Request, photos: PreparedPhoto[]): void => {
  const hashes = photos.map((photo) => photo.sourceHash);
  if (new Set(hashes).size !== hashes.length) {
    throw attachmentRejected(req, 'Duplicate attachments are not allowed in one offline bundle.');
  }
};

const assertEditableFeature = (
  feature: any,
  payload: OfflineBundlePayload,
  { requireExactValues }: { requireExactValues: boolean },
): void => {
  if (!feature) {
    throw permanentOfflineSyncError(
      'Offline submission parent record is no longer accessible.',
      'OFFLINE_SYNC_PARENT_INACCESSIBLE',
    );
  }
  if (feature.project_id !== payload.projectId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its project does not match.',
      'OFFLINE_SYNC_PROJECT_MISMATCH',
    );
  }
  if (feature.collected_by_user_id !== payload.ownerUserId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because it belongs to another account.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }
  if (feature.collected_offline !== true) {
    throw permanentOfflineSyncError(
      'Offline submission parent record is no longer accessible.',
      'OFFLINE_SYNC_PARENT_INACCESSIBLE',
    );
  }
  if (
    requireExactValues &&
    (feature.geometry_matches !== true ||
      feature.attributes_match !== true ||
      feature.accuracy_matches !== true)
  ) {
    throw permanentOfflineSyncError(
      'Offline submission identifiers or idempotency data do not match.',
      'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
      409,
    );
  }
};

const readExistingBundleOutcome = async ({
  client,
  userId,
  projectId,
  draftId,
  idempotencyKeyHash,
  payloadHash,
}: {
  client: QueryExecutor;
  userId: string;
  projectId: string;
  draftId: string;
  idempotencyKeyHash: string;
  payloadHash: string;
}): Promise<BundleOutcome | null> => {
  const receipt = await getOfflineReceipt({
    executor: client,
    userId,
    projectId,
    operation: 'offline_bundle',
    idempotencyKeyHash,
  });
  if (!receipt) {
    return null;
  }

  assertMatchingOfflineReceipt(receipt, payloadHash, [draftId]);
  const replay = await client.query(
    `SELECT id, status, version, ST_AsGeoJSON(geom) AS geometry, attributes
     FROM spatial_feature
     WHERE id = $1 AND project_id = $2 AND collected_by_user_id = $3`,
    [draftId, projectId, userId],
  );
  if (!replay.rows[0]) {
    throw permanentOfflineSyncError(
      'Offline submission parent record is no longer accessible.',
      'OFFLINE_SYNC_PARENT_INACCESSIBLE',
    );
  }
  await client.query(
    `UPDATE offline_sync_receipt
     SET outcome = 'already_synchronized'
     WHERE user_id = $1
       AND project_id = $2
       AND operation = 'offline_bundle'
       AND idempotency_key_hash = $3`,
    [userId, projectId, idempotencyKeyHash],
  );
  return { row: replay.rows[0], alreadySynchronized: true };
};

const insertPreparedPhotos = async ({
  client,
  req,
  featureId,
  preparedPhotos,
  policy,
}: {
  client: QueryExecutor;
  req: Request;
  featureId: string;
  preparedPhotos: PlannedPhoto[];
  policy: ProjectCollectionPolicy;
}): Promise<number> => {
  const existingResult = await client.query(
    `SELECT id, exif_data->>'source_sha256' AS source_sha256
     FROM photo
     WHERE feature_id = $1
     ORDER BY display_order, uploaded_at, id
     FOR UPDATE`,
    [featureId],
  );
  const existingHashes = new Set(
    existingResult.rows
      .map((photo) => photo.source_sha256)
      .filter((value): value is string => typeof value === 'string' && value.length > 0),
  );
  const photosToInsert = preparedPhotos.filter((photo) => {
    if (existingHashes.has(photo.sourceHash)) {
      return false;
    }
    existingHashes.add(photo.sourceHash);
    return true;
  });
  const currentCount = existingResult.rows.length;
  if (currentCount + photosToInsert.length > policy.maxPhotos) {
    throw attachmentRejected(
      req,
      `The attachment count exceeds this project's current limit of ${policy.maxPhotos}.`,
    );
  }

  for (let index = 0; index < photosToInsert.length; index += 1) {
    const photo = photosToInsert[index];
    await writeNewPrivateFile(photo.photoPath, photo.encodedImage);
    await writeNewPrivateFile(photo.thumbnailPath, photo.thumbnail);
    await client.query(
      `INSERT INTO photo (
         id, feature_id, file_path, thumbnail_path, exif_data,
         file_size_bytes, display_order, status
       ) VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, 'pending')`,
      [
        photo.photoId,
        featureId,
        photo.photoPath,
        photo.thumbnailPath,
        JSON.stringify(photo.metadata),
        photo.encodedImage.length,
        currentCount + index + 1,
      ],
    );
  }

  return currentCount + photosToInsert.length;
};

const submitForReview = async ({
  client,
  featureId,
  projectId,
  projectName,
  photoCount,
  policy,
}: {
  client: QueryExecutor;
  featureId: string;
  projectId: string;
  projectName: string;
  photoCount: number;
  policy: ProjectCollectionPolicy;
}): Promise<void> => {
  if (policy.requiresPhotos && photoCount < policy.minPhotos) {
    throw permanentOfflineSyncError(
      'Offline submission does not meet the project attachment requirements.',
      'OFFLINE_SYNC_ATTACHMENT_REJECTED',
      422,
    );
  }
  const submitted = await client.query(
    `UPDATE spatial_feature
     SET status = 'pending_review', submitted_at = NOW(), synced_at = NOW(), version = version + 1
     WHERE id = $1 AND project_id = $2 AND status = 'draft'
     RETURNING id`,
    [featureId, projectId],
  );
  if (!submitted.rows[0]) {
    throw permanentOfflineSyncError(
      'Offline submission parent record is no longer submittable.',
      'OFFLINE_SYNC_PARENT_INACCESSIBLE',
      409,
    );
  }
  const admins = await client.query(
    `SELECT id FROM "user" WHERE role = 'admin' AND is_active = TRUE`,
  );
  for (const admin of admins.rows) {
    const notification = await client.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES ($1, 'review_completed', 'Feature review pending', $2, $3::jsonb)
       RETURNING id`,
      [
        admin.id,
        `A submitted feature in ${projectName} is waiting for review.`,
        JSON.stringify({
          feature_id: featureId,
          project_id: projectId,
          project_name: projectName,
          status: 'pending_review',
        }),
      ],
    );
    await publishRealtimeChanges(
      [
        {
          scopeType: 'notifications',
          scopeId: admin.id,
          action: 'created',
          entityType: 'notification',
          entityId: notification.rows[0].id,
          projectId,
          audience: { kind: 'user', userId: admin.id },
        },
      ],
      client,
    );
  }
};

const syncOfflineFeatureBundle = async (req: Request, res: Response): Promise<void> => {
  const userId = req.user?.id;
  if (!userId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its owner could not be verified.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }

  const payload = readBundlePayload(req);
  if (payload.ownerUserId !== userId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because it belongs to another account.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }
  const { idempotencyKeyHash } = assertOfflineRequestBinding({
    req,
    projectId: payload.projectId,
    userId,
  });
  const files = Array.isArray(req.files) ? (req.files.slice() as MemoryPhotoFile[]) : [];
  const payloadHash = sha256Json({
    draft_id: payload.draftId,
    offline_owner_user_id: userId,
    project_id: payload.projectId,
    operation: payload.operation,
    geom: payload.geometry,
    attributes: payload.attributes,
    accuracy_meters: payload.accuracyMeters,
    submit_for_review: payload.submitForReview,
    expected_version: payload.expectedVersion,
    photo_source_hashes: files.map((file) =>
      createHash('sha256').update(file.buffer).digest('hex'),
    ),
  });

  // Reject revoked accounts/projects before spending CPU decoding images. The
  // same checks run again under the committing transaction to close the race.
  await assertCurrentOfflineAuthorization({
    executor: { query },
    userId,
    projectId: payload.projectId,
  });
  let outcome: BundleOutcome | null = await transaction(
    async (client: QueryExecutor): Promise<BundleOutcome | null> => {
      await assertCurrentOfflineAuthorization({
        executor: client,
        userId,
        projectId: payload.projectId,
      });
      return readExistingBundleOutcome({
        client,
        userId,
        projectId: payload.projectId,
        draftId: payload.draftId,
        idempotencyKeyHash,
        payloadHash,
      });
    },
  );

  const preparedPhotos: PreparedPhoto[] = [];
  if (!outcome) {
    const preflightPolicy = await readProjectPolicy({ query }, payload.projectId);
    validateAttributesAgainstSchema(payload.attributes, preflightPolicy.schema, {
      strictOffline: true,
    });
    assertOfflineCollectionConstraints({
      schema: preflightPolicy.schema,
      geometry: payload.geometry,
      accuracyMeters: payload.accuracyMeters,
    });
    await assertGeometryAcceptedByPostgis({ query }, payload.geometry);
    for (const file of files) {
      // Decode sequentially so the per-image pixel limit also bounds peak memory
      // when a bundle contains the maximum number of attachments.
      preparedPhotos.push(await preparePhoto(req, file));
    }
    assertUniquePhotos(req, preparedPhotos);
    const plannedPhotos: PlannedPhoto[] = preparedPhotos.map((photo) => {
      const photoId = randomUUID();
      return {
        ...photo,
        photoId,
        photoPath: path.join(privateFeaturePhotosDir, `.${photoId}.jpg`),
        thumbnailPath: path.join(privateFeatureThumbnailsDir, `.${photoId}.jpg`),
      };
    });
    const reservedPaths = plannedPhotos.flatMap((photo) => [photo.photoPath, photo.thumbnailPath]);
    const cleanupJobIds = await reserveFeatureMediaCleanupJobs(reservedPaths);

    try {
      outcome = await transaction(
        async (client): Promise<BundleOutcome> =>
          withReservedFeatureMediaJobs(client, cleanupJobIds, async () => {
            await assertCurrentOfflineAuthorization({
              executor: client,
              userId,
              projectId: payload.projectId,
            });
            const policy = await readProjectPolicy(client, payload.projectId);
            const normalizedAttributes = validateAttributesAgainstSchema(
              payload.attributes,
              policy.schema,
              { strictOffline: true },
            );
            const normalizedAccuracy = assertOfflineCollectionConstraints({
              schema: policy.schema,
              geometry: payload.geometry,
              accuracyMeters: payload.accuracyMeters,
            });
            await assertGeometryAcceptedByPostgis(client, payload.geometry);
            await lockOfflineFeatureIds(client, [payload.draftId]);

            const existingOutcome = await readExistingBundleOutcome({
              client,
              userId,
              projectId: payload.projectId,
              draftId: payload.draftId,
              idempotencyKeyHash,
              payloadHash,
            });
            if (existingOutcome) {
              return existingOutcome;
            }

            if (payload.operation === 'create') {
              const priorBundle = await client.query(
                `SELECT 1
           FROM offline_sync_receipt
           WHERE user_id = $1
             AND project_id = $2
             AND operation = 'offline_bundle'
             AND $3::uuid = ANY(entity_ids)
           LIMIT 1
           FOR SHARE`,
                [userId, payload.projectId, payload.draftId],
              );
              if (priorBundle.rows[0]) {
                throw permanentOfflineSyncError(
                  'Offline submission identifiers or idempotency data do not match.',
                  'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
                  409,
                );
              }
            }

            let featureStatus = 'draft';
            let featureAlreadyExisted = false;
            if (payload.operation === 'create') {
              const existing = await client.query(
                `SELECT id, project_id, collected_by_user_id, collected_offline, status,
                  ST_Equals(geom, ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)) AS geometry_matches,
                  attributes = $3::jsonb AS attributes_match,
                  accuracy_meters IS NOT DISTINCT FROM $4::double precision AS accuracy_matches
           FROM spatial_feature
           WHERE id = $1
           FOR UPDATE`,
                [
                  payload.draftId,
                  JSON.stringify(payload.geometry),
                  JSON.stringify(normalizedAttributes),
                  normalizedAccuracy,
                ],
              );
              if (existing.rows[0]) {
                assertEditableFeature(existing.rows[0], payload, { requireExactValues: true });
                featureStatus = existing.rows[0].status;
                featureAlreadyExisted = true;
              } else {
                await client.query(
                  `INSERT INTO spatial_feature (
               id, project_id, collected_by_user_id, geom, attributes,
               accuracy_meters, collected_offline, status, synced_at
             ) VALUES (
               $1, $2, $3, ST_SetSRID(ST_GeomFromGeoJSON($4), 4326),
               $5::jsonb, $6, TRUE, 'draft', NULL
             )`,
                  [
                    payload.draftId,
                    payload.projectId,
                    userId,
                    JSON.stringify(payload.geometry),
                    JSON.stringify(normalizedAttributes),
                    normalizedAccuracy,
                  ],
                );
              }
            } else {
              const existing = await client.query(
                `SELECT id, project_id, collected_by_user_id, collected_offline, status, version
           FROM spatial_feature
           WHERE id = $1
           FOR UPDATE`,
                [payload.draftId],
              );
              assertEditableFeature(existing.rows[0], payload, { requireExactValues: false });
              if (existing.rows[0].version !== payload.expectedVersion) {
                throw offlineSyncConflictError(existing.rows[0].version);
              }
              if (existing.rows[0].status !== 'draft') {
                throw permanentOfflineSyncError(
                  'Offline submission parent record is no longer editable.',
                  'OFFLINE_SYNC_PARENT_INACCESSIBLE',
                  409,
                );
              }
              await client.query(
                `UPDATE spatial_feature
           SET geom = ST_SetSRID(ST_GeomFromGeoJSON($1), 4326),
               attributes = $2::jsonb,
               accuracy_meters = $3,
               version = version + 1
           WHERE id = $4 AND project_id = $5 AND status = 'draft' AND version = $6`,
                [
                  JSON.stringify(payload.geometry),
                  JSON.stringify(normalizedAttributes),
                  normalizedAccuracy,
                  payload.draftId,
                  payload.projectId,
                  payload.expectedVersion,
                ],
              );
            }

            if (featureStatus !== 'draft') {
              if (
                !featureAlreadyExisted ||
                featureStatus !== 'pending_review' ||
                !payload.submitForReview
              ) {
                throw permanentOfflineSyncError(
                  'Offline submission parent record is no longer editable.',
                  'OFFLINE_SYNC_PARENT_INACCESSIBLE',
                  409,
                );
              }
              const existingPhotoHashes = await client.query(
                `SELECT exif_data->>'source_sha256' AS source_sha256
           FROM photo
           WHERE feature_id = $1`,
                [payload.draftId],
              );
              const available = new Set(
                existingPhotoHashes.rows.map((photo) => photo.source_sha256),
              );
              if (plannedPhotos.some((photo) => !available.has(photo.sourceHash))) {
                throw permanentOfflineSyncError(
                  'Offline submission parent record does not match its attachments.',
                  'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
                  409,
                );
              }
              await insertOfflineReceipt({
                executor: client,
                userId,
                projectId: payload.projectId,
                operation: 'offline_bundle',
                idempotencyKeyHash,
                payloadHash,
                entityIds: [payload.draftId],
              });
              const replay = await client.query(
                `SELECT id, status, version, ST_AsGeoJSON(geom) AS geometry, attributes
           FROM spatial_feature WHERE id = $1`,
                [payload.draftId],
              );
              return { row: replay.rows[0], alreadySynchronized: true };
            }

            const photoCount = await insertPreparedPhotos({
              client,
              req,
              featureId: payload.draftId,
              preparedPhotos: plannedPhotos,
              policy,
            });
            if (payload.submitForReview) {
              await submitForReview({
                client,
                featureId: payload.draftId,
                projectId: payload.projectId,
                projectName: policy.name,
                photoCount,
                policy,
              });
            } else {
              await client.query(
                `UPDATE spatial_feature SET synced_at = NOW() WHERE id = $1 AND project_id = $2`,
                [payload.draftId, payload.projectId],
              );
            }

            await insertOfflineReceipt({
              executor: client,
              userId,
              projectId: payload.projectId,
              operation: 'offline_bundle',
              idempotencyKeyHash,
              payloadHash,
              entityIds: [payload.draftId],
            });
            const saved = await client.query(
              `SELECT id, status, version, ST_AsGeoJSON(geom) AS geometry, attributes
         FROM spatial_feature WHERE id = $1`,
              [payload.draftId],
            );
            await publishRealtimeChanges(
              offlineBundleRealtimeInputs({
                projectId: payload.projectId,
                featureId: payload.draftId,
                action: payload.submitForReview
                  ? 'offline_bundle_submitted'
                  : 'offline_bundle_synchronized',
                submitted: payload.submitForReview,
                originSessionId: req.authSessionId,
              }),
              client,
            );
            return { row: saved.rows[0], alreadySynchronized: false };
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
        logger.error('Unable to run immediate offline-bundle media cleanup', {
          jobCount: cleanupJobIds.length,
          errorCode: String((cleanupError as { code?: unknown })?.code ?? 'CLEANUP_DEFERRED'),
        });
      }
      throw error;
    }
  }

  if (!outcome) {
    throw new Error('Offline synchronization completed without an outcome.');
  }

  logger.info(
    outcome.alreadySynchronized
      ? 'Offline feature bundle replay confirmed'
      : 'Offline feature bundle synchronized',
    {
      featureId: payload.draftId,
      projectId: payload.projectId,
      userId,
      operation: payload.operation,
      photoCount: preparedPhotos.length,
      outcome: outcome.alreadySynchronized ? 'already_synchronized' : 'accepted',
    },
  );
  res.locals.offlineSyncAudit = {
    project_id: payload.projectId,
    operation: payload.operation,
    outcome: outcome.alreadySynchronized ? 'already_synchronized' : 'accepted',
    attachment_count: preparedPhotos.length,
  };
  res.status(outcome.alreadySynchronized ? 200 : 201).json({
    success: true,
    message: outcome.alreadySynchronized
      ? 'Offline submission was already synchronized.'
      : 'Offline submission synchronized successfully.',
    data: {
      ...outcome.row,
      project_id: payload.projectId,
      geometry: JSON.parse(outcome.row.geometry),
      outcome: outcome.alreadySynchronized ? 'already_synchronized' : 'accepted',
    },
  });
};

export { preauthorizeOfflineFeatureBundle, syncOfflineFeatureBundle };
