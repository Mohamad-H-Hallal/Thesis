import crypto from 'node:crypto';

type MigrationChecksumRecord = {
  filename: string;
  checksum: string;
};

type MigrationSourceChecksumRecord = MigrationChecksumRecord & {
  compatibleChecksums?: readonly string[];
};

type MigrationChecksumCompatibilityEntry = {
  filename: string;
  sourceChecksum: string;
  acceptedChecksums: string[];
  reason: string;
};

type MigrationChecksumCompatibilityConfig = {
  version: 1;
  migrations: MigrationChecksumCompatibilityEntry[];
};

const SHA256_PATTERN = /^[0-9a-f]{64}$/;

const sha256 = (value: string): string => crypto.createHash('sha256').update(value).digest('hex');

const normalizeMigrationSql = (sql: string): string => sql.replace(/\r\n?/g, '\n');

const calculateMigrationChecksum = (sql: string): string => sha256(normalizeMigrationSql(sql));

const calculateCompatibleMigrationChecksums = (sql: string): string[] => {
  const normalized = normalizeMigrationSql(sql);
  return [...new Set([sha256(sql), sha256(normalized), sha256(normalized.replace(/\n/g, '\r\n'))])];
};

const resolveMigrationChecksumCompatibility = (
  value: unknown,
  available: readonly MigrationChecksumRecord[],
): Map<string, readonly string[]> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('Migration checksum compatibility file must be an object');
  }

  const config = value as Partial<MigrationChecksumCompatibilityConfig>;
  if (config.version !== 1 || !Array.isArray(config.migrations)) {
    throw new Error(
      'Migration checksum compatibility file must use version 1 and a migrations array',
    );
  }

  const availableByFilename = new Map(
    available.map((migration) => [migration.filename, migration.checksum]),
  );
  const resolved = new Map<string, readonly string[]>();

  for (const valueEntry of config.migrations) {
    if (typeof valueEntry !== 'object' || valueEntry === null || Array.isArray(valueEntry)) {
      throw new Error('Migration checksum compatibility entries must be objects');
    }
    const entry = valueEntry as Partial<MigrationChecksumCompatibilityEntry>;
    if (
      typeof entry.filename !== 'string' ||
      typeof entry.sourceChecksum !== 'string' ||
      !Array.isArray(entry.acceptedChecksums) ||
      typeof entry.reason !== 'string' ||
      entry.reason.trim().length === 0
    ) {
      throw new Error('Invalid migration checksum compatibility entry');
    }
    if (
      !SHA256_PATTERN.test(entry.sourceChecksum) ||
      entry.acceptedChecksums.length === 0 ||
      !entry.acceptedChecksums.every(
        (checksum): checksum is string =>
          typeof checksum === 'string' && SHA256_PATTERN.test(checksum),
      )
    ) {
      throw new Error(`Invalid SHA-256 checksum in compatibility entry: ${entry.filename}`);
    }
    if (resolved.has(entry.filename)) {
      throw new Error(`Duplicate migration checksum compatibility entry: ${entry.filename}`);
    }

    const currentChecksum = availableByFilename.get(entry.filename);
    if (currentChecksum === undefined) {
      throw new Error(`Compatibility entry references a missing migration: ${entry.filename}`);
    }
    if (currentChecksum !== entry.sourceChecksum) {
      throw new Error(`Compatibility entry source checksum is stale: ${entry.filename}`);
    }

    resolved.set(entry.filename, [...new Set(entry.acceptedChecksums)]);
  }

  return resolved;
};

const findMigrationIntegrityIssues = (
  available: readonly MigrationSourceChecksumRecord[],
  applied: readonly MigrationChecksumRecord[],
): string[] => {
  const availableByFilename = new Map(
    available.map((migration) => [migration.filename, migration]),
  );
  const issues: string[] = [];

  for (const migration of applied) {
    const current = availableByFilename.get(migration.filename);
    if (current === undefined) {
      issues.push(`Applied migration is missing from the source tree: ${migration.filename}`);
      continue;
    }
    const compatibleChecksums = new Set([current.checksum, ...(current.compatibleChecksums ?? [])]);
    if (!compatibleChecksums.has(migration.checksum)) {
      issues.push(
        `Applied migration checksum changed: ${migration.filename} ` +
          `(database=${migration.checksum}, source=${current.checksum})`,
      );
    }
  }

  return issues;
};

export {
  type MigrationChecksumRecord,
  type MigrationChecksumCompatibilityConfig,
  type MigrationSourceChecksumRecord,
  calculateMigrationChecksum,
  calculateCompatibleMigrationChecksums,
  findMigrationIntegrityIssues,
  resolveMigrationChecksumCompatibility,
};
