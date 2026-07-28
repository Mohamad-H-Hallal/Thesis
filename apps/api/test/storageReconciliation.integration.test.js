const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const {
  closePool,
  query,
  transaction,
} = require('../src/config/database');
const { LocalStorageAdapter } = require('../src/services/storageAdapter.service');
const {
  createStorageInventory,
  inventoryManifestHash,
} = require('../src/services/storageInventory.service');
const {
  executeStorageMigration,
  preflightReviewedOrphans,
  preflightStorageMigration,
  quarantineReviewedOrphans,
  rollbackStorageMigration,
} = require('../src/services/storageReconciliation.service');

const database = { query, transaction };

describe('storage reconciliation PostgreSQL integration', () => {
  let tempRoot;
  let adapter;
  const cleanupMigrationIds = new Set();
  const cleanupProjectIds = new Set();
  const cleanupCategoryIds = new Set();
  const cleanupUserIds = new Set();
  const cleanupOrphanSources = new Set();

  beforeEach(async () => {
    tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'gis-storage-db-integration-'));
    adapter = new LocalStorageAdapter({
      uploads: path.join(tempRoot, 'uploads'),
      exports: path.join(tempRoot, 'exports'),
    });
  });

  afterEach(async () => {
    for (const sourceReference of cleanupOrphanSources) {
      await query(
        'DELETE FROM storage_orphan_quarantine_record WHERE source_reference = $1',
        [sourceReference],
      );
    }
    cleanupOrphanSources.clear();
    for (const referenceRowId of cleanupMigrationIds) {
      await query(
        'DELETE FROM storage_object_migration WHERE reference_row_id = $1',
        [referenceRowId],
      );
    }
    cleanupMigrationIds.clear();
    for (const projectId of cleanupProjectIds) {
      await query('DELETE FROM project WHERE id = $1', [projectId]);
    }
    cleanupProjectIds.clear();
    for (const categoryId of cleanupCategoryIds) {
      await query('DELETE FROM project_category WHERE id = $1', [categoryId]);
    }
    cleanupCategoryIds.clear();
    for (const userId of cleanupUserIds) {
      await query('DELETE FROM "user" WHERE id = $1', [userId]);
    }
    cleanupUserIds.clear();
    await fs.rm(tempRoot, { recursive: true, force: true });
  });

  afterAll(async () => {
    await closePool();
  });

  test('persists copy/verify/switch audit state and rolls the exact photo reference back', async () => {
    const userId = randomUUID();
    const categoryId = randomUUID();
    const projectId = randomUUID();
    const featureId = randomUUID();
    const photoId = randomUUID();
    cleanupUserIds.add(userId);
    cleanupCategoryIds.add(categoryId);
    cleanupProjectIds.add(projectId);
    cleanupMigrationIds.add(photoId);

    const sourceCanonical = adapter.reference('uploads', 'photos/legacy-db-photo.jpg');
    const source = await adapter.writeExclusive(
      sourceCanonical,
      Buffer.from('legacy-photo-database-integration'),
    );
    const sourceReference = source.localPath;
    const destinationReference = adapter.reference(
      'uploads',
      '.private/feature-photos/migrated-db-photo.jpg',
    );

    await query(
      `INSERT INTO "user" (id, email, password_hash, full_name, role)
       VALUES ($1, $2, 'integration-test-hash', 'Storage Integration User', 'admin')`,
      [userId, `storage-integration-${userId}@example.com`],
    );
    await query(
      `INSERT INTO project_category (id, name)
       VALUES ($1, $2)`,
      [categoryId, `Storage Integration ${categoryId}`],
    );
    await query(
      `INSERT INTO project (id, category_id, created_by_user_id, name)
       VALUES ($1, $2, $3, 'Storage Integration Project')`,
      [projectId, categoryId, userId],
    );
    await query(
      `INSERT INTO spatial_feature (
         id, project_id, collected_by_user_id, geom, attributes
       ) VALUES (
         $1, $2, $3, ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326), '{}'::jsonb
       )`,
      [featureId, projectId, userId],
    );
    await query(
      `INSERT INTO photo (id, feature_id, file_path, file_size_bytes)
       VALUES ($1, $2, $3, $4)`,
      [photoId, featureId, sourceReference, source.size],
    );

    const manifest = {
      version: 1,
      operation: 'copy_verify_switch',
      approvedBy: 'Storage integration reviewer',
      approvedAt: new Date().toISOString(),
      rollbackRetentionDays: 30,
      items: [
        {
          objectKind: 'feature_photo',
          referenceTable: 'photo',
          referenceColumn: 'file_path',
          referenceRowId: photoId,
          sourceReference,
          destinationKey: '.private/feature-photos/migrated-db-photo.jpg',
          expectedSizeBytes: source.size,
          expectedSha256: source.sha256,
        },
      ],
    };

    await expect(
      preflightStorageMigration({ manifest, adapter, database }),
    ).resolves.toEqual(
      expect.objectContaining({
        sourceVerified: 1,
        destinationExisting: 0,
        alreadySwitched: 0,
      }),
    );
    await expect(
      executeStorageMigration({ manifest, adapter, database }),
    ).resolves.toEqual(expect.objectContaining({ switched: 1 }));

    const switched = await query(
      `SELECT p.file_path,
              migration.status,
              migration.source_retained,
              migration.destination_sha256,
              migration.rollback_retain_until
       FROM photo AS p
       JOIN storage_object_migration AS migration
         ON migration.reference_row_id = p.id
       WHERE p.id = $1`,
      [photoId],
    );
    expect(switched.rows[0]).toEqual(
      expect.objectContaining({
        file_path: destinationReference,
        status: 'switched',
        source_retained: true,
        destination_sha256: source.sha256,
        rollback_retain_until: expect.any(Date),
      }),
    );
    await expect(adapter.exists(sourceReference)).resolves.toBe(true);
    await expect(adapter.exists(destinationReference)).resolves.toBe(true);

    await expect(
      rollbackStorageMigration({ manifest, adapter, database }),
    ).resolves.toEqual(expect.objectContaining({ rolledBack: 1 }));
    const rolledBack = await query('SELECT file_path FROM photo WHERE id = $1', [photoId]);
    expect(rolledBack.rows[0].file_path).toBe(sourceReference);
    await expect(adapter.exists(destinationReference)).resolves.toBe(true);
  });

  test('records and retains a checksummed reviewed orphan under real table locks', async () => {
    const sourceReference = adapter.reference(
      'uploads',
      'imports/reviewed-db-orphan.geojson',
    );
    cleanupOrphanSources.add(sourceReference);
    const source = await adapter.writeExclusive(
      sourceReference,
      Buffer.from('{"type":"FeatureCollection","features":[]}'),
    );
    const inventory = await createStorageInventory({
      executor: { query },
      adapter,
      includeChecksums: true,
    });
    const manifest = {
      version: 1,
      operation: 'quarantine_reviewed_orphans',
      inventoryManifestSha256: inventoryManifestHash(inventory),
      reviewedBy: 'Storage integration reviewer',
      reviewedAt: new Date().toISOString(),
      reviewReason: 'Confirmed integration-test orphan.',
      items: [
        {
          sourceReference,
          expectedSizeBytes: source.size,
          expectedSha256: source.sha256,
        },
      ],
    };

    await expect(
      preflightReviewedOrphans({ manifest, adapter, database }),
    ).resolves.toEqual(expect.objectContaining({ verifiedUnreferenced: 1 }));
    await expect(
      quarantineReviewedOrphans({ manifest, adapter, database }),
    ).resolves.toEqual(expect.objectContaining({ quarantined: 1 }));

    const record = await query(
      `SELECT quarantine_reference, status, source_removed_at
       FROM storage_orphan_quarantine_record
       WHERE source_reference = $1`,
      [sourceReference],
    );
    expect(record.rows[0]).toEqual(
      expect.objectContaining({
        status: 'quarantined',
        source_removed_at: expect.any(Date),
      }),
    );
    await expect(adapter.exists(sourceReference)).resolves.toBe(false);
    await expect(adapter.exists(record.rows[0].quarantine_reference)).resolves.toBe(true);
  });
});
