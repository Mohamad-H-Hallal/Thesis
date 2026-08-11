import { RedisStore, type RedisReply } from 'rate-limit-redis';
import { createClient, type RedisClientType } from 'redis';
import type { Store } from 'express-rate-limit';
const logger = require('../utils/logger');

type RateLimitStoreMode = 'memory' | 'redis';

interface RateLimitBackendConfig {
  RATE_LIMIT_STORE?: RateLimitStoreMode;
  REDIS_URL?: string;
  REDIS_PASSWORD?: string;
  REDIS_CONNECT_TIMEOUT_MS?: number;
}

class RateLimitBackendUnavailableError extends Error {
  statusCode = 503;
  errorCode = 'RATE_LIMIT_BACKEND_UNAVAILABLE';
  disposition = 'retry';
  retryable = true;

  constructor(message = 'Shared rate limiting is temporarily unavailable.') {
    super(message);
    this.name = 'RateLimitBackendUnavailableError';
  }
}

let configuredMode: RateLimitStoreMode =
  process.env.RATE_LIMIT_STORE === 'redis' ? 'redis' : 'memory';
let configuredRedisUrl = process.env.REDIS_URL?.trim() ?? '';
let configuredRedisPassword = process.env.REDIS_PASSWORD ?? '';
let configuredConnectTimeoutMs = Math.max(
  1000,
  Number.parseInt(process.env.REDIS_CONNECT_TIMEOUT_MS ?? '5000', 10) || 5000,
);
let redisClient: RedisClientType | null = null;
let redisConnectionPromise: Promise<void> | null = null;
let rateLimitBackendClosed = false;
const pendingRedisCommands = new Set<Promise<unknown>>();

const configureRateLimitBackend = (config: RateLimitBackendConfig): void => {
  const nextMode = config.RATE_LIMIT_STORE === 'redis' ? 'redis' : 'memory';
  const nextUrl = String(config.REDIS_URL ?? '').trim();
  const nextPassword = String(config.REDIS_PASSWORD ?? '');
  const nextTimeout = Math.max(1000, Number(config.REDIS_CONNECT_TIMEOUT_MS ?? 5000));

  if (
    redisClient &&
    (nextMode !== configuredMode ||
      nextUrl !== configuredRedisUrl ||
      nextPassword !== configuredRedisPassword)
  ) {
    throw new Error('Rate-limit backend cannot be reconfigured after its client is created');
  }

  configuredMode = nextMode;
  configuredRedisUrl = nextUrl;
  configuredRedisPassword = nextPassword;
  configuredConnectTimeoutMs = nextTimeout;
};

const getOrCreateRedisClient = (): RedisClientType => {
  if (redisClient) {
    return redisClient;
  }
  if (!configuredRedisUrl) {
    throw new RateLimitBackendUnavailableError('REDIS_URL is required for shared rate limiting.');
  }

  redisClient = createClient({
    url: configuredRedisUrl,
    ...(configuredRedisPassword ? { password: configuredRedisPassword } : {}),
    socket: {
      connectTimeout: configuredConnectTimeoutMs,
      reconnectStrategy: (retries) => {
        if (retries >= 8) {
          return new Error('Redis reconnect retry limit reached');
        }
        return Math.min(250 * 2 ** retries, 5000);
      },
    },
  });
  redisClient.on('error', (error: Error) => {
    logger.error('Shared rate-limit backend error', {
      error: error.message,
    });
  });
  return redisClient;
};

const ensureRedisClientReady = async (client: RedisClientType): Promise<void> => {
  if (client.isReady) {
    return;
  }

  if (!redisConnectionPromise) {
    redisConnectionPromise = (async () => {
      if (!client.isOpen) {
        await client.connect();
      }
      await client.ping();
    })().finally(() => {
      redisConnectionPromise = null;
    });
  }

  await redisConnectionPromise;
  if (!client.isReady) {
    throw new RateLimitBackendUnavailableError();
  }
};

const createSharedRateLimitStore = (policyName: string): Store | undefined => {
  if (configuredMode !== 'redis') {
    return undefined;
  }
  if (rateLimitBackendClosed) {
    return {
      increment: async () => {
        throw new RateLimitBackendUnavailableError();
      },
      decrement: async () => undefined,
      resetKey: async () => undefined,
    };
  }

  const client = getOrCreateRedisClient();
  return new RedisStore({
    prefix: `gis-rate-limit:${policyName}:`,
    sendCommand: async (...args: string[]) => {
      if (rateLimitBackendClosed) {
        throw new RateLimitBackendUnavailableError();
      }
      const command: Promise<RedisReply> = (async () => {
        await ensureRedisClientReady(client);
        const reply = await client.sendCommand(args as never);
        if (reply === null) {
          throw new RateLimitBackendUnavailableError('Redis returned an empty rate-limit reply.');
        }
        return reply as unknown as RedisReply;
      })();
      pendingRedisCommands.add(command);
      try {
        return await command;
      } catch (error) {
        throw new RateLimitBackendUnavailableError(
          error instanceof Error ? error.message : undefined,
        );
      } finally {
        pendingRedisCommands.delete(command);
      }
    },
  });
};

const initializeRateLimitBackend = async (config: RateLimitBackendConfig): Promise<void> => {
  configureRateLimitBackend(config);
  rateLimitBackendClosed = false;
  if (configuredMode !== 'redis') {
    logger.warn('Using process-local rate limiting', {
      mode: configuredMode,
      productionSafe: false,
    });
    return;
  }

  const client = getOrCreateRedisClient();
  await ensureRedisClientReady(client);
  await client.ping();
  logger.info('Shared rate-limit backend is ready', { mode: configuredMode });
};

const getRateLimitBackendReadiness = async (): Promise<{
  mode: RateLimitStoreMode;
  status: 'up' | 'down' | 'local';
  latencyMs?: number;
}> => {
  if (configuredMode !== 'redis') {
    return { mode: configuredMode, status: 'local' };
  }

  const startedAt = Date.now();
  try {
    const client = getOrCreateRedisClient();
    if (!client.isReady) {
      throw new RateLimitBackendUnavailableError();
    }
    await client.ping();
    return {
      mode: configuredMode,
      status: 'up',
      latencyMs: Date.now() - startedAt,
    };
  } catch {
    return {
      mode: configuredMode,
      status: 'down',
    };
  }
};

const closeRateLimitBackend = async (): Promise<void> => {
  rateLimitBackendClosed = true;
  if (!redisClient) {
    return;
  }
  const client = redisClient;
  redisClient = null;
  if (redisConnectionPromise) {
    await redisConnectionPromise.catch(() => undefined);
  }
  if (pendingRedisCommands.size > 0) {
    await Promise.allSettled([...pendingRedisCommands]);
  }
  if (client.isOpen) {
    await client.quit();
  }
};

const isRateLimitBackendUnavailableError = (error: unknown): boolean =>
  error instanceof RateLimitBackendUnavailableError ||
  (typeof error === 'object' &&
    error !== null &&
    (error as { errorCode?: unknown }).errorCode === 'RATE_LIMIT_BACKEND_UNAVAILABLE');

export {
  RateLimitBackendUnavailableError,
  closeRateLimitBackend,
  configureRateLimitBackend,
  createSharedRateLimitStore,
  getRateLimitBackendReadiness,
  initializeRateLimitBackend,
  isRateLimitBackendUnavailableError,
};
