type JsonRecord = Record<string, unknown>;
const logger = require('../utils/logger');

export type AiServerRunStatus =
  | 'accepted'
  | 'created'
  | 'starting'
  | 'running'
  | 'completed'
  | 'failed'
  | 'cancelling'
  | 'cancelled'
  | 'paused'
  | 'queued';

export type AiServerStatusPayload = {
  run_id: string;
  project_id?: string;
  status: AiServerRunStatus | string;
  stage?: string | null;
  progress?: number | null;
  message?: string | null;
  started_at?: string | null;
  updated_at?: string | null;
  error?: unknown;
  metrics?: unknown;
  artifacts?: unknown;
  counts?: unknown;
  settings?: unknown;
  dry_run?: boolean | null;
  last_log_at?: string | null;
  last_log_message?: string | null;
};

export type AiServerStartPayload = {
  run_id: string;
  project_id: string;
  settings: JsonRecord;
  callback_url: string;
  callback_secret: string | null;
  requested_by: string | null;
  metadata: JsonRecord;
};

export type AiServerRetrainCheckPayload = {
  project_id: string;
  run_id?: string | null;
  settings: JsonRecord;
  validation_summary: JsonRecord;
};

type AiServerConfig = {
  baseUrl: string;
  timeoutMs: number;
  callbackSecret: string;
  internalApiSecret: string;
  appPublicApiUrl: string;
  callbackBaseUrl: string;
};

const stripTrailingSlash = (value: string): string => value.replace(/\/+$/, '');

const normalizeBaseUrl = (value: string): string => stripTrailingSlash(value.trim());

const envString = (key: string, fallback = ''): string => process.env[key] ?? fallback;

const parsePort = (value: string | undefined): number => {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 && parsed <= 65535 ? parsed : 3000;
};

const parseAiServerTimeoutMs = (value: string | undefined): number => {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 1000 && parsed <= 120000 ? parsed : 30000;
};

const normalizeApiPrefix = (value: string | undefined): string => {
  const trimmed = (value ?? '/api/v1').trim() || '/api/v1';
  const prefixed = trimmed.startsWith('/') ? trimmed : `/${trimmed}`;
  return stripTrailingSlash(prefixed);
};

const toJsonRecord = (value: unknown): JsonRecord =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as JsonRecord) : {};

export const loadAiServerConfigFromEnv = (): AiServerConfig => {
  const port = parsePort(process.env.PORT);
  const configuredAppPublicApiUrl = envString('APP_PUBLIC_API_URL').trim();
  const appPublicApiUrl = stripTrailingSlash(
    configuredAppPublicApiUrl || `http://localhost:${port}`,
  );
  const configuredCallbackBaseUrl = envString('AI_CALLBACK_BASE_URL').trim();

  return {
    baseUrl: normalizeBaseUrl(envString('AI_SERVER_URL')),
    timeoutMs: parseAiServerTimeoutMs(process.env.AI_SERVER_TIMEOUT_MS),
    callbackSecret: envString('AI_CALLBACK_SECRET', 'dev-ai-callback-secret-change-me'),
    internalApiSecret: envString(
      'AI_INTERNAL_API_SECRET',
      'dev-ai-internal-secret-change-me',
    ),
    appPublicApiUrl,
    callbackBaseUrl: stripTrailingSlash(configuredCallbackBaseUrl || appPublicApiUrl),
  };
};

class AiServerClient {
  private readonly config: AiServerConfig;

  constructor(config: AiServerConfig = loadAiServerConfigFromEnv()) {
    this.config = config;
  }

  isConfigured(): boolean {
    return this.config.baseUrl.length > 0;
  }

  callbackSecret(): string {
    return this.config.callbackSecret;
  }

  callbackUrl(runId: string): string {
    const prefix = normalizeApiPrefix(process.env.API_VERSION_PREFIX);
    return `${this.config.callbackBaseUrl}${prefix}/ai/runs/${runId}/callback`;
  }

  async health(): Promise<JsonRecord> {
    return this.request<JsonRecord>('GET', '/health');
  }

  async startRun(payload: AiServerStartPayload): Promise<AiServerStatusPayload> {
    return this.request<AiServerStatusPayload>('POST', '/api/runs/start', payload);
  }

  async getRunStatus(runId: string): Promise<AiServerStatusPayload> {
    return this.request<AiServerStatusPayload>('GET', `/api/runs/${runId}/status`);
  }

  async getRunDetails(runId: string): Promise<AiServerStatusPayload> {
    return this.request<AiServerStatusPayload>('GET', `/api/runs/${runId}`);
  }

  async cancelRun(runId: string): Promise<AiServerStatusPayload> {
    return this.request<AiServerStatusPayload>('POST', `/api/runs/${runId}/cancel`);
  }

  async resumeRun(runId: string): Promise<AiServerStatusPayload> {
    return this.request<AiServerStatusPayload>('POST', `/api/runs/${runId}/resume`);
  }

  async checkRetrain(payload: AiServerRetrainCheckPayload): Promise<JsonRecord> {
    return this.request<JsonRecord>('POST', '/api/retrain/check', payload);
  }

  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    if (!this.isConfigured()) {
      throw new Error('AI server URL is not configured.');
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.config.timeoutMs);
    const startedAt = Date.now();
    let responseStatus: number | undefined;
    try {
      const response = await fetch(`${this.config.baseUrl}${path}`, {
        method,
        headers: {
          Accept: 'application/json',
          'X-TerraLeb-Internal-Secret': this.config.internalApiSecret,
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
      });
      responseStatus = response.status;
      const text = await response.text();
      const payload = text.trim().length > 0 ? JSON.parse(text) : {};
      if (!response.ok) {
        const message =
          typeof payload?.message === 'string'
            ? payload.message
            : typeof payload?.detail === 'string'
              ? payload.detail
              : `AI server request failed with HTTP ${response.status}.`;
        throw new Error(message);
      }
      return toJsonRecord(payload) as T;
    } catch (error) {
      const reportedError =
        error instanceof Error && error.name === 'AbortError'
          ? new Error('AI server request timed out.')
          : error;
      const logMethod = responseStatus !== undefined && responseStatus < 500 ? 'warn' : 'error';
      logger[logMethod]('AI server request failed', {
        component: 'ai-server-client',
        method,
        path,
        statusCode: responseStatus,
        durationMs: Date.now() - startedAt,
        error: reportedError,
      });
      if (error instanceof Error && error.name === 'AbortError') {
        throw reportedError;
      }
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }
}

export const createAiServerClient = (): AiServerClient => new AiServerClient();

export { AiServerClient };
