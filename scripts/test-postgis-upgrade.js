#!/usr/bin/env node

const { execFileSync } = require('node:child_process');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const oldImage =
  'postgis/postgis:16-3.4@sha256:44126d872ac91993766c341e369c539e8196614321765d36a6f1bab0419a5fa5';
const newImage = process.env.RELEASE_DATABASE_IMAGE || 'gis-phase6-postgis-audit:local';
const suffix = `${process.pid}-${Date.now()}`;
const oldContainer = `gis-phase6-postgis-old-${suffix}`;
const newContainer = `gis-phase6-postgis-new-${suffix}`;
const volume = `gis-phase6-postgis-upgrade-${suffix}`;
const password = 'Phase6Upgrade-Local-Only-47';

const run = (args, options = {}) =>
  execFileSync('docker', args, {
    cwd: root,
    encoding: 'utf8',
    stdio: options.stdio ?? 'pipe',
    timeout: options.timeout ?? 180000,
  });

const waitUntilReady = (container) => {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      run([
        'exec',
        container,
        'pg_isready',
        '--username',
        'gis_owner',
        '--dbname',
        'gis_upgrade',
      ]);
      return;
    } catch {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
    }
  }
  throw new Error(`${container} did not become ready`);
};

const start = (container, image) => {
  run([
    'run',
    '--detach',
    '--name',
    container,
    '--env',
    'POSTGRES_DB=gis_upgrade',
    '--env',
    'POSTGRES_USER=gis_owner',
    '--env',
    `POSTGRES_PASSWORD=${password}`,
    '--volume',
    `${volume}:/var/lib/postgresql/data`,
    image,
  ]);
  waitUntilReady(container);
};

const sql = (container, statement) =>
  run([
    'exec',
    '--env',
    `PGPASSWORD=${password}`,
    container,
    'psql',
    '--username',
    'gis_owner',
    '--dbname',
    'gis_upgrade',
    '--tuples-only',
    '--no-align',
    '--set',
    'ON_ERROR_STOP=1',
    '--command',
    statement,
  ]).trim();

try {
  try {
    run(['image', 'inspect', newImage], { stdio: 'ignore' });
  } catch {
    if (newImage !== 'gis-phase6-postgis-audit:local') {
      throw new Error(`Configured release database image is unavailable: ${newImage}`);
    }
    run([
      'build',
      '--tag',
      newImage,
      '--file',
      'infra/db/Dockerfile.production',
      '.',
    ]);
  }

  run(['volume', 'create', volume]);
  start(oldContainer, oldImage);
  sql(
    oldContainer,
    [
      'CREATE EXTENSION IF NOT EXISTS postgis;',
      'CREATE TABLE upgrade_probe (id integer PRIMARY KEY, label text NOT NULL, point geometry(Point, 4326) NOT NULL);',
      "INSERT INTO upgrade_probe VALUES (1, 'preserved', ST_SetSRID(ST_MakePoint(35.5018, 33.8938), 4326));",
      'CHECKPOINT;',
    ].join(' '),
  );
  const oldVersion = sql(
    oldContainer,
    "SELECT extversion FROM pg_extension WHERE extname = 'postgis';",
  );
  const oldValue = sql(
    oldContainer,
    "SELECT label || '|' || ST_AsText(point) FROM upgrade_probe WHERE id = 1;",
  );
  if (oldValue !== 'preserved|POINT(35.5018 33.8938)') {
    throw new Error(`Old database fixture was not written correctly: ${oldValue}`);
  }

  run(['stop', '--time', '30', oldContainer]);
  run(['rm', oldContainer]);

  start(newContainer, newImage);
  sql(newContainer, 'ALTER EXTENSION postgis UPDATE;');
  const newVersion = sql(
    newContainer,
    "SELECT extversion FROM pg_extension WHERE extname = 'postgis';",
  );
  const newValue = sql(
    newContainer,
    "SELECT label || '|' || ST_AsText(point) FROM upgrade_probe WHERE id = 1;",
  );
  const integrity = sql(newContainer, 'SELECT COUNT(*) FROM upgrade_probe;');
  if (newValue !== oldValue || integrity !== '1') {
    throw new Error(
      `PostGIS upgrade did not preserve the fixture: value=${newValue}, rows=${integrity}`,
    );
  }
  if (oldVersion === newVersion || !newVersion.startsWith('3.5.')) {
    throw new Error(`PostGIS extension was not upgraded: ${oldVersion} -> ${newVersion}`);
  }

  console.log(
    `PostGIS same-major data/geometry upgrade and recovery: PASS (${oldVersion} -> ${newVersion})`,
  );
} finally {
  for (const container of [oldContainer, newContainer]) {
    try {
      run(['rm', '--force', '--volumes', container]);
    } catch {
      // The container may not have been created or may already be removed.
    }
  }
  try {
    run(['volume', 'rm', volume]);
  } catch {
    // The named test volume may not have been created.
  }
}
