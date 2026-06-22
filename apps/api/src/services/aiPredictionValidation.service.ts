import type { PoolClient } from 'pg';
import { query, transaction } from '../config/database';
import { AppError } from '../middleware/error';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';

type JsonRecord = Record<string, unknown>;

type TaskStatus =
  | 'open'
  | 'assigned'
  | 'in_progress'
  | 'submitted'
  | 'accepted'
  | 'rejected'
  | 'cancelled';

type SubmissionResult = 'correct' | 'wrong_class' | 'not_target_class' | 'unsure';
type ReviewDecision = 'accepted' | 'rejected';

type PaginationOptions = {
  page?: number;
  limit?: number;
};

type TaskFilterOptions = PaginationOptions & {
  status?: string | null;
  assignedTo?: string | null;
  aiRunId?: string | null;
};

type GenerateTasksInput = {
  projectId: string;
  createdBy: string;
  aiRunId?: string | null;
  aiOutputLayerId?: string | null;
  aiPredictionFeatureId?: string | null;
  confidenceThreshold?: number | null;
  limit?: number | null;
  priority?: number | null;
};

type SubmitValidationInput = {
  taskId: string;
  submittedBy: string;
  result: SubmissionResult;
  correctedClass?: string | null;
  note?: string | null;
  evidence?: JsonRecord | null;
  linkedFeatureId?: string | null;
};

type ReviewValidationInput = {
  taskId: string;
  reviewedBy: string;
  decision: ReviewDecision;
  reason?: string | null;
  submissionId?: string | null;
};

const DEFAULT_VALIDATION_CONFIDENCE_THRESHOLD = 0.6;
const MAX_GENERATION_LIMIT = 10000;
const DEFAULT_PAGE_LIMIT = 50;
const ACTIVE_TASK_STATUSES = ['open', 'assigned', 'in_progress', 'submitted'];
const ALL_TASK_STATUSES = [
  'open',
  'assigned',
  'in_progress',
  'submitted',
  'accepted',
  'rejected',
  'cancelled',
];
const unclassifiedLabel = 'Unclassified';

const isProtectedSuperAdminUser = (user: Express.UserContext | undefined): boolean =>
  user?.role === 'admin' && isProtectedSuperAdminEmail(user.email);

const contributorHasApprovedProjectAccess = async ({
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
         AND status = 'approved'
     ) AS has_project_assignment`,
    [projectId, userId],
  );
  return result.rows[0]?.has_project_assignment === true;
};

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

const parsePageLimit = ({ page, limit }: PaginationOptions) => {
  const parsedPage = Number.isInteger(page) && Number(page) > 0 ? Number(page) : 1;
  const parsedLimit =
    Number.isInteger(limit) && Number(limit) > 0
      ? Math.min(Number(limit), 100)
      : DEFAULT_PAGE_LIMIT;
  return {
    page: parsedPage,
    limit: parsedLimit,
    offset: (parsedPage - 1) * parsedLimit,
  };
};

const parseGenerationLimit = (limit: number | null | undefined): number => {
  if (!Number.isInteger(limit) || Number(limit) <= 0) {
    return MAX_GENERATION_LIMIT;
  }
  return Math.min(Number(limit), MAX_GENERATION_LIMIT);
};

const parsePriority = (priority: number | null | undefined): number => {
  if (!Number.isInteger(priority) || Number(priority) < 0) {
    return 0;
  }
  return Number(priority);
};

const readThresholdFromRecord = (
  value: unknown,
  sourcePrefix: string,
): { value: number; source: string } | null => {
  const record = toJsonRecord(value);
  const directKeys = [
    'validation_confidence_threshold',
    'low_confidence_threshold',
    'confidence_threshold',
  ];
  for (const key of directKeys) {
    const parsed = toOptionalNumber(record[key]);
    if (parsed !== null && parsed >= 0 && parsed <= 1) {
      return {
        value: parsed,
        source: `${sourcePrefix}.${key}`,
      };
    }
  }

  for (const nestedKey of ['confidence_summary', 'validation', 'prediction_validation']) {
    const nested = toJsonRecord(record[nestedKey]);
    for (const key of directKeys) {
      const parsed = toOptionalNumber(nested[key]);
      if (parsed !== null && parsed >= 0 && parsed <= 1) {
        return {
          value: parsed,
          source: `${sourcePrefix}.${nestedKey}.${key}`,
        };
      }
    }
  }

  return null;
};

const resolveGenerationThreshold = async ({
  projectId,
  aiRunId,
  requestedThreshold,
}: {
  projectId: string;
  aiRunId?: string | null;
  requestedThreshold?: number | null;
}): Promise<{ value: number; source: string }> => {
  if (requestedThreshold !== null && requestedThreshold !== undefined) {
    if (requestedThreshold < 0 || requestedThreshold > 1) {
      throw new AppError('confidence_threshold must be between 0 and 1.', 400);
    }
    return {
      value: requestedThreshold,
      source: 'request.confidence_threshold',
    };
  }

  const result = await query(
    `SELECT ar.metadata AS run_metadata,
            aps.confidence_threshold AS settings_confidence_threshold,
            aps.model_preferences AS settings_model_preferences
     FROM project p
     LEFT JOIN ai_project_settings aps ON aps.project_id = p.id
     LEFT JOIN ai_run ar ON ar.project_id = p.id
       AND ($2::uuid IS NULL OR ar.id = $2)
     WHERE p.id = $1
     ORDER BY ar.created_at DESC NULLS LAST
     LIMIT 1`,
    [projectId, aiRunId ?? null],
  );

  if (result.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  const row = result.rows[0];
  const runThreshold = readThresholdFromRecord(row.run_metadata, 'ai_run.metadata');
  if (runThreshold) {
    return runThreshold;
  }
  const settingsPreferenceThreshold = readThresholdFromRecord(
    row.settings_model_preferences,
    'ai_project_settings.model_preferences',
  );
  if (settingsPreferenceThreshold) {
    return settingsPreferenceThreshold;
  }
  const settingsThreshold = toOptionalNumber(row.settings_confidence_threshold);
  if (settingsThreshold !== null && settingsThreshold >= 0 && settingsThreshold <= 1) {
    return {
      value: settingsThreshold,
      source: 'ai_project_settings.confidence_threshold',
    };
  }

  return {
    value: DEFAULT_VALIDATION_CONFIDENCE_THRESHOLD,
    source: 'default',
  };
};

const preferredCandidateLayerType = async ({
  projectId,
  aiRunId,
  aiOutputLayerId,
}: {
  projectId: string;
  aiRunId?: string | null;
  aiOutputLayerId?: string | null;
}): Promise<'classification' | 'confidence' | 'uncertainty'> => {
  if (aiOutputLayerId) {
    const layerResult = await query(
      `SELECT layer_type
       FROM ai_output_layer
       WHERE id = $1
         AND project_id = $2
         AND ($3::uuid IS NULL OR ai_run_id = $3)`,
      [aiOutputLayerId, projectId, aiRunId ?? null],
    );
    if (layerResult.rows.length === 0) {
      throw new AppError('AI output layer not found for this project.', 404);
    }
    return layerResult.rows[0].layer_type;
  }

  const classificationResult = await query(
    `SELECT 1
     FROM ai_prediction_feature p
     JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
     WHERE p.project_id = $1
       AND ($2::uuid IS NULL OR p.ai_run_id = $2)
       AND l.layer_type = 'classification'
     LIMIT 1`,
    [projectId, aiRunId ?? null],
  );
  return classificationResult.rows.length > 0 ? 'classification' : 'uncertainty';
};

const pushTaskFilters = ({
  params,
  conditions,
  filters,
  tableAlias,
}: {
  params: unknown[];
  conditions: string[];
  filters: TaskFilterOptions;
  tableAlias: string;
}): void => {
  const status = normalizeOptionalString(filters.status);
  if (status) {
    conditions.push(
      `${tableAlias}.status = $${params.length + 1}::ai_prediction_validation_task_status`,
    );
    params.push(status);
  }
  const assignedTo = normalizeOptionalString(filters.assignedTo);
  if (assignedTo) {
    conditions.push(`${tableAlias}.assigned_to = $${params.length + 1}`);
    params.push(assignedTo);
  }
  const aiRunId = normalizeOptionalString(filters.aiRunId);
  if (aiRunId) {
    conditions.push(`${tableAlias}.ai_run_id = $${params.length + 1}`);
    params.push(aiRunId);
  }
};

const taskSelectSql = `
  SELECT t.id,
         t.project_id,
         t.ai_run_id,
         t.ai_prediction_feature_id,
         t.status,
         t.assigned_to,
         assigned_user.full_name AS assigned_to_name,
         t.created_by,
         created_user.full_name AS created_by_name,
         t.reviewed_by,
         reviewed_user.full_name AS reviewed_by_name,
         t.review_decision,
         t.review_reason,
         t.priority,
         t.due_at,
         t.metadata,
         t.created_at,
         t.updated_at,
         p.artifact_feature_id,
         ST_AsGeoJSON(COALESCE(p.processed_geom, p.geom))::json AS prediction_geometry,
         p.geometry_type,
         p.predicted_class,
         p.confidence,
         p.uncertainty_score,
         p.model_name,
         p.source AS prediction_source,
         p.status AS prediction_status,
         p.metadata AS prediction_metadata,
         l.id AS ai_output_layer_id,
         l.layer_type,
         l.name AS layer_name,
         latest_submission.id AS latest_submission_id,
         latest_submission.result AS latest_submission_result,
         latest_submission.corrected_class AS latest_submission_corrected_class,
         latest_submission.note AS latest_submission_note,
         latest_submission.evidence AS latest_submission_evidence,
         latest_submission.linked_feature_id AS latest_submission_linked_feature_id,
         latest_submission.status AS latest_submission_status,
         latest_submission.submitted_by AS latest_submission_submitted_by,
         latest_submission.created_at AS latest_submission_created_at,
         latest_submission.reviewed_at AS latest_submission_reviewed_at,
         latest_submission.reviewed_by AS latest_submission_reviewed_by
  FROM ai_prediction_validation_task t
  JOIN ai_prediction_feature p ON p.id = t.ai_prediction_feature_id
  JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
  LEFT JOIN "user" assigned_user ON assigned_user.id = t.assigned_to
  LEFT JOIN "user" created_user ON created_user.id = t.created_by
  LEFT JOIN "user" reviewed_user ON reviewed_user.id = t.reviewed_by
  LEFT JOIN LATERAL (
    SELECT s.id,
           s.result,
           s.corrected_class,
           s.note,
           s.evidence,
           s.linked_feature_id,
           s.status,
           s.submitted_by,
           s.created_at,
           s.reviewed_at,
           s.reviewed_by
    FROM ai_prediction_validation_submission s
    WHERE s.validation_task_id = t.id
    ORDER BY s.created_at DESC
    LIMIT 1
  ) latest_submission ON TRUE
`;

const normalizeTaskRow = (row: any) => ({
  id: row.id,
  project_id: row.project_id,
  ai_run_id: row.ai_run_id,
  ai_prediction_feature_id: row.ai_prediction_feature_id,
  status: row.status,
  assigned_to: row.assigned_to,
  assigned_user: row.assigned_to
    ? {
        id: row.assigned_to,
        full_name: row.assigned_to_name,
      }
    : null,
  created_by: row.created_by,
  created_user: row.created_by
    ? {
        id: row.created_by,
        full_name: row.created_by_name,
      }
    : null,
  reviewed_by: row.reviewed_by,
  reviewed_user: row.reviewed_by
    ? {
        id: row.reviewed_by,
        full_name: row.reviewed_by_name,
      }
    : null,
  review_decision: row.review_decision,
  review_reason: row.review_reason,
  priority: Number(row.priority ?? 0),
  due_at: row.due_at,
  metadata: row.metadata ?? {},
  created_at: row.created_at,
  updated_at: row.updated_at,
  prediction: {
    id: row.ai_prediction_feature_id,
    artifact_feature_id: row.artifact_feature_id,
    geometry: row.prediction_geometry,
    geometry_type: row.geometry_type,
    predicted_class: row.predicted_class,
    confidence: row.confidence === null ? null : Number(row.confidence),
    uncertainty_score: row.uncertainty_score === null ? null : Number(row.uncertainty_score),
    model_name: row.model_name,
    source: row.prediction_source,
    status: row.prediction_status,
    metadata: row.prediction_metadata ?? {},
    layer: {
      id: row.ai_output_layer_id,
      layer_type: row.layer_type,
      name: row.layer_name,
    },
    not_official_field_data: true,
  },
  latest_submission: row.latest_submission_id
    ? {
        id: row.latest_submission_id,
        result: row.latest_submission_result,
        corrected_class: row.latest_submission_corrected_class,
        note: row.latest_submission_note,
        evidence: row.latest_submission_evidence ?? {},
        linked_feature_id: row.latest_submission_linked_feature_id,
        status: row.latest_submission_status,
        submitted_by: row.latest_submission_submitted_by,
        created_at: row.latest_submission_created_at,
        reviewed_at: row.latest_submission_reviewed_at,
        reviewed_by: row.latest_submission_reviewed_by,
      }
    : null,
  not_official_field_data: true,
  no_spatial_feature_writes: true,
});

const getTaskById = async (taskId: string, client?: PoolClient) => {
  const executor = client ?? { query };
  const result = await executor.query(
    `${taskSelectSql}
     WHERE t.id = $1`,
    [taskId],
  );
  if (result.rows.length === 0) {
    throw new AppError('AI prediction validation task not found', 404);
  }
  return normalizeTaskRow(result.rows[0]);
};

const candidateConditionsFor = ({
  projectId,
  aiRunId,
  aiOutputLayerId,
  aiPredictionFeatureId,
  candidateLayerType,
}: {
  projectId: string;
  aiRunId?: string | null;
  aiOutputLayerId?: string | null;
  aiPredictionFeatureId?: string | null;
  candidateLayerType: 'classification' | 'confidence' | 'uncertainty';
}) => {
  const params: unknown[] = [projectId];
  const conditions = ['p.project_id = $1'];
  const manualPredictionId = normalizeOptionalString(aiPredictionFeatureId);

  if (aiRunId) {
    params.push(aiRunId);
    conditions.push(`p.ai_run_id = $${params.length}`);
  }
  if (aiOutputLayerId) {
    params.push(aiOutputLayerId);
    conditions.push(`p.ai_output_layer_id = $${params.length}`);
  }
  if (manualPredictionId) {
    params.push(manualPredictionId);
    conditions.push(`p.id = $${params.length}`);
    return {
      params,
      whereSql: conditions.join(' AND '),
      criterion: 'manual_prediction',
    };
  }

  params.push(candidateLayerType);
  conditions.push(`l.layer_type = $${params.length}::ai_output_layer_type`);

  if (candidateLayerType === 'uncertainty') {
    return {
      params,
      whereSql: conditions.join(' AND '),
      criterion: 'uncertainty_layer',
    };
  }

  return {
    params,
    whereSql: conditions.join(' AND '),
    criterion: 'all_predictions',
  };
};

const countCandidateTasks = async ({
  whereSql,
  params,
}: {
  whereSql: string;
  params: unknown[];
}) => {
  const result = await query(
    `SELECT COUNT(*)::int AS candidate_count,
            COUNT(t.id)::int AS existing_active_count
     FROM ai_prediction_feature p
     JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
     LEFT JOIN ai_prediction_validation_task t
       ON t.ai_prediction_feature_id = p.id
      AND t.status = ANY($${params.length + 1}::ai_prediction_validation_task_status[])
     WHERE ${whereSql}`,
    [...params, ACTIVE_TASK_STATUSES],
  );
  return {
    candidateCount: Number(result.rows[0]?.candidate_count ?? 0),
    existingActiveCount: Number(result.rows[0]?.existing_active_count ?? 0),
  };
};

const generatePredictionValidationTasks = async (input: GenerateTasksInput) => {
  const threshold = await resolveGenerationThreshold({
    projectId: input.projectId,
    aiRunId: input.aiRunId,
    requestedThreshold: input.confidenceThreshold,
  });
  const candidateLayerType = await preferredCandidateLayerType({
    projectId: input.projectId,
    aiRunId: input.aiRunId,
    aiOutputLayerId: input.aiOutputLayerId,
  });
  const { params, whereSql, criterion } = candidateConditionsFor({
    projectId: input.projectId,
    aiRunId: input.aiRunId,
    aiOutputLayerId: input.aiOutputLayerId,
    aiPredictionFeatureId: input.aiPredictionFeatureId,
    candidateLayerType,
  });
  const limit = parseGenerationLimit(input.limit);
  const priority = parsePriority(input.priority);
  const counts = await countCandidateTasks({ whereSql, params });
  const generationMetadata = {
    phase: 'phase_s1_prediction_validation',
    mode: input.aiPredictionFeatureId ? 'manual_prediction' : 'auto_candidate_generation',
    criterion,
    threshold: threshold.value,
    threshold_source: threshold.source,
    confidence_used_for_priority_only: true,
    candidate_layer_type: candidateLayerType,
    ai_run_id: input.aiRunId ?? null,
    ai_output_layer_id: input.aiOutputLayerId ?? null,
    created_by: input.createdBy,
    no_spatial_feature_writes: true,
    not_official_field_data: true,
  };

  const insertResult = await query(
    `INSERT INTO ai_prediction_validation_task (
       project_id,
       ai_run_id,
       ai_prediction_feature_id,
       status,
       created_by,
       priority,
       metadata
     )
     SELECT p.project_id,
            p.ai_run_id,
            p.id,
            'open',
            $${params.length + 1},
            $${params.length + 2},
            $${params.length + 3}::jsonb || jsonb_build_object(
              'prediction_snapshot',
              jsonb_build_object(
                'ai_prediction_feature_id', p.id,
                'artifact_feature_id', p.artifact_feature_id,
                'ai_output_layer_id', p.ai_output_layer_id,
                'layer_type', l.layer_type,
                'predicted_class', p.predicted_class,
                'confidence', p.confidence,
                'uncertainty_score', p.uncertainty_score,
                'model_name', p.model_name,
                'source', p.source
              )
            )
     FROM ai_prediction_feature p
     JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
     WHERE ${whereSql}
       AND NOT EXISTS (
         SELECT 1
         FROM ai_prediction_validation_task existing
         WHERE existing.ai_prediction_feature_id = p.id
           AND existing.status = ANY($${params.length + 4}::ai_prediction_validation_task_status[])
       )
     ORDER BY COALESCE(p.confidence, 0) ASC,
              COALESCE(p.uncertainty_score, 0) DESC,
              p.created_at ASC,
              p.artifact_feature_id ASC
     LIMIT $${params.length + 5}
     RETURNING id`,
    [
      ...params,
      input.createdBy,
      priority,
      JSON.stringify({
        generation: generationMetadata,
      }),
      ACTIVE_TASK_STATUSES,
      limit,
    ],
  );

  return {
    created_count: insertResult.rowCount ?? 0,
    candidate_count: counts.candidateCount,
    existing_active_count: counts.existingActiveCount,
    threshold: threshold.value,
    threshold_source: threshold.source,
    candidate_layer_type: candidateLayerType,
    criterion,
    task_ids: insertResult.rows.map((row) => row.id),
    no_spatial_feature_writes: true,
  };
};

const listProjectPredictionValidationTasks = async (
  projectId: string,
  filters: TaskFilterOptions,
) => {
  const { page, limit, offset } = parsePageLimit(filters);
  const params: unknown[] = [projectId];
  const conditions = ['t.project_id = $1'];
  pushTaskFilters({
    params,
    conditions,
    filters,
    tableAlias: 't',
  });

  const whereSql = conditions.join(' AND ');
  const result = await query(
    `${taskSelectSql}
     WHERE ${whereSql}
     ORDER BY t.priority DESC, t.created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, limit, offset],
  );
  const countResult = await query(
    `SELECT COUNT(*)::int AS total
     FROM ai_prediction_validation_task t
     WHERE ${whereSql}`,
    params,
  );
  const statusResult = await query(
    `SELECT status, COUNT(*)::int AS count
     FROM ai_prediction_validation_task
     WHERE project_id = $1
     GROUP BY status
     ORDER BY status ASC`,
    [projectId],
  );
  const total = Number(countResult.rows[0]?.total ?? 0);

  return {
    tasks: result.rows.map(normalizeTaskRow),
    pagination: {
      page,
      limit,
      total,
      pages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + result.rows.length < total,
    },
    status_counts: Object.fromEntries(
      statusResult.rows.map((row) => [row.status, Number(row.count ?? 0)]),
    ),
  };
};

const listAssignedPredictionValidationTasks = async (
  user: Express.UserContext,
  filters: TaskFilterOptions,
) => {
  if (user.role !== 'contributor') {
    throw new AppError('Only project contributors can access AI validation tasks.', 403);
  }

  const { page, limit, offset } = parsePageLimit(filters);
  const params: unknown[] = [user.id];
  const conditions = [
    `EXISTS (
       SELECT 1
       FROM project_assignment pa
       WHERE pa.project_id = t.project_id
         AND pa.user_id = $1
         AND pa.status = 'approved'
     )`,
    `(
       (t.assigned_to IS NULL AND t.status IN ('open', 'submitted'))
       OR t.assigned_to = $1
       OR EXISTS (
         SELECT 1
         FROM ai_prediction_validation_submission own_submission
         WHERE own_submission.validation_task_id = t.id
           AND own_submission.submitted_by = $1
       )
     )`,
  ];
  pushTaskFilters({
    params,
    conditions,
    filters,
    tableAlias: 't',
  });
  const whereSql = conditions.join(' AND ');

  const result = await query(
    `${taskSelectSql}
     WHERE ${whereSql}
     ORDER BY t.priority DESC, t.created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, limit, offset],
  );
  const countResult = await query(
    `SELECT COUNT(*)::int AS total
     FROM ai_prediction_validation_task t
     WHERE ${whereSql}`,
    params,
  );
  const statusResult = await query(
    `SELECT t.status, COUNT(*)::int AS count
     FROM ai_prediction_validation_task t
     WHERE EXISTS (
       SELECT 1
       FROM project_assignment pa
       WHERE pa.project_id = t.project_id
         AND pa.user_id = $1
         AND pa.status = 'approved'
     )
       AND (
         (t.assigned_to IS NULL AND t.status IN ('open', 'submitted'))
         OR t.assigned_to = $1
         OR EXISTS (
           SELECT 1
           FROM ai_prediction_validation_submission own_submission
           WHERE own_submission.validation_task_id = t.id
             AND own_submission.submitted_by = $1
         )
       )
     GROUP BY t.status
     ORDER BY t.status ASC`,
    [user.id],
  );
  const total = Number(countResult.rows[0]?.total ?? 0);

  return {
    tasks: result.rows.map(normalizeTaskRow),
    pagination: {
      page,
      limit,
      total,
      pages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + result.rows.length < total,
    },
    status_counts: Object.fromEntries(
      statusResult.rows.map((row) => [row.status, Number(row.count ?? 0)]),
    ),
  };
};

const getPredictionValidationTaskForUser = async (taskId: string, user: Express.UserContext) => {
  const task = await getTaskById(taskId);
  if (user.role === 'admin' || isProtectedSuperAdminUser(user)) {
    return task;
  }
  if (user.role === 'contributor') {
    const hasProjectAccess = await contributorHasApprovedProjectAccess({
      projectId: task.project_id,
      userId: user.id,
    });
    if (!hasProjectAccess) {
      throw new AppError('You do not have access to this AI validation task.', 403);
    }
    if (!task.assigned_to || task.assigned_to === user.id) {
      return task;
    }
    const ownSubmission = await query(
      `SELECT 1
       FROM ai_prediction_validation_submission
       WHERE validation_task_id = $1
         AND submitted_by = $2
       LIMIT 1`,
      [taskId, user.id],
    );
    if (ownSubmission.rows.length > 0) {
      return task;
    }
  }
  throw new AppError('You do not have access to this AI validation task.', 403);
};

const assertContributorAssignable = async ({
  projectId,
  userId,
  client,
}: {
  projectId: string;
  userId: string;
  client: PoolClient;
}) => {
  const result = await client.query(
    `SELECT u.id,
            u.role,
            u.is_active,
            EXISTS (
              SELECT 1
              FROM project_assignment pa
              WHERE pa.project_id = $1
                AND pa.user_id = u.id
                AND pa.status = 'approved'
            ) AS has_project_assignment
     FROM "user" u
     WHERE u.id = $2`,
    [projectId, userId],
  );
  if (result.rows.length === 0) {
    throw new AppError('Assigned contributor not found.', 404);
  }
  const row = result.rows[0];
  if (row.role !== 'contributor' || row.is_active !== true) {
    throw new AppError('AI validation tasks can only be assigned to active contributors.', 400);
  }
  if (row.has_project_assignment !== true) {
    throw new AppError('Contributor must have approved access to this project.', 400);
  }
};

const assignPredictionValidationTask = async ({
  taskId,
  assignedTo,
}: {
  taskId: string;
  assignedTo: string;
}) =>
  transaction(async (client: PoolClient) => {
    const taskResult = await client.query(
      `SELECT id, project_id, status
       FROM ai_prediction_validation_task
       WHERE id = $1
       FOR UPDATE`,
      [taskId],
    );
    if (taskResult.rows.length === 0) {
      throw new AppError('AI prediction validation task not found', 404);
    }
    const task = taskResult.rows[0];
    if (!['open', 'assigned', 'in_progress'].includes(task.status)) {
      throw new AppError('Only open or active AI validation tasks can be assigned.', 409);
    }

    await assertContributorAssignable({
      projectId: task.project_id,
      userId: assignedTo,
      client,
    });

    await client.query(
      `UPDATE ai_prediction_validation_task
       SET assigned_to = $2,
           status = 'assigned',
           updated_at = NOW()
       WHERE id = $1`,
      [taskId, assignedTo],
    );
    return getTaskById(taskId, client);
  });

const updatePredictionValidationTaskStatus = async ({
  taskId,
  status,
}: {
  taskId: string;
  status: TaskStatus;
}) => {
  if (!ALL_TASK_STATUSES.includes(status)) {
    throw new AppError('Unsupported AI validation task status.', 400);
  }
  if (status === 'submitted') {
    throw new AppError('Submit contributor evidence to move a task to submitted.', 400);
  }
  if (status === 'accepted' || status === 'rejected') {
    throw new AppError(
      'Use the AI validation review endpoint for accepted or rejected tasks.',
      400,
    );
  }

  return transaction(async (client: PoolClient) => {
    const taskResult = await client.query(
      `SELECT id, assigned_to
       FROM ai_prediction_validation_task
       WHERE id = $1
       FOR UPDATE`,
      [taskId],
    );
    if (taskResult.rows.length === 0) {
      throw new AppError('AI prediction validation task not found', 404);
    }
    const task = taskResult.rows[0];
    if ((status === 'assigned' || status === 'in_progress') && !task.assigned_to) {
      throw new AppError('Task must be assigned before it can use this status.', 400);
    }

    await client.query(
      `UPDATE ai_prediction_validation_task
       SET status = $2::ai_prediction_validation_task_status,
           assigned_to = CASE WHEN $2 = 'open' THEN NULL ELSE assigned_to END,
           updated_at = NOW()
       WHERE id = $1`,
      [taskId, status],
    );
    return getTaskById(taskId, client);
  });
};

const collectClassLabelsFromMetadata = (metadata: unknown): string[] => {
  const record = toJsonRecord(metadata);
  const labels = new Set<string>();
  const addLabel = (value: unknown) => {
    const label = normalizeOptionalString(value);
    if (label) {
      labels.add(label);
    }
  };
  const addArrayLabels = (value: unknown) => {
    if (!Array.isArray(value)) {
      return;
    }
    for (const item of value) {
      if (typeof item === 'string') {
        addLabel(item);
      } else {
        const itemRecord = toJsonRecord(item);
        addLabel(itemRecord.class_label);
        addLabel(itemRecord.label);
        addLabel(itemRecord.class);
        addLabel(itemRecord.predicted_class);
      }
    }
  };

  addArrayLabels(record.class_counts);
  addArrayLabels(record.label_counts);
  addArrayLabels(record.eligible_classes);
  addArrayLabels(record.trained_classes);
  addArrayLabels(record.classes);
  addArrayLabels(toJsonRecord(record.model_metrics_summary).classes);

  return Array.from(labels);
};

const eligibleClassLabelsForRun = async (aiRunId: string): Promise<string[]> => {
  const result = await query(
    `SELECT ar.metadata,
            ARRAY(
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
  const row = result.rows[0];
  const labels = new Set<string>();
  for (const label of row.statistic_labels ?? []) {
    const normalized = normalizeOptionalString(label);
    if (normalized) {
      labels.add(normalized);
    }
  }
  for (const label of collectClassLabelsFromMetadata(row.metadata)) {
    labels.add(label);
  }
  if (labels.size === 0) {
    for (const label of row.prediction_labels ?? []) {
      const normalized = normalizeOptionalString(label);
      if (normalized) {
        labels.add(normalized);
      }
    }
  }
  return Array.from(labels);
};

const assertCorrectedClassEligible = async ({
  aiRunId,
  correctedClass,
}: {
  aiRunId: string;
  correctedClass: string;
}) => {
  if (isUnclassifiedLabel(correctedClass)) {
    return;
  }
  const labels = await eligibleClassLabelsForRun(aiRunId);
  if (labels.length === 0) {
    throw new AppError('No eligible AI class list is available for this run.', 409);
  }
  const normalizedAllowed = new Set(labels.map(normalizeClassLabel));
  if (!normalizedAllowed.has(normalizeClassLabel(correctedClass))) {
    throw new AppError('corrected_class must be one of the trained AI classes.', 400);
  }
};

const assertLinkedFeaturePending = async ({
  featureId,
  projectId,
}: {
  featureId: string;
  projectId: string;
}) => {
  const result = await query(
    `SELECT id, project_id, status
     FROM spatial_feature
     WHERE id = $1`,
    [featureId],
  );
  if (result.rows.length === 0) {
    throw new AppError('linked_feature_id was not found.', 404);
  }
  const row = result.rows[0];
  if (row.project_id !== projectId) {
    throw new AppError('linked_feature_id must belong to the same project.', 400);
  }
  if (!['draft', 'pending_review'].includes(row.status)) {
    throw new AppError('linked_feature_id must reference a draft or pending feature.', 409);
  }
};

const createPredictionValidationSubmission = async (input: SubmitValidationInput) => {
  const note = normalizeOptionalString(input.note);
  if (!note) {
    throw new AppError('note is required for AI validation evidence.', 400);
  }
  if (!['correct', 'wrong_class', 'not_target_class', 'unsure'].includes(input.result)) {
    throw new AppError('Unsupported AI validation result.', 400);
  }
  const correctedClass = normalizeOptionalString(input.correctedClass);
  if (input.result === 'wrong_class' && !correctedClass) {
    throw new AppError('corrected_class is required when result is wrong_class.', 400);
  }
  if (input.result !== 'wrong_class' && correctedClass) {
    throw new AppError('corrected_class is only allowed when result is wrong_class.', 400);
  }
  if (input.result === 'not_target_class' && correctedClass) {
    throw new AppError('corrected_class must be empty when result is not_target_class.', 400);
  }

  return transaction(async (client: PoolClient) => {
    const taskResult = await client.query(
      `SELECT t.id,
              t.project_id,
              t.ai_run_id,
              t.status,
              t.assigned_to
       FROM ai_prediction_validation_task t
       WHERE t.id = $1
       FOR UPDATE`,
      [input.taskId],
    );
    if (taskResult.rows.length === 0) {
      throw new AppError('AI prediction validation task not found', 404);
    }
    const task = taskResult.rows[0];
    const hasProjectAccess = await contributorHasApprovedProjectAccess({
      projectId: task.project_id,
      userId: input.submittedBy,
      client,
    });
    if (!hasProjectAccess) {
      throw new AppError('You can only submit AI validation tasks for assigned projects.', 403);
    }
    if (task.assigned_to && task.assigned_to !== input.submittedBy) {
      throw new AppError('This AI validation task is assigned to another contributor.', 403);
    }
    if (!['open', 'assigned', 'in_progress', 'submitted'].includes(task.status)) {
      throw new AppError('This AI validation task is no longer accepting submissions.', 409);
    }
    const duplicateSubmission = await client.query(
      `SELECT id
       FROM ai_prediction_validation_submission
       WHERE validation_task_id = $1
         AND submitted_by = $2
         AND status = 'submitted'
       LIMIT 1`,
      [input.taskId, input.submittedBy],
    );
    if (duplicateSubmission.rows.length > 0) {
      throw new AppError('You already submitted active evidence for this AI validation task.', 409);
    }

    if (correctedClass) {
      await assertCorrectedClassEligible({
        aiRunId: task.ai_run_id,
        correctedClass,
      });
    }
    const linkedFeatureId = normalizeOptionalString(input.linkedFeatureId);
    if (linkedFeatureId) {
      await assertLinkedFeaturePending({
        featureId: linkedFeatureId,
        projectId: task.project_id,
      });
    }

    const submissionResult = await client.query(
      `INSERT INTO ai_prediction_validation_submission (
         validation_task_id,
         submitted_by,
         result,
         corrected_class,
         note,
         evidence,
         linked_feature_id,
         status
       )
       VALUES (
         $1,
         $2,
         $3::ai_prediction_validation_submission_result,
         $4,
         $5,
         $6::jsonb,
         $7,
         'submitted'
       )
       RETURNING id`,
      [
        input.taskId,
        input.submittedBy,
        input.result,
        correctedClass,
        note,
        JSON.stringify(input.evidence ?? {}),
        linkedFeatureId,
      ],
    );
    await client.query(
      `UPDATE ai_prediction_validation_task
       SET status = 'submitted',
           updated_at = NOW()
       WHERE id = $1`,
      [input.taskId],
    );

    return {
      submission_id: submissionResult.rows[0].id,
      task: await getTaskById(input.taskId, client),
      no_spatial_feature_writes: true,
      no_auto_approval: true,
    };
  });
};

const promoteAcceptedValidationToSpatialFeature = async ({
  client,
  taskId,
  submissionId,
  reviewedBy,
}: {
  client: PoolClient;
  taskId: string;
  submissionId: string;
  reviewedBy: string;
}): Promise<string | null> => {
  const result = await client.query(
    `SELECT t.id AS task_id,
            t.project_id,
            t.ai_run_id,
            t.ai_prediction_feature_id,
            p.predicted_class,
            p.confidence,
            p.model_name,
            p.metadata AS prediction_metadata,
            ST_AsGeoJSON(COALESCE(p.processed_geom, p.geom))::json AS prediction_geometry,
            ar.label_field,
            s.result,
            s.corrected_class,
            s.note,
            s.submitted_by,
            s.linked_feature_id
     FROM ai_prediction_validation_task t
     JOIN ai_prediction_feature p ON p.id = t.ai_prediction_feature_id
     JOIN ai_run ar ON ar.id = t.ai_run_id
     JOIN ai_prediction_validation_submission s ON s.id = $2
       AND s.validation_task_id = t.id
     WHERE t.id = $1
     FOR UPDATE OF t, p, s`,
    [taskId, submissionId],
  );
  if (result.rows.length === 0) {
    throw new AppError('Submitted AI validation evidence was not found.', 409);
  }

  const row = result.rows[0];
  const resultValue = normalizeOptionalString(row.result);
  const correctedClass = normalizeOptionalString(row.corrected_class);
  const predictedClass = normalizeOptionalString(row.predicted_class);
  const finalClass =
    resultValue === 'correct'
      ? predictedClass
      : resultValue === 'wrong_class'
        ? correctedClass
        : null;
  if (!finalClass) {
    await client.query(
      `UPDATE ai_prediction_feature
       SET status = 'rejected',
           metadata = COALESCE(metadata, '{}'::jsonb) || $2::jsonb,
           updated_at = NOW()
       WHERE id = $1`,
      [
        row.ai_prediction_feature_id,
        JSON.stringify({
          ai_validated: true,
          ai_validation_status: resultValue === 'unsure' ? 'unsure' : 'rejected',
          validation_task_id: taskId,
          validation_submission_id: submissionId,
          validated_by: reviewedBy,
          validated_at: new Date().toISOString(),
          use_for_future_training: false,
        }),
      ],
    );
    return null;
  }

  const labelField = normalizeOptionalString(row.label_field) ?? 'ai_class';
  const nowIso = new Date().toISOString();
  const attributes = {
    [labelField]: finalClass,
    source: 'ai',
    aiRunId: row.ai_run_id,
    aiPredictionId: row.ai_prediction_feature_id,
    aiPredictedClass: predictedClass,
    aiCorrectedClass: resultValue === 'wrong_class' ? finalClass : null,
    aiConfidence: row.confidence,
    aiModelName: row.model_name,
    aiValidated: true,
    aiValidationStatus: resultValue === 'wrong_class' ? 'corrected' : 'approved',
    aiValidationTaskId: taskId,
    aiValidationSubmissionId: submissionId,
    validatedBy: reviewedBy,
    validatedAt: nowIso,
    useForFutureTraining: true,
  };
  const existingLinkedFeatureId = normalizeOptionalString(row.linked_feature_id);
  if (existingLinkedFeatureId) {
    const linkedFeatureResult = await client.query(
      `UPDATE spatial_feature
       SET attributes = COALESCE(attributes, '{}'::jsonb) || $2::jsonb,
           status = 'approved',
           reviewed_at = NOW(),
           reviewed_by_user_id = $3,
           review_notes = $4,
           source = 'ai'
       WHERE id = $1
         AND project_id = $5
       RETURNING id`,
      [
        existingLinkedFeatureId,
        JSON.stringify(attributes),
        reviewedBy,
        normalizeOptionalString(row.note) ?? 'AI prediction validation accepted.',
        row.project_id,
      ],
    );
    if (linkedFeatureResult.rows.length === 0) {
      throw new AppError('linked_feature_id was not found for this project.', 404);
    }
    await client.query(
      `UPDATE ai_prediction_feature
       SET status = 'approved',
           metadata = COALESCE(metadata, '{}'::jsonb) || $2::jsonb,
           updated_at = NOW()
       WHERE id = $1`,
      [
        row.ai_prediction_feature_id,
        JSON.stringify({
          ai_validated: true,
          ai_validation_status: resultValue === 'wrong_class' ? 'corrected' : 'approved',
          validation_task_id: taskId,
          validation_submission_id: submissionId,
          linked_spatial_feature_id: existingLinkedFeatureId,
          validated_by: reviewedBy,
          validated_at: nowIso,
          use_for_future_training: true,
        }),
      ],
    );
    return existingLinkedFeatureId;
  }

  const insertResult = await client.query(
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
       source
     )
     VALUES (
       $1,
       $2,
       ST_SetSRID(ST_GeomFromGeoJSON($3::text), 4326),
       $4::jsonb,
       'approved',
       NOW(),
       NOW(),
       $5,
       $6,
       'ai'
     )
     RETURNING id`,
    [
      row.project_id,
      reviewedBy,
      JSON.stringify(row.prediction_geometry),
      JSON.stringify(attributes),
      reviewedBy,
      normalizeOptionalString(row.note) ?? 'AI prediction validation accepted.',
    ],
  );
  const featureId = insertResult.rows[0].id;

  await client.query(
    `UPDATE ai_prediction_validation_submission
     SET linked_feature_id = $2
     WHERE id = $1`,
    [submissionId, featureId],
  );
  await client.query(
    `UPDATE ai_prediction_feature
     SET status = 'approved',
         metadata = COALESCE(metadata, '{}'::jsonb) || $2::jsonb,
         updated_at = NOW()
     WHERE id = $1`,
    [
      row.ai_prediction_feature_id,
      JSON.stringify({
        ai_validated: true,
        ai_validation_status: resultValue === 'wrong_class' ? 'corrected' : 'approved',
        validation_task_id: taskId,
        validation_submission_id: submissionId,
        linked_spatial_feature_id: featureId,
        validated_by: reviewedBy,
        validated_at: nowIso,
        use_for_future_training: true,
      }),
    ],
  );

  return featureId;
};

const reviewPredictionValidationTask = async (input: ReviewValidationInput) => {
  const reason = normalizeOptionalString(input.reason);
  if (!['accepted', 'rejected'].includes(input.decision)) {
    throw new AppError('Unsupported AI validation review decision.', 400);
  }
  if (input.decision === 'rejected' && !reason) {
    throw new AppError('reason is required when rejecting an AI validation submission.', 400);
  }

  return transaction(async (client: PoolClient) => {
    const taskResult = await client.query(
      `SELECT id, status
       FROM ai_prediction_validation_task
       WHERE id = $1
       FOR UPDATE`,
      [input.taskId],
    );
    if (taskResult.rows.length === 0) {
      throw new AppError('AI prediction validation task not found', 404);
    }
    if (taskResult.rows[0].status !== 'submitted') {
      throw new AppError('Only submitted AI validation tasks can be reviewed.', 409);
    }

    const submissionParams: unknown[] = [input.taskId];
    const submissionConditions = ['validation_task_id = $1', "status = 'submitted'"];
    const submissionId = normalizeOptionalString(input.submissionId);
    if (submissionId) {
      submissionParams.push(submissionId);
      submissionConditions.push(`id = $${submissionParams.length}`);
    }
    const submissionResult = await client.query(
      `SELECT id
       FROM ai_prediction_validation_submission
       WHERE ${submissionConditions.join(' AND ')}
       ORDER BY created_at DESC
       LIMIT 1
       FOR UPDATE`,
      submissionParams,
    );
    if (submissionResult.rows.length === 0) {
      throw new AppError('Submitted AI validation evidence was not found.', 409);
    }
    const reviewedSubmissionId = submissionResult.rows[0].id;

    await client.query(
      `UPDATE ai_prediction_validation_submission
       SET status = $2::ai_prediction_validation_submission_status,
           reviewed_at = NOW(),
           reviewed_by = $3
       WHERE id = $1`,
      [reviewedSubmissionId, input.decision, input.reviewedBy],
    );
    await client.query(
      `UPDATE ai_prediction_validation_task
       SET status = $2::text::ai_prediction_validation_task_status,
           reviewed_by = $3,
           review_decision = $2::text::ai_prediction_validation_review_decision,
           review_reason = $4,
           updated_at = NOW()
       WHERE id = $1`,
      [input.taskId, input.decision, input.reviewedBy, reason],
    );
    const linkedSpatialFeatureId =
      input.decision === 'accepted'
        ? await promoteAcceptedValidationToSpatialFeature({
            client,
            taskId: input.taskId,
            submissionId: reviewedSubmissionId,
            reviewedBy: input.reviewedBy,
          })
        : null;
    if (input.decision === 'rejected') {
      await client.query(
        `UPDATE ai_prediction_feature p
         SET status = 'rejected',
             metadata = COALESCE(p.metadata, '{}'::jsonb) || $2::jsonb,
             updated_at = NOW()
         FROM ai_prediction_validation_task t
         WHERE t.ai_prediction_feature_id = p.id
           AND t.id = $1`,
        [
          input.taskId,
          JSON.stringify({
            ai_validated: true,
            ai_validation_status: 'rejected',
            validation_task_id: input.taskId,
            validation_submission_id: reviewedSubmissionId,
            validated_by: input.reviewedBy,
            validated_at: new Date().toISOString(),
            use_for_future_training: false,
          }),
        ],
      );
    }

    return {
      submission_id: reviewedSubmissionId,
      task: await getTaskById(input.taskId, client),
      linked_spatial_feature_id: linkedSpatialFeatureId,
      no_spatial_feature_writes: linkedSpatialFeatureId === null,
      no_auto_approval: input.decision !== 'accepted',
    };
  });
};

export {
  generatePredictionValidationTasks,
  listProjectPredictionValidationTasks,
  listAssignedPredictionValidationTasks,
  getPredictionValidationTaskForUser,
  assignPredictionValidationTask,
  updatePredictionValidationTaskStatus,
  createPredictionValidationSubmission,
  reviewPredictionValidationTask,
};
