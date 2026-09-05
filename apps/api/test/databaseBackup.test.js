const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {
  BACKUP_MAGIC,
  decryptDatabaseBackup,
  encryptDatabaseDump,
} = require('../src/services/databaseBackup.service');

describe('database backup encryption envelope', () => {
  test('round-trips a dump with authenticated encryption and detects tampering', async () => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'terraleb-backup-'));
    const source = path.join(directory, 'source.dump');
    const encrypted = path.join(directory, 'source.dump.tldb');
    const restored = path.join(directory, 'restored.dump');
    const tampered = path.join(directory, 'tampered.dump.tldb');
    const key = Buffer.alloc(32, 7);
    const payload = Buffer.from('PostgreSQL custom-format fixture payload');
    try {
      await fs.writeFile(source, payload, { mode: 0o600 });
      const evidence = await encryptDatabaseDump({
        plaintextPath: source,
        encryptedPath: encrypted,
        key,
      });
      expect((await fs.readFile(encrypted)).subarray(0, BACKUP_MAGIC.length)).toEqual(BACKUP_MAGIC);
      expect(evidence.encryptedSha256).toMatch(/^[a-f0-9]{64}$/);

      const recovered = await decryptDatabaseBackup({
        encryptedPath: encrypted,
        plaintextPath: restored,
        key,
      });
      expect(await fs.readFile(restored)).toEqual(payload);
      expect(recovered.plaintextSha256).toBe(evidence.plaintextSha256);

      const damaged = await fs.readFile(encrypted);
      damaged[Math.floor(damaged.length / 2)] ^= 1;
      await fs.writeFile(tampered, damaged, { mode: 0o600 });
      await expect(
        decryptDatabaseBackup({
          encryptedPath: tampered,
          plaintextPath: path.join(directory, 'must-not-restore.dump'),
          key,
        }),
      ).rejects.toThrow();
    } finally {
      key.fill(0);
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
});
