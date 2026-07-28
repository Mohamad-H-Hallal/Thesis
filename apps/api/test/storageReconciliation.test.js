const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
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
  validateMigrationManifest,
  validateOrphanManifest,
} = require('../src/services/storageReconciliation.service');

const emptyInventoryRows = async (sql) => {
  if (
    sql.includes('ai_output_layer.storage_path') ||
    sql.includes('project_category.icon_url') ||
    sql.includes('legacy_ai_validation_media_snapshot')
  ) {
    return { rows: [] };
  }
  throw new Error(`Unexpected inventory query: ${sql}`);
};

describe('storage reconciliation safety workflow', () => {
  let tempRoot;
  let adapter;

  beforeEach(async () => {
    tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'gis-storage-reconciliation-'));
    adapter = new LocalStorageAdapter({
      uploads: path.join(tempRoot, 'uploads'),
      exports: path.join(tempRoot, 'exports'),
    });
  });

  afterEach(async () => {
    await fs.rm(tempRoot, { recursive: true, force: true });
  });

  test('copies, verifies, switches, and rolls back while retaining both objects', async () => {
    const sourceCanonical = adapter.reference('uploads', 'photos/legacy.jpg');
    const source = await adapter.writeExclusive(sourceCanonical, Buffer.from('legacy-photo'));
    const sourceReference = adapter.resolve(sourceCanonical).localPath;
    const rowId = randomUUID();
    const state = {
      currentReference: sourceReference,
      migration: null,
    };
    const updateMigration = (sql, params) => {
      if (sql.includes("SET status = 'verified'")) {
        Object.assign(state.migration, {
          status: 'verified',
          destination_size_bytes: params[1],
          destination_sha256: params[2],
          copied_at: new Date(),
          verified_at: new Date(),
          last_error_code: null,
        });
      } else if (sql.includes("SET status = 'switched'")) {
        Object.assign(state.migration, {
          status: 'switched',
          source_retained: true,
          rollback_retain_until: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
          switched_at: new Date(),
          rolled_back_at: null,
          last_error_code: null,
        });
      } else if (sql.includes("SET status = 'rolled_back'")) {
        Object.assign(state.migration, {
          status: 'rolled_back',
          rolled_back_at: new Date(),
          last_error_code: null,
        });
      } else if (sql.includes("SET status = CASE")) {
        state.migration.last_error_code = params[1];
      }
      return { rows: [], rowCount: 1 };
    };
    const client = {
      query: jest.fn(async (sql, params = []) => {
        if (sql.includes('AS current_reference') && sql.includes('FOR UPDATE')) {
          return { rows: [{ current_reference: state.currentReference }], rowCount: 1 };
        }
        if (sql.includes('UPDATE photo') && sql.includes('SET file_path')) {
          state.currentReference = params[1];
          return { rows: [], rowCount: 1 };
        }
        if (sql.includes('UPDATE storage_object_migration')) {
          return updateMigration(sql, params);
        }
        throw new Error(`Unexpected transaction query: ${sql}`);
      }),
    };
    const database = {
      query: jest.fn(async (sql, params = []) => {
        if (sql.includes('FROM storage_object_migration') && sql.includes('SELECT *')) {
          return { rows: state.migration ? [state.migration] : [] };
        }
        if (sql.includes('INSERT INTO storage_object_migration')) {
          state.migration = {
            id: randomUUID(),
            manifest_sha256: params[0],
            object_kind: params[1],
            reference_table: params[2],
            reference_column: params[3],
            reference_row_id: params[4],
            source_reference: params[5],
            destination_reference: params[6],
            source_size_bytes: params[7],
            source_sha256: params[8],
            status: 'planned',
          };
          return { rows: [state.migration], rowCount: 1 };
        }
        if (sql.includes('UPDATE storage_object_migration')) {
          return updateMigration(sql, params);
        }
        if (sql.includes('AS current_reference') && sql.includes('FROM photo')) {
          return { rows: [{ current_reference: state.currentReference }], rowCount: 1 };
        }
        throw new Error(`Unexpected database query: ${sql}`);
      }),
      transaction: jest.fn(async (callback) => callback(client)),
    };
    const manifest = {
      version: 1,
      operation: 'copy_verify_switch',
      approvedBy: 'Security reviewer',
      approvedAt: new Date().toISOString(),
      rollbackRetentionDays: 30,
      items: [
        {
          objectKind: 'feature_photo',
          referenceTable: 'photo',
          referenceColumn: 'file_path',
          referenceRowId: rowId,
          sourceReference,
          destinationKey: '.private/feature-photos/migrated.jpg',
          expectedSizeBytes: source.size,
          expectedSha256: source.sha256,
        },
      ],
    };
    const destinationReference = adapter.reference(
      'uploads',
      '.private/feature-photos/migrated.jpg',
    );

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
    ).resolves.toEqual(
      expect.objectContaining({ switched: 1, alreadySwitched: 0 }),
    );
    expect(state.currentReference).toBe(destinationReference);
    expect(state.migration.status).toBe('switched');
    await expect(adapter.exists(sourceReference)).resolves.toBe(true);
    await expect(adapter.exists(destinationReference)).resolves.toBe(true);

    await expect(
      executeStorageMigration({ manifest, adapter, database }),
    ).resolves.toEqual(
      expect.objectContaining({ switched: 0, alreadySwitched: 1 }),
    );
    await expect(
      rollbackStorageMigration({ manifest, adapter, database }),
    ).resolves.toEqual(
      expect.objectContaining({ rolledBack: 1, alreadyRolledBack: 0 }),
    );
    expect(state.currentReference).toBe(sourceReference);
    expect(state.migration.status).toBe('rolled_back');
    await expect(adapter.exists(destinationReference)).resolves.toBe(true);
  });

  test('moves only a checksum-reviewed current orphan into recoverable quarantine', async () => {
    const sourceReference = adapter.reference('uploads', 'imports/reviewed-orphan.geojson');
    const source = await adapter.writeExclusive(
      sourceReference,
      Buffer.from('{"type":"FeatureCollection","features":[]}'),
    );
    const state = { record: null };
    const inventoryExecutor = { query: jest.fn(emptyInventoryRows) };
    const inventory = await createStorageInventory({
      executor: inventoryExecutor,
      adapter,
      includeChecksums: true,
    });
    expect(inventory.files[0].classification).toBe('unreferenced');

    const client = {
      query: jest.fn(async (sql) => {
        if (sql.includes('LOCK TABLE')) {
          return { rows: [] };
        }
        if (
          sql.includes('ai_output_layer.storage_path') ||
          sql.includes('project_category.icon_url') ||
          sql.includes('legacy_ai_validation_media_snapshot')
        ) {
          return { rows: [] };
        }
        if (sql.includes('UPDATE storage_orphan_quarantine_record')) {
          Object.assign(state.record, {
            status: 'quarantined',
            source_removed_at: new Date(),
            last_error_code: null,
          });
          return { rows: [], rowCount: 1 };
        }
        throw new Error(`Unexpected orphan transaction query: ${sql}`);
      }),
    };
    const database = {
      query: jest.fn(async (sql, params = []) => {
        if (
          sql.includes('ai_output_layer.storage_path') ||
          sql.includes('project_category.icon_url') ||
          sql.includes('legacy_ai_validation_media_snapshot')
        ) {
          return { rows: [] };
        }
        if (
          sql.includes('FROM storage_orphan_quarantine_record') &&
          sql.includes('SELECT *')
        ) {
          return { rows: state.record ? [state.record] : [] };
        }
        if (sql.includes('INSERT INTO storage_orphan_quarantine_record')) {
          state.record = {
            id: randomUUID(),
            manifest_sha256: params[0],
            source_reference: params[1],
            quarantine_reference: params[2],
            object_size_bytes: params[3],
            object_sha256: params[4],
            status: 'copied',
          };
          return { rows: [state.record], rowCount: 1 };
        }
        if (sql.includes('UPDATE storage_orphan_quarantine_record')) {
          state.record.status = 'failed';
          state.record.last_error_code = params[1];
          return { rows: [], rowCount: 1 };
        }
        throw new Error(`Unexpected orphan database query: ${sql}`);
      }),
      transaction: jest.fn(async (callback) => callback(client)),
    };
    const manifest = {
      version: 1,
      operation: 'quarantine_reviewed_orphans',
      inventoryManifestSha256: inventoryManifestHash(inventory),
      reviewedBy: 'Storage owner',
      reviewedAt: new Date().toISOString(),
      reviewReason: 'Confirmed test orphan after database and backup review.',
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
    ).resolves.toEqual(
      expect.objectContaining({
        inventoryManifestSha256: manifest.inventoryManifestSha256,
        verifiedUnreferenced: 1,
      }),
    );
    await expect(
      quarantineReviewedOrphans({ manifest, adapter, database }),
    ).resolves.toEqual(expect.objectContaining({ quarantined: 1, resumed: 0 }));
    expect(state.record.status).toBe('quarantined');
    await expect(adapter.exists(sourceReference)).resolves.toBe(false);
    await expect(adapter.exists(state.record.quarantine_reference)).resolves.toBe(true);

    await expect(
      quarantineReviewedOrphans({ manifest, adapter, database }),
    ).resolves.toEqual(expect.objectContaining({ quarantined: 0, resumed: 1 }));
    await expect(adapter.exists(state.record.quarantine_reference)).resolves.toBe(true);
  });

  test('rejects unreviewed or unsafe manifests before any state change', () => {
    expect(() =>
      validateMigrationManifest(
        {
          version: 1,
          operation: 'copy_verify_switch',
          approvedBy: 'Reviewer',
          approvedAt: new Date().toISOString(),
          rollbackRetentionDays: 30,
          items: [
            {
              objectKind: 'feature_photo',
              referenceTable: 'photo',
              referenceColumn: 'file_path',
              referenceRowId: randomUUID(),
              sourceReference: 'outside/file.jpg',
              destinationKey: '../escape.jpg',
              expectedSizeBytes: 1,
              expectedSha256: '0'.repeat(64),
            },
          ],
        },
        adapter,
      ),
    ).toThrow('invalid or targets a disallowed reference');

    expect(() =>
      validateOrphanManifest({
        version: 1,
        operation: 'quarantine_reviewed_orphans',
        inventoryManifestSha256: '0'.repeat(64),
        reviewedBy: '',
        reviewedAt: new Date().toISOString(),
        reviewReason: '',
        items: [],
      }),
    ).toThrow('invalid');

    expect(() =>
      validateOrphanManifest({
        version: 1,
        operation: 'quarantine_reviewed_orphans',
        inventoryManifestSha256: '0'.repeat(64),
        reviewedBy: 'Reviewer',
        reviewedAt: new Date().toISOString(),
        reviewReason: 'Reviewed.',
        items: [
          {
            sourceReference: 'storage://uploads/imports/orphan.geojson',
            expectedSizeBytes: 1,
            expectedSha256: '0'.repeat(64),
            ignoredField: true,
          },
        ],
      }),
    ).toThrow('item is invalid');
  });
});
