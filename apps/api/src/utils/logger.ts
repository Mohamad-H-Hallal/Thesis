const winston = require('winston');
const path = require('path');
const fs = require('fs');

const isProduction = process.env.NODE_ENV === 'production';
const prettyConsole = !isProduction && process.env.LOG_PRETTY !== 'false';
const logToFile = process.env.LOG_TO_FILE === 'true';

const jsonFormat = winston.format.combine(
  winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
  winston.format.errors({ stack: true }),
  winston.format.splat(),
  winston.format.json()
);

const prettyFormat = winston.format.combine(
  winston.format.colorize(),
  winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
  winston.format.printf(({ timestamp, level, message, ...meta }) => {
    let msg = `${timestamp} [${level}]: ${message}`;
    if (Object.keys(meta).length > 0) {
      msg += ` ${JSON.stringify(meta)}`;
    }
    return msg;
  })
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
    })
  );
}

const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  transports,
});

module.exports = logger;

export {};
