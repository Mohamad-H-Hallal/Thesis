const fs = require('node:fs/promises');

const {
  WORKLOAD_WORKER_HEALTH_FILE,
  isWorkloadWorkerHealthFresh,
  startWorkloadWorkerHealth,
  stopWorkloadWorkerHealth,
} = require('../src/jobs/workloadWorkerHealth');

describe('workload worker health marker', () => {
  afterEach(async () => {
    await stopWorkloadWorkerHealth();
  });

  test('is unhealthy until the worker starts and removes its marker on stop', async () => {
    await fs.rm(WORKLOAD_WORKER_HEALTH_FILE, { force: true });
    expect(await isWorkloadWorkerHealthFresh()).toBe(false);

    await startWorkloadWorkerHealth();
    expect(await isWorkloadWorkerHealthFresh()).toBe(true);

    await stopWorkloadWorkerHealth();
    expect(await isWorkloadWorkerHealthFresh()).toBe(false);
  });

  test('rejects stale and malformed markers', async () => {
    await fs.writeFile(WORKLOAD_WORKER_HEALTH_FILE, String(Date.now() - 5_000), 'utf8');
    expect(await isWorkloadWorkerHealthFresh(1_000)).toBe(false);

    await fs.writeFile(WORKLOAD_WORKER_HEALTH_FILE, 'not-a-timestamp', 'utf8');
    expect(await isWorkloadWorkerHealthFresh()).toBe(false);
  });
});
