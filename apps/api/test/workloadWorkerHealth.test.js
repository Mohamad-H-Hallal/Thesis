const {
  isWorkloadWorkerHealthFresh,
  startWorkloadWorkerHealth,
  stopWorkloadWorkerHealth,
  writeWorkloadWorkerHealth,
} = require('../src/jobs/workloadWorkerHealth');

describe('workload worker health marker', () => {
  afterEach(async () => {
    await stopWorkloadWorkerHealth();
  });

  test('is unhealthy until the worker starts and removes its marker on stop', async () => {
    await stopWorkloadWorkerHealth();
    expect(await isWorkloadWorkerHealthFresh()).toBe(false);

    await startWorkloadWorkerHealth();
    expect(await isWorkloadWorkerHealthFresh()).toBe(true);

    await stopWorkloadWorkerHealth();
    expect(await isWorkloadWorkerHealthFresh()).toBe(false);
  });

  test('rejects stale and malformed markers', async () => {
    await writeWorkloadWorkerHealth(Date.now() - 5_000);
    expect(await isWorkloadWorkerHealthFresh(1_000)).toBe(false);

    await writeWorkloadWorkerHealth('not-a-timestamp');
    expect(await isWorkloadWorkerHealthFresh()).toBe(false);
  });
});
