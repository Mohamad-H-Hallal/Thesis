# Mobile Data-at-Rest Security Design

Status: Phase 3 implementation complete on its isolated branch; repository CI
and macOS/iOS release validation remain mandatory gates

Baseline: `preprod-baseline-2026-07-27`

Current deployment targets: Android and web; iOS remains a future target that
requires validation on macOS.

## Purpose

Protect sensitive offline mobile data if application-private storage is copied
from a device, while preserving existing drafts, sync work, project packages,
and account isolation during upgrades.

This design separates two storage classes:

1. `gis_collector_offline.db`, protected with SQLCipher.
2. Offline draft photos, protected independently with authenticated
   AES-256-GCM files because SQLCipher covers only the database.

Offline map tiles contain public basemap imagery and are not classified as
sensitive user data. Their ownership paths still need containment checks, but
they do not require content encryption in this phase.

## Current Storage Inventory

| Data | Location | Current protection | Required treatment |
| --- | --- | --- | --- |
| Access and refresh tokens | `flutter_secure_storage` | Device-bound platform secure storage | Keep |
| User metadata | `flutter_secure_storage` | Platform secure storage | Keep |
| Projects, drafts, sync queue, package metadata | `gis_collector_offline.db` in application documents | SQLCipher, `secure_delete`, integrity gates, and a device-only 256-bit key | Keep; validate every release |
| Draft photos | `offline_photos/` in application documents | AES-256-GCM, path-bound authentication, exact owner/project/draft containment, and a separate device-only 256-bit key | Keep; validate migration and tamper gates |
| Basemap tiles | `offline_tiles/` in application documents | App sandbox and owner-scoped paths | Exclude from backup; content encryption not required |
| Downloaded exports/imports | App documents or Android external app storage | App sandbox or shareable file location | Govern separately by export/import retention policy |

The local database is shared by accounts on one installation. Rows are scoped
by `owner_user_id`, and the existing authorization and synchronization layers
must continue enforcing that scope.

## Threat Model

This phase protects against:

- copying application data through backup, device transfer, debugging, or a
  filesystem extraction;
- reading an offline database without the installation key;
- restoring a database without its matching secure-storage key;
- a crash or power loss during plaintext-to-encrypted migration;
- an old or incorrect key causing the app to overwrite an unreadable database;
- reading, modifying, or moving an offline photo without detection;
- account switching exposing rows owned by another account.

This phase does not claim to protect against:

- a fully compromised device while the application is unlocked and using the
  decryption key;
- screenshots, accessibility capture, or data already displayed by the app;
- files deliberately exported to a user-visible/shareable location.

## Key Lifecycle Decision

Use separate random, installation-scoped 256-bit keys for the database and
offline photos. Separating the keys limits cross-format key reuse and lets each
format evolve independently.

- Generate the key with the operating system cryptographic random source.
- Encode it with unpadded base64url for storage and transport inside the app.
- Store it only in `flutter_secure_storage`.
- Never derive it from a password, user identifier, token, or hard-coded value.
- Never log the key, include it in diagnostics, or write it to normal files.
- Keep it across logout and account switching because the database contains
  durable offline work for multiple owners.
- Remove it only when application data is explicitly reset or the app is
  uninstalled.
- Use a dedicated secure-storage key name and format-version marker.
- Configure Android secure storage to avoid silent reset-on-error. A storage
  error must fail closed because silently generating a replacement key would
  make the existing encrypted database unrecoverable.

Neither key is synchronized across devices. On Apple platforms the keychain
items use `first_unlock_this_device` and are explicitly non-synchronizable.
Each installation downloads its own server-backed data and owns its own
unsynchronized drafts.

## Database State Detection

Before opening the database:

1. Check whether the file exists.
2. Read only the fixed SQLite header length.
3. A file beginning with `SQLite format 3\0` is plaintext.
4. A non-empty file without that header is treated as encrypted or unknown.
5. Never treat an encrypted/unknown file as a missing database.

State handling:

| Database state | Key state | Action |
| --- | --- | --- |
| Missing | Missing | Generate key and create encrypted database |
| Missing | Present and valid | Create encrypted database with existing key |
| Plaintext | Missing | Generate and persist key, then migrate |
| Plaintext | Present and valid | Migrate with existing key |
| Encrypted/unknown | Present and valid | Open with key and verify |
| Encrypted/unknown | Missing or malformed | Fail closed; preserve every file |

## Plaintext-to-SQLCipher Migration

Migration is exclusive and runs before the `LocalStore` becomes available.

1. Recover or clean up any interrupted migration using the state table below.
2. Validate the original plaintext database with `PRAGMA integrity_check`.
3. Create and open a new encrypted temporary database in the same directory,
   passing the installation key through the database driver's password
   parameter.
4. Attach the plaintext source to the encrypted temporary database with a fixed
   internal alias and an explicitly empty source key.
5. Copy schema, indexes, triggers, and rows from the attached plaintext source
   into the encrypted main database with `sqlcipher_export()`.
6. Compare the encrypted result against the still-unmodified plaintext source.
7. Copy the source `user_version`; `sqlcipher_export()` does not do this.
8. Detach and close both databases.
9. Open the temporary database with the key and verify:
   - SQLCipher is available and reports an allowed version;
   - `PRAGMA cipher_integrity_check` returns `ok`;
   - `PRAGMA integrity_check` returns `ok`;
   - `user_version` matches;
   - the expected application tables exist;
   - schema definitions, per-table row counts, and deterministic SHA-256
     digests of every row match the plaintext source.
10. Rename the plaintext database to a migration backup.
11. Atomically rename the verified encrypted temporary database to the normal
    database path.
12. Reopen and verify the normal path with the installation key.
13. Remove plaintext backup, journal, WAL, and SHM files only after successful
    verification.

The temporary and backup names are fixed application constants. SQL identifiers
and attachment aliases are never derived from user input.

Deleting a plaintext file on flash storage cannot guarantee physical erasure of
every previous block. The migration minimizes plaintext lifetime, prevents
future plaintext backups, and relies on device storage encryption for remnant
protection.

## Crash Recovery

| Main file | Encrypted temp | Plaintext backup | Recovery |
| --- | --- | --- | --- |
| Plaintext | Missing | Missing | Start migration |
| Plaintext | Present | Missing | Verify temp; replace if valid, otherwise remove temp and retry |
| Encrypted and valid | Any | Present | Keep main, remove temp, then remove plaintext backup |
| Missing | Encrypted and valid | Plaintext | Promote encrypted temp, verify, then remove backup |
| Missing | Missing/invalid | Plaintext | Restore plaintext backup and retry migration |
| Encrypted/unknown | Missing | Missing | Require the existing key; never recreate automatically |
| Conflicting valid candidates | Any | Any | Fail closed and preserve all candidates for support review |

All recovery decisions are based on file headers and integrity checks, not only
on filenames.

## Rollback Policy

An older app build using normal SQLite cannot open the encrypted database.
Therefore:

- do not roll the mobile binary back to a pre-encryption version after rollout;
- use a forward-fix release for application defects;
- keep the tagged pre-migration source baseline for code comparison, not as an
  automatic binary downgrade;
- provide a separately tested support tool if decrypting an encrypted database
  is ever required;
- never keep a permanent plaintext rollback copy on the device.

Before production rollout, test upgrades from schema versions 1 through 9 and
test interrupted migration at every file-transition boundary.

## Missing-Key and Recovery Policy

If an encrypted database or photo exists but its matching secure-storage key
is unavailable:

- do not delete the database;
- do not create a replacement key;
- do not create a new empty database at the same path;
- show a recoverable security-storage error;
- allow a destructive local reset only through an explicit confirmation that
  warns that unsynchronized work cannot be inspected or recovered.

Android disables application backup and device transfer and also carries
explicit exclusion rules for root, file, database, preferences, and external
domains. On iOS, startup marks Documents and Application Support as excluded
from backup, reads the resource value back, and refuses startup if exclusion
cannot be verified. This prevents restoring encrypted data without its
device-only key.

## Offline Photo Decision

SQLCipher does not encrypt `offline_photos/`.

The implemented photo vault:

- uses a separate random 256-bit key stored only in device-bound secure
  storage;
- encrypts each file with AES-256-GCM and a fresh 96-bit nonce;
- authenticates the file header, media type, and normalized
  owner/project/draft-relative destination path;
- recognizes only JPEG, PNG, HEIC, and HEIF signatures before encryption;
- rejects symlinks and non-regular files;
- writes to an exclusive temporary file, flushes it, authenticates and hashes
  it against the source, then renames it into place;
- updates draft and synchronization references in one database transaction;
- queues the old plaintext path for idempotent deletion only after the
  reference switch;
- deletes picker-created plaintext copies only when they are proven to be
  regular, non-symlink files inside this application's temporary or cache
  directory; gallery originals and arbitrary external paths are never deletion
  candidates;
- records temporary-copy cleanup durably and retries it after interruption;
- resumes a verified temporary file after interruption and preserves
  conflicting candidates;
- decrypts into memory for gallery display and multipart upload, never into a
  persistent plaintext preview or upload file;
- validates declared upload MIME type from authenticated file metadata; and
- scans the protected photo tree at startup and refuses to expose the local
  store while plaintext, unsafe filesystem objects, missing keys, invalid
  formats, or failed authentication remain.

Moving ciphertext to a different authenticated relative path, modifying any
byte, or using the wrong key causes authenticated decryption to fail.

Historical databases from schema versions 1 and 2 predate account ownership.
Their rows are preserved under reserved identities that cannot equal a real
authenticated UUID. Their synchronization work is moved to `deadLetter`
instead of being exposed to an account or uploaded automatically. A historical
photo is assigned only when exactly one preserved draft identity matches; any
ambiguous ownership fails closed without deleting the database or files.

## Platform and Dependency Decision

The database uses `sqflite_sqlcipher` 3.4.0. Offline photos use
`cryptography` 2.9.0 with AES-GCM streaming. Keys use
`flutter_secure_storage` 10.3.1.

The selected Flutter release declares SQLCipher 4.10.0. Android overrides that
transitive dependency with an exact 4.17.0 constraint, and the application
rejects older native versions at runtime. Apple dependency resolution still
needs to be updated and validated on macOS before an iOS or macOS release.
Before production:

- verify the embedded native version at runtime;
- review SQLCipher releases newer than the pinned version;
- reject versions below 4.17.0;
- upgrade the Flutter binding or use a reviewed local fork if a relevant
  security fix is unavailable through the package;
- run Android release builds and device migration tests;
- run iOS archive and physical-device migration tests on macOS before enabling
  iOS distribution.

The web implementation remains the separate in-memory store and is not changed
by the native SQLCipher dependency.

## Verification Gates

The implementation is not complete until all of these pass:

- key generation produces exactly 256 bits and validates stored encoding;
- missing/malformed-key cases fail closed;
- new database files do not expose the SQLite plaintext header;
- the wrong key cannot open or modify the database;
- plaintext versions 1 through 8 migrate without row loss;
- encrypted schema version 9 opens without an unintended schema migration;
- source and encrypted row counts match;
- source and encrypted schema/content digests match;
- both SQLCipher and SQLite integrity checks pass;
- crash-recovery matrix tests pass;
- logout/account switching retains the installation key and row isolation;
- Android backup/device-transfer exclusions are verified;
- photo key-loss, tamper, wrong-key, path-rebinding, conflict, and interrupted
  migration tests pass;
- the offline photo tree contains no remaining plaintext files;
- iOS backup exclusion is verified by the native unit test and on a release
  device;
- Flutter analysis and the complete mobile test suite pass;
- Android debug and release builds pass;
- iOS validation passes on macOS before iOS release.

The authoritative implementation, recovery, rollback, verification, and
platform-gate runbook is
[`phase-3-mobile-data-at-rest.md`](../predeployment/phase-3-mobile-data-at-rest.md).

## Primary References

- SQLCipher API and `sqlcipher_export()`:
  https://www.zetetic.net/sqlcipher/sqlcipher-api/
- SQLCipher plaintext migration:
  https://www.zetetic.net/sqlcipher/encrypting-plaintext-databases/
- Android backup rules:
  https://developer.android.com/identity/data/autobackup
- Flutter secure storage:
  https://github.com/juliansteenbakker/flutter_secure_storage
- SQLCipher-compatible sqflite package:
  https://pub.dev/packages/sqflite_sqlcipher
- Dart AES-GCM implementation:
  https://pub.dev/packages/cryptography
- Apple backup exclusion:
  https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey
