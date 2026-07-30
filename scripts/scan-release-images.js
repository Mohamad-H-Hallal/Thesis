#!/usr/bin/env node

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const trivyImage =
  'ghcr.io/aquasecurity/trivy:0.72.0@sha256:cffe3f5161a47a6823fbd23d985795b3ed72a4c806da4c4df16266c02accdd6f';
const trivyTemplate =
  '{{- range . }}{{ $target := .Target }}{{- range .Vulnerabilities }}{{ .Severity }}|{{ .VulnerabilityID }}|{{ .PkgName }}|{{ .InstalledVersion }}|{{ .FixedVersion }}|{{ $target }}{{ "\\n" }}{{- end }}{{- end }}';
const apiImage = process.env.RELEASE_API_IMAGE || 'gis-phase6-api-audit:local';
const databaseImage =
  process.env.RELEASE_DATABASE_IMAGE || 'gis-phase6-postgis-audit:local';
const certbotImage =
  process.env.RELEASE_CERTBOT_IMAGE || 'gis-phase6-certbot-audit:local';
const prometheusImage =
  process.env.RELEASE_PROMETHEUS_IMAGE || 'gis-phase6-prometheus-audit:local';
const alertmanagerImage =
  process.env.RELEASE_ALERTMANAGER_IMAGE ||
  'gis-phase6-alertmanager-audit:local';
const blackboxImage =
  process.env.RELEASE_BLACKBOX_IMAGE || 'gis-phase6-blackbox-audit:local';
const lokiImage =
  process.env.RELEASE_LOKI_IMAGE || 'gis-phase6-loki-audit:local';
const alloyImage =
  process.env.RELEASE_ALLOY_IMAGE || 'gis-phase6-alloy-audit:local';
const alloyVexPath = path.join(root, 'infra', 'alloy', 'alloy.openvex.json');
const alloyMediumPolicy = JSON.parse(
  fs.readFileSync(
    path.join(root, 'infra', 'alloy', 'alloy.medium-risk-acceptance.json'),
    'utf8',
  ),
);
const expectedAlloyFindings = [
  'CVE-2026-34040|github.com/docker/docker|v28.5.2+incompatible',
  'CVE-2026-41567|github.com/docker/docker|v28.5.2+incompatible',
  'CVE-2026-42306|github.com/docker/docker|v28.5.2+incompatible',
];
const expectedAlloyMediumFindings = alloyMediumPolicy.findings.map(
  ({ id, package: packageName, installedVersion }) =>
    `${id}|${packageName}|${installedVersion}`,
);
const pullBeforeScan = process.argv.includes('--pull');
const onlyApi = process.argv.includes('--only-api');
const onlyDatabase = process.argv.includes('--only-database');
const onlyCertbot = process.argv.includes('--only-certbot');
const onlyPrometheus = process.argv.includes('--only-prometheus');
const onlyAlertmanager = process.argv.includes('--only-alertmanager');
const onlyBlackbox = process.argv.includes('--only-blackbox');
const onlyLoki = process.argv.includes('--only-loki');
const onlyAlloy = process.argv.includes('--only-alloy');
const onlyImageArgument = process.argv.find((argument) =>
  argument.startsWith('--image='),
);
const onlyImage = onlyImageArgument?.slice('--image='.length);
if (
  onlyImage &&
  ![
    apiImage,
    databaseImage,
    certbotImage,
    prometheusImage,
    alertmanagerImage,
    blackboxImage,
    lokiImage,
    alloyImage,
  ].includes(onlyImage) &&
  !/@sha256:[a-f0-9]{64}$/.test(onlyImage)
) {
  throw new Error(`Ad-hoc release scan image is not digest-pinned: ${onlyImage}`);
}

const runDocker = (args, options = {}) =>
  execFileSync('docker', args, {
    cwd: root,
    encoding: 'utf8',
    stdio: options.stdio ?? 'inherit',
    timeout: options.timeout ?? 600000,
  });

const parseTrivyFindings = (output) => {
  if (!output.trim()) {
    return [];
  }
  const findings = [];
  for (const line of output.trim().split(/\r?\n/)) {
    const [severity, id, packageName, installedVersion, fixedVersion, target] =
      line.split('|');
    if (!severity || !id || !packageName || !installedVersion || !target) {
      return null;
    }
    findings.push({
      target,
      id,
      packageName,
      severity,
      installedVersion,
      fixedVersion: fixedVersion || 'unfixed',
    });
  }
  return findings;
};

const printFindings = (findings) => {
  for (const finding of findings) {
    console.error(
      [
        finding.severity,
        finding.id,
        finding.packageName,
        `${finding.installedVersion} -> ${finding.fixedVersion}`,
        finding.target,
      ].join(' | '),
    );
  }
};

const buildTrivyArgs = (
  archivePath,
  cacheDirectory,
  { exitCode = '1', severity = 'CRITICAL,HIGH', vexPath } = {},
) => {
  const args = [
    'run',
    '--rm',
    '--cap-drop',
    'ALL',
    '--security-opt',
    'no-new-privileges',
    '--pids-limit',
    '256',
    '--memory',
    '2g',
    '--volume',
    `${archivePath}:/image.tar:ro`,
    '--volume',
    `${cacheDirectory}:/trivy-cache:rw`,
  ];
  if (vexPath) {
    args.push('--volume', `${vexPath}:/scan.openvex.json:ro`);
  }
  args.push(
    trivyImage,
    'image',
    '--input',
    '/image.tar',
    '--scanners',
    'vuln',
    '--severity',
    severity,
    '--exit-code',
    exitCode,
    '--no-progress',
    '--cache-dir',
    '/trivy-cache',
    '--timeout',
    '10m',
    '--format',
    'template',
    '--template',
    trivyTemplate,
  );
  if (vexPath) {
    args.push('--vex', '/scan.openvex.json');
  }
  return args;
};

const collectArchiveFindings = (
  archivePath,
  cacheDirectory,
  severity = 'CRITICAL,HIGH',
) => {
  const args = buildTrivyArgs(archivePath, cacheDirectory, {
    exitCode: '0',
    severity,
  });
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const output = runDocker(args, { stdio: 'pipe', timeout: 900000 });
      const findings = parseTrivyFindings(output);
      if (findings === null) {
        throw new Error('Trivy returned an unreadable findings report');
      }
      return findings;
    } catch (error) {
      const output = [error?.stdout, error?.stderr, error?.message]
        .filter(Boolean)
        .join('\n');
      const isTransient =
        /unexpected EOF|connection reset|timed? out|temporarily unavailable|\b50[234]\b|failed to download/i.test(
          output,
        );
      if (!isTransient || attempt === 3) {
        throw error;
      }
      console.warn(`Scanner transport failure; retrying raw image scan (${attempt}/3)`);
      Atomics.wait(
        new Int32Array(new SharedArrayBuffer(4)),
        0,
        0,
        attempt * 5000,
      );
    }
  }
  throw new Error('Trivy raw image scan did not complete');
};

const assertExpectedFindings = (findings, expectedFindings, label) => {
  const actual = findings
    .map(
      ({ id, packageName, installedVersion }) =>
        `${id}|${packageName}|${installedVersion}`,
    )
    .sort();
  const expected = [...expectedFindings].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    printFindings(findings);
    throw new Error(
      `${label} changed; expected exactly ${expected.length} reviewed findings`,
    );
  }
  console.log(`${label} match ${expected.length} reviewed records`);
};

const scanArchive = (archivePath, cacheDirectory, vexPath) => {
  const args = buildTrivyArgs(archivePath, cacheDirectory, { vexPath });
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const output = runDocker(args, { stdio: 'pipe', timeout: 900000 });
      const findings = parseTrivyFindings(output);
      if (findings === null) {
        throw new Error('Trivy returned an unreadable JSON report');
      }
      if (findings.length > 0) {
        printFindings(findings);
        throw new Error(`Trivy reported ${findings.length} Critical/High findings`);
      }
      console.log('Trivy Critical/High findings: 0');
      return;
    } catch (error) {
      const output = [error?.stdout, error?.stderr, error?.message]
        .filter(Boolean)
        .join('\n');
      const findings = parseTrivyFindings(error?.stdout ?? '');
      if (findings?.length) {
        printFindings(findings);
        throw new Error(`Trivy reported ${findings.length} Critical/High findings`);
      }
      const isTransient =
        /unexpected EOF|connection reset|timed? out|temporarily unavailable|\b50[234]\b|failed to download/i.test(
          output,
        );
      if (!isTransient || attempt === 3) {
        if (output.trim()) {
          console.error(output.trim());
        }
        throw error;
      }
      console.warn(`Scanner transport failure; retrying image scan (${attempt}/3)`);
      Atomics.wait(
        new Int32Array(new SharedArrayBuffer(4)),
        0,
        0,
        attempt * 5000,
      );
    }
  }
};

const readDeclaredImages = () => {
  const composeFiles = ['compose.prod.yml', 'compose.observability.yml'];
  const images = [];
  for (const relativePath of composeFiles) {
    const content = fs.readFileSync(path.join(root, relativePath), 'utf8');
    for (const line of content.split(/\r?\n/)) {
      const image = line.match(/^\s*image:\s*(\S+)\s*$/)?.[1];
      if (image) {
        if (!/@sha256:[a-f0-9]{64}$/.test(image)) {
          throw new Error(`Release image is not digest-pinned: ${image}`);
        }
        images.push(image);
      }
    }
  }
  return [...new Set(images)];
};

const images = onlyImage
  ? [onlyImage]
  : onlyApi
    ? [apiImage]
    : onlyDatabase
      ? [databaseImage]
      : onlyCertbot
        ? [certbotImage]
        : onlyPrometheus
          ? [prometheusImage]
          : onlyAlertmanager
            ? [alertmanagerImage]
            : onlyBlackbox
              ? [blackboxImage]
              : onlyLoki
                ? [lokiImage]
                : onlyAlloy
                  ? [alloyImage]
                : [
                    apiImage,
                    databaseImage,
                    certbotImage,
                    prometheusImage,
                    alertmanagerImage,
                    blackboxImage,
                    lokiImage,
                    alloyImage,
                    ...readDeclaredImages(),
                  ];
const temporaryDirectory = fs.mkdtempSync(
  path.join(os.tmpdir(), 'gis-release-image-scan-'),
);
const scannerCacheDirectory = path.resolve(
  process.env.RELEASE_SCANNER_CACHE ||
    path.join(os.tmpdir(), 'gis-trivy-release-cache-v0.72.0'),
);
fs.mkdirSync(scannerCacheDirectory, { recursive: true });

try {
  for (const [index, image] of images.entries()) {
    console.log(`[${index + 1}/${images.length}] Scanning ${image}`);
    if (pullBeforeScan && image !== apiImage) {
      runDocker(['pull', image]);
    } else {
      try {
        runDocker(['image', 'inspect', image], { stdio: 'ignore' });
      } catch {
        if (
          [
            apiImage,
            databaseImage,
            certbotImage,
            prometheusImage,
            alertmanagerImage,
            blackboxImage,
            lokiImage,
            alloyImage,
          ].includes(image)
        ) {
          throw new Error(
            `Locally built release image is missing: ${image}. Build it before scanning.`,
          );
        }
        runDocker(['pull', image]);
      }
    }

    const archivePath = path.join(temporaryDirectory, `image-${index}.tar`);
    try {
      runDocker(['save', '--output', archivePath, image]);
      const vexPath = image === alloyImage ? alloyVexPath : undefined;
      if (vexPath) {
        assertExpectedFindings(
          collectArchiveFindings(archivePath, scannerCacheDirectory),
          expectedAlloyFindings,
          'Alloy unsuppressed Critical/High findings',
        );
        assertExpectedFindings(
          collectArchiveFindings(
            archivePath,
            scannerCacheDirectory,
            'MEDIUM',
          ),
          expectedAlloyMediumFindings,
          'Alloy Medium risk inventory',
        );
      }
      scanArchive(archivePath, scannerCacheDirectory, vexPath);
    } finally {
      fs.rmSync(archivePath, { force: true });
    }
  }
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}

console.log(`Release container images scanned with Trivy: ${images.length} PASS`);
