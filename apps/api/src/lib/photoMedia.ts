import type { Request } from 'express';

const apiRootForRequest = (req: Request): string => {
  const baseUrl = String(req.baseUrl ?? '').replace(/\/+$/, '');
  const separator = baseUrl.lastIndexOf('/');
  if (separator > 0) {
    return baseUrl.slice(0, separator);
  }
  return String(process.env.API_VERSION_PREFIX ?? '/api/v1').replace(/\/+$/, '');
};

const photoMediaPath = (
  req: Request,
  photoId: string,
  { thumbnail = false }: { thumbnail?: boolean } = {},
): string =>
  `${apiRootForRequest(req)}/photos/${encodeURIComponent(photoId)}${
    thumbnail ? '?thumbnail=true' : ''
  }`;

const serializePhotoForClient = (req: Request, photo: Record<string, unknown>) => {
  const photoId = typeof photo.id === 'string' ? photo.id : '';
  if (!photoId) {
    return photo;
  }
  return {
    ...photo,
    file_path: photoMediaPath(req, photoId),
    thumbnail_path:
      photo.thumbnail_path === null || photo.thumbnail_path === undefined
        ? null
        : photoMediaPath(req, photoId, { thumbnail: true }),
  };
};

export { photoMediaPath, serializePhotoForClient };
