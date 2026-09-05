# TerraLeb retention and deletion matrix

Status: **owner-approved operational schedule; counsel and implementation evidence still gate production**

Decision record: `TERRALEB_OWNER_POLICY_DECISION_RECORD_V1.md`
Decision date: **2026-09-05**

“Delete” means removal from active systems followed by natural encrypted backup
expiry. It never means silently rewriting production backups. A legal hold is
disabled unless a specific approved, encrypted, purpose-limited, access-audited
case record with an expiry exists.

| Category | Trigger | Approved target/action | Hold and backup rule |
|---|---|---|---|
| Access/refresh sessions | Expiry/revocation | Delete after 30 days; retain only a non-reversible security event when necessary | No token or session secret enters a hold. |
| Password reset and contact challenges | Expiry/use | Delete code/hash and delivery metadata after 30 days | Abuse evidence must be separately justified and minimized. |
| Pending unverified signup | Last activity | Delete shell and unused contact data after 30 days | A separate non-reversible abuse event may remain. |
| Device registrations | Logout, deletion, revocation, invalid response | Disable immediately and purge within 7 days | No restoration into active delivery state. |
| Notifications | Creation | Delete body and user copy after 180 days | Retain only required minimal outcome evidence. |
| Routine application/Loki logs | Event | Delete or aggregate after 30 days | Security events may move to the separate one-year class. |
| Security events | Event | Delete or aggregate after 1 year | Longer retention requires a specific approved hold. |
| Audit/admin decisions | Event | Restricted retention for 7 years, then review/delete | Valid case hold only; never store secrets or unnecessary payloads. |
| Privacy/moderation case | Closure | After 3 years delete submitted PII and detail; keep minimum fulfillment/outcome evidence | Case-specific hold only. |
| Personal-data export artifact | Successful generation | Delete encrypted artifact after 24 hours; retain fulfillment/access evidence for 2 years | User-held downloads are outside server cleanup. |
| Project export | Generation | Delete artifact after 7 days; retain non-PII provenance for 2 years | Downstream authorized recipient controls its copy. |
| Temporary import/quarantine | Completion/failure | Delete file after 30 days | Security evidence is separate and minimized. |
| Rejected import source | Final rejection | Delete source after 90 days; retain minimum rejection/provenance record | Case hold only. |
| Approved import source/provenance | Project archive | Source artifact: active project plus 2 years. Provenance metadata: active project plus 10 years, then review/delete | Preserve license/source accountability, not uploader contact data. |
| Unsynchronized/private draft | Last activity/deletion | Delete after 90 inactive days or immediately on completed account deletion after warning | Remove only the affected owner's local encrypted copy. |
| Rejected/private photo | Final rejection | Delete file/thumbnails after 90 days | Case hold only. |
| Accepted GIS/photo/review/comment/provenance | Project archive | Active project plus 10 years, then review/delete under sensitivity and masked-identity controls | Retain only accepted record and minimum institutional provenance. |
| Published GIS provenance/decision | Publication withdrawal | While published plus 10 years, then review/delete | Never expose deleted-account UUIDs. |
| Temporary/failed AI artifact | Completion/failure | Delete after 30 days; no general or cross-project training reuse | Case hold only. |
| Approved AI provenance/evaluation | Model retirement/publication withdrawal | Restricted retention for 10 years, then review/delete | No account/profile inputs. |
| Database/object backup | Creation | Automatically expire after 35 days | Deletion ledger prevents erased identity restoration. |
| Legal hold | Approved hold start | Case-specific expiry; review every 6 months and release promptly when purpose ends | Disabled by default; separately encrypted and audited. |

The implementation uses configuration and approval references rather than
hard-coding these durations as legal claims. Every cleanup path must be
idempotent, auditable, transaction-safe, dry-run capable where appropriate, and
tested before `retentionAutomationVerified` may be approved.

The ten-day privacy-request target remains an internal service target pending
Lebanese counsel's interpretation; this matrix does not assert a universal
statutory deadline.
