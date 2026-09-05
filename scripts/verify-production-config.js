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
const apiEntrypointPath = path.join(root, 'apps', 'api', 'docker', 'entrypoint.sh');
const apiEnvSchemaPath = path.join(root, 'apps', 'api', 'src', 'config', 'env.ts');
const productionEnvExamplePath = path.join(root, '.env.prod.example');
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
const alloyDockerfilePath = path.join(
  root,
  'infra',
  'alloy',
  'Dockerfile.production',
);
const alloyVexPath = path.join(root, 'infra', 'alloy', 'alloy.openvex.json');
const alloyMediumPolicyPath = path.join(
  root,
  'infra',
  'alloy',
  'alloy.medium-risk-acceptance.json',
);
const nginxTemplatePath = path.join(root, 'infra', 'nginx', 'production.conf.template');
const observabilityPath = path.join(root, 'infra', 'observability');
const digitalOceanTerraformPath = path.join(root, 'infra', 'digitalocean', 'terraform');

const read = (filePath) => fs.readFileSync(filePath, 'utf8');
const assert = (condition, message) => {
  if (!condition) {
    throw new Error(message);
  }
};

const productionCompose = read(productionComposePath);
const observabilityCompose = read(observabilityComposePath);
const apiDockerfile = read(apiDockerfilePath);
const apiEntrypoint = read(apiEntrypointPath);
const apiEnvSchema = read(apiEnvSchemaPath);
const productionEnvExample = read(productionEnvExamplePath);
const digitalOceanTerraform = ['versions.tf', 'variables.tf', 'main.tf', 'outputs.tf']
  .map((fileName) => read(path.join(digitalOceanTerraformPath, fileName)))
  .join('\n');
const digitalOceanCloudInit = read(
  path.join(digitalOceanTerraformPath, 'cloud-init.yaml.tftpl'),
);
const databaseDockerfile = read(databaseDockerfilePath);
const certbotDockerfile = read(certbotDockerfilePath);
const prometheusDockerfile = read(prometheusDockerfilePath);
const alertmanagerDockerfile = read(alertmanagerDockerfilePath);
const blackboxDockerfile = read(blackboxDockerfilePath);
const lokiDockerfile = read(lokiDockerfilePath);
const alloyDockerfile = read(alloyDockerfilePath);
const alloyVex = JSON.parse(read(alloyVexPath));
const alloyMediumPolicy = JSON.parse(read(alloyMediumPolicyPath));
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
assert(composeImages.length >= 3, 'Expected production and observability image declarations');
for (const image of composeImages) {
  if (image.startsWith('${AI_SERVER_IMAGE:')) {
    continue;
  }
  assert(
    /@sha256:[a-f0-9]{64}$/.test(image),
    `Production image is not pinned by digest: ${image}`,
  );
}
for (const image of workflowImages) {
  assert(/@sha256:[a-f0-9]{64}$/.test(image), `CI service image is not digest-pinned: ${image}`);
}

const apiDockerfileStages = new Set();
const dockerfileBases = [];
for (const line of apiDockerfile.split(/\r?\n/)) {
  const instruction = line.match(/^\s*FROM\s+(\S+)(?:\s+AS\s+(\S+))?/i);
  if (!instruction) continue;
  const image = instruction[1];
  if (!apiDockerfileStages.has(image)) dockerfileBases.push(image);
  if (instruction[2]) apiDockerfileStages.add(instruction[2]);
}
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
  certbotDockerfile.includes('rm -f /usr/local/bin/uv /usr/local/bin/uvx') &&
    certbotDockerfile.includes('site-packages/setuptools'),
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
  prometheusDockerfile.includes('golang.org/x/crypto@v0.55.0') &&
    prometheusDockerfile.includes('golang.org/x/mod@v0.40.0') &&
    prometheusDockerfile.includes('golang.org/x/text@v0.41.0') &&
    prometheusDockerfile.includes('google.golang.org/grpc@v1.83.1') &&
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
    dockerfile.includes('golang.org/x/crypto@v0.55.0') &&
      dockerfile.includes('golang.org/x/mod@v0.40.0') &&
      dockerfile.includes('golang.org/x/text@v0.41.0') &&
      dockerfile.includes('google.golang.org/grpc@v1.83.1') &&
      dockerfile.includes('SOURCE_SHA256='),
    `${name} security rebuild must pin source and patched Go modules`,
  );
}
assert(
  blackboxDockerfile.includes('github.com/google/cel-go@v0.29.0') &&
    blackboxDockerfile.includes('github.com/quic-go/quic-go@v0.59.1'),
  'Blackbox security rebuild must patch reviewed Medium Go dependencies',
);
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
  lokiDockerfile.includes('golang.org/x/crypto@v0.55.0') &&
    lokiDockerfile.includes('golang.org/x/mod@v0.40.0') &&
    lokiDockerfile.includes('golang.org/x/text@v0.41.0') &&
    lokiDockerfile.includes('google.golang.org/grpc@v1.83.1') &&
    lokiDockerfile.includes('LOKI_SOURCE_SHA256=') &&
    lokiDockerfile.includes('go mod vendor'),
  'Loki security rebuild must pin source, patched Go modules, and vendor state',
);
const alloyBases = alloyDockerfile
  .split(/\r?\n/)
  .map((line) => line.match(/^\s*FROM\s+(\S+)/i)?.[1])
  .filter(Boolean);
assert(
  alloyBases.length === 4 &&
    alloyBases.filter((image) => image !== 'source').length === 3 &&
    alloyBases
      .filter((image) => image !== 'source')
      .every((image) => /@sha256:[a-f0-9]{64}$/.test(image)),
  'Alloy build and runtime images must all be digest-pinned',
);
assert(
  observabilityCompose.includes('dockerfile: infra/alloy/Dockerfile.production'),
  'Production observability must use the patched Alloy image build',
);
assert(
  alloyDockerfile.includes(
    'ALLOY_COMMIT=a435563ff073d5355952c1a8d1821110b1392691',
  ) &&
    alloyDockerfile.includes(
      'ALLOY_SOURCE_SHA256=6ba0318a3eb0da0a67b7567e97720e880e5ba0dd880e3ef73f68227f2b8c7150',
    ) &&
    alloyDockerfile.includes('github.com/apache/thrift@v0.24.0') &&
    alloyDockerfile.includes('github.com/go-git/go-git/v5@v5.19.2') &&
    alloyDockerfile.includes('golang.org/x/crypto@v0.55.0') &&
    alloyDockerfile.includes('golang.org/x/mod@v0.40.0') &&
    alloyDockerfile.includes('golang.org/x/text@v0.41.0') &&
    alloyDockerfile.includes('google.golang.org/grpc@v1.83.1') &&
    alloyDockerfile.includes('bsdutils=1:2.39.3-9ubuntu6.6') &&
    alloyDockerfile.includes('libp11-kit0=0.25.3-4ubuntu2.2') &&
    alloyDockerfile.includes('libssl3t64=3.0.13-0ubuntu3.15') &&
    alloyDockerfile.includes('libsystemd0=255.4-1ubuntu8.17') &&
    alloyDockerfile.includes('perl-base=5.38.2-3.2ubuntu0.4') &&
    alloyDockerfile.includes('libc6=2.39-0ubuntu8.8') &&
    alloyDockerfile.includes('libpam0g=1.5.3-5ubuntu5.7') &&
    alloyDockerfile.includes('tar=1.35+dfsg-3ubuntu0.4'),
  'Alloy security rebuild must pin source, patched Go modules, and OS updates',
);
const expectedAlloyVulnerabilities = [
  'CVE-2026-33997',
  'CVE-2026-41568',
  'CVE-2026-41567',
  'CVE-2026-42306',
];
const alloyVexStatements = alloyVex.statements ?? [];
assert(
  alloyVexStatements.length === expectedAlloyVulnerabilities.length &&
    alloyVexStatements
      .map((statement) => statement.vulnerability?.name)
      .sort()
      .join(',') === [...expectedAlloyVulnerabilities].sort().join(','),
  'Alloy VEX must contain exactly the four reviewed upstream findings',
);
for (const statement of alloyVexStatements) {
  assert(
    statement.status === 'not_affected' &&
      statement.justification === 'vulnerable_code_not_in_execute_path' &&
      statement.products?.length === 1 &&
      statement.products[0]['@id'] ===
        'pkg:golang/github.com/docker/docker@v28.5.2%2Bincompatible',
    `Alloy VEX scope is invalid for ${statement.vulnerability?.name ?? 'unknown finding'}`,
  );
}
assert(
  /^\d{4}-\d{2}-\d{2}$/.test(alloyVex.x_expiry) &&
    Date.parse(`${alloyVex.x_expiry}T00:00:00Z`) > Date.now(),
  'Alloy VEX security decision has expired',
);
const expectedAlloyMediumPolicyIds = [
  'CVE-2026-18374',
  'CVE-2026-18477',
  'CVE-2026-18508',
  'CVE-2026-33997',
  'CVE-2026-41568',
];
assert(
  alloyMediumPolicy.schemaVersion === 1 &&
    typeof alloyMediumPolicy.owner === 'string' &&
    alloyMediumPolicy.owner.trim().length > 0 &&
    /^\d{4}-\d{2}-\d{2}$/.test(alloyMediumPolicy.reviewBy) &&
    Date.parse(`${alloyMediumPolicy.reviewBy}T00:00:00Z`) > Date.now() &&
    alloyMediumPolicy.findings?.length === 6 &&
    [...new Set(alloyMediumPolicy.findings.map(({ id }) => id))]
      .sort()
      .join(',') === expectedAlloyMediumPolicyIds.sort().join(',') &&
    alloyMediumPolicy.findings.every(
      ({ decision, rationale, mitigation, evidence }) =>
        decision === 'accepted_with_mitigation' || decision === 'not_affected',
    ) &&
    alloyMediumPolicy.findings.every(
      ({ rationale, mitigation, evidence }) =>
        typeof rationale === 'string' &&
        rationale.length >= 40 &&
        typeof mitigation === 'string' &&
        mitigation.length >= 40 &&
        typeof evidence === 'string' &&
        evidence.length >= 10,
    ),
  'Alloy Medium risk acceptance is missing, changed, or expired',
);
assert(
  apiDockerfile.includes('/usr/local/lib/node_modules/npm') &&
    apiDockerfile.includes('/usr/local/bin/npx'),
  'Production API runtime must remove package-management tooling',
);

const envSchemaBlock = apiEnvSchema
  .split('const envSchema = Joi.object({', 2)[1]
  ?.split('}).unknown(true);', 1)[0];
assert(envSchemaBlock, 'Unable to inspect the API environment schema');
const apiEnvironmentKeys = [
  ...envSchemaBlock.matchAll(/^\s{2}([A-Z][A-Z0-9_]+):/gm),
].map((match) => match[1]);
const documentedEnvironmentKeys = new Set(
  [...productionEnvExample.matchAll(/^([A-Z][A-Z0-9_]+)=/gm)].map((match) => match[1]),
);
const undocumentedEnvironmentKeys = apiEnvironmentKeys.filter(
  (key) => !documentedEnvironmentKeys.has(key),
);
assert(
  undocumentedEnvironmentKeys.length === 0,
  `Production environment template is missing API settings: ${undocumentedEnvironmentKeys.join(', ')}`,
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
for (const [variable, secretName] of [
  ['DB_PASSWORD', 'db_runtime_password'],
  ['JWT_SECRET', 'jwt_secret'],
  ['JWT_SECRET_CURRENT', 'jwt_secret'],
  ['JWT_REFRESH_SECRET', 'jwt_refresh_secret'],
  ['JWT_REFRESH_SECRET_CURRENT', 'jwt_refresh_secret'],
  ['REDIS_PASSWORD', 'redis_password'],
  ['METRICS_TOKEN', 'metrics_token'],
  ['SMTP_PASS', 'smtp_password'],
  ['SUPER_ADMIN_PASSWORD', 'super_admin_password'],
  ['AI_CALLBACK_SECRET', 'ai_callback_secret'],
  ['AI_INTERNAL_API_SECRET', 'ai_internal_api_secret'],
  ['API_DOCS_TOKEN', 'api_docs_token'],
  ['PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64', 'privacy_export_encryption_key'],
  ['VERIFICATION_HMAC_SECRET', 'verification_hmac_secret'],
  ['STORAGE_S3_ACCESS_KEY_ID', 'spaces_s3_access_key_id'],
  ['STORAGE_S3_SECRET_ACCESS_KEY', 'spaces_s3_secret_access_key'],
  ['STORAGE_S3_CUSTOMER_KEY_BASE64', 'spaces_s3_customer_key'],
  ['ARCGIS_CLIENT_ID', 'arcgis_client_id'],
  ['ARCGIS_CLIENT_SECRET', 'arcgis_client_secret'],
]) {
  assert(
    apiEntrypoint.includes(`load_secret_var ${variable}`),
    `${variable} is not loaded from a Docker secret`,
  );
  assert(
    productionCompose.includes(`${variable}_FILE: /run/secrets/${secretName}`) &&
      productionCompose.includes(`${secretName}:`),
    `${variable} Docker secret wiring is incomplete`,
  );
}
assert(
  apiEntrypoint.includes('load_secret_var BACKUP_ENCRYPTION_KEY_BASE64') &&
    productionCompose.includes(
      'BACKUP_ENCRYPTION_KEY_BASE64_FILE: /run/secrets/backup_encryption_key',
    ) &&
    productionCompose.includes(
      'STORAGE_S3_ACCESS_KEY_ID_FILE: /run/secrets/spaces_backup_s3_access_key_id',
    ) &&
    productionCompose.includes(
      'STORAGE_S3_SECRET_ACCESS_KEY_FILE: /run/secrets/spaces_backup_s3_secret_access_key',
    ) &&
    productionCompose.includes(
      'STORAGE_S3_CUSTOMER_KEY_BASE64_FILE: /run/secrets/spaces_backup_s3_customer_key',
    ),
  'Dedicated encrypted database-backup secret wiring is incomplete',
);
const backupSection = productionCompose
  .split(/\n  database-backup:\s*\n/, 2)[1]
  ?.split(/\n  nginx:\s*\n/, 1)[0];
assert(backupSection, 'Encrypted database-backup service is missing');
assert(
  !/(spaces_s3_access_key_id|spaces_s3_secret_access_key|spaces_s3_customer_key|privacy_export_encryption_key)/i.test(
    backupSection,
  ),
  'Database backups must use credentials and an encryption key separate from application storage',
);
assert(
  /^STORAGE_DRIVER=s3$/m.test(productionEnvExample) &&
    /^STORAGE_S3_PROVIDER=digitalocean_spaces$/m.test(productionEnvExample) &&
    /^STORAGE_S3_ENDPOINT=https:\/\/fra1\.digitaloceanspaces\.com$/m.test(productionEnvExample) &&
    /^STORAGE_S3_REGION=fra1$/m.test(productionEnvExample) &&
    /^STORAGE_S3_FORCE_PATH_STYLE=false$/m.test(productionEnvExample) &&
    /^STORAGE_S3_SERVER_SIDE_ENCRYPTION=SSE-C$/m.test(productionEnvExample) &&
    /^STORAGE_S3_CUSTOMER_KEY_BASE64=$/m.test(productionEnvExample),
  'Production object storage must use private DigitalOcean Spaces in FRA1 with SSE-C',
);
assert(
  digitalOceanTerraform.includes('version = "2.100.0"') &&
    digitalOceanTerraform.includes('default     = "fra1"') &&
    digitalOceanTerraform.includes('default     = "s-4vcpu-8gb"') &&
    digitalOceanTerraform.includes('acl           = "private"') &&
    digitalOceanTerraform.includes('force_destroy = false') &&
    digitalOceanTerraform.includes('noncurrent_version_expiration') &&
    digitalOceanTerraform.includes('days = 35') &&
    digitalOceanTerraform.includes('prevent_destroy = true') &&
    digitalOceanTerraform.includes('source_addresses = var.operator_ssh_cidrs') &&
    digitalOceanCloudInit.includes('for cidr in operator_ssh_cidrs') &&
    !digitalOceanCloudInit.includes('[ufw, allow, OpenSSH]'),
  'DigitalOcean IaC must retain its pinned provider, reviewed size/region, private buckets, and destruction/SSH safeguards',
);
assert(
  /^REALTIME_V2_ENABLED=true$/m.test(productionEnvExample) &&
    /^REALTIME_LEGACY_BROADCAST_ENABLED=false$/m.test(productionEnvExample) &&
    /^REALTIME_POLLING_FALLBACK_ENABLED=false$/m.test(productionEnvExample),
  'Production real-time v2 rollout flags are unsafe',
);
assert(
  /^AI_PIPELINE_ENABLED=true$/m.test(productionEnvExample) &&
    /^AI_SERVER_IMAGE=.+@sha256:/m.test(productionEnvExample) &&
    /^AI_SERVER_SOURCE_COMMIT=[a-f0-9]{40}$/m.test(productionEnvExample) &&
    /^GEE_PROJECT_ID=$/m.test(productionEnvExample) &&
    /^GEE_SERVICE_ACCOUNT=$/m.test(productionEnvExample) &&
    /^GEE_ASSET_FOLDER=$/m.test(productionEnvExample),
  'Production AI must be enabled and configured with an immutable image digest',
);
const aiServerSection = productionCompose
  .split(/\n  ai-server:\s*\n/, 2)[1]
  ?.split(/\n  workload-worker:\s*\n/, 1)[0];
assert(aiServerSection, 'Hardened production AI service is missing');
assert(
  aiServerSection.includes('image: ${AI_SERVER_IMAGE:') &&
    aiServerSection.includes('profiles: ["ai-local"]') &&
    aiServerSection.includes('AI_DRY_RUN: "false"') &&
    aiServerSection.includes('GEE_PRIVATE_KEY_PATH: /run/secrets/gee_service_account') &&
    aiServerSection.includes('AI_INTERNAL_API_SECRET') &&
    aiServerSection.includes('GEE_PROJECT_ID is required for the ai-local profile') &&
    aiServerSection.includes('read_only: true') &&
    aiServerSection.includes('no-new-privileges:true') &&
    !/^\s*ports:/m.test(aiServerSection),
  'Production AI image, secret, network or container hardening is incomplete',
);
assert(
  apiEntrypoint.includes('load_secret_var AI_INTERNAL_API_SECRET') &&
    productionCompose.includes(
      'AI_INTERNAL_API_SECRET_FILE: /run/secrets/ai_internal_api_secret',
    ) &&
    productionCompose.includes('ai_internal_api_secret:'),
  'AI internal service secret-file wiring is incomplete',
);
assert(
  productionCompose.includes(
    'FIREBASE_SERVICE_ACCOUNT_PATH: /run/secrets/firebase_service_account',
  ) && productionCompose.includes('firebase_service_account:'),
  'Firebase service-account secret wiring is incomplete',
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
const alloyConfig = read(path.join(observabilityPath, 'config.alloy'));
assert(
  alloyConfig.includes('local.file_match') &&
    alloyConfig.includes('loki.source.file') &&
    !/(discovery\.docker|prometheus\.exporter\.cadvisor|docker\.sock)/.test(
      alloyConfig,
    ),
  'Alloy must remain on file-based log collection without Docker discovery or cAdvisor',
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
  AI_SERVER_IMAGE:
    'registry.example.invalid/terraleb-ai@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  GEE_PROJECT_ID: 'terraleb-production',
  GEE_SERVICE_ACCOUNT: 'terraleb-ai@example.invalid',
  GEE_ASSET_FOLDER: 'projects/terraleb-production/assets/terraleb',
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
  'AI_INTERNAL_API_SECRET',
  'PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64',
  'VERIFICATION_HMAC_SECRET',
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
    'gis-phase6-alloy-audit:local',
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
  [images.alloy, 'infra/alloy/Dockerfile.production'],
]) {
  try {
    dockerRun(['image', 'inspect', image], { stdio: 'ignore' });
  } catch {
    dockerRun(
      ['build', '--tag', image, '--file', dockerfile, context],
      { timeout: 1800000 },
    );
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
      '--entrypoint',
      '/bin/sh',
      images.alloy,
      '-c',
      'test ! -e /usr/bin/mount && test ! -e /usr/bin/umount',
    ]);
    dockerRun([...common, images.alloy, '--version']);
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
