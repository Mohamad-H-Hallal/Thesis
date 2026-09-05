import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import { Transform, type TransformCallback } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { hashFile } from './storageAdapter.service';

const BACKUP_MAGIC = Buffer.from('TLDB1', 'ascii');
const BACKUP_IV_BYTES = 12;
const BACKUP_TAG_BYTES = 16;

class BackupEncryptionTransform extends Transform {
  private readonly cipher;

  private headerWritten = false;

  constructor(
    key: Buffer,
    private readonly iv: Buffer,
  ) {
    super();
    this.cipher = createCipheriv('aes-256-gcm', key, iv);
  }

  private writeHeader(): void {
    if (!this.headerWritten) {
      this.push(Buffer.concat([BACKUP_MAGIC, this.iv]));
      this.headerWritten = true;
    }
  }

  override _transform(chunk: Buffer, _encoding: BufferEncoding, callback: TransformCallback): void {
    try {
      this.writeHeader();
      callback(null, this.cipher.update(chunk));
    } catch (error) {
      callback(error as Error);
    }
  }

  override _flush(callback: TransformCallback): void {
    try {
      this.writeHeader();
      this.push(this.cipher.final());
      this.push(this.cipher.getAuthTag());
      callback();
    } catch (error) {
      callback(error as Error);
    }
  }
}

const validateBackupKey = (key: Buffer): void => {
  if (key.length !== 32) {
    throw new Error('BACKUP_ENCRYPTION_KEY_INVALID');
  }
};

const encryptDatabaseDump = async ({
  plaintextPath,
  encryptedPath,
  key,
}: {
  plaintextPath: string;
  encryptedPath: string;
  key: Buffer;
}): Promise<{
  iv: string;
  plaintextSha256: string;
  encryptedSha256: string;
  plaintextBytes: number;
  encryptedBytes: number;
}> => {
  validateBackupKey(key);
  const iv = randomBytes(BACKUP_IV_BYTES);
  const plaintextBefore = await fs.stat(plaintextPath);
  await pipeline(
    createReadStream(plaintextPath),
    new BackupEncryptionTransform(key, iv),
    createWriteStream(encryptedPath, { flags: 'wx', mode: 0o600 }),
  );
  const [plaintextAfter, encryptedStat, plaintextSha256, encryptedSha256] = await Promise.all([
    fs.stat(plaintextPath),
    fs.stat(encryptedPath),
    hashFile(plaintextPath),
    hashFile(encryptedPath),
  ]);
  if (
    plaintextBefore.size <= 0 ||
    plaintextBefore.size !== plaintextAfter.size ||
    encryptedStat.size !==
      plaintextBefore.size + BACKUP_MAGIC.length + BACKUP_IV_BYTES + BACKUP_TAG_BYTES
  ) {
    throw new Error('BACKUP_ENVELOPE_VALIDATION_FAILED');
  }
  return {
    iv: iv.toString('base64'),
    plaintextSha256,
    encryptedSha256,
    plaintextBytes: plaintextBefore.size,
    encryptedBytes: encryptedStat.size,
  };
};

const decryptDatabaseBackup = async ({
  encryptedPath,
  plaintextPath,
  key,
}: {
  encryptedPath: string;
  plaintextPath: string;
  key: Buffer;
}): Promise<{ plaintextSha256: string; plaintextBytes: number }> => {
  validateBackupKey(key);
  const stat = await fs.stat(encryptedPath);
  const headerBytes = BACKUP_MAGIC.length + BACKUP_IV_BYTES;
  if (stat.size <= headerBytes + BACKUP_TAG_BYTES) {
    throw new Error('BACKUP_ENVELOPE_INVALID');
  }
  const handle = await fs.open(encryptedPath, 'r');
  const header = Buffer.alloc(headerBytes);
  const tag = Buffer.alloc(BACKUP_TAG_BYTES);
  try {
    await handle.read(header, 0, header.length, 0);
    await handle.read(tag, 0, tag.length, stat.size - tag.length);
  } finally {
    await handle.close();
  }
  if (!header.subarray(0, BACKUP_MAGIC.length).equals(BACKUP_MAGIC)) {
    throw new Error('BACKUP_ENVELOPE_VERSION_UNSUPPORTED');
  }
  const iv = header.subarray(BACKUP_MAGIC.length);
  const decipher = createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  await pipeline(
    createReadStream(encryptedPath, {
      start: headerBytes,
      end: stat.size - BACKUP_TAG_BYTES - 1,
    }),
    decipher,
    createWriteStream(plaintextPath, { flags: 'wx', mode: 0o600 }),
  );
  const plaintextStat = await fs.stat(plaintextPath);
  return {
    plaintextSha256: await hashFile(plaintextPath),
    plaintextBytes: plaintextStat.size,
  };
};

export {
  BACKUP_IV_BYTES,
  BACKUP_MAGIC,
  BACKUP_TAG_BYTES,
  decryptDatabaseBackup,
  encryptDatabaseDump,
};
