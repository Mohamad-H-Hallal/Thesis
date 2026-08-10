const { query } = require('../config/database');
const { AppError } = require('../middleware/error');
import { notifyProjectStatusChanged } from './workflowNotifications';

const publicVisibleStatuses = ['draft', 'active', 'paused', 'completed'] as const;
const projectScheduleReminderKinds = [
  'starts_tomorrow',
  'ends_tomorrow',
  'paused_ends_tomorrow',
] as const;

const projectStatusTransitions: Record<string, string[]> = {
  draft: ['active'],
  active: ['paused', 'completed'],
  paused: ['active', 'completed'],
  completed: ['active', 'paused', 'archived'],
  archived: ['completed'],
};

const assertProjectStatusTransition = (currentStatus: string, nextStatus: string): void => {
  const current = String(currentStatus).trim().toLowerCase();
  const next = String(nextStatus).trim().toLowerCase();

  if (current === next) {
    return;
  }

  const allowed = projectStatusTransitions[current as keyof typeof projectStatusTransitions] ?? [];
  if (!allowed.includes(next)) {
    throw new AppError(`Invalid project status transition from ${current} to ${next}`, 400);
  }
};

const todayIsoDate = (): string => {
  const now = new Date();
  const month = `${now.getMonth() + 1}`.padStart(2, '0');
  const day = `${now.getDate()}`.padStart(2, '0');
  return `${now.getFullYear()}-${month}-${day}`;
};

const normalizeProjectDateInput = (value: unknown): string | null => {
  if (value === undefined) {
    return null;
  }
  if (value === null) {
    return null;
  }
  if (value instanceof Date) {
    const month = `${value.getMonth() + 1}`.padStart(2, '0');
    const day = `${value.getDate()}`.padStart(2, '0');
    return `${value.getFullYear()}-${month}-${day}`;
  }
  const raw = String(value).trim();
  if (!raw) {
    return null;
  }
  return raw.slice(0, 10);
};

const resolveProjectScheduleForMutation = ({
  currentStatus,
  nextStatus,
  currentStartDate,
  currentEndDate,
  startDateProvided,
  endDateProvided,
  requestedStartDate,
  requestedEndDate,
}: {
  currentStatus: string;
  nextStatus: string;
  currentStartDate: unknown;
  currentEndDate: unknown;
  startDateProvided: boolean;
  endDateProvided: boolean;
  requestedStartDate?: unknown;
  requestedEndDate?: unknown;
}): {
  startDate: string | null;
  endDate: string | null;
} => {
  const today = todayIsoDate();
  let startDate = startDateProvided
    ? normalizeProjectDateInput(requestedStartDate)
    : normalizeProjectDateInput(currentStartDate);
  let endDate = endDateProvided
    ? normalizeProjectDateInput(requestedEndDate)
    : normalizeProjectDateInput(currentEndDate);

  if (nextStatus === 'draft' && startDate !== null && startDate < today) {
    throw new AppError('Draft projects must use a start date that is today or later.', 422);
  }

  if (nextStatus === 'active') {
    if (
      startDate === null ||
      startDate > today ||
      ['draft', 'completed', 'archived'].includes(currentStatus)
    ) {
      startDate = today;
    }
    if (
      !endDateProvided &&
      ['completed', 'archived'].includes(currentStatus) &&
      endDate !== null &&
      endDate <= today
    ) {
      endDate = null;
    }
  }

  if (nextStatus === 'paused') {
    if (startDate === null) {
      startDate = today;
    }
    if (
      !endDateProvided &&
      ['completed', 'archived'].includes(currentStatus) &&
      endDate !== null &&
      endDate <= today
    ) {
      endDate = null;
    }
  }

  if (nextStatus === 'completed') {
    if (endDate === null || endDate > today) {
      endDate = today;
    }
    if (startDate !== null && endDate < startDate) {
      throw new AppError(
        'Completed projects must use an end date on or after the start date.',
        422,
      );
    }
  }

  if (nextStatus === 'archived' && endDate === null) {
    endDate = normalizeProjectDateInput(currentEndDate) ?? today;
  }

  if (startDate !== null && endDate !== null && endDate < startDate) {
    throw new AppError('End date must be on or after the start date.', 422);
  }

  return { startDate, endDate };
};

const synchronizeProjectStatuses = async (
  projectId?: string,
  actorUserId?: string | null,
): Promise<void> => {
  const conditions = [
    `(status = 'draft' AND start_date IS NOT NULL AND start_date <= CURRENT_DATE AND (end_date IS NULL OR end_date >= CURRENT_DATE))`,
    `(status IN ('active', 'paused') AND end_date IS NOT NULL AND end_date <= CURRENT_DATE)`,
    `(status = 'draft' AND end_date IS NOT NULL AND end_date < CURRENT_DATE)`,
  ];

  const params: unknown[] = [];
  const projectClause = projectId ? 'AND id = $1' : '';
  if (projectId) {
    params.push(projectId);
  }

  const changedProjects = await query(
    `
      WITH candidates AS (
        SELECT id,
               status AS previous_status,
               CASE
                 WHEN status IN ('active', 'paused')
                   AND end_date IS NOT NULL
                   AND end_date <= CURRENT_DATE
                   THEN 'completed'::project_status
                 WHEN status = 'draft'
                   AND end_date IS NOT NULL
                   AND end_date < CURRENT_DATE
                   THEN 'completed'::project_status
                 WHEN status = 'draft'
                   AND start_date IS NOT NULL
                   AND start_date <= CURRENT_DATE
                   AND (end_date IS NULL OR end_date >= CURRENT_DATE)
                   THEN 'active'::project_status
                 ELSE status
               END AS next_status
        FROM project
        WHERE (${conditions.join(' OR ')})
        ${projectClause}
      )
      UPDATE project p
      SET status = candidates.next_status
      FROM candidates
      WHERE p.id = candidates.id
        AND p.status = candidates.previous_status
        AND candidates.next_status <> candidates.previous_status
      RETURNING p.id, p.name, candidates.previous_status, p.status
    `,
    params,
  );

  for (const project of changedProjects.rows as Array<{
    id: string;
    name: string;
    previous_status: string;
    status: string;
  }>) {
    await notifyProjectStatusChanged(query, {
      projectId: project.id,
      projectName: project.name,
      previousStatus: project.previous_status,
      status: project.status,
      actorUserId,
      eventKey: `project_status:scheduled:${project.id}:${project.previous_status}:${project.status}:${todayIsoDate()}`,
    });
  }

  await synchronizeProjectScheduleNotifications(projectId);
};

const synchronizeProjectScheduleNotifications = async (projectId?: string): Promise<void> => {
  const params: unknown[] = [];
  const projectFilter = projectId ? 'WHERE p.id = $1' : '';
  if (projectId) {
    params.push(projectId);
  }

  const [tomorrowResult, adminsResult, projectsResult] = await Promise.all([
    query(`SELECT TO_CHAR(CURRENT_DATE + INTERVAL '1 day', 'YYYY-MM-DD') AS tomorrow`),
    query(
      `SELECT id
       FROM "user"
       WHERE role = 'admin'
         AND is_active = TRUE`,
    ),
    query(
      `SELECT
          p.id,
          p.name,
          p.status,
          TO_CHAR(p.start_date, 'YYYY-MM-DD') AS start_date,
          TO_CHAR(p.end_date, 'YYYY-MM-DD') AS end_date
       FROM project p
       ${projectFilter}`,
      params,
    ),
  ]);

  const tomorrow = (tomorrowResult.rows[0] as { tomorrow?: string } | undefined)?.tomorrow;
  if (!tomorrow || adminsResult.rows.length === 0) {
    return;
  }

  for (const project of projectsResult.rows as Array<{
    id: string;
    name: string;
    status: string;
    start_date: string | null;
    end_date: string | null;
  }>) {
    const desiredKinds = new Set<string>();
    if (project.status === 'draft' && project.start_date === tomorrow) {
      desiredKinds.add('starts_tomorrow');
    }
    if (project.status === 'active' && project.end_date === tomorrow) {
      desiredKinds.add('ends_tomorrow');
    }
    if (project.status === 'paused' && project.end_date === tomorrow) {
      desiredKinds.add('paused_ends_tomorrow');
    }

    const staleKinds = projectScheduleReminderKinds.filter((kind) => !desiredKinds.has(kind));
    if (staleKinds.length > 0) {
      await query(
        `DELETE FROM notification
         WHERE type = 'assignment'
           AND metadata->>'project_id' = $1
           AND metadata->>'schedule_reminder_kind' = ANY($2::text[])`,
        [project.id, staleKinds],
      );
    }

    for (const kind of desiredKinds) {
      const title =
        kind === 'starts_tomorrow'
          ? 'Project starts tomorrow'
          : kind === 'paused_ends_tomorrow'
            ? 'Paused project reaches its end date tomorrow'
            : 'Project completes tomorrow';
      const message =
        kind === 'starts_tomorrow'
          ? `${project.name} starts tomorrow and will move into active collection.`
          : kind === 'paused_ends_tomorrow'
            ? `${project.name} is paused and reaches its end date tomorrow. Review the schedule if it should stay paused longer.`
            : `${project.name} reaches its end date tomorrow and will move into completed status.`;
      const metadata = JSON.stringify({
        project_id: project.id,
        project_name: project.name,
        schedule_reminder_kind: kind,
        target_date: kind === 'starts_tomorrow' ? project.start_date : project.end_date,
      });

      for (const admin of adminsResult.rows as Array<{ id: string }>) {
        await query(
          `INSERT INTO notification (user_id, type, title, message, metadata)
           SELECT $1, 'assignment'::notification_type, $2, $3, $4::jsonb
           WHERE NOT EXISTS (
             SELECT 1
             FROM notification
             WHERE user_id = $1
               AND type = 'assignment'
               AND metadata->>'project_id' = $5
               AND metadata->>'schedule_reminder_kind' = $6
               AND metadata->>'target_date' = $7
           )`,
          [
            admin.id,
            title,
            message,
            metadata,
            project.id,
            kind,
            kind === 'starts_tomorrow' ? project.start_date : project.end_date,
          ],
        );
      }
    }
  }
};

export {
  assertProjectStatusTransition,
  normalizeProjectDateInput,
  publicVisibleStatuses,
  projectStatusTransitions,
  resolveProjectScheduleForMutation,
  synchronizeProjectStatuses,
  synchronizeProjectScheduleNotifications,
  todayIsoDate,
};
