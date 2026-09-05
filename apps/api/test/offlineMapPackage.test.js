const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const AdmZip = require('adm-zip');
const {
  assertZipEnvelope,
  readEmbeddedManifest,
  validateOfflinePackageManifest,
} = require('../src/services/offlineMapPackage.service');

const validManifest = () => ({
  schema_version: 1,
  package_version: 'lebanon-s2-2026-08-v1',
  tile_count: 123,
  zoom_min: 7,
  zoom_max: 15,
  tile_scheme: 'xyz',
  dataset_code: 'copernicus_sentinel2_osm_labels',
  source_acquisition_start: '2026-07-01',
  source_acquisition_end: '2026-07-31',
  source_scene_ids: ['S2A_MSIL2A_20260701T081611_N0609_R121'],
  source_terms_url: 'https://dataspace.copernicus.eu/terms-and-conditions',
  source_attribution: 'Contains modified Copernicus Sentinel-2 data and OpenStreetMap data.',
  source_resolution_meters: 10,
  processing_manifest: {
    cloud_mask: 'SCL cloud and shadow classes removed',
    mosaic: 'latest-clear-pixel',
    reprojection: 'EPSG:3857',
    tools: { gdal: '3.10.0' },
  },
});

describe('provider-neutral offline package publication boundary', () => {
  test('accepts a complete Copernicus and OSM-derived evidence manifest', () => {
    expect(validateOfflinePackageManifest(validManifest())).toMatchObject({
      package_version: 'lebanon-s2-2026-08-v1',
      source_resolution_meters: 10,
    });
  });

  test('rejects incomplete provenance and unsupported source metadata', () => {
    expect(() =>
      validateOfflinePackageManifest({
        ...validManifest(),
        source_scene_ids: [],
      }),
    ).toThrow('OFFLINE_PACKAGE_MANIFEST_INVALID');
    expect(() =>
      validateOfflinePackageManifest({
        ...validManifest(),
        dataset_code: 'esri_world_imagery',
      }),
    ).toThrow('OFFLINE_PACKAGE_MANIFEST_INVALID');
  });

  test('requires a structurally complete zip envelope before upload', async () => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'terraleb-offline-zip-'));
    const validPath = path.join(directory, 'valid.zip');
    const invalidPath = path.join(directory, 'invalid.zip');
    try {
      const zip = new AdmZip();
      zip.addFile('manifest.json', Buffer.from(JSON.stringify(validManifest())));
      zip.addFile('tiles/7/76/51.tile', Buffer.from('tile'));
      zip.writeZip(validPath);
      await fs.writeFile(invalidPath, 'not-a-package');

      await expect(assertZipEnvelope(validPath)).resolves.toBeUndefined();
      await expect(readEmbeddedManifest(validPath)).resolves.toMatchObject({
        package_version: 'lebanon-s2-2026-08-v1',
      });
      await expect(assertZipEnvelope(invalidPath)).rejects.toThrow('OFFLINE_PACKAGE_ZIP_INVALID');
    } finally {
      await fs.rm(directory, { recursive: true, force: true });
    }
  });

  test('rejects an archive whose first entry is not its bounded manifest', async () => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'terraleb-offline-order-'));
    const packagePath = path.join(directory, 'invalid.zip');
    try {
      const zip = new AdmZip();
      zip.addFile('tiles/7/76/51.tile', Buffer.from('tile'));
      zip.writeZip(packagePath);
      await expect(readEmbeddedManifest(packagePath)).rejects.toThrow(
        'OFFLINE_PACKAGE_MANIFEST_MISSING',
      );
    } finally {
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
});
