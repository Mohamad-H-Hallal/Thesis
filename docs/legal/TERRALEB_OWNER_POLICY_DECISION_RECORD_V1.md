# TerraLeb owner policy decision record v1

Status: **adopted product policy; external facts and counsel approval remain separate release gates**
Decision date: **2026-09-05**
Release: **TerraLeb Android and authenticated web v1**
Territory: **Lebanon**

The TerraLeb product owner directed the repository to adopt the conservative
choices below. This record authorizes engineering and policy drafting. It does
not identify the legal operator, execute a provider contract, approve a store
submission, state a final legal basis, replace qualified Lebanese counsel, or
authorize production. Those facts and approvals remain blocked until their
real evidence is attached to the exact release.

## Adopted decisions

- TerraLeb v1 is offered and marketed for Lebanon only on Android and an
  authenticated web application. Public iOS distribution is outside v1.
- Users must be at least 18. Minors are not intentionally permitted or
  processed. TerraLeb will not collect date of birth solely to prove age.
- Arabic and English are required for public legal documents and critical
  consent, deletion, permission, and safety surfaces. Counsel must approve the
  controlling-language and discrepancy clauses.
- The eventual legal operator controls accounts, authentication, security,
  TerraLeb administration, support, privacy requests, and operational logs.
  Each project-owning institution controls or supplies the competent authority
  for its project purpose, contributor access, review, retention, and
  publication. TerraLeb acts as service operator/processor for
  institution-directed project data except where it makes independent account
  or security decisions. No role is attributed to a named institution until a
  real agreement or public-authority record confirms it.
- AI remains a production capability but every project starts AI-disabled.
  Only the protected super administrator may enable a project, start or stop a
  run, approve datasets, validate results, and publish, unpublish, or retract a
  layer. Inputs are allowlisted approved project GIS data and imagery. Account
  profiles, contact details, credentials, sessions, device tokens,
  notifications, unrelated projects, and private/unsynchronized drafts are
  excluded. General, cross-project, or third-party model training is prohibited
  without a new separately approved decision.
- Contributors retain rights they actually hold and grant the operator and
  responsible project institution the non-exclusive rights needed to receive,
  store, secure, validate, transform for GIS interoperability, review, analyze
  in the approved project AI workflow, back up, export, and—only after a
  separate institutional publication decision—publish accepted contributions.
  The permission for an accepted official GIS record survives account deletion
  only for the approved record-retention period. TerraLeb does not claim
  ownership of third-party or institutional source data merely because it was
  uploaded.
- Public publication is not authorized by signup acceptance. It requires
  recorded project/institution authority, source rights, sensitivity review,
  and protected-super-admin approval. Sensitive locations default to private.
- Account deletion remains reviewed and asynchronous for every role except the
  protected super administrator. Deactivation stays separate and
  contributor-only. A protected administrator may explicitly choose to discard
  unfinished work and release or transfer responsibilities; no destructive
  choice is preselected.
- Completed deletion removes direct identifiers, credentials, sessions, device
  tokens, private profile fields, local account data, drafts, pending and
  unapproved content, unnecessary attachments, and personal export artifacts.
  Accepted GIS and only the minimum approved review/provenance record needed for
  institutional integrity may remain. Retained identity displays as a one-time
  Unicode-safe pseudonymous masked label such as `A. H.` to authorized project
  users and protected administrators; public layers and general exports show
  `Contributor`. No full name is retained to recreate the label, and internal
  UUIDs are not public identifiers.
- Rejected/private photos and content follow their shorter deletion period.
  Accepted photos and exact locations follow the accepted project record's
  sensitivity and retention decision and are never made public automatically.
  Structured identity snapshots are scrubbed. Arbitrary free text is not
  silently rewritten; possible direct identifiers create a restricted review
  task.
- Backups expire after 35 days. They are not destructively rewritten, and the
  deletion ledger prevents erased identities from being restored into active
  state. A legal hold is disabled by default and requires a case-specific,
  encrypted, access-audited record with an expiry reviewed every six months.
- Notification previews are privacy-preserving by default. Push is optional;
  disabling push does not disable in-app notifications.
- No advertising, behavioral analytics, marketing tracking, or SMS possession
  verification is part of v1. Phone numbers are format-validated only.

## Adopted retention schedule

| Record | Trigger | Duration | Expiry action |
|---|---|---:|---|
| Verification and password-reset challenges | Expiry or successful use | 30 days | Delete codes, hashes, and delivery metadata. |
| Inactive unverified account shell | Last activity | 30 days | Delete unused account/contact data unless separately retained abuse evidence applies. |
| Expired or revoked sessions | Expiry or revocation | 30 days | Delete; keep only a non-reversible security event when necessary. |
| Device token | Logout, deletion, revocation, or invalid-token response | Disable immediately; delete within 7 days | Delete token and destination. |
| Notification | Creation | 180 days | Delete body and user copy; keep only required minimal audit evidence. |
| Routine application/log data | Event | 30 days | Delete or aggregate. |
| Restricted security event | Event | 1 year | Delete or aggregate unless a valid hold applies. |
| Audit and administrator decision history | Event | 7 years | Delete or restricted archive review unless a valid hold applies. |
| Closed privacy or moderation case | Closure | 3 years | Delete submitted PII/detail; retain minimal fulfillment/outcome evidence. |
| Personal-data export artifact | Successful generation | 24 hours | Delete encrypted artifact; retain fulfillment/access evidence for 2 years. |
| Ordinary project export artifact | Generation | 7 days | Delete artifact; retain non-PII provenance metadata for 2 years. |
| Temporary import or quarantine upload | Completion or failure | 30 days | Delete temporary file. |
| Rejected import source | Final rejection | 90 days | Delete source; retain minimal rejection/provenance evidence. |
| Approved import source artifact | Project archive | Active project plus 2 years | Delete source artifact. |
| Approved import provenance metadata | Project archive | Active project plus 10 years | Review and delete at expiry. |
| Unsynchronized/private draft | Last activity or completed account deletion | 90 inactive days, or immediately on completed deletion after warning | Delete server and affected-owner local copy. |
| Rejected/private photo | Final rejection | 90 days | Delete file and thumbnails unless a valid case/hold applies. |
| Accepted GIS/photo/review/comment/provenance | Project archive | Active project plus 10 years | Retain under sensitivity and masked-identity controls, then review/delete. |
| Published GIS provenance/decision | Publication withdrawal | While published plus 10 years | Review/delete; never expose a deleted user's UUID. |
| Temporary or failed AI artifact | Completion or failure | 30 days | Delete; no training reuse. |
| Approved AI model/dataset/evaluation provenance | Model retirement or publication withdrawal | 10 years | Restricted review/delete. |
| Database/object backup | Creation | 35 days | Automatic expiry with restore suppression for deleted identities. |
| Approved legal hold | Hold start | Case-specific; review every 6 months | Release and delete promptly when the hold ends. |

This schedule is the owner's operational choice. Production automation may be
enabled only after each implemented cleanup path is tested and the final
operator/counsel approval references are configured. A missing cleanup path
remains blocked; it is not deemed complete by this decision record.

## Still requiring external evidence

The following are facts or acts that this owner decision does not create:

1. Exact legal operator name, legal form/authority, serviceable address, and
   accountable people.
2. A controlled production domain and monitored public support/privacy contact.
3. Executed OCI, Firebase/Google Play, ArcGIS, SMTP, and Earth Engine terms,
   account ownership, regions, and provider evidence.
4. Exact online/offline map source and attribution evidence, including the
   Copernicus/OSM-derived package manifest.
5. Final Android identifier, signing custody, Firebase registration, Play
   declarations, and signed-build evidence.
6. Qualified Lebanese counsel's governing-law, dispute, Law No. 81,
   public/institutional record, translation, and final policy conclusions.
7. Provider-backed staging/pilot evidence and authorization of the exact
   build, configuration, policy hashes, and rollback plan.

Until these items are evidenced, legal documents remain owner-reviewed drafts,
production legal enforcement/deletion remains fail-closed where configured,
and `productionAuthorized` remains `false`.
