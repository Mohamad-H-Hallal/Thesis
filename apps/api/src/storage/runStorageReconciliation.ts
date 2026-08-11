import 'dotenv/config';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { closePool, query, transaction } from '../config/database';
import { storageAdapter } from '../services/storageAdapter.service';
import {
  executeStorageMigration,
  manifestHash,
  preflightReviewedOrphans,
  preflightStorageMigration,
  quarantineReviewedOrphans,
  rollbackStorageMigration,
  validateMigrationManifest,
  validateOrphanManifest,
  type ReviewedOrphanManifest,
  type StorageMigrationManifest,
} from '../services/storageReconciliation.service';

type ReconciliationAction =
  | 'validate-migration'
  | 'execute-migration'
  | 'rollback-migration'
  | 'validate-orphans'
  | 'quarantine-orphans';

const actions = new Set<ReconciliationAction>([
  'validate-migration',
  'execute-migration',
  'rollback-migration',
  'validate-orphans',
  'quarantine-orphans',
]);

const parseArguments = (): {
  action: ReconciliationAction;
  manifestPath: string;
  confirmation: string | null;
} => {
  const raw = process.argv.slice(2);
  const action = raw.shift() as ReconciliationAction;
  if (!actions.has(action)) {
    throw new Error('A valid storage reconciliation action is required.');
  }
  let manifestPath: string | null = null;
  let confirmation: string | null = null;
  while (raw.length > 0) {
    const option = raw.shift();
    const value = raw.shift();
    if (!value || (option !== '--manifest' && option !== '--confirm')) {
      throw new Error(`Invalid storage reconciliation option: ${option ?? ''}`);
    }
    if (option === '--manifest' && manifestPath === null) {
      manifestPath = value;
    } else if (option === '--confirm' && confirmation === null) {
      confirmation = value;
    } else {
      throw new Error(`Duplicate storage reconciliation option: ${option}`);
    }
  }
  if (!manifestPath) {
    throw new Error('A reviewed manifest path is required.');
  }
  return {
    action,
    manifestPath: path.resolve(manifestPath),
    confirmation,
  };
};

const readManifest = async (manifestPath: string): Promise<unknown> => {
  const handle = await fs.open(manifestPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size < 2 || stat.size > 5 * 1024 * 1024) {
      throw new Error('Manifest must be a regular JSON file no larger than 5 MiB.');
    }
    return JSON.parse(await handle.readFile('utf8'));
  } finally {
    await handle.close();
  }
};

const database = { query, transaction };

const run = async (): Promise<void> => {
  const { action, manifestPath, confirmation } = parseArguments();
  const manifest = await readManifest(manifestPath);
  let result: unknown;

  if (action === 'validate-migration') {
    validateMigrationManifest(manifest as StorageMigrationManifest, storageAdapter);
    const validated = await preflightStorageMigration({
      manifest: manifest as StorageMigrationManifest,
      adapter: storageAdapter,
      database,
    });
    result = {
      valid: true,
      operation: 'copy_verify_switch',
      ...validated,
      mutatesState: false,
    };
  } else if (action === 'execute-migration') {
    if (confirmation !== 'COPY_VERIFY_SWITCH_SOURCE_RETAINED') {
      throw new Error(
        'Execution requires --confirm COPY_VERIFY_SWITCH_SOURCE_RETAINED.',
      );
    }
    result = await executeStorageMigration({
      manifest: manifest as StorageMigrationManifest,
      adapter: storageAdapter,
      database,
    });
  } else if (action === 'rollback-migration') {
    if (confirmation !== 'ROLLBACK_REFERENCE_SWITCH_KEEP_DESTINATION') {
      throw new Error(
        'Rollback requires --confirm ROLLBACK_REFERENCE_SWITCH_KEEP_DESTINATION.',
      );
    }
    result = await rollbackStorageMigration({
      manifest: manifest as StorageMigrationManifest,
      adapter: storageAdapter,
      database,
    });
  } else if (action === 'validate-orphans') {
    validateOrphanManifest(manifest as ReviewedOrphanManifest);
    const validated = await preflightReviewedOrphans({
      manifest: manifest as ReviewedOrphanManifest,
      adapter: storageAdapter,
      database,
    });
    result = {
      valid: true,
      operation: 'quarantine_reviewed_orphans',
      ...validated,
      mutatesState: false,
    };
  } else {
    if (confirmation !== 'QUARANTINE_REVIEWED_ORPHANS_NO_DELETE') {
      throw new Error(
        'Quarantine execution requires --confirm QUARANTINE_REVIEWED_ORPHANS_NO_DELETE.',
      );
    }
    result = await quarantineReviewedOrphans({
      manifest: manifest as ReviewedOrphanManifest,
      adapter: storageAdapter,
      database,
    });
  }

  process.stdout.write(
    `${JSON.stringify(
      {
        action,
        manifestPath,
        manifestSha256: manifestHash(manifest),
        result,
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
        : String(error) || 'Unknown storage reconciliation failure';
    process.stderr.write(`Storage reconciliation failed: ${message}\n`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closePool();
  });
