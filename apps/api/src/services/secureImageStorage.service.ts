import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

interface ReleasedImage {
  filename: string;
  filePath: string;
  size: number;
}

const releaseNormalizedJpeg = async (
  encodedImage: Buffer,
  destinationDirectory: string,
): Promise<ReleasedImage> => {
  const directory = path.resolve(destinationDirectory);
  const identifier = randomUUID();
  const temporaryPath = path.join(directory, `.${identifier}.tmp`);
  const filename = `${identifier}.jpg`;
  const finalPath = path.join(directory, filename);

  await fs.writeFile(temporaryPath, encodedImage, { flag: 'wx', mode: 0o600 });
  try {
    await fs.rename(temporaryPath, finalPath);
  } catch (error) {
    await fs.rm(temporaryPath, { force: true });
    throw error;
  }

  return {
    filename,
    filePath: finalPath,
    size: encodedImage.length,
  };
};

const removeReleasedImages = async (filePaths: string[]): Promise<void> => {
  await Promise.all(filePaths.map((filePath) => fs.rm(filePath, { force: true })));
};

export { releaseNormalizedJpeg, removeReleasedImages, type ReleasedImage };
