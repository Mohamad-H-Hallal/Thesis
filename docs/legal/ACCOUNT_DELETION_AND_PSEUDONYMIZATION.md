# Account deletion and pseudonymous attribution

Status: engineering design implemented behind `ACCOUNT_DELETION_EXECUTION_ENABLED=false` by default. It is not a legal conclusion.

## Execution model

Deletion is a reviewed, reauthenticated privacy request. The protected super-administrator account is excluded. Contributors remain blocked by assignments, pending reviews, unresolved work and unresolved private offline data. Administrators require transfer of active projects, AI assignments, and privacy/moderation cases to another active administrator.

The idempotent background job locks the execution and user, rechecks eligibility, releases eligible assignments and administrator queue ownership, revokes sessions and device tokens, removes direct identifiers and credentials, scrubs known structured snapshots, records free-text review tasks, creates a backup-expiry schedule and completes the request only after every mandatory stage succeeds. Retries preserve the same masked label and tombstone.

## Deleted data

The proposed pipeline removes email, phone fields, password hash, verification/recovery state, sessions, device tokens, notification destinations, private profile values, unnecessary private drafts and owner-scoped cached/offline data. The Flutter cleanup uses a durable owner-specific marker, resumes after interruption, clears memory images and does not purge another account on a shared device.

## Retained data

Where an approved institutional-record rule requires integrity, GIS contributions, review decisions, comments, imports/exports provenance, AI validation/publication decisions and necessary audit evidence retain the internal immutable user relationship. The account is permanently non-authenticatable, has no fake reusable contact value and cannot be reactivated.

Before the full name is erased, the service creates one pseudonymous masked label from the first Unicode grapheme of each meaningful component (`Ali Hassan` → `A. H.`). The full name is not retained to regenerate it. This is pseudonymization, not legal anonymity. Known structured snapshots are scrubbed; arbitrary free text is not rewritten because that can corrupt the record, so matches create a restricted review task.

## Production gate

Execution must remain disabled until the designated legal owner/counsel approves the retained-record basis and exact classes, retention periods, masked-label visibility, contributor/deletion notices, photos and precise-location treatment, free-text handling, legal holds, backup ageing and store disclosures. A Terms clause or contributor consent alone is not treated as permanent authority to retain a real identity.

Backups are not destructively rewritten. The schedule prevents a restored tombstone from becoming active and supplies the approved expiry target once configured. Any exceptional identity legal hold must remain separately encrypted, purpose-limited, expiring and access-audited; it is disabled without an approved policy.
