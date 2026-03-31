const { query } = require('../config/database');
const { AppError } = require('../middleware/error');

const viewerVisibleStatuses = ['active', 'paused', 'completed'] as const;

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

  const allowed =
    projectStatusTransitions[current as keyof typeof projectStatusTransitions] ?? [];
  if (!allowed.includes(next)) {
    throw new AppError(
      `Invalid project status transition from ${current} to ${next}`,
      400,
    );
  }
};

const synchronizeProjectStatuses = async (projectId?: string): Promise<void> => {
  const conditions = [
    `(status = 'draft' AND start_date IS NOT NULL AND start_date <= CURRENT_DATE AND (end_date IS NULL OR end_date >= CURRENT_DATE))`,
    `(status IN ('draft', 'active', 'paused') AND end_date IS NOT NULL AND end_date < CURRENT_DATE)`,
  ];

  const params: unknown[] = [];
  const projectClause = projectId ? 'AND id = $1' : '';
  if (projectId) {
    params.push(projectId);
  }

  await query(
    `
      UPDATE project
      SET status = CASE
        WHEN status IN ('draft', 'active', 'paused')
          AND end_date IS NOT NULL
          AND end_date < CURRENT_DATE
          THEN 'completed'::project_status
        WHEN status = 'draft'
          AND start_date IS NOT NULL
          AND start_date <= CURRENT_DATE
          AND (end_date IS NULL OR end_date >= CURRENT_DATE)
          THEN 'active'::project_status
        ELSE status
      END
      WHERE (${conditions.join(' OR ')})
      ${projectClause}
    `,
    params,
  );
};

export {
  assertProjectStatusTransition,
  projectStatusTransitions,
  synchronizeProjectStatuses,
  viewerVisibleStatuses,
};
