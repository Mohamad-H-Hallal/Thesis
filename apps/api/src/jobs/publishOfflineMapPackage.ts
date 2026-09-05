import fs from 'node:fs/promises';
import { closePool } from '../config/database';
import { publishOfflineMapPackage } from '../services/offlineMapPackage.service';

const argument = (name: string): string => {
  const index = process.argv.indexOf(`--${name}`);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value?.trim()) throw new Error(`--${name} is required`);
  return value.trim();
};

const run = async (): Promise<void> => {
  const manifest = JSON.parse(await fs.readFile(argument('manifest'), 'utf8')) as unknown;
  const evidence = await publishOfflineMapPackage({
    packagePath: argument('package'),
    manifest,
    actorUserId: argument('actor-user-id'),
  });
  process.stdout.write(`${JSON.stringify(evidence)}\n`);
};

if (require.main === module) {
  void run()
    .catch((error) => {
      process.stderr.write(
        `Offline package publication failed: ${error instanceof Error ? error.message : String(error)}\n`,
      );
      process.exitCode = 1;
    })
    .finally(closePool);
}

export { run };
