-- Prevent concurrent or repeated open reports for the same item by one reporter.

CREATE UNIQUE INDEX uq_content_report_open_target_per_reporter
  ON content_report (reporter_user_id, entity_type, entity_id)
  WHERE status IN ('submitted', 'in_review');
