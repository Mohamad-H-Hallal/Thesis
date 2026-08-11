import { randomUUID } from 'node:crypto';
import jwt, { type JwtPayload, type SignOptions, type VerifyOptions } from 'jsonwebtoken';
import type { user_role } from '../types/roles';

const tokenAlgorithm = 'HS256' as const;

interface AuthTokenPayload extends JwtPayload {
  exp?: number;
  sub?: string;
  userId: string;
  authVersion: number;
  sessionId: string;
  tokenType: 'access' | 'refresh';
  role?: user_role;
}

const tokenIssuer = (): string => process.env.JWT_ISSUER?.trim() || 'terraleb-api';
const tokenAudience = (): string => process.env.JWT_AUDIENCE?.trim() || 'terraleb-mobile';

const parsePreviousSecrets = (raw?: string): string[] =>
  (raw ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);

const accessSecrets = (): string[] => [
  process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET || '',
  ...parsePreviousSecrets(process.env.JWT_SECRET_PREVIOUS),
].filter(Boolean);

const refreshSecrets = (): string[] => [
  process.env.JWT_REFRESH_SECRET_CURRENT || process.env.JWT_REFRESH_SECRET || '',
  ...parsePreviousSecrets(process.env.JWT_REFRESH_SECRET_PREVIOUS),
].filter(Boolean);

const verifyOptions = (): VerifyOptions => ({
  algorithms: [tokenAlgorithm],
  issuer: tokenIssuer(),
  audience: tokenAudience(),
});

const assertTokenPayload = (
  decoded: string | JwtPayload,
  expectedType: AuthTokenPayload['tokenType'],
): AuthTokenPayload => {
  if (
    typeof decoded === 'string' ||
    decoded.tokenType !== expectedType ||
    typeof decoded.userId !== 'string' ||
    decoded.userId.length === 0 ||
    decoded.sub !== decoded.userId ||
    typeof decoded.sessionId !== 'string' ||
    decoded.sessionId.length === 0 ||
    !Number.isSafeInteger(decoded.authVersion) ||
    decoded.authVersion < 0
  ) {
    throw new jwt.JsonWebTokenError(`Invalid ${expectedType} token claims`);
  }
  if (
    expectedType === 'access' &&
    !['admin', 'contributor', 'viewer'].includes(String(decoded.role))
  ) {
    throw new jwt.JsonWebTokenError('Invalid access token role claim');
  }
  return decoded as AuthTokenPayload;
};

const verifyWithSecrets = (
  token: string,
  secrets: string[],
  expectedType: AuthTokenPayload['tokenType'],
): AuthTokenPayload => {
  let lastError: unknown = null;
  for (const secret of secrets) {
    try {
      return assertTokenPayload(jwt.verify(token, secret, verifyOptions()), expectedType);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new jwt.JsonWebTokenError('Token verification failed');
};

const generateToken = (
  userId: string,
  role: user_role,
  authVersion = 0,
  sessionId: string = randomUUID(),
): string => {
  const signingSecret = process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET;
  const expiresIn = (process.env.JWT_EXPIRE || '15m') as SignOptions['expiresIn'];
  return jwt.sign(
    { userId, role, authVersion, sessionId, tokenType: 'access' },
    signingSecret as string,
    {
      algorithm: tokenAlgorithm,
      expiresIn,
      issuer: tokenIssuer(),
      audience: tokenAudience(),
      subject: userId,
      jwtid: randomUUID(),
    },
  );
};

const generateRefreshToken = (
  userId: string,
  authVersion = 0,
  sessionId: string = randomUUID(),
): string => {
  const signingSecret = process.env.JWT_REFRESH_SECRET_CURRENT || process.env.JWT_REFRESH_SECRET;
  const expiresIn = (process.env.JWT_REFRESH_EXPIRE || '30d') as SignOptions['expiresIn'];
  return jwt.sign(
    { userId, authVersion, sessionId, tokenType: 'refresh' },
    signingSecret as string,
    {
      algorithm: tokenAlgorithm,
      expiresIn,
      issuer: tokenIssuer(),
      audience: tokenAudience(),
      subject: userId,
      jwtid: randomUUID(),
    },
  );
};

const verifyAccessToken = (token: string): AuthTokenPayload =>
  verifyWithSecrets(token, accessSecrets(), 'access');

const verifyRefreshToken = (token: string): AuthTokenPayload =>
  verifyWithSecrets(token, refreshSecrets(), 'refresh');

const tokenExpiresAt = (token: string): Date => {
  const decoded = jwt.decode(token);
  if (!decoded || typeof decoded === 'string' || typeof decoded.exp !== 'number') {
    throw new Error('Signed token is missing an expiration claim');
  }
  return new Date(decoded.exp * 1000);
};

export {
  generateRefreshToken,
  generateToken,
  tokenAudience,
  tokenAlgorithm,
  tokenExpiresAt,
  tokenIssuer,
  verifyAccessToken,
  verifyRefreshToken,
};
export type { AuthTokenPayload };
