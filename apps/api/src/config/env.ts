import Joi from 'joi';

export interface EnvConfig {
  NODE_ENV: 'development' | 'test' | 'production';
  MAIL_TRANSPORT: 'mailpit' | 'smtp';
  PORT: number;
  HOST: string;
  TRUST_PROXY: boolean;
  TRUST_PROXY_HOPS: number;
  ENFORCE_HTTPS: boolean;
  DB_HOST: string;
  DB_PORT: number;
  DB_NAME: string;
  DB_USER: string;
  DB_PASSWORD: string;
  DB_MAX_CONNECTIONS: number;
  JWT_SECRET: string;
  JWT_SECRET_CURRENT: string;
  JWT_SECRET_PREVIOUS: string;
  JWT_EXPIRE: string;
  JWT_REFRESH_SECRET: string;
  JWT_REFRESH_SECRET_CURRENT: string;
  JWT_REFRESH_SECRET_PREVIOUS: string;
  JWT_REFRESH_EXPIRE: string;
  CORS_ORIGIN: string;
  CORS_STRICT: boolean;
  CORS_CREDENTIALS: boolean;
  API_VERSION_PREFIX: string;
  ENABLE_LEGACY_API_PREFIX: boolean;
  RATE_LIMIT_WINDOW_MS: number;
  RATE_LIMIT_MAX_REQUESTS: number;
  RATE_LIMIT_AUTH_MAX_REQUESTS: number;
  RATE_LIMIT_EXPORT_MAX_REQUESTS: number;
  RATE_LIMIT_STORE: 'memory' | 'redis';
  REDIS_URL: string;
  REDIS_PASSWORD: string;
  REDIS_CONNECT_TIMEOUT_MS: number;
  RATE_LIMIT_WORKLOAD_WINDOW_MS: number;
  RATE_LIMIT_IMPORT_MAX_REQUESTS: number;
  RATE_LIMIT_AI_JOB_MAX_REQUESTS: number;
  RATE_LIMIT_MAP_MAX_REQUESTS: number;
  RATE_LIMIT_NOTIFICATION_MAX_REQUESTS: number;
  RATE_LIMIT_PASSWORD_RESET_MAX_REQUESTS: number;
  WORKLOAD_WORKER_MODE: 'inline' | 'external' | 'disabled';
  WORKLOAD_WORKER_CONCURRENCY: number;
  WORKLOAD_POLL_INTERVAL_MS: number;
  WORKLOAD_LEASE_MS: number;
  WORKLOAD_JOB_TIMEOUT_MS: number;
  WORKLOAD_MAX_ATTEMPTS: number;
  WORKLOAD_HARD_EXIT_ON_TIMEOUT: boolean;
  OFFLINE_SYNC_RATE_LIMIT_WINDOW_MS: number;
  OFFLINE_SYNC_RATE_LIMIT_MAX_REQUESTS: number;
  OFFLINE_SYNC_INGRESS_RATE_LIMIT_MAX_REQUESTS: number;
  LOG_LEVEL: 'error' | 'warn' | 'info' | 'http' | 'verbose' | 'debug' | 'silly';
  LOG_PRETTY: boolean;
  LOG_TO_FILE: boolean;
  AUDIT_LOG_ENABLED: boolean;
  API_DOCS_ENABLED: boolean;
  API_DOCS_TOKEN: string;
  METRICS_ENABLED: boolean;
  METRICS_TOKEN: string;
  UPLOAD_DIR: string;
  PHOTO_MAX_SIZE: number;
  PHOTO_MAX_WIDTH: number;
  PHOTO_MAX_HEIGHT: number;
  PHOTO_MAX_PIXELS: number;
  IMPORT_MAX_SIZE: number;
  IMPORT_MAX_FEATURES: number;
  MALWARE_SCANNER_MODE: 'disabled' | 'clamav';
  CLAMAV_HOST: string;
  CLAMAV_PORT: number;
  CLAMAV_TIMEOUT_MS: number;
  CLAMAV_MAX_STREAM_BYTES: number;
  ARCHIVE_MAX_ENTRIES: number;
  ARCHIVE_MAX_EXPANDED_BYTES: number;
  ARCHIVE_MAX_ENTRY_BYTES: number;
  ARCHIVE_MAX_COMPRESSION_RATIO: number;
  EXPORT_DIR: string;
  EXPORT_RETENTION_DAYS: number;
  EXPORT_CLEANUP_INTERVAL_HOURS: number;
  NOTIFICATION_MAINTENANCE_INTERVAL_MINUTES: number;
  NOTIFICATION_EMAIL_BATCH_SIZE: number;
  NOTIFICATION_EMAIL_MAX_ATTEMPTS: number;
  PUSH_NOTIFICATIONS_ENABLED: boolean;
  ANDROID_PUSH_NOTIFICATIONS_ENABLED: boolean;
  IOS_PUSH_NOTIFICATIONS_ENABLED: boolean;
  NOTIFICATION_PUSH_BATCH_SIZE: number;
  NOTIFICATION_PUSH_MAX_ATTEMPTS: number;
  FIREBASE_SERVICE_ACCOUNT_JSON: string;
  FIREBASE_SERVICE_ACCOUNT_BASE64: string;
  FIREBASE_SERVICE_ACCOUNT_PATH: string;
  PASSWORD_RESET_TOKEN_EXPIRY_MINUTES: number;
  PASSWORD_RESET_REQUIRE_REAL_DELIVERY: boolean;
  SMTP_HOST: string;
  SMTP_PORT: number;
  SMTP_SECURE: boolean;
  SMTP_USER: string;
  SMTP_PASS: string;
  SMTP_FROM_EMAIL: string;
  SMTP_FROM_NAME: string;
  SUPER_ADMIN_EMAIL: string;
  SUPER_ADMIN_PASSWORD: string;
  SUPER_ADMIN_FULL_NAME: string;
  AI_PIPELINE_ENABLED: boolean;
  AI_PIPELINE_ROOT: string;
  AI_PIPELINE_OUTPUT_ROOT: string;
  AI_PYTHON_BIN: string;
  AI_PIPELINE_TIMEOUT_MS: number;
  AI_PIPELINE_MODE:
    | 'disabled'
    | 'dry_run'
    | 'local_ground_truth_export'
    | 'regional_feature_extraction'
    | 'regional_model_eval'
    | 'regional_classification'
    | 'regional_vectorization_artifacts'
    | 'regional_full_review_artifacts';
  AI_SERVER_URL: string;
  APP_PUBLIC_API_URL: string;
  AI_CALLBACK_BASE_URL: string;
  AI_CALLBACK_SECRET: string;
  AI_SERVER_TIMEOUT_MS: number;
}

export interface WorkloadWorkerEnvConfig {
  NODE_ENV: 'development' | 'test' | 'production';
  DB_HOST: string;
  DB_PORT: number;
  DB_NAME: string;
  DB_USER: string;
  DB_PASSWORD: string;
  DB_MAX_CONNECTIONS: number;
  WORKLOAD_WORKER_MODE: 'inline' | 'external' | 'disabled';
  WORKLOAD_HARD_EXIT_ON_TIMEOUT: boolean;
  LOG_PRETTY: boolean;
  LOG_TO_FILE: boolean;
}

const envSchema = Joi.object({
  NODE_ENV: Joi.string().valid('development', 'test', 'production').default('development'),
  MAIL_TRANSPORT: Joi.string().valid('mailpit', 'smtp').default('mailpit'),
  PORT: Joi.number().port().default(3000),
  HOST: Joi.string().default('localhost'),
  TRUST_PROXY: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(false),
  TRUST_PROXY_HOPS: Joi.number().integer().min(1).max(5).default(1),
  ENFORCE_HTTPS: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(false),

  DB_HOST: Joi.string().required(),
  DB_PORT: Joi.number().port().required(),
  DB_NAME: Joi.string().required(),
  DB_USER: Joi.string().required(),
  DB_PASSWORD: Joi.string().required(),
  DB_MAX_CONNECTIONS: Joi.number().integer().min(1).default(20),

  JWT_SECRET: Joi.string().min(32).required(),
  JWT_SECRET_CURRENT: Joi.string().min(32).optional(),
  JWT_SECRET_PREVIOUS: Joi.string().allow('').default(''),
  JWT_EXPIRE: Joi.string().default('7d'),
  JWT_REFRESH_SECRET: Joi.string().min(32).required(),
  JWT_REFRESH_SECRET_CURRENT: Joi.string().min(32).optional(),
  JWT_REFRESH_SECRET_PREVIOUS: Joi.string().allow('').default(''),
  JWT_REFRESH_EXPIRE: Joi.string().default('30d'),

  CORS_ORIGIN: Joi.string().allow('').default(''),
  CORS_STRICT: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(true),
  CORS_CREDENTIALS: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  API_VERSION_PREFIX: Joi.string().default('/api/v1'),
  ENABLE_LEGACY_API_PREFIX: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  RATE_LIMIT_WINDOW_MS: Joi.number()
    .integer()
    .min(1000)
    .default(15 * 60 * 1000),
  RATE_LIMIT_MAX_REQUESTS: Joi.number().integer().min(1).default(100),
  RATE_LIMIT_AUTH_MAX_REQUESTS: Joi.number().integer().min(1).default(20),
  RATE_LIMIT_EXPORT_MAX_REQUESTS: Joi.number().integer().min(1).default(40),
  RATE_LIMIT_STORE: Joi.string().valid('memory', 'redis').default('memory'),
  REDIS_URL: Joi.string()
    .uri({ scheme: ['redis', 'rediss'] })
    .allow('')
    .default(''),
  REDIS_PASSWORD: Joi.string().allow('').default(''),
  REDIS_CONNECT_TIMEOUT_MS: Joi.number().integer().min(1000).max(60000).default(5000),
  RATE_LIMIT_WORKLOAD_WINDOW_MS: Joi.number().integer().min(1000).default(60000),
  RATE_LIMIT_IMPORT_MAX_REQUESTS: Joi.number().integer().min(1).default(6),
  RATE_LIMIT_AI_JOB_MAX_REQUESTS: Joi.number().integer().min(1).default(10),
  RATE_LIMIT_MAP_MAX_REQUESTS: Joi.number().integer().min(1).default(60),
  RATE_LIMIT_NOTIFICATION_MAX_REQUESTS: Joi.number().integer().min(1).default(30),
  RATE_LIMIT_PASSWORD_RESET_MAX_REQUESTS: Joi.number().integer().min(1).default(5),
  WORKLOAD_WORKER_MODE: Joi.string().valid('inline', 'external', 'disabled').default('inline'),
  WORKLOAD_WORKER_CONCURRENCY: Joi.number().integer().min(1).max(16).default(2),
  WORKLOAD_POLL_INTERVAL_MS: Joi.number().integer().min(100).max(60000).default(1000),
  WORKLOAD_LEASE_MS: Joi.number().integer().min(10000).max(3600000).default(300000),
  WORKLOAD_JOB_TIMEOUT_MS: Joi.number().integer().min(10000).max(7200000).default(1800000),
  WORKLOAD_MAX_ATTEMPTS: Joi.number().integer().min(1).max(20).default(3),
  WORKLOAD_HARD_EXIT_ON_TIMEOUT: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  OFFLINE_SYNC_RATE_LIMIT_WINDOW_MS: Joi.number().integer().min(1000).default(60000),
  OFFLINE_SYNC_RATE_LIMIT_MAX_REQUESTS: Joi.number().integer().min(1).default(60),
  OFFLINE_SYNC_INGRESS_RATE_LIMIT_MAX_REQUESTS: Joi.number().integer().min(1).default(240),

  LOG_LEVEL: Joi.string()
    .valid('error', 'warn', 'info', 'http', 'verbose', 'debug', 'silly')
    .default('info'),
  LOG_PRETTY: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  LOG_TO_FILE: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  AUDIT_LOG_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  API_DOCS_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  API_DOCS_TOKEN: Joi.string().allow('').default(''),
  METRICS_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  METRICS_TOKEN: Joi.string().allow('').default(''),

  UPLOAD_DIR: Joi.string().default('./uploads'),
  PHOTO_MAX_SIZE: Joi.number()
    .integer()
    .min(1)
    .default(5 * 1024 * 1024),
  PHOTO_MAX_WIDTH: Joi.number().integer().min(1).default(10000),
  PHOTO_MAX_HEIGHT: Joi.number().integer().min(1).default(10000),
  PHOTO_MAX_PIXELS: Joi.number().integer().min(1).default(40000000),
  IMPORT_MAX_SIZE: Joi.number()
    .integer()
    .min(1)
    .default(25 * 1024 * 1024),
  IMPORT_MAX_FEATURES: Joi.number().integer().min(1).max(50000).default(20000),
  MALWARE_SCANNER_MODE: Joi.string().valid('disabled', 'clamav').default('disabled'),
  CLAMAV_HOST: Joi.string().hostname().default('clamav'),
  CLAMAV_PORT: Joi.number().port().default(3310),
  CLAMAV_TIMEOUT_MS: Joi.number().integer().min(1000).max(120000).default(15000),
  CLAMAV_MAX_STREAM_BYTES: Joi.number()
    .integer()
    .min(1024)
    .default(30 * 1024 * 1024),
  ARCHIVE_MAX_ENTRIES: Joi.number().integer().min(1).max(10000).default(1000),
  ARCHIVE_MAX_EXPANDED_BYTES: Joi.number()
    .integer()
    .min(1024)
    .default(100 * 1024 * 1024),
  ARCHIVE_MAX_ENTRY_BYTES: Joi.number()
    .integer()
    .min(1024)
    .default(50 * 1024 * 1024),
  ARCHIVE_MAX_COMPRESSION_RATIO: Joi.number().integer().min(1).max(10000).default(100),

  EXPORT_DIR: Joi.string().default('./exports'),
  EXPORT_RETENTION_DAYS: Joi.number().integer().min(1).default(7),
  EXPORT_CLEANUP_INTERVAL_HOURS: Joi.number().integer().min(1).default(24),
  NOTIFICATION_MAINTENANCE_INTERVAL_MINUTES: Joi.number().integer().min(1).default(60),
  NOTIFICATION_EMAIL_BATCH_SIZE: Joi.number().integer().min(1).max(500).default(50),
  NOTIFICATION_EMAIL_MAX_ATTEMPTS: Joi.number().integer().min(1).max(20).default(5),
  PUSH_NOTIFICATIONS_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  ANDROID_PUSH_NOTIFICATIONS_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(Joi.ref('PUSH_NOTIFICATIONS_ENABLED')),
  IOS_PUSH_NOTIFICATIONS_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  NOTIFICATION_PUSH_BATCH_SIZE: Joi.number().integer().min(1).max(500).default(100),
  NOTIFICATION_PUSH_MAX_ATTEMPTS: Joi.number().integer().min(1).max(20).default(5),
  FIREBASE_SERVICE_ACCOUNT_JSON: Joi.string().allow('').default(''),
  FIREBASE_SERVICE_ACCOUNT_BASE64: Joi.string().allow('').default(''),
  FIREBASE_SERVICE_ACCOUNT_PATH: Joi.string().allow('').default(''),
  PASSWORD_RESET_TOKEN_EXPIRY_MINUTES: Joi.number().integer().min(5).max(60).default(15),
  PASSWORD_RESET_REQUIRE_REAL_DELIVERY: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),

  SMTP_HOST: Joi.string().allow('').default(''),
  SMTP_PORT: Joi.number().port().default(1025),
  SMTP_SECURE: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(false),
  SMTP_USER: Joi.string().allow('').default(''),
  SMTP_PASS: Joi.string().allow('').default(''),
  SMTP_FROM_EMAIL: Joi.string()
    .email({ tlds: { allow: false } })
    .allow('')
    .default(''),
  SMTP_FROM_NAME: Joi.string().allow('').default('Lebanese GIS Collector'),

  SUPER_ADMIN_EMAIL: Joi.string().allow('').default(''),
  SUPER_ADMIN_PASSWORD: Joi.string().allow('').default(''),
  SUPER_ADMIN_FULL_NAME: Joi.string().allow('').default(''),
  AI_PIPELINE_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  AI_PIPELINE_ROOT: Joi.string().allow('').default(''),
  AI_PIPELINE_OUTPUT_ROOT: Joi.string().allow('').default(''),
  AI_PYTHON_BIN: Joi.string().allow('').default('python'),
  AI_PIPELINE_TIMEOUT_MS: Joi.number().integer().min(1000).max(600000).default(60000),
  AI_PIPELINE_MODE: Joi.string()
    .valid(
      'disabled',
      'dry_run',
      'local_ground_truth_export',
      'regional_feature_extraction',
      'regional_model_eval',
      'regional_classification',
      'regional_vectorization_artifacts',
      'regional_full_review_artifacts',
    )
    .default('disabled'),
  AI_SERVER_URL: Joi.string().allow('').default(''),
  APP_PUBLIC_API_URL: Joi.string().allow('').default('http://localhost:3000'),
  AI_CALLBACK_BASE_URL: Joi.string().allow('').default(''),
  AI_CALLBACK_SECRET: Joi.string().allow('').default('dev-ai-callback-secret-change-me'),
  AI_SERVER_TIMEOUT_MS: Joi.number().integer().min(1000).max(120000).default(30000),
}).unknown(true);

const unsafeProductionSecret = (value: unknown): boolean => {
  const normalized = String(value ?? '').trim().toLowerCase();
  return (
    normalized.length < 16 ||
    [
      'change_me',
      'changeme',
      'password',
      'replace-',
      'replace_',
      'example',
      'dev-',
      'test-',
    ].some((marker) => normalized.includes(marker))
  );
};

const unsafeProductionIdentifier = (value: unknown): boolean => {
  const normalized = String(value ?? '').trim().toLowerCase();
  return (
    normalized.length === 0 ||
    ['change_me', 'changeme', 'replace-', 'replace_', 'example'].some((marker) =>
      normalized.includes(marker),
    )
  );
};

const validateProductionOrigin = (origin: string): boolean => {
  try {
    const parsed = new URL(origin);
    const normalizedHostname = parsed.hostname.toLowerCase();
    const hostnameLabels = normalizedHostname.split('.');
    const isReservedHostname =
      normalizedHostname === 'localhost' ||
      normalizedHostname === '127.0.0.1' ||
      normalizedHostname === '::1' ||
      normalizedHostname.endsWith('.localhost') ||
      normalizedHostname.endsWith('.example') ||
      normalizedHostname.endsWith('.invalid') ||
      normalizedHostname.endsWith('.test') ||
      hostnameLabels.includes('example');
    return (
      parsed.protocol === 'https:' &&
      parsed.username === '' &&
      parsed.password === '' &&
      !isReservedHostname &&
      parsed.pathname === '/' &&
      parsed.search === '' &&
      parsed.hash === ''
    );
  } catch {
    return false;
  }
};

const validateEnv = (source: NodeJS.ProcessEnv = process.env): EnvConfig => {
  const { error, value } = envSchema.validate(source, { abortEarly: false });
  if (error) {
    const details = error.details.map((d: { message: string }) => d.message).join('; ');
    throw new Error(`Environment validation failed: ${details}`);
  }

  if (!value.JWT_SECRET_CURRENT) {
    value.JWT_SECRET_CURRENT = value.JWT_SECRET;
  }
  if (!value.JWT_REFRESH_SECRET_CURRENT) {
    value.JWT_REFRESH_SECRET_CURRENT = value.JWT_REFRESH_SECRET;
  }

  const hasSuperAdminConfig = [
    value.SUPER_ADMIN_EMAIL,
    value.SUPER_ADMIN_PASSWORD,
    value.SUPER_ADMIN_FULL_NAME,
  ].some((item: string) => item.trim().length > 0);
  const hasCompleteSuperAdminConfig = [
    value.SUPER_ADMIN_EMAIL,
    value.SUPER_ADMIN_PASSWORD,
    value.SUPER_ADMIN_FULL_NAME,
  ].every((item: string) => item.trim().length > 0);

  if (hasSuperAdminConfig && !hasCompleteSuperAdminConfig) {
    throw new Error(
      'Environment validation failed: SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD, and SUPER_ADMIN_FULL_NAME must be set together',
    );
  }

  if (value.NODE_ENV === 'production' && !hasCompleteSuperAdminConfig) {
    throw new Error(
      'Environment validation failed: production requires SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD, and SUPER_ADMIN_FULL_NAME',
    );
  }

  const hasSmtpConfig = [value.SMTP_HOST, value.SMTP_FROM_EMAIL].every(
    (item: string) => item.trim().length > 0,
  );
  const hasExplicitSmtpPort =
    typeof source.SMTP_PORT === 'string' && source.SMTP_PORT.trim().length > 0;

  if (value.MAIL_TRANSPORT === 'smtp' && (!hasSmtpConfig || !hasExplicitSmtpPort)) {
    throw new Error(
      'Environment validation failed: MAIL_TRANSPORT=smtp requires SMTP_HOST, SMTP_PORT, and SMTP_FROM_EMAIL',
    );
  }

  if (value.NODE_ENV === 'production' && value.MAIL_TRANSPORT !== 'smtp') {
    throw new Error('Environment validation failed: production requires MAIL_TRANSPORT=smtp');
  }

  if (value.NODE_ENV === 'production' && !hasSmtpConfig) {
    throw new Error(
      'Environment validation failed: production requires SMTP_HOST and SMTP_FROM_EMAIL',
    );
  }

  if (value.NODE_ENV === 'production') {
    if (!value.TRUST_PROXY || !value.ENFORCE_HTTPS) {
      throw new Error(
        'Environment validation failed: production requires TRUST_PROXY=true and ENFORCE_HTTPS=true',
      );
    }

    const productionOrigins = String(value.CORS_ORIGIN)
      .split(',')
      .map((origin) => origin.trim())
      .filter(Boolean);
    if (
      !value.CORS_STRICT ||
      productionOrigins.length === 0 ||
      productionOrigins.some((origin) => !validateProductionOrigin(origin))
    ) {
      throw new Error(
        'Environment validation failed: production requires strict explicit HTTPS CORS origins',
      );
    }

    if (value.ENABLE_LEGACY_API_PREFIX) {
      throw new Error(
        'Environment validation failed: production requires ENABLE_LEGACY_API_PREFIX=false',
      );
    }

    if (!value.METRICS_ENABLED || unsafeProductionSecret(value.METRICS_TOKEN)) {
      throw new Error(
        'Environment validation failed: production requires protected metrics with a non-placeholder token',
      );
    }

    if (value.API_DOCS_ENABLED && unsafeProductionSecret(value.API_DOCS_TOKEN)) {
      throw new Error(
        'Environment validation failed: enabled production API docs require a non-placeholder token',
      );
    }

    if (value.LOG_PRETTY || value.LOG_TO_FILE) {
      throw new Error(
        'Environment validation failed: production requires redacted JSON logs on stdout (LOG_PRETTY=false, LOG_TO_FILE=false)',
      );
    }

    if (!value.PASSWORD_RESET_REQUIRE_REAL_DELIVERY) {
      throw new Error(
        'Environment validation failed: production requires PASSWORD_RESET_REQUIRE_REAL_DELIVERY=true',
      );
    }

    let publicApiUrl: URL;
    try {
      publicApiUrl = new URL(String(value.APP_PUBLIC_API_URL));
    } catch {
      throw new Error(
        'Environment validation failed: APP_PUBLIC_API_URL must be a valid production HTTPS URL',
      );
    }
    if (
      publicApiUrl.protocol !== 'https:' ||
      publicApiUrl.username ||
      publicApiUrl.password ||
      !validateProductionOrigin(publicApiUrl.origin)
    ) {
      throw new Error(
        'Environment validation failed: APP_PUBLIC_API_URL must be a public HTTPS URL in production',
      );
    }

    const requiredStrongSecrets = [
      ['DB_PASSWORD', value.DB_PASSWORD],
      ['JWT_SECRET_CURRENT', value.JWT_SECRET_CURRENT],
      ['JWT_REFRESH_SECRET_CURRENT', value.JWT_REFRESH_SECRET_CURRENT],
      ['SUPER_ADMIN_PASSWORD', value.SUPER_ADMIN_PASSWORD],
    ] as const;
    const unsafeSecrets = requiredStrongSecrets
      .filter(([, secret]) => unsafeProductionSecret(secret))
      .map(([name]) => name);
    if (unsafeSecrets.length > 0) {
      throw new Error(
        `Environment validation failed: insecure or placeholder production secrets: ${unsafeSecrets.join(', ')}`,
      );
    }

    const hasSmtpUser = String(value.SMTP_USER).trim().length > 0;
    const hasSmtpPassword = String(value.SMTP_PASS).trim().length > 0;
    if (hasSmtpUser !== hasSmtpPassword) {
      throw new Error(
        'Environment validation failed: SMTP_USER and SMTP_PASS must be set together',
      );
    }
    if (hasSmtpPassword && unsafeProductionSecret(value.SMTP_PASS)) {
      throw new Error(
        'Environment validation failed: SMTP_PASS must not be a placeholder in production',
      );
    }
    if (hasSmtpUser && unsafeProductionIdentifier(value.SMTP_USER)) {
      throw new Error(
        'Environment validation failed: SMTP_USER must not be a placeholder in production',
      );
    }

    if (
      String(value.AI_CALLBACK_SECRET).trim().length > 0 &&
      unsafeProductionSecret(value.AI_CALLBACK_SECRET)
    ) {
      throw new Error(
        'Environment validation failed: AI_CALLBACK_SECRET must not be a placeholder in production',
      );
    }
  }

  if (value.NODE_ENV === 'production' && value.MALWARE_SCANNER_MODE !== 'clamav') {
    throw new Error(
      'Environment validation failed: production requires MALWARE_SCANNER_MODE=clamav',
    );
  }

  if (value.RATE_LIMIT_STORE === 'redis' && !String(value.REDIS_URL).trim()) {
    throw new Error(
      'Environment validation failed: RATE_LIMIT_STORE=redis requires REDIS_URL',
    );
  }

  if (value.NODE_ENV === 'production' && value.RATE_LIMIT_STORE !== 'redis') {
    throw new Error(
      'Environment validation failed: production requires RATE_LIMIT_STORE=redis',
    );
  }

  if (value.NODE_ENV === 'production' && value.WORKLOAD_WORKER_MODE !== 'external') {
    throw new Error(
      'Environment validation failed: production requires WORKLOAD_WORKER_MODE=external',
    );
  }

  if (value.NODE_ENV === 'production' && !value.WORKLOAD_HARD_EXIT_ON_TIMEOUT) {
    throw new Error(
      'Environment validation failed: production requires WORKLOAD_HARD_EXIT_ON_TIMEOUT=true',
    );
  }

  if (value.CLAMAV_MAX_STREAM_BYTES < Math.max(value.IMPORT_MAX_SIZE, value.PHOTO_MAX_SIZE)) {
    throw new Error(
      'Environment validation failed: CLAMAV_MAX_STREAM_BYTES must cover the largest configured upload',
    );
  }

  if (value.PUSH_NOTIFICATIONS_ENABLED) {
    const hasInlineFirebaseConfig =
      String(value.FIREBASE_SERVICE_ACCOUNT_JSON ?? '').trim().length > 0 ||
      String(value.FIREBASE_SERVICE_ACCOUNT_BASE64 ?? '').trim().length > 0 ||
      String(value.FIREBASE_SERVICE_ACCOUNT_PATH ?? '').trim().length > 0 ||
      String(source.GOOGLE_APPLICATION_CREDENTIALS ?? '').trim().length > 0;

    if (!hasInlineFirebaseConfig) {
      throw new Error(
        'Environment validation failed: PUSH_NOTIFICATIONS_ENABLED=true requires Firebase service account configuration',
      );
    }
  }

  return value as EnvConfig;
};

const workloadWorkerEnvSchema = Joi.object({
  NODE_ENV: Joi.string().valid('development', 'test', 'production').default('development'),
  DB_HOST: Joi.string().required(),
  DB_PORT: Joi.number().port().required(),
  DB_NAME: Joi.string().required(),
  DB_USER: Joi.string().required(),
  DB_PASSWORD: Joi.string().required(),
  DB_MAX_CONNECTIONS: Joi.number().integer().min(1).default(20),
  WORKLOAD_WORKER_MODE: Joi.string().valid('inline', 'external', 'disabled').default('inline'),
  WORKLOAD_HARD_EXIT_ON_TIMEOUT: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  LOG_PRETTY: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  LOG_TO_FILE: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
}).unknown(true);

const validateWorkloadWorkerEnv = (
  source: NodeJS.ProcessEnv = process.env,
): WorkloadWorkerEnvConfig => {
  const { error, value } = workloadWorkerEnvSchema.validate(source, { abortEarly: false });
  if (error) {
    const details = error.details.map((detail: { message: string }) => detail.message).join('; ');
    throw new Error(`Workload worker environment validation failed: ${details}`);
  }

  if (value.NODE_ENV === 'production') {
    if (unsafeProductionSecret(value.DB_PASSWORD)) {
      throw new Error(
        'Workload worker environment validation failed: DB_PASSWORD is insecure or a placeholder',
      );
    }
    if (value.WORKLOAD_WORKER_MODE !== 'external' || !value.WORKLOAD_HARD_EXIT_ON_TIMEOUT) {
      throw new Error(
        'Workload worker environment validation failed: production requires an external worker with hard timeout exit',
      );
    }
    if (value.LOG_PRETTY || value.LOG_TO_FILE) {
      throw new Error(
        'Workload worker environment validation failed: production requires redacted JSON stdout logs',
      );
    }
  }

  return value as WorkloadWorkerEnvConfig;
};

export { validateEnv, validateWorkloadWorkerEnv };
