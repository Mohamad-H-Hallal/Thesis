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

The next slice must:

1. accept private imports and evidence into a non-public quarantine area;
2. identify content from bytes rather than extension or client MIME type;
3. apply bounded archive entry, expanded-size, compression-ratio, nesting,
   symlink, and traversal checks;
4. integrate a real malware scanner;
5. fail closed in production when scanning is unavailable;
6. prevent parsers and publication from seeing files until the scan is clean;
7. retain evidence and audit status for clean, rejected, and failed scans.

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
