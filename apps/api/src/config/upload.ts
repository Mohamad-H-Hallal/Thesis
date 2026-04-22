import multer, { type FileFilterCallback } from 'multer';
import path from 'node:path';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import type { Request } from 'express';

// Ensure upload directories exist
const uploadDir = process.env.UPLOAD_DIR ?? './uploads';
const photosDir = path.join(uploadDir, 'photos');
const thumbnailsDir = path.join(uploadDir, 'thumbnails');
const categoryIconsDir = path.join(uploadDir, 'category-icons');

[uploadDir, photosDir, thumbnailsDir, categoryIconsDir].forEach((dir) => {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
});

// Storage configuration
const storage = multer.diskStorage({
  destination: (_req, _file, cb) => {
    cb(null, photosDir);
  },
  filename: (_req, file, cb) => {
    const uniqueName = `${randomUUID()}${path.extname(file.originalname)}`;
    cb(null, uniqueName);
  },
});

// File filter
const fileFilter = (
  _req: Request,
  file: { originalname: string; mimetype: string },
  cb: FileFilterCallback
): void => {
  // Accept only images
  const allowedTypes = /jpeg|jpg|png|heic|heif/;
  const extname = allowedTypes.test(path.extname(file.originalname).toLowerCase());
  const mimetype = allowedTypes.test(file.mimetype);

  if (mimetype && extname) {
    cb(null, true);
    return;
  }
  cb(new Error('Only image files are allowed (jpeg, jpg, png, heic, heif)'));
};

// Multer configuration
const upload = multer({
  storage: storage,
  limits: {
    fileSize: Number.parseInt(process.env.PHOTO_MAX_SIZE ?? '5242880', 10), // 5MB default
  },
  fileFilter: fileFilter,
});

// Single photo upload
const uploadSingle = upload.single('photo');

// Multiple photos upload (max 10)
const uploadMultiple = upload.array('photos', 10);

const categoryIconStorage = multer.diskStorage({
  destination: (_req, _file, cb) => {
    cb(null, categoryIconsDir);
  },
  filename: (_req, file, cb) => {
    const uniqueName = `${randomUUID()}${path.extname(file.originalname)}`;
    cb(null, uniqueName);
  },
});

const uploadCategoryIcon = multer({
  storage: categoryIconStorage,
  limits: {
    fileSize: Number.parseInt(process.env.CATEGORY_ICON_MAX_SIZE ?? '3145728', 10),
  },
  fileFilter: fileFilter,
}).single('icon');

export {
  uploadSingle,
  uploadMultiple,
  uploadCategoryIcon,
  photosDir,
  thumbnailsDir,
  categoryIconsDir,
};
