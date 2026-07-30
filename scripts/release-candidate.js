"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const TAG_PATTERN =
  /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.([1-9]\d*)$/;
const COMMIT_PATTERN = /^[0-9a-f]{40}$/i;
const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/i;
const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const APPLICATION_ID_PATTERN =
  /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*){2,}$/;

function invariant(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function requiredString(value, name) {
  invariant(
    typeof value === "string" && value.trim().length > 0,
    `${name} is required.`,
  );
  return value.trim();
}

function validateReleaseTag(value) {
  const tag = requiredString(value, "RELEASE_TAG");
  invariant(
    TAG_PATTERN.test(tag),
    "RELEASE_TAG must match vMAJOR.MINOR.PATCH-rc.NUMBER.",
  );
  return tag;
}

function validateApplicationId(value) {
  const applicationId = requiredString(value, "ANDROID_APPLICATION_ID");
  invariant(
    APPLICATION_ID_PATTERN.test(applicationId),
    "ANDROID_APPLICATION_ID must be a valid reverse-DNS identifier.",
  );
  invariant(
    !applicationId.toLowerCase().startsWith("com.example"),
    "ANDROID_APPLICATION_ID must not use the com.example placeholder.",
  );
  return applicationId;
}

function validateHttpsUrl(value, name = "RC_API_BASE_URL") {
  const raw = requiredString(value, name);
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`${name} must be a valid URL.`);
  }
  invariant(url.protocol === "https:", `${name} must use HTTPS.`);
  invariant(
    !url.username && !url.password,
    `${name} must not contain credentials.`,
  );
  const hostname = url.hostname.toLowerCase();
  invariant(
    hostname !== "localhost" &&
      hostname !== "127.0.0.1" &&
      hostname !== "[::1]" &&
      hostname !== "::1" &&
      !hostname.endsWith(".localhost") &&
      !hostname.endsWith(".example") &&
      !hostname.endsWith(".invalid") &&
      !hostname.endsWith(".test") &&
      !/(^|\.)example\.(com|net|org)$/.test(hostname),
    `${name} must not use a local or reserved hostname.`,
  );
  invariant(
    !raw.includes("<") &&
      !raw.includes(">") &&
      !raw.toLowerCase().includes("replace"),
    `${name} contains a placeholder.`,
  );
  return url.toString().replace(/\/$/, "");
}

function validatePositiveInteger(value, name) {
  const parsed = Number(value);
  invariant(
    Number.isSafeInteger(parsed) && parsed > 0,
    `${name} must be a positive integer.`,
  );
  return parsed;
}

function validateGoogleServicesConfiguration(configuration, applicationId) {
  const expectedApplicationId = validateApplicationId(applicationId);
  invariant(
    configuration && Array.isArray(configuration.client),
    "Google Services configuration must contain a client array.",
  );
  const configuredIds = configuration.client
    .map((client) => client?.client_info?.android_client_info?.package_name)
    .filter((value) => typeof value === "string");
  invariant(
    configuredIds.includes(expectedApplicationId),
    "Google Services configuration does not match ANDROID_APPLICATION_ID.",
  );
  return true;
}

function validatePrebuildInputs(input) {
  const tag = validateReleaseTag(input.RELEASE_TAG);
  const sourceCommit = requiredString(input.SOURCE_COMMIT, "SOURCE_COMMIT");
  invariant(
    COMMIT_PATTERN.test(sourceCommit),
    "SOURCE_COMMIT must be a 40-character Git SHA.",
  );

  const sourceDate = new Date(requiredString(input.SOURCE_DATE, "SOURCE_DATE"));
  invariant(
    !Number.isNaN(sourceDate.valueOf()),
    "SOURCE_DATE must be a valid date.",
  );

  const repository = requiredString(input.REPOSITORY, "REPOSITORY");
  invariant(
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository),
    "REPOSITORY must use owner/name format.",
  );

  return {
    tag,
    version: tag.slice(1),
    sourceCommit: sourceCommit.toLowerCase(),
    sourceDate: sourceDate.toISOString(),
    repository,
    apiBaseUrl: validateHttpsUrl(input.RC_API_BASE_URL),
    androidApplicationId: validateApplicationId(input.ANDROID_APPLICATION_ID),
    androidVersionCode: validatePositiveInteger(
      input.ANDROID_VERSION_CODE,
      "ANDROID_VERSION_CODE",
    ),
  };
}

function validateReleaseInputs(input) {
  const metadata = validatePrebuildInputs(input);
  const apiImage = requiredString(input.API_IMAGE, "API_IMAGE").toLowerCase();
  invariant(
    /^ghcr\.io\/[a-z0-9_.-]+\/[a-z0-9_./-]+$/.test(apiImage),
    "API_IMAGE must be a lowercase GHCR image name without a tag.",
  );

  const apiImageDigest = requiredString(
    input.API_IMAGE_DIGEST,
    "API_IMAGE_DIGEST",
  );
  invariant(
    DIGEST_PATTERN.test(apiImageDigest),
    "API_IMAGE_DIGEST must be a SHA-256 digest.",
  );

  return {
    ...metadata,
    apiImage,
    apiImageDigest: apiImageDigest.toLowerCase(),
  };
}

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function listArtifactFiles(directory, excludedPaths) {
  const files = [];

  function visit(current) {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      const relative = path
        .relative(directory, absolute)
        .split(path.sep)
        .join("/");
      invariant(
        !entry.isSymbolicLink(),
        `Release artifact must not be a symlink: ${relative}`,
      );
      invariant(
        !relative.includes("\n") && !relative.includes("\r"),
        "Release artifact paths must not contain line breaks.",
      );
      if (entry.isDirectory()) {
        visit(absolute);
      } else if (entry.isFile() && !excludedPaths.has(path.resolve(absolute))) {
        files.push({ absolute, relative });
      }
    }
  }

  visit(directory);
  return files.sort((left, right) =>
    left.relative.localeCompare(right.relative),
  );
}

function createManifest(input, artifactDirectory, manifestPath, checksumsPath) {
  const metadata = validateReleaseInputs(input);
  const resolvedDirectory = path.resolve(artifactDirectory);
  const resolvedManifest = path.resolve(manifestPath);
  const resolvedChecksums = path.resolve(checksumsPath);

  invariant(
    fs.statSync(resolvedDirectory).isDirectory(),
    "Artifact directory is required.",
  );
  invariant(
    path.dirname(resolvedManifest) === resolvedDirectory,
    "Manifest must be written directly inside the artifact directory.",
  );
  invariant(
    path.dirname(resolvedChecksums) === resolvedDirectory,
    "Checksums must be written directly inside the artifact directory.",
  );

  const excluded = new Set([resolvedManifest, resolvedChecksums]);
  const artifactFiles = listArtifactFiles(resolvedDirectory, excluded);
  invariant(
    artifactFiles.length > 0,
    "At least one release artifact is required.",
  );
  const migrationDirectory = path.join(ROOT, "infra", "migrations");
  const migrationFiles = listArtifactFiles(migrationDirectory, new Set());

  const manifest = {
    schemaVersion: 1,
    candidate: metadata,
    deployment: {
      authorizedTarget: "staging-only",
      productionAuthorized: false,
      apiImageReference: `${metadata.apiImage}@${metadata.apiImageDigest}`,
      runtimeDefines: {
        appFlavor: "staging",
        apiBaseUrl: metadata.apiBaseUrl,
        useMockAuth: false,
        useMockData: false,
      },
      databaseMigrations: migrationFiles.map(({ absolute, relative }) => ({
        path: `infra/migrations/${relative}`,
        bytes: fs.statSync(absolute).size,
        sha256: sha256File(absolute),
      })),
    },
    artifacts: artifactFiles.map(({ absolute, relative }) => ({
      path: relative,
      bytes: fs.statSync(absolute).size,
      sha256: sha256File(absolute),
    })),
  };

  fs.writeFileSync(resolvedManifest, `${JSON.stringify(manifest, null, 2)}\n`, {
    encoding: "utf8",
    flag: "w",
  });

  const checksummedFiles = [
    ...artifactFiles,
    {
      absolute: resolvedManifest,
      relative: path
        .relative(resolvedDirectory, resolvedManifest)
        .split(path.sep)
        .join("/"),
    },
  ].sort((left, right) => left.relative.localeCompare(right.relative));

  fs.writeFileSync(
    resolvedChecksums,
    `${checksummedFiles
      .map(({ absolute, relative }) => `${sha256File(absolute)}  ${relative}`)
      .join("\n")}\n`,
    { encoding: "utf8", flag: "w" },
  );

  return manifest;
}

function validateSha256(value, name) {
  invariant(
    SHA256_PATTERN.test(requiredString(value, name)),
    `${name} must be a SHA-256 hash.`,
  );
}

function validateCompletedEvidence(evidence) {
  invariant(
    evidence && evidence.schemaVersion === 1,
    "Unsupported Phase 7 evidence schema.",
  );
  invariant(
    evidence.status === "complete",
    "Phase 7 evidence status must be complete.",
  );

  const candidate = evidence.candidate || {};
  validateReleaseTag(candidate.tag);
  invariant(
    COMMIT_PATTERN.test(
      requiredString(candidate.sourceCommit, "candidate.sourceCommit"),
    ),
    "candidate.sourceCommit must be a 40-character Git SHA.",
  );
  validateSha256(candidate.manifestSha256, "candidate.manifestSha256");
  requiredString(candidate.apiImage, "candidate.apiImage");
  invariant(
    DIGEST_PATTERN.test(
      requiredString(candidate.apiImageDigest, "candidate.apiImageDigest"),
    ),
    "candidate.apiImageDigest must be a SHA-256 digest.",
  );
  validateApplicationId(candidate.androidApplicationId);
  validateSha256(candidate.androidAabSha256, "candidate.androidAabSha256");
  validateSha256(candidate.webBundleSha256, "candidate.webBundleSha256");

  const approvals = evidence.approvals || {};
  invariant(
    approvals.stagingChangeApproved === true,
    "Staging change approval is required.",
  );
  invariant(approvals.pilotApproved === true, "Pilot approval is required.");
  requiredString(approvals.releaseOwner, "approvals.releaseOwner");
  requiredString(approvals.securityReviewer, "approvals.securityReviewer");
  requiredString(approvals.operationsOwner, "approvals.operationsOwner");

  const staging = evidence.staging || {};
  validateHttpsUrl(staging.baseUrl, "staging.baseUrl");
  for (const field of [
    "dnsTlsVerified",
    "privateStorageVerified",
    "scannerVerified",
    "valkeyVerified",
    "pushNotificationsVerified",
    "alertDeliveryVerified",
    "deployedDigestMatchesManifest",
    "smokeTestsPassed",
  ]) {
    invariant(staging[field] === true, `staging.${field} must be true.`);
  }

  const restore = evidence.backupRestore || {};
  invariant(
    restore.offServerBackupVerified === true,
    "Off-server backup evidence is required.",
  );
  invariant(
    restore.restoreExercisePassed === true,
    "Restore exercise must pass.",
  );
  const sourceRows = validatePositiveInteger(
    restore.sourceRowCount,
    "backupRestore.sourceRowCount",
  );
  const restoredRows = validatePositiveInteger(
    restore.restoredRowCount,
    "backupRestore.restoredRowCount",
  );
  invariant(
    sourceRows === restoredRows,
    "Restored row count must match the source.",
  );
  invariant(restore.checksumMatched === true, "Restore checksum must match.");
  validateHttpsUrl(restore.evidenceUrl, "backupRestore.evidenceUrl");

  const devices = evidence.devices || {};
  invariant(
    devices.androidPhysicalDevicePassed === true,
    "A physical Android device release-candidate test is required.",
  );
  requiredString(devices.androidDeviceModel, "devices.androidDeviceModel");
  requiredString(devices.androidOsVersion, "devices.androidOsVersion");
  invariant(
    typeof devices.appleReleaseInScope === "boolean",
    "devices.appleReleaseInScope must explicitly record Apple scope.",
  );
  if (devices.appleReleaseInScope) {
    invariant(
      devices.macosIosValidationPassed === true,
      "macOS/iOS validation is required when Apple release is in scope.",
    );
    requiredString(devices.appleDeviceModel, "devices.appleDeviceModel");
    requiredString(devices.appleOsVersion, "devices.appleOsVersion");
  }

  const soak = evidence.soak || {};
  const approvedHours = validatePositiveInteger(
    soak.approvedDurationHours,
    "soak.approvedDurationHours",
  );
  const actualHours = validatePositiveInteger(
    soak.durationHours,
    "soak.durationHours",
  );
  invariant(
    actualHours >= approvedHours,
    "Soak duration is shorter than the approved duration.",
  );
  const startedAt = new Date(requiredString(soak.startedAt, "soak.startedAt"));
  const endedAt = new Date(requiredString(soak.endedAt, "soak.endedAt"));
  invariant(
    !Number.isNaN(startedAt.valueOf()) &&
      !Number.isNaN(endedAt.valueOf()) &&
      endedAt > startedAt,
    "Soak timestamps are invalid.",
  );
  const elapsedHours = (endedAt.valueOf() - startedAt.valueOf()) / 3_600_000;
  invariant(
    elapsedHours >= approvedHours && elapsedHours >= actualHours,
    "Soak timestamps do not cover the recorded duration.",
  );
  invariant(soak.criticalAlerts === 0, "Soak critical alerts must be zero.");
  invariant(
    soak.unresolvedHighAlerts === 0,
    "Soak unresolved high alerts must be zero.",
  );
  invariant(
    soak.dataIntegrityChecksPassed === true,
    "Soak data-integrity checks must pass.",
  );
  invariant(
    soak.scannerFailurePolicyExercised === true,
    "Scanner failure policy must be exercised in staging.",
  );
  invariant(
    soak.valkeyOutagePolicyExercised === true,
    "Valkey outage policy must be exercised in staging.",
  );

  const rollback = evidence.rollback || {};
  invariant(rollback.rehearsed === true, "Rollback must be rehearsed.");
  invariant(
    rollback.candidateDigestUsed === candidate.apiImageDigest,
    "Rollback rehearsal must use the candidate digest.",
  );
  invariant(
    DIGEST_PATTERN.test(
      requiredString(
        rollback.previousDigestRestored,
        "rollback.previousDigestRestored",
      ),
    ),
    "rollback.previousDigestRestored must be a SHA-256 digest.",
  );
  invariant(
    rollback.databaseRollbackDecisionRecorded === true,
    "Database rollback decision must be recorded.",
  );
  invariant(
    rollback.dataLossDetected === false,
    "Rollback must not show data loss.",
  );
  validatePositiveInteger(
    rollback.recoveryTimeMinutes,
    "rollback.recoveryTimeMinutes",
  );
  validateHttpsUrl(rollback.evidenceUrl, "rollback.evidenceUrl");

  const pilot = evidence.pilot || {};
  const authorizedUsers = validatePositiveInteger(
    pilot.authorizedUserCount,
    "pilot.authorizedUserCount",
  );
  const completedUsers = validatePositiveInteger(
    pilot.completedUserCount,
    "pilot.completedUserCount",
  );
  invariant(
    completedUsers <= authorizedUsers,
    "Pilot completions exceed authorized users.",
  );
  invariant(
    pilot.criticalDefects === 0,
    "Pilot critical defects must be zero.",
  );
  invariant(
    pilot.unresolvedHighDefects === 0,
    "Pilot unresolved high defects must be zero.",
  );
  invariant(
    pilot.dataIntegrityDiffs === 0,
    "Pilot data-integrity differences must be zero.",
  );
  requiredString(pilot.ownerSignoff, "pilot.ownerSignoff");
  validateHttpsUrl(pilot.evidenceUrl, "pilot.evidenceUrl");

  return true;
}

function verifyContract(root = ROOT) {
  const workflowPath = path.join(
    root,
    ".github",
    "workflows",
    "release-candidate.yml",
  );
  const gradlePath = path.join(
    root,
    "apps",
    "mobile",
    "android",
    "app",
    "build.gradle.kts",
  );
  const dockerfilePath = path.join(root, "apps", "api", "Dockerfile");
  const evidencePath = path.join(
    root,
    "release",
    "evidence",
    "phase-7-evidence.template.json",
  );
  const tagRulesetPath = path.join(
    root,
    "release",
    "policy",
    "rc-tag-ruleset.json",
  );
  const documentationPath = path.join(
    root,
    "docs",
    "predeployment",
    "phase-7-release-candidate-pilot.md",
  );

  for (const requiredPath of [
    workflowPath,
    gradlePath,
    dockerfilePath,
    evidencePath,
    tagRulesetPath,
    documentationPath,
  ]) {
    invariant(
      fs.existsSync(requiredPath) && fs.statSync(requiredPath).isFile(),
      `Missing release-candidate contract file: ${requiredPath}`,
    );
  }

  const workflow = fs.readFileSync(workflowPath, "utf8");
  const actionReferences = [
    ...workflow.matchAll(/^\s*uses:\s*([^#\s]+)\s*$/gm),
  ].map((match) => match[1]);
  invariant(
    actionReferences.length > 0,
    "Release-candidate workflow must use pinned actions.",
  );
  for (const reference of actionReferences) {
    if (reference.startsWith("./") || reference.startsWith("docker://")) {
      continue;
    }
    invariant(
      /@[0-9a-f]{40}$/i.test(reference),
      `Workflow action is not pinned to a full commit SHA: ${reference}`,
    );
  }
  for (const requiredText of [
    "refs/tags/",
    "environment: release-candidate",
    "attestations: write",
    "id-token: write",
    "packages: write",
    "ANDROID_GOOGLE_SERVICES_JSON_BASE64",
    'flutter-version: "3.41.2"',
    "actions/attest@508db95dd578ae2727ebd6217d5ba78e4fbda05d",
    "ghcr.io/aquasecurity/trivy:0.72.0@sha256:cffe3f5161a47a6823fbd23d985795b3ed72a4c806da4c4df16266c02accdd6f",
    "node scripts/release-candidate.js create-manifest",
    "node scripts/release-candidate.js verify-google-services",
    "docker manifest inspect",
  ]) {
    invariant(
      workflow.includes(requiredText),
      `Workflow contract missing: ${requiredText}`,
    );
  }
  invariant(
    !workflow.includes("pull_request_target"),
    "Release-candidate workflow must not use pull_request_target.",
  );

  const gradle = fs.readFileSync(gradlePath, "utf8");
  invariant(
    !gradle.includes('signingConfig = signingConfigs.getByName("debug")'),
    "Android release build must never use debug signing.",
  );
  for (const name of [
    "TERRALEB_APPLICATION_ID",
    "TERRALEB_KEYSTORE_PATH",
    "TERRALEB_KEYSTORE_PASSWORD",
    "TERRALEB_KEY_ALIAS",
    "TERRALEB_KEY_PASSWORD",
    "google-services.json",
  ]) {
    invariant(
      gradle.includes(name),
      `Android release contract missing ${name}.`,
    );
  }

  const dockerfile = fs.readFileSync(dockerfilePath, "utf8");
  for (const label of [
    "org.opencontainers.image.source",
    "org.opencontainers.image.version",
    "org.opencontainers.image.revision",
  ]) {
    invariant(
      dockerfile.includes(label),
      `API image metadata missing ${label}.`,
    );
  }

  const template = JSON.parse(fs.readFileSync(evidencePath, "utf8"));
  invariant(
    template.status === "blocked",
    "Evidence template must default to blocked.",
  );
  invariant(
    template.rollback && template.rollback.dataLossDetected === true,
    "Evidence template must fail closed on rollback data loss.",
  );

  const tagRuleset = JSON.parse(fs.readFileSync(tagRulesetPath, "utf8"));
  invariant(tagRuleset.target === "tag", "RC ruleset must target tags.");
  invariant(tagRuleset.enforcement === "active", "RC ruleset must be active.");
  invariant(
    tagRuleset.conditions?.ref_name?.include?.includes("refs/tags/v*.*.*-rc.*"),
    "RC ruleset must target release-candidate tags.",
  );
  const tagRuleTypes = new Set(
    (tagRuleset.rules || []).map((rule) => rule.type),
  );
  invariant(
    tagRuleTypes.has("update") && tagRuleTypes.has("deletion"),
    "RC ruleset must prevent tag updates and deletion.",
  );
  invariant(
    !tagRuleTypes.has("creation"),
    "RC ruleset must allow initial candidate-tag creation.",
  );

  const documentation = fs.readFileSync(documentationPath, "utf8");
  invariant(
    documentation.includes("Phase 8 is not authorized"),
    "Phase 7 documentation must state the Phase 8 authorization gate.",
  );

  return true;
}

function argumentValue(args, name) {
  const index = args.indexOf(name);
  invariant(index !== -1 && index + 1 < args.length, `${name} is required.`);
  return args[index + 1];
}

function runCli(argv = process.argv.slice(2)) {
  const command = argv[0];
  if (command === "verify-contract") {
    verifyContract();
    process.stdout.write("Phase 7 release-candidate contract verified.\n");
    return;
  }
  if (command === "verify-prebuild") {
    validatePrebuildInputs(process.env);
    process.stdout.write("Protected release-candidate inputs verified.\n");
    return;
  }
  if (command === "verify-google-services") {
    const configurationPath = path.resolve(argumentValue(argv, "--file"));
    const configuration = JSON.parse(
      fs.readFileSync(configurationPath, "utf8"),
    );
    validateGoogleServicesConfiguration(
      configuration,
      process.env.ANDROID_APPLICATION_ID,
    );
    process.stdout.write("Android Google Services application ID verified.\n");
    return;
  }
  if (command === "verify-evidence") {
    const evidencePath = path.resolve(argumentValue(argv, "--file"));
    const evidence = JSON.parse(fs.readFileSync(evidencePath, "utf8"));
    validateCompletedEvidence(evidence);
    process.stdout.write(
      `Completed Phase 7 evidence verified: ${evidencePath}\n`,
    );
    return;
  }
  if (command === "create-manifest") {
    const artifactDirectory = path.resolve(
      argumentValue(argv, "--artifact-dir"),
    );
    const manifestPath = path.join(artifactDirectory, "release-manifest.json");
    const checksumsPath = path.join(artifactDirectory, "SHA256SUMS");
    createManifest(process.env, artifactDirectory, manifestPath, checksumsPath);
    process.stdout.write(`Release manifest created: ${manifestPath}\n`);
    return;
  }
  throw new Error(
    "Usage: release-candidate.js verify-contract | verify-prebuild | " +
      "verify-google-services --file PATH | verify-evidence --file PATH | " +
      "create-manifest --artifact-dir PATH",
  );
}

if (require.main === module) {
  try {
    runCli();
  } catch (error) {
    process.stderr.write(`Release-candidate gate failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  createManifest,
  validateApplicationId,
  validateCompletedEvidence,
  validateGoogleServicesConfiguration,
  validateHttpsUrl,
  validatePrebuildInputs,
  validateReleaseInputs,
  validateReleaseTag,
  verifyContract,
};
