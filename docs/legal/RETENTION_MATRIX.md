# TerraLeb retention and deletion matrix

No new legal retention period is approved by this document. Existing operational
defaults are recorded as facts, not legal decisions. Automated cleanup for a
category must remain disabled until `approved` is recorded in controlled policy.

| Category | Trigger | Current behavior | Approved target/action | Legal hold/backup rule |
|---|---|---|---|---|
| Access/refresh sessions | Expiry/revocation | Expired and old revoked sessions are opportunistically removed | DECISION REQUIRED | DECISION REQUIRED |
| Password reset requests | Expiry/use | Expiry enforced; complete purge schedule not evidenced | DECISION REQUIRED | DECISION REQUIRED |
| Contact challenges/audit | Expiry/consumption | Challenge state retained; no complete approved purge | DECISION REQUIRED | DECISION REQUIRED |
| Pending unverified signup | Cancellation/abandonment | Explicit cancellation deletes eligible pending user and keeps masked audit | DECISION REQUIRED | DECISION REQUIRED |
| Device registrations/delivery snapshots | Invalid token/logout/account action | Best-effort unregister/invalidation | DECISION REQUIRED | DECISION REQUIRED |
| Notifications | Read/dismiss/delete/account action | User can delete; maintenance exists | DECISION REQUIRED | DECISION REQUIRED |
| Server application logs | Creation | API rotating default 14 days | DECISION REQUIRED | Incident/legal hold process required |
| Loki reference logs | Creation | Reference configuration 30 days | DECISION REQUIRED | Region/access/hold approval required |
| Export files | Completion | Default expiry 7 days; metadata retained | DECISION REQUIRED | Downstream copies are recipient-controlled |
| Import uploads/temp files | Upload/process/failure | Security and reconciliation registries exist | DECISION REQUIRED | Failed/quarantine evidence rules required |
| Draft features/photos | Creation/sync/rejection/deletion | Local cleanup is workflow-specific | DECISION REQUIRED | Account deletion and unsynced-draft warning required |
| Submitted GIS/history and attribution | Collection/review/project closure/account deletion | Proposed deletion retains justified relationships through a non-authenticatable tombstone and replaces the profile name with a one-time pseudonymous masked label | DECISION REQUIRED: classify each retained record; approve basis, exact fields, label visibility and period | Government/public-record, platform UGC, correction/objection, free-text and relational-integrity decisions required |
| Personal-data export artifacts | Artifact readiness/download/expiry | Encrypted, short-lived, single-use authenticated download; cleanup supported | DECISION REQUIRED: TTL, access evidence and exceptional hold | Production requires an approval reference; downstream user copies are outside server cleanup |
| Account-deletion execution evidence | Request completion/failure | Safe status history, final audit, free-text review tasks and backup-expiry schedule | DECISION REQUIRED: minimal evidence and retention | Must not preserve erased PII; legal holds require separate approved controls |
| AI runs/artifacts/evidence | Run completion/rejection/retraction | Persists across review lifecycle | DECISION REQUIRED | Model accountability vs minimization decision required |
| Privacy requests/evidence | Completion | New workflow records request/status/deadline | DECISION REQUIRED | Minimal evidence may be needed to prove fulfillment |
| Database/object backups | Backup creation | Architecture/runbooks exist; production values unresolved | DECISION REQUIRED | Deletion propagates on normal expiry unless lawful hold applies |

The ten-day privacy-request target in the implementation is an internal safety
SLA pending Lebanese counsel's interpretation; it is not a statement that every
request must legally be completed in exactly ten days.
