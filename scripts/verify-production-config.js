#!/usr/bin/env node

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const runtimeValidation = process.argv.includes('--runtime');
const onlyArgument = process.argv.find((argument) => argument.startsWith('--only='));
const selectedComponents = new Set(
  onlyArgument
    ? onlyArgument
        .slice('--only='.length)
        .split(',')
        .map((value) => value.trim())
        .filter(Boolean)
    : [],
);
const shouldRun = (component) =>
  selectedComponents.size === 0 || selectedComponents.has(component);
const productionComposePath = path.join(root, 'compose.prod.yml');
const observabilityComposePath = path.join(root, 'compose.observability.yml');
const apiDockerfilePath = path.join(root, 'apps', 'api', 'Dockerfile');
const nginxTemplatePath = path.join(root, 'infra', 'nginx', 'production.conf.template');
const observabilityPath = path.join(root, 'infra', 'observability');

const read = (filePath) => fs.readFileSync(filePath, 'utf8');
const assert = (condition, message) => {
  if (!condition) {
    throw new Error(message);
  }
};

const productionCompose = read(productionComposePath);
const observabilityCompose = read(observabilityComposePath);
const apiDockerfile = read(apiDockerfilePath);
const gitignore = read(path.join(root, '.gitignore'));
const workflowImages = [
  read(path.join(root, '.github', 'workflows', 'reusable-api-release-gate.yml')),
  read(path.join(root, '.github', 'workflows', 'staging-readiness.yml')),
]
  .join('\n')
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*image:\s*(\S+)\s*$/)?.[1])
  .filter(Boolean);

const composeImages = `${productionCompose}\n${observabilityCompose}`
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*image:\s*(\S+)\s*$/)?.[1])
  .filter(Boolean);
assert(composeImages.length >= 9, 'Expected production and observability image declarations');
for (const image of composeImages) {
  assert(
    /@sha256:[a-f0-9]{64}$/.test(image),
    `Production image is not pinned by digest: ${image}`,
  );
}
for (const image of workflowImages) {
  assert(/@sha256:[a-f0-9]{64}$/.test(image), `CI service image is not digest-pinned: ${image}`);
}

const dockerfileBases = apiDockerfile
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*FROM\s+(\S+)/i)?.[1])
  .filter(Boolean);
assert(dockerfileBases.length > 0, 'API Dockerfile has no base image');
for (const image of dockerfileBases) {
  assert(/@sha256:[a-f0-9]{64}$/.test(image), `API base image is not digest-pinned: ${image}`);
}

assert(!/redis(?:s)?:\/\/[^\s/]*@/i.test(productionCompose), 'Redis credential found in URL');
assert(!/VALKEY_PASSWORD/.test(productionCompose), 'Legacy inline Valkey password remains');
assert(
  !/POSTGRES_PASSWORD:\s*\$\{/.test(productionCompose),
  'Postgres password is interpolated inline',
);
assert(
  productionCompose.includes('DB_RUNTIME_USER') &&
    productionCompose.includes('db-security') &&
    productionCompose.includes('db_runtime_password'),
  'Restricted database runtime role is not enforced',
);
const workerSection = productionCompose
  .split(/\n  workload-worker:\s*\n/, 2)[1]
  ?.split(/\n  nginx:\s*\n/, 1)[0];
assert(workerSection, 'Workload worker service is missing');
assert(
  !/(jwt_secret|smtp_password|super_admin_password|metrics_token|api_docs_token)/i.test(
    workerSection,
  ),
  'Workload worker receives unrelated application secrets',
);
assert(
  productionCompose.includes('read_only: true') &&
    productionCompose.includes('no-new-privileges:true') &&
    productionCompose.includes('pids_limit:') &&
    productionCompose.includes('mem_limit:') &&
    productionCompose.includes('cpus:'),
  'Container security/resource controls are incomplete',
);
assert(
  productionCompose.includes('certbot-bootstrap') &&
    productionCompose.includes('certbot renew') &&
    read(nginxTemplatePath).includes('ssl_protocols TLSv1.2 TLSv1.3'),
  'TLS bootstrap/renewal controls are incomplete',
);
assert(
  observabilityCompose.includes('/var/lib/docker/containers:ro') &&
    !observabilityCompose.includes('/var/run/docker.sock'),
  'Log collection must use read-only files without the Docker control socket',
);
assert(gitignore.includes('secrets/**/*.txt'), 'Nested secret text files are not ignored');
assert(
  !fs.existsSync(path.join(root, 'apps', 'api', 'docker-compose.production.yml')),
  'Ambiguous API-local production Compose file still exists',
);
assert(
  !fs.existsSync(path.join(root, 'docker-compose.prod.example.yml')),
  'Ambiguous legacy production example still exists',
);

const composeEnvironment = {
  ...process.env,
  API_ENV_FILE: '.env.prod.example',
  PUBLIC_HOSTNAME: 'collector.gis.gov.lb',
  CERTBOT_EMAIL: 'operations@gis.gov.lb',
  DB_RUNTIME_USER: 'gis_runtime',
  POSTGRES_USER: 'gis_owner',
  POSTGRES_DB: 'gis_app_prod',
  POSTGIS_PROD_DATA_VOLUME: 'gis_phase5_config_validation',
};
for (const name of [
  'POSTGRES_PASSWORD',
  'DB_PASSWORD',
  'JWT_SECRET',
  'JWT_SECRET_CURRENT',
  'JWT_SECRET_PREVIOUS',
  'JWT_REFRESH_SECRET',
  'JWT_REFRESH_SECRET_CURRENT',
  'JWT_REFRESH_SECRET_PREVIOUS',
  'REDIS_PASSWORD',
  'METRICS_TOKEN',
  'API_DOCS_TOKEN',
  'SMTP_PASS',
  'SUPER_ADMIN_PASSWORD',
  'AI_CALLBACK_SECRET',
]) {
  composeEnvironment[name] = '';
}

execFileSync(
  'docker',
  [
    'compose',
    '--env-file',
    '.env.prod.example',
    '-f',
    'compose.prod.yml',
    '-f',
    'compose.observability.yml',
    'config',
    '--quiet',
  ],
  {
    cwd: root,
    env: composeEnvironment,
    stdio: 'pipe',
  },
);

console.log('Production Compose and static security invariants: PASS');

if (!runtimeValidation) {
  process.exit(0);
}

const images = {
  prometheus:
    'prom/prometheus:v3.13.1@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893',
  alertmanager:
    'prom/alertmanager:v0.33.1@sha256:9e082985f56f4c8c9f724e18f2288c6708f472e56a5286b8863d080434ea065d',
  blackbox:
    'prom/blackbox-exporter:v0.28.0@sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc',
  loki:
    'grafana/loki:3.7.4@sha256:87f0a067673756a3cede1bcbf0c74875f7df9b09fddb53e399d0c576f756cfcc',
  alloy:
    'grafana/alloy:v1.18.0@sha256:491b0578c04983fd54fe99b587b6fab4404dc46d0dc16677bd6b00cc1140b308',
  nginx:
    'nginxinc/nginx-unprivileged:1.29.4-alpine@sha256:a6c4f61f456b85b8fdf7ec7ab28cc3e299440e6fb4a9dea520e5fd8fd440025e',
  certbot:
    'certbot/certbot:v5.7.0@sha256:34ee91d2f43008eb78a007d22f23ed4b2eaa9a454cb27ca2c042b49527a695b4',
};

const dockerRun = (args, options = {}) =>
  execFileSync('docker', args, {
    cwd: root,
    encoding: 'utf8',
    stdio: options.stdio ?? 'pipe',
    timeout: options.timeout ?? 180000,
  });

const common = [
  'run',
  '--rm',
  '--network',
  'none',
  '--read-only',
  '--cap-drop',
  'ALL',
  '--security-opt',
  'no-new-privileges',
  '--pids-limit',
  '64',
  '--memory',
  '512m',
];

const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'gis-phase5-config-'));
try {
  const tokenPath = path.join(temporaryDirectory, 'metrics_token');
  fs.writeFileSync(tokenPath, 'phase5-config-validation-token\n', {
    encoding: 'utf8',
    mode: 0o600,
  });

  if (shouldRun('prometheus')) {
    dockerRun([
      ...common,
      '--volume',
      `${observabilityPath}:/etc/prometheus:ro`,
      '--volume',
      `${tokenPath}:/run/secrets/metrics_token:ro`,
      '--entrypoint',
      '/bin/promtool',
      images.prometheus,
      'check',
      'config',
      '/etc/prometheus/prometheus.yml',
    ]);
    dockerRun([
      ...common,
      '--tmpfs',
      '/tmp:rw,noexec,nosuid,size=64m',
      '--workdir',
      '/etc/prometheus',
      '--volume',
      `${observabilityPath}:/etc/prometheus:ro`,
      '--entrypoint',
      '/bin/promtool',
      images.prometheus,
      'test',
      'rules',
      '/etc/prometheus/alerts.test.yml',
    ]);
    console.log('Prometheus config and deliberate alert rule tests: PASS');
  }

  if (shouldRun('alertmanager')) {
    dockerRun([
      ...common,
      '--volume',
      `${observabilityPath}:/etc/alertmanager:ro`,
      '--entrypoint',
      '/bin/amtool',
      images.alertmanager,
      'check-config',
      '/etc/alertmanager/alertmanager.yml',
    ]);
    console.log('Alertmanager routing config: PASS');
  }

  if (shouldRun('loki')) {
    dockerRun([
      ...common,
      '--tmpfs',
      '/tmp:rw,noexec,nosuid,size=32m',
      '--volume',
      `${observabilityPath}:/etc/loki:ro`,
      images.loki,
      '-config.file=/etc/loki/loki.yml',
      '-verify-config=true',
    ]);
    console.log('Loki config: PASS');
  }

  if (shouldRun('alloy')) {
    dockerRun([
      ...common,
      '--tmpfs',
      '/tmp:rw,noexec,nosuid,size=32m',
      '--volume',
      `${observabilityPath}:/etc/alloy:ro`,
      images.alloy,
      'validate',
      '/etc/alloy/config.alloy',
    ]);
    console.log('Alloy config: PASS');
  }

  if (shouldRun('blackbox')) {
    const blackboxName = `gis-phase5-blackbox-config-${process.pid}`;
    try {
      dockerRun([
        'run',
        '--detach',
        '--name',
        blackboxName,
        '--network',
        'none',
        '--read-only',
        '--cap-drop',
        'ALL',
        '--security-opt',
        'no-new-privileges',
        '--pids-limit',
        '64',
        '--memory',
        '128m',
        '--tmpfs',
        '/tmp:rw,noexec,nosuid,size=16m',
        '--volume',
        `${observabilityPath}:/etc/blackbox:ro`,
        images.blackbox,
        '--config.file=/etc/blackbox/blackbox.yml',
        '--web.listen-address=127.0.0.1:9115',
      ]);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500);
      const state = JSON.parse(
        dockerRun(['inspect', '--format', '{{json .State}}', blackboxName]).trim(),
      );
      if (!state.Running && state.ExitCode !== 0) {
        const logs = dockerRun(['logs', blackboxName]);
        throw new Error(`Blackbox exporter config failed: ${logs}`);
      }
      console.log('Blackbox exporter config: PASS');
    } finally {
      try {
        dockerRun(['rm', '--force', blackboxName]);
      } catch {
        // The container may already have been removed after a startup failure.
      }
    }
  }

  if (shouldRun('nginx')) {
    const certificateRoot = path.join(temporaryDirectory, 'letsencrypt');
    const liveCertificatePath = path.join(certificateRoot, 'live', 'collector.gis.gov.lb');
    fs.mkdirSync(liveCertificatePath, { recursive: true });
    const certificatePath = path.join(liveCertificatePath, 'fullchain.pem');
    const privateKeyPath = path.join(liveCertificatePath, 'privkey.pem');
    dockerRun([
      ...common,
      '--volume',
      `${certificateRoot}:/certs:rw`,
      '--entrypoint',
      '/usr/bin/openssl',
      images.certbot,
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=collector.gis.gov.lb',
      '-keyout',
      '/certs/live/collector.gis.gov.lb/privkey.pem',
      '-out',
      '/certs/live/collector.gis.gov.lb/fullchain.pem',
    ]);
    fs.chmodSync(privateKeyPath, 0o644);
    fs.chmodSync(certificatePath, 0o644);
    dockerRun([
      ...common,
      '--add-host',
      'api:127.0.0.1',
      '--tmpfs',
      '/etc/nginx/conf.d:rw,noexec,nosuid,size=8m',
      '--tmpfs',
      '/var/cache/nginx:rw,noexec,nosuid,size=32m',
      '--tmpfs',
      '/var/run:rw,noexec,nosuid,size=8m',
      '--tmpfs',
      '/tmp:rw,noexec,nosuid,size=16m',
      '--env',
      'PUBLIC_HOSTNAME=collector.gis.gov.lb',
      '--env',
      'NGINX_ENVSUBST_FILTER=^PUBLIC_HOSTNAME$',
      '--volume',
      `${nginxTemplatePath}:/etc/nginx/templates/default.conf.template:ro`,
      '--volume',
      `${certificateRoot}:/etc/letsencrypt:ro`,
      images.nginx,
      'nginx',
      '-t',
    ]);
    console.log('Exact pinned Nginx TLS config: PASS');
  }
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}

console.log('Pinned production observability runtime validation: PASS');
