CREATE OR REPLACE FUNCTION trg_enforce_project_status_transition()
RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      RAISE EXCEPTION 'project.status must start at draft';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'draft' AND NEW.status = 'active' THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'active' AND NEW.status IN ('paused', 'completed') THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'paused' AND NEW.status IN ('active', 'completed') THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'completed' AND NEW.status IN ('active', 'paused', 'archived') THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'archived' AND NEW.status = 'completed' THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'Invalid project status transition from % to %',
    OLD.status,
    NEW.status;
END;
$$ LANGUAGE plpgsql;
