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
  predictionFeaturesRegistered: number;
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
  | 'metadata'
  | 'feature_extraction_summary'
  | 'ground_truth_summary'
  | 'regional_classification_summary'
  | 'vectorization_summary'
  | 'ai_class_statistics_json'
  | 'ai_class_statistics_csv'
  | 'ai_classification_review'
  | 'ai_confidence_review'
  | 'ai_uncertainty_areas'
  | 'classification_polygons'
  | 'confidence_polygons'
  | 'uncertainty_areas';

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

type ReviewLayerType = 'classification';

type InsertedOutputLayer = {
  id: string;
  layerType: ReviewLayerType;
  storagePath: string;
};

type ReviewOutputLayerInsertResult = {
  inserted: number;
  layers: Partial<Record<ReviewLayerType, InsertedOutputLayer>>;
};

type PredictionFeatureRow = {
  artifactFeatureId: string;
  geometryType: string;
  geometry: JsonRecord;
  predictedClass: string | null;
  confidence: number | null;
  uncertaintyScore: number | null;
  modelName: string | null;
  metadata: JsonRecord;
};

const AI_PREDICTION_GEOMETRY_DIAGNOSTIC_SQL = `
WITH raw AS (
  SELECT ST_SetSRID(ST_GeomFromGeoJSON($1), 4326) AS raw_geom
),
cleaned AS (
  SELECT
    ST_Multi(
      ST_CollectionExtract(
        ST_MakeValid(
          ST_RemoveRepeatedPoints(
            ST_SnapToGrid(raw_geom, 0.0000001)
          )
        ),
        3
      )
    ) AS geom
  FROM raw
)
SELECT
  CASE
    WHEN geom IS NULL THEN 'No geometry after repair.'
    WHEN ST_IsEmpty(geom) THEN 'Geometry is empty after repair.'
    ELSE ST_IsValidReason(geom)
  END AS reason
FROM cleaned`;

const INSERT_AI_PREDICTION_FEATURE_SQL = `
WITH raw AS (
  SELECT ST_SetSRID(ST_GeomFromGeoJSON($1), 4326) AS raw_geom
),
cleaned AS (
  SELECT
    raw_geom,
    ST_Multi(
      ST_CollectionExtract(
        ST_MakeValid(
          ST_RemoveRepeatedPoints(
            ST_SnapToGrid(raw_geom, 0.0000001)
          )
        ),
        3
      )
    ) AS geom
  FROM raw
),
valid AS (
  SELECT
    geom,
    (
      NOT ST_IsValid(raw_geom)
      OR REPLACE(ST_GeometryType(raw_geom), 'ST_', '') <> REPLACE(ST_GeometryType(geom), 'ST_', '')
    ) AS repaired,
    REPLACE(ST_GeometryType(geom), 'ST_', '') AS geometry_type
  FROM cleaned
  WHERE geom IS NOT NULL
    AND NOT ST_IsEmpty(geom)
    AND ST_IsValid(geom)
),
upserted AS (
  INSERT INTO ai_prediction_feature (
    project_id,
    ai_run_id,
    ai_output_layer_id,
    artifact_feature_id,
    geom,
    raw_geom,
    processed_geom,
    geometry_type,
    predicted_class,
    confidence,
    uncertainty_score,
    model_name,
    source,
    status,
    metadata,
    source_resolution_m,
    raw_area_m2,
    processed_area_m2,
    area_change_percent,
    processing_method,
    minimum_mapping_unit_m2,
    simplification_tolerance_m,
    smoothing_iterations,
    geometry_quality
  )
  SELECT
    $2,
    $3,
    $4,
    $5,
    geom,
    geom,
    geom,
    geometry_type,
    $6,
    $7,
    $8,
    $9,
    'ai_prediction',
    'ready_for_review',
    $10::jsonb,
    NULLIF($10::jsonb #>> '{properties,source_resolution_m}', '')::double precision,
    NULLIF($10::jsonb #>> '{properties,raw_area_m2}', '')::double precision,
    NULLIF($10::jsonb #>> '{properties,processed_area_m2}', '')::double precision,
    NULLIF($10::jsonb #>> '{properties,area_change_percent}', '')::double precision,
    NULLIF($10::jsonb #>> '{properties,processing_method}', ''),
    NULLIF($10::jsonb #>> '{properties,minimum_mapping_unit_m2}', '')::double precision,
    NULLIF($10::jsonb #>> '{properties,simplification_tolerance_m}', '')::double precision,
    NULLIF($10::jsonb #>> '{properties,smoothing_iterations}', '')::integer,
    NULLIF($10::jsonb #>> '{properties,geometry_quality}', '')
  FROM valid
  ON CONFLICT (ai_output_layer_id, artifact_feature_id)
  DO UPDATE SET
    geom = EXCLUDED.geom,
    raw_geom = EXCLUDED.raw_geom,
    processed_geom = EXCLUDED.processed_geom,
    geometry_type = EXCLUDED.geometry_type,
    predicted_class = EXCLUDED.predicted_class,
    confidence = EXCLUDED.confidence,
    uncertainty_score = EXCLUDED.uncertainty_score,
    model_name = EXCLUDED.model_name,
    source = 'ai_prediction',
    status = CASE
      WHEN ai_prediction_feature.status = 'published' THEN ai_prediction_feature.status
      ELSE EXCLUDED.status
    END,
    metadata = EXCLUDED.metadata,
    source_resolution_m = EXCLUDED.source_resolution_m,
    raw_area_m2 = EXCLUDED.raw_area_m2,
    processed_area_m2 = EXCLUDED.processed_area_m2,
    area_change_percent = EXCLUDED.area_change_percent,
    processing_method = EXCLUDED.processing_method,
    minimum_mapping_unit_m2 = EXCLUDED.minimum_mapping_unit_m2,
    simplification_tolerance_m = EXCLUDED.simplification_tolerance_m,
    smoothing_iterations = EXCLUDED.smoothing_iterations,
    geometry_quality = EXCLUDED.geometry_quality,
    updated_at = NOW()
  RETURNING id
)
SELECT
  (SELECT id FROM upserted) AS id,
  COALESCE((SELECT repaired FROM valid LIMIT 1), false) AS repaired`;

const KNOWN_ARTIFACT_FILENAMES: Record<KnownArtifactKey, string> = {
  metrics: 'metrics.json',
  confusion_matrix: 'confusion_matrix.csv',
  classification_report: 'classification_report.csv',
  feature_importance: 'feature_importance.csv',
  model_metadata: 'model_metadata.json',
  metadata: 'metadata.json',
  feature_extraction_summary: 'feature_extraction_summary.json',
  ground_truth_summary: 'ground_truth_summary.json',
  regional_classification_summary: 'regional_classification_summary.json',
  vectorization_summary: 'vectorization_summary.json',
  ai_class_statistics_json: 'ai_class_statistics.json',
  ai_class_statistics_csv: 'ai_class_statistics.csv',
  ai_classification_review: 'ai_classification_review.geojson',
  ai_confidence_review: 'ai_confidence_review.geojson',
  ai_uncertainty_areas: 'ai_uncertainty_areas.geojson',
  classification_polygons: 'classification_polygons.geojson',
  confidence_polygons: 'confidence_polygons.geojson',
  uncertainty_areas: 'uncertainty_areas.geojson',
};

const KNOWN_ARTIFACT_KEYS = Object.keys(KNOWN_ARTIFACT_FILENAMES) as KnownArtifactKey[];
const KNOWN_ARTIFACT_BASENAMES = new Set(Object.values(KNOWN_ARTIFACT_FILENAMES));
const REGISTRATION_PHASE = 'phase_h_artifact_registration';
const LEGACY_REVIEW_LAYER_ARTIFACT_KEYS = new Set<KnownArtifactKey>([
  'ai_confidence_review',
  'ai_uncertainty_areas',
  'confidence_polygons',
  'uncertainty_areas',
]);

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
    case 'gradient_boosting':
    case 'gb':
      return 'Gradient Boosting';
    case 'xgboost':
    case 'xgb':
      return 'XGBoost (historical, unsupported)';
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

  const candidate = path.isAbsolute(rawPath) ? path.resolve(rawPath) : path.resolve(root, rawPath);
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

const outputPathEndingWith = (metadata: JsonRecord, filename: string): string | null => {
  const pathCollections = [metadata.output_paths, metadata.review_artifacts, metadata.outputs];
  const outputPaths = pathCollections.flatMap((collection) => {
    if (Array.isArray(collection)) {
      return collection;
    }
    const record = toRecord(collection);
    return Object.keys(record).length > 0 ? Object.values(record) : [];
  });
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
    metadata.run_id,
    metadata.regional_run_id,
    toRecord(metadata.model_metrics_summary).run_id,
  ]);
  const runOutputDir = runId ? `outputs/runs/${runId}` : null;
  const projectOutputDir = `outputs/projects/${input.projectId}`;
  const executionMode = toStringValue(metadata.execution_mode);
  const hasRegionalClassificationArtifacts =
    executionMode === 'regional_classification' ||
    executionMode === 'regional_vectorization_artifacts' ||
    executionMode === 'regional_full_review_artifacts';
  const hasRegionalVectorArtifacts =
    executionMode === 'regional_vectorization_artifacts' ||
    executionMode === 'regional_full_review_artifacts';

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
    metadata:
      firstString([metadata.metadata_path, outputPathEndingWith(metadata, 'metadata.json')]) ??
      undefined,
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
    ...(hasRegionalClassificationArtifacts
      ? {
          regional_classification_summary:
            firstString([
              metadata.regional_classification_summary_path,
              outputPathEndingWith(metadata, 'regional_classification_summary.json'),
              runOutputDir ? `${runOutputDir}/regional_classification_summary.json` : null,
            ]) ?? undefined,
        }
      : {}),
    ...(hasRegionalVectorArtifacts
      ? {
          vectorization_summary:
            firstString([
              metadata.vectorization_summary_path,
              outputPathEndingWith(metadata, 'vectorization_summary.json'),
              runOutputDir ? `${runOutputDir}/vectorization_summary.json` : null,
            ]) ?? undefined,
          ai_class_statistics_json:
            firstString([
              metadata.ai_class_statistics_json_path,
              outputPathEndingWith(metadata, 'ai_class_statistics.json'),
            ]) ?? undefined,
          ai_class_statistics_csv:
            firstString([
              metadata.ai_class_statistics_csv_path,
              outputPathEndingWith(metadata, 'ai_class_statistics.csv'),
            ]) ?? undefined,
          ai_classification_review:
            firstString([
              metadata.ai_classification_review_path,
              outputPathEndingWith(metadata, 'ai_classification_review.geojson'),
            ]) ?? undefined,
          ai_confidence_review:
            firstString([
              metadata.ai_confidence_review_path,
              outputPathEndingWith(metadata, 'ai_confidence_review.geojson'),
            ]) ?? undefined,
          ai_uncertainty_areas:
            firstString([
              metadata.ai_uncertainty_areas_path,
              outputPathEndingWith(metadata, 'ai_uncertainty_areas.geojson'),
            ]) ?? undefined,
          classification_polygons:
            firstString([
              metadata.classification_polygons_path,
              outputPathEndingWith(metadata, 'classification_polygons.geojson'),
              runOutputDir ? `${runOutputDir}/classification_polygons.geojson` : null,
            ]) ?? undefined,
          confidence_polygons:
            firstString([
              metadata.confidence_polygons_path,
              outputPathEndingWith(metadata, 'confidence_polygons.geojson'),
              runOutputDir ? `${runOutputDir}/confidence_polygons.geojson` : null,
            ]) ?? undefined,
          uncertainty_areas:
            firstString([
              metadata.uncertainty_areas_path,
              outputPathEndingWith(metadata, 'uncertainty_areas.geojson'),
              runOutputDir ? `${runOutputDir}/uncertainty_areas.geojson` : null,
            ]) ?? undefined,
        }
      : {}),
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

const existingArtifactPath = async (
  artifact: ResolvedArtifact | undefined,
  warnings: string[],
): Promise<string | null> => {
  if (!artifact) {
    return null;
  }
  if (!(await fileExists(artifact.absolutePath))) {
    warnings.push(`AI artifact not found: ${artifact.relativePath}.`);
    return null;
  }
  return artifact.relativePath;
};

const readGeoJsonFeatureCollection = async (
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
    const parsed = JSON.parse(await fs.readFile(artifact.absolutePath, 'utf8'));
    const collection = toRecord(parsed);
    if (collection.type !== 'FeatureCollection' || !Array.isArray(collection.features)) {
      warnings.push(`AI GeoJSON artifact is not a FeatureCollection: ${artifact.relativePath}.`);
      return {};
    }
    return collection;
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown GeoJSON parse error.';
    warnings.push(`Could not parse ${artifact.relativePath}: ${message}`);
    return {};
  }
};

const boundedScore = (value: unknown): number | null => {
  const parsed = toNumberValue(value);
  if (parsed === null || parsed < 0 || parsed > 1) {
    return null;
  }
  return parsed;
};

const firstNumber = (values: unknown[]): number | null => {
  for (const value of values) {
    const parsed = boundedScore(value);
    if (parsed !== null) {
      return parsed;
    }
  }
  return null;
};

const predictionArtifactFeatureId = (
  feature: JsonRecord,
  properties: JsonRecord,
  artifactKey: KnownArtifactKey,
  index: number,
): string =>
  firstString([
    feature.id,
    properties.id,
    properties.feature_id,
    properties.artifact_feature_id,
    properties.source_feature_id,
    properties.source_id,
    properties.prediction_id,
    properties.objectid,
    properties.OBJECTID,
    properties.fid,
    properties.FID,
    properties.gid,
  ]) ?? `${artifactKey}-${index + 1}`;

const predictionClassFrom = (properties: JsonRecord): string | null =>
  firstString([
    properties.predicted_class,
    properties.predicted_class_label,
    properties.class_label,
    properties.class_name,
    properties.dominant_class,
    properties.suggested_class,
    properties.label,
    properties.L4_descr,
    properties.class,
    properties.prediction,
  ]);

const predictionModelFrom = (properties: JsonRecord, selectedModel: string | null): string | null =>
  firstString([
    properties.model_name,
    properties.model,
    properties.classification_model,
    selectedModel,
  ]);

const predictionConfidenceFrom = (properties: JsonRecord): number | null =>
  firstNumber([
    properties.confidence,
    properties.confidence_score,
    properties.probability,
    properties.max_probability,
    properties.prediction_confidence,
    properties.mean_confidence,
    properties.confidence_mean,
    properties.mean,
  ]);

const predictionUncertaintyFrom = (properties: JsonRecord): number | null =>
  firstNumber([
    properties.uncertainty_score,
    properties.uncertainty,
    properties.prediction_uncertainty,
  ]);

const predictionRowsFromGeoJson = ({
  collection,
  artifactKey,
  layerType,
  selectedModel,
  limitations,
}: {
  collection: JsonRecord;
  artifactKey: KnownArtifactKey;
  layerType: 'classification';
  selectedModel: string | null;
  limitations: string[];
}): PredictionFeatureRow[] => {
  return toArray(collection.features)
    .map((item, index): PredictionFeatureRow | null => {
      const feature = toRecord(item);
      const properties = toRecord(feature.properties);
      const geometry = toRecord(feature.geometry);
      const geometryType = toStringValue(geometry.type);
      if (!geometryType || !Array.isArray(geometry.coordinates)) {
        return null;
      }

      return {
        artifactFeatureId: predictionArtifactFeatureId(feature, properties, artifactKey, index),
        geometryType,
        geometry,
        predictedClass: predictionClassFrom(properties),
        confidence: predictionConfidenceFrom(properties),
        uncertaintyScore: predictionUncertaintyFrom(properties),
        modelName: predictionModelFrom(properties, selectedModel),
        metadata: {
          properties,
          artifact_key: artifactKey,
          layer_type: layerType,
          source: 'ai_prediction',
          area: properties.area ?? properties.area_ha ?? properties.area_sq_m ?? null,
          regional_review_prediction: true,
          not_official_field_data: true,
          no_spatial_feature_writes: true,
          not_national_classification: true,
          confidence_is_attribute: true,
          standalone_confidence_layer: false,
          standalone_uncertainty_layer: false,
          limitations,
        },
      };
    })
    .filter((row): row is PredictionFeatureRow => row !== null);
};

const confidenceThresholdFromArtifacts = ({
  inputMetadata,
  collection,
  artifactMetadata,
  regionalClassificationSummary,
  aiClassStatistics,
}: {
  inputMetadata: JsonRecord;
  collection: JsonRecord;
  artifactMetadata: JsonRecord;
  regionalClassificationSummary: JsonRecord;
  aiClassStatistics: JsonRecord;
}): number | null =>
  firstNumber([
    inputMetadata.confidence_threshold,
    toRecord(inputMetadata.ai_settings).confidence_threshold,
    toRecord(inputMetadata.settings).confidence_threshold,
    toRecord(collection.metadata).confidence_threshold,
    artifactMetadata.confidence_threshold,
    regionalClassificationSummary.confidence_threshold,
    toRecord(aiClassStatistics.confidence_summary).threshold,
  ]);

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
  const modelSelection = toRecord(metricsPayload.model_selection);
  const selectedModel =
    firstString([
      metricsPayload.model_used_for_classification_map,
      metricsPayload.selected_model,
      metricsPayload.best_model,
      modelSelection.selected_model,
      modelSelection.model,
    ]) ?? bestModel;
  const holdoutResults = toRecord(metricsPayload.holdout_results);
  const classLabels = toArray(metricsPayload.selected_classes ?? metricsPayload.classes)
    .map(String)
    .filter((value) => value.trim().length > 0);
  const confusionMatrixFrom = (value: unknown): unknown => {
    if (!Array.isArray(value)) {
      return value;
    }
    const rows = value
      .map((rawRow, index) => {
        if (!Array.isArray(rawRow)) {
          return null;
        }
        const actual = classLabels[index] ?? `Class ${index + 1}`;
        const row: JsonRecord = { actual };
        let total = 0;
        rawRow.forEach((rawCount, predictedIndex) => {
          const label = classLabels[predictedIndex] ?? `Class ${predictedIndex + 1}`;
          const count = toIntValue(rawCount) ?? 0;
          row[label] = count;
          total += count;
        });
        row.total = total;
        return row;
      })
      .filter((row): row is JsonRecord => row !== null);
    return { labels: classLabels, rows };
  };
  const candidates = (() => {
    if (Object.keys(models).length > 0) {
      return Object.entries(models).map(([modelName, metricValue]) => ({
        model: modelName,
        ...toRecord(metricValue),
      }));
    }
    const selectionCandidates = toArray(modelSelection.candidates).map(toRecord);
    if (selectionCandidates.length > 0) {
      return selectionCandidates;
    }
    const cvResults = toArray(metricsPayload.cv_results).map(toRecord);
    if (cvResults.length > 0) {
      return cvResults;
    }
    return [];
  })();
  return candidates
    .map((candidateValue) => {
      const candidate = toRecord(candidateValue);
      const candidateModelName = firstString([
        candidate.model_name,
        candidate.model,
        candidate.model_key,
      ]);
      const modelKey = candidateModelName ?? 'AI pipeline';
      const holdout = toRecord(holdoutResults[modelKey]);
      const metrics = { ...holdout, ...candidate };
      const isSelected =
        selectedModel !== null &&
        normalizeModelName(selectedModel) === normalizeModelName(modelKey);
      return {
        modelName: modelKey,
        overallAccuracy: toNumberValue(
          metrics.accuracy ??
            metrics.overall_accuracy ??
            metrics.holdout_overall_accuracy ??
            metrics.holdout_oa ??
            metrics.validation_accuracy ??
            metrics.oa_mean,
        ),
        macroF1: toNumberValue(
          metrics.macro_f1 ?? metrics.macroF1 ?? metrics.holdout_f1_macro ?? metrics.f1_mean,
        ),
        weightedF1: toNumberValue(
          metrics.weighted_f1 ??
            metrics.weightedF1 ??
            metrics.holdout_f1_weighted ??
            metrics.f1_weighted ??
            metrics.weighted_f1_score,
        ),
        metrics: {
          model_key: modelKey,
          model_display_name: friendlyModelName(modelKey),
          model_metrics: metrics,
          selected_by_macro_f1: bestModel === modelKey,
          selected_by_composite: isSelected,
          model_selection: Object.keys(modelSelection).length > 0 ? modelSelection : undefined,
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
        confusionMatrix:
          (isSelected && metricsPayload.confusion_matrix) ||
          metrics.confusion_matrix ||
          confusionMatrixFrom(metrics.holdout_confusion_matrix) || {
            applies_to_model: selectedModel ?? bestModel,
            rows: confusionMatrixRows,
          },
        featureImportance:
          (isSelected && toArray(metricsPayload.feature_importance).length > 0
            ? toArray(metricsPayload.feature_importance)
            : featureImportanceForModel(featureImportanceRows, modelKey)),
      };
    })
    .filter(
      (row) => row.overallAccuracy !== null || row.macroF1 !== null || row.weightedF1 !== null,
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
      sources: Array.from(new Set([...toArray(existing.statistics.sources).map(String), source])),
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

const mergePhaseMClassStatistics = (
  rowsByLabel: Map<string, ClassStatisticRow>,
  aiClassStatistics: JsonRecord,
): void => {
  for (const item of toArray(aiClassStatistics.class_statistics)) {
    const row = toRecord(item);
    const classLabel = toStringValue(row.class_label);
    const predictedCount = toIntValue(
      row.predicted_feature_count ?? row.feature_count ?? row.count,
    );
    if (!classLabel || predictedCount === null) {
      continue;
    }

    const normalized = classLabel.toLowerCase();
    const existing =
      rowsByLabel.get(normalized) ??
      ({
        classLabel,
        featureCount: predictedCount,
        areaHa: null,
        confidenceMean: null,
        statistics: {
          sources: [],
        },
      } satisfies ClassStatisticRow);

    existing.featureCount = predictedCount;
    existing.areaHa = toNumberValue(row.area_ha) ?? existing.areaHa;
    existing.confidenceMean = toNumberValue(row.confidence_mean) ?? existing.confidenceMean;
    existing.statistics = {
      ...existing.statistics,
      eligible: true,
      predicted_feature_count: predictedCount,
      approved_feature_count: toIntValue(row.approved_feature_count),
      confidence_min: toNumberValue(row.confidence_min),
      confidence_max: toNumberValue(row.confidence_max),
      phase_m_review_artifact: true,
      sources: Array.from(
        new Set([...toArray(existing.statistics.sources).map(String), 'ai_class_statistics']),
      ),
    };
    rowsByLabel.set(normalized, existing);
  }

  mergeClassCountSource(
    rowsByLabel,
    aiClassStatistics.predicted_class_counts,
    'ai_class_statistics',
    true,
  );
};

const mergeExcludedClassCountSource = (
  rowsByLabel: Map<string, ClassStatisticRow>,
  excludedClasses: unknown,
  source: string,
): void => {
  const excludedCounts = toRecord(excludedClasses);
  for (const [label, countValue] of Object.entries(excludedCounts)) {
    const classLabel = label.trim();
    const featureCount = toIntValue(countValue);
    if (!classLabel || featureCount === null) {
      continue;
    }
    const normalized = classLabel.toLowerCase();
    if (rowsByLabel.has(normalized)) {
      continue;
    }
    rowsByLabel.set(normalized, {
      classLabel,
      featureCount,
      areaHa: null,
      confidenceMean: null,
      statistics: {
        eligible: false,
        excluded: true,
        exclusion_reason: 'below_minimum_samples',
        [`${source}_feature_count`]: featureCount,
        sources: [source],
      },
    });
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
  mergeExcludedClassCountSource(rowsByLabel, metadata.excluded_classes, 'ai_run_metadata');
};

const classStatisticRowsFromArtifacts = ({
  metricsPayload,
  featureExtractionSummary,
  groundTruthSummary,
  vectorizationSummary,
  regionalClassificationSummary,
  aiClassStatistics,
  classificationReportRows,
  metadata,
}: {
  metricsPayload: JsonRecord;
  featureExtractionSummary: JsonRecord;
  groundTruthSummary: JsonRecord;
  vectorizationSummary: JsonRecord;
  regionalClassificationSummary: JsonRecord;
  aiClassStatistics: JsonRecord;
  classificationReportRows: JsonRecord[];
  metadata: JsonRecord;
}): ClassStatisticRow[] => {
  const rowsByLabel = new Map<string, ClassStatisticRow>();
  mergeClassCountSource(rowsByLabel, groundTruthSummary.class_counts, 'ground_truth', true);
  mergeClassCountSource(
    rowsByLabel,
    featureExtractionSummary.class_counts,
    'feature_extraction',
    true,
  );
  mergeClassCountSource(rowsByLabel, metricsPayload.class_counts, 'metrics', true);
  mergeClassCountSource(
    rowsByLabel,
    regionalClassificationSummary.class_counts,
    'regional_classification',
    true,
  );
  mergeClassCountSource(rowsByLabel, vectorizationSummary.class_counts, 'vectorization', true);
  mergeClassificationReportSupport(rowsByLabel, classificationReportRows);
  mergePhaseMClassStatistics(rowsByLabel, aiClassStatistics);
  mergeExcludedClassCountSource(
    rowsByLabel,
    regionalClassificationSummary.excluded_classes,
    'regional_classification',
  );
  mergeExcludedClassCountSource(
    rowsByLabel,
    vectorizationSummary.excluded_classes,
    'vectorization',
  );
  mergeExcludedClasses(rowsByLabel, metadata);
  return Array.from(rowsByLabel.values()).sort((left, right) =>
    left.classLabel.localeCompare(right.classLabel),
  );
};

const modelMetricsSummaryFrom = (metricsPayload: JsonRecord): JsonRecord => {
  const modelSelection = toRecord(metricsPayload.model_selection);
  const selectedModel = firstString([
    metricsPayload.model_used_for_classification_map,
    metricsPayload.selected_model,
    metricsPayload.best_model,
    modelSelection.selected_model,
    modelSelection.model,
  ]);
  const holdoutResults = toRecord(metricsPayload.holdout_results);
  const modelCandidates = (() => {
    const models = toRecord(metricsPayload.models);
    if (Object.keys(models).length > 0) {
      return Object.entries(models).map(([modelName, metrics]) => ({
        modelName,
        metrics: toRecord(metrics),
      }));
    }
    const candidates = toArray(modelSelection.candidates).map(toRecord);
    if (candidates.length > 0) {
      return candidates.map((metrics) => {
        const modelName = firstString([metrics.model_name, metrics.model, metrics.model_key]);
        return { modelName: modelName ?? 'AI pipeline', metrics };
      });
    }
    return toArray(metricsPayload.cv_results).map(toRecord).map((metrics) => {
      const modelName = firstString([metrics.model_name, metrics.model, metrics.model_key]);
      return { modelName: modelName ?? 'AI pipeline', metrics };
    });
  })();
  const modelEntries = modelCandidates.map(({ modelName, metrics }) => {
    const holdout = toRecord(holdoutResults[modelName]);
    return [modelName, { ...holdout, ...metrics }] as const;
  });
  const models = Object.fromEntries(modelEntries);
  const bestBalanced = modelEntries
    .map(([modelName, metrics]) => ({
      modelName,
      macroF1: toNumberValue(
        toRecord(metrics).macro_f1 ??
          toRecord(metrics).holdout_f1_macro ??
          toRecord(metrics).f1_mean,
      ),
      accuracy: toNumberValue(
        toRecord(metrics).accuracy ??
          toRecord(metrics).holdout_overall_accuracy ??
          toRecord(metrics).holdout_oa ??
          toRecord(metrics).oa_mean,
      ),
    }))
    .filter((row) => row.macroF1 !== null)
    .sort((left, right) => {
      const macroDiff = (right.macroF1 ?? 0) - (left.macroF1 ?? 0);
      return macroDiff !== 0 ? macroDiff : (right.accuracy ?? 0) - (left.accuracy ?? 0);
    })[0];
  const highestAccuracy = modelEntries
    .map(([modelName, metrics]) => ({
      modelName,
      accuracy: toNumberValue(
        toRecord(metrics).accuracy ??
          toRecord(metrics).holdout_overall_accuracy ??
          toRecord(metrics).holdout_oa ??
          toRecord(metrics).oa_mean,
      ),
    }))
    .filter((row) => row.accuracy !== null)
    .sort((left, right) => (right.accuracy ?? 0) - (left.accuracy ?? 0))[0];

  return {
    run_id: metricsPayload.run_id,
    best_model: selectedModel ?? metricsPayload.best_model,
    best_balanced_model: selectedModel ?? bestBalanced?.modelName ?? metricsPayload.best_model,
    highest_accuracy_model: highestAccuracy?.modelName ?? null,
    selected_model: selectedModel ?? metricsPayload.best_model,
    model_selection: modelSelection,
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

const insertOutputLayer = async ({
  client,
  runId,
  projectId,
  layerType,
  name,
  description,
  storagePath,
}: {
  client: PoolClient;
  runId: string;
  projectId: string;
  layerType: 'classification';
  name: string;
  description: string;
  storagePath: string | null;
}): Promise<InsertedOutputLayer | null> => {
  if (!storagePath) {
    return null;
  }
  const result = await client.query(
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
       $3,
       'ready_for_review',
       $4,
       $5,
       $6,
       'EPSG:4326',
       '{}'::jsonb
     )
     RETURNING id, layer_type`,
    [runId, projectId, layerType, name, description, storagePath],
  );
  return {
    id: result.rows[0].id,
    layerType: result.rows[0].layer_type,
    storagePath,
  };
};

const insertReviewOutputLayers = async ({
  client,
  runId,
  projectId,
  classificationPath,
}: {
  client: PoolClient;
  runId: string;
  projectId: string;
  classificationPath: string | null;
}): Promise<ReviewOutputLayerInsertResult> => {
  const layers: Partial<Record<ReviewLayerType, InsertedOutputLayer>> = {};
  const track = (layer: InsertedOutputLayer | null): void => {
    if (layer) {
      layers[layer.layerType] = layer;
    }
  };

  track(
    await insertOutputLayer({
      client,
      runId,
      projectId,
      layerType: 'classification',
      name: 'Regional AI classification review layer',
      description:
        'Unpublished regional classification polygons with confidence attributes for review.',
      storagePath: classificationPath,
    }),
  );
  return {
    inserted: Object.keys(layers).length,
    layers,
  };
};

const updateOutputLayerBounds = async (client: PoolClient, layerId: string): Promise<void> => {
  await client.query(
    `UPDATE ai_output_layer l
     SET bounds = bounds_summary.bounds,
         updated_at = NOW()
     FROM (
       SELECT ST_SetSRID(ST_Envelope(ST_Extent(COALESCE(processed_geom, geom))::geometry), 4326) AS bounds
       FROM ai_prediction_feature
       WHERE ai_output_layer_id = $1
     ) AS bounds_summary
     WHERE l.id = $1
       AND bounds_summary.bounds IS NOT NULL`,
    [layerId],
  );
};

const aiPredictionGeometrySkipReason = async (
  client: PoolClient,
  geometryJson: string,
): Promise<string> => {
  await client.query('SAVEPOINT ai_prediction_feature_diag');
  try {
    const result = await client.query<{ reason: string | null }>(
      AI_PREDICTION_GEOMETRY_DIAGNOSTIC_SQL,
      [geometryJson],
    );
    await client.query('RELEASE SAVEPOINT ai_prediction_feature_diag');
    return result.rows[0]?.reason ?? 'Geometry is invalid after repair.';
  } catch (error) {
    await client.query('ROLLBACK TO SAVEPOINT ai_prediction_feature_diag');
    await client.query('RELEASE SAVEPOINT ai_prediction_feature_diag');
    const message = error instanceof Error ? error.message : 'Unknown diagnostic error.';
    return `Geometry diagnostic failed: ${message}`;
  }
};

const pushAiRegistrationWarning = (warnings: string[], message: string): void => {
  if (warnings.length < 50) {
    warnings.push(message);
  }
};

const insertPredictionFeatureRows = async ({
  client,
  runId,
  projectId,
  layer,
  rows,
  warnings,
}: {
  client: PoolClient;
  runId: string;
  projectId: string;
  layer: InsertedOutputLayer | undefined;
  rows: PredictionFeatureRow[];
  warnings: string[];
}): Promise<number> => {
  if (!layer || rows.length === 0) {
    return 0;
  }

  let registered = 0;
  let repaired = 0;
  let skipped = 0;
  let failed = 0;
  for (const row of rows) {
    const geometryJson = JSON.stringify(row.geometry);
    await client.query('SAVEPOINT ai_prediction_feature_row');
    try {
      const result = await client.query<{ id: string | null; repaired: boolean }>(
        INSERT_AI_PREDICTION_FEATURE_SQL,
        [
          geometryJson,
          projectId,
          runId,
          layer.id,
          row.artifactFeatureId,
          row.predictedClass,
          row.confidence,
          row.uncertaintyScore,
          row.modelName,
          JSON.stringify({
            ...row.metadata,
            source_geometry_type: row.geometryType,
          }),
        ],
      );
      const inserted = result.rows[0];
      if (!inserted?.id) {
        const reason = await aiPredictionGeometrySkipReason(client, geometryJson);
        skipped += 1;
        pushAiRegistrationWarning(
          warnings,
          `Skipped invalid AI prediction geometry ${row.artifactFeatureId} (${row.predictedClass ?? 'unknown'}): ${reason}`,
        );
        await client.query('RELEASE SAVEPOINT ai_prediction_feature_row');
        continue;
      }
      if (inserted.repaired) {
        repaired += 1;
      }
      await client.query('RELEASE SAVEPOINT ai_prediction_feature_row');
      registered += 1;
    } catch (error) {
      await client.query('ROLLBACK TO SAVEPOINT ai_prediction_feature_row');
      await client.query('RELEASE SAVEPOINT ai_prediction_feature_row');
      failed += 1;
      const message = error instanceof Error ? error.message : 'Unknown geometry insert error.';
      pushAiRegistrationWarning(
        warnings,
        `Failed to insert AI prediction geometry ${row.artifactFeatureId} (${row.predictedClass ?? 'unknown'}): ${message}`,
      );
      continue;
    }
  }

  if (repaired > 0 || skipped > 0 || failed > 0) {
    pushAiRegistrationWarning(
      warnings,
      `AI prediction geometry cleanup summary: inserted=${registered}, repaired=${repaired}, skipped=${skipped}, failed=${failed}.`,
    );
  }

  if (rows.length > 0 && registered === 0 && (skipped > 0 || failed > 0)) {
    throw new Error(
      `AI prediction output did not contain any insertable geometries after repair. skipped=${skipped}, failed=${failed}.`,
    );
  }

  if (registered > 0) {
    await updateOutputLayerBounds(client, layer.id);
  }
  return registered;
};

const insertPredictionFeaturesForReviewLayers = async ({
  client,
  runId,
  projectId,
  layers,
  classificationRows,
  warnings,
}: {
  client: PoolClient;
  runId: string;
  projectId: string;
  layers: Partial<Record<ReviewLayerType, InsertedOutputLayer>>;
  classificationRows: PredictionFeatureRow[];
  warnings: string[];
}): Promise<number> => {
  const classificationCount = await insertPredictionFeatureRows({
    client,
    runId,
    projectId,
    layer: layers.classification,
    rows: classificationRows,
    warnings,
  });

  return classificationCount;
};

const classCountMetadataFromRows = (
  rows: ClassStatisticRow[],
): { classCounts: JsonRecord[]; excludedClasses: JsonRecord[] } => {
  const classCounts: JsonRecord[] = [];
  const excludedClasses: JsonRecord[] = [];
  for (const row of rows) {
    const target =
      row.statistics.excluded === true || row.statistics.eligible === false
        ? excludedClasses
        : classCounts;
    target.push({
      class_label: row.classLabel,
      feature_count: row.featureCount,
    });
  }
  return { classCounts, excludedClasses };
};

const registerAiRunArtifactsForReview = async (
  input: AiRunArtifactRegistrationInput,
): Promise<AiArtifactRegistrationResult> => {
  const metadata = input.metadata ?? {};
  const executionMode = toStringValue(metadata.execution_mode);
  const registrationEnabledModes = new Set([
    'regional_model_eval',
    'regional_classification',
    'regional_vectorization_artifacts',
    'regional_full_review_artifacts',
  ]);
  if (!executionMode || !registrationEnabledModes.has(executionMode)) {
    return {
      success: true,
      skipped: true,
      metricsRegistered: 0,
      classStatisticsRegistered: 0,
      outputLayersRegistered: 0,
      predictionFeaturesRegistered: 0,
      warnings: [
        'Artifact registration is only enabled for regional model or regional artifact runs.',
      ],
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
    Object.entries(artifacts)
      .filter(([key]) => !LEGACY_REVIEW_LAYER_ARTIFACT_KEYS.has(key as KnownArtifactKey))
      .map(([key, artifact]) => [key, artifact?.relativePath]),
  ) as RegisteredArtifactPaths;

  const [
    metricsPayload,
    modelMetadata,
    artifactMetadata,
    featureExtractionSummary,
    groundTruthSummary,
    regionalClassificationSummary,
    vectorizationSummary,
    aiClassStatistics,
    confusionMatrixRows,
    classificationReportRows,
    featureImportanceRows,
  ] = await Promise.all([
    readJsonArtifact(artifacts.metrics, warnings),
    readJsonArtifact(artifacts.model_metadata, warnings),
    readJsonArtifact(artifacts.metadata, warnings),
    readJsonArtifact(artifacts.feature_extraction_summary, warnings),
    readJsonArtifact(artifacts.ground_truth_summary, warnings),
    readJsonArtifact(artifacts.regional_classification_summary, warnings),
    readJsonArtifact(artifacts.vectorization_summary, warnings),
    readJsonArtifact(artifacts.ai_class_statistics_json, warnings),
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
    regionalClassificationSummary,
    vectorizationSummary,
    aiClassStatistics,
    classificationReportRows,
    metadata,
  });
  if (classStatisticRows.length === 0) {
    warnings.push('No class statistics were available to register.');
  }

  const classificationArtifact =
    artifacts.ai_classification_review ?? artifacts.classification_polygons;
  const classificationPath = await existingArtifactPath(classificationArtifact, warnings);
  const limitations = [
    ...toArray(regionalClassificationSummary.limitations),
    ...toArray(vectorizationSummary.limitations),
    ...toArray(artifactMetadata.limitations),
  ]
    .map(String)
    .filter((value, index, array) => value.trim().length > 0 && array.indexOf(value) === index);
  const selectedModel =
    toStringValue(metricsPayload.best_model) ??
    toStringValue(modelMetadata.best_model) ??
    toStringValue(regionalClassificationSummary.classification_model) ??
    toStringValue(regionalClassificationSummary.classification_output_model) ??
    toStringValue(artifactMetadata.classification_model) ??
    toStringValue(vectorizationSummary.classification_output_model);
  const modelMetricsSummary =
    Object.keys(metricsPayload).length > 0 ? modelMetricsSummaryFrom(metricsPayload) : {};
  const classificationCollection = await readGeoJsonFeatureCollection(
    classificationArtifact,
    warnings,
  );
  const confidenceThreshold = confidenceThresholdFromArtifacts({
    inputMetadata: metadata,
    collection: classificationCollection,
    artifactMetadata,
    regionalClassificationSummary,
    aiClassStatistics,
  });
  const rawClassificationPredictionRows = predictionRowsFromGeoJson({
    collection: classificationCollection,
    artifactKey: classificationArtifact?.key ?? 'ai_classification_review',
    layerType: 'classification',
    selectedModel,
    limitations,
  });
  const classificationPredictionRows =
    confidenceThreshold === null
      ? rawClassificationPredictionRows
      : rawClassificationPredictionRows.filter(
          (row) => row.confidence === null || row.confidence >= confidenceThreshold,
        );
  const belowThresholdRows =
    rawClassificationPredictionRows.length - classificationPredictionRows.length;
  if (belowThresholdRows > 0) {
    warnings.push(
      `${belowThresholdRows} AI prediction feature(s) below CONFIDENCE_THRESHOLD were not registered in the visible classification layer.`,
    );
  }

  const result = await transaction(async (client: PoolClient) => {
    await client.query(`DELETE FROM ai_run_metric WHERE ai_run_id = $1`, [input.runId]);
    await client.query(`DELETE FROM ai_class_statistic WHERE ai_run_id = $1`, [input.runId]);
    await client.query(
      `DELETE FROM ai_output_layer
       WHERE ai_run_id = $1
         AND status <> 'published'
         AND layer_type = ANY($2::ai_output_layer_type[])`,
      [input.runId, ['statistics', 'classification', 'confidence', 'uncertainty']],
    );

    const metricsRegistered = await insertMetricRows(client, input.runId, metricRows);
    const classStatisticsRegistered = await insertClassStatisticRows(
      client,
      input.runId,
      classStatisticRows,
    );
    const outputLayerResult = await insertReviewOutputLayers({
      client,
      runId: input.runId,
      projectId: input.projectId,
      classificationPath,
    });
    const predictionFeaturesRegistered = await insertPredictionFeaturesForReviewLayers({
      client,
      runId: input.runId,
      projectId: input.projectId,
      layers: outputLayerResult.layers,
      classificationRows: classificationPredictionRows,
      warnings,
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
      outputLayersRegistered: outputLayerResult.inserted,
      predictionFeaturesRegistered,
    };
  });

  const metadataPatch: JsonRecord = {
    artifact_registration: {
      phase: REGISTRATION_PHASE,
      registered_at: new Date().toISOString(),
      execution_mode: executionMode,
      metrics_registered: result.metricsRegistered,
      class_statistics_registered: result.classStatisticsRegistered,
      output_layers_registered: result.outputLayersRegistered,
      prediction_features_registered: result.predictionFeaturesRegistered,
      warnings,
      artifact_paths: artifactPaths,
      unpublished_only: true,
      review_only: true,
      no_spatial_feature_writes: true,
      prediction_feature_store: true,
      confidence_threshold: confidenceThreshold,
      below_threshold_excluded: belowThresholdRows,
    },
    registered_artifact_paths: artifactPaths,
  };

  if (selectedModel) {
    metadataPatch.selected_model = selectedModel;
  }
  if (Object.keys(modelMetricsSummary).length > 0) {
    metadataPatch.model_metrics_summary = modelMetricsSummary;
  }
  const { classCounts, excludedClasses } = classCountMetadataFromRows(classStatisticRows);
  if (classCounts.length > 0) {
    metadataPatch.class_counts = classCounts;
  }
  if (excludedClasses.length > 0) {
    metadataPatch.excluded_classes = excludedClasses;
  }
  const classificationModel = firstString([
    regionalClassificationSummary.classification_model,
    regionalClassificationSummary.classification_output_model,
    artifactMetadata.classification_model,
    vectorizationSummary.classification_output_model,
  ]);
  const metricsBestMacroF1Model = firstString([
    regionalClassificationSummary.metrics_best_macro_f1_model,
    regionalClassificationSummary.metrics_selected_model,
    artifactMetadata.metrics_best_macro_f1_model,
    vectorizationSummary.metrics_selected_model,
  ]);
  const highestAccuracyModel = firstString([
    regionalClassificationSummary.highest_accuracy_model,
    artifactMetadata.highest_accuracy_model,
  ]);
  const modelMismatchReason = firstString([
    regionalClassificationSummary.model_mismatch_reason,
    regionalClassificationSummary.model_selection_reason,
    artifactMetadata.model_mismatch_reason,
  ]);
  const confidenceSummary =
    Object.keys(toRecord(aiClassStatistics.confidence_summary)).length > 0
      ? toRecord(aiClassStatistics.confidence_summary)
      : toRecord(regionalClassificationSummary.confidence_summary);
  const belowThresholdFeatureCount =
    toIntValue(regionalClassificationSummary.below_threshold_feature_count) ??
    toIntValue(regionalClassificationSummary.uncertainty_feature_count) ??
    toIntValue(confidenceSummary.below_threshold_feature_count) ??
    toIntValue(confidenceSummary.uncertain_feature_count);
  const regionalScope = toRecord(regionalClassificationSummary.scope);

  if (classificationModel) {
    metadataPatch.classification_model = classificationModel;
  }
  if (metricsBestMacroF1Model) {
    metadataPatch.metrics_best_macro_f1_model = metricsBestMacroF1Model;
  }
  if (highestAccuracyModel) {
    metadataPatch.highest_accuracy_model = highestAccuracyModel;
  }
  if (modelMismatchReason) {
    metadataPatch.model_mismatch_reason = modelMismatchReason;
  }
  if (Object.keys(confidenceSummary).length > 0) {
    metadataPatch.confidence_summary = confidenceSummary;
  }
  if (belowThresholdFeatureCount !== null) {
    metadataPatch.below_threshold_feature_count = belowThresholdFeatureCount;
  }
  if (Object.keys(regionalScope).length > 0) {
    metadataPatch.regional_scope = regionalScope;
  }
  if (limitations.length > 0) {
    metadataPatch.scientific_limitations = limitations;
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
