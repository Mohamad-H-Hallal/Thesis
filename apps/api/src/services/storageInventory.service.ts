import { createHash } from 'node:crypto';
import type { StorageAdapter, StorageBucket, StorageListEntry } from './storageAdapter.service';

interface QueryExecutor {
  query: (sql: string, params?: unknown[]) => Promise<{ rows: any[] }>;
}

type InventoryClassification =
  | 'referenced'
  | 'protected_legacy'
  | 'quarantine'
  | 'unreferenced'
  | 'unsafe_symlink';

interface InventoryReference {
  id: string;
  source: string;
  rowId: string;
  storedValue: string;
  candidates: string[];
  policyOnly: boolean;
}

interface InventoryFile {
  bucket: StorageBucket;
  key: string;
  reference: string;
  size: number | null;
  sha256: string | null;
  classification: InventoryClassification;
  referenceIds: string[];
}

interface MissingInventoryReference {
  id: string;
  source: string;
  rowId: string;
  storedValue: string;
  candidates: string[];
}

interface UnresolvedInventoryReference {
  id: string;
  source: string;
  rowId: string;
  storedValue: string;
  reason: 'outside_managed_storage' | 'invalid_media_identifier';
}

interface StorageInventoryReport {
  version: 1;
  generatedAt: string;
  readOnly: true;
  driver: string;
  roots: Array<{ bucket: StorageBucket; files: number; bytes: number }>;
  counts: Record<InventoryClassification | 'missing_reference' | 'unresolved_reference', number>;
  files: InventoryFile[];
  missingReferences: MissingInventoryReference[];
  unresolvedReferences: UnresolvedInventoryReference[];
}

const safeMediaUrl =
  /^\/?uploads\/(ai-validation|photos|category-icons)\/([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:jpe?g|png|gif|hei[cf]s?))$/i;
const safeSnapshotName =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:jpe?g|png|gif|hei[cf]s?)$/i;

const directReferenceRows = async (executor: QueryExecutor): Promise<any[]> => {
  const result = await executor.query(
    `SELECT source, row_id, stored_value
     FROM (
       SELECT 'photo.file_path'::text AS source, id::text AS row_id, file_path::text AS stored_value
       FROM photo
       WHERE file_path IS NOT NULL

       UNION ALL

       SELECT 'photo.thumbnail_path', id::text, thumbnail_path::text
       FROM photo
       WHERE thumbnail_path IS NOT NULL

       UNION ALL

       SELECT 'gis_import_job.file_path', id::text, file_path::text
       FROM gis_import_job
       WHERE file_path IS NOT NULL

       UNION ALL

       SELECT 'shapefile_export.file_path', id::text, file_path::text
       FROM shapefile_export
       WHERE file_path IS NOT NULL

       UNION ALL

       SELECT 'upload_quarantine_record.storage_path', id::text, storage_path::text
       FROM upload_quarantine_record
       WHERE disposition <> 'released' OR released_path IS NULL

       UNION ALL

       SELECT 'upload_quarantine_record.released_path', id::text, released_path::text
       FROM upload_quarantine_record
       WHERE released_path IS NOT NULL

       UNION ALL

       SELECT 'ai_output_layer.storage_path', id::text, storage_path::text
       FROM ai_output_layer
       WHERE storage_path IS NOT NULL
     ) AS stored_reference
     ORDER BY source, row_id, stored_value`,
  );
  return result.rows;
};

const mediaIdentifierRows = async (executor: QueryExecutor): Promise<any[]> => {
  const result = await executor.query(
    `SELECT source, row_id, stored_value
     FROM (
       SELECT
         'ai_prediction_feature_validation.photo_media_ids'::text AS source,
         validation.id::text AS row_id,
         media.media_url::text AS stored_value
       FROM ai_prediction_feature_validation AS validation
       CROSS JOIN LATERAL jsonb_array_elements_text(validation.photo_media_ids) AS media(media_url)

       UNION ALL

       SELECT
         'ai_prediction_validation_submission.evidence',
         submission.id::text,
         media.media_url::text
       FROM ai_prediction_validation_submission AS submission
       CROSS JOIN LATERAL jsonb_array_elements_text(
         CASE
           WHEN jsonb_typeof(submission.evidence->'photo_media_ids') = 'array'
             THEN submission.evidence->'photo_media_ids'
           WHEN jsonb_typeof(submission.evidence->'photos') = 'array'
             THEN submission.evidence->'photos'
           ELSE '[]'::jsonb
         END
       ) AS media(media_url)

       UNION ALL

       SELECT
         'project_category.icon_url',
         category.id::text,
         category.icon_url::text
       FROM project_category AS category
       WHERE category.icon_url IS NOT NULL
     ) AS media_reference
     ORDER BY source, row_id, stored_value`,
  );
  return result.rows;
};

const snapshotRows = async (executor: QueryExecutor): Promise<any[]> => {
  const result = await executor.query(
    `SELECT storage_name
     FROM legacy_ai_validation_media_snapshot
     ORDER BY storage_name`,
  );
  return result.rows;
};

const referenceId = (source: string, rowId: string, index: number): string =>
  `${source}:${rowId}:${index}`;

const loadInventoryReferences = async (
  executor: QueryExecutor,
  adapter: StorageAdapter,
): Promise<{
  references: InventoryReference[];
  unresolved: UnresolvedInventoryReference[];
}> => {
  const references: InventoryReference[] = [];
  const unresolved: UnresolvedInventoryReference[] = [];
  const [directRows, mediaRows, legacySnapshotRows] = await Promise.all([
    directReferenceRows(executor),
    mediaIdentifierRows(executor),
    snapshotRows(executor),
  ]);

  directRows.forEach((row, index) => {
    const source = String(row.source);
    const rowId = String(row.row_id);
    const storedValue = String(row.stored_value);
    const id = referenceId(source, rowId, index);
    const resolved = adapter.resolve(storedValue);
    if (!resolved) {
      unresolved.push({
        id,
        source,
        rowId,
        storedValue,
        reason: 'outside_managed_storage',
      });
      return;
    }
    references.push({
      id,
      source,
      rowId,
      storedValue,
      candidates: [resolved.reference],
      policyOnly: false,
    });
  });

  mediaRows.forEach((row, index) => {
    const source = String(row.source);
    const rowId = String(row.row_id);
    const storedValue = String(row.stored_value);
    const id = referenceId(source, rowId, index);
    const matched = safeMediaUrl.exec(storedValue);
    if (!matched) {
      unresolved.push({
        id,
        source,
        rowId,
        storedValue,
        reason: 'invalid_media_identifier',
      });
      return;
    }
    const directory = matched[1].toLowerCase();
    const name = matched[2];
    const keys =
      directory === 'ai-validation'
        ? [`.private/ai-validation/${name}`, `ai-validation/${name}`]
        : [`${directory}/${name}`];
    references.push({
      id,
      source,
      rowId,
      storedValue,
      candidates: keys.map((key) => adapter.reference('uploads', key)),
      policyOnly: false,
    });
  });

  legacySnapshotRows.forEach((row, index) => {
    const storedValue = String(row.storage_name ?? '');
    const source = 'legacy_ai_validation_media_snapshot.storage_name';
    const rowId = storedValue;
    const id = referenceId(source, rowId, index);
    if (!safeSnapshotName.test(storedValue)) {
      unresolved.push({
        id,
        source,
        rowId,
        storedValue,
        reason: 'invalid_media_identifier',
      });
      return;
    }
    references.push({
      id,
      source,
      rowId,
      storedValue,
      candidates: [adapter.reference('uploads', `photos/${storedValue}`)],
      policyOnly: true,
    });
  });

  return { references, unresolved };
};

const hashInventoryFiles = async (
  adapter: StorageAdapter,
  entries: StorageListEntry[],
  concurrency = 8,
): Promise<Map<string, string>> => {
  const checksums = new Map<string, string>();
  const regularFiles = entries.filter((entry) => entry.kind === 'file');
  let cursor = 0;
  const worker = async (): Promise<void> => {
    while (cursor < regularFiles.length) {
      const index = cursor;
      cursor += 1;
      const entry = regularFiles[index];
      const info = await adapter.info(entry.reference, [entry.bucket]);
      checksums.set(entry.reference, info.sha256);
    }
  };
  await Promise.all(
    Array.from({ length: Math.max(1, Math.min(concurrency, regularFiles.length || 1)) }, worker),
  );
  return checksums;
};

const createStorageInventory = async ({
  executor,
  adapter,
  includeChecksums = true,
}: {
  executor: QueryExecutor;
  adapter: StorageAdapter;
  includeChecksums?: boolean;
}): Promise<StorageInventoryReport> => {
  const entries = (
    await Promise.all(
      (['uploads', 'exports'] as const).map((bucket) => adapter.list(bucket)),
    )
  ).flat();
  const availableReferences = new Set(entries.map((entry) => entry.reference));
  const { references, unresolved } = await loadInventoryReferences(executor, adapter);
  const liveReferenceIds = new Map<string, string[]>();
  const policyReferenceIds = new Map<string, string[]>();
  const missingReferences: MissingInventoryReference[] = [];

  for (const reference of references) {
    const existingCandidate = reference.candidates.find((candidate) =>
      availableReferences.has(candidate),
    );
    if (!existingCandidate) {
      missingReferences.push({
        id: reference.id,
        source: reference.source,
        rowId: reference.rowId,
        storedValue: reference.storedValue,
        candidates: reference.candidates,
      });
      continue;
    }
    const map = reference.policyOnly ? policyReferenceIds : liveReferenceIds;
    map.set(existingCandidate, [...(map.get(existingCandidate) ?? []), reference.id]);
  }

  const checksums = includeChecksums
    ? await hashInventoryFiles(adapter, entries)
    : new Map<string, string>();
  const files = entries.map((entry): InventoryFile => {
    const live = liveReferenceIds.get(entry.reference) ?? [];
    const policy = policyReferenceIds.get(entry.reference) ?? [];
    let classification: InventoryClassification;
    if (entry.kind === 'symlink') {
      classification = 'unsafe_symlink';
    } else if (live.length > 0) {
      classification = 'referenced';
    } else if (policy.length > 0) {
      classification = 'protected_legacy';
    } else if (
      entry.key.startsWith('.quarantine/') ||
      entry.key.startsWith('.private/quarantine/')
    ) {
      classification = 'quarantine';
    } else {
      classification = 'unreferenced';
    }
    return {
      bucket: entry.bucket,
      key: entry.key,
      reference: entry.reference,
      size: entry.size,
      sha256: checksums.get(entry.reference) ?? null,
      classification,
      referenceIds: [...live, ...policy].sort(),
    };
  });

  const classifications: InventoryClassification[] = [
    'referenced',
    'protected_legacy',
    'quarantine',
    'unreferenced',
    'unsafe_symlink',
  ];
  const counts = Object.fromEntries(
    classifications.map((classification) => [
      classification,
      files.filter((file) => file.classification === classification).length,
    ]),
  ) as StorageInventoryReport['counts'];
  counts.missing_reference = missingReferences.length;
  counts.unresolved_reference = unresolved.length;

  const roots = (['uploads', 'exports'] as const).map((bucket) => {
    const bucketFiles = files.filter((file) => file.bucket === bucket && file.size !== null);
    return {
      bucket,
      files: bucketFiles.length,
      bytes: bucketFiles.reduce((sum, file) => sum + Number(file.size ?? 0), 0),
    };
  });

  return {
    version: 1,
    generatedAt: new Date().toISOString(),
    readOnly: true,
    driver: adapter.driver,
    roots,
    counts,
    files,
    missingReferences,
    unresolvedReferences: unresolved,
  };
};

const inventoryManifestHash = (report: StorageInventoryReport): string => {
  const stable = JSON.stringify({
    version: report.version,
    roots: report.roots,
    files: report.files.map((file) => ({
      reference: file.reference,
      size: file.size,
      sha256: file.sha256,
      classification: file.classification,
      referenceIds: file.referenceIds,
    })),
    missingReferences: report.missingReferences,
    unresolvedReferences: report.unresolvedReferences,
  });
  return createHash('sha256').update(stable).digest('hex');
};

export {
  createStorageInventory,
  inventoryManifestHash,
  loadInventoryReferences,
  type InventoryClassification,
  type InventoryFile,
  type InventoryReference,
  type MissingInventoryReference,
  type StorageInventoryReport,
  type UnresolvedInventoryReference,
};
