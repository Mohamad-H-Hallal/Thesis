import { createHash, randomUUID } from 'node:crypto';
import { constants as fsConstants, createReadStream, createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  S3Client,
  type HeadObjectCommandOutput,
} from '@aws-sdk/client-s3';
import { NodeHttpHandler } from '@smithy/node-http-handler';

type StorageBucket = 'uploads' | 'exports' | 'offline' | 'ai' | 'backups';

interface StorageObjectLocation {
  bucket: StorageBucket;
  key: string;
  reference: string;
  localPath: string;
  size: number;
  contentType?: string;
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
  releaseLocalCopy(reference: string, allowedBuckets?: readonly StorageBucket[]): Promise<void>;
  info(reference: string, allowedBuckets?: readonly StorageBucket[]): Promise<StorageObjectInfo>;
  exists(reference: string, allowedBuckets?: readonly StorageBucket[]): Promise<boolean>;
  openReadStream(reference: string, allowedBuckets?: readonly StorageBucket[]): Promise<Readable>;
  openReadRange(
    reference: string,
    range: { start: number; end: number },
    allowedBuckets?: readonly StorageBucket[],
  ): Promise<Readable>;
  writeStream(
    reference: string,
    contents: Readable,
    expected: { size: number; sha256: string; contentType?: string },
  ): Promise<StorageObjectInfo>;
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

const canonicalPattern = /^storage:\/\/(uploads|exports|offline|ai|backups)\/(.+)$/;
const sha256Pattern = /^[0-9a-f]{64}$/;

const contentTypeForKey = (key: string): string => {
  const extension = path.posix.extname(key).toLowerCase();
  return (
    (
      {
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.png': 'image/png',
        '.webp': 'image/webp',
        '.gif': 'image/gif',
        '.zip': 'application/zip',
        '.json': 'application/json',
        '.geojson': 'application/geo+json',
        '.csv': 'text/csv; charset=utf-8',
        '.pmtiles': 'application/vnd.pmtiles',
        '.mbtiles': 'application/vnd.sqlite3',
      } as Record<string, string>
    )[extension] ?? 'application/octet-stream'
  );
};

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

  constructor(private readonly rootOverrides: Partial<Record<StorageBucket, string>> = {}) {}

  private root(bucket: StorageBucket): string {
    const configured =
      this.rootOverrides[bucket] ??
      (bucket === 'uploads'
        ? (process.env.UPLOAD_DIR ?? './uploads')
        : bucket === 'exports'
          ? (process.env.EXPORT_DIR ?? './exports')
          : bucket === 'offline'
            ? (process.env.OFFLINE_PACKAGE_DIR ?? './offline-packages')
            : bucket === 'ai'
              ? (process.env.AI_PIPELINE_OUTPUT_ROOT ?? './ai-outputs')
              : (process.env.BACKUP_TEMP_DIR ?? './backups'));
    return path.resolve(configured);
  }

  private async prepareParent(resolved: {
    bucket: StorageBucket;
    localPath: string;
  }): Promise<void> {
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
    await assertNoSymlinkTraversal(this.root(resolved.bucket), resolved.localPath, false);
    const stat = await fs.lstat(resolved.localPath);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error('Storage reference does not identify a regular file.');
    }
    return {
      ...resolved,
      size: stat.size,
      contentType: contentTypeForKey(resolved.key),
    };
  }

  async releaseLocalCopy(
    _reference: string,
    _allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<void> {
    // A local object is authoritative storage, not an expendable materialization.
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

  async openReadRange(
    reference: string,
    range: { start: number; end: number },
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<Readable> {
    if (
      !Number.isSafeInteger(range.start) ||
      !Number.isSafeInteger(range.end) ||
      range.start < 0 ||
      range.end < range.start
    ) {
      throw new Error('Storage byte range is invalid.');
    }
    const located = await this.locate(reference, allowedBuckets);
    if (range.end >= located.size) throw new Error('Storage byte range exceeds the object.');
    return createReadStream(located.localPath, { start: range.start, end: range.end });
  }

  async writeStream(
    reference: string,
    contents: Readable,
    expected: { size: number; sha256: string; contentType?: string },
  ): Promise<StorageObjectInfo> {
    if (!sha256Pattern.test(expected.sha256) || expected.size < 0) {
      throw new Error('Expected storage size or checksum is invalid.');
    }
    const resolved = this.resolve(reference, ['uploads', 'exports', 'offline', 'ai', 'backups']);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await this.prepareParent(resolved);
    const temporaryPath = `${resolved.localPath}.${randomUUID()}.tmp`;
    const hash = createHash('sha256');
    let size = 0;
    const verifier = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length;
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    try {
      await pipeline(
        contents,
        verifier,
        createWriteStream(temporaryPath, { flags: 'wx', mode: 0o600 }),
      );
      const checksum = hash.digest('hex');
      if (size !== expected.size || checksum !== expected.sha256) {
        throw new Error('Streamed storage object failed size or checksum verification.');
      }
      await fs.link(temporaryPath, resolved.localPath);
    } catch (error) {
      await fs.rm(temporaryPath, { force: true });
      throw error;
    }
    await fs.rm(temporaryPath, { force: true });
    return this.info(resolved.reference, [resolved.bucket]);
  }

  async writeExclusive(reference: string, contents: Buffer): Promise<StorageObjectInfo> {
    const resolved = this.resolve(reference, ['uploads', 'exports', 'offline', 'ai', 'backups']);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await this.prepareParent(resolved);
    await fs.writeFile(resolved.localPath, contents, { flag: 'wx', mode: 0o600 });
    return this.info(resolved.reference, [resolved.bucket]);
  }

  async writeAtomic(reference: string, contents: Buffer): Promise<StorageObjectInfo> {
    const resolved = this.resolve(reference, ['uploads', 'exports', 'offline', 'ai', 'backups']);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await this.prepareParent(resolved);
    const directoryKey = path.posix.dirname(resolved.key);
    const temporaryKey =
      directoryKey === '.' ? `.${randomUUID()}.tmp` : `${directoryKey}/.${randomUUID()}.tmp`;
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
    const sourceBefore = await this.info(sourceReference, [
      'uploads',
      'exports',
      'offline',
      'ai',
      'backups',
    ]);
    if (
      (expected.size !== undefined && sourceBefore.size !== expected.size) ||
      (expected.sha256 !== undefined && sourceBefore.sha256 !== expected.sha256)
    ) {
      throw new Error('Source object does not match the reviewed size and checksum.');
    }

    const destination = this.resolve(destinationReference, [
      'uploads',
      'exports',
      'offline',
      'ai',
      'backups',
    ]);
    if (!destination) {
      throw new Error('Destination storage reference is outside configured roots.');
    }
    await this.prepareParent(destination);
    let destinationAlreadyExisted = false;
    try {
      await fs.copyFile(sourceBefore.localPath, destination.localPath, fsConstants.COPYFILE_EXCL);
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
    const resolved = this.resolve(reference, ['uploads', 'exports', 'offline', 'ai', 'backups']);
    if (!resolved) {
      throw new Error('Storage reference is outside configured roots.');
    }
    await assertNoSymlinkTraversal(this.root(resolved.bucket), resolved.localPath, true);
    await fs.unlink(resolved.localPath);
  }

  async list(bucket: StorageBucket, prefix = ''): Promise<StorageListEntry[]> {
    const root = this.root(bucket);
    const normalizedPrefix = prefix.length > 0 ? safeStorageKey(prefix) : '';
    const start = normalizedPrefix ? path.resolve(root, ...normalizedPrefix.split('/')) : root;
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

interface S3StorageAdapterOptions {
  endpoint: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  forcePathStyle: boolean;
  prefix: string;
  tempDirectory: string;
  maxObjectBytes: number;
  requestTimeoutMs: number;
  maxAttempts: number;
  serverSideEncryption: 'AES256' | 'SSE-C';
  customerKeyBase64?: string;
  buckets: Record<StorageBucket, string>;
  client?: S3Client;
}

const isCanonicalReference = (value: string): boolean => canonicalPattern.test(value.trim());

const isStorageNotFound = (error: unknown): boolean => {
  const candidate = error as {
    name?: string;
    Code?: string;
    $metadata?: { httpStatusCode?: number };
  };
  return (
    candidate?.$metadata?.httpStatusCode === 404 ||
    candidate?.name === 'NotFound' ||
    candidate?.name === 'NoSuchKey' ||
    candidate?.Code === 'NoSuchKey'
  );
};

const isStoragePreconditionFailure = (error: unknown): boolean => {
  const candidate = error as { name?: string; $metadata?: { httpStatusCode?: number } };
  return candidate?.$metadata?.httpStatusCode === 412 || candidate?.name === 'PreconditionFailed';
};

const readableObjectBody = (body: unknown): Readable => {
  if (body instanceof Readable) {
    return body;
  }
  if (body && typeof (body as AsyncIterable<Uint8Array>)[Symbol.asyncIterator] === 'function') {
    return Readable.from(body as AsyncIterable<Uint8Array>);
  }
  throw new Error('Object storage returned an unsupported response body.');
};

const hashReadable = async (
  stream: Readable,
  maxBytes: number,
): Promise<{ sha256: string; size: number }> => {
  const hash = createHash('sha256');
  let size = 0;
  for await (const chunk of stream) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > maxBytes) {
      stream.destroy();
      throw new Error('Storage object exceeds the configured maximum size.');
    }
    hash.update(buffer);
  }
  return { sha256: hash.digest('hex'), size };
};

class S3StorageAdapter implements StorageAdapter {
  readonly driver = 's3';

  private readonly client: S3Client;

  private readonly cacheAdapter: LocalStorageAdapter;

  private readonly legacyLocalAdapter: LocalStorageAdapter;

  constructor(private readonly options: S3StorageAdapterOptions) {
    if (options.serverSideEncryption === 'SSE-C') {
      const customerKey = Buffer.from(String(options.customerKeyBase64 ?? ''), 'base64');
      if (customerKey.length !== 32) {
        throw new Error('S3 SSE-C requires a 32-byte customer key.');
      }
    }
    this.client =
      options.client ??
      new S3Client({
        endpoint: options.endpoint,
        region: options.region,
        forcePathStyle: options.forcePathStyle,
        credentials: {
          accessKeyId: options.accessKeyId,
          secretAccessKey: options.secretAccessKey,
        },
        maxAttempts: options.maxAttempts,
        requestHandler: new NodeHttpHandler({
          connectionTimeout: options.requestTimeoutMs,
          requestTimeout: options.requestTimeoutMs,
        }),
      });
    const cacheRoots = Object.fromEntries(
      (['uploads', 'exports', 'offline', 'ai', 'backups'] as StorageBucket[]).map((bucket) => [
        bucket,
        path.join(path.resolve(options.tempDirectory), 'cache', bucket),
      ]),
    ) as Record<StorageBucket, string>;
    this.cacheAdapter = new LocalStorageAdapter(cacheRoots);
    this.legacyLocalAdapter = new LocalStorageAdapter();
  }

  private physicalBucket(bucket: StorageBucket): string {
    return this.options.buckets[bucket];
  }

  private customerEncryptionHeaders(): {
    SSECustomerAlgorithm?: 'AES256';
    SSECustomerKey?: string;
    SSECustomerKeyMD5?: string;
  } {
    if (this.options.serverSideEncryption === 'AES256') {
      return {};
    }
    const customerKeyBase64 = String(this.options.customerKeyBase64);
    return {
      SSECustomerAlgorithm: 'AES256',
      SSECustomerKey: customerKeyBase64,
      SSECustomerKeyMD5: createHash('md5')
        .update(Buffer.from(customerKeyBase64, 'base64'))
        .digest('base64'),
    };
  }

  private writeEncryptionHeaders(): {
    ServerSideEncryption?: 'AES256';
    SSECustomerAlgorithm?: 'AES256';
    SSECustomerKey?: string;
    SSECustomerKeyMD5?: string;
  } {
    return this.options.serverSideEncryption === 'AES256'
      ? { ServerSideEncryption: 'AES256' }
      : this.customerEncryptionHeaders();
  }

  private remoteKey(key: string): string {
    const prefix = this.options.prefix.replace(/^\/+|\/+$/g, '');
    return prefix ? `${prefix}/${key}` : key;
  }

  private canonical(
    value: string,
    allowedBuckets: readonly StorageBucket[],
  ): { bucket: StorageBucket; key: string; reference: string; localPath: string } | null {
    const match = canonicalPattern.exec(value.trim());
    if (!match) {
      return null;
    }
    const bucket = match[1] as StorageBucket;
    if (!allowedBuckets.includes(bucket)) {
      return null;
    }
    let key: string;
    try {
      key = safeStorageKey(match[2]);
    } catch {
      return null;
    }
    const reference = this.reference(bucket, key);
    return this.cacheAdapter.resolve(reference, [bucket]);
  }

  private async head(resolved: {
    bucket: StorageBucket;
    key: string;
  }): Promise<HeadObjectCommandOutput> {
    return this.client.send(
      new HeadObjectCommand({
        Bucket: this.physicalBucket(resolved.bucket),
        Key: this.remoteKey(resolved.key),
        ...this.customerEncryptionHeaders(),
      }),
    );
  }

  private async remoteReadStream(
    resolved: { bucket: StorageBucket; key: string },
    range?: { start: number; end: number },
  ): Promise<{ stream: Readable; contentType?: string; size?: number }> {
    const response = await this.client.send(
      new GetObjectCommand({
        Bucket: this.physicalBucket(resolved.bucket),
        Key: this.remoteKey(resolved.key),
        ...this.customerEncryptionHeaders(),
        ...(range ? { Range: `bytes=${range.start}-${range.end}` } : {}),
      }),
    );
    const size = response.ContentLength;
    if (size !== undefined && size > this.options.maxObjectBytes) {
      const body = response.Body as { destroy?: () => void } | undefined;
      body?.destroy?.();
      throw new Error('Storage object exceeds the configured maximum size.');
    }
    return {
      stream: readableObjectBody(response.Body),
      ...(response.ContentType ? { contentType: response.ContentType } : {}),
      ...(size !== undefined ? { size } : {}),
    };
  }

  reference(bucket: StorageBucket, key: string): string {
    return `storage://${bucket}/${safeStorageKey(key)}`;
  }

  resolve(
    value: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): { bucket: StorageBucket; key: string; reference: string; localPath: string } | null {
    if (typeof value !== 'string' || !value.trim()) {
      return null;
    }
    return (
      this.canonical(value, allowedBuckets) ??
      this.legacyLocalAdapter.resolve(value, allowedBuckets)
    );
  }

  async locate(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<StorageObjectLocation> {
    if (!isCanonicalReference(reference)) {
      return this.legacyLocalAdapter.locate(reference, allowedBuckets);
    }
    const remote = await this.info(reference, allowedBuckets);
    try {
      const cached = await this.cacheAdapter.info(remote.reference, [remote.bucket]);
      if (cached.size === remote.size && cached.sha256 === remote.sha256) {
        return { ...remote, localPath: cached.localPath };
      }
      await this.cacheAdapter.remove(remote.reference);
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException)?.code !== 'ENOENT') {
        await this.cacheAdapter.remove(remote.reference).catch(() => undefined);
      }
    }
    const { stream } = await this.remoteReadStream(remote);
    try {
      await this.cacheAdapter.writeStream(remote.reference, stream, {
        size: remote.size,
        sha256: remote.sha256,
        ...(remote.contentType ? { contentType: remote.contentType } : {}),
      });
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException)?.code !== 'EEXIST') {
        throw error;
      }
    }
    const cached = await this.cacheAdapter.info(remote.reference, [remote.bucket]);
    if (cached.size !== remote.size || cached.sha256 !== remote.sha256) {
      await this.cacheAdapter.remove(remote.reference).catch(() => undefined);
      throw new Error('Materialized storage object failed checksum verification.');
    }
    return { ...remote, localPath: cached.localPath };
  }

  async releaseLocalCopy(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<void> {
    if (!isCanonicalReference(reference)) {
      return;
    }
    const resolved = this.canonical(reference, allowedBuckets);
    if (!resolved) {
      throw new Error('Storage reference is outside configured buckets.');
    }
    await this.cacheAdapter.remove(resolved.reference).catch((error: unknown) => {
      if ((error as NodeJS.ErrnoException)?.code !== 'ENOENT') {
        throw error;
      }
    });
  }

  async info(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<StorageObjectInfo> {
    if (!isCanonicalReference(reference)) {
      return this.legacyLocalAdapter.info(reference, allowedBuckets);
    }
    const resolved = this.canonical(reference, allowedBuckets);
    if (!resolved) {
      throw new Error('Storage reference is outside configured buckets.');
    }
    const metadata = await this.head(resolved);
    const size = metadata.ContentLength;
    if (size === undefined || size < 0 || size > this.options.maxObjectBytes) {
      throw new Error('Storage object size is missing or outside configured limits.');
    }
    let sha256 = String(metadata.Metadata?.sha256 ?? '').toLowerCase();
    if (!sha256Pattern.test(sha256)) {
      const downloaded = await this.remoteReadStream(resolved);
      const calculated = await hashReadable(downloaded.stream, this.options.maxObjectBytes);
      if (calculated.size !== size) {
        throw new Error('Storage object changed while its checksum was calculated.');
      }
      sha256 = calculated.sha256;
    }
    return {
      ...resolved,
      size,
      sha256,
      ...(metadata.ContentType ? { contentType: metadata.ContentType } : {}),
    };
  }

  async exists(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<boolean> {
    if (!isCanonicalReference(reference)) {
      return this.legacyLocalAdapter.exists(reference, allowedBuckets);
    }
    const resolved = this.canonical(reference, allowedBuckets);
    if (!resolved) {
      return false;
    }
    try {
      await this.head(resolved);
      return true;
    } catch (error) {
      if (isStorageNotFound(error)) {
        return false;
      }
      throw error;
    }
  }

  async openReadStream(
    reference: string,
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<Readable> {
    if (!isCanonicalReference(reference)) {
      return this.legacyLocalAdapter.openReadStream(reference, allowedBuckets);
    }
    const resolved = this.canonical(reference, allowedBuckets);
    if (!resolved) {
      throw new Error('Storage reference is outside configured buckets.');
    }
    return (await this.remoteReadStream(resolved)).stream;
  }

  async openReadRange(
    reference: string,
    range: { start: number; end: number },
    allowedBuckets: readonly StorageBucket[] = ['uploads', 'exports'],
  ): Promise<Readable> {
    if (!isCanonicalReference(reference)) {
      return this.legacyLocalAdapter.openReadRange(reference, range, allowedBuckets);
    }
    const resolved = this.canonical(reference, allowedBuckets);
    if (
      !resolved ||
      !Number.isSafeInteger(range.start) ||
      !Number.isSafeInteger(range.end) ||
      range.start < 0 ||
      range.end < range.start
    ) {
      throw new Error('Storage byte range is invalid.');
    }
    const metadata = await this.head(resolved);
    if (metadata.ContentLength === undefined || range.end >= metadata.ContentLength) {
      throw new Error('Storage byte range exceeds the object.');
    }
    return (await this.remoteReadStream(resolved, range)).stream;
  }

  async writeStream(
    reference: string,
    contents: Readable,
    expected: { size: number; sha256: string; contentType?: string },
  ): Promise<StorageObjectInfo> {
    const resolved = this.canonical(reference, ['uploads', 'exports', 'offline', 'ai', 'backups']);
    if (
      !resolved ||
      expected.size < 0 ||
      expected.size > this.options.maxObjectBytes ||
      !sha256Pattern.test(expected.sha256)
    ) {
      throw new Error('Storage destination, size, or checksum is invalid.');
    }
    if (await this.exists(resolved.reference, [resolved.bucket])) {
      const error = new Error('Storage object already exists.') as NodeJS.ErrnoException;
      error.code = 'EEXIST';
      throw error;
    }
    const hash = createHash('sha256');
    let size = 0;
    const verifier = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length;
        if (size > expected.size) {
          callback(new Error('Streamed storage object exceeds its reviewed size.'));
          return;
        }
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    try {
      await this.client.send(
        new PutObjectCommand({
          Bucket: this.physicalBucket(resolved.bucket),
          Key: this.remoteKey(resolved.key),
          Body: contents.pipe(verifier),
          ContentLength: expected.size,
          ContentType: expected.contentType ?? contentTypeForKey(resolved.key),
          IfNoneMatch: '*',
          Metadata: { sha256: expected.sha256 },
          ...this.writeEncryptionHeaders(),
        }),
      );
      const calculated = hash.digest('hex');
      if (size !== expected.size || calculated !== expected.sha256) {
        await this.remove(resolved.reference).catch(() => undefined);
        throw new Error('Streamed storage object failed size or checksum verification.');
      }
      const stored = await this.info(resolved.reference, [resolved.bucket]);
      if (stored.size !== expected.size || stored.sha256 !== expected.sha256) {
        await this.remove(resolved.reference).catch(() => undefined);
        throw new Error('Stored object failed post-upload verification.');
      }
      return stored;
    } catch (error) {
      if (!isStoragePreconditionFailure(error)) {
        throw error;
      }
      const conflict = new Error('Storage object already exists.') as NodeJS.ErrnoException;
      conflict.code = 'EEXIST';
      throw conflict;
    }
  }

  async writeExclusive(reference: string, contents: Buffer): Promise<StorageObjectInfo> {
    const resolved = this.canonical(reference, ['uploads', 'exports', 'offline', 'ai', 'backups']);
    if (!resolved || contents.length > this.options.maxObjectBytes) {
      throw new Error('Storage destination or object size is invalid.');
    }
    const sha256 = createHash('sha256').update(contents).digest('hex');
    try {
      await this.client.send(
        new PutObjectCommand({
          Bucket: this.physicalBucket(resolved.bucket),
          Key: this.remoteKey(resolved.key),
          Body: contents,
          ContentLength: contents.length,
          ContentType: contentTypeForKey(resolved.key),
          IfNoneMatch: '*',
          Metadata: { sha256 },
          ...this.writeEncryptionHeaders(),
        }),
      );
    } catch (error) {
      if (isStoragePreconditionFailure(error)) {
        const conflict = new Error('Storage object already exists.') as NodeJS.ErrnoException;
        conflict.code = 'EEXIST';
        throw conflict;
      }
      throw error;
    }
    const stored = await this.info(resolved.reference, [resolved.bucket]);
    if (stored.size !== contents.length || stored.sha256 !== sha256) {
      await this.remove(resolved.reference).catch(() => undefined);
      throw new Error('Stored object failed post-upload verification.');
    }
    return stored;
  }

  async writeAtomic(reference: string, contents: Buffer): Promise<StorageObjectInfo> {
    return this.writeExclusive(reference, contents);
  }

  async copyVerified(
    sourceReference: string,
    destinationReference: string,
    expected: { size?: number; sha256?: string } = {},
  ): Promise<VerifiedCopyResult> {
    if (expected.sha256 && !sha256Pattern.test(expected.sha256)) {
      throw new Error('Expected storage checksum is invalid.');
    }
    const source = await this.info(sourceReference);
    if (
      (expected.size !== undefined && source.size !== expected.size) ||
      (expected.sha256 !== undefined && source.sha256 !== expected.sha256)
    ) {
      throw new Error('Source object does not match the reviewed size and checksum.');
    }
    const destination = this.canonical(destinationReference, [
      'uploads',
      'exports',
      'offline',
      'ai',
      'backups',
    ]);
    if (!destination) {
      throw new Error('Destination must be a canonical storage reference.');
    }
    let destinationAlreadyExisted = await this.exists(destination.reference, [destination.bucket]);
    if (!destinationAlreadyExisted) {
      const sourceStream = await this.openReadStream(sourceReference, [source.bucket]);
      try {
        await this.writeStream(destination.reference, sourceStream, {
          size: source.size,
          sha256: source.sha256,
          ...(source.contentType ? { contentType: source.contentType } : {}),
        });
      } catch (error: unknown) {
        if ((error as NodeJS.ErrnoException)?.code !== 'EEXIST') {
          throw error;
        }
        destinationAlreadyExisted = true;
      }
    }
    const destinationInfo = await this.info(destination.reference, [destination.bucket]);
    const sourceAfter = await this.info(sourceReference, [source.bucket]);
    if (
      sourceAfter.size !== source.size ||
      sourceAfter.sha256 !== source.sha256 ||
      destinationInfo.size !== source.size ||
      destinationInfo.sha256 !== source.sha256
    ) {
      if (!destinationAlreadyExisted) {
        await this.remove(destination.reference).catch(() => undefined);
      }
      throw new Error('Copied storage object failed size or checksum verification.');
    }
    return {
      source: sourceAfter,
      destination: destinationInfo,
      destinationAlreadyExisted,
    };
  }

  async remove(reference: string): Promise<void> {
    if (!isCanonicalReference(reference)) {
      await this.legacyLocalAdapter.remove(reference);
      return;
    }
    const resolved = this.canonical(reference, ['uploads', 'exports', 'offline', 'ai', 'backups']);
    if (!resolved) {
      throw new Error('Storage reference is outside configured buckets.');
    }
    await this.client.send(
      new DeleteObjectCommand({
        Bucket: this.physicalBucket(resolved.bucket),
        Key: this.remoteKey(resolved.key),
      }),
    );
    await this.cacheAdapter.remove(resolved.reference).catch((error: unknown) => {
      if ((error as NodeJS.ErrnoException)?.code !== 'ENOENT') {
        throw error;
      }
    });
  }

  async list(bucket: StorageBucket, prefix = ''): Promise<StorageListEntry[]> {
    const normalizedPrefix = prefix ? safeStorageKey(prefix) : '';
    const remotePrefix = this.remoteKey(normalizedPrefix);
    const entries: StorageListEntry[] = [];
    let continuationToken: string | undefined;
    do {
      const page = await this.client.send(
        new ListObjectsV2Command({
          Bucket: this.physicalBucket(bucket),
          Prefix: remotePrefix,
          ContinuationToken: continuationToken,
        }),
      );
      for (const object of page.Contents ?? []) {
        if (!object.Key || object.Size === undefined) {
          continue;
        }
        const configuredPrefix = this.options.prefix.replace(/^\/+|\/+$/g, '');
        const key = configuredPrefix
          ? object.Key.replace(
              new RegExp(`^${configuredPrefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/`),
              '',
            )
          : object.Key;
        let safeKey: string;
        try {
          safeKey = safeStorageKey(key);
        } catch {
          continue;
        }
        const reference = this.reference(bucket, safeKey);
        const resolved = this.cacheAdapter.resolve(reference, [bucket]);
        if (!resolved) {
          continue;
        }
        entries.push({
          bucket,
          key: safeKey,
          reference,
          localPath: resolved.localPath,
          kind: 'file',
          size: object.Size,
        });
      }
      continuationToken = page.IsTruncated ? page.NextContinuationToken : undefined;
    } while (continuationToken);
    return entries.sort((left, right) => left.reference.localeCompare(right.reference));
  }
}

const createStorageAdapter = (): StorageAdapter => {
  if (process.env.STORAGE_DRIVER !== 's3') {
    return new LocalStorageAdapter();
  }
  return new S3StorageAdapter({
    endpoint: process.env.STORAGE_S3_ENDPOINT ?? '',
    region: process.env.STORAGE_S3_REGION ?? '',
    accessKeyId: process.env.STORAGE_S3_ACCESS_KEY_ID ?? '',
    secretAccessKey: process.env.STORAGE_S3_SECRET_ACCESS_KEY ?? '',
    forcePathStyle: process.env.STORAGE_S3_FORCE_PATH_STYLE !== 'false',
    prefix: process.env.STORAGE_S3_PREFIX ?? 'terraleb',
    tempDirectory: process.env.STORAGE_TEMP_DIR ?? '/tmp/terraleb-storage',
    maxObjectBytes: Number(process.env.STORAGE_MAX_OBJECT_BYTES ?? 1024 * 1024 * 1024),
    requestTimeoutMs: Number(process.env.STORAGE_S3_REQUEST_TIMEOUT_MS ?? 30000),
    maxAttempts: Number(process.env.STORAGE_S3_MAX_ATTEMPTS ?? 3),
    serverSideEncryption:
      process.env.STORAGE_S3_SERVER_SIDE_ENCRYPTION === 'AES256' ? 'AES256' : 'SSE-C',
    customerKeyBase64: process.env.STORAGE_S3_CUSTOMER_KEY_BASE64,
    buckets: {
      uploads: process.env.STORAGE_S3_UPLOADS_BUCKET ?? '',
      exports: process.env.STORAGE_S3_EXPORTS_BUCKET ?? '',
      offline: process.env.STORAGE_S3_OFFLINE_BUCKET ?? '',
      ai: process.env.STORAGE_S3_AI_BUCKET ?? '',
      backups: process.env.STORAGE_S3_BACKUPS_BUCKET ?? '',
    },
  });
};

const storageAdapter = createStorageAdapter();

export {
  LocalStorageAdapter,
  S3StorageAdapter,
  createStorageAdapter,
  hashFile,
  storageAdapter,
  type StorageAdapter,
  type StorageBucket,
  type StorageListEntry,
  type StorageObjectInfo,
  type StorageObjectLocation,
  type S3StorageAdapterOptions,
  type VerifiedCopyResult,
};
