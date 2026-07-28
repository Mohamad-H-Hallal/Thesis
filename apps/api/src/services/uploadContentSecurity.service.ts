import path from 'node:path';
import { TextDecoder } from 'node:util';
import { AppError } from '../middleware/error';

const AdmZip = require('adm-zip');

type ImportFileType = 'geojson' | 'shapefile_zip' | 'kml' | 'kmz' | 'csv' | 'xlsx';

interface ArchiveInspection {
  entryCount: number;
  expandedBytes: number;
  maximumCompressionRatio: number;
  entryNames: string[];
}

interface ImportContentInspection {
  detectedType: 'json' | 'xml' | 'text' | 'zip';
  archive?: ArchiveInspection;
}

const positiveInteger = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};

const rejection = (message: string, code: string): AppError =>
  new AppError(message, 422, {
    code,
    disposition: 'permanent_rejection',
    retryable: false,
  });

const hasZipSignature = (buffer: Buffer): boolean =>
  buffer.length >= 4 &&
  buffer[0] === 0x50 &&
  buffer[1] === 0x4b &&
  ((buffer[2] === 0x03 && buffer[3] === 0x04) ||
    (buffer[2] === 0x05 && buffer[3] === 0x06) ||
    (buffer[2] === 0x07 && buffer[3] === 0x08));

const decodeUtf8 = (buffer: Buffer): string => {
  if (buffer.includes(0)) {
    throw rejection('The uploaded text file contains binary data.', 'UPLOAD_SIGNATURE_REJECTED');
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch {
    throw rejection('The uploaded text file is not valid UTF-8.', 'UPLOAD_SIGNATURE_REJECTED');
  }
};

const unsafeArchiveName = (name: string): boolean => {
  if (
    name.length === 0 ||
    Buffer.byteLength(name, 'utf8') > 255 ||
    name.includes('\0') ||
    name.includes('\\') ||
    name.startsWith('/') ||
    /^[A-Za-z]:/.test(name)
  ) {
    return true;
  }
  const segments = name.split('/').filter((segment) => segment.length > 0);
  return (
    segments.length === 0 ||
    segments.some((segment) => segment === '.' || segment === '..') ||
    path.posix.normalize(name).startsWith('../')
  );
};

const isSymlinkEntry = (entry: any): boolean => {
  const attributes = Number(entry.attr ?? entry.header?.attr ?? 0) >>> 0;
  const unixMode = (attributes >>> 16) & 0o170000;
  return unixMode === 0o120000;
};

const isEncryptedEntry = (entry: any): boolean => {
  const flags = Number(entry.header?.flags ?? 0);
  return entry.header?.encrypted === true || (flags & 0x1) === 0x1;
};

const nestedArchiveExtension = (name: string): boolean =>
  /\.(?:zip|kmz|xlsx|xlsm|jar|7z|rar|tar|tgz|gz|bz2|xz)$/i.test(name);

const inspectArchive = (buffer: Buffer, fileType: ImportFileType): ArchiveInspection => {
  if (!hasZipSignature(buffer)) {
    throw rejection(
      'The uploaded archive signature does not match its file type.',
      'UPLOAD_SIGNATURE_REJECTED',
    );
  }

  let zip: any;
  try {
    zip = new AdmZip(buffer);
  } catch {
    throw rejection('The uploaded archive could not be read safely.', 'UPLOAD_ARCHIVE_REJECTED');
  }
  const entries = zip.getEntries();
  const maxEntries = positiveInteger(process.env.ARCHIVE_MAX_ENTRIES, 1000);
  const maxExpandedBytes = positiveInteger(
    process.env.ARCHIVE_MAX_EXPANDED_BYTES,
    100 * 1024 * 1024,
  );
  const maxEntryBytes = positiveInteger(process.env.ARCHIVE_MAX_ENTRY_BYTES, 50 * 1024 * 1024);
  const maxCompressionRatio = positiveInteger(process.env.ARCHIVE_MAX_COMPRESSION_RATIO, 100);
  if (entries.length === 0 || entries.length > maxEntries) {
    throw rejection(
      'The uploaded archive contains an unsafe number of entries.',
      'UPLOAD_ARCHIVE_REJECTED',
    );
  }

  let expandedBytes = 0;
  let maximumCompressionRatio = 1;
  const entryNames: string[] = [];
  for (const entry of entries) {
    const entryName = String(entry.entryName ?? '');
    const rawEntryName = Buffer.isBuffer(entry.rawEntryName)
      ? entry.rawEntryName.toString('utf8')
      : entryName;
    if (unsafeArchiveName(entryName) || unsafeArchiveName(rawEntryName)) {
      throw rejection(
        'The uploaded archive contains an unsafe entry path.',
        'UPLOAD_ARCHIVE_REJECTED',
      );
    }
    if (isSymlinkEntry(entry)) {
      throw rejection('The uploaded archive contains a symbolic link.', 'UPLOAD_ARCHIVE_REJECTED');
    }
    if (isEncryptedEntry(entry)) {
      throw rejection('Encrypted archive entries are not supported.', 'UPLOAD_ARCHIVE_REJECTED');
    }

    const isDirectory = entry.isDirectory === true || entryName.endsWith('/');
    if (!isDirectory && nestedArchiveExtension(entryName)) {
      throw rejection('Nested archives are not supported.', 'UPLOAD_ARCHIVE_REJECTED');
    }
    const expandedSize = Number(entry.header?.size ?? 0);
    const compressedSize = Number(entry.header?.compressedSize ?? 0);
    if (
      !Number.isSafeInteger(expandedSize) ||
      expandedSize < 0 ||
      !Number.isSafeInteger(compressedSize) ||
      compressedSize < 0 ||
      expandedSize > maxEntryBytes
    ) {
      throw rejection(
        'The uploaded archive contains an oversized entry.',
        'UPLOAD_ARCHIVE_REJECTED',
      );
    }
    expandedBytes += expandedSize;
    if (!Number.isSafeInteger(expandedBytes) || expandedBytes > maxExpandedBytes) {
      throw rejection(
        'The uploaded archive expands beyond the allowed size.',
        'UPLOAD_ARCHIVE_REJECTED',
      );
    }
    const ratio =
      expandedSize === 0
        ? 1
        : compressedSize === 0
          ? Number.POSITIVE_INFINITY
          : expandedSize / compressedSize;
    if (!Number.isFinite(ratio) || ratio > maxCompressionRatio) {
      throw rejection(
        'The uploaded archive exceeds the allowed compression ratio.',
        'UPLOAD_ARCHIVE_REJECTED',
      );
    }
    maximumCompressionRatio = Math.max(maximumCompressionRatio, ratio);
    entryNames.push(entryName);
  }

  const lowerNames = entryNames.map((name) => name.toLowerCase());
  if (fileType === 'kmz' && !lowerNames.some((name) => name.endsWith('.kml'))) {
    throw rejection('The KMZ archive does not contain a KML document.', 'UPLOAD_ARCHIVE_REJECTED');
  }
  if (
    fileType === 'xlsx' &&
    (!lowerNames.includes('[content_types].xml') ||
      !lowerNames.includes('xl/workbook.xml') ||
      !lowerNames.includes('xl/_rels/workbook.xml.rels'))
  ) {
    throw rejection(
      'The Excel archive does not contain the required workbook structure.',
      'UPLOAD_ARCHIVE_REJECTED',
    );
  }
  if (fileType === 'xlsx' && lowerNames.some((name) => name.endsWith('vbaproject.bin'))) {
    throw rejection('Macro-enabled Excel content is not supported.', 'UPLOAD_ARCHIVE_REJECTED');
  }

  return {
    entryCount: entries.length,
    expandedBytes,
    maximumCompressionRatio,
    entryNames,
  };
};

const inspectImportContent = (
  buffer: Buffer,
  fileType: ImportFileType,
): ImportContentInspection => {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    throw rejection('The uploaded file is empty or unreadable.', 'UPLOAD_SIGNATURE_REJECTED');
  }

  if (fileType === 'shapefile_zip' || fileType === 'kmz' || fileType === 'xlsx') {
    return {
      detectedType: 'zip',
      archive: inspectArchive(buffer, fileType),
    };
  }

  const text = decodeUtf8(buffer)
    .replace(/^\uFEFF/, '')
    .trimStart();
  if (fileType === 'geojson') {
    if (!text.startsWith('{')) {
      throw rejection(
        'The uploaded GeoJSON signature is not valid JSON object content.',
        'UPLOAD_SIGNATURE_REJECTED',
      );
    }
    return { detectedType: 'json' };
  }
  if (fileType === 'kml') {
    const prefix = text.slice(0, 8192);
    if (!prefix.startsWith('<') || !/<(?:[A-Za-z0-9_-]+:)?kml(?:\s|>)/i.test(prefix)) {
      throw rejection(
        'The uploaded KML signature is not valid XML/KML content.',
        'UPLOAD_SIGNATURE_REJECTED',
      );
    }
    return { detectedType: 'xml' };
  }
  return { detectedType: 'text' };
};

export {
  hasZipSignature,
  inspectArchive,
  inspectImportContent,
  type ArchiveInspection,
  type ImportContentInspection,
  type ImportFileType,
};
