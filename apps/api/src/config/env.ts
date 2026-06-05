import Joi from 'joi';

export interface EnvConfig {
  NODE_ENV: 'development' | 'test' | 'production';
  MAIL_TRANSPORT: 'mailpit' | 'smtp';
  PORT: number;
  HOST: string;
  TRUST_PROXY: boolean;
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
  LOG_LEVEL: 'error' | 'warn' | 'info' | 'http' | 'verbose' | 'debug' | 'silly';
  AUDIT_LOG_ENABLED: boolean;
  METRICS_ENABLED: boolean;
  METRICS_TOKEN: string;
  UPLOAD_DIR: string;
  PHOTO_MAX_SIZE: number;
  IMPORT_MAX_SIZE: number;
  IMPORT_MAX_FEATURES: number;
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
  AI_PYTHON_BIN: string;
  AI_PIPELINE_TIMEOUT_MS: number;
  AI_PIPELINE_MODE: 'disabled' | 'dry_run' | 'local_ground_truth_export';
}

const envSchema = Joi.object({
  NODE_ENV: Joi.string().valid('development', 'test', 'production').default('development'),
  MAIL_TRANSPORT: Joi.string().valid('mailpit', 'smtp').default('mailpit'),
  PORT: Joi.number().port().default(3000),
  HOST: Joi.string().default('localhost'),
  TRUST_PROXY: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(false),
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

  LOG_LEVEL: Joi.string()
    .valid('error', 'warn', 'info', 'http', 'verbose', 'debug', 'silly')
    .default('info'),
  AUDIT_LOG_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
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
  IMPORT_MAX_SIZE: Joi.number()
    .integer()
    .min(1)
    .default(25 * 1024 * 1024),
  IMPORT_MAX_FEATURES: Joi.number().integer().min(1).max(50000).default(20000),

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
  AI_PYTHON_BIN: Joi.string().allow('').default('python'),
  AI_PIPELINE_TIMEOUT_MS: Joi.number().integer().min(1000).max(600000).default(60000),
  AI_PIPELINE_MODE: Joi.string()
    .valid('disabled', 'dry_run', 'local_ground_truth_export')
    .default('disabled'),
}).unknown(true);

const validateEnv = (): EnvConfig => {
  const { error, value } = envSchema.validate(process.env, { abortEarly: false });
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
    typeof process.env.SMTP_PORT === 'string' && process.env.SMTP_PORT.trim().length > 0;

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

  if (value.PUSH_NOTIFICATIONS_ENABLED) {
    const hasInlineFirebaseConfig =
      String(value.FIREBASE_SERVICE_ACCOUNT_JSON ?? '').trim().length > 0 ||
      String(value.FIREBASE_SERVICE_ACCOUNT_BASE64 ?? '').trim().length > 0 ||
      String(value.FIREBASE_SERVICE_ACCOUNT_PATH ?? '').trim().length > 0 ||
      String(process.env.GOOGLE_APPLICATION_CREDENTIALS ?? '').trim().length > 0;

    if (!hasInlineFirebaseConfig) {
      throw new Error(
        'Environment validation failed: PUSH_NOTIFICATIONS_ENABLED=true requires Firebase service account configuration',
      );
    }
  }

  return value as EnvConfig;
};

export { validateEnv };
