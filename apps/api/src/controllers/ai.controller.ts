import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import type { PoolClient } from 'pg';
import type { Request, Response } from 'express';
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const { createAiPipelineService } = require('../services/aiPipeline.service');
import { publicVisibleStatuses, synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';

const allowedRunStatuses = [
  'draft',
  'queued',
  'extracting_features',
  'training',
  'evaluating',
  'classifying',
  'ready_for_review',
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
];

const regionalExecutionModes = [
  'regional_feature_extraction',
  'regional_model_eval',
  'regional_classification',
  'regional_vectorization_artifacts',
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
const previewableLayerTypes = new Set(['classification', 'confidence', 'uncertainty']);
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
  model_preferences: {},
};

const lebanonApproxBounds = {
  min_lon: 35.1,
  min_lat: 33.0,
  max_lon: 36.7,
  max_lat: 34.75,
};

const nationalScopeUnmetRequirements = [
  'National mode is enabled for this project.',
  'Lebanon boundary is configured for AI prediction.',
  'Approved training samples cover multiple Lebanese regions and environmental conditions.',
  'Every class has enough approved samples: minimum 50, recommended 100+.',
  'All samples used for training have valid and consistent labels.',
  'No class or region is dangerously underrepresented, or the warning is reviewed.',
  'The AI pipeline supports the selected satellite, dates, features, and national boundary.',
  'A validation/review plan exists before national results are published.',
];

const boolPreference = (preferences: Record<string, unknown> | null | undefined, key: string) =>
  preferences?.[key] === true;

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

const nationalScopeEligibilityFor = ({
  requestedNational,
  labelCounts = [],
  totals,
  warnings = [],
  modelPreferences = {},
}: {
  requestedNational: boolean;
  labelCounts?: Array<{ sample_count: number }>;
  totals?: {
    missing_label_count?: number;
    invalid_geometry_count?: number;
  };
  warnings?: string[];
  modelPreferences?: Record<string, unknown>;
}) => {
  const unmetRequirements: string[] = [];
  const nationalModeAllowed = boolPreference(modelPreferences, 'national_mode_allowed');
  const lebanonBoundaryConfigured = boolPreference(modelPreferences, 'lebanon_boundary_configured');
  const nationalSampleSpreadConfirmed = boolPreference(
    modelPreferences,
    'national_sample_spread_confirmed',
  );
  const minimumSamplesPerClassMet =
    labelCounts.length > 0 && labelCounts.every((row) => Number(row.sample_count) >= 50);
  const labelsValid =
    Number(totals?.missing_label_count ?? 0) === 0 &&
    Number(totals?.invalid_geometry_count ?? 0) === 0;
  const imbalanceWarningsReviewed =
    !warnings.some((warning) => /balance|spatially limited|below/i.test(warning)) ||
    boolPreference(modelPreferences, 'national_imbalance_reviewed');
  const pipelineSupportsNational = boolPreference(
    modelPreferences,
    'pipeline_supports_national_scope',
  );
  const validationPlanRecorded = boolPreference(
    modelPreferences,
    'national_validation_plan_recorded',
  );

  if (!nationalModeAllowed) {
    unmetRequirements.push(nationalScopeUnmetRequirements[0]);
  }
  if (!lebanonBoundaryConfigured) {
    unmetRequirements.push(nationalScopeUnmetRequirements[1]);
  }
  if (!nationalSampleSpreadConfirmed) {
    unmetRequirements.push(nationalScopeUnmetRequirements[2]);
  }
  if (!minimumSamplesPerClassMet) {
    unmetRequirements.push(nationalScopeUnmetRequirements[3]);
  }
  if (!labelsValid) {
    unmetRequirements.push(nationalScopeUnmetRequirements[4]);
  }
  if (!imbalanceWarningsReviewed) {
    unmetRequirements.push(nationalScopeUnmetRequirements[5]);
  }
  if (!pipelineSupportsNational) {
    unmetRequirements.push(nationalScopeUnmetRequirements[6]);
  }
  if (!validationPlanRecorded) {
    unmetRequirements.push(nationalScopeUnmetRequirements[7]);
  }

  const eligible = unmetRequirements.length === 0;
  return {
    eligible,
    unmet_requirements: unmetRequirements,
    warnings:
      requestedNational && !eligible
        ? [
            ...warnings,
            'National Lebanon prediction is locked until national readiness requirements are met.',
          ]
        : warnings,
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
    model_preferences: existing?.model_preferences ?? defaultSettings.model_preferences,
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

  if (!labelField) {
    blockers.push('No AI label field is configured or requested.');
  }
  if (Number(totals.approved_feature_count) === 0) {
    blockers.push('Project has no approved field/import features available for AI.');
  }
  if (labelCounts.length < 2) {
    blockers.push('At least two labeled classes are required for supervised training.');
  }

  const classesBelowMinimum = labelCounts.filter((row) => row.sample_count < minSamplesPerClass);
  const classesAtMinimum = labelCounts.filter((row) => row.sample_count >= minSamplesPerClass);
  const eligibleClassCount = classesAtMinimum.length;
  const eligibleFeatureCount = classesAtMinimum.reduce((total, row) => total + row.sample_count, 0);
  const validLabeledFeatureCount = Number(totals.valid_labeled_feature_count);

  if (labelCounts.length >= 2 && eligibleClassCount < 2) {
    blockers.push(`At least two classes must meet the minimum of ${minSamplesPerClass} samples.`);
  } else if (classesBelowMinimum.length > 0) {
    const excluded = classesBelowMinimum
      .map((row) => `${row.class_label} (${row.sample_count})`)
      .join(', ');
    warnings.push(
      `Classes below ${minSamplesPerClass} samples will be excluded from the AI run: ${excluded}.`,
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

  const status = blockers.length > 0 ? 'not_ready' : warnings.length > 0 ? 'warning' : 'ready';
  const nationalScopeEligibility = nationalScopeEligibilityFor({
    requestedNational: scopeType === 'national',
    labelCounts,
    totals: {
      missing_label_count: Number(totals.missing_label_count),
      invalid_geometry_count: Number(totals.invalid_geometry_count),
    },
    warnings:
      scopeType === 'national' && spatialExtent === null
        ? ['No approved sample extent is available for national readiness evaluation.']
        : [],
    modelPreferences,
  });
  const nationalScopeEnabled =
    boolPreference(modelPreferences, 'national_scope_enabled') && nationalScopeEligibility.eligible;

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
    coverage_warning_applies: warnings.some((warning) => warning.includes('spatially limited')),
    warnings,
    blockers,
  };
};

const normalizeRunRow = (row: any) => ({
  ...row,
  training_feature_count: Number(row.training_feature_count ?? 0),
  eligible_feature_count: Number(row.eligible_feature_count ?? 0),
  excluded_feature_count: Number(row.excluded_feature_count ?? 0),
});

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
      },
      readiness: {
        ...readiness,
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
  await getProjectOrFail(projectId);
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
    model_preferences:
      body.model_preferences !== undefined
        ? (body.model_preferences ?? {})
        : (existing.model_preferences ?? {}),
  };

  const nationalReadiness = await getFeatureReadinessSummary({
    projectId,
    labelField: nextSettings.label_field,
    minSamplesPerClass: nextSettings.min_samples_per_class,
    scopeType: 'national',
    scopeGeometry: null,
    modelPreferences: nextSettings.model_preferences ?? {},
  });
  const nationalEligibility = nationalReadiness.national_scope_eligibility;
  const nationalModeRequested =
    nextSettings.scope_type === 'national' ||
    nextSettings.model_preferences?.national_scope_enabled === true;

  if (nationalModeRequested && nationalEligibility.eligible !== true) {
    throw new AppError(
      'National Lebanon is locked until national readiness requirements are met.',
      422,
    );
  }

  if (
    nextSettings.scope_type === 'national' &&
    nextSettings.model_preferences?.national_scope_enabled !== true
  ) {
    throw new AppError('Enable national mode before selecting National Lebanon.', 422);
  }

  const result = await query(
    `INSERT INTO ai_project_settings (
       project_id,
       is_enabled,
       label_field,
       scope_type,
       scope_geometry,
       min_samples_per_class,
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
       $7::jsonb,
       $8,
       $8
     )
     ON CONFLICT (project_id)
     DO UPDATE SET
       is_enabled = EXCLUDED.is_enabled,
       label_field = EXCLUDED.label_field,
       scope_type = EXCLUDED.scope_type,
       scope_geometry = EXCLUDED.scope_geometry,
       min_samples_per_class = EXCLUDED.min_samples_per_class,
       model_preferences = EXCLUDED.model_preferences,
       updated_by = EXCLUDED.updated_by
     RETURNING id,
               project_id,
               is_enabled,
               label_field,
               scope_type,
               ST_AsGeoJSON(scope_geometry)::json AS scope_geometry,
               min_samples_per_class,
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
      JSON.stringify(nextSettings.model_preferences),
      (req.user as Express.UserContext).id,
    ],
  );

  res.json({
    success: true,
    message: 'AI project settings saved successfully.',
    data: result.rows[0],
  });
};

const createProjectAiRun = async (req: Request, res: Response): Promise<void> => {
  const { projectId } = req.params;
  const project = await getProjectOrFail(projectId);
  const settings = await getEffectiveAiSettings(projectId);
  const body = req.body ?? {};
  const status = body.status === 'queued' ? 'queued' : 'draft';
  const requestedExecutionMode = normalizeOptionalString(body.execution_mode);
  const executionMode = requestedExecutionMode ?? 'mock';
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

  if (!labelField) {
    throw new AppError('AI label_field is required to create an AI run.', 400);
  }

  if (scopeType === 'national' && settings.model_preferences?.national_scope_enabled !== true) {
    throw new AppError('Enable national mode before selecting National Lebanon.', 422);
  }

  if (scopeType === 'national') {
    const nationalReadiness = await getFeatureReadinessSummary({
      projectId,
      labelField,
      minSamplesPerClass,
      scopeType: 'national',
      scopeGeometry: null,
      modelPreferences: settings.model_preferences ?? {},
    });
    if (nationalReadiness.national_scope_eligibility?.eligible !== true) {
      throw new AppError(
        'National Lebanon is locked until national readiness requirements are met.',
        422,
      );
    }
  }

  if (scopeType === 'national' && regionalExecutionModes.includes(executionMode)) {
    throw new AppError('Regional AI execution modes cannot be queued with national scope.', 400);
  }

  if (scopeType === 'national' && executionMode !== 'mock' && executionMode !== 'dry_run') {
    throw new AppError(
      'National AI execution is not available until the national pipeline is connected.',
      400,
    );
  }

  if (!allowedExecutionModes.includes(executionMode)) {
    throw new AppError(
      'Unsupported AI execution_mode. Allowed modes are mock, dry_run, local_ground_truth_export, regional_feature_extraction, regional_model_eval, regional_classification, or regional_vectorization_artifacts.',
      400,
    );
  }

  const readiness = await getFeatureReadinessSummary({
    projectId,
    labelField,
    minSamplesPerClass,
    scopeType,
    scopeGeometry,
    modelPreferences: settings.model_preferences ?? {},
  });

  if (status === 'queued' && !settings.is_enabled) {
    throw new AppError('AI must be enabled for this project before queueing a run.', 400);
  }

  if (status === 'queued' && readiness.status === 'not_ready') {
    throw new AppError('AI run cannot be queued until readiness blockers are resolved.', 422);
  }

  const currentUser = req.user as Express.UserContext;
  const trainingSamplesAreaType = aiAreaTypeFromScope(scopeType);
  const predictionAreaType = trainingSamplesAreaType;
  const pendingPipelineSettings = [
    'satellite_source',
    'date_range',
    'feature_inputs',
    'prediction_area_type',
    ...(scopeType === 'custom_polygon' ? ['custom_area'] : []),
  ];
  const createdRun = await transaction(async (client: PoolClient) => {
    const runResult = await client.query(
      `INSERT INTO ai_run (
         project_id,
         settings_id,
         status,
         label_field,
         scope_type,
         scope_geometry,
         region_preset,
         training_feature_count,
         eligible_feature_count,
         excluded_feature_count,
         started_by,
         metadata
       )
       VALUES (
         $1,
         $2,
         $3,
         $4,
         $5,
         CASE
           WHEN $6::text IS NULL THEN NULL
           ELSE ST_SetSRID(ST_GeomFromGeoJSON($6::text), 4326)
         END,
         $7,
         $8,
         $9,
         $10,
         $11,
         $12::jsonb
       )
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
        projectId,
        settings.id,
        status,
        labelField,
        scopeType,
        serializeGeometry(scopeGeometry),
        regionPreset,
        readiness.approved_feature_count,
        readiness.eligible_feature_count,
        readiness.excluded_feature_count,
        currentUser.id,
        JSON.stringify({
          readiness_status: readiness.status,
          training_samples_area_type: trainingSamplesAreaType,
          prediction_area_type: predictionAreaType,
          national_scope_enabled: false,
          national_scope_eligibility: readiness.national_scope_eligibility,
          project_bounds: readiness.spatial_extent,
          ai_settings: {
            satellite_source: settings.model_preferences?.satellite_source ?? null,
            target_year: settings.model_preferences?.target_year ?? null,
            season: settings.model_preferences?.season ?? null,
            date_from: settings.model_preferences?.date_from ?? null,
            date_to: settings.model_preferences?.date_to ?? null,
            feature_inputs: settings.model_preferences?.feature_inputs ?? [],
            preferred_model: settings.model_preferences?.preferred_model ?? null,
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
          worker_execution: 'not_started_phase_f',
          execution_mode: executionMode,
          real_ai_execution: false,
          regional_ai_execution_requested: regionalExecutionModes.includes(executionMode),
          scientific_limitations: [
            'Regional proof-of-concept only; not a national model.',
            'AI outputs remain separate from approved spatial_feature data.',
          ],
          requested_by: currentUser.id,
          requested_status: status,
        }),
      ],
    );

    await client.query(
      `INSERT INTO ai_run_log (ai_run_id, level, message, metadata)
       VALUES ($1, 'info', $2, $3::jsonb)`,
      [
        runResult.rows[0].id,
        status === 'queued'
          ? 'AI run queued as a backend placeholder; no worker execution started.'
          : 'AI run draft created; no worker execution started.',
        JSON.stringify({
          phase: 'backend_phase_f',
          readiness_status: readiness.status,
          execution_mode: executionMode,
          real_ai_execution: false,
        }),
      ],
    );

    return runResult.rows[0];
  });

  res.status(201).json({
    success: true,
    message: 'AI run record created. No AI worker has been started.',
    data: normalizeRunRow(createdRun),
  });
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
            updated_at
     FROM ai_run
     WHERE project_id = $1
       ${statusFilter}
     ORDER BY created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, limit, offset],
  );

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
    data: result.rows.map(normalizeRunRow),
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
  const run = await assertRunReadable(req.params.runId, req.user as Express.UserContext);

  res.json({
    success: true,
    data: normalizeRunRow(run),
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
    `SELECT id,
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
            updated_at
     FROM ai_output_layer
     WHERE project_id = $1
       AND status = 'published'
       AND published_at IS NOT NULL
     ORDER BY layer_type ASC, published_at DESC`,
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
    throw new AppError('AI output layer does not reference a GeoJSON preview artifact.', 400);
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

const parseAiLayerFeatureQuery = (
  req: Request,
): {
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
} => {
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
    normalizeOptionalString(properties.class_label) ??
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
    properties.dominant_class,
    properties.class_label,
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

const filterAiLayerFeatures = (
  features: any[],
  options: {
    search: string | null;
    classLabel: string | null;
    featureId: string | null;
  },
): any[] => {
  const search = options.search?.toLowerCase() ?? null;
  const classLabel = options.classLabel?.toLowerCase() ?? null;
  const featureId = options.featureId?.toLowerCase() ?? null;
  if (!search && !classLabel && !featureId) {
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
    'feature_id',
    'source_feature_id',
    'predicted_class',
    'class_label',
    'label',
    'L4_descr',
    'confidence',
    'confidence_score',
    'probability',
    'max_probability',
    'model_name',
    'model',
    'run_id',
    'source',
    'area',
    'area_ha',
    'limitation_note',
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
  const storagePath = normalizeOptionalString(layer.storage_path);
  if (!storagePath) {
    throw new AppError('AI output layer has no registered preview artifact.', 404);
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
    throw new AppError('AI output layer preview artifact was not found.', 404);
  }
  if (!stat.isFile()) {
    throw new AppError('AI output layer preview artifact is not a file.', 400);
  }
  if (stat.size > MAX_AI_LAYER_GEOJSON_BYTES) {
    throw new AppError('AI output layer preview artifact is too large to load directly.', 413);
  }

  let parsed: any;
  try {
    parsed = JSON.parse(await fs.readFile(artifactPath, 'utf8'));
  } catch {
    throw new AppError('AI output layer preview artifact is not valid GeoJSON.', 422);
  }

  if (!parsed || parsed.type !== 'FeatureCollection' || !Array.isArray(parsed.features)) {
    throw new AppError(
      'AI output layer preview artifact must be a GeoJSON FeatureCollection.',
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
    if (layer.status !== 'approved') {
      throw new AppError('Only approved AI layers can be published.', 409);
    }
    if (!previewableLayerTypes.has(layer.layer_type)) {
      throw new AppError('Only map-preview AI layers can be published.', 400);
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

    const updated = await client.query(
      `UPDATE ai_output_layer
       SET status = 'published',
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
      [layer.id, currentUser.id],
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
  getAiRun,
  listAiRunMetrics,
  listAiRunLayers,
  listProjectPublishedAiLayers,
  getAiLayerFeatures,
  listAiRunLogs,
  listAiRunReviews,
  reviewAiRun,
  publishAiLayer,
  unpublishAiLayer,
};

export {};
