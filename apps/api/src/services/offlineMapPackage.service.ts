import { createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { inflateRawSync } from 'node:zlib';
import { transaction } from '../config/database';
import { validateEnv } from '../config/env';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import { hashFile, storageAdapter } from './storageAdapter.service';

interface OfflinePackageManifest {
  schema_version: 1;
  package_version: string;
  tile_count: number;
  zoom_min: number;
  zoom_max: number;
  tile_scheme: 'xyz';
  dataset_code: 'copernicus_sentinel2_osm_labels';
  source_acquisition_start: string;
  source_acquisition_end: string;
  source_scene_ids: string[];
  source_terms_url: string;
  source_attribution: string;
  source_resolution_meters: number;
  processing_manifest: Record<string, unknown>;
}

const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const versionPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,49}$/;

const validateOfflinePackageManifest = (value: unknown): OfflinePackageManifest => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('OFFLINE_PACKAGE_MANIFEST_INVALID');
  }
  const manifest = value as Record<string, unknown>;
  const sceneIds = manifest.source_scene_ids;
  const processing = manifest.processing_manifest;
  if (
    manifest.schema_version !== 1 ||
    typeof manifest.package_version !== 'string' ||
    !versionPattern.test(manifest.package_version) ||
    !Number.isSafeInteger(manifest.tile_count) ||
    Number(manifest.tile_count) < 1 ||
    !Number.isSafeInteger(manifest.zoom_min) ||
    !Number.isSafeInteger(manifest.zoom_max) ||
    Number(manifest.zoom_min) < 0 ||
    Number(manifest.zoom_max) > 18 ||
    Number(manifest.zoom_max) < Number(manifest.zoom_min) ||
    manifest.tile_scheme !== 'xyz' ||
    manifest.dataset_code !== 'copernicus_sentinel2_osm_labels' ||
    typeof manifest.source_acquisition_start !== 'string' ||
    !datePattern.test(manifest.source_acquisition_start) ||
    typeof manifest.source_acquisition_end !== 'string' ||
    !datePattern.test(manifest.source_acquisition_end) ||
    manifest.source_acquisition_start > manifest.source_acquisition_end ||
    !Array.isArray(sceneIds) ||
    sceneIds.length < 1 ||
    sceneIds.length > 500 ||
    sceneIds.some(
      (scene) => typeof scene !== 'string' || !/^[A-Za-z0-9._:-]{1,160}$/.test(scene),
    ) ||
    typeof manifest.source_terms_url !== 'string' ||
    !/^https:\/\/\S{1,500}$/.test(manifest.source_terms_url) ||
    typeof manifest.source_attribution !== 'string' ||
    manifest.source_attribution.trim().length < 10 ||
    manifest.source_attribution.length > 1000 ||
    typeof manifest.source_resolution_meters !== 'number' ||
    !Number.isFinite(manifest.source_resolution_meters) ||
    manifest.source_resolution_meters < 1 ||
    manifest.source_resolution_meters > 100 ||
    !processing ||
    typeof processing !== 'object' ||
    Array.isArray(processing) ||
    Object.keys(processing as Record<string, unknown>).length < 1
  ) {
    throw new Error('OFFLINE_PACKAGE_MANIFEST_INVALID');
  }
  const processingJson = JSON.stringify(processing);
  if (Buffer.byteLength(processingJson, 'utf8') > 64 * 1024) {
    throw new Error('OFFLINE_PACKAGE_PROCESSING_MANIFEST_TOO_LARGE');
  }
  return manifest as unknown as OfflinePackageManifest;
};

const assertZipEnvelope = async (filePath: string): Promise<void> => {
  const handle = await fs.open(filePath, 'r');
  try {
    const stat = await handle.stat();
    if (stat.size < 22) throw new Error('OFFLINE_PACKAGE_ZIP_INVALID');
    const start = Buffer.alloc(4);
    await handle.read(start, 0, start.length, 0);
    if (!start.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) {
      throw new Error('OFFLINE_PACKAGE_ZIP_INVALID');
    }
    const tailLength = Math.min(stat.size, 65_557);
    const tail = Buffer.alloc(tailLength);
    await handle.read(tail, 0, tailLength, stat.size - tailLength);
    if (tail.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06])) < 0) {
      throw new Error('OFFLINE_PACKAGE_ZIP_INVALID');
    }
  } finally {
    await handle.close();
  }
};

const stableJson = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${stableJson(entry)}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
};

const readEmbeddedManifest = async (filePath: string): Promise<OfflinePackageManifest> => {
  const handle = await fs.open(filePath, 'r');
  try {
    const header = Buffer.alloc(30);
    const { bytesRead } = await handle.read(header, 0, header.length, 0);
    if (bytesRead !== header.length || header.readUInt32LE(0) !== 0x04034b50) {
      throw new Error('OFFLINE_PACKAGE_MANIFEST_MISSING');
    }
    const flags = header.readUInt16LE(6);
    const compressionMethod = header.readUInt16LE(8);
    const compressedSize = header.readUInt32LE(18);
    const uncompressedSize = header.readUInt32LE(22);
    const fileNameLength = header.readUInt16LE(26);
    const extraLength = header.readUInt16LE(28);
    if (
      flags & 0x1 ||
      flags & 0x8 ||
      ![0, 8].includes(compressionMethod) ||
      compressedSize < 2 ||
      compressedSize > 256 * 1024 ||
      uncompressedSize < 2 ||
      uncompressedSize > 256 * 1024 ||
      fileNameLength < 1 ||
      fileNameLength > 64 ||
      extraLength > 4096
    ) {
      throw new Error('OFFLINE_PACKAGE_MANIFEST_INVALID');
    }
    const prefix = Buffer.alloc(fileNameLength + extraLength + compressedSize);
    const prefixResult = await handle.read(prefix, 0, prefix.length, header.length);
    if (prefixResult.bytesRead !== prefix.length) {
      throw new Error('OFFLINE_PACKAGE_MANIFEST_INVALID');
    }
    const fileName = prefix.subarray(0, fileNameLength).toString('utf8');
    if (fileName !== 'manifest.json') throw new Error('OFFLINE_PACKAGE_MANIFEST_MISSING');
    const compressed = prefix.subarray(fileNameLength + extraLength);
    const contents =
      compressionMethod === 0
        ? compressed
        : inflateRawSync(compressed, { maxOutputLength: 256 * 1024 });
    if (contents.length !== uncompressedSize) {
      throw new Error('OFFLINE_PACKAGE_MANIFEST_INVALID');
    }
    return validateOfflinePackageManifest(JSON.parse(contents.toString('utf8')) as unknown);
  } catch (error) {
    if (error instanceof Error && error.message.startsWith('OFFLINE_PACKAGE_')) throw error;
    throw new Error('OFFLINE_PACKAGE_MANIFEST_INVALID');
  } finally {
    await handle.close();
  }
};

const publishOfflineMapPackage = async ({
  packagePath,
  manifest: untrustedManifest,
  actorUserId,
}: {
  packagePath: string;
  manifest: unknown;
  actorUserId: string;
}): Promise<Record<string, unknown>> => {
  const env = validateEnv();
  const manifest = validateOfflinePackageManifest(untrustedManifest);
  const absolutePath = path.resolve(packagePath);
  const stat = await fs.stat(absolutePath);
  if (!stat.isFile() || stat.size < 22 || stat.size > env.OFFLINE_PACKAGE_MAX_BYTES) {
    throw new Error('OFFLINE_PACKAGE_SIZE_INVALID');
  }
  await assertZipEnvelope(absolutePath);
  const embeddedManifest = await readEmbeddedManifest(absolutePath);
  if (stableJson(embeddedManifest) !== stableJson(manifest)) {
    throw new Error('OFFLINE_PACKAGE_MANIFEST_MISMATCH');
  }
  const sha256 = await hashFile(absolutePath);
  const objectReference = storageAdapter.reference(
    'offline',
    `packages/${manifest.package_version}/${sha256}.zip`,
  );
  let createdObject = false;
  try {
    try {
      await storageAdapter.writeStream(objectReference, createReadStream(absolutePath), {
        size: stat.size,
        sha256,
        contentType: 'application/zip',
      });
      createdObject = true;
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException)?.code !== 'EEXIST') throw error;
      const existing = await storageAdapter.info(objectReference, ['offline']);
      if (existing.size !== stat.size || existing.sha256 !== sha256) {
        throw new Error('OFFLINE_PACKAGE_OBJECT_CONFLICT');
      }
    }

    const published = await transaction(async (client) => {
      await client.query(`SELECT pg_advisory_xact_lock(hashtext('terraleb-offline-package'))`);
      const actor = await client.query<{ email: string; role: string; account_status: string }>(
        `SELECT email, role, account_status
         FROM "user"
         WHERE id = $1
         FOR UPDATE`,
        [actorUserId],
      );
      const actorRow = actor.rows[0];
      if (
        !actorRow ||
        actorRow.role !== 'admin' ||
        actorRow.account_status !== 'active' ||
        !isProtectedSuperAdminEmail(actorRow.email)
      ) {
        throw new Error('OFFLINE_PACKAGE_PROTECTED_SUPER_ADMIN_REQUIRED');
      }
      const source = await client.query<{
        offline_use_approved_at: Date | null;
        derived_work_approved_at: Date | null;
        redistribution_approved_at: Date | null;
        approval_reference: string | null;
        reviewed_at: Date | null;
      }>(
        `SELECT offline_use_approved_at, derived_work_approved_at,
                redistribution_approved_at, approval_reference, reviewed_at
         FROM data_source_license
         WHERE source_key = $1
         FOR SHARE`,
        [manifest.dataset_code],
      );
      const sourceRow = source.rows[0];
      if (
        !sourceRow?.offline_use_approved_at ||
        !sourceRow.derived_work_approved_at ||
        !sourceRow.redistribution_approved_at ||
        !sourceRow.approval_reference?.trim() ||
        !sourceRow.reviewed_at
      ) {
        throw new Error('OFFLINE_PACKAGE_SOURCE_APPROVAL_REQUIRED');
      }

      const existing = await client.query<{ id: string; artifact_sha256: string | null }>(
        `SELECT id, artifact_sha256
         FROM lebanon_offline_map
         WHERE version = $1
         FOR UPDATE`,
        [manifest.package_version],
      );
      if (existing.rows[0] && existing.rows[0].artifact_sha256 !== sha256) {
        throw new Error('OFFLINE_PACKAGE_VERSION_IMMUTABLE');
      }
      await client.query(
        `UPDATE lebanon_offline_map SET is_current = FALSE WHERE is_current = TRUE`,
      );
      const result = await client.query<{ id: string; version: string }>(
        `INSERT INTO lebanon_offline_map (
           version, zoom_level_min, zoom_level_max, downloaded_at, last_updated_at,
           tile_count, size_bytes, tile_source, is_current, artifact_reference,
           artifact_sha256, artifact_content_type, source_acquisition_start,
           source_acquisition_end, source_scene_ids, source_terms_url,
           source_attribution, source_resolution_meters, processing_manifest,
           published_at, published_by_user_id
         )
         VALUES (
           $1, $2, $3, NULL, CURRENT_TIMESTAMP, $4, $5, $6, TRUE, $7, $8,
           'application/zip', $9::date, $10::date, $11::text[], $12, $13, $14,
           $15::jsonb, CURRENT_TIMESTAMP, $16
         )
         ON CONFLICT (version) DO UPDATE SET
           is_current = TRUE,
           last_updated_at = CURRENT_TIMESTAMP,
           published_at = COALESCE(lebanon_offline_map.published_at, CURRENT_TIMESTAMP)
         RETURNING id, version`,
        [
          manifest.package_version,
          manifest.zoom_min,
          manifest.zoom_max,
          manifest.tile_count,
          stat.size,
          manifest.dataset_code,
          objectReference,
          sha256,
          manifest.source_acquisition_start,
          manifest.source_acquisition_end,
          manifest.source_scene_ids,
          manifest.source_terms_url,
          manifest.source_attribution.trim(),
          manifest.source_resolution_meters,
          JSON.stringify(manifest.processing_manifest),
          actorUserId,
        ],
      );
      await publishRealtimeChanges(
        [
          {
            scopeType: 'offline_map',
            scopeId: 'all',
            action: 'published',
            entityType: 'offline_map_package',
            entityId: result.rows[0]?.id,
            audience: { kind: 'all_authenticated' },
          },
        ],
        client,
      );
      return result.rows[0];
    });
    return {
      schemaVersion: 1,
      packageId: published?.id,
      packageVersion: manifest.package_version,
      artifactSha256: sha256,
      artifactBytes: stat.size,
      objectReference,
      published: true,
    };
  } catch (error) {
    if (createdObject) await storageAdapter.remove(objectReference).catch(() => undefined);
    throw error;
  }
};

export {
  assertZipEnvelope,
  readEmbeddedManifest,
  publishOfflineMapPackage,
  validateOfflinePackageManifest,
  type OfflinePackageManifest,
};
