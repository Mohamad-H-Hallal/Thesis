import fs from 'node:fs';
import path from 'node:path';
import dotenv from 'dotenv';

export interface LoadedEnvFile {
  path: string;
  keys: string[];
}

const apiRoot = path.resolve(__dirname, '..', '..');
const repoRoot = path.resolve(apiRoot, '..', '..');

const applyEnvFile = (filePath: string): LoadedEnvFile | null => {
  if (!fs.existsSync(filePath)) {
    return null;
  }

  const parsed = dotenv.parse(fs.readFileSync(filePath));
  const appliedKeys: string[] = [];
  for (const [key, value] of Object.entries(parsed)) {
    if (process.env[key] === undefined) {
      process.env[key] = value;
      appliedKeys.push(key);
    }
  }

  return {
    path: filePath,
    keys: appliedKeys,
  };
};

const loadBackendEnvFiles = (): LoadedEnvFile[] => {
  const candidates = [
    path.join(apiRoot, '.env'),
    path.join(repoRoot, '.env'),
  ];

  return candidates
    .map(applyEnvFile)
    .filter((item): item is LoadedEnvFile => item !== null);
};

export { loadBackendEnvFiles };
