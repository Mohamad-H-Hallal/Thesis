import Joi from 'joi';

export interface EnvConfig {
  NODE_ENV: 'development' | 'test' | 'production';
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
  EXPORT_DIR: string;
  EXPORT_RETENTION_DAYS: number;
  EXPORT_CLEANUP_INTERVAL_HOURS: number;
  SUPER_ADMIN_EMAIL: string;
  SUPER_ADMIN_PASSWORD: string;
  SUPER_ADMIN_FULL_NAME: string;
}

const envSchema = Joi.object({
  NODE_ENV: Joi.string().valid('development', 'test', 'production').default('development'),
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
  CORS_CREDENTIALS: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(true),
  API_VERSION_PREFIX: Joi.string().default('/api/v1'),
  ENABLE_LEGACY_API_PREFIX: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(true),
  RATE_LIMIT_WINDOW_MS: Joi.number().integer().min(1000).default(15 * 60 * 1000),
  RATE_LIMIT_MAX_REQUESTS: Joi.number().integer().min(1).default(100),
  RATE_LIMIT_AUTH_MAX_REQUESTS: Joi.number().integer().min(1).default(20),
  RATE_LIMIT_EXPORT_MAX_REQUESTS: Joi.number().integer().min(1).default(40),

  LOG_LEVEL: Joi.string().valid('error', 'warn', 'info', 'http', 'verbose', 'debug', 'silly').default('info'),
  AUDIT_LOG_ENABLED: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(true),
  METRICS_ENABLED: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(false),
  METRICS_TOKEN: Joi.string().allow('').default(''),

  UPLOAD_DIR: Joi.string().default('./uploads'),
  PHOTO_MAX_SIZE: Joi.number().integer().min(1).default(5 * 1024 * 1024),

  EXPORT_DIR: Joi.string().default('./exports'),
  EXPORT_RETENTION_DAYS: Joi.number().integer().min(1).default(7),
  EXPORT_CLEANUP_INTERVAL_HOURS: Joi.number().integer().min(1).default(24),

  SUPER_ADMIN_EMAIL: Joi.string().allow('').default(''),
  SUPER_ADMIN_PASSWORD: Joi.string().allow('').default(''),
  SUPER_ADMIN_FULL_NAME: Joi.string().allow('').default(''),
})
  .unknown(true);

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
      'Environment validation failed: SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD, and SUPER_ADMIN_FULL_NAME must be set together'
    );
  }

  if (value.NODE_ENV === 'production' && !hasCompleteSuperAdminConfig) {
    throw new Error(
      'Environment validation failed: production requires SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD, and SUPER_ADMIN_FULL_NAME'
    );
  }

  return value as EnvConfig;
};

export { validateEnv };

