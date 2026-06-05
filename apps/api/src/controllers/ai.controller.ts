import type { PoolClient } from 'pg';
import type { Request, Response } from 'express';
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');

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
];

const regionalExecutionModes = ['regional_feature_extraction', 'regional_model_eval'];

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
}: {
  projectId: string;
  labelField: string | null;
  minSamplesPerClass: number;
  scopeType: string;
}) => {
  const warnings: string[] = [];
  const blockers: string[] = [];
  const hasSourceColumn = await hasSpatialFeatureSourceColumn();

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
    [projectId, labelField],
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
           AND geom IS NOT NULL
           AND ST_IsValid(geom)
           AND NULLIF(BTRIM(attributes ->> $2), '') IS NOT NULL
         GROUP BY class_label
         ORDER BY sample_count DESC, class_label ASC`,
        [projectId, labelField],
      )
    : { rows: [] };

  const sourceCountsResult = hasSourceColumn
    ? await query(
        `SELECT COALESCE(source, 'unknown') AS source,
                COUNT(*)::int AS feature_count
         FROM spatial_feature
         WHERE project_id = $1
           AND status = 'approved'
         GROUP BY COALESCE(source, 'unknown')
         ORDER BY feature_count DESC, source ASC`,
        [projectId],
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
       AND geom IS NOT NULL
       AND ST_IsValid(geom)`,
    [projectId],
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

  if (!allowedExecutionModes.includes(executionMode)) {
    throw new AppError(
      'Unsupported AI execution_mode. Phase F allows only mock, dry_run, local_ground_truth_export, regional_feature_extraction, or regional_model_eval.',
      400,
    );
  }

  if (
    status === 'queued' &&
    regionalExecutionModes.includes(executionMode) &&
    scopeType === 'national'
  ) {
    throw new AppError('Regional AI execution modes cannot be queued with national scope.', 400);
  }

  const readiness = await getFeatureReadinessSummary({
    projectId,
    labelField,
    minSamplesPerClass,
    scopeType,
  });

  if (status === 'queued' && !settings.is_enabled) {
    throw new AppError('AI must be enabled for this project before queueing a run.', 400);
  }

  if (status === 'queued' && readiness.status === 'not_ready') {
    throw new AppError('AI run cannot be queued until readiness blockers are resolved.', 422);
  }

  const currentUser = req.user as Express.UserContext;
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

module.exports = {
  getProjectAiReadiness,
  getProjectAiSettings,
  upsertProjectAiSettings,
  createProjectAiRun,
  listProjectAiRuns,
  getAiRun,
  listAiRunMetrics,
  listAiRunLayers,
  listAiRunLogs,
};

export {};
