import type { PoolClient, QueryResultRow } from 'pg';
import { query, transaction } from '../config/database';
import {
  createAiPipelineService,
  type AiPipelineCommandResult,
  type AiPipelineService,
} from '../services/aiPipeline.service';
import { registerAiRunArtifactsForReview } from '../services/aiArtifactRegistration.service';
const logger = require('../utils/logger');

type AiRunActiveStatus = 'extracting_features' | 'training' | 'evaluating';
type AiRunWorkerStatus = AiRunActiveStatus | 'ready_for_review';
type AiRunFinalStatus = AiRunWorkerStatus | 'failed' | 'queued';
type AiRunExecutionMode =
  | 'mock'
  | 'dry_run'
  | 'local_ground_truth_export'
  | 'regional_feature_extraction'
  | 'regional_model_eval';

type AiRunRow = QueryResultRow & {
  id: string;
  project_id: string;
  status: string;
  label_field: string;
  scope_type: string | null;
  region_preset: string | null;
  metadata: Record<string, unknown> | null;
};

type AiRunSafetySummary = {
  status: 'ready' | 'warning' | 'not_ready';
  approved_feature_count: number;
  labeled_feature_count: number;
  eligible_feature_count: number;
  excluded_feature_count: number;
  eligible_class_count: number;
  missing_label_count: number;
  invalid_geometry_count: number;
  label_counts: Array<{ class_label: string; sample_count: number }>;
  eligible_classes: Array<{ class_label: string; sample_count: number }>;
  excluded_classes: Array<{ class_label: string; sample_count: number }>;
  warnings: string[];
  blockers: string[];
};

type AiWorkerOnceOptions = {
  workerId?: string;
  dryRun?: boolean;
  mock?: boolean;
  failAtStatus?: AiRunActiveStatus | null;
  pipelineService?: AiPipelineService;
};

type AiWorkerOnceResult = {
  processed: boolean;
  dryRun: boolean;
  mock: boolean;
  executionMode: AiRunExecutionMode | null;
  pipelineEnabled: boolean;
  runId: string | null;
  projectId: string | null;
  labelField: string | null;
  initialStatus: 'queued' | null;
  finalStatus: AiRunFinalStatus | null;
  statuses: AiRunWorkerStatus[];
  logsWritten: number;
  failureReason: string | null;
};

const AI_WORKER_MOCK_STATUS_SEQUENCE: AiRunWorkerStatus[] = [
  'extracting_features',
  'training',
  'evaluating',
  'ready_for_review',
];

const AI_WORKER_PIPELINE_STATUS_SEQUENCE: AiRunWorkerStatus[] = [
  'extracting_features',
  'ready_for_review',
];

const AI_WORKER_REGIONAL_MODEL_STATUS_SEQUENCE: AiRunWorkerStatus[] = [
  'extracting_features',
  'training',
  'evaluating',
  'ready_for_review',
];

const activeStatusSet = new Set<AiRunActiveStatus>([
  'extracting_features',
  'training',
  'evaluating',
]);

const executionModeSet = new Set<AiRunExecutionMode>([
  'mock',
  'dry_run',
  'local_ground_truth_export',
  'regional_feature_extraction',
  'regional_model_eval',
]);

const LOG_METADATA_MAX_CHARS = 4000;
const WORKER_PHASE = 'phase_f_regional_worker';
const REGIONAL_SCIENTIFIC_LIMITATIONS = [
  'Regional proof-of-concept only; not a national model.',
  'AI predictions remain separate from approved field/import features.',
  'Outputs must be reviewed before any future publication.',
];

const createWorkerId = (): string => `phase-f-worker-${process.pid}-${Date.now().toString(36)}`;

const safeMetadata = (metadata: Record<string, unknown>): string => JSON.stringify(metadata);

const truncateForMetadata = (value: string): string =>
  value.length > LOG_METADATA_MAX_CHARS
    ? `${value.slice(0, LOG_METADATA_MAX_CHARS)}\n[log truncated]`
    : value;

const insertRunLog = async (
  runId: string,
  level: 'info' | 'warning' | 'error',
  message: string,
  metadata: Record<string, unknown>,
): Promise<void> => {
  await query(
    `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
     VALUES ($1, $2, $3, $4::jsonb)`,
    [runId, level, message, safeMetadata(metadata)],
  );
};

const peekQueuedAiRun = async (): Promise<AiRunRow | null> => {
  const result = await query<AiRunRow>(
    `SELECT id, project_id, status, label_field, scope_type, region_preset, metadata
     FROM ai_run
     WHERE status = 'queued'
     ORDER BY created_at ASC
     LIMIT 1`,
  );

  return result.rows[0] ?? null;
};

const claimQueuedRun = async (client: PoolClient, workerId: string): Promise<AiRunRow | null> => {
  const result = await client.query<AiRunRow>(
    `WITH candidate AS (
       SELECT id
       FROM ai_run
       WHERE status = 'queued'
       ORDER BY created_at ASC
       FOR UPDATE SKIP LOCKED
       LIMIT 1
     )
     UPDATE ai_run run
     SET status = 'extracting_features',
         started_at = COALESCE(run.started_at, CURRENT_TIMESTAMP),
         metadata = COALESCE(run.metadata, '{}'::jsonb) || $1::jsonb,
         updated_at = CURRENT_TIMESTAMP
     FROM candidate
     WHERE run.id = candidate.id
     RETURNING run.id,
               run.project_id,
               run.status,
               run.label_field,
               run.scope_type,
               run.region_preset,
               run.metadata`,
    [
      safeMetadata({
        worker_phase: WORKER_PHASE,
        worker_id: workerId,
        real_ai_execution: false,
      }),
    ],
  );

  return result.rows[0] ?? null;
};

const claimNextQueuedRun = async (workerId: string): Promise<AiRunRow | null> =>
  transaction(async (client: PoolClient) => claimQueuedRun(client, workerId));

const updateRunStatus = async (
  runId: string,
  fromStatus: AiRunWorkerStatus,
  toStatus: AiRunWorkerStatus,
  workerId: string,
  metadata: Record<string, unknown> = {},
): Promise<AiRunRow> => {
  const result = await query<AiRunRow>(
    `UPDATE ai_run
     SET status = $3,
         completed_at = CASE
           WHEN $3::ai_run_status = 'ready_for_review' THEN CURRENT_TIMESTAMP
           ELSE completed_at
         END,
         metadata = COALESCE(metadata, '{}'::jsonb) || $4::jsonb,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND status = $2
     RETURNING id, project_id, status, label_field, scope_type, region_preset, metadata`,
    [
      runId,
      fromStatus,
      toStatus,
      safeMetadata({
        worker_phase: WORKER_PHASE,
        worker_id: workerId,
        real_ai_execution: false,
        ...metadata,
      }),
    ],
  );

  if (result.rows.length === 0) {
    throw new Error(`AI run ${runId} was not in expected status ${fromStatus}.`);
  }

  return result.rows[0];
};

const failRun = async (
  runId: string,
  fromStatus: AiRunActiveStatus,
  failureReason: string,
  workerId: string,
  metadata: Record<string, unknown> = {},
): Promise<AiRunRow> => {
  const result = await query<AiRunRow>(
    `UPDATE ai_run
     SET status = 'failed',
         failed_at = CURRENT_TIMESTAMP,
         failure_reason = $3,
         metadata = COALESCE(metadata, '{}'::jsonb) || $4::jsonb,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND status = $2
     RETURNING id, project_id, status, label_field, scope_type, region_preset, metadata`,
    [
      runId,
      fromStatus,
      failureReason,
      safeMetadata({
        worker_phase: WORKER_PHASE,
        worker_id: workerId,
        real_ai_execution: false,
        ...metadata,
      }),
    ],
  );

  if (result.rows.length === 0) {
    throw new Error(`AI run ${runId} could not be failed from status ${fromStatus}.`);
  }

  return result.rows[0];
};

const emptyResult = (
  dryRun: boolean,
  mock: boolean,
  pipelineEnabled = false,
): AiWorkerOnceResult => ({
  processed: false,
  dryRun,
  mock,
  executionMode: null,
  pipelineEnabled,
  runId: null,
  projectId: null,
  labelField: null,
  initialStatus: null,
  finalStatus: null,
  statuses: [],
  logsWritten: 0,
  failureReason: null,
});

const metadataExecutionMode = (
  metadata: Record<string, unknown> | null,
): AiRunExecutionMode | null => {
  const value = metadata?.execution_mode;
  return typeof value === 'string' && executionModeSet.has(value as AiRunExecutionMode)
    ? (value as AiRunExecutionMode)
    : null;
};

const resolveExecutionMode = (
  run: AiRunRow,
  pipelineService: AiPipelineService,
  forceMock: boolean,
): { executionMode: AiRunExecutionMode; pipelineEnabled: boolean } => {
  const config = pipelineService.getConfig();
  if (forceMock || !config.enabled) {
    return {
      executionMode: 'mock',
      pipelineEnabled: config.enabled,
    };
  }

  const requestedMode = metadataExecutionMode(run.metadata);
  if (requestedMode) {
    return {
      executionMode: requestedMode,
      pipelineEnabled: config.enabled,
    };
  }

  if (executionModeSet.has(config.mode as AiRunExecutionMode)) {
    return {
      executionMode: config.mode as AiRunExecutionMode,
      pipelineEnabled: config.enabled,
    };
  }

  return {
    executionMode: 'mock',
    pipelineEnabled: config.enabled,
  };
};

const commandSummary = (result: AiPipelineCommandResult): Record<string, unknown> => ({
  command: result.command,
  success: result.success,
  exit_code: result.exitCode,
  duration_ms: result.durationMs,
  timed_out: result.timedOut,
  output_paths: result.outputPaths,
});

const outputPathsFrom = (results: AiPipelineCommandResult[]): string[] =>
  Array.from(new Set(results.flatMap((result) => result.outputPaths)));

const regionalRunIdFor = (runId: string): string => `app-ai-${runId.replace(/-/g, '').slice(0, 24)}`;

const metadataMinSamplesPerClass = (metadata: Record<string, unknown> | null): number => {
  const raw = metadata?.min_samples_per_class;
  const parsed =
    typeof raw === 'number'
      ? raw
      : typeof raw === 'string'
        ? Number.parseInt(raw, 10)
        : Number.NaN;
  return Number.isFinite(parsed) && parsed > 0 ? Math.min(parsed, 10000) : 50;
};

const requestedNationalScope = (run: AiRunRow): boolean => {
  const metadata = run.metadata ?? {};
  return (
    run.scope_type === 'national' ||
    run.region_preset === 'lebanon' ||
    metadata.national_classification === true ||
    metadata.classification_scope === 'national' ||
    metadata.scope_type === 'national' ||
    metadata.region_preset === 'lebanon'
  );
};

const summarizeRunReadiness = async (
  projectId: string,
  labelField: string,
  minSamplesPerClass: number,
): Promise<{ projectExists: boolean; projectName: string | null; summary: AiRunSafetySummary }> => {
  const projectResult = await query<{ id: string; name: string }>(
    `SELECT id, name
     FROM project
     WHERE id = $1`,
    [projectId],
  );
  const projectExists = projectResult.rows.length > 0;

  const totalsResult = await query<{
    approved_feature_count: number;
    missing_label_count: number;
    invalid_geometry_count: number;
    labeled_feature_count: number;
  }>(
    `WITH approved AS (
       SELECT geom,
              NULLIF(BTRIM(attributes ->> $2), '') AS class_label
       FROM spatial_feature
       WHERE project_id = $1
         AND status = 'approved'
     )
     SELECT COUNT(*)::int AS approved_feature_count,
            COUNT(*) FILTER (WHERE class_label IS NULL)::int AS missing_label_count,
            COUNT(*) FILTER (WHERE geom IS NULL OR NOT ST_IsValid(geom))::int AS invalid_geometry_count,
            COUNT(*) FILTER (
              WHERE class_label IS NOT NULL
                AND geom IS NOT NULL
                AND ST_IsValid(geom)
            )::int AS labeled_feature_count
     FROM approved`,
    [projectId, labelField],
  );

  const labelCountsResult = await query<{ class_label: string; sample_count: number }>(
    `SELECT NULLIF(BTRIM(attributes ->> $2), '') AS class_label,
            COUNT(*)::int AS sample_count
     FROM spatial_feature
     WHERE project_id = $1
       AND status = 'approved'
       AND geom IS NOT NULL
       AND ST_IsValid(geom)
       AND NULLIF(BTRIM(attributes ->> $2), '') IS NOT NULL
     GROUP BY class_label
     ORDER BY sample_count DESC, class_label ASC`,
    [projectId, labelField],
  );

  const totals = totalsResult.rows[0] ?? {
    approved_feature_count: 0,
    missing_label_count: 0,
    invalid_geometry_count: 0,
    labeled_feature_count: 0,
  };
  const labelCounts = labelCountsResult.rows.map((row) => ({
    class_label: row.class_label,
    sample_count: Number(row.sample_count),
  }));
  const eligibleClasses = labelCounts.filter((row) => row.sample_count >= minSamplesPerClass);
  const excludedClasses = labelCounts.filter((row) => row.sample_count < minSamplesPerClass);
  const eligibleFeatureCount = eligibleClasses.reduce(
    (total, row) => total + row.sample_count,
    0,
  );
  const warnings: string[] = [];
  const blockers: string[] = [];

  if (!projectExists) {
    blockers.push('AI run project does not exist.');
  }
  if (Number(totals.approved_feature_count) === 0) {
    blockers.push('Project has no approved field/import features available for AI.');
  }
  if (labelCounts.length === 0) {
    blockers.push(`Label field ${labelField} has no approved labels.`);
  }
  if (labelCounts.length > 0 && labelCounts.length < 2) {
    blockers.push('At least two labeled classes are required for supervised training.');
  }
  if (labelCounts.length >= 2 && eligibleClasses.length < 2) {
    blockers.push(`At least two classes must meet ${minSamplesPerClass} samples.`);
  }
  if (excludedClasses.length > 0 && eligibleClasses.length >= 2) {
    warnings.push(
      `Classes below ${minSamplesPerClass} samples will be excluded: ${excludedClasses
        .map((row) => `${row.class_label} (${row.sample_count})`)
        .join(', ')}.`,
    );
  }
  if (Number(totals.missing_label_count) > 0) {
    warnings.push('Some approved features are missing the selected label field.');
  }
  if (Number(totals.invalid_geometry_count) > 0) {
    warnings.push('Some approved features have null or invalid geometry.');
  }

  return {
    projectExists,
    projectName: projectResult.rows[0]?.name ?? null,
    summary: {
      status: blockers.length > 0 ? 'not_ready' : warnings.length > 0 ? 'warning' : 'ready',
      approved_feature_count: Number(totals.approved_feature_count),
      labeled_feature_count: Number(totals.labeled_feature_count),
      eligible_feature_count: eligibleFeatureCount,
      excluded_feature_count: Number(totals.approved_feature_count) - eligibleFeatureCount,
      eligible_class_count: eligibleClasses.length,
      missing_label_count: Number(totals.missing_label_count),
      invalid_geometry_count: Number(totals.invalid_geometry_count),
      label_counts: labelCounts,
      eligible_classes: eligibleClasses,
      excluded_classes: excludedClasses,
      warnings,
      blockers,
    },
  };
};

const buildUnsafeReason = (
  run: AiRunRow,
  executionMode: AiRunExecutionMode,
  readiness: AiRunSafetySummary,
): string | null => {
  if (!executionModeSet.has(executionMode)) {
    return `Unsupported AI execution mode: ${executionMode}.`;
  }
  if (requestedNationalScope(run)) {
    return 'National classification is not allowed in Phase F regional worker execution.';
  }
  if (readiness.status === 'not_ready') {
    return readiness.blockers[0] ?? 'AI run readiness checks did not pass.';
  }
  if (readiness.approved_feature_count <= 0) {
    return 'Approved training features are required before regional AI execution.';
  }
  if (readiness.eligible_class_count < 2) {
    return 'At least two eligible classes are required before regional AI execution.';
  }
  return null;
};

const runMockExecution = async ({
  claimedRun,
  workerId,
  failAtStatus,
  pipelineEnabled,
}: {
  claimedRun: AiRunRow;
  workerId: string;
  failAtStatus: AiRunActiveStatus | null;
  pipelineEnabled: boolean;
}): Promise<AiWorkerOnceResult> => {
  const statuses: AiRunWorkerStatus[] = ['extracting_features'];
  let logsWritten = 0;
  let currentRun = claimedRun;
  let currentStatus: AiRunWorkerStatus = 'extracting_features';

  await insertRunLog(
    claimedRun.id,
    'info',
    'AI worker mock step: extracting features. Real AI execution was not started.',
    {
      status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: 'mock',
      worker_id: workerId,
      real_ai_execution: false,
    },
  );
  logsWritten += 1;

  if (failAtStatus === currentStatus) {
    const failureReason = `Mock AI worker failure at ${currentStatus}.`;
    currentRun = await failRun(claimedRun.id, currentStatus, failureReason, workerId, {
      execution_mode: 'mock',
    });
    await insertRunLog(claimedRun.id, 'error', failureReason, {
      status: 'failed',
      failed_from_status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: 'mock',
      worker_id: workerId,
      real_ai_execution: false,
    });
    return {
      processed: true,
      dryRun: false,
      mock: true,
      executionMode: 'mock',
      pipelineEnabled,
      runId: currentRun.id,
      projectId: currentRun.project_id,
      labelField: currentRun.label_field,
      initialStatus: 'queued',
      finalStatus: 'failed',
      statuses,
      logsWritten: logsWritten + 1,
      failureReason,
    };
  }

  for (const nextStatus of AI_WORKER_MOCK_STATUS_SEQUENCE.slice(1)) {
    currentRun = await updateRunStatus(claimedRun.id, currentStatus, nextStatus, workerId, {
      execution_mode: 'mock',
    });
    currentStatus = nextStatus;
    statuses.push(nextStatus);

    await insertRunLog(
      claimedRun.id,
      'info',
      `AI worker mock step: ${nextStatus}. Real AI execution was not started.`,
      {
        status: nextStatus,
        worker_phase: WORKER_PHASE,
        execution_mode: 'mock',
        worker_id: workerId,
        real_ai_execution: false,
      },
    );
    logsWritten += 1;

    if (failAtStatus === nextStatus && activeStatusSet.has(nextStatus as AiRunActiveStatus)) {
      const failureReason = `Mock AI worker failure at ${nextStatus}.`;
      currentRun = await failRun(
        claimedRun.id,
        nextStatus as AiRunActiveStatus,
        failureReason,
        workerId,
        {
          execution_mode: 'mock',
        },
      );
      await insertRunLog(claimedRun.id, 'error', failureReason, {
        status: 'failed',
        failed_from_status: nextStatus,
        worker_phase: WORKER_PHASE,
        execution_mode: 'mock',
        worker_id: workerId,
        real_ai_execution: false,
      });
      return {
        processed: true,
        dryRun: false,
        mock: true,
        executionMode: 'mock',
        pipelineEnabled,
        runId: currentRun.id,
        projectId: currentRun.project_id,
        labelField: currentRun.label_field,
        initialStatus: 'queued',
        finalStatus: 'failed',
        statuses,
        logsWritten: logsWritten + 1,
        failureReason,
      };
    }
  }

  logger.info('AI worker mock run completed', {
    runId: currentRun.id,
    projectId: currentRun.project_id,
    statuses,
    realAiExecution: false,
  });

  return {
    processed: true,
    dryRun: false,
    mock: true,
    executionMode: 'mock',
    pipelineEnabled,
    runId: currentRun.id,
    projectId: currentRun.project_id,
    labelField: currentRun.label_field,
    initialStatus: 'queued',
    finalStatus: 'ready_for_review',
    statuses,
    logsWritten,
    failureReason: null,
  };
};

const runPipelineCommandWithLogs = async ({
  run,
  workerId,
  executionMode,
  status,
  realAiExecution,
  message,
  commandRunner,
}: {
  run: AiRunRow;
  workerId: string;
  executionMode: AiRunExecutionMode;
  status: AiRunWorkerStatus;
  realAiExecution: boolean;
  message: string;
  commandRunner: () => Promise<AiPipelineCommandResult>;
}): Promise<{ result: AiPipelineCommandResult; logsWritten: number }> => {
  await insertRunLog(run.id, 'info', `${message} started.`, {
    status,
    worker_phase: WORKER_PHASE,
    execution_mode: executionMode,
    worker_id: workerId,
    real_ai_execution: realAiExecution,
  });

  const result = await commandRunner();
  await insertRunLog(
    run.id,
    result.success ? 'info' : 'error',
    `${message} ${result.success ? 'completed' : 'failed'}.`,
    {
      status,
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      real_ai_execution: realAiExecution,
      ...commandSummary(result),
      sanitized_log: truncateForMetadata(result.sanitizedLog),
    },
  );

  return {
    result,
    logsWritten: 2,
  };
};

const runPipelineExecution = async ({
  claimedRun,
  workerId,
  executionMode,
  pipelineService,
}: {
  claimedRun: AiRunRow;
  workerId: string;
  executionMode: Exclude<AiRunExecutionMode, 'mock'>;
  pipelineService: AiPipelineService;
}): Promise<AiWorkerOnceResult> => {
  const startedAt = Date.now();
  const commandResults: AiPipelineCommandResult[] = [];
  const regionalRunId = regionalRunIdFor(claimedRun.id);
  const realAiExecution =
    executionMode === 'regional_feature_extraction' || executionMode === 'regional_model_eval';
  const statuses: AiRunWorkerStatus[] = ['extracting_features'];
  let currentStatus: AiRunActiveStatus = 'extracting_features';
  let safetySummary: AiRunSafetySummary | null = null;
  let artifactRegistrationMetadata: Record<string, unknown> | null = null;
  let logsWritten = 0;

  await insertRunLog(
    claimedRun.id,
    'info',
    'AI pipeline bridge started. Phase F allows controlled regional execution modes only.',
    {
      status: 'extracting_features',
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
    },
  );
  logsWritten += 1;

  const completionMetadata = (): Record<string, unknown> => {
    const outputPaths = outputPathsFrom(commandResults);
    const metadata: Record<string, unknown> = {
      execution_mode: executionMode,
      pipeline_bridge_phase: 'phase_f',
      worker_phase: WORKER_PHASE,
      ai_pipeline_run_id: regionalRunId,
      project_id: claimedRun.project_id,
      label_field: claimedRun.label_field,
      command_results: commandResults.map(commandSummary),
      output_paths: outputPaths,
      duration_ms: Date.now() - startedAt,
      real_ai_execution: realAiExecution,
      scientific_limitations: REGIONAL_SCIENTIFIC_LIMITATIONS,
    };

    if (safetySummary) {
      metadata.readiness_status = safetySummary.status;
      metadata.class_counts = safetySummary.label_counts;
      metadata.eligible_classes = safetySummary.eligible_classes;
      metadata.excluded_classes = safetySummary.excluded_classes;
      metadata.approved_feature_count = safetySummary.approved_feature_count;
      metadata.eligible_feature_count = safetySummary.eligible_feature_count;
      metadata.excluded_feature_count = safetySummary.excluded_feature_count;
    }
    if (
      executionMode === 'local_ground_truth_export' ||
      executionMode === 'regional_feature_extraction' ||
      executionMode === 'regional_model_eval'
    ) {
      metadata.output_directory = `outputs/projects/${claimedRun.project_id}`;
      metadata.ground_truth_path = `outputs/projects/${claimedRun.project_id}/ground_truth.geojson`;
    }
    if (
      executionMode === 'regional_feature_extraction' ||
      executionMode === 'regional_model_eval'
    ) {
      metadata.output_directory = `outputs/runs/${regionalRunId}`;
      metadata.feature_table_path = `outputs/runs/${regionalRunId}/feature_table.csv`;
      metadata.feature_extraction_summary_path =
        `outputs/runs/${regionalRunId}/feature_extraction_summary.json`;
    }
    if (executionMode === 'regional_model_eval') {
      metadata.metrics_path = `outputs/runs/${regionalRunId}/metrics.json`;
      metadata.confusion_matrix_path = `outputs/runs/${regionalRunId}/confusion_matrix.csv`;
      metadata.classification_report_path =
        `outputs/runs/${regionalRunId}/classification_report.csv`;
      metadata.feature_importance_path = `outputs/runs/${regionalRunId}/feature_importance.csv`;
      metadata.model_metadata_path = `outputs/runs/${regionalRunId}/model_metadata.json`;
      metadata.model_metrics_summary =
        artifactRegistrationMetadata?.model_metrics_summary ?? {
          source: `outputs/runs/${regionalRunId}/metrics.json`,
          note: 'Regional proof-of-concept metrics only; not national accuracy.',
        };
    }

    if (artifactRegistrationMetadata) {
      Object.assign(metadata, artifactRegistrationMetadata);
    }

    return metadata;
  };

  const failFromCurrentStatus = async (failureReason: string): Promise<AiWorkerOnceResult> => {
    await failRun(claimedRun.id, currentStatus, failureReason, workerId, completionMetadata());
    return {
      processed: true,
      dryRun: false,
      mock: false,
      executionMode,
      pipelineEnabled: true,
      runId: claimedRun.id,
      projectId: claimedRun.project_id,
      labelField: claimedRun.label_field,
      initialStatus: 'queued',
      finalStatus: 'failed',
      statuses,
      logsWritten,
      failureReason,
    };
  };

  if (executionMode !== 'dry_run') {
    const minSamplesPerClass = metadataMinSamplesPerClass(claimedRun.metadata);
    const readiness = await summarizeRunReadiness(
      claimedRun.project_id,
      claimedRun.label_field,
      minSamplesPerClass,
    );
    safetySummary = readiness.summary;

    await insertRunLog(claimedRun.id, 'info', 'AI regional safety checks completed.', {
      status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
      project_exists: readiness.projectExists,
      project_name: readiness.projectName,
      min_samples_per_class: minSamplesPerClass,
      readiness: safetySummary,
    });
    logsWritten += 1;

    const unsafeReason = buildUnsafeReason(claimedRun, executionMode, safetySummary);
    if (unsafeReason) {
      await insertRunLog(claimedRun.id, 'error', unsafeReason, {
        status: 'failed',
        failed_from_status: currentStatus,
        worker_phase: WORKER_PHASE,
        execution_mode: executionMode,
        worker_id: workerId,
        ai_pipeline_run_id: regionalRunId,
        real_ai_execution: realAiExecution,
      });
      logsWritten += 1;
      return failFromCurrentStatus(unsafeReason);
    }
  }

  const steps: Array<{
    message: string;
    run: () => Promise<AiPipelineCommandResult>;
  }> = [
    {
      message: 'AI pipeline config check',
      run: () => pipelineService.checkConfig(),
    },
    {
      message: 'AI pipeline dry-run',
      run: () => pipelineService.dryRun(),
    },
    {
      message: 'AI pipeline project readiness probe',
      run: () => pipelineService.probeProject(claimedRun.project_id, claimedRun.label_field),
    },
  ];

  if (executionMode === 'local_ground_truth_export') {
    steps.push({
      message: 'AI local-only ground truth export',
      run: () =>
        pipelineService.exportGroundTruthLocal(claimedRun.project_id, claimedRun.label_field),
    });
  }
  if (
    executionMode === 'regional_feature_extraction' ||
    executionMode === 'regional_model_eval'
  ) {
    steps.push(
      {
        message: 'AI local-only ground truth export',
        run: () =>
          pipelineService.exportGroundTruthLocal(claimedRun.project_id, claimedRun.label_field),
      },
      {
        message: 'AI regional Sentinel-2 feature extraction',
        run: () =>
          pipelineService.extractRegionalFeatures(
            claimedRun.project_id,
            claimedRun.label_field,
            regionalRunId,
          ),
      },
    );
  }

  for (const step of steps) {
    const { result, logsWritten: stepLogsWritten } = await runPipelineCommandWithLogs({
      run: claimedRun,
      workerId,
      executionMode,
      status: currentStatus,
      realAiExecution,
      message: step.message,
      commandRunner: step.run,
    });
    commandResults.push(result);
    logsWritten += stepLogsWritten;

    if (!result.success) {
      const failureReason = `AI pipeline ${result.command} failed during Phase F regional worker execution.`;
      return failFromCurrentStatus(failureReason);
    }
  }

  if (executionMode === 'regional_model_eval') {
    await updateRunStatus(claimedRun.id, currentStatus, 'training', workerId, completionMetadata());
    currentStatus = 'training';
    statuses.push('training');
    await insertRunLog(claimedRun.id, 'info', 'AI regional model evaluation started.', {
      status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
    });
    logsWritten += 1;

    const { result, logsWritten: modelLogsWritten } = await runPipelineCommandWithLogs({
      run: claimedRun,
      workerId,
      executionMode,
      status: currentStatus,
      realAiExecution,
      message: 'AI regional model evaluation',
      commandRunner: () =>
        pipelineService.evaluateRegionalModel(
          claimedRun.project_id,
          claimedRun.label_field,
          regionalRunId,
        ),
    });
    commandResults.push(result);
    logsWritten += modelLogsWritten;

    if (!result.success) {
      const failureReason = `AI pipeline ${result.command} failed during Phase F regional worker execution.`;
      return failFromCurrentStatus(failureReason);
    }

    await updateRunStatus(claimedRun.id, currentStatus, 'evaluating', workerId, completionMetadata());
    currentStatus = 'evaluating';
    statuses.push('evaluating');
    await insertRunLog(claimedRun.id, 'info', 'AI regional model metrics are ready for review.', {
      status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
      metrics_path: `outputs/runs/${regionalRunId}/metrics.json`,
    });
    logsWritten += 1;

    try {
      const registrationResult = await registerAiRunArtifactsForReview({
        runId: claimedRun.id,
        projectId: claimedRun.project_id,
        labelField: claimedRun.label_field,
        metadata: completionMetadata(),
        pipelineConfig: pipelineService.getConfig(),
      });
      artifactRegistrationMetadata = registrationResult.metadataPatch;
      await insertRunLog(
        claimedRun.id,
        registrationResult.warnings.length > 0 ? 'warning' : 'info',
        'AI artifacts registered for review.',
        {
          status: currentStatus,
          worker_phase: WORKER_PHASE,
          registration_phase: 'phase_h_artifact_registration',
          execution_mode: executionMode,
          worker_id: workerId,
          ai_pipeline_run_id: regionalRunId,
          real_ai_execution: realAiExecution,
          metrics_registered: registrationResult.metricsRegistered,
          class_statistics_registered: registrationResult.classStatisticsRegistered,
          output_layers_registered: registrationResult.outputLayersRegistered,
          warnings: registrationResult.warnings,
          artifact_paths: registrationResult.artifactPaths,
          unpublished_only: true,
          no_spatial_feature_writes: true,
        },
      );
      logsWritten += 1;
    } catch (error) {
      const failureReason =
        error instanceof Error
          ? `AI artifact registration failed: ${error.message}`
          : 'AI artifact registration failed.';
      await insertRunLog(claimedRun.id, 'error', failureReason, {
        status: 'failed',
        failed_from_status: currentStatus,
        worker_phase: WORKER_PHASE,
        registration_phase: 'phase_h_artifact_registration',
        execution_mode: executionMode,
        worker_id: workerId,
        ai_pipeline_run_id: regionalRunId,
        real_ai_execution: realAiExecution,
      });
      logsWritten += 1;
      return failFromCurrentStatus(failureReason);
    }
  }

  const completedRun = await updateRunStatus(
    claimedRun.id,
    currentStatus,
    'ready_for_review',
    workerId,
    completionMetadata(),
  );
  statuses.push('ready_for_review');

  await insertRunLog(
    claimedRun.id,
    'info',
    'AI pipeline bridge completed. Run is ready for admin review; nothing was published.',
    {
      status: 'ready_for_review',
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
      output_paths: outputPathsFrom(commandResults),
      scientific_limitations: REGIONAL_SCIENTIFIC_LIMITATIONS,
    },
  );
  logsWritten += 1;

  logger.info('AI pipeline bridge run completed', {
    runId: completedRun.id,
    projectId: completedRun.project_id,
    executionMode,
    realAiExecution,
  });

  return {
    processed: true,
    dryRun: false,
    mock: false,
    executionMode,
    pipelineEnabled: true,
    runId: completedRun.id,
    projectId: completedRun.project_id,
    labelField: completedRun.label_field,
    initialStatus: 'queued',
    finalStatus: 'ready_for_review',
    statuses,
    logsWritten,
    failureReason: null,
  };
};

const runAiWorkerOnce = async (options: AiWorkerOnceOptions = {}): Promise<AiWorkerOnceResult> => {
  const dryRun = Boolean(options.dryRun);
  const forceMock = options.mock ?? false;
  const workerId = options.workerId ?? createWorkerId();
  const failAtStatus = options.failAtStatus ?? null;
  const pipelineService = options.pipelineService ?? createAiPipelineService();

  if (!dryRun && options.mock === false) {
    throw new Error('AI worker direct calls should use --mock, --pipeline-bridge, or --dry-run.');
  }

  if (failAtStatus && !activeStatusSet.has(failAtStatus)) {
    throw new Error(`Cannot fail mock AI run at unsupported status ${failAtStatus}.`);
  }

  const pipelineEnabled = pipelineService.getConfig().enabled;
  if (dryRun) {
    const queuedRun = await peekQueuedAiRun();
    if (!queuedRun) {
      return emptyResult(true, forceMock, pipelineEnabled);
    }

    const { executionMode } = resolveExecutionMode(queuedRun, pipelineService, forceMock);
    return {
      processed: false,
      dryRun: true,
      mock: executionMode === 'mock',
      executionMode,
      pipelineEnabled,
      runId: queuedRun.id,
      projectId: queuedRun.project_id,
      labelField: queuedRun.label_field,
      initialStatus: 'queued',
      finalStatus: 'queued',
      statuses: [],
      logsWritten: 0,
      failureReason: null,
    };
  }

  const claimedRun = await claimNextQueuedRun(workerId);
  if (!claimedRun) {
    return emptyResult(false, forceMock, pipelineEnabled);
  }

  const { executionMode, pipelineEnabled: effectivePipelineEnabled } = resolveExecutionMode(
    claimedRun,
    pipelineService,
    forceMock,
  );

  if (executionMode === 'mock') {
    return runMockExecution({
      claimedRun,
      workerId,
      failAtStatus,
      pipelineEnabled: effectivePipelineEnabled,
    });
  }

  return runPipelineExecution({
    claimedRun,
    workerId,
    executionMode,
    pipelineService,
  });
};

export {
  AI_WORKER_MOCK_STATUS_SEQUENCE,
  AI_WORKER_PIPELINE_STATUS_SEQUENCE,
  AI_WORKER_REGIONAL_MODEL_STATUS_SEQUENCE,
  peekQueuedAiRun,
  runAiWorkerOnce,
  type AiRunActiveStatus,
  type AiRunExecutionMode,
  type AiWorkerOnceResult,
};
