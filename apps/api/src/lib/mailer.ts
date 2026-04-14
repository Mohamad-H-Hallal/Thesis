import nodemailer from 'nodemailer';
import type SMTPTransport from 'nodemailer/lib/smtp-transport';
import { AppError } from '../middleware/error';
import { validateEnv } from '../config/env';
const logger = require('../utils/logger');

let cachedTransporter: nodemailer.Transporter | null = null;
let loggedTransportDetails = false;

const deliveryUnavailableMessage =
  'We could not send the verification code right now. Please try again later.';
const realDeliveryRequiredMessage =
  'Email delivery is not configured for real password reset yet. Please contact support.';
const notificationDeliveryUnavailableMessage =
  'We could not send the notification email right now. Please try again later.';

const isMailpitHost = (value: string): boolean =>
  value.trim().toLowerCase() === 'mailpit';

const isLocalMailCaptureMode = (
  env: ReturnType<typeof validateEnv>,
): boolean =>
  env.MAIL_TRANSPORT === 'mailpit' ||
  (env.MAIL_TRANSPORT === 'smtp' && isMailpitHost(env.SMTP_HOST));

const localCaptureHostCandidates = (
  env: ReturnType<typeof validateEnv>,
): string[] => {
  const configuredHost = env.SMTP_HOST.trim();
  return Array.from(
    new Set(
      [configuredHost, 'mailpit', 'localhost', '127.0.0.1'].filter(
        (value): value is string => value.trim().length > 0,
      ),
    ),
  );
};

const localCapturePortCandidates = (
  env: ReturnType<typeof validateEnv>,
): number[] =>
  Array.from(
    new Set(
      [env.SMTP_PORT, 1025].filter(
        (value): value is number => Number.isFinite(value) && value > 0,
      ),
    ),
  );

const getMailEnv = () => {
  try {
    return validateEnv();
  } catch (error) {
    logger.error('Password reset mail configuration validation failed', {
      error:
        error instanceof Error
          ? error.message
          : typeof error === 'string'
            ? error
            : 'unknown',
    });
    throw new AppError(deliveryUnavailableMessage, 503);
  }
};

const normalizeEnvelopeAddress = (value: unknown): string | null => {
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    return normalized.length === 0 ? null : normalized;
  }

  if (
    value != null &&
    typeof value === 'object' &&
    'address' in value &&
    typeof (value as { address?: unknown }).address === 'string'
  ) {
    const normalized = (value as { address: string }).address
      .trim()
      .toLowerCase();
    return normalized.length === 0 ? null : normalized;
  }

  return null;
};

const buildTransport = (
  hostOverride?: string,
  portOverride?: number,
): nodemailer.Transporter => {
  const env = getMailEnv();

  if (env.NODE_ENV === 'test') {
    return nodemailer.createTransport({
      jsonTransport: true,
    });
  }

  if (isLocalMailCaptureMode(env)) {
    if (env.PASSWORD_RESET_REQUIRE_REAL_DELIVERY) {
      logger.error(
        'Notification mail blocked because real delivery is required but local mail capture is active',
        {
          mailTransport: env.MAIL_TRANSPORT,
          smtpHost: env.SMTP_HOST.trim().length > 0 ? env.SMTP_HOST : 'mailpit',
          smtpPort: env.SMTP_PORT,
          realDeliveryRequired: env.PASSWORD_RESET_REQUIRE_REAL_DELIVERY,
          effectiveDeliveryMode: 'local_capture',
        },
      );
      throw new AppError(realDeliveryRequiredMessage, 503);
    }

    return nodemailer.createTransport({
      host:
        hostOverride ??
        (env.SMTP_HOST.trim().length > 0 ? env.SMTP_HOST : 'mailpit'),
      port: portOverride ?? env.SMTP_PORT,
      secure: false,
    });
  }

  if (!env.SMTP_HOST.trim() || !env.SMTP_FROM_EMAIL.trim()) {
    logger.error('Notification SMTP configuration is incomplete', {
      mailTransport: env.MAIL_TRANSPORT,
      smtpHostConfigured: env.SMTP_HOST.trim().length > 0,
      smtpFromConfigured: env.SMTP_FROM_EMAIL.trim().length > 0,
    });
    throw new AppError(
      deliveryUnavailableMessage,
      503,
    );
  }

  const options: SMTPTransport.Options = {
    host: env.SMTP_HOST,
    port: env.SMTP_PORT,
    secure: env.SMTP_SECURE,
  };

  if (env.SMTP_USER.trim().length > 0 || env.SMTP_PASS.trim().length > 0) {
    options.auth = {
      user: env.SMTP_USER,
      pass: env.SMTP_PASS,
    };
  }

  return nodemailer.createTransport(options);
};

const getTransporter = (): nodemailer.Transporter => {
  if (cachedTransporter != null) {
    return cachedTransporter;
  }
  const env = getMailEnv();
  cachedTransporter = buildTransport();
  if (!loggedTransportDetails) {
    const effectiveDeliveryMode = isLocalMailCaptureMode(env)
      ? 'local_capture'
      : 'transactional_smtp';
    logger.info('Notification mail transport initialized', {
      mailTransport: env.MAIL_TRANSPORT,
      smtpHost:
        env.MAIL_TRANSPORT === 'mailpit'
          ? env.SMTP_HOST.trim().length > 0
              ? env.SMTP_HOST
              : 'mailpit'
          : env.SMTP_HOST,
      smtpPort: env.SMTP_PORT,
      smtpSecure: env.SMTP_SECURE,
      realDeliveryRequired: env.PASSWORD_RESET_REQUIRE_REAL_DELIVERY,
      effectiveDeliveryMode,
      fromEmail:
        env.MAIL_TRANSPORT === 'mailpit' && env.SMTP_FROM_EMAIL.trim().length === 0
            ? 'no-reply@gis.local'
            : env.SMTP_FROM_EMAIL,
    });
    if (isLocalMailCaptureMode(env)) {
      logger.warn('Notification email is using local mail capture; real inbox delivery is disabled for this runtime', {
        mailTransport: env.MAIL_TRANSPORT,
        smtpHost:
          env.SMTP_HOST.trim().length > 0 ? env.SMTP_HOST : 'mailpit',
        smtpPort: env.SMTP_PORT,
        realDeliveryRequired: env.PASSWORD_RESET_REQUIRE_REAL_DELIVERY,
        effectiveDeliveryMode,
      });
    }
    loggedTransportDetails = true;
  }
  return cachedTransporter;
};

const formatFromHeader = (): string => {
  const env = getMailEnv();
  const fromEmail =
    env.MAIL_TRANSPORT === 'mailpit' && env.SMTP_FROM_EMAIL.trim().length === 0
        ? 'no-reply@gis.local'
        : env.SMTP_FROM_EMAIL;
  if (!env.SMTP_FROM_NAME.trim()) {
    return fromEmail;
  }
  return `"${env.SMTP_FROM_NAME.replaceAll('"', '\\"')}" <${fromEmail}>`;
};

const sendMail = async (
  env: ReturnType<typeof validateEnv>,
  options: nodemailer.SendMailOptions,
) => {
  if (!isLocalMailCaptureMode(env)) {
    return getTransporter().sendMail(options);
  }

  let lastError: unknown;
  for (const host of localCaptureHostCandidates(env)) {
    for (const port of localCapturePortCandidates(env)) {
      try {
        const transporter = buildTransport(host, port);
        const info = await transporter.sendMail(options);
        if (host !== env.SMTP_HOST || port !== env.SMTP_PORT) {
          logger.warn('Notification mail capture fallback used', {
            preferredHost: env.SMTP_HOST,
            preferredPort: env.SMTP_PORT,
            fallbackHost: host,
            fallbackPort: port,
          });
        }
        return info;
      } catch (error) {
        lastError = error;
      }
    }
  }

  throw lastError ?? new Error('Unable to deliver local-capture email');
};

const sendPasswordResetOtpEmail = async ({
  toEmail,
  recipientName,
  otp,
  expiresInMinutes,
}: {
  toEmail: string;
  recipientName: string;
  otp: string;
  expiresInMinutes: number;
}): Promise<void> => {
  const env = getMailEnv();
  const appName = 'Lebanese GIS Collector';
  const trimmedName = recipientName.trim();
  const safeName = trimmedName.length === 0 ? 'User' : trimmedName;
  const normalizedRecipient = toEmail.trim().toLowerCase();

  try {
    const info = await sendMail(env, {
      from: formatFromHeader(),
      to: toEmail,
      subject: `${appName} password reset code`,
      text: [
        `Hello ${safeName},`,
        '',
        `Use this one-time password to reset your ${appName} password: ${otp}`,
        '',
        `This code expires in ${expiresInMinutes} minutes.`,
        '',
        'If you did not request a password reset, you can ignore this email.',
      ].join('\n'),
      html: `
        <p>Hello ${safeName},</p>
        <p>Use this one-time password to reset your <strong>${appName}</strong> password:</p>
        <p style="font-size: 24px; font-weight: 700; letter-spacing: 4px;">${otp}</p>
        <p>This code expires in <strong>${expiresInMinutes} minutes</strong>.</p>
        <p>If you did not request a password reset, you can ignore this email.</p>
      `,
    });

    if (env.NODE_ENV !== 'test') {
      const acceptedRecipients = (info.accepted ?? [])
        .map(normalizeEnvelopeAddress)
        .filter((value): value is string => value != null);
      const rejectedRecipients = (info.rejected ?? [])
        .map(normalizeEnvelopeAddress)
        .filter((value): value is string => value != null);

      if (
        !acceptedRecipients.includes(normalizedRecipient) ||
        rejectedRecipients.includes(normalizedRecipient)
      ) {
        logger.error('Password reset email rejected by SMTP transport', {
          mailTransport: env.MAIL_TRANSPORT,
          toEmail,
          acceptedRecipients,
          rejectedRecipients,
        });
        throw new AppError(
          deliveryUnavailableMessage,
          503,
        );
      }

      logger.info('Password reset email accepted by transport', {
        mailTransport: env.MAIL_TRANSPORT,
        toEmail,
        acceptedRecipients,
        rejectedRecipients,
        messageId: info.messageId ?? null,
        response:
          typeof info.response === 'string' && info.response.trim().length > 0
            ? info.response
            : null,
      });
    }
  } catch (error) {
    logger.error('Password reset email delivery failed', {
      mailTransport: env.MAIL_TRANSPORT,
      toEmail,
      smtpHost:
        env.MAIL_TRANSPORT === 'mailpit'
          ? env.SMTP_HOST.trim().length > 0
              ? env.SMTP_HOST
              : 'mailpit'
          : env.SMTP_HOST,
      smtpPort: env.SMTP_PORT,
      error:
        error instanceof Error
          ? error.message
          : typeof error === 'string'
            ? error
            : 'unknown',
    });
    throw new AppError(
      deliveryUnavailableMessage,
      503,
    );
  }
};

const sendNotificationEmail = async ({
  toEmail,
  recipientName,
  title,
  message,
}: {
  toEmail: string;
  recipientName: string;
  title: string;
  message: string;
}): Promise<void> => {
  const env = getMailEnv();
  const appName = 'Lebanese GIS Collector';
  const trimmedName = recipientName.trim();
  const safeName = trimmedName.length === 0 ? 'User' : trimmedName;
  const normalizedRecipient = toEmail.trim().toLowerCase();

  try {
    const info = await sendMail(env, {
      from: formatFromHeader(),
      to: toEmail,
      subject: `${appName}: ${title}`,
      text: [
        `Hello ${safeName},`,
        '',
        title,
        '',
        message,
        '',
        `This notification was sent by ${appName}.`,
      ].join('\n'),
      html: `
        <p>Hello ${safeName},</p>
        <p><strong>${title}</strong></p>
        <p>${message}</p>
        <p>This notification was sent by <strong>${appName}</strong>.</p>
      `,
    });

    if (env.NODE_ENV !== 'test') {
      const acceptedRecipients = (info.accepted ?? [])
        .map(normalizeEnvelopeAddress)
        .filter((value): value is string => value != null);
      const rejectedRecipients = (info.rejected ?? [])
        .map(normalizeEnvelopeAddress)
        .filter((value): value is string => value != null);

      if (
        !acceptedRecipients.includes(normalizedRecipient) ||
        rejectedRecipients.includes(normalizedRecipient)
      ) {
        logger.error('Notification email rejected by SMTP transport', {
          mailTransport: env.MAIL_TRANSPORT,
          toEmail,
          acceptedRecipients,
          rejectedRecipients,
        });
        throw new AppError(notificationDeliveryUnavailableMessage, 503);
      }
    }
  } catch (error) {
    logger.error('Notification email delivery failed', {
      mailTransport: env.MAIL_TRANSPORT,
      toEmail,
      smtpHost:
        env.MAIL_TRANSPORT === 'mailpit'
          ? env.SMTP_HOST.trim().length > 0
              ? env.SMTP_HOST
              : 'mailpit'
          : env.SMTP_HOST,
      smtpPort: env.SMTP_PORT,
      error:
        error instanceof Error
          ? error.message
          : typeof error === 'string'
            ? error
            : 'unknown',
    });
    throw new AppError(notificationDeliveryUnavailableMessage, 503);
  }
};

export { sendNotificationEmail, sendPasswordResetOtpEmail };
