import 'dotenv/config';
import { closePool, query } from '../config/database';
import { storageAdapter } from '../services/storageAdapter.service';
import {
  createStorageInventory,
  inventoryManifestHash,
} from '../services/storageInventory.service';

const run = async (): Promise<void> => {
  const allowedArguments = new Set(['--no-checksums']);
  const unknown = process.argv.slice(2).filter((argument) => !allowedArguments.has(argument));
  if (unknown.length > 0) {
    throw new Error(`Unknown storage inventory argument: ${unknown.join(', ')}`);
  }
  const report = await createStorageInventory({
    executor: { query },
    adapter: storageAdapter,
    includeChecksums: !process.argv.includes('--no-checksums'),
  });
  process.stdout.write(
    `${JSON.stringify(
      {
        manifestSha256: inventoryManifestHash(report),
        report,
      },
      null,
      2,
    )}\n`,
  );
};

void run()
  .catch((error: unknown) => {
    const message =
      error instanceof Error && error.message
        ? error.message
        : String(error) || 'Unknown storage inventory failure';
    process.stderr.write(`Storage inventory failed: ${message}\n`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closePool();
  });
