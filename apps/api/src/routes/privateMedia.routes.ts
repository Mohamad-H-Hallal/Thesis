import express from 'express';
import {
  getAiValidationMedia,
  getLegacyAiValidationMedia,
} from '../controllers/privateMedia.controller';
import { authenticate } from '../middleware/auth';
import { asyncHandler } from '../middleware/error';

const router = express.Router();

router.get('/ai-validation/:storageName', authenticate, asyncHandler(getAiValidationMedia));
router.get('/photos/:storageName', authenticate, asyncHandler(getLegacyAiValidationMedia));

export { router as privateMediaRouter };
