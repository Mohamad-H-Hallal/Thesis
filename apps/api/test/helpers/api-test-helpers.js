const bcrypt = require('bcryptjs');
const request = require('supertest');
const { Pool } = require('pg');
const { applyTestEnvDefaults } = require('../../src/config/testEnv');
applyTestEnvDefaults();

const { buildApp } = require('../../src/app');
const { closePool } = require('../../src/config/database');
const { validateEnv } = require('../../src/config/env');
const { storageAdapter } = require('../../src/services/storageAdapter.service');
const {
  clearVerificationTestOutboxes,
  getMockEmailVerificationCodeForTest,
} = require('../../src/services/contactVerification.service');
const {
  getMockPhoneVerificationCodeForTest,
  resetPhoneVerificationProviderForTest,
} = require('../../src/services/phoneVerificationProvider.service');
const { normalizeLebaneseMobile } = require('../../src/services/contactIdentity.service');
const {
  stopImportProcessingLoop,
  waitForImportProcessingIdle,
} = require('../../src/controllers/import.controller');
const {
  startWorkloadWorker,
  stopWorkloadWorker,
  waitForWorkloadWorkerIdle,
} = require('../../src/jobs/workloadWorker');

const API_PREFIX = process.env.API_PREFIX || '/api/v1';

const testEnv = {
  ...validateEnv(),
  NODE_ENV: 'test',
  CORS_ORIGIN: '',
  CORS_STRICT: false,
  CORS_CREDENTIALS: true,
  TRUST_PROXY: false,
  ENFORCE_HTTPS: false,
  API_VERSION_PREFIX: API_PREFIX,
  ENABLE_LEGACY_API_PREFIX: true,
  RATE_LIMIT_WINDOW_MS: 15 * 60 * 1000,
  RATE_LIMIT_MAX_REQUESTS: 1000,
  RATE_LIMIT_AUTH_MAX_REQUESTS: 1000,
  RATE_LIMIT_EXPORT_MAX_REQUESTS: 1000,
  AUDIT_LOG_ENABLED: true,
  METRICS_ENABLED: false,
};

const app = buildApp(testEnv);

const pool = new Pool({
  host: process.env.DB_HOST ?? 'localhost',
  port: Number(process.env.DB_PORT ?? 5432),
  database: process.env.DB_NAME ?? 'gis_app',
  user: process.env.DB_USER ?? 'gis_user',
  password: process.env.DB_PASSWORD ?? 'change_me',
});

const authHeader = (token) => ({ Authorization: `Bearer ${token}` });

const uniqueEmail = (prefix = 'phase10-user') =>
  `${prefix}-${Date.now()}-${Math.floor(Math.random() * 100000)}@example.com`;
let phoneSequence = Math.floor(Math.random() * 900000);
const uniquePhone = () => {
  phoneSequence = (phoneSequence + 1) % 1000000;
  return `71${String(phoneSequence).padStart(6, '0')}`;
};

const resetDb = async () => {
  clearVerificationTestOutboxes();
  resetPhoneVerificationProviderForTest();
  stopWorkloadWorker();
  await waitForWorkloadWorkerIdle();
  stopImportProcessingLoop();
  await waitForImportProcessingIdle();

  await pool.query(`
    ALTER TABLE project
    ADD COLUMN IF NOT EXISTS visible_to_contributors BOOLEAN NOT NULL DEFAULT TRUE
  `);

  await pool.query(`
    ALTER TABLE gis_import_job
    ADD COLUMN IF NOT EXISTS processing_attempt_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS processing_heartbeat_at TIMESTAMPTZ
  `);

  for (const status of ['created', 'starting', 'running', 'completed', 'cancelling', 'paused']) {
    await pool.query(`ALTER TYPE ai_run_status ADD VALUE IF NOT EXISTS '${status}'`);
  }

  await pool.query(`
    ALTER TABLE ai_run
      ADD COLUMN IF NOT EXISTS stage TEXT,
      ADD COLUMN IF NOT EXISTS progress DOUBLE PRECISION NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS message TEXT,
      ADD COLUMN IF NOT EXISTS ai_server_run_id TEXT,
      ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS callback_received_at TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS artifacts JSONB NOT NULL DEFAULT '{}'::jsonb,
      ADD COLUMN IF NOT EXISTS counts JSONB NOT NULL DEFAULT '{}'::jsonb,
      ADD COLUMN IF NOT EXISTS error_details JSONB NOT NULL DEFAULT '{}'::jsonb
  `);

  await pool.query(`
    ALTER TABLE ai_run
      DROP CONSTRAINT IF EXISTS chk_ai_run_progress,
      ADD CONSTRAINT chk_ai_run_progress CHECK (progress >= 0 AND progress <= 1),
      DROP CONSTRAINT IF EXISTS chk_ai_run_artifacts,
      ADD CONSTRAINT chk_ai_run_artifacts CHECK (jsonb_typeof(artifacts) = 'object'),
      DROP CONSTRAINT IF EXISTS chk_ai_run_counts_json,
      ADD CONSTRAINT chk_ai_run_counts_json CHECK (jsonb_typeof(counts) = 'object'),
      DROP CONSTRAINT IF EXISTS chk_ai_run_error_details,
      ADD CONSTRAINT chk_ai_run_error_details CHECK (jsonb_typeof(error_details) = 'object')
  `);

  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_ai_run_server_status_updated
      ON ai_run(status, updated_at DESC)
  `);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS gis_import_comment (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      import_job_id UUID NOT NULL REFERENCES gis_import_job(id) ON DELETE CASCADE,
      author_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
      comment_text TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  await pool.query(`
    ALTER TABLE gis_import_comment
    ADD COLUMN IF NOT EXISTS import_feature_id UUID NULL
    REFERENCES gis_import_feature(id) ON DELETE SET NULL
  `);

  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_gis_import_comment_feature_created
      ON gis_import_comment (import_feature_id, created_at ASC)
      WHERE import_feature_id IS NOT NULL
  `);

  await pool.query(`
    TRUNCATE TABLE
      contact_verification_audit_event,
      contact_verification_challenge,
      workload_job,
      feature_media_cleanup_job,
      notification_push_delivery,
      notification_delivery,
      push_device_registration,
      gis_import_comment,
      gis_import_feature,
      gis_import_job,
      notification,
      audit_log,
      password_reset_request,
      photo,
      spatial_feature,
      shapefile_export,
      project_assignment,
      project,
      project_category,
      lebanon_offline_map,
      "user"
    RESTART IDENTITY CASCADE
  `);
  startWorkloadWorker();
};

const cleanupExportFiles = async () => {
  const result = await pool.query(
    `SELECT DISTINCT file_path
     FROM shapefile_export
     WHERE file_path IS NOT NULL`,
  );

  for (const row of result.rows) {
    try {
      await storageAdapter.remove(row.file_path);
    } catch (_error) {
      // Ignore missing/deleted files
    }
  }
};

const shutdown = async () => {
  stopWorkloadWorker();
  await waitForWorkloadWorkerIdle();
  await pool.end();
  await closePool();
};

const registerUser = async ({
  role = 'contributor',
  fullName = 'Phase10 User',
  password = 'Passw0rd!123',
  phone,
  emailPrefix = 'phase10-user',
} = {}) => {
  const email = uniqueEmail(emailPrefix);
  const resolvedPhone = phone ?? uniquePhone();
  const payload = {
    email,
    password,
    full_name: fullName,
    phone: resolvedPhone,
  };
  if (role) {
    payload.role = role;
  }

  const response = await request(app).post(`${API_PREFIX}/auth/register`).send(payload);

  if (response.status !== 201) {
    throw new Error(`registerUser failed (${response.status}): ${JSON.stringify(response.body)}`);
  }

  let verificationToken = response.body.data.verification_token;
  const emailCode = getMockEmailVerificationCodeForTest(email, 'signup');
  const emailConfirmation = await request(app)
    .post(`${API_PREFIX}/auth/verification/email/confirm`)
    .set(authHeader(verificationToken))
    .send({ code: emailCode });
  if (emailConfirmation.status !== 200) {
    throw new Error(
      `email verification failed (${emailConfirmation.status}): ${JSON.stringify(emailConfirmation.body)}`,
    );
  }
  verificationToken = emailConfirmation.body.data.verification_token;

  const smsSend = await request(app)
    .post(`${API_PREFIX}/auth/verification/phone/send`)
    .set(authHeader(verificationToken))
    .send({});
  if (smsSend.status !== 200) {
    throw new Error(`SMS send failed (${smsSend.status}): ${JSON.stringify(smsSend.body)}`);
  }
  const phoneE164 = normalizeLebaneseMobile(resolvedPhone).e164;
  const smsCode = getMockPhoneVerificationCodeForTest(phoneE164, 'signup');
  const phoneConfirmation = await request(app)
    .post(`${API_PREFIX}/auth/verification/phone/confirm`)
    .set(authHeader(verificationToken))
    .send({ code: smsCode });
  if (phoneConfirmation.status !== 200) {
    throw new Error(
      `phone verification failed (${phoneConfirmation.status}): ${JSON.stringify(phoneConfirmation.body)}`,
    );
  }

  return {
    email,
    password,
    message: phoneConfirmation.body.message,
    user: phoneConfirmation.body.data.user,
  };
};

const createAdminUser = async ({
  fullName = 'Phase10 Admin',
  password = 'Passw0rd!123',
  phone,
  emailPrefix = 'phase10-admin',
  email,
} = {}) => {
  const resolvedEmail = email ?? uniqueEmail(emailPrefix);
  const resolvedPhone = phone ?? uniquePhone();
  const phoneE164 = normalizeLebaneseMobile(resolvedPhone).e164;
  const passwordHash = await bcrypt.hash(password, 12);

  const insertResult = await pool.query(
    `INSERT INTO "user"
       (email, email_original, email_canonical, email_verified_at, password_hash,
        full_name, phone, phone_e164, phone_verified_at, role, is_active, account_status)
     VALUES ($1, $1, LOWER($1), CURRENT_TIMESTAMP, $2, $3, $4, $4,
             CURRENT_TIMESTAMP, 'admin', TRUE, 'active')
     RETURNING id, email, full_name, phone, role, created_at`,
    [resolvedEmail, passwordHash, fullName, phoneE164],
  );

  const loginData = await loginUser({ email: resolvedEmail, password });

  return {
    email: resolvedEmail,
    password,
    token: loginData.token,
    refreshToken: loginData.refreshToken,
    user: insertResult.rows[0],
  };
};

const approveContributorRequest = async ({ token, userId }) => {
  const response = await request(app)
    .post(`${API_PREFIX}/users/${userId}/approve-contributor`)
    .set(authHeader(token));

  if (response.status !== 200) {
    throw new Error(
      `approveContributorRequest failed (${response.status}): ${JSON.stringify(response.body)}`,
    );
  }

  return response.body.data;
};

const rejectContributorRequest = async ({ token, userId }) => {
  const response = await request(app)
    .post(`${API_PREFIX}/users/${userId}/reject-contributor`)
    .set(authHeader(token));

  if (response.status !== 200) {
    throw new Error(
      `rejectContributorRequest failed (${response.status}): ${JSON.stringify(response.body)}`,
    );
  }

  return response.body.data;
};

const loginUser = async ({ email, password }) => {
  const response = await request(app).post(`${API_PREFIX}/auth/login`).send({ email, password });
  if (response.status !== 200) {
    throw new Error(`loginUser failed (${response.status}): ${JSON.stringify(response.body)}`);
  }
  return response.body.data;
};

const createCategory = async ({ token, name, description = 'Phase 10 category' }) => {
  const response = await request(app).post(`${API_PREFIX}/categories`).set(authHeader(token)).send({
    name,
    description,
  });

  if (response.status !== 201) {
    throw new Error(`createCategory failed (${response.status}): ${JSON.stringify(response.body)}`);
  }

  return response.body.data;
};

const createProject = async ({
  token,
  categoryId,
  name,
  visibleToViewers = false,
  visibleToContributors = true,
  status = 'draft',
}) => {
  const response = await request(app)
    .post(`${API_PREFIX}/projects`)
    .set(authHeader(token))
    .send({
      category_id: categoryId,
      name,
      description: 'Phase 10 project',
      collection_form_schema: {
        schemaVersion: '0.1.0',
        fields: [
          {
            key: 'feature_type',
            label: 'Feature type',
            type: 'select',
            required: true,
            options: ['olive', 'citrus', 'cedar', 'pine', 'apple', 'oak'],
          },
          {
            key: 'condition',
            label: 'Condition',
            type: 'select',
            required: false,
            options: ['good', 'fair', 'healthy'],
          },
        ],
      },
      status,
      requires_photos: false,
      min_photos: 0,
      max_photos: 3,
      visible_to_viewers: visibleToViewers,
      visible_to_contributors: visibleToContributors,
    });

  if (response.status !== 201) {
    throw new Error(`createProject failed (${response.status}): ${JSON.stringify(response.body)}`);
  }

  return response.body.data;
};

const createAssignment = async ({ token, projectId, userId, role = 'contributor' }) => {
  const response = await request(app)
    .post(`${API_PREFIX}/assignments`)
    .set(authHeader(token))
    .send({
      project_id: projectId,
      user_id: userId,
      role,
    });

  if (response.status !== 201) {
    throw new Error(
      `createAssignment failed (${response.status}): ${JSON.stringify(response.body)}`,
    );
  }

  return response.body.data;
};

const updateAssignmentStatus = async ({ token, assignmentId, status }) => {
  const response = await request(app)
    .put(`${API_PREFIX}/assignments/${assignmentId}`)
    .set(authHeader(token))
    .send({ status });

  if (response.status !== 200) {
    throw new Error(
      `updateAssignmentStatus failed (${response.status}): ${JSON.stringify(response.body)}`,
    );
  }

  return response.body.data;
};

const waitForExportCompletion = async ({
  token,
  exportId,
  timeoutMs = Number(process.env.PERF_EXPORT_TIMEOUT_MS ?? 30000),
  intervalMs = 400,
}) => {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const response = await request(app)
      .get(`${API_PREFIX}/exports/${exportId}`)
      .set(authHeader(token));

    if (response.status !== 200) {
      throw new Error(
        `waitForExportCompletion failed (${response.status}): ${JSON.stringify(response.body)}`,
      );
    }

    const status = response.body?.data?.status;
    if (status === 'completed') {
      return response.body.data;
    }
    if (status === 'failed') {
      throw new Error(`Export failed: ${response.body?.data?.error_message ?? 'unknown error'}`);
    }

    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  throw new Error(`Export ${exportId} did not complete within ${timeoutMs}ms`);
};

const collectPlanNodes = (planNode, nodes = []) => {
  nodes.push(planNode);
  if (Array.isArray(planNode.Plans)) {
    for (const child of planNode.Plans) {
      collectPlanNodes(child, nodes);
    }
  }
  return nodes;
};

module.exports = {
  app,
  API_PREFIX,
  pool,
  request,
  authHeader,
  resetDb,
  cleanupExportFiles,
  shutdown,
  registerUser,
  createAdminUser,
  loginUser,
  approveContributorRequest,
  rejectContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  waitForExportCompletion,
  collectPlanNodes,
};
