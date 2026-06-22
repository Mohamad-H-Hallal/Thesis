import type { PoolClient } from 'pg';
import { query, transaction } from '../config/database';
import { AppError } from '../middleware/error';

type JsonRecord = Record<string, unknown>;

type PredictionValidationResult = 'correct' | 'incorrect' | 'unsure' | 'cannot_verify';
type PredictionAdminReviewStatus = 'approved' | 'rejected' | 'needs_more_validation';

type PredictionValidationInput = {
  projectId: string;
  predictionId: string;
  submittedBy: string;
  result: PredictionValidationResult;
  correctedClass?: string | null;
  note?: string | null;
  photoMediaIds?: unknown;
  gpsLocation?: unknown;
  gpsAccuracyM?: unknown;
  metadata?: JsonRecord | null;
};

type PredictionAdminReviewInput = {
  projectId: string;
  predictionId: string;
  reviewedBy: string;
  approvalStatus: PredictionAdminReviewStatus;
  approvedClass?: string | null;
  adminNote?: string | null;
};

const validationResults = new Set<PredictionValidationResult>([
  'correct',
  'incorrect',
  'unsure',
  'cannot_verify',
]);

const adminReviewStatuses = new Set<PredictionAdminReviewStatus>([
  'approved',
  'rejected',
  'needs_more_validation',
]);

const unclassifiedLabel = 'Unclassified';

const normalizeOptionalString = (value: unknown): string | null => {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const normalizeClassLabel = (value: string): string => value.trim().toLowerCase();

const isUnclassifiedLabel = (value: string): boolean =>
  normalizeClassLabel(value) === normalizeClassLabel(unclassifiedLabel);

const toJsonRecord = (value: unknown): JsonRecord =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as JsonRecord) : {};

const toOptionalNumber = (value: unknown): number | null => {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
};

const normalizePhotoMediaIds = (value: unknown): string[] => {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((item) => normalizeOptionalString(item))
    .filter((item): item is string => item !== null);
};

const normalizeGpsLocation = (
  value: unknown,
): { lon: number | null; lat: number | null } => {
  const record = toJsonRecord(value);
  const lon = toOptionalNumber(record.lon ?? record.lng ?? record.longitude);
  const lat = toOptionalNumber(record.lat ?? record.latitude);
  if (lon === null || lat === null || lon < -180 || lon > 180 || lat < -90 || lat > 90) {
    return { lon: null, lat: null };
  }
  return { lon, lat };
};

const contributorHasAssignedProjectAccess = async ({
  projectId,
  userId,
  client,
}: {
  projectId: string;
  userId: string;
  client?: PoolClient;
}): Promise<boolean> => {
  const executor = client ?? { query };
  const result = await executor.query(
    `SELECT EXISTS (
       SELECT 1
       FROM project_assignment
       WHERE project_id = $1
         AND user_id = $2
         AND role = 'contributor'
         AND status = 'approved'
     ) AS has_project_assignment`,
    [projectId, userId],
  );
  return result.rows[0]?.has_project_assignment === true;
};

const eligibleClassLabelsForRun = async (
  aiRunId: string,
  client?: PoolClient,
): Promise<string[]> => {
  const executor = client ?? { query };
  const result = await executor.query(
    `SELECT ARRAY(
              SELECT class_label
              FROM ai_class_statistic
              WHERE ai_run_id = ar.id
              ORDER BY class_label ASC
            ) AS statistic_labels,
            ARRAY(
              SELECT DISTINCT predicted_class
              FROM ai_prediction_feature
              WHERE ai_run_id = ar.id
                AND predicted_class IS NOT NULL
              ORDER BY predicted_class ASC
            ) AS prediction_labels
     FROM ai_run ar
     WHERE ar.id = $1`,
    [aiRunId],
  );
  if (result.rows.length === 0) {
    throw new AppError('AI run not found', 404);
  }
  const labels = new Set<string>();
  for (const label of result.rows[0].statistic_labels ?? []) {
    const normalized = normalizeOptionalString(label);
    if (normalized) {
      labels.add(normalized);
    }
  }
  if (labels.size === 0) {
    for (const label of result.rows[0].prediction_labels ?? []) {
      const normalized = normalizeOptionalString(label);
      if (normalized) {
        labels.add(normalized);
      }
    }
  }
  return Array.from(labels);
};

const assertClassEligibleIfKnown = async ({
  aiRunId,
  classLabel,
  client,
}: {
  aiRunId: string;
  classLabel: string;
  client?: PoolClient;
}): Promise<void> => {
  if (isUnclassifiedLabel(classLabel)) {
    return;
  }
  const labels = await eligibleClassLabelsForRun(aiRunId, client);
  if (labels.length === 0) {
    return;
  }
  const normalizedAllowed = new Set(labels.map(normalizeClassLabel));
  if (!normalizedAllowed.has(normalizeClassLabel(classLabel))) {
    throw new AppError('approved_class/corrected_class must match a known AI class for this run.', 400);
  }
};

const loadPredictionForProject = async ({
  projectId,
  predictionId,
  runId,
  client,
  forUpdate = false,
}: {
  projectId: string;
  predictionId: string;
  runId?: string | null;
  client?: PoolClient;
  forUpdate?: boolean;
}) => {
  const executor = client ?? { query };
  const result = await executor.query(
    `SELECT p.id,
            p.project_id,
            p.ai_run_id,
            p.ai_output_layer_id,
            p.artifact_feature_id,
            ST_AsGeoJSON(COALESCE(p.processed_geom, p.geom))::json AS geometry,
            p.geometry_type,
            p.predicted_class,
            p.confidence,
            p.uncertainty_score,
            p.model_name,
            p.source,
            p.status,
            p.metadata,
            p.admin_validation_status,
            p.admin_note,
            p.admin_reviewed_by,
            admin_user.full_name AS admin_reviewed_by_name,
            p.admin_reviewed_at,
            p.approved_class,
            p.promoted_spatial_feature_id,
            p.created_at,
            p.updated_at,
            l.layer_type,
            l.status AS layer_status,
            l.name AS layer_name,
            l.published_at AS layer_published_at,
            l.published_by AS layer_published_by,
            ar.label_field,
            ar.published_at AS run_published_at,
            ar.published_by AS run_published_by
     FROM ai_prediction_feature p
     JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
     JOIN ai_run ar ON ar.id = p.ai_run_id
     LEFT JOIN "user" admin_user ON admin_user.id = p.admin_reviewed_by
     WHERE p.project_id = $1
       AND p.id = $2
       AND ($3::uuid IS NULL OR p.ai_run_id = $3)
     ${forUpdate ? 'FOR UPDATE OF p' : ''}`,
    [projectId, predictionId, runId ?? null],
  );
  if (result.rows.length === 0) {
    throw new AppError('AI prediction feature not found for this project.', 404);
  }
  const prediction = result.rows[0];
  if (prediction.layer_type !== 'classification') {
    throw new AppError('Only AI classification prediction features can be validated.', 400);
  }
  return prediction;
};

const isPredictionPublished = (prediction: any): boolean =>
  prediction.layer_status === 'published' && prediction.layer_published_at !== null;

const validationSummaryForPrediction = async (
  predictionId: string,
  client?: PoolClient,
) => {
  const executor = client ?? { query };
  const result = await executor.query(
    `SELECT COUNT(*)::int AS total,
            COUNT(*) FILTER (WHERE validation_result = 'correct')::int AS correct,
            COUNT(*) FILTER (WHERE validation_result = 'incorrect')::int AS incorrect,
            COUNT(*) FILTER (WHERE validation_result = 'unsure')::int AS unsure,
            COUNT(*) FILTER (WHERE validation_result = 'cannot_verify')::int AS cannot_verify,
            COUNT(DISTINCT contributor_user_id)::int AS contributor_count
     FROM ai_prediction_feature_validation
     WHERE ai_prediction_feature_id = $1`,
    [predictionId],
  );
  const row = result.rows[0] ?? {};
  return {
    total: Number(row.total ?? 0),
    correct: Number(row.correct ?? 0),
    incorrect: Number(row.incorrect ?? 0),
    unsure: Number(row.unsure ?? 0),
    cannot_verify: Number(row.cannot_verify ?? 0),
    contributor_count: Number(row.contributor_count ?? 0),
  };
};

const normalizeValidationRow = (row: any) => ({
  id: row.id,
  project_id: row.project_id,
  ai_run_id: row.ai_run_id,
  ai_prediction_feature_id: row.ai_prediction_feature_id,
  contributor_user_id: row.contributor_user_id,
  contributor: row.contributor_user_id
    ? {
        id: row.contributor_user_id,
        full_name: row.contributor_full_name,
      }
    : null,
  validation_result: row.validation_result,
  corrected_class: row.corrected_class,
  note: row.note,
  photo_media_ids: row.photo_media_ids ?? [],
  gps_location: row.gps_location ?? null,
  gps_accuracy_m: row.gps_accuracy_m === null ? null : Number(row.gps_accuracy_m),
  metadata: row.metadata ?? {},
  created_at: row.created_at,
  updated_at: row.updated_at,
});

const listValidationsForPrediction = async (
  predictionId: string,
  client?: PoolClient,
) => {
  const executor = client ?? { query };
  const result = await executor.query(
    `SELECT v.id,
            v.project_id,
            v.ai_run_id,
            v.ai_prediction_feature_id,
            v.contributor_user_id,
            contributor.full_name AS contributor_full_name,
            v.validation_result,
            v.corrected_class,
            v.note,
            v.photo_media_ids,
            ST_AsGeoJSON(v.gps_location)::json AS gps_location,
            v.gps_accuracy_m,
            v.metadata,
            v.created_at,
            v.updated_at
     FROM ai_prediction_feature_validation v
     JOIN "user" contributor ON contributor.id = v.contributor_user_id
     WHERE v.ai_prediction_feature_id = $1
     ORDER BY v.created_at ASC`,
    [predictionId],
  );
  return result.rows.map(normalizeValidationRow);
};

const myValidationForPrediction = async ({
  predictionId,
  userId,
  client,
}: {
  predictionId: string;
  userId: string;
  client?: PoolClient;
}) => {
  const executor = client ?? { query };
  const result = await executor.query(
    `SELECT v.id,
            v.project_id,
            v.ai_run_id,
            v.ai_prediction_feature_id,
            v.contributor_user_id,
            contributor.full_name AS contributor_full_name,
            v.validation_result,
            v.corrected_class,
            v.note,
            v.photo_media_ids,
            ST_AsGeoJSON(v.gps_location)::json AS gps_location,
            v.gps_accuracy_m,
            v.metadata,
            v.created_at,
            v.updated_at
     FROM ai_prediction_feature_validation v
     JOIN "user" contributor ON contributor.id = v.contributor_user_id
     WHERE v.ai_prediction_feature_id = $1
       AND v.contributor_user_id = $2
     LIMIT 1`,
    [predictionId, userId],
  );
  return result.rows.length === 0 ? null : normalizeValidationRow(result.rows[0]);
};

const predictionDetailsPayload = async ({
  prediction,
  user,
  client,
}: {
  prediction: any;
  user: Express.UserContext;
  client?: PoolClient;
}) => {
  const published = isPredictionPublished(prediction);
  if (user.role !== 'admin' && !published) {
    throw new AppError('This AI prediction layer is not published.', 403);
  }
  const summary = await validationSummaryForPrediction(prediction.id, client);
  const eligibleClassLabels = await eligibleClassLabelsForRun(prediction.ai_run_id, client);
  const userValidation =
    user.role === 'contributor'
      ? await myValidationForPrediction({
          predictionId: prediction.id,
          userId: user.id,
          client,
        })
      : null;
  const assignedContributor =
    user.role === 'contributor'
      ? await contributorHasAssignedProjectAccess({
          projectId: prediction.project_id,
          userId: user.id,
          client,
        })
      : false;
  const adminStatus = normalizeOptionalString(prediction.admin_validation_status);
  const validationClosed =
    adminStatus === 'approved' ||
    adminStatus === 'rejected' ||
    prediction.promoted_spatial_feature_id !== null;

  return {
    prediction: {
      id: prediction.id,
      project_id: prediction.project_id,
      ai_run_id: prediction.ai_run_id,
      ai_output_layer_id: prediction.ai_output_layer_id,
      artifact_feature_id: prediction.artifact_feature_id,
      geometry: prediction.geometry,
      geometry_type: prediction.geometry_type,
      predicted_class: prediction.predicted_class,
      confidence: prediction.confidence === null ? null : Number(prediction.confidence),
      uncertainty_score:
        prediction.uncertainty_score === null ? null : Number(prediction.uncertainty_score),
      model_name: prediction.model_name,
      source: prediction.source,
      status: prediction.status,
      metadata: prediction.metadata ?? {},
      not_official_field_data: true,
    },
    layer: {
      id: prediction.ai_output_layer_id,
      layer_type: prediction.layer_type,
      status: prediction.layer_status,
      name: prediction.layer_name,
      published_at: prediction.layer_published_at,
      published_by: prediction.layer_published_by,
      one_classification_layer: true,
    },
    run: {
      id: prediction.ai_run_id,
      label_field: prediction.label_field,
      published_at: prediction.run_published_at,
      published_by: prediction.run_published_by,
      class_labels: eligibleClassLabels,
    },
    validation_summary: summary,
    my_validation: userValidation,
    admin_review: {
      status: prediction.admin_validation_status,
      note: prediction.admin_note,
      reviewed_by: prediction.admin_reviewed_by,
      reviewed_by_user: prediction.admin_reviewed_by
        ? {
            id: prediction.admin_reviewed_by,
            full_name: prediction.admin_reviewed_by_name,
          }
        : null,
      reviewed_at: prediction.admin_reviewed_at,
      approved_class: prediction.approved_class,
      promoted_spatial_feature_id: prediction.promoted_spatial_feature_id,
    },
    published,
    assigned_contributor: assignedContributor,
    validation_closed: validationClosed,
    can_validate:
      user.role === 'contributor' &&
      assignedContributor &&
      published &&
      userValidation === null &&
      !validationClosed,
    can_admin_review: user.role === 'admin',
    confidence_is_attribute: true,
    standalone_confidence_layer: false,
    standalone_uncertainty_layer: false,
  };
};

const getPredictionFeatureDetailsForUser = async ({
  projectId,
  runId,
  predictionId,
  user,
}: {
  projectId: string;
  runId?: string | null;
  predictionId: string;
  user: Express.UserContext;
}) => {
  const prediction = await loadPredictionForProject({
    projectId,
    predictionId,
    runId,
  });
  return predictionDetailsPayload({ prediction, user });
};

const createPredictionFeatureValidation = async (
  input: PredictionValidationInput,
  user: Express.UserContext,
) => {
  if (user.role !== 'contributor') {
    throw new AppError('Only assigned contributors can validate AI prediction features.', 403);
  }
  if (!validationResults.has(input.result)) {
    throw new AppError('validation_result must be correct, incorrect, unsure, or cannot_verify.', 400);
  }

  const correctedClass = normalizeOptionalString(input.correctedClass);
  if (input.result === 'incorrect' && !correctedClass) {
    throw new AppError('corrected_class is required when validation_result is incorrect.', 400);
  }
  if (input.result !== 'incorrect' && correctedClass) {
    throw new AppError('corrected_class is only allowed when validation_result is incorrect.', 400);
  }

  return transaction(async (client: PoolClient) => {
    const prediction = await loadPredictionForProject({
      projectId: input.projectId,
      predictionId: input.predictionId,
      client,
      forUpdate: true,
    });
    if (!isPredictionPublished(prediction)) {
      throw new AppError('AI prediction features can be validated only after the AI layer is published.', 403);
    }
    const assignedContributor = await contributorHasAssignedProjectAccess({
      projectId: input.projectId,
      userId: input.submittedBy,
      client,
    });
    if (!assignedContributor) {
      throw new AppError('You can only validate AI predictions for projects assigned to you.', 403);
    }
    if (
      prediction.admin_validation_status === 'approved' ||
      prediction.admin_validation_status === 'rejected' ||
      prediction.promoted_spatial_feature_id !== null
    ) {
      throw new AppError('This AI prediction is already closed for contributor validation.', 409);
    }
    if (correctedClass) {
      await assertClassEligibleIfKnown({
        aiRunId: prediction.ai_run_id,
        classLabel: correctedClass,
        client,
      });
    }

    const photoMediaIds = normalizePhotoMediaIds(input.photoMediaIds);
    const gps = normalizeGpsLocation(input.gpsLocation);
    const gpsAccuracy = toOptionalNumber(input.gpsAccuracyM);

    try {
      await client.query(
        `INSERT INTO ai_prediction_feature_validation (
           project_id,
           ai_run_id,
           ai_prediction_feature_id,
           contributor_user_id,
           validation_result,
           corrected_class,
           note,
           photo_media_ids,
           gps_location,
           gps_accuracy_m,
           metadata
         )
         VALUES (
           $1,
           $2,
           $3,
           $4,
           $5,
           $6,
           $7,
           $8::jsonb,
           CASE
             WHEN $9::double precision IS NULL OR $10::double precision IS NULL THEN NULL
             ELSE ST_SetSRID(ST_MakePoint($9, $10), 4326)
           END,
           $11,
           $12::jsonb
         )`,
        [
          prediction.project_id,
          prediction.ai_run_id,
          prediction.id,
          input.submittedBy,
          input.result,
          correctedClass,
          normalizeOptionalString(input.note),
          JSON.stringify(photoMediaIds),
          gps.lon,
          gps.lat,
          gpsAccuracy,
          JSON.stringify({
            ...toJsonRecord(input.metadata),
            validated_at: new Date().toISOString(),
            online_only: true,
          }),
        ],
      );
    } catch (error: any) {
      if (error?.code === '23505') {
        throw new AppError('You already validated this AI prediction feature.', 409);
      }
      throw error;
    }

    const refreshed = await loadPredictionForProject({
      projectId: input.projectId,
      predictionId: input.predictionId,
      client,
    });
    return predictionDetailsPayload({ prediction: refreshed, user, client });
  });
};

const promotePredictionFeature = async ({
  client,
  prediction,
  approvedClass,
  reviewedBy,
  adminNote,
  validationSummary,
}: {
  client: PoolClient;
  prediction: any;
  approvedClass: string;
  reviewedBy: string;
  adminNote: string | null;
  validationSummary: JsonRecord;
}): Promise<string> => {
  const labelField = normalizeOptionalString(prediction.label_field) ?? 'ai_class';
  const nowIso = new Date().toISOString();
  const attributes = {
    [labelField]: approvedClass,
    source: 'ai',
    aiRunId: prediction.ai_run_id,
    aiPredictionId: prediction.id,
    aiPredictedClass: prediction.predicted_class,
    aiApprovedClass: approvedClass,
    aiConfidence: prediction.confidence,
    aiModelName: prediction.model_name,
    aiValidated: true,
    aiValidationStatus: 'admin_approved',
    aiApprovedBy: reviewedBy,
    aiApprovedAt: nowIso,
    aiAdminNote: adminNote,
    useForFutureTraining: true,
    contributorValidationSummary: validationSummary,
    promotedFromAi: true,
  };

  const result = await client.query(
    `INSERT INTO spatial_feature (
       project_id,
       collected_by_user_id,
       geom,
       attributes,
       status,
       submitted_at,
       reviewed_at,
       reviewed_by_user_id,
       review_notes,
       source,
       ai_run_id,
       ai_prediction_feature_id,
       ai_predicted_class,
       ai_confidence,
       ai_validated,
       ai_validation_status,
       ai_approved_by,
       ai_approved_at,
       ai_admin_note,
       use_for_future_training,
       contributor_validation_summary,
       promoted_from_ai
     )
     SELECT p.project_id,
            $2,
            p.geom,
            $3::jsonb,
            'approved',
            NOW(),
            NOW(),
            $2,
            $4,
            'ai',
            p.ai_run_id,
            p.id,
            p.predicted_class,
            p.confidence,
            TRUE,
            'admin_approved',
            $2,
            NOW(),
            $4,
            TRUE,
            $5::jsonb,
            TRUE
     FROM ai_prediction_feature p
     WHERE p.id = $1
     ON CONFLICT (project_id, ai_prediction_feature_id)
       WHERE source = 'ai' AND ai_prediction_feature_id IS NOT NULL
     DO UPDATE SET
       geom = EXCLUDED.geom,
       attributes = COALESCE(spatial_feature.attributes, '{}'::jsonb) || EXCLUDED.attributes,
       status = 'approved',
       reviewed_at = NOW(),
       reviewed_by_user_id = EXCLUDED.reviewed_by_user_id,
       review_notes = EXCLUDED.review_notes,
       ai_run_id = EXCLUDED.ai_run_id,
       ai_predicted_class = EXCLUDED.ai_predicted_class,
       ai_confidence = EXCLUDED.ai_confidence,
       ai_validated = TRUE,
       ai_validation_status = 'admin_approved',
       ai_approved_by = EXCLUDED.ai_approved_by,
       ai_approved_at = NOW(),
       ai_admin_note = EXCLUDED.ai_admin_note,
       use_for_future_training = TRUE,
       contributor_validation_summary = EXCLUDED.contributor_validation_summary,
       promoted_from_ai = TRUE,
       source = 'ai'
     RETURNING id`,
    [
      prediction.id,
      reviewedBy,
      JSON.stringify(attributes),
      adminNote ?? 'AI prediction approved by admin review.',
      JSON.stringify(validationSummary),
    ],
  );
  const featureId = result.rows[0].id;
  await client.query(
    `UPDATE ai_prediction_feature
     SET promoted_spatial_feature_id = $2,
         updated_at = NOW()
     WHERE id = $1`,
    [prediction.id, featureId],
  );
  return featureId;
};

const markPromotedFeatureRejectedIfPresent = async ({
  client,
  prediction,
  reviewedBy,
  adminNote,
}: {
  client: PoolClient;
  prediction: any;
  reviewedBy: string;
  adminNote: string | null;
}) => {
  const featureId = normalizeOptionalString(prediction.promoted_spatial_feature_id);
  if (!featureId) {
    return;
  }
  await client.query(
    `UPDATE spatial_feature
     SET attributes = COALESCE(attributes, '{}'::jsonb) || $2::jsonb,
         ai_validation_status = 'admin_rejected',
         ai_approved_by = $3,
         ai_approved_at = NOW(),
         ai_admin_note = $4,
         use_for_future_training = FALSE,
         reviewed_at = NOW(),
         reviewed_by_user_id = $3,
         review_notes = $4
     WHERE id = $1
       AND source = 'ai'`,
    [
      featureId,
      JSON.stringify({
        aiValidationStatus: 'admin_rejected',
        useForFutureTraining: false,
      }),
      reviewedBy,
      adminNote ?? 'AI prediction rejected by admin review.',
    ],
  );
};

const reviewPredictionFeature = async (
  input: PredictionAdminReviewInput,
  user: Express.UserContext,
) => {
  if (user.role !== 'admin') {
    throw new AppError('Only admins can review AI prediction validations.', 403);
  }
  if (!adminReviewStatuses.has(input.approvalStatus)) {
    throw new AppError('approval_status must be approved, rejected, or needs_more_validation.', 400);
  }

  return transaction(async (client: PoolClient) => {
    const prediction = await loadPredictionForProject({
      projectId: input.projectId,
      predictionId: input.predictionId,
      client,
      forUpdate: true,
    });
    if (!isPredictionPublished(prediction)) {
      throw new AppError('AI predictions can be admin-reviewed only after the AI layer is published.', 409);
    }

    const approvedClass =
      input.approvalStatus === 'approved'
        ? normalizeOptionalString(input.approvedClass) ??
          normalizeOptionalString(prediction.predicted_class)
        : normalizeOptionalString(input.approvedClass);
    if (input.approvalStatus === 'approved' && !approvedClass) {
      throw new AppError('approved_class is required when approving an AI prediction.', 400);
    }
    if (approvedClass) {
      await assertClassEligibleIfKnown({
        aiRunId: prediction.ai_run_id,
        classLabel: approvedClass,
        client,
      });
    }

    const validationSummary = await validationSummaryForPrediction(prediction.id, client);
    let promotedSpatialFeatureId: string | null = null;
    if (input.approvalStatus === 'approved') {
      promotedSpatialFeatureId = await promotePredictionFeature({
        client,
        prediction,
        approvedClass: approvedClass as string,
        reviewedBy: input.reviewedBy,
        adminNote: normalizeOptionalString(input.adminNote),
        validationSummary,
      });
    } else if (input.approvalStatus === 'rejected') {
      await markPromotedFeatureRejectedIfPresent({
        client,
        prediction,
        reviewedBy: input.reviewedBy,
        adminNote: normalizeOptionalString(input.adminNote),
      });
    }

    const statusForPrediction =
      input.approvalStatus === 'approved'
        ? 'approved'
        : input.approvalStatus === 'rejected'
          ? 'rejected'
          : prediction.status;
    await client.query(
      `UPDATE ai_prediction_feature
       SET status = $2::ai_prediction_feature_status,
           admin_validation_status = $3,
           admin_note = $4,
           admin_reviewed_by = $5,
           admin_reviewed_at = NOW(),
           approved_class = $6,
           promoted_spatial_feature_id = COALESCE($7, promoted_spatial_feature_id),
           metadata = COALESCE(metadata, '{}'::jsonb) || $8::jsonb,
           updated_at = NOW()
       WHERE id = $1`,
      [
        prediction.id,
        statusForPrediction,
        input.approvalStatus,
        normalizeOptionalString(input.adminNote),
        input.reviewedBy,
        approvedClass,
        promotedSpatialFeatureId,
        JSON.stringify({
          ai_validated: true,
          ai_validation_status:
            input.approvalStatus === 'approved'
              ? 'admin_approved'
              : input.approvalStatus === 'rejected'
                ? 'admin_rejected'
                : 'needs_more_validation',
          approved_class: approvedClass ?? null,
          linked_spatial_feature_id: promotedSpatialFeatureId ?? prediction.promoted_spatial_feature_id ?? null,
          admin_reviewed_by: input.reviewedBy,
          admin_reviewed_at: new Date().toISOString(),
          use_for_future_training: input.approvalStatus === 'approved',
          contributor_validation_summary: validationSummary,
        }),
      ],
    );

    const refreshed = await loadPredictionForProject({
      projectId: input.projectId,
      predictionId: input.predictionId,
      client,
    });
    return predictionDetailsPayload({ prediction: refreshed, user, client });
  });
};

const listPredictionFeatureValidations = async ({
  projectId,
  predictionId,
}: {
  projectId: string;
  predictionId: string;
}) => {
  await loadPredictionForProject({ projectId, predictionId });
  const [validations, summary] = await Promise.all([
    listValidationsForPrediction(predictionId),
    validationSummaryForPrediction(predictionId),
  ]);
  return {
    validations,
    summary,
  };
};

const getMyPredictionFeatureValidation = async ({
  projectId,
  predictionId,
  user,
}: {
  projectId: string;
  predictionId: string;
  user: Express.UserContext;
}) => {
  await loadPredictionForProject({ projectId, predictionId });
  if (user.role !== 'contributor') {
    return null;
  }
  return myValidationForPrediction({ predictionId, userId: user.id });
};

const getRunPredictionValidationSummary = async ({
  projectId,
  runId,
}: {
  projectId: string;
  runId: string;
}) => {
  const result = await query(
    `WITH prediction_rows AS (
       SELECT p.id,
              p.confidence,
              p.status,
              p.admin_validation_status,
              p.promoted_spatial_feature_id,
              l.status AS layer_status,
              l.published_at AS layer_published_at
       FROM ai_prediction_feature p
       JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
       WHERE p.project_id = $1
         AND p.ai_run_id = $2
         AND l.layer_type = 'classification'
     ),
     validation_rows AS (
       SELECT v.ai_prediction_feature_id,
              COUNT(*)::int AS validation_count
       FROM ai_prediction_feature_validation v
       WHERE v.project_id = $1
         AND v.ai_run_id = $2
       GROUP BY v.ai_prediction_feature_id
     )
     SELECT COUNT(p.id)::int AS total_ai_features,
            COUNT(p.id) FILTER (
              WHERE p.layer_status = 'published'
                AND p.layer_published_at IS NOT NULL
            )::int AS published_features,
            COALESCE(SUM(v.validation_count), 0)::int AS contributor_validations_submitted,
            COUNT(p.id) FILTER (WHERE COALESCE(v.validation_count, 0) > 0)::int
              AS features_validated_by_contributor,
            COUNT(p.id) FILTER (
              WHERE p.admin_validation_status = 'approved'
                 OR p.promoted_spatial_feature_id IS NOT NULL
            )::int AS admin_approved_promoted,
            COUNT(p.id) FILTER (
              WHERE p.admin_validation_status = 'rejected'
                 OR p.status = 'rejected'
            )::int AS rejected,
            COUNT(p.id) FILTER (
              WHERE p.admin_validation_status IS NULL
                 OR p.admin_validation_status = 'needs_more_validation'
            )::int AS pending,
            COUNT(p.id) FILTER (WHERE p.confidence IS NULL)::int AS confidence_unknown,
            COUNT(p.id) FILTER (WHERE p.confidence IS NOT NULL AND p.confidence < 0.5)::int
              AS confidence_below_50,
            COUNT(p.id) FILTER (WHERE p.confidence >= 0.5 AND p.confidence < 0.8)::int
              AS confidence_50_to_80,
            COUNT(p.id) FILTER (WHERE p.confidence >= 0.8)::int AS confidence_80_plus
     FROM prediction_rows p
     LEFT JOIN validation_rows v ON v.ai_prediction_feature_id = p.id`,
    [projectId, runId],
  );
  const row = result.rows[0] ?? {};
  return {
    project_id: projectId,
    ai_run_id: runId,
    one_classification_layer: true,
    confidence_is_attribute: true,
    confidence_threshold_filters_validation: false,
    total_ai_features: Number(row.total_ai_features ?? 0),
    published_features: Number(row.published_features ?? 0),
    contributor_validations_submitted: Number(row.contributor_validations_submitted ?? 0),
    features_validated_by_contributor: Number(row.features_validated_by_contributor ?? 0),
    admin_approved_promoted: Number(row.admin_approved_promoted ?? 0),
    rejected: Number(row.rejected ?? 0),
    pending: Number(row.pending ?? 0),
    confidence_distribution: {
      unknown: Number(row.confidence_unknown ?? 0),
      below_50: Number(row.confidence_below_50 ?? 0),
      from_50_to_80: Number(row.confidence_50_to_80 ?? 0),
      from_80_up: Number(row.confidence_80_plus ?? 0),
    },
  };
};

const listRunPredictionValidations = async ({
  projectId,
  runId,
  page = 1,
  limit = 50,
}: {
  projectId: string;
  runId: string;
  page?: number;
  limit?: number;
}) => {
  const safePage = Number.isInteger(page) && page > 0 ? page : 1;
  const safeLimit = Number.isInteger(limit) && limit > 0 ? Math.min(limit, 100) : 50;
  const offset = (safePage - 1) * safeLimit;
  const result = await query(
    `SELECT p.id,
            p.artifact_feature_id,
            p.predicted_class,
            p.confidence,
            p.status,
            p.admin_validation_status,
            p.approved_class,
            p.promoted_spatial_feature_id,
            COUNT(v.id)::int AS validation_count,
            COUNT(v.id) FILTER (WHERE v.validation_result = 'correct')::int AS correct,
            COUNT(v.id) FILTER (WHERE v.validation_result = 'incorrect')::int AS incorrect,
            COUNT(v.id) FILTER (WHERE v.validation_result = 'unsure')::int AS unsure,
            COUNT(v.id) FILTER (WHERE v.validation_result = 'cannot_verify')::int AS cannot_verify
     FROM ai_prediction_feature p
     JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
     LEFT JOIN ai_prediction_feature_validation v ON v.ai_prediction_feature_id = p.id
     WHERE p.project_id = $1
       AND p.ai_run_id = $2
       AND l.layer_type = 'classification'
     GROUP BY p.id
     ORDER BY p.created_at ASC, p.artifact_feature_id ASC
     LIMIT $3 OFFSET $4`,
    [projectId, runId, safeLimit, offset],
  );
  const countResult = await query(
    `SELECT COUNT(*)::int AS total
     FROM ai_prediction_feature p
     JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
     WHERE p.project_id = $1
       AND p.ai_run_id = $2
       AND l.layer_type = 'classification'`,
    [projectId, runId],
  );
  const total = Number(countResult.rows[0]?.total ?? 0);
  return {
    predictions: result.rows.map((row) => ({
      id: row.id,
      artifact_feature_id: row.artifact_feature_id,
      predicted_class: row.predicted_class,
      confidence: row.confidence === null ? null : Number(row.confidence),
      status: row.status,
      admin_validation_status: row.admin_validation_status,
      approved_class: row.approved_class,
      promoted_spatial_feature_id: row.promoted_spatial_feature_id,
      validation_summary: {
        total: Number(row.validation_count ?? 0),
        correct: Number(row.correct ?? 0),
        incorrect: Number(row.incorrect ?? 0),
        unsure: Number(row.unsure ?? 0),
        cannot_verify: Number(row.cannot_verify ?? 0),
      },
    })),
    pagination: {
      page: safePage,
      limit: safeLimit,
      total,
      pages: Math.max(1, Math.ceil(total / safeLimit)),
      has_more: offset + result.rows.length < total,
    },
  };
};

export {
  createPredictionFeatureValidation,
  getMyPredictionFeatureValidation,
  getPredictionFeatureDetailsForUser,
  getRunPredictionValidationSummary,
  listPredictionFeatureValidations,
  listRunPredictionValidations,
  reviewPredictionFeature,
};
