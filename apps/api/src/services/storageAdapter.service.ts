import { createHash, randomUUID } from 'node:crypto';
import { constants as fsConstants, createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import type { Readable } from 'node:stream';

type StorageBucket = 'uploads' | 'exports';

interface StorageObjectLocation {
  bucket: StorageBucket;
  key: string;
  reference: string;
  localPath: string;
  size: number;
}

interface StorageObjectInfo extends StorageObjectLocation {
  sha256: string;
}

interface StorageListEntry {
  bucket: StorageBucket;
  key: string;
  reference: string;
  localPath: string;
  kind: 'file' | 'symlink';
  size: number | null;
}

interface VerifiedCopyResult {
  source: StorageObjectInfo;
  destination: StorageObjectInfo;
  destinationAlreadyExisted: boolean;
}

interface StorageAdapter {
  readonly driver: string;
  reference(bucket: StorageBucket, key: string): string;
  resolve(
    reference: string,
    allowedBuckets?: readonly StorageBucket[],
  ): { bucket: StorageBucket; key: string; reference: string; localPath: string } | null;
  locate(
    reference: string,
    allowedBuckets?: readonly StorageBucket[],
  ): Promise<StorageObjectLocation>;
  info(reference: string, allowedBuckets?: readonly StorageBucket[]): Promise<StorageObjectInfo>;
  exists(reference: string, allowedBuckets?: readonly StorageBucket[]): Promise<boolean>;
  openReadStream(
    reference: string,
    allowedBuckets?: readonly StorageBucket[],
  ): Promise<Readable>;
  writeExclusive(reference: string, contents: Buffer): Promise<StorageObjectInfo>;
  writeAtomic(reference: string, contents: Buffer): Promise<StorageObjectInfo>;
  copyVerified(
    sourceReference: string,
    destinationReference: string,
    expected?: { size?: number; sha256?: string },
  ): Promise<VerifiedCopyResult>;
  remove(reference: string): Promise<void>;
  list(bucket: StorageBucket, prefix?: string): Promise<StorageListEntry[]>;
}

const canonicalPattern = /^storage:\/\/(uploads|exports)\/(.+)$/;
const sha256Pattern = /^[0-9a-f]{64}$/;

const safeStorageKey = (value: string): string => {
  const key = value.trim();
  const segments = key.split('/');
  if (
    key.length === 0 ||
    Buffer.byteLength(key, 'utf8') > 1024 ||
    key.startsWith('/') ||
    key.endsWith('/') ||
    key.includes('\\') ||
    key.includes('\0') ||
    key.includes('%') ||
    path.posix.normalize(key) !== key ||
    segments.some((segment) => segment.length === 0 || segment === '.' || segment === '..')
  ) {
    throw new Error('Storage key is invalid.');
  }
  return key;
};

const isContainedPath = (root: string, candidate: string): boolean => {
  const relative = path.relative(root, candidate);
  return relative.length > 0 && !relative.startsWith('..') && !path.isAbsolute(relative);
};

const assertNoSymlinkTraversal = async (
  root: string,
  candidate: string,
  allowMissing: boolean,
): Promise<void> => {
  if (candidate !== root && !isContainedPath(root, candidate)) {
    throw new Error('Storage path is outside its configured root.');
  }
  const relative = path.relative(root, candidate);
  const segments = relative.length > 0 ? relative.split(path.sep) : [];
  const paths = [root];
  for (const segment of segments) {
    paths.push(path.join(paths.at(-1) as string, segment));
  }
  for (let index = 0; index < paths.length; index += 1) {
    let stat;
    try {
      stat = await fs.lstat(paths[index]);
    } catch (error: unknown) {
      if (allowMissing && (error as NodeJS.ErrnoException)?.code === 'ENOENT') {
        return;
      }
      throw error;
    }
    if (stat.isSymbolicLink()) {
      throw new Error('Storage path traverses a symbolic link.');
    }
    if (index < paths.length - 1 && !stat.isDirectory()) {
      throw new Error('Storage path traverses a non-directory component.');
    }
  }
};

const hashFile = async (filePath: string): Promise<string> =>
  new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.once('error', reject);
    stream.once('end', () => resolve(hash.digest('hex')));
  });

class LocalStorageAdapter implements StorageAdapter {
  readonly driver = 'local';

  constructor(
    private readonly rootOverrides: Partial<Record<StorageBucket, string>> = {},
  ) {}

  private root(bucket: StorageBucket): string {
    const configured =
      this.rootOverrides[bucket] ??
      (bucket === 'uploads'
        ? process.env.UPLOAD_DIR ?? './uploads'
        : process.env.EXPORT_DIR ?? './exports');
    return path.resolve(configured);
  }

  private async prepareParent(
    resolved: { bucket: StorageBucket; localPath: string },
  ): Promise<void> {
    const root = this.root(resolved.bucket);
    const parent = path.dirname(resolved.localPath);
    if (parent !== root && !isContainedPath(root, parent)) {
      throw new Error('Storage destination parent is outside its configured root.');
    }
    try {
      await fs.mkdir(root, { recursive: true });
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException)?.code !== 'EEXIST') {
        throw error;
      }
    }
    const rootStat = await fs.lstat(root);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
      throw new Error('Configured storage root must be a real directory.');
    }

    let current = root;
    const relative = path.relative(root, parent);
    for (const segment of relative.length > 0 ? relative.split(path.sep) : []) {
      current = path.join(current, segment);
      try {
        await fs.mkdir(current);
      } catch (error: unknown) {
        if ((error as NodeJS.ErrnoException)?.code !== 'EEXIST') {
          throw error;
        }
      }
      const stat = await fs.lstat(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new Error('Storage path traverses a non-directory or symbolic link.');
      }
    }
  }

  reference(bucket: StorageBucket, key: string): string {
    return `storage://${bucket}/${safeStorageKey(key)}`;
  }

  resolve(
    value: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): { bucket: StorageBucket; key: string; reference: string; localPath: string } | null {
    if (typeof value !== 'string' || value.trim().length === 0) {
      return null;
    }
    const reference = value.trim();
    const canonical = canonicalPattern.exec(reference);
    if (canonical) {
      const bucket = canonical[1] as StorageBucket;
      if (!allowedBuckets.includes(bucket)) {
        return null;
      }
      let key: string;
      try {
        key = safeStorageKey(canonical[2]);
      } catch {
        return null;
      }
      const root = this.root(bucket);
      const localPath = path.resolve(root, ...key.split('/'));
      if (!isContainedPath(root, localPath)) {
        return null;
      }
      return {
        bucket,
        key,
        reference: this.reference(bucket, key),
        localPath,
      };
    }

    const localPath = path.resolve(reference);
    for (const bucket of allowedBuckets) {
      const root = this.root(bucket);
      if (!isContainedPath(root, localPath)) {
        continue;
      }
      const key = path.relative(root, localPath).split(path.sep).join('/');
      try {
        return {
          bucket,
          key: safeStorageKey(key),
          reference: this.reference(bucket, key),
          localPath,
        };
      } catch {
        return null;
      }
    }
    return null;
  }

  async locate(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<StorageObjectLocation> {
    const resolved = this.resolve(reference, allowedBuckets);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await assertNoSymlinkTraversal(
      this.root(resolved.bucket),
      resolved.localPath,
      false,
    );
    const stat = await fs.lstat(resolved.localPath);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error('Storage reference does not identify a regular file.');
    }
    return {
      ...resolved,
      size: stat.size,
    };
  }

  async info(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<StorageObjectInfo> {
    const before = await this.locate(reference, allowedBuckets);
    const beforeStat = await fs.lstat(before.localPath);
    const sha256 = await hashFile(before.localPath);
    const after = await this.locate(reference, allowedBuckets);
    const afterStat = await fs.lstat(after.localPath);
    if (
      before.size !== after.size ||
      beforeStat.mtimeMs !== afterStat.mtimeMs ||
      beforeStat.ctimeMs !== afterStat.ctimeMs ||
      beforeStat.ino !== afterStat.ino
    ) {
      throw new Error('Storage object changed while it was being inspected.');
    }
    return {
      ...after,
      sha256,
    };
  }

  async exists(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<boolean> {
    try {
      await this.locate(reference, allowedBuckets);
      return true;
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
        return false;
      }
      throw error;
    }
  }

  async openReadStream(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<Readable> {
    const located = await this.locate(reference, allowedBuckets);
    return createReadStream(located.localPath);
  }

  async writeExclusive(reference: string, contents: Buffer): Promise<StorageObjectInfo> {
    const resolved = this.resolve(reference);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await this.prepareParent(resolved);
    await fs.writeFile(resolved.localPath, contents, { flag: 'wx', mode: 0o600 });
    return this.info(resolved.reference, [resolved.bucket]);
  }

  async writeAtomic(reference: string, contents: Buffer): Promise<StorageObjectInfo> {
    const resolved = this.resolve(reference);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await this.prepareParent(resolved);
    const directoryKey = path.posix.dirname(resolved.key);
    const temporaryKey =
      directoryKey === '.'
        ? `.${randomUUID()}.tmp`
        : `${directoryKey}/.${randomUUID()}.tmp`;
    const temporaryReference = this.reference(resolved.bucket, temporaryKey);
    const temporary = this.resolve(temporaryReference, [resolved.bucket]);
    if (!temporary) {
      throw new Error('Temporary storage reference is invalid.');
    }
    try {
      await fs.writeFile(temporary.localPath, contents, { flag: 'wx', mode: 0o600 });
      await fs.link(temporary.localPath, resolved.localPath);
    } catch (error) {
      await fs.rm(temporary.localPath, { force: true });
      throw error;
    }
    await fs.rm(temporary.localPath, { force: true }).catch(() => undefined);
    return this.info(resolved.reference, [resolved.bucket]);
  }

  async copyVerified(
    sourceReference: string,
    destinationReference: string,
    expected: { size?: number; sha256?: string } = {},
  ): Promise<VerifiedCopyResult> {
    if (expected.sha256 && !sha256Pattern.test(expected.sha256)) {
      throw new Error('Expected storage checksum is invalid.');
    }
    const sourceBefore = await this.info(sourceReference);
    if (
      (expected.size !== undefined && sourceBefore.size !== expected.size) ||
      (expected.sha256 !== undefined && sourceBefore.sha256 !== expected.sha256)
    ) {
      throw new Error('Source object does not match the reviewed size and checksum.');
    }

    const destination = this.resolve(destinationReference);
    if (!destination) {
      throw new Error('Destination storage reference is outside configured roots.');
    }
    await this.prepareParent(destination);
    let destinationAlreadyExisted = false;
    try {
      await fs.copyFile(
        sourceBefore.localPath,
        destination.localPath,
        fsConstants.COPYFILE_EXCL,
      );
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException)?.code !== 'EEXIST') {
        throw error;
      }
      destinationAlreadyExisted = true;
    }

    try {
      const [sourceAfter, destinationAfter] = await Promise.all([
        this.info(sourceBefore.reference, [sourceBefore.bucket]),
        this.info(destination.reference, [destination.bucket]),
      ]);
      if (
        sourceAfter.size !== sourceBefore.size ||
        sourceAfter.sha256 !== sourceBefore.sha256 ||
        destinationAfter.size !== sourceBefore.size ||
        destinationAfter.sha256 !== sourceBefore.sha256
      ) {
        throw new Error('Copied storage object failed size or checksum verification.');
      }
      return {
        source: sourceAfter,
        destination: destinationAfter,
        destinationAlreadyExisted,
      };
    } catch (error) {
      if (!destinationAlreadyExisted) {
        await fs.rm(destination.localPath, { force: true });
      }
      throw error;
    }
  }

  async remove(reference: string): Promise<void> {
    const resolved = this.resolve(reference);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await assertNoSymlinkTraversal(
      this.root(resolved.bucket),
      resolved.localPath,
      true,
    );
    await fs.unlink(resolved.localPath);
  }

  async list(bucket: StorageBucket, prefix = ''): Promise<StorageListEntry[]> {
    const root = this.root(bucket);
    const normalizedPrefix = prefix.length > 0 ? safeStorageKey(prefix) : '';
    const start = normalizedPrefix
      ? path.resolve(root, ...normalizedPrefix.split('/'))
      : root;
    if (start !== root && !isContainedPath(root, start)) {
      throw new Error('Storage inventory prefix is outside its configured root.');
    }
    await assertNoSymlinkTraversal(root, start, true);

    const entries: StorageListEntry[] = [];
    const visit = async (directory: string): Promise<void> => {
      try {
        await assertNoSymlinkTraversal(root, directory, false);
      } catch (error: unknown) {
        if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
          return;
        }
        throw error;
      }
      let children;
      try {
        children = await fs.readdir(directory, { withFileTypes: true });
      } catch (error: unknown) {
        if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
          return;
        }
        throw error;
      }
      for (const child of children) {
        const localPath = path.join(directory, child.name);
        const key = path.relative(root, localPath).split(path.sep).join('/');
        const stat = await fs.lstat(localPath);
        if (stat.isSymbolicLink()) {
          entries.push({
            bucket,
            key,
            reference: this.reference(bucket, key),
            localPath,
            kind: 'symlink',
            size: null,
          });
        } else if (stat.isDirectory()) {
          await visit(localPath);
        } else if (stat.isFile()) {
          entries.push({
            bucket,
            key,
            reference: this.reference(bucket, key),
            localPath,
            kind: 'file',
            size: stat.size,
          });
        }
      }
    };
    await visit(start);
    return entries.sort((left, right) => left.reference.localeCompare(right.reference));
  }
}

const storageAdapter = new LocalStorageAdapter();

export {
  LocalStorageAdapter,
  hashFile,
  storageAdapter,
  type StorageAdapter,
  type StorageBucket,
  type StorageListEntry,
  type StorageObjectInfo,
  type StorageObjectLocation,
  type VerifiedCopyResult,
};
