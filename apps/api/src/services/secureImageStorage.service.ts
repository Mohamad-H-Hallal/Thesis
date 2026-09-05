import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { storageAdapter } from './storageAdapter.service';

interface ReleasedImage {
  filename: string;
  filePath: string;
  storageReference: string;
  size: number;
}

const releaseNormalizedJpeg = async (
  encodedImage: Buffer,
  destinationDirectory: string,
): Promise<ReleasedImage> => {
  const identifier = randomUUID();
  const filename = `${identifier}.jpg`;
  const resolved = storageAdapter.resolve(path.join(destinationDirectory, filename), ['uploads']);
  if (
    !resolved ||
    !['.private/ai-validation/', 'category-icons/'].some((prefix) =>
      resolved.key.startsWith(prefix),
    )
  ) {
    throw new Error('Refusing to release an image outside managed image storage.');
  }
  const stored = await storageAdapter.writeAtomic(resolved.reference, encodedImage);

  return {
    filename,
    // Keep cleanup portable across local and object-storage drivers. Callers
    // historically named this value filePath, so retain the field while
    // returning the canonical storage reference.
    filePath: stored.reference,
    storageReference: stored.reference,
    size: encodedImage.length,
  };
};

const removeReleasedImages = async (filePaths: string[]): Promise<void> => {
  await Promise.all(filePaths.map((filePath) => storageAdapter.remove(filePath)));
};

export { releaseNormalizedJpeg, removeReleasedImages, type ReleasedImage };
