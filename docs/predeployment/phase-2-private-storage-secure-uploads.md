# Phase 2 — Private Storage and Secure Uploads

This phase removes public delivery paths for sensitive media before adding
quarantine, malware scanning, or storage migration. It is intentionally split
into independently reviewable slices.

## Security invariants

- Category icons are the only files intentionally served without
  authentication under `/uploads`.
- Feature photos remain available only from their authenticated photo API
  endpoints.
- Current and legacy AI validation evidence requires a valid bearer token and
  access to at least one project that references the file.
- Import source files, exports, thumbnails, private feature media, and
  unreferenced files are never served by a generic static mount.
- Private responses use `Cache-Control: private, no-store` and
  `X-Content-Type-Options: nosniff`.
- A filename alone never grants access.

## Slice 2A — delivery boundary

The broad `/uploads` static mount is removed. Public category icons retain
their existing `/uploads/category-icons/<name>` URLs through an exact,
dotfile-denying static mount.

AI evidence retains its existing stable media identifiers for database and
mobile compatibility:

- `/uploads/ai-validation/<name>` for current evidence;
- `/uploads/photos/<name>` for migration-snapshotted legacy evidence.

Both paths now pass through authentication, immutable filename validation,
database-reference validation, project authorization, storage-root
containment, and private response headers. The mobile evidence preview sends
the current bearer token when loading these URLs.

No database row or stored file is deleted, moved, or rewritten by this slice.

## Slice 2B — intake quarantine and content safety

Status: implemented on `fix/upload-quarantine-malware-scanning`; merge and CI
evidence must still be recorded before this slice is called complete.

The implementation now:

1. authorizes GIS imports before accepting multipart file bytes;
2. stores import sources under `.quarantine/imports` and records their size,
   SHA-256, uploader, project, detected type, scan status, disposition, and
   rejection reason in `upload_quarantine_record`;
3. identifies JSON, XML, UTF-8 text, and ZIP-based formats from their bytes
   before release;
4. rejects unsafe archive paths, symlinks, encrypted entries, nested archives,
   excessive entry counts, oversized entries/expansion, and excessive
   compression ratios before a GIS parser can see the file;
5. sends every accepted import and image source to ClamAV using its bounded
   `INSTREAM` protocol;
6. keeps rejected imports in quarantine and moves only clean imports into the
   private import root;
7. rechecks the released file's managed root, SHA-256, and content constraints
   inside the background worker immediately before parsing;
8. holds feature photos, AI evidence, and category icons in memory until
   scanning and strict raster decoding succeed, strips image metadata by
   normalizing to JPEG, and releases the result atomically;
9. forces `MALWARE_SCANNER_MODE=clamav` in production and returns a retryable
   `503` without parsing or publishing when the scanner is unavailable;
10. deploys ClamAV on the private Compose network only, with no host port, a
    persistent signature volume, a health check, and a 4 GiB memory ceiling.

The scanner protocol and container choices follow the official
[ClamAV `INSTREAM` protocol](https://docs.clamav.net/manual/Usage/ClamdProtocol.html)
and [ClamAV container guidance](https://docs.clamav.net/manual/Installing/Docker.html).
The controls also implement the signature validation, authorization, storage,
archive, and malware-scanning recommendations in the
[OWASP File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html).

Repository verification includes scanner protocol tests, clean/infected/
unavailable behavior, archive-bomb and traversal tests, immediate `422`
rejection for corrupt archives, quarantine-registry assertions, existing import
workflow tests, photo security tests, image normalization tests, TypeScript,
lint, migration application, and Compose rendering.

Local verification recorded on 2026-07-28:

- the complete API release gate passed: 27 suites and 216 tests, 70.95% line
  coverage, both GIS performance tests, OpenAPI, lint, TypeScript, and zero
  production dependency vulnerabilities;
- a fresh disposable PostgreSQL database applied all 42 migration files and
  created the quarantine registry successfully;
- the complete npm audit reported zero vulnerabilities across production and
  development dependencies;
- all four maintained Compose configurations rendered successfully;
- the pinned real ClamAV container returned clean for harmless content,
  detected the standard EICAR test object, and caused the application to fail
  closed when the scanner was stopped;
- Flutter analysis passed and all 330 mobile tests passed, confirming that this
  API-only slice did not regress the mobile application.

Production-like staging must still prove that signature updates succeed, the
scanner becomes healthy after a cold start, a harmless EICAR test object is
rejected and retained in quarantine, and stopping ClamAV causes uploads to fail
closed with `503`. The ClamAV TCP port must remain internal because the clamd
protocol does not provide transport encryption or authentication.

## Slice 2C — storage migration and orphan reconciliation

The final slice must introduce the replaceable storage adapter and migration
workflow:

1. copy without changing the active reference;
2. verify source and destination SHA-256 plus size;
3. switch the database reference transactionally;
4. retain the old object for the reviewed rollback window;
5. inventory unreferenced media in read-only mode;
6. quarantine only explicitly reviewed orphan candidates;
7. permanently delete nothing in this phase.

The Phase 2 gate is not complete until all three slices pass the complete API,
mobile, migration, audit, and CI release gates.
