import 'dotenv/config';
import { closePool } from '../config/database';
import { runAiWorkerOnce, type AiRunActiveStatus } from './aiWorker';
const logger = require('../utils/logger');

const parseArgs = (
  args: string[],
): {
  once: boolean;
  dryRun: boolean;
  mock: boolean;
  pipelineBridge: boolean;
  failAtStatus: AiRunActiveStatus | null;
} => {
  const parsed = {
    once: false,
    dryRun: false,
    mock: false,
    pipelineBridge: false,
    failAtStatus: null as AiRunActiveStatus | null,
  };

  for (const arg of args) {
    if (arg === '--once') {
      parsed.once = true;
      continue;
    }
    if (arg === '--dry-run') {
      parsed.dryRun = true;
      continue;
    }
    if (arg === '--mock') {
      parsed.mock = true;
      continue;
    }
    if (arg === '--pipeline-bridge') {
      parsed.pipelineBridge = true;
      continue;
    }
    if (arg.startsWith('--fail-at=')) {
      parsed.failAtStatus = arg.slice('--fail-at='.length) as AiRunActiveStatus;
      continue;
    }
    throw new Error(`Unknown AI worker option: ${arg}`);
  }

  return parsed;
};

const run = async (): Promise<void> => {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (!args.once) {
      throw new Error('Phase D AI worker supports only --once execution.');
    }
    if (!args.dryRun && !args.mock && !args.pipelineBridge) {
      throw new Error('Phase E AI worker requires --mock, --pipeline-bridge, or --dry-run.');
    }

    const result = await runAiWorkerOnce({
      dryRun: args.dryRun,
      mock: args.mock ? true : undefined,
      failAtStatus: args.failAtStatus,
    });

    logger.info('AI worker once finished', result);
  } catch (error) {
    logger.error('AI worker once failed', error);
    process.exitCode = 1;
  } finally {
    await closePool();
  }
};

void run();
