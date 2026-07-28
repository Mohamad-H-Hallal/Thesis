import { createHash } from 'node:crypto';
import type { PoolClient } from 'pg';
import type { StorageAdapter, StorageBucket } from './storageAdapter.service';
import {
  createStorageInventory,
  inventoryManifestHash,
  loadInventoryReferences,
} from './storageInventory.service';

interface QueryResult {
  rows: any[];
  rowCount?: number | null;
}

interface ReconciliationDatabase {
  query: (sql: string, params?: unknown[]) => Promise<QueryResult>;
  transaction: <T>(callback: (client: PoolClient) => Promise<T>) => Promise<T>;
}

type MigratableObjectKind =
  | 'feature_photo'
  | 'feature_thumbnail'
  | 'gis_import'
  | 'export_file';

interface StorageMigrationItem {
  objectKind: MigratableObjectKind;
  referenceTable: 'photo' | 'gis_import_job' | 'shapefile_export';
  referenceColumn: 'file_path' | 'thumbnail_path';
  referenceRowId: string;
  sourceReference: string;
  destinationKey: string;
  expectedSizeBytes: number;
  expectedSha256: string;
}

interface StorageMigrationManifest {
  version: 1;
  operation: 'copy_verify_switch';
  approvedBy: string;
  approvedAt: string;
  rollbackRetentionDays: number;
  items: StorageMigrationItem[];
}

interface ReviewedOrphanItem {
  sourceReference: string;
  expectedSizeBytes: number;
  expectedSha256: string;
  reviewReason?: string;
}

interface ReviewedOrphanManifest {
  version: 1;
  operation: 'quarantine_reviewed_orphans';
  inventoryManifestSha256: string;
  reviewedBy: string;
  reviewedAt: string;
  reviewReason: string;
  items: ReviewedOrphanItem[];
}

interface MigrationExecutionResult {
  manifestSha256: string;
  switched: number;
  alreadySwitched: number;
}

interface MigrationRollbackResult {
  manifestSha256: string;
  rolledBack: number;
  alreadyRolledBack: number;
}

interface OrphanQuarantineResult {
  manifestSha256: string;
  quarantined: number;
  resumed: number;
}

interface MigrationPreflightResult {
  manifestSha256: string;
  sourceVerified: number;
  destinationExisting: number;
  alreadySwitched: number;
}

interface OrphanPreflightResult {
  manifestSha256: string;
  inventoryManifestSha256: string;
  verifiedUnreferenced: number;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const sha256Pattern = /^[0-9a-f]{64}$/;

const hasExactKeys = (
  value: unknown,
  required: readonly string[],
  optional: readonly string[] = [],
): value is Record<string, unknown> => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }
  const keys = Object.keys(value);
  const allowed = new Set([...required, ...optional]);
  return (
    required.every((key) => Object.prototype.hasOwnProperty.call(value, key)) &&
    keys.every((key) => allowed.has(key))
  );
};

const safeHumanText = (value: unknown, maximumLength: number): boolean => {
  if (typeof value !== 'string' || value.length < 1 || value.length > maximumLength) {
    return false;
  }
  return !Array.from(value).some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint <= 0x1f || codePoint === 0x7f;
  });
};

const migrationTargets: Record<
  MigratableObjectKind,
  {
    table: StorageMigrationItem['referenceTable'];
    column: StorageMigrationItem['referenceColumn'];
    bucket: StorageBucket;
    prefix: string;
  }
> = {
  feature_photo: {
    table: 'photo',
    column: 'file_path',
    bucket: 'uploads',
    prefix: '.private/feature-photos/',
  },
  feature_thumbnail: {
    table: 'photo',
    column: 'thumbnail_path',
    bucket: 'uploads',
    prefix: '.private/feature-thumbnails/',
  },
  gis_import: {
    table: 'gis_import_job',
    column: 'file_path',
    bucket: 'uploads',
    prefix: '.private/imports/',
  },
  export_file: {
    table: 'shapefile_export',
    column: 'file_path',
    bucket: 'exports',
    prefix: 'completed/',
  },
};

const stableJson = (value: unknown): string => {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(',')}]`;
  }
  const record = value as Record<string, unknown>;
  return `{${Object.keys(record)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`)
    .join(',')}}`;
};

const manifestHash = (manifest: unknown): string =>
  createHash('sha256').update(stableJson(manifest)).digest('hex');

const safeErrorCode = (error: unknown): string => {
  const candidate = String((error as { code?: unknown })?.code ?? 'STORAGE_RECONCILIATION_FAILED')
    .toUpperCase()
    .replace(/[^A-Z0-9_]/g, '_')
    .slice(0, 64);
  return candidate || 'STORAGE_RECONCILIATION_FAILED';
};

const validReviewDate = (value: unknown): Date => {
  if (typeof value !== 'string') {
    throw new Error('Review timestamp must be a canonical UTC timestamp.');
  }
  const date = new Date(String(value ?? ''));
  if (
    Number.isNaN(date.getTime()) ||
    date.toISOString() !== value ||
    date.getTime() > Date.now() + 5 * 60 * 1000 ||
    date.getTime() < Date.now() - 180 * 24 * 60 * 60 * 1000
  ) {
    throw new Error('Review timestamp must be valid, recent, and not in the future.');
  }
  return date;
};

const validateMigrationManifest = (
  manifest: StorageMigrationManifest,
  adapter: StorageAdapter,
  options: { requireRecentReview?: boolean } = {},
): { hash: string; destinations: Map<StorageMigrationItem, string> } => {
  const manifestKeys = [
    'version',
    'operation',
    'approvedBy',
    'approvedAt',
    'rollbackRetentionDays',
    'items',
  ] as const;
  if (
    !hasExactKeys(manifest, manifestKeys) ||
    manifest?.version !== 1 ||
    manifest.operation !== 'copy_verify_switch' ||
    !safeHumanText(manifest.approvedBy, 200) ||
    typeof manifest.approvedAt !== 'string' ||
    !Number.isSafeInteger(manifest.rollbackRetentionDays) ||
    manifest.rollbackRetentionDays < 7 ||
    manifest.rollbackRetentionDays > 3650 ||
    !Array.isArray(manifest.items) ||
    manifest.items.length === 0 ||
    manifest.items.length > 10000
  ) {
    throw new Error('Storage migration manifest is invalid.');
  }
  const approvedAt = new Date(String(manifest.approvedAt ?? ''));
  if (
    Number.isNaN(approvedAt.getTime()) ||
    approvedAt.toISOString() !== manifest.approvedAt ||
    approvedAt.getTime() > Date.now() + 5 * 60 * 1000
  ) {
    throw new Error('Storage migration approval timestamp is invalid or in the future.');
  }
  if (options.requireRecentReview !== false) {
    validReviewDate(manifest.approvedAt);
  }

  const identities = new Set<string>();
  const destinationReferences = new Set<string>();
  const destinations = new Map<StorageMigrationItem, string>();
  for (const item of manifest.items) {
    if (
      !hasExactKeys(item, [
        'objectKind',
        'referenceTable',
        'referenceColumn',
        'referenceRowId',
        'sourceReference',
        'destinationKey',
        'expectedSizeBytes',
        'expectedSha256',
      ])
    ) {
      throw new Error('Storage migration item is invalid or targets a disallowed reference.');
    }
    const target = migrationTargets[item.objectKind];
    if (
      !target ||
      item.referenceTable !== target.table ||
      item.referenceColumn !== target.column ||
      !uuidPattern.test(item.referenceRowId) ||
      typeof item.sourceReference !== 'string' ||
      item.sourceReference.length === 0 ||
      item.sourceReference.length > 2048 ||
      !Number.isSafeInteger(item.expectedSizeBytes) ||
      item.expectedSizeBytes < 1 ||
      !sha256Pattern.test(item.expectedSha256) ||
      typeof item.destinationKey !== 'string' ||
      !item.destinationKey.startsWith(target.prefix)
    ) {
      throw new Error('Storage migration item is invalid or targets a disallowed reference.');
    }
    const identity = `${target.table}:${target.column}:${item.referenceRowId}`;
    if (identities.has(identity)) {
      throw new Error('Storage migration manifest contains a duplicate database reference.');
    }
    identities.add(identity);
    const destination = adapter.reference(target.bucket, item.destinationKey);
    if (destinationReferences.has(destination)) {
      throw new Error('Storage migration manifest contains a duplicate destination.');
    }
    destinationReferences.add(destination);
    destinations.set(item, destination);
  }
  return { hash: manifestHash(manifest), destinations };
};

const loadMigrationRecord = async (
  database: Pick<ReconciliationDatabase, 'query'>,
  item: StorageMigrationItem,
): Promise<any | null> => {
  const result = await database.query(
    `SELECT *
     FROM storage_object_migration
     WHERE reference_table = $1
       AND reference_column = $2
       AND reference_row_id = $3`,
    [item.referenceTable, item.referenceColumn, item.referenceRowId],
  );
  return result.rows[0] ?? null;
};

const assertMatchingMigrationRecord = ({
  record,
  item,
  destinationReference,
  expectedManifestHash,
}: {
  record: any;
  item: StorageMigrationItem;
  destinationReference: string;
  expectedManifestHash: string;
}): void => {
  if (
    record.manifest_sha256 !== expectedManifestHash ||
    record.source_reference !== item.sourceReference ||
    record.destination_reference !== destinationReference ||
    Number(record.source_size_bytes) !== item.expectedSizeBytes ||
    record.source_sha256 !== item.expectedSha256
  ) {
    throw new Error('An existing migration record conflicts with the reviewed manifest.');
  }
};

const preflightStorageMigration = async ({
  manifest,
  adapter,
  database,
}: {
  manifest: StorageMigrationManifest;
  adapter: StorageAdapter;
  database: Pick<ReconciliationDatabase, 'query'>;
}): Promise<MigrationPreflightResult> => {
  const { hash, destinations } = validateMigrationManifest(manifest, adapter);
  let destinationExisting = 0;
  let alreadySwitched = 0;
  for (const item of manifest.items) {
    const destinationReference = destinations.get(item) as string;
    const source = await adapter.info(item.sourceReference);
    if (source.size !== item.expectedSizeBytes || source.sha256 !== item.expectedSha256) {
      throw new Error('Migration source does not match the reviewed size and checksum.');
    }
    const current = await database.query(
      `SELECT ${item.referenceColumn} AS current_reference
       FROM ${item.referenceTable}
       WHERE id = $1`,
      [item.referenceRowId],
    );
    if (current.rows.length !== 1) {
      throw new Error('Storage migration target row does not exist.');
    }
    if (
      current.rows[0].current_reference !== item.sourceReference &&
      current.rows[0].current_reference !== destinationReference
    ) {
      throw new Error('Storage migration target does not match the reviewed source.');
    }
    if (current.rows[0].current_reference === destinationReference) {
      alreadySwitched += 1;
    }
    if (await adapter.exists(destinationReference)) {
      const destination = await adapter.info(destinationReference);
      if (destination.size !== source.size || destination.sha256 !== source.sha256) {
        throw new Error('Existing migration destination conflicts with the reviewed source.');
      }
      destinationExisting += 1;
    }
  }
  return {
    manifestSha256: hash,
    sourceVerified: manifest.items.length,
    destinationExisting,
    alreadySwitched,
  };
};

const executeStorageMigration = async ({
  manifest,
  adapter,
  database,
}: {
  manifest: StorageMigrationManifest;
  adapter: StorageAdapter;
  database: ReconciliationDatabase;
}): Promise<MigrationExecutionResult> => {
  const { hash, destinations } = validateMigrationManifest(manifest, adapter);
  let switched = 0;
  let alreadySwitched = 0;

  for (const item of manifest.items) {
    const destinationReference = destinations.get(item) as string;
    let record = await loadMigrationRecord(database, item);
    if (record) {
      assertMatchingMigrationRecord({
        record,
        item,
        destinationReference,
        expectedManifestHash: hash,
      });
    } else {
      const inserted = await database.query(
        `INSERT INTO storage_object_migration (
           manifest_sha256,
           object_kind,
           reference_table,
           reference_column,
           reference_row_id,
           source_reference,
           destination_reference,
           source_size_bytes,
           source_sha256,
           metadata
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
         ON CONFLICT (reference_table, reference_column, reference_row_id) DO NOTHING
         RETURNING *`,
        [
          hash,
          item.objectKind,
          item.referenceTable,
          item.referenceColumn,
          item.referenceRowId,
          item.sourceReference,
          destinationReference,
          item.expectedSizeBytes,
          item.expectedSha256,
          JSON.stringify({
            approved_by: manifest.approvedBy,
            approved_at: manifest.approvedAt,
          }),
        ],
      );
      record = inserted.rows[0] ?? (await loadMigrationRecord(database, item));
      if (!record) {
        throw new Error('Storage migration registry row could not be created.');
      }
      assertMatchingMigrationRecord({
        record,
        item,
        destinationReference,
        expectedManifestHash: hash,
      });
    }

    try {
      if (record.status === 'switched') {
        const current = await database.query(
          `SELECT ${item.referenceColumn} AS current_reference
           FROM ${item.referenceTable}
           WHERE id = $1`,
          [item.referenceRowId],
        );
        if (current.rows[0]?.current_reference !== destinationReference) {
          throw new Error('A switched migration no longer matches its database reference.');
        }
        await adapter.copyVerified(item.sourceReference, destinationReference, {
          size: item.expectedSizeBytes,
          sha256: item.expectedSha256,
        });
        alreadySwitched += 1;
        continue;
      }

      const copied = await adapter.copyVerified(item.sourceReference, destinationReference, {
        size: item.expectedSizeBytes,
        sha256: item.expectedSha256,
      });
      await database.query(
        `UPDATE storage_object_migration
         SET status = 'verified',
             destination_size_bytes = $2,
             destination_sha256 = $3,
             copied_at = COALESCE(copied_at, CURRENT_TIMESTAMP),
             verified_at = CURRENT_TIMESTAMP,
             last_error_code = NULL
         WHERE id = $1`,
        [record.id, copied.destination.size, copied.destination.sha256],
      );

      const switchedNow = await database.transaction(async (client) => {
        const locked = await client.query(
          `SELECT ${item.referenceColumn} AS current_reference
           FROM ${item.referenceTable}
           WHERE id = $1
           FOR UPDATE`,
          [item.referenceRowId],
        );
        if (locked.rows.length !== 1) {
          throw new Error('Storage migration target row no longer exists.');
        }
        const currentReference = locked.rows[0].current_reference;
        if (currentReference !== item.sourceReference && currentReference !== destinationReference) {
          throw new Error('Storage migration target changed after manifest review.');
        }
        if (currentReference === item.sourceReference) {
          await client.query(
            `UPDATE ${item.referenceTable}
             SET ${item.referenceColumn} = $2
             WHERE id = $1`,
            [item.referenceRowId, destinationReference],
          );
        }
        await client.query(
          `UPDATE storage_object_migration
           SET status = 'switched',
               source_retained = TRUE,
               rollback_retain_until =
                 CURRENT_TIMESTAMP + ($2::int * INTERVAL '1 day'),
               switched_at = CURRENT_TIMESTAMP,
               rolled_back_at = NULL,
               last_error_code = NULL
           WHERE id = $1`,
          [record.id, manifest.rollbackRetentionDays],
        );
        return currentReference === item.sourceReference;
      });
      if (switchedNow) {
        switched += 1;
      } else {
        alreadySwitched += 1;
      }
    } catch (error) {
      await database.query(
        `UPDATE storage_object_migration
         SET status = CASE WHEN status = 'switched' THEN status ELSE 'failed' END,
             last_error_code = $2
         WHERE id = $1`,
        [record.id, safeErrorCode(error)],
      );
      throw error;
    }
  }

  return { manifestSha256: hash, switched, alreadySwitched };
};

const rollbackStorageMigration = async ({
  manifest,
  adapter,
  database,
}: {
  manifest: StorageMigrationManifest;
  adapter: StorageAdapter;
  database: ReconciliationDatabase;
}): Promise<MigrationRollbackResult> => {
  const { hash, destinations } = validateMigrationManifest(manifest, adapter, {
    requireRecentReview: false,
  });
  let rolledBack = 0;
  let alreadyRolledBack = 0;

  for (const item of [...manifest.items].reverse()) {
    const destinationReference = destinations.get(item) as string;
    const record = await loadMigrationRecord(database, item);
    if (!record) {
      throw new Error('Storage migration rollback record is missing.');
    }
    assertMatchingMigrationRecord({
      record,
      item,
      destinationReference,
      expectedManifestHash: hash,
    });
    if (!['switched', 'rolled_back'].includes(record.status)) {
      throw new Error('Only switched storage migrations can be rolled back.');
    }
    if (
      record.status === 'switched' &&
      (!record.rollback_retain_until ||
        new Date(record.rollback_retain_until).getTime() < Date.now())
    ) {
      throw new Error('Storage migration rollback retention window has expired.');
    }
    const source = await adapter.info(item.sourceReference);
    if (source.size !== item.expectedSizeBytes || source.sha256 !== item.expectedSha256) {
      throw new Error('Retained migration source failed rollback verification.');
    }
    await adapter.copyVerified(item.sourceReference, destinationReference, {
      size: item.expectedSizeBytes,
      sha256: item.expectedSha256,
    });

    const changed = await database.transaction(async (client) => {
      const locked = await client.query(
        `SELECT ${item.referenceColumn} AS current_reference
         FROM ${item.referenceTable}
         WHERE id = $1
         FOR UPDATE`,
        [item.referenceRowId],
      );
      if (locked.rows.length !== 1) {
        throw new Error('Storage migration rollback target row no longer exists.');
      }
      const currentReference = locked.rows[0].current_reference;
      if (currentReference !== destinationReference && currentReference !== item.sourceReference) {
        throw new Error('Storage migration rollback target has changed.');
      }
      if (currentReference === destinationReference) {
        await client.query(
          `UPDATE ${item.referenceTable}
           SET ${item.referenceColumn} = $2
           WHERE id = $1`,
          [item.referenceRowId, item.sourceReference],
        );
      }
      await client.query(
        `UPDATE storage_object_migration
         SET status = 'rolled_back',
             rolled_back_at = CURRENT_TIMESTAMP,
             last_error_code = NULL
         WHERE id = $1`,
        [record.id],
      );
      return currentReference === destinationReference;
    });
    if (changed) {
      rolledBack += 1;
    } else {
      alreadyRolledBack += 1;
    }
  }
  return { manifestSha256: hash, rolledBack, alreadyRolledBack };
};

const validateOrphanManifest = (manifest: ReviewedOrphanManifest): string => {
  if (
    !hasExactKeys(manifest, [
      'version',
      'operation',
      'inventoryManifestSha256',
      'reviewedBy',
      'reviewedAt',
      'reviewReason',
      'items',
    ]) ||
    manifest?.version !== 1 ||
    manifest.operation !== 'quarantine_reviewed_orphans' ||
    !sha256Pattern.test(manifest.inventoryManifestSha256) ||
    !safeHumanText(manifest.reviewedBy, 200) ||
    typeof manifest.reviewedAt !== 'string' ||
    !safeHumanText(manifest.reviewReason, 1000) ||
    !Array.isArray(manifest.items) ||
    manifest.items.length === 0 ||
    manifest.items.length > 10000
  ) {
    throw new Error('Reviewed orphan manifest is invalid.');
  }
  validReviewDate(manifest.reviewedAt);
  const sources = new Set<string>();
  for (const item of manifest.items) {
    if (
      !hasExactKeys(
        item,
        ['sourceReference', 'expectedSizeBytes', 'expectedSha256'],
        ['reviewReason'],
      ) ||
      typeof item.sourceReference !== 'string' ||
      item.sourceReference.length === 0 ||
      item.sourceReference.length > 2048 ||
      !Number.isSafeInteger(item.expectedSizeBytes) ||
      item.expectedSizeBytes < 1 ||
      !sha256Pattern.test(item.expectedSha256) ||
      (item.reviewReason !== undefined &&
        !safeHumanText(item.reviewReason, 1000))
    ) {
      throw new Error('Reviewed orphan manifest item is invalid.');
    }
    if (sources.has(item.sourceReference)) {
      throw new Error('Reviewed orphan manifest contains a duplicate source.');
    }
    sources.add(item.sourceReference);
  }
  return manifestHash(manifest);
};

const preflightReviewedOrphans = async ({
  manifest,
  adapter,
  database,
}: {
  manifest: ReviewedOrphanManifest;
  adapter: StorageAdapter;
  database: Pick<ReconciliationDatabase, 'query'>;
}): Promise<OrphanPreflightResult> => {
  const hash = validateOrphanManifest(manifest);
  const inventory = await createStorageInventory({
    executor: { query: database.query },
    adapter,
    includeChecksums: true,
  });
  const currentInventoryHash = inventoryManifestHash(inventory);
  if (currentInventoryHash !== manifest.inventoryManifestSha256) {
    throw new Error('Storage inventory changed after orphan review; generate and review a new manifest.');
  }
  const files = new Map(inventory.files.map((file) => [file.reference, file]));
  for (const item of manifest.items) {
    const file = files.get(item.sourceReference);
    if (
      file?.classification !== 'unreferenced' ||
      file.size !== item.expectedSizeBytes ||
      file.sha256 !== item.expectedSha256
    ) {
      throw new Error('Reviewed orphan no longer matches the checksummed inventory.');
    }
  }
  return {
    manifestSha256: hash,
    inventoryManifestSha256: currentInventoryHash,
    verifiedUnreferenced: manifest.items.length,
  };
};

const assertMatchingOrphanRecord = ({
  record,
  expectedManifestHash,
  item,
  quarantineReference,
}: {
  record: any;
  expectedManifestHash: string;
  item: ReviewedOrphanItem;
  quarantineReference: string;
}): void => {
  if (
    record.manifest_sha256 !== expectedManifestHash ||
    record.source_reference !== item.sourceReference ||
    record.quarantine_reference !== quarantineReference ||
    Number(record.object_size_bytes) !== item.expectedSizeBytes ||
    record.object_sha256 !== item.expectedSha256
  ) {
    throw new Error('Existing orphan quarantine record conflicts with the reviewed manifest.');
  }
};

const lockStorageReferenceTables = async (client: PoolClient): Promise<void> => {
  await client.query(
    `LOCK TABLE
       photo,
       gis_import_job,
       shapefile_export,
       upload_quarantine_record,
       ai_output_layer,
       project_category,
       ai_prediction_feature_validation,
       ai_prediction_validation_submission,
       legacy_ai_validation_media_snapshot
     IN SHARE MODE`,
  );
};

const quarantineReviewedOrphans = async ({
  manifest,
  adapter,
  database,
}: {
  manifest: ReviewedOrphanManifest;
  adapter: StorageAdapter;
  database: ReconciliationDatabase;
}): Promise<OrphanQuarantineResult> => {
  const hash = validateOrphanManifest(manifest);
  const initialInventory = await createStorageInventory({
    executor: { query: database.query },
    adapter,
    includeChecksums: true,
  });
  const inventoryMatches =
    inventoryManifestHash(initialInventory) === manifest.inventoryManifestSha256;
  const existingRecords = new Map<string, any>();
  for (const item of manifest.items) {
    const existing = await database.query(
      `SELECT *
       FROM storage_orphan_quarantine_record
       WHERE source_reference = $1
         AND object_sha256 = $2`,
      [item.sourceReference, item.expectedSha256],
    );
    if (existing.rows[0]) {
      existingRecords.set(item.sourceReference, existing.rows[0]);
    }
  }
  if (!inventoryMatches && existingRecords.size === 0) {
    throw new Error('Storage inventory changed after orphan review; generate and review a new manifest.');
  }
  const inventoryByReference = new Map(
    initialInventory.files.map((file) => [file.reference, file]),
  );
  let quarantined = 0;
  let resumed = 0;

  for (const item of manifest.items) {
    const source = adapter.resolve(item.sourceReference);
    if (!source || source.key.startsWith('.quarantine/')) {
      throw new Error('Reviewed orphan source is invalid or already quarantined.');
    }
    const baseName = source.key.split('/').at(-1) as string;
    const sourceIdentity = createHash('sha256')
      .update(source.reference)
      .digest('hex')
      .slice(0, 16);
    const quarantineReference = adapter.reference(
      source.bucket,
      `.quarantine/legacy-orphans/${item.expectedSha256.slice(0, 16)}/${sourceIdentity}-${baseName}`,
    );
    let record = existingRecords.get(item.sourceReference) ?? null;
    if (record) {
      assertMatchingOrphanRecord({
        record,
        expectedManifestHash: hash,
        item,
        quarantineReference,
      });
    }
    let sourceExists = await adapter.exists(item.sourceReference);
    const reviewed = inventoryByReference.get(item.sourceReference);
    const sourceStillMatchesReview =
      reviewed?.classification === 'unreferenced' &&
      reviewed.size === item.expectedSizeBytes &&
      reviewed.sha256 === item.expectedSha256;
    if (!sourceStillMatchesReview && !(record && !sourceExists)) {
      throw new Error('Reviewed orphan no longer matches the read-only inventory.');
    }
    if (record?.status === 'quarantined') {
      if (sourceExists) {
        throw new Error('A previously quarantined orphan source has unexpectedly reappeared.');
      }
      const retained = await adapter.info(quarantineReference, [source.bucket]);
      if (
        retained.size !== item.expectedSizeBytes ||
        retained.sha256 !== item.expectedSha256
      ) {
        throw new Error('Quarantined orphan failed its retained checksum verification.');
      }
      resumed += 1;
      continue;
    }
    if (record && !sourceExists) {
      const retained = await adapter.info(quarantineReference, [source.bucket]);
      if (
        retained.size !== item.expectedSizeBytes ||
        retained.sha256 !== item.expectedSha256
      ) {
        throw new Error('Copied orphan quarantine object failed resume verification.');
      }
    }

    if (!record || sourceExists) {
      const copied = await adapter.copyVerified(item.sourceReference, quarantineReference, {
        size: item.expectedSizeBytes,
        sha256: item.expectedSha256,
      });
      if (!record) {
        const inserted = await database.query(
          `INSERT INTO storage_orphan_quarantine_record (
             manifest_sha256,
             source_reference,
             quarantine_reference,
             object_size_bytes,
             object_sha256,
             reviewed_by,
             reviewed_at,
             review_reason,
             status,
             metadata
           ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'copied', $9::jsonb)
           ON CONFLICT (source_reference, object_sha256) DO NOTHING
           RETURNING *`,
          [
            hash,
            item.sourceReference,
            quarantineReference,
            copied.destination.size,
            copied.destination.sha256,
            manifest.reviewedBy,
            manifest.reviewedAt,
            item.reviewReason ?? manifest.reviewReason,
            JSON.stringify({
              inventory_manifest_sha256: manifest.inventoryManifestSha256,
            }),
          ],
        );
        record =
          inserted.rows[0] ??
          (
            await database.query(
              `SELECT *
               FROM storage_orphan_quarantine_record
               WHERE source_reference = $1
                 AND object_sha256 = $2`,
              [item.sourceReference, item.expectedSha256],
            )
          ).rows[0];
      }
    }
    if (!record) {
      throw new Error('Orphan quarantine audit record is missing or conflicts with the manifest.');
    }
    assertMatchingOrphanRecord({
      record,
      expectedManifestHash: hash,
      item,
      quarantineReference,
    });

    try {
      await database.transaction(async (client) => {
        await lockStorageReferenceTables(client);
        const fresh = await loadInventoryReferences(client, adapter);
        const nowReferenced = fresh.references.some((reference) =>
          reference.candidates.includes(item.sourceReference),
        );
        if (nowReferenced) {
          throw new Error('Reviewed orphan became referenced before quarantine.');
        }
        sourceExists = await adapter.exists(item.sourceReference);
        if (sourceExists) {
          const sourceImmediatelyBeforeRemoval = await adapter.info(
            item.sourceReference,
            [source.bucket],
          );
          if (
            sourceImmediatelyBeforeRemoval.size !== item.expectedSizeBytes ||
            sourceImmediatelyBeforeRemoval.sha256 !== item.expectedSha256
          ) {
            throw new Error('Reviewed orphan changed before quarantine removal.');
          }
          await adapter.remove(item.sourceReference);
        }
        await client.query(
          `UPDATE storage_orphan_quarantine_record
           SET status = 'quarantined',
               source_removed_at = CURRENT_TIMESTAMP,
               last_error_code = NULL
           WHERE id = $1`,
          [record.id],
        );
      });
      if (sourceExists) {
        quarantined += 1;
      } else {
        resumed += 1;
      }
    } catch (error) {
      await database.query(
        `UPDATE storage_orphan_quarantine_record
         SET status = 'failed',
             last_error_code = $2
         WHERE id = $1`,
        [record.id, safeErrorCode(error)],
      );
      throw error;
    }
  }
  return { manifestSha256: hash, quarantined, resumed };
};

export {
  executeStorageMigration,
  manifestHash,
  preflightReviewedOrphans,
  preflightStorageMigration,
  quarantineReviewedOrphans,
  rollbackStorageMigration,
  validateMigrationManifest,
  validateOrphanManifest,
  type MigrationExecutionResult,
  type MigrationPreflightResult,
  type MigrationRollbackResult,
  type OrphanPreflightResult,
  type OrphanQuarantineResult,
  type ReviewedOrphanManifest,
  type StorageMigrationManifest,
};
