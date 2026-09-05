"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  createManifest,
  validateCompletedEvidence,
  validateGoogleServicesConfiguration,
  validatePrebuildInputs,
  validateReleaseInputs,
  validateReleaseTag,
  verifyContract,
} = require("./release-candidate");

function validInputs(overrides = {}) {
  return {
    RELEASE_TAG: "v1.0.0-rc.1",
    SOURCE_COMMIT: "a".repeat(40),
    SOURCE_DATE: "2026-07-30T12:00:00Z",
    REPOSITORY: "Mohamad-H-Hallal/Thesis",
    API_IMAGE: "ghcr.io/mohamad-h-hallal/thesis-api",
    API_IMAGE_DIGEST: `sha256:${"b".repeat(64)}`,
    RC_API_BASE_URL: "https://staging.terraleb.org",
    ANDROID_APPLICATION_ID: "org.terraleb.mobile",
    MAP_PROVIDER_USER_AGENT: "TerraLeb/1.0 (+https://terraleb.org/legal/important-notices)",
    ANDROID_VERSION_CODE: "1000001",
    ...overrides,
  };
}

function validEvidence() {
  return {
    schemaVersion: 1,
    status: "complete",
    candidate: {
      tag: "v1.0.0-rc.1",
      sourceCommit: "a".repeat(40),
      manifestSha256: "b".repeat(64),
      apiImage: "ghcr.io/mohamad-h-hallal/thesis-api",
      apiImageDigest: `sha256:${"c".repeat(64)}`,
      androidApplicationId: "org.terraleb.mobile",
      androidAabSha256: "d".repeat(64),
      webBundleSha256: "e".repeat(64),
    },
    approvals: {
      stagingChangeApproved: true,
      pilotApproved: true,
      releaseOwner: "release-owner",
      securityReviewer: "security-reviewer",
      operationsOwner: "operations-owner",
    },
    staging: {
      baseUrl: "https://staging.terraleb.org",
      dnsTlsVerified: true,
      privateStorageVerified: true,
      scannerVerified: true,
      valkeyVerified: true,
      pushNotificationsVerified: true,
      alertDeliveryVerified: true,
      deployedDigestMatchesManifest: true,
      smokeTestsPassed: true,
    },
    backupRestore: {
      offServerBackupVerified: true,
      restoreExercisePassed: true,
      sourceRowCount: 1200,
      restoredRowCount: 1200,
      checksumMatched: true,
      evidenceUrl: "https://evidence.terraleb.org/restore/rc-1",
    },
    devices: {
      androidPhysicalDevicePassed: true,
      androidDeviceModel: "Test Android Device",
      androidOsVersion: "16",
      appleReleaseInScope: false,
      macosIosValidationPassed: false,
      appleDeviceModel: "",
      appleOsVersion: "",
    },
    soak: {
      approvedDurationHours: 24,
      startedAt: "2026-08-01T08:00:00Z",
      endedAt: "2026-08-02T08:00:00Z",
      durationHours: 24,
      criticalAlerts: 0,
      unresolvedHighAlerts: 0,
      dataIntegrityChecksPassed: true,
      scannerFailurePolicyExercised: true,
      valkeyOutagePolicyExercised: true,
    },
    rollback: {
      rehearsed: true,
      candidateDigestUsed: `sha256:${"c".repeat(64)}`,
      previousDigestRestored: `sha256:${"f".repeat(64)}`,
      databaseRollbackDecisionRecorded: true,
      dataLossDetected: false,
      recoveryTimeMinutes: 12,
      evidenceUrl: "https://evidence.terraleb.org/rollback/rc-1",
    },
    pilot: {
      authorizedUserCount: 5,
      completedUserCount: 5,
      criticalDefects: 0,
      unresolvedHighDefects: 0,
      dataIntegrityDiffs: 0,
      ownerSignoff: "pilot-owner",
      evidenceUrl: "https://evidence.terraleb.org/pilot/rc-1",
    },
  };
}

test("release tags use the strict annotated-candidate naming contract", () => {
  assert.equal(validateReleaseTag("v2.3.4-rc.5"), "v2.3.4-rc.5");
  for (const invalid of [
    "v2.3.4",
    "2.3.4-rc.1",
    "v2.3.4-rc.0",
    "v02.3.4-rc.1",
    "v2.3.4-beta.1",
  ]) {
    assert.throws(() => validateReleaseTag(invalid), /RELEASE_TAG/);
  }
});

test("release inputs reject placeholder identity and non-HTTPS staging", () => {
  assert.throws(
    () =>
      validateReleaseInputs(
        validInputs({ ANDROID_APPLICATION_ID: "com.example.app" }),
      ),
    /placeholder/,
  );
  assert.throws(
    () =>
      validateReleaseInputs(
        validInputs({ RC_API_BASE_URL: "http://staging.internal" }),
      ),
    /HTTPS/,
  );
  assert.throws(
    () =>
      validateReleaseInputs(
        validInputs({ RC_API_BASE_URL: "https://localhost" }),
      ),
    /local or reserved/,
  );
});

test("prebuild validation does not require an image digest that does not exist yet", () => {
  const inputs = validInputs();
  delete inputs.API_IMAGE;
  delete inputs.API_IMAGE_DIGEST;
  assert.equal(
    validatePrebuildInputs(inputs).androidApplicationId,
    "org.terraleb.mobile",
  );
});

test("Google Services configuration must match the final application ID", () => {
  const configuration = {
    client: [
      {
        client_info: {
          android_client_info: { package_name: "org.terraleb.mobile" },
        },
      },
    ],
  };
  assert.equal(
    validateGoogleServicesConfiguration(configuration, "org.terraleb.mobile"),
    true,
  );
  assert.throws(
    () =>
      validateGoogleServicesConfiguration(
        configuration,
        "org.terraleb.different",
      ),
    /does not match/,
  );
});

test("manifest hashes explicit artifacts and excludes its generated outputs", (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "terraleb-rc-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.writeFileSync(path.join(directory, "mobile.aab"), "signed-aab");
  fs.writeFileSync(path.join(directory, "web.zip"), "web-bundle");

  const manifestPath = path.join(directory, "release-manifest.json");
  const checksumsPath = path.join(directory, "SHA256SUMS");
  const manifest = createManifest(
    validInputs(),
    directory,
    manifestPath,
    checksumsPath,
  );

  assert.deepEqual(
    manifest.artifacts.map((artifact) => artifact.path),
    ["mobile.aab", "web.zip"],
  );
  assert.equal(manifest.deployment.productionAuthorized, false);
  assert.equal(manifest.deployment.authorizedTarget, "staging-only");
  assert.ok(manifest.deployment.databaseMigrations.length > 0);
  assert.ok(
    manifest.artifacts.every((artifact) =>
      /^[0-9a-f]{64}$/.test(artifact.sha256),
    ),
  );
  const checksums = fs.readFileSync(checksumsPath, "utf8");
  assert.match(checksums, /release-manifest\.json/);
  assert.doesNotMatch(checksums, /SHA256SUMS/);
});

test("evidence template fails closed and complete external evidence passes", () => {
  const template = JSON.parse(
    fs.readFileSync(
      path.resolve(
        __dirname,
        "..",
        "release",
        "evidence",
        "phase-7-evidence.template.json",
      ),
      "utf8",
    ),
  );
  assert.throws(
    () => validateCompletedEvidence(template),
    /status must be complete/,
  );
  assert.equal(validateCompletedEvidence(validEvidence()), true);
});

test("completed evidence rejects missing Apple validation when Apple is in scope", () => {
  const evidence = validEvidence();
  evidence.devices.appleReleaseInScope = true;
  assert.throws(
    () => validateCompletedEvidence(evidence),
    /macOS\/iOS validation/,
  );
});

test("completed evidence rejects a shorter-than-approved soak and rollback data loss", () => {
  const shortSoak = validEvidence();
  shortSoak.soak.durationHours = 12;
  assert.throws(() => validateCompletedEvidence(shortSoak), /shorter than/);

  const lossyRollback = validEvidence();
  lossyRollback.rollback.dataLossDetected = true;
  assert.throws(
    () => validateCompletedEvidence(lossyRollback),
    /must not show data loss/,
  );
});

test("completed evidence rejects timestamps that do not cover the claimed soak", () => {
  const evidence = validEvidence();
  evidence.soak.endedAt = "2026-08-01T09:00:00Z";
  assert.throws(
    () => validateCompletedEvidence(evidence),
    /timestamps do not cover/,
  );
});

test("repository release-candidate contract is fail-closed", () => {
  assert.equal(verifyContract(), true);
});
