import fs from 'node:fs';
import path from 'node:path';
import dotenv from 'dotenv';

export interface TestDbConfig {
  host: string;
  port: number;
  database: string;
  user: string;
  password: string;
  adminDatabase: string;
  migrationsDir: string;
}

const apiRoot = path.resolve(__dirname, '..', '..');

const resolveMigrationsDir = (): string => {
  const configured = process.env.MIGRATIONS_DIR?.trim();
  if (configured) {
    return path.resolve(configured);
  }

  return path.resolve(apiRoot, '..', '..', 'infra', 'migrations');
};

const loadTestEnvFiles = (): void => {
  const candidates = ['.env.test.local', '.env.test', '.env'].map((file) =>
    path.resolve(apiRoot, file),
  );

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      dotenv.config({ path: candidate, override: false });
    }
  }
};

const setDefault = (key: string, value: string): void => {
  if (!process.env[key] || process.env[key]?.trim().length === 0) {
    process.env[key] = value;
  }
};

const resolveNumber = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const applyTestEnvDefaults = (): TestDbConfig => {
  loadTestEnvFiles();

  const host = process.env.TEST_DB_HOST?.trim() || 'localhost';
  const port = resolveNumber(process.env.TEST_DB_PORT, 54329);
  const database = process.env.TEST_DB_NAME?.trim() || 'gis_app_test';
  const user = process.env.TEST_DB_USER?.trim() || 'gis_user';
  const password = process.env.TEST_DB_PASSWORD ?? 'change_me';
  const adminDatabase = process.env.TEST_DB_ADMIN_DB?.trim() || 'postgres';
  const migrationsDir = resolveMigrationsDir();

  process.env.NODE_ENV = 'test';
  process.env.DB_HOST = host;
  process.env.DB_PORT = String(port);
  process.env.DB_NAME = database;
  process.env.DB_USER = user;
  process.env.DB_PASSWORD = password;
  process.env.MIGRATIONS_DIR = migrationsDir;

  setDefault('JWT_SECRET', 'phase10-test-jwt-secret-12345678901234567890');
  setDefault('JWT_SECRET_CURRENT', process.env.JWT_SECRET as string);
  setDefault('JWT_REFRESH_SECRET', 'phase10-test-refresh-secret-12345678901234567890');
  setDefault('JWT_REFRESH_SECRET_CURRENT', process.env.JWT_REFRESH_SECRET as string);
  setDefault('JWT_SECRET_PREVIOUS', '');
  setDefault('JWT_REFRESH_SECRET_PREVIOUS', '');
  setDefault('JWT_EXPIRE', '7d');
  setDefault('JWT_REFRESH_EXPIRE', '30d');
  setDefault('CORS_ORIGIN', '');
  setDefault('CORS_STRICT', 'false');
  setDefault('CORS_CREDENTIALS', 'true');
  setDefault('API_VERSION_PREFIX', '/api/v1');
  setDefault('ENABLE_LEGACY_API_PREFIX', 'true');
  setDefault('RATE_LIMIT_WINDOW_MS', '900000');
  setDefault('RATE_LIMIT_MAX_REQUESTS', '1000');
  setDefault('RATE_LIMIT_AUTH_MAX_REQUESTS', '1000');
  setDefault('RATE_LIMIT_EXPORT_MAX_REQUESTS', '1000');
  setDefault('OFFLINE_SYNC_RATE_LIMIT_WINDOW_MS', '60000');
  setDefault('OFFLINE_SYNC_RATE_LIMIT_MAX_REQUESTS', '10000');
  setDefault('OFFLINE_SYNC_INGRESS_RATE_LIMIT_MAX_REQUESTS', '10000');
  setDefault('AUDIT_LOG_ENABLED', 'true');
  setDefault('METRICS_ENABLED', 'false');
  setDefault('MAIL_TRANSPORT', 'mailpit');
  setDefault('PASSWORD_RESET_REQUIRE_REAL_DELIVERY', 'false');
  setDefault('SMTP_HOST', 'mailpit');
  setDefault('SMTP_PORT', '1025');
  setDefault('SMTP_SECURE', 'false');
  setDefault('SMTP_FROM_EMAIL', 'no-reply@gis.local');
  setDefault('SMTP_FROM_NAME', 'Lebanese GIS Collector');
  setDefault('AI_PIPELINE_ENABLED', 'false');
  setDefault('AI_PIPELINE_ROOT', '');
  setDefault('AI_PIPELINE_OUTPUT_ROOT', '');
  setDefault('AI_PYTHON_BIN', 'python');
  setDefault('AI_PIPELINE_TIMEOUT_MS', '60000');
  setDefault('AI_PIPELINE_MODE', 'disabled');
  setDefault('MALWARE_SCANNER_MODE', 'disabled');
  setDefault('CLAMAV_HOST', '127.0.0.1');
  setDefault('CLAMAV_PORT', '3310');
  setDefault('CLAMAV_TIMEOUT_MS', '15000');
  setDefault('CLAMAV_MAX_STREAM_BYTES', String(30 * 1024 * 1024));
  setDefault('ARCHIVE_MAX_ENTRIES', '1000');
  setDefault('ARCHIVE_MAX_EXPANDED_BYTES', String(100 * 1024 * 1024));
  setDefault('ARCHIVE_MAX_ENTRY_BYTES', String(50 * 1024 * 1024));
  setDefault('ARCHIVE_MAX_COMPRESSION_RATIO', '100');

  return {
    host,
    port,
    database,
    user,
    password,
    adminDatabase,
    migrationsDir,
  };
};

export { applyTestEnvDefaults };
