type MapLayer = 'imagery' | 'reference' | 'metadata';
type MapOutcome = 'success' | 'disabled' | 'auth_failure' | 'quota' | 'upstream_failure';

const counters = new Map<string, number>();
const latencyBuckets = [100, 250, 500, 1000, 2500, 5000, 10000] as const;
const latencyCounts = new Map<string, number[]>();
const latencySums = new Map<string, number>();
const requestCounts = new Map<string, number>();

const metricKey = (layer: MapLayer, outcome: MapOutcome): string => `${layer}:${outcome}`;

const recordMapProviderRequest = ({
  layer,
  outcome,
  durationMs,
}: {
  layer: MapLayer;
  outcome: MapOutcome;
  durationMs: number;
}): void => {
  const key = metricKey(layer, outcome);
  counters.set(key, (counters.get(key) ?? 0) + 1);
  const buckets = latencyCounts.get(layer) ?? latencyBuckets.map(() => 0);
  latencyBuckets.forEach((bound, index) => {
    if (durationMs <= bound) buckets[index] += 1;
  });
  latencyCounts.set(layer, buckets);
  latencySums.set(layer, (latencySums.get(layer) ?? 0) + durationMs);
  requestCounts.set(layer, (requestCounts.get(layer) ?? 0) + 1);
};

const getMapProviderMetricsSnapshot = () => ({
  counters: Object.fromEntries(counters),
  latencyBuckets: [...latencyBuckets],
  latencyCounts: Object.fromEntries(latencyCounts),
  latencySums: Object.fromEntries(latencySums),
  requestCounts: Object.fromEntries(requestCounts),
});

export { getMapProviderMetricsSnapshot, recordMapProviderRequest, type MapLayer, type MapOutcome };
