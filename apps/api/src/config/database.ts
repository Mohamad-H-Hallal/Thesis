import { Pool, type PoolClient, type QueryResult, type QueryResultRow } from 'pg';
const logger = require('../utils/logger');

const pool = new Pool({
  host: process.env.DB_HOST ?? 'localhost',
  port: Number(process.env.DB_PORT ?? 5432),
  database: process.env.DB_NAME ?? 'gis_app',
  user: process.env.DB_USER ?? 'gis_user',
  password: process.env.DB_PASSWORD ?? 'change_me',
  max: Number.parseInt(process.env.DB_MAX_CONNECTIONS ?? '20', 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

// Test database connection
pool.on('connect', () => {
  logger.info('Database connected successfully');
});

pool.on('error', (err: Error) => {
  logger.error('Unexpected database error:', err);
});

// Query helper with logging
const query = async <T extends QueryResultRow = QueryResultRow>(
  text: string,
  params: unknown[] = []
): Promise<QueryResult<T>> => {
  const start = Date.now();
  try {
    const result = await pool.query<T>(text, params);
    const duration = Date.now() - start;
    logger.debug('Executed query', { text, duration, rows: result.rowCount });
    return result;
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : 'Unknown query error';
    logger.error('Query error:', { text, error: message });
    throw error;
  }
};

// Transaction helper
const transaction = async <T>(callback: (client: PoolClient) => Promise<T>): Promise<T> => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (error: unknown) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
};

// Test connection function
const testConnection = async (): Promise<boolean> => {
  try {
    const result = await query<{ now: string }>('SELECT NOW() as now');
    logger.info('Database connection test successful:', result.rows[0]);
    return true;
  } catch (error: unknown) {
    logger.error('Database connection test failed:', error);
    return false;
  }
};

const closePool = async (): Promise<void> => {
  try {
    await pool.end();
    logger.info('Database pool closed');
  } catch (error: unknown) {
    logger.error('Error closing database pool:', error);
  }
};

export { pool, query, transaction, testConnection, closePool };
