# Account deletion and pseudonymous attribution

Status: engineering design implemented behind `ACCOUNT_DELETION_EXECUTION_ENABLED=false` by default. It is not a legal conclusion.

## Execution model

Deletion is a reviewed, reauthenticated privacy request. The protected super-administrator account is excluded. Approval requires two explicit, non-default protected-administrator decisions: whether unfinished work must first be resolved or may be discarded, and whether responsibilities are released or were already transferred through authoritative admin workflows. A legal/security hold always blocks execution.

The idempotent background job locks the execution and user, rechecks current counts and the recorded decisions, releases eligible assignments and queue ownership, revokes sessions and device tokens, removes direct identifiers and credentials, scrubs known structured snapshots, records free-text review tasks, and creates a backup-expiry schedule. Unapproved features, their photos, unfinished imports/exports, unpublished AI runs, assignments, and quarantined uploads are removed only after the administrator expressly selects `discard_unapproved`.

Database erasure/tombstoning and artifact deletion are separate durable stages. Storage references are recorded in a restricted retry queue, and the request cannot become `completed` until every queued object is deleted or verified absent. A failed storage stage leaves the account non-authenticatable and reports that protected cleanup will retry; it never falsely tells the user that the account stayed fully active. Retries preserve the same masked label and tombstone.

## Deleted data

The pipeline removes email, phone fields, password hash, verification/recovery state, sessions, device tokens, notification destinations, private profile values, privacy-export contents, offline synchronization receipts, approved discarded work, and unnecessary stored artifacts. The Flutter cleanup uses a durable owner-specific marker, resumes after interruption, clears memory images and does not purge another account on a shared device.

## Retained data

Where an approved institutional-record rule requires integrity, GIS contributions, review decisions, comments, imports/exports provenance, AI validation/publication decisions and necessary audit evidence retain the internal immutable user relationship. The account is permanently non-authenticatable, has no fake reusable contact value and cannot be reactivated.

Before the full name is erased, the service creates one pseudonymous masked label from the first Unicode grapheme of each meaningful component (`Ali Hassan` → `A. H.`). The full name is not retained to regenerate it. This is pseudonymization, not legal anonymity. Known structured snapshots are scrubbed; arbitrary free text is not rewritten because that can corrupt the record, so matches create a restricted review task.

## Production gate

Execution must remain disabled until every configured reference is real and immutable: deletion policy, retention, retained-GIS basis, masked-label visibility, accepted photo/location treatment, free-text treatment, and backup ageing. The designated legal owner/counsel must also approve contributor/deletion notices, legal holds, and store disclosures. A Terms clause or contributor consent alone is not treated as permanent authority to retain a real identity.

Backups are not destructively rewritten. The schedule prevents a restored tombstone from becoming active and supplies the approved expiry target once configured. Any exceptional identity legal hold must remain separately encrypted, purpose-limited, expiring and access-audited; it is disabled without an approved policy.
