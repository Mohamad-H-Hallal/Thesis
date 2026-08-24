import { isWorkloadWorkerHealthFresh } from './workloadWorkerHealth';

void isWorkloadWorkerHealthFresh()
  .then((healthy) => process.exit(healthy ? 0 : 1))
  .catch(() => process.exit(1));
