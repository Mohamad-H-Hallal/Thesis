import fs from 'node:fs';
import { applicationDefault, cert, getApp, getApps, initializeApp } from 'firebase-admin/app';
import type { ServiceAccount } from 'firebase-admin/app';
import { getMessaging, type Messaging } from 'firebase-admin/messaging';
import { validateEnv } from '../config/env';
const logger = require('../utils/logger');

const firebaseAppName = 'notifications-push';

const parseInlineServiceAccount = (): ServiceAccount | null => {
  const env = validateEnv();

  const inlineJson = String(env.FIREBASE_SERVICE_ACCOUNT_JSON ?? '').trim();
  if (inlineJson.length > 0) {
    return JSON.parse(inlineJson) as ServiceAccount;
  }

  const base64 = String(env.FIREBASE_SERVICE_ACCOUNT_BASE64 ?? '').trim();
  if (base64.length > 0) {
    return JSON.parse(Buffer.from(base64, 'base64').toString('utf8')) as ServiceAccount;
  }

  const path = String(env.FIREBASE_SERVICE_ACCOUNT_PATH ?? '').trim();
  if (path.length > 0) {
    return JSON.parse(fs.readFileSync(path, 'utf8')) as ServiceAccount;
  }

  return null;
};

const isPushDeliveryConfigured = (): boolean => {
  const env = validateEnv();
  if (!env.PUSH_NOTIFICATIONS_ENABLED) {
    return false;
  }

  return (
    parseInlineServiceAccount() !== null ||
    String(process.env.GOOGLE_APPLICATION_CREDENTIALS ?? '').trim().length > 0
  );
};

const isPlatformPushEnabled = (platform: 'android' | 'ios'): boolean => {
  const env = validateEnv();
  if (!env.PUSH_NOTIFICATIONS_ENABLED) {
    return false;
  }

  return platform === 'ios'
    ? env.IOS_PUSH_NOTIFICATIONS_ENABLED
    : env.ANDROID_PUSH_NOTIFICATIONS_ENABLED;
};

const getPushMessaging = (): Messaging | null => {
  if (!isPushDeliveryConfigured()) {
    return null;
  }

  const existing = getApps().find((app) => app.name == firebaseAppName);
  if (existing) {
    return getMessaging(existing);
  }

  const serviceAccount = parseInlineServiceAccount();
  const app = initializeApp(
    serviceAccount != null
      ? {
          credential: cert(serviceAccount),
        }
      : {
          credential: applicationDefault(),
        },
    firebaseAppName,
  );

  logger.info('Firebase push messaging initialized', {
    usingServiceAccountFile:
      String(process.env.GOOGLE_APPLICATION_CREDENTIALS ?? '').trim().length > 0 &&
      serviceAccount == null,
  });

  return getMessaging(app);
};

const getFirebaseApp = () => getApp(firebaseAppName);

export {
  getFirebaseApp,
  getPushMessaging,
  isPlatformPushEnabled,
  isPushDeliveryConfigured,
};
