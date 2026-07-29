const path = require('path');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const compression = require('compression');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');

const { notFound, errorHandler } = require('./middleware/error');
import { attachRequestContext } from './middleware/requestContext';
import {
  collectRequestMetrics,
  createMetricsHandler,
  readinessHandler,
  assertMetricsConfig,
} from './middleware/observability';
import { createOperationalTokenGuard } from './middleware/operationalAccess';
import { broadcastWorkflowMutations } from './middleware/workflowBroadcast';
import { offlineSyncIngressRateLimit } from './middleware/offlineSyncRateLimit';
import { categoryIconsDir } from './config/upload';
import { privateMediaRouter } from './routes/privateMedia.routes';
import {
  configureRateLimitBackend,
  createSharedRateLimitStore,
} from './services/sharedRateLimit.service';

// Import routes
const authRoutes = require('./routes/auth.routes');
const projectRoutes = require('./routes/project.routes');
const featureRoutes = require('./routes/feature.routes');
const importRoutes = require('./routes/import.routes');
const exportRoutes = require('./routes/export.routes');
const aiRoutes = require('./routes/ai.routes');
const meRoutes = require('./routes/me.routes');
const {
  assignmentRouter,
  photoRouter,
  categoryRouter,
  notificationRouter,
  offlineMapRouter,
  settingsRouter,
  userRouter,
} = require('./routes/index');

const isLocalDevelopmentOrigin = (origin: string): boolean => {
  try {
    const parsed = new URL(origin);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return false;
    }
    return (
      parsed.hostname === 'localhost' ||
      parsed.hostname === '127.0.0.1' ||
      parsed.hostname === '[::1]' ||
      parsed.hostname === '::1'
    );
  } catch (_) {
    return false;
  }
};

const buildApp = (env) => {
  configureRateLimitBackend(env);
  const app = express();
  const normalizedApiPrefix = String(env.API_VERSION_PREFIX || '/api/v1').replace(/\/+$/, '');
  const legacyPrefix = '/api';
  const apiPrefixes = [normalizedApiPrefix];
  if (env.ENABLE_LEGACY_API_PREFIX && normalizedApiPrefix !== legacyPrefix) {
    apiPrefixes.push(legacyPrefix);
  }
  const allowedOrigins = (env.CORS_ORIGIN || '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);

  if (env.CORS_STRICT && env.NODE_ENV === 'production' && allowedOrigins.length === 0) {
    throw new Error('CORS_STRICT=true requires CORS_ORIGIN to be configured in production');
  }

  if (env.TRUST_PROXY) {
    app.set('trust proxy', env.TRUST_PROXY_HOPS);
  }

  const corsOriginHandler = (origin, callback) => {
    if (!origin) {
      callback(null, true);
      return;
    }

    if (env.NODE_ENV !== 'production' && isLocalDevelopmentOrigin(origin)) {
      callback(null, true);
      return;
    }

    if (!env.CORS_STRICT && allowedOrigins.length === 0) {
      callback(null, true);
      return;
    }

    if (allowedOrigins.includes(origin)) {
      callback(null, true);
      return;
    }

    const corsError = new Error('Origin is not allowed by CORS') as Error & {
      statusCode?: number;
    };
    corsError.statusCode = 403;
    callback(corsError);
  };

  app.use(attachRequestContext);
  app.use(collectRequestMetrics);
  app.use(broadcastWorkflowMutations);

  app.use((req, res, next) => {
    if (!env.ENFORCE_HTTPS || env.NODE_ENV !== 'production') {
      next();
      return;
    }

    if (req.secure) {
      next();
      return;
    }

    res.status(426).json({
      success: false,
      message: 'HTTPS is required in production',
      requestId: req.requestId,
    });
  });

  app.use(
    helmet({
      hsts: env.ENFORCE_HTTPS
        ? {
            maxAge: 31536000,
            includeSubDomains: true,
            preload: true,
          }
        : false,
      crossOriginEmbedderPolicy: false,
    })
  );
  app.use(
    cors({
      origin: corsOriginHandler,
      credentials: env.CORS_CREDENTIALS,
    })
  );
  // Bound request-body parsing and authentication work for every feature/photo
  // synchronization ingress, including requests with invalid or stale tokens.
  app.use(offlineSyncIngressRateLimit);
  app.use(express.json({ limit: '10mb' }));
  app.use(express.urlencoded({ extended: true, limit: '10mb' }));
  app.use(compression());
  if (env.API_DOCS_ENABLED) {
    if (env.NODE_ENV === 'production') {
      app.use(
        '/docs',
        createOperationalTokenGuard({
          expectedToken: env.API_DOCS_TOKEN,
          headerName: 'x-api-docs-token',
          hidden: true,
        }),
      );
    }
    app.use(
      '/docs',
      express.static(path.join(__dirname, '..', 'docs'), {
        dotfiles: 'deny',
        index: false,
        redirect: false,
      }),
    );
  }
  app.use(
    '/uploads/category-icons',
    express.static(categoryIconsDir, {
      dotfiles: 'deny',
      index: false,
      redirect: false,
    }),
  );
  app.use('/uploads', privateMediaRouter);

  if (env.NODE_ENV === 'development') {
    app.use(morgan('dev'));
  }

  const limiter = rateLimit({
    windowMs: env.RATE_LIMIT_WINDOW_MS,
    max: env.RATE_LIMIT_MAX_REQUESTS,
    message: 'Too many requests from this IP, please try again later',
    standardHeaders: true,
    legacyHeaders: false,
    passOnStoreError: false,
    store: createSharedRateLimitStore('anonymous-api'),
    skip: (req) => Boolean(req.headers.authorization),
  });
  for (const prefix of apiPrefixes) {
    app.use(`${prefix}/`, limiter);
  }

  const authLimiter = rateLimit({
    windowMs: env.RATE_LIMIT_WINDOW_MS,
    max: env.RATE_LIMIT_AUTH_MAX_REQUESTS,
    message: 'Too many authentication attempts, please try again later',
    standardHeaders: true,
    legacyHeaders: false,
    passOnStoreError: false,
    store: createSharedRateLimitStore('authentication'),
  });
  for (const prefix of apiPrefixes) {
    app.use(`${prefix}/auth`, authLimiter);
  }

  app.get('/health', (req, res) => {
    res.json({
      success: true,
      status: 'live',
      message: 'Server is running',
      timestamp: new Date().toISOString(),
      requestId: req.requestId,
    });
  });
  app.get('/ready', readinessHandler);
  assertMetricsConfig(env);
  if (env.METRICS_ENABLED) {
    if (String(env.METRICS_TOKEN ?? '').trim()) {
      app.get(
        '/metrics',
        createOperationalTokenGuard({
          expectedToken: env.METRICS_TOKEN,
          headerName: 'x-metrics-token',
        }),
      );
    }
    app.get(
      '/metrics',
      createMetricsHandler({
        uploadDir: env.UPLOAD_DIR,
        exportDir: env.EXPORT_DIR,
      }),
    );
  }

  const metadataHandler = (req, res) => {
    res.json({
      success: true,
      message: 'Lebanese GIS Mobile Application API',
      version: '1.0.0',
      activePrefix: normalizedApiPrefix,
      legacyPrefixEnabled: Boolean(env.ENABLE_LEGACY_API_PREFIX),
      endpoints: {
        auth: `${normalizedApiPrefix}/auth`,
        projects: `${normalizedApiPrefix}/projects`,
        features: `${normalizedApiPrefix}/features`,
        assignments: `${normalizedApiPrefix}/assignments`,
        imports: `${normalizedApiPrefix}/imports`,
        ai: `${normalizedApiPrefix}/ai`,
        me: `${normalizedApiPrefix}/me`,
        photos: `${normalizedApiPrefix}/photos`,
        categories: `${normalizedApiPrefix}/categories`,
        notifications: `${normalizedApiPrefix}/notifications`,
        offlineMap: `${normalizedApiPrefix}/offline-map`,
        settings: `${normalizedApiPrefix}/settings`,
        users: `${normalizedApiPrefix}/users (admin only)`,
      },
      documentation: env.API_DOCS_ENABLED ? '/docs/openapi.yaml' : 'disabled',
      operations: {
        health: '/health',
        readiness: '/ready',
        metrics: env.METRICS_ENABLED ? '/metrics' : 'disabled',
      },
    });
  };

  for (const prefix of apiPrefixes) {
    app.use(`${prefix}/auth`, authRoutes);
    app.use(`${prefix}/projects`, projectRoutes);
    app.use(`${prefix}/features`, featureRoutes);
    app.use(`${prefix}/imports`, importRoutes);
    app.use(`${prefix}/exports`, exportRoutes);
    app.use(`${prefix}/ai`, aiRoutes);
    app.use(`${prefix}/me`, meRoutes);
    app.use(`${prefix}/assignments`, assignmentRouter);
    app.use(`${prefix}/photos`, photoRouter);
    app.use(`${prefix}/categories`, categoryRouter);
    app.use(`${prefix}/notifications`, notificationRouter);
    app.use(`${prefix}/offline-map`, offlineMapRouter);
    app.use(`${prefix}/settings`, settingsRouter);
    app.use(`${prefix}/users`, userRouter);
    app.get(prefix, metadataHandler);
  }

  app.use(notFound);
  app.use(errorHandler);

  return app;
};

module.exports = {
  buildApp,
};

export {};
