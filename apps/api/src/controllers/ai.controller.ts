import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import type { PoolClient } from 'pg';
import type { Request, Response } from 'express';
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const { createAiPipelineService } = require('../services/aiPipeline.service');
const logger = require('../utils/logger');
import {
  createAiServerClient,
  type AiServerStartPayload,
  type AiServerStatusPayload,
} from '../services/aiServerClient.service';
import {
  assignPredictionValidationTask,
  createPredictionValidationSubmission,
  generatePredictionValidationTasks,
  getPredictionValidationTaskForUser,
  listAssignedPredictionValidationTasks,
  listProjectPredictionValidationTasks,
  reviewPredictionValidationTask,
  updatePredictionValidationTaskStatus,
} from '../services/aiPredictionValidation.service';
import {
  createPredictionFeatureValidation,
  getMyPredictionFeatureValidation,
  getPredictionFeatureDetailsForUser,
  getRunPredictionValidationSummary,
  listPredictionFeatureValidations,
  listRunPredictionValidations,
  reviewPredictionFeature,
} from '../services/aiPredictionFeatureValidation.service';
import { publicVisibleStatuses, synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';

const allowedRunStatuses = [
  'draft',
  'created',
  'queued',
  'starting',
  'running',
  'extracting_features',
  'training',
  'evaluating',
  'classifying',
  'ready_for_review',
  'completed',
  'cancelling',
  'paused',
  'published',
  'failed',
  'cancelled',
];

const allowedExecutionModes = [
  'mock',
  'dry_run',
  'local_ground_truth_export',
  'regional_feature_extraction',
  'regional_model_eval',
  'regional_classification',
  'regional_vectorization_artifacts',
  'regional_full_review_artifacts',
];

const regionalExecutionModes = [
  'regional_feature_extraction',
  'regional_model_eval',
  'regional_classification',
  'regional_vectorization_artifacts',
  'regional_full_review_artifacts',
];

const reviewActions = {
  approve_for_publication: {
    decision: 'approved_for_publish',
    layerStatus: 'approved',
    reviewStatus: 'approved_for_publication',
    logMessage: 'AI run approved for future publication. No viewer-facing AI layer was published.',
  },
  reject: {
    decision: 'rejected',
    layerStatus: 'rejected',
    reviewStatus: 'rejected',
    logMessage: 'AI run results rejected during protected super-admin review.',
  },
  request_more_data: {
    decision: 'needs_more_data',
    layerStatus: 'draft',
    reviewStatus: 'needs_more_data',
    logMessage: 'More training data requested during AI result review.',
  },
  keep_draft: {
    decision: 'keep_draft',
    layerStatus: 'draft',
    reviewStatus: 'draft',
    logMessage: 'AI run kept as a draft for later review.',
  },
} as const;

const previewableLayerStatuses = new Set(['draft', 'ready_for_review', 'approved', 'published']);
const previewableLayerTypes = new Set(['classification']);
const MAX_AI_LAYER_GEOJSON_BYTES = 20 * 1024 * 1024;
const MAX_AI_LAYER_PREVIEW_FEATURES = 2500;
const DEFAULT_AI_LAYER_OVERVIEW_FEATURE_LIMIT = 1800;
const DEV_CONTAINER_AI_OUTPUT_ROOT = '/workspace-ai-outputs';

const defaultSettings = {
  is_enabled: false,
  label_field: null,
  scope_type: 'project',
  scope_geometry: null,
  min_samples_per_class: 50,
  confidence_threshold: 0.6,
  model_preferences: {},
};

const lebanonApproxBounds = {
  min_lon: 35.1,
  min_lat: 33.0,
  max_lon: 36.7,
  max_lat: 34.75,
};

const lebanonStaticGovernorateZones = [
  { key: 'akkar', label: 'Akkar', min_lon: 35.65, min_lat: 34.35, max_lon: 36.65, max_lat: 34.75 },
  { key: 'north', label: 'North', min_lon: 35.55, min_lat: 34.05, max_lon: 36.35, max_lat: 34.45 },
  { key: 'beirut', label: 'Beirut', min_lon: 35.42, min_lat: 33.82, max_lon: 35.57, max_lat: 33.95 },
  { key: 'mount_lebanon', label: 'Mount Lebanon', min_lon: 35.35, min_lat: 33.45, max_lon: 36.1, max_lat: 34.15 },
  { key: 'bekaa', label: 'Bekaa', min_lon: 35.75, min_lat: 33.55, max_lon: 36.65, max_lat: 34.15 },
  { key: 'baalbek_hermel', label: 'Baalbek-Hermel', min_lon: 36.0, min_lat: 34.0, max_lon: 36.7, max_lat: 34.65 },
  { key: 'south', label: 'South', min_lon: 35.15, min_lat: 33.15, max_lon: 35.75, max_lat: 33.6 },
  { key: 'nabatieh', label: 'Nabatieh', min_lon: 35.35, min_lat: 33.05, max_lon: 36.0, max_lat: 33.65 },
] as const;

const NATIONAL_GRID_COLUMNS = 5;
const NATIONAL_GRID_ROWS = 4;

type NationalScopeRequirement = {
  key: string;
  label: string;
  passed: boolean;
  current_value: string | number | boolean | null;
  required_value: string | number | boolean;
  message: string;
};

type NationalCoverageSample = {
  lon: number | null;
  lat: number | null;
  class_label: string | null;
  governorate: string | null;
  elevation_band: string | null;
};

const supportedSatelliteAliases: Record<string, 'sentinel2' | 'landsat'> = {
  sentinel2: 'sentinel2',
  'sentinel-2': 'sentinel2',
  sentinel_2: 'sentinel2',
  s2: 'sentinel2',
  landsat: 'landsat',
  'landsat-8': 'landsat',
  'landsat-9': 'landsat',
  landsat8: 'landsat',
  landsat9: 'landsat',
};

const supportedSeasons = new Set(['growing', 'dry', 'harvest', 'winter']);
const supportedFeatureGroups = new Set([
  'spectral_bands',
  'vegetation_indices',
  'topography',
  'texture',
]);
const sentinel2SpectralFeatures = ['B2', 'B3', 'B4', 'B5', 'B6', 'B7', 'B8', 'B8A', 'B11', 'B12'];
const landsatSpectralFeatures = ['SR_B2', 'SR_B3', 'SR_B4', 'SR_B5', 'SR_B6', 'SR_B7'];
const sentinel2IndexFeatures = ['NDVI', 'EVI', 'NDRE', 'SAVI', 'NDWI'];
const landsatIndexFeatures = ['NDVI', 'EVI', 'SAVI', 'NDWI'];
const topographyFeatures = ['static_srtm_elevation', 'static_srtm_slope', 'static_srtm_aspect'];
const textureFeatures = ['static_texture_pc1'];
const textureDependencyMessage =
  'Texture features require Sentinel-2 NDVI from the dry season. Add a Sentinel-2 dry season/timeframe and select NDVI, or remove static_texture_pc1.';
const defaultFeatureGroups = ['spectral_bands', 'vegetation_indices', 'topography', 'texture'];
const defaultSentinel2FeatureInputs = [
  'B2',
  'B3',
  'B4',
  'B5',
  'B8',
  'B11',
  'B12',
  'NDVI',
  'EVI',
  'NDRE',
];
const defaultLandsatFeatureInputs = [
  'SR_B2',
  'SR_B3',
  'SR_B4',
  'SR_B5',
  'SR_B6',
  'SR_B7',
  'NDVI',
  'EVI',
  'SAVI',
  'NDWI',
];

const normalizeSatelliteSource = (value: unknown): 'sentinel2' | 'landsat' | null => {
  if (typeof value !== 'string') {
    return null;
  }
  return supportedSatelliteAliases[value.trim().toLowerCase()] ?? null;
};

const normalizeSatelliteSources = (preferences: Record<string, unknown>): Array<'sentinel2' | 'landsat'> => {
  const rawSources = Array.isArray(preferences.satellite_sources)
    ? preferences.satellite_sources
    : Array.isArray(preferences.satelliteSources)
      ? preferences.satelliteSources
      : preferences.satellite_source !== undefined
        ? [preferences.satellite_source]
        : preferences.satelliteSource !== undefined
          ? [preferences.satelliteSource]
          : ['sentinel2'];
  const sources: Array<'sentinel2' | 'landsat'> = [];
  for (const rawSource of rawSources) {
    const source = normalizeSatelliteSource(rawSource);
    if (source && !sources.includes(source)) {
      sources.push(source);
    }
  }
  return sources.length > 0 ? sources : ['sentinel2'];
};

const normalizeSeason = (value: unknown): string | null => {
  if (typeof value !== 'string') {
    return null;
  }
  const normalized = value.trim().toLowerCase();
  if (normalized === 'summer') {
    return 'dry';
  }
  if (normalized === 'spring') {
    return 'growing';
  }
  if (normalized === 'autumn' || normalized === 'fall') {
    return 'harvest';
  }
  return supportedSeasons.has(normalized) ? normalized : null;
};

const defaultSeasonRange = (season: string, year: number): { from_date: string; to_date: string } => {
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

const normalizeDateString = (value: unknown): string | null => {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? trimmed : null;
};

const normalizeYear = (value: unknown): number => {
  const parsed =
    typeof value === 'number'
      ? value
      : typeof value === 'string'
        ? Number.parseInt(value.trim(), 10)
        : Number.NaN;
  const currentYear = new Date().getFullYear();
  return Number.isInteger(parsed) && parsed >= 1980 && parsed <= currentYear + 2
    ? parsed
    : currentYear - 1;
};

const normalizeSatelliteTimeframes = (
  preferences: Record<string, unknown>,
  satelliteSources: Array<'sentinel2' | 'landsat'>,
): Record<string, { map_year: number; seasons: Array<{ season: string; from_date: string; to_date: string }> }> => {
  const rawTimeframes =
    preferences.satellite_timeframes && typeof preferences.satellite_timeframes === 'object'
      ? (preferences.satellite_timeframes as Record<string, unknown>)
      : preferences.satelliteTimeframes && typeof preferences.satelliteTimeframes === 'object'
        ? (preferences.satelliteTimeframes as Record<string, unknown>)
        : {};
  const fallbackFrom = normalizeDateString(preferences.date_from ?? preferences.from_date ?? preferences.fromDate);
  const fallbackTo = normalizeDateString(preferences.date_to ?? preferences.to_date ?? preferences.toDate);
  const fallbackDateYear = fallbackFrom?.slice(0, 4);
  const fallbackYear = normalizeYear(
    preferences.target_year ?? preferences.year ?? preferences.mapYear ?? fallbackDateYear,
  );
  const fallbackSeason = normalizeSeason(preferences.season) ?? 'growing';
  const fallbackRange = defaultSeasonRange(fallbackSeason, fallbackYear);
  const normalized: Record<
    string,
    { map_year: number; seasons: Array<{ season: string; from_date: string; to_date: string }> }
  > = {};

  for (const source of satelliteSources) {
    const rawForSource =
      rawTimeframes[source] ??
      rawTimeframes[source === 'sentinel2' ? 'sentinel-2' : source] ??
      rawTimeframes[source === 'sentinel2' ? 'sentinel_2' : source];
    const sourceRecord =
      rawForSource && typeof rawForSource === 'object' && !Array.isArray(rawForSource)
        ? (rawForSource as Record<string, unknown>)
        : {};
    const mapYear = normalizeYear(
      sourceRecord.map_year ??
        sourceRecord.mapYear ??
        preferences.target_year ??
        preferences.year ??
        fallbackDateYear,
    );
    const rawSeasons = Array.isArray(sourceRecord.seasons)
      ? sourceRecord.seasons
      : sourceRecord.season !== undefined
        ? [sourceRecord]
        : [
            {
              season: fallbackSeason,
              from_date: fallbackFrom ?? fallbackRange.from_date,
              to_date: fallbackTo ?? fallbackRange.to_date,
            },
          ];
    const seasons: Array<{ season: string; from_date: string; to_date: string }> = [];
    for (const rawSeason of rawSeasons) {
      const seasonRecord: Record<string, unknown> =
        rawSeason && typeof rawSeason === 'object' && !Array.isArray(rawSeason)
          ? (rawSeason as Record<string, unknown>)
          : { season: rawSeason };
      const season = normalizeSeason(seasonRecord.season) ?? fallbackSeason;
      if (seasons.some((item) => item.season === season)) {
        continue;
      }
      const range = defaultSeasonRange(season, mapYear);
      const fromDate =
        normalizeDateString(
          seasonRecord.from_date ?? seasonRecord.fromDate ?? seasonRecord.date_from,
        ) ??
        (season === fallbackSeason ? fallbackFrom : null) ??
        range.from_date;
      const toDate =
        normalizeDateString(seasonRecord.to_date ?? seasonRecord.toDate ?? seasonRecord.date_to) ??
        (season === fallbackSeason ? fallbackTo : null) ??
        range.to_date;
      seasons.push({
        season,
        from_date: fromDate,
        to_date: toDate,
      });
    }
    normalized[source] = {
      map_year: mapYear,
      seasons: seasons.length > 0
        ? seasons
        : [{ season: fallbackSeason, from_date: fallbackRange.from_date, to_date: fallbackRange.to_date }],
    };
  }

  return normalized;
};

const normalizeConfidenceThreshold = (value: unknown, fallback = defaultSettings.confidence_threshold): number => {
  const parsed =
    typeof value === 'number'
      ? value
      : typeof value === 'string' && value.trim().length > 0
        ? Number.parseFloat(value)
        : Number.NaN;
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
    return fallback;
  }
  return parsed;
};

const normalizeFeatureGroups = (value: unknown, fallbackInputs: string[] = []): string[] => {
  const groups = Array.isArray(value)
    ? value
        .map((item) => (typeof item === 'string' ? item.trim().toLowerCase() : ''))
        .filter((item) => supportedFeatureGroups.has(item))
    : [];
  if (groups.length > 0) {
    return Array.from(new Set(groups));
  }
  const inferred = new Set<string>();
  for (const input of fallbackInputs) {
    if ([...sentinel2SpectralFeatures, ...landsatSpectralFeatures].includes(input)) {
      inferred.add('spectral_bands');
    }
    if ([...sentinel2IndexFeatures, ...landsatIndexFeatures].includes(input)) {
      inferred.add('vegetation_indices');
    }
    if (topographyFeatures.includes(input)) {
      inferred.add('topography');
    }
    if (textureFeatures.includes(input)) {
      inferred.add('texture');
    }
  }
  return inferred.size > 0 ? Array.from(inferred) : defaultFeatureGroups;
};

const inferFeatureGroupsFromInputs = (inputs: string[]): string[] => {
  const groups = new Set<string>();
  for (const input of inputs) {
    if ([...sentinel2SpectralFeatures, ...landsatSpectralFeatures].includes(input)) {
      groups.add('spectral_bands');
    }
    if ([...sentinel2IndexFeatures, ...landsatIndexFeatures].includes(input)) {
      groups.add('vegetation_indices');
    }
    if (topographyFeatures.includes(input)) {
      groups.add('topography');
    }
    if (textureFeatures.includes(input)) {
      groups.add('texture');
    }
  }
  return Array.from(groups);
};

const expandFeatureGroups = (
  groups: string[],
  satelliteSources: Array<'sentinel2' | 'landsat'>,
): string[] => {
  const features = new Set<string>();
  if (groups.includes('spectral_bands')) {
    if (satelliteSources.includes('sentinel2')) {
      sentinel2SpectralFeatures.forEach((feature) => features.add(feature));
    }
    if (satelliteSources.includes('landsat')) {
      landsatSpectralFeatures.forEach((feature) => features.add(feature));
    }
  }
  if (groups.includes('vegetation_indices')) {
    if (satelliteSources.includes('sentinel2')) {
      sentinel2IndexFeatures.forEach((feature) => features.add(feature));
    }
    if (satelliteSources.includes('landsat')) {
      landsatIndexFeatures.forEach((feature) => features.add(feature));
    }
  }
  if (groups.includes('topography')) {
    topographyFeatures.forEach((feature) => features.add(feature));
  }
  if (groups.includes('texture')) {
    textureFeatures.forEach((feature) => features.add(feature));
  }
  return Array.from(features);
};

const defaultFeatureInputsForSources = (satelliteSources: Array<'sentinel2' | 'landsat'>): string[] => {
  const features = new Set<string>();
  if (satelliteSources.includes('sentinel2')) {
    defaultSentinel2FeatureInputs.forEach((feature) => features.add(feature));
  }
  if (satelliteSources.includes('landsat')) {
    defaultLandsatFeatureInputs.forEach((feature) => features.add(feature));
  }
  return Array.from(features);
};

const hasSeason = (
  satelliteTimeframes: Record<string, { seasons: Array<{ season: string }> }>,
  source: 'sentinel2' | 'landsat',
  season: string,
): boolean => satelliteTimeframes[source]?.seasons?.some((item) => item.season === season) === true;

const applyFeatureDependencyDefaults = ({
  featureInputs,
  featureGroups,
  satelliteSources,
  satelliteTimeframes,
  strict,
  featureInputsExplicit,
}: {
  featureInputs: string[];
  featureGroups: string[];
  satelliteSources: Array<'sentinel2' | 'landsat'>;
  satelliteTimeframes: Record<string, { seasons: Array<{ season: string }> }>;
  strict: boolean;
  featureInputsExplicit: boolean;
}): string[] => {
  const features = new Set(featureInputs);
  const errors: string[] = [];
  const hasTexture =
    features.has('static_texture_pc1') ||
    (!featureInputsExplicit && featureGroups.includes('texture'));
  const hasSentinel2 = satelliteSources.includes('sentinel2');
  const hasLandsat = satelliteSources.includes('landsat');

  if (hasTexture) {
    if (!hasSentinel2) {
      errors.push(textureDependencyMessage);
    }
    if (!features.has('NDVI')) {
      errors.push(textureDependencyMessage);
    }
    if (!hasSeason(satelliteTimeframes, 'sentinel2', 'dry')) {
      errors.push(textureDependencyMessage);
    }
  }

  const sentinel2OnlyFeatures = new Set(['B2', 'B3', 'B4', 'B5', 'B6', 'B7', 'B8', 'B8A', 'B11', 'B12']);
  if (!hasSentinel2 && [...features].some((feature) => sentinel2OnlyFeatures.has(feature))) {
    errors.push('Sentinel-2 bands and red-edge indices require Sentinel-2.');
  }
  if (features.has('NDRE') && !hasSentinel2) {
    errors.push('NDRE requires Sentinel-2 because it uses Sentinel-2 red-edge bands.');
  }
  if (!hasLandsat && [...features].some((feature) => landsatSpectralFeatures.includes(feature))) {
    errors.push('Landsat bands require Landsat.');
  }

  if (strict && errors.length > 0) {
    throw new AppError(Array.from(new Set(errors)).join(' '), 400);
  }
  return Array.from(features);
};

const supportedAiModelAliases: Record<string, string> = {
  auto: 'auto',
  random_forest: 'random_forest',
  rf: 'random_forest',
  svm: 'svm',
  svm_rbf: 'svm',
  gradient_boosting: 'gradient_boosting',
  gb: 'gradient_boosting',
  gradient_boost: 'gradient_boosting',
  gradient_tree_boost: 'gradient_boosting',
};

const normalizePreferredAiModel = (
  value: unknown,
  options: { strict?: boolean } = {},
): string => {
  const raw = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (!raw) {
    return 'auto';
  }
  if (['mlp', 'neural', 'neural_network', 'neuralnet'].includes(raw)) {
    if (options.strict) {
      throw new AppError(
        'MLP/neural network is not supported for new AI runs. Choose Auto, Random Forest, SVM, or Gradient Boosting.',
        400,
      );
    }
    return 'auto';
  }
  if (['xgb', 'xgboost'].includes(raw)) {
    if (options.strict) {
      throw new AppError(
        'XGBoost is not supported end-to-end in the current GEE workflow. Choose Auto, Random Forest, SVM, or Gradient Boosting.',
        400,
      );
    }
    return 'auto';
  }
  const normalized = supportedAiModelAliases[raw];
  if (!normalized) {
    if (options.strict) {
      throw new AppError(
        'Unsupported AI model. Choose Auto, Random Forest, SVM, or Gradient Boosting.',
        400,
      );
    }
    return 'auto';
  }
  return normalized;
};

const normalizeFeatureInputs = (value: string[]): string[] => {
  const seen = new Set<string>();
  const inputs: string[] = [];
  for (const item of value) {
    const feature = item.trim();
    if (!feature || seen.has(feature)) {
      continue;
    }
    seen.add(feature);
    inputs.push(feature);
  }
  return inputs;
};

const boolPreference = (preferences: Record<string, unknown> | null | undefined, key: string): boolean =>
  preferences?.[key] === true;

const normalizeAiModelPreferences = (
  preferences: unknown,
  options: { strictModel?: boolean } = {},
): Record<string, unknown> => {
  const raw =
    preferences && typeof preferences === 'object' && !Array.isArray(preferences)
      ? { ...(preferences as Record<string, unknown>) }
      : {};
  const satelliteSources = normalizeSatelliteSources(raw);
  const satelliteTimeframes = normalizeSatelliteTimeframes(raw, satelliteSources);
  const legacyFeatureInputs = Array.isArray(raw.feature_inputs)
    ? raw.feature_inputs.filter((item): item is string => typeof item === 'string')
    : Array.isArray(raw.selected_feature_inputs)
      ? raw.selected_feature_inputs.filter((item): item is string => typeof item === 'string')
      : Array.isArray(raw.selected_extracted_features)
        ? raw.selected_extracted_features.filter((item): item is string => typeof item === 'string')
        : [];
  const rawFeatureInputs = normalizeFeatureInputs(legacyFeatureInputs);
  const initialFeatureGroups = normalizeFeatureGroups(raw.feature_groups, rawFeatureInputs);
  const hasExplicitFeatureGroups = Array.isArray(raw.feature_groups) && initialFeatureGroups.length > 0;
  const baseFeatureInputs =
    rawFeatureInputs.length > 0
      ? rawFeatureInputs
      : hasExplicitFeatureGroups
        ? expandFeatureGroups(initialFeatureGroups, satelliteSources)
        : defaultFeatureInputsForSources(satelliteSources);
  const featureInputs = applyFeatureDependencyDefaults({
    featureInputs: baseFeatureInputs,
    featureGroups: hasExplicitFeatureGroups
      ? initialFeatureGroups
      : inferFeatureGroupsFromInputs(baseFeatureInputs),
    satelliteSources,
    satelliteTimeframes,
    strict: options.strictModel === true,
    featureInputsExplicit: rawFeatureInputs.length > 0,
  });
  const featureGroups = hasExplicitFeatureGroups
    ? initialFeatureGroups
    : inferFeatureGroupsFromInputs(featureInputs);
  const primarySource = satelliteSources[0] ?? 'sentinel2';
  const primaryFrame = satelliteTimeframes[primarySource];
  const primarySeason = primaryFrame?.seasons[0];

  return {
    ...raw,
    preferred_model: normalizePreferredAiModel(raw.preferred_model, {
      strict: options.strictModel,
    }),
    satellite_sources: satelliteSources,
    satellite_timeframes: satelliteTimeframes,
    feature_groups: featureGroups,
    feature_inputs: featureInputs,
    selected_feature_inputs: featureInputs,
    selected_extracted_features: featureInputs,
    satellite_source: primarySource,
    target_year: primaryFrame?.map_year ?? normalizeYear(raw.target_year ?? raw.year),
    season: primarySeason?.season ?? normalizeSeason(raw.season) ?? 'growing',
    date_from: primarySeason?.from_date ?? normalizeDateString(raw.date_from ?? raw.from_date),
    date_to: primarySeason?.to_date ?? normalizeDateString(raw.date_to ?? raw.to_date),
  };
};

const nationalRequirement = ({
  key,
  label,
  passed,
  currentValue,
  requiredValue,
  message,
}: {
  key: string;
  label: string;
  passed: boolean;
  currentValue: string | number | boolean | null;
  requiredValue: string | number | boolean;
  message: string;
}): NationalScopeRequirement => ({
  key,
  label,
  passed,
  current_value: currentValue,
  required_value: requiredValue,
  message,
});

const aiAreaTypeFromScope = (
  scopeType: string,
): 'project_area' | 'custom_ai_area' | 'national_lebanon' => {
  if (scopeType === 'custom_polygon') {
    return 'custom_ai_area';
  }
  if (scopeType === 'national') {
    return 'national_lebanon';
  }
  return 'project_area';
};

const percentOf = (value: number, total: number): number =>
  total <= 0 ? 0 : Math.round((value / total) * 100);

const coverageRatingFor = (percent: number): 'good' | 'limited' | 'weak' => {
  if (percent >= 70) {
    return 'good';
  }
  if (percent >= 40) {
    return 'limited';
  }
  return 'weak';
};

const coverageRatingLabel = (rating: 'good' | 'limited' | 'weak'): string => {
  switch (rating) {
    case 'good':
      return 'Good coverage';
    case 'limited':
      return 'Limited coverage';
    case 'weak':
    default:
      return 'Weak coverage';
  }
};

const normalizeGovernorateName = (value: string | null): string | null => {
  const text = value?.trim().toLowerCase();
  if (!text) {
    return null;
  }
  if (text.includes('akkar')) return 'akkar';
  if (text.includes('north') || text.includes('tripoli')) return 'north';
  if (text.includes('beirut')) return 'beirut';
  if (text.includes('mount') || text.includes('jabal')) return 'mount_lebanon';
  if (text.includes('baalbek') || text.includes('hermel')) return 'baalbek_hermel';
  if (text.includes('bekaa') || text.includes('beqaa')) return 'bekaa';
  if (text.includes('nabatieh') || text.includes('nabatiye')) return 'nabatieh';
  if (text.includes('south') || text.includes('saida') || text.includes('sidon')) return 'south';
  return null;
};

const pointInBounds = (
  sample: NationalCoverageSample,
  bounds: { min_lon: number; min_lat: number; max_lon: number; max_lat: number },
): boolean =>
  typeof sample.lon === 'number' &&
  typeof sample.lat === 'number' &&
  sample.lon >= bounds.min_lon &&
  sample.lon <= bounds.max_lon &&
  sample.lat >= bounds.min_lat &&
  sample.lat <= bounds.max_lat;

const governorateKeyForSample = (sample: NationalCoverageSample): string | null => {
  const fromAttributes = normalizeGovernorateName(sample.governorate);
  if (fromAttributes) {
    return fromAttributes;
  }
  const zone = lebanonStaticGovernorateZones.find((candidate) => pointInBounds(sample, candidate));
  return zone?.key ?? null;
};

const gridCellKeyForSample = (sample: NationalCoverageSample): string | null => {
  if (!pointInBounds(sample, lebanonApproxBounds) || sample.lon === null || sample.lat === null) {
    return null;
  }
  const width = lebanonApproxBounds.max_lon - lebanonApproxBounds.min_lon;
  const height = lebanonApproxBounds.max_lat - lebanonApproxBounds.min_lat;
  const column = Math.min(
    NATIONAL_GRID_COLUMNS - 1,
    Math.max(0, Math.floor(((sample.lon - lebanonApproxBounds.min_lon) / width) * NATIONAL_GRID_COLUMNS)),
  );
  const row = Math.min(
    NATIONAL_GRID_ROWS - 1,
    Math.max(0, Math.floor(((sample.lat - lebanonApproxBounds.min_lat) / height) * NATIONAL_GRID_ROWS)),
  );
  return `${row}:${column}`;
};

const computeNationalCoverage = ({
  samples,
  labelCounts,
  minSamplesPerClass,
}: {
  samples: NationalCoverageSample[];
  labelCounts: Array<{ class_label: string; sample_count: number }>;
  minSamplesPerClass: number;
}) => {
  const governorates = new Set<string>();
  const gridCells = new Set<string>();
  const elevationBands = new Set<string>();
  for (const sample of samples) {
    const governorate = governorateKeyForSample(sample);
    if (governorate) {
      governorates.add(governorate);
    }
    const gridCell = gridCellKeyForSample(sample);
    if (gridCell) {
      gridCells.add(gridCell);
    }
    const elevationBand = sample.elevation_band?.trim().toLowerCase();
    if (elevationBand) {
      elevationBands.add(elevationBand);
    }
  }
  const totalGovernorates = lebanonStaticGovernorateZones.length;
  const totalGridCells = NATIONAL_GRID_COLUMNS * NATIONAL_GRID_ROWS;
  const usableClassCount = labelCounts.filter(
    (row) => Number(row.sample_count) >= minSamplesPerClass,
  ).length;
  const weakClassCount = Math.max(0, labelCounts.length - usableClassCount);
  const governoratePercent = percentOf(governorates.size, totalGovernorates);
  const gridPercent = percentOf(gridCells.size, totalGridCells);
  const classPercent = percentOf(usableClassCount, labelCounts.length);
  const score = Math.round(governoratePercent * 0.4 + gridPercent * 0.4 + classPercent * 0.2);
  const rating = coverageRatingFor(score);

  return {
    governorates_covered: governorates.size,
    total_governorates: totalGovernorates,
    governorate_percent: governoratePercent,
    governorate_rating: coverageRatingFor(governoratePercent),
    grid_cells_covered: gridCells.size,
    total_grid_cells: totalGridCells,
    grid_percent: gridPercent,
    grid_rating: coverageRatingFor(gridPercent),
    usable_class_count: usableClassCount,
    weak_class_count: weakClassCount,
    total_class_count: labelCounts.length,
    class_percent: classPercent,
    class_rating: coverageRatingFor(classPercent),
    elevation_measured: elevationBands.size > 0,
    elevation_bands: Array.from(elevationBands).sort(),
    score,
    rating,
    rating_label: coverageRatingLabel(rating),
    boundary_source: 'static_lebanon_boundary',
  };
};

const nationalScopeEligibilityFor = ({
  requestedNational,
  labelCounts = [],
  samples = [],
  minSamplesPerClass,
  modelPreferences = {},
  totals,
  warnings = [],
}: {
  requestedNational: boolean;
  labelCounts?: Array<{ class_label: string; sample_count: number }>;
  samples?: NationalCoverageSample[];
  minSamplesPerClass: number;
  modelPreferences?: Record<string, unknown>;
  totals?: {
    missing_label_count?: number;
    invalid_geometry_count?: number;
  };
  warnings?: string[];
}) => {
  const missingLabelCount = Number(totals?.missing_label_count ?? 0);
  const invalidGeometryCount = Number(totals?.invalid_geometry_count ?? 0);
  const coverage = computeNationalCoverage({ samples, labelCounts, minSamplesPerClass });
  const nationalModeAllowed = boolPreference(modelPreferences, 'national_mode_allowed');
  const lebanonBoundaryConfigured = boolPreference(
    modelPreferences,
    'lebanon_boundary_configured',
  );
  const pipelineSupportsNational =
    boolPreference(modelPreferences, 'pipeline_supports_national_scope') &&
    boolPreference(modelPreferences, 'backend_bridge_supports_national_scope') &&
    boolPreference(modelPreferences, 'python_pipeline_supports_national_scope');
  const minimumSamplesPerClassMet =
    labelCounts.length >= 2 &&
    labelCounts.every((row) => Number(row.sample_count) >= minSamplesPerClass);
  const labelsValid =
    labelCounts.length > 0 && missingLabelCount === 0 && invalidGeometryCount === 0;
  const regionalCoverageConfigured = boolPreference(
    modelPreferences,
    'national_regional_coverage_configured',
  );
  const nationalSampleSpreadConfirmed = boolPreference(
    modelPreferences,
    'national_sample_spread_confirmed',
  );
  const regionalCoverageReady = regionalCoverageConfigured && nationalSampleSpreadConfirmed;
  const validationPlanRecorded = boolPreference(
    modelPreferences,
    'national_validation_plan_recorded',
  );
  const qualityWarnings =
    requestedNational && coverage.score < 70
      ? [
          ...warnings,
          'Samples are not well distributed across Lebanon. Results may be less reliable.',
        ]
      : warnings;
  const requirements = [
    nationalRequirement({
      key: 'national_mode_allowed',
      label: 'National mode allowed for this project',
      passed: nationalModeAllowed,
      currentValue: nationalModeAllowed,
      requiredValue: true,
      message: nationalModeAllowed
        ? 'A protected super-admin has allowed national AI mode for this project.'
        : 'A protected super-admin must allow national AI mode for this project.',
    }),
    nationalRequirement({
      key: 'lebanon_boundary_configured',
      label: 'Lebanon boundary configured',
      passed: lebanonBoundaryConfigured,
      currentValue: lebanonBoundaryConfigured,
      requiredValue: true,
      message: lebanonBoundaryConfigured
        ? 'A Lebanon boundary/ROI is configured for AI processing.'
        : 'Lebanon boundary/ROI must be configured before national mode can be enabled.',
    }),
    nationalRequirement({
      key: 'pipeline_supports_national_processing',
      label: 'Pipeline supports national processing',
      passed: pipelineSupportsNational,
      currentValue: pipelineSupportsNational,
      requiredValue: true,
      message: pipelineSupportsNational
        ? 'The backend bridge and Python pipeline support national ROI/config processing.'
        : 'National mode stays locked until the backend bridge and Python pipeline support national ROI/config processing.',
    }),
    nationalRequirement({
      key: 'minimum_samples_per_class',
      label: 'Enough approved samples per class',
      passed: minimumSamplesPerClassMet,
      currentValue: coverage.usable_class_count,
      requiredValue: `2+ classes with at least ${minSamplesPerClass} samples`,
      message: minimumSamplesPerClassMet
        ? 'Every target class has enough approved labeled samples.'
        : `At least two classes need ${minSamplesPerClass} approved labeled samples.`,
    }),
    nationalRequirement({
      key: 'labels_valid',
      label: 'Labels are valid',
      passed: labelsValid,
      currentValue: `missing labels: ${missingLabelCount}; invalid geometries: ${invalidGeometryCount}`,
      requiredValue: '0 missing labels and 0 invalid geometries',
      message: labelsValid
        ? 'Approved training samples have valid selected labels and usable geometries.'
        : 'Samples used for training must have valid selected labels and usable geometries.',
    }),
    nationalRequirement({
      key: 'regional_coverage_configured',
      label: 'Geographic coverage is broad enough',
      passed: regionalCoverageReady,
      currentValue: regionalCoverageConfigured
        ? nationalSampleSpreadConfirmed
        : 'coverage check not configured',
      requiredValue: 'configured regional/governorate or environmental-zone coverage check',
      message: !regionalCoverageConfigured
        ? 'Regional coverage check is not configured yet.'
        : nationalSampleSpreadConfirmed
          ? 'Approved samples cover multiple Lebanese regions or configured environmental zones.'
          : 'Approved samples must cover multiple Lebanese regions or configured environmental zones.',
    }),
    nationalRequirement({
      key: 'validation_plan_recorded',
      label: 'Validation plan exists',
      passed: validationPlanRecorded,
      currentValue: validationPlanRecorded,
      requiredValue: true,
      message: validationPlanRecorded
        ? 'A validation plan has been recorded before national publishing.'
        : 'A super-admin must record/confirm a validation plan before national results can be published.',
    }),
  ];
  const eligible = requirements.every((requirement) => requirement.passed);
  const unmetRequirements = eligible
    ? []
    : requirements.filter((requirement) => !requirement.passed).map((requirement) => requirement.message);
  return {
    eligible,
    requirements,
    unmet_requirements: unmetRequirements,
    warnings:
      requestedNational && !eligible
        ? [
            ...qualityWarnings,
            'National Lebanon prediction is locked until national readiness requirements are met.',
          ]
        : qualityWarnings,
    coverage,
    missing_label_count: missingLabelCount,
    invalid_geometry_count: invalidGeometryCount,
  };
};

const normalizeOptionalString = (value: unknown): string | null => {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const parsePositiveInteger = (value: unknown, fallback: number, max = 10000): number => {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return Math.min(parsed, max);
};

const parsePagination = (req: Request): { page: number; limit: number; offset: number } => {
  const page = parsePositiveInteger(req.query.page, 1, 100000);
  const limit = parsePositiveInteger(req.query.limit, 20, 100);
  return {
    page,
    limit,
    offset: (page - 1) * limit,
  };
};

const parseOptionalBodyNumber = (value: unknown): number | null => {
  if (value === null || value === undefined || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

const serializeGeometry = (geometry: unknown): string | null => {
  if (geometry === undefined || geometry === null || geometry === '') {
    return null;
  }
  return JSON.stringify(geometry);
};

const getProjectOrFail = async (projectId: string) => {
  const result = await query(
    `SELECT id, name, collection_form_schema
     FROM project
     WHERE id = $1`,
    [projectId],
  );

  if (result.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  return result.rows[0];
};

const collectionSchemaFieldsFrom = (
  collectionFormSchema: unknown,
): Array<{ key: string; label: string | null; required: boolean; type: string | null }> => {
  if (
    !collectionFormSchema ||
    typeof collectionFormSchema !== 'object' ||
    !Array.isArray((collectionFormSchema as { fields?: unknown }).fields)
  ) {
    return [];
  }

  const seen = new Set<string>();
  return (collectionFormSchema as { fields: unknown[] }).fields
    .map((field) => {
      if (!field || typeof field !== 'object') {
        return null;
      }
      const key = normalizeOptionalString((field as { key?: unknown }).key);
      if (!key || seen.has(key)) {
        return null;
      }
      seen.add(key);
      return {
        key,
        label: normalizeOptionalString((field as { label?: unknown }).label),
        required: Boolean((field as { required?: unknown }).required),
        type: normalizeOptionalString((field as { type?: unknown }).type)?.toLowerCase() ?? null,
      };
    })
    .filter(
      (
        field,
      ): field is { key: string; label: string | null; required: boolean; type: string | null } =>
        field !== null,
    );
};

const isClassifierSchemaField = (type: string | null): boolean =>
  type === 'select' || type === 'classification' || type === 'class';

const looksLikeAttributeKey = (value: string | null): value is string =>
  Boolean(value && /^[A-Za-z_][A-Za-z0-9_]*$/.test(value));

const schemaClassifierKeyFor = (
  field: { key: string; label: string | null; required: boolean; type: string | null },
  approvedAttributeFields?: Set<string>,
): string => {
  const label = normalizeOptionalString(field.label);
  if (
    looksLikeAttributeKey(label) &&
    label !== field.key &&
    (!approvedAttributeFields || approvedAttributeFields.has(label))
  ) {
    return label;
  }
  return field.key;
};

const preferredSchemaLabelFieldFrom = (collectionFormSchema: unknown): string | null => {
  const schemaFields = collectionSchemaFieldsFrom(collectionFormSchema);
  const preferredRequiredClassifier = schemaFields.find(
    (field) => field.required && isClassifierSchemaField(field.type),
  );
  if (preferredRequiredClassifier) {
    return schemaClassifierKeyFor(preferredRequiredClassifier);
  }

  const preferredClassifier = schemaFields.find((field) => isClassifierSchemaField(field.type));
  if (preferredClassifier) {
    return schemaClassifierKeyFor(preferredClassifier);
  }

  const preferredRequired = schemaFields.find((field) => field.required);
  if (preferredRequired) {
    return schemaClassifierKeyFor(preferredRequired);
  }

  return schemaFields[0] ? schemaClassifierKeyFor(schemaFields[0]) : null;
};

const normalizedFieldName = (field: string): string => field.trim().toLowerCase();

const isSystemOrMeasurementField = (field: string): boolean => {
  const normalized = normalizedFieldName(field);
  return (
    /^objectid(_\d+)?$/.test(normalized) ||
    /(^|_)fid$/.test(normalized) ||
    /(^|_)gid$/.test(normalized) ||
    /^id$/.test(normalized) ||
    normalized === 'level_4' ||
    normalized.endsWith('_id') ||
    normalized.endsWith('_code') ||
    /^l\d+_code$/.test(normalized) ||
    /^l\d+_descr$/.test(normalized) ||
    normalized.startsWith('shape_') ||
    normalized === 'shape_area' ||
    normalized === 'shape_leng' ||
    normalized === 'shape_length' ||
    normalized.endsWith('_area') ||
    normalized.endsWith('_leng') ||
    normalized.endsWith('_length') ||
    normalized.includes('geometry') ||
    normalized === 'geom'
  );
};

const isClassLikeFieldName = (field: string): boolean => {
  const normalized = normalizedFieldName(field);
  return (
    normalized.includes('class') ||
    normalized.includes('category') ||
    normalized.includes('type') ||
    normalized.includes('label') ||
    normalized.includes('descr') ||
    normalized.includes('description') ||
    normalized.includes('cover') ||
    normalized.includes('land_use') ||
    normalized.includes('crop') ||
    normalized.includes('species') ||
    normalized.includes('tree') ||
    normalized.includes('irrigation')
  );
};

const isNumericText = (value: string): boolean => /^-?\d+(\.\d+)?$/.test(value.trim());

const getAiSettingsRow = async (projectId: string) => {
  const result = await query(
    `SELECT id,
            project_id,
            is_enabled,
            label_field,
            scope_type,
            ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
            min_samples_per_class,
            confidence_threshold,
            model_preferences,
            created_by,
            updated_by,
            created_at,
            updated_at
     FROM ai_project_settings
     WHERE project_id = $1`,
    [projectId],
  );

  return result.rows[0] ?? null;
};

const getEffectiveAiSettings = async (projectId: string) => {
  const existing = await getAiSettingsRow(projectId);
  return {
    id: existing?.id ?? null,
    project_id: projectId,
    is_enabled: existing?.is_enabled ?? defaultSettings.is_enabled,
    label_field: existing?.label_field ?? defaultSettings.label_field,
    scope_type: existing?.scope_type ?? defaultSettings.scope_type,
    scope_geometry: existing?.scope_geometry ?? defaultSettings.scope_geometry,
    min_samples_per_class: existing?.min_samples_per_class ?? defaultSettings.min_samples_per_class,
    confidence_threshold:
      existing?.confidence_threshold ?? defaultSettings.confidence_threshold,
    model_preferences: normalizeAiModelPreferences(
      existing?.model_preferences ?? defaultSettings.model_preferences,
    ),
    created_by: existing?.created_by ?? null,
    updated_by: existing?.updated_by ?? null,
    created_at: existing?.created_at ?? null,
    updated_at: existing?.updated_at ?? null,
    persisted: Boolean(existing),
  };
};

const hasSpatialFeatureSourceColumn = async (): Promise<boolean> => {
  const result = await query(
    `SELECT 1
     FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'spatial_feature'
       AND column_name = 'source'
     LIMIT 1`,
  );
  return result.rows.length > 0;
};

const getCandidateLabelFieldSummary = async ({
  projectId,
  collectionFormSchema,
  selectedLabelField,
}: {
  projectId: string;
  collectionFormSchema: unknown;
  selectedLabelField: string | null;
}) => {
  const candidates = new Map<
    string,
    {
      field: string;
      sources: Set<string>;
      schemaRequired: boolean;
      schemaClassifier: boolean;
      schemaDisplayField: boolean;
      schemaTechnicalField: boolean;
      labeledFeatureCount: number;
      classCount: number;
      distribution: Map<string, number>;
      signature: string | null;
      aliasOf: string | null;
      aliases: string[];
      hiddenReason: string | null;
    }
  >();

  const ensureCandidate = (field: string) => {
    const normalized = field.trim();
    if (!normalized) {
      return null;
    }
    const existing = candidates.get(normalized);
    if (existing) {
      return existing;
    }
    const candidate = {
      field: normalized,
      sources: new Set<string>(),
      schemaRequired: false,
      schemaClassifier: false,
      schemaDisplayField: false,
      schemaTechnicalField: false,
      labeledFeatureCount: 0,
      classCount: 0,
      distribution: new Map<string, number>(),
      signature: null,
      aliasOf: null,
      aliases: [],
      hiddenReason: null,
    };
    candidates.set(normalized, candidate);
    return candidate;
  };

  for (const schemaField of collectionSchemaFieldsFrom(collectionFormSchema)) {
    const candidate = ensureCandidate(schemaField.key);
    if (!candidate) {
      continue;
    }
    candidate.sources.add('schema');
    candidate.schemaTechnicalField = true;
    candidate.schemaRequired = candidate.schemaRequired || schemaField.required;
    candidate.schemaClassifier =
      candidate.schemaClassifier || isClassifierSchemaField(schemaField.type);

    const schemaLabelKey = normalizeOptionalString(schemaField.label);
    if (looksLikeAttributeKey(schemaLabelKey) && schemaLabelKey !== schemaField.key) {
      const displayCandidate = ensureCandidate(schemaLabelKey);
      if (displayCandidate) {
        displayCandidate.sources.add('schema_label');
        displayCandidate.schemaDisplayField = true;
        displayCandidate.schemaRequired = displayCandidate.schemaRequired || schemaField.required;
        displayCandidate.schemaClassifier =
          displayCandidate.schemaClassifier || isClassifierSchemaField(schemaField.type);
      }
    }
  }

  const attributeLabelDistributionResult = await query(
    `SELECT kv.key AS field,
            LOWER(BTRIM(kv.value)) AS normalized_label,
            COUNT(*)::int AS sample_count
     FROM spatial_feature sf
     CROSS JOIN LATERAL jsonb_each_text(
       COALESCE(sf.attributes, '{}'::jsonb)
     ) AS kv(key, value)
     WHERE sf.project_id = $1
       AND sf.status = 'approved'
       AND NULLIF(BTRIM(kv.value), '') IS NOT NULL
     GROUP BY kv.key, LOWER(BTRIM(kv.value))
     ORDER BY kv.key ASC, normalized_label ASC`,
    [projectId],
  );

  for (const row of attributeLabelDistributionResult.rows) {
    const candidate = ensureCandidate(String(row.field ?? ''));
    if (!candidate) {
      continue;
    }
    candidate.sources.add('approved_attributes');
    const normalizedLabel = normalizeOptionalString(row.normalized_label);
    if (!normalizedLabel) {
      continue;
    }
    const currentCount = candidate.distribution.get(normalizedLabel) ?? 0;
    candidate.distribution.set(normalizedLabel, currentCount + Number(row.sample_count ?? 0));
  }

  const requestedLabelField = normalizeOptionalString(selectedLabelField);
  if (requestedLabelField) {
    ensureCandidate(requestedLabelField)?.sources.add('selected');
  }

  const rows = Array.from(candidates.values());
  for (const row of rows) {
    row.labeledFeatureCount = Array.from(row.distribution.values()).reduce(
      (total, count) => total + count,
      0,
    );
    row.classCount = row.distribution.size;
    row.signature =
      row.classCount > 0
        ? Array.from(row.distribution.entries())
            .sort(([leftLabel], [rightLabel]) => leftLabel.localeCompare(rightLabel))
            .map(([label, count]) => `${label}:${count}`)
            .join('|')
        : null;
  }

  const compareForPrimary = (left: (typeof rows)[number], right: (typeof rows)[number]) => {
    const leftDisplayRequiredClassifier =
      left.schemaDisplayField && left.schemaRequired && left.schemaClassifier;
    const rightDisplayRequiredClassifier =
      right.schemaDisplayField && right.schemaRequired && right.schemaClassifier;
    if (leftDisplayRequiredClassifier !== rightDisplayRequiredClassifier) {
      return leftDisplayRequiredClassifier ? -1 : 1;
    }
    const leftRequiredClassifier = left.schemaRequired && left.schemaClassifier;
    const rightRequiredClassifier = right.schemaRequired && right.schemaClassifier;
    if (leftRequiredClassifier !== rightRequiredClassifier) {
      return leftRequiredClassifier ? -1 : 1;
    }
    const leftDisplayClassifier = left.schemaDisplayField && left.schemaClassifier;
    const rightDisplayClassifier = right.schemaDisplayField && right.schemaClassifier;
    if (leftDisplayClassifier !== rightDisplayClassifier) {
      return leftDisplayClassifier ? -1 : 1;
    }
    if (left.schemaClassifier !== right.schemaClassifier) {
      return left.schemaClassifier ? -1 : 1;
    }
    const leftSelected = requestedLabelField !== null && left.field === requestedLabelField;
    const rightSelected = requestedLabelField !== null && right.field === requestedLabelField;
    if (leftSelected !== rightSelected) {
      return leftSelected ? -1 : 1;
    }
    if (left.schemaRequired !== right.schemaRequired) {
      return left.schemaRequired ? -1 : 1;
    }
    const leftSchema = left.sources.has('schema');
    const rightSchema = right.sources.has('schema');
    if (leftSchema !== rightSchema) {
      return leftSchema ? -1 : 1;
    }
    if (left.labeledFeatureCount !== right.labeledFeatureCount) {
      return right.labeledFeatureCount - left.labeledFeatureCount;
    }
    return left.field.localeCompare(right.field);
  };

  const usableRows = rows
    .filter((row) => row.labeledFeatureCount > 0 && row.classCount > 0 && row.signature)
    .sort(compareForPrimary);

  const primaryBySignature = new Map<string, string>();
  for (const row of usableRows) {
    if (!row.signature) {
      continue;
    }
    const primaryField = primaryBySignature.get(row.signature);
    if (!primaryField) {
      primaryBySignature.set(row.signature, row.field);
      continue;
    }
    row.aliasOf = primaryField;
    const primary = candidates.get(primaryField);
    if (primary && !primary.aliases.includes(row.field)) {
      primary.aliases.push(row.field);
    }
  }

  const hiddenReasonFor = (row: (typeof rows)[number]): string | null => {
    const hasLabels = row.labeledFeatureCount > 0 && row.classCount > 0;
    if (!hasLabels) {
      return 'No labels found in approved features.';
    }
    if (row.aliasOf) {
      return `Equivalent field mapped automatically to ${row.aliasOf}.`;
    }

    const schemaBacked =
      row.schemaClassifier || row.schemaDisplayField || row.sources.has('schema');
    const labels = Array.from(row.distribution.keys());
    const numericOnly = labels.length > 0 && labels.every(isNumericText);
    const uniqueRatio = row.labeledFeatureCount > 0 ? row.classCount / row.labeledFeatureCount : 1;

    if (!schemaBacked && isSystemOrMeasurementField(row.field)) {
      return 'Hidden because this looks like a source ID, code, geometry, or measurement field.';
    }
    if (!schemaBacked && numericOnly) {
      return 'Hidden because labels are numeric-only and look like IDs or measurements.';
    }
    if (!schemaBacked && row.classCount > 20 && uniqueRatio > 0.5) {
      return 'Hidden because values are mostly unique and look like IDs.';
    }
    if (row.classCount < 2) {
      return 'Hidden because only one class value was found.';
    }
    if (!schemaBacked && !isClassLikeFieldName(row.field)) {
      return 'Hidden because this is not a class-like project field.';
    }

    return null;
  };

  for (const row of rows) {
    row.hiddenReason = hiddenReasonFor(row);
  }

  const recommendedField =
    usableRows.find((row) => row.aliasOf === null && row.hiddenReason === null)?.field ?? null;

  return rows
    .map((row) => {
      const hasLabels = row.labeledFeatureCount > 0 && row.classCount > 0;
      const classifierCandidate = hasLabels && row.hiddenReason === null;
      const selectable = hasLabels && row.aliasOf === null && classifierCandidate;
      const isRecommended = selectable && row.field === recommendedField;
      const diagnosticOnly = !selectable;
      const note =
        row.hiddenReason ??
        (isRecommended ? 'Recommended project label field.' : 'Approved labels available.');
      return {
        field: row.field,
        source: Array.from(row.sources).sort(),
        labeled_feature_count: row.labeledFeatureCount,
        class_count: row.classCount,
        usable: hasLabels,
        classifier_candidate: classifierCandidate,
        selectable,
        diagnostic_only: diagnosticOnly,
        alias_of: row.aliasOf,
        aliases: row.aliases.sort(),
        hidden_reason: row.hiddenReason,
        recommended: isRecommended,
        note,
      };
    })
    .sort((left, right) => {
      if (left.recommended !== right.recommended) {
        return left.recommended ? -1 : 1;
      }
      if (left.selectable !== right.selectable) {
        return left.selectable ? -1 : 1;
      }
      if (left.usable !== right.usable) {
        return left.usable ? -1 : 1;
      }
      return left.field.localeCompare(right.field);
    });
};

const getFeatureReadinessSummary = async ({
  projectId,
  labelField,
  minSamplesPerClass,
  scopeType,
  scopeGeometry,
  modelPreferences = {},
}: {
  projectId: string;
  labelField: string | null;
  minSamplesPerClass: number;
  scopeType: string;
  scopeGeometry?: unknown;
  modelPreferences?: Record<string, unknown>;
}) => {
  const warnings: string[] = [];
  const blockers: string[] = [];
  const hasSourceColumn = await hasSpatialFeatureSourceColumn();
  const scopeGeometryText =
    scopeType === 'custom_polygon' ? serializeGeometry(scopeGeometry) : null;

  const totalsResult = await query(
    `WITH approved AS (
       SELECT geom,
              attributes,
              CASE
                WHEN $2::text IS NULL THEN NULL
                ELSE NULLIF(BTRIM(attributes ->> $2::text), '')
              END AS class_label
       FROM spatial_feature
       WHERE project_id = $1
         AND status = 'approved'
         AND (
           COALESCE(source, 'field') <> 'ai'
           OR use_for_future_training = TRUE
           OR attributes->>'useForFutureTraining' = 'true'
         )
         AND (
           $3::text IS NULL
           OR ST_Intersects(geom, ST_SetSRID(ST_GeomFromGeoJSON($3::text), 4326))
         )
     )
     SELECT COUNT(*)::int AS approved_feature_count,
            COUNT(*) FILTER (
              WHERE $2::text IS NULL
                 OR class_label IS NULL
            )::int AS missing_label_count,
            COUNT(*) FILTER (
              WHERE geom IS NULL OR NOT ST_IsValid(geom)
            )::int AS invalid_geometry_count,
            COUNT(*) FILTER (
              WHERE $2::text IS NOT NULL
                AND class_label IS NOT NULL
                AND geom IS NOT NULL
                AND ST_IsValid(geom)
            )::int AS valid_labeled_feature_count
     FROM approved`,
    [projectId, labelField, scopeGeometryText],
  );
  const totals = totalsResult.rows[0] ?? {
    approved_feature_count: 0,
    missing_label_count: 0,
    invalid_geometry_count: 0,
    valid_labeled_feature_count: 0,
  };

  const labelCountsResult = labelField
    ? await query(
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
           AND (
             $3::text IS NULL
             OR ST_Intersects(geom, ST_SetSRID(ST_GeomFromGeoJSON($3::text), 4326))
           )
           AND geom IS NOT NULL
           AND ST_IsValid(geom)
           AND NULLIF(BTRIM(attributes ->> $2), '') IS NOT NULL
         GROUP BY class_label
         ORDER BY sample_count DESC, class_label ASC`,
        [projectId, labelField, scopeGeometryText],
      )
    : { rows: [] };

  const sourceCountsResult = hasSourceColumn
    ? await query(
        `SELECT COALESCE(source, 'unknown') AS source,
                COUNT(*)::int AS feature_count
         FROM spatial_feature
         WHERE project_id = $1
           AND status = 'approved'
           AND (
             COALESCE(source, 'field') <> 'ai'
             OR use_for_future_training = TRUE
             OR attributes->>'useForFutureTraining' = 'true'
           )
           AND (
             $2::text IS NULL
             OR ST_Intersects(geom, ST_SetSRID(ST_GeomFromGeoJSON($2::text), 4326))
           )
         GROUP BY COALESCE(source, 'unknown')
         ORDER BY feature_count DESC, source ASC`,
        [projectId, scopeGeometryText],
      )
    : { rows: [] };

  const extentResult = await query(
    `SELECT ST_XMin(ST_Extent(geom)::box3d) AS min_lon,
            ST_YMin(ST_Extent(geom)::box3d) AS min_lat,
            ST_XMax(ST_Extent(geom)::box3d) AS max_lon,
            ST_YMax(ST_Extent(geom)::box3d) AS max_lat
     FROM spatial_feature
     WHERE project_id = $1
       AND status = 'approved'
       AND (
         COALESCE(source, 'field') <> 'ai'
         OR use_for_future_training = TRUE
         OR attributes->>'useForFutureTraining' = 'true'
       )
       AND (
         $2::text IS NULL
         OR ST_Intersects(geom, ST_SetSRID(ST_GeomFromGeoJSON($2::text), 4326))
       )
       AND geom IS NOT NULL
       AND ST_IsValid(geom)`,
    [projectId, scopeGeometryText],
  );
  const extent = extentResult.rows[0] ?? null;
  const spatialExtent =
    extent && extent.min_lon !== null
      ? {
          min_lon: Number(extent.min_lon),
          min_lat: Number(extent.min_lat),
          max_lon: Number(extent.max_lon),
          max_lat: Number(extent.max_lat),
        }
      : null;

  const labelCounts = labelCountsResult.rows.map((row) => ({
    class_label: row.class_label,
    sample_count: Number(row.sample_count),
  }));

  const nationalSamplesResult = labelField
    ? await query(
        `SELECT ST_X(ST_PointOnSurface(geom))::float AS lon,
                ST_Y(ST_PointOnSurface(geom))::float AS lat,
                NULLIF(BTRIM(attributes ->> $2), '') AS class_label,
                COALESCE(
                  NULLIF(BTRIM(attributes ->> 'governorate'), ''),
                  NULLIF(BTRIM(attributes ->> 'Governorate'), ''),
                  NULLIF(BTRIM(attributes ->> 'mohafaza'), ''),
                  NULLIF(BTRIM(attributes ->> 'Mohafaza'), ''),
                  NULLIF(BTRIM(attributes ->> 'admin1'), ''),
                  NULLIF(BTRIM(attributes ->> 'admin_1'), ''),
                  NULLIF(BTRIM(attributes ->> 'region'), ''),
                  NULLIF(BTRIM(attributes ->> 'Region'), '')
                ) AS governorate,
                COALESCE(
                  NULLIF(BTRIM(attributes ->> 'elevation_band'), ''),
                  NULLIF(BTRIM(attributes ->> 'elevationBand'), ''),
                  NULLIF(BTRIM(attributes ->> 'topography_band'), ''),
                  NULLIF(BTRIM(attributes ->> 'topographyBand'), '')
                ) AS elevation_band
         FROM spatial_feature
         WHERE project_id = $1
           AND status = 'approved'
           AND (
             COALESCE(source, 'field') <> 'ai'
             OR use_for_future_training = TRUE
             OR attributes->>'useForFutureTraining' = 'true'
           )
           AND (
             $3::text IS NULL
             OR ST_Intersects(geom, ST_SetSRID(ST_GeomFromGeoJSON($3::text), 4326))
           )
           AND geom IS NOT NULL
           AND ST_IsValid(geom)
           AND NULLIF(BTRIM(attributes ->> $2), '') IS NOT NULL`,
        [projectId, labelField, scopeGeometryText],
      )
    : { rows: [] };
  const nationalSamples: NationalCoverageSample[] = nationalSamplesResult.rows.map((row) => ({
    lon: row.lon === null || row.lon === undefined ? null : Number(row.lon),
    lat: row.lat === null || row.lat === undefined ? null : Number(row.lat),
    class_label: normalizeOptionalString(row.class_label),
    governorate: normalizeOptionalString(row.governorate),
    elevation_band: normalizeOptionalString(row.elevation_band),
  }));

  if (!labelField) {
    blockers.push('No AI label field is configured or requested.');
  }
  if (Number(totals.approved_feature_count) === 0) {
    blockers.push('Project has no approved field/import features available for AI.');
  }
  if (scopeType !== 'custom_polygon' && scopeType !== 'national' && spatialExtent === null) {
    blockers.push(
      'Project area scope is not configured. AI runs need an AOI to clip imagery and generate predictions.',
    );
  }
  if (labelCounts.length < 2) {
    blockers.push('At least two labeled classes are required for supervised training.');
  }

  const classesBelowMinimum = labelCounts.filter((row) => row.sample_count < minSamplesPerClass);
  const classesAtMinimum = labelCounts.filter((row) => row.sample_count >= minSamplesPerClass);
  const eligibleClassCount = classesAtMinimum.length;
  const eligibleFeatureCount = classesAtMinimum.reduce((total, row) => total + row.sample_count, 0);
  const validLabeledFeatureCount = Number(totals.valid_labeled_feature_count);

  if (labelCounts.length >= 2 && eligibleClassCount < 2 && scopeType !== 'national') {
    blockers.push(`At least two classes must meet the minimum of ${minSamplesPerClass} samples.`);
  } else if (classesBelowMinimum.length > 0) {
    const excluded = classesBelowMinimum
      .map((row) => `${row.class_label} (${row.sample_count})`)
      .join(', ');
    warnings.push(
      scopeType === 'national'
        ? `Classes with too few samples will be skipped: ${excluded}.`
        : `Classes below ${minSamplesPerClass} samples will be excluded from the AI run: ${excluded}.`,
    );
  }

  if (Number(totals.missing_label_count) > 0) {
    warnings.push('Some approved features are missing the selected label field.');
  }
  if (Number(totals.invalid_geometry_count) > 0) {
    warnings.push('Some approved features have null or invalid geometry.');
  }

  if (labelCounts.length >= 2) {
    const balanceRows = classesAtMinimum.length >= 2 ? classesAtMinimum : labelCounts;
    const sampleCounts = balanceRows.map((row) => row.sample_count);
    const minClassCount = Math.min(...sampleCounts);
    const maxClassCount = Math.max(...sampleCounts);
    if (minClassCount > 0 && maxClassCount / minClassCount >= 3) {
      warnings.push('Class balance is uneven and may bias model training.');
    }
  }

  if (scopeType === 'national' && spatialExtent) {
    const width = spatialExtent.max_lon - spatialExtent.min_lon;
    const height = spatialExtent.max_lat - spatialExtent.min_lat;
    const lebanonWidth = lebanonApproxBounds.max_lon - lebanonApproxBounds.min_lon;
    const lebanonHeight = lebanonApproxBounds.max_lat - lebanonApproxBounds.min_lat;
    if (width < lebanonWidth * 0.6 || height < lebanonHeight * 0.6) {
      warnings.push('Approved samples appear spatially limited for a national AI run.');
    }
  }

  const nationalScopeEligibility = nationalScopeEligibilityFor({
    requestedNational: scopeType === 'national',
    labelCounts,
    samples: nationalSamples,
    minSamplesPerClass,
    modelPreferences,
    totals: {
      missing_label_count: Number(totals.missing_label_count),
      invalid_geometry_count: Number(totals.invalid_geometry_count),
    },
    warnings: [
      ...warnings,
      ...(scopeType === 'national' && spatialExtent === null
        ? ['No approved sample extent is available for national readiness evaluation.']
        : []),
    ],
  });
  const topLevelWarnings =
    scopeType === 'national'
      ? Array.from(new Set([...warnings, ...nationalScopeEligibility.warnings]))
      : warnings;
  const status =
    blockers.length > 0 ? 'not_ready' : topLevelWarnings.length > 0 ? 'warning' : 'ready';
  const nationalScopeEnabled =
    (scopeType === 'national' || scopeType === 'national_lebanon') &&
    nationalScopeEligibility.eligible &&
    boolPreference(modelPreferences, 'national_scope_enabled');

  return {
    status,
    label_field: labelField,
    min_samples_per_class: minSamplesPerClass,
    approved_feature_count: Number(totals.approved_feature_count),
    labeled_feature_count: validLabeledFeatureCount,
    eligible_feature_count: eligibleFeatureCount,
    missing_label_count: Number(totals.missing_label_count),
    invalid_geometry_count: Number(totals.invalid_geometry_count),
    excluded_feature_count: Number(totals.approved_feature_count) - eligibleFeatureCount,
    class_count: labelCounts.length,
    eligible_class_count: eligibleClassCount,
    label_counts: labelCounts,
    classes_below_minimum: classesBelowMinimum,
    source_column_available: hasSourceColumn,
    source_counts: sourceCountsResult.rows.map((row) => ({
      source: row.source,
      feature_count: Number(row.feature_count),
    })),
    spatial_extent: spatialExtent,
    scope_type: scopeType,
    training_samples_area_type: aiAreaTypeFromScope(scopeType),
    prediction_area_type: aiAreaTypeFromScope(scopeType),
    national_scope_enabled: nationalScopeEnabled,
    national_scope_eligibility: nationalScopeEligibility,
    custom_scope_applied: scopeGeometryText !== null,
    coverage_warning_applies: topLevelWarnings.some((warning) =>
      warning.toLowerCase().includes('coverage') ||
      warning.toLowerCase().includes('distributed') ||
      warning.toLowerCase().includes('spatially limited'),
    ),
    warnings: topLevelWarnings,
    blockers,
  };
};

const runJsonRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};

const AI_GEOMETRY_INSERTION_SAFE_MESSAGE =
  'AI result insertion failed because some generated polygons were invalid. Please retry after processing cleanup.';

const isAiPredictionGeometryInsertError = (...values: unknown[]): boolean => {
  const text = values
    .map((value) => {
      if (typeof value === 'string') {
        return value;
      }
      if (value instanceof Error) {
        return value.message;
      }
      if (value && typeof value === 'object') {
        try {
          return JSON.stringify(value);
        } catch {
          return '';
        }
      }
      return '';
    })
    .join(' ')
    .toLowerCase();
  return (
    text.includes('chk_ai_prediction_feature_geom_valid') ||
    (text.includes('ai_prediction_feature') &&
      text.includes('violates check constraint')) ||
    (text.includes('ai_prediction_feature') && text.includes('failing row contains'))
  );
};

const publicAiRunMessage = (message: unknown, ...context: unknown[]): string | null => {
  const normalized = normalizeOptionalString(message);
  if (isAiPredictionGeometryInsertError(normalized, ...context)) {
    return AI_GEOMETRY_INSERTION_SAFE_MESSAGE;
  }
  return normalized;
};

const storeAiRunErrorRecord = (value: unknown): Record<string, unknown> => {
  const record = errorRecordFrom(value);
  const rawMessage =
    normalizeOptionalString(record.technical_message) ??
    normalizeOptionalString(record.message) ??
    normalizeOptionalString(value);
  if (isAiPredictionGeometryInsertError(record, rawMessage)) {
    return {
      ...record,
      message: AI_GEOMETRY_INSERTION_SAFE_MESSAGE,
      technical_message: rawMessage,
      code: 'AI_GEOMETRY_INSERTION_FAILED',
    };
  }
  return record;
};

const publicAiRunErrorRecord = (value: unknown): Record<string, unknown> => {
  const record = runJsonRecord(value);
  if (Object.keys(record).length === 0) {
    return {};
  }
  if (isAiPredictionGeometryInsertError(record)) {
    return {
      message: AI_GEOMETRY_INSERTION_SAFE_MESSAGE,
      code: 'AI_GEOMETRY_INSERTION_FAILED',
    };
  }
  const sanitized: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(record)) {
    if (
      [
        'technical_message',
        'raw_message',
        'raw_error',
        'stack',
        'trace',
        'tail',
        'failing_row',
      ].includes(key)
    ) {
      continue;
    }
    sanitized[key] = item;
  }
  const message = publicAiRunMessage(sanitized.message, record);
  if (message) {
    sanitized.message = message;
  }
  return sanitized;
};

const boundedProgress = (value: unknown): number => {
  const parsed =
    typeof value === 'number'
      ? value
      : typeof value === 'string'
        ? Number.parseFloat(value)
        : Number.NaN;
  if (!Number.isFinite(parsed)) {
    return 0;
  }
  return Math.min(1, Math.max(0, parsed));
};

const publicAiRunProgress = (
  status: unknown,
  stage: unknown,
  progress: unknown,
  ...context: unknown[]
): number => {
  const bounded = boundedProgress(progress);
  const normalizedStatus = normalizeOptionalString(status)?.toLowerCase();
  const normalizedStage = normalizeOptionalString(stage)?.toLowerCase();
  if (
    normalizedStatus === 'failed' &&
    normalizedStage === 'insertion_failed' &&
    bounded >= 1 &&
    isAiPredictionGeometryInsertError(...context)
  ) {
    return 0.96;
  }
  return bounded;
};

const normalizeRunRow = (row: any) => {
  const metadata = runJsonRecord(row.metadata);
  const aiServer = runJsonRecord(metadata.ai_server);
  const aiServerCounts = runJsonRecord(aiServer.counts);
  const artifacts = runJsonRecord(row.artifacts);
  const counts = runJsonRecord(row.counts);
  const errorDetails = runJsonRecord(row.error_details);
  const dryRun =
    row.is_dry_run === true ||
    aiServer.dry_run === true ||
    metadata.dry_run === true ||
    metadata.execution_mode === 'dry_run' ||
    metadata.execution_mode === 'mock';
  const stage =
    normalizeOptionalString(row.stage) ??
    normalizeOptionalString(aiServer.stage) ??
    normalizeOptionalString(metadata.stage);
  const message =
    publicAiRunMessage(row.message, row.error_details, row.failure_reason) ??
    publicAiRunMessage(aiServer.message, aiServer.error) ??
    publicAiRunMessage(metadata.message, metadata.error);
  const error =
    Object.keys(errorDetails).length > 0
      ? publicAiRunErrorRecord(errorDetails)
      : publicAiRunErrorRecord(aiServer.error ?? metadata.error);
  const failureReason = publicAiRunMessage(row.failure_reason, errorDetails) ?? null;
  const publicMetadata = {
    ...metadata,
    ...(Object.keys(aiServer).length > 0
      ? {
          ai_server: {
            ...aiServer,
            message: publicAiRunMessage(aiServer.message, aiServer.error),
            error: publicAiRunErrorRecord(aiServer.error),
          },
        }
      : {}),
  };
  return {
    ...row,
    metadata: publicMetadata,
    error_details: error,
    training_feature_count: Number(row.training_feature_count ?? 0),
    eligible_feature_count: Number(row.eligible_feature_count ?? 0),
    excluded_feature_count: Number(row.excluded_feature_count ?? 0),
    prediction_count: Number(
      row.prediction_count ??
        counts.predictions_inserted ??
        aiServerCounts.predictions_inserted ??
        0,
    ),
    is_dry_run: dryRun,
    display_name:
      normalizeOptionalString(row.display_name) ??
      normalizeOptionalString(metadata.display_name) ??
      null,
    published_layer_name:
      normalizeOptionalString(row.published_layer_name) ??
      normalizeOptionalString(runJsonRecord(metadata.publication).layer_name) ??
      null,
    unpublished_reason:
      normalizeOptionalString(row.unpublished_reason) ??
      normalizeOptionalString(runJsonRecord(metadata.publication).unpublished_reason) ??
      null,
    replaced_by_run_id:
      normalizeOptionalString(row.replaced_by_run_id) ??
      normalizeOptionalString(runJsonRecord(metadata.publication).replaced_by_run_id) ??
      null,
    stage,
    progress: publicAiRunProgress(
      row.status,
      stage,
      row.progress ?? aiServer.progress ?? metadata.progress,
      row.error_details,
      row.message,
      row.failure_reason,
    ),
    message,
    failure_reason: failureReason,
    ai_server_run_id:
      normalizeOptionalString(row.ai_server_run_id) ??
      normalizeOptionalString(aiServer.run_id) ??
      null,
    artifacts:
      Object.keys(artifacts).length > 0
        ? artifacts
        : runJsonRecord(aiServer.artifacts ?? metadata.artifacts),
    counts:
      Object.keys(counts).length > 0
        ? counts
        : runJsonRecord(aiServer.counts ?? metadata.counts),
    error,
    can_cancel: ['queued', 'created', 'starting', 'running', 'cancelling'].includes(
      String(row.status),
    ),
    can_resume: ['failed', 'cancelled', 'paused'].includes(String(row.status)),
  };
};

const aiServerActiveStatuses = new Set([
  'queued',
  'created',
  'starting',
  'running',
  'cancelling',
  'paused',
  'extracting_features',
  'training',
  'evaluating',
  'classifying',
]);

const activeAiRunStatusesForProject = [
  'created',
  'queued',
  'starting',
  'running',
  'cancelling',
  'extracting_features',
  'training',
  'evaluating',
  'classifying',
] as const;

const aiServerRestartMessage = 'AI server restarted before this run completed.';

const isAiServerStateNotFoundError = (error: unknown): boolean => {
  const message = error instanceof Error ? error.message : String(error ?? '');
  const normalized = message.toLowerCase();
  return (
    normalized.includes('ai run state not found') ||
    (normalized.includes('run state') && normalized.includes('not found'))
  );
};

const normalizeAiServerRunStatus = (status: unknown): string => {
  const value = normalizeOptionalString(status)?.toLowerCase() ?? 'running';
  switch (value) {
    case 'accepted':
      return 'starting';
    case 'done':
    case 'succeeded':
    case 'success':
    case 'finished':
      return 'completed';
    case 'canceling':
      return 'cancelling';
    case 'extracting_features':
    case 'training':
    case 'evaluating':
    case 'classifying':
      return 'running';
    default:
      return allowedRunStatuses.includes(value) ? value : 'running';
  }
};

const markAiRunInterruptedByAiServerRestart = async (run: any): Promise<any> =>
  updateAiRunFromServerPayload(run.id, {
    run_id: run.id,
    project_id: run.project_id,
    status: 'failed',
    stage: 'interrupted',
    progress: boundedProgress(run.progress),
    message: aiServerRestartMessage,
    error: {
      message: aiServerRestartMessage,
      reason: 'ai_server_restart',
      recoverable: true,
    },
  });

const statusTimestampPatch = (status: string): string => {
  if (status === 'completed') {
    return 'completed_at = COALESCE(completed_at, NOW()), failed_at = NULL,';
  }
  if (status === 'failed') {
    return 'failed_at = COALESCE(failed_at, NOW()),';
  }
  if (status === 'cancelled') {
    return 'cancelled_at = COALESCE(cancelled_at, NOW()),';
  }
  if (status === 'starting' || status === 'running') {
    return 'started_at = COALESCE(started_at, NOW()),';
  }
  return '';
};

const errorRecordFrom = (value: unknown): Record<string, unknown> => {
  if (value instanceof Error) {
    return { message: value.message };
  }
  const record = runJsonRecord(value);
  if (Object.keys(record).length > 0) {
    return record;
  }
  const text = normalizeOptionalString(value);
  return text ? { message: text } : {};
};

const updateAiRunFromServerPayload = async (
  runId: string,
  payload: AiServerStatusPayload,
): Promise<any> => {
  const status = normalizeAiServerRunStatus(payload.status);
  const stage = normalizeOptionalString(payload.stage);
  const payloadErrorRecord = errorRecordFrom(payload.error);
  const rawErrorInput =
    Object.keys(payloadErrorRecord).length > 0 ? payload.error : payload.message;
  const rawErrorDetails = errorRecordFrom(rawErrorInput);
  const errorDetails = status === 'failed' ? storeAiRunErrorRecord(rawErrorInput) : payloadErrorRecord;
  const message =
    publicAiRunMessage(payload.message, rawErrorDetails, errorDetails) ??
    normalizeOptionalString((errorDetails as { message?: unknown }).message);
  const progress = publicAiRunProgress(status, stage, payload.progress, rawErrorDetails, message);
  const artifacts = runJsonRecord(payload.artifacts);
  const counts = runJsonRecord(payload.counts);
  const failureReason =
    status === 'failed'
      ? publicAiRunMessage((errorDetails as { message?: unknown }).message, rawErrorDetails) ??
        message
      : null;
  const predictionsInserted = Number(counts.predictions_inserted ?? counts.prediction_count ?? 0);
  const payloadDryRun =
    payload.dry_run === true ||
    runJsonRecord(payload.metrics).dry_run === true ||
    runJsonRecord(payload.settings).dry_run === true;
  const timestampPatch = statusTimestampPatch(status);
  const existingResult = await query(`SELECT metadata FROM ai_run WHERE id = $1`, [runId]);
  const existingMetadata = runJsonRecord(existingResult.rows[0]?.metadata);
  const aiServerMetadata = runJsonRecord(existingMetadata.ai_server);
  const metadata = {
    ...existingMetadata,
    ai_server: {
      ...aiServerMetadata,
      run_id: payload.run_id ?? runId,
      project_id: payload.project_id ?? aiServerMetadata.project_id ?? null,
      status,
      stage,
      progress,
      message,
      dry_run: payloadDryRun,
      updated_at: payload.updated_at ?? new Date().toISOString(),
      last_log_at: payload.last_log_at ?? null,
      last_log_message: payload.last_log_message ?? null,
      artifacts,
      counts,
      error: Object.keys(errorDetails).length > 0 ? errorDetails : null,
    },
  };
  const result = await query(
    `UPDATE ai_run
     SET status = $2::ai_run_status,
         stage = $3,
         progress = $4,
         message = $5,
         ai_server_run_id = COALESCE(ai_server_run_id, $6),
         ${timestampPatch}
         failure_reason = CASE
           WHEN $2::text = 'failed' THEN COALESCE($10, failure_reason, 'AI server reported failure.')
           WHEN $2::text IN ('starting', 'running', 'cancelling', 'cancelled', 'completed', 'paused') THEN NULL
           ELSE failure_reason
         END,
         artifacts = $7::jsonb,
         counts = $8::jsonb,
         error_details = $9::jsonb,
         metadata = $11::jsonb,
         callback_received_at = COALESCE(callback_received_at, CASE WHEN $12::boolean THEN NOW() ELSE NULL END),
         is_dry_run = is_dry_run OR $13::boolean,
         prediction_count = GREATEST(prediction_count, $14::integer),
         updated_at = NOW()
     WHERE id = $1
     RETURNING id,
               project_id,
               settings_id,
               status,
               label_field,
               scope_type,
               ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
               region_preset,
               training_feature_count,
               eligible_feature_count,
               excluded_feature_count,
               selected_model,
               started_by,
               started_at,
               completed_at,
               failed_at,
               failure_reason,
               stage,
               progress,
               message,
               ai_server_run_id,
               cancelled_at,
               callback_received_at,
               published_at,
               published_by,
               unpublished_at,
               unpublished_by,
               display_name,
               is_dry_run,
               published_layer_name,
               unpublished_reason,
               replaced_by_run_id,
               prediction_count,
               artifacts,
               counts,
               error_details,
               metadata,
               created_at,
               updated_at`,
    [
      runId,
      status,
      stage,
      progress,
      message,
      payload.run_id ?? runId,
      JSON.stringify(artifacts),
      JSON.stringify(counts),
      JSON.stringify(errorDetails),
      failureReason,
      JSON.stringify(metadata),
      true,
      payloadDryRun,
      Number.isFinite(predictionsInserted) ? predictionsInserted : 0,
    ],
  );
  return result.rows[0];
};

const failAiRunFromDispatchError = async (
  runId: string,
  error: unknown,
  message = 'AI server is unavailable. Please start the AI server and refresh readiness.',
): Promise<any> => {
  const errorDetails = errorRecordFrom(error);
  const failureReason =
    normalizeOptionalString((errorDetails as { message?: unknown }).message) ?? message;
  const result = await query(
    `UPDATE ai_run
     SET status = 'failed',
         stage = COALESCE(stage, 'dispatch'),
         progress = 0,
         message = $2,
         failed_at = COALESCE(failed_at, NOW()),
         failure_reason = $3,
         error_details = $4::jsonb,
         metadata = metadata || $5::jsonb,
         updated_at = NOW()
     WHERE id = $1
     RETURNING id,
               project_id,
               settings_id,
               status,
               label_field,
               scope_type,
               ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
               region_preset,
               training_feature_count,
               eligible_feature_count,
               excluded_feature_count,
               selected_model,
               started_by,
               started_at,
               completed_at,
               failed_at,
               failure_reason,
               stage,
               progress,
               message,
               ai_server_run_id,
               cancelled_at,
               callback_received_at,
               artifacts,
               counts,
               error_details,
               metadata,
               created_at,
               updated_at`,
    [
      runId,
      message,
      failureReason,
      JSON.stringify(errorDetails),
      JSON.stringify({
        ai_server: {
          status: 'unavailable',
          error: errorDetails,
          updated_at: new Date().toISOString(),
        },
      }),
    ],
  );
  await query(
    `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
     VALUES ($1, 'error', $2, $3::jsonb)`,
    [
      runId,
      message,
      JSON.stringify({
        phase: 'ai_server_dispatch',
        ai_server_unavailable: true,
        error: errorDetails,
      }),
    ],
  );
  return result.rows[0];
};

const buildProjectAreaScopePayload = ({
  scopeType,
  scopeGeometry,
  readiness,
}: {
  scopeType: string;
  scopeGeometry: unknown;
  readiness: Record<string, any>;
}): Record<string, unknown> => {
  const geometry = scopeGeometry && typeof scopeGeometry === 'object' ? scopeGeometry : null;
  const extent = runJsonRecord(readiness.spatial_extent);
  const bbox =
    scopeType === 'national'
      ? [
          lebanonApproxBounds.min_lon,
          lebanonApproxBounds.min_lat,
          lebanonApproxBounds.max_lon,
          lebanonApproxBounds.max_lat,
        ]
      : typeof extent.min_lon === 'number' &&
    typeof extent.min_lat === 'number' &&
    typeof extent.max_lon === 'number' &&
    typeof extent.max_lat === 'number'
      ? [extent.min_lon, extent.min_lat, extent.max_lon, extent.max_lat]
      : [];
  const type =
    scopeType === 'custom_polygon'
      ? 'custom_aoi'
      : scopeType === 'national'
        ? 'national_lebanon'
        : 'project_boundary_or_feature_extent';
  return {
    type,
    scope_type: scopeType,
    geometry,
    bbox,
    source:
      scopeType === 'national'
        ? 'static_lebanon_boundary'
        : geometry !== null
        ? 'explicit_project_ai_scope_geometry'
        : bbox.length === 4
          ? 'project_feature_extent'
          : 'not_configured',
  };
};

const buildAiServerRunPayload = ({
  runId,
  projectId,
  settings,
  modelPreferences,
  satelliteSources,
  satelliteTimeframes,
  scopeType,
  scopeGeometry,
  readiness,
  currentUserId,
  executionMode,
  minSamplesPerClass,
}: {
  runId: string;
  projectId: string;
  settings: any;
  modelPreferences: Record<string, unknown>;
  satelliteSources: Array<'sentinel2' | 'landsat'>;
  satelliteTimeframes: Record<
    string,
    { map_year: number; seasons: Array<{ season: string; from_date: string; to_date: string }> }
  >;
  scopeType: string;
  scopeGeometry: unknown;
  readiness: Record<string, any>;
  currentUserId: string | null;
  executionMode: string;
  minSamplesPerClass: number;
}): AiServerStartPayload => {
  const aiServerClient = createAiServerClient();
  const projectAreaScope = buildProjectAreaScopePayload({
    scopeType,
    scopeGeometry,
    readiness,
  });
  const selectedFeatureInputs = Array.isArray(modelPreferences.feature_inputs)
    ? modelPreferences.feature_inputs
    : Array.isArray(modelPreferences.selected_feature_inputs)
      ? modelPreferences.selected_feature_inputs
      : Array.isArray(modelPreferences.selected_extracted_features)
        ? modelPreferences.selected_extracted_features
        : [];
  const featureGroups = Array.isArray(modelPreferences.feature_groups)
    ? modelPreferences.feature_groups
    : [];
  const preferredModel = normalizeOptionalString(modelPreferences.preferred_model);
  return {
    run_id: runId,
    project_id: projectId,
    settings: {
      project_id: projectId,
      run_id: runId,
      satellite_sources: satelliteSources,
      satellite_timeframes: satelliteTimeframes,
      confidence_threshold: settings.confidence_threshold,
      min_samples_per_class: minSamplesPerClass,
      label_field: settings.label_field,
      scope_type: scopeType,
      training_samples_area_type: aiAreaTypeFromScope(scopeType),
      prediction_area_type: aiAreaTypeFromScope(scopeType),
      feature_groups: featureGroups,
      selected_feature_inputs: selectedFeatureInputs,
      selected_extracted_features: selectedFeatureInputs,
      preferred_model: preferredModel,
      project_area_scope: projectAreaScope,
      custom_polygon:
        scopeType === 'custom_polygon' && projectAreaScope.geometry
          ? projectAreaScope.geometry
          : undefined,
      model_preferences: modelPreferences,
      execution_mode: executionMode,
      dry_run: executionMode === 'dry_run' || executionMode === 'mock',
      safety_flags: {
        national_scope_enabled: readiness.national_scope_enabled === true,
        allow_spatial_feature_writes: false,
        publish_outputs: false,
      },
    },
    callback_url: aiServerClient.callbackUrl(runId),
    callback_secret: aiServerClient.callbackSecret(),
    requested_by: currentUserId,
    metadata: {
      app_backend_run_id: runId,
      execution_mode: executionMode,
      readiness_status: readiness.status,
      training_samples_area_type: aiAreaTypeFromScope(scopeType),
      prediction_area_type: aiAreaTypeFromScope(scopeType),
    },
  };
};

const maybeRefreshAiRunFromServer = async (
  run: any,
  options: { force?: boolean } = {},
): Promise<any> => {
  const isActive = aiServerActiveStatuses.has(String(run.status));
  if (!options.force && !isActive) {
    return run;
  }
  const aiServerClient = createAiServerClient();
  if (!aiServerClient.isConfigured()) {
    return run;
  }
  try {
    const payload = await aiServerClient.getRunStatus(run.id);
    const updated = await updateAiRunFromServerPayload(run.id, payload);
    await insertCallbackMetricRows(run.id, payload.metrics);
    return updated;
  } catch (error) {
    if (isAiServerStateNotFoundError(error)) {
      if (!isActive) {
        return run;
      }
      return markAiRunInterruptedByAiServerRestart(run);
    }
    return run;
  }
};

const loadProjectAiRunOrFail = async (projectId: string, runId: string): Promise<any> => {
  const result = await query(
    `SELECT ar.*,
            p.name AS project_name,
            ST_AsGeoJSON(ar.scope_geometry)::json AS scope_geometry
     FROM ai_run ar
     JOIN project p ON p.id = ar.project_id
     WHERE ar.id = $1
       AND ar.project_id = $2`,
    [runId, projectId],
  );
  if (result.rows.length === 0) {
    throw new AppError('AI run not found', 404);
  }
  return result.rows[0];
};

const assertRunReadable = async (runId: string, user: Express.UserContext) => {
  const runResult = await query(
    `SELECT ar.*,
            p.name AS project_name,
            ST_AsGeoJSON(ar.scope_geometry)::json AS scope_geometry
     FROM ai_run ar
     JOIN project p ON p.id = ar.project_id
     WHERE ar.id = $1`,
    [runId],
  );

  if (runResult.rows.length === 0) {
    throw new AppError('AI run not found', 404);
  }

  const run = runResult.rows[0];
  if (user.role === 'admin') {
    return run;
  }

  const accessResult = await query(
    `SELECT id
     FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
       AND role = 'admin'
       AND status = 'approved'
     LIMIT 1`,
    [run.project_id, user.id],
  );

  if (accessResult.rows.length === 0) {
    throw new AppError('You must be a project admin to access this AI run', 403);
  }

  return run;
};

const isProtectedSuperAdminUser = (user: Express.UserContext | undefined): boolean =>
  user?.role === 'admin' && isProtectedSuperAdminEmail(user.email);

const assertProjectReadableForAiLayer = async (
  projectId: string,
  user: Express.UserContext,
): Promise<void> => {
  await synchronizeProjectStatuses(projectId);
  if (user.role === 'admin') {
    return;
  }

  const visibleStatuses = publicVisibleStatuses;
  if (user.role === 'viewer') {
    const result = await query(
      `SELECT id
       FROM project
       WHERE id = $1
         AND visible_to_viewers = TRUE
         AND status::text = ANY($2::text[])`,
      [projectId, visibleStatuses],
    );
    if (result.rows.length > 0) {
      return;
    }
    throw new AppError('You do not have access to this project', 403);
  }

  const result = await query(
    `SELECT
        EXISTS (
          SELECT 1
          FROM project_assignment
          WHERE project_id = $1
            AND user_id = $2
            AND status = 'approved'
        ) AS has_assignment,
        EXISTS (
          SELECT 1
          FROM project
          WHERE id = $1
            AND visible_to_contributors = TRUE
            AND status::text = ANY($3::text[])
        ) AS is_public_project`,
    [projectId, user.id, visibleStatuses],
  );
  const row = result.rows[0];
  if (row?.has_assignment === true || row?.is_public_project === true) {
    return;
  }
  throw new AppError('You do not have access to this project', 403);
};

const getProjectAiReadiness = async (req: Request, res: Response): Promise<void> => {
  const { projectId } = req.params;
  const project = await getProjectOrFail(projectId);
  const settings = await getEffectiveAiSettings(projectId);
  const requestedLabelField = normalizeOptionalString(req.query.label_field);
  const labelField =
    requestedLabelField ??
    settings.label_field ??
    preferredSchemaLabelFieldFrom(project.collection_form_schema);
  const minSamplesPerClass = parsePositiveInteger(
    req.query.min_samples_per_class,
    Number(settings.min_samples_per_class),
  );
  const requestedScopeType = normalizeOptionalString(req.query.scope_type);
  const scopeType = requestedScopeType ?? settings.scope_type;

  const readiness = await getFeatureReadinessSummary({
    projectId,
    labelField,
    minSamplesPerClass,
    scopeType,
    scopeGeometry: settings.scope_geometry,
    modelPreferences: settings.model_preferences ?? {},
  });
  const aiServerClient = createAiServerClient();
  let aiServerHealth: Record<string, unknown> = {
    configured: aiServerClient.isConfigured(),
    status: aiServerClient.isConfigured() ? 'unknown' : 'unconfigured',
    available: false,
    callback_secret_configured: aiServerClient.callbackSecret().trim().length > 0,
  };
  if (aiServerClient.isConfigured()) {
    try {
      const health = await aiServerClient.health();
      const healthStatus =
        typeof health.status === 'string' && health.status.trim().length > 0
          ? health.status.trim()
          : 'unknown';
      aiServerHealth = {
        ...health,
        configured: true,
        status: healthStatus,
        available: healthStatus === 'ok',
        callback_secret_configured: aiServerClient.callbackSecret().trim().length > 0,
      };
    } catch (error) {
      aiServerHealth = {
        configured: true,
        status: 'unavailable',
        available: false,
        callback_secret_configured: aiServerClient.callbackSecret().trim().length > 0,
        message: error instanceof Error ? error.message : 'AI server health check failed.',
      };
    }
  }
  const readinessWithAiServer = { ...readiness };
  const aiServerWarnings: string[] = [];
  if (!aiServerClient.isConfigured()) {
    aiServerWarnings.push('AI server URL is not configured. Set AI_SERVER_URL before starting AI runs.');
  } else if (aiServerHealth.available !== true) {
    const healthStatus =
      typeof aiServerHealth.status === 'string' ? aiServerHealth.status : 'unavailable';
    const detail =
      typeof aiServerHealth.message === 'string' && aiServerHealth.message.trim().length > 0
        ? ` ${aiServerHealth.message.trim()}`
        : '';
    aiServerWarnings.push(
      healthStatus === 'degraded'
        ? `AI server health is degraded.${detail}`
        : 'AI server is unavailable. Please start the AI server and refresh readiness.',
    );
  }
  if (aiServerClient.callbackSecret().trim().length === 0) {
    aiServerWarnings.push('AI_CALLBACK_SECRET is not configured. AI server callbacks cannot be accepted.');
  }
  if (aiServerWarnings.length > 0) {
    readinessWithAiServer.warnings = Array.from(
      new Set([...(readiness.warnings ?? []), ...aiServerWarnings]),
    );
    if (settings.is_enabled) {
      readinessWithAiServer.blockers = Array.from(
        new Set([...(readiness.blockers ?? []), ...aiServerWarnings]),
      );
      readinessWithAiServer.status = 'not_ready';
    }
  }
  const candidateLabelFields = await getCandidateLabelFieldSummary({
    projectId,
    collectionFormSchema: project.collection_form_schema,
    selectedLabelField: labelField,
  });

  res.json({
    success: true,
    data: {
      project: {
        id: project.id,
        name: project.name,
      },
      settings: {
        is_enabled: settings.is_enabled,
        label_field: labelField,
        scope_type: settings.scope_type,
        min_samples_per_class: settings.min_samples_per_class,
        confidence_threshold: settings.confidence_threshold,
        model_preferences: settings.model_preferences,
      },
      readiness: {
        ...readinessWithAiServer,
        ai_server: aiServerHealth,
        candidate_label_fields: candidateLabelFields,
      },
    },
  });
};

const getProjectAiSettings = async (req: Request, res: Response): Promise<void> => {
  const { projectId } = req.params;
  const project = await getProjectOrFail(projectId);
  const settings = await getEffectiveAiSettings(projectId);

  res.json({
    success: true,
    data: {
      ...settings,
      label_field:
        settings.label_field ?? preferredSchemaLabelFieldFrom(project.collection_form_schema),
    },
  });
};

const upsertProjectAiSettings = async (req: Request, res: Response): Promise<void> => {
  const { projectId } = req.params;
  const project = await getProjectOrFail(projectId);
  const existing = await getEffectiveAiSettings(projectId);
  const body = req.body ?? {};

  const nextSettings = {
    is_enabled: body.is_enabled !== undefined ? Boolean(body.is_enabled) : existing.is_enabled,
    label_field:
      body.label_field !== undefined
        ? normalizeOptionalString(body.label_field)
        : existing.label_field,
    scope_type: body.scope_type !== undefined ? String(body.scope_type) : existing.scope_type,
    scope_geometry:
      body.scope_geometry !== undefined ? body.scope_geometry : existing.scope_geometry,
    min_samples_per_class:
      body.min_samples_per_class !== undefined
        ? parsePositiveInteger(body.min_samples_per_class, existing.min_samples_per_class)
        : existing.min_samples_per_class,
    confidence_threshold:
      body.confidence_threshold !== undefined
        ? normalizeConfidenceThreshold(body.confidence_threshold, existing.confidence_threshold)
        : existing.confidence_threshold,
    model_preferences: normalizeAiModelPreferences(
      body.model_preferences !== undefined
        ? (body.model_preferences ?? {})
        : (existing.model_preferences ?? {}),
      { strictModel: true },
    ),
  };

  if (
    nextSettings.scope_type === 'national' ||
    boolPreference(nextSettings.model_preferences, 'national_scope_enabled')
  ) {
    const labelField =
      nextSettings.label_field ?? preferredSchemaLabelFieldFrom(project.collection_form_schema);
    if (!labelField) {
      throw new AppError('AI label_field is required before national AI can be enabled.', 422);
    }
    const nationalReadiness = await getFeatureReadinessSummary({
      projectId,
      labelField,
      minSamplesPerClass: nextSettings.min_samples_per_class,
      scopeType: 'national',
      scopeGeometry: nextSettings.scope_geometry,
      modelPreferences: nextSettings.model_preferences,
    });
    if (!nationalReadiness.national_scope_eligibility?.eligible) {
      throw new AppError(
        'National Lebanon AI scope is locked until national readiness requirements pass.',
        422,
      );
    }
    if (
      nextSettings.scope_type === 'national' &&
      !boolPreference(nextSettings.model_preferences, 'national_scope_enabled')
    ) {
      throw new AppError(
        'National Lebanon AI scope must be explicitly enabled before it can be saved as the active AI scope.',
        422,
      );
    }
  }

  const result = await query(
    `INSERT INTO ai_project_settings (
       project_id,
       is_enabled,
       label_field,
       scope_type,
       scope_geometry,
       min_samples_per_class,
       confidence_threshold,
       model_preferences,
       created_by,
       updated_by
     )
     VALUES (
       $1,
       $2,
       $3,
       $4,
       CASE
         WHEN $5::text IS NULL THEN NULL
         ELSE ST_SetSRID(ST_GeomFromGeoJSON($5::text), 4326)
       END,
       $6,
       $7,
       $8::jsonb,
       $9,
       $9
     )
     ON CONFLICT (project_id)
     DO UPDATE SET
       is_enabled = EXCLUDED.is_enabled,
       label_field = EXCLUDED.label_field,
       scope_type = EXCLUDED.scope_type,
       scope_geometry = EXCLUDED.scope_geometry,
       min_samples_per_class = EXCLUDED.min_samples_per_class,
       confidence_threshold = EXCLUDED.confidence_threshold,
       model_preferences = EXCLUDED.model_preferences,
       updated_by = EXCLUDED.updated_by
     RETURNING id,
               project_id,
               is_enabled,
               label_field,
               scope_type,
               ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
               min_samples_per_class,
               confidence_threshold,
               model_preferences,
               created_by,
               updated_by,
               created_at,
               updated_at`,
    [
      projectId,
      nextSettings.is_enabled,
      nextSettings.label_field,
      nextSettings.scope_type,
      serializeGeometry(nextSettings.scope_geometry),
      nextSettings.min_samples_per_class,
      nextSettings.confidence_threshold,
      JSON.stringify(nextSettings.model_preferences),
      (req.user as Express.UserContext).id,
    ],
  );

  res.json({
    success: true,
    message: 'AI project settings saved successfully.',
    data: {
      ...result.rows[0],
      model_preferences: normalizeAiModelPreferences(result.rows[0].model_preferences),
    },
  });
};

const createProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  const { projectId } = req.params;
  const project = await getProjectOrFail(projectId);
  const settings = await getEffectiveAiSettings(projectId);
  const body = req.body ?? {};
  const requestedStatus = normalizeOptionalString(body.status);
  const shouldStart = requestedStatus !== 'draft';
  const status = shouldStart ? 'starting' : 'draft';
  const requestedExecutionMode = normalizeOptionalString(body.execution_mode);
  const executionMode = requestedExecutionMode ?? 'regional_full_review_artifacts';
  const labelField =
    normalizeOptionalString(body.label_field) ??
    settings.label_field ??
    preferredSchemaLabelFieldFrom(project.collection_form_schema);
  const scopeType = normalizeOptionalString(body.scope_type) ?? settings.scope_type;
  const scopeGeometry =
    body.scope_geometry !== undefined ? body.scope_geometry : settings.scope_geometry;
  const regionPreset = normalizeOptionalString(body.region_preset);
  const minSamplesPerClass =
    body.min_samples_per_class !== undefined
      ? parsePositiveInteger(body.min_samples_per_class, settings.min_samples_per_class)
      : settings.min_samples_per_class;
  const modelPreferences = normalizeAiModelPreferences(settings.model_preferences ?? {}, {
    strictModel: true,
  });

  if (!labelField) {
    throw new AppError('AI label_field is required to create an AI run.', 400);
  }

  if (!allowedExecutionModes.includes(executionMode)) {
    throw new AppError(
      'Unsupported AI execution_mode. Allowed modes are mock, dry_run, local_ground_truth_export, regional_feature_extraction, regional_model_eval, regional_classification, regional_vectorization_artifacts, or regional_full_review_artifacts.',
      400,
    );
  }

  const readiness = await getFeatureReadinessSummary({
    projectId,
    labelField,
    minSamplesPerClass,
    scopeType,
    scopeGeometry,
    modelPreferences,
  });
  const isNationalScope = scopeType === 'national' || scopeType === 'national_lebanon';

  if (isNationalScope && readiness.national_scope_enabled !== true) {
    throw new AppError(
      'National Lebanon AI scope is locked until national readiness requirements pass.',
      422,
    );
  }

  if (shouldStart && !settings.is_enabled) {
    throw new AppError('AI must be enabled for this project before starting a run.', 400);
  }

  if (shouldStart && readiness.status === 'not_ready') {
    throw new AppError('AI run cannot start until readiness blockers are resolved.', 422);
  }

  if (
    shouldStart &&
    isNationalScope &&
    regionalExecutionModes.includes(executionMode)
  ) {
    throw new AppError(
      'National Lebanon AI runs are not available in the current regional AI pipeline. Choose Project area or Custom AI area.',
      422,
    );
  }

  const currentUser = req.user as Express.UserContext;
  const aiServerClient = createAiServerClient();
  let aiServerHealth: Record<string, unknown> | null = null;
  let preDispatchFailure: { error: unknown; responseMessage: string } | null = null;
  const aiServerStartDryRun = executionMode === 'dry_run' || executionMode === 'mock';
  if (shouldStart) {
    if (!aiServerClient.isConfigured()) {
      const message = 'AI server URL is not configured. Set AI_SERVER_URL before starting AI runs.';
      preDispatchFailure = {
        error: new AppError(message, 503),
        responseMessage: message,
      };
    } else if (aiServerClient.callbackSecret().trim().length === 0) {
      const message = 'AI_CALLBACK_SECRET is not configured. AI server callbacks cannot be accepted.';
      preDispatchFailure = {
        error: new AppError(message, 503),
        responseMessage: message,
      };
    } else {
      try {
        aiServerHealth = await aiServerClient.health();
        const healthStatus =
          typeof aiServerHealth.status === 'string' ? aiServerHealth.status : 'unknown';
        if (healthStatus !== 'ok') {
          const detail =
            normalizeOptionalString(aiServerHealth.message) ??
            `AI server health check did not return ok (status: ${healthStatus}).`;
          preDispatchFailure = {
            error: new AppError(detail, 503),
            responseMessage: detail,
          };
        }
      } catch (error) {
        preDispatchFailure = {
          error,
          responseMessage: 'AI server is unavailable. Please start the AI server and refresh readiness.',
        };
      }
    }
  }
  const trainingSamplesAreaType = aiAreaTypeFromScope(scopeType);
  const predictionAreaType = trainingSamplesAreaType;
  const satelliteSources = normalizeSatelliteSources(modelPreferences);
  const satelliteTimeframes = normalizeSatelliteTimeframes(modelPreferences, satelliteSources);
  const pendingPipelineSettings = [
    'satellite_sources',
    'satellite_timeframes',
    'confidence_threshold',
    'date_range',
    'feature_groups',
    'feature_inputs',
    'preferred_model',
    'prediction_area_type',
    ...(scopeType === 'custom_polygon' ? ['custom_area'] : []),
  ];
  const runCreatedLogMessage =
    shouldStart
      ? 'AI run record created; dispatching to AI server.'
      : 'AI run draft created; no AI server execution started.';
  const runCreatedResponseMessage =
    shouldStart
      ? 'AI run created and dispatching to the AI server.'
      : 'AI run draft created. No AI server execution has started.';
  const runDisplayName = `AI Classification - ${project.name} - ${new Date()
    .toISOString()
    .slice(0, 10)}`;
  const createdRun = await transaction(async (client: PoolClient) => {
    if (shouldStart) {
      await client.query('SELECT id FROM project WHERE id = $1 FOR UPDATE', [projectId]);
      const activeRun = await client.query(
        `SELECT id, display_name, status, created_at
         FROM ai_run
         WHERE project_id = $1
           AND status IN (
             'created',
             'queued',
             'starting',
             'running',
             'cancelling',
             'extracting_features',
             'training',
             'evaluating',
             'classifying'
           )
         ORDER BY created_at DESC
         LIMIT 1
         FOR UPDATE`,
        [projectId],
      );
      if (activeRun.rows.length > 0) {
        throw new AppError('An AI run is already active for this project.', 409);
      }
    }
    const runResult = await client.query(
      `INSERT INTO ai_run (
         project_id,
         settings_id,
         status,
         display_name,
         is_dry_run,
         label_field,
         scope_type,
         scope_geometry,
         region_preset,
         training_feature_count,
         eligible_feature_count,
         excluded_feature_count,
         started_by,
         stage,
         progress,
         message,
         artifacts,
         counts,
         error_details,
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
         CASE
           WHEN $8::text IS NULL THEN NULL
           ELSE ST_SetSRID(ST_GeomFromGeoJSON($8::text), 4326)
         END,
         $9,
         $10,
         $11,
         $12,
         $13,
         $14,
         $15,
         $16,
         '{}'::jsonb,
         '{}'::jsonb,
         '{}'::jsonb,
         $17::jsonb
       )
       RETURNING id,
                 project_id,
                 settings_id,
                 status,
                 display_name,
                 is_dry_run,
                 published_layer_name,
                 unpublished_reason,
                 replaced_by_run_id,
                 prediction_count,
                 label_field,
                 scope_type,
                 ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
                 region_preset,
                 training_feature_count,
                 eligible_feature_count,
                 excluded_feature_count,
                 selected_model,
                 started_by,
                 started_at,
                 completed_at,
                 failed_at,
                 failure_reason,
                 stage,
                 progress,
                 message,
                 ai_server_run_id,
                 cancelled_at,
                 callback_received_at,
                 published_at,
                 published_by,
                 unpublished_at,
                 unpublished_by,
                 artifacts,
                 counts,
                 error_details,
                 metadata,
                 created_at,
                 updated_at`,
      [
        projectId,
        settings.id,
        status,
        runDisplayName,
        shouldStart && (aiServerHealth?.dry_run === true || aiServerStartDryRun),
        labelField,
        scopeType,
        serializeGeometry(scopeGeometry),
        regionPreset,
        readiness.approved_feature_count,
        readiness.eligible_feature_count,
        readiness.excluded_feature_count,
        currentUser.id,
        shouldStart ? 'dispatch' : null,
        0,
        shouldStart ? 'Dispatching run to AI server.' : 'Draft AI run record created.',
        JSON.stringify({
          readiness_status: readiness.status,
          training_samples_area_type: trainingSamplesAreaType,
          prediction_area_type: predictionAreaType,
          national_scope_enabled: readiness.national_scope_enabled === true,
          national_scope_eligibility: readiness.national_scope_eligibility,
          project_bounds: readiness.spatial_extent,
          ai_settings: {
            satellite_sources: satelliteSources,
            satellite_timeframes: satelliteTimeframes,
            satellite_source: modelPreferences.satellite_source ?? null,
            target_year: modelPreferences.target_year ?? null,
            season: modelPreferences.season ?? null,
            date_from: modelPreferences.date_from ?? null,
            date_to: modelPreferences.date_to ?? null,
            feature_groups: modelPreferences.feature_groups ?? [],
            feature_inputs: modelPreferences.feature_inputs ?? [],
            preferred_model: modelPreferences.preferred_model ?? null,
            confidence_threshold: settings.confidence_threshold,
            scope_type: scopeType,
            training_samples_area_type: trainingSamplesAreaType,
            prediction_area_type: predictionAreaType,
            custom_scope_applied: readiness.custom_scope_applied === true,
            custom_polygon_summary:
              scopeType === 'custom_polygon'
                ? {
                    saved_for_run: true,
                    geometry_type:
                      scopeGeometry && typeof scopeGeometry === 'object'
                        ? ((scopeGeometry as { type?: unknown }).type ?? null)
                        : null,
                  }
                : null,
          },
          pipeline_execution_support: {
            settings_saved_for_run: true,
            backend_scope_applied: true,
            pipeline_config_payload_ready: true,
            effective_pipeline_settings: [
              'label_field',
              'execution_mode',
              'training_samples_area_type',
            ],
            pending_pipeline_settings: pendingPipelineSettings,
          },
          min_samples_per_class: minSamplesPerClass,
          confidence_threshold: settings.confidence_threshold,
          class_counts: readiness.label_counts.map(
            (row: { class_label: string; sample_count: number }) => ({
              class_label: row.class_label,
              feature_count: row.sample_count,
              sample_count: row.sample_count,
            }),
          ),
          selected_classes: readiness.label_counts
            .filter((row: { class_label: string; sample_count: number }) => row.sample_count >= minSamplesPerClass)
            .map((row: { class_label: string; sample_count: number }) => row.class_label),
          ai_server: {
            status: shouldStart ? 'dispatching' : 'not_started',
            stage: shouldStart ? 'dispatch' : null,
            progress: 0,
            dry_run: shouldStart ? aiServerHealth?.dry_run === true : null,
          },
          worker_execution: 'replaced_by_ai_server',
          execution_mode: executionMode,
          display_name: runDisplayName,
          dry_run: shouldStart && (aiServerHealth?.dry_run === true || aiServerStartDryRun),
          real_run: shouldStart && aiServerHealth?.dry_run !== true && !aiServerStartDryRun,
          real_ai_execution: shouldStart,
          regional_ai_execution_requested: regionalExecutionModes.includes(executionMode),
          scientific_limitations: [],
          requested_by: currentUser.id,
          requested_status: requestedStatus ?? status,
        }),
      ],
    );

    await client.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        runResult.rows[0].id,
        runCreatedLogMessage,
        JSON.stringify({
          phase: 'backend_run_creation',
          readiness_status: readiness.status,
          execution_mode: executionMode,
          real_ai_execution: shouldStart,
        }),
      ],
    );

    return runResult.rows[0];
  });

  if (!shouldStart) {
    res.status(201).json({
      success: true,
      message: runCreatedResponseMessage,
      data: normalizeRunRow(createdRun),
    });
    return;
  }

  if (preDispatchFailure) {
    const failedRun = await failAiRunFromDispatchError(
      createdRun.id,
      preDispatchFailure.error,
      preDispatchFailure.responseMessage,
    );
    res.status(503).json({
      success: false,
      message: preDispatchFailure.responseMessage,
      data: normalizeRunRow(failedRun),
    });
    return;
  }

  try {
    logger.info('Dispatching AI run to AI server', {
      runId: createdRun.id,
      projectId,
      executionMode,
    });
    const payload = buildAiServerRunPayload({
      runId: createdRun.id,
      projectId,
      settings: { ...settings, label_field: labelField },
      modelPreferences,
      satelliteSources,
      satelliteTimeframes,
      scopeType,
      scopeGeometry,
      readiness,
      currentUserId: currentUser.id,
      executionMode,
      minSamplesPerClass,
    });
    const serverResponse = await aiServerClient.startRun(payload);
    logger.info('AI server start response received', {
      runId: createdRun.id,
      aiServerStatus: serverResponse.status ?? 'accepted',
      stage: serverResponse.stage ?? 'accepted',
    });
    const updatedRun = await updateAiRunFromServerPayload(createdRun.id, {
      ...serverResponse,
      run_id: serverResponse.run_id ?? createdRun.id,
      project_id: serverResponse.project_id ?? projectId,
      status: normalizeAiServerRunStatus(serverResponse.status ?? 'starting'),
      stage: serverResponse.stage ?? 'accepted',
      progress: serverResponse.progress ?? 0,
      message: serverResponse.message ?? 'Pipeline accepted by AI server.',
    });
    await query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        createdRun.id,
        'AI run dispatched to AI server.',
        JSON.stringify({
          phase: 'ai_server_dispatch',
          ai_server_status: serverResponse.status ?? 'accepted',
          stage: serverResponse.stage ?? 'accepted',
        }),
      ],
    );
    res.status(201).json({
      success: true,
      message: 'AI run started through the AI server.',
      data: normalizeRunRow(updatedRun),
    });
  } catch (error) {
    logger.error('AI server dispatch failed', {
      runId: createdRun.id,
      projectId,
      error: error instanceof Error ? error.message : 'Unknown dispatch failure',
    });
    const failedRun = await failAiRunFromDispatchError(createdRun.id, error);
    res.status(503).json({
      success: false,
      message: 'AI server is unavailable. Please start the AI server and refresh readiness.',
      data: normalizeRunRow(failedRun),
    });
  }
};

const listProjectAiRuns = async (req: Request, res: Response): Promise<void> => {
  const { projectId } = req.params;
  await getProjectOrFail(projectId);
  const { page, limit, offset } = parsePagination(req);
  const status = normalizeOptionalString(req.query.status);
  const params: unknown[] = [projectId];
  let statusFilter = '';
  if (status) {
    if (!allowedRunStatuses.includes(status)) {
      throw new AppError('Invalid AI run status filter.', 400);
    }
    params.push(status);
    statusFilter = ` AND status = $${params.length}`;
  }

  const result = await query(
    `SELECT id,
            project_id,
            settings_id,
            status,
            display_name,
            is_dry_run,
            published_layer_name,
            unpublished_reason,
            replaced_by_run_id,
            prediction_count,
            label_field,
            scope_type,
            ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
            region_preset,
            training_feature_count,
            eligible_feature_count,
            excluded_feature_count,
            selected_model,
            started_by,
            started_at,
            completed_at,
            failed_at,
            failure_reason,
            stage,
            progress,
            message,
            ai_server_run_id,
            cancelled_at,
            callback_received_at,
            artifacts,
            counts,
            error_details,
            published_at,
            published_by,
            unpublished_at,
            unpublished_by,
            metadata,
            created_at,
            updated_at
     FROM ai_run
     WHERE project_id = $1
       ${statusFilter}
     ORDER BY created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, limit, offset],
  );
  const refreshedRows: any[] = [];
  for (const row of result.rows) {
    refreshedRows.push(await maybeRefreshAiRunFromServer(row));
  }

  const countResult = await query(
    `SELECT COUNT(*)::int AS total
     FROM ai_run
     WHERE project_id = $1
       ${statusFilter}`,
    params,
  );
  const total = Number(countResult.rows[0]?.total ?? 0);

  res.json({
    success: true,
    data: refreshedRows.map(normalizeRunRow),
    pagination: {
      page,
      limit,
      total,
      pages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + result.rows.length < total,
    },
  });
};

const getAiRun = async (req: Request, res: Response): Promise<void> => {
  const run = await maybeRefreshAiRunFromServer(
    await assertRunReadable(req.params.runId, req.user as Express.UserContext),
  );

  res.json({
    success: true,
    data: normalizeRunRow(run),
  });
};

const getProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  await getProjectOrFail(req.params.projectId);
  const run = await maybeRefreshAiRunFromServer(
    await loadProjectAiRunOrFail(req.params.projectId, req.params.runId),
  );
  res.json({
    success: true,
    data: normalizeRunRow(run),
  });
};

const getProjectAiRunStatus = async (req: Request, res: Response): Promise<void> => {
  await getProjectOrFail(req.params.projectId);
  const run = await maybeRefreshAiRunFromServer(
    await loadProjectAiRunOrFail(req.params.projectId, req.params.runId),
    { force: true },
  );
  res.json({
    success: true,
    data: normalizeRunRow(run),
  });
};

const cancelProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  await getProjectOrFail(req.params.projectId);
  const run = await loadProjectAiRunOrFail(req.params.projectId, req.params.runId);
  if (!['queued', 'created', 'starting', 'running', 'cancelling'].includes(String(run.status))) {
    throw new AppError('Only active AI runs can be cancelled.', 409);
  }
  const aiServerClient = createAiServerClient();
  if (!aiServerClient.isConfigured()) {
    const cancelled = await updateAiRunFromServerPayload(run.id, {
      run_id: run.id,
      project_id: run.project_id,
      status: 'cancelled',
      stage: 'cancelled',
      progress: boundedProgress(run.progress),
      message: 'AI run cancelled locally because the AI server is not configured.',
    });
    res.json({
      success: true,
      message: 'AI run cancelled locally.',
      data: normalizeRunRow(cancelled),
    });
    return;
  }
  let serverResponse: AiServerStatusPayload;
  try {
    serverResponse = await aiServerClient.cancelRun(run.id);
  } catch (error) {
    if (!isAiServerStateNotFoundError(error)) {
      throw error;
    }
    const interrupted = await markAiRunInterruptedByAiServerRestart(run);
    res.json({
      success: true,
      message: aiServerRestartMessage,
      data: normalizeRunRow(interrupted),
    });
    return;
  }
  const updated = await updateAiRunFromServerPayload(run.id, {
    ...serverResponse,
    run_id: serverResponse.run_id ?? run.id,
    project_id: serverResponse.project_id ?? run.project_id,
    status: serverResponse.status ?? 'cancelled',
  });
  await query(
    `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
     VALUES ($1, 'info', 'AI run cancellation requested.', $2::jsonb)`,
    [
      run.id,
      JSON.stringify({
        phase: 'ai_server_cancel',
        ai_server_status: serverResponse.status ?? 'cancelled',
      }),
    ],
  );
  res.json({
    success: true,
    message: 'AI run cancellation requested.',
    data: normalizeRunRow(updated),
  });
};

const resumeProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  await getProjectOrFail(req.params.projectId);
  const run = await loadProjectAiRunOrFail(req.params.projectId, req.params.runId);
  if (!['failed', 'cancelled', 'paused'].includes(String(run.status))) {
    throw new AppError('Only failed, cancelled, or paused AI runs can be resumed.', 409);
  }
  const activeRun = await query(
    `SELECT id, display_name, status, created_at
     FROM ai_run
     WHERE project_id = $1
       AND id <> $2
       AND status = ANY($3::ai_run_status[])
     ORDER BY created_at DESC
     LIMIT 1`,
    [run.project_id, run.id, activeAiRunStatusesForProject],
  );
  if (activeRun.rows.length > 0) {
    throw new AppError('Another AI run is already active for this project.', 409);
  }
  const aiServerClient = createAiServerClient();
  if (!aiServerClient.isConfigured()) {
    throw new AppError('AI server URL is not configured. Set AI_SERVER_URL before resuming runs.', 503);
  }
  let serverResponse: AiServerStatusPayload;
  try {
    serverResponse = await aiServerClient.resumeRun(run.id);
  } catch (error) {
    if (isAiServerStateNotFoundError(error)) {
      throw new AppError(
        'Resume is not available because the AI server no longer has this run state. Start a new AI run.',
        409,
      );
    }
    throw error;
  }
  const updated = await updateAiRunFromServerPayload(run.id, {
    ...serverResponse,
    run_id: serverResponse.run_id ?? run.id,
    project_id: serverResponse.project_id ?? run.project_id,
    status: serverResponse.status ?? 'starting',
  });
  await query(
    `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
     VALUES ($1, 'info', 'AI run resume requested.', $2::jsonb)`,
    [
      run.id,
      JSON.stringify({
        phase: 'ai_server_resume',
        ai_server_status: serverResponse.status ?? 'starting',
      }),
    ],
  );
  res.json({
    success: true,
    message: 'AI run resume requested.',
    data: normalizeRunRow(updated),
  });
};

const insertCallbackMetricRows = async (
  runId: string,
  metricsValue: unknown,
): Promise<number> => {
  const metrics = runJsonRecord(metricsValue);
  if (Object.keys(metrics).length === 0) {
    return 0;
  }

  const metricNumber = (
    record: Record<string, unknown>,
    keys: string[],
  ): number | null => {
    for (const key of keys) {
      const parsed = parseOptionalBodyNumber(record[key]);
      if (parsed !== null) {
        return parsed;
      }
    }
    return null;
  };
  const metricModelName = (record: Record<string, unknown>): string | null =>
    normalizeOptionalString(record.model_name) ??
    normalizeOptionalString(record.model) ??
    normalizeOptionalString(record.model_key);
  const normalizeMetricModelName = (value: string | null): string | null =>
    value?.trim().toLowerCase().replace(/[-\s]+/g, '_') ?? null;
  const globalSelection = runJsonRecord(metrics.model_selection);
  const selectedModel =
    normalizeOptionalString(metrics.model_used_for_classification_map) ??
    normalizeOptionalString(metrics.selected_model) ??
    normalizeOptionalString(metrics.best_model) ??
    normalizeOptionalString(globalSelection.selected_model) ??
    normalizeOptionalString(globalSelection.model);
  const selectedModelKey = normalizeMetricModelName(selectedModel);
  const holdoutByModel = runJsonRecord(metrics.holdout_results);
  const modelMap = runJsonRecord(metrics.models);
  const candidateRows = (() => {
    if (Object.keys(modelMap).length > 0) {
      return Object.entries(modelMap).map(([modelName, value]) => ({
        model: modelName,
        ...runJsonRecord(value),
      }));
    }
    if (Object.keys(holdoutByModel).length > 0) {
      return Object.entries(holdoutByModel).map(([modelName, value]) => ({
        model: modelName,
        ...runJsonRecord(value),
      }));
    }
    if (Array.isArray(metrics.model_comparison)) {
      return metrics.model_comparison.map((item) => runJsonRecord(item));
    }
    const selectionCandidates = Array.isArray(globalSelection.candidates)
      ? globalSelection.candidates.map((item) => runJsonRecord(item))
      : [];
    if (selectionCandidates.length > 0) {
      return selectionCandidates;
    }
    if (Array.isArray(metrics.cv_results)) {
      return metrics.cv_results
        .map((item) => runJsonRecord(item))
        .filter((item) => metricModelName(item) !== null);
    }
    return [
      {
        model_name:
          selectedModel ??
          normalizeOptionalString(metrics.model_name) ??
          'AI pipeline',
        overall_accuracy: metrics.overall_accuracy ?? metrics.accuracy ?? null,
        macro_f1: metrics.macro_f1 ?? metrics.macroF1 ?? null,
        weighted_f1: metrics.weighted_f1 ?? metrics.weightedF1 ?? null,
      },
    ];
  })();
  const rows = candidateRows.map((row) => {
    const modelName = metricModelName(row);
    const holdout = modelName ? runJsonRecord(holdoutByModel[modelName]) : {};
    return {
      ...holdout,
      ...row,
      model_name: modelName ?? normalizeOptionalString(row.model_name) ?? 'AI pipeline',
    };
  });
  const highestAccuracy = rows
    .map((row) => ({
      modelName: metricModelName(row),
      accuracy: metricNumber(row, [
        'overall_accuracy',
        'accuracy',
        'holdout_overall_accuracy',
        'holdout_oa',
        'validation_accuracy',
        'oa_mean',
      ]),
    }))
    .filter((row): row is { modelName: string; accuracy: number } =>
      row.modelName !== null && row.accuracy !== null,
    )
    .sort((left, right) => right.accuracy - left.accuracy)[0];
  const bestBalanced =
    selectedModel ??
    normalizeOptionalString(globalSelection.selected_model) ??
    normalizeOptionalString(globalSelection.model) ??
    normalizeOptionalString(metrics.best_balanced_model);
  const modelMetricsSummary = {
    run_id: metrics.run_id ?? runId,
    selected_model: selectedModel ?? bestBalanced ?? null,
    best_balanced_model: bestBalanced ?? null,
    highest_accuracy_model: highestAccuracy?.modelName ?? null,
    model_selection: globalSelection,
    models: Object.fromEntries(
      rows
        .map((row) => [metricModelName(row), row] as const)
        .filter((entry): entry is [string, Record<string, unknown>] => entry[0] !== null),
    ),
    evaluation_method: metrics.evaluation_method ?? 'spatial_holdout_plus_spatial_cv',
  };
  const selectedClasses = Array.isArray(metrics.selected_classes)
    ? metrics.selected_classes.map(String).filter((value) => value.trim().length > 0)
    : [];
  const fallbackClassLabels = selectedClasses.length > 0
    ? selectedClasses
    : Array.isArray(metrics.classes)
      ? metrics.classes.map(String).filter((value) => value.trim().length > 0)
      : rows
          .flatMap((row) => {
            const labels = row.confusion_matrix_labels;
            return Array.isArray(labels) ? labels.map(String) : [];
          })
          .filter((value, index, values) =>
            value.trim().length > 0 && values.indexOf(value) === index,
          );
  const hasMetricRows = (value: unknown): boolean => {
    if (Array.isArray(value)) {
      return value.length > 0;
    }
    const record = runJsonRecord(value);
    const rowsValue = record.rows;
    return Array.isArray(rowsValue) && rowsValue.length > 0;
  };
  const nonEmptyMetricRows = (value: unknown): unknown | undefined =>
    hasMetricRows(value) ? value : undefined;
  const nonEmptyArray = (value: unknown): unknown[] | undefined =>
    Array.isArray(value) && value.length > 0 ? value : undefined;
  const confusionMatrixFrom = (value: unknown): unknown => {
    if (!Array.isArray(value)) {
      return value;
    }
    const rows = value
      .map((rawRow, index) => {
        if (!Array.isArray(rawRow)) {
          return null;
        }
        const actual = fallbackClassLabels[index] ?? `Class ${index + 1}`;
        const row: Record<string, unknown> = { actual };
        let total = 0;
        rawRow.forEach((rawCount, predictedIndex) => {
          const label = fallbackClassLabels[predictedIndex] ?? `Class ${predictedIndex + 1}`;
          const count = Number.parseInt(String(rawCount ?? 0), 10);
          const safeCount = Number.isFinite(count) ? count : 0;
          row[label] = safeCount;
          total += safeCount;
        });
        row.total = total;
        return row;
      })
      .filter((row): row is Record<string, unknown> => row !== null);
    return { labels: fallbackClassLabels, rows };
  };
  await query(`DELETE FROM ai_run_metric WHERE ai_run_id = $1`, [runId]);
  let inserted = 0;
  for (const row of rows) {
    const baseRecord = runJsonRecord(row);
    const record: Record<string, unknown> = {
      ...baseRecord,
      ...(baseRecord.model_selection === undefined && Object.keys(globalSelection).length > 0
        ? { model_selection: globalSelection }
        : {}),
      ...(baseRecord.selection_explanation === undefined &&
      globalSelection.selection_explanation !== undefined
        ? { selection_explanation: globalSelection.selection_explanation }
        : {}),
    };
    const modelName =
      normalizeOptionalString(record.model_name) ??
      normalizeOptionalString(record.model) ??
      'AI pipeline';
    const modelKey = normalizeMetricModelName(modelName);
    const isSelectedModel = modelKey !== null && modelKey === selectedModelKey;
    const confusionMatrix =
      confusionMatrixFrom(
        (isSelectedModel
          ? nonEmptyMetricRows(metrics.confusion_matrix) ??
            nonEmptyMetricRows(metrics.confusionMatrix)
          : undefined) ??
          nonEmptyMetricRows(record.confusion_matrix) ??
          record.holdout_confusion_matrix,
      ) ?? {};
    const featureImportance =
      (isSelectedModel
        ? nonEmptyArray(metrics.feature_importance) ?? nonEmptyArray(metrics.featureImportance)
        : undefined) ??
      nonEmptyArray(record.feature_importance) ??
      [];
    await query(
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
        modelName,
        metricNumber(record, [
          'overall_accuracy',
          'accuracy',
          'holdout_overall_accuracy',
          'holdout_oa',
          'validation_accuracy',
          'oa_mean',
        ]),
        metricNumber(record, ['macro_f1', 'macroF1', 'holdout_f1_macro', 'f1_mean']),
        metricNumber(record, [
          'weighted_f1',
          'weightedF1',
          'holdout_f1_weighted',
          'f1_weighted',
          'weighted_f1_score',
        ]),
        JSON.stringify({
          ...record,
          selected_model: selectedModel ?? null,
          selected_by_composite: isSelectedModel,
        }),
        JSON.stringify(confusionMatrix),
        JSON.stringify(featureImportance),
      ],
    );
    inserted += 1;
  }
  await query(
    `UPDATE ai_run
     SET selected_model = COALESCE($2, selected_model),
         metadata = metadata || $3::jsonb,
         updated_at = NOW()
     WHERE id = $1`,
    [
      runId,
      selectedModel ?? null,
      JSON.stringify({
        selected_model: selectedModel ?? null,
        model_metrics_summary: modelMetricsSummary,
        best_balanced_model: modelMetricsSummary.best_balanced_model,
        highest_accuracy_model: modelMetricsSummary.highest_accuracy_model,
        ...(selectedClasses.length > 0 ? { selected_classes: selectedClasses } : {}),
      }),
    ],
  );
  return inserted;
};

const handleAiRunCallback = async (req: Request, res: Response): Promise<void> => {
  const aiServerClient = createAiServerClient();
  const expectedSecret = aiServerClient.callbackSecret();
  const providedSecret =
    normalizeOptionalString(req.header('x-ai-callback-secret')) ??
    normalizeOptionalString(req.body?.callback_secret);
  if (!expectedSecret || providedSecret !== expectedSecret) {
    await query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       SELECT $1, 'warning', 'Rejected AI server callback with invalid secret.', $2::jsonb
       WHERE EXISTS (SELECT 1 FROM ai_run WHERE id = $1)`,
      [
        req.params.runId,
        JSON.stringify({
          phase: 'ai_server_callback',
          rejected: true,
          reason: 'invalid_secret',
        }),
      ],
    );
    throw new AppError('Invalid AI callback secret.', 401);
  }

  const body = req.body ?? {};
  const runId = normalizeOptionalString(body.run_id) ?? req.params.runId;
  if (runId !== req.params.runId) {
    throw new AppError('AI callback run_id does not match route run id.', 400);
  }
  const runResult = await query(
    `SELECT id, project_id
     FROM ai_run
     WHERE id = $1`,
    [runId],
  );
  if (runResult.rows.length === 0) {
    throw new AppError('AI run not found', 404);
  }
  const run = runResult.rows[0];
  const callbackProjectId = normalizeOptionalString(body.project_id);
  if (callbackProjectId && callbackProjectId !== run.project_id) {
    throw new AppError('AI callback project_id does not match the run project.', 400);
  }

  const payload: AiServerStatusPayload = {
    run_id: runId,
    project_id: run.project_id,
    status: normalizeOptionalString(body.status) ?? 'running',
    stage: normalizeOptionalString(body.stage),
    progress: parseOptionalBodyNumber(body.progress),
    message: normalizeOptionalString(body.message),
    metrics: body.metrics,
    artifacts: body.artifacts,
    counts: body.counts,
    error: body.error,
    settings: body.settings,
    dry_run: body.dry_run === true,
  };
  const updated = await updateAiRunFromServerPayload(runId, payload);
  const metricsRegistered = await insertCallbackMetricRows(runId, body.metrics);
  const callbackStatus = normalizeAiServerRunStatus(payload.status);
  const callbackMessage =
    publicAiRunMessage(payload.message, payload.error) ?? 'AI server callback received.';
  await query(
    `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
     VALUES ($1, $2::ai_run_log_level, $3, $4::jsonb)`,
    [
      runId,
      callbackStatus === 'failed' ? 'error' : 'info',
      callbackMessage,
      JSON.stringify({
        phase: 'ai_server_callback',
        status: callbackStatus,
        stage: payload.stage ?? null,
        progress: payload.progress ?? null,
        metrics_registered: metricsRegistered,
      }),
    ],
  );

  res.json({
    success: true,
    message: 'AI run callback accepted.',
    data: normalizeRunRow(updated),
  });
};

const retrainCheckProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  const { projectId, runId } = req.params;
  await getProjectOrFail(projectId);
  const settings = await getEffectiveAiSettings(projectId);
  if (runId) {
    await loadProjectAiRunOrFail(projectId, runId);
  }
  const summaryResult = await query(
    `SELECT
       COUNT(*) FILTER (
         WHERE t.status = 'accepted'
            OR t.review_decision = 'accepted'
       )::int AS approved_count,
       COUNT(*) FILTER (
         WHERE t.status = 'rejected'
            OR t.review_decision = 'rejected'
       )::int AS rejected_count,
       COUNT(*) FILTER (
         WHERE s.result = 'wrong_class'
            AND COALESCE(s.corrected_class, '') <> ''
       )::int AS corrected_count
     FROM ai_prediction_validation_task t
     LEFT JOIN ai_prediction_validation_submission s
       ON s.validation_task_id = t.id
      AND s.status = 'accepted'
     WHERE t.project_id = $1
       AND ($2::uuid IS NULL OR t.ai_run_id = $2)`,
    [projectId, runId ?? null],
  );
  const trainingSamplesResult = await query(
    `SELECT COUNT(*)::int AS new_training_samples_count
     FROM spatial_feature
     WHERE project_id = $1
       AND source IN ('ai', 'ai_validation')
       AND attributes->>'useForFutureTraining' = 'true'`,
    [projectId],
  );
  const validationSummary = {
    ...summaryResult.rows[0],
    new_training_samples_count:
      Number(trainingSamplesResult.rows[0]?.new_training_samples_count ?? 0),
  };
  const aiServerClient = createAiServerClient();
  if (!aiServerClient.isConfigured()) {
    throw new AppError('AI server URL is not configured. Set AI_SERVER_URL before checking retraining.', 503);
  }
  const result = await aiServerClient.checkRetrain({
    project_id: projectId,
    run_id: runId ?? null,
    settings: {
      confidence_threshold: settings.confidence_threshold,
      model_preferences: settings.model_preferences ?? {},
    },
    validation_summary: validationSummary,
  });
  res.json({
    success: true,
    data: {
      ...result,
      validation_summary: validationSummary,
    },
  });
};

const listAiRunMetrics = async (req: Request, res: Response): Promise<void> => {
  const run = await assertRunReadable(req.params.runId, req.user as Express.UserContext);
  const result = await query(
    `SELECT id,
            ai_run_id,
            model_name,
            overall_accuracy,
            macro_f1,
            weighted_f1,
            metrics,
            confusion_matrix,
            feature_importance,
            created_at
     FROM ai_run_metric
     WHERE ai_run_id = $1
     ORDER BY created_at DESC`,
    [run.id],
  );

  res.json({
    success: true,
    data: result.rows,
  });
};

const listAiRunLayers = async (req: Request, res: Response): Promise<void> => {
  const run = await assertRunReadable(req.params.runId, req.user as Express.UserContext);
  const result = await query(
    `SELECT id,
            ai_run_id,
            project_id,
            layer_type,
            status,
            name,
            description,
            storage_path,
            asset_id,
            crs,
            ST_AsGeoJSON(bounds)::json AS bounds,
            style,
            published_at,
            published_by,
            created_at,
            updated_at
     FROM ai_output_layer
     WHERE ai_run_id = $1
       AND layer_type = 'classification'
     ORDER BY created_at DESC`,
    [run.id],
  );

  res.json({
    success: true,
    data: result.rows,
  });
};

const listProjectPublishedAiLayers = async (req: Request, res: Response): Promise<void> => {
  const user = req.user as Express.UserContext;
  await assertProjectReadableForAiLayer(req.params.projectId, user);
  const settings = await getEffectiveAiSettings(req.params.projectId);
  if (!settings.is_enabled) {
    res.json({
      success: true,
      data: [],
    });
    return;
  }
  const result = await query(
    `SELECT l.id,
            l.ai_run_id,
            l.project_id,
            l.layer_type,
            l.status,
            COALESCE(NULLIF(BTRIM(l.name), ''), ar.published_layer_name, ar.display_name) AS name,
            l.description,
            NULL::text AS storage_path,
            l.asset_id,
            l.crs,
            ST_AsGeoJSON(l.bounds)::json AS bounds,
            l.style,
            l.published_at,
            l.published_by,
            COUNT(p.id)::int AS prediction_count,
            ar.display_name AS run_display_name,
            ar.is_dry_run,
            ar.prediction_count AS run_prediction_count,
            l.created_at,
            l.updated_at
     FROM ai_output_layer l
     JOIN ai_run ar ON ar.id = l.ai_run_id
     LEFT JOIN ai_prediction_feature p ON p.ai_output_layer_id = l.id
     WHERE l.project_id = $1
       AND l.status = 'published'
       AND l.published_at IS NOT NULL
       AND l.layer_type = 'classification'
       AND ar.published_at IS NOT NULL
       AND ar.unpublished_at IS NULL
     GROUP BY l.id, ar.id
     ORDER BY l.published_at DESC
     LIMIT 1`,
    [req.params.projectId],
  );

  res.json({
    success: true,
    data: result.rows,
  });
};

const resolveRegisteredAiLayerGeoJsonPath = ({
  storagePath,
  outputRoot,
}: {
  storagePath: string;
  outputRoot: string | null;
}): string => {
  if (!outputRoot) {
    throw new AppError('AI pipeline output root is not configured.', 503);
  }

  const rawPath = storagePath.trim();
  if (!rawPath || rawPath.includes('\0')) {
    throw new AppError('AI output layer path is invalid.', 400);
  }

  const posixPath = rawPath.replace(/\\/g, '/');
  if (posixPath.split('/').includes('..')) {
    throw new AppError('AI output layer path traversal is not allowed.', 400);
  }

  if (!posixPath.toLowerCase().endsWith('.geojson')) {
    throw new AppError('AI output layer does not reference a GeoJSON preview output file.', 400);
  }

  const resolvedOutputRoot = path.resolve(outputRoot);
  const relativeArtifactPath = posixPath.startsWith('outputs/')
    ? posixPath.slice('outputs/'.length)
    : posixPath;
  const candidatePath = path.isAbsolute(rawPath)
    ? path.resolve(rawPath)
    : path.resolve(resolvedOutputRoot, relativeArtifactPath);
  const relativeToOutputRoot = path.relative(resolvedOutputRoot, candidatePath);
  if (
    !relativeToOutputRoot ||
    relativeToOutputRoot.startsWith('..') ||
    path.isAbsolute(relativeToOutputRoot)
  ) {
    throw new AppError('AI output layer path is outside the configured output directory.', 400);
  }

  return candidatePath;
};

const resolveConfiguredAiOutputRoot = (pipelineRoot: string | null): string | null => {
  const explicitOutputRoot = process.env.AI_PIPELINE_OUTPUT_ROOT?.trim();
  if (explicitOutputRoot) {
    return path.resolve(explicitOutputRoot);
  }
  if (
    process.platform !== 'win32' &&
    fsSync.existsSync(DEV_CONTAINER_AI_OUTPUT_ROOT) &&
    fsSync.statSync(DEV_CONTAINER_AI_OUTPUT_ROOT).isDirectory()
  ) {
    return DEV_CONTAINER_AI_OUTPUT_ROOT;
  }
  return pipelineRoot ? path.resolve(pipelineRoot, 'outputs') : null;
};

type AiLayerDetail = 'overview' | 'full';
type AiLayerGeometry = 'aggregate' | 'simplified' | 'full';
type AiLayerBounds = {
  west: number;
  south: number;
  east: number;
  north: number;
};

type AiLayerFeatureQueryOptions = {
  detail: AiLayerDetail;
  geometry: AiLayerGeometry;
  limit: number;
  page: number;
  offset: number;
  search: string | null;
  classLabel: string | null;
  featureId: string | null;
  bounds: AiLayerBounds | null;
  zoom: number | null;
  confidenceMin: number | null;
  confidenceMax: number | null;
  uncertaintyMin: number | null;
  uncertaintyMax: number | null;
};

type AiPredictionLayerStats = {
  totalCount: number;
  visibleCount: number;
  totalAreaM2: number;
  totalAreaHectares: number;
  countByClass: Record<string, number>;
  areaByClass: Record<string, number>;
  layerBounds: AiLayerBounds | null;
  geometryTypes: string[];
};

const parseAiLayerBounds = (value: unknown): AiLayerBounds | null => {
  const raw = normalizeOptionalString(value);
  if (!raw) {
    return null;
  }
  const parts = raw.split(',').map((part) => Number.parseFloat(part.trim()));
  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part))) {
    throw new AppError('AI layer bounds must be west,south,east,north.', 400);
  }
  const [west, south, east, north] = parts;
  if (west < -180 || east > 180 || south < -90 || north > 90 || west >= east || south >= north) {
    throw new AppError('AI layer bounds are invalid.', 400);
  }
  return { west, south, east, north };
};

const parseOptionalZoom = (value: unknown): number | null => {
  const raw = normalizeOptionalString(value);
  if (!raw) {
    return null;
  }
  const zoom = Number.parseFloat(raw);
  if (!Number.isFinite(zoom) || zoom < 0 || zoom > 24) {
    throw new AppError('AI layer zoom is invalid.', 400);
  }
  return zoom;
};

const parseOptionalUnitScore = (value: unknown, label: string): number | null => {
  const raw = normalizeOptionalString(value);
  if (!raw) {
    return null;
  }
  const score = Number.parseFloat(raw);
  if (!Number.isFinite(score) || score < 0 || score > 1) {
    throw new AppError(`${label} must be between 0 and 1.`, 400);
  }
  return score;
};

const parseAiLayerFeatureQuery = (req: Request): AiLayerFeatureQueryOptions => {
  const rawDetailValue = normalizeOptionalString(req.query.detail) ?? 'overview';
  const rawDetail = rawDetailValue === 'preview' ? 'overview' : rawDetailValue;
  if (rawDetail !== 'overview' && rawDetail !== 'full') {
    throw new AppError('AI layer detail must be overview or full.', 400);
  }
  const zoom = parseOptionalZoom(req.query.zoom);
  const rawGeometry = normalizeOptionalString(req.query.geometry);
  const geometry =
    rawGeometry ??
    (rawDetail === 'overview' && (zoom === null || zoom < 10)
      ? 'aggregate'
      : rawDetail === 'overview'
        ? 'simplified'
        : 'full');
  if (geometry !== 'aggregate' && geometry !== 'simplified' && geometry !== 'full') {
    throw new AppError('AI layer geometry must be aggregate, simplified, or full.', 400);
  }
  if (rawDetail === 'full' && geometry !== 'full') {
    throw new AppError('Full AI layer detail requires full geometry.', 400);
  }
  const page = parsePositiveInteger(req.query.page, 1, 100000);
  const limit = parsePositiveInteger(
    req.query.limit,
    DEFAULT_AI_LAYER_OVERVIEW_FEATURE_LIMIT,
    MAX_AI_LAYER_PREVIEW_FEATURES,
  );
  const confidenceMin = parseOptionalUnitScore(
    req.query.confidence_min ?? req.query.min_confidence,
    'AI layer confidence_min',
  );
  const confidenceMax = parseOptionalUnitScore(
    req.query.confidence_max ?? req.query.max_confidence,
    'AI layer confidence_max',
  );
  const uncertaintyMin = parseOptionalUnitScore(
    req.query.uncertainty_min ?? req.query.min_uncertainty,
    'AI layer uncertainty_min',
  );
  const uncertaintyMax = parseOptionalUnitScore(
    req.query.uncertainty_max ?? req.query.max_uncertainty,
    'AI layer uncertainty_max',
  );
  if (confidenceMin !== null && confidenceMax !== null && confidenceMin > confidenceMax) {
    throw new AppError('AI layer confidence_min cannot be greater than confidence_max.', 400);
  }
  if (uncertaintyMin !== null && uncertaintyMax !== null && uncertaintyMin > uncertaintyMax) {
    throw new AppError('AI layer uncertainty_min cannot be greater than uncertainty_max.', 400);
  }
  return {
    detail: rawDetail,
    geometry,
    limit,
    page,
    offset: (page - 1) * limit,
    search: normalizeOptionalString(req.query.q),
    classLabel: normalizeOptionalString(req.query.class_label),
    featureId: normalizeOptionalString(req.query.feature_id),
    bounds: parseAiLayerBounds(req.query.bounds),
    zoom,
    confidenceMin,
    confidenceMax,
    uncertaintyMin,
    uncertaintyMax,
  };
};

const collectGeoJsonPositions = (value: unknown, positions: Array<[number, number]>): void => {
  if (!Array.isArray(value)) {
    return;
  }
  if (
    value.length >= 2 &&
    typeof value[0] === 'number' &&
    typeof value[1] === 'number' &&
    Number.isFinite(value[0]) &&
    Number.isFinite(value[1])
  ) {
    positions.push([value[0], value[1]]);
    return;
  }
  for (const child of value) {
    collectGeoJsonPositions(child, positions);
  }
};

const featureBounds = (feature: any): AiLayerBounds | null => {
  const positions: Array<[number, number]> = [];
  collectGeoJsonPositions(feature?.geometry?.coordinates, positions);
  if (positions.length === 0) {
    return null;
  }
  let minLon = Number.POSITIVE_INFINITY;
  let minLat = Number.POSITIVE_INFINITY;
  let maxLon = Number.NEGATIVE_INFINITY;
  let maxLat = Number.NEGATIVE_INFINITY;
  for (const [lon, lat] of positions) {
    minLon = Math.min(minLon, lon);
    minLat = Math.min(minLat, lat);
    maxLon = Math.max(maxLon, lon);
    maxLat = Math.max(maxLat, lat);
  }
  return { west: minLon, south: minLat, east: maxLon, north: maxLat };
};

const boundsIntersect = (a: AiLayerBounds, b: AiLayerBounds): boolean =>
  a.west <= b.east && a.east >= b.west && a.south <= b.north && a.north >= b.south;

const layerBoundsFromFeatures = (features: any[]): AiLayerBounds | null => {
  let west = Number.POSITIVE_INFINITY;
  let south = Number.POSITIVE_INFINITY;
  let east = Number.NEGATIVE_INFINITY;
  let north = Number.NEGATIVE_INFINITY;
  for (const feature of features) {
    const bounds = featureBounds(feature);
    if (!bounds) {
      continue;
    }
    west = Math.min(west, bounds.west);
    south = Math.min(south, bounds.south);
    east = Math.max(east, bounds.east);
    north = Math.max(north, bounds.north);
  }
  if (![west, south, east, north].every(Number.isFinite)) {
    return null;
  }
  return { west, south, east, north };
};

const aiFeatureClassLabel = (feature: any): string => {
  const properties =
    feature?.properties && typeof feature.properties === 'object' ? feature.properties : {};
  return (
    normalizeOptionalString(properties.predicted_class) ??
    normalizeOptionalString(properties.predicted_class_label) ??
    normalizeOptionalString(properties.class_label) ??
    normalizeOptionalString(properties.class_name) ??
    normalizeOptionalString(properties.label) ??
    normalizeOptionalString(properties.L4_descr) ??
    'unknown'
  );
};

const aiFeatureIdentifier = (feature: any, fallbackIndex?: number): string => {
  const properties =
    feature?.properties && typeof feature.properties === 'object' ? feature.properties : {};
  return (
    normalizeOptionalString(feature?.id) ??
    normalizeOptionalString(properties.id) ??
    normalizeOptionalString(properties.feature_id) ??
    normalizeOptionalString(properties.source_feature_id) ??
    normalizeOptionalString(properties.source_id) ??
    (fallbackIndex === undefined ? '' : `ai-preview-${fallbackIndex}`)
  );
};

const incrementCount = (counts: Record<string, number>, key: string, value = 1): void => {
  counts[key] = (counts[key] ?? 0) + value;
};

const classCountsForFeatures = (features: any[]): Record<string, number> => {
  const counts: Record<string, number> = {};
  for (const feature of features) {
    incrementCount(counts, aiFeatureClassLabel(feature));
  }
  return counts;
};

const aiFeatureSearchBlob = (feature: any): string => {
  const properties =
    feature?.properties && typeof feature.properties === 'object' ? feature.properties : {};
  const values = [
    properties.predicted_class,
    properties.predicted_class_label,
    properties.dominant_class,
    properties.class_label,
    properties.class_name,
    properties.label,
    properties.model_name,
    properties.model,
  ];
  return values
    .map((value) => normalizeOptionalString(value))
    .filter((value): value is string => Boolean(value))
    .join(' ')
    .toLowerCase();
};

const aiFeatureNumericProperty = (feature: any, keys: string[]): number | null => {
  const properties =
    feature?.properties && typeof feature.properties === 'object' ? feature.properties : {};
  for (const key of keys) {
    const value = properties[key];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    if (typeof value === 'string' && value.trim().length > 0) {
      const parsed = Number.parseFloat(value);
      if (Number.isFinite(parsed)) {
        return parsed;
      }
    }
  }
  return null;
};

const filterAiLayerFeatures = (
  features: any[],
  options: {
    search: string | null;
    classLabel: string | null;
    featureId: string | null;
    confidenceMin?: number | null;
    confidenceMax?: number | null;
    uncertaintyMin?: number | null;
    uncertaintyMax?: number | null;
  },
): any[] => {
  const search = options.search?.toLowerCase() ?? null;
  const classLabel = options.classLabel?.toLowerCase() ?? null;
  const featureId = options.featureId?.toLowerCase() ?? null;
  const confidenceMin = options.confidenceMin ?? null;
  const confidenceMax = options.confidenceMax ?? null;
  const uncertaintyMin = options.uncertaintyMin ?? null;
  const uncertaintyMax = options.uncertaintyMax ?? null;
  if (
    !search &&
    !classLabel &&
    !featureId &&
    confidenceMin === null &&
    confidenceMax === null &&
    uncertaintyMin === null &&
    uncertaintyMax === null
  ) {
    return features;
  }
  return features.filter((feature, index) => {
    if (featureId && aiFeatureIdentifier(feature, index).toLowerCase() !== featureId) {
      return false;
    }
    if (classLabel && aiFeatureClassLabel(feature).toLowerCase() !== classLabel) {
      return false;
    }
    if (search && !aiFeatureSearchBlob(feature).includes(search)) {
      return false;
    }
    if (confidenceMin !== null || confidenceMax !== null) {
      const confidence = aiFeatureNumericProperty(feature, [
        'confidence',
        'confidence_score',
        'probability',
        'max_probability',
        'prediction_confidence',
        'mean_confidence',
        'confidence_mean',
        'mean',
      ]);
      if (confidence === null) {
        return false;
      }
      if (confidenceMin !== null && confidence < confidenceMin) {
        return false;
      }
      if (confidenceMax !== null && confidence > confidenceMax) {
        return false;
      }
    }
    if (uncertaintyMin !== null || uncertaintyMax !== null) {
      const uncertainty = aiFeatureNumericProperty(feature, ['uncertainty_score', 'uncertainty']);
      if (uncertainty === null) {
        return false;
      }
      if (uncertaintyMin !== null && uncertainty < uncertaintyMin) {
        return false;
      }
      if (uncertaintyMax !== null && uncertainty > uncertaintyMax) {
        return false;
      }
    }
    return true;
  });
};

const geometryTypesForFeatures = (features: any[]): string[] =>
  Array.from(
    new Set(
      features
        .map((feature) => normalizeOptionalString(feature?.geometry?.type))
        .filter((value): value is string => Boolean(value)),
    ),
  ).sort();

const overviewCoordinateBudget = (zoom: number | null): number => {
  if (zoom === null || zoom < 9) {
    return 28;
  }
  if (zoom < 11) {
    return 44;
  }
  if (zoom < 13) {
    return 72;
  }
  return 120;
};

const aggregateGridSize = (zoom: number | null): number => {
  if (zoom === null || zoom < 7) {
    return 0.18;
  }
  if (zoom < 9) {
    return 0.09;
  }
  if (zoom < 11) {
    return 0.045;
  }
  return 0.0225;
};

const aggregateAiLayerFeatures = (
  features: any[],
  options: {
    limit: number;
    offset: number;
    zoom: number | null;
  },
): {
  features: Record<string, unknown>[];
  capped: boolean;
  cap: number;
} => {
  const cellSize = aggregateGridSize(options.zoom);
  const cells = new Map<
    string,
    {
      count: number;
      classCounts: Record<string, number>;
      lonSum: number;
      latSum: number;
    }
  >();

  for (const feature of features) {
    const bounds = featureBounds(feature);
    if (!bounds) {
      continue;
    }
    const lon = (bounds.west + bounds.east) / 2;
    const lat = (bounds.south + bounds.north) / 2;
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
      continue;
    }
    const x = Math.floor(lon / cellSize);
    const y = Math.floor(lat / cellSize);
    const key = `${x}:${y}`;
    const cell = cells.get(key) ?? {
      count: 0,
      classCounts: {},
      lonSum: 0,
      latSum: 0,
    };
    cell.count += 1;
    cell.lonSum += lon;
    cell.latSum += lat;
    incrementCount(cell.classCounts, aiFeatureClassLabel(feature));
    cells.set(key, cell);
  }

  const allCells = Array.from(cells.entries()).sort((a, b) => b[1].count - a[1].count);
  const selectedCells = allCells.slice(options.offset, options.offset + options.limit);
  return {
    capped: options.offset + selectedCells.length < allCells.length,
    cap: options.limit,
    features: selectedCells.map(([key, cell]) => {
      const dominantClass =
        Object.entries(cell.classCounts).sort((a, b) => b[1] - a[1])[0]?.[0] ?? 'unknown';
      return {
        type: 'Feature',
        id: `ai-aggregate-${key}`,
        properties: {
          preview_kind: 'aggregate',
          preview_detail: 'overview',
          preview_geometry: 'aggregate',
          aggregate: true,
          aggregate_count: cell.count,
          class_counts: cell.classCounts,
          predicted_class: dominantClass,
          dominant_class: dominantClass,
        },
        geometry: {
          type: 'Point',
          coordinates: [
            Number((cell.lonSum / cell.count).toFixed(7)),
            Number((cell.latSum / cell.count).toFixed(7)),
          ],
        },
      };
    }),
  };
};

const simplifyCoordinateList = (
  coordinates: any[],
  maxPoints: number,
  closeRing = false,
): any[] => {
  if (coordinates.length <= maxPoints) {
    return coordinates;
  }
  const step = Math.max(1, Math.ceil(coordinates.length / Math.max(2, maxPoints)));
  const simplified: any[] = [];
  for (let index = 0; index < coordinates.length; index += step) {
    simplified.push(coordinates[index]);
  }
  const last = coordinates[coordinates.length - 1];
  if (simplified[simplified.length - 1] !== last) {
    simplified.push(last);
  }
  if (closeRing && simplified.length > 0) {
    const first = simplified[0];
    const tail = simplified[simplified.length - 1];
    if (
      Array.isArray(first) &&
      Array.isArray(tail) &&
      (first[0] !== tail[0] || first[1] !== tail[1])
    ) {
      simplified.push(first);
    }
  }
  return simplified;
};

const simplifyGeometry = (geometry: any, maxPoints: number): any => {
  if (!geometry || typeof geometry !== 'object') {
    return geometry ?? null;
  }
  const type = normalizeOptionalString(geometry.type);
  const coordinates = geometry.coordinates;
  if (!type || !Array.isArray(coordinates)) {
    return geometry;
  }
  switch (type) {
    case 'LineString':
      return { ...geometry, coordinates: simplifyCoordinateList(coordinates, maxPoints) };
    case 'MultiLineString':
      return {
        ...geometry,
        coordinates: coordinates.map((line: any) =>
          Array.isArray(line) ? simplifyCoordinateList(line, maxPoints) : line,
        ),
      };
    case 'Polygon':
      return {
        ...geometry,
        coordinates: coordinates.map((ring: any) =>
          Array.isArray(ring) ? simplifyCoordinateList(ring, maxPoints, true) : ring,
        ),
      };
    case 'MultiPolygon':
      return {
        ...geometry,
        coordinates: coordinates.map((polygon: any) =>
          Array.isArray(polygon)
            ? polygon.map((ring: any) =>
                Array.isArray(ring) ? simplifyCoordinateList(ring, maxPoints, true) : ring,
              )
            : polygon,
        ),
      };
    default:
      return geometry;
  }
};

const overviewPropertiesFor = (feature: any): Record<string, unknown> => {
  const properties =
    feature?.properties && typeof feature.properties === 'object' ? feature.properties : {};
  const allowedKeys = [
    'id',
    'prediction_feature_id',
    'artifact_feature_id',
    'feature_id',
    'source_feature_id',
    'predicted_class',
    'predicted_class_label',
    'class_name',
    'class_label',
    'label',
    'L4_descr',
    'confidence',
    'confidence_score',
    'probability',
    'max_probability',
    'prediction_confidence',
    'mean_confidence',
    'confidence_mean',
    'uncertainty_score',
    'model_name',
    'model',
    'run_id',
    'source',
    'status',
    'area',
    'area_ha',
    'limitation_note',
    'not_official_field_data',
  ];
  return Object.fromEntries(
    allowedKeys
      .filter((key) => properties[key] !== undefined && properties[key] !== null)
      .map((key) => [key, properties[key]]),
  );
};

const buildAiLayerFeatureCollection = (
  parsed: any,
  options: {
    detail: AiLayerDetail;
    geometry: AiLayerGeometry;
    limit: number;
    offset: number;
    search: string | null;
    classLabel: string | null;
    featureId: string | null;
    bounds: AiLayerBounds | null;
    zoom: number | null;
    confidenceMin?: number | null;
    confidenceMax?: number | null;
    uncertaintyMin?: number | null;
    uncertaintyMax?: number | null;
  },
): {
  featureCollection: Record<string, unknown>;
  returnedFeatureCount: number;
  sourceFeatureCount: number;
  matchingFeatureCount: number;
  capped: boolean;
  cap: number;
  layerBounds: AiLayerBounds | null;
  classCounts: Record<string, number>;
  geometryTypes: string[];
} => {
  const sourceFeatures = Array.isArray(parsed.features) ? parsed.features : [];
  const filteredFeatures = filterAiLayerFeatures(sourceFeatures, {
    search: options.search,
    classLabel: options.classLabel,
    featureId: options.featureId,
    confidenceMin: options.confidenceMin,
    confidenceMax: options.confidenceMax,
    uncertaintyMin: options.uncertaintyMin,
    uncertaintyMax: options.uncertaintyMax,
  });
  const boundedFeatures = options.bounds
    ? filteredFeatures.filter((feature: any) => {
        const bounds = featureBounds(feature);
        return bounds ? boundsIntersect(bounds, options.bounds as AiLayerBounds) : false;
      })
    : filteredFeatures;
  const layerBounds = layerBoundsFromFeatures(sourceFeatures);
  const classCounts = classCountsForFeatures(sourceFeatures);
  const geometryTypes = geometryTypesForFeatures(sourceFeatures);
  if (options.geometry === 'aggregate') {
    const aggregate = aggregateAiLayerFeatures(boundedFeatures, {
      limit: options.limit,
      offset: options.offset,
      zoom: options.zoom,
    });
    return {
      featureCollection: {
        type: 'FeatureCollection',
        features: aggregate.features,
      },
      returnedFeatureCount: aggregate.features.length,
      sourceFeatureCount: sourceFeatures.length,
      matchingFeatureCount: boundedFeatures.length,
      capped: aggregate.capped,
      cap: aggregate.cap,
      layerBounds,
      classCounts,
      geometryTypes,
    };
  }
  const selectedFeatures = boundedFeatures.slice(options.offset, options.offset + options.limit);
  const coordinateBudget = overviewCoordinateBudget(options.zoom);
  const capped = options.offset + selectedFeatures.length < boundedFeatures.length;
  const features = selectedFeatures.map((feature: any, index: number) => {
    const properties = {
      ...(options.detail === 'overview'
        ? overviewPropertiesFor(feature)
        : feature?.properties && typeof feature.properties === 'object'
          ? feature.properties
          : {}),
      preview_detail: options.detail,
      preview_geometry: options.geometry,
    };
    return {
      type: 'Feature',
      id: aiFeatureIdentifier(feature, options.offset + index),
      properties,
      geometry:
        options.geometry === 'simplified'
          ? simplifyGeometry(feature?.geometry, coordinateBudget)
          : (feature?.geometry ?? null),
    };
  });
  return {
    featureCollection: {
      type: 'FeatureCollection',
      features,
    },
    returnedFeatureCount: features.length,
    sourceFeatureCount: sourceFeatures.length,
    matchingFeatureCount: boundedFeatures.length,
    capped,
    cap: options.limit,
    layerBounds,
    classCounts,
    geometryTypes,
  };
};

const loadPreviewableAiLayerForUser = async (layerId: string, user: Express.UserContext) => {
  const layerResult = await query(
    `SELECT l.id,
            l.ai_run_id,
            l.project_id,
            l.layer_type,
            l.status,
            l.name,
            l.description,
            l.storage_path,
            l.crs,
            l.published_at,
            ar.project_id AS run_project_id
     FROM ai_output_layer l
     JOIN ai_run ar ON ar.id = l.ai_run_id
     WHERE l.id = $1`,
    [layerId],
  );

  if (layerResult.rows.length === 0) {
    throw new AppError('AI output layer not found', 404);
  }

  const layer = layerResult.rows[0];
  if (layer.project_id !== layer.run_project_id) {
    throw new AppError('AI output layer project mismatch.', 400);
  }
  if (!previewableLayerTypes.has(layer.layer_type)) {
    throw new AppError('This AI output layer is not a map-preview layer.', 400);
  }
  const protectedSuperAdmin = isProtectedSuperAdminUser(user);
  const viewerPublished = layer.status === 'published' && layer.published_at !== null;
  if (protectedSuperAdmin) {
    if (!previewableLayerStatuses.has(layer.status)) {
      throw new AppError('This AI output layer is not available for preview.', 403);
    }
  } else {
    if (!viewerPublished) {
      throw new AppError('This AI output layer is not published.', 403);
    }
    const settings = await getEffectiveAiSettings(layer.project_id);
    if (!settings.is_enabled) {
      throw new AppError('AI layers are disabled for this project.', 403);
    }
    await assertProjectReadableForAiLayer(layer.project_id, user);
  }

  return {
    layer,
    viewerPublished,
  };
};

const predictionFeaturePropertiesFromRow = (row: any): Record<string, unknown> => {
  const metadata = row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
  const originalProperties =
    metadata.properties && typeof metadata.properties === 'object'
      ? (metadata.properties as Record<string, unknown>)
      : {};
  return {
    ...originalProperties,
    id: row.artifact_feature_id,
    prediction_feature_id: row.id,
    artifact_feature_id: row.artifact_feature_id,
    predicted_class: row.predicted_class,
    confidence: row.confidence,
    uncertainty_score: row.uncertainty_score,
    model_name: row.model_name,
    run_id: row.ai_run_id,
    source: row.source ?? 'ai_prediction',
    status: row.status,
    layer_id: row.ai_output_layer_id,
    source_resolution_m: row.source_resolution_m ?? row.metadata?.properties?.source_resolution_m ?? null,
    processed_area_m2: row.processed_area_m2 ?? row.metadata?.properties?.processed_area_m2 ?? null,
    area_change_percent: row.area_change_percent ?? row.metadata?.properties?.area_change_percent ?? null,
    processing_method: row.processing_method ?? row.metadata?.properties?.processing_method ?? null,
    geometry_quality: row.geometry_quality ?? row.metadata?.properties?.geometry_quality ?? null,
    not_official_field_data: true,
    no_spatial_feature_writes: true,
  };
};

const predictionRowsToGeoJsonFeatures = (rows: any[]): Record<string, unknown>[] =>
  rows.map((row) => ({
    type: 'Feature',
    id: row.artifact_feature_id,
    properties: predictionFeaturePropertiesFromRow(row),
    geometry: row.geometry,
  }));

const appendPredictionFeatureFilters = (
  conditions: string[],
  params: unknown[],
  featureQuery: AiLayerFeatureQueryOptions,
  options: {
    includeClassLabel?: boolean;
    includeSearch?: boolean;
    includeFeatureId?: boolean;
    includeBounds?: boolean;
    includeScores?: boolean;
  } = {},
): void => {
  const {
    includeClassLabel = true,
    includeSearch = true,
    includeFeatureId = true,
    includeBounds = true,
    includeScores = true,
  } = options;
  if (includeClassLabel && featureQuery.classLabel) {
    params.push(featureQuery.classLabel.toLowerCase());
    conditions.push(`LOWER(p.predicted_class) = $${params.length}`);
  }
  if (includeFeatureId && featureQuery.featureId) {
    params.push(featureQuery.featureId.toLowerCase());
    conditions.push(`LOWER(p.artifact_feature_id) = $${params.length}`);
  }
  if (includeSearch && featureQuery.search) {
    params.push(`%${featureQuery.search.toLowerCase()}%`);
    conditions.push(
      `LOWER(CONCAT_WS(' ', p.predicted_class, p.model_name, p.artifact_feature_id, p.status)) LIKE $${params.length}`,
    );
  }
  if (includeScores && featureQuery.confidenceMin !== null) {
    params.push(featureQuery.confidenceMin);
    conditions.push(`p.confidence IS NOT NULL AND p.confidence >= $${params.length}`);
  }
  if (includeScores && featureQuery.confidenceMax !== null) {
    params.push(featureQuery.confidenceMax);
    conditions.push(`p.confidence IS NOT NULL AND p.confidence <= $${params.length}`);
  }
  if (includeScores && featureQuery.uncertaintyMin !== null) {
    params.push(featureQuery.uncertaintyMin);
    conditions.push(`p.uncertainty_score IS NOT NULL AND p.uncertainty_score >= $${params.length}`);
  }
  if (includeScores && featureQuery.uncertaintyMax !== null) {
    params.push(featureQuery.uncertaintyMax);
    conditions.push(`p.uncertainty_score IS NOT NULL AND p.uncertainty_score <= $${params.length}`);
  }
  if (includeBounds && featureQuery.bounds) {
    const { west, south, east, north } = featureQuery.bounds;
    params.push(west, south, east, north);
    const westIndex = params.length - 3;
    const southIndex = params.length - 2;
    const eastIndex = params.length - 1;
    const northIndex = params.length;
    conditions.push(
      `COALESCE(p.processed_geom, p.geom) && ST_MakeEnvelope($${westIndex}, $${southIndex}, $${eastIndex}, $${northIndex}, 4326)`,
    );
    conditions.push(
      `ST_Intersects(COALESCE(p.processed_geom, p.geom), ST_MakeEnvelope($${westIndex}, $${southIndex}, $${eastIndex}, $${northIndex}, 4326))`,
    );
  }
};

const predictionWhereSql = (
  layerId: string,
  featureQuery: AiLayerFeatureQueryOptions,
  options: Parameters<typeof appendPredictionFeatureFilters>[3] = {},
): { where: string; params: unknown[] } => {
  const params: unknown[] = [layerId];
  const conditions = ['p.ai_output_layer_id = $1'];
  appendPredictionFeatureFilters(conditions, params, featureQuery, options);
  return {
    where: conditions.join(' AND '),
    params,
  };
};

const recordFromKeyValueRows = (
  rows: any[],
  keyColumn: string,
  valueColumn: string,
): Record<string, number> => {
  const result: Record<string, number> = {};
  for (const row of rows) {
    const key = normalizeOptionalString(row[keyColumn]) ?? 'unknown';
    result[key] = Number(row[valueColumn] ?? 0);
  }
  return result;
};

const loadPredictionLayerStats = async (
  layerId: string,
  featureQuery: AiLayerFeatureQueryOptions,
): Promise<AiPredictionLayerStats> => {
  const totalWhere = predictionWhereSql(layerId, featureQuery, { includeBounds: false });
  const visibleWhere = predictionWhereSql(layerId, featureQuery, { includeBounds: true });
  const classWhere = predictionWhereSql(layerId, featureQuery, {
    includeClassLabel: false,
    includeFeatureId: false,
    includeBounds: false,
  });

  const [totalResult, visibleResult, classResult, boundsResult] = await Promise.all([
    query(
      `SELECT COUNT(*)::int AS total_count,
              COALESCE(SUM(ST_Area(ST_Transform(COALESCE(p.processed_geom, p.geom), 32636))), 0)::float8 AS total_area_m2
       FROM ai_prediction_feature p
       WHERE ${totalWhere.where}`,
      totalWhere.params,
    ),
    query(
      `SELECT COUNT(*)::int AS visible_count
       FROM ai_prediction_feature p
       WHERE ${visibleWhere.where}`,
      visibleWhere.params,
    ),
    query(
      `SELECT COALESCE(NULLIF(TRIM(p.predicted_class), ''), 'unknown') AS class_label,
              COUNT(*)::int AS feature_count,
              COALESCE(SUM(ST_Area(ST_Transform(COALESCE(p.processed_geom, p.geom), 32636))), 0)::float8 AS area_m2
       FROM ai_prediction_feature p
       WHERE ${classWhere.where}
       GROUP BY COALESCE(NULLIF(TRIM(p.predicted_class), ''), 'unknown')
       ORDER BY class_label ASC`,
      classWhere.params,
    ),
    query(
      `WITH layer_features AS (
         SELECT COALESCE(p.processed_geom, p.geom) AS geom
         FROM ai_prediction_feature p
         WHERE p.ai_output_layer_id = $1
       ),
       extent AS (
         SELECT ST_Extent(geom)::box3d AS box,
                ARRAY_AGG(DISTINCT ST_GeometryType(geom)) FILTER (WHERE geom IS NOT NULL) AS geometry_types
         FROM layer_features
       )
       SELECT CASE WHEN box IS NULL THEN NULL ELSE ST_XMin(box)::float8 END AS west,
              CASE WHEN box IS NULL THEN NULL ELSE ST_YMin(box)::float8 END AS south,
              CASE WHEN box IS NULL THEN NULL ELSE ST_XMax(box)::float8 END AS east,
              CASE WHEN box IS NULL THEN NULL ELSE ST_YMax(box)::float8 END AS north,
              COALESCE(geometry_types, ARRAY[]::text[]) AS geometry_types
       FROM extent`,
      [layerId],
    ),
  ]);

  const totalCount = Number(totalResult.rows[0]?.total_count ?? 0);
  const totalAreaM2 = Number(totalResult.rows[0]?.total_area_m2 ?? 0);
  const boundsRow = boundsResult.rows[0] ?? {};
  const west = Number(boundsRow.west);
  const south = Number(boundsRow.south);
  const east = Number(boundsRow.east);
  const north = Number(boundsRow.north);
  const layerBounds =
    [west, south, east, north].every((value) => Number.isFinite(value)) &&
    west < east &&
    south < north
      ? { west, south, east, north }
      : null;

  return {
    totalCount,
    visibleCount: Number(visibleResult.rows[0]?.visible_count ?? 0),
    totalAreaM2,
    totalAreaHectares: totalAreaM2 / 10000,
    countByClass: recordFromKeyValueRows(classResult.rows, 'class_label', 'feature_count'),
    areaByClass: recordFromKeyValueRows(classResult.rows, 'class_label', 'area_m2'),
    layerBounds,
    geometryTypes: Array.isArray(boundsRow.geometry_types)
      ? boundsRow.geometry_types
          .map((value: unknown) => normalizeOptionalString(value))
          .filter((value: string | null): value is string => Boolean(value))
          .sort()
      : [],
  };
};

const predictionLayerStatsFromRows = (
  rows: any[],
  featureQuery: AiLayerFeatureQueryOptions,
): AiPredictionLayerStats => {
  const features = predictionRowsToGeoJsonFeatures(rows);
  const totalFeatures = filterAiLayerFeatures(features, {
    search: featureQuery.search,
    classLabel: featureQuery.classLabel,
    featureId: featureQuery.featureId,
    confidenceMin: featureQuery.confidenceMin,
    confidenceMax: featureQuery.confidenceMax,
    uncertaintyMin: featureQuery.uncertaintyMin,
    uncertaintyMax: featureQuery.uncertaintyMax,
  });
  const visibleFeatures = featureQuery.bounds
    ? totalFeatures.filter((feature) => {
        const bounds = featureBounds(feature);
        return bounds ? boundsIntersect(bounds, featureQuery.bounds as AiLayerBounds) : false;
      })
    : totalFeatures;
  const classFeatures = filterAiLayerFeatures(features, {
    search: featureQuery.search,
    classLabel: null,
    featureId: null,
    confidenceMin: featureQuery.confidenceMin,
    confidenceMax: featureQuery.confidenceMax,
    uncertaintyMin: featureQuery.uncertaintyMin,
    uncertaintyMax: featureQuery.uncertaintyMax,
  });
  const countByClass: Record<string, number> = {};
  const areaByClass: Record<string, number> = {};
  for (const feature of classFeatures) {
    const classLabel = aiFeatureClassLabel(feature);
    incrementCount(countByClass, classLabel);
    areaByClass[classLabel] =
      (areaByClass[classLabel] ?? 0) +
      (aiFeatureNumericProperty(feature, ['processed_area_m2', 'area_m2', 'area']) ?? 0);
  }
  const totalAreaM2 = totalFeatures.reduce(
    (sum, feature) =>
      sum + (aiFeatureNumericProperty(feature, ['processed_area_m2', 'area_m2', 'area']) ?? 0),
    0,
  );

  return {
    totalCount: totalFeatures.length,
    visibleCount: visibleFeatures.length,
    totalAreaM2,
    totalAreaHectares: totalAreaM2 / 10000,
    countByClass,
    areaByClass,
    layerBounds: layerBoundsFromFeatures(features),
    geometryTypes: geometryTypesForFeatures(features),
  };
};

const predictionRowsForResponseFromRows = (
  rows: any[],
  featureQuery: AiLayerFeatureQueryOptions,
): any[] => {
  const pairs = rows.map((row) => ({
    row,
    feature: predictionRowsToGeoJsonFeatures([row])[0],
  }));
  const filtered = pairs.filter(({ feature }) => {
    const matches = filterAiLayerFeatures([feature], {
      search: featureQuery.search,
      classLabel: featureQuery.classLabel,
      featureId: featureQuery.featureId,
      confidenceMin: featureQuery.confidenceMin,
      confidenceMax: featureQuery.confidenceMax,
      uncertaintyMin: featureQuery.uncertaintyMin,
      uncertaintyMax: featureQuery.uncertaintyMax,
    });
    if (matches.length === 0) {
      return false;
    }
    if (!featureQuery.bounds) {
      return true;
    }
    const bounds = featureBounds(feature);
    return bounds ? boundsIntersect(bounds, featureQuery.bounds) : false;
  });
  if (featureQuery.geometry === 'aggregate') {
    return filtered.map(({ row }) => row);
  }
  return filtered
    .slice(featureQuery.offset, featureQuery.offset + featureQuery.limit)
    .map(({ row }) => row);
};

const loadPredictionFeaturesForLayer = async (
  layerId: string,
  featureQuery?: AiLayerFeatureQueryOptions,
): Promise<any[]> => {
  const params: unknown[] = [layerId];
  const conditions = ['p.ai_output_layer_id = $1'];
  if (featureQuery) {
    appendPredictionFeatureFilters(conditions, params, featureQuery, {
      includeBounds: true,
    });
  }
  const paginate = Boolean(featureQuery && featureQuery.geometry !== 'aggregate');
  const limitSql = paginate ? `LIMIT $${params.length + 1} OFFSET $${params.length + 2}` : '';
  if (paginate && featureQuery) {
    params.push(featureQuery.limit, featureQuery.offset);
  }
  const result = await query(
    `SELECT id,
            project_id,
            ai_run_id,
            ai_output_layer_id,
            artifact_feature_id,
            ST_AsGeoJSON(COALESCE(processed_geom, geom))::json AS geometry,
            geometry_type,
            predicted_class,
            confidence,
            uncertainty_score,
            model_name,
            source,
            status,
            metadata,
            source_resolution_m,
            processed_area_m2,
            area_change_percent,
            processing_method,
            geometry_quality,
            created_at,
            updated_at
     FROM ai_prediction_feature p
     WHERE ${conditions.join(' AND ')}
     ORDER BY p.created_at ASC, p.artifact_feature_id ASC
     ${limitSql}`,
    params,
  );
  return result.rows;
};

const aiLayerPredictionResponseData = ({
  layer,
  viewerPublished,
  featureQuery,
  rows,
  stats,
}: {
  layer: any;
  viewerPublished: boolean;
  featureQuery: AiLayerFeatureQueryOptions;
  rows: any[];
  stats: AiPredictionLayerStats;
}) => {
  const parsed = {
    type: 'FeatureCollection',
    features: predictionRowsToGeoJsonFeatures(rows),
  };
  const collectionQuery = {
    ...featureQuery,
    offset: featureQuery.geometry === 'aggregate' ? featureQuery.offset : 0,
    search: null,
    classLabel: null,
    featureId: null,
    bounds: null,
    confidenceMin: null,
    confidenceMax: null,
    uncertaintyMin: null,
    uncertaintyMax: null,
  };
  const {
    featureCollection,
    returnedFeatureCount,
    cap,
  } = buildAiLayerFeatureCollection(parsed, collectionQuery);
  const capped = featureQuery.offset + returnedFeatureCount < stats.totalCount;

  return {
    layer: {
      id: layer.id,
      ai_run_id: layer.ai_run_id,
      project_id: layer.project_id,
      layer_type: layer.layer_type,
      status: layer.status,
      name: layer.name,
      description: layer.description,
      crs: layer.crs,
      published_at: layer.published_at,
      viewer_published: viewerPublished,
      source: 'ai_prediction_feature',
    },
    feature_collection: featureCollection,
    feature_count: stats.totalCount,
    total_count: stats.totalCount,
    total_area_m2: stats.totalAreaM2,
    total_area_hectares: stats.totalAreaHectares,
    matching_feature_count: stats.visibleCount,
    visible_count: stats.visibleCount,
    loaded_feature_count: returnedFeatureCount,
    returned_feature_count: returnedFeatureCount,
    returned_count: returnedFeatureCount,
    capped,
    cap,
    pagination: {
      page: featureQuery.page,
      limit: featureQuery.limit,
      total: stats.totalCount,
      pages: Math.max(1, Math.ceil(stats.totalCount / featureQuery.limit)),
      has_more: featureQuery.offset + returnedFeatureCount < stats.totalCount,
    },
    detail: featureQuery.detail,
    geometry_mode: featureQuery.geometry,
    optimized_preview: featureQuery.detail === 'overview',
    available_detail_modes: ['overview', 'full'],
    available_geometry_modes: ['aggregate', 'simplified', 'full'],
    q: featureQuery.search,
    class_label: featureQuery.classLabel,
    confidence_min: featureQuery.confidenceMin,
    confidence_max: featureQuery.confidenceMax,
    uncertainty_min: featureQuery.uncertaintyMin,
    uncertainty_max: featureQuery.uncertaintyMax,
    layer_bounds: stats.layerBounds,
    class_counts: stats.countByClass,
    count_by_class: stats.countByClass,
    area_by_class: stats.areaByClass,
    active_class_filter: featureQuery.classLabel,
    run_id: layer.ai_run_id,
    project_id: layer.project_id,
    status_filter: 'all_app_visible_prediction_statuses',
    geometry_types: stats.geometryTypes,
    bounds: featureQuery.bounds,
    zoom: featureQuery.zoom,
    source: 'ai_prediction_feature',
    count_semantics: 'authoritative_database_total_excludes_viewport_bounds',
    loaded_count_semantics: 'returned_feature_count is only the current page or viewport payload',
    not_official_field_data: true,
  };
};

const getAiLayerPredictions = async (req: Request, res: Response): Promise<void> => {
  const featureQuery = parseAiLayerFeatureQuery(req);
  const currentUser = req.user as Express.UserContext;
  const { layer, viewerPublished } = await loadPreviewableAiLayerForUser(
    req.params.layerId,
    currentUser,
  );
  const [stats, rows] = await Promise.all([
    loadPredictionLayerStats(layer.id, featureQuery),
    loadPredictionFeaturesForLayer(layer.id, featureQuery),
  ]);

  res.json({
    success: true,
    data: aiLayerPredictionResponseData({
      layer,
      viewerPublished,
      featureQuery,
      rows,
      stats,
    }),
  });
};

const listProjectPublishedAiPredictions = async (req: Request, res: Response): Promise<void> => {
  const user = req.user as Express.UserContext;
  await assertProjectReadableForAiLayer(req.params.projectId, user);
  const settings = await getEffectiveAiSettings(req.params.projectId);
  if (!settings.is_enabled) {
    res.json({
      success: true,
      data: {
        project_id: req.params.projectId,
        layers: [],
        feature_collection: {
          type: 'FeatureCollection',
          features: [],
        },
        feature_count: 0,
        total_count: 0,
        matching_feature_count: 0,
        visible_count: 0,
        returned_feature_count: 0,
        returned_count: 0,
        capped: false,
        cap: DEFAULT_AI_LAYER_OVERVIEW_FEATURE_LIMIT,
        class_counts: {},
        geometry_types: [],
        source: 'ai_prediction_feature',
        primary_layer_type: 'classification',
        primary_prediction_count: 0,
        layer_counts: {},
        total_prediction_row_count: 0,
        count_semantics: 'primary_prediction_layer',
      },
    });
    return;
  }

  const featureQuery = parseAiLayerFeatureQuery(req);
  const result = await query(
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
            p.source_resolution_m,
            p.processed_area_m2,
            p.area_change_percent,
            p.processing_method,
            p.geometry_quality,
            p.created_at,
            p.updated_at,
            l.layer_type,
            l.name AS layer_name,
            l.status AS layer_status,
            l.published_at
     FROM ai_prediction_feature p
     JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
     JOIN ai_run ar ON ar.id = p.ai_run_id
     WHERE p.project_id = $1
       AND l.status = 'published'
       AND l.published_at IS NOT NULL
       AND l.layer_type = 'classification'
       AND ar.published_at IS NOT NULL
       AND ar.unpublished_at IS NULL
     ORDER BY p.created_at ASC, p.artifact_feature_id ASC`,
    [req.params.projectId],
  );
  const layerResult = await query(
    `SELECT l.id,
            l.ai_run_id,
            l.project_id,
            l.layer_type,
            l.status,
            COALESCE(NULLIF(BTRIM(l.name), ''), ar.published_layer_name, ar.display_name) AS name,
            l.description,
            NULL::text AS storage_path,
            l.asset_id,
            l.crs,
            ST_AsGeoJSON(l.bounds)::json AS bounds,
            l.style,
            l.published_at,
            l.published_by,
            COUNT(p.id)::int AS prediction_count,
            ar.display_name AS run_display_name,
            ar.is_dry_run,
            ar.prediction_count AS run_prediction_count,
            l.created_at,
            l.updated_at
     FROM ai_output_layer l
     JOIN ai_run ar ON ar.id = l.ai_run_id
     LEFT JOIN ai_prediction_feature p ON p.ai_output_layer_id = l.id
     WHERE l.project_id = $1
       AND l.status = 'published'
       AND l.published_at IS NOT NULL
       AND l.layer_type = 'classification'
       AND ar.published_at IS NOT NULL
       AND ar.unpublished_at IS NULL
     GROUP BY l.id, ar.id
     ORDER BY l.published_at DESC
     LIMIT 1`,
    [req.params.projectId],
  );
  const layerCounts: Record<string, number> = result.rows.reduce(
    (counts, row) => {
      const layerType = typeof row.layer_type === 'string' ? row.layer_type : 'unknown';
      counts[layerType] = (counts[layerType] ?? 0) + 1;
      return counts;
    },
    {} as Record<string, number>,
  );
  const primaryLayerType = layerCounts.classification
    ? 'classification'
    : (Object.keys(layerCounts)[0] ?? 'classification');
  const primaryRows = result.rows.filter((row) => row.layer_type === primaryLayerType);
  const aggregateLayer = {
    id: null,
    ai_run_id: null,
    project_id: req.params.projectId,
    layer_type: primaryLayerType,
    status: 'published',
    name: 'Published AI predictions',
    description: 'Primary read-only AI predictions stored in the application database.',
    crs: 'EPSG:4326',
    published_at: null,
  };
  const primaryStats = predictionLayerStatsFromRows(primaryRows, featureQuery);
  const data = aiLayerPredictionResponseData({
    layer: aggregateLayer,
    viewerPublished: true,
    featureQuery,
    rows: predictionRowsForResponseFromRows(primaryRows, featureQuery),
    stats: primaryStats,
  });

  res.json({
    success: true,
    data: {
      ...data,
      project_id: req.params.projectId,
      layers: layerResult.rows.map(({ storage_path: _storagePath, ...row }) => row),
      primary_layer_type: primaryLayerType,
      primary_prediction_count: layerCounts[primaryLayerType] ?? 0,
      layer_counts: layerCounts,
      total_prediction_row_count: result.rows.length,
      count_semantics: 'primary_prediction_layer',
    },
  });
};

const listProjectAiPredictionValidationTasks = async (
  req: Request,
  res: Response,
): Promise<void> => {
  const { page, limit } = parsePagination(req);
  const result = await listProjectPredictionValidationTasks(req.params.projectId, {
    page,
    limit,
    status: normalizeOptionalString(req.query.status),
    assignedTo: normalizeOptionalString(req.query.assigned_to),
    aiRunId: normalizeOptionalString(req.query.ai_run_id),
  });

  res.json({
    success: true,
    data: {
      tasks: result.tasks,
      status_counts: result.status_counts,
      no_spatial_feature_writes: true,
      not_official_field_data: true,
    },
    pagination: result.pagination,
  });
};

const generateProjectAiPredictionValidationTasks = async (
  req: Request,
  res: Response,
): Promise<void> => {
  const result = await generatePredictionValidationTasks({
    projectId: req.params.projectId,
    createdBy: (req.user as Express.UserContext).id,
    aiRunId: normalizeOptionalString(req.body?.ai_run_id),
    aiOutputLayerId: normalizeOptionalString(req.body?.ai_output_layer_id),
    aiPredictionFeatureId:
      normalizeOptionalString(req.body?.ai_prediction_feature_id) ??
      normalizeOptionalString(req.body?.prediction_feature_id),
    confidenceThreshold: parseOptionalBodyNumber(req.body?.confidence_threshold),
    limit: parseOptionalBodyNumber(req.body?.limit),
    priority: parseOptionalBodyNumber(req.body?.priority),
  });

  res.status(201).json({
    success: true,
    message: 'AI prediction validation tasks generated.',
    data: result,
  });
};

const assignAiPredictionValidationTask = async (req: Request, res: Response): Promise<void> => {
  const assignedTo = normalizeOptionalString(req.body?.assigned_to);
  if (!assignedTo) {
    throw new AppError('assigned_to is required.', 400);
  }

  const task = await assignPredictionValidationTask({
    taskId: req.params.taskId,
    assignedTo,
  });

  res.json({
    success: true,
    message: 'AI prediction validation task assigned.',
    data: task,
  });
};

const updateAiPredictionValidationTaskStatus = async (
  req: Request,
  res: Response,
): Promise<void> => {
  const status = normalizeOptionalString(req.body?.status);
  if (!status) {
    throw new AppError('status is required.', 400);
  }

  const task = await updatePredictionValidationTaskStatus({
    taskId: req.params.taskId,
    status: status as any,
  });

  res.json({
    success: true,
    message: 'AI prediction validation task status updated.',
    data: task,
  });
};

const getAiPredictionValidationTask = async (req: Request, res: Response): Promise<void> => {
  const task = await getPredictionValidationTaskForUser(
    req.params.taskId,
    req.user as Express.UserContext,
  );

  res.json({
    success: true,
    data: task,
  });
};

const listMyAiValidationTasks = async (req: Request, res: Response): Promise<void> => {
  const { page, limit } = parsePagination(req);
  const result = await listAssignedPredictionValidationTasks(req.user as Express.UserContext, {
    page,
    limit,
    status: normalizeOptionalString(req.query.status),
    aiRunId: normalizeOptionalString(req.query.ai_run_id),
  });

  res.json({
    success: true,
    data: {
      tasks: result.tasks,
      no_spatial_feature_writes: true,
      not_official_field_data: true,
    },
    pagination: result.pagination,
  });
};

const submitAiPredictionValidation = async (req: Request, res: Response): Promise<void> => {
  const currentUser = req.user as Express.UserContext;
  if (currentUser.role !== 'contributor') {
    throw new AppError('Only contributors can submit AI validation evidence.', 403);
  }

  const result = await createPredictionValidationSubmission({
    taskId: req.params.taskId,
    submittedBy: currentUser.id,
    result: normalizeOptionalString(req.body?.result) as any,
    correctedClass: normalizeOptionalString(req.body?.corrected_class),
    note: normalizeOptionalString(req.body?.note),
    evidence:
      req.body?.evidence &&
      typeof req.body.evidence === 'object' &&
      !Array.isArray(req.body.evidence)
        ? req.body.evidence
        : {},
    linkedFeatureId: normalizeOptionalString(req.body?.linked_feature_id),
  });

  res.status(201).json({
    success: true,
    message: 'AI validation evidence submitted for admin review.',
    data: result,
  });
};

const reviewAiPredictionValidationTask = async (req: Request, res: Response): Promise<void> => {
  const result = await reviewPredictionValidationTask({
    taskId: req.params.taskId,
    reviewedBy: (req.user as Express.UserContext).id,
    decision: normalizeOptionalString(req.body?.decision) as any,
    reason: normalizeOptionalString(req.body?.reason),
    submissionId: normalizeOptionalString(req.body?.submission_id),
  });

  res.json({
    success: true,
    message: 'AI prediction validation review saved.',
    data: result,
  });
};

const getProjectAiPredictionDetails = async (req: Request, res: Response): Promise<void> => {
  const result = await getPredictionFeatureDetailsForUser({
    projectId: req.params.projectId,
    runId: req.params.runId,
    predictionId: req.params.predictionId,
    user: req.user as Express.UserContext,
  });

  res.json({
    success: true,
    data: result,
  });
};

const uploadProjectAiPredictionValidationPhotos = async (
  req: Request,
  res: Response,
): Promise<void> => {
  const currentUser = req.user as Express.UserContext;
  const files = ((req.files as any[]) || []) as Array<{
    filename?: string;
    originalname?: string;
    mimetype?: string;
    size?: number;
  }>;
  if (files.length === 0) {
    throw new AppError('No validation photos uploaded.', 400);
  }

  const details = await getPredictionFeatureDetailsForUser({
    projectId: req.params.projectId,
    predictionId: req.params.predictionId,
    user: currentUser,
  });
  if (currentUser.role === 'contributor' && details.can_validate !== true) {
    throw new AppError('This AI prediction is not open for your validation.', 409);
  }
  if (currentUser.role !== 'contributor' && currentUser.role !== 'admin') {
    throw new AppError('Only contributors and admins can attach AI validation photos.', 403);
  }

  const photos = files
    .filter((file) => typeof file.filename === 'string' && file.filename.trim().length > 0)
    .map((file) => {
      const url = `/uploads/ai-validation/${file.filename}`;
      return {
        id: url,
        url,
        file_name: file.originalname ?? file.filename,
        mime_type: file.mimetype ?? null,
        size_bytes: file.size ?? null,
      };
    });
  if (photos.length === 0) {
    throw new AppError('No usable validation photos were uploaded.', 400);
  }

  logger.info('AI validation photos uploaded', {
    projectId: req.params.projectId,
    predictionId: req.params.predictionId,
    count: photos.length,
    userId: currentUser.id,
  });

  res.status(201).json({
    success: true,
    message: `${photos.length} validation photo(s) uploaded.`,
    data: {
      photo_media_ids: photos.map((photo) => photo.id),
      photos,
    },
  });
};

const submitProjectAiPredictionValidation = async (
  req: Request,
  res: Response,
): Promise<void> => {
  const currentUser = req.user as Express.UserContext;
  const metadata =
    req.body?.metadata && typeof req.body.metadata === 'object' && !Array.isArray(req.body.metadata)
      ? req.body.metadata
      : {};
  const result = await createPredictionFeatureValidation(
    {
      projectId: req.params.projectId,
      predictionId: req.params.predictionId,
      submittedBy: currentUser.id,
      result:
        (normalizeOptionalString(req.body?.validation_result) ??
          normalizeOptionalString(req.body?.result)) as any,
      correctedClass: normalizeOptionalString(req.body?.corrected_class),
      note: normalizeOptionalString(req.body?.note),
      photoMediaIds: req.body?.photo_media_ids ?? req.body?.photos,
      gpsLocation: req.body?.gps_location ?? req.body?.location,
      gpsAccuracyM: req.body?.gps_accuracy_m ?? req.body?.accuracy_meters,
      metadata,
    },
    currentUser,
  );

  res.status(201).json({
    success: true,
    message: 'AI prediction validation submitted.',
    data: result,
  });
};

const getMyProjectAiPredictionValidation = async (
  req: Request,
  res: Response,
): Promise<void> => {
  const result = await getMyPredictionFeatureValidation({
    projectId: req.params.projectId,
    predictionId: req.params.predictionId,
    user: req.user as Express.UserContext,
  });

  res.json({
    success: true,
    data: result,
  });
};

const listProjectAiPredictionValidations = async (
  req: Request,
  res: Response,
): Promise<void> => {
  const result = await listPredictionFeatureValidations({
    projectId: req.params.projectId,
    predictionId: req.params.predictionId,
  });

  res.json({
    success: true,
    data: result,
  });
};

const reviewProjectAiPrediction = async (req: Request, res: Response): Promise<void> => {
  const result = await reviewPredictionFeature(
    {
      projectId: req.params.projectId,
      predictionId: req.params.predictionId,
      reviewedBy: (req.user as Express.UserContext).id,
      approvalStatus:
        (normalizeOptionalString(req.body?.approval_status) ??
          normalizeOptionalString(req.body?.status)) as any,
      approvedClass: normalizeOptionalString(req.body?.approved_class),
      adminNote: normalizeOptionalString(req.body?.admin_note ?? req.body?.note),
    },
    req.user as Express.UserContext,
  );

  res.json({
    success: true,
    message: 'AI prediction admin review saved.',
    data: result,
  });
};

const getProjectAiRunValidationSummary = async (
  req: Request,
  res: Response,
): Promise<void> => {
  await loadProjectAiRunOrFail(req.params.projectId, req.params.runId);
  const result = await getRunPredictionValidationSummary({
    projectId: req.params.projectId,
    runId: req.params.runId,
  });

  res.json({
    success: true,
    data: result,
  });
};

const listProjectAiRunValidations = async (req: Request, res: Response): Promise<void> => {
  await loadProjectAiRunOrFail(req.params.projectId, req.params.runId);
  const { page, limit } = parsePagination(req);
  const result = await listRunPredictionValidations({
    projectId: req.params.projectId,
    runId: req.params.runId,
    page,
    limit,
  });

  res.json({
    success: true,
    data: {
      predictions: result.predictions,
    },
    pagination: result.pagination,
  });
};

const getAiLayerFeatures = async (req: Request, res: Response): Promise<void> => {
  const featureQuery = parseAiLayerFeatureQuery(req);
  const layerResult = await query(
    `SELECT l.id,
            l.ai_run_id,
            l.project_id,
            l.layer_type,
            l.status,
            l.name,
            l.description,
            l.storage_path,
            l.crs,
            l.published_at,
            ar.project_id AS run_project_id
     FROM ai_output_layer l
     JOIN ai_run ar ON ar.id = l.ai_run_id
     WHERE l.id = $1`,
    [req.params.layerId],
  );

  if (layerResult.rows.length === 0) {
    throw new AppError('AI output layer not found', 404);
  }

  const layer = layerResult.rows[0];
  if (layer.project_id !== layer.run_project_id) {
    throw new AppError('AI output layer project mismatch.', 400);
  }
  if (!previewableLayerTypes.has(layer.layer_type)) {
    throw new AppError('This AI output layer is not a map-preview layer.', 400);
  }
  const currentUser = req.user as Express.UserContext;
  const protectedSuperAdmin = isProtectedSuperAdminUser(currentUser);
  const viewerPublished = layer.status === 'published' && layer.published_at !== null;
  if (protectedSuperAdmin) {
    if (!previewableLayerStatuses.has(layer.status)) {
      throw new AppError('This AI output layer is not available for preview.', 403);
    }
  } else {
    if (!viewerPublished) {
      throw new AppError('This AI output layer is not published.', 403);
    }
    const settings = await getEffectiveAiSettings(layer.project_id);
    if (!settings.is_enabled) {
      throw new AppError('AI layers are disabled for this project.', 403);
    }
    await assertProjectReadableForAiLayer(layer.project_id, currentUser);
  }
  const predictionStats = await loadPredictionLayerStats(layer.id, featureQuery);
  if (predictionStats.totalCount > 0) {
    const predictionRows = await loadPredictionFeaturesForLayer(layer.id, featureQuery);
    res.json({
      success: true,
      data: aiLayerPredictionResponseData({
        layer,
        viewerPublished,
        featureQuery,
        rows: predictionRows,
        stats: predictionStats,
      }),
    });
    return;
  }
  const storagePath = normalizeOptionalString(layer.storage_path);
  if (!storagePath) {
    throw new AppError('AI output layer has no registered preview output file.', 404);
  }

  const pipelineConfig = createAiPipelineService().getConfig();
  const artifactPath = resolveRegisteredAiLayerGeoJsonPath({
    storagePath,
    outputRoot: resolveConfiguredAiOutputRoot(pipelineConfig.root),
  });

  let stat;
  try {
    stat = await fs.stat(artifactPath);
  } catch {
    throw new AppError('AI output layer preview output file was not found.', 404);
  }
  if (!stat.isFile()) {
    throw new AppError('AI output layer preview output is not a file.', 400);
  }
  if (stat.size > MAX_AI_LAYER_GEOJSON_BYTES) {
    throw new AppError('AI output layer preview output is too large to load directly.', 413);
  }

  let parsed: any;
  try {
    parsed = JSON.parse(await fs.readFile(artifactPath, 'utf8'));
  } catch {
    throw new AppError('AI output layer preview output is not valid GeoJSON.', 422);
  }

  if (!parsed || parsed.type !== 'FeatureCollection' || !Array.isArray(parsed.features)) {
    throw new AppError(
      'AI output layer preview output must be a GeoJSON FeatureCollection.',
      422,
    );
  }

  const {
    featureCollection,
    returnedFeatureCount,
    sourceFeatureCount,
    matchingFeatureCount,
    capped,
    cap,
    layerBounds,
    classCounts,
    geometryTypes,
  } = buildAiLayerFeatureCollection(parsed, featureQuery);

  res.json({
    success: true,
    data: {
      layer: {
        id: layer.id,
        ai_run_id: layer.ai_run_id,
        project_id: layer.project_id,
        layer_type: layer.layer_type,
        status: layer.status,
        name: layer.name,
        description: layer.description,
        crs: layer.crs,
        published_at: layer.published_at,
        viewer_published: viewerPublished,
      },
      feature_collection: featureCollection,
      feature_count: sourceFeatureCount,
      total_count: sourceFeatureCount,
      matching_feature_count: matchingFeatureCount,
      visible_count: matchingFeatureCount,
      returned_feature_count: returnedFeatureCount,
      returned_count: returnedFeatureCount,
      capped,
      cap,
      pagination: {
        page: featureQuery.page,
        limit: featureQuery.limit,
        total: matchingFeatureCount,
        pages: Math.max(1, Math.ceil(matchingFeatureCount / featureQuery.limit)),
        has_more: featureQuery.offset + returnedFeatureCount < matchingFeatureCount,
      },
      detail: featureQuery.detail,
      geometry_mode: featureQuery.geometry,
      optimized_preview: featureQuery.detail === 'overview',
      available_detail_modes: ['overview', 'full'],
      available_geometry_modes: ['aggregate', 'simplified', 'full'],
      q: featureQuery.search,
      class_label: featureQuery.classLabel,
      layer_bounds: layerBounds,
      class_counts: classCounts,
      geometry_types: geometryTypes,
      bounds: featureQuery.bounds,
      zoom: featureQuery.zoom,
    },
  });
};

const listAiRunLogs = async (req: Request, res: Response): Promise<void> => {
  const run = await assertRunReadable(req.params.runId, req.user as Express.UserContext);
  const { page, limit, offset } = parsePagination(req);
  const result = await query(
    `SELECT id,
            ai_run_id,
            level,
            message,
            metadata,
            created_at
     FROM ai_run_log
     WHERE ai_run_id = $1
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3`,
    [run.id, limit, offset],
  );
  const countResult = await query(
    `SELECT COUNT(*)::int AS total
     FROM ai_run_log
     WHERE ai_run_id = $1`,
    [run.id],
  );
  const total = Number(countResult.rows[0]?.total ?? 0);

  res.json({
    success: true,
    data: result.rows,
    pagination: {
      page,
      limit,
      total,
      pages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + result.rows.length < total,
    },
  });
};

const listAiRunReviews = async (req: Request, res: Response): Promise<void> => {
  const run = await assertRunReadable(req.params.runId, req.user as Express.UserContext);
  const result = await query(
    `SELECT id,
            ai_run_id,
            decision,
            reason,
            decided_by,
            decided_at,
            metadata
     FROM ai_review_decision
     WHERE ai_run_id = $1
     ORDER BY decided_at DESC`,
    [run.id],
  );

  res.json({
    success: true,
    data: result.rows,
  });
};

const reviewAiRun = async (req: Request, res: Response): Promise<void> => {
  const run = await assertRunReadable(req.params.runId, req.user as Express.UserContext);
  const currentUser = req.user as Express.UserContext;
  const action = normalizeOptionalString(req.body?.action) as keyof typeof reviewActions | null;
  const reason = normalizeOptionalString(req.body?.reason);

  if (!action || !(action in reviewActions)) {
    throw new AppError('Unsupported AI review action.', 400);
  }
  if ((action === 'reject' || action === 'request_more_data') && !reason) {
    throw new AppError('A reason is required for this AI review action.', 400);
  }

  const config = reviewActions[action];
  const result = await transaction(async (client: PoolClient) => {
    const lockedRunResult = await client.query(
      `SELECT id,
              project_id,
              status,
              metadata
       FROM ai_run
       WHERE id = $1
       FOR UPDATE`,
      [run.id],
    );

    if (lockedRunResult.rows.length === 0) {
      throw new AppError('AI run not found', 404);
    }

    const lockedRun = lockedRunResult.rows[0];
    const currentMetadata =
      lockedRun.metadata && typeof lockedRun.metadata === 'object' ? lockedRun.metadata : {};
    const reviewMetadata = {
      action,
      review_status: config.reviewStatus,
      layer_status: config.layerStatus,
      viewer_publication_enabled: false,
      spatial_feature_writes: false,
      reviewed_by: currentUser.id,
      reviewed_at: new Date().toISOString(),
    };

    const decisionResult = await client.query(
      `INSERT INTO ai_review_decision (ai_run_id, decision, reason, decided_by, metadata)
       VALUES ($1, $2, $3, $4, $5::jsonb)
       RETURNING id,
                 ai_run_id,
                 decision,
                 reason,
                 decided_by,
                 decided_at,
                 metadata`,
      [
        lockedRun.id,
        config.decision,
        reason,
        currentUser.id,
        JSON.stringify({
          phase: 'phase_i_review',
          ...reviewMetadata,
        }),
      ],
    );

    const preservePublishedLayers = action === 'approve_for_publication';
    const layerResult = await client.query(
      `UPDATE ai_output_layer
       SET status = $2,
           published_at = CASE WHEN $3::boolean THEN published_at ELSE NULL END,
           published_by = CASE WHEN $3::boolean THEN published_by ELSE NULL END,
           updated_at = NOW()
       WHERE ai_run_id = $1
         AND ($3::boolean = false OR status <> 'published')
       RETURNING id,
                 ai_run_id,
                 project_id,
                 layer_type,
                 status,
                 name,
                 published_at,
                 published_by`,
      [lockedRun.id, config.layerStatus, preservePublishedLayers],
    );
    await client.query(
      `UPDATE ai_prediction_feature p
       SET status = $2::ai_prediction_feature_status,
           updated_at = NOW()
       FROM ai_output_layer l
       WHERE p.ai_output_layer_id = l.id
         AND l.ai_run_id = $1
         AND ($3::boolean = false OR p.status <> 'published')`,
      [lockedRun.id, config.layerStatus, preservePublishedLayers],
    );

    const updatedRunResult = await client.query(
      `UPDATE ai_run
       SET metadata = $2::jsonb
       WHERE id = $1
       RETURNING id,
                 project_id,
                 settings_id,
                 status,
                 label_field,
                 scope_type,
                 ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
                 region_preset,
                 training_feature_count,
                 eligible_feature_count,
                 excluded_feature_count,
                 selected_model,
                 started_by,
                 started_at,
                 completed_at,
                 failed_at,
                 failure_reason,
                 metadata,
                 created_at,
                 updated_at`,
      [
        lockedRun.id,
        JSON.stringify({
          ...currentMetadata,
          review: {
            ...reviewMetadata,
            decision_id: decisionResult.rows[0].id,
            reason,
          },
        }),
      ],
    );

    await client.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        lockedRun.id,
        config.logMessage,
        JSON.stringify({
          phase: 'phase_i_review',
          action,
          decision: config.decision,
          layer_status: config.layerStatus,
          layers_updated: layerResult.rowCount ?? 0,
          published_layers_preserved: preservePublishedLayers,
          viewer_publication_changed: false,
          viewer_publication_enabled: false,
          spatial_feature_writes: false,
        }),
      ],
    );

    return {
      decision: decisionResult.rows[0],
      run: updatedRunResult.rows[0],
      layers: layerResult.rows,
    };
  });

  res.json({
    success: true,
    message:
      action === 'approve_for_publication'
        ? 'AI run approved for future publication. It has not been published to viewers.'
        : 'AI review decision saved.',
    data: {
      decision: result.decision,
      run: normalizeRunRow(result.run),
      layers: result.layers,
      viewer_published: false,
    },
  });
};

const publishProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  const currentUser = req.user as Express.UserContext;
  const result = await transaction(async (client: PoolClient) => {
    const runResult = await client.query(
      `SELECT ar.id,
              ar.project_id,
              ar.status,
              ar.completed_at,
              ar.published_at,
              ar.display_name,
              ar.is_dry_run,
              COALESCE(aps.is_enabled, project_aps.is_enabled) AS is_enabled
       FROM ai_run ar
       LEFT JOIN ai_project_settings aps ON aps.id = ar.settings_id
       LEFT JOIN ai_project_settings project_aps ON project_aps.project_id = ar.project_id
       WHERE ar.id = $1
         AND ar.project_id = $2
       FOR UPDATE OF ar`,
      [req.params.runId, req.params.projectId],
    );
    if (runResult.rows.length === 0) {
      throw new AppError('AI run not found', 404);
    }
    const run = runResult.rows[0];
    if (run.is_enabled !== true) {
      throw new AppError('AI must be enabled for this project before publishing AI runs.', 409);
    }
    if (run.is_dry_run === true && process.env.AI_ALLOW_DRY_RUN_PUBLISH !== 'true') {
      throw new AppError(
        'Dry-run AI runs cannot be published because no real prediction features were generated.',
        409,
      );
    }
    if (
      !['completed', 'ready_for_review', 'published'].includes(String(run.status)) &&
      run.completed_at === null
    ) {
      throw new AppError('Only completed AI runs with predictions can be published.', 409);
    }

    const layerResult = await client.query(
      `SELECT l.id,
              l.layer_type,
              l.status,
              l.published_at,
              (
                SELECT COUNT(*)::int
                FROM ai_prediction_feature p
                WHERE p.ai_output_layer_id = l.id
              ) AS prediction_count
       FROM ai_output_layer l
       WHERE l.ai_run_id = $1
         AND l.project_id = $2
         AND l.layer_type = 'classification'
       ORDER BY CASE l.status
                  WHEN 'published' THEN 0
                  WHEN 'ready_for_review' THEN 1
                  WHEN 'approved' THEN 2
                  ELSE 3
                END,
                l.created_at DESC
       LIMIT 1
       FOR UPDATE`,
      [run.id, run.project_id],
    );
    if (layerResult.rows.length === 0 || Number(layerResult.rows[0].prediction_count ?? 0) === 0) {
      throw new AppError('This AI run has no classification predictions to publish.', 409);
    }
    const layer = layerResult.rows[0];
    if (!['ready_for_review', 'approved', 'published', 'draft'].includes(String(layer.status))) {
      throw new AppError('This AI run layer is not publishable.', 409);
    }
    const publishedLayerName =
      normalizeOptionalString(layer.name) ??
      normalizeOptionalString(run.display_name) ??
      `AI Classification - ${run.id}`;

    await client.query(
      `UPDATE ai_output_layer
       SET status = 'approved',
           published_at = NULL,
           published_by = NULL,
           updated_at = NOW()
       WHERE project_id = $1
         AND ai_run_id <> $2
         AND layer_type = 'classification'
         AND status = 'published'`,
      [run.project_id, run.id],
    );
    await client.query(
      `UPDATE ai_prediction_feature p
       SET status = CASE
             WHEN p.status IN ('approved', 'rejected') THEN p.status
             ELSE 'ready_for_review'::ai_prediction_feature_status
           END,
           updated_at = NOW()
       FROM ai_output_layer l
       WHERE p.ai_output_layer_id = l.id
         AND l.project_id = $1
         AND l.ai_run_id <> $2
         AND p.status = 'published'`,
      [run.project_id, run.id],
    );
    await client.query(
      `UPDATE ai_run
       SET unpublished_at = COALESCE(unpublished_at, NOW()),
           unpublished_by = COALESCE(unpublished_by, $2),
           unpublished_reason = 'replaced_by_new_published_run',
           replaced_by_run_id = $3,
           metadata = metadata || $4::jsonb,
           updated_at = NOW()
       WHERE project_id = $1
         AND id <> $3
         AND published_at IS NOT NULL
         AND unpublished_at IS NULL`,
      [
        run.project_id,
        currentUser.id,
        run.id,
        JSON.stringify({
          publication: {
            published: false,
            unpublished_by: currentUser.id,
            unpublished_at: new Date().toISOString(),
            unpublished_reason: 'replaced_by_new_published_run',
            replaced_by_run_id: run.id,
          },
        }),
      ],
    );

    const layerUpdate = await client.query(
      `UPDATE ai_output_layer
       SET status = 'published',
           name = $3,
           published_at = NOW(),
           published_by = $2,
           updated_at = NOW()
       WHERE id = $1
       RETURNING id,
                 ai_run_id,
                 project_id,
                 layer_type,
                 status,
                 name,
                 description,
                 NULL::text AS storage_path,
                 asset_id,
                 crs,
                 ST_AsGeoJSON(bounds)::json AS bounds,
                 style,
                 published_at,
                 published_by,
                 created_at,
                 updated_at`,
      [layer.id, currentUser.id, publishedLayerName],
    );
    await client.query(
      `UPDATE ai_prediction_feature
       SET status = CASE
             WHEN status IN ('approved', 'rejected') THEN status
             ELSE 'published'::ai_prediction_feature_status
           END,
           updated_at = NOW()
       WHERE ai_output_layer_id = $1`,
      [layer.id],
    );
    const runUpdate = await client.query(
      `UPDATE ai_run
       SET status = 'published',
           published_at = NOW(),
           published_by = $2,
           unpublished_at = NULL,
           unpublished_by = NULL,
           unpublished_reason = NULL,
           replaced_by_run_id = NULL,
           published_layer_name = $3,
           prediction_count = $4,
           metadata = metadata || $5::jsonb,
           updated_at = NOW()
       WHERE id = $1
       RETURNING id,
                 project_id,
                 settings_id,
                 status,
                 display_name,
                 is_dry_run,
                 published_layer_name,
                 unpublished_reason,
                 replaced_by_run_id,
                 prediction_count,
                 label_field,
                 scope_type,
                 ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
                 region_preset,
                 training_feature_count,
                 eligible_feature_count,
                 excluded_feature_count,
                 selected_model,
                 started_by,
                 started_at,
                 completed_at,
                 failed_at,
                 failure_reason,
                 stage,
                 progress,
                 message,
                 ai_server_run_id,
                 cancelled_at,
                 callback_received_at,
                 artifacts,
                 counts,
                 error_details,
                 published_at,
                 published_by,
                 unpublished_at,
                 unpublished_by,
                 metadata,
                 created_at,
                 updated_at`,
      [
        run.id,
        currentUser.id,
        publishedLayerName,
        Number(layer.prediction_count ?? 0),
        JSON.stringify({
          publication: {
            published: true,
            published_by: currentUser.id,
            published_at: new Date().toISOString(),
            layer_id: layer.id,
            layer_name: publishedLayerName,
            prediction_count: Number(layer.prediction_count ?? 0),
            one_classification_layer: true,
          },
        }),
      ],
    );

    await client.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        run.id,
        'AI run classification layer published for project map validation.',
        JSON.stringify({
          phase: 'ai_run_publish',
          layer_id: layer.id,
          published_by: currentUser.id,
          confidence_is_attribute: true,
          standalone_confidence_layer: false,
          standalone_uncertainty_layer: false,
        }),
      ],
    );

    return {
      run: normalizeRunRow(runUpdate.rows[0]),
      layer: layerUpdate.rows[0],
    };
  });

  res.json({
    success: true,
    message: 'AI run published for project map validation.',
    data: result,
  });
};

const unpublishProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  const currentUser = req.user as Express.UserContext;
  const result = await transaction(async (client: PoolClient) => {
    const runResult = await client.query(
      `SELECT id, project_id
       FROM ai_run
       WHERE id = $1
         AND project_id = $2
       FOR UPDATE`,
      [req.params.runId, req.params.projectId],
    );
    if (runResult.rows.length === 0) {
      throw new AppError('AI run not found', 404);
    }
    const run = runResult.rows[0];
    const layerResult = await client.query(
      `UPDATE ai_output_layer
       SET status = 'approved',
           published_at = NULL,
           published_by = NULL,
           updated_at = NOW()
       WHERE ai_run_id = $1
         AND project_id = $2
         AND layer_type = 'classification'
         AND status = 'published'
       RETURNING id,
                 ai_run_id,
                 project_id,
                 layer_type,
                 status,
                 name,
                 description,
                 NULL::text AS storage_path,
                 asset_id,
                 crs,
                 ST_AsGeoJSON(bounds)::json AS bounds,
                 style,
                 published_at,
                 published_by,
                 created_at,
                 updated_at`,
      [run.id, run.project_id],
    );
    await client.query(
      `UPDATE ai_prediction_feature p
       SET status = 'approved',
           updated_at = NOW()
       FROM ai_output_layer l
       WHERE p.ai_output_layer_id = l.id
         AND l.ai_run_id = $1
         AND l.project_id = $2
         AND p.status = 'published'`,
      [run.id, run.project_id],
    );
    const runUpdate = await client.query(
      `UPDATE ai_run
       SET status = CASE WHEN status = 'published' THEN 'completed'::ai_run_status ELSE status END,
           unpublished_at = NOW(),
           unpublished_by = $2,
           unpublished_reason = 'manual_unpublish',
           metadata = metadata || $3::jsonb,
           updated_at = NOW()
       WHERE id = $1
       RETURNING id,
                 project_id,
                 settings_id,
                 status,
                 display_name,
                 is_dry_run,
                 published_layer_name,
                 unpublished_reason,
                 replaced_by_run_id,
                 prediction_count,
                 label_field,
                 scope_type,
                 ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
                 region_preset,
                 training_feature_count,
                 eligible_feature_count,
                 excluded_feature_count,
                 selected_model,
                 started_by,
                 started_at,
                 completed_at,
                 failed_at,
                 failure_reason,
                 stage,
                 progress,
                 message,
                 ai_server_run_id,
                 cancelled_at,
                 callback_received_at,
                 artifacts,
                 counts,
                 error_details,
                 published_at,
                 published_by,
                 unpublished_at,
                 unpublished_by,
                 metadata,
                 created_at,
                 updated_at`,
      [
        run.id,
        currentUser.id,
        JSON.stringify({
          publication: {
            published: false,
            unpublished_by: currentUser.id,
            unpublished_at: new Date().toISOString(),
            unpublished_reason: 'manual_unpublish',
          },
        }),
      ],
    );
    await client.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        run.id,
        'AI run classification layer unpublished. Contributor validation access is disabled.',
        JSON.stringify({
          phase: 'ai_run_unpublish',
          unpublished_by: currentUser.id,
          layers_updated: layerResult.rowCount ?? 0,
        }),
      ],
    );
    return {
      run: normalizeRunRow(runUpdate.rows[0]),
      layers: layerResult.rows,
    };
  });

  res.json({
    success: true,
    message: 'AI run unpublished.',
    data: result,
  });
};

const publishAiLayer = async (req: Request, res: Response): Promise<void> => {
  const currentUser = req.user as Express.UserContext;
  const result = await transaction(async (client: PoolClient) => {
    const layerResult = await client.query(
      `SELECT l.id,
              l.ai_run_id,
              l.project_id,
              l.layer_type,
              l.status,
              l.name,
              l.published_at,
              ar.status AS run_status,
              ar.completed_at AS run_completed_at,
              ar.display_name,
              ar.is_dry_run,
              ar.project_id AS run_project_id
       FROM ai_output_layer l
       JOIN ai_run ar ON ar.id = l.ai_run_id
       WHERE l.id = $1
       FOR UPDATE`,
      [req.params.layerId],
    );

    if (layerResult.rows.length === 0) {
      throw new AppError('AI output layer not found', 404);
    }

    const layer = layerResult.rows[0];
    if (layer.project_id !== layer.run_project_id) {
      throw new AppError('AI output layer project mismatch.', 400);
    }
    if (!['approved', 'published'].includes(String(layer.status))) {
      throw new AppError('Only approved AI classification layers can be published.', 409);
    }
    if (!previewableLayerTypes.has(layer.layer_type)) {
      throw new AppError('Only map-preview AI layers can be published.', 400);
    }
    if (layer.is_dry_run === true && process.env.AI_ALLOW_DRY_RUN_PUBLISH !== 'true') {
      throw new AppError(
        'Dry-run AI layers cannot be published because no real prediction features were generated.',
        409,
      );
    }
    if (
      !['completed', 'ready_for_review', 'published'].includes(String(layer.run_status)) &&
      layer.run_completed_at === null
    ) {
      throw new AppError('Only completed AI runs with predictions can be published.', 409);
    }
    const settingsResult = await client.query(
      `SELECT is_enabled
       FROM ai_project_settings
       WHERE project_id = $1`,
      [layer.project_id],
    );
    if (settingsResult.rows[0]?.is_enabled !== true) {
      throw new AppError('AI must be enabled for this project before publishing layers.', 409);
    }
    const predictionCountResult = await client.query(
      `SELECT COUNT(*)::int AS count
       FROM ai_prediction_feature
       WHERE ai_output_layer_id = $1`,
      [layer.id],
    );
    const predictionCount = Number(predictionCountResult.rows[0]?.count ?? 0);
    if (predictionCount === 0) {
      throw new AppError('This AI layer has no classification predictions to publish.', 409);
    }
    const publishedLayerName =
      normalizeOptionalString(layer.name) ??
      normalizeOptionalString(layer.display_name) ??
      `AI Classification - ${layer.ai_run_id}`;

    await client.query(
      `UPDATE ai_output_layer
       SET status = 'approved',
           published_at = NULL,
           published_by = NULL,
           updated_at = NOW()
       WHERE project_id = $1
         AND id <> $2
         AND layer_type = 'classification'
         AND status = 'published'`,
      [layer.project_id, layer.id],
    );
    await client.query(
      `UPDATE ai_prediction_feature p
       SET status = CASE
             WHEN p.status IN ('approved', 'rejected') THEN p.status
             ELSE 'ready_for_review'::ai_prediction_feature_status
           END,
           updated_at = NOW()
       FROM ai_output_layer l
       WHERE p.ai_output_layer_id = l.id
         AND l.project_id = $1
         AND l.id <> $2
         AND p.status = 'published'`,
      [layer.project_id, layer.id],
    );
    await client.query(
      `UPDATE ai_run
       SET unpublished_at = COALESCE(unpublished_at, NOW()),
           unpublished_by = COALESCE(unpublished_by, $2),
           unpublished_reason = 'replaced_by_new_published_run',
           replaced_by_run_id = $3,
           metadata = metadata || $4::jsonb,
           updated_at = NOW()
       WHERE project_id = $1
         AND id <> $3
         AND published_at IS NOT NULL
         AND unpublished_at IS NULL`,
      [
        layer.project_id,
        currentUser.id,
        layer.ai_run_id,
        JSON.stringify({
          publication: {
            published: false,
            unpublished_by: currentUser.id,
            unpublished_at: new Date().toISOString(),
            unpublished_reason: 'replaced_by_new_published_run',
            replaced_by_run_id: layer.ai_run_id,
          },
        }),
      ],
    );

    const updated = await client.query(
      `UPDATE ai_output_layer
       SET status = 'published',
           name = $3,
           published_at = NOW(),
           published_by = $2,
           updated_at = NOW()
       WHERE id = $1
       RETURNING id,
                 ai_run_id,
                 project_id,
                 layer_type,
                 status,
                 name,
                 description,
                 NULL::text AS storage_path,
                 asset_id,
                 crs,
                 ST_AsGeoJSON(bounds)::json AS bounds,
                 style,
                 published_at,
                 published_by,
                 created_at,
                 updated_at`,
      [layer.id, currentUser.id, publishedLayerName],
    );
    await client.query(
      `UPDATE ai_prediction_feature
       SET status = CASE
             WHEN status IN ('approved', 'rejected') THEN status
             ELSE 'published'::ai_prediction_feature_status
           END,
           updated_at = NOW()
       WHERE ai_output_layer_id = $1`,
      [layer.id],
    );
    await client.query(
      `UPDATE ai_run
       SET status = 'published',
           published_at = NOW(),
           published_by = $2,
           unpublished_at = NULL,
           unpublished_by = NULL,
           unpublished_reason = NULL,
           replaced_by_run_id = NULL,
           published_layer_name = $3,
           prediction_count = $4,
           metadata = metadata || $5::jsonb,
           updated_at = NOW()
       WHERE id = $1`,
      [
        layer.ai_run_id,
        currentUser.id,
        publishedLayerName,
        predictionCount,
        JSON.stringify({
          publication: {
            published: true,
            published_by: currentUser.id,
            published_at: new Date().toISOString(),
            layer_id: layer.id,
            layer_name: publishedLayerName,
            prediction_count: predictionCount,
            one_classification_layer: true,
          },
        }),
      ],
    );

    await client.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        layer.ai_run_id,
        'AI output layer published for read-only viewer map access.',
        JSON.stringify({
          phase: 'phase_p_publish',
          layer_id: layer.id,
          layer_type: layer.layer_type,
          published_by: currentUser.id,
          viewer_publication_enabled: true,
          spatial_feature_writes: false,
        }),
      ],
    );

    return updated.rows[0];
  });

  res.json({
    success: true,
    message: 'AI layer published as a read-only map overlay.',
    data: result,
  });
};

const unpublishAiLayer = async (req: Request, res: Response): Promise<void> => {
  const currentUser = req.user as Express.UserContext;
  const result = await transaction(async (client: PoolClient) => {
    const layerResult = await client.query(
      `SELECT l.id,
              l.ai_run_id,
              l.project_id,
              l.layer_type,
              l.status,
              l.name,
              l.published_at,
              l.published_by,
              ar.project_id AS run_project_id
       FROM ai_output_layer l
       JOIN ai_run ar ON ar.id = l.ai_run_id
       WHERE l.id = $1
       FOR UPDATE`,
      [req.params.layerId],
    );

    if (layerResult.rows.length === 0) {
      throw new AppError('AI output layer not found', 404);
    }

    const layer = layerResult.rows[0];
    if (layer.project_id !== layer.run_project_id) {
      throw new AppError('AI output layer project mismatch.', 400);
    }
    if (layer.status !== 'published') {
      throw new AppError('Only published AI layers can be unpublished.', 409);
    }

    const updated = await client.query(
      `UPDATE ai_output_layer
       SET status = 'approved',
           published_at = NULL,
           published_by = NULL,
           updated_at = NOW()
       WHERE id = $1
       RETURNING id,
                 ai_run_id,
                 project_id,
                 layer_type,
                 status,
                 name,
                 description,
                 NULL::text AS storage_path,
                 asset_id,
                 crs,
                 ST_AsGeoJSON(bounds)::json AS bounds,
                 style,
                 published_at,
                 published_by,
                 created_at,
                 updated_at`,
      [layer.id],
    );
    await client.query(
      `UPDATE ai_prediction_feature
       SET status = 'approved',
           updated_at = NOW()
       WHERE ai_output_layer_id = $1
         AND status = 'published'`,
      [layer.id],
    );
    await client.query(
      `UPDATE ai_run
       SET status = CASE WHEN status = 'published' THEN 'completed'::ai_run_status ELSE status END,
           unpublished_at = NOW(),
           unpublished_by = $2,
           unpublished_reason = 'manual_unpublish',
           metadata = metadata || $3::jsonb,
           updated_at = NOW()
       WHERE id = $1`,
      [
        layer.ai_run_id,
        currentUser.id,
        JSON.stringify({
          publication: {
            published: false,
            unpublished_by: currentUser.id,
            unpublished_at: new Date().toISOString(),
            unpublished_reason: 'manual_unpublish',
            layer_id: layer.id,
          },
        }),
      ],
    );

    await client.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        layer.ai_run_id,
        'AI output layer unpublished. Viewer map access was removed.',
        JSON.stringify({
          phase: 'phase_p_unpublish',
          layer_id: layer.id,
          layer_type: layer.layer_type,
          unpublished_by: currentUser.id,
          previous_published_at: layer.published_at,
          previous_published_by: layer.published_by,
          viewer_publication_enabled: false,
          spatial_feature_writes: false,
        }),
      ],
    );

    return updated.rows[0];
  });

  res.json({
    success: true,
    message: 'AI layer unpublished. Viewer access is disabled.',
    data: result,
  });
};

module.exports = {
  getProjectAiReadiness,
  getProjectAiSettings,
  upsertProjectAiSettings,
  createProjectAiRun,
  listProjectAiRuns,
  getProjectAiRun,
  getProjectAiRunStatus,
  publishProjectAiRun,
  unpublishProjectAiRun,
  cancelProjectAiRun,
  resumeProjectAiRun,
  retrainCheckProjectAiRun,
  handleAiRunCallback,
  getAiRun,
  listAiRunMetrics,
  listAiRunLayers,
  listProjectPublishedAiLayers,
  listProjectPublishedAiPredictions,
  listProjectAiPredictionValidationTasks,
  generateProjectAiPredictionValidationTasks,
  getProjectAiPredictionDetails,
  uploadProjectAiPredictionValidationPhotos,
  submitProjectAiPredictionValidation,
  getMyProjectAiPredictionValidation,
  listProjectAiPredictionValidations,
  reviewProjectAiPrediction,
  getProjectAiRunValidationSummary,
  listProjectAiRunValidations,
  getAiLayerFeatures,
  getAiLayerPredictions,
  assignAiPredictionValidationTask,
  updateAiPredictionValidationTaskStatus,
  getAiPredictionValidationTask,
  listMyAiValidationTasks,
  submitAiPredictionValidation,
  reviewAiPredictionValidationTask,
  listAiRunLogs,
  listAiRunReviews,
  reviewAiRun,
  publishAiLayer,
  unpublishAiLayer,
};

export {};
