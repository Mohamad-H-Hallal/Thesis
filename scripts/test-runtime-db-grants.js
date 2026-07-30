#!/usr/bin/env node

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const fullSchemaValidation = process.argv.includes('--full-schema');
const image = process.env.RELEASE_DATABASE_IMAGE || 'gis-phase6-postgis-audit:local';
const suffix = `${process.pid}-${Date.now()}`;
const containerName = `gis-phase5-db-grants-${suffix}`;
const networkName = `gis-phase5-db-grants-${suffix}`;
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'gis-phase5-db-grants-'));
const adminSecretPath = path.join(temporaryDirectory, 'admin_password');
const runtimeSecretPath = path.join(temporaryDirectory, 'runtime_password');
const grantScriptPath = path.join(root, 'infra', 'db', 'security', 'apply-runtime-grants.sh');
const adminPassword = 'Phase5Admin-Local-Only-91';
const firstRuntimePassword = 'Phase5Runtime-Local-Only-27';
const secondRuntimePassword = 'Phase5Runtime-Rotated-Local-63';

const run = (args, options = {}) =>
  execFileSync('docker', args, {
    cwd: root,
    encoding: 'utf8',
    stdio: options.stdio ?? 'pipe',
    timeout: options.timeout ?? 120000,
  });

const runNode = (args, environment) =>
  execFileSync(process.execPath, args, {
    cwd: path.join(root, 'apps', 'api'),
    env: environment,
    encoding: 'utf8',
    stdio: 'pipe',
    timeout: 180000,
  });

const runtimePsql = (password, sql) =>
  run([
    'run',
    '--rm',
    '--network',
    networkName,
    '--read-only',
    '--cap-drop',
    'ALL',
    '--security-opt',
    'no-new-privileges',
    '--pids-limit',
    '32',
    '--memory',
    '128m',
    '--tmpfs',
    '/tmp:rw,noexec,nosuid,size=16m',
    '--env',
    `PGPASSWORD=${password}`,
    image,
    'psql',
    '--host',
    containerName,
    '--username',
    'gis_runtime',
    '--dbname',
    'gis_phase5_grants',
    '--tuples-only',
    '--no-align',
    '--set',
    'ON_ERROR_STOP=1',
    '--command',
    sql,
  ]);

const expectDenied = (password, sql, label, expectedPattern) => {
  try {
    runtimePsql(password, sql);
    throw new Error(`${label} unexpectedly succeeded`);
  } catch (error) {
    if (String(error.message).includes('unexpectedly succeeded')) {
      throw error;
    }
    const output = [
      error?.message,
      error?.stdout,
      error?.stderr,
      ...(Array.isArray(error?.output) ? error.output : []),
    ]
      .filter(Boolean)
      .join('\n');
    if (!expectedPattern.test(output)) {
      throw new Error(`${label} failed for an unexpected reason: ${output}`);
    }
  }
};

const applyGrants = () =>
  run([
    'run',
    '--rm',
    '--network',
    networkName,
    '--read-only',
    '--cap-drop',
    'ALL',
    '--security-opt',
    'no-new-privileges',
    '--pids-limit',
    '64',
    '--memory',
    '256m',
    '--tmpfs',
    '/tmp:rw,noexec,nosuid,size=32m',
    '--env',
    `DB_HOST=${containerName}`,
    '--env',
    'DB_PORT=5432',
    '--env',
    'DB_NAME=gis_phase5_grants',
    '--env',
    'DB_OWNER_USER=gis_owner',
    '--env',
    'DB_RUNTIME_USER=gis_runtime',
    '--env',
    'DB_ADMIN_PASSWORD_FILE=/run/secrets/admin_password',
    '--env',
    'DB_RUNTIME_PASSWORD_FILE=/run/secrets/runtime_password',
    '--volume',
    `${adminSecretPath}:/run/secrets/admin_password:ro`,
    '--volume',
    `${runtimeSecretPath}:/run/secrets/runtime_password:ro`,
    '--volume',
    `${grantScriptPath}:/opt/gis/apply-runtime-grants.sh:ro`,
    '--entrypoint',
    '/bin/sh',
    image,
    '/opt/gis/apply-runtime-grants.sh',
  ]);

// Docker Compose secrets are mounted read-only and container-readable. These
// synthetic, randomly located test secrets must model that behavior on Linux,
// where a 0600 host file owned by the CI runner is unreadable by the PostGIS
// image's unprivileged user. The temporary directory is removed in `finally`.
fs.writeFileSync(adminSecretPath, `${adminPassword}\n`, { mode: 0o644 });
fs.writeFileSync(runtimeSecretPath, `${firstRuntimePassword}\n`, { mode: 0o644 });

try {
  try {
    run(['image', 'inspect', image], { stdio: 'ignore' });
  } catch {
    if (image !== 'gis-phase6-postgis-audit:local') {
      throw new Error(`Configured release database image is unavailable: ${image}`);
    }
    run([
      'build',
      '--tag',
      image,
      '--file',
      'infra/db/Dockerfile.production',
      '.',
    ]);
  }
  run(['network', 'create', networkName]);
  run([
    'run',
    '--detach',
    '--name',
    containerName,
    '--network',
    networkName,
    '--network-alias',
    containerName,
    '--publish',
    '127.0.0.1::5432',
    '--env',
    'POSTGRES_DB=gis_phase5_grants',
    '--env',
    'POSTGRES_USER=gis_owner',
    '--env',
    'POSTGRES_PASSWORD_FILE=/run/secrets/admin_password',
    '--volume',
    `${adminSecretPath}:/run/secrets/admin_password:ro`,
    image,
  ]);

  let ready = false;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const probe = run([
        'exec',
        '--env',
        `PGPASSWORD=${adminPassword}`,
        containerName,
        'psql',
        '--username',
        'gis_owner',
        '--dbname',
        'gis_phase5_grants',
        '--tuples-only',
        '--no-align',
        '--set',
        'ON_ERROR_STOP=1',
        '--command',
        'SELECT 1;',
      ]).trim();
      if (probe === '1') {
        ready = true;
        break;
      }
    } catch {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
    }
  }
  if (!ready) {
    throw new Error('Isolated PostGIS did not become ready');
  }

  if (fullSchemaValidation) {
    const portOutput = run(['port', containerName, '5432/tcp']).trim();
    const hostPort = portOutput.match(/:(\d+)\s*$/)?.[1];
    if (!hostPort) {
      throw new Error(`Unable to resolve isolated PostGIS host port: ${portOutput}`);
    }
    const migrationEnvironment = {
      ...process.env,
      NODE_ENV: 'production',
      DB_HOST: '127.0.0.1',
      DB_PORT: hostPort,
      DB_NAME: 'gis_phase5_grants',
      DB_USER: 'gis_owner',
      DB_PASSWORD: adminPassword,
      DB_MAX_CONNECTIONS: '4',
      MIGRATIONS_DIR: path.join(root, 'infra', 'migrations'),
      LOG_PRETTY: 'false',
      LOG_TO_FILE: 'false',
    };
    let hostReady = false;
    for (let attempt = 0; attempt < 30; attempt += 1) {
      try {
        runNode(
          [
            '-e',
            [
              "const { Client } = require('pg');",
              '(async () => {',
              '  const client = new Client({',
              '    host: process.env.DB_HOST,',
              '    port: Number(process.env.DB_PORT),',
              '    database: process.env.DB_NAME,',
              '    user: process.env.DB_USER,',
              '    password: process.env.DB_PASSWORD,',
              '  });',
              '  await client.connect();',
              "  await client.query('SELECT 1');",
              '  await client.end();',
              '})().catch(() => process.exit(1));',
            ].join('\n'),
          ],
          migrationEnvironment,
        );
        hostReady = true;
        break;
      } catch {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
      }
    }
    if (!hostReady) {
      throw new Error('Isolated PostGIS host port did not become ready');
    }
    runNode(['dist/db/migrate.js'], migrationEnvironment);
  } else {
    run([
      'exec',
      '--env',
      `PGPASSWORD=${adminPassword}`,
      containerName,
      'psql',
      '--username',
      'gis_owner',
      '--dbname',
      'gis_phase5_grants',
      '--set',
      'ON_ERROR_STOP=1',
      '--command',
      'CREATE TABLE schema_migrations (filename text PRIMARY KEY, checksum text NOT NULL);',
    ]);
  }
  run([
    'exec',
    '--env',
    `PGPASSWORD=${adminPassword}`,
    containerName,
    'psql',
    '--username',
    'gis_owner',
    '--dbname',
    'gis_phase5_grants',
    '--set',
    'ON_ERROR_STOP=1',
    '--command',
    'CREATE TABLE runtime_probe (id integer PRIMARY KEY, value text NOT NULL);',
  ]);

  applyGrants();

  const roleFlags = runtimePsql(
    firstRuntimePassword,
    "SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication FROM pg_roles WHERE rolname = 'gis_runtime';",
  ).trim();
  if (roleFlags !== 'f|f|f|f') {
    throw new Error(`Runtime role has unsafe flags: ${roleFlags}`);
  }
  runtimePsql(
    firstRuntimePassword,
    "INSERT INTO runtime_probe (id, value) VALUES (1, 'preserved');",
  );
  expectDenied(
    firstRuntimePassword,
    'CREATE TABLE runtime_must_not_create (id integer);',
    'Runtime DDL',
    /permission denied for schema public/i,
  );
  expectDenied(
    firstRuntimePassword,
    "INSERT INTO schema_migrations (filename, checksum) VALUES ('forbidden.sql', 'x');",
    'Migration history mutation',
    /permission denied for table schema_migrations/i,
  );

  fs.writeFileSync(runtimeSecretPath, `${secondRuntimePassword}\n`, { mode: 0o644 });
  applyGrants();
  expectDenied(
    firstRuntimePassword,
    'SELECT 1;',
    'Old runtime password',
    /password authentication failed for user "gis_runtime"/i,
  );
  const preserved = runtimePsql(
    secondRuntimePassword,
    'SELECT value FROM runtime_probe WHERE id = 1;',
  ).trim();
  if (preserved !== 'preserved') {
    throw new Error('Runtime credential rotation did not preserve data');
  }
  if (fullSchemaValidation) {
    const migrationCount = Number(
      runtimePsql(secondRuntimePassword, 'SELECT COUNT(*) FROM schema_migrations;').trim(),
    );
    const expectedMigrationCount = fs
      .readdirSync(path.join(root, 'infra', 'migrations'))
      .filter((name) => name.endsWith('.sql')).length;
    if (migrationCount !== expectedMigrationCount) {
      throw new Error(
        `Runtime role saw ${migrationCount} migrations; expected ${expectedMigrationCount}`,
      );
    }

    const portOutput = run(['port', containerName, '5432/tcp']).trim();
    const hostPort = portOutput.match(/:(\d+)\s*$/)?.[1];
    runNode(
      [
        '-e',
        [
          "const { getPendingMigrations } = require('./dist/db/migrationRunner');",
          "const { closePool } = require('./dist/config/database');",
          '(async () => {',
          '  const pending = await getPendingMigrations();',
          "  if (pending.length) throw new Error(`Pending migrations: ${pending.join(', ')}`);",
          '  await closePool();',
          "  console.log('Production runtime migration read check: PASS');",
          '})().catch(async (error) => {',
          '  console.error(error.message);',
          '  try { await closePool(); } catch {}',
          '  process.exit(1);',
          '});',
        ].join('\n'),
      ],
      {
        ...process.env,
        NODE_ENV: 'production',
        DB_HOST: '127.0.0.1',
        DB_PORT: hostPort,
        DB_NAME: 'gis_phase5_grants',
        DB_USER: 'gis_runtime',
        DB_PASSWORD: secondRuntimePassword,
        DB_MAX_CONNECTIONS: '4',
        MIGRATIONS_DIR: path.join(root, 'infra', 'migrations'),
        LOG_PRETTY: 'false',
        LOG_TO_FILE: 'false',
      },
    );
  }

  console.log(
    fullSchemaValidation
      ? 'All migrations, restricted runtime startup check, denied DDL, and no-loss rotation: PASS'
      : 'Restricted database role, denied DDL, and no-loss password rotation: PASS',
  );
} finally {
  try {
    run(['rm', '--force', '--volumes', containerName]);
  } catch {
    // The container may not have been created.
  }
  try {
    run(['network', 'rm', networkName]);
  } catch {
    // The network may not have been created or may already be detached.
  }
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
