ALTER TABLE ai_prediction_validation_task
  DROP CONSTRAINT IF EXISTS chk_ai_prediction_validation_task_assignee;

ALTER TABLE ai_prediction_validation_task
  ADD CONSTRAINT chk_ai_prediction_validation_task_assignee CHECK (
    status NOT IN ('assigned', 'in_progress')
    OR assigned_to IS NOT NULL
  );

CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_prediction_validation_submission_active_contributor
  ON ai_prediction_validation_submission(validation_task_id, submitted_by)
  WHERE status = 'submitted';
