import type { PoolClient, QueryResult, QueryResultRow } from 'pg';
import { query, transaction } from '../config/database';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import { buildMaskedContributorLabel } from './privacyIdentity.service';
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
  manual_review_required: true;
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
    message: 'Draft and submitted contributions must be synchronized or reviewed first.',
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
        WHERE collected_by_user_id = $1 AND status IN ('draft', 'pending_review')) AS pending_contribution_count,
       (SELECT COUNT(*)::INT FROM gis_import_job
        WHERE uploaded_by_user_id = $1 AND status IN ('uploaded', 'processing', 'pending_review')) AS unresolved_import_count,
       (SELECT COUNT(*)::INT FROM shapefile_export
        WHERE requested_by_user_id = $1 AND status IN ('pending', 'processing')) AS unresolved_export_count,
       (SELECT COUNT(*)::INT FROM ai_run
        WHERE started_by = $1 AND status NOT IN ('published', 'failed', 'cancelled')) AS active_ai_run_count,
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
  let blockers = blockerDefinitions.flatMap((definition) => {
    const count = Number(counts[definition.key] ?? 0);
    return count > 0 ? [{ code: definition.code, count, message: definition.message }] : [];
  });
  if (user.role === 'admin') {
    const automaticallyReleased = new Set([
      'ACTIVE_PROJECT_OWNERSHIP',
      'ACTIVE_AI_RESPONSIBILITIES',
      'ASSIGNED_PRIVACY_OR_MODERATION_CASES',
    ]);
    blockers = blockers.filter((blocker) => !automaticallyReleased.has(blocker.code));
  }
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
    manual_review_required: true,
  };
};

const scheduleAccountDeletion = async (
  executor: PoolClient,
  { requestId, userId }: { requestId: string; userId: string },
): Promise<string> => {
  assertAccountDeletionPolicyConfigured();
  const execution = await executor.query<{ id: string }>(
    `INSERT INTO account_deletion_execution (privacy_request_id, user_id, status)
     VALUES ($1, $2, 'scheduled')
     ON CONFLICT (privacy_request_id) DO UPDATE
       SET status = CASE
             WHEN account_deletion_execution.status = 'failed' THEN 'scheduled'
             ELSE account_deletion_execution.status
           END,
           failure_code = CASE
             WHEN account_deletion_execution.status = 'failed' THEN NULL
             ELSE account_deletion_execution.failure_code
           END,
           updated_at = CURRENT_TIMESTAMP
     RETURNING id`,
    [requestId, userId],
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
};

const processAccountDeletion = async (executionId: string): Promise<void> => {
  try {
    assertAccountDeletionPolicyConfigured();
    await transaction(async (client) => {
      const result = await client.query<
        {
          execution_id: string;
          execution_status: string;
          privacy_request_id: string;
          user_id: string;
          request_details: Record<string, unknown>;
        } & DeletionUserRow
      >(
        `SELECT execution.id AS execution_id, execution.status AS execution_status,
                execution.privacy_request_id, execution.user_id,
                request.request_details,
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
      if (!row || row.execution_status === 'completed' || row.account_status === 'deleted') {
        return;
      }
      if (isProtectedSuperAdminEmail(row.email)) {
        throw new Error('PROTECTED_ACCOUNT_DELETION_FORBIDDEN');
      }
      if (!row.full_name) {
        throw new Error('ACCOUNT_DELETION_IDENTITY_UNAVAILABLE');
      }
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

      const eligibility = await getAccountDeletionEligibility(
        { id: row.user_id, email: row.email, role: row.role },
        client,
        row.request_details,
      );
      if (eligibility.blockers.length > 0) {
        throw new Error(`ACCOUNT_DELETION_INELIGIBLE:${eligibility.blockers[0].code}`);
      }
      await client.query(
        `UPDATE account_deletion_execution SET eligibility_checked_at = CURRENT_TIMESTAMP WHERE id = $1`,
        [executionId],
      );

      await releaseOperationalResponsibilities(client, row.user_id);
      await client.query(
        `UPDATE account_deletion_execution SET responsibilities_released_at = CURRENT_TIMESTAMP WHERE id = $1`,
        [executionId],
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
            scopeType: 'user',
            scopeId: row.user_id,
            action: 'account_deletion_completed',
            entityType: 'user',
            entityId: row.user_id,
            audience: { kind: 'user', userId: row.user_id },
          },
          {
            scopeType: 'privacy_admin_queue',
            scopeId: 'all',
            action: 'deletion_completed',
            entityType: 'privacy_request',
            entityId: row.privacy_request_id,
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
      await client.query(`DELETE FROM contact_verification_challenge WHERE user_id = $1`, [
        row.user_id,
      ]);
      await client.query(`DELETE FROM contact_verification_audit_event WHERE user_id = $1`, [
        row.user_id,
      ]);
      await client.query(`DELETE FROM notification WHERE user_id = $1`, [row.user_id]);
      await client.query(
        `DELETE FROM spatial_feature WHERE collected_by_user_id = $1 AND status = 'draft'`,
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
        `INSERT INTO backup_account_deletion_schedule
           (privacy_request_id, user_id, status)
         VALUES ($1, $2, 'awaiting_approved_policy')
         ON CONFLICT (privacy_request_id) DO NOTHING`,
        [row.privacy_request_id, row.user_id],
      );
      await client.query(
        `UPDATE account_deletion_execution
         SET backup_expiry_scheduled_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [executionId],
      );

      await client.query(
        `UPDATE "user"
         SET email = NULL, email_original = NULL, email_canonical = NULL,
             password_hash = NULL, full_name = NULL, phone = NULL, phone_e164 = NULL,
             email_verified_at = NULL, phone_verified_at = NULL,
             phone_format_validated_at = NULL, phone_validation_method = NULL,
             contact_verification_exempted_at = NULL,
             contact_verification_exempted_by = NULL,
             pending_email_original = NULL, pending_email_canonical = NULL,
             pending_phone_e164 = NULL, verification_required_at = NULL,
             profile_picture_url = NULL, last_login = NULL,
             is_active = FALSE, account_status = 'deleted', auth_version = auth_version + 1,
             permanently_deleted_at = CURRENT_TIMESTAMP,
             masked_contributor_label = $2,
             deleted_by_privacy_request_id = $3
         WHERE id = $1 AND account_status <> 'deleted'`,
        [row.user_id, maskedLabel, row.privacy_request_id],
      );
      await client.query(
        `UPDATE account_deletion_execution
         SET direct_identifiers_erased_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [executionId],
      );
      await client.query(`DELETE FROM auth_session WHERE user_id = $1`, [row.user_id]);

      await client.query(
        `UPDATE account_deletion_execution
         SET status = 'completed', completed_at = CURRENT_TIMESTAMP,
             failure_code = NULL, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [executionId],
      );
      await client.query(
        `UPDATE privacy_request
         SET status = 'completed', completed_at = CURRENT_TIMESTAMP,
             resolution_code = 'account_deleted',
             resolution_summary = 'Credentials and direct account identifiers were erased; approved institutional records retain only a masked contributor label.',
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
                 'Mandatory deletion stages completed; backup expiry awaits the approved backup policy.')`,
        [row.privacy_request_id],
      );
      await client.query(
        `INSERT INTO audit_log
           (user_id, action_type, entity_type, entity_id, new_values)
         VALUES (NULL, 'delete', 'user', $1,
                 jsonb_build_object(
                   'privacy_request_id', $2::TEXT,
                   'account_state', 'deleted_tombstone',
                   'masked_contributor_label', $3::TEXT,
                   'mandatory_stages_completed', TRUE
                 ))`,
        [row.user_id, row.privacy_request_id, maskedLabel],
      );
    });
  } catch (error) {
    const code = String(error instanceof Error ? error.message : error)
      .split(':')[0]
      .slice(0, 120);
    await transaction(async (client) => {
      const execution = await client.query<{ privacy_request_id: string }>(
        `UPDATE account_deletion_execution
         SET status = 'failed', failure_code = $2, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status <> 'completed'
         RETURNING privacy_request_id`,
        [executionId, code],
      );
      if (execution.rows[0]) {
        await client.query(
          `UPDATE privacy_request
           SET status = CASE WHEN status = 'completed' THEN status ELSE 'failed' END,
               failed_at = CASE WHEN status = 'completed' THEN failed_at ELSE CURRENT_TIMESTAMP END,
               failure_code = CASE WHEN status = 'completed' THEN failure_code ELSE $2 END,
               last_user_visible_message = CASE WHEN status = 'completed' THEN last_user_visible_message
                 ELSE 'Deletion is paused for privacy-team review. Your account was not partially deleted.' END,
               updated_at = CURRENT_TIMESTAMP
           WHERE id = $1`,
          [execution.rows[0].privacy_request_id, code],
        );
      }
    });
    throw error;
  }
};

export {
  getAccountDeletionEligibility,
  processAccountDeletion,
  scheduleAccountDeletion,
  scrubStructuredValue,
};
export type { AccountDeletionBlocker, AccountDeletionEligibility };
