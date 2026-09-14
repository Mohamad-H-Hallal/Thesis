const { createHash } = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');
const { S3StorageAdapter } = require('../src/services/storageAdapter.service');

const bodyBuffer = async (body) => {
  if (Buffer.isBuffer(body)) return body;
  const chunks = [];
  for await (const chunk of body) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
};

class InMemoryS3Client {
  constructor() {
    this.objects = new Map();
    this.commands = [];
  }

  async send(command) {
    this.commands.push(command);
    const input = command.input;
    const objectKey = `${input.Bucket}/${input.Key ?? ''}`;
    switch (command.constructor.name) {
      case 'PutObjectCommand': {
        if (input.IfNoneMatch === '*' && this.objects.has(objectKey)) {
          const error = new Error('precondition failed');
          error.name = 'PreconditionFailed';
          error.$metadata = { httpStatusCode: 412 };
          throw error;
        }
        const body = await bodyBuffer(input.Body);
        this.objects.set(objectKey, {
          body,
          contentType: input.ContentType,
          metadata: input.Metadata,
          encryption: input.ServerSideEncryption,
        });
        return { ETag: 'fixture-etag' };
      }
      case 'HeadObjectCommand': {
        const object = this.objects.get(objectKey);
        if (!object) {
          const error = new Error('not found');
          error.name = 'NotFound';
          error.$metadata = { httpStatusCode: 404 };
          throw error;
        }
        return {
          ContentLength: object.body.length,
          ContentType: object.contentType,
          Metadata: object.metadata,
          ServerSideEncryption: object.encryption,
        };
      }
      case 'GetObjectCommand': {
        const object = this.objects.get(objectKey);
        if (!object) throw new Error('missing fixture object');
        const range = /^bytes=(\d+)-(\d+)$/.exec(input.Range ?? '');
        const body = range
          ? object.body.subarray(Number(range[1]), Number(range[2]) + 1)
          : object.body;
        return {
          Body: Readable.from(body),
          ContentLength: body.length,
          ContentType: object.contentType,
        };
      }
      case 'DeleteObjectCommand':
        this.objects.delete(objectKey);
        return {};
      case 'ListObjectsV2Command': {
        const prefix = `${input.Bucket}/`;
        return {
          Contents: [...this.objects.entries()]
            .filter(([key]) => key.startsWith(prefix))
            .map(([key, object]) => ({
              Key: key.slice(prefix.length),
              Size: object.body.length,
            })),
          IsTruncated: false,
        };
      }
      default:
        throw new Error(`Unexpected command: ${command.constructor.name}`);
    }
  }
}

describe('S3-compatible storage adapter', () => {
  let tempDirectory;
  let client;
  let adapter;

  beforeEach(async () => {
    tempDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'terraleb-s3-adapter-'));
    client = new InMemoryS3Client();
    adapter = new S3StorageAdapter({
      endpoint: 'https://fra1.digitaloceanspaces.com',
      region: 'fra1',
      accessKeyId: 'fixture-access-key',
      secretAccessKey: 'fixture-secret-key',
      forcePathStyle: false,
      prefix: 'terraleb',
      tempDirectory,
      maxObjectBytes: 10 * 1024 * 1024,
      requestTimeoutMs: 30000,
      maxAttempts: 3,
      serverSideEncryption: 'SSE-C',
      customerKeyBase64: Buffer.alloc(32, 9).toString('base64'),
      buckets: {
        uploads: 'uploads-private',
        exports: 'exports-private',
        offline: 'offline-private',
        ai: 'ai-private',
        backups: 'backups-private',
      },
      client,
    });
  });

  afterEach(async () => {
    await fs.rm(tempDirectory, { recursive: true, force: true });
  });

  test('writes private encrypted objects with immutable checksums and exclusive keys', async () => {
    const reference = adapter.reference('uploads', '.private/photos/photo.jpg');
    const payload = Buffer.from('photo fixture');
    const stored = await adapter.writeExclusive(reference, payload);

    expect(stored).toEqual(
      expect.objectContaining({
        reference,
        size: payload.length,
        sha256: createHash('sha256').update(payload).digest('hex'),
      }),
    );
    const put = client.commands.find(({ constructor }) => constructor.name === 'PutObjectCommand');
    expect(put.input).toEqual(
      expect.objectContaining({
        Bucket: 'uploads-private',
        Key: 'terraleb/.private/photos/photo.jpg',
        IfNoneMatch: '*',
        SSECustomerAlgorithm: 'AES256',
        SSECustomerKey: Buffer.alloc(32, 9).toString('base64'),
        SSECustomerKeyMD5: createHash('md5').update(Buffer.alloc(32, 9)).digest('base64'),
      }),
    );
    await expect(adapter.writeExclusive(reference, payload)).rejects.toMatchObject({
      code: 'EEXIST',
    });
  });

  test('streams uploads and downloads without making a public URL', async () => {
    const reference = adapter.reference('exports', 'ordinary/export.zip');
    const payload = Buffer.from('streamed export fixture');
    const sha256 = createHash('sha256').update(payload).digest('hex');

    await adapter.writeStream(reference, Readable.from(payload), {
      size: payload.length,
      sha256,
      contentType: 'application/zip',
    });
    const stream = await adapter.openReadStream(reference, ['exports']);
    await expect(bodyBuffer(stream)).resolves.toEqual(payload);
    const range = await adapter.openReadRange(reference, { start: 9, end: 14 }, ['exports']);
    await expect(bodyBuffer(range)).resolves.toEqual(Buffer.from('export'));
    const rangeCommand = client.commands.find(
      ({ constructor, input }) =>
        constructor.name === 'GetObjectCommand' && input.Range === 'bytes=9-14',
    );
    expect(rangeCommand).toBeDefined();
    expect(rangeCommand.input).toEqual(
      expect.objectContaining({
        SSECustomerAlgorithm: 'AES256',
        SSECustomerKey: Buffer.alloc(32, 9).toString('base64'),
      }),
    );
    expect(reference.startsWith('storage://')).toBe(true);
    expect(reference).not.toContain('http');
  });

  test('materializes only a checksum-verified private cache file for file-based parsers', async () => {
    const reference = adapter.reference('offline', 'lebanon/package-v1.pmtiles');
    const payload = Buffer.from('offline package fixture');
    await adapter.writeExclusive(reference, payload);

    const located = await adapter.locate(reference, ['offline']);
    await expect(fs.readFile(located.localPath)).resolves.toEqual(payload);
    expect(located.localPath).toContain(path.join('cache', 'offline'));
    expect(located.sha256).toBe(createHash('sha256').update(payload).digest('hex'));

    await adapter.releaseLocalCopy(reference, ['offline']);
    await expect(fs.stat(located.localPath)).rejects.toMatchObject({ code: 'ENOENT' });
    await expect(adapter.exists(reference, ['offline'])).resolves.toBe(true);
  });

  test('lists and deletes only the requested logical bucket', async () => {
    const upload = adapter.reference('uploads', '.private/imports/source.geojson');
    const output = adapter.reference('ai', 'project/run/output.geojson');
    await adapter.writeExclusive(upload, Buffer.from('upload'));
    await adapter.writeExclusive(output, Buffer.from('output'));

    await expect(adapter.list('uploads')).resolves.toEqual([
      expect.objectContaining({ bucket: 'uploads', reference: upload, kind: 'file' }),
    ]);
    await adapter.remove(upload);
    await expect(adapter.exists(upload)).resolves.toBe(false);
    await expect(adapter.exists(output, ['ai'])).resolves.toBe(true);
  });

  test('fails closed when SSE-C is selected without a valid 32-byte key', () => {
    expect(
      () =>
        new S3StorageAdapter({
          ...adapter.options,
          serverSideEncryption: 'SSE-C',
          customerKeyBase64: Buffer.alloc(16).toString('base64'),
          client,
        }),
    ).toThrow('32-byte customer key');
  });

  test('keeps provider-managed AES256 compatible without sending write-only headers on reads', async () => {
    const aesClient = new InMemoryS3Client();
    const aesAdapter = new S3StorageAdapter({
      ...adapter.options,
      serverSideEncryption: 'AES256',
      customerKeyBase64: undefined,
      client: aesClient,
    });
    const reference = 'storage://uploads/.private/photos/aes.jpg';
    await aesAdapter.writeExclusive(reference, Buffer.from('provider-managed encryption'));

    await aesAdapter.exists(reference);
    const readStream = await aesAdapter.openReadStream(reference);
    await bodyBuffer(readStream);

    const put = aesClient.commands.find(
      ({ constructor }) => constructor.name === 'PutObjectCommand',
    );
    const reads = aesClient.commands.filter(({ constructor }) =>
      ['HeadObjectCommand', 'GetObjectCommand'].includes(constructor.name),
    );
    expect(put.input.ServerSideEncryption).toBe('AES256');
    expect(reads).not.toHaveLength(0);
    for (const command of reads) {
      expect(command.input).not.toHaveProperty('ServerSideEncryption');
      expect(command.input).not.toHaveProperty('SSECustomerKey');
    }
  });
});
