import type { PoolClient, QueryResult, QueryResultRow } from 'pg';
import { query } from '../config/database';

type QueryExecutor = Pick<PoolClient, 'query'> | typeof query;

type AiNotificationInput = {
  userId: string;
  eventKey: string;
  title: string;
  message: string;
  metadata: Record<string, unknown>;
};

const runQuery = async <T extends QueryResultRow = QueryResultRow>(
  executor: QueryExecutor,
  text: string,
  params: unknown[] = [],
): Promise<QueryResult<T>> => {
  if (typeof executor === 'function') {
    return executor<T>(text, params);
  }
  return executor.query<T>(text, params);
};

const createAiNotification = async (
  executor: QueryExecutor,
  input: AiNotificationInput,
): Promise<boolean> => {
  const metadata = {
    ...input.metadata,
    event_key: input.eventKey,
  };
  const result = await runQuery(
    executor,
    `INSERT INTO notification (user_id, type, title, message, metadata)
     SELECT $1, 'ai_event'::notification_type, $2, $3, $4::jsonb
     WHERE NOT EXISTS (
       SELECT 1
       FROM notification
       WHERE user_id = $1
         AND type = 'ai_event'
         AND metadata->>'event_key' = $5
     )
     ON CONFLICT DO NOTHING
     RETURNING id`,
    [input.userId, input.title, input.message, JSON.stringify(metadata), input.eventKey],
  );
  return (result.rowCount ?? 0) > 0;
};

const notifyAiRunStatus = async (runId: string): Promise<void> => {
  const result = await query<{
    id: string;
    project_id: string;
    project_name: string;
    display_name: string | null;
    status: string;
    started_by: string | null;
    message: string | null;
  }>(
    `SELECT ar.id,
            ar.project_id,
            p.name AS project_name,
            ar.display_name,
            ar.status,
            ar.started_by,
            ar.message
     FROM ai_run ar
     JOIN project p ON p.id = ar.project_id
     WHERE ar.id = $1`,
    [runId],
  );
  const run = result.rows[0];
  if (!run?.started_by) {
    return;
  }

  const notification =
    run.status === 'completed' || run.status === 'ready_for_review'
      ? {
          eventStatus: 'ready_for_review',
          title: 'AI run ready for review',
          message: `${run.display_name ?? 'AI processing'} for ${run.project_name} finished and is ready for review.`,
        }
      : run.status === 'failed'
        ? {
            eventStatus: 'failed',
            title: 'AI run failed',
            message: `${run.display_name ?? 'AI processing'} for ${run.project_name} failed. Open the AI run to review the details and retry when ready.`,
          }
        : run.status === 'cancelled'
          ? {
              eventStatus: 'cancelled',
              title: 'AI run cancelled',
              message: `${run.display_name ?? 'AI processing'} for ${run.project_name} was cancelled.`,
            }
          : null;

  if (!notification) {
    return;
  }

  await createAiNotification(query, {
    userId: run.started_by,
    eventKey: `ai_run:${run.id}:${notification.eventStatus}`,
    title: notification.title,
    message: notification.message,
    metadata: {
      project_id: run.project_id,
      project_name: run.project_name,
      ai_run_id: run.id,
      ai_run_status: run.status,
    },
  });
};

const notifyAiValidationTaskAssigned = async (
  executor: QueryExecutor,
  task: Record<string, any>,
): Promise<void> => {
  const assignedTo = typeof task.assigned_to === 'string' ? task.assigned_to : null;
  const projectId = typeof task.project_id === 'string' ? task.project_id : null;
  if (!assignedTo || !projectId || typeof task.id !== 'string') {
    return;
  }
  const projectResult = await runQuery<{ name: string }>(
    executor,
    `SELECT name FROM project WHERE id = $1`,
    [projectId],
  );
  const projectName = projectResult.rows[0]?.name ?? 'your project';
  await createAiNotification(executor, {
    userId: assignedTo,
    eventKey: `ai_validation_task:${task.id}:assigned:${assignedTo}`,
    title: 'AI validation task assigned',
    message: `An AI prediction validation task was assigned to you in ${projectName}.`,
    metadata: {
      project_id: projectId,
      project_name: projectName,
      ai_run_id: task.ai_run_id ?? null,
      ai_validation_task_id: task.id,
      ai_prediction_feature_id: task.ai_prediction_feature_id ?? null,
      task_status: task.status,
    },
  });
};

const notifyAdminsAboutAiValidationSubmission = async (
  executor: QueryExecutor,
  {
    projectId,
    taskId,
    predictionId,
    submissionId,
    submittedBy,
  }: {
    projectId: string;
    taskId?: string | null;
    predictionId: string;
    submissionId: string;
    submittedBy: string;
  },
): Promise<void> => {
  const contextResult = await runQuery<{
    project_name: string;
    contributor_name: string;
  }>(
    executor,
    `SELECT p.name AS project_name, u.full_name AS contributor_name
     FROM project p
     JOIN "user" u ON u.id = $2
     WHERE p.id = $1`,
    [projectId, submittedBy],
  );
  const context = contextResult.rows[0];
  if (!context) {
    return;
  }
  const admins = await runQuery<{ id: string }>(
    executor,
    `SELECT id FROM "user" WHERE role = 'admin' AND is_active = TRUE`,
  );
  for (const admin of admins.rows) {
    if (admin.id === submittedBy) {
      continue;
    }
    await createAiNotification(executor, {
      userId: admin.id,
      eventKey: `ai_validation_submission:${submissionId}`,
      title: 'AI validation awaiting review',
      message: `${context.contributor_name} submitted AI prediction validation evidence in ${context.project_name}.`,
      metadata: {
        project_id: projectId,
        project_name: context.project_name,
        ai_validation_task_id: taskId ?? null,
        ai_prediction_feature_id: predictionId,
        ai_validation_submission_id: submissionId,
        submitted_by_user_id: submittedBy,
        review_status: 'pending',
      },
    });
  }
};

const notifyAiValidationTaskReviewed = async (
  executor: QueryExecutor,
  task: Record<string, any>,
  submissionId: string,
  reviewedContributorId?: string | null,
): Promise<void> => {
  const recipient =
    typeof reviewedContributorId === 'string'
      ? reviewedContributorId
      : typeof task.latest_submission?.submitted_by === 'string'
        ? task.latest_submission.submitted_by
        : typeof task.assigned_to === 'string'
          ? task.assigned_to
          : null;
  if (!recipient || typeof task.id !== 'string' || typeof task.project_id !== 'string') {
    return;
  }
  const projectResult = await runQuery<{ name: string }>(
    executor,
    `SELECT name FROM project WHERE id = $1`,
    [task.project_id],
  );
  const projectName = projectResult.rows[0]?.name ?? 'your project';
  const accepted = task.review_decision === 'accepted';
  await createAiNotification(executor, {
    userId: recipient,
    eventKey: `ai_validation_submission:${submissionId}:reviewed`,
    title: accepted ? 'AI validation accepted' : 'AI validation needs attention',
    message: accepted
      ? `Your AI prediction validation in ${projectName} was accepted.`
      : `Your AI prediction validation in ${projectName} was rejected. Open the task to review the reason.`,
    metadata: {
      project_id: task.project_id,
      project_name: projectName,
      ai_run_id: task.ai_run_id ?? null,
      ai_validation_task_id: task.id,
      ai_prediction_feature_id: task.ai_prediction_feature_id ?? null,
      ai_validation_submission_id: submissionId,
      review_status: task.review_decision,
    },
  });
};

const notifyAiPredictionValidationSubmitted = async (
  executor: QueryExecutor,
  {
    projectId,
    predictionId,
    submittedBy,
  }: {
    projectId: string;
    predictionId: string;
    submittedBy: string;
  },
): Promise<void> => {
  const validationResult = await runQuery<{ id: string }>(
    executor,
    `SELECT id
     FROM ai_prediction_feature_validation
     WHERE project_id = $1
       AND ai_prediction_feature_id = $2
       AND contributor_user_id = $3
     ORDER BY created_at DESC
     LIMIT 1`,
    [projectId, predictionId, submittedBy],
  );
  const validationId = validationResult.rows[0]?.id;
  if (!validationId) {
    return;
  }
  await notifyAdminsAboutAiValidationSubmission(executor, {
    projectId,
    predictionId,
    submissionId: validationId,
    submittedBy,
  });
};

const notifyAiPredictionReviewed = async (
  executor: QueryExecutor,
  {
    projectId,
    predictionId,
    reviewStatus,
  }: {
    projectId: string;
    predictionId: string;
    reviewStatus: string;
  },
): Promise<void> => {
  const result = await runQuery<{ user_id: string; project_name: string }>(
    executor,
    `SELECT DISTINCT v.contributor_user_id AS user_id, p.name AS project_name
     FROM ai_prediction_feature_validation v
     JOIN project p ON p.id = v.project_id
     WHERE v.project_id = $1
       AND v.ai_prediction_feature_id = $2`,
    [projectId, predictionId],
  );
  for (const row of result.rows) {
    await createAiNotification(executor, {
      userId: row.user_id,
      eventKey: `ai_prediction:${predictionId}:review:${reviewStatus}:${row.user_id}`,
      title:
        reviewStatus === 'approved'
          ? 'AI prediction validation approved'
          : reviewStatus === 'rejected'
            ? 'AI prediction validation rejected'
            : 'More AI validation requested',
      message:
        reviewStatus === 'approved'
          ? `The AI prediction you validated in ${row.project_name} was approved.`
          : reviewStatus === 'rejected'
            ? `The AI prediction you validated in ${row.project_name} was rejected.`
            : `More validation is needed for an AI prediction in ${row.project_name}.`,
      metadata: {
        project_id: projectId,
        project_name: row.project_name,
        ai_prediction_feature_id: predictionId,
        review_status: reviewStatus,
      },
    });
  }
};

const notifyProjectAiPublication = async (
  executor: QueryExecutor,
  {
    projectId,
    runId,
    layerId,
    published,
    actorUserId,
  }: {
    projectId: string;
    runId: string;
    layerId: string;
    published: boolean;
    actorUserId: string;
  },
): Promise<void> => {
  const recipients = await runQuery<{ user_id: string; project_name: string }>(
    executor,
    `SELECT DISTINCT recipients.user_id, p.name AS project_name
     FROM project p
     CROSS JOIN LATERAL (
       SELECT p.created_by_user_id AS user_id
       UNION
       SELECT pa.user_id
       FROM project_assignment pa
       WHERE pa.project_id = p.id
         AND pa.status = 'approved'
     ) recipients
     JOIN "user" u ON u.id = recipients.user_id AND u.is_active = TRUE
     WHERE p.id = $1`,
    [projectId],
  );
  for (const recipient of recipients.rows) {
    if (recipient.user_id === actorUserId) {
      continue;
    }
    await createAiNotification(executor, {
      userId: recipient.user_id,
      eventKey: `ai_layer:${layerId}:${published ? 'published' : 'unpublished'}`,
      title: published ? 'AI map layer published' : 'AI map layer unpublished',
      message: published
        ? `A reviewed AI classification layer is now available in ${recipient.project_name}.`
        : `The AI classification layer for ${recipient.project_name} is no longer published.`,
      metadata: {
        project_id: projectId,
        project_name: recipient.project_name,
        ai_run_id: runId,
        ai_output_layer_id: layerId,
        publication_status: published ? 'published' : 'unpublished',
      },
    });
  }
};

const notifyAiRunReviewed = async (
  executor: QueryExecutor,
  {
    runId,
    action,
    actorUserId,
  }: {
    runId: string;
    action: string;
    actorUserId: string;
  },
): Promise<void> => {
  const result = await runQuery<{
    project_id: string;
    project_name: string;
    display_name: string | null;
    started_by: string | null;
  }>(
    executor,
    `SELECT ar.project_id, p.name AS project_name, ar.display_name, ar.started_by
     FROM ai_run ar
     JOIN project p ON p.id = ar.project_id
     WHERE ar.id = $1`,
    [runId],
  );
  const run = result.rows[0];
  if (!run?.started_by || run.started_by === actorUserId) {
    return;
  }
  const titles: Record<string, string> = {
    approve_for_publication: 'AI run approved for publication',
    reject: 'AI run rejected',
    request_more_data: 'More AI training data requested',
    keep_draft: 'AI run kept as draft',
  };
  await createAiNotification(executor, {
    userId: run.started_by,
    eventKey: `ai_run:${runId}:review:${action}`,
    title: titles[action] ?? 'AI run review updated',
    message: `${run.display_name ?? 'AI run'} for ${run.project_name} received a review decision.`,
    metadata: {
      project_id: run.project_id,
      project_name: run.project_name,
      ai_run_id: runId,
      review_action: action,
    },
  });
};

export {
  createAiNotification,
  notifyAdminsAboutAiValidationSubmission,
  notifyAiPredictionReviewed,
  notifyAiPredictionValidationSubmitted,
  notifyAiRunReviewed,
  notifyAiRunStatus,
  notifyAiValidationTaskAssigned,
  notifyAiValidationTaskReviewed,
  notifyProjectAiPublication,
};
