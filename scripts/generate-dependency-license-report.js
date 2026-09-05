"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { fileURLToPath } = require("node:url");

function sha256(contents) {
  return crypto.createHash("sha256").update(contents).digest("hex");
}

function normalizeLicense(value) {
  if (typeof value === "string" && value.trim()) return value.trim();
  if (Array.isArray(value)) {
    const identifiers = value.map(normalizeLicense).filter(Boolean);
    return identifiers.length > 0 ? identifiers.join(" OR ") : null;
  }
  if (value && typeof value === "object") {
    return normalizeLicense(value.type ?? value.name);
  }
  return null;
}

function packageNameFromLockPath(lockPath) {
  const marker = "node_modules/";
  const index = lockPath.lastIndexOf(marker);
  return index >= 0 ? lockPath.slice(index + marker.length) : lockPath;
}

function installedNpmLicense(installedRoot, lockPath) {
  if (!installedRoot || !lockPath) return null;
  const packageJsonPath = path.join(installedRoot, ...lockPath.split("/"), "package.json");
  if (!fs.existsSync(packageJsonPath)) return null;
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
  return normalizeLicense(packageJson.license ?? packageJson.licenses);
}

function collectNpmPackages(lock, options = {}) {
  const packages = [];
  for (const [lockPath, metadata] of Object.entries(lock.packages ?? {})) {
    if (!lockPath || metadata.dev === true) continue;
    const name = metadata.name ?? packageNameFromLockPath(lockPath);
    if (!name || !metadata.version) continue;
    const license =
      normalizeLicense(metadata.license) ?? installedNpmLicense(options.installedRoot, lockPath);
    packages.push({
      name,
      version: String(metadata.version),
      license,
      reviewStatus: license ? "review_required" : "missing_license_metadata",
    });
  }
  return packages.sort((left, right) =>
    `${left.name}@${left.version}`.localeCompare(`${right.name}@${right.version}`),
  );
}

function licenseFileFor(packageRoot) {
  const candidates = fs
    .readdirSync(packageRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .filter((name) => /^(licen[cs]e|copying|notice)(\.|$)/i.test(name))
    .sort((left, right) => left.localeCompare(right));
  return candidates[0] ?? null;
}

function flutterLicenseEvidence(packageRoot) {
  const localLicense = licenseFileFor(packageRoot);
  if (localLicense) {
    return {
      label: localLicense,
      contents: fs.readFileSync(path.join(packageRoot, localLicense)),
    };
  }

  const packageParent = path.dirname(packageRoot);
  if (path.basename(packageParent).toLowerCase() !== "packages") return null;
  const sdkRoot = path.dirname(packageParent);
  const sdkLicense = licenseFileFor(sdkRoot);
  if (!sdkLicense) return null;
  return {
    label: `Flutter SDK ${sdkLicense}`,
    contents: fs.readFileSync(path.join(sdkRoot, sdkLicense)),
  };
}

function pubVersion(packageRoot) {
  const pubspecPath = path.join(packageRoot, "pubspec.yaml");
  const pubspec = fs.readFileSync(pubspecPath, "utf8");
  return pubspec.match(/^version:\s*([^\s#]+)/m)?.[1] ?? "unknown";
}

function collectFlutterPackages(packageConfig, applicationPackageName) {
  const packages = [];
  for (const entry of packageConfig.packages ?? []) {
    if (entry.name === applicationPackageName) continue;
    const packageRoot = fileURLToPath(new URL(entry.rootUri));
    const licenseEvidence = flutterLicenseEvidence(packageRoot);
    packages.push({
      name: entry.name,
      version: pubVersion(packageRoot),
      licenseFile: licenseEvidence?.label ?? null,
      licenseSha256: licenseEvidence ? sha256(licenseEvidence.contents) : null,
      reviewStatus: licenseEvidence ? "review_required" : "missing_license_file",
    });
  }
  return packages.sort((left, right) =>
    `${left.name}@${left.version}`.localeCompare(`${right.name}@${right.version}`),
  );
}

function createReport({ repositoryRoot, generatedAt = new Date().toISOString() }) {
  const npmLock = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, "apps", "api", "package-lock.json"), "utf8"),
  );
  const flutterConfig = JSON.parse(
    fs.readFileSync(
      path.join(repositoryRoot, "apps", "mobile", ".dart_tool", "package_config.json"),
      "utf8",
    ),
  );
  const npmPackages = collectNpmPackages(npmLock, {
    installedRoot: path.join(repositoryRoot, "apps", "api"),
  });
  const flutterPackages = collectFlutterPackages(flutterConfig, "lebanese_gis_mobile");
  return {
    schemaVersion: 1,
    generatedAt,
    sourceCommit: process.env.SOURCE_COMMIT?.trim() || "working-tree",
    reviewStatus: "owner_review_required",
    warning:
      "This inventory is evidence for license review; generation does not establish license compatibility or legal compliance.",
    npmProduction: {
      packageCount: npmPackages.length,
      unresolvedCount: npmPackages.filter((item) => !item.license).length,
      packages: npmPackages,
    },
    flutterResolved: {
      packageCount: flutterPackages.length,
      unresolvedCount: flutterPackages.filter((item) => !item.licenseFile).length,
      packages: flutterPackages,
    },
  };
}

function outputPathFrom(argv) {
  const index = argv.indexOf("--output");
  if (index < 0 || !argv[index + 1]) {
    throw new Error("Usage: node scripts/generate-dependency-license-report.js --output <path>");
  }
  return path.resolve(argv[index + 1]);
}

if (require.main === module) {
  const repositoryRoot = path.resolve(__dirname, "..");
  const outputPath = outputPathFrom(process.argv.slice(2));
  const report = createReport({ repositoryRoot });
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`, { flag: "wx" });
  process.stdout.write(
    `Dependency license inventory created: npm=${report.npmProduction.packageCount}, flutter=${report.flutterResolved.packageCount}, unresolved=${report.npmProduction.unresolvedCount + report.flutterResolved.unresolvedCount}\n`,
  );
}

module.exports = {
  collectFlutterPackages,
  collectNpmPackages,
  createReport,
  normalizeLicense,
  outputPathFrom,
};
