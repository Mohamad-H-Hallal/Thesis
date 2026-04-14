const { AppError } = require('../middleware/error');

const defaultAllowedGeometryTypes = ['Point', 'LineString', 'Polygon'] as const;
const defaultCollectionSchemaVersion = 'v1.0';
const defaultMaxGpsAccuracyMeters = 25;

type NormalizedFieldType = 'text' | 'textarea' | 'number' | 'select' | 'boolean' | 'date';

interface RawFieldSchema {
  key?: unknown;
  label?: unknown;
  name?: unknown;
  type?: unknown;
  required?: unknown;
  options?: unknown;
  hint?: unknown;
  min?: unknown;
  max?: unknown;
  unit?: unknown;
}

interface NormalizedFieldSchema {
  key: string;
  label: string;
  type: NormalizedFieldType;
  required: boolean;
  options: string[];
  hint?: string;
  min?: number;
  max?: number;
  unit?: string;
}

const normalizeString = (value: unknown): string => String(value ?? '').trim();

const normalizeNumeric = (value: unknown): number | undefined => {
  const raw = normalizeString(value);
  if (!raw) {
    return undefined;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : undefined;
};

const slugifyFieldKey = (label: string, fallbackIndex: number): string => {
  const normalized = label
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .replace(/_+/g, '_');
  return normalized || `field_${fallbackIndex + 1}`;
};

const normalizeFieldType = (value: unknown): NormalizedFieldType => {
  const raw = normalizeString(value).toLowerCase();
  switch (raw) {
    case 'textarea':
    case 'multiline':
    case 'long_text':
      return 'textarea';
    case 'number':
    case 'integer':
    case 'int':
    case 'float':
    case 'decimal':
      return 'number';
    case 'select':
    case 'dropdown':
    case 'choice':
    case 'combo':
      return 'select';
    case 'boolean':
    case 'bool':
      return 'boolean';
    case 'date':
      return 'date';
    default:
      return 'text';
  }
};

const normalizeOptions = (value: unknown): string[] => {
  if (Array.isArray(value)) {
    return Array.from(
      new Set(
        value
          .map((item) => normalizeString(item))
          .filter(Boolean),
      ),
    );
  }

  const raw = normalizeString(value);
  if (!raw) {
    return [];
  }

  return Array.from(
    new Set(
      raw
        .split(/\r?\n|,/)
        .map((item) => item.trim())
        .filter(Boolean),
    ),
  );
};

const looksLikeFeatureTitleField = (field: NormalizedFieldSchema): boolean => {
  const haystack = `${field.key} ${field.label}`.toLowerCase();
  return haystack.includes('feature_type') ||
    haystack.includes('feature type') ||
    haystack.includes('feature name') ||
    haystack.includes('tree') ||
    haystack.includes('species') ||
    haystack.includes('crop') ||
    haystack.includes('orchard') ||
    haystack.includes('variety');
};

const normalizeFieldSchema = (field: RawFieldSchema, index: number): NormalizedFieldSchema => {
  const label = normalizeString(field.label ?? field.name ?? field.key);
  const key = normalizeString(field.key) || slugifyFieldKey(label, index);
  const type = normalizeFieldType(field.type);
  const options = type === 'select' ? normalizeOptions(field.options) : [];

  return {
    key,
    label: label || key,
    type,
    required: field.required === true,
    options,
    hint: normalizeString(field.hint) || undefined,
    min: type === 'number' ? normalizeNumeric(field.min) : undefined,
    max: type === 'number' ? normalizeNumeric(field.max) : undefined,
    unit: type === 'number' ? normalizeString(field.unit) || undefined : undefined,
  };
};

const normalizeCollectionFormSchema = (schemaInput: unknown): Record<string, unknown> => {
  if (!schemaInput || typeof schemaInput !== 'object' || Array.isArray(schemaInput)) {
    throw new AppError('collection_form_schema must be a JSON object', 422);
  }

  const schema = schemaInput as Record<string, unknown>;
  const rawFields = Array.isArray(schema.fields) ? schema.fields : [];
  const fields = rawFields
    .map((rawField, index) => normalizeFieldSchema(rawField as RawFieldSchema, index))
    .filter((field) => field.label.trim().length > 0);

  if (fields.length === 0) {
    throw new AppError(
      'Add a required feature type field with at least one option before saving this project.',
      422,
    );
  }

  const keys = new Set<string>();
  for (const field of fields) {
    if (keys.has(field.key)) {
      throw new AppError(`Collection field keys must be unique. Duplicate key: ${field.key}`, 422);
    }
    keys.add(field.key);

    if (field.type === 'select' && field.required && field.options.length === 0) {
      throw new AppError(`Field "${field.label}" requires at least one option.`, 422);
    }
  }

  const hasFeatureTitleField = fields.some(
    (field) =>
      field.type === 'select' &&
      field.required &&
      field.options.length > 0 &&
      looksLikeFeatureTitleField(field),
  );

  if (!hasFeatureTitleField) {
    throw new AppError(
      'Add a required feature type field with at least one option before saving this project.',
      422,
    );
  }

  return {
    version: normalizeString(schema.version ?? schema.schemaVersion) || defaultCollectionSchemaVersion,
    allowedGeometryTypes: [...defaultAllowedGeometryTypes],
    maxGpsAccuracyMeters: defaultMaxGpsAccuracyMeters,
    fields,
  };
};

export {
  defaultAllowedGeometryTypes,
  defaultCollectionSchemaVersion,
  defaultMaxGpsAccuracyMeters,
  looksLikeFeatureTitleField,
  normalizeCollectionFormSchema,
};
