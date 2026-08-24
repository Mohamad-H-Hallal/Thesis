import type { PoolClient, QueryResultRow } from 'pg';
import fs from 'node:fs/promises';
import path from 'node:path';
import { query, transaction } from '../config/database';
import {
  createAiPipelineService,
  resolveRunConfigDir,
  type AiPipelineCommandResult,
  type AiPipelineConfig,
  type AiPipelineService,
} from '../services/aiPipeline.service';
import { registerAiRunArtifactsForReview } from '../services/aiArtifactRegistration.service';
const logger = require('../utils/logger');

type AiRunActiveStatus = 'extracting_features' | 'training' | 'evaluating' | 'classifying';
type AiRunWorkerStatus = AiRunActiveStatus | 'ready_for_review';
type AiRunFinalStatus = AiRunWorkerStatus | 'failed' | 'queued';
type AiRunExecutionMode =
  | 'mock'
  | 'dry_run'
  | 'local_ground_truth_export'
  | 'regional_feature_extraction'
  | 'regional_model_eval'
  | 'regional_classification'
  | 'regional_vectorization_artifacts'
  | 'regional_full_review_artifacts';

type AiRunRow = QueryResultRow & {
  id: string;
  project_id: string;
  status: string;
  label_field: string;
  scope_type: string | null;
  scope_geometry: Record<string, unknown> | null;
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
  spatial_extent: {
    min_lon: number;
    min_lat: number;
    max_lon: number;
    max_lat: number;
  } | null;
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

const AI_WORKER_REGIONAL_ARTIFACT_STATUS_SEQUENCE: AiRunWorkerStatus[] = [
  'extracting_features',
  'classifying',
  'ready_for_review',
];

const AI_WORKER_REGIONAL_FULL_REVIEW_STATUS_SEQUENCE: AiRunWorkerStatus[] = [
  'extracting_features',
  'training',
  'evaluating',
  'classifying',
  'ready_for_review',
];

const activeStatusSet = new Set<AiRunActiveStatus>([
  'extracting_features',
  'training',
  'evaluating',
  'classifying',
]);

const executionModeSet = new Set<AiRunExecutionMode>([
  'mock',
  'dry_run',
  'local_ground_truth_export',
  'regional_feature_extraction',
  'regional_model_eval',
  'regional_classification',
  'regional_vectorization_artifacts',
  'regional_full_review_artifacts',
]);

const LOG_METADATA_MAX_CHARS = 4000;
const WORKER_PHASE = 'phase_f_regional_worker';
const REGIONAL_SCIENTIFIC_LIMITATIONS = [
  'Regional proof-of-concept only; not a national model.',
  'AI prediction quality depends on approved sample coverage.',
  'AI predictions remain separate from approved field/import features.',
  'Outputs must be reviewed before any future publication.',
];

const createWorkerId = (): string => `phase-f-worker-${process.pid}-${Date.now().toString(36)}`;

const regionalClassificationModeSet = new Set<AiRunExecutionMode>([
  'regional_classification',
  'regional_vectorization_artifacts',
  'regional_full_review_artifacts',
]);

const regionalModelOrArtifactModeSet = new Set<AiRunExecutionMode>([
  'regional_model_eval',
  'regional_full_review_artifacts',
]);

const regionalFeatureOrLaterModeSet = new Set<AiRunExecutionMode>([
  'regional_feature_extraction',
  'regional_model_eval',
  'regional_full_review_artifacts',
]);

const regionalVectorArtifactModeSet = new Set<AiRunExecutionMode>([
  'regional_vectorization_artifacts',
  'regional_full_review_artifacts',
]);

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
    `SELECT id,
            project_id,
            status,
            label_field,
            scope_type,
            ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
            region_preset,
            metadata
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
               ST_AsGeoJSON(run.scope_geometry)::json AS scope_geometry,
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
     RETURNING id,
               project_id,
               status,
               label_field,
               scope_type,
               ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
               region_preset,
               metadata`,
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
     RETURNING id,
               project_id,
               status,
               label_field,
               scope_type,
               ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
               region_preset,
               metadata`,
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

const safeOutputRunIdPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

const metadataSourceModelRunId = (metadata: Record<string, unknown> | null): string | null => {
  const raw = metadata?.source_model_run_id;
  if (typeof raw !== 'string') {
    return null;
  }
  const value = raw.trim();
  return safeOutputRunIdPattern.test(value) ? value : null;
};

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

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value && typeof value === 'object' && !Array.isArray(value));

const stringOrNull = (value: unknown): string | null => {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const stringListFrom = (value: unknown): string[] => {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((item) => stringOrNull(item))
    .filter((item): item is string => item !== null);
};

const numberOrNull = (value: unknown): number | null => {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number.parseFloat(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
};

const areaTypeFromScope = (
  scopeType: string | null | undefined,
): 'project_area' | 'custom_ai_area' | 'national_lebanon' => {
  if (scopeType === 'custom_polygon' || scopeType === 'custom_ai_area') {
    return 'custom_ai_area';
  }
  if (scopeType === 'national' || scopeType === 'national_lebanon') {
    return 'national_lebanon';
  }
  return 'project_area';
};

const firstString = (values: unknown[]): string | null => {
  for (const value of values) {
    const normalized = stringOrNull(value);
    if (normalized) {
      return normalized;
    }
  }
  return null;
};

type SatelliteSeasonConfig = {
  season: string;
  from_date: string | null;
  to_date: string | null;
};

type SatelliteTimeframeConfig = {
  map_year: number | null;
  seasons: SatelliteSeasonConfig[];
};

const satelliteAliases = new Map<string, string>([
  ['sentinel2', 'sentinel2'],
  ['sentinel-2', 'sentinel2'],
  ['sentinel_2', 'sentinel2'],
  ['s2', 'sentinel2'],
  ['landsat', 'landsat'],
  ['landsat8', 'landsat'],
  ['landsat-8', 'landsat'],
  ['landsat9', 'landsat'],
  ['landsat-9', 'landsat'],
]);

const seasonAliases = new Set(['growing', 'dry', 'harvest', 'winter']);

const normalizeSatelliteSource = (value: unknown): string | null => {
  const raw = stringOrNull(value)?.toLowerCase().replace(/\s+/g, '');
  return raw ? satelliteAliases.get(raw) ?? null : null;
};

const normalizeSeason = (value: unknown): string | null => {
  const raw = stringOrNull(value)?.toLowerCase().replace(/\s+/g, '_');
  return raw && seasonAliases.has(raw) ? raw : null;
};

const isoDateOrNull = (value: unknown): string | null => {
  const raw = stringOrNull(value);
  if (!raw || !/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    return null;
  }
  const parsed = new Date(`${raw}T00:00:00.000Z`);
  return Number.isNaN(parsed.getTime()) ? null : raw;
};

const defaultSeasonRange = (year: number, season: string): { from_date: string; to_date: string } => {
  switch (season) {
    case 'dry':
      return { from_date: `${year}-06-01`, to_date: `${year}-08-31` };
    case 'harvest':
      return { from_date: `${year}-08-01`, to_date: `${year}-10-31` };
    case 'winter':
      return { from_date: `${year}-12-01`, to_date: `${year + 1}-02-28` };
    case 'growing':
    default:
      return { from_date: `${year}-03-01`, to_date: `${year}-06-30` };
  }
};

const normalizeSatelliteSourcesFromSettings = (settings: Record<string, unknown>): string[] => {
  const sources = [
    ...stringListFrom(settings.satellite_sources),
    ...stringListFrom(settings.satelliteSources),
  ]
    .map((source) => normalizeSatelliteSource(source))
    .filter((source): source is string => source !== null);
  const legacySource = normalizeSatelliteSource(settings.satellite_source ?? settings.satelliteSource);
  if (sources.length === 0 && legacySource) {
    sources.push(legacySource);
  }
  return Array.from(new Set(sources.length > 0 ? sources : ['sentinel2']));
};

const normalizeSatelliteTimeframesFromSettings = (
  settings: Record<string, unknown>,
  sources: string[],
): Record<string, SatelliteTimeframeConfig> => {
  const configured =
    isRecord(settings.satellite_timeframes)
      ? settings.satellite_timeframes
      : isRecord(settings.satelliteTimeframes)
        ? settings.satelliteTimeframes
        : {};
  const legacySeason = normalizeSeason(settings.season) ?? 'growing';
  const legacyFromRaw = isoDateOrNull(settings.date_from ?? settings.from_date);
  const legacyYear =
    Math.trunc(
      numberOrNull(
        settings.target_year ?? settings.year ?? settings.map_year ?? legacyFromRaw?.slice(0, 4),
      ) ?? 2025,
    );
  const legacyRange = defaultSeasonRange(legacyYear, legacySeason);
  const legacyFrom = legacyFromRaw ?? legacyRange.from_date;
  const legacyTo = isoDateOrNull(settings.date_to ?? settings.to_date) ?? legacyRange.to_date;

  return sources.reduce<Record<string, SatelliteTimeframeConfig>>((timeframes, source) => {
    const sourceConfig = isRecord(configured[source]) ? (configured[source] as Record<string, unknown>) : {};
    const mapYear =
      Math.trunc(
        numberOrNull(
          sourceConfig.map_year ??
            sourceConfig.mapYear ??
            isoDateOrNull(sourceConfig.from_date ?? sourceConfig.fromDate)?.slice(0, 4),
        ) ?? legacyYear,
      );
    const rawSeasons = Array.isArray(sourceConfig.seasons) ? sourceConfig.seasons : [];
    const seasons = rawSeasons
      .map((item) => {
        const record: Record<string, unknown> = isRecord(item) ? item : { season: item };
        const season = normalizeSeason(record.season) ?? legacySeason;
        const fallback = defaultSeasonRange(mapYear, season);
        const fromDate = isoDateOrNull(record.from_date ?? record.fromDate) ?? fallback.from_date;
        const toDate = isoDateOrNull(record.to_date ?? record.toDate) ?? fallback.to_date;
        return {
          season,
          from_date: fromDate,
          to_date: toDate,
        };
      })
      .filter(
        (item, index, all) =>
          item.from_date <= item.to_date &&
          all.findIndex((candidate) => candidate.season === item.season) === index,
      );

    timeframes[source] = {
      map_year: mapYear,
      seasons:
        seasons.length > 0
          ? seasons
          : [
              {
                season: legacySeason,
                from_date: legacyFrom,
                to_date: legacyTo,
              },
            ],
    };
    return timeframes;
  }, {});
};

const confidenceThresholdFromSettings = (
  settings: Record<string, unknown>,
  metadata: Record<string, unknown> | null,
): number | null => {
  const parsed = numberOrNull(settings.confidence_threshold ?? metadata?.confidence_threshold);
  return parsed !== null && parsed >= 0 && parsed <= 1 ? parsed : null;
};

const metadataSettings = (metadata: Record<string, unknown> | null): Record<string, unknown> =>
  isRecord(metadata?.ai_settings) ? metadata.ai_settings : {};

const metadataSupport = (metadata: Record<string, unknown> | null): Record<string, unknown> =>
  isRecord(metadata?.pipeline_execution_support) ? metadata.pipeline_execution_support : {};

const mergeUnique = (...lists: string[][]): string[] => Array.from(new Set(lists.flat()));

const buildRunConfigSupportPatch = (
  metadata: Record<string, unknown> | null,
): Record<string, unknown> => {
  const support = metadataSupport(metadata);
  const existingEffective = stringListFrom(support.effective_pipeline_settings);
  const existingPending = stringListFrom(support.pending_pipeline_settings);
  const settings = metadataSettings(metadata);
  const trainingArea = areaTypeFromScope(
    firstString([
      metadata?.training_samples_area_type,
      settings.training_samples_area_type,
      settings.scope_type,
    ]),
  );
  const predictionArea = areaTypeFromScope(
    firstString([
      metadata?.prediction_area_type,
      settings.prediction_area_type,
      settings.scope_type,
    ]),
  );
  const newlyEffective = [
    'satellite_sources',
    'satellite_timeframes',
    'date_range',
    'feature_groups',
    'feature_inputs',
    'preferred_model',
    'confidence_threshold',
    'label_field',
    'execution_mode',
    'training_samples_area_type',
    'prediction_area_type',
    ...(trainingArea === 'custom_ai_area' || predictionArea === 'custom_ai_area'
      ? ['custom_area']
      : []),
  ];
  const effective = mergeUnique(existingEffective, newlyEffective);
  return {
    ...support,
    settings_saved_for_run: true,
    backend_scope_applied: true,
    pipeline_config_payload_ready: true,
    python_pipeline_config_consumed: true,
    effective_pipeline_settings: effective,
    pending_pipeline_settings: existingPending.filter((setting) => !effective.includes(setting)),
  };
};

const projectBoundsFrom = (
  metadata: Record<string, unknown> | null,
  safetySummary: AiRunSafetySummary | null,
): Record<string, number> | null => {
  if (safetySummary?.spatial_extent) {
    return safetySummary.spatial_extent;
  }
  const bounds = metadata?.project_bounds;
  if (!isRecord(bounds)) {
    return null;
  }
  const minLon = numberOrNull(bounds.min_lon);
  const minLat = numberOrNull(bounds.min_lat);
  const maxLon = numberOrNull(bounds.max_lon);
  const maxLat = numberOrNull(bounds.max_lat);
  if ([minLon, minLat, maxLon, maxLat].some((value) => value === null)) {
    return null;
  }
  return {
    min_lon: minLon as number,
    min_lat: minLat as number,
    max_lon: maxLon as number,
    max_lat: maxLat as number,
  };
};

const safeRunConfigFileName = (runId: string): string => `${runId}.json`;

const writeAiRunPipelineConfig = async ({
  run,
  regionalRunId,
  executionMode,
  pipelineConfig,
  projectName,
  safetySummary,
}: {
  run: AiRunRow;
  regionalRunId: string;
  executionMode: AiRunExecutionMode;
  pipelineConfig: AiPipelineConfig;
  projectName: string | null;
  safetySummary: AiRunSafetySummary | null;
}): Promise<{
  path: string;
  relativePath: string;
  payload: Record<string, unknown>;
  summary: Record<string, unknown>;
  supportPatch: Record<string, unknown>;
}> => {
  const runConfigDir = resolveRunConfigDir(pipelineConfig);
  await fs.mkdir(runConfigDir, { recursive: true });
  const configPath = path.join(runConfigDir, safeRunConfigFileName(run.id));
  const relativePath = path.relative(process.cwd(), configPath);
  const settings = metadataSettings(run.metadata);
  const trainingArea = areaTypeFromScope(
    firstString([
      run.metadata?.training_samples_area_type,
      settings.training_samples_area_type,
      settings.scope_type,
      run.scope_type,
    ]),
  );
  const predictionArea = areaTypeFromScope(
    firstString([
      run.metadata?.prediction_area_type,
      settings.prediction_area_type,
      settings.scope_type,
      run.scope_type,
    ]),
  );
  if (trainingArea === 'national_lebanon' || predictionArea === 'national_lebanon') {
    throw new Error('National Lebanon scope is blocked for settings-driven regional execution.');
  }

  const featureGroups = stringListFrom(settings.feature_groups);
  const featureInputs = stringListFrom(
    settings.feature_inputs ?? settings.selected_extracted_features,
  );
  const satelliteSources = normalizeSatelliteSourcesFromSettings(settings);
  const satelliteTimeframes = normalizeSatelliteTimeframesFromSettings(settings, satelliteSources);
  const primarySatelliteSource = satelliteSources[0] ?? 'sentinel2';
  const primaryTimeframe = satelliteTimeframes[primarySatelliteSource];
  const primarySeason = primaryTimeframe?.seasons[0] ?? null;
  const confidenceThreshold = confidenceThresholdFromSettings(settings, run.metadata);
  const projectBounds = projectBoundsFrom(run.metadata, safetySummary);
  const customPolygon =
    trainingArea === 'custom_ai_area' || predictionArea === 'custom_ai_area'
      ? run.scope_geometry
      : null;
  const supportPatch = buildRunConfigSupportPatch(run.metadata);
  const payload: Record<string, unknown> = {
    contract_version: 1,
    run_id: run.id,
    ai_pipeline_run_id: regionalRunId,
    project_id: run.project_id,
    project_name: projectName,
    label_field: run.label_field,
    execution_mode: executionMode,
    satellite_sources: satelliteSources,
    satellite_timeframes: satelliteTimeframes,
    satellite_source: primarySatelliteSource,
    year: primaryTimeframe?.map_year ?? null,
    season: primarySeason?.season ?? null,
    from_date: primarySeason?.from_date ?? null,
    to_date: primarySeason?.to_date ?? null,
    feature_groups: featureGroups,
    selected_feature_inputs: featureInputs,
    selected_extracted_features: featureInputs,
    preferred_model: firstString([settings.preferred_model]) ?? null,
    confidence_threshold: confidenceThreshold,
    training_samples_area_type: trainingArea,
    prediction_area_type: predictionArea,
    custom_polygon: customPolygon,
    custom_polygon_summary:
      customPolygon && isRecord(settings.custom_polygon_summary)
        ? settings.custom_polygon_summary
        : customPolygon
          ? {
              saved_for_run: true,
              geometry_type: isRecord(customPolygon) ? customPolygon.type ?? null : null,
            }
          : null,
    project_bounds: projectBounds,
    output_directory: `outputs/runs/${regionalRunId}`,
    safety_flags: {
      national_scope_enabled: false,
      allow_spatial_feature_writes: false,
      publish_outputs: false,
    },
    support: {
      consumed_by_python_pipeline: true,
      unsupported_settings: [],
    },
  };
  const summary = {
    contract_version: 1,
    ai_pipeline_run_id: regionalRunId,
    config_path: relativePath,
    satellite_sources: satelliteSources,
    satellite_timeframes: satelliteTimeframes,
    satellite_source: primarySatelliteSource,
    season: payload.season,
    from_date: payload.from_date,
    to_date: payload.to_date,
    feature_groups: featureGroups,
    selected_extracted_feature_count: featureInputs.length,
    preferred_model: payload.preferred_model,
    confidence_threshold: confidenceThreshold,
    training_samples_area_type: trainingArea,
    prediction_area_type: predictionArea,
    custom_polygon_configured: customPolygon !== null,
    national_scope_enabled: false,
    allow_spatial_feature_writes: false,
    publish_outputs: false,
  };

  await fs.writeFile(configPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

  return {
    path: configPath,
    relativePath,
    payload,
    summary,
    supportPatch,
  };
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
  const projectResult = await query<{
    id: string;
    name: string;
    training_data_use_authorized: boolean;
  }>(
    `SELECT project.id,
            project.name,
            COALESCE(governance.training_data_use_authorized, FALSE) AS training_data_use_authorized
     FROM project
     LEFT JOIN project_ai_governance governance ON governance.project_id = project.id
     WHERE project.id = $1`,
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
         AND (
           COALESCE(source, 'field') <> 'ai'
           OR use_for_future_training = TRUE
           OR attributes->>'useForFutureTraining' = 'true'
         )
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
       AND (
         COALESCE(source, 'field') <> 'ai'
         OR use_for_future_training = TRUE
         OR attributes->>'useForFutureTraining' = 'true'
       )
       AND geom IS NOT NULL
       AND ST_IsValid(geom)
       AND NULLIF(BTRIM(attributes ->> $2), '') IS NOT NULL
     GROUP BY class_label
     ORDER BY sample_count DESC, class_label ASC`,
    [projectId, labelField],
  );
  const extentResult = await query<{
    min_lon: number | null;
    min_lat: number | null;
    max_lon: number | null;
    max_lat: number | null;
  }>(
    `WITH extent AS (
       SELECT ST_Extent(geom)::box3d AS bbox
       FROM spatial_feature
       WHERE project_id = $1
         AND status = 'approved'
         AND (
           COALESCE(source, 'field') <> 'ai'
           OR use_for_future_training = TRUE
           OR attributes->>'useForFutureTraining' = 'true'
         )
         AND geom IS NOT NULL
         AND ST_IsValid(geom)
         AND NULLIF(BTRIM(attributes ->> $2), '') IS NOT NULL
     )
     SELECT ST_XMin(bbox)::float8 AS min_lon,
            ST_YMin(bbox)::float8 AS min_lat,
            ST_XMax(bbox)::float8 AS max_lon,
            ST_YMax(bbox)::float8 AS max_lat
     FROM extent`,
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
  const extent = extentResult.rows[0];
  const spatialExtent =
    extent &&
    extent.min_lon !== null &&
    extent.min_lat !== null &&
    extent.max_lon !== null &&
    extent.max_lat !== null
      ? {
          min_lon: Number(extent.min_lon),
          min_lat: Number(extent.min_lat),
          max_lon: Number(extent.max_lon),
          max_lat: Number(extent.max_lat),
        }
      : null;
  const warnings: string[] = [];
  const blockers: string[] = [];
  if (projectResult.rows[0]?.training_data_use_authorized !== true) {
    blockers.push(
      'Project data is not authorized for AI training under a recorded governance approval.',
    );
  }

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
      spatial_extent: spatialExtent,
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
    return 'National classification is not allowed in regional AI worker execution.';
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
  const sourceModelRunId = metadataSourceModelRunId(claimedRun.metadata);
  const sourceModelMetadataPath = sourceModelRunId
    ? `outputs/runs/${sourceModelRunId}/model_metadata.json`
    : `outputs/runs/${regionalRunId}/model_metadata.json`;
  const realAiExecution =
    regionalFeatureOrLaterModeSet.has(executionMode) ||
    regionalClassificationModeSet.has(executionMode);
  const statuses: AiRunWorkerStatus[] = ['extracting_features'];
  let currentStatus: AiRunActiveStatus = 'extracting_features';
  let safetySummary: AiRunSafetySummary | null = null;
  let projectName: string | null = null;
  let artifactRegistrationMetadata: Record<string, unknown> | null = null;
  let runConfigPath: string | null = null;
  let runConfigRelativePath: string | null = null;
  let runConfigSummary: Record<string, unknown> | null = null;
  let runConfigSupportPatch: Record<string, unknown> | null = null;
  let logsWritten = 0;

  await insertRunLog(
    claimedRun.id,
    'info',
    'AI pipeline bridge started. Controlled regional execution modes only; national classification is blocked.',
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
      pipeline_bridge_phase:
        executionMode === 'regional_full_review_artifacts'
          ? 'phase_r_full_regional_review'
          : regionalClassificationModeSet.has(executionMode)
            ? 'phase_k'
            : 'phase_f',
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

    if (runConfigRelativePath && runConfigSummary) {
      metadata.run_config_path = runConfigRelativePath;
      metadata.run_config = runConfigSummary;
      metadata.pipeline_execution_support = runConfigSupportPatch;
    }

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
      regionalFeatureOrLaterModeSet.has(executionMode)
    ) {
      metadata.output_directory = `outputs/projects/${claimedRun.project_id}`;
      metadata.ground_truth_path = `outputs/projects/${claimedRun.project_id}/ground_truth.geojson`;
    }
    if (
      regionalFeatureOrLaterModeSet.has(executionMode)
    ) {
      metadata.output_directory = `outputs/runs/${regionalRunId}`;
      metadata.feature_table_path = `outputs/runs/${regionalRunId}/feature_table.csv`;
      metadata.feature_extraction_summary_path =
        `outputs/runs/${regionalRunId}/feature_extraction_summary.json`;
    }
    if (regionalModelOrArtifactModeSet.has(executionMode)) {
      metadata.metrics_path = `outputs/runs/${regionalRunId}/metrics.json`;
      metadata.confusion_matrix_path = `outputs/runs/${regionalRunId}/confusion_matrix.csv`;
      metadata.classification_report_path =
        `outputs/runs/${regionalRunId}/classification_report.csv`;
      metadata.feature_importance_path = `outputs/runs/${regionalRunId}/feature_importance.csv`;
      metadata.model_metadata_path = `outputs/runs/${regionalRunId}/model_metadata.json`;
      metadata.model_metrics_summary =
        artifactRegistrationMetadata?.model_metrics_summary ?? {
          source: `outputs/runs/${regionalRunId}/metrics.json`,
          note: 'Metrics describe this run only and depend on available validation data.',
        };
    }
    if (regionalClassificationModeSet.has(executionMode)) {
      metadata.regional_classification_summary_path =
        `outputs/runs/${regionalRunId}/regional_classification_summary.json`;
      if (sourceModelRunId) {
        metadata.source_model_run_id = sourceModelRunId;
        metadata.source_model_metadata_path = sourceModelMetadataPath;
      }
    }
    if (regionalVectorArtifactModeSet.has(executionMode)) {
      metadata.classification_polygons_path =
        `outputs/runs/${regionalRunId}/classification_polygons.geojson`;
      metadata.confidence_polygons_path =
        `outputs/runs/${regionalRunId}/confidence_polygons.geojson`;
      metadata.uncertainty_areas_path = `outputs/runs/${regionalRunId}/uncertainty_areas.geojson`;
      metadata.vectorization_summary_path =
        `outputs/runs/${regionalRunId}/vectorization_summary.json`;
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
    projectName = readiness.projectName;

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

  try {
    const runConfig = await writeAiRunPipelineConfig({
      run: claimedRun,
      regionalRunId,
      executionMode,
      pipelineConfig: pipelineService.getConfig(),
      projectName,
      safetySummary,
    });
    runConfigPath = runConfig.path;
    runConfigRelativePath = runConfig.relativePath;
    runConfigSummary = runConfig.summary;
    runConfigSupportPatch = runConfig.supportPatch;
    await query(
      `UPDATE ai_run
       SET metadata = COALESCE(metadata, '{}'::jsonb) || $2::jsonb,
           updated_at = CURRENT_TIMESTAMP
       WHERE id = $1`,
      [
        claimedRun.id,
        safeMetadata({
          run_config_path: runConfigRelativePath,
          run_config: runConfigSummary,
          pipeline_execution_support: runConfigSupportPatch,
        }),
      ],
    );
    await insertRunLog(claimedRun.id, 'info', 'AI pipeline run config written.', {
      status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
      run_config: runConfigSummary,
      secrets_included: false,
    });
    logsWritten += 1;
  } catch (error) {
    const failureReason =
      error instanceof Error
        ? `AI run config creation failed: ${error.message}`
        : 'AI run config creation failed.';
    await insertRunLog(claimedRun.id, 'error', failureReason, {
      status: 'failed',
      failed_from_status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
    });
    logsWritten += 1;
    return failFromCurrentStatus(failureReason);
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
      run: () => pipelineService.dryRun(runConfigPath ?? undefined),
    },
    {
      message: 'AI pipeline project readiness probe',
      run: () =>
        pipelineService.probeProject(
          claimedRun.project_id,
          claimedRun.label_field,
          runConfigPath ?? undefined,
        ),
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
    regionalFeatureOrLaterModeSet.has(executionMode)
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
            runConfigPath ?? undefined,
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
      const failureReason = `AI pipeline ${result.command} failed during regional AI worker execution.`;
      return failFromCurrentStatus(failureReason);
    }
  }

  if (regionalModelOrArtifactModeSet.has(executionMode)) {
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
          undefined,
          runConfigPath ?? undefined,
        ),
    });
    commandResults.push(result);
    logsWritten += modelLogsWritten;

    if (!result.success) {
      const failureReason = `AI pipeline ${result.command} failed during regional AI worker execution.`;
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

    if (executionMode === 'regional_model_eval') {
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
  }

  if (regionalClassificationModeSet.has(executionMode)) {
    await updateRunStatus(
      claimedRun.id,
      currentStatus,
      'classifying',
      workerId,
      completionMetadata(),
    );
    currentStatus = 'classifying';
    statuses.push('classifying');
    await insertRunLog(claimedRun.id, 'info', 'AI regional classification artifact step started.', {
      status: currentStatus,
      worker_phase: WORKER_PHASE,
      execution_mode: executionMode,
      worker_id: workerId,
      ai_pipeline_run_id: regionalRunId,
      real_ai_execution: realAiExecution,
      national_classification: false,
    });
    logsWritten += 1;

    const { result: classificationResult, logsWritten: classificationLogsWritten } =
      await runPipelineCommandWithLogs({
        run: claimedRun,
        workerId,
        executionMode,
        status: currentStatus,
        realAiExecution,
        message: 'AI regional classification artifact preparation',
        commandRunner: () =>
          pipelineService.classifyRegional(
            claimedRun.project_id,
            claimedRun.label_field,
            regionalRunId,
            sourceModelMetadataPath,
            undefined,
            runConfigPath ?? undefined,
          ),
      });
    commandResults.push(classificationResult);
    logsWritten += classificationLogsWritten;

    if (!classificationResult.success) {
      const failureReason =
        `AI pipeline ${classificationResult.command} failed during regional AI worker execution.`;
      return failFromCurrentStatus(failureReason);
    }

    if (regionalVectorArtifactModeSet.has(executionMode)) {
      const { result: vectorizationResult, logsWritten: vectorizationLogsWritten } =
        await runPipelineCommandWithLogs({
          run: claimedRun,
          workerId,
          executionMode,
          status: currentStatus,
          realAiExecution,
          message: 'AI regional vectorization review artifact preparation',
          commandRunner: () =>
            pipelineService.prepareRegionalVectorArtifacts(
              claimedRun.project_id,
              claimedRun.label_field,
              regionalRunId,
              undefined,
              undefined,
              runConfigPath ?? undefined,
            ),
        });
      commandResults.push(vectorizationResult);
      logsWritten += vectorizationLogsWritten;

      if (!vectorizationResult.success) {
        const failureReason =
          `AI pipeline ${vectorizationResult.command} failed during regional AI worker execution.`;
        return failFromCurrentStatus(failureReason);
      }
    }

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
  AI_WORKER_REGIONAL_ARTIFACT_STATUS_SEQUENCE,
  AI_WORKER_REGIONAL_FULL_REVIEW_STATUS_SEQUENCE,
  peekQueuedAiRun,
  runAiWorkerOnce,
  type AiRunActiveStatus,
  type AiRunExecutionMode,
  type AiWorkerOnceResult,
};
