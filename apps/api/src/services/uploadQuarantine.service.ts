import { query } from '../config/database';
import type { MalwareScanResult } from './malwareScanner.service';

interface QueryExecutor {
  query: (
    sql: string,
    params?: unknown[],
  ) => Promise<{ rows: any[]; rowCount?: number | null }>;
}

interface QuarantinedUploadInput {
  uploadKind: 'gis_import' | 'ai_validation_photo' | 'category_icon' | 'feature_photo';
  storagePath: string;
  originalFilename: string;
  uploadedByUserId: string;
  projectId?: string | null;
  fileSizeBytes: number;
  checksumSha256: string;
  metadata?: Record<string, unknown>;
}

const recordQuarantinedUpload = async (input: QuarantinedUploadInput): Promise<string> => {
  const result = await query(
    `INSERT INTO upload_quarantine_record (
       upload_kind,
       storage_path,
       original_filename,
       uploaded_by_user_id,
       project_id,
       file_size_bytes,
       file_checksum_sha256,
       metadata
     ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
     RETURNING id`,
    [
      input.uploadKind,
      input.storagePath,
      input.originalFilename,
      input.uploadedByUserId,
      input.projectId ?? null,
      input.fileSizeBytes,
      input.checksumSha256,
      JSON.stringify(input.metadata ?? {}),
    ],
  );
  return String(result.rows[0].id);
};

const recordContentInspection = async ({
  quarantineId,
  detectedType,
  metadata,
}: {
  quarantineId: string;
  detectedType: string;
  metadata?: Record<string, unknown>;
}): Promise<void> => {
  await query(
    `UPDATE upload_quarantine_record
     SET detected_type = $2,
         metadata = metadata || $3::jsonb,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND disposition = 'quarantined'`,
    [quarantineId, detectedType, JSON.stringify(metadata ?? {})],
  );
};

const recordMalwareScan = async (
  quarantineId: string,
  result: MalwareScanResult,
): Promise<void> => {
  await query(
    `UPDATE upload_quarantine_record
     SET scan_status = $2,
         reason_code = CASE
           WHEN $2 = 'infected' THEN 'UPLOAD_MALWARE_DETECTED'
           WHEN $2 = 'unavailable' THEN 'UPLOAD_SCANNER_UNAVAILABLE'
           ELSE reason_code
         END,
         scanner_signature = $3,
         metadata = metadata || $4::jsonb,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND disposition = 'quarantined'`,
    [
      quarantineId,
      result.status,
      result.signature ?? null,
      JSON.stringify({
        malware_scanner: result.scanner,
        ...(result.reason ? { scanner_reason: result.reason } : {}),
      }),
    ],
  );
};

const keepUploadQuarantined = async (quarantineId: string, reasonCode: string): Promise<void> => {
  await query(
    `UPDATE upload_quarantine_record
     SET reason_code = $2,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND disposition = 'quarantined'`,
    [quarantineId, reasonCode],
  );
};

const releaseQuarantinedUpload = async ({
  executor,
  quarantineId,
  releasedPath,
}: {
  executor: QueryExecutor;
  quarantineId: string;
  releasedPath: string;
}): Promise<void> => {
  const result = await executor.query(
    `UPDATE upload_quarantine_record
     SET disposition = 'released',
         released_path = $2,
         released_at = CURRENT_TIMESTAMP,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1
       AND disposition = 'quarantined'
       AND scan_status IN ('clean', 'skipped')`,
    [quarantineId, releasedPath],
  );
  if (result.rowCount !== 1) {
    throw new Error('The quarantined upload could not be released safely.');
  }
};

export {
  keepUploadQuarantined,
  recordContentInspection,
  recordMalwareScan,
  recordQuarantinedUpload,
  releaseQuarantinedUpload,
};
