import nodemailer from 'nodemailer';
import type SMTPTransport from 'nodemailer/lib/smtp-transport';
import { AppError } from '../middleware/error';
import { validateEnv } from '../config/env';

let cachedTransporter: nodemailer.Transporter | null = null;

const buildTransport = (): nodemailer.Transporter => {
  const env = validateEnv();

  if (env.NODE_ENV === 'test') {
    return nodemailer.createTransport({
      jsonTransport: true,
    });
  }

  if (!env.SMTP_HOST.trim() || !env.SMTP_FROM_EMAIL.trim()) {
    throw new AppError(
      'Password reset email service is unavailable right now. Please contact support.',
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
  cachedTransporter = buildTransport();
  return cachedTransporter;
};

const formatFromHeader = (): string => {
  const env = validateEnv();
  if (!env.SMTP_FROM_NAME.trim()) {
    return env.SMTP_FROM_EMAIL;
  }
  return `"${env.SMTP_FROM_NAME.replaceAll('"', '\\"')}" <${env.SMTP_FROM_EMAIL}>`;
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
  const transporter = getTransporter();
  const appName = 'Lebanese GIS Collector';
  const trimmedName = recipientName.trim();
  const safeName = trimmedName.length == 0 ? 'User' : trimmedName;

  try {
    await transporter.sendMail({
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
  } catch (_error) {
    throw new AppError(
      'Password reset email service is unavailable right now. Please contact support.',
      503,
    );
  }
};

export { sendPasswordResetOtpEmail };
