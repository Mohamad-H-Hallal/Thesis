const express = require('express');
const router = express.Router();
const authController = require('../controllers/auth.controller');
const { authenticate, authenticateVerificationSession } = require('../middleware/auth');
const { userValidation, validate } = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');
import { auditAction } from '../middleware/audit';
import {
  contactVerificationRateLimit,
  passwordResetRateLimit,
} from '../middleware/workloadRateLimit';

// Public routes
router.post(
  '/register',
  auditAction({
    actionType: 'create',
    entityType: 'user',
    resolveEntityId: (_req, _res, body) => body?.data?.user?.id ?? null,
  }),
  userValidation.register,
  validate,
  asyncHandler(authController.register),
);

router.post(
  '/login',
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (_req, _res, body) => body?.data?.user?.id ?? null,
    resolveNewValues: (req) => ({ email: req.body?.email, event: 'login' }),
  }),
  userValidation.login,
  validate,
  asyncHandler(authController.login),
);

router.post(
  '/reactivate-login',
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (_req, _res, body) => body?.data?.user?.id ?? null,
    resolveNewValues: (req) => ({ email: req.body?.email, event: 'reactivate_login' }),
  }),
  userValidation.login,
  validate,
  asyncHandler(authController.reactivateContributorLogin),
);

router.post(
  '/forgot-password',
  passwordResetRateLimit,
  userValidation.forgotPassword,
  validate,
  asyncHandler(authController.requestPasswordReset),
);

router.post(
  '/verify-reset-otp',
  passwordResetRateLimit,
  userValidation.verifyResetOtp,
  validate,
  asyncHandler(authController.verifyPasswordResetOtp),
);

router.post(
  '/reset-password',
  passwordResetRateLimit,
  userValidation.resetPassword,
  validate,
  asyncHandler(authController.resetPassword),
);

router.post(
  '/refresh-token',
  userValidation.refreshToken,
  validate,
  asyncHandler(authController.refreshToken),
);

router.get(
  '/verification/status',
  contactVerificationRateLimit,
  authenticateVerificationSession,
  asyncHandler(authController.getVerificationStatus),
);
router.post(
  '/verification/email/send',
  contactVerificationRateLimit,
  authenticateVerificationSession,
  userValidation.verificationSendEmail,
  validate,
  asyncHandler(authController.sendSignupEmailVerification),
);
router.post(
  '/verification/email/confirm',
  contactVerificationRateLimit,
  authenticateVerificationSession,
  userValidation.verificationCode,
  validate,
  asyncHandler(authController.confirmSignupEmailVerification),
);
router.delete(
  '/verification/pending-signup',
  contactVerificationRateLimit,
  authenticateVerificationSession,
  asyncHandler(authController.cancelSignupVerification),
);
router.post(
  '/verification/phone/validate',
  contactVerificationRateLimit,
  authenticateVerificationSession,
  userValidation.verificationSendPhone,
  validate,
  asyncHandler(authController.validateSignupPhoneFormat),
);
router.post(
  '/verification/phone/send',
  contactVerificationRateLimit,
  authenticateVerificationSession,
  userValidation.verificationSendPhone,
  validate,
  asyncHandler(authController.sendSignupPhoneVerification),
);
router.post(
  '/verification/phone/confirm',
  contactVerificationRateLimit,
  authenticateVerificationSession,
  userValidation.verificationCode,
  validate,
  asyncHandler(authController.confirmSignupPhoneVerification),
);

// Protected routes
router.use(authenticate);

router.get('/me', asyncHandler(authController.getMe));

router.put(
  '/me',
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.user?.id ?? null,
  }),
  userValidation.update,
  validate,
  asyncHandler(authController.updateMe),
);

router.post(
  '/me/phone-change/request',
  contactVerificationRateLimit,
  userValidation.requestPhoneChange,
  validate,
  asyncHandler(authController.requestMyPhoneChange),
);
router.post(
  '/me/phone-change/confirm',
  contactVerificationRateLimit,
  userValidation.verificationCode,
  validate,
  asyncHandler(authController.confirmMyPhoneChange),
);

router.post(
  '/change-password',
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.user?.id ?? null,
    resolveNewValues: () => ({ event: 'change_password' }),
  }),
  userValidation.changePassword,
  validate,
  asyncHandler(authController.changePassword),
);

router.post(
  '/logout',
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.user?.id ?? null,
    resolveNewValues: () => ({ event: 'logout' }),
  }),
  asyncHandler(authController.logout),
);

router.post(
  '/self-deactivate',
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.user?.id ?? null,
    resolveNewValues: () => ({
      is_active: false,
      account_state: 'inactive',
      event: 'self_deactivate',
    }),
  }),
  asyncHandler(authController.selfDeactivate),
);

module.exports = router;

export {};
