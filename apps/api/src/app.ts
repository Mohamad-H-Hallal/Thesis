const path = require('path');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const compression = require('compression');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');

const logger = require('./utils/logger');
const { notFound, errorHandler } = require('./middleware/error');
import { attachRequestContext } from './middleware/requestContext';
import {
  collectRequestMetrics,
  metricsHandler,
  readinessHandler,
  assertMetricsConfig,
} from './middleware/observability';
import { broadcastWorkflowMutations } from './middleware/workflowBroadcast';
import { guardLegacyFeaturePhotoDirectory } from './middleware/legacyFeaturePhotoGuard';
import { offlineSyncIngressRateLimit } from './middleware/offlineSyncRateLimit';

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
    app.set('trust proxy', 1);
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

    callback(new Error('Origin is not allowed by CORS'));
  };

  app.use(attachRequestContext);
  app.use(collectRequestMetrics);
  app.use(broadcastWorkflowMutations);

  app.use((req, res, next) => {
    if (!env.ENFORCE_HTTPS || env.NODE_ENV !== 'production') {
      next();
      return;
    }

    const forwardedProto = req.headers['x-forwarded-proto'];
    const isHttps = req.secure || forwardedProto === 'https';

    if (isHttps) {
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
  app.use('/docs', express.static(path.join(__dirname, '..', 'docs')));
  app.use('/uploads/photos', guardLegacyFeaturePhotoDirectory('photos'));
  app.use('/uploads/thumbnails', guardLegacyFeaturePhotoDirectory('thumbnails'));
  app.use('/uploads', express.static(path.resolve(env.UPLOAD_DIR ?? './uploads')));

  if (env.NODE_ENV === 'development') {
    app.use(morgan('dev'));
  } else {
    app.use(
      morgan('combined', {
        stream: {
          write: (message) => logger.info(message.trim()),
        },
      })
    );
  }

  const limiter = rateLimit({
    windowMs: env.RATE_LIMIT_WINDOW_MS,
    max: env.RATE_LIMIT_MAX_REQUESTS,
    message: 'Too many requests from this IP, please try again later',
    standardHeaders: true,
    legacyHeaders: false,
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
      environment: env.NODE_ENV,
      requestId: req.requestId,
    });
  });
  app.get('/ready', readinessHandler);
  assertMetricsConfig(env);
  if (env.METRICS_ENABLED) {
    app.get('/metrics', metricsHandler);
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
      documentation: '/docs/openapi.yaml',
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
