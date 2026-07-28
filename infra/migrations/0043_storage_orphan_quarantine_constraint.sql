ALTER TABLE storage_orphan_quarantine_record
  DROP CONSTRAINT IF EXISTS chk_storage_orphan_quarantine_destination;

ALTER TABLE storage_orphan_quarantine_record
  ADD CONSTRAINT chk_storage_orphan_quarantine_destination CHECK (
    quarantine_reference ~ '^storage://(uploads|exports)/[.]quarantine/legacy-orphans/'
    AND char_length(quarantine_reference) BETWEEN 1 AND 2048
  );
