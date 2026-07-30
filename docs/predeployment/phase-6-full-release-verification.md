# Phase 6 — Full Release Verification

Status: repository implementation and local verification complete on
`codex/phase-6-full-release-verification`. This phase does not deploy or modify
staging or production. The external release gates at the end of this document
remain mandatory before a release candidate can be approved.

## Release-security controls

- Every third-party GitHub Action is pinned to a reviewed commit and checkout
  credentials are not persisted.
- CodeQL runs JavaScript/TypeScript `security-extended` analysis on pull
  requests, `handover-ready`, a weekly schedule, and manual dispatch.
- The release-security workflow scans complete Git history with Gitleaks,
  recursively scans npm and Dart dependency graphs with OSV-Scanner, builds the
  production API image, and rejects Critical/High image findings.
- Production images are built from exact sources or exact upstream digests.
  Runtime images omit package managers and unnecessary executable tooling where
  practical.
- The Alloy image is built from the exact Grafana Alloy v1.18.0 source commit.
  Fixable Go and Ubuntu packages are updated, and unused `mount`/`umount`
  executables are removed.
- Alloy's three High findings are constrained to non-executed Docker-daemon
  paths and are recorded in an image- and version-specific OpenVEX document.
  The scanner first requires the raw inventory to match the reviewed records,
  applies VEX, and then requires zero Critical/High findings.
- Alloy's ten remaining Medium records are exact-matched by a machine-readable
  decision file. Each has an owner, rationale, and a 2026-10-01 review
  deadline. The Docker VEX decisions expire no later than 2027-01-01. Changed,
  added, expired, or removed findings fail verification.

The complete Alloy rationale and review procedure are in
[`infra/alloy/SECURITY.md`](../../infra/alloy/SECURITY.md).

## Defects found and fixed during verification

- A GitHub CI race used server-level PostgreSQL readiness before the exact
  fixture database existed. The test now performs an authenticated `SELECT 1`
  against that database and waits for the exact result.
- Flutter web called the Android/iOS foreground-task bridge during startup,
  causing a blank release page. Native foreground-task integration now has an
  explicit platform availability policy and the web root omits the native
  wrapper. A deterministic regression test protects the policy.
- Fixable Certbot and blackbox-exporter dependency findings were removed rather
  than accepted.

## Verification evidence

Recorded on 2026-07-30:

- Git object verification and patch whitespace checks passed after the laptop
  restart and network interruption. Local and remote Phase 6 checkpoint
  pointers both resolved to
  `a5b18c2b6ff178b45604538234456b91b1841a25`; no source file was lost or
  truncated.
- Clean npm installation installed 667 packages. Complete and
  production-only audits reported zero vulnerabilities.
- The complete API release gate passed, including production configuration,
  OpenAPI coverage, lint, typecheck, all 45 migrations under the restricted
  migration model, API tests, GIS/workload performance tests, and the final
  audit. API line coverage was 71.09%.
- An exact-database runtime-grant test passed after the readiness correction.
- The PostGIS upgrade drill preserved data while upgrading 3.4.3 to 3.5.7.
- A local logical backup/restore drill restored all 39 public-table row counts
  into a new database and removed the temporary restore database without
  modifying the source. The retained ignored backup is
  `backups/db/gis_app-20260730-071614217.dump`, size 90.44 MB, SHA-256
  `88cca157a6d1e670f31800439426399ad27acb7a92121aa03d5125c621b70495`.
- Flutter 3.41.2/Dart 3.11.0 completed locked normal and offline dependency
  resolution. Analysis reported no issues. All 345 local Flutter tests passed
  with 50.63% line coverage against a 19% minimum.
- Android debug and release APK builds and the Flutter web release build
  completed. These are verification artifacts, not approved store artifacts.
- On an Android 14/API 34 emulator, all seven SQLCipher integration scenarios
  passed: historical schema versions 1–8 with typed-row preservation, current
  schema and account/photo isolation, new encrypted database creation,
  interrupted promote/restore, conflicting-candidate preservation, and
  wrong-key handling.
- The release web app was exercised at 390×844 and 1440×900. It rendered
  without horizontal overflow or new console errors, and exposed the expected
  sign-in controls and semantic heading after the foreground-task fix.
- Production and observability configuration passed static and real-runtime
  validation for PostgreSQL/PostGIS, Prometheus and its alert-rule tests,
  Alertmanager, Loki, Alloy, blackbox exporter, and Nginx TLS.
- Eleven production images passed the exact pinned Trivy gate with zero
  Critical/High findings after the reviewed Alloy VEX decision: API, PostGIS,
  Certbot, Prometheus, Alertmanager, blackbox exporter, Loki, Alloy, ClamAV,
  Valkey, and Nginx. Alloy's raw inventory remained exactly three reviewed High
  and ten reviewed Medium records.
- Local full-history Gitleaks and recursive OSV scans passed. GitHub CI is the
  final independent execution of the committed workflows.
- All disposable validation containers, temporary databases, the emulator, and
  the temporary local web server were stopped. A subsequent Docker restart left
  three exited Phase 6 fixtures; their exact names were reviewed and removed.

## Required external release gates

Phase 6 repository completion does **not** prove production readiness. The
following require approved infrastructure, credentials, hardware, or a release
candidate and therefore remain open:

1. Restore encrypted off-server database and private-media backups into a
   production-like staging environment and prove the agreed RPO/RTO.
2. Exercise real private object storage, migration checksums, real malware
   scanning and scanner outage behavior, and a read-only legacy-media inventory.
   No permanent deletion is authorized.
3. Validate Keychain/SQLCipher migration and release builds on macOS/iOS.
   Validate Android Keystore, account switching, backup exclusion, low-storage,
   interruption, and encrypted photos on at least one supported physical
   Android device.
4. Exercise shared Valkey counters and durable workers across at least two
   deployed API replicas, including dependency outage, worker restart,
   idempotency, dead-letter recovery, and realistic sustained GIS load.
5. Prove real DNS/TLS renewal, managed-secret rotation, alert delivery,
   centralized-log retention, WAF behavior, backup alerts, and controlled
   dependency failure in production-like staging.
6. Complete the role/endpoint authorization matrix, upload/archive attacks,
   offline conflicts, interrupted uploads, session expiry, permissions,
   accessibility, responsive layout, and manual end-to-end checks against
   production-like staging data.

These are Phase 7 entry gates, not permission to deploy. Phase 7 must not begin
until the Phase 6 pull request and all independent GitHub checks are green and
merged into protected `handover-ready`.
