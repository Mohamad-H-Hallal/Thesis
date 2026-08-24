import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
  randomUUID,
} from 'node:crypto';
import fs from 'node:fs';
import fsPromises from 'node:fs/promises';
import path from 'node:path';
import { Transform, type TransformCallback, type Readable } from 'node:stream';
import type { PoolClient, QueryResult, QueryResultRow } from 'pg';
import { query, transaction } from '../config/database';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import { enqueueWorkloadJob } from './workloadQueue.service';

interface QueryExecutor {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: unknown[],
  ): Promise<QueryResult<T>>;
}

interface PrivacyExportArtifactRow {
  id: string;
  privacy_request_id: string;
  user_id: string;
  status: string;
  encrypted_file_path: string | null;
  encryption_iv: Buffer | null;
  encryption_auth_tag: Buffer | null;
  encryption_key_id: string | null;
  plaintext_sha256: string | null;
  content_type: string;
  expires_at: Date | string | null;
}

const forbiddenExportKeyPattern = /^(?:password(?:_hash)?|.*token.*|auth_version|secret|private_key|internal_.*|resolution_summary|authorization)$/i;

const sha256 = (value: Buffer | string): string =>
  createHash('sha256').update(value).digest('hex');

class Sha256VerificationTransform extends Transform {
  private readonly digest = createHash('sha256');

  constructor(private readonly expectedDigest: string) {
    super();
  }

  override _transform(chunk: Buffer, _encoding: BufferEncoding, callback: TransformCallback): void {
    this.digest.update(chunk);
    callback(null, chunk);
  }

  override _flush(callback: TransformCallback): void {
    const actualDigest = this.digest.digest('hex');
    callback(
      actualDigest === this.expectedDigest
        ? undefined
        : new Error('PRIVACY_EXPORT_INTEGRITY_CHECK_FAILED'),
    );
  }
}

const configuredEncryptionKey = (): { key: Buffer; keyId: string } => {
  const configured = String(process.env.PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64 ?? '').trim();
  if (configured) {
    const key = Buffer.from(configured, 'base64');
    if (key.length !== 32) {
      throw new Error('PRIVACY_EXPORT_ENCRYPTION_KEY_INVALID');
    }
    return {
      key,
      keyId: String(process.env.PRIVACY_EXPORT_ENCRYPTION_KEY_ID ?? 'primary').trim() || 'primary',
    };
  }
  if (process.env.NODE_ENV === 'production') {
    throw new Error('PRIVACY_EXPORT_ENCRYPTION_KEY_REQUIRED');
  }
  const developmentSecret =
    process.env.JWT_SECRET_CURRENT ?? process.env.JWT_SECRET ?? 'terraleb-test-export-key';
  return {
    key: createHash('sha256').update(`privacy-export:${developmentSecret}`).digest(),
    keyId: 'development-derived-key',
  };
};

const artifactTtlHours = (): number => {
  const raw = String(process.env.PRIVACY_EXPORT_TTL_HOURS ?? '').trim();
  if (!raw && process.env.NODE_ENV === 'production') {
    throw new Error('PRIVACY_EXPORT_TTL_HOURS_REQUIRED');
  }
  const parsed = Number.parseInt(raw || '24', 10);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 168) {
    throw new Error('PRIVACY_EXPORT_TTL_HOURS_INVALID');
  }
  return parsed;
};

const assertPrivacyExportPolicyConfigured = (): void => {
  configuredEncryptionKey();
  artifactTtlHours();
  if (
    process.env.NODE_ENV === 'production' &&
    !String(process.env.PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE ?? '').trim()
  ) {
    throw new Error('PRIVACY_EXPORT_RETENTION_APPROVAL_REQUIRED');
  }
};

const exportDirectory = (): string =>
  path.resolve(
    process.env.PRIVACY_EXPORT_DIR?.trim() ||
      path.join(process.env.EXPORT_DIR?.trim() || './exports', 'privacy-data'),
  );

const assertSafeArtifactPath = (filePath: string): string => {
  const base = exportDirectory();
  const resolved = path.resolve(filePath);
  if (resolved !== base && !resolved.startsWith(`${base}${path.sep}`)) {
    throw new Error('PRIVACY_EXPORT_PATH_INVALID');
  }
  return resolved;
};

const assertNoForbiddenKeys = (value: unknown, pathParts: string[] = []): void => {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoForbiddenKeys(item, [...pathParts, String(index)]));
    return;
  }
  if (!value || typeof value !== 'object') {
    return;
  }
  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    if (forbiddenExportKeyPattern.test(key)) {
      throw new Error(`PRIVACY_EXPORT_FORBIDDEN_FIELD:${[...pathParts, key].join('.')}`);
    }
    assertNoForbiddenKeys(nested, [...pathParts, key]);
  }
};

const escapeHtml = (value: string): string =>
  value.replace(
    /[&<>"']/g,
    (character) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character] ??
      character,
  );

const exportSectionLabels: Readonly<Record<string, string>> = {
  profile: 'Account profile',
  legal_acceptances: 'Legal acceptances',
  privacy_requests: 'Privacy requests',
  project_assignments: 'Project assignments',
  contributed_features: 'Contributed features',
  contributed_photo_metadata: 'Photo metadata',
  uploaded_imports: 'Uploaded imports',
  imported_features: 'Imported features',
  requested_project_exports: 'Requested project exports',
  authored_import_comments: 'Import comments',
  ai_validation_submissions: 'AI validation submissions',
  notification_index: 'Notifications',
  submitted_content_reports: 'Submitted content reports',
  audit_activity_index: 'Account activity',
};

const humanizeExportKey = (value: string): string =>
  value
    .split('_')
    .filter(Boolean)
    .map((part) => `${part.slice(0, 1).toUpperCase()}${part.slice(1)}`)
    .join(' ')
    .replace(/^Exif\b/, 'EXIF')
    .replace(/^Ai\b/, 'AI');

const isTechnicalExportField = (key: string): boolean =>
  key === 'id' ||
  key.endsWith('_id') ||
  key === 'geometry' ||
  key === 'location' ||
  key === 'checksum_sha256' ||
  key === 'source_identifier';

const displayExportValue = (value: unknown, key: string): string => {
  if (value === null || value === undefined || value === '') {
    return 'Not recorded';
  }
  if (value instanceof Date) {
    return value.toLocaleString('en-GB', {
      dateStyle: 'medium',
      timeStyle: 'short',
      timeZone: 'Asia/Beirut',
    });
  }
  if (typeof value === 'boolean') {
    return value ? 'Yes' : 'No';
  }
  if (
    typeof value === 'string' &&
    ['status', 'role', 'request_type', 'document_type', 'entity_type', 'reason_code', 'outcome_code', 'file_status'].includes(key)
  ) {
    return humanizeExportKey(value);
  }
  if (typeof value === 'string' && (key.endsWith('_at') || key.endsWith('_date'))) {
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.getTime())) {
      return parsed.toLocaleString('en-GB', {
        dateStyle: 'medium',
        timeStyle: key.endsWith('_at') ? 'short' : undefined,
        timeZone: 'Asia/Beirut',
      });
    }
  }
  if (typeof value === 'object') {
    return JSON.stringify(value, null, 2);
  }
  return String(value);
};

const renderExportFields = (entries: [string, unknown][]): string =>
  entries
    .map(([key, value]) => {
      const rendered = displayExportValue(value, key);
      const isStructured = typeof value === 'object' && value !== null && !(value instanceof Date);
      return `<div class="field"><dt>${escapeHtml(humanizeExportKey(key))}</dt><dd dir="auto"${isStructured ? ' class="structured"' : ''}>${escapeHtml(rendered)}</dd></div>`;
    })
    .join('');

const renderExportRecord = (record: unknown, index: number, total: number): string => {
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    return `<article class="record"><dl>${renderExportFields([['value', record]])}</dl></article>`;
  }
  const entries = Object.entries(record as Record<string, unknown>);
  const primary = entries.filter(([key]) => !isTechnicalExportField(key));
  const technical = entries.filter(([key]) => isTechnicalExportField(key));
  return `<article class="record">
    ${total > 1 ? `<h3>Record ${index + 1}</h3>` : ''}
    <dl>${renderExportFields(primary)}</dl>
    ${
      technical.length
        ? `<details><summary>Technical details</summary><dl>${renderExportFields(technical)}</dl></details>`
        : ''
    }
  </article>`;
};

const renderPersonalDataHtml = (payload: Record<string, unknown>): string => {
  const manifest = (payload.manifest ?? {}) as Record<string, unknown>;
  const data = (payload.data ?? {}) as Record<string, unknown>;
  const counts = (manifest.record_counts ?? {}) as Record<string, unknown>;
  const sections = Object.entries(data)
    .map(([key, value]) => {
      const records = Array.isArray(value) ? value : value ? [value] : [];
      const label = exportSectionLabels[key] ?? humanizeExportKey(key);
      return `<section>
        <div class="section-heading"><h2>${escapeHtml(label)}</h2><span>${records.length} ${records.length === 1 ? 'record' : 'records'}</span></div>
        ${
          records.length
            ? records.map((record, index) => renderExportRecord(record, index, records.length)).join('')
            : '<p class="empty">No records in this section.</p>'
        }
      </section>`;
    })
    .join('');
  const summary = Object.entries(counts)
    .map(
      ([key, value]) =>
        `<div class="summary-item"><strong>${escapeHtml(String(value))}</strong><span>${escapeHtml(exportSectionLabels[key] ?? humanizeExportKey(key))}</span></div>`,
    )
    .join('');
  const generatedAt = displayExportValue(manifest.generated_at, 'generated_at');

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
  <title>TerraLeb personal data report</title>
  <style>
    :root { color-scheme: light; font-family: Arial, Helvetica, sans-serif; color: #172019; background: #f4f7f4; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #f4f7f4; line-height: 1.5; }
    main { width: min(100% - 24px, 980px); margin: 24px auto 48px; }
    header, section { background: #fff; border: 1px solid #d9e1da; border-radius: 18px; padding: 20px; margin-bottom: 16px; box-shadow: 0 5px 18px rgba(22, 64, 39, .06); }
    header { border-top: 6px solid #22764f; }
    h1, h2, h3, p { margin-top: 0; }
    h1 { color: #185b3d; margin-bottom: 4px; }
    h2 { font-size: 1.25rem; margin: 0; }
    h3 { font-size: 1rem; color: #185b3d; margin-bottom: 12px; }
    .meta, .empty { color: #526057; }
    .notice { padding: 12px 14px; border-radius: 12px; background: #e9f4ed; color: #194c35; }
    .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-top: 18px; }
    .summary-item { border: 1px solid #dce5de; border-radius: 12px; padding: 12px; }
    .summary-item strong { display: block; color: #185b3d; font-size: 1.35rem; }
    .summary-item span { color: #526057; font-size: .88rem; }
    .section-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding-bottom: 12px; border-bottom: 1px solid #e2e8e3; }
    .section-heading span { white-space: nowrap; background: #e7efe9; border-radius: 999px; padding: 4px 10px; font-size: .82rem; font-weight: 700; }
    .record { padding: 16px 0 4px; border-bottom: 1px solid #eef2ef; }
    .record:last-child { border-bottom: 0; }
    dl { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 10px 18px; margin: 0; }
    .field { min-width: 0; }
    dt { color: #607068; font-size: .8rem; font-weight: 700; text-transform: uppercase; letter-spacing: .03em; }
    dd { margin: 3px 0 0; overflow-wrap: anywhere; }
    dd.structured { white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .85rem; background: #f5f7f5; border-radius: 9px; padding: 9px; }
    details { margin-top: 14px; border: 1px solid #e1e7e2; border-radius: 10px; padding: 10px 12px; }
    summary { cursor: pointer; color: #286449; font-weight: 700; }
    details dl { margin-top: 12px; }
    footer { color: #66736a; text-align: center; font-size: .82rem; padding: 8px; }
    @media (max-width: 540px) { main { width: min(100% - 16px, 980px); margin-top: 8px; } header, section { padding: 16px; border-radius: 14px; } .section-heading { align-items: flex-start; } dl { grid-template-columns: 1fr; } }
    @media print { body { background: #fff; } main { width: 100%; margin: 0; } header, section { box-shadow: none; break-inside: avoid; } details { display: block; } }
  </style>
</head>
<body>
<main>
  <header>
    <h1>TerraLeb personal data report</h1>
    <p class="meta">Generated ${escapeHtml(generatedAt)} in Lebanon time</p>
    <p class="notice">This report contains data linked to your account and your recorded activity. Empty sections mean that no matching records were found.</p>
    <div class="summary">${summary}</div>
  </header>
  ${sections}
  <footer>Keep this report private because it may contain personal and location information.</footer>
</main>
</body>
</html>`;
};

const rows = async <T extends QueryResultRow>(
  executor: QueryExecutor,
  sql: string,
  userId: string,
): Promise<T[]> => (await executor.query<T>(sql, [userId])).rows;

const buildPersonalDataPayload = async (
  executor: QueryExecutor,
  userId: string,
): Promise<{ payload: Record<string, unknown>; counts: Record<string, number> }> => {
  const [
    profile,
    legalAcceptances,
    privacyRequests,
    assignments,
    features,
    photos,
    imports,
    importFeatures,
    projectExports,
    importComments,
    aiSubmissions,
    notifications,
    contentReports,
    auditActivity,
  ] = await Promise.all([
    rows(executor, `SELECT id, email_original AS email, full_name, phone_e164 AS phone,
                           role, account_status, created_at, last_login,
                           email_verified_at, phone_verified_at
                    FROM "user" WHERE id = $1`, userId),
    rows(executor, `SELECT document_type, document_version, locale, accepted_at,
                           withdrawn_at, superseded_at
                    FROM legal_acceptance WHERE user_id = $1 ORDER BY accepted_at`, userId),
    rows(executor, `SELECT id, request_type, status, request_details, requested_at,
                           acknowledged_at, completed_at, cancelled_at,
                           resolution_code, last_user_visible_message
                    FROM privacy_request WHERE user_id = $1 ORDER BY requested_at`, userId),
    rows(executor, `SELECT assignment.id, assignment.project_id,
                           project.name AS project_title, assignment.role,
                           assignment.status, assignment.assigned_date,
                           assignment.approved_date, assignment.created_at
                    FROM project_assignment assignment
                    LEFT JOIN project ON project.id = assignment.project_id
                    WHERE assignment.user_id = $1 ORDER BY assignment.created_at`, userId),
    rows(executor, `SELECT feature.id, feature.project_id,
                           project.name AS project_title,
                           ST_AsGeoJSON(feature.geom)::JSONB AS geometry,
                           feature.attributes, feature.status, feature.collected_at,
                           feature.submitted_at, feature.reviewed_at,
                           feature.accuracy_meters, feature.collected_offline,
                           feature.synced_at, feature.version, feature.source_provenance
                    FROM spatial_feature feature
                    LEFT JOIN project ON project.id = feature.project_id
                    WHERE feature.collected_by_user_id = $1
                    ORDER BY feature.collected_at`, userId),
    rows(executor, `SELECT ph.id, ph.feature_id, project.name AS project_title,
                           ST_AsGeoJSON(ph.location)::JSONB AS location,
                           ph.accuracy_meters, ph.taken_at, ph.exif_data, ph.file_size_bytes,
                           ph.status, ph.display_order, ph.uploaded_at
                    FROM photo ph
                    JOIN spatial_feature feature ON feature.id = ph.feature_id
                    LEFT JOIN project ON project.id = feature.project_id
                    WHERE feature.collected_by_user_id = $1 ORDER BY ph.uploaded_at`, userId),
    rows(executor, `SELECT job.id, job.project_id, project.name AS project_title,
                           job.original_filename, job.file_size_bytes,
                           job.file_checksum_sha256 AS checksum_sha256,
                           job.status, job.uploaded_at, job.processed_at, job.reviewed_at,
                           job.geometry_count AS feature_count, job.source_provider,
                           job.source_dataset_name, job.source_dataset_date,
                           job.source_accuracy_statement, job.source_license_or_authority,
                           job.source_attribution, job.source_terms_url,
                           job.source_redistribution_rules
                    FROM gis_import_job job
                    LEFT JOIN project ON project.id = job.project_id
                    WHERE job.uploaded_by_user_id = $1 ORDER BY job.uploaded_at`, userId),
    rows(executor, `SELECT feature.id, feature.import_job_id, feature.source_index,
                           feature.source_identifier, feature.display_title,
                           feature.source_feature_name, feature.geometry_type,
                           ST_AsGeoJSON(feature.geom)::JSONB AS geometry,
                           feature.attributes, feature.status,
                           feature.validation_warnings, feature.validation_errors,
                           feature.review_reason, feature.created_at,
                           feature.reviewed_at, feature.approved_at
                    FROM gis_import_feature feature
                    JOIN gis_import_job job ON job.id = feature.import_job_id
                    WHERE job.uploaded_by_user_id = $1
                    ORDER BY job.uploaded_at, feature.source_index`, userId),
    rows(executor, `SELECT export_job.id, export_job.project_id,
                           project.name AS project_title,
                           export_job.requested_at, export_job.completed_at,
                           export_job.feature_count, export_job.export_parameters,
                           export_job.status, export_job.file_size_bytes,
                           export_job.file_status, export_job.retention_expires_at,
                           export_job.retention_expired_at
                    FROM shapefile_export export_job
                    LEFT JOIN project ON project.id = export_job.project_id
                    WHERE export_job.requested_by_user_id = $1
                    ORDER BY export_job.requested_at`, userId),
    rows(executor, `SELECT comment.id, comment.import_job_id,
                           project.name AS project_title, comment.comment_text,
                           comment.created_at
                    FROM gis_import_comment comment
                    JOIN gis_import_job job ON job.id = comment.import_job_id
                    LEFT JOIN project ON project.id = job.project_id
                    WHERE comment.author_user_id = $1 ORDER BY comment.created_at`, userId),
    rows(executor, `SELECT id, validation_task_id, result, corrected_class, note, evidence,
                           linked_feature_id, status, created_at, reviewed_at
                    FROM ai_prediction_validation_submission
                    WHERE submitted_by = $1 ORDER BY created_at`, userId),
    rows(executor, `SELECT id, type, title, is_read, created_at, read_at
                    FROM notification WHERE user_id = $1 ORDER BY created_at`, userId),
    rows(executor, `SELECT report.id, report.project_id,
                           project.name AS project_title, report.entity_type,
                           report.entity_id, report.reason_code, report.description,
                           report.status, report.user_visible_message,
                           report.outcome_code, report.created_at,
                           report.updated_at, report.resolved_at
                    FROM content_report report
                    LEFT JOIN project ON project.id = report.project_id
                    WHERE report.reporter_user_id = $1 ORDER BY report.created_at`, userId),
    rows(executor, `SELECT id, action_type, entity_type, entity_id, created_at
                    FROM audit_log WHERE user_id = $1 ORDER BY created_at`, userId),
  ]);

  const data = {
    profile: profile[0] ?? null,
    legal_acceptances: legalAcceptances,
    privacy_requests: privacyRequests,
    project_assignments: assignments,
    contributed_features: features,
    contributed_photo_metadata: photos,
    uploaded_imports: imports,
    imported_features: importFeatures,
    requested_project_exports: projectExports,
    authored_import_comments: importComments,
    ai_validation_submissions: aiSubmissions,
    notification_index: notifications,
    submitted_content_reports: contentReports,
    audit_activity_index: auditActivity,
  };
  const counts = Object.fromEntries(
    Object.entries(data).map(([key, value]) => [key, Array.isArray(value) ? value.length : value ? 1 : 0]),
  );
  const payload = {
    manifest: {
      format: 'TerraLeb personal data export',
      format_version: 'terraleb-personal-data-v2',
      generated_at: new Date().toISOString(),
      subject_user_id: userId,
      notes: [
        'This export contains data linked to your TerraLeb account and your own recorded activity.',
        'Security secrets, authorization internals, confidential moderation notes, and other users’ personal data are excluded.',
      ],
      record_counts: counts,
    },
    data,
  };
  assertNoForbiddenKeys(payload);
  return { payload, counts };
};

const schedulePersonalDataExport = async (
  executor: PoolClient,
  { requestId, userId }: { requestId: string; userId: string },
): Promise<string> => {
  assertPrivacyExportPolicyConfigured();
  const artifact = await executor.query<{ id: string }>(
    `INSERT INTO privacy_export_artifact (privacy_request_id, user_id, status)
     VALUES ($1, $2, 'pending')
     ON CONFLICT (privacy_request_id) DO UPDATE
       SET status = CASE
             WHEN privacy_export_artifact.status = 'failed' THEN 'pending'
             ELSE privacy_export_artifact.status
           END,
           failure_code = CASE
             WHEN privacy_export_artifact.status = 'failed' THEN NULL
             ELSE privacy_export_artifact.failure_code
           END,
           updated_at = CURRENT_TIMESTAMP
     RETURNING id`,
    [requestId, userId],
  );
  await enqueueWorkloadJob(executor, {
    kind: 'privacy_access_export',
    entityId: artifact.rows[0].id,
    maxAttempts: Number.parseInt(process.env.WORKLOAD_MAX_ATTEMPTS ?? '3', 10),
  });
  return artifact.rows[0].id;
};

const processPersonalDataExport = async (artifactId: string): Promise<void> => {
  const claimed = await transaction(async (client) => {
    const result = await client.query<PrivacyExportArtifactRow>(
      `SELECT artifact.*, request.status AS request_status
       FROM privacy_export_artifact artifact
       JOIN privacy_request request ON request.id = artifact.privacy_request_id
       WHERE artifact.id = $1
         AND artifact.status IN ('pending', 'generating', 'failed')
         AND request.request_type = 'access_export'
         AND request.status IN ('approved', 'scheduled', 'processing', 'failed')
       FOR UPDATE OF artifact, request`,
      [artifactId],
    );
    const artifact = result.rows[0];
    if (!artifact) {
      return null;
    }
    await client.query(
      `UPDATE privacy_export_artifact
       SET status = 'generating', failure_code = NULL, updated_at = CURRENT_TIMESTAMP
       WHERE id = $1`,
      [artifactId],
    );
    await client.query(
      `UPDATE privacy_request
       SET status = 'processing', execution_started_at = COALESCE(execution_started_at, CURRENT_TIMESTAMP),
           failed_at = NULL, failure_code = NULL, updated_at = CURRENT_TIMESTAMP
       WHERE id = $1`,
      [artifact.privacy_request_id],
    );
    await client.query(
      `INSERT INTO privacy_request_status_history
         (request_id, from_status, to_status, actor_kind, user_visible_message)
       VALUES ($1, $2, 'processing', 'worker',
               'We are preparing your personal-data export.')`,
      [artifact.privacy_request_id, (artifact as PrivacyExportArtifactRow & { request_status: string }).request_status],
    );
    return artifact;
  });
  if (!claimed) {
    return;
  }

  let temporaryPath: string | null = null;
  let completedPath: string | null = null;
  try {
    const { payload, counts } = await buildPersonalDataPayload({ query }, claimed.user_id);
    const plaintext = Buffer.from(renderPersonalDataHtml(payload), 'utf8');
    const maxBytes = Number.parseInt(process.env.PRIVACY_EXPORT_MAX_BYTES ?? '52428800', 10);
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 1024 || plaintext.length > maxBytes) {
      throw new Error('PRIVACY_EXPORT_SIZE_LIMIT');
    }
    const { key, keyId } = configuredEncryptionKey();
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', key, iv);
    const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const tag = cipher.getAuthTag();
    const directory = exportDirectory();
    await fsPromises.mkdir(directory, { recursive: true, mode: 0o700 });
    const finalPath = assertSafeArtifactPath(path.join(directory, `${artifactId}.html.enc`));
    temporaryPath = assertSafeArtifactPath(path.join(directory, `.${artifactId}.${randomUUID()}.tmp`));
    await fsPromises.writeFile(temporaryPath, encrypted, { mode: 0o600, flag: 'wx' });
    await fsPromises.rename(temporaryPath, finalPath);
    temporaryPath = null;
    completedPath = finalPath;
    const expiresAt = new Date(Date.now() + artifactTtlHours() * 60 * 60 * 1000);

    await transaction(async (client) => {
      const updated = await client.query(
        `UPDATE privacy_export_artifact
         SET status = 'ready', encrypted_file_path = $2,
             format_version = 'terraleb-personal-data-v2',
             content_type = 'text/html; charset=utf-8',
             encryption_algorithm = 'AES-256-GCM', encryption_key_id = $3,
             encryption_iv = $4, encryption_auth_tag = $5,
             plaintext_sha256 = $6, encrypted_size_bytes = $7,
             record_counts = $8::JSONB, generated_at = CURRENT_TIMESTAMP,
             expires_at = $9, failure_code = NULL, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status = 'generating'
         RETURNING id`,
        [
          artifactId,
          finalPath,
          keyId,
          iv,
          tag,
          sha256(plaintext),
          encrypted.length,
          JSON.stringify(counts),
          expiresAt,
        ],
      );
      if (updated.rowCount !== 1 || !fs.existsSync(finalPath)) {
        throw new Error('PRIVACY_EXPORT_ARTIFACT_VALIDATION_FAILED');
      }
      await client.query(
        `UPDATE privacy_request
         SET status = 'completed', completed_at = CURRENT_TIMESTAMP,
             last_user_visible_message = 'Your personal-data export is ready for a limited time.',
             resolution_code = 'export_generated',
             resolution_summary = 'The requester-isolated encrypted export passed artifact validation.',
             updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status = 'processing'`,
        [claimed.privacy_request_id],
      );
      await client.query(
        `INSERT INTO privacy_request_status_history
           (request_id, from_status, to_status, actor_kind, user_visible_message,
            resolution_code, resolution_summary)
         VALUES ($1, 'processing', 'completed', 'worker',
                 'Your personal-data export is ready for a limited time.',
                 'export_generated', 'Encrypted artifact generated and validated.')`,
        [claimed.privacy_request_id],
      );
      const notification = await client.query<{ id: string }>(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'account_event', 'Your data export is ready',
                 'Open Privacy & data to create a secure download link.',
                 $2::JSONB)
         RETURNING id`,
        [claimed.user_id, JSON.stringify({ privacy_request_id: claimed.privacy_request_id })],
      );
      await publishRealtimeChanges(
        [
          {
            scopeType: 'privacy_requests',
            scopeId: claimed.user_id,
            action: 'export_ready',
            entityType: 'privacy_request',
            entityId: claimed.privacy_request_id,
            audience: { kind: 'user', userId: claimed.user_id },
          },
          {
            scopeType: 'privacy_admin_queue',
            scopeId: 'all',
            action: 'request_completed',
            entityType: 'privacy_request',
            entityId: claimed.privacy_request_id,
            audience: { kind: 'protected_admins' },
          },
          {
            scopeType: 'notifications',
            scopeId: claimed.user_id,
            action: 'created',
            entityType: 'notification',
            entityId: notification.rows[0].id,
            audience: { kind: 'user', userId: claimed.user_id },
          },
        ],
        client,
      );
    });
    completedPath = null;
  } catch (error) {
    if (temporaryPath) {
      await fsPromises.unlink(temporaryPath).catch(() => undefined);
    }
    if (completedPath) {
      await fsPromises.unlink(completedPath).catch(() => undefined);
    }
    const code = String(error instanceof Error ? error.message : error).split(':')[0].slice(0, 120);
    await transaction(async (client) => {
      await client.query(
        `UPDATE privacy_export_artifact
         SET status = 'failed', failure_code = $2, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [artifactId, code],
      );
      await client.query(
        `UPDATE privacy_request
         SET status = 'failed', failed_at = CURRENT_TIMESTAMP, failure_code = $2,
             last_user_visible_message = 'We could not prepare your export yet. The privacy team can retry it.',
             updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status = 'processing'`,
        [claimed.privacy_request_id, code],
      );
    });
    throw error;
  }
};

const createExportDownloadGrant = async (
  executor: QueryExecutor,
  {
    requestId,
    userId,
    sessionId,
  }: { requestId: string; userId: string; sessionId: string },
): Promise<{ artifactId: string; token: string; expiresAt: string }> => {
  const artifact = await executor.query<{ id: string }>(
    `SELECT artifact.id
     FROM privacy_export_artifact artifact
     JOIN privacy_request request ON request.id = artifact.privacy_request_id
     WHERE request.id = $1 AND request.user_id = $2
       AND request.status = 'completed' AND artifact.status = 'ready'
       AND artifact.expires_at > CURRENT_TIMESTAMP`,
    [requestId, userId],
  );
  if (!artifact.rows[0]) {
    throw new Error('PRIVACY_EXPORT_NOT_AVAILABLE');
  }
  const token = randomBytes(32).toString('base64url');
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
  await executor.query(
    `INSERT INTO privacy_export_download_grant
       (artifact_id, user_id, session_id, token_hash, expires_at)
     VALUES ($1, $2, $3, $4, $5)`,
    [artifact.rows[0].id, userId, sessionId, sha256(token), expiresAt],
  );
  return { artifactId: artifact.rows[0].id, token, expiresAt: expiresAt.toISOString() };
};

const consumeExportDownloadGrant = async (
  {
    artifactId,
    userId,
    sessionId,
    token,
  }: { artifactId: string; userId: string; sessionId: string; token: string },
): Promise<{
  stream: Readable;
  filename: string;
  expectedSha256: string;
  contentType: string;
}> => {
  const artifact = await transaction(async (client) => {
    const grant = await client.query<PrivacyExportArtifactRow>(
      `UPDATE privacy_export_download_grant AS download_grant
       SET used_at = CURRENT_TIMESTAMP
       FROM privacy_export_artifact artifact
       WHERE download_grant.artifact_id = $1
         AND download_grant.user_id = $2
         AND download_grant.session_id = $3
         AND download_grant.token_hash = $4
         AND download_grant.used_at IS NULL
         AND download_grant.expires_at > CURRENT_TIMESTAMP
         AND artifact.id = download_grant.artifact_id
         AND artifact.user_id = download_grant.user_id
         AND artifact.status = 'ready' AND artifact.expires_at > CURRENT_TIMESTAMP
       RETURNING artifact.*`,
      [artifactId, userId, sessionId, sha256(token)],
    );
    return grant.rows[0] ?? null;
  });
  if (
    !artifact?.encrypted_file_path ||
    !artifact.encryption_iv ||
    !artifact.encryption_auth_tag ||
    !artifact.plaintext_sha256
  ) {
    throw new Error('PRIVACY_EXPORT_DOWNLOAD_GRANT_INVALID');
  }
  const filePath = assertSafeArtifactPath(artifact.encrypted_file_path);
  await fsPromises.access(filePath, fs.constants.R_OK);
  const { key, keyId } = configuredEncryptionKey();
  if (artifact.encryption_key_id !== keyId) {
    throw new Error('PRIVACY_EXPORT_ENCRYPTION_KEY_UNAVAILABLE');
  }
  const decipher = createDecipheriv('aes-256-gcm', key, artifact.encryption_iv);
  decipher.setAuthTag(artifact.encryption_auth_tag);
  const verifiedStream = fs
    .createReadStream(filePath)
    .pipe(decipher)
    .pipe(new Sha256VerificationTransform(artifact.plaintext_sha256));
  return {
    stream: verifiedStream,
    filename: `terraleb-personal-data-${artifact.privacy_request_id}.${artifact.content_type.startsWith('text/html') ? 'html' : 'json'}`,
    expectedSha256: artifact.plaintext_sha256,
    contentType: artifact.content_type,
  };
};

const deleteExpiredPrivacyExportArtifacts = async (): Promise<number> => {
  const expired = await query<{ id: string; encrypted_file_path: string | null }>(
    `SELECT id, encrypted_file_path
     FROM privacy_export_artifact
     WHERE status = 'ready' AND expires_at <= CURRENT_TIMESTAMP
     ORDER BY expires_at
     LIMIT 200`,
  );
  let deleted = 0;
  for (const artifact of expired.rows) {
    if (artifact.encrypted_file_path) {
      const safePath = assertSafeArtifactPath(artifact.encrypted_file_path);
      await fsPromises.unlink(safePath).catch((error: NodeJS.ErrnoException) => {
        if (error.code !== 'ENOENT') {
          throw error;
        }
      });
    }
    const result = await query(
      `UPDATE privacy_export_artifact
       SET status = 'expired', deleted_at = CURRENT_TIMESTAMP,
           encrypted_file_path = NULL, encryption_iv = NULL,
           encryption_auth_tag = NULL, updated_at = CURRENT_TIMESTAMP
       WHERE id = $1 AND status = 'ready'`,
      [artifact.id],
    );
    deleted += result.rowCount ?? 0;
  }
  await query(
    `DELETE FROM privacy_export_download_grant
     WHERE expires_at < CURRENT_TIMESTAMP OR used_at < CURRENT_TIMESTAMP - INTERVAL '1 day'`,
  );
  return deleted;
};

export {
  buildPersonalDataPayload,
  consumeExportDownloadGrant,
  createExportDownloadGrant,
  deleteExpiredPrivacyExportArtifacts,
  processPersonalDataExport,
  renderPersonalDataHtml,
  schedulePersonalDataExport,
};
