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
const databaseDockerfilePath = path.join(root, 'infra', 'db', 'Dockerfile.production');
const certbotDockerfilePath = path.join(root, 'infra', 'certbot', 'Dockerfile.production');
const prometheusDockerfilePath = path.join(
  root,
  'infra',
  'prometheus',
  'Dockerfile.production',
);
const alertmanagerDockerfilePath = path.join(
  root,
  'infra',
  'alertmanager',
  'Dockerfile.production',
);
const blackboxDockerfilePath = path.join(
  root,
  'infra',
  'blackbox',
  'Dockerfile.production',
);
const lokiDockerfilePath = path.join(
  root,
  'infra',
  'loki',
  'Dockerfile.production',
);
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
const databaseDockerfile = read(databaseDockerfilePath);
const certbotDockerfile = read(certbotDockerfilePath);
const prometheusDockerfile = read(prometheusDockerfilePath);
const alertmanagerDockerfile = read(alertmanagerDockerfilePath);
const blackboxDockerfile = read(blackboxDockerfilePath);
const lokiDockerfile = read(lokiDockerfilePath);
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
assert(composeImages.length >= 4, 'Expected production and observability image declarations');
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
const databaseDockerfileBases = databaseDockerfile
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*FROM\s+(\S+)/i)?.[1])
  .filter(Boolean);
assert(databaseDockerfileBases.length === 1, 'Database Dockerfile must have one base image');
assert(
  /@sha256:[a-f0-9]{64}$/.test(databaseDockerfileBases[0]),
  `Database base image is not digest-pinned: ${databaseDockerfileBases[0]}`,
);
assert(
  (productionCompose.match(/dockerfile:\s*infra\/db\/Dockerfile\.production/g) ?? [])
    .length === 2,
  'Production database services must use the hardened database image build',
);
assert(
  databaseDockerfile.includes("su-exec=0.3-r0") &&
    databaseDockerfile.includes('rm -f /usr/local/bin/gosu'),
  'Hardened database image must replace the upstream gosu helper',
);
const certbotDockerfileBases = certbotDockerfile
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*FROM\s+(\S+)/i)?.[1])
  .filter(Boolean);
assert(certbotDockerfileBases.length === 1, 'Certbot Dockerfile must have one base image');
assert(
  /@sha256:[a-f0-9]{64}$/.test(certbotDockerfileBases[0]),
  `Certbot base image is not digest-pinned: ${certbotDockerfileBases[0]}`,
);
assert(
  (productionCompose.match(/dockerfile:\s*infra\/certbot\/Dockerfile\.production/g) ?? [])
    .length === 2,
  'Production certificate services must use the hardened Certbot image build',
);
assert(
  certbotDockerfile.includes('rm -f /usr/local/bin/uv /usr/local/bin/uvx'),
  'Hardened Certbot image must remove package-management tooling',
);
const prometheusDockerfileBases = prometheusDockerfile
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*FROM\s+(\S+)/i)?.[1])
  .filter(Boolean);
assert(
  prometheusDockerfileBases.length === 3 &&
    prometheusDockerfileBases.every((image) => /@sha256:[a-f0-9]{64}$/.test(image)),
  'Prometheus build and runtime images must all be digest-pinned',
);
assert(
  observabilityCompose.includes('dockerfile: infra/prometheus/Dockerfile.production'),
  'Production observability must use the patched Prometheus image build',
);
assert(
  prometheusDockerfile.includes('golang.org/x/text@v0.39.0') &&
    prometheusDockerfile.includes('google.golang.org/grpc@v1.82.1') &&
    prometheusDockerfile.includes('PROMETHEUS_SOURCE_SHA256='),
  'Prometheus security rebuild must pin source and patched Go modules',
);
for (const [name, dockerfile, expectedPath] of [
  [
    'Alertmanager',
    alertmanagerDockerfile,
    'infra/alertmanager/Dockerfile.production',
  ],
  ['Blackbox exporter', blackboxDockerfile, 'infra/blackbox/Dockerfile.production'],
]) {
  const bases = dockerfile
    .split(/\r?\n/)
    .map((line) => line.match(/^\s*FROM\s+(\S+)/i)?.[1])
    .filter(Boolean);
  assert(
    bases.length >= 2 &&
      bases.every((image) => /@sha256:[a-f0-9]{64}$/.test(image)),
    `${name} build and runtime images must all be digest-pinned`,
  );
  assert(
    observabilityCompose.includes(`dockerfile: ${expectedPath}`),
    `Production observability must use the patched ${name} image build`,
  );
  assert(
    dockerfile.includes('golang.org/x/text@v0.39.0') &&
      dockerfile.includes('google.golang.org/grpc@v1.82.1') &&
      dockerfile.includes('SOURCE_SHA256='),
    `${name} security rebuild must pin source and patched Go modules`,
  );
}
const lokiBases = lokiDockerfile
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*FROM\s+(\S+)/i)?.[1])
  .filter(Boolean);
assert(
  lokiBases.length === 2 &&
    lokiBases.every((image) => /@sha256:[a-f0-9]{64}$/.test(image)),
  'Loki build and runtime images must be digest-pinned',
);
assert(
  observabilityCompose.includes('context: ./infra/loki') &&
    observabilityCompose.includes('dockerfile: Dockerfile.production'),
  'Production observability must use the patched Loki image build',
);
assert(
  lokiDockerfile.includes('golang.org/x/text@v0.39.0') &&
    lokiDockerfile.includes('google.golang.org/grpc@v1.82.1') &&
    lokiDockerfile.includes('LOKI_SOURCE_SHA256=') &&
    lokiDockerfile.includes('go mod vendor'),
  'Loki security rebuild must pin source, patched Go modules, and vendor state',
);
assert(
  apiDockerfile.includes('/usr/local/lib/node_modules/npm') &&
    apiDockerfile.includes('/usr/local/bin/npx'),
  'Production API runtime must remove package-management tooling',
);

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
    'gis-phase6-prometheus-audit:local',
  alertmanager:
    'gis-phase6-alertmanager-audit:local',
  blackbox:
    'gis-phase6-blackbox-audit:local',
  loki:
    'gis-phase6-loki-audit:local',
  alloy:
    'grafana/alloy:v1.18.0@sha256:491b0578c04983fd54fe99b587b6fab4404dc46d0dc16677bd6b00cc1140b308',
  nginx:
    'nginxinc/nginx-unprivileged:1.31.3-alpine3.24@sha256:59ccf0943b0b8e8d9e6ea9039a39555730f544701a655c596f7df7d096c593f5',
  certbot:
    'gis-phase6-certbot-audit:local',
};

const dockerRun = (args, options = {}) =>
  execFileSync('docker', args, {
    cwd: root,
    encoding: 'utf8',
    stdio: options.stdio ?? 'pipe',
    timeout: options.timeout ?? 180000,
  });

for (const [image, dockerfile, context = '.'] of [
  [images.certbot, 'infra/certbot/Dockerfile.production'],
  [images.prometheus, 'infra/prometheus/Dockerfile.production'],
  [images.alertmanager, 'infra/alertmanager/Dockerfile.production'],
  [images.blackbox, 'infra/blackbox/Dockerfile.production'],
  [images.loki, 'infra/loki/Dockerfile.production', 'infra/loki'],
]) {
  try {
    dockerRun(['image', 'inspect', image], { stdio: 'ignore' });
  } catch {
    dockerRun([
      'build',
      '--tag',
      image,
      '--file',
      dockerfile,
      context,
    ]);
  }
}

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
const hostFilesystemUser =
  typeof process.getuid === 'function' && typeof process.getgid === 'function'
    ? ['--user', `${process.getuid()}:${process.getgid()}`]
    : [];

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
      ...hostFilesystemUser,
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
