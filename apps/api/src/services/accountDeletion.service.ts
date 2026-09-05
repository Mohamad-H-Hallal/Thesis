import type { PoolClient, QueryResult, QueryResultRow } from 'pg';
import { query, transaction } from '../config/database';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import { buildMaskedContributorLabel } from './privacyIdentity.service';
import { storageAdapter } from './storageAdapter.service';
import { enqueueWorkloadJob } from './workloadQueue.service';

interface QueryExecutor {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: unknown[],
  ): Promise<QueryResult<T>>;
}

interface AccountDeletionBlocker {
  code: string;
  count: number;
  message: string;
}

interface AccountDeletionEligibility {
  can_request: boolean;
  operationally_eligible: boolean;
  protected_account: boolean;
  role: string;
  blockers: AccountDeletionBlocker[];
  counts: Record<string, number>;
  manual_review_required: true;
}

type UnfinishedWorkDecision = 'require_resolution' | 'discard_unapproved';
type ResponsibilityDecision = 'release' | 'confirmed_transferred';

interface AccountDeletionDecision {
  unfinishedWorkDecision: UnfinishedWorkDecision;
  responsibilityDecision: ResponsibilityDecision;
}

interface DeletionUserRow {
  id: string;
  email: string | null;
  full_name: string | null;
  phone: string | null;
  phone_e164: string | null;
  role: string;
  account_status: string;
  is_active: boolean;
}

const blockerDefinitions: Array<{
  key: string;
  code: string;
  message: string;
}> = [
  {
    key: 'assignment_count',
    code: 'ACTIVE_PROJECT_ASSIGNMENTS',
    message: 'Project assignments and pending assignment requests must be resolved first.',
  },
  {
    key: 'pending_contribution_count',
    code: 'PENDING_CONTRIBUTION_REVIEWS',
    message: 'Draft, submitted, or rejected contributions must be resolved first.',
  },
  {
    key: 'unresolved_import_count',
    code: 'UNRESOLVED_IMPORTS',
    message: 'Your active imports must finish before deletion.',
  },
  {
    key: 'unresolved_export_count',
    code: 'UNRESOLVED_EXPORTS',
    message: 'Your active exports must finish first.',
  },
  {
    key: 'active_ai_run_count',
    code: 'ACTIVE_AI_RUNS',
    message: 'Your active AI runs must finish before deletion.',
  },
  {
    key: 'active_ai_task_count',
    code: 'ACTIVE_AI_RESPONSIBILITIES',
    message: 'Your assigned AI validation work must be completed or unassigned first.',
  },
  {
    key: 'assigned_case_count',
    code: 'ASSIGNED_PRIVACY_OR_MODERATION_CASES',
    message: 'Assigned privacy and moderation cases must be resolved or reassigned first.',
  },
  {
    key: 'active_project_owner_count',
    code: 'ACTIVE_PROJECT_OWNERSHIP',
    message: 'Active project attribution must be reviewed before deletion.',
  },
  {
    key: 'active_legal_hold_count',
    code: 'ACTIVE_LEGAL_OR_SECURITY_HOLD',
    message: 'A protected retention hold requires privacy-team review before deletion.',
  },
];

const assertAccountDeletionPolicyConfigured = (): void => {
  if (process.env.NODE_ENV !== 'production') {
    return;
  }
  const executionEnabled =
    String(process.env.ACCOUNT_DELETION_EXECUTION_ENABLED ?? '')
      .trim()
      .toLowerCase() === 'true';
  const requiredReferences = [
    process.env.ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE,
    process.env.ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE,
    process.env.MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE,
    process.env.RETAINED_GIS_RECORDS_APPROVAL_REFERENCE,
    process.env.ACCEPTED_MEDIA_LOCATION_APPROVAL_REFERENCE,
    process.env.FREE_TEXT_TREATMENT_APPROVAL_REFERENCE,
    process.env.BACKUP_AGEING_APPROVAL_REFERENCE,
  ];
  if (!executionEnabled || requiredReferences.some((value) => !String(value ?? '').trim())) {
    throw new Error('ACCOUNT_DELETION_POLICY_APPROVAL_REQUIRED');
  }
};

const getAccountDeletionEligibility = async (
  user: { id: string; email?: string | null; role: string },
  executor: QueryExecutor = { query },
  requestDetails?: Record<string, unknown>,
): Promise<AccountDeletionEligibility> => {
  const protectedAccount = isProtectedSuperAdminEmail(user.email);
  const countsResult = await executor.query<Record<string, number | string>>(
    `SELECT
       (SELECT COUNT(*)::INT FROM project_assignment
        WHERE user_id = $1 AND status IN ('pending', 'approved')) AS assignment_count,
       (SELECT COUNT(*)::INT FROM spatial_feature
        WHERE collected_by_user_id = $1 AND status <> 'approved') AS pending_contribution_count,
       (SELECT COUNT(*)::INT FROM spatial_feature
        WHERE collected_by_user_id = $1 AND status = 'approved') AS accepted_contribution_count,
       (SELECT COUNT(*)::INT FROM gis_import_job
        WHERE uploaded_by_user_id = $1 AND status NOT IN ('approved', 'partially_approved')) AS unresolved_import_count,
       (SELECT COUNT(*)::INT FROM shapefile_export
        WHERE requested_by_user_id = $1 AND status <> 'completed') AS unresolved_export_count,
       (SELECT COUNT(*)::INT FROM ai_run
        WHERE started_by = $1 AND status <> 'published') AS active_ai_run_count,
       (SELECT COUNT(*)::INT FROM ai_prediction_validation_task
        WHERE assigned_to = $1 AND status IN ('open', 'assigned', 'in_progress', 'submitted'))
         +
       (SELECT COUNT(*)::INT FROM ai_uncertainty_area
        WHERE assigned_to = $1 AND status IN ('open', 'assigned', 'in_review')) AS active_ai_task_count,
       (SELECT COUNT(*)::INT FROM privacy_request
        WHERE assigned_to_user_id = $1 AND status NOT IN ('completed', 'cancelled', 'rejected'))
         +
       (SELECT COUNT(*)::INT FROM content_report
        WHERE assigned_to_user_id = $1 AND status NOT IN ('resolved', 'dismissed'))
         AS assigned_case_count,
       (SELECT COUNT(*)::INT FROM project
        WHERE created_by_user_id = $1 AND status <> 'archived') AS active_project_owner_count,
       (SELECT COUNT(*)::INT FROM data_retention_hold
        WHERE released_at IS NULL AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
          AND record_table = 'user' AND record_id = $1::TEXT) AS active_legal_hold_count`,
    [user.id],
  );
  const counts = countsResult.rows[0] ?? {};
  const numericCounts = Object.fromEntries(
    Object.entries(counts).map(([key, value]) => [key, Number(value ?? 0)]),
  );
  let blockers = blockerDefinitions.flatMap((definition) => {
    const count = Number(counts[definition.key] ?? 0);
    return count > 0 ? [{ code: definition.code, count, message: definition.message }] : [];
  });
  if (user.role === 'contributor' && requestDetails?.offline_data_resolved !== true) {
    blockers.push({
      code: 'OFFLINE_DATA_CONFIRMATION_REQUIRED',
      count: 1,
      message: 'Synchronize or remove private offline drafts on every device before deletion.',
    });
  }
  return {
    can_request: !protectedAccount,
    operationally_eligible: !protectedAccount && blockers.length === 0,
    protected_account: protectedAccount,
    role: user.role,
    blockers,
    counts: numericCounts,
    manual_review_required: true,
  };
};

const remainingBlockersForDecision = (
  eligibility: AccountDeletionEligibility,
  decision: AccountDeletionDecision,
): AccountDeletionBlocker[] => {
  const discardable = new Set([
    'ACTIVE_PROJECT_ASSIGNMENTS',
    'PENDING_CONTRIBUTION_REVIEWS',
    'UNRESOLVED_IMPORTS',
    'UNRESOLVED_EXPORTS',
    'ACTIVE_AI_RUNS',
  ]);
  const releasable = new Set([
    'ACTIVE_PROJECT_ASSIGNMENTS',
    'ACTIVE_AI_RESPONSIBILITIES',
    'ASSIGNED_PRIVACY_OR_MODERATION_CASES',
  ]);
  return eligibility.blockers.filter((blocker) => {
    if (blocker.code === 'ACTIVE_PROJECT_OWNERSHIP') {
      return false;
    }
    if (
      decision.unfinishedWorkDecision === 'discard_unapproved' &&
      discardable.has(blocker.code)
    ) {
      return false;
    }
    if (decision.responsibilityDecision === 'release' && releasable.has(blocker.code)) {
      return false;
    }
    return true;
  });
};

const scheduleAccountDeletion = async (
  executor: PoolClient,
  {
    requestId,
    userId,
    unfinishedWorkDecision,
    responsibilityDecision,
  }: { requestId: string; userId: string } & AccountDeletionDecision,
): Promise<string> => {
  assertAccountDeletionPolicyConfigured();
  const execution = await executor.query<{ id: string }>(
    `INSERT INTO account_deletion_execution
       (privacy_request_id, user_id, status, unfinished_work_decision, responsibility_decision)
     VALUES ($1, $2, 'scheduled', $3, $4)
     ON CONFLICT (privacy_request_id) DO UPDATE
       SET status = CASE
             WHEN account_deletion_execution.status = 'failed' THEN 'scheduled'
             ELSE account_deletion_execution.status
           END,
           failure_code = CASE
             WHEN account_deletion_execution.status = 'failed' THEN NULL
             ELSE account_deletion_execution.failure_code
           END,
           unfinished_work_decision = EXCLUDED.unfinished_work_decision,
           responsibility_decision = EXCLUDED.responsibility_decision,
           updated_at = CURRENT_TIMESTAMP
     RETURNING id`,
    [requestId, userId, unfinishedWorkDecision, responsibilityDecision],
  );
  await enqueueWorkloadJob(executor, {
    kind: 'account_deletion',
    entityId: execution.rows[0].id,
    maxAttempts: Number.parseInt(process.env.WORKLOAD_MAX_ATTEMPTS ?? '3', 10),
  });
  return execution.rows[0].id;
};

const releaseOperationalResponsibilities = async (
  client: PoolClient,
  userId: string,
): Promise<void> => {
  await client.query(`DELETE FROM project_assignment WHERE user_id = $1`, [userId]);
  await client.query(
    `UPDATE privacy_request SET assigned_to_user_id = NULL, updated_at = CURRENT_TIMESTAMP
     WHERE assigned_to_user_id = $1 AND status NOT IN ('completed', 'cancelled', 'rejected')`,
    [userId],
  );
  await client.query(
    `UPDATE content_report SET assigned_to_user_id = NULL, updated_at = CURRENT_TIMESTAMP
     WHERE assigned_to_user_id = $1 AND status NOT IN ('resolved', 'dismissed')`,
    [userId],
  );
  await client.query(
    `UPDATE ai_prediction_validation_task SET assigned_to = NULL, updated_at = CURRENT_TIMESTAMP
     WHERE assigned_to = $1 AND status IN ('open', 'assigned', 'in_progress', 'submitted')`,
    [userId],
  );
  await client.query(
    `UPDATE ai_uncertainty_area SET assigned_to = NULL, updated_at = CURRENT_TIMESTAMP
     WHERE assigned_to = $1 AND status IN ('open', 'assigned', 'in_review')`,
    [userId],
  );
};

const collectStorageReferences = (value: unknown, references: Set<string>): void => {
  if (typeof value === 'string') {
    if (storageAdapter.resolve(value)) {
      references.add(value);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item) => collectStorageReferences(item, references));
    return;
  }
  if (value && typeof value === 'object') {
    Object.values(value as Record<string, unknown>).forEach((item) =>
      collectStorageReferences(item, references),
    );
  }
};

const queueUnapprovedArtifactCleanup = async (
  client: PoolClient,
  executionId: string,
  userId: string,
): Promise<number> => {
  const rows = await client.query<{ storage_reference: string | null }>(
    `SELECT photo.file_path AS storage_reference
       FROM photo
       JOIN spatial_feature feature ON feature.id = photo.feature_id
      WHERE feature.collected_by_user_id = $1 AND feature.status <> 'approved'
     UNION
     SELECT photo.thumbnail_path
       FROM photo
       JOIN spatial_feature feature ON feature.id = photo.feature_id
      WHERE feature.collected_by_user_id = $1 AND feature.status <> 'approved'
     UNION
     SELECT job.file_path FROM gis_import_job job
      WHERE job.uploaded_by_user_id = $1
        AND job.status IN ('uploaded', 'processing', 'pending_review', 'rejected', 'failed')
     UNION
     SELECT export.file_path FROM shapefile_export export
      WHERE export.requested_by_user_id = $1 AND export.status <> 'completed'
     UNION
     SELECT layer.storage_path
       FROM ai_output_layer layer
       JOIN ai_run run ON run.id = layer.ai_run_id
      WHERE run.started_by = $1 AND run.status <> 'published'
     UNION
     SELECT quarantine.storage_path FROM upload_quarantine_record quarantine
      WHERE quarantine.uploaded_by_user_id = $1 AND quarantine.disposition = 'quarantined'
     UNION
     SELECT artifact.encrypted_file_path FROM privacy_export_artifact artifact
      WHERE artifact.user_id = $1 AND artifact.encrypted_file_path IS NOT NULL
     UNION
     SELECT account.profile_picture_url FROM "user" account WHERE account.id = $1`,
    [userId],
  );
  const references = new Set<string>();
  rows.rows.forEach((row) => {
    const reference = row.storage_reference?.trim();
    if (reference && storageAdapter.resolve(reference)) references.add(reference);
  });
  const aiArtifacts = await client.query<{ artifacts: unknown; metadata: unknown }>(
    `SELECT artifacts, metadata FROM ai_run
      WHERE started_by = $1 AND status <> 'published'`,
    [userId],
  );
  aiArtifacts.rows.forEach((row) => {
    collectStorageReferences(row.artifacts, references);
    collectStorageReferences(row.metadata, references);
  });
  if (references.size === 0) {
    return 0;
  }
  await client.query(
    `INSERT INTO account_deletion_artifact_cleanup (execution_id, storage_reference)
     SELECT $1, reference FROM UNNEST($2::TEXT[]) AS reference
     ON CONFLICT (execution_id, storage_reference) DO NOTHING`,
    [executionId, [...references]],
  );
  return references.size;
};

const discardUnapprovedWork = async (
  client: PoolClient,
  userId: string,
): Promise<Record<string, number>> => {
  await client.query(
    `UPDATE workload_job
        SET status = 'succeeded', completed_at = COALESCE(completed_at, CURRENT_TIMESTAMP),
            lease_expires_at = NULL, worker_id = NULL,
            last_error = 'Cancelled by approved account deletion.'
      WHERE status IN ('queued', 'running')
        AND (
          (kind = 'gis_import' AND entity_id IN (
            SELECT id FROM gis_import_job WHERE uploaded_by_user_id = $1
              AND status IN ('uploaded', 'processing', 'pending_review', 'rejected', 'failed')
          ))
          OR (kind = 'project_export' AND entity_id IN (
            SELECT id FROM shapefile_export WHERE requested_by_user_id = $1
              AND status <> 'completed'
          ))
        )`,
    [userId],
  );
  const assignments = await client.query(`DELETE FROM project_assignment WHERE user_id = $1`, [
    userId,
  ]);
  const features = await client.query(
    `DELETE FROM spatial_feature WHERE collected_by_user_id = $1 AND status <> 'approved'`,
    [userId],
  );
  const imports = await client.query(
    `DELETE FROM gis_import_job WHERE uploaded_by_user_id = $1
       AND status IN ('uploaded', 'processing', 'pending_review', 'rejected', 'failed')`,
    [userId],
  );
  const exports = await client.query(
    `DELETE FROM shapefile_export WHERE requested_by_user_id = $1 AND status <> 'completed'`,
    [userId],
  );
  const aiRuns = await client.query(
    `DELETE FROM ai_run WHERE started_by = $1 AND status <> 'published'`,
    [userId],
  );
  const quarantine = await client.query(
    `DELETE FROM upload_quarantine_record
      WHERE uploaded_by_user_id = $1 AND disposition = 'quarantined'`,
    [userId],
  );
  return {
    project_assignments: assignments.rowCount ?? 0,
    unapproved_features: features.rowCount ?? 0,
    unfinished_imports: imports.rowCount ?? 0,
    unfinished_exports: exports.rowCount ?? 0,
    unpublished_ai_runs: aiRuns.rowCount ?? 0,
    quarantined_uploads: quarantine.rowCount ?? 0,
  };
};

const removeQueuedDeletionArtifacts = async (executionId: string): Promise<void> => {
  const pending = await query<{ id: string; storage_reference: string }>(
    `SELECT id, storage_reference FROM account_deletion_artifact_cleanup
      WHERE execution_id = $1 AND status <> 'deleted'
      ORDER BY created_at, id`,
    [executionId],
  );
  for (const artifact of pending.rows) {
    try {
      await storageAdapter.remove(artifact.storage_reference).catch((error: unknown) => {
        if ((error as NodeJS.ErrnoException)?.code !== 'ENOENT') throw error;
      });
      await query(
        `UPDATE account_deletion_artifact_cleanup
            SET status = 'deleted', attempt_count = attempt_count + 1,
                last_error_code = NULL, deleted_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [artifact.id],
      );
    } catch (error) {
      const code = String((error as { name?: string; code?: string })?.code ??
        (error as { name?: string })?.name ?? 'STORAGE_DELETE_FAILED').slice(0, 120);
      await query(
        `UPDATE account_deletion_artifact_cleanup
            SET status = 'failed', attempt_count = attempt_count + 1,
                last_error_code = $2, deleted_at = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [artifact.id, code],
      );
      throw new Error('ACCOUNT_DELETION_ARTIFACT_CLEANUP_FAILED');
    }
  }
};

const scheduleFreeTextReview = async (
  client: PoolClient,
  {
    requestId,
    fullName,
    email,
    phone,
  }: {
    requestId: string;
    fullName: string;
    email: string | null;
    phone: string | null;
  },
): Promise<void> => {
  const identifiers = [
    { code: 'possible_name', value: fullName },
    { code: 'possible_email', value: email },
    { code: 'possible_phone', value: phone },
  ].filter((entry) => entry.value && entry.value.trim().length >= 3) as Array<{
    code: string;
    value: string;
  }>;
  for (const identifier of identifiers) {
    await client.query(
      `INSERT INTO privacy_free_text_review_task
         (privacy_request_id, record_table, record_id, reason_code)
       SELECT $1, 'gis_import_comment', comment.id, $2
       FROM gis_import_comment comment
       WHERE comment.comment_text ILIKE ('%' || $3 || '%')
       ON CONFLICT DO NOTHING`,
      [requestId, identifier.code, identifier.value],
    );
    await client.query(
      `INSERT INTO privacy_free_text_review_task
         (privacy_request_id, record_table, record_id, reason_code)
       SELECT $1, 'spatial_feature', feature.id, $2
       FROM spatial_feature feature
       WHERE feature.review_notes ILIKE ('%' || $3 || '%')
       ON CONFLICT DO NOTHING`,
      [requestId, identifier.code, identifier.value],
    );
    await client.query(
      `INSERT INTO privacy_free_text_review_task
         (privacy_request_id, record_table, record_id, reason_code)
       SELECT $1, 'content_report', report.id, $2
       FROM content_report report
       WHERE report.description ILIKE ('%' || $3 || '%')
          OR report.internal_resolution_notes ILIKE ('%' || $3 || '%')
          OR report.resolution_summary ILIKE ('%' || $3 || '%')
       ON CONFLICT DO NOTHING`,
      [requestId, identifier.code, identifier.value],
    );
    await client.query(
      `INSERT INTO privacy_free_text_review_task
         (privacy_request_id, record_table, record_id, reason_code)
       SELECT $1, 'ai_prediction_validation_submission', submission.id, $2
       FROM ai_prediction_validation_submission submission
       WHERE submission.note ILIKE ('%' || $3 || '%')
       ON CONFLICT DO NOTHING`,
      [requestId, identifier.code, identifier.value],
    );
  }
};

interface IdentityScrubValues {
  fullName: string;
  email: string | null;
  phone: string | null;
}

const escapeRegExp = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const scrubIdentityText = (
  value: string,
  maskedLabel: string,
  identifiers: IdentityScrubValues,
): string => {
  let scrubbed = value;
  for (const contact of [identifiers.email, identifiers.phone]) {
    if (contact?.trim()) {
      scrubbed = scrubbed.replace(new RegExp(escapeRegExp(contact.trim()), 'giu'), '[removed]');
    }
  }
  if (identifiers.fullName.trim()) {
    scrubbed = scrubbed.replace(
      new RegExp(escapeRegExp(identifiers.fullName.trim()), 'giu'),
      maskedLabel,
    );
  }
  return scrubbed;
};

const scrubStructuredValue = (
  value: unknown,
  maskedLabel: string,
  identifiers: IdentityScrubValues,
): unknown => {
  if (typeof value === 'string') {
    return scrubIdentityText(value, maskedLabel, identifiers);
  }
  if (Array.isArray(value)) {
    return value.map((item) => scrubStructuredValue(item, maskedLabel, identifiers));
  }
  if (!value || typeof value !== 'object') {
    return value;
  }
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).map(([key, nested]) => {
      const normalizedKey = key.toLowerCase();
      if (/(?:^|_)(?:email|phone)(?:_|$)/.test(normalizedKey)) {
        return [key, null];
      }
      if (/(?:^|_)(?:full_name|user_name|display_name)(?:_|$)/.test(normalizedKey)) {
        return [key, maskedLabel];
      }
      return [key, scrubStructuredValue(nested, maskedLabel, identifiers)];
    }),
  );
};

const scrubStructuredIdentity = async (
  client: PoolClient,
  userId: string,
  maskedLabel: string,
  identifiers: IdentityScrubValues,
): Promise<void> => {
  const needles = [identifiers.fullName, identifiers.email, identifiers.phone]
    .filter((value): value is string => Boolean(value?.trim()))
    .map((value) => value.trim());
  const auditRows = await client.query<{
    id: string;
    old_values: unknown;
    new_values: unknown;
  }>(
    `SELECT id, old_values, new_values
     FROM audit_log
     WHERE (entity_type = 'user' AND entity_id = $1)
        OR EXISTS (
          SELECT 1 FROM UNNEST($2::TEXT[]) AS identifier(value)
          WHERE POSITION(LOWER(identifier.value) IN LOWER(
            COALESCE(old_values::TEXT, '') || ' ' || COALESCE(new_values::TEXT, '')
          )) > 0
        )
     FOR UPDATE`,
    [userId, needles],
  );
  for (const row of auditRows.rows) {
    await client.query(
      `UPDATE audit_log SET old_values = $2::JSONB, new_values = $3::JSONB WHERE id = $1`,
      [
        row.id,
        row.old_values == null
          ? null
          : JSON.stringify(scrubStructuredValue(row.old_values, maskedLabel, identifiers)),
        row.new_values == null
          ? null
          : JSON.stringify(scrubStructuredValue(row.new_values, maskedLabel, identifiers)),
      ],
    );
  }

  const requestRows = await client.query<{ id: string; request_details: unknown }>(
    `SELECT id, request_details FROM privacy_request WHERE user_id = $1 FOR UPDATE`,
    [userId],
  );
  for (const row of requestRows.rows) {
    await client.query(`UPDATE privacy_request SET request_details = $2::JSONB WHERE id = $1`, [
      row.id,
      JSON.stringify(scrubStructuredValue(row.request_details, maskedLabel, identifiers)),
    ]);
  }

  const notificationRows = await client.query<{
    id: string;
    title: string;
    message: string;
    metadata: unknown;
  }>(
    `SELECT id, title, message, metadata
     FROM notification
     WHERE metadata @> jsonb_build_object('user_id', $1::TEXT)
        OR EXISTS (
          SELECT 1 FROM UNNEST($2::TEXT[]) AS identifier(value)
          WHERE POSITION(LOWER(identifier.value) IN LOWER(title || ' ' || message || ' ' ||
            COALESCE(metadata::TEXT, ''))) > 0
        )
     FOR UPDATE`,
    [userId, needles],
  );
  for (const row of notificationRows.rows) {
    await client.query(
      `UPDATE notification SET title = $2, message = $3, metadata = $4::JSONB WHERE id = $1`,
      [
        row.id,
        scrubIdentityText(row.title, maskedLabel, identifiers),
        scrubIdentityText(row.message, maskedLabel, identifiers),
        row.metadata == null
          ? null
          : JSON.stringify(scrubStructuredValue(row.metadata, maskedLabel, identifiers)),
      ],
    );
  }

  const featureRows = await client.query<{
    id: string;
    attributes: unknown;
    source_provenance: unknown;
    contributor_validation_summary: unknown;
  }>(
    `SELECT id, attributes, source_provenance, contributor_validation_summary
       FROM spatial_feature
      WHERE collected_by_user_id = $1 AND status = 'approved'
      FOR UPDATE`,
    [userId],
  );
  for (const row of featureRows.rows) {
    await client.query(
      `UPDATE spatial_feature
          SET attributes = $2::JSONB, source_provenance = $3::JSONB,
              contributor_validation_summary = $4::JSONB
        WHERE id = $1`,
      [
        row.id,
        JSON.stringify(scrubStructuredValue(row.attributes, maskedLabel, identifiers)),
        JSON.stringify(scrubStructuredValue(row.source_provenance, maskedLabel, identifiers)),
        JSON.stringify(
          scrubStructuredValue(row.contributor_validation_summary, maskedLabel, identifiers),
        ),
      ],
    );
  }

  const photoRows = await client.query<{ id: string; exif_data: unknown }>(
    `SELECT photo.id, photo.exif_data
       FROM photo
       JOIN spatial_feature feature ON feature.id = photo.feature_id
      WHERE feature.collected_by_user_id = $1 AND feature.status = 'approved'
      FOR UPDATE OF photo`,
    [userId],
  );
  for (const row of photoRows.rows) {
    await client.query(`UPDATE photo SET exif_data = $2::JSONB WHERE id = $1`, [
      row.id,
      row.exif_data == null
        ? null
        : JSON.stringify(scrubStructuredValue(row.exif_data, maskedLabel, identifiers)),
    ]);
  }

  const importRows = await client.query<{
    id: string;
    original_filename: string;
    file_metadata: unknown;
    validation_summary: unknown;
  }>(
    `SELECT id, original_filename, file_metadata, validation_summary
       FROM gis_import_job
      WHERE uploaded_by_user_id = $1
      FOR UPDATE`,
    [userId],
  );
  for (const row of importRows.rows) {
    await client.query(
      `UPDATE gis_import_job
          SET original_filename = $2, file_metadata = $3::JSONB,
              validation_summary = $4::JSONB
        WHERE id = $1`,
      [
        row.id,
        scrubIdentityText(row.original_filename, maskedLabel, identifiers),
        JSON.stringify(scrubStructuredValue(row.file_metadata, maskedLabel, identifiers)),
        JSON.stringify(scrubStructuredValue(row.validation_summary, maskedLabel, identifiers)),
      ],
    );
  }

  const exportRows = await client.query<{ id: string; export_parameters: unknown }>(
    `SELECT id, export_parameters FROM shapefile_export
      WHERE requested_by_user_id = $1 FOR UPDATE`,
    [userId],
  );
  for (const row of exportRows.rows) {
    await client.query(`UPDATE shapefile_export SET export_parameters = $2::JSONB WHERE id = $1`, [
      row.id,
      JSON.stringify(scrubStructuredValue(row.export_parameters, maskedLabel, identifiers)),
    ]);
  }

  const aiRows = await client.query<{ id: string; metadata: unknown; artifacts: unknown }>(
    `SELECT id, metadata, artifacts FROM ai_run WHERE started_by = $1 FOR UPDATE`,
    [userId],
  );
  for (const row of aiRows.rows) {
    await client.query(
      `UPDATE ai_run SET metadata = $2::JSONB, artifacts = $3::JSONB WHERE id = $1`,
      [
        row.id,
        JSON.stringify(scrubStructuredValue(row.metadata, maskedLabel, identifiers)),
        JSON.stringify(scrubStructuredValue(row.artifacts, maskedLabel, identifiers)),
      ],
    );
  }

  const quarantineRows = await client.query<{
    id: string;
    original_filename: string;
    metadata: unknown;
  }>(
    `SELECT id, original_filename, metadata FROM upload_quarantine_record
      WHERE uploaded_by_user_id = $1 FOR UPDATE`,
    [userId],
  );
  for (const row of quarantineRows.rows) {
    await client.query(
      `UPDATE upload_quarantine_record
          SET original_filename = $2, metadata = $3::JSONB
        WHERE id = $1`,
      [
        row.id,
        scrubIdentityText(row.original_filename, maskedLabel, identifiers),
        JSON.stringify(scrubStructuredValue(row.metadata, maskedLabel, identifiers)),
      ],
    );
  }
};

const processAccountDeletion = async (executionId: string): Promise<void> => {
  try {
    assertAccountDeletionPolicyConfigured();
    const coreState = await transaction(async (client) => {
      const result = await client.query<
        {
          execution_id: string;
          execution_status: string;
          privacy_request_id: string;
          user_id: string;
          request_details: Record<string, unknown>;
          unfinished_work_decision: UnfinishedWorkDecision;
          responsibility_decision: ResponsibilityDecision;
          masked_contributor_label: string | null;
        } & DeletionUserRow
      >(
        `SELECT execution.id AS execution_id, execution.status AS execution_status,
                execution.privacy_request_id, execution.user_id,
                execution.unfinished_work_decision, execution.responsibility_decision,
                execution.masked_contributor_label, request.request_details,
                account.id, account.email, account.full_name, account.phone,
                account.phone_e164, account.role, account.account_status, account.is_active
         FROM account_deletion_execution execution
         JOIN privacy_request request ON request.id = execution.privacy_request_id
         JOIN "user" account ON account.id = execution.user_id
         WHERE execution.id = $1
         FOR UPDATE OF execution, request, account`,
        [executionId],
      );
      const row = result.rows[0];
      if (!row || row.execution_status === 'completed') return 'completed' as const;
      if (row.account_status === 'deleted') return 'cleanup' as const;
      if (isProtectedSuperAdminEmail(row.email)) {
        throw new Error('PROTECTED_ACCOUNT_DELETION_FORBIDDEN');
      }
      if (!row.full_name) throw new Error('ACCOUNT_DELETION_IDENTITY_UNAVAILABLE');

      await client.query(
        `UPDATE account_deletion_execution
            SET status = 'processing', attempt_count = attempt_count + 1,
                failure_code = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [executionId],
      );
      await client.query(
        `UPDATE privacy_request
            SET status = 'processing', execution_started_at = COALESCE(execution_started_at, CURRENT_TIMESTAMP),
                failed_at = NULL, failure_code = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [row.privacy_request_id],
      );

      const decision: AccountDeletionDecision = {
        unfinishedWorkDecision: row.unfinished_work_decision,
        responsibilityDecision: row.responsibility_decision,
      };
      const eligibility = await getAccountDeletionEligibility(
        { id: row.user_id, email: row.email, role: row.role },
        client,
        row.request_details,
      );
      const remainingBlockers = remainingBlockersForDecision(eligibility, decision);
      if (remainingBlockers.length > 0) {
        throw new Error(`ACCOUNT_DELETION_INELIGIBLE:${remainingBlockers[0].code}`);
      }
      await client.query(
        `UPDATE account_deletion_execution SET eligibility_checked_at = CURRENT_TIMESTAMP WHERE id = $1`,
        [executionId],
      );

      if (decision.responsibilityDecision === 'release') {
        await releaseOperationalResponsibilities(client, row.user_id);
      }
      const artifactCount = await queueUnapprovedArtifactCleanup(client, executionId, row.user_id);
      const discardCounts =
        decision.unfinishedWorkDecision === 'discard_unapproved'
          ? await discardUnapprovedWork(client, row.user_id)
          : {};
      await client.query(
        `UPDATE account_deletion_execution
            SET responsibilities_released_at = CURRENT_TIMESTAMP,
                discard_counts = $2::JSONB,
                discard_completed_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [executionId, JSON.stringify({ ...discardCounts, storage_artifacts: artifactCount })],
      );

      const maskedLabel = buildMaskedContributorLabel(row.full_name);
      await scheduleFreeTextReview(client, {
        requestId: row.privacy_request_id,
        fullName: row.full_name,
        email: row.email,
        phone: row.phone_e164 ?? row.phone,
      });
      await client.query(
        `UPDATE account_deletion_execution
            SET masked_contributor_label = $2, free_text_review_scheduled_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [executionId, maskedLabel],
      );

      await publishRealtimeChanges(
        [
          {
            scopeType: 'user', scopeId: row.user_id, action: 'session_revoked',
            entityType: 'user', entityId: row.user_id,
            audience: { kind: 'user', userId: row.user_id },
          },
          {
            scopeType: 'privacy_admin_queue', scopeId: 'all', action: 'deletion_processing',
            entityType: 'privacy_request', entityId: row.privacy_request_id,
            audience: { kind: 'protected_admins' },
          },
        ],
        client,
      );
      await client.query(
        `UPDATE auth_session
            SET revoked_at = COALESCE(revoked_at, CURRENT_TIMESTAMP),
                revocation_reason = COALESCE(revocation_reason, 'account_deleted')
          WHERE user_id = $1 AND revoked_at IS NULL`,
        [row.user_id],
      );
      await client.query(
        `UPDATE account_deletion_execution SET sessions_revoked_at = CURRENT_TIMESTAMP WHERE id = $1`,
        [executionId],
      );
      await client.query(`DELETE FROM push_device_registration WHERE user_id = $1`, [row.user_id]);
      await client.query(`DELETE FROM password_reset_request WHERE user_id = $1`, [row.user_id]);
      await client.query(`DELETE FROM contact_verification_challenge WHERE user_id = $1`, [row.user_id]);
      await client.query(`DELETE FROM contact_verification_audit_event WHERE user_id = $1`, [row.user_id]);
      await client.query(`DELETE FROM notification WHERE user_id = $1`, [row.user_id]);
      await client.query(`DELETE FROM offline_sync_receipt WHERE user_id = $1`, [row.user_id]);
      await client.query(`DELETE FROM privacy_export_download_grant WHERE user_id = $1`, [row.user_id]);
      await client.query(
        `UPDATE privacy_export_artifact
            SET status = 'deleted', encrypted_file_path = NULL, encryption_algorithm = NULL,
                encryption_key_id = NULL, encryption_iv = NULL, encryption_auth_tag = NULL,
                plaintext_sha256 = NULL, encrypted_size_bytes = NULL,
                record_counts = '{}'::JSONB, deleted_at = CURRENT_TIMESTAMP,
                failure_code = NULL, updated_at = CURRENT_TIMESTAMP
          WHERE user_id = $1`,
        [row.user_id],
      );

      await scrubStructuredIdentity(client, row.user_id, maskedLabel, {
        fullName: row.full_name,
        email: row.email,
        phone: row.phone_e164 ?? row.phone,
      });
      await client.query(
        `UPDATE account_deletion_execution
            SET structured_snapshots_scrubbed_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [executionId],
      );
      await client.query(
        `INSERT INTO backup_account_deletion_schedule (privacy_request_id, user_id, status)
         VALUES ($1, $2, 'awaiting_approved_policy')
         ON CONFLICT (privacy_request_id) DO NOTHING`,
        [row.privacy_request_id, row.user_id],
      );
      await client.query(
        `UPDATE account_deletion_execution SET backup_expiry_scheduled_at = CURRENT_TIMESTAMP WHERE id = $1`,
        [executionId],
      );
      await client.query(
        `UPDATE "user"
            SET email = NULL, email_original = NULL, email_canonical = NULL,
                password_hash = NULL, full_name = NULL, phone = NULL, phone_e164 = NULL,
                email_verified_at = NULL, phone_verified_at = NULL,
                phone_format_validated_at = NULL, phone_validation_method = NULL,
                contact_verification_exempted_at = NULL, contact_verification_exempted_by = NULL,
                pending_email_original = NULL, pending_email_canonical = NULL,
                pending_phone_e164 = NULL, verification_required_at = NULL,
                profile_picture_url = NULL, last_login = NULL,
                is_active = FALSE, account_status = 'deleted', auth_version = auth_version + 1,
                permanently_deleted_at = CURRENT_TIMESTAMP, masked_contributor_label = $2,
                deleted_by_privacy_request_id = $3
          WHERE id = $1 AND account_status <> 'deleted'`,
        [row.user_id, maskedLabel, row.privacy_request_id],
      );
      await client.query(
        `UPDATE account_deletion_execution
            SET direct_identifiers_erased_at = CURRENT_TIMESTAMP,
                account_tombstoned_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [executionId],
      );
      await client.query(`DELETE FROM auth_session WHERE user_id = $1`, [row.user_id]);
      return 'cleanup' as const;
    });

    if (coreState === 'completed') return;
    await removeQueuedDeletionArtifacts(executionId);
    await transaction(async (client) => {
      const execution = await client.query<{
        privacy_request_id: string;
        user_id: string;
        masked_contributor_label: string;
        status: string;
      }>(
        `SELECT privacy_request_id, user_id, masked_contributor_label, status
           FROM account_deletion_execution WHERE id = $1 FOR UPDATE`,
        [executionId],
      );
      const row = execution.rows[0];
      if (!row || row.status === 'completed') return;
      const remaining = await client.query<{ count: number }>(
        `SELECT COUNT(*)::INT AS count FROM account_deletion_artifact_cleanup
          WHERE execution_id = $1 AND status <> 'deleted'`,
        [executionId],
      );
      if (Number(remaining.rows[0]?.count ?? 0) > 0) {
        throw new Error('ACCOUNT_DELETION_ARTIFACT_CLEANUP_INCOMPLETE');
      }
      await client.query(
        `UPDATE account_deletion_execution
            SET status = 'completed', artifact_cleanup_completed_at = CURRENT_TIMESTAMP,
                completed_at = CURRENT_TIMESTAMP, failure_code = NULL,
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [executionId],
      );
      await client.query(
        `UPDATE privacy_request
            SET status = 'completed', completed_at = CURRENT_TIMESTAMP,
                resolution_code = 'account_deleted',
                resolution_summary = 'Credentials, direct identifiers, and approved discarded work were erased; accepted institutional GIS records retain only a masked contributor label.',
                last_user_visible_message = 'Your TerraLeb account was deleted.',
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [row.privacy_request_id],
      );
      await client.query(
        `INSERT INTO privacy_request_status_history
           (request_id, from_status, to_status, actor_kind, user_visible_message,
            resolution_code, resolution_summary)
         VALUES ($1, 'processing', 'completed', 'worker',
                 'Your TerraLeb account was deleted.', 'account_deleted',
                 'Mandatory database, storage, session, and backup-scheduling stages completed.')`,
        [row.privacy_request_id],
      );
      await client.query(
        `INSERT INTO audit_log (user_id, action_type, entity_type, entity_id, new_values)
         VALUES (NULL, 'delete', 'user', $1,
                 jsonb_build_object('privacy_request_id', $2::TEXT,
                   'account_state', 'deleted_tombstone',
                   'masked_contributor_label', $3::TEXT,
                   'mandatory_stages_completed', TRUE))`,
        [row.user_id, row.privacy_request_id, row.masked_contributor_label],
      );
      await publishRealtimeChanges(
        [
          {
            scopeType: 'user', scopeId: row.user_id, action: 'account_deletion_completed',
            entityType: 'user', entityId: row.user_id,
            audience: { kind: 'user', userId: row.user_id },
          },
          {
            scopeType: 'privacy_admin_queue', scopeId: 'all', action: 'deletion_completed',
            entityType: 'privacy_request', entityId: row.privacy_request_id,
            audience: { kind: 'protected_admins' },
          },
        ],
        client,
      );
    });
  } catch (error) {
    const code = String(error instanceof Error ? error.message : error)
      .split(':')[0]
      .slice(0, 120);
    await transaction(async (client) => {
      const execution = await client.query<{ privacy_request_id: string; user_id: string }>(
        `UPDATE account_deletion_execution
         SET status = 'failed', failure_code = $2, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status <> 'completed'
          RETURNING privacy_request_id, user_id`,
        [executionId, code],
      );
      if (execution.rows[0]) {
        const account = await client.query<{ account_status: string }>(
          `SELECT account_status FROM "user" WHERE id = $1`,
          [execution.rows[0].user_id],
        );
        const tombstoned = account.rows[0]?.account_status === 'deleted';
        await client.query(
          `UPDATE privacy_request
           SET status = CASE WHEN status = 'completed' THEN status ELSE 'failed' END,
               failed_at = CASE WHEN status = 'completed' THEN failed_at ELSE CURRENT_TIMESTAMP END,
               failure_code = CASE WHEN status = 'completed' THEN failure_code ELSE $2 END,
                last_user_visible_message = CASE WHEN status = 'completed' THEN last_user_visible_message
                  WHEN $3::BOOLEAN THEN 'Your account access was removed. Protected cleanup is paused and will be retried.'
                  ELSE 'Deletion is paused for privacy-team review. Your account remains active.' END,
               updated_at = CURRENT_TIMESTAMP
           WHERE id = $1`,
          [execution.rows[0].privacy_request_id, code, tombstoned],
        );
      }
    });
    throw error;
  }
};

export {
  getAccountDeletionEligibility,
  processAccountDeletion,
  remainingBlockersForDecision,
  scheduleAccountDeletion,
  scrubStructuredValue,
};
export type {
  AccountDeletionBlocker,
  AccountDeletionDecision,
  AccountDeletionEligibility,
  ResponsibilityDecision,
  UnfinishedWorkDecision,
};
