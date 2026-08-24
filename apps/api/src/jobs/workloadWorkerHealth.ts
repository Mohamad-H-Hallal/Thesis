import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const WORKLOAD_WORKER_HEALTH_FILE = path.join(os.tmpdir(), 'terraleb-workload-worker-health');
const WORKLOAD_WORKER_HEARTBEAT_MS = 10_000;
const WORKLOAD_WORKER_MAX_HEALTH_AGE_MS = 60_000;

let healthInterval: NodeJS.Timeout | null = null;

const writeWorkloadWorkerHealth = async (
  writtenAt: number | string = Date.now(),
): Promise<void> => {
  await fs.writeFile(WORKLOAD_WORKER_HEALTH_FILE, String(writtenAt), {
    encoding: 'utf8',
    mode: 0o600,
  });
};

const startWorkloadWorkerHealth = async (): Promise<void> => {
  await writeWorkloadWorkerHealth();
  if (healthInterval) {
    return;
  }
  healthInterval = setInterval(() => {
    void writeWorkloadWorkerHealth().catch(() => undefined);
  }, WORKLOAD_WORKER_HEARTBEAT_MS);
  healthInterval.unref();
};

const stopWorkloadWorkerHealth = async (): Promise<void> => {
  if (healthInterval) {
    clearInterval(healthInterval);
    healthInterval = null;
  }
  await fs.rm(WORKLOAD_WORKER_HEALTH_FILE, { force: true });
};

const isWorkloadWorkerHealthFresh = async (
  maximumAgeMs = WORKLOAD_WORKER_MAX_HEALTH_AGE_MS,
): Promise<boolean> => {
  try {
    const writtenAt = Number.parseInt(await fs.readFile(WORKLOAD_WORKER_HEALTH_FILE, 'utf8'), 10);
    return Number.isFinite(writtenAt) && Date.now() - writtenAt <= maximumAgeMs;
  } catch {
    return false;
  }
};

export {
  WORKLOAD_WORKER_HEALTH_FILE,
  WORKLOAD_WORKER_HEARTBEAT_MS,
  WORKLOAD_WORKER_MAX_HEALTH_AGE_MS,
  isWorkloadWorkerHealthFresh,
  startWorkloadWorkerHealth,
  stopWorkloadWorkerHealth,
  writeWorkloadWorkerHealth,
};
