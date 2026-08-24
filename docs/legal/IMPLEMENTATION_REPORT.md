# TerraLeb privacy, moderation, export and deletion implementation report

Status: **engineering implementation complete; public production release blocked pending owner/counsel decisions and staging evidence**

Technical review date: 2026-08-16

This report is engineering evidence, not legal advice and not a conclusion that
TerraLeb is legally compliant. Final policies, lawful bases, retention periods,
territorial conclusions, contracts, map rights, store declarations and the
production activation decision require approval by TerraLeb's designated legal
owner or qualified Lebanese counsel.

## 1. Architecture and compliance summary

The implementation preserves the existing Node/Express, PostgreSQL, Flutter,
offline-sync, REST and role model. It adds:

- versioned public legal documents and exact Terms/Acceptable Use acceptance;
- user privacy requests and content reports with status history and evidence;
- a protected-super-admin Privacy & moderation workspace with paginated queues;
- canonical, allowlisted profile correction;
- asynchronous encrypted personal-data exports;
- reviewed, role-aware and idempotent account deletion;
- non-authenticatable relational tombstones and one-time pseudonymous contributor
  labels such as `A. H.`;
- targeted WebSocket invalidation and privacy-preserving notifications;
- approval-backed retention cleanup and backup-expiry scheduling;
- map/source provenance, AI authority and mobile/store privacy controls; and
- fail-closed production configuration and legal-readiness gates.

REST remains authoritative. Real-time messages contain identifiers and scope
revisions only; they do not contain request descriptions, contact details,
export contents or other sensitive records. Background execution uses the
existing durable workload queue and worker.

The production legal gate currently reports **44 unresolved findings**. Export
and deletion code is testable in development, but production activation remains
blocked until the required approvals, keys, policy references and release
evidence are configured.

## 2. Files changed

The work spans the following principal file groups. The exact worktree inventory
is available with `git status --short`; unrelated pre-existing user changes were
preserved.

- API privacy/legal controllers and routes:
  `apps/api/src/controllers/privacy.controller.ts`,
  `apps/api/src/controllers/legal.controller.ts`,
  `apps/api/src/routes/privacy.routes.ts`,
  `apps/api/src/routes/legal.routes.ts`, and `apps/api/src/app.ts`.
- Execution services and worker:
  `apps/api/src/services/accountDeletion.service.ts`,
  `apps/api/src/services/privacyExport.service.ts`,
  `apps/api/src/services/privacyIdentity.service.ts`,
  `apps/api/src/services/dataRetention.service.ts`,
  `apps/api/src/jobs/workloadWorker.ts`,
  `apps/api/src/jobs/runWorkloadWorker.ts`, and the worker health modules.
- Authentication, notifications, audit, real-time and configuration under
  `apps/api/src/{middleware,lib,realtime,config}` plus the root/API environment
  examples.
- API contract and tests: `apps/api/docs/openapi.yaml`,
  `apps/api/scripts/check-openapi.js`, and the privacy, legal, retention,
  real-time, worker-health, security, integration and performance suites in
  `apps/api/test/`.
- Flutter privacy/legal domain, data and screens under
  `apps/mobile/lib/features/legal/`, profile/authentication/shell integration,
  local cleanup under `apps/mobile/lib/core/privacy/`, API deleted-account
  handling and scoped real-time integration.
- Flutter responsive dialog actions, permissions, notification privacy,
  attribution/offline-source controls and their tests.
- Android/iOS permission and privacy metadata, including
  `AndroidManifest.xml`, `Info.plist` and `PrivacyInfo.xcprivacy`.
- Docker/edge configuration: `docker-compose.yml`,
  `docker-compose.dev.yml`, `compose.prod.yml`, Nginx configurations and
  observability alerts.
- Governance sources, runbooks, decision registers and this report under
  `apps/api/docs/legal/` and `docs/legal/`.

## 3. Database migrations added

Previously deployed migrations were not edited.

- `0057_realtime_scope_revisions.sql`: durable, non-sensitive scope revisions.
- `0058_mutable_entity_versions.sql`: optimistic versions for mutable projects
  and categories.
- `0059_compliance_governance.sql`: legal versions/acceptance, privacy requests,
  content reports, retention, GIS provenance, AI authority and notification
  privacy foundations.
- `0060_compliance_governance_extensions.sql`: additive compatibility extension
  for retention holds/evidence, GIS provenance and governance objects.
- `0061_privacy_request_execution.sql`: histories, queue indexes, encrypted
  export artifacts/grants, deletion executions, tombstone constraints,
  correction/free-text tasks and backup schedules.
- `0062_masked_contributor_read_model.sql`: masked-label support in the existing
  productivity read model and deleted-contact trigger behavior.
- `0063_privacy_request_submitted_state.sql`: separates user submission from
  administrator-opened review while retaining backward compatibility.

The migration chain and stored checksums pass, with no pending migrations in the
live development stack.

## 4. Protected-super-admin workflows

Only the protected super administrator can access the Privacy & moderation
workspace or its API. It provides:

- separately paginated privacy-request and content-report queues;
- server-side status/type/search filters and stable sorting;
- queue and overdue counts;
- request/report details, histories and safe related-task evidence;
- assignment, user-facing response and internal resolution notes;
- required resolution summaries for terminal decisions;
- loading, empty, error and retry states; and
- responsive phone/tablet/desktop dialogs using centered equal-width actions
  when two actions fit, with accessible stacking when they do not.

Hidden navigation is not an authorization boundary: all endpoints also apply
the existing protected-super-admin middleware.

## 5. Content-report moderation

Reports preserve their submitted reason/description and can concern projects,
features, photos, imports, comments, AI outputs or users. Target existence and
the reporter's project access are checked without revealing unrelated private
project information.

Supported recorded outcomes are limited to unsupported/dismissed, corrected,
restricted or unpublished through an existing authoritative workflow, and
independently confirmed action. A report never automatically hides or deletes
content. Administrators must perform the actual project/content mutation through
the existing owning workflow before resolving the report. This avoids bypassing
entity authorization and business rules or inventing a new moderation policy.

The reporter receives only a safe user-facing response. Protected queue updates
and requester updates are targeted through existing real-time scopes.

## 6. Correction workflow

Correction requests currently allow only `full_name`. Role, access, email and
arbitrary fields are rejected; phone changes continue through the existing
verified ownership flow. Approval calls the canonical profile service and its
normal validation. Audit evidence records the request and safe field/change
metadata without storing password, token or unnecessary contact values.
Downstream-correction tasks are available for approved processors where needed.
Completing an administrative status alone cannot falsely complete the request.

## 7. Personal-data export design

Access export requires reauthentication and protected-super-admin approval. The
durable worker builds structured JSON with a human-readable manifest containing
only the requester's profile and recorded activity. It excludes password hashes,
tokens, security/authorization internals, confidential moderation notes and
other users' personal data.

Artifacts are generated outside the HTTP request, capped in size, encrypted at
rest with AES-256-GCM, stored outside public static routes, checksummed and
validated before the privacy request can become `completed`. Downloads require
the authenticated owner, the exact current session and a single-use ten-minute
grant. The response is streamed through authenticated REST. Expired files and
grants are deleted by maintenance. Generation, use, expiry, failure and deletion
are recorded. Production requires an explicit encryption key, key identifier,
approved TTL and retention approval reference.

## 8. Account deletion and masked identity

Deletion is a reviewed request, distinct from contributor deactivation. The
protected super administrator cannot be deleted. Other roles can request
deletion after reauthentication.

Immediately before execution, the worker locks the execution/request/account
rows and recalculates eligibility. Contributors are blocked by active or pending
assignments, unsynchronized/private drafts, pending submissions/reviews and
unresolved institutional work. Administrators require protected-super-admin
review and a valid transfer target for transferable project, AI, moderation and
privacy responsibilities. The job is retry-safe and records each mandatory
stage; the request completes only after all stages succeed.

The full name is converted once, before erasure, to a Unicode-aware
pseudonymous label (for example `Ali Hassan` to `A. H.`). The full name is not
kept to regenerate it. The internal immutable user ID remains only where needed
for relational integrity. The tombstone has no usable credentials or contact
fields, cannot authenticate or reactivate, and does not use a fake email/phone.
The masked label is explicitly **pseudonymous, not anonymous**.

## 9. Exact data deleted and retained

On successful execution, the pipeline removes or nulls:

- password hash, email/canonical email, phone, verification/contact state and
  pending contact changes;
- profile name, picture, last-login value and other direct account fields;
- password-reset records, contact-verification challenges/audit events;
- sessions, refresh families represented by those sessions, device/push tokens
  and notifications;
- the deleted user's private draft spatial features; and
- structured copies of known name/email/phone values in supported audit,
  request, notification and metadata snapshots.

It retains, subject to still-required legal approval:

- the non-authenticatable internal tombstone ID and masked label;
- submitted GIS contributions and their accepted/rejected review state;
- institutional comments, approvals/rejections, collected-by/review relations;
- import/export provenance, AI validation/publication decisions; and
- required audit/evidence records stripped of direct identifiers where the
  implemented structured scrubber applies.

Arbitrary free text is not automatically rewritten. Potential name/email/phone
matches create restricted privacy-review tasks to avoid corrupting evidence.
Backups are not destructively rewritten; a backup-expiry schedule is recorded
and remains `awaiting_approved_policy` until an approved maximum age and restore
suppression procedure exist. Legal-hold identity storage remains disabled unless
an approved policy is configured.

The Flutter client receives targeted revocation/deletion state, clears only the
affected account's credentials, encrypted drafts, cached personal records,
photos and memory image cache, and resumes cleanup safely after interruption.
It does not clear another account's data on a shared device.

## 10. Authorization, security and real-time controls

- Protected queues are server-authorized and ordinary admins/contributors are
  denied.
- Requests, export grants and downloads enforce owner/session binding and prevent
  IDOR/cross-user access.
- All inputs are allowlisted/validated and SQL is parameterized.
- Queue queries are paginated and indexed; Flutter never loads the full queue.
- Logs, metrics, errors and real-time events omit erased PII and export content.
- Privacy/user/admin real-time scopes are targeted and coalesced; no polling was
  introduced.
- Import/export foreground polling remains only behind the disabled
  `REALTIME_POLLING_FALLBACK_ENABLED` rollout fallback. OTP countdown and actual
  offline-sync scheduling remain intentionally unchanged.
- Production account deletion defaults off and requires policy/retention approval
  references. Production export requires encryption and retention configuration.
- Worker dead-letter handling records failure history, notifies safely and never
  marks incomplete execution completed.
- The worker now has a dedicated event-loop heartbeat healthcheck instead of the
  API image's invalid HTTP probe.

## 11. Performance measurements

Local performance tests passed:

- indexed bbox request: 85 ms (2,000 ms test limit);
- export generation/download readiness: 487 ms (30,000 ms test limit);
- concurrent bounded GIS workloads: 4,432 ms;
- crashed-lease worker recovery: 1,100 ms.

Privacy queues use server pagination and compound queue indexes; exports and
deletions run in the background. An idle WebSocket uses network ping/pong and no
application HTTP polling or per-connection heartbeat database query.

No trustworthy pre-change staging baseline was supplied. Therefore the requested
less-than-5% before/after comparison, twice-peak connection test and staging
event-to-visible-update p95 below one second are **not claimed** and remain
production-release evidence items.

## 12. Tests and commands run

Passing verification on 2026-08-16:

- API lint, TypeScript typecheck, build and OpenAPI coverage check; all 178
  Express operations are documented.
- 47 non-performance API suites passed in bounded serial groups; 1 optional
  Redis two-replica suite was skipped because `PHASE4_REDIS_URL` was not supplied
  to Jest (no failure). The groups include privacy rights/execution, correction,
  cross-user export isolation, deletion transfer/tombstone/masking, legal pages,
  retention, auth/security, imports, AI, offline sync, storage and real-time.
- Dedicated workload health regression tests: 2/2.
- API performance suites: 3/3 suites and 4/4 tests.
- Legal release-gate tests: 4/4; the actual gate correctly blocks with 44
  unresolved findings.
- Flutter formatting and static analysis passed; full unit/widget suite passed
  400/400, including protected workspace, responsive/accessibility dialogs,
  account cleanup, session binding, scoped real-time and existing workflows.
- Migration preparation/integrity: no pending migration and no checksum mismatch.
- Docker images built with zero production dependency audit findings; live API,
  migration and workload-worker startup succeeded.
- Direct and Nginx public legal routes returned HTTP 200; an actual Nginx
  WebSocket upgrade succeeded.
- All base/development Compose syntax checks passed. Production Compose retains
  required deployment variables and must be rendered with the production env/
  secrets inventory.

The repository's monolithic `npm run test:ci` exceeded the command harness's
ten-minute window because the end-to-end group alone takes about 7m53s. It did
not yield a summary and is not counted as a pass; every API test file was then
run in bounded groups as recorded above.

## 13. Remaining legal decisions and risks

`LEGAL_DECISIONS_REQUIRED.md` is authoritative. Blocking decisions include the
operator/controller and privacy contact; controller/processor roles; public
distribution; minimum age/minors; required languages; production hosting regions
and subprocessors; approved retention and backup age; lawful/institutional basis
and visibility for retained GIS records/masked labels; photos, precise location
and free-text treatment; map/offline/export rights; GIS ownership/publication;
AI training/publication; government/public-record duties; store declarations;
policy wording; governing law/disputes; and counsel approval.

Lebanon-only targeting is recorded as the owner's direction, but storefront
configuration and counsel approval are still required. Engineering must not
enable deletion/export enforcement or present draft policies as final merely to
clear the gate.

Operational risks still requiring deployment evidence are backup restore
suppression, real provider/license validation, store signing/review, production
accessibility review, staging peak/reconnect testing, incident exercises and
formal moderation/privacy staffing targets.

## 14. Deployment and rollback

Deployment order:

1. Resolve and approve every blocking legal decision; publish only verbatim,
   versioned, counsel-approved documents and store immutable approval references.
2. Approve vendors/regions, map rights, record classes, retention/backup policy,
   masked-label visibility, store disclosures and operational owners.
3. Back up and verify the database, then apply additive migrations 0057-0069.
4. Provision export encryption key/key ID, private export storage, approved TTL
   and retention reference; keep files outside public routes.
5. Deploy API and worker, verify migration integrity and worker health, then
   deploy Nginx and mobile clients.
6. Pilot the protected queues, corrections, exports, automatic responsibility release,
   revocation/local cleanup and real-time events in staging.
7. Run staging load/reconnect/latency, accessibility, store, backup-restore and
   incident exercises.
8. Enable `ACCOUNT_DELETION_EXECUTION_ENABLED` only with the approved policy and
   retention references. Disable legacy/polling fallbacks only after the real-time
   pilot is stable.

Rollback is configuration/artifact based: turn off deletion execution and legal/
provenance enforcement, restore the previous API/mobile artifact and temporarily
enable the documented real-time polling fallback if necessary. Do not drop
0057-0069 or erase request, acceptance, audit, export, deletion, provenance or
retention evidence. Already deleted accounts must never be reactivated by
rollback. Keep restricted offline map sources disabled.

## 15. Existing feature or behavior changes

### Privacy/moderation administration

- Previous: protected endpoints existed but no complete super-admin UI or
  executable privacy workflow.
- New: protected paginated workspace, histories, responses, required summaries,
  canonical corrections, async exports and reviewed deletion execution.
- Why: an administrative status alone cannot prove fulfillment or safely perform
  sensitive actions.
- Compatibility: existing roles and content workflows remain; ordinary admins
  gain no new privacy access.
- Tests: protected-role isolation, pagination/filtering, execution and responsive
  workspace tests.
- Deployment/training: assign protected privacy/moderation operators and train
  them to use authoritative entity workflows and evidence references.

### Account deletion and retained contributions

- Previous: deletion completion was fail-closed because no execution pipeline
  existed; deactivation was the only account-access action.
- New: deletion is a separate reviewed request. Direct identifiers/credentials
  are erased, while approved institutional relations can remain on a deleted
  tombstone using a pseudonymous masked label.
- Why: deletion must not silently abandon responsibilities, leave an account
  authenticatable or falsely label retained relational data anonymous.
- Compatibility: contribution/review integrity is preserved; protected super
  admin cannot be deleted; production execution remains disabled until approval.
- Tests: role eligibility and automatic responsibility release, protected account rejection, Unicode labels,
  no fake identifiers, tombstone constraints, retries/rollback, snapshots,
  backup schedule, sessions/devices and Flutter local cleanup.
- Deployment/training: counsel must approve retained classes, visibility and notices;
  active work that cannot be released automatically must be resolved before approval.

### Personal-data export and correction

- Previous: users could submit requests, but no isolated export artifact or
  authoritative correction completion existed.
- New: name corrections use the profile service; exports are worker-generated,
  encrypted, validated and downloaded with owner/session-bound one-use grants.
- Why: queue status changes cannot safely modify accounts or expose personal
  data.
- Compatibility: verified phone and fixed-email rules remain unchanged.
- Tests: correction allowlist, canonical update, artifact completion gate,
  cross-user/session isolation, expiry and deletion.
- Deployment/training: manage encryption keys and teach the protected operator
  which profile fields require separate verification.

### Content reporting

- Previous: reports could be submitted but lacked a complete operational review
  interface and evidence rules.
- New: protected queue, histories, safe reporter responses and explicit outcomes.
  Resolved reports identify the completed action without storing a separate
  workflow-reference field.
- Why: a report must never automatically remove content or bypass owning-service
  authorization.
- Compatibility: project, feature, photo, import, AI and user business rules are
  unchanged.
- Tests: private-target isolation, state transitions, required outcomes
  and protected workspace coverage.
- Deployment/training: define staffing and escalation targets and train operators
  to complete authoritative domain actions before resolving reports.

### Session revocation and local data cleanup

- Previous: account deletion had no end-to-end multi-device cleanup.
- New: targeted revocation logs out affected sessions and clears only that
  account's local encrypted/cached data, including memory image cache, with
  interruption-safe resume.
- Why: deleted credentials and private offline data cannot remain active.
- Compatibility: other users' shared-device data and normal offline sync remain.
- Tests: exact session binding, multi-account isolation, revocation/logout and
  cleanup resume.
- Deployment/training: no special user training beyond the deletion notice.

### Worker container health

- Previous: the background worker inherited an API HTTP healthcheck and was
  always marked unhealthy despite running normally.
- New: a private heartbeat file proves the worker event loop is alive; no network
  endpoint is exposed.
- Why: deployment orchestration and alerts otherwise report a false outage.
- Compatibility: job scheduling/processing is unchanged.
- Tests: marker freshness tests, Compose validation and live Docker healthy state.
- Deployment/training: monitor worker health separately from API readiness.

### Previously introduced legal, notification, map and AI safeguards

- Previous: public legal versioning/acceptance, notification-preview privacy,
  universal map attribution/offline-source restrictions, structured import
  provenance and separate AI training/publication authority were incomplete.
- New: those safeguards remain in place and are covered by the release gate.
- Why: transparency, permission minimization, provider rights and separate data-
  use authority cannot be inferred from generic Terms.
- Compatibility: existing features remain available except unlicensed offline
  sources and unapproved AI/publication actions remain fail-closed.
- Tests: legal/public-page, push privacy, attribution/offline, import provenance,
  AI authority and full Flutter suites.
- Deployment/training: publish approved documents, configure licensed providers
  and record the required authority evidence before enforcement.

Passing engineering tests does not itself establish legal compliance.
