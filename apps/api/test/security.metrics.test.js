const { assertMetricsConfig } = require('../src/middleware/observability');

describe('Security: metrics configuration', () => {
  test('throws in production when metrics is enabled without token', () => {
    expect(() =>
      assertMetricsConfig({
        NODE_ENV: 'production',
        METRICS_ENABLED: true,
        METRICS_TOKEN: '',
      })
    ).toThrow('METRICS_TOKEN is required');
  });

  test('allows metrics in production when token is configured', () => {
    expect(() =>
      assertMetricsConfig({
        NODE_ENV: 'production',
        METRICS_ENABLED: true,
        METRICS_TOKEN: 'secure-token',
      })
    ).not.toThrow();
  });

  test('allows empty token when metrics are disabled', () => {
    expect(() =>
      assertMetricsConfig({
        NODE_ENV: 'production',
        METRICS_ENABLED: false,
        METRICS_TOKEN: '',
      })
    ).not.toThrow();
  });
});
