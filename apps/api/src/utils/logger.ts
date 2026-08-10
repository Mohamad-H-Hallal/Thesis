const winston = require('winston');
const path = require('path');
const fs = require('fs');

const isProduction = process.env.NODE_ENV === 'production';
const prettyConsole = !isProduction && process.env.LOG_PRETTY !== 'false';
const logToFile = process.env.LOG_TO_FILE === 'true';
const REDACTED = '[REDACTED]';

const sensitiveKeyPattern =
  /(?:authorization|cookie|password|passphrase|token|otp|verification[_-]?code|secret|private[_-]?key|credential|smtp[_-]?pass|database[_-]?url|redis[_-]?url|service[_-]?account|body|payload|geometry|coordinates|geojson|latitude|longitude|bbox|attributes|feature[_-]?collection|storage[_-]?path|file[_-]?(?:buffer|path|name)|raw[_-]?content|email|phone)/i;

const sanitizeLogString = (value: string): string =>
  value
    .replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----/gi, REDACTED)
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, `Bearer ${REDACTED}`)
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, REDACTED)
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/)([^/\s:@]+):([^@\s/]+)@/gi, `$1${REDACTED}:${REDACTED}@`)
    .replace(
      /\b(password|passphrase|token|secret|private[_-]?key|smtp[_-]?pass)\s*[:=]\s*([^\s,;]+)/gi,
      `$1=${REDACTED}`,
    );

const redactSensitive = (
  value: unknown,
  key = '',
  seen: WeakSet<object> = new WeakSet<object>(),
): unknown => {
  if (sensitiveKeyPattern.test(key)) {
    return REDACTED;
  }
  if (typeof value === 'string') {
    return sanitizeLogString(value);
  }
  if (
    value === null ||
    value === undefined ||
    typeof value === 'number' ||
    typeof value === 'boolean' ||
    typeof value === 'bigint'
  ) {
    return value;
  }
  if (value instanceof Error) {
    return {
      name: value.name,
      message: sanitizeLogString(value.message),
      stack: value.stack ? sanitizeLogString(value.stack) : undefined,
    };
  }
  if (Buffer.isBuffer(value)) {
    return `[BUFFER ${value.length} bytes]`;
  }
  if (Array.isArray(value)) {
    return value.map((item) => redactSensitive(item, '', seen));
  }
  if (typeof value === 'object') {
    if (seen.has(value)) {
      return '[CIRCULAR]';
    }
    seen.add(value);
    const output: Record<string, unknown> = {};
    for (const [childKey, childValue] of Object.entries(value)) {
      output[childKey] = redactSensitive(childValue, childKey, seen);
    }
    return output;
  }
  return String(value);
};

const redactionFormat = winston.format((info) => {
  for (const key of Object.keys(info)) {
    info[key] = redactSensitive(info[key], key);
  }
  return info;
})();

const jsonFormat = winston.format.combine(
  winston.format.timestamp(),
  winston.format.errors({ stack: true }),
  winston.format.splat(),
  redactionFormat,
  winston.format.json(),
);

const prettyFormat = winston.format.combine(
  winston.format.colorize(),
  winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
  redactionFormat,
  winston.format.printf(({ timestamp, level, message, ...meta }) => {
    let msg = `${timestamp} [${level}]: ${message}`;
    if (Object.keys(meta).length > 0) {
      msg += ` ${JSON.stringify(meta)}`;
    }
    return msg;
  }),
);

const transports = [
  new winston.transports.Console({
    format: prettyConsole ? prettyFormat : jsonFormat,
  }),
];

if (logToFile) {
  const logsDir = path.join(process.cwd(), 'logs');
  if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir, { recursive: true });
  }

  transports.push(
    new winston.transports.File({
      filename: path.join(logsDir, 'error.log'),
      level: 'error',
      maxsize: 5242880,
      maxFiles: 5,
      format: jsonFormat,
    }),
    new winston.transports.File({
      filename: path.join(logsDir, 'combined.log'),
      maxsize: 5242880,
      maxFiles: 5,
      format: jsonFormat,
    }),
  );
}

const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  defaultMeta: {
    service: process.env.SERVICE_NAME || 'gis-api',
    environment: process.env.NODE_ENV || 'development',
  },
  transports,
});

module.exports = logger;
module.exports.redactSensitive = redactSensitive;
module.exports.sanitizeLogString = sanitizeLogString;

export { redactSensitive, sanitizeLogString };
