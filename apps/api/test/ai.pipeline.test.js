const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createAiPipelineService, sanitizeLog } = require('../src/services/aiPipeline.service');

const TEST_PROJECT_ID = '91fbb1ae-3fea-49f7-a057-ada303260534';
const tempRoots = [];

const createTempPipelineRoot = async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gis-ai-pipeline-test-'));
  tempRoots.push(root);
  const writeScript = async (name, body) => {
    await fs.writeFile(path.join(root, name), body, 'utf8');
  };

  await writeScript('config.py', "console.log('config ok DB_PASSWORD=super-secret');");
  await writeScript(
    'run_pipeline.py',
    [
      'const args = process.argv.slice(2);',
      'console.log(`run_pipeline args=${JSON.stringify(args)} TOKEN=hidden-token`);',
      "if (args.includes('--fail')) process.exit(7);",
    ].join('\n'),
  );
  await writeScript(
    '01_export_ground_truth.py',
    [
      'const args = process.argv.slice(2);',
      'console.log(`export args=${JSON.stringify(args)}`);',
    ].join('\n'),
  );

  return root;
};

const createService = (root, overrides = {}) =>
  createAiPipelineService(() => ({
    enabled: true,
    root,
    pythonBin: process.execPath,
    timeoutMs: 1000,
    mode: 'dry_run',
    ...overrides,
  }));

describe('AI pipeline adapter phase E', () => {
  afterAll(async () => {
    await Promise.all(tempRoots.map((root) => fs.rm(root, { recursive: true, force: true })));
  });

  test('runs only approved commands with argument arrays and sanitized logs', async () => {
    const root = await createTempPipelineRoot();
    const service = createService(root);

    const configResult = await service.checkConfig();
    expect(configResult).toEqual(
      expect.objectContaining({
        command: 'config_check',
        success: true,
        exitCode: 0,
      }),
    );
    expect(configResult.sanitizedLog).toContain('DB_PASSWORD=[redacted]');
    expect(configResult.sanitizedLog).not.toContain('super-secret');

    const dryRunResult = await service.dryRun();
    expect(dryRunResult.sanitizedLog).toContain('--dry-run');
    expect(dryRunResult.sanitizedLog).toContain('TOKEN=[redacted]');
    expect(dryRunResult.sanitizedLog).not.toContain('hidden-token');

    const probeResult = await service.probeProject(TEST_PROJECT_ID, 'L4_descr');
    expect(probeResult.sanitizedLog).toContain('--probe-db');
    expect(probeResult.sanitizedLog).toContain(TEST_PROJECT_ID);
    expect(probeResult.sanitizedLog).toContain('L4_descr');

    const exportResult = await service.exportGroundTruthLocal(TEST_PROJECT_ID, 'L4_descr');
    expect(exportResult.outputPaths).toEqual([
      `outputs/projects/${TEST_PROJECT_ID}/ground_truth.geojson`,
    ]);
    expect(exportResult.sanitizedLog).toContain('--local-only');

    const extractionResult = await service.extractRegionalFeatures(
      TEST_PROJECT_ID,
      'L4_descr',
      'app-ai-test-run',
    );
    expect(extractionResult.sanitizedLog).toContain('--regional-feature-extraction');
    expect(extractionResult.sanitizedLog).toContain('--ground-truth');
    expect(extractionResult.outputPaths).toEqual([
      'outputs/runs/app-ai-test-run/feature_table.csv',
      'outputs/runs/app-ai-test-run/feature_extraction_summary.json',
    ]);

    const evalResult = await service.evaluateRegionalModel(
      TEST_PROJECT_ID,
      'L4_descr',
      'app-ai-test-run',
    );
    expect(evalResult.sanitizedLog).toContain('--regional-model-eval');
    expect(evalResult.sanitizedLog).toContain('--feature-table');
    expect(evalResult.outputPaths).toEqual([
      'outputs/runs/app-ai-test-run/metrics.json',
      'outputs/runs/app-ai-test-run/model_metadata.json',
      'outputs/runs/app-ai-test-run/confusion_matrix.csv',
      'outputs/runs/app-ai-test-run/classification_report.csv',
      'outputs/runs/app-ai-test-run/feature_importance.csv',
    ]);
  });

  test('fails clearly when the pipeline root is missing', async () => {
    const service = createAiPipelineService(() => ({
      enabled: true,
      root: null,
      pythonBin: process.execPath,
      timeoutMs: 1000,
      mode: 'dry_run',
    }));

    const result = await service.checkConfig();
    expect(result.success).toBe(false);
    expect(result.sanitizedLog).toBe('AI pipeline root is not configured.');
  });

  test('returns command failure without leaking secrets', async () => {
    const root = await createTempPipelineRoot();
    await fs.writeFile(
      path.join(root, 'run_pipeline.py'),
      "console.error('failed DB_PASSWORD=bad-secret'); process.exit(7);",
      'utf8',
    );
    const service = createService(root);

    const result = await service.dryRun();
    expect(result.success).toBe(false);
    expect(result.exitCode).toBe(7);
    expect(result.sanitizedLog).toContain('DB_PASSWORD=[redacted]');
    expect(result.sanitizedLog).not.toContain('bad-secret');
  });

  test('times out safely', async () => {
    const root = await createTempPipelineRoot();
    await fs.writeFile(path.join(root, 'run_pipeline.py'), 'setTimeout(() => {}, 5000);', 'utf8');
    const service = createService(root, {
      timeoutMs: 50,
    });

    const result = await service.dryRun();
    expect(result.success).toBe(false);
    expect(result.timedOut).toBe(true);
  });

  test('rejects unsafe project ids and label fields before execution', async () => {
    const root = await createTempPipelineRoot();
    const service = createService(root);

    expect(() => service.probeProject('not-a-uuid', 'L4_descr')).toThrow('Invalid AI project id');
    expect(() => service.probeProject(TEST_PROJECT_ID, 'L4_descr; rm -rf /')).toThrow(
      'Invalid AI label field',
    );
    expect(() =>
      service.extractRegionalFeatures(TEST_PROJECT_ID, 'L4_descr', '../unsafe'),
    ).toThrow('Invalid AI regional run id');
  });

  test('redacts common secret shapes', () => {
    const sanitized = sanitizeLog(
      [
        'PASSWORD=my-password',
        'TOKEN=abc123',
        '"private_key":"-----BEGIN PRIVATE KEY-----abc-----END PRIVATE KEY-----"',
        "'client_secret':'secret-value'",
      ].join('\n'),
    );

    expect(sanitized).not.toContain('my-password');
    expect(sanitized).not.toContain('abc123');
    expect(sanitized).not.toContain('secret-value');
    expect(sanitized).toContain('PASSWORD=[redacted]');
    expect(sanitized).toContain('TOKEN=[redacted]');
  });
});
