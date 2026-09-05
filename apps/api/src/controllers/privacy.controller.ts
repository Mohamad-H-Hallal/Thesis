import bcrypt from 'bcryptjs';
import type { Request, Response } from 'express';
import type { PoolClient } from 'pg';
import { query, transaction } from '../config/database';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { AppError } from '../middleware/error';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import {
  getAccountDeletionEligibility as evaluateAccountDeletionEligibility,
  remainingBlockersForDecision,
  scheduleAccountDeletion,
} from '../services/accountDeletion.service';
import {
  consumeExportDownloadGrant,
  createExportDownloadGrant,
  schedulePersonalDataExport,
} from '../services/privacyExport.service';
import { applyCorrectableProfileField } from '../services/privacyIdentity.service';

type PrivacyRequestType = 'access_export' | 'correction' | 'deletion' | 'restriction' | 'objection';

const privacyRequestTypes = new Set<PrivacyRequestType>([
  'access_export',
  'correction',
  'deletion',
  'restriction',
  'objection',
]);

const openPrivacyStatuses = new Set([
  'pending_verification',
  'submitted',
  'in_review',
  'scheduled',
  'processing',
  'failed',
]);

const terminalPrivacyStatuses = new Set(['rejected', 'completed', 'cancelled']);
const privacyStatusTransitions: Readonly<Record<string, ReadonlySet<string>>> = {
  submitted: new Set(['in_review']),
  in_review: new Set(['approved', 'rejected']),
  failed: new Set(['approved', 'rejected']),
};

const terminalReportStatuses = new Set(['resolved', 'dismissed']);
const reportStatusTransitions: Readonly<Record<string, ReadonlySet<string>>> = {
  submitted: new Set(['in_review']),
  in_review: new Set(['resolved', 'dismissed']),
};

const activePrivacyRequestConflict = (requestType: unknown, status: unknown) =>
  new AppError(
    `You already have an active ${String(requestType).replaceAll('_', ' ')} request (${String(status).replaceAll('_', ' ')}). You cannot submit another request of this type until it is decided or cancelled.`,
    409,
    {
      code: 'ACTIVE_PRIVACY_REQUEST_EXISTS',
      disposition: 'permanent_rejection',
      retryable: false,
    },
  );

const defaultPrivacyAdminMessage = (requestType: PrivacyRequestType, status: string): string => {
  if (status === 'in_review') return 'We are reviewing your request.';
  if (status === 'approved') {
    if (requestType === 'correction') return 'Your correction was approved and applied.';
    if (requestType === 'access_export') {
      return 'Your data request was approved and is being prepared.';
    }
    if (requestType === 'deletion') {
      return 'Your deletion request was approved and scheduled.';
    }
    return 'Your privacy request was approved.';
  }
  if (status === 'rejected') return 'Your request was reviewed and was not approved.';
  return 'Your privacy request was updated.';
};

const defaultContentReportMessage = (status: string, outcomeCode?: string | null): string => {
  if (status === 'in_review') return 'We are reviewing your report.';
  if (status === 'resolved') {
    if (outcomeCode === 'corrected_existing_workflow') {
      return 'Your report was confirmed. The reported item was corrected.';
    }
    if (outcomeCode === 'restricted_existing_workflow') {
      return 'Your report was confirmed. Access to the reported item was restricted.';
    }
    if (outcomeCode === 'unpublished_existing_workflow') {
      return 'Your report was confirmed. The reported item was unpublished.';
    }
    return 'Your report was confirmed and the appropriate action was completed.';
  }
  if (status === 'dismissed') {
    return 'Your report was reviewed. No issue requiring action was found.';
  }
  return 'Your content report was updated.';
};

const safePrivacyRow = (row: Record<string, unknown>, includeInternal = false) => ({
  id: row.id,
  request_type: row.request_type,
  status: row.status,
  request_details: row.request_details,
  identity_verified_at: row.identity_verified_at,
  requested_at: row.requested_at,
  internal_target_at: row.internal_target_at,
  acknowledged_at: row.acknowledged_at,
  completed_at: row.completed_at,
  cancelled_at: row.cancelled_at,
  failed_at: row.failed_at,
  resolution_code: row.resolution_code,
  last_user_visible_message: row.last_user_visible_message,
  export_status: row.export_status,
  export_expires_at: row.export_expires_at,
  overdue: row.overdue,
  ...(includeInternal
    ? {
        user_id: row.user_id,
        requester_role: row.user_role,
        requester_label: row.user_full_name ?? row.masked_contributor_label ?? 'Former user',
        requester_contact: typeof row.user_email === 'string' ? row.user_email : null,
        assigned_to_user_id: row.assigned_to_user_id,
        reviewed_by_user_id: row.reviewed_by_user_id,
        reviewed_at: row.reviewed_at,
        retention_exceptions: row.retention_exceptions,
        failure_code: row.failure_code,
        export_artifact_id: row.export_artifact_id,
        export_failure_code: row.export_failure_code,
        deletion_execution_id: row.deletion_execution_id,
        deletion_execution_status: row.deletion_execution_status,
        deletion_failure_code: row.deletion_failure_code,
        deletion_unfinished_work_decision: row.deletion_unfinished_work_decision,
        deletion_responsibility_decision: row.deletion_responsibility_decision,
        deletion_discard_counts: row.deletion_discard_counts,
      }
    : {}),
});

const reauthenticate = async (
  userId: string,
  currentPassword: unknown,
  executor: { query: PoolClient['query'] } = { query },
): Promise<void> => {
  if (
    typeof currentPassword !== 'string' ||
    currentPassword.length < 1 ||
    currentPassword.length > 256
  ) {
    throw new AppError('Enter your current password to continue.', 400, {
      code: 'REAUTHENTICATION_REQUIRED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  const result = await executor.query<{ password_hash: string | null }>(
    `SELECT password_hash FROM "user"
     WHERE id = $1 AND is_active = TRUE AND account_status <> 'deleted'`,
    [userId],
  );
  const passwordHash = result.rows[0]?.password_hash;
  const matches = passwordHash ? await bcrypt.compare(currentPassword, passwordHash) : false;
  if (!matches) {
    throw new AppError('Current password is incorrect.', 403, {
      code: 'REAUTHENTICATION_FAILED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
};

const normalizeRequestDetails = (
  requestType: PrivacyRequestType,
  value: unknown,
): Record<string, unknown> => {
  const input =
    value && typeof value === 'object' && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  const reason = typeof input.reason === 'string' ? input.reason.trim().slice(0, 1000) : '';
  if (requestType === 'correction') {
    const field = typeof input.field === 'string' ? input.field.trim() : '';
    const requestedValue =
      typeof input.requested_value === 'string' ? input.requested_value.trim() : '';
    if (field !== 'full_name' || !requestedValue || requestedValue.length > 200) {
      throw new AppError(
        'This request can correct your profile name. Use the verified mobile-number flow for phone changes; account email is fixed.',
        422,
        {
          code: 'CORRECTION_FIELD_NOT_SUPPORTED',
          disposition: 'permanent_rejection',
          retryable: false,
        },
      );
    }
    return {
      field,
      requested_value: requestedValue,
      ...(reason ? { reason } : {}),
    };
  }
  const offlineDataResolved = input.offline_data_resolved === true;
  return {
    ...(reason ? { reason } : {}),
    ...(requestType === 'deletion' ? { offline_data_resolved: offlineDataResolved } : {}),
  };
};

const publishPrivacyQueueChanges = async (
  client: PoolClient,
  {
    requestId,
    userId,
    action,
    originSessionId,
    notificationId,
  }: {
    requestId: string;
    userId: string | null;
    action: string;
    originSessionId?: string | null;
    notificationId?: string | null;
  },
): Promise<void> => {
  await publishRealtimeChanges(
    [
      ...(userId
        ? [
            {
              scopeType: 'privacy_requests',
              scopeId: userId,
              action,
              entityType: 'privacy_request',
              entityId: requestId,
              originSessionId: originSessionId ?? null,
              audience: { kind: 'user' as const, userId },
            },
          ]
        : []),
      {
        scopeType: 'privacy_admin_queue',
        scopeId: 'all',
        action,
        entityType: 'privacy_request',
        entityId: requestId,
        originSessionId: originSessionId ?? null,
        audience: { kind: 'protected_admins' as const },
      },
      ...(userId && notificationId
        ? [
            {
              scopeType: 'notifications',
              scopeId: userId,
              action: 'created',
              entityType: 'notification',
              entityId: notificationId,
              originSessionId: originSessionId ?? null,
              audience: { kind: 'user' as const, userId },
            },
          ]
        : []),
    ],
    client,
  );
};

const accountDeletionEligibility = async (req: Request, client?: PoolClient) => {
  const details = await query<{ request_details: Record<string, unknown> }>(
    `SELECT request_details FROM privacy_request
     WHERE user_id = $1 AND request_type = 'deletion'
       AND status IN ('submitted', 'in_review', 'scheduled', 'processing', 'failed')
     ORDER BY requested_at DESC LIMIT 1`,
    [req.user!.id],
  );
  return evaluateAccountDeletionEligibility(
    req.user!,
    client ?? { query },
    details.rows[0]?.request_details,
  );
};

const createPrivacyRequest = async (req: Request, res: Response): Promise<void> => {
  const requestType = req.body?.request_type as PrivacyRequestType;
  if (!privacyRequestTypes.has(requestType)) {
    throw new AppError('Unsupported privacy request type.', 422);
  }
  const existing = await query<{ id: string; request_type: string; status: string }>(
    `SELECT id, request_type, status FROM privacy_request
     WHERE user_id = $1 AND request_type = $2 AND status = ANY($3::TEXT[])
     ORDER BY requested_at DESC LIMIT 1`,
    [req.user!.id, requestType, [...openPrivacyStatuses]],
  );
  const verifiesPublicDeletion =
    requestType === 'deletion' &&
    existing.rows[0]?.request_type === 'deletion' &&
    existing.rows[0]?.status === 'pending_verification';
  if (existing.rows[0] && !verifiesPublicDeletion) {
    throw activePrivacyRequestConflict(existing.rows[0].request_type, existing.rows[0].status);
  }
  if (requestType === 'deletion' || requestType === 'access_export') {
    await reauthenticate(req.user!.id, req.body?.current_password);
  }
  if (requestType === 'deletion' && isProtectedSuperAdminEmail(req.user!.email)) {
    throw new AppError('The protected super administrator account cannot be deleted.', 409, {
      code: 'PROTECTED_ACCOUNT_DELETION_FORBIDDEN',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  let creation: { row: Record<string, unknown>; verifiedExisting: boolean };
  try {
    creation = await transaction(async (client) => {
      await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [req.user!.id]);
      const active = await client.query<{ id: string; request_type: string; status: string }>(
        `SELECT id, request_type, status FROM privacy_request
         WHERE user_id = $1 AND request_type = $2 AND status = ANY($3::TEXT[])
         ORDER BY requested_at DESC LIMIT 1`,
        [req.user!.id, requestType, [...openPrivacyStatuses]],
      );
      const requestDetails = normalizeRequestDetails(requestType, req.body?.details);
      if (requestType === 'deletion') {
        const eligibility = await evaluateAccountDeletionEligibility(
          req.user!,
          client,
          requestDetails,
        );
        requestDetails.operational_eligibility_at_request = {
          eligible: eligibility.operationally_eligible,
          blocker_codes: eligibility.blockers.map((blocker) => blocker.code),
          blocker_counts: Object.fromEntries(
            eligibility.blockers.map((blocker) => [blocker.code, blocker.count]),
          ),
        };
      }
      const activeRow = active.rows[0];
      if (
        activeRow?.status === 'pending_verification' &&
        activeRow.request_type === requestType &&
        requestType === 'deletion'
      ) {
        const verified = await client.query<Record<string, unknown>>(
          `UPDATE privacy_request
           SET status = 'submitted',
               request_details = request_details || $2::JSONB,
               identity_verified_at = CURRENT_TIMESTAMP,
               acknowledged_at = CURRENT_TIMESTAMP,
               last_user_visible_message =
                 'Your identity was verified and your request is awaiting privacy-team review.',
               updated_at = CURRENT_TIMESTAMP
           WHERE id = $1 AND status = 'pending_verification'
           RETURNING *`,
          [activeRow.id, JSON.stringify(requestDetails)],
        );
        const row = verified.rows[0];
        await client.query(
          `INSERT INTO privacy_request_status_history
             (request_id, from_status, to_status, actor_user_id, actor_kind, user_visible_message)
           VALUES ($1, 'pending_verification', 'submitted', $2, 'requester', $3)`,
          [row.id, req.user!.id, row.last_user_visible_message],
        );
        await publishPrivacyQueueChanges(client, {
          requestId: String(row.id),
          userId: req.user!.id,
          action: 'request_identity_verified',
          originSessionId: req.authSessionId,
        });
        return { row, verifiedExisting: true };
      }
      if (activeRow) {
        throw activePrivacyRequestConflict(activeRow.request_type, activeRow.status);
      }
      const result = await client.query<Record<string, unknown>>(
        `INSERT INTO privacy_request
           (user_id, request_type, status, request_details, identity_verified_at, acknowledged_at,
            last_user_visible_message)
         VALUES ($1, $2, 'submitted', $3::JSONB, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP,
                 'Your request was received and is awaiting privacy-team review.')
         RETURNING *`,
        [req.user!.id, requestType, JSON.stringify(requestDetails)],
      );
      const row = result.rows[0];
      await client.query(
        `INSERT INTO privacy_request_status_history
           (request_id, from_status, to_status, actor_user_id, actor_kind, user_visible_message)
         VALUES ($1, NULL, 'submitted', $2, 'requester', $3)`,
        [row.id, req.user!.id, row.last_user_visible_message],
      );
      await publishPrivacyQueueChanges(client, {
        requestId: String(row.id),
        userId: req.user!.id,
        action: 'request_created',
        originSessionId: req.authSessionId,
      });
      return { row, verifiedExisting: false };
    });
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === '23505') {
      throw activePrivacyRequestConflict(requestType, 'in progress');
    }
    throw error;
  }
  res.status(creation.verifiedExisting ? 200 : 201).json({
    success: true,
    message:
      requestType === 'deletion'
        ? creation.verifiedExisting
          ? 'Identity verified. Your existing account deletion request is now awaiting review.'
          : 'Account deletion request received. Your account remains active during review.'
        : 'Privacy request received.',
    data: safePrivacyRow(creation.row),
  });
};

const getAccountDeletionEligibility = async (req: Request, res: Response): Promise<void> => {
  const eligibility = await accountDeletionEligibility(req);
  res.json({
    success: true,
    data: {
      ...eligibility,
      notice:
        'Deletion is reviewed separately from deactivation. Credentials and contact details are erased; eligible project records may keep a masked contributor label.',
    },
  });
};

const listMyPrivacyRequests = async (req: Request, res: Response): Promise<void> => {
  const result = await query<Record<string, unknown>>(
    `SELECT request.*,
            artifact.status AS export_status,
            artifact.expires_at AS export_expires_at
     FROM privacy_request request
     LEFT JOIN privacy_export_artifact artifact ON artifact.privacy_request_id = request.id
     WHERE request.user_id = $1
     ORDER BY request.requested_at DESC LIMIT 100`,
    [req.user!.id],
  );
  res.json({ success: true, data: result.rows.map((row) => safePrivacyRow(row)) });
};

const getMyPrivacyRequest = async (req: Request, res: Response): Promise<void> => {
  const requestResult = await query<Record<string, unknown>>(
    `SELECT request.*, artifact.status AS export_status,
            artifact.expires_at AS export_expires_at
     FROM privacy_request request
     LEFT JOIN privacy_export_artifact artifact ON artifact.privacy_request_id = request.id
     WHERE request.id = $1 AND request.user_id = $2`,
    [req.params.requestId, req.user!.id],
  );
  if (!requestResult.rows[0]) {
    throw new AppError('Privacy request not found.', 404);
  }
  const history = await query(
    `SELECT to_status, actor_kind, user_visible_message, resolution_code, occurred_at
     FROM privacy_request_status_history
     WHERE request_id = $1
     ORDER BY occurred_at, id`,
    [req.params.requestId],
  );
  res.json({
    success: true,
    data: { request: safePrivacyRow(requestResult.rows[0]), history: history.rows },
  });
};

const cancelMyPrivacyRequest = async (req: Request, res: Response): Promise<void> => {
  const updated = await transaction(async (client) => {
    const current = await client.query<Record<string, unknown>>(
      `SELECT * FROM privacy_request WHERE id = $1 AND user_id = $2 FOR UPDATE`,
      [req.params.requestId, req.user!.id],
    );
    const row = current.rows[0];
    if (!row || !['pending_verification', 'submitted', 'in_review'].includes(String(row.status))) {
      throw new AppError('This privacy request cannot be cancelled.', 409);
    }
    const result = await client.query<Record<string, unknown>>(
      `UPDATE privacy_request
       SET status = 'cancelled', cancelled_at = CURRENT_TIMESTAMP,
           updated_at = CURRENT_TIMESTAMP,
           last_user_visible_message = 'You cancelled this request before processing began.'
       WHERE id = $1 RETURNING *`,
      [req.params.requestId],
    );
    await client.query(
      `INSERT INTO privacy_request_status_history
         (request_id, from_status, to_status, actor_user_id, actor_kind, user_visible_message)
       VALUES ($1, $2, 'cancelled', $3, 'requester', $4)`,
      [req.params.requestId, row.status, req.user!.id, result.rows[0].last_user_visible_message],
    );
    await publishPrivacyQueueChanges(client, {
      requestId: req.params.requestId,
      userId: req.user!.id,
      action: 'request_cancelled',
      originSessionId: req.authSessionId,
    });
    return result.rows[0];
  });
  res.json({ success: true, message: 'Privacy request cancelled.', data: safePrivacyRow(updated) });
};

const listPrivacyRequestsForAdmin = async (req: Request, res: Response): Promise<void> => {
  const page = Math.max(1, Number.parseInt(String(req.query.page ?? '1'), 10) || 1);
  const limit = Math.min(
    100,
    Math.max(1, Number.parseInt(String(req.query.limit ?? '20'), 10) || 20),
  );
  const status = typeof req.query.status === 'string' && req.query.status ? req.query.status : null;
  const requestType =
    typeof req.query.request_type === 'string' && req.query.request_type
      ? req.query.request_type
      : null;
  const search =
    typeof req.query.q === 'string' && req.query.q.trim() ? req.query.q.trim().slice(0, 120) : null;
  const result = await query<Record<string, unknown>>(
    `SELECT request.*, account.full_name AS user_full_name, account.role AS user_role,
            account.masked_contributor_label,
            COALESCE(account.email_original, account.email) AS user_email,
            artifact.status AS export_status, artifact.expires_at AS export_expires_at,
            request.internal_target_at < CURRENT_TIMESTAMP
              AND request.status = ANY($6::TEXT[]) AS overdue,
            COUNT(*) OVER()::INT AS total_count
     FROM privacy_request request
     LEFT JOIN "user" account ON account.id = request.user_id
     LEFT JOIN privacy_export_artifact artifact ON artifact.privacy_request_id = request.id
     WHERE ($1::TEXT IS NULL OR request.status = $1)
       AND ($2::TEXT IS NULL OR request.request_type = $2)
       AND ($3::TEXT IS NULL OR request.id::TEXT ILIKE ('%' || $3 || '%')
            OR account.full_name ILIKE ('%' || $3 || '%')
            OR account.email_canonical ILIKE ('%' || LOWER($3) || '%'))
     ORDER BY request.requested_at DESC, request.id DESC
     LIMIT $4 OFFSET $5`,
    [status, requestType, search, limit, (page - 1) * limit, [...openPrivacyStatuses]],
  );
  const summary = await query(
    `SELECT status, COUNT(*)::INT AS count,
            COUNT(*) FILTER (WHERE internal_target_at < CURRENT_TIMESTAMP
              AND status = ANY($1::TEXT[]))::INT AS overdue_count
     FROM privacy_request GROUP BY status ORDER BY status`,
    [[...openPrivacyStatuses]],
  );
  const total = Number(result.rows[0]?.total_count ?? 0);
  res.json({
    success: true,
    data: result.rows.map((row) => safePrivacyRow(row, true)),
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
      has_more: page * limit < total,
    },
    summary: summary.rows,
  });
};

const getPrivacyRequestForAdmin = async (req: Request, res: Response): Promise<void> => {
  const result = await query<Record<string, unknown>>(
    `SELECT request.*, account.full_name AS user_full_name, account.role AS user_role,
            account.masked_contributor_label,
            COALESCE(account.email_original, account.email) AS user_email,
            artifact.id AS export_artifact_id, artifact.status AS export_status,
            artifact.expires_at AS export_expires_at, artifact.failure_code AS export_failure_code,
            execution.id AS deletion_execution_id, execution.status AS deletion_execution_status,
             execution.failure_code AS deletion_failure_code,
             execution.unfinished_work_decision AS deletion_unfinished_work_decision,
             execution.responsibility_decision AS deletion_responsibility_decision,
             execution.discard_counts AS deletion_discard_counts
     FROM privacy_request request
     LEFT JOIN "user" account ON account.id = request.user_id
     LEFT JOIN privacy_export_artifact artifact ON artifact.privacy_request_id = request.id
     LEFT JOIN account_deletion_execution execution ON execution.privacy_request_id = request.id
     WHERE request.id = $1`,
    [req.params.requestId],
  );
  if (!result.rows[0]) {
    throw new AppError('Privacy request not found.', 404);
  }
  const [history, downstream, freeText] = await Promise.all([
    query(
      `SELECT id, from_status, to_status, actor_user_id, actor_kind,
              user_visible_message, resolution_code, occurred_at
       FROM privacy_request_status_history WHERE request_id = $1
       ORDER BY occurred_at, id`,
      [req.params.requestId],
    ),
    query(
      `SELECT id, processor_key, status, safe_instruction, assigned_to_user_id,
              completed_at, evidence_reference, created_at, updated_at
       FROM privacy_downstream_correction_task WHERE privacy_request_id = $1
       ORDER BY created_at`,
      [req.params.requestId],
    ),
    query(
      `SELECT id, record_table, record_id, reason_code, status,
              assigned_to_user_id, resolution_summary, created_at, reviewed_at
       FROM privacy_free_text_review_task WHERE privacy_request_id = $1
       ORDER BY created_at`,
      [req.params.requestId],
    ),
  ]);
  res.json({
    success: true,
    data: {
      request: safePrivacyRow(result.rows[0], true),
      history: history.rows,
      downstream_correction_tasks: downstream.rows,
      free_text_review_tasks: freeText.rows,
    },
  });
};

const insertAccountNotification = async (
  client: PoolClient,
  userId: string | null,
  requestId: string,
  message: string | null,
): Promise<string | null> => {
  if (!userId || !message) {
    return null;
  }
  const result = await client.query<{ id: string }>(
    `INSERT INTO notification (user_id, type, title, message, metadata)
     VALUES ($1, 'account_event', 'Privacy request updated', $2, $3::JSONB)
     RETURNING id`,
    [userId, message, JSON.stringify({ privacy_request_id: requestId })],
  );
  return result.rows[0].id;
};

const updatePrivacyRequestForAdmin = async (req: Request, res: Response): Promise<void> => {
  const requestedStatus = String(req.body?.status ?? '');
  if (!['in_review', 'approved', 'rejected'].includes(requestedStatus)) {
    throw new AppError('Unsupported privacy request status.', 422);
  }
  const suppliedUserMessage =
    typeof req.body?.user_message === 'string'
      ? req.body.user_message.trim().slice(0, 1000) || null
      : null;

  const updated = await transaction(async (client) => {
    const currentResult = await client.query<Record<string, unknown>>(
      `SELECT request.*, account.email, account.role, account.account_status
       FROM privacy_request request
       LEFT JOIN "user" account ON account.id = request.user_id
       WHERE request.id = $1 FOR UPDATE OF request`,
      [req.params.requestId],
    );
    const current = currentResult.rows[0];
    if (!current) {
      throw new AppError('Privacy request not found.', 404);
    }
    const currentStatus = String(current.status);
    if (terminalPrivacyStatuses.has(currentStatus)) {
      throw new AppError('Privacy request is already closed.', 409);
    }
    if (!privacyStatusTransitions[currentStatus]?.has(requestedStatus)) {
      throw new AppError(
        `Privacy requests cannot move from ${currentStatus.replaceAll('_', ' ')} to ${requestedStatus.replaceAll('_', ' ')}.`,
        409,
        {
          code: 'INVALID_PRIVACY_STATUS_TRANSITION',
          disposition: 'permanent_rejection',
          retryable: false,
        },
      );
    }
    const requestType = current.request_type as PrivacyRequestType;
    const userId = typeof current.user_id === 'string' ? current.user_id : null;
    if (!userId && ['correction', 'access_export', 'deletion'].includes(requestType)) {
      throw new AppError('The request no longer has an executable account subject.', 409);
    }

    let finalStatus = requestedStatus;
    let finalMessage =
      suppliedUserMessage ?? defaultPrivacyAdminMessage(requestType, requestedStatus);
    let resolutionCode =
      typeof req.body?.resolution_code === 'string'
        ? req.body.resolution_code.trim().slice(0, 120) || null
        : null;

    if (requestedStatus === 'approved' && requestType === 'correction') {
      const details = current.request_details as Record<string, unknown>;
      try {
        const evidence = await applyCorrectableProfileField(client, {
          userId: userId!,
          field: String(details.field ?? ''),
          requestedValue: details.requested_value,
        });
        await client.query(
          `INSERT INTO audit_log
             (user_id, action_type, entity_type, entity_id, new_values)
           VALUES ($1, 'update', 'user', $2, $3::JSONB)`,
          [
            req.user!.id,
            userId,
            JSON.stringify({ correction_request_id: req.params.requestId, ...evidence }),
          ],
        );
      } catch (error) {
        const code = error instanceof Error ? error.message : String(error);
        throw new AppError(
          code === 'CORRECTION_FIELD_REQUIRES_SEPARATE_VERIFICATION'
            ? 'This field requires its existing ownership-verification workflow.'
            : 'The correction could not be applied using the authoritative profile rules.',
          409,
          { code, disposition: 'permanent_rejection', retryable: false },
        );
      }
      finalStatus = 'completed';
      resolutionCode = 'profile_correction_applied';
      finalMessage =
        suppliedUserMessage ?? defaultPrivacyAdminMessage(requestType, requestedStatus);
    } else if (requestedStatus === 'approved' && requestType === 'access_export') {
      try {
        await schedulePersonalDataExport(client, {
          requestId: req.params.requestId,
          userId: userId!,
        });
      } catch (error) {
        const code = error instanceof Error ? error.message : String(error);
        if (code.startsWith('PRIVACY_EXPORT_') && code.endsWith('_REQUIRED')) {
          throw new AppError(
            'Personal-data export is unavailable until its protected production configuration is approved.',
            503,
            { code, disposition: 'retry', retryable: false },
          );
        }
        throw error;
      }
      finalStatus = 'scheduled';
      resolutionCode = 'export_scheduled';
      finalMessage =
        suppliedUserMessage ?? defaultPrivacyAdminMessage(requestType, requestedStatus);
    } else if (requestedStatus === 'approved' && requestType === 'deletion') {
      if (isProtectedSuperAdminEmail(current.email as string | null)) {
        throw new AppError('The protected super administrator account cannot be deleted.', 409, {
          code: 'PROTECTED_ACCOUNT_DELETION_FORBIDDEN',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      const unfinishedWorkDecision = String(req.body?.unfinished_work_decision ?? '');
      const responsibilityDecision = String(req.body?.responsibility_decision ?? '');
      if (!['require_resolution', 'discard_unapproved'].includes(unfinishedWorkDecision)) {
        throw new AppError('Choose how unfinished work must be handled.', 422, {
          code: 'ACCOUNT_DELETION_UNFINISHED_WORK_DECISION_REQUIRED',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      if (!['release', 'confirmed_transferred'].includes(responsibilityDecision)) {
        throw new AppError('Choose how active responsibilities must be handled.', 422, {
          code: 'ACCOUNT_DELETION_RESPONSIBILITY_DECISION_REQUIRED',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      const deletionDecision = {
        unfinishedWorkDecision: unfinishedWorkDecision as
          | 'require_resolution'
          | 'discard_unapproved',
        responsibilityDecision: responsibilityDecision as 'release' | 'confirmed_transferred',
      };
      const eligibility = await evaluateAccountDeletionEligibility(
        { id: userId!, email: current.email as string | null, role: String(current.role) },
        client,
        current.request_details as Record<string, unknown>,
      );
      const remainingBlockers = remainingBlockersForDecision(eligibility, deletionDecision);
      if (remainingBlockers.length > 0) {
        throw new AppError(
          'Deletion is blocked until the listed responsibilities are resolved.',
          409,
          {
            code: 'ACCOUNT_DELETION_INELIGIBLE',
            disposition: 'permanent_rejection',
            retryable: false,
          },
        );
      }
      try {
        await scheduleAccountDeletion(client, {
          requestId: req.params.requestId,
          userId: userId!,
          ...deletionDecision,
        });
      } catch (error) {
        if (
          error instanceof Error &&
          error.message === 'ACCOUNT_DELETION_POLICY_APPROVAL_REQUIRED'
        ) {
          throw new AppError(
            'Account deletion execution is unavailable until the production policy is approved.',
            503,
            {
              code: error.message,
              disposition: 'retry',
              retryable: false,
            },
          );
        }
        throw error;
      }
      finalStatus = 'scheduled';
      resolutionCode = 'deletion_scheduled';
      finalMessage =
        suppliedUserMessage ?? defaultPrivacyAdminMessage(requestType, requestedStatus);
    } else if (
      requestedStatus === 'approved' &&
      ['restriction', 'objection'].includes(requestType)
    ) {
      finalStatus = 'completed';
      resolutionCode = `${requestType}_approved`;
      finalMessage =
        suppliedUserMessage ?? defaultPrivacyAdminMessage(requestType, requestedStatus);
    }

    const completed = finalStatus === 'completed';
    const result = await client.query<Record<string, unknown>>(
      `UPDATE privacy_request
       SET status = $2,
           assigned_to_user_id = COALESCE(assigned_to_user_id, $3),
           reviewed_by_user_id = $3, reviewed_at = CURRENT_TIMESTAMP,
           completed_at = CASE WHEN $2 = 'completed' THEN CURRENT_TIMESTAMP ELSE completed_at END,
           failed_at = CASE WHEN $2 <> 'failed' THEN NULL ELSE failed_at END,
           failure_code = CASE WHEN $2 <> 'failed' THEN NULL ELSE failure_code END,
           resolution_code = COALESCE($4, resolution_code),
           resolution_summary = $5,
           last_user_visible_message = $6,
           updated_at = CURRENT_TIMESTAMP
       WHERE id = $1 RETURNING *`,
      [req.params.requestId, finalStatus, req.user!.id, resolutionCode, finalMessage, finalMessage],
    );
    await client.query(
      `INSERT INTO privacy_request_status_history
         (request_id, from_status, to_status, actor_user_id, actor_kind,
          user_visible_message, resolution_code, resolution_summary)
       VALUES ($1, $2, $3, $4, 'administrator', $5, $6, $7)`,
      [
        req.params.requestId,
        currentStatus,
        finalStatus,
        req.user!.id,
        finalMessage,
        resolutionCode,
        finalMessage,
      ],
    );
    const notificationId = await insertAccountNotification(
      client,
      userId,
      req.params.requestId,
      finalMessage,
    );
    await publishPrivacyQueueChanges(client, {
      requestId: req.params.requestId,
      userId,
      action: completed ? 'request_completed' : 'request_updated',
      originSessionId: req.authSessionId,
      notificationId,
    });
    return result.rows[0];
  });
  res.json({
    success: true,
    message: 'Privacy request updated.',
    data: safePrivacyRow(updated, true),
  });
};

const retryPrivacyRequestExecution = async (req: Request, res: Response): Promise<void> => {
  req.body = { ...req.body, status: 'approved' };
  await updatePrivacyRequestForAdmin(req, res);
};

const createExportGrant = async (req: Request, res: Response): Promise<void> => {
  await reauthenticate(req.user!.id, req.body?.current_password);
  let grant;
  try {
    grant = await transaction((client) =>
      createExportDownloadGrant(client, {
        requestId: req.params.requestId,
        userId: req.user!.id,
        sessionId: req.authSessionId!,
      }),
    );
  } catch (error) {
    if (error instanceof Error && error.message === 'PRIVACY_EXPORT_NOT_AVAILABLE') {
      throw new AppError('This export is not ready or has expired.', 409, {
        code: error.message,
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }
    throw error;
  }
  res.status(201).json({
    success: true,
    data: {
      download_path: `/api/v1/privacy/exports/${grant.artifactId}/download`,
      grant_token: grant.token,
      expires_at: grant.expiresAt,
    },
  });
};

const downloadPersonalDataExport = async (req: Request, res: Response): Promise<void> => {
  const token = req.get('x-privacy-export-grant') ?? '';
  if (!token || token.length > 128) {
    throw new AppError('Download grant is invalid.', 403, {
      code: 'DOWNLOAD_GRANT_INVALID',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  try {
    const download = await consumeExportDownloadGrant({
      artifactId: req.params.artifactId,
      userId: req.user!.id,
      sessionId: req.authSessionId!,
      token,
    });
    res.setHeader('Content-Type', download.contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${download.filename}"`);
    res.setHeader('Cache-Control', 'no-store, private');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    download.stream.on('error', () => res.destroy());
    download.stream.pipe(res);
  } catch (error) {
    const code = error instanceof Error ? error.message : String(error);
    if (code.startsWith('PRIVACY_EXPORT_')) {
      throw new AppError('Download grant is invalid or expired.', 403, {
        code,
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }
    throw error;
  }
};

const contentTargetExists = async (
  client: PoolClient | null,
  entityType: string,
  entityId: string,
  projectId: string,
): Promise<boolean> => {
  const executor = client ?? { query };
  const targets: Record<string, string> = {
    project: 'SELECT 1 FROM project WHERE id = $1 AND id = $2',
    feature: 'SELECT 1 FROM spatial_feature WHERE id = $1 AND project_id = $2',
    photo: `SELECT 1 FROM photo item JOIN spatial_feature feature ON feature.id = item.feature_id
            WHERE item.id = $1 AND feature.project_id = $2`,
    import: 'SELECT 1 FROM gis_import_job WHERE id = $1 AND project_id = $2',
    comment: `SELECT 1 FROM gis_import_comment item
              JOIN gis_import_job job ON job.id = item.import_job_id
              WHERE item.id = $1 AND job.project_id = $2`,
    ai_output: 'SELECT 1 FROM ai_output_layer WHERE id = $1 AND project_id = $2',
    user: `SELECT 1 FROM "user" account WHERE account.id = $1 AND (
             EXISTS (SELECT 1 FROM project_assignment assignment
                     WHERE assignment.user_id = account.id AND assignment.project_id = $2)
             OR EXISTS (SELECT 1 FROM spatial_feature feature
                        WHERE feature.collected_by_user_id = account.id AND feature.project_id = $2))`,
  };
  const sql = targets[entityType];
  if (!sql) {
    return false;
  }
  return (await executor.query(sql, [entityId, projectId])).rowCount === 1;
};

const createContentReport = async (req: Request, res: Response): Promise<void> => {
  const projectId = String(req.body.project_id);
  const entityId = String(req.body.entity_id);
  const entityType = String(req.body.entity_type);
  const created = await transaction(async (client) => {
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [
      `${req.user!.id}:${entityType}:${entityId}`,
    ]);
    if (!(await contentTargetExists(client, entityType, entityId, projectId))) {
      throw new AppError('The reported content was not found in this project.', 404);
    }
    const activeReport = await client.query<{ id: string }>(
      `SELECT id FROM content_report
       WHERE reporter_user_id = $1 AND entity_type = $2 AND entity_id = $3
         AND status IN ('submitted', 'in_review')
       LIMIT 1`,
      [req.user!.id, entityType, entityId],
    );
    if (activeReport.rows[0]) {
      throw new AppError('You already have an open report for this item.', 409, {
        code: 'ACTIVE_CONTENT_REPORT_EXISTS',
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }
    const activeReportCount = await client.query<{ count: number }>(
      `SELECT COUNT(*)::INT AS count FROM content_report
       WHERE reporter_user_id = $1 AND status IN ('submitted', 'in_review')`,
      [req.user!.id],
    );
    if (Number(activeReportCount.rows[0]?.count ?? 0) >= 10) {
      throw new AppError('You have reached the limit of 10 open content reports.', 429, {
        code: 'ACTIVE_CONTENT_REPORT_LIMIT_REACHED',
        disposition: 'retry',
        retryable: true,
      });
    }
    const result = await client.query<Record<string, unknown>>(
      `INSERT INTO content_report
         (reporter_user_id, project_id, entity_type, entity_id, reason_code, description, status)
       VALUES ($1, $2, $3, $4, $5, $6, 'submitted')
       RETURNING *`,
      [
        req.user!.id,
        projectId,
        entityType,
        entityId,
        req.body.reason_code,
        typeof req.body.description === 'string' ? req.body.description.trim() || null : null,
      ],
    );
    await client.query(
      `INSERT INTO content_report_status_history
         (report_id, from_status, to_status, actor_user_id, actor_kind)
       VALUES ($1, NULL, 'submitted', $2, 'reporter')`,
      [result.rows[0].id, req.user!.id],
    );
    await publishRealtimeChanges(
      [
        {
          scopeType: 'content_reports',
          scopeId: req.user!.id,
          action: 'report_created',
          entityType: 'content_report',
          entityId: String(result.rows[0].id),
          originSessionId: req.authSessionId,
          audience: { kind: 'user', userId: req.user!.id },
        },
        {
          scopeType: 'moderation_admin_queue',
          scopeId: 'all',
          action: 'report_created',
          entityType: 'content_report',
          entityId: String(result.rows[0].id),
          originSessionId: req.authSessionId,
          audience: { kind: 'protected_admins' },
        },
      ],
      client,
    );
    return result.rows[0];
  });
  res.status(201).json({ success: true, message: 'Report received for review.', data: created });
};

const listMyContentReports = async (req: Request, res: Response): Promise<void> => {
  const result = await query(
    `SELECT report.id, report.project_id, project.name AS project_title,
            report.entity_type, report.entity_id, report.reason_code, report.description,
            report.status, report.user_visible_message, report.outcome_code,
            report.created_at, report.updated_at, report.resolved_at
     FROM content_report report
     LEFT JOIN project ON project.id = report.project_id
     WHERE report.reporter_user_id = $1
     ORDER BY report.created_at DESC LIMIT 100`,
    [req.user!.id],
  );
  res.json({ success: true, data: result.rows });
};

const listContentReportsForAdmin = async (req: Request, res: Response): Promise<void> => {
  const page = Math.max(1, Number.parseInt(String(req.query.page ?? '1'), 10) || 1);
  const limit = Math.min(
    100,
    Math.max(1, Number.parseInt(String(req.query.limit ?? '20'), 10) || 20),
  );
  const status = typeof req.query.status === 'string' && req.query.status ? req.query.status : null;
  const entityType =
    typeof req.query.entity_type === 'string' && req.query.entity_type
      ? req.query.entity_type
      : null;
  const search =
    typeof req.query.q === 'string' && req.query.q.trim() ? req.query.q.trim().slice(0, 120) : null;
  const result = await query<Record<string, unknown>>(
    `SELECT report.id, report.project_id, project.name AS project_title,
            report.entity_type, report.entity_id,
            report.reason_code, report.status, report.assigned_to_user_id,
            report.outcome_code, report.internal_target_at, report.created_at,
            report.updated_at, report.resolved_at,
            COALESCE(reporter.full_name, reporter.masked_contributor_label, 'Former user')
              AS reporter_label,
            COALESCE(reporter.email_original, reporter.email) AS reporter_contact,
            report.internal_target_at < CURRENT_TIMESTAMP
              AND report.status <> ALL($6::TEXT[]) AS overdue,
            COUNT(*) OVER()::INT AS total_count
     FROM content_report report
      LEFT JOIN "user" reporter ON reporter.id = report.reporter_user_id
      LEFT JOIN project ON project.id = report.project_id
     WHERE ($1::TEXT IS NULL OR report.status = $1)
       AND ($2::TEXT IS NULL OR report.entity_type = $2)
        AND ($3::TEXT IS NULL OR report.id::TEXT ILIKE ('%' || $3 || '%')
             OR report.entity_id::TEXT ILIKE ('%' || $3 || '%')
             OR report.reason_code ILIKE ('%' || $3 || '%')
             OR project.name ILIKE ('%' || $3 || '%'))
     ORDER BY report.created_at DESC, report.id DESC
     LIMIT $4 OFFSET $5`,
    [status, entityType, search, limit, (page - 1) * limit, [...terminalReportStatuses]],
  );
  const summary = await query(
    `SELECT status, COUNT(*)::INT AS count,
            COUNT(*) FILTER (WHERE internal_target_at < CURRENT_TIMESTAMP
              AND status <> ALL($1::TEXT[]))::INT AS overdue_count
     FROM content_report GROUP BY status ORDER BY status`,
    [[...terminalReportStatuses]],
  );
  const total = Number(result.rows[0]?.total_count ?? 0);
  res.json({
    success: true,
    data: result.rows,
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
      has_more: page * limit < total,
    },
    summary: summary.rows,
  });
};

const getContentReportForAdmin = async (req: Request, res: Response): Promise<void> => {
  const result = await query<Record<string, unknown>>(
    `SELECT report.id, report.reporter_user_id, report.project_id,
            project.name AS project_title,
            report.entity_type, report.entity_id, report.reason_code,
            report.description, report.status, report.assigned_to_user_id,
            report.reviewed_by_user_id, report.internal_target_at,
            report.user_visible_message, report.outcome_code,
            report.created_at, report.updated_at,
            report.resolved_at,
            COALESCE(reporter.full_name, reporter.masked_contributor_label, 'Former user')
              AS reporter_label,
            COALESCE(reporter.email_original, reporter.email) AS reporter_contact
     FROM content_report report
     LEFT JOIN "user" reporter ON reporter.id = report.reporter_user_id
     LEFT JOIN project ON project.id = report.project_id
     WHERE report.id = $1`,
    [req.params.reportId],
  );
  const report = result.rows[0];
  if (!report) {
    throw new AppError('Content report not found.', 404);
  }
  const [history, available] = await Promise.all([
    query(
      `SELECT id, from_status, to_status, actor_user_id, actor_kind, outcome_code,
              user_visible_message, occurred_at
       FROM content_report_status_history WHERE report_id = $1
       ORDER BY occurred_at, id`,
      [req.params.reportId],
    ),
    contentTargetExists(
      null,
      String(report.entity_type),
      String(report.entity_id),
      String(report.project_id),
    ),
  ]);
  res.json({
    success: true,
    data: { report: { ...report, entity_available: available }, history: history.rows },
  });
};

const updateContentReportForAdmin = async (req: Request, res: Response): Promise<void> => {
  const status = String(req.body?.status ?? '');
  if (!['in_review', 'resolved', 'dismissed'].includes(status)) {
    throw new AppError('Unsupported content-report status.', 422);
  }
  const outcomeCode =
    typeof req.body?.outcome_code === 'string'
      ? req.body.outcome_code.trim().slice(0, 120) || null
      : null;
  const allowedOutcomes = new Set([
    'unsupported',
    'corrected_existing_workflow',
    'restricted_existing_workflow',
    'unpublished_existing_workflow',
    'independent_action_confirmed',
  ]);
  if (outcomeCode && !allowedOutcomes.has(outcomeCode)) {
    throw new AppError('Unsupported moderation outcome.', 422);
  }
  const effectiveOutcome =
    status === 'dismissed' ? 'unsupported' : status === 'resolved' ? outcomeCode : null;
  const userMessage =
    typeof req.body?.user_message === 'string'
      ? req.body.user_message.trim().slice(0, 1000) ||
        defaultContentReportMessage(status, effectiveOutcome)
      : defaultContentReportMessage(status, effectiveOutcome);
  const updated = await transaction(async (client) => {
    const current = await client.query<Record<string, unknown>>(
      `SELECT * FROM content_report WHERE id = $1 FOR UPDATE`,
      [req.params.reportId],
    );
    const row = current.rows[0];
    if (!row) {
      throw new AppError('Content report not found.', 404);
    }
    const currentStatus = String(row.status);
    if (terminalReportStatuses.has(currentStatus)) {
      throw new AppError('Content report is already final.', 409);
    }
    if (!reportStatusTransitions[currentStatus]?.has(status)) {
      throw new AppError(
        `Content reports cannot move from ${currentStatus.replaceAll('_', ' ')} to ${status.replaceAll('_', ' ')}.`,
        409,
        {
          code: 'INVALID_CONTENT_REPORT_STATUS_TRANSITION',
          disposition: 'permanent_rejection',
          retryable: false,
        },
      );
    }
    if (
      status === 'resolved' &&
      !new Set([
        'corrected_existing_workflow',
        'restricted_existing_workflow',
        'unpublished_existing_workflow',
        'independent_action_confirmed',
      ]).has(String(effectiveOutcome))
    ) {
      throw new AppError('Select the action completed for this report.', 422);
    }
    const result = await client.query<Record<string, unknown>>(
      `UPDATE content_report
       SET status = $2, assigned_to_user_id = COALESCE(assigned_to_user_id, $3),
            reviewed_by_user_id = $3, resolution_summary = $4,
            user_visible_message = $4,
            internal_resolution_notes = NULL,
            outcome_code = $5,
            action_reference = NULL,
            resolved_at = CASE WHEN $2 = ANY($6::TEXT[]) THEN CURRENT_TIMESTAMP ELSE NULL END,
            updated_at = CURRENT_TIMESTAMP
       WHERE id = $1 RETURNING *`,
      [
        req.params.reportId,
        status,
        req.user!.id,
        userMessage,
        effectiveOutcome,
        [...terminalReportStatuses],
      ],
    );
    await client.query(
      `INSERT INTO content_report_status_history
         (report_id, from_status, to_status, actor_user_id, actor_kind,
           outcome_code, user_visible_message, resolution_summary)
        VALUES ($1, $2, $3, $4, 'administrator', $5, $6, $6)`,
      [req.params.reportId, row.status, status, req.user!.id, effectiveOutcome, userMessage],
    );
    let notificationId: string | null = null;
    if (userMessage) {
      const notification = await client.query<{ id: string }>(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'account_event', 'Content report updated', $2, $3::JSONB)
         RETURNING id`,
        [
          row.reporter_user_id,
          userMessage,
          JSON.stringify({ content_report_id: req.params.reportId }),
        ],
      );
      notificationId = notification.rows[0].id;
    }
    await publishRealtimeChanges(
      [
        {
          scopeType: 'content_reports',
          scopeId: String(row.reporter_user_id),
          action: 'report_updated',
          entityType: 'content_report',
          entityId: req.params.reportId,
          originSessionId: req.authSessionId,
          audience: { kind: 'user', userId: String(row.reporter_user_id) },
        },
        {
          scopeType: 'moderation_admin_queue',
          scopeId: 'all',
          action: 'report_updated',
          entityType: 'content_report',
          entityId: req.params.reportId,
          originSessionId: req.authSessionId,
          audience: { kind: 'protected_admins' },
        },
        ...(notificationId
          ? [
              {
                scopeType: 'notifications',
                scopeId: String(row.reporter_user_id),
                action: 'created',
                entityType: 'notification',
                entityId: notificationId,
                originSessionId: req.authSessionId,
                audience: { kind: 'user' as const, userId: String(row.reporter_user_id) },
              },
            ]
          : []),
      ],
      client,
    );
    return result.rows[0];
  });
  res.json({ success: true, message: 'Content report updated.', data: updated });
};

const getPrivacyAdminQueueCounts = async (_req: Request, res: Response): Promise<void> => {
  const result = await query(
    `SELECT
       (SELECT COUNT(*)::INT FROM privacy_request
         WHERE status IN ('pending_verification', 'submitted', 'in_review',
                          'scheduled', 'processing', 'failed')) AS open_privacy_requests,
       (SELECT COUNT(*)::INT FROM privacy_request
         WHERE internal_target_at < CURRENT_TIMESTAMP
           AND status IN ('pending_verification', 'submitted', 'in_review',
                          'scheduled', 'processing', 'failed')) AS overdue_privacy_requests,
       (SELECT COUNT(*)::INT FROM content_report
         WHERE status NOT IN ('resolved', 'dismissed')) AS open_content_reports,
       (SELECT COUNT(*)::INT FROM content_report
         WHERE internal_target_at < CURRENT_TIMESTAMP
           AND status NOT IN ('resolved', 'dismissed')) AS overdue_content_reports`,
  );
  res.json({ success: true, data: result.rows[0] });
};

export {
  cancelMyPrivacyRequest,
  createContentReport,
  createExportGrant,
  createPrivacyRequest,
  downloadPersonalDataExport,
  getAccountDeletionEligibility,
  getContentReportForAdmin,
  getMyPrivacyRequest,
  getPrivacyAdminQueueCounts,
  getPrivacyRequestForAdmin,
  listContentReportsForAdmin,
  listMyContentReports,
  listMyPrivacyRequests,
  listPrivacyRequestsForAdmin,
  retryPrivacyRequestExecution,
  updateContentReportForAdmin,
  updatePrivacyRequestForAdmin,
};
