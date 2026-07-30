# Phase 7 — Release Candidate and Pilot

## Status

Repository enablement is in progress on
`codex/phase-7-release-candidate-pilot`. Phase 7 is not complete. No release
candidate has been tagged, no production system has been changed, and no
external staging or pilot evidence is being inferred from local or synthetic CI
tests.

Phase 8 is not authorized. It can be considered only after a candidate-specific
evidence file passes `node scripts/release-candidate.js verify-evidence` and the
Phase 7 completion PR is green and merged.

## Preserved baseline

- Protected branch: `handover-ready`
- Phase 6 merge: `14923e304719486fdcc8e27713b3214b18a065ad`
- Phase 6 PR: `#13`
- Phases 0–6 are preserved and are not restarted by this work.

## Local repository-enablement evidence

These checks validate the repository controls; they do not replace any external
gate:

- Git integrity passed and the Phase 7 branch began at the exact protected
  Phase 6 merge.
- Active GitHub ruleset `20073091` protects matching RC tags from update or
  deletion with no bypass actor.
- Release-candidate unit/contract tests: `10/10`.
- Workflow YAML parsing, full-SHA action pinning, Prettier, and `git diff
--check`: passed.
- Flutter 3.41.2 analysis: no issues.
- Full Flutter tests: `345/345`; line coverage `50.63%`.
- Android debug APK: built successfully.
- Android release without signing inputs: rejected by the intended fail-closed
  signing gate.
- A disposable local signing-path exercise reached Google Services processing
  and correctly stopped because the ignored workstation configuration belongs
  to the old placeholder application ID. The disposable key was deleted, no
  signed candidate was retained, and the workflow now requires and validates a
  protected configuration matching the final application ID.
- Clean npm installation: 667 packages audited, 0 vulnerabilities. Production
  and complete npm audits: 0 vulnerabilities.
- Complete API release gate: passed, including static production invariants,
  OpenAPI, lint, typecheck, full migration/runtime-role checks, API tests,
  performance tests, and production audit. API line coverage was `71.09%`.
- Local API image built with the expected OCI version/revision/source labels.
  The corrected pinned Trivy scanner reported 0 high/critical findings.

## External-input inventory (2026-07-30)

| Gate/input                                 | Observed availability                                       | Phase 7 consequence                                         |
| ------------------------------------------ | ----------------------------------------------------------- | ----------------------------------------------------------- |
| Protected `handover-ready` and required CI | Available and green at the Phase 6 merge                    | Valid release source                                        |
| Immutable RC tag policy                    | Active ruleset `20073091`; update/deletion; no bypass       | candidate tag can be created once                           |
| GitHub `release-candidate` environment     | Not configured                                              | Candidate build is blocked                                  |
| Repository/environment secret names        | None configured                                             | Android signing is blocked                                  |
| Repository/environment variables           | None configured                                             | final app ID, version code, and staging API URL are blocked |
| Production Android application ID          | Placeholder remains in debug configuration                  | release build now rejects `com.example`                     |
| Android upload/release keystore            | Not available to this workspace or GitHub                   | signed AAB is blocked                                       |
| Android Firebase project configuration     | Ignored local file is registered to the placeholder ID      | final-ID build and push verification are blocked            |
| Physical Android device                    | No attached device detected                                 | device release test is blocked                              |
| macOS/Xcode/iOS signing environment        | Current host is Windows; none found in GitHub configuration | Apple production readiness is explicitly blocked            |
| Real staging compute/database              | No deployed GitHub environment or deployment found          | staging deployment and soak are blocked                     |
| Staging DNS/TLS                            | No approved hostname or credentials supplied                | public endpoint verification is blocked                     |
| Private object storage                     | Only local/reference configuration found                    | external storage behavior is blocked                        |
| Malware scanner                            | Local Compose/reference configuration only                  | scanner availability/failure exercise is blocked            |
| Shared Valkey                              | Local Compose/reference configuration only                  | multi-replica and outage exercise is blocked                |
| External alert delivery                    | No staging credentials or receivers supplied                | delivery evidence is blocked                                |
| Off-server backup target                   | Local Phase 6 backup evidence only                          | independent restore exercise is blocked                     |
| Pilot users/devices                        | No authorized cohort, owners, or schedule supplied          | pilot is blocked                                            |
| Change/security/operations approvals       | No named approvers supplied                                 | tag, staging change, and pilot are blocked                  |

The existing `Staging Readiness` workflow creates an ephemeral PostGIS service,
resets synthetic data, and validates repository behavior. It is valuable CI
evidence, but it is not evidence of a deployed production-like staging system.

## Candidate build contract

The `Release Candidate` workflow has two deliberately different paths:

1. Pull requests, protected-branch pushes, and manual dispatches run only the
   repository contract tests.
2. An annotated tag matching `vMAJOR.MINOR.PATCH-rc.NUMBER` can build a
   candidate only when it points to the exact current protected
   `handover-ready` head and the protected `release-candidate` environment
   provides every required value.

The tag path:

- requires a non-placeholder Android application ID, real release keystore,
  and matching protected Firebase configuration;
- builds and verifies a signed Android App Bundle;
- builds the web bundle against the approved HTTPS staging URL;
- builds and pushes the API image to GHCR without deploying it;
- records OCI source, version, and commit labels;
- records the image digest and SHA-256 hashes in a release manifest;
- inventories and hashes the exact database migration chain in the deployment
  manifest, which remains explicitly staging-only and production-unauthorized;
- generates a CycloneDX API-image SBOM;
- creates GitHub provenance attestations for files and the image;
- uploads the exact artifacts and publishes a prerelease.

An image publication is an artifact operation, not a staging or production
deployment. Deployment remains a separate approved action using the manifest
digest, never a mutable tag. The workflow refuses to overwrite an existing
candidate image or prerelease.

The active repository tag ruleset is defined by
`release/policy/rc-tag-ruleset.json`. It allows a candidate tag to be created
once and prevents matching `v*.*.*-rc.*` tags from being updated or deleted,
with no bypass actor.

## Required GitHub environment

Create an environment named `release-candidate` before creating an RC tag. Add
required reviewers and prevent administrator bypass where the repository plan
supports those controls. Configure only the following values:

Variables:

- `ANDROID_APPLICATION_ID`: final unique application ID, not `com.example`.
- `ANDROID_VERSION_CODE`: positive and never reused for a published Android
  build.
- `RC_API_BASE_URL`: real approved staging HTTPS API origin.

Secrets:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded release/upload keystore.
- `ANDROID_GOOGLE_SERVICES_JSON_BASE64`: Android Firebase configuration
  registered to the exact final application ID.
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The keystore and passwords must be held in the approved secrets manager and
recovery process. Do not commit them, paste them into logs, or store them in an
evidence JSON file.

## Candidate creation approval gate

Before pushing an RC tag, record all of the following:

1. Release, security, and operations owners.
2. Final Android application ID and version-code owner.
3. Keystore custody and tested recovery.
4. Staging hostname, certificate, compute, PostGIS, private storage, scanner,
   Valkey, Firebase project, push delivery, alert receivers, and off-server
   backup destinations.
5. Authorized pilot cohort, physical devices, agreed soak duration, support
   window, and rollback decision authority.
6. Apple scope. If Apple is in scope, a macOS/Xcode build, signing, archive,
   install, encrypted-storage migration, and physical iOS device test are
   mandatory. If deferred, evidence must say so and Phase 8 cannot claim an
   Apple release.

Only after explicit approval:

```powershell
git switch handover-ready
git pull --ff-only origin handover-ready
git status --short
git tag -a v1.0.0-rc.1 -m "TerraLeb v1.0.0-rc.1"
git push origin v1.0.0-rc.1
```

The example version is not an instruction to run it. Select the approved
version first. Never move or reuse a candidate tag.

## Staging, soak, rollback, and pilot

Deploy to staging only after change approval and only by the API digest and file
hashes in `release-manifest.json`. Capture external evidence without secrets:

1. Verify DNS/TLS, migrations, runtime database role, health/readiness, private
   object access, scanner behavior, shared rate-limit/worker behavior, Firebase
   push delivery, alert delivery, and realistic volume.
2. Restore an off-server backup into an isolated target and compare counts and
   checksums.
3. Run physical-device Android install, upgrade, account-switching, offline
   encrypted-data/photo, sync, export, and recovery tests.
4. Run macOS/iOS validation when Apple is in scope.
5. Run the approved soak. Exercise scanner-unavailable and Valkey-unavailable
   policies; stop on any critical, unresolved high, or data-integrity event.
6. Rehearse application rollback using exact current and previous digests.
   Record the database roll-forward/rollback decision; do not reverse a
   destructive migration without its reviewed procedure.
7. Run only the approved pilot cohort and record defects, data-integrity
   comparisons, operational metrics, and owner sign-off.

Copy `release/evidence/phase-7-evidence.template.json` to a
candidate-specific file. Replace placeholders with links or identifiers for the
real evidence, set the status to `complete` only after all applicable gates
pass, then run:

```powershell
node scripts/release-candidate.js verify-evidence --file <candidate-evidence.json>
```

The evidence file must not contain credentials, personal data, private signing
material, access tokens, or sensitive internal logs.

## Stop conditions

Do not merge a Phase 7 completion PR or begin Phase 8 when any of these apply:

- the candidate workflow, attestation, SBOM, signature, checksum, or manifest
  fails;
- the deployed digest differs from the manifest;
- a required external service has only local/synthetic evidence;
- restore, device, soak, rollback, or pilot evidence is missing;
- any critical or unresolved high-severity defect remains;
- any unexplained data-integrity difference or rollback data loss exists;
- required owners have not signed off.

Repository enablement may be merged separately when its CI and review are green;
that merge does not mark Phase 7 complete and does not authorize a tag,
deployment, pilot, or Phase 8.
