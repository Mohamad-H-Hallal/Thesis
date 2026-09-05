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
  JWT_ISSUER: string;
  JWT_AUDIENCE: string;
  JWT_REFRESH_SECRET: string;
  JWT_REFRESH_SECRET_CURRENT: string;
  JWT_REFRESH_SECRET_PREVIOUS: string;
  JWT_REFRESH_EXPIRE: string;
  CORS_ORIGIN: string;
  CORS_STRICT: boolean;
  CORS_CREDENTIALS: boolean;
  API_VERSION_PREFIX: string;
  ENABLE_LEGACY_API_PREFIX: boolean;
  REALTIME_V2_ENABLED: boolean;
  REALTIME_LEGACY_BROADCAST_ENABLED: boolean;
  REALTIME_POLLING_FALLBACK_ENABLED: boolean;
  REALTIME_AUTH_TIMEOUT_MS: number;
  REALTIME_HEARTBEAT_INTERVAL_MS: number;
  REALTIME_MAX_CONNECTIONS_PER_USER: number;
  REALTIME_MAX_CONNECTIONS_PER_IP: number;
  REALTIME_MAX_BUFFERED_BYTES: number;
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
  RATE_LIMIT_VERIFICATION_MAX_REQUESTS: number;
  RATE_LIMIT_PRIVACY_REQUEST_MAX_REQUESTS: number;
  RATE_LIMIT_PUBLIC_PRIVACY_REQUEST_MAX_REQUESTS: number;
  RATE_LIMIT_CONTENT_REPORT_MAX_REQUESTS: number;
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
  LOG_DIR: string;
  LOG_MAX_SIZE: string;
  LOG_RETENTION_DAYS: number;
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
  STORAGE_DRIVER: 'local' | 's3';
  STORAGE_TEMP_DIR: string;
  STORAGE_MAX_OBJECT_BYTES: number;
  STORAGE_S3_ENDPOINT: string;
  STORAGE_S3_REGION: string;
  STORAGE_S3_FORCE_PATH_STYLE: boolean;
  STORAGE_S3_ACCESS_KEY_ID: string;
  STORAGE_S3_SECRET_ACCESS_KEY: string;
  STORAGE_S3_UPLOADS_BUCKET: string;
  STORAGE_S3_EXPORTS_BUCKET: string;
  STORAGE_S3_OFFLINE_BUCKET: string;
  STORAGE_S3_AI_BUCKET: string;
  STORAGE_S3_BACKUPS_BUCKET: string;
  STORAGE_S3_PREFIX: string;
  STORAGE_S3_REQUEST_TIMEOUT_MS: number;
  STORAGE_S3_MAX_ATTEMPTS: number;
  STORAGE_S3_PROVIDER: 'digitalocean_spaces' | 'oci';
  STORAGE_S3_SERVER_SIDE_ENCRYPTION: 'AES256' | 'SSE-C';
  STORAGE_S3_CUSTOMER_KEY_BASE64: string;
  EXPORT_DIR: string;
  EXPORT_RETENTION_DAYS: number;
  EXPORT_CLEANUP_INTERVAL_HOURS: number;
  PRIVACY_EXPORT_DIR: string;
  PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64: string;
  PRIVACY_EXPORT_ENCRYPTION_KEY_ID: string;
  PRIVACY_EXPORT_TTL_HOURS: number | null;
  PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE: string;
  PRIVACY_EXPORT_MAX_BYTES: number;
  ACCOUNT_DELETION_EXECUTION_ENABLED: boolean;
  ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE: string;
  ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE: string;
  MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE: string;
  RETAINED_GIS_RECORDS_APPROVAL_REFERENCE: string;
  ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE: string;
  FREE_TEXT_TREATMENT_APPROVAL_REFERENCE: string;
  BACKUP_AGEING_APPROVAL_REFERENCE: string;
  NOTIFICATION_MAINTENANCE_INTERVAL_MINUTES: number;
  PUSH_NOTIFICATIONS_ENABLED: boolean;
  ANDROID_PUSH_NOTIFICATIONS_ENABLED: boolean;
  IOS_PUSH_NOTIFICATIONS_ENABLED: boolean;
  NOTIFICATION_PUSH_BATCH_SIZE: number;
  NOTIFICATION_PUSH_MAX_ATTEMPTS: number;
  LEGAL_ENFORCEMENT_ENABLED: boolean;
  LEGAL_DRAFTS_PUBLIC_ENABLED: boolean;
  LEGAL_COUNSEL_APPROVAL_REFERENCE: string;
  IMPORT_PROVENANCE_ENFORCEMENT_ENABLED: boolean;
  FIREBASE_SERVICE_ACCOUNT_JSON: string;
  FIREBASE_SERVICE_ACCOUNT_BASE64: string;
  FIREBASE_SERVICE_ACCOUNT_PATH: string;
  PASSWORD_RESET_TOKEN_EXPIRY_MINUTES: number;
  PASSWORD_RESET_REQUIRE_REAL_DELIVERY: boolean;
  VERIFICATION_HMAC_SECRET: string;
  CONTACT_VERIFICATION_TOKEN_EXPIRY_MINUTES: number;
  VERIFICATION_CODE_EXPIRY_MINUTES: number;
  VERIFICATION_RESEND_COOLDOWN_SECONDS: number;
  VERIFICATION_MAX_ATTEMPTS: number;
  VERIFICATION_BLOCK_MINUTES: number;
  VERIFICATION_DAILY_TARGET_CAP: number;
  VERIFICATION_DAILY_ACCOUNT_CAP: number;
  VERIFICATION_DAILY_IP_CAP: number;
  VERIFICATION_DAILY_DEVICE_CAP: number;
  VERIFICATION_PROVIDER_TIMEOUT_MS: number;
  PHONE_ACCOUNT_REUSE_LIMIT: number;
  PHONE_ASSURANCE_MODE: 'format_only' | 'sms_otp';
  PHONE_FORMAT_VALIDATION_PROVIDER: 'libphonenumber' | 'twilio_lookup_basic';
  PHONE_VERIFICATION_PROVIDER: 'mock' | 'twilio_verify';
  TWILIO_ACCOUNT_SID: string;
  TWILIO_AUTH_TOKEN: string;
  TWILIO_VERIFY_SERVICE_SID: string;
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
  AI_INTERNAL_API_SECRET: string;
  AI_SERVER_TIMEOUT_MS: number;
  AI_MAX_CONCURRENT_RUNS: number;
  AI_MAX_RUNS_PER_PROJECT_PER_DAY: number;
  AI_MAX_ESTIMATED_COST_USD_PER_RUN: number;
  ARCGIS_ONLINE_ENABLED: boolean;
  ARCGIS_CLIENT_ID: string;
  ARCGIS_CLIENT_SECRET: string;
  ARCGIS_TOKEN_URL: string;
  ARCGIS_IMAGERY_TILE_URL: string;
  ARCGIS_REFERENCE_TILE_URL: string;
  ARCGIS_ATTRIBUTION_URL: string;
  ARCGIS_REQUEST_TIMEOUT_MS: number;
  ARCGIS_TOKEN_REFRESH_SKEW_SECONDS: number;
  ARCGIS_MAX_TILE_BYTES: number;
  ARCGIS_DAILY_TILE_SOFT_LIMIT: number;
  ARCGIS_ALLOWED_HOSTS: string;
  MAP_PROVIDER_USER_AGENT: string;
  OFFLINE_PACKAGE_ENABLED: boolean;
  OFFLINE_PACKAGE_DIR: string;
  OFFLINE_PACKAGE_MAX_BYTES: number;
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
  STORAGE_DRIVER: 'local' | 's3';
  STORAGE_TEMP_DIR: string;
  STORAGE_MAX_OBJECT_BYTES: number;
  STORAGE_S3_ENDPOINT: string;
  STORAGE_S3_REGION: string;
  STORAGE_S3_FORCE_PATH_STYLE: boolean;
  STORAGE_S3_ACCESS_KEY_ID: string;
  STORAGE_S3_SECRET_ACCESS_KEY: string;
  STORAGE_S3_UPLOADS_BUCKET: string;
  STORAGE_S3_EXPORTS_BUCKET: string;
  STORAGE_S3_OFFLINE_BUCKET: string;
  STORAGE_S3_AI_BUCKET: string;
  STORAGE_S3_BACKUPS_BUCKET: string;
  STORAGE_S3_PREFIX: string;
  STORAGE_S3_REQUEST_TIMEOUT_MS: number;
  STORAGE_S3_MAX_ATTEMPTS: number;
  STORAGE_S3_PROVIDER: 'digitalocean_spaces' | 'oci';
  STORAGE_S3_SERVER_SIDE_ENCRYPTION: 'AES256' | 'SSE-C';
  STORAGE_S3_CUSTOMER_KEY_BASE64: string;
  PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64: string;
  PRIVACY_EXPORT_TTL_HOURS: number | null;
  PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE: string;
  ACCOUNT_DELETION_EXECUTION_ENABLED: boolean;
  ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE: string;
  ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE: string;
  MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE: string;
  RETAINED_GIS_RECORDS_APPROVAL_REFERENCE: string;
  ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE: string;
  FREE_TEXT_TREATMENT_APPROVAL_REFERENCE: string;
  BACKUP_AGEING_APPROVAL_REFERENCE: string;
  LOG_PRETTY: boolean;
  LOG_TO_FILE: boolean;
  LOG_DIR: string;
  LOG_MAX_SIZE: string;
  LOG_RETENTION_DAYS: number;
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
  JWT_EXPIRE: Joi.string()
    .pattern(/^\d+[smhd]$/)
    .default('15m'),
  JWT_ISSUER: Joi.string().trim().min(3).max(200).default('terraleb-api'),
  JWT_AUDIENCE: Joi.string().trim().min(3).max(200).default('terraleb-mobile'),
  JWT_REFRESH_SECRET: Joi.string().min(32).required(),
  JWT_REFRESH_SECRET_CURRENT: Joi.string().min(32).optional(),
  JWT_REFRESH_SECRET_PREVIOUS: Joi.string().allow('').default(''),
  JWT_REFRESH_EXPIRE: Joi.string()
    .pattern(/^\d+[smhd]$/)
    .default('30d'),

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
  REALTIME_V2_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  REALTIME_LEGACY_BROADCAST_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  REALTIME_POLLING_FALLBACK_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  REALTIME_AUTH_TIMEOUT_MS: Joi.number().integer().min(1000).max(30000).default(5000),
  REALTIME_HEARTBEAT_INTERVAL_MS: Joi.number().integer().min(10000).max(120000).default(30000),
  REALTIME_MAX_CONNECTIONS_PER_USER: Joi.number().integer().min(1).max(50).default(5),
  REALTIME_MAX_CONNECTIONS_PER_IP: Joi.number().integer().min(1).max(500).default(30),
  REALTIME_MAX_BUFFERED_BYTES: Joi.number().integer().min(16384).max(16777216).default(262144),
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
  RATE_LIMIT_VERIFICATION_MAX_REQUESTS: Joi.number().integer().min(1).default(20),
  RATE_LIMIT_PRIVACY_REQUEST_MAX_REQUESTS: Joi.number().integer().min(1).default(10),
  RATE_LIMIT_PUBLIC_PRIVACY_REQUEST_MAX_REQUESTS: Joi.number().integer().min(1).default(5),
  RATE_LIMIT_CONTENT_REPORT_MAX_REQUESTS: Joi.number().integer().min(1).default(20),
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
  LOG_PRETTY: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(true),
  LOG_TO_FILE: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(false),
  LOG_DIR: Joi.string().trim().min(1).default('./logs/api'),
  LOG_MAX_SIZE: Joi.string()
    .trim()
    .lowercase()
    .pattern(/^\d+(?:k|m|g)?$/)
    .default('10m'),
  LOG_RETENTION_DAYS: Joi.number().integer().min(1).max(365).default(14),
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

  STORAGE_DRIVER: Joi.string().valid('local', 's3').default('local'),
  STORAGE_TEMP_DIR: Joi.string().trim().min(1).default('/tmp/terraleb-storage'),
  STORAGE_MAX_OBJECT_BYTES: Joi.number()
    .integer()
    .min(5 * 1024 * 1024)
    .max(5 * 1024 * 1024 * 1024)
    .default(1024 * 1024 * 1024),
  STORAGE_S3_ENDPOINT: Joi.string().trim().allow('').default(''),
  STORAGE_S3_REGION: Joi.string().trim().allow('').default(''),
  STORAGE_S3_FORCE_PATH_STYLE: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  STORAGE_S3_ACCESS_KEY_ID: Joi.string().trim().allow('').default(''),
  STORAGE_S3_SECRET_ACCESS_KEY: Joi.string().allow('').default(''),
  STORAGE_S3_UPLOADS_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_EXPORTS_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_OFFLINE_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_AI_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_BACKUPS_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_PREFIX: Joi.string().trim().allow('').max(200).default('terraleb'),
  STORAGE_S3_REQUEST_TIMEOUT_MS: Joi.number().integer().min(1000).max(120000).default(30000),
  STORAGE_S3_MAX_ATTEMPTS: Joi.number().integer().min(1).max(10).default(3),
  STORAGE_S3_PROVIDER: Joi.string()
    .valid('digitalocean_spaces', 'oci')
    .default('digitalocean_spaces'),
  STORAGE_S3_SERVER_SIDE_ENCRYPTION: Joi.string().valid('AES256', 'SSE-C').default('SSE-C'),
  STORAGE_S3_CUSTOMER_KEY_BASE64: Joi.string().trim().base64().allow('').default(''),

  EXPORT_DIR: Joi.string().default('./exports'),
  EXPORT_RETENTION_DAYS: Joi.number().integer().min(1).default(7),
  EXPORT_CLEANUP_INTERVAL_HOURS: Joi.number().integer().min(1).default(24),
  PRIVACY_EXPORT_DIR: Joi.string().trim().allow('').default(''),
  PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64: Joi.string().trim().base64().allow('').default(''),
  PRIVACY_EXPORT_ENCRYPTION_KEY_ID: Joi.string()
    .trim()
    .pattern(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$/)
    .default('primary'),
  PRIVACY_EXPORT_TTL_HOURS: Joi.number().integer().min(1).max(168).allow(null).default(null),
  PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  PRIVACY_EXPORT_MAX_BYTES: Joi.number()
    .integer()
    .min(1024)
    .default(50 * 1024 * 1024),
  ACCOUNT_DELETION_EXECUTION_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  RETAINED_GIS_RECORDS_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  FREE_TEXT_TREATMENT_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  BACKUP_AGEING_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  NOTIFICATION_MAINTENANCE_INTERVAL_MINUTES: Joi.number().integer().min(1).default(60),
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
  LEGAL_ENFORCEMENT_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  LEGAL_DRAFTS_PUBLIC_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(true),
  LEGAL_COUNSEL_APPROVAL_REFERENCE: Joi.string().allow('').max(240).default(''),
  IMPORT_PROVENANCE_ENFORCEMENT_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
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
  VERIFICATION_HMAC_SECRET: Joi.string()
    .min(32)
    .default('development-verification-hmac-secret-change-me'),
  CONTACT_VERIFICATION_TOKEN_EXPIRY_MINUTES: Joi.number().integer().min(5).max(1440).default(30),
  VERIFICATION_CODE_EXPIRY_MINUTES: Joi.number().integer().min(2).max(30).default(5),
  VERIFICATION_RESEND_COOLDOWN_SECONDS: Joi.number().integer().min(10).max(3600).default(60),
  VERIFICATION_MAX_ATTEMPTS: Joi.number().integer().min(3).max(10).default(5),
  VERIFICATION_BLOCK_MINUTES: Joi.number().integer().min(1).max(1440).default(15),
  VERIFICATION_DAILY_TARGET_CAP: Joi.number().integer().min(1).max(100).default(10),
  VERIFICATION_DAILY_ACCOUNT_CAP: Joi.number().integer().min(1).max(200).default(20),
  VERIFICATION_DAILY_IP_CAP: Joi.number().integer().min(1).max(1000).default(50),
  VERIFICATION_DAILY_DEVICE_CAP: Joi.number().integer().min(1).max(1000).default(30),
  VERIFICATION_PROVIDER_TIMEOUT_MS: Joi.number().integer().min(1000).max(60000).default(10000),
  PHONE_ACCOUNT_REUSE_LIMIT: Joi.number().integer().min(1).max(3).default(3),
  PHONE_ASSURANCE_MODE: Joi.string().valid('format_only', 'sms_otp').default('format_only'),
  PHONE_FORMAT_VALIDATION_PROVIDER: Joi.string()
    .valid('libphonenumber', 'twilio_lookup_basic')
    .default('libphonenumber'),
  PHONE_VERIFICATION_PROVIDER: Joi.string().valid('mock', 'twilio_verify').default('mock'),
  TWILIO_ACCOUNT_SID: Joi.string().allow('').default(''),
  TWILIO_AUTH_TOKEN: Joi.string().allow('').default(''),
  TWILIO_VERIFY_SERVICE_SID: Joi.string().allow('').default(''),

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
  AI_INTERNAL_API_SECRET: Joi.string().allow('').default('dev-ai-internal-secret-change-me'),
  AI_SERVER_TIMEOUT_MS: Joi.number().integer().min(1000).max(120000).default(30000),
  AI_MAX_CONCURRENT_RUNS: Joi.number().integer().min(1).max(32).default(2),
  AI_MAX_RUNS_PER_PROJECT_PER_DAY: Joi.number().integer().min(1).max(100).default(4),
  AI_MAX_ESTIMATED_COST_USD_PER_RUN: Joi.number().min(0).max(100000).default(25),
  ARCGIS_ONLINE_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  ARCGIS_CLIENT_ID: Joi.string().trim().allow('').default(''),
  ARCGIS_CLIENT_SECRET: Joi.string().allow('').default(''),
  ARCGIS_TOKEN_URL: Joi.string().trim().default('https://www.arcgis.com/sharing/rest/oauth2/token'),
  ARCGIS_IMAGERY_TILE_URL: Joi.string()
    .trim()
    .default(
      'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    ),
  ARCGIS_REFERENCE_TILE_URL: Joi.string()
    .trim()
    .default(
      'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    ),
  ARCGIS_ATTRIBUTION_URL: Joi.string()
    .trim()
    .default(
      'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/attribution',
    ),
  ARCGIS_REQUEST_TIMEOUT_MS: Joi.number().integer().min(1000).max(60000).default(10000),
  ARCGIS_TOKEN_REFRESH_SKEW_SECONDS: Joi.number().integer().min(30).max(3600).default(300),
  ARCGIS_MAX_TILE_BYTES: Joi.number()
    .integer()
    .min(1024)
    .max(20 * 1024 * 1024)
    .default(5 * 1024 * 1024),
  ARCGIS_DAILY_TILE_SOFT_LIMIT: Joi.number().integer().min(1).default(100000),
  ARCGIS_ALLOWED_HOSTS: Joi.string()
    .trim()
    .default('www.arcgis.com,services.arcgisonline.com,server.arcgisonline.com'),
  MAP_PROVIDER_USER_AGENT: Joi.string().trim().min(10).max(300).default('TerraLeb-development/1.0'),
  OFFLINE_PACKAGE_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  OFFLINE_PACKAGE_DIR: Joi.string().trim().min(1).default('./offline-packages'),
  OFFLINE_PACKAGE_MAX_BYTES: Joi.number()
    .integer()
    .min(1024 * 1024)
    .max(20 * 1024 * 1024 * 1024)
    .default(5 * 1024 * 1024 * 1024),
}).unknown(true);

const unsafeProductionSecret = (value: unknown): boolean => {
  const normalized = String(value ?? '')
    .trim()
    .toLowerCase();
  return (
    normalized.length < 16 ||
    ['change_me', 'changeme', 'password', 'replace-', 'replace_', 'example', 'dev-', 'test-'].some(
      (marker) => normalized.includes(marker),
    )
  );
};

const unsafeProductionIdentifier = (value: unknown): boolean => {
  const normalized = String(value ?? '')
    .trim()
    .toLowerCase();
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

const validateSecureProviderUrl = (value: unknown): boolean => {
  try {
    const parsed = new URL(String(value));
    return parsed.protocol === 'https:' && !parsed.username && !parsed.password;
  } catch {
    return false;
  }
};

const validateProductionStorage = (value: Record<string, unknown>, errorPrefix: string): void => {
  if (value.STORAGE_DRIVER !== 's3') {
    throw new Error(`${errorPrefix}: production requires STORAGE_DRIVER=s3`);
  }
  if (value.STORAGE_S3_PROVIDER !== 'digitalocean_spaces') {
    throw new Error(`${errorPrefix}: production storage provider must be digitalocean_spaces`);
  }
  if (value.STORAGE_S3_REGION !== 'fra1') {
    throw new Error(`${errorPrefix}: DigitalOcean production storage must use region fra1`);
  }
  if (!validateSecureProviderUrl(value.STORAGE_S3_ENDPOINT)) {
    throw new Error(`${errorPrefix}: STORAGE_S3_ENDPOINT must be an HTTPS URL`);
  }
  const endpoint = new URL(String(value.STORAGE_S3_ENDPOINT));
  if (
    endpoint.hostname !== 'fra1.digitaloceanspaces.com' ||
    endpoint.pathname !== '/' ||
    endpoint.search ||
    endpoint.hash
  ) {
    throw new Error(
      `${errorPrefix}: STORAGE_S3_ENDPOINT must be the DigitalOcean Spaces FRA1 endpoint`,
    );
  }
  if (
    unsafeProductionIdentifier(value.STORAGE_S3_ACCESS_KEY_ID) ||
    unsafeProductionSecret(value.STORAGE_S3_SECRET_ACCESS_KEY)
  ) {
    throw new Error(`${errorPrefix}: DigitalOcean Spaces credentials are missing or unsafe`);
  }
  const bucketPattern = /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/;
  const buckets = [
    value.STORAGE_S3_UPLOADS_BUCKET,
    value.STORAGE_S3_EXPORTS_BUCKET,
    value.STORAGE_S3_OFFLINE_BUCKET,
    value.STORAGE_S3_AI_BUCKET,
    value.STORAGE_S3_BACKUPS_BUCKET,
  ].map((bucket) => String(bucket ?? '').trim());
  if (buckets.some((bucket) => !bucketPattern.test(bucket)) || new Set(buckets).size !== 5) {
    throw new Error(
      `${errorPrefix}: production requires five distinct DNS-compatible private storage buckets`,
    );
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9/_-]{0,199}$/.test(String(value.STORAGE_S3_PREFIX))) {
    throw new Error(`${errorPrefix}: STORAGE_S3_PREFIX is invalid`);
  }
  if (value.STORAGE_S3_SERVER_SIDE_ENCRYPTION !== 'SSE-C') {
    throw new Error(`${errorPrefix}: DigitalOcean Spaces must use SSE-C object encryption`);
  }
  const customerKey = Buffer.from(String(value.STORAGE_S3_CUSTOMER_KEY_BASE64 ?? ''), 'base64');
  if (customerKey.length !== 32) {
    throw new Error(`${errorPrefix}: DigitalOcean Spaces SSE-C requires a 32-byte customer key`);
  }
};

const durationSeconds = (value: string): number => {
  const match = value.match(/^(\d+)([smhd])$/);
  if (!match) {
    return Number.POSITIVE_INFINITY;
  }
  const unitSeconds = ({ s: 1, m: 60, h: 3600, d: 86400 } as Record<string, number>)[match[2]];
  if (!unitSeconds) {
    return Number.POSITIVE_INFINITY;
  }
  return Number(match[1]) * unitSeconds;
};

const rotationSecrets = (current: string, previousRaw: string): string[] => [
  current,
  ...previousRaw
    .split(',')
    .map((secret) => secret.trim())
    .filter(Boolean),
];

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

  const configuredAccessSecrets = rotationSecrets(
    value.JWT_SECRET_CURRENT,
    value.JWT_SECRET_PREVIOUS,
  );
  const configuredRefreshSecrets = rotationSecrets(
    value.JWT_REFRESH_SECRET_CURRENT,
    value.JWT_REFRESH_SECRET_PREVIOUS,
  );
  if (
    [...configuredAccessSecrets, ...configuredRefreshSecrets].some((secret) => secret.length < 32)
  ) {
    throw new Error(
      'Environment validation failed: every current and previous JWT secret must be at least 32 characters',
    );
  }
  const accessSecretSet = new Set(configuredAccessSecrets);
  if (configuredRefreshSecrets.some((secret) => accessSecretSet.has(secret))) {
    throw new Error(
      'Environment validation failed: access-token and refresh-token secrets must be distinct',
    );
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
    validateProductionStorage(value, 'Environment validation failed');
    if (
      !value.REALTIME_V2_ENABLED ||
      value.REALTIME_LEGACY_BROADCAST_ENABLED ||
      value.REALTIME_POLLING_FALLBACK_ENABLED
    ) {
      throw new Error(
        'Environment validation failed: production requires real-time v2 with legacy broadcasting and polling fallback disabled',
      );
    }
    if (Number(value.STORAGE_MAX_OBJECT_BYTES) < Number(value.OFFLINE_PACKAGE_MAX_BYTES)) {
      throw new Error(
        'Environment validation failed: STORAGE_MAX_OBJECT_BYTES must cover OFFLINE_PACKAGE_MAX_BYTES',
      );
    }
    const privacyExportKey = Buffer.from(value.PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64, 'base64');
    if (
      privacyExportKey.length !== 32 ||
      value.PRIVACY_EXPORT_TTL_HOURS == null ||
      !value.PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE
    ) {
      throw new Error(
        'Environment validation failed: production privacy exports require a 32-byte base64 encryption key, an approved TTL, and its approval reference',
      );
    }
    if (
      value.ACCOUNT_DELETION_EXECUTION_ENABLED &&
      [
        value.ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE,
        value.ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE,
        value.MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE,
        value.RETAINED_GIS_RECORDS_APPROVAL_REFERENCE,
        value.ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE,
        value.FREE_TEXT_TREATMENT_APPROVAL_REFERENCE,
        value.BACKUP_AGEING_APPROVAL_REFERENCE,
      ].some((reference: string) => !reference)
    ) {
      throw new Error(
        'Environment validation failed: enabled account deletion requires policy, retention, retained-record, masked-attribution, media/location, free-text, and backup-ageing approval references',
      );
    }
    if (value.LEGAL_DRAFTS_PUBLIC_ENABLED) {
      throw new Error(
        'Environment validation failed: production must not expose draft legal documents',
      );
    }
    if (value.LEGAL_ENFORCEMENT_ENABLED && !String(value.LEGAL_COUNSEL_APPROVAL_REFERENCE).trim()) {
      throw new Error(
        'Environment validation failed: enabled legal enforcement requires an approval reference',
      );
    }
    if (durationSeconds(value.JWT_EXPIRE) > 60 * 60) {
      throw new Error(
        'Environment validation failed: production access tokens must expire within 1 hour',
      );
    }
    if (durationSeconds(value.JWT_REFRESH_EXPIRE) > 30 * 24 * 60 * 60) {
      throw new Error(
        'Environment validation failed: production refresh tokens must expire within 30 days',
      );
    }
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

    if (value.LOG_PRETTY) {
      throw new Error(
        'Environment validation failed: production requires redacted JSON logs (LOG_PRETTY=false)',
      );
    }

    if (!value.PASSWORD_RESET_REQUIRE_REAL_DELIVERY) {
      throw new Error(
        'Environment validation failed: production requires PASSWORD_RESET_REQUIRE_REAL_DELIVERY=true',
      );
    }

    if (unsafeProductionSecret(value.VERIFICATION_HMAC_SECRET)) {
      throw new Error(
        'Environment validation failed: production requires a non-placeholder VERIFICATION_HMAC_SECRET',
      );
    }

    const twilioCredentialsRequired =
      value.PHONE_ASSURANCE_MODE === 'sms_otp' ||
      value.PHONE_FORMAT_VALIDATION_PROVIDER === 'twilio_lookup_basic';
    if (
      twilioCredentialsRequired &&
      [value.TWILIO_ACCOUNT_SID, value.TWILIO_AUTH_TOKEN].some((item: string) =>
        unsafeProductionIdentifier(item),
      )
    ) {
      throw new Error(
        'Environment validation failed: configured Twilio provider requires safe account credentials',
      );
    }
    if (value.PHONE_ASSURANCE_MODE === 'sms_otp') {
      if (value.PHONE_VERIFICATION_PROVIDER !== 'twilio_verify') {
        throw new Error(
          'Environment validation failed: SMS ownership assurance requires PHONE_VERIFICATION_PROVIDER=twilio_verify',
        );
      }
      if (unsafeProductionIdentifier(value.TWILIO_VERIFY_SERVICE_SID)) {
        throw new Error(
          'Environment validation failed: production Twilio Verify Service SID is incomplete or unsafe',
        );
      }
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
    if (unsafeProductionSecret(value.AI_INTERNAL_API_SECRET)) {
      throw new Error(
        'Environment validation failed: AI_INTERNAL_API_SECRET must be a strong non-placeholder production secret',
      );
    }
    if (
      !value.AI_PIPELINE_ENABLED ||
      !String(value.AI_SERVER_URL).trim() ||
      unsafeProductionSecret(value.AI_CALLBACK_SECRET) ||
      unsafeProductionSecret(value.AI_INTERNAL_API_SECRET)
    ) {
      throw new Error(
        'Environment validation failed: production AI requires an enabled internal service URL and strong callback secret',
      );
    }
    if (value.ARCGIS_ONLINE_ENABLED) {
      if (
        unsafeProductionIdentifier(value.ARCGIS_CLIENT_ID) ||
        unsafeProductionSecret(value.ARCGIS_CLIENT_SECRET)
      ) {
        throw new Error(
          'Environment validation failed: enabled ArcGIS online maps require operator-owned credentials',
        );
      }
      for (const [name, configuredUrl] of [
        ['ARCGIS_TOKEN_URL', value.ARCGIS_TOKEN_URL],
        ['ARCGIS_IMAGERY_TILE_URL', value.ARCGIS_IMAGERY_TILE_URL],
        ['ARCGIS_REFERENCE_TILE_URL', value.ARCGIS_REFERENCE_TILE_URL],
        ['ARCGIS_ATTRIBUTION_URL', value.ARCGIS_ATTRIBUTION_URL],
      ]) {
        if (!validateSecureProviderUrl(configuredUrl)) {
          throw new Error(`Environment validation failed: ${name} must be an HTTPS URL`);
        }
      }
      const allowedHosts = new Set(
        String(value.ARCGIS_ALLOWED_HOSTS)
          .split(',')
          .map((host) => host.trim().toLowerCase())
          .filter(Boolean),
      );
      if (allowedHosts.size === 0) {
        throw new Error('Environment validation failed: ARCGIS_ALLOWED_HOSTS is required');
      }
      for (const [name, configuredUrl] of [
        ['ARCGIS_TOKEN_URL', value.ARCGIS_TOKEN_URL],
        ['ARCGIS_IMAGERY_TILE_URL', value.ARCGIS_IMAGERY_TILE_URL],
        ['ARCGIS_REFERENCE_TILE_URL', value.ARCGIS_REFERENCE_TILE_URL],
        ['ARCGIS_ATTRIBUTION_URL', value.ARCGIS_ATTRIBUTION_URL],
      ]) {
        if (!allowedHosts.has(new URL(String(configuredUrl)).hostname.toLowerCase())) {
          throw new Error(
            `Environment validation failed: ${name} host is not listed in ARCGIS_ALLOWED_HOSTS`,
          );
        }
      }
    }
    if (/development|replace|example\.com/i.test(String(value.MAP_PROVIDER_USER_AGENT))) {
      throw new Error(
        'Environment validation failed: MAP_PROVIDER_USER_AGENT must identify the production operator',
      );
    }
  }

  if (value.NODE_ENV === 'production' && value.MALWARE_SCANNER_MODE !== 'clamav') {
    throw new Error(
      'Environment validation failed: production requires MALWARE_SCANNER_MODE=clamav',
    );
  }

  if (value.RATE_LIMIT_STORE === 'redis' && !String(value.REDIS_URL).trim()) {
    throw new Error('Environment validation failed: RATE_LIMIT_STORE=redis requires REDIS_URL');
  }

  if (value.NODE_ENV === 'production' && value.RATE_LIMIT_STORE !== 'redis') {
    throw new Error('Environment validation failed: production requires RATE_LIMIT_STORE=redis');
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
  STORAGE_DRIVER: Joi.string().valid('local', 's3').default('local'),
  STORAGE_TEMP_DIR: Joi.string().trim().min(1).default('/tmp/terraleb-storage'),
  STORAGE_MAX_OBJECT_BYTES: Joi.number()
    .integer()
    .min(5 * 1024 * 1024)
    .max(5 * 1024 * 1024 * 1024)
    .default(1024 * 1024 * 1024),
  STORAGE_S3_ENDPOINT: Joi.string().trim().allow('').default(''),
  STORAGE_S3_REGION: Joi.string().trim().allow('').default(''),
  STORAGE_S3_FORCE_PATH_STYLE: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  STORAGE_S3_ACCESS_KEY_ID: Joi.string().trim().allow('').default(''),
  STORAGE_S3_SECRET_ACCESS_KEY: Joi.string().allow('').default(''),
  STORAGE_S3_UPLOADS_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_EXPORTS_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_OFFLINE_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_AI_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_BACKUPS_BUCKET: Joi.string().trim().allow('').default(''),
  STORAGE_S3_PREFIX: Joi.string().trim().allow('').max(200).default('terraleb'),
  STORAGE_S3_REQUEST_TIMEOUT_MS: Joi.number().integer().min(1000).max(120000).default(30000),
  STORAGE_S3_MAX_ATTEMPTS: Joi.number().integer().min(1).max(10).default(3),
  STORAGE_S3_PROVIDER: Joi.string()
    .valid('digitalocean_spaces', 'oci')
    .default('digitalocean_spaces'),
  STORAGE_S3_SERVER_SIDE_ENCRYPTION: Joi.string().valid('AES256', 'SSE-C').default('SSE-C'),
  STORAGE_S3_CUSTOMER_KEY_BASE64: Joi.string().trim().base64().allow('').default(''),
  PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64: Joi.string().trim().base64().allow('').default(''),
  PRIVACY_EXPORT_TTL_HOURS: Joi.number().integer().min(1).max(168).allow(null).default(null),
  PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  ACCOUNT_DELETION_EXECUTION_ENABLED: Joi.boolean()
    .truthy('true')
    .truthy('1')
    .falsy('false')
    .falsy('0')
    .default(false),
  ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  RETAINED_GIS_RECORDS_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  FREE_TEXT_TREATMENT_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  BACKUP_AGEING_APPROVAL_REFERENCE: Joi.string().trim().allow('').max(240).default(''),
  LOG_PRETTY: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(true),
  LOG_TO_FILE: Joi.boolean().truthy('true').truthy('1').falsy('false').falsy('0').default(false),
  LOG_DIR: Joi.string().trim().min(1).default('./logs/api'),
  LOG_MAX_SIZE: Joi.string()
    .trim()
    .lowercase()
    .pattern(/^\d+(?:k|m|g)?$/)
    .default('10m'),
  LOG_RETENTION_DAYS: Joi.number().integer().min(1).max(365).default(14),
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
    validateProductionStorage(value, 'Workload worker environment validation failed');
    const privacyExportKey = Buffer.from(value.PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64, 'base64');
    if (
      privacyExportKey.length !== 32 ||
      value.PRIVACY_EXPORT_TTL_HOURS == null ||
      !value.PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE
    ) {
      throw new Error(
        'Workload worker environment validation failed: privacy export key, approved TTL, and approval reference are required',
      );
    }
    if (
      value.ACCOUNT_DELETION_EXECUTION_ENABLED &&
      [
        value.ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE,
        value.ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE,
        value.MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE,
        value.RETAINED_GIS_RECORDS_APPROVAL_REFERENCE,
        value.ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE,
        value.FREE_TEXT_TREATMENT_APPROVAL_REFERENCE,
        value.BACKUP_AGEING_APPROVAL_REFERENCE,
      ].some((reference: string) => !reference)
    ) {
      throw new Error(
        'Workload worker environment validation failed: enabled deletion requires every configured policy and retention approval reference',
      );
    }
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
    if (value.LOG_PRETTY) {
      throw new Error(
        'Workload worker environment validation failed: production requires redacted JSON logs',
      );
    }
  }

  return value as WorkloadWorkerEnvConfig;
};

export { validateEnv, validateWorkloadWorkerEnv };
