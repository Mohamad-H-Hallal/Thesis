# Phase 3 — Mobile Data at Rest

Status: implementation complete on `codex/phase-3-mobile-encryption`;
repository PR/CI and the separate macOS/iOS release gate must still be
recorded.

This phase encrypts the native mobile application's offline database and draft
photos without deleting unsynchronized work. It does not authorize a
production deployment, a destructive local reset, or an iOS release.

## 1. Prior-phase gate classification

The repository gates for Phases 0, 1, and 2 are complete:

- Phase 0 has a clean dependency baseline, protected `handover-ready` branch,
  required CI checks, and tag `preprod-baseline-2026-07-27`.
- Phase 1 has the reviewed data classification, backup, restore, retention,
  migration, and rollback engineering controls.
- Phase 2 private delivery, upload quarantine/scanning, storage abstraction,
  and reconciliation changes merged through PRs #7, #8, and #9.

The following are external acceptance gates, not missing repository fixes:

- production-like staging infrastructure and distinct staging secrets;
- encrypted off-server database and media backups;
- a real RDS/PostgreSQL and object-storage restore/rollback drill;
- ClamAV cold start, signature update, EICAR, and unavailable-scanner drills;
- a matched database/storage inventory, migration, rollback, and
  orphan-quarantine drill.

They remain deferred to the infrastructure and release-candidate phases.
Nothing in this document authorizes changes to production data or services.

## 2. Security invariants

- `gis_collector_offline.db` is SQLCipher-encrypted with a random,
  installation-scoped 256-bit key.
- Offline draft photos are independently AES-256-GCM encrypted with a separate
  random 256-bit key.
- Both keys live only in device-bound platform secure storage and survive
  logout or account switching.
- Existing encrypted data with a missing or malformed key fails closed. The app
  never silently generates a replacement key over unreadable data.
- Database migration verifies SQLCipher and SQLite integrity, schema, row
  counts, row digests, and `user_version` before removing plaintext artifacts.
- Photo migration verifies authenticated ciphertext before switching database
  references or scheduling plaintext cleanup.
- Protected photos are decrypted only into memory for display and upload.
- A ciphertext file is bound to its normalized owner/project/draft-relative
  path. Moving, modifying, or substituting it fails authentication.
- Files outside the exact owned photo tree are not accepted as protected draft
  photos.
- Picker copies are deleted only when proven to be regular, non-symlink files
  inside this application's temporary or cache directory.
- Android backup and device transfer are disabled. Apple application data is
  excluded from backup and startup fails if the exclusion cannot be verified.

## 3. Key lifecycle and account switching

The database key and photo key have different secure-storage identifiers and
format markers. Each key is generated from the operating-system cryptographic
random source, must decode to exactly 32 bytes, and is never derived from user
identity, credentials, tokens, or application constants.

The local database is installation-scoped and may contain work for more than
one account. Logout removes session credentials but does not delete either
data-at-rest key. Queries, storage paths, and synchronization continue to use
the authenticated owner identifier. Switching accounts therefore preserves
offline work while preventing one account from seeing another account's rows.

An explicit destructive application-data reset may remove the keys only after
warning that unsynchronized local work will become unrecoverable. No automatic
reset or automatic replacement-key path is permitted.

## 4. Historical database migration

The device integration suite contains independent snapshots of the actual
schemas first shipped as versions 1 through 8. The fixtures do not reuse the
current schema builder.

For every historical version the test creates a real plaintext database and
photo, opens it through the production initializer, and verifies:

- plaintext-to-SQLCipher conversion and upgrade to schema 9;
- preservation of projects, drafts, photos, synchronization work, packages,
  types, nulls, and row identity;
- removal of plaintext database migration artifacts after verified promotion;
- copy of each photo into the exact owned vault, authenticated encryption, and
  transactional reference update;
- deletion of the temporary plaintext source and exhaustion of both durable
  cleanup queues;
- absence of plaintext or plaintext-named files from the protected photo tree;
- owner isolation and installation-key stability across account switching;
- missing-photo-key failure without deleting the database or ciphertext.

Schemas 1 and 2 predate account ownership. Their work is retained under
reserved identifiers that cannot equal an authenticated UUID. Their
synchronization items are dead-lettered and cannot upload automatically.
Photos are mapped only when one exact preserved draft identity exists.
Ambiguous legacy identity fails closed and preserves all candidates.

## 5. Interruption, cleanup, and recovery

Database migration uses fixed main, encrypted-temporary, and plaintext-backup
paths. Startup classifies and integrity-checks every candidate. A verified
encrypted temporary database may be promoted; an unverified or conflicting
candidate is preserved or rejected according to the recovery matrix in
[`mobile-data-at-rest-design.md`](../security/mobile-data-at-rest-design.md).

Photo encryption writes an exclusive `.tlphoto.tmp`, flushes it, verifies
authenticated plaintext equivalence, and only then renames it into place.
A later start may promote a verified temporary file. A conflicting destination
or failed authentication preserves the files and refuses migration.

After a verified photo reference switch, old owned plaintext paths enter the
project/owner/draft-scoped cleanup queue. Picker-created source copies enter a
separate durable cleanup queue only after containment and no-symlink checks.
Failed deletions remain queued for a later start. Missing files are treated as
an idempotent success.

Low disk space, process termination, or an I/O error before verified promotion
leaves the original source and database references intact. A cleanup failure
does not convert a successful upload into a duplicate upload attempt.

Deleting plaintext from flash cannot guarantee erasure of historical physical
blocks. Backup exclusion, device encryption, minimized plaintext lifetime, and
verified logical cleanup are the applicable controls.

## 6. Rollback and support policy

A pre-encryption application binary cannot read the encrypted schema.
Therefore:

- do not roll devices back to a pre-encryption binary after rollout;
- prefer a forward-fix release;
- never retain a permanent plaintext rollback database or photo copy;
- do not remove or rotate either installation key during a normal update;
- do not reset a user's local data without explicit confirmation;
- preserve all main/temp/backup candidates when recovery is ambiguous;
- use a separately reviewed support tool if decryption/export is ever required.

The source tag is for code comparison and reconstruction, not an automatic
binary rollback mechanism.

## 7. Platform gates

### Android repository gate

Before merging this phase:

- Flutter dependency resolution succeeds online and from the lockfile cache;
- Flutter analysis and targeted encryption tests pass;
- the complete Flutter suite and coverage gate pass;
- the real schemas 1–8 integration suite passes on an Android emulator or
  device;
- debug installation and the release APK build pass;
- the APK contains SQLCipher for every packaged ABI;
- the packaged manifest disables backup/device transfer;
- npm clean install and production/development audits remain clean;
- required GitHub API and Flutter checks pass.

The locally built release APK is not a production artifact while it uses the
Android debug certificate. Production signing, secret custody, Play signing,
and reproducible release provenance are Phase 5 gates.

### Apple gate

Windows cannot execute the required Apple validation. Before any iOS
production-readiness claim, a macOS runner and a physical release device must:

1. resolve and audit CocoaPods dependencies;
2. compile and run `RunnerTests`, including backup-exclusion verification;
3. build a release archive with the approved bundle identifier and signing;
4. install the upgrade over historical schemas and real draft-photo fixtures;
5. run wrong-key, missing-key, interruption, account-switching, tamper, and
   plaintext-cleanup checks;
6. inspect the application container and backup behavior;
7. record the resolved SQLCipher version, archive hash, signing identity,
   device/OS versions, and test evidence.

Until that evidence exists, Android repository verification does not imply iOS
production readiness.

## 8. Evidence record

Local verification recorded on 2026-07-29:

- the work resumed from the intact, remote-synchronized checkpoint
  `a32168b19f0dc40d74a7c6d08adcac922360a0b6`;
- Flutter 3.41.2 and Dart 3.11.0 resolved dependencies online and from the
  existing lockfile cache;
- Flutter analysis reported no issues;
- all 58 focused encryption, cleanup, synchronization, and protected-gallery
  tests passed;
- the serial complete Flutter suite passed all 343 tests;
- line coverage was 14,612 of 28,601 lines, or 51.09%, above the 19% gate;
- the seven-test native integration suite passed on an Android 14/API 34
  x86_64 emulator, including the actual SQLCipher library and schemas 1–8;
- the integration run built, installed, and exercised the debug APK;
- the release APK built successfully, packaged `libsqlcipher.so` for
  `arm64-v8a`, `armeabi-v7a`, and `x86_64`, and had SHA-256
  `1F5DADBECA019E1D2D6ED0591DAD61423ADC4CE6F88434C975AA5F305056C0A2`;
- the packaged release manifest set `allowBackup=false`, referenced both
  exclusion-rule resources, and contained no `debuggable` attribute;
- APK signature verification passed, but the signer was the Android Debug
  certificate, so this build is not a production-signing artifact;
- a clean npm installation completed and both the production-only and complete
  npm audits reported zero vulnerabilities;
- Pub reported available newer dependency releases as informational; no
  unrelated or incompatible major upgrade was added to this security phase.

Repository PR, merge commit, and required-check evidence must be added to the
phase handoff report after GitHub completes them. The Apple gate in section 7
was not executable on this Windows host and remains explicitly open.

Phase 3 is repository-complete only after its PR merges green into the protected
`handover-ready` branch. It is not an iOS release approval and is not a
production deployment approval.
