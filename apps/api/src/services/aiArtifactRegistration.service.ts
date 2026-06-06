import fs from 'node:fs/promises';
import path from 'node:path';
import type { PoolClient } from 'pg';
import { transaction } from '../config/database';
import type { AiPipelineConfig } from './aiPipeline.service';

type JsonRecord = Record<string, unknown>;

type AiRunArtifactRegistrationInput = {
  runId: string;
  projectId: string;
  labelField: string;
  metadata: JsonRecord | null;
  pipelineConfig: AiPipelineConfig;
};

type RegisteredArtifactPaths = Partial<Record<KnownArtifactKey, string>>;

type AiArtifactRegistrationResult = {
  success: boolean;
  skipped: boolean;
  metricsRegistered: number;
  classStatisticsRegistered: number;
  outputLayersRegistered: number;
  warnings: string[];
  artifactPaths: RegisteredArtifactPaths;
  metadataPatch: JsonRecord;
};

type KnownArtifactKey =
  | 'metrics'
  | 'confusion_matrix'
  | 'classification_report'
  | 'feature_importance'
  | 'model_metadata'
  | 'feature_extraction_summary'
  | 'ground_truth_summary';

type ResolvedArtifact = {
  key: KnownArtifactKey;
  relativePath: string;
  absolutePath: string;
};

type MetricRow = {
  modelName: string;
  overallAccuracy: number | null;
  macroF1: number | null;
  weightedF1: number | null;
  metrics: JsonRecord;
  confusionMatrix: unknown;
  featureImportance: unknown;
};

type ClassStatisticRow = {
  classLabel: string;
  featureCount: number;
  areaHa: number | null;
  confidenceMean: number | null;
  statistics: JsonRecord;
};

const KNOWN_ARTIFACT_FILENAMES: Record<KnownArtifactKey, string> = {
  metrics: 'metrics.json',
  confusion_matrix: 'confusion_matrix.csv',
  classification_report: 'classification_report.csv',
  feature_importance: 'feature_importance.csv',
  model_metadata: 'model_metadata.json',
  feature_extraction_summary: 'feature_extraction_summary.json',
  ground_truth_summary: 'ground_truth_summary.json',
};

const KNOWN_ARTIFACT_KEYS = Object.keys(KNOWN_ARTIFACT_FILENAMES) as KnownArtifactKey[];
const KNOWN_ARTIFACT_BASENAMES = new Set(Object.values(KNOWN_ARTIFACT_FILENAMES));
const REGISTRATION_PHASE = 'phase_h_artifact_registration';

const toRecord = (value: unknown): JsonRecord =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as JsonRecord) : {};

const toArray = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);

const toStringValue = (value: unknown): string | null => {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const toNumberValue = (value: unknown): number | null => {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
};

const toIntValue = (value: unknown): number | null => {
  const parsed = toNumberValue(value);
  return parsed === null ? null : Math.max(0, Math.round(parsed));
};

const toSafeJson = (value: unknown): JsonRecord | unknown[] => {
  if (Array.isArray(value)) {
    return value;
  }
  return toRecord(value);
};

const toPosixPath = (value: string): string => value.replace(/\\/g, '/');

const normalizeModelName = (value: string): string => value.trim().toLowerCase();

const friendlyModelName = (value: string): string => {
  switch (normalizeModelName(value)) {
    case 'random_forest':
      return 'Random Forest';
    case 'svm_rbf':
      return 'SVM RBF';
    case 'xgboost':
      return 'XGBoost';
    default:
      return value
        .split(/[_\s-]+/)
        .filter(Boolean)
        .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
        .join(' ');
  }
};

const firstString = (values: unknown[]): string | null => {
  for (const value of values) {
    const text = toStringValue(value);
    if (text) {
      return text;
    }
  }
  return null;
};

const ensureOutputPath = (
  pipelineConfig: AiPipelineConfig,
  artifactKey: KnownArtifactKey,
  candidatePath: string,
): ResolvedArtifact => {
  if (!pipelineConfig.root) {
    throw new Error('AI artifact registration requires AI_PIPELINE_ROOT.');
  }

  const root = path.resolve(pipelineConfig.root);
  const outputRoot = path.resolve(root, 'outputs');
  const rawPath = candidatePath.trim();
  if (!rawPath || rawPath.includes('\0')) {
    throw new Error('Invalid empty AI artifact path.');
  }
  if (toPosixPath(rawPath).split('/').includes('..')) {
    throw new Error('AI artifact path traversal is not allowed.');
  }

  const candidate = path.isAbsolute(rawPath)
    ? path.resolve(rawPath)
    : path.resolve(root, rawPath);
  const relativeToOutputRoot = path.relative(outputRoot, candidate);
  if (
    relativeToOutputRoot.startsWith('..') ||
    path.isAbsolute(relativeToOutputRoot) ||
    relativeToOutputRoot.length === 0
  ) {
    throw new Error('AI artifact path is outside the configured output directory.');
  }

  const basename = path.basename(candidate);
  const expectedBasename = KNOWN_ARTIFACT_FILENAMES[artifactKey];
  if (basename !== expectedBasename || !KNOWN_ARTIFACT_BASENAMES.has(basename)) {
    throw new Error(`Unexpected AI artifact file for ${artifactKey}.`);
  }

  return {
    key: artifactKey,
    absolutePath: candidate,
    relativePath: toPosixPath(path.relative(root, candidate)),
  };
};

const outputPathEndingWith = (
  metadata: JsonRecord,
  filename: string,
): string | null => {
  const outputPaths = toArray(metadata.output_paths);
  for (const item of outputPaths) {
    const outputPath = toStringValue(item);
    if (outputPath && toPosixPath(outputPath).endsWith(`/${filename}`)) {
      return outputPath;
    }
  }
  return null;
};

const collectArtifactCandidates = (
  input: AiRunArtifactRegistrationInput,
): Partial<Record<KnownArtifactKey, string>> => {
  const metadata = input.metadata ?? {};
  const runId = firstString([
    metadata.ai_pipeline_run_id,
    toRecord(metadata.model_metrics_summary).run_id,
  ]);
  const runOutputDir = runId ? `outputs/runs/${runId}` : null;
  const projectOutputDir = `outputs/projects/${input.projectId}`;

  return {
    metrics:
      firstString([
        metadata.metrics_path,
        toRecord(metadata.model_metrics_summary).source,
        outputPathEndingWith(metadata, 'metrics.json'),
        runOutputDir ? `${runOutputDir}/metrics.json` : null,
      ]) ?? undefined,
    confusion_matrix:
      firstString([
        metadata.confusion_matrix_path,
        outputPathEndingWith(metadata, 'confusion_matrix.csv'),
        runOutputDir ? `${runOutputDir}/confusion_matrix.csv` : null,
      ]) ?? undefined,
    classification_report:
      firstString([
        metadata.classification_report_path,
        outputPathEndingWith(metadata, 'classification_report.csv'),
        runOutputDir ? `${runOutputDir}/classification_report.csv` : null,
      ]) ?? undefined,
    feature_importance:
      firstString([
        metadata.feature_importance_path,
        outputPathEndingWith(metadata, 'feature_importance.csv'),
        runOutputDir ? `${runOutputDir}/feature_importance.csv` : null,
      ]) ?? undefined,
    model_metadata:
      firstString([
        metadata.model_metadata_path,
        outputPathEndingWith(metadata, 'model_metadata.json'),
        runOutputDir ? `${runOutputDir}/model_metadata.json` : null,
      ]) ?? undefined,
    feature_extraction_summary:
      firstString([
        metadata.feature_extraction_summary_path,
        outputPathEndingWith(metadata, 'feature_extraction_summary.json'),
        runOutputDir ? `${runOutputDir}/feature_extraction_summary.json` : null,
      ]) ?? undefined,
    ground_truth_summary:
      firstString([
        metadata.ground_truth_summary_path,
        outputPathEndingWith(metadata, 'ground_truth_summary.json'),
        `${projectOutputDir}/ground_truth_summary.json`,
      ]) ?? undefined,
  };
};

const resolveKnownArtifacts = (
  input: AiRunArtifactRegistrationInput,
): Partial<Record<KnownArtifactKey, ResolvedArtifact>> => {
  const candidates = collectArtifactCandidates(input);
  const resolved: Partial<Record<KnownArtifactKey, ResolvedArtifact>> = {};

  for (const key of KNOWN_ARTIFACT_KEYS) {
    const candidate = candidates[key];
    if (!candidate) {
      continue;
    }
    resolved[key] = ensureOutputPath(input.pipelineConfig, key, candidate);
  }

  return resolved;
};

const fileExists = async (filePath: string): Promise<boolean> => {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
};

const readJsonArtifact = async (
  artifact: ResolvedArtifact | undefined,
  warnings: string[],
): Promise<JsonRecord> => {
  if (!artifact) {
    return {};
  }
  if (!(await fileExists(artifact.absolutePath))) {
    warnings.push(`AI artifact not found: ${artifact.relativePath}.`);
    return {};
  }

  try {
    return toRecord(JSON.parse(await fs.readFile(artifact.absolutePath, 'utf8')));
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown JSON parse error.';
    warnings.push(`Could not parse ${artifact.relativePath}: ${message}`);
    return {};
  }
};

const splitCsvLine = (line: string): string[] => {
  const values: string[] = [];
  let current = '';
  let quoted = false;

  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const next = line[index + 1];
    if (char === '"' && quoted && next === '"') {
      current += '"';
      index += 1;
      continue;
    }
    if (char === '"') {
      quoted = !quoted;
      continue;
    }
    if (char === ',' && !quoted) {
      values.push(current);
      current = '';
      continue;
    }
    current += char;
  }
  values.push(current);
  return values;
};

const parseCsvRows = (content: string): JsonRecord[] => {
  const lines = content
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter((line) => line.trim().length > 0);
  if (lines.length < 2) {
    return [];
  }
  const headers = splitCsvLine(lines[0]).map((header) => header.trim());
  return lines.slice(1).map((line) => {
    const cells = splitCsvLine(line);
    const row: JsonRecord = {};
    headers.forEach((header, index) => {
      const rawValue = cells[index] ?? '';
      const numeric = toNumberValue(rawValue);
      row[header] = numeric !== null && rawValue.trim() !== '' ? numeric : rawValue;
    });
    return row;
  });
};

const readCsvArtifact = async (
  artifact: ResolvedArtifact | undefined,
  warnings: string[],
): Promise<JsonRecord[]> => {
  if (!artifact) {
    return [];
  }
  if (!(await fileExists(artifact.absolutePath))) {
    warnings.push(`AI artifact not found: ${artifact.relativePath}.`);
    return [];
  }

  try {
    return parseCsvRows(await fs.readFile(artifact.absolutePath, 'utf8'));
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown CSV parse error.';
    warnings.push(`Could not parse ${artifact.relativePath}: ${message}`);
    return [];
  }
};

const featureImportanceForModel = (
  featureImportanceRows: JsonRecord[],
  modelName: string,
): JsonRecord[] => {
  const normalized = normalizeModelName(modelName);
  const rows = featureImportanceRows.filter((row) => {
    const rowModel = toStringValue(row.model);
    return rowModel !== null && normalizeModelName(rowModel) === normalized;
  });
  return rows.length > 0 ? rows : [];
};

const metricRowsFromArtifacts = ({
  metricsPayload,
  confusionMatrixRows,
  featureImportanceRows,
}: {
  metricsPayload: JsonRecord;
  confusionMatrixRows: JsonRecord[];
  featureImportanceRows: JsonRecord[];
}): MetricRow[] => {
  const models = toRecord(metricsPayload.models);
  const bestModel = toStringValue(metricsPayload.best_model);
  return Object.entries(models)
    .map(([modelName, metricValue]) => {
      const metrics = toRecord(metricValue);
      return {
        modelName,
        overallAccuracy: toNumberValue(metrics.accuracy ?? metrics.overall_accuracy),
        macroF1: toNumberValue(metrics.macro_f1 ?? metrics.macroF1),
        weightedF1: toNumberValue(metrics.weighted_f1 ?? metrics.weightedF1),
        metrics: {
          model_key: modelName,
          model_display_name: friendlyModelName(modelName),
          model_metrics: metrics,
          selected_by_macro_f1: bestModel === modelName,
          regional_only: metricsPayload.regional_only === true,
          not_national_accuracy: metricsPayload.not_national_accuracy === true,
          evaluation_method: metricsPayload.evaluation_method,
          sample_count: metricsPayload.sample_count,
          train_count: metricsPayload.train_count,
          test_count: metricsPayload.test_count,
          class_counts: metricsPayload.class_counts,
          classes: metricsPayload.classes,
          warnings: metricsPayload.warnings,
        },
        confusionMatrix: {
          applies_to_model: bestModel,
          rows: confusionMatrixRows,
        },
        featureImportance: featureImportanceForModel(featureImportanceRows, modelName),
      };
    })
    .filter(
      (row) =>
        row.overallAccuracy !== null || row.macroF1 !== null || row.weightedF1 !== null,
    );
};

const mergeClassCountSource = (
  rowsByLabel: Map<string, ClassStatisticRow>,
  classCounts: unknown,
  source: string,
  eligible: boolean | null,
): void => {
  const counts = toRecord(classCounts);
  for (const [label, countValue] of Object.entries(counts)) {
    const classLabel = label.trim();
    if (!classLabel) {
      continue;
    }
    const featureCount = toIntValue(countValue);
    if (featureCount === null) {
      continue;
    }

    const normalized = classLabel.toLowerCase();
    const existing =
      rowsByLabel.get(normalized) ??
      ({
        classLabel,
        featureCount,
        areaHa: null,
        confidenceMean: null,
        statistics: {
          sources: [],
        },
      } satisfies ClassStatisticRow);

    existing.featureCount = Math.max(existing.featureCount, featureCount);
    existing.statistics = {
      ...existing.statistics,
      eligible,
      [`${source}_feature_count`]: featureCount,
      sources: Array.from(
        new Set([...toArray(existing.statistics.sources).map(String), source]),
      ),
    };
    rowsByLabel.set(normalized, existing);
  }
};

const mergeClassificationReportSupport = (
  rowsByLabel: Map<string, ClassStatisticRow>,
  reportRows: JsonRecord[],
): void => {
  const ignoredLabels = new Set(['accuracy', 'macro avg', 'weighted avg']);
  for (const row of reportRows) {
    const classLabel = toStringValue(row.label);
    if (!classLabel || ignoredLabels.has(classLabel.toLowerCase())) {
      continue;
    }
    const support = toIntValue(row.support);
    if (support === null) {
      continue;
    }

    const normalized = classLabel.toLowerCase();
    const existing =
      rowsByLabel.get(normalized) ??
      ({
        classLabel,
        featureCount: support,
        areaHa: null,
        confidenceMean: null,
        statistics: {
          sources: [],
        },
      } satisfies ClassStatisticRow);
    existing.featureCount = Math.max(existing.featureCount, support);
    existing.statistics = {
      ...existing.statistics,
      classification_report_support: support,
      precision: toNumberValue(row.precision),
      recall: toNumberValue(row.recall),
      f1_score: toNumberValue(row['f1-score']),
      sources: Array.from(
        new Set([...toArray(existing.statistics.sources).map(String), 'classification_report']),
      ),
    };
    rowsByLabel.set(normalized, existing);
  }
};

const mergeExcludedClasses = (
  rowsByLabel: Map<string, ClassStatisticRow>,
  metadata: JsonRecord,
): void => {
  for (const item of toArray(metadata.excluded_classes)) {
    const row = toRecord(item);
    const classLabel = toStringValue(row.class_label);
    const sampleCount = toIntValue(row.sample_count);
    if (!classLabel || sampleCount === null) {
      continue;
    }
    const normalized = classLabel.toLowerCase();
    if (rowsByLabel.has(normalized)) {
      continue;
    }
    rowsByLabel.set(normalized, {
      classLabel,
      featureCount: sampleCount,
      areaHa: null,
      confidenceMean: null,
      statistics: {
        eligible: false,
        excluded: true,
        exclusion_reason: 'below_minimum_samples',
        sources: ['ai_run_metadata'],
      },
    });
  }
};

const classStatisticRowsFromArtifacts = ({
  metricsPayload,
  featureExtractionSummary,
  groundTruthSummary,
  classificationReportRows,
  metadata,
}: {
  metricsPayload: JsonRecord;
  featureExtractionSummary: JsonRecord;
  groundTruthSummary: JsonRecord;
  classificationReportRows: JsonRecord[];
  metadata: JsonRecord;
}): ClassStatisticRow[] => {
  const rowsByLabel = new Map<string, ClassStatisticRow>();
  mergeClassCountSource(rowsByLabel, groundTruthSummary.class_counts, 'ground_truth', true);
  mergeClassCountSource(rowsByLabel, featureExtractionSummary.class_counts, 'feature_extraction', true);
  mergeClassCountSource(rowsByLabel, metricsPayload.class_counts, 'metrics', true);
  mergeClassificationReportSupport(rowsByLabel, classificationReportRows);
  mergeExcludedClasses(rowsByLabel, metadata);
  return Array.from(rowsByLabel.values()).sort((left, right) =>
    left.classLabel.localeCompare(right.classLabel),
  );
};

const modelMetricsSummaryFrom = (metricsPayload: JsonRecord): JsonRecord => {
  const models = toRecord(metricsPayload.models);
  const modelEntries = Object.entries(models);
  const bestBalanced = modelEntries
    .map(([modelName, metrics]) => ({
      modelName,
      macroF1: toNumberValue(toRecord(metrics).macro_f1),
      accuracy: toNumberValue(toRecord(metrics).accuracy),
    }))
    .filter((row) => row.macroF1 !== null)
    .sort((left, right) => {
      const macroDiff = (right.macroF1 ?? 0) - (left.macroF1 ?? 0);
      return macroDiff !== 0 ? macroDiff : (right.accuracy ?? 0) - (left.accuracy ?? 0);
    })[0];
  const highestAccuracy = modelEntries
    .map(([modelName, metrics]) => ({
      modelName,
      accuracy: toNumberValue(toRecord(metrics).accuracy),
    }))
    .filter((row) => row.accuracy !== null)
    .sort((left, right) => (right.accuracy ?? 0) - (left.accuracy ?? 0))[0];

  return {
    run_id: metricsPayload.run_id,
    best_model: metricsPayload.best_model,
    best_balanced_model: bestBalanced?.modelName ?? metricsPayload.best_model,
    highest_accuracy_model: highestAccuracy?.modelName ?? null,
    selected_model: metricsPayload.best_model,
    models,
    sample_count: metricsPayload.sample_count,
    class_counts: metricsPayload.class_counts,
    classes: metricsPayload.classes,
    evaluation_method: metricsPayload.evaluation_method,
    runtime_seconds: metricsPayload.runtime_seconds,
    warnings: metricsPayload.warnings,
    regional_only: metricsPayload.regional_only === true,
    not_national_accuracy: metricsPayload.not_national_accuracy === true,
  };
};

const insertMetricRows = async (
  client: PoolClient,
  runId: string,
  rows: MetricRow[],
): Promise<number> => {
  for (const row of rows) {
    await client.query(
      `INSERT INTO ai_run_metric (
         ai_run_id,
         model_name,
         overall_accuracy,
         macro_f1,
         weighted_f1,
         metrics,
         confusion_matrix,
         feature_importance
       )
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8::jsonb)`,
      [
        runId,
        row.modelName,
        row.overallAccuracy,
        row.macroF1,
        row.weightedF1,
        JSON.stringify(row.metrics),
        JSON.stringify(toSafeJson(row.confusionMatrix)),
        JSON.stringify(toSafeJson(row.featureImportance)),
      ],
    );
  }
  return rows.length;
};

const insertClassStatisticRows = async (
  client: PoolClient,
  runId: string,
  rows: ClassStatisticRow[],
): Promise<number> => {
  for (const row of rows) {
    await client.query(
      `INSERT INTO ai_class_statistic (
         ai_run_id,
         class_label,
         feature_count,
         area_ha,
         confidence_mean,
         statistics
       )
       VALUES ($1, $2, $3, $4, $5, $6::jsonb)
       ON CONFLICT (ai_run_id, class_label)
       DO UPDATE SET
         feature_count = EXCLUDED.feature_count,
         area_ha = EXCLUDED.area_ha,
         confidence_mean = EXCLUDED.confidence_mean,
         statistics = EXCLUDED.statistics`,
      [
        runId,
        row.classLabel,
        row.featureCount,
        row.areaHa,
        row.confidenceMean,
        JSON.stringify(row.statistics),
      ],
    );
  }
  return rows.length;
};

const insertStatisticsLayer = async ({
  client,
  runId,
  projectId,
  storagePath,
}: {
  client: PoolClient;
  runId: string;
  projectId: string;
  storagePath: string | null;
}): Promise<number> => {
  if (!storagePath) {
    return 0;
  }
  await client.query(
    `INSERT INTO ai_output_layer (
       ai_run_id,
       project_id,
       layer_type,
       status,
       name,
       description,
       storage_path,
       crs,
       style
     )
     VALUES (
       $1,
       $2,
       'statistics',
       'ready_for_review',
       'Regional AI statistics',
       'Unpublished regional AI metrics and class statistics for admin review.',
       $3,
       'EPSG:4326',
       '{}'::jsonb
     )`,
    [runId, projectId, storagePath],
  );
  return 1;
};

const registerAiRunArtifactsForReview = async (
  input: AiRunArtifactRegistrationInput,
): Promise<AiArtifactRegistrationResult> => {
  const metadata = input.metadata ?? {};
  if (metadata.execution_mode !== 'regional_model_eval') {
    return {
      success: true,
      skipped: true,
      metricsRegistered: 0,
      classStatisticsRegistered: 0,
      outputLayersRegistered: 0,
      warnings: ['Artifact registration is only enabled for regional_model_eval runs in Phase H.'],
      artifactPaths: {},
      metadataPatch: {
        artifact_registration: {
          phase: REGISTRATION_PHASE,
          skipped: true,
        },
      },
    };
  }

  const warnings: string[] = [];
  const artifacts = resolveKnownArtifacts(input);
  const artifactPaths = Object.fromEntries(
    Object.entries(artifacts).map(([key, artifact]) => [key, artifact?.relativePath]),
  ) as RegisteredArtifactPaths;

  const [
    metricsPayload,
    modelMetadata,
    featureExtractionSummary,
    groundTruthSummary,
    confusionMatrixRows,
    classificationReportRows,
    featureImportanceRows,
  ] = await Promise.all([
    readJsonArtifact(artifacts.metrics, warnings),
    readJsonArtifact(artifacts.model_metadata, warnings),
    readJsonArtifact(artifacts.feature_extraction_summary, warnings),
    readJsonArtifact(artifacts.ground_truth_summary, warnings),
    readCsvArtifact(artifacts.confusion_matrix, warnings),
    readCsvArtifact(artifacts.classification_report, warnings),
    readCsvArtifact(artifacts.feature_importance, warnings),
  ]);

  const metricRows = metricRowsFromArtifacts({
    metricsPayload,
    confusionMatrixRows,
    featureImportanceRows,
  });
  if (metricRows.length === 0) {
    warnings.push('No structured model metrics were available to register.');
  }

  const classStatisticRows = classStatisticRowsFromArtifacts({
    metricsPayload,
    featureExtractionSummary,
    groundTruthSummary,
    classificationReportRows,
    metadata,
  });
  if (classStatisticRows.length === 0) {
    warnings.push('No class statistics were available to register.');
  }

  const metricsPath = artifacts.metrics?.relativePath ?? null;
  const selectedModel =
    toStringValue(metricsPayload.best_model) ?? toStringValue(modelMetadata.best_model);
  const modelMetricsSummary =
    Object.keys(metricsPayload).length > 0 ? modelMetricsSummaryFrom(metricsPayload) : {};

  const result = await transaction(async (client: PoolClient) => {
    await client.query(`DELETE FROM ai_run_metric WHERE ai_run_id = $1`, [input.runId]);
    await client.query(`DELETE FROM ai_class_statistic WHERE ai_run_id = $1`, [input.runId]);
    await client.query(
      `DELETE FROM ai_output_layer
       WHERE ai_run_id = $1
         AND status <> 'published'
         AND layer_type = 'statistics'`,
      [input.runId],
    );

    const metricsRegistered = await insertMetricRows(client, input.runId, metricRows);
    const classStatisticsRegistered = await insertClassStatisticRows(
      client,
      input.runId,
      classStatisticRows,
    );
    const hasReviewableStructuredResults =
      metricRows.length > 0 || classStatisticRows.length > 0;
    const outputLayersRegistered = await insertStatisticsLayer({
      client,
      runId: input.runId,
      projectId: input.projectId,
      storagePath: hasReviewableStructuredResults ? metricsPath : null,
    });
    if (selectedModel) {
      await client.query(`UPDATE ai_run SET selected_model = $2 WHERE id = $1`, [
        input.runId,
        selectedModel,
      ]);
    }

    return {
      metricsRegistered,
      classStatisticsRegistered,
      outputLayersRegistered,
    };
  });

  const metadataPatch: JsonRecord = {
    artifact_registration: {
      phase: REGISTRATION_PHASE,
      registered_at: new Date().toISOString(),
      metrics_registered: result.metricsRegistered,
      class_statistics_registered: result.classStatisticsRegistered,
      output_layers_registered: result.outputLayersRegistered,
      warnings,
      artifact_paths: artifactPaths,
      unpublished_only: true,
      no_spatial_feature_writes: true,
    },
    registered_artifact_paths: artifactPaths,
  };

  if (selectedModel) {
    metadataPatch.selected_model = selectedModel;
  }
  if (Object.keys(modelMetricsSummary).length > 0) {
    metadataPatch.model_metrics_summary = modelMetricsSummary;
  }

  return {
    success: true,
    skipped: false,
    ...result,
    warnings,
    artifactPaths,
    metadataPatch,
  };
};

export {
  registerAiRunArtifactsForReview,
  type AiArtifactRegistrationResult,
  type AiRunArtifactRegistrationInput,
};
