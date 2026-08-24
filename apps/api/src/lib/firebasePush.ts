import fs from 'node:fs';
import { type AuthClient, GoogleAuth } from 'google-auth-library';
import { validateEnv } from '../config/env';
const logger = require('../utils/logger');

type PushPlatform = 'android' | 'ios';

type PushServiceAccount = {
  project_id?: string;
  client_email?: string;
  private_key?: string;
};

type PushNotificationMessage = {
  token: string;
  title: string;
  message: string;
  notificationId: string;
  showSensitivePreview?: boolean;
};

class PushDeliveryError extends Error {
  code: string;
  status?: number;

  constructor(message: string, code: string, status?: number) {
    super(message);
    this.name = 'PushDeliveryError';
    this.code = code;
    this.status = status;
  }
}

const pushScope = 'https://www.googleapis.com/auth/firebase.messaging';
const firebaseProjectIdPattern = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;

let authClientPromise: Promise<AuthClient> | null = null;
let projectIdPromise: Promise<string | null> | null = null;
let hasLoggedInitialization = false;

const parseInlineServiceAccount = (): PushServiceAccount | null => {
  const env = validateEnv();

  const inlineJson = String(env.FIREBASE_SERVICE_ACCOUNT_JSON ?? '').trim();
  if (inlineJson.length > 0) {
    return JSON.parse(inlineJson) as PushServiceAccount;
  }

  const base64 = String(env.FIREBASE_SERVICE_ACCOUNT_BASE64 ?? '').trim();
  if (base64.length > 0) {
    return JSON.parse(Buffer.from(base64, 'base64').toString('utf8')) as PushServiceAccount;
  }

  const filePath = String(env.FIREBASE_SERVICE_ACCOUNT_PATH ?? '').trim();
  if (filePath.length > 0) {
    return JSON.parse(fs.readFileSync(filePath, 'utf8')) as PushServiceAccount;
  }

  return null;
};

const createGoogleAuth = () => {
  const serviceAccount = parseInlineServiceAccount();

  return new GoogleAuth({
    credentials:
      serviceAccount?.client_email && serviceAccount?.private_key ? serviceAccount : undefined,
    scopes: [pushScope],
  });
};

const getGoogleAuthClient = async () => {
  if (authClientPromise == null) {
    authClientPromise = createGoogleAuth().getClient();
  }

  return authClientPromise;
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

const isPlatformPushEnabled = (platform: PushPlatform): boolean => {
  const env = validateEnv();
  if (!env.PUSH_NOTIFICATIONS_ENABLED) {
    return false;
  }

  return platform === 'ios'
    ? env.IOS_PUSH_NOTIFICATIONS_ENABLED
    : env.ANDROID_PUSH_NOTIFICATIONS_ENABLED;
};

const getPushProjectId = async (): Promise<string | null> => {
  if (projectIdPromise == null) {
    projectIdPromise = (async () => {
      const inlineProjectId = parseInlineServiceAccount()?.project_id?.trim();
      if (inlineProjectId) {
        return inlineProjectId;
      }

      const auth = createGoogleAuth();
      const resolved = await auth.getProjectId().catch(() => null);
      return typeof resolved === 'string' && resolved.trim().length > 0 ? resolved.trim() : null;
    })();
  }

  return projectIdPromise;
};

const getPushAccessToken = async (): Promise<string> => {
  const client = await getGoogleAuthClient();
  const tokenResponse = await client.getAccessToken();
  const accessToken =
    typeof tokenResponse === 'string' ? tokenResponse : tokenResponse?.token ?? null;

  if (typeof accessToken !== 'string' || accessToken.trim().length === 0) {
    throw new PushDeliveryError(
      'Unable to obtain a Firebase messaging access token.',
      'messaging/authentication-error',
    );
  }

  return accessToken;
};

const extractPushErrorCode = (payload: unknown, status: number): string => {
  if (payload && typeof payload === 'object') {
    const errorPayload =
      'error' in payload && payload.error && typeof payload.error === 'object'
        ? payload.error
        : payload;
    const details = Array.isArray((errorPayload as { details?: unknown }).details)
      ? ((errorPayload as { details?: Array<Record<string, unknown>> }).details ?? [])
      : [];

    const fcmDetail = details.find(
      (detail) =>
        typeof detail?.['@type'] === 'string' &&
        String(detail['@type']).includes('google.firebase.fcm.v1.FcmError'),
    );
    const fcmErrorCode = typeof fcmDetail?.errorCode === 'string' ? fcmDetail.errorCode : '';
    if (fcmErrorCode === 'UNREGISTERED') {
      return 'messaging/registration-token-not-registered';
    }
    if (fcmErrorCode === 'INVALID_ARGUMENT') {
      return 'messaging/invalid-registration-token';
    }

    const statusCode =
      typeof (errorPayload as { status?: unknown }).status === 'string'
        ? (errorPayload as { status?: string }).status
        : '';
    if (statusCode === 'UNAUTHENTICATED') {
      return 'messaging/authentication-error';
    }
  }

  if (status === 401 || status === 403) {
    return 'messaging/authentication-error';
  }
  if (status === 404) {
    return 'messaging/registration-token-not-registered';
  }
  if (status === 400) {
    return 'messaging/invalid-registration-token';
  }

  return 'messaging/unknown-error';
};

const buildFirebaseMessage = (payload: PushNotificationMessage) => {
  const showSensitivePreview = payload.showSensitivePreview === true;
  return {
    message: {
      token: payload.token,
      notification: {
        title: showSensitivePreview ? payload.title : 'TerraLeb',
        body: showSensitivePreview
          ? payload.message
          : 'You have a new TerraLeb notification. Open the app to view it securely.',
      },
      data: {
        notificationId: payload.notificationId,
        route: '/app/notifications',
        previewMode: showSensitivePreview ? 'detailed' : 'private',
        ...(showSensitivePreview ? { title: payload.title, message: payload.message } : {}),
      },
      android: {
        priority: 'high',
        notification: {
          channelId: 'fieldops_alerts',
          clickAction: 'FLUTTER_NOTIFICATION_CLICK',
        },
      },
      apns: {
        headers: {
          'apns-priority': '10',
        },
        payload: {
          aps: {
            sound: 'default',
          },
        },
      },
    },
  };
};

const sendPushNotification = async (
  platform: PushPlatform,
  payload: PushNotificationMessage,
): Promise<void> => {
  if (!isPushDeliveryConfigured()) {
    throw new PushDeliveryError(
      'Push delivery is not configured for this environment.',
      'messaging/configuration-error',
    );
  }

  const projectId = await getPushProjectId();
  if (!projectId || !firebaseProjectIdPattern.test(projectId)) {
    throw new PushDeliveryError(
      'Firebase project id could not be resolved for push delivery.',
      'messaging/configuration-error',
    );
  }

  const accessToken = await getPushAccessToken();
  if (!hasLoggedInitialization) {
    hasLoggedInitialization = true;
    logger.info('Firebase push messaging initialized', {
      usingServiceAccountFile:
        String(process.env.GOOGLE_APPLICATION_CREDENTIALS ?? '').trim().length > 0 &&
        parseInlineServiceAccount() == null,
    });
  }

  const endpoint = new URL('https://fcm.googleapis.com');
  endpoint.pathname = `/v1/projects/${encodeURIComponent(projectId)}/messages:send`;
  const response = await fetch(
    endpoint,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(buildFirebaseMessage(payload)),
    },
  );

  if (response.ok) {
    return;
  }

  let errorPayload: unknown = null;
  try {
    errorPayload = await response.json();
  } catch {
    errorPayload = null;
  }

  const errorMessage =
    typeof errorPayload === 'object' &&
    errorPayload &&
    'error' in errorPayload &&
    errorPayload.error &&
    typeof errorPayload.error === 'object' &&
    typeof (errorPayload.error as { message?: unknown }).message === 'string'
      ? String((errorPayload.error as { message?: string }).message)
      : `Push notification delivery failed with status ${response.status}.`;

  throw new PushDeliveryError(
    errorMessage,
    extractPushErrorCode(errorPayload, response.status),
    response.status,
  );
};

export {
  PushDeliveryError,
  sendPushNotification,
  isPlatformPushEnabled,
  isPushDeliveryConfigured,
  buildFirebaseMessage,
};
