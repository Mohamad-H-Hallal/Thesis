import { Readable, Transform } from 'node:stream';
import { query } from '../config/database';
import { validateEnv } from '../config/env';
import { consumeSharedDailyQuota } from './sharedRateLimit.service';
import { recordMapProviderRequest, type MapLayer, type MapOutcome } from './mapProviderMetrics';

const env = validateEnv();
const lebanonBounds = { west: 35.094, south: 33.045, east: 36.645, north: 34.695 };
let tokenCache: { value: string; expiresAtMs: number } | null = null;
let tokenRequest: Promise<string> | null = null;
let attributionCache: { value: string; expiresAtMs: number } | null = null;
let enabledCache: { value: boolean; expiresAtMs: number } | null = null;
const configurationCacheMs = 30_000;
const maximumTokenJsonBytes = 64 * 1024;
const maximumAttributionJsonBytes = 512 * 1024;

class MapProviderError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status: number,
    readonly retryAfterSeconds?: number,
  ) {
    super(message);
  }
}

const withTimeout = async (url: string, init: RequestInit): Promise<Response> => {
  const parsed = new URL(url);
  const allowedHosts = new Set(
    env.ARCGIS_ALLOWED_HOSTS.split(',')
      .map((host) => host.trim().toLowerCase())
      .filter(Boolean),
  );
  if (parsed.protocol !== 'https:' || !allowedHosts.has(parsed.hostname.toLowerCase())) {
    throw new MapProviderError(
      'Map provider configuration is invalid.',
      'MAP_PROVIDER_CONFIG',
      503,
    );
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), env.ARCGIS_REQUEST_TIMEOUT_MS);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
};

const boundedJson = async (
  response: Response,
  maximumBytes = maximumTokenJsonBytes,
): Promise<Record<string, unknown>> => {
  const declaredLength = Number(response.headers.get('content-length') ?? 0);
  if (declaredLength > maximumBytes) {
    throw new MapProviderError(
      'Map provider response exceeded its limit.',
      'MAP_PROVIDER_INVALID_RESPONSE',
      502,
    );
  }
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length > maximumBytes) {
    throw new MapProviderError(
      'Map provider response exceeded its limit.',
      'MAP_PROVIDER_INVALID_RESPONSE',
      502,
    );
  }
  try {
    const parsed = JSON.parse(buffer.toString('utf8')) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid');
    return parsed as Record<string, unknown>;
  } catch {
    throw new MapProviderError(
      'Map provider returned an invalid response.',
      'MAP_PROVIDER_INVALID_RESPONSE',
      502,
    );
  }
};

const arcgisToken = async (force = false): Promise<string> => {
  const now = Date.now();
  if (!force && tokenCache && tokenCache.expiresAtMs > now) return tokenCache.value;
  if (!force && tokenRequest) return tokenRequest;
  const pending = (async () => {
    const response = await withTimeout(env.ARCGIS_TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: env.ARCGIS_CLIENT_ID,
        client_secret: env.ARCGIS_CLIENT_SECRET,
        grant_type: 'client_credentials',
        f: 'json',
      }),
    });
    const payload: Record<string, unknown> = await boundedJson(response).catch(() => ({}));
    const value = typeof payload.access_token === 'string' ? payload.access_token.trim() : '';
    const expiresIn = Number(payload.expires_in ?? 3600);
    if (!response.ok || !value || !Number.isFinite(expiresIn)) {
      throw new MapProviderError(
        'Satellite map authorization is unavailable.',
        'MAP_AUTH_FAILED',
        503,
      );
    }
    tokenCache = {
      value,
      expiresAtMs:
        Date.now() + Math.max(60, expiresIn - env.ARCGIS_TOKEN_REFRESH_SKEW_SECONDS) * 1000,
    };
    return value;
  })();
  tokenRequest = pending;
  try {
    return await pending;
  } finally {
    if (tokenRequest === pending) tokenRequest = null;
  }
};

const isHybridEnabled = async (): Promise<boolean> => {
  if (!env.ARCGIS_ONLINE_ENABLED) return false;
  if (enabledCache && enabledCache.expiresAtMs > Date.now()) return enabledCache.value;
  const result = await query<{ hybrid_basemap_enabled: boolean }>(
    `SELECT hybrid_basemap_enabled FROM app_support_settings WHERE id = 1`,
  );
  const value = result.rows[0]?.hybrid_basemap_enabled !== false;
  enabledCache = { value, expiresAtMs: Date.now() + configurationCacheMs };
  return value;
};

const invalidateMapProviderConfigurationCache = (): void => {
  enabledCache = null;
  attributionCache = null;
};

const resetMapProviderCachesForTests = (): void => {
  if (env.NODE_ENV !== 'test') return;
  invalidateMapProviderConfigurationCache();
  tokenCache = null;
  tokenRequest = null;
};

const tileRange = (zoom: number): { minX: number; maxX: number; minY: number; maxY: number } => {
  const scale = 2 ** zoom;
  const longitudeToX = (longitude: number) => Math.floor(((longitude + 180) / 360) * scale);
  const latitudeToY = (latitude: number) => {
    const radians = (Math.max(-85.05112878, Math.min(85.05112878, latitude)) * Math.PI) / 180;
    return Math.floor(
      ((1 - Math.log(Math.tan(radians) + 1 / Math.cos(radians)) / Math.PI) / 2) * scale,
    );
  };
  return {
    minX: longitudeToX(lebanonBounds.west),
    maxX: longitudeToX(lebanonBounds.east),
    minY: latitudeToY(lebanonBounds.north),
    maxY: latitudeToY(lebanonBounds.south),
  };
};

const assertLebanonTile = (zoom: number, x: number, y: number): void => {
  if (
    !Number.isSafeInteger(zoom) ||
    !Number.isSafeInteger(x) ||
    !Number.isSafeInteger(y) ||
    zoom < 0 ||
    zoom > 20
  ) {
    throw new MapProviderError('Map tile coordinates are invalid.', 'MAP_TILE_INVALID', 400);
  }
  const range = tileRange(zoom);
  if (x < range.minX || x > range.maxX || y < range.minY || y > range.maxY) {
    throw new MapProviderError(
      'Map tile is outside the Lebanon service area.',
      'MAP_TILE_OUTSIDE_AREA',
      404,
    );
  }
};

const providerUrl = (
  template: string,
  zoom: number,
  x: number,
  y: number,
  token: string,
): string => {
  const raw = template
    .replaceAll('{z}', String(zoom))
    .replaceAll('{x}', String(x))
    .replaceAll('{y}', String(y));
  const url = new URL(raw);
  url.searchParams.set('token', token);
  return url.toString();
};

const boundedStream = (response: Response): Readable => {
  if (!response.body)
    throw new MapProviderError('Map provider returned no tile.', 'MAP_EMPTY', 502);
  let size = 0;
  return Readable.from(response.body as AsyncIterable<Uint8Array>).pipe(
    new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length;
        callback(
          size > env.ARCGIS_MAX_TILE_BYTES
            ? new MapProviderError(
                'Map tile exceeded the configured limit.',
                'MAP_TILE_TOO_LARGE',
                502,
              )
            : null,
          chunk,
        );
      },
    }),
  );
};

const fetchTile = async ({
  layer,
  zoom,
  x,
  y,
}: {
  layer: Exclude<MapLayer, 'metadata'>;
  zoom: number;
  x: number;
  y: number;
}): Promise<{ stream: Readable; contentType: string; cacheControl: string; etag?: string }> => {
  const started = Date.now();
  let outcome: MapOutcome = 'upstream_failure';
  try {
    assertLebanonTile(zoom, x, y);
    if (!(await isHybridEnabled())) {
      outcome = 'disabled';
      throw new MapProviderError(
        'Satellite map is temporarily unavailable.',
        'MAP_PROVIDER_DISABLED',
        503,
      );
    }
    const dailyQuota = await consumeSharedDailyQuota({
      namespace: 'arcgis-tiles',
      limit: env.ARCGIS_DAILY_TILE_SOFT_LIMIT,
    });
    if (!dailyQuota.allowed) {
      outcome = 'quota';
      throw new MapProviderError(
        'Satellite map daily usage limit has been reached.',
        'MAP_PROVIDER_DAILY_LIMIT',
        503,
        Math.max(1, Math.ceil((dailyQuota.resetAt.getTime() - Date.now()) / 1000)),
      );
    }
    const template =
      layer === 'imagery' ? env.ARCGIS_IMAGERY_TILE_URL : env.ARCGIS_REFERENCE_TILE_URL;
    let token = await arcgisToken();
    let response = await withTimeout(providerUrl(template, zoom, x, y, token), {
      headers: { 'User-Agent': env.MAP_PROVIDER_USER_AGENT },
    });
    if (response.status === 401 || response.status === 403) {
      tokenCache = null;
      token = await arcgisToken(true);
      response = await withTimeout(providerUrl(template, zoom, x, y, token), {
        headers: { 'User-Agent': env.MAP_PROVIDER_USER_AGENT },
      });
    }
    if (response.status === 429) {
      outcome = 'quota';
      const retryAfter = Number.parseInt(response.headers.get('retry-after') ?? '60', 10);
      throw new MapProviderError(
        'Satellite map quota is temporarily unavailable.',
        'MAP_PROVIDER_QUOTA',
        503,
        Number.isFinite(retryAfter) ? retryAfter : 60,
      );
    }
    if (response.status === 401 || response.status === 403) {
      outcome = 'auth_failure';
      throw new MapProviderError(
        'Satellite map authorization is unavailable.',
        'MAP_AUTH_FAILED',
        503,
      );
    }
    if (!response.ok) {
      throw new MapProviderError(
        'Satellite map provider is unavailable.',
        'MAP_PROVIDER_FAILED',
        502,
      );
    }
    const contentType = (response.headers.get('content-type') ?? '').split(';', 1)[0]?.trim();
    if (!contentType || !['image/jpeg', 'image/png', 'image/webp'].includes(contentType)) {
      throw new MapProviderError(
        'Map provider returned an invalid tile.',
        'MAP_TILE_INVALID_CONTENT',
        502,
      );
    }
    const contentLength = Number(response.headers.get('content-length') ?? 0);
    if (contentLength > env.ARCGIS_MAX_TILE_BYTES) {
      throw new MapProviderError(
        'Map tile exceeded the configured limit.',
        'MAP_TILE_TOO_LARGE',
        502,
      );
    }
    outcome = 'success';
    return {
      stream: boundedStream(response),
      contentType,
      cacheControl: response.headers.get('cache-control') ?? 'private, max-age=3600',
      ...(response.headers.get('etag') ? { etag: response.headers.get('etag') as string } : {}),
    };
  } finally {
    recordMapProviderRequest({ layer, outcome, durationMs: Date.now() - started });
  }
};

const getProviderConfiguration = async (): Promise<{ enabled: boolean; attribution: string }> => {
  const enabled = await isHybridEnabled();
  if (!enabled) return { enabled: false, attribution: '© Esri and imagery providers' };
  if (attributionCache && attributionCache.expiresAtMs > Date.now()) {
    return { enabled: true, attribution: attributionCache.value };
  }
  const started = Date.now();
  let outcome: MapOutcome = 'upstream_failure';
  try {
    const url = new URL(env.ARCGIS_ATTRIBUTION_URL);
    url.searchParams.set('f', 'json');
    url.searchParams.set('token', await arcgisToken());
    const response = await withTimeout(url.toString(), {
      headers: { 'User-Agent': env.MAP_PROVIDER_USER_AGENT },
    });
    if (!response.ok)
      throw new MapProviderError('Map attribution is unavailable.', 'MAP_ATTRIBUTION_FAILED', 502);
    const payload = await boundedJson(response, maximumAttributionJsonBytes);
    const copyrightText =
      typeof payload.copyrightText === 'string' ? payload.copyrightText.trim() : '';
    const contributorAttributions = Array.isArray(payload.contributors)
      ? payload.contributors
          .map((contributor) =>
            contributor && typeof contributor === 'object' && 'attribution' in contributor
              ? String((contributor as { attribution?: unknown }).attribution ?? '').trim()
              : '',
          )
          .filter(Boolean)
      : [];
    const attribution =
      [...new Set([copyrightText, ...contributorAttributions].filter(Boolean))].join(' · ') ||
      '© Esri and imagery providers';
    if (attribution.length > 4000) {
      throw new MapProviderError(
        'Map attribution exceeded its reviewed limit.',
        'MAP_ATTRIBUTION_FAILED',
        502,
      );
    }
    attributionCache = { value: attribution, expiresAtMs: Date.now() + 24 * 60 * 60 * 1000 };
    outcome = 'success';
    return { enabled: true, attribution };
  } finally {
    recordMapProviderRequest({ layer: 'metadata', outcome, durationMs: Date.now() - started });
  }
};

export {
  MapProviderError,
  assertLebanonTile,
  fetchTile,
  getProviderConfiguration,
  invalidateMapProviderConfigurationCache,
  resetMapProviderCachesForTests,
};
