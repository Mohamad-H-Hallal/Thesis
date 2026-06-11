import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { performance } from 'node:perf_hooks';

type AiPipelineMode =
  | 'disabled'
  | 'dry_run'
  | 'local_ground_truth_export'
  | 'regional_feature_extraction'
  | 'regional_model_eval'
  | 'regional_classification'
  | 'regional_vectorization_artifacts';

type AiPipelineConfig = {
  enabled: boolean;
  root: string | null;
  pythonBin: string;
  timeoutMs: number;
  mode: AiPipelineMode;
  runConfigDir?: string | null;
};

type AiPipelineCommandName =
  | 'config_check'
  | 'dry_run'
  | 'probe_project'
  | 'export_ground_truth_local'
  | 'regional_feature_extraction'
  | 'regional_model_eval'
  | 'regional_classification'
  | 'regional_vectorization_artifacts';

type AiPipelineCommandResult = {
  command: AiPipelineCommandName;
  success: boolean;
  exitCode: number | null;
  durationMs: number;
  timedOut: boolean;
  sanitizedLog: string;
  outputPaths: string[];
};

type AiPipelineService = {
  getConfig: () => AiPipelineConfig;
  checkConfig: () => Promise<AiPipelineCommandResult>;
  dryRun: (runConfigPath?: string) => Promise<AiPipelineCommandResult>;
  probeProject: (
    projectId: string,
    labelField: string,
    runConfigPath?: string,
  ) => Promise<AiPipelineCommandResult>;
  exportGroundTruthLocal: (
    projectId: string,
    labelField: string,
  ) => Promise<AiPipelineCommandResult>;
  extractRegionalFeatures: (
    projectId: string,
    labelField: string,
    regionalRunId: string,
    runConfigPath?: string,
  ) => Promise<AiPipelineCommandResult>;
  evaluateRegionalModel: (
    projectId: string,
    labelField: string,
    regionalRunId: string,
    featureTablePath?: string,
    runConfigPath?: string,
  ) => Promise<AiPipelineCommandResult>;
  classifyRegional: (
    projectId: string,
    labelField: string,
    regionalRunId: string,
    modelMetadataPath?: string,
    regionPreset?: string,
    runConfigPath?: string,
  ) => Promise<AiPipelineCommandResult>;
  prepareRegionalVectorArtifacts: (
    projectId: string,
    labelField: string,
    regionalRunId: string,
    classificationSummaryPath?: string,
    regionPreset?: string,
    runConfigPath?: string,
  ) => Promise<AiPipelineCommandResult>;
};

const DEFAULT_TIMEOUT_MS = 60_000;
const MAX_TIMEOUT_MS = 10 * 60_000;
const MAX_LOG_CHARS = 12_000;

const validPipelineModes = new Set<AiPipelineMode>([
  'disabled',
  'dry_run',
  'local_ground_truth_export',
  'regional_feature_extraction',
  'regional_model_eval',
  'regional_classification',
  'regional_vectorization_artifacts',
]);

const parseBoolean = (value: string | undefined): boolean => {
  const normalized = String(value ?? '')
    .trim()
    .toLowerCase();
  return normalized === 'true' || normalized === '1' || normalized === 'yes';
};

const parseTimeoutMs = (value: string | undefined): number => {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return DEFAULT_TIMEOUT_MS;
  }
  return Math.min(parsed, MAX_TIMEOUT_MS);
};

const resolvePipelineMode = (value: string | undefined): AiPipelineMode => {
  const normalized = String(value ?? 'disabled').trim() as AiPipelineMode;
  return validPipelineModes.has(normalized) ? normalized : 'disabled';
};

const loadAiPipelineConfigFromEnv = (): AiPipelineConfig => ({
  enabled: parseBoolean(process.env.AI_PIPELINE_ENABLED),
  root: process.env.AI_PIPELINE_ROOT?.trim()
    ? path.resolve(process.env.AI_PIPELINE_ROOT.trim())
    : null,
  pythonBin: process.env.AI_PYTHON_BIN?.trim() || 'python',
  timeoutMs: parseTimeoutMs(process.env.AI_PIPELINE_TIMEOUT_MS),
  mode: resolvePipelineMode(process.env.AI_PIPELINE_MODE),
  runConfigDir: process.env.AI_PIPELINE_RUN_CONFIG_DIR?.trim()
    ? path.resolve(process.env.AI_PIPELINE_RUN_CONFIG_DIR.trim())
    : path.resolve(process.cwd(), 'tmp', 'ai-run-configs'),
});

const sanitizeLog = (value: string): string => {
  let sanitized = value;

  sanitized = sanitized.replace(
    /-----BEGIN [\s\S]*?PRIVATE KEY-----[\s\S]*?-----END [\s\S]*?PRIVATE KEY-----/gi,
    '[redacted-private-key]',
  );
  sanitized = sanitized.replace(
    /\b(DB_PASSWORD|PASSWORD|PASS|TOKEN|SECRET|PRIVATE_KEY|GEE_KEY|GOOGLE_APPLICATION_CREDENTIALS)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)/gi,
    '$1=[redacted]',
  );
  sanitized = sanitized.replace(
    /("(?:password|private_key|client_secret|token|secret)"\s*:\s*)"[^"]*"/gi,
    '$1"[redacted]"',
  );
  sanitized = sanitized.replace(
    /('(?:password|private_key|client_secret|token|secret)'\s*:\s*)'[^']*'/gi,
    "$1'[redacted]'",
  );

  return sanitized.length > MAX_LOG_CHARS
    ? `${sanitized.slice(0, MAX_LOG_CHARS)}\n[log truncated]`
    : sanitized;
};

const failureResult = (
  command: AiPipelineCommandName,
  message: string,
  startedAt: number,
): AiPipelineCommandResult => ({
  command,
  success: false,
  exitCode: null,
  durationMs: Math.round(performance.now() - startedAt),
  timedOut: false,
  sanitizedLog: sanitizeLog(message),
  outputPaths: [],
});

const validateProjectId = (projectId: string): void => {
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(projectId)
  ) {
    throw new Error('Invalid AI project id for pipeline command.');
  }
};

const validateLabelField = (labelField: string): void => {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(labelField)) {
    throw new Error('Invalid AI label field for pipeline command.');
  }
};

const validateRegionalRunId = (regionalRunId: string): void => {
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(regionalRunId)) {
    throw new Error('Invalid AI regional run id for pipeline command.');
  }
};

const validateRegionalPreset = (regionPreset: string): void => {
  if (regionPreset !== 'south_lebanon') {
    throw new Error('Invalid AI regional preset for pipeline command.');
  }
};

const resolveRunConfigDir = (config: AiPipelineConfig): string =>
  path.resolve(config.runConfigDir ?? path.join(process.cwd(), 'tmp', 'ai-run-configs'));

const validateRunConfigPath = (config: AiPipelineConfig, runConfigPath: string): string => {
  if (!runConfigPath.trim()) {
    throw new Error('Invalid AI run config path for pipeline command.');
  }
  if (runConfigPath.includes('\0')) {
    throw new Error('Invalid AI run config path for pipeline command.');
  }

  const resolved = path.resolve(runConfigPath);
  const allowedRoot = resolveRunConfigDir(config);
  const relative = path.relative(allowedRoot, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error('AI run config path must stay inside the configured run-config directory.');
  }
  if (path.extname(resolved).toLowerCase() !== '.json') {
    throw new Error('AI run config path must be a JSON file.');
  }
  return resolved;
};

const appendRunConfigArg = (
  config: AiPipelineConfig,
  args: string[],
  runConfigPath?: string,
): string[] => {
  if (!runConfigPath) {
    return args;
  }
  return [...args, '--config', validateRunConfigPath(config, runConfigPath)];
};

class DefaultAiPipelineService implements AiPipelineService {
  private readonly configLoader: () => AiPipelineConfig;

  constructor(configLoader: () => AiPipelineConfig = loadAiPipelineConfigFromEnv) {
    this.configLoader = configLoader;
  }

  getConfig(): AiPipelineConfig {
    return this.configLoader();
  }

  checkConfig(): Promise<AiPipelineCommandResult> {
    return this.runAllowedCommand('config_check', 'config.py', ['--check']);
  }

  dryRun(runConfigPath?: string): Promise<AiPipelineCommandResult> {
    return this.runAllowedCommand('dry_run', 'run_pipeline.py', ['--dry-run'], [], runConfigPath);
  }

  probeProject(
    projectId: string,
    labelField: string,
    runConfigPath?: string,
  ): Promise<AiPipelineCommandResult> {
    validateProjectId(projectId);
    validateLabelField(labelField);
    return this.runAllowedCommand(
      'probe_project',
      'run_pipeline.py',
      [
        '--probe-db',
        '--project-id',
        projectId,
        '--label-field',
        labelField,
      ],
      [],
      runConfigPath,
    );
  }

  exportGroundTruthLocal(projectId: string, labelField: string): Promise<AiPipelineCommandResult> {
    validateProjectId(projectId);
    validateLabelField(labelField);
    return this.runAllowedCommand(
      'export_ground_truth_local',
      '01_export_ground_truth.py',
      ['--project-id', projectId, '--label-field', labelField, '--local-only'],
      [`outputs/projects/${projectId}/ground_truth.geojson`],
    );
  }

  extractRegionalFeatures(
    projectId: string,
    labelField: string,
    regionalRunId: string,
    runConfigPath?: string,
  ): Promise<AiPipelineCommandResult> {
    validateProjectId(projectId);
    validateLabelField(labelField);
    validateRegionalRunId(regionalRunId);
    return this.runAllowedCommand(
      'regional_feature_extraction',
      'run_pipeline.py',
      [
        '--regional-feature-extraction',
        '--project-id',
        projectId,
        '--label-field',
        labelField,
        '--ground-truth',
        `outputs/projects/${projectId}/ground_truth.geojson`,
        '--regional-run-id',
        regionalRunId,
      ],
      [
        `outputs/runs/${regionalRunId}/feature_table.csv`,
        `outputs/runs/${regionalRunId}/feature_extraction_summary.json`,
      ],
      runConfigPath,
    );
  }

  evaluateRegionalModel(
    projectId: string,
    labelField: string,
    regionalRunId: string,
    featureTablePath = `outputs/runs/${regionalRunId}/feature_table.csv`,
    runConfigPath?: string,
  ): Promise<AiPipelineCommandResult> {
    validateProjectId(projectId);
    validateLabelField(labelField);
    validateRegionalRunId(regionalRunId);
    return this.runAllowedCommand(
      'regional_model_eval',
      'run_pipeline.py',
      [
        '--regional-model-eval',
        '--project-id',
        projectId,
        '--label-field',
        labelField,
        '--feature-table',
        featureTablePath,
        '--regional-run-id',
        regionalRunId,
      ],
      [
        `outputs/runs/${regionalRunId}/metrics.json`,
        `outputs/runs/${regionalRunId}/model_metadata.json`,
        `outputs/runs/${regionalRunId}/confusion_matrix.csv`,
        `outputs/runs/${regionalRunId}/classification_report.csv`,
        `outputs/runs/${regionalRunId}/feature_importance.csv`,
      ],
      runConfigPath,
    );
  }

  classifyRegional(
    projectId: string,
    labelField: string,
    regionalRunId: string,
    modelMetadataPath = `outputs/runs/${regionalRunId}/model_metadata.json`,
    regionPreset = 'south_lebanon',
    runConfigPath?: string,
  ): Promise<AiPipelineCommandResult> {
    validateProjectId(projectId);
    validateLabelField(labelField);
    validateRegionalRunId(regionalRunId);
    validateRegionalPreset(regionPreset);
    return this.runAllowedCommand(
      'regional_classification',
      'run_pipeline.py',
      [
        '--regional-classification',
        '--project-id',
        projectId,
        '--label-field',
        labelField,
        '--region-preset',
        regionPreset,
        '--model-metadata',
        modelMetadataPath,
        '--regional-run-id',
        regionalRunId,
      ],
      [
        `outputs/runs/${regionalRunId}/regional_classification_summary.json`,
      ],
      runConfigPath,
    );
  }

  prepareRegionalVectorArtifacts(
    projectId: string,
    labelField: string,
    regionalRunId: string,
    classificationSummaryPath = `outputs/runs/${regionalRunId}/regional_classification_summary.json`,
    regionPreset = 'south_lebanon',
    runConfigPath?: string,
  ): Promise<AiPipelineCommandResult> {
    validateProjectId(projectId);
    validateLabelField(labelField);
    validateRegionalRunId(regionalRunId);
    validateRegionalPreset(regionPreset);
    return this.runAllowedCommand(
      'regional_vectorization_artifacts',
      'run_pipeline.py',
      [
        '--regional-vectorization-artifacts',
        '--project-id',
        projectId,
        '--label-field',
        labelField,
        '--region-preset',
        regionPreset,
        '--classification-summary',
        classificationSummaryPath,
        '--regional-run-id',
        regionalRunId,
      ],
      [
        `outputs/runs/${regionalRunId}/classification_polygons.geojson`,
        `outputs/runs/${regionalRunId}/confidence_polygons.geojson`,
        `outputs/runs/${regionalRunId}/uncertainty_areas.geojson`,
        `outputs/runs/${regionalRunId}/vectorization_summary.json`,
      ],
      runConfigPath,
    );
  }

  private async runAllowedCommand(
    command: AiPipelineCommandName,
    scriptName: 'config.py' | 'run_pipeline.py' | '01_export_ground_truth.py',
    args: string[],
    outputPaths: string[] = [],
    runConfigPath?: string,
  ): Promise<AiPipelineCommandResult> {
    const startedAt = performance.now();
    const config = this.getConfig();

    if (!config.enabled) {
      return failureResult(command, 'AI pipeline bridge is disabled.', startedAt);
    }
    if (!config.root) {
      return failureResult(command, 'AI pipeline root is not configured.', startedAt);
    }
    if (!fs.existsSync(config.root) || !fs.statSync(config.root).isDirectory()) {
      return failureResult(
        command,
        'AI pipeline root does not exist or is not a directory.',
        startedAt,
      );
    }
    if (!config.pythonBin.trim()) {
      return failureResult(command, 'AI Python executable is not configured.', startedAt);
    }

    const scriptPath = path.join(config.root, scriptName);
    if (!fs.existsSync(scriptPath) || !fs.statSync(scriptPath).isFile()) {
      return failureResult(
        command,
        `Required AI pipeline script is missing: ${scriptName}.`,
        startedAt,
      );
    }

    let commandArgs: string[];
    try {
      commandArgs =
        scriptName === 'run_pipeline.py'
          ? appendRunConfigArg(config, args, runConfigPath)
          : args;
    } catch (error) {
      return failureResult(
        command,
        error instanceof Error ? error.message : 'Invalid AI pipeline command arguments.',
        startedAt,
      );
    }

    return new Promise<AiPipelineCommandResult>((resolve) => {
      execFile(
        config.pythonBin,
        [scriptName, ...commandArgs],
        {
          cwd: config.root as string,
          timeout: config.timeoutMs,
          maxBuffer: 1024 * 1024,
          windowsHide: true,
        },
        (error, stdout, stderr) => {
          const durationMs = Math.round(performance.now() - startedAt);
          const timedOut = Boolean(
            error && typeof error === 'object' && 'killed' in error && error.killed,
          );
          const exitCode =
            error && typeof error === 'object' && 'code' in error && typeof error.code === 'number'
              ? error.code
              : error
                ? null
                : 0;
          const rawLog = [stdout, stderr]
            .filter((part) => typeof part === 'string' && part.length > 0)
            .join('\n');
          const errorMessage =
            error instanceof Error && rawLog.trim().length === 0 ? error.message : '';

          resolve({
            command,
            success: !error,
            exitCode,
            durationMs,
            timedOut,
            sanitizedLog: sanitizeLog([rawLog, errorMessage].filter(Boolean).join('\n')),
            outputPaths: !error ? outputPaths : [],
          });
        },
      );
    });
  }
}

const createAiPipelineService = (configLoader?: () => AiPipelineConfig): AiPipelineService =>
  new DefaultAiPipelineService(configLoader);

export {
  createAiPipelineService,
  loadAiPipelineConfigFromEnv,
  resolveRunConfigDir,
  sanitizeLog,
  type AiPipelineCommandName,
  type AiPipelineCommandResult,
  type AiPipelineConfig,
  type AiPipelineMode,
  type AiPipelineService,
};
