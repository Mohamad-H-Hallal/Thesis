import { createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { encryptDatabaseDump } from '../services/databaseBackup.service';
import { S3StorageAdapter } from '../services/storageAdapter.service';

const required = (name: string): string => {
  const value = String(process.env[name] ?? '').trim();
  if (!value) throw new Error(`${name}_REQUIRED`);
  return value;
};

const positiveInteger = (name: string, fallback: number): number => {
  const parsed = Number.parseInt(String(process.env[name] ?? fallback), 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${name}_INVALID`);
  return parsed;
};

const runCommand = async (
  command: string,
  args: string[],
  options: { env?: NodeJS.ProcessEnv; maxErrorBytes?: number } = {},
): Promise<string> =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: options.env ?? process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    const maxErrorBytes = options.maxErrorBytes ?? 4096;
    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => {
      if (Buffer.concat(stderr).length < maxErrorBytes) stderr.push(chunk);
    });
    child.once('error', reject);
    child.once('close', (code) => {
      if (code === 0) {
        resolve(Buffer.concat(stdout).toString('utf8').trim());
      } else {
        reject(
          new Error(
            `${path.basename(command)} failed (${code ?? 'signal'}): ${Buffer.concat(stderr)
              .toString('utf8')
              .slice(0, maxErrorBytes)}`,
          ),
        );
      }
    });
  });

const runDatabaseBackup = async (): Promise<Record<string, unknown>> => {
  const databaseHost = required('DB_HOST');
  const databasePort = positiveInteger('DB_PORT', 5432);
  const databaseName = required('DB_NAME');
  const databaseUser = required('DB_USER');
  const databasePassword = required('DB_PASSWORD');
  const encryptionKey = Buffer.from(required('BACKUP_ENCRYPTION_KEY_BASE64'), 'base64');
  if (encryptionKey.length !== 32) throw new Error('BACKUP_ENCRYPTION_KEY_INVALID');

  const bucket = required('STORAGE_S3_BACKUPS_BUCKET');
  const adapter = new S3StorageAdapter({
    endpoint: required('STORAGE_S3_ENDPOINT'),
    region: required('STORAGE_S3_REGION'),
    accessKeyId: required('STORAGE_S3_ACCESS_KEY_ID'),
    secretAccessKey: required('STORAGE_S3_SECRET_ACCESS_KEY'),
    forcePathStyle: String(process.env.STORAGE_S3_FORCE_PATH_STYLE ?? 'true') !== 'false',
    prefix: String(process.env.STORAGE_S3_PREFIX ?? 'terraleb').trim(),
    tempDirectory: required('BACKUP_TEMP_DIR'),
    maxObjectBytes: positiveInteger('BACKUP_MAX_BYTES', 20 * 1024 * 1024 * 1024),
    requestTimeoutMs: positiveInteger('STORAGE_S3_REQUEST_TIMEOUT_MS', 30000),
    maxAttempts: positiveInteger('STORAGE_S3_MAX_ATTEMPTS', 3),
    serverSideEncryption: 'AES256',
    buckets: { uploads: bucket, exports: bucket, offline: bucket, ai: bucket, backups: bucket },
  });

  const workDirectory = await fs.mkdtemp(
    path.join(path.resolve(required('BACKUP_TEMP_DIR')), 'db-'),
  );
  const plaintextPath = path.join(workDirectory, 'database.dump');
  const encryptedPath = `${plaintextPath}.tldb`;
  const createdAt = new Date();
  const backupId = `${createdAt.toISOString().replaceAll(':', '').replaceAll('.', '')}-${randomUUID()}`;
  const datePrefix = createdAt.toISOString().slice(0, 10).replaceAll('-', '/');
  const objectReference = adapter.reference(
    'backups',
    `database/${datePrefix}/${backupId}.dump.tldb`,
  );
  const manifestReference = adapter.reference(
    'backups',
    `database/${datePrefix}/${backupId}.manifest.json`,
  );
  let uploadedObject = false;
  try {
    const commandEnvironment = { ...process.env, PGPASSWORD: databasePassword };
    await runCommand(
      'pg_dump',
      [
        '--host',
        databaseHost,
        '--port',
        String(databasePort),
        '--username',
        databaseUser,
        '--dbname',
        databaseName,
        '--format=custom',
        '--no-owner',
        '--no-privileges',
        '--file',
        plaintextPath,
      ],
      { env: commandEnvironment },
    );
    await runCommand('pg_restore', ['--list', plaintextPath]);
    const pgDumpVersion = await runCommand('pg_dump', ['--version']);
    const encrypted = await encryptDatabaseDump({
      plaintextPath,
      encryptedPath,
      key: encryptionKey,
    });
    const stored = await adapter.writeStream(objectReference, createReadStream(encryptedPath), {
      size: encrypted.encryptedBytes,
      sha256: encrypted.encryptedSha256,
      contentType: 'application/octet-stream',
    });
    uploadedObject = true;
    const manifest = {
      schemaVersion: 1,
      backupId,
      createdAt: createdAt.toISOString(),
      objectReference,
      encryption: {
        algorithm: 'AES-256-GCM',
        envelopeVersion: 'TLDB1',
        keyId: required('BACKUP_ENCRYPTION_KEY_ID'),
        iv: encrypted.iv,
      },
      plaintext: { bytes: encrypted.plaintextBytes, sha256: encrypted.plaintextSha256 },
      encrypted: { bytes: stored.size, sha256: stored.sha256 },
      pgDumpVersion,
      pgRestoreListValidated: true,
    };
    const manifestBuffer = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
    await adapter.writeExclusive(manifestReference, manifestBuffer);
    return { ...manifest, manifestReference };
  } catch (error) {
    if (uploadedObject) await adapter.remove(objectReference).catch(() => undefined);
    await adapter.remove(manifestReference).catch(() => undefined);
    throw error;
  } finally {
    encryptionKey.fill(0);
    await fs.rm(workDirectory, { recursive: true, force: true });
  }
};

if (require.main === module) {
  void runDatabaseBackup()
    .then((evidence) => process.stdout.write(`${JSON.stringify(evidence)}\n`))
    .catch((error) => {
      process.stderr.write(
        `Database backup failed: ${error instanceof Error ? error.message : String(error)}\n`,
      );
      process.exitCode = 1;
    });
}

export { runDatabaseBackup };
