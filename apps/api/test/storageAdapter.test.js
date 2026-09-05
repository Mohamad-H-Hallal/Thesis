const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { LocalStorageAdapter } = require('../src/services/storageAdapter.service');
const {
  createStorageInventory,
  inventoryManifestHash,
} = require('../src/services/storageInventory.service');

describe('local storage adapter and read-only inventory', () => {
  let tempRoot;
  let uploadsRoot;
  let exportsRoot;
  let adapter;

  beforeEach(async () => {
    tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'gis-storage-adapter-'));
    uploadsRoot = path.join(tempRoot, 'uploads');
    exportsRoot = path.join(tempRoot, 'exports');
    adapter = new LocalStorageAdapter({
      uploads: uploadsRoot,
      exports: exportsRoot,
    });
  });

  afterEach(async () => {
    await fs.rm(tempRoot, { recursive: true, force: true });
  });

  test('contains references, writes atomically, and copies only with matching checksums', async () => {
    const sourceReference = adapter.reference('uploads', '.private/imports/source.geojson');
    const destinationReference = adapter.reference('uploads', '.private/migrated/source.geojson');
    const payload = Buffer.from('{"type":"FeatureCollection","features":[]}');

    const source = await adapter.writeAtomic(sourceReference, payload);
    expect(source).toEqual(
      expect.objectContaining({
        reference: sourceReference,
        size: payload.length,
        sha256: expect.stringMatching(/^[0-9a-f]{64}$/),
      }),
    );
    await expect(adapter.writeAtomic(sourceReference, payload)).rejects.toMatchObject({
      code: 'EEXIST',
    });

    const copied = await adapter.copyVerified(sourceReference, destinationReference, {
      size: source.size,
      sha256: source.sha256,
    });
    expect(copied.destination).toEqual(
      expect.objectContaining({
        reference: destinationReference,
        size: source.size,
        sha256: source.sha256,
      }),
    );
    await expect(
      adapter.copyVerified(sourceReference, destinationReference, {
        size: source.size,
        sha256: source.sha256,
      }),
    ).resolves.toEqual(expect.objectContaining({ destinationAlreadyExisted: true }));
    await expect(
      adapter.copyVerified(sourceReference, adapter.reference('exports', 'bad-copy'), {
        sha256: '0'.repeat(64),
      }),
    ).rejects.toThrow('reviewed size and checksum');

    expect(adapter.resolve('storage://uploads/../outside')).toBeNull();
    expect(adapter.resolve(path.join(tempRoot, 'outside.txt'))).toBeNull();
    const range = await adapter.openReadRange(sourceReference, { start: 2, end: 7 }, ['uploads']);
    const rangeChunks = [];
    for await (const chunk of range) rangeChunks.push(Buffer.from(chunk));
    expect(Buffer.concat(rangeChunks)).toEqual(payload.subarray(2, 8));
  });

  test('rejects symbolic-link traversal for reads, writes, and removal', async () => {
    const outsideRoot = path.join(tempRoot, 'outside');
    const linkedDirectory = path.join(uploadsRoot, 'linked');
    const outsideFile = path.join(outsideRoot, 'protected.txt');
    await fs.mkdir(uploadsRoot, { recursive: true });
    await fs.mkdir(outsideRoot, { recursive: true });
    await fs.writeFile(outsideFile, 'must remain');
    await fs.symlink(
      outsideRoot,
      linkedDirectory,
      process.platform === 'win32' ? 'junction' : 'dir',
    );
    const escapedReference = adapter.reference('uploads', 'linked/protected.txt');

    await expect(adapter.info(escapedReference)).rejects.toThrow('symbolic link');
    await expect(
      adapter.writeExclusive(
        adapter.reference('uploads', 'linked/new.txt'),
        Buffer.from('must not escape'),
      ),
    ).rejects.toThrow('symbolic link');
    await expect(adapter.remove(escapedReference)).rejects.toThrow('symbolic link');
    await expect(adapter.list('uploads')).resolves.toEqual([
      expect.objectContaining({
        key: 'linked',
        kind: 'symlink',
      }),
    ]);
    await expect(fs.readFile(outsideFile, 'utf8')).resolves.toBe('must remain');
    await expect(fs.stat(path.join(outsideRoot, 'new.txt'))).rejects.toMatchObject({
      code: 'ENOENT',
    });
  });

  test('classifies live, protected, quarantined, missing, unresolved, and orphan objects without mutation', async () => {
    const photoName = `${randomUUID()}.jpg`;
    const aiName = `${randomUUID()}.jpg`;
    const legacyName = `${randomUUID()}.jpg`;
    const livePhoto = adapter.reference('uploads', `.private/feature-photos/${photoName}`);
    const currentAi = adapter.reference('uploads', `.private/ai-validation/${aiName}`);
    const protectedLegacy = adapter.reference('uploads', `photos/${legacyName}`);
    const quarantined = adapter.reference('uploads', '.quarantine/imports/rejected.raw');
    const orphan = adapter.reference('exports', 'unreferenced-export.zip');
    for (const reference of [livePhoto, currentAi, protectedLegacy, quarantined, orphan]) {
      await adapter.writeExclusive(reference, Buffer.from(reference));
    }

    const missingPath = path.join(uploadsRoot, '.private', 'imports', 'missing.geojson');
    const executor = {
      query: jest.fn(async (sql) => {
        if (sql.includes('ai_output_layer.storage_path')) {
          return {
            rows: [
              {
                source: 'photo.file_path',
                row_id: randomUUID(),
                stored_value: adapter.resolve(livePhoto).localPath,
              },
              {
                source: 'gis_import_job.file_path',
                row_id: randomUUID(),
                stored_value: missingPath,
              },
              {
                source: 'ai_output_layer.storage_path',
                row_id: randomUUID(),
                stored_value: 'outputs/unmanaged.geojson',
              },
            ],
          };
        }
        if (sql.includes('project_category.icon_url')) {
          return {
            rows: [
              {
                source: 'ai_prediction_feature_validation.photo_media_ids',
                row_id: randomUUID(),
                stored_value: `/uploads/ai-validation/${aiName}`,
              },
            ],
          };
        }
        if (sql.includes('legacy_ai_validation_media_snapshot')) {
          return { rows: [{ storage_name: legacyName }] };
        }
        throw new Error('Unexpected inventory query');
      }),
    };

    const report = await createStorageInventory({ executor, adapter });
    expect(report.readOnly).toBe(true);
    expect(report.counts).toEqual({
      referenced: 2,
      protected_legacy: 1,
      quarantine: 1,
      unreferenced: 1,
      unsafe_symlink: 0,
      missing_reference: 1,
      unresolved_reference: 1,
    });
    expect(report.files.find((file) => file.reference === orphan)).toEqual(
      expect.objectContaining({
        classification: 'unreferenced',
        sha256: expect.stringMatching(/^[0-9a-f]{64}$/),
      }),
    );
    expect(report.missingReferences[0].storedValue).toBe(missingPath);
    expect(report.unresolvedReferences[0]).toEqual(
      expect.objectContaining({
        storedValue: 'outputs/unmanaged.geojson',
        reason: 'outside_managed_storage',
      }),
    );
    expect(inventoryManifestHash(report)).toBe(inventoryManifestHash(report));
    expect(await adapter.exists(orphan)).toBe(true);
  });
});
