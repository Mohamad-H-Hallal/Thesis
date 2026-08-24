import express from 'express';
import {
  acceptCurrentDocuments,
  getAcceptanceStatus,
  getDocument,
  getPublicAccountDeletionRequest,
  listDocuments,
  submitPublicAccountDeletionRequest,
} from '../controllers/legal.controller';
import { authenticate } from '../middleware/auth';
import { asyncHandler } from '../middleware/error';
import { publicPrivacyRequestRateLimit } from '../middleware/workloadRateLimit';

const publicLegalRouter = express.Router();
const legalApiRouter = express.Router();

publicLegalRouter.get('/', asyncHandler(listDocuments));
publicLegalRouter.get(
  '/account-deletion/request',
  publicPrivacyRequestRateLimit,
  asyncHandler(getPublicAccountDeletionRequest),
);
publicLegalRouter.post(
  '/account-deletion/request',
  publicPrivacyRequestRateLimit,
  asyncHandler(submitPublicAccountDeletionRequest),
);
publicLegalRouter.get('/:slug', asyncHandler(getDocument));

legalApiRouter.get('/documents', asyncHandler(listDocuments));
legalApiRouter.get('/documents/:slug', asyncHandler(getDocument));
legalApiRouter.get('/documents/:slug/versions/:version', asyncHandler(getDocument));
legalApiRouter.get('/acceptance/status', authenticate, asyncHandler(getAcceptanceStatus));
legalApiRouter.post('/acceptance', authenticate, asyncHandler(acceptCurrentDocuments));

export { legalApiRouter, publicLegalRouter };
