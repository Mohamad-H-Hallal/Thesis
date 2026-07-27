ALTER TABLE offline_sync_receipt
  DROP CONSTRAINT IF EXISTS chk_offline_sync_receipt_operation;

ALTER TABLE offline_sync_receipt
  ADD CONSTRAINT chk_offline_sync_receipt_operation
  CHECK (
    operation IN ('create', 'update', 'submit', 'batch_create', 'photo_upload', 'offline_bundle')
  );
