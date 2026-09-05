const { validateEnv, validateWorkloadWorkerEnv } = require('../src/config/env');
const { safeTokenEqual } = require('../src/middleware/operationalAccess');
const { normalizeRequestId, normalizeRequestPath } = require('../src/middleware/requestContext');
const { redactSensitive, sanitizeLogString } = require('../src/utils/logger');

const validFixtureCredential = (label) => `${label}-${'x'.repeat(40)}`;

const validProductionEnv = (overrides = {}) => ({
  NODE_ENV: 'production',
  MAIL_TRANSPORT: 'smtp',
  HOST: '0.0.0.0',
  PORT: '3000',
  TRUST_PROXY: 'true',
  TRUST_PROXY_HOPS: '1',
  ENFORCE_HTTPS: 'true',
  DB_HOST: 'db',
  DB_PORT: '5432',
  DB_NAME: 'gis_app',
  DB_USER: 'gis_runtime',
  DB_PASSWORD: 'G7m4Q2v9N8s6K3x1',
  JWT_SECRET: 'eK9w7Q2m4X8v6N3s1P5r0T2y7U4i9O6p',
  JWT_SECRET_CURRENT: 'eK9w7Q2m4X8v6N3s1P5r0T2y7U4i9O6p',
  JWT_REFRESH_SECRET: 'qP3n8V5m1X7k4S9r2T6w0Y8u5I1o7A4d',
  JWT_REFRESH_SECRET_CURRENT: 'qP3n8V5m1X7k4S9r2T6w0Y8u5I1o7A4d',
  CORS_ORIGIN: 'https://collector.gis.gov.lb',
  CORS_STRICT: 'true',
  CORS_CREDENTIALS: 'true',
  ENABLE_LEGACY_API_PREFIX: 'false',
  RATE_LIMIT_STORE: 'redis',
  REDIS_URL: 'redis://valkey:6379',
  REDIS_PASSWORD: 'R6d2M8p4V9x1K7s3',
  WORKLOAD_WORKER_MODE: 'external',
  WORKLOAD_HARD_EXIT_ON_TIMEOUT: 'true',
  REALTIME_V2_ENABLED: 'true',
  REALTIME_LEGACY_BROADCAST_ENABLED: 'false',
  REALTIME_POLLING_FALLBACK_ENABLED: 'false',
  STORAGE_DRIVER: 's3',
  STORAGE_S3_ENDPOINT: 'https://fixture.compat.objectstorage.me-jeddah-1.oraclecloud.com',
  STORAGE_S3_REGION: 'me-jeddah-1',
  STORAGE_S3_ACCESS_KEY_ID: validFixtureCredential('oci-access-fixture'),
  STORAGE_S3_SECRET_ACCESS_KEY: validFixtureCredential('oci-secret-fixture'),
  STORAGE_S3_UPLOADS_BUCKET: 'terraleb-fixture-uploads',
  STORAGE_S3_EXPORTS_BUCKET: 'terraleb-fixture-exports',
  STORAGE_S3_OFFLINE_BUCKET: 'terraleb-fixture-offline',
  STORAGE_S3_AI_BUCKET: 'terraleb-fixture-ai',
  STORAGE_S3_BACKUPS_BUCKET: 'terraleb-fixture-backups',
  STORAGE_S3_PREFIX: 'terraleb-fixture',
  STORAGE_MAX_OBJECT_BYTES: String(5 * 1024 * 1024 * 1024),
  OFFLINE_PACKAGE_MAX_BYTES: String(5 * 1024 * 1024 * 1024),
  MAP_PROVIDER_USER_AGENT: 'TerraLeb-test/1.0 (+https://collector.gis.gov.lb/map-support)',
  LOG_PRETTY: 'false',
  LOG_TO_FILE: 'false',
  API_DOCS_ENABLED: 'false',
  METRICS_ENABLED: 'true',
  METRICS_TOKEN: 'M9x4Q7v2K8s5P1d6R3t0W4y7',
  MALWARE_SCANNER_MODE: 'clamav',
  PASSWORD_RESET_REQUIRE_REAL_DELIVERY: 'true',
  VERIFICATION_HMAC_SECRET: validFixtureCredential('hmac-fixture'),
  PHONE_ASSURANCE_MODE: 'sms_otp',
  PHONE_FORMAT_VALIDATION_PROVIDER: 'libphonenumber',
  PHONE_VERIFICATION_PROVIDER: 'twilio_verify',
  TWILIO_ACCOUNT_SID: 'AC1234567890abcdef1234567890abcd',
  TWILIO_AUTH_TOKEN: validFixtureCredential('twilio-fixture'),
  TWILIO_VERIFY_SERVICE_SID: 'VA1234567890abcdef1234567890abcd',
  SMTP_HOST: 'smtp.gis.gov.lb',
  SMTP_PORT: '587',
  SMTP_USER: 'gis-mailer',
  SMTP_PASS: 'S8m2V5q9N4x7K1d6',
  SMTP_FROM_EMAIL: 'no-reply@gis.gov.lb',
  SUPER_ADMIN_EMAIL: 'superadmin@gis.gov.lb',
  SUPER_ADMIN_PASSWORD: 'A7m3Q9v5K1x8R4d2',
  SUPER_ADMIN_FULL_NAME: 'GIS Super Administrator',
  PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64: Buffer.alloc(32, 7).toString('base64'),
  PRIVACY_EXPORT_TTL_HOURS: '24',
  PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE: 'approved-retention-policy-2026',
  LEGAL_DRAFTS_PUBLIC_ENABLED: 'false',
  APP_PUBLIC_API_URL: 'https://collector.gis.gov.lb',
  AI_PIPELINE_ENABLED: 'true',
  AI_SERVER_URL: 'http://ai-server:8000',
  AI_CALLBACK_SECRET: 'C9v3N7m1Q5x8K2d6R4t0W9y7',
  AI_INTERNAL_API_SECRET: validFixtureCredential('ai-internal-fixture'),
  ...overrides,
});

describe('Phase 5 production security controls', () => {
  test('accepts a fail-closed production configuration', () => {
    const env = validateEnv(validProductionEnv());
    expect(env.NODE_ENV).toBe('production');
    expect(env.ENFORCE_HTTPS).toBe(true);
    expect(env.CORS_STRICT).toBe(true);
    expect(env.METRICS_ENABLED).toBe(true);
  });

  test('accepts provider-free format assurance without Twilio credentials', () => {
    const env = validateEnv(
      validProductionEnv({
        PHONE_ASSURANCE_MODE: 'format_only',
        PHONE_FORMAT_VALIDATION_PROVIDER: 'libphonenumber',
        PHONE_VERIFICATION_PROVIDER: 'mock',
        TWILIO_ACCOUNT_SID: '',
        TWILIO_AUTH_TOKEN: '',
        TWILIO_VERIFY_SERVICE_SID: '',
      }),
    );
    expect(env.PHONE_ASSURANCE_MODE).toBe('format_only');
    expect(env.PHONE_FORMAT_VALIDATION_PROVIDER).toBe('libphonenumber');
    expect(env.TWILIO_VERIFY_SERVICE_SID).toBe('');
  });

  test('optional Twilio Lookup provider still requires Twilio account credentials', () => {
    expect(() =>
      validateEnv(
        validProductionEnv({
          PHONE_ASSURANCE_MODE: 'format_only',
          PHONE_FORMAT_VALIDATION_PROVIDER: 'twilio_lookup_basic',
          TWILIO_ACCOUNT_SID: '',
        }),
      ),
    ).toThrow('Twilio provider requires safe account credentials');
  });

  test.each([
    [{ ENFORCE_HTTPS: 'false' }, 'ENFORCE_HTTPS=true'],
    [{ CORS_ORIGIN: 'http://collector.gis.gov.lb' }, 'HTTPS CORS origins'],
    [{ CORS_ORIGIN: 'https://collector.example' }, 'HTTPS CORS origins'],
    [{ CORS_ORIGIN: 'https://collector.example.gov.lb' }, 'HTTPS CORS origins'],
    [{ ENABLE_LEGACY_API_PREFIX: 'true' }, 'ENABLE_LEGACY_API_PREFIX=false'],
    [{ JWT_EXPIRE: '2h' }, 'access tokens must expire within 1 hour'],
    [{ JWT_REFRESH_EXPIRE: '31d' }, 'refresh tokens must expire within 30 days'],
    [
      {
        JWT_REFRESH_SECRET: validProductionEnv().JWT_SECRET,
        JWT_REFRESH_SECRET_CURRENT: validProductionEnv().JWT_SECRET_CURRENT,
      },
      'access-token and refresh-token secrets must be distinct',
    ],
    [{ METRICS_ENABLED: 'false' }, 'protected metrics'],
    [{ LOG_PRETTY: 'true' }, 'redacted JSON logs'],
    [
      { PASSWORD_RESET_REQUIRE_REAL_DELIVERY: 'false' },
      'PASSWORD_RESET_REQUIRE_REAL_DELIVERY=true',
    ],
    [{ DB_PASSWORD: 'replace-with-password' }, 'DB_PASSWORD'],
    [{ SMTP_USER: 'replace-with-smtp-username' }, 'SMTP_USER'],
    [{ PHONE_VERIFICATION_PROVIDER: 'mock' }, 'PHONE_VERIFICATION_PROVIDER=twilio_verify'],
    [{ VERIFICATION_HMAC_SECRET: 'replace-with-secret' }, 'VERIFICATION_HMAC_SECRET'],
    [{ STORAGE_DRIVER: 'local' }, 'STORAGE_DRIVER=s3'],
    [{ STORAGE_S3_REGION: 'eu-frankfurt-1' }, 'region me-jeddah-1'],
    [
      { STORAGE_S3_SECRET_ACCESS_KEY: 'replace-with-storage-secret' },
      'OCI S3 credentials',
    ],
    [{ REALTIME_LEGACY_BROADCAST_ENABLED: 'true' }, 'legacy broadcasting'],
    [{ REALTIME_POLLING_FALLBACK_ENABLED: 'true' }, 'polling fallback disabled'],
    [{ AI_PIPELINE_ENABLED: 'false' }, 'production AI requires'],
  ])('rejects insecure production override %j', (override, expectedMessage) => {
    expect(() => validateEnv(validProductionEnv(override))).toThrow(expectedMessage);
  });

  test('requires a strong token when production API docs are enabled', () => {
    expect(() =>
      validateEnv(validProductionEnv({ API_DOCS_ENABLED: 'true', API_DOCS_TOKEN: '' })),
    ).toThrow('production API docs require');

    expect(
      validateEnv(
        validProductionEnv({
          API_DOCS_ENABLED: 'true',
          API_DOCS_TOKEN: 'D4m8Q1v7K3x9R5s2N6p0T4w8',
        }),
      ).API_DOCS_ENABLED,
    ).toBe(true);
  });

  test('requires explicit policy evidence before enabling account deletion', () => {
    expect(() =>
      validateEnv(validProductionEnv({ ACCOUNT_DELETION_EXECUTION_ENABLED: 'true' })),
    ).toThrow('enabled account deletion requires');

    const env = validateEnv(
      validProductionEnv({
        ACCOUNT_DELETION_EXECUTION_ENABLED: 'true',
        ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE: 'deletion-policy-2026',
        ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE: 'retention-policy-2026',
        MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE: 'masked-label-policy-2026',
        RETAINED_GIS_RECORDS_APPROVAL_REFERENCE: 'retained-gis-policy-2026',
        ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE: 'media-location-policy-2026',
        FREE_TEXT_TREATMENT_APPROVAL_REFERENCE: 'free-text-policy-2026',
        BACKUP_AGEING_APPROVAL_REFERENCE: 'backup-ageing-policy-2026',
      }),
    );
    expect(env.ACCOUNT_DELETION_EXECUTION_ENABLED).toBe(true);
  });

  test('requires operator-owned credentials before ArcGIS online maps are enabled', () => {
    expect(() =>
      validateEnv(
        validProductionEnv({
          ARCGIS_ONLINE_ENABLED: 'true',
          ARCGIS_CLIENT_ID: '',
          ARCGIS_CLIENT_SECRET: '',
        }),
      ),
    ).toThrow('operator-owned credentials');

    const env = validateEnv(
      validProductionEnv({
        ARCGIS_ONLINE_ENABLED: 'true',
        ARCGIS_CLIENT_ID: validFixtureCredential('arcgis-client'),
        ARCGIS_CLIENT_SECRET: validFixtureCredential('arcgis-secret'),
      }),
    );
    expect(env.ARCGIS_ONLINE_ENABLED).toBe(true);
  });

  test('workload worker validates only its required credential boundary', () => {
    const workerEnv = validateWorkloadWorkerEnv({
      NODE_ENV: 'production',
      DB_HOST: 'db',
      DB_PORT: '5432',
      DB_NAME: 'gis_app',
      DB_USER: 'gis_runtime',
      DB_PASSWORD: 'G7m4Q2v9N8s6K3x1',
      WORKLOAD_WORKER_MODE: 'external',
      WORKLOAD_HARD_EXIT_ON_TIMEOUT: 'true',
      STORAGE_DRIVER: 's3',
      STORAGE_S3_ENDPOINT: 'https://fixture.compat.objectstorage.me-jeddah-1.oraclecloud.com',
      STORAGE_S3_REGION: 'me-jeddah-1',
      STORAGE_S3_ACCESS_KEY_ID: validFixtureCredential('oci-access-fixture'),
      STORAGE_S3_SECRET_ACCESS_KEY: validFixtureCredential('oci-secret-fixture'),
      STORAGE_S3_UPLOADS_BUCKET: 'terraleb-fixture-uploads',
      STORAGE_S3_EXPORTS_BUCKET: 'terraleb-fixture-exports',
      STORAGE_S3_OFFLINE_BUCKET: 'terraleb-fixture-offline',
      STORAGE_S3_AI_BUCKET: 'terraleb-fixture-ai',
      STORAGE_S3_BACKUPS_BUCKET: 'terraleb-fixture-backups',
      STORAGE_S3_PREFIX: 'terraleb-fixture',
      PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64: Buffer.alloc(32, 7).toString('base64'),
      PRIVACY_EXPORT_TTL_HOURS: '24',
      PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE: 'approved-retention-policy-2026',
      LOG_PRETTY: 'false',
      LOG_TO_FILE: 'false',
    });
    expect(workerEnv.DB_USER).toBe('gis_runtime');
    expect(workerEnv.WORKLOAD_WORKER_MODE).toBe('external');

    expect(() =>
      validateWorkloadWorkerEnv({
        ...workerEnv,
        DB_PASSWORD: 'replace-with-password',
      }),
    ).toThrow('DB_PASSWORD');
  });

  test('compares operational tokens without accepting partial values', () => {
    expect(safeTokenEqual('a-strong-operational-token', 'a-strong-operational-token')).toBe(true);
    expect(safeTokenEqual('a-strong-operational', 'a-strong-operational-token')).toBe(false);
    expect(safeTokenEqual('', 'a-strong-operational-token')).toBe(false);
  });

  test('removes query strings and high-cardinality identifiers from request paths', () => {
    expect(
      normalizeRequestPath(
        '/api/v1/projects/88b10e32-d91f-4c04-a582-b1f03c4fb853/features?bbox=1,2,3,4&token=secret',
      ),
    ).toBe('/api/v1/projects/:id/features');
  });

  test('accepts only bounded safe request IDs', () => {
    expect(normalizeRequestId('trace-123_A.B')).toBe('trace-123_A.B');
    expect(normalizeRequestId('trace\r\nx-injected: yes')).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
    expect(normalizeRequestId('x'.repeat(129))).not.toBe('x'.repeat(129));
  });

  test('redacts nested credentials, private keys, tokens, and GIS payloads', () => {
    const redacted = redactSensitive({
      password: 'do-not-log',
      nested: {
        authorization: 'Bearer abc.def.ghi',
        newPassword: 'also-do-not-log',
        jwtSecretCurrent: 'never-log-this',
        geometry: { type: 'Point', coordinates: [1, 2] },
        attributes: { owner: 'sensitive-field-data' },
        storagePath: 'tenant/project/private-object.jpg',
        safeCount: 3,
      },
    });
    expect(redacted.password).toBe('[REDACTED]');
    expect(redacted.nested.authorization).toBe('[REDACTED]');
    expect(redacted.nested.newPassword).toBe('[REDACTED]');
    expect(redacted.nested.jwtSecretCurrent).toBe('[REDACTED]');
    expect(redacted.nested.geometry).toBe('[REDACTED]');
    expect(redacted.nested.attributes).toBe('[REDACTED]');
    expect(redacted.nested.storagePath).toBe('[REDACTED]');
    expect(redacted.nested.safeCount).toBe(3);

    const line = sanitizeLogString(
      'Authorization: Bearer abc.def.ghi redis://user:password@valkey:6379',
    );
    expect(line).not.toContain('abc.def.ghi');
    expect(line).not.toContain('user:password');
  });
});
