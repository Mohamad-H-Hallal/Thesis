DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'ai_output_layer_status'
      AND e.enumlabel = 'approved'
  ) THEN
    ALTER TYPE ai_output_layer_status ADD VALUE 'approved' AFTER 'ready_for_review';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'ai_review_decision_type'
      AND e.enumlabel = 'keep_draft'
  ) THEN
    ALTER TYPE ai_review_decision_type ADD VALUE 'keep_draft' AFTER 'needs_more_data';
  END IF;
END $$;
