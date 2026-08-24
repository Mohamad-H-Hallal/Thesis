# TerraLeb legal, privacy, platform and release blocker assessment

> **Owner decisions now available:** the companion
> [`TERRALEB_OWNER_DECISIONS_AND_BLOCKER_CLOSURE_FORM.md`](TERRALEB_OWNER_DECISIONS_AND_BLOCKER_CLOSURE_FORM.md)
> supplies the proportional Lebanon-only v1 owner-policy answers, the complete
> 44-gate disposition, and the exact remaining engineering, evidence and counsel
> work. The later costed implementation report
> [`TERRALEB_REVISED_OWNER_POLICY_COST_AND_DEPLOYMENT_PLAN.md`](TERRALEB_REVISED_OWNER_POLICY_COST_AND_DEPLOYMENT_PLAN.md)
> supersedes any earlier proposal to remove AI or map modes. This assessment is
> retained only as the audit of the earlier supplied answer; its recommendations
> must be read in that historical context.

**Assessment date:** 2026-08-16

**Repository:** `D:\GIS_APP`

**Input reviewed:** `C:\Users\User\Downloads\TERRALEB_ANSWERS.md`

## Purpose and limits

This document assesses the supplied Claude answer against the actual TerraLeb
repository, the current release gates, and authoritative platform and technical
sources. The attachment was treated as evidence and advice to assess, not as an
instruction to change code, configuration, legal documents, or release status.

This is compliance engineering, not legal advice. It does not establish that
TerraLeb is legally compliant. The legal operator, lawful bases, retention
periods, public-record duties, and final policy wording require approval by the
designated legal owner and qualified Lebanese counsel.

No release-readiness boolean was changed. No legal draft was approved. No
production feature flag was enabled. The repository had extensive pre-existing
uncommitted work, so it was not pulled, committed, reset, or pushed for this
read-only assessment.

## Executive conclusion

The supplied answer is a useful decision-organizing draft, but it is **not
sufficient to close TerraLeb's production blockers**.

The strongest parts are:

- separating engineering facts, owner choices, and counsel decisions;
- recommending Android and web as a possible v1 scope while deferring iOS;
- recommending no AI training by default;
- recommending no analytics SDKs unless deliberately approved;
- recommending Play App Signing, a protected release environment, real staging,
  physical-device testing, and named approvers;
- recommending an OSM-derived production basemap and disabling unlicensed Esri
  offline use;
- identifying the likely Law No. 81 article-numbering problem; and
- keeping deletion completion fail-closed until retention and attribution rules
  are approved.

The material errors or unsafe assumptions are:

- “seven counsel-only items” does not replace the repository's **44 current
  production-readiness findings** or the separate Phase 7 external gates;
- AI is already a substantial shipped workflow, not merely an unused schema flag;
  removing all AI from v1 is a product-scope change;
- phone/contact assurance is part of registration; dropping the phone field or
  changing its assurance policy is not a zero-cost vendor simplification;
- the proposed three GitHub variables and five secrets do not match the actual
  release workflow;
- Firebase signing fingerprints are not required for standalone FCM delivery;
  Firebase documents SHA-1 as required for Google/phone Firebase Authentication
  and Dynamic Links, which TerraLeb does not currently use for authentication;
- the proposed deletion attribution-snapshot schema is unnecessary and conflicts
  with the implemented tombstone and one-time masked-initial design;
- a 30-day grace period and 90-day deletion target are unapproved and conflict
  with TerraLeb's current ten-day internal privacy-request target;
- the OSM public tile policy does not categorically prohibit every real app, but
  it prohibits bulk/offline prefetch, requires attribution and identifiable
  requests, provides no SLA, and may block harmful traffic;
- online Esri is still selectable in the app, so saying “Esri off for v1” does not
  close anything until it is licensed or technically disabled;
- `lb.terraleb.app` is only acceptable after the operator proves control of the
  corresponding naming/domain strategy; it is not automatically safe;
- Android `minSdk` cannot be chosen as 24 or 26 from preference alone; the actual
  supported-device inventory and dependency floor must decide it; and
- the current readiness schema cannot represent “not applicable.” It would still
  block an Android/web-only release on Apple and disabled-Esri booleans unless the
  gate is carefully versioned to accept evidence-backed `not_applicable` states.

The correct overall result is therefore:

> **Use the attachment as a proposal pack, adopt the verified engineering parts,
> correct the factual errors, record owner choices, obtain Lebanese counsel's
> conclusions, complete external configuration and evidence, and keep production
> fail-closed until all applicable gates pass.**

## Evidence hierarchy used

When sources disagreed, this assessment used the following order:

1. Actual repository code, migrations, tests, workflows and current gate output.
2. Official regulator, platform, standards-body and provider documentation.
3. TerraLeb's engineering drafts and runbooks.
4. The supplied Claude answer.

Key repository sources include:

- [`release-readiness.json`](../../apps/api/docs/legal/release-readiness.json)
- [`legal-documents.json`](../../apps/api/docs/legal/legal-documents.json)
- [`LEGAL_DECISIONS_REQUIRED.md`](LEGAL_DECISIONS_REQUIRED.md)
- [`OWNER_AND_COUNSEL_QUESTIONNAIRE.md`](OWNER_AND_COUNSEL_QUESTIONNAIRE.md)
- [`RETENTION_MATRIX.md`](RETENTION_MATRIX.md)
- [`ACCOUNT_DELETION_AND_PSEUDONYMIZATION.md`](ACCOUNT_DELETION_AND_PSEUDONYMIZATION.md)
- [`STORE_DISCLOSURES.md`](STORE_DISCLOSURES.md)
- [`GIS_SOURCE_LICENSE_REGISTER.md`](GIS_SOURCE_LICENSE_REGISTER.md)
- [`AI_PROVENANCE_REGISTER.md`](AI_PROVENANCE_REGISTER.md)
- [`phase-7-release-candidate-pilot.md`](../predeployment/phase-7-release-candidate-pilot.md)
- [`.github/workflows/release-candidate.yml`](../../.github/workflows/release-candidate.yml)

Authoritative external references used include:

- [Lebanese Parliament publication for Law No. 81/2018](https://www.lp.gov.lb/PublicationDetails?Id=544)
- [English translation of Law No. 81/2018](https://smex.org/wp-content/uploads/2018/10/E-transaction-law-Lebanon-Official-Gazette-English.pdf), used only as a working translation pending counsel review of the Arabic Official Gazette text
- [Google Play User Data and account deletion policy](https://support.google.com/googleplay/android-developer/answer/10144311)
- [Google Play account deletion guidance](https://support.google.com/googleplay/android-developer/answer/13327111)
- [Google Play Data Safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469)
- [Google Play UGC policy](https://support.google.com/googleplay/android-developer/answer/9876937)
- [Google Play testing requirements for newer personal accounts](https://support.google.com/googleplay/android-developer/answer/14151465)
- [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [Firebase Android SHA-1 guidance](https://firebase.google.com/docs/android/troubleshooting-faq)
- [Google Play App Signing guidance](https://support.google.com/googleplay/android-developer/answer/9842756)
- [Android application ID guidance](https://developer.android.com/build/configure-app-module)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/)
- [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/)
- [NIST Privacy Framework](https://www.nist.gov/privacy-framework)
- [NIST SSDF SP 800-218](https://www.nist.gov/publications/secure-software-development-framework-ssdf-version-11-recommendations-mitigating-risk)
- [NIST AI Risk Management Framework](https://www.nist.gov/itl/ai-risk-management-framework)
- [ISO/IEC 27001:2022 overview](https://www.iso.org/standard/27001)

## Current verified state

### Production legal gate

Running:

```powershell
node scripts/verify-legal-readiness.js --allow-incomplete
```

returns:

```text
TerraLeb legal production-readiness gate: BLOCKED (44 findings)
```

The 44 findings are composed of:

- 1 final production authorization;
- 1 counsel approval and evidence reference;
- 18 legal/product decisions;
- 2 store disclosure approvals;
- 11 platform-readiness verifications;
- 4 map/license verifications; and
- 7 approved English legal documents.

### Current policy documents

Seven English documents exist, but every one is a draft, has no effective date,
and has `counselApproved=false`:

- Privacy Notice
- Terms of Use
- Acceptable Use Policy
- Important Notices
- Account Deletion Notice
- Subprocessor Notice
- Open-Source Notices

The public routes and versioned document infrastructure exist. Draft documents
must remain non-production. Production configuration intentionally rejects
`LEGAL_DRAFTS_PUBLIC_ENABLED=true`.

### Current deletion implementation

Deletion engineering already exists behind
`ACCOUNT_DELETION_EXECUTION_ENABLED=false`. It includes reviewed requests,
reauthentication, eligibility checks, automatic responsibility release, an idempotent
worker, session/device revocation, removal of direct identifiers, structured
snapshot scrubbing, restricted free-text review tasks, a backup-expiry record,
a non-authenticatable tombstone, and a one-time Unicode-aware masked label such
as `A. H.`.

The immutable user ID is retained only where needed for relational integrity and
is not intended as a public identity. The masked label is pseudonymous, not
anonymous. Production execution correctly remains blocked pending approval of
the retained-record basis, exact record classes, retention, label visibility,
photos/location/free-text treatment, backup ageing, and user-facing wording.

### Current product facts that affect the answer

- AI runs, readiness, validation, review and publication are real product
  workflows. AI training reuse is separately controlled and must remain off
  without authority.
- Email and phone are registration fields. Production supports an explicitly
  selected format-only or provider-backed SMS assurance mode; removing the phone
  field or changing that policy would affect authentication and disclosure and
  must not be treated as vendor cleanup.
- Android and iOS source projects both exist. Android still uses a
  `com.example.*` fallback; iOS bundle identifiers are also placeholders.
- Android requests foreground coarse/fine location and notification permission.
  It does not currently declare background location or Android camera permission.
  iOS has camera/photo purpose strings and a privacy manifest source file.
- OSM online tiles and Esri World Imagery are both selectable. Esri offline
  downloading is fail-closed unless
  `LICENSED_ESRI_OFFLINE_BASEMAP_ENABLED=true`.
- Content reports support projects, features, photos, imports, comments, AI
  output and users, with a protected-super-admin queue. For an institutional
  app with identified users, Google Play requires in-app reporting of content
  and users; user blocking becomes specifically required for one-to-one or
  publicly accessible UGC experiences.

## Assessment of the supplied answer

### Part A - release preparation

| Item | Verdict | What may be used | Required correction or evidence |
|---|---|---|---|
| A1 GitHub authentication | Accept with correction | Browser/device-flow login, `gh auth status`, no token in chat, and use of scoped automation credentials are sound. | Do not run `gh auth logout` unless the existing account is wrong or stale. OS-keyring storage is not guaranteed on every host. `shred` is not a reliable Windows/SSD deletion instruction. Use the existing authenticated session or approved credential manager and least privilege. |
| A2 Android + web; defer iOS | Owner decision | This is a reasonable v1 scope proposal and matches the lack of a current macOS/iOS signing environment. | It excludes iOS users and cannot be silently adopted. Record the owner decision and pilot-device evidence. Update the readiness schema to represent Apple items as evidence-backed `not_applicable`; never mark Apple “approved” when no Apple release was reviewed. Keep iOS source intact. |
| A3 app ID/version | Accept with correction | Finalize the ID before first publication; [Android treats a changed ID as a different app](https://developer.android.com/build/configure-app-module). Monotonic version codes are required. | `lb.terraleb.app` is only a proposal. Confirm operator/domain authority and naming ownership. The current workflow requires `ANDROID_VERSION_CODE` as an explicit protected variable; it does not derive it from Gradle semantic-version math. The repo, rather than this report, currently rejects `com.example.*` releases. |
| A4 Play signing | Accept with correction | Enrol in Play App Signing, protect the upload key, test recovery, and keep signing material out of Git and logs. | Generate the production upload key once the owner/custodian is known and do not casually regenerate after first publication. Use an approved secret manager and recovery process. Distinguished-name fields are operational metadata, not proof of legal identity. |
| A5 Firebase | Partially accept | Final package-specific `google-services.json`, separate staging/production isolation, FCM HTTP v1 and protected server credentials are good practices. | The current CI injects one protected file at `apps/mobile/android/app/google-services.json`; per-flavor paths would be a deliberate build change. [Firebase says SHA-1 is required for Firebase Google/phone Auth and Dynamic Links](https://firebase.google.com/docs/android/troubleshooting-faq), not standalone FCM. Register Play fingerprints only for APIs that actually authenticate by them. The claim that a missing Play signing fingerprint causes TerraLeb push failure is unsupported. |
| A6 staging | Accept with architecture corrections | Real DNS/TLS, private storage, malware tests, shared Valkey, push, alerts, off-server backup and restore evidence are mandatory Phase 7 inputs. | TerraLeb's authenticated private-file API is a valid delivery model; signed URLs are not mandatory. Validate the implemented adapter rather than replacing it. Logging and PITR periods feed the retention decision and cannot be enabled indefinitely without an approved policy. |
| A7 GitHub environment | Accept with correction | Create protected `release-candidate`, require independent reviewers, prevent bypass where supported, and scope tag access. | The source branch is `handover-ready`, not `main`. The immutable tag pattern is `vMAJOR.MINOR.PATCH-rc.NUMBER`, not generic `v*.*.*`. Follow the repository workflow and ruleset exactly. |
| A8 variables/secrets | Reject proposed list; replace with repository contract | The concept of three variables and five secrets is correct. | The exact values are listed below. `API_BASE_URL`, `RELEASE_TRACK`, `ANDROID_KEY_ALIAS_PASSWORD`, `PLAY_SERVICE_ACCOUNT_JSON`, and `FIREBASE_SERVICE_ACCOUNT_JSON` are not the workflow contract. |
| A9 device floor | Accept in principle | Test location, offline encrypted storage, photos, interrupted sync, storage pressure, upgrades and battery on real Android hardware. Defer Apple hardware only if iOS is formally out of scope. | Do not arbitrarily set minSdk 24/26. Use the final device inventory, Flutter/dependency floor and support decision. Background-location testing/declaration is not currently applicable because TerraLeb does not request that permission. |
| A10 pilot and approvers | Accept as a proposal | Named independent release/security/operations approvers, a real workflow cohort, a 14-day soak, restore and rollback evidence are appropriate. | For a [personal Play developer account created after 2023-11-13](https://support.google.com/googleplay/android-developer/answer/14151465), Google requires at least 12 opted-in closed testers for 14 continuous days. A “10 user” pilot would fail that condition. Confirm account type. A 99.5% crash-free target also needs an approved measurement source; do not add an analytics SDK merely to produce it. |

### Correct A8 release-candidate contract

Create the GitHub environment named `release-candidate` with these exact
non-secret variables:

```text
ANDROID_APPLICATION_ID
ANDROID_VERSION_CODE
RC_API_BASE_URL
```

and these exact secrets:

```text
ANDROID_KEYSTORE_BASE64
ANDROID_GOOGLE_SERVICES_JSON_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

`RC_API_BASE_URL` must be a real approved HTTPS staging API origin. The Firebase
client configuration must contain the exact final application ID. The workflow
already fails early when required values are absent and verifies the signed AAB,
image, SBOM, attestations and manifests.

### Part B - owner and counsel questionnaire

| Section | Verdict | TerraLeb resolution |
|---|---|---|
| §1 operator/contact | Counsel and owner required | No factual operator identity, legal form, address, privacy contact or representative can be inferred. Do not publish placeholders or the developer's personal information unless that person is legally the operator. |
| §2 territory, channels, age, language | Useful owner proposal, not approved | Lebanon-only is already recorded as owner direction. Android + authenticated web, iOS deferred, 18+, no minors, and Arabic + English are sensible proposals. Record each separately. Counsel must assess travelers/existing users abroad, controlling language and whether geo-restriction representations are accurate. If Arabic is required, the current English-only legal-document gate is insufficient. |
| §3 party roles | Counsel required | Determine operator, project institution, NCRS/CNRS, municipality/ministry, hosting, AI and vendor roles per activity. A single blanket controller/processor label is not adequate. |
| §4 purposes/bases | Factual inventory useful; legal bases unresolved | Use the existing processing register. Counsel must assign the basis and required/optional nature per purpose. Privacy-policy viewing is notice, not bundled consent. Public publication, AI training and marketing need separate authority where enabled. |
| §5 vendors/regions | Reject generic “one EU provider” as an answer | The repository's earlier architecture recommends AWS Bahrain subject to approval; the attachment proposes an unspecified EU provider. Neither is an approved deployment. Name every actual legal entity, region, backup/support location, DPA, deletion commitment and transfer mechanism. Keep no analytics SDKs as the recommended default. Do not drop phone assurance without a separate product/security change. |
| §6 retention/deletion | Reject unapproved 30/90-day values | The current ten-day internal request target remains the safe operating target pending counsel's Article 101 interpretation. Do not adopt a 30-day grace period, immediate account disablement, or 90-day completion without owner/counsel approval and workflow changes. Complete every row of the retention matrix. |
| §7 attribution | Counsel required; attachment design rejected | Keep TerraLeb's implemented tombstone and one-time initials. Do not add a real-name snapshot or switch before counsel approves exact retained record classes and visibility. `Reviewer · NCRS · 2026-03` remains potentially identifying and is not anonymous. |
| §8 GIS/maps | Partially useful | Prefer a contracted/self-hosted OSM-derived provider, retain visible attribution, and keep [public OSM offline prefetch prohibited](https://operations.osmfoundation.org/policies/tiles/). Esri offline stays disabled. Online Esri must also be licensed or disabled. Import provenance enforcement must be enabled only after legacy records and deployment behavior are reviewed. |
| §9 AI | “No training” accepted as proposal; “no AI v1” not accepted | Existing AI inference/validation is a shipped feature. Keep training reuse off. Keep publication and project-training authority fail-closed. If the owner wants to remove all AI from v1, treat that as an explicit product change with compatibility tests and user/deployment notes. |
| §10 moderation | Useful owner proposal | Named owners, response targets, escalation and appeals are needed. Do not auto-delete reported content. Use existing authoritative content workflows. Confirm the institutional UGC classification and demonstrate reports for both content and users. Blocking is additionally required if one-to-one or public UGC is enabled. |
| §11 Terms | Counsel required | Operational clauses may be proposed, but governing law, venue, mandatory-right carve-outs, warranties, liability, indemnity and termination language require counsel. |
| §12 Law No. 81 | Important correction accepted | Correct the questionnaire's Article 96 wording and send the exact processing/data-flow facts to Lebanese counsel. Do not infer an exemption, permit, licence or public-record basis. |
| §13 store evidence | Partially useful | Public Privacy Notice and deletion URLs, Data Safety, signed-binary permission review, SBOM/SDK inventory and accessibility evidence remain required. Closed/open/production Play tracks require Data Safety; exclusively internal testing is exempt. Apple may be out of release scope, but must be represented as not applicable rather than falsely approved. |

### Parts C, D and E

**Part C - “seven counsel items”: not accepted as the release count.** It may be
a useful way to bundle questions into one counsel engagement, but it does not
close the 18 decision rows, store/platform/map evidence, seven legal documents,
final authorization, or Phase 7. Several allegedly owner-only rows still need
legal review or technical enforcement. For example, selecting OSM does not prove
tile-service rights, and selecting “no AI” does not remove the need to disclose
actual deployed processing.

**Part D - new attribution snapshot: do not implement.** TerraLeb migrations and
services already solve relational integrity using a deleted-account tombstone and
one-time masked initials. Adding immutable snapshots containing optional real names
would create another PII store, conflict with the owner's `A. H.` direction, and
expand retention risk. A role/institution/month pseudonym can still single out a
person in a small project. Keep the current design fail-closed.

**Part E - counsel memo: accept.** A concise facts memo with closed decision
options, record-class tables, the Law 81 article question, and exact draft policy
text is better than asking counsel to discover the architecture. Include the full
register as an appendix and require an immutable approval reference for the exact
version reviewed.

## Law No. 81/2018 correction and counsel questions

The [Lebanese Parliament identifies Law No. 81/2018](https://www.lp.gov.lb/PublicationDetails?Id=544)
as the Electronic Transactions and Personal Data law. The [available English
translation](https://smex.org/wp-content/uploads/2018/10/E-transaction-law-Lebanon-Official-Gazette-English.pdf)
indicates:

- Article 88 addresses information to provide to the data subject;
- Article 90 limits retention to the period declared or otherwise authorized;
- Article 94 contains processing exemptions;
- Article 95 concerns notification to the Ministry of Economy and Trade under a
  permit/receipt mechanism;
- Article 96 lists the information in that declaration;
- Article 97 identifies licensing categories including internal/external state
  security, criminal proceedings, and health/genetic/sexual-life processing;
- Articles 99–101 address access and correction/update/erasure; and
- Article 101's English translation refers to ten days for the listed operations
  and notification to third parties.

Therefore the current questionnaire phrase “Article 96 exception or authorization
conclusion” should be corrected. Counsel must verify against the Arabic Official
Gazette text, current amendments, implementing practice and the Ministry's actual
procedure. The English translation is not the controlling legal text.

Counsel should answer at least these concrete questions:

1. Who is the legal operator and controller for each processing activity?
2. Which institutions are controllers, joint controllers, processors or independent
   controllers for project data?
3. Does each TerraLeb processing activity fall within an Article 94 exemption or an
   Article 95 declaration requirement?
4. Does storing or publishing sensitive site/location data trigger Article 97 or
   another security/public-sector authorization?
5. What does Article 101 require for access, correction and erasure, including the
   ten-day wording, exceptions and third-party notifications?
6. What public-record, archival, cadastral, surveying, photography, telecom,
   government-data or institutional rules apply?
7. What basis permits retention of each GIS/review/audit record after account
   deletion, and for how long?
8. Who may see the masked initials: protected administrators, project members,
   authenticated users, exports or the public?
9. How must photos, precise location, free text and legal holds be handled?
10. What notification, permit, licence, cross-border transfer or ministry filing is
    required before pilot and before production?
11. What governing law, venue, mandatory-right, liability and complaint wording is
    valid?
12. Approve the exact Arabic and English public documents and record the controlling
    version.

## Complete 44-finding production gate register

Every item below remains blocked until its evidence is recorded. “Suggested
resolution” is not permission to set a boolean to `true`.

### Final authority and counsel - 2 findings

| ID | Gate | Current status | Suggested resolution |
|---|---|---|---|
| A-01 | `productionAuthorized` | Blocked | Last action only: product/legal owner signs the exact release manifest after all applicable gates pass. |
| A-02 | `counselApproval` | Blocked | Counsel approves exact document versions and legal conclusions; store an immutable approval reference, date, reviewer role and scope. |

### Legal and product decisions - 18 findings

| ID | Gate key | Current status | Suggested answer/action |
|---|---|---|---|
| D-01 | `legalOperatorController` | Unknown | Owner supplies exact entity/legal form/address; counsel confirms role. No safe default exists. |
| D-02 | `controllerProcessorRoles` | Unknown | Complete an activity-by-activity role matrix for operator, project institutions and vendors. |
| D-03 | `targetTerritoriesAndDistribution` | Partial owner direction | Record Lebanon-only. Recommended v1 proposal: Android + authenticated web; iOS deferred. Decide treatment of existing users abroad and enforce store/web representations. |
| D-04 | `minimumAgeAndMinors` | Unknown | Recommended owner proposal: 18+, no minors. Add truthful eligibility wording and store target-audience answers; counsel reviews institutional/student cases. |
| D-05 | `privacyContact` | Unknown | Publish a monitored privacy email/address and accountable owner with escalation and absence coverage. |
| D-06 | `hostingRegionsAndSubprocessors` | Unknown | Select actual vendors/regions through procurement, security and DPA review. Record backup and support-access locations. |
| D-07 | `retentionMatrix` | Unapproved | Approve every row, trigger, duration, action, hold, backup rule and owner. Current technical defaults are facts, not approvals. |
| D-08 | `retainedInstitutionalRecordBasis` | Owner intent only | Counsel identifies the exact basis and record classes for GIS/review/audit integrity. Terms acceptance alone is insufficient. |
| D-09 | `maskedContributorDisplayPolicy` | Owner intent only | Current proposal is one-time initials such as `A. H.`. Approve visibility per record class; never call it anonymous. |
| D-10 | `photosPreciseLocationFreeTextTreatment` | Unknown | Separate rules for private/rejected/accepted photos, location history, snapshots and free text; define review/redaction/takedown and holds. |
| D-11 | `backupAgeingPeriod` | Unknown | Choose from the real backup/PITR architecture; document maximum ageing, restore suppression and deletion propagation. Do not invent a duration. |
| D-12 | `contributorAndDeletionNoticeWording` | Draft only | Counsel approves brief pre-contribution and pre-deletion wording that clearly describes retained pseudonymous records. |
| D-13 | `mapAndOfflineRights` | Unapproved | Contract/self-host an OSM-derived service or approve compliant public-tile online use; keep OSM bulk/offline off; license or disable every Esri online/offline path. |
| D-14 | `gisOwnershipAndPublication` | Unknown | Define ownership/custodianship, limited hosting/processing licence, importer warranties, publication authority, sensitive-site review and takedown. |
| D-15 | `aiTrainingAndPublication` | Partial technical safeguards | Recommended: no AI training reuse by default. Separately decide inference/validation and public publication, with model/data provenance and human accountability. |
| D-16 | `governingLawAndDisputes` | Unknown | Counsel drafts governing law, venue/dispute, mandatory-right carve-outs, warranties and liability. |
| D-17 | `requiredLanguages` | Unknown | Recommended: Arabic and English; French deferred. Owner confirms and counsel selects controlling language. Add locale-complete documents and acceptance records. |
| D-18 | `lebanonLaw81Formalities` | Unknown | Counsel resolves Articles 94–97, Article 101, regulator/ministry process, transfers and related Lebanese laws from the official Arabic text. |

### Store disclosures - 2 findings

| ID | Gate | Current status | Suggested resolution |
|---|---|---|---|
| S-01 | `appleApproved` | Blocked | If iOS is deferred, version the gate to record `not_applicable` with an approved release-scope reference. If iOS returns, complete Apple labels, privacy manifests, purpose strings, account deletion, signing and device evidence. |
| S-02 | `googlePlayApproved` | Blocked | Complete Data Safety and deletion declarations from the final signed AAB, backend and active vendors; record screenshots/export, reviewer and date. [Closed/open/production tracks require Data Safety](https://support.google.com/googleplay/android-developer/answer/10787469). |

### Platform readiness - 11 findings

| ID | Gate | Current status | Suggested resolution/evidence |
|---|---|---|---|
| P-01 | `accountDeletionVerified` | Implemented but disabled | Approve policy/config, run end-to-end staging execution, multi-device revocation, local cleanup, tombstone, retained-record, backup schedule and retry/rollback tests. Verify the protected super-admin is an organization-controlled operator account; otherwise provide a safe transfer/deletion process. |
| P-02 | `iosPurposeStringsVerified` | Source strings exist; release scope unknown | Mark evidence-backed N/A only if iOS is deferred; otherwise inspect the signed IPA and test prompts on a physical device. |
| P-03 | `privacyManifestInventoryVerified` | Source manifest exists | Reconcile the final dependency graph and signed artifact. Android/web still need SDK/data inventories even if Apple is deferred. |
| P-04 | `productionIdentifiersVerified` | Blocked by placeholders | Owner approves final Android ID and web origin; update Firebase and signed build. Approve iOS bundle ID only if in scope. |
| P-05 | `privacyRightsFulfillmentVerified` | Workflows implemented | Run user isolation, reauthentication, correction, encrypted export, expiry, deletion and administrator access-control tests in staging; approve operational owners and SLA. |
| P-06 | `retentionAutomationVerified` | Cleanup exists; policy unapproved | Configure only approved categories/durations; test idempotence, rollback, audit and holds. |
| P-07 | `notificationPrivacyVerified` | Privacy-preserving design exists | Verify generic lock-screen text, preview controls, REST detail fetch, permission timing, token revocation and real-device delivery. |
| P-08 | `ugcModerationVerified` | Reporting/queue implemented | Approve Terms/AUP, demonstrate reporting for content and users, queue access, timely action through canonical workflows, appeals and evidence. Apply the [Google Play UGC rules](https://support.google.com/googleplay/android-developer/answer/9876937) to the final institutional/public/one-to-one experience; add user blocking when that experience requires it. |
| P-09 | `accessibilityVerified` | Automated/widget evidence incomplete for release | Test legal, consent, deletion, permission and moderation flows at WCAG 2.2 AA targets, text scaling, screen reader, focus order, contrast and touch targets. Record manual evidence. |
| P-10 | `softwareLicenseAndSbomVerified` | RC workflow supports SBOM | Produce final Flutter/API/container dependency and licence reports for the exact candidate; resolve prohibited/unknown licences and publish notices. |
| P-11 | `importProvenanceEnforcementVerified` | Flag defaults false | Review legacy imports, enable `IMPORT_PROVENANCE_ENFORCEMENT_ENABLED=true` in staging/production, test fail-closed ingestion and provenance in exports. |

### Map and attribution - 4 findings

| ID | Gate | Current status | Suggested resolution/evidence |
|---|---|---|---|
| M-01 | `openstreetmapOnlineReviewed` | Public OSM tiles currently configured | Verify the [OSM tile-policy requirements](https://operations.osmfoundation.org/policies/tiles/): visible attribution, custom identifying User-Agent, cache compliance, no bulk/offline use and projected load. Prefer a contracted/self-hosted production service because public tiles have no SLA. |
| M-02 | `esriOnlineLicensed` | Esri online selectable; no licence evidence | Obtain documented online terms/entitlement or add a fail-closed online-provider flag and disable it in the v1 signed build. The current offline-only flag is insufficient. |
| M-03 | `esriOfflineLicensed` | Offline is technically disabled | Keep disabled unless explicit offline/bulk rights are documented. Version the gate to allow `not_applicable_disabled` with signed-build evidence rather than falsely recording “licensed.” |
| M-04 | `attributionVerified` | Attribution widget/tests exist | Capture phone/tablet/web and export evidence from the signed candidate for every enabled source; verify it is visible above drawers/overlays and includes required provider text. |

### Legal documents - 7 findings

| ID | Required document | Current status | Resolution |
|---|---|---|---|
| L-01 | Privacy Notice | English draft | Fill verified facts, remove placeholders, translate as approved, counsel approve, set effective date/version, publish stable HTTPS URL. |
| L-02 | Terms of Use | English draft | Complete legal/product clauses, counsel approve, classify material-change reacceptance and publish. |
| L-03 | Acceptable Use | English draft | Define prohibited content/conduct, reporting, moderation and appeal; approve and publish. |
| L-04 | Important Notices | English draft | Approve cadastral/survey/GPS/AI/offline/field/property/photo/sensitive-site notices. |
| L-05 | Account Deletion | English draft | Match the approved execution, retention, masked-label, timeline, cancellation, backup and contact rules. |
| L-06 | Subprocessors | English draft | Replace service categories with exact active legal entities, purposes, data, regions, safeguards and change notice. |
| L-07 | Open Source | English draft | Generate from the final Flutter/API/container dependency inventory and approve notice delivery. |

## What the final Privacy Notice must contain

The draft cannot become production-visible until it accurately states:

1. Exact legal operator/controller identity, address and privacy contact.
2. Scope: Lebanon-only targeting, actual web/Android/iOS channels, account types,
   age rule and treatment of users temporarily abroad.
3. Actual collected data: name, email, phone, credentials/security state, roles,
   assignments, precise GIS geometry/location, accuracy, attributes, photos,
   comments, reviews, imports/exports, AI inputs/outputs, notifications/device
   tokens, audit/security events, offline data and provider request metadata.
4. Source of each category and whether it is required or optional.
5. Purpose and counsel-approved basis per processing activity.
6. Recipients and exact subprocessors, including hosting, database, storage,
   backup, SMTP, SMS, Firebase, map providers, support/monitoring and AI.
7. Countries/regions, remote support access and approved transfer safeguards.
8. Approved retention and trigger for each category, including backups and legal
   holds.
9. Rights and request methods for access/export, correction, restriction/objection
   and deletion, including identity verification and escalation.
10. Clear deletion behavior: direct identifiers/credentials removed; approved
    institutional records may remain with a masked pseudonymous label; the label
    is not anonymous; exact visibility and periods must be stated.
11. Treatment of private drafts, photos, precise location, free text, shared
    devices and restored backups.
12. AI inference/validation, human review, publication, and the separate rule that
    private contributions are not used for training without approved authority.
13. Map/tile request data, source attribution and offline restrictions.
14. Notification preview choices and permission timing.
15. Security overview without revealing exploitable details.
16. Complaint/regulatory contact wording approved for Lebanon.
17. Version/effective date, material changes and notification method.

Privacy Notice acknowledgement must not be presented as optional-purpose consent.
Terms/AUP acceptance may be mandatory for account use; public publication, AI
training and marketing require separate authority when applicable.

## What the final Terms, AUP and Important Notices must contain

### Terms of Use

- operator and service description;
- 18+/minor rule and institutional authority if approved;
- account security, verification, roles and project-access rules;
- ownership/custodianship and the limited licence necessary to host, process,
  review, synchronize and export contributions;
- separate public-publication and AI-training authority;
- GIS import provenance, licences, attribution and redistribution warranties;
- acceptable field collection, property access, photography and sensitive-site
  responsibilities;
- moderation, suspension, restriction, takedown, restoration and appeal;
- service availability, offline staleness, data export and end-of-life process;
- approved warranties, liability, indemnity, governing law, venue/disputes and
  mandatory-right carve-outs; and
- version changes and which material changes require renewed acceptance.

### Acceptable Use

- illegal, harmful, harassing, infringing, privacy-invasive, misleading and
  sensitive-site content rules;
- no unauthorized access, scraping, bulk tile download, malware or security abuse;
- report-content and report-user paths;
- proportionate review using existing business workflows, without automatic
  deletion on report; and
- escalation, evidence, response targets and appeal.

### Important Notices

TerraLeb must clearly say that it is not a cadastral or land-title authority, a
professional legal survey, emergency navigation, or a guarantee of GPS, imagery,
source or AI accuracy. It must also explain property/access permission, field
safety, photography, sensitive locations, offline staleness, source dates,
attribution, and human review of AI-derived information.

## Account deletion: approved engineering position and remaining legal work

### Keep the current architecture

The implemented approach is preferable to the attachment's proposed snapshot:

- accept and track deletion requests for all supported ordinary accounts;
- exclude the protected super-administrator only if it is an organization-owned
  operational identity and has a documented succession process;
- allow contributors to request deletion even when execution must wait for
  blocking work or private offline data to be resolved;
- recheck eligibility transactionally before execution;
- revoke sessions/device tokens early;
- erase email, phone, password hash, verification/recovery data and private profile
  data;
- delete unnecessary private drafts/temp data and clean only the affected local
  account on devices;
- retain only approved institutional/GIS/review/audit records;
- generate `A. H.` once, erase the full name, and never keep a normal-database
  reverse mapping;
- keep the internal UUID only for necessary relationships and never expose it as a
  public identity;
- scrub structured snapshots;
- review rather than automatically rewrite arbitrary free text;
- schedule backup expiry and prevent restoration from reactivating the account;
  and
- complete the request only when every mandatory stage succeeds.

### What the Terms cannot solve alone

Saying “all contribution data remains after deletion” in Terms does not by itself
make unlimited retention lawful or satisfy [Google Play's account-deletion
policy](https://support.google.com/googleplay/android-developer/answer/10144311). The retained record must
have a legitimate approved purpose/basis, be limited to necessary fields, have an
approved period and visibility, remain correctable/contestable where applicable,
and be disclosed clearly. The `A. H.` label reduces exposure but does not make the
record anonymous.

### Decisions still required before enabling execution

- record-by-record retained institutional/public-interest basis;
- exact fields and periods;
- masked-label audience;
- photos and precise location;
- free-text review and takedown;
- legal hold authority and controls;
- backup maximum ageing;
- request target and any cancellable stage;
- contributor-enrolment and pre-deletion wording;
- Play/Apple disclosures; and
- treatment/succession of the protected super-administrator identity.

## Retention: current facts and required decisions

There is no universal “true” retention period that can safely be inferred from
the code or a generic template. The shortest period that satisfies the approved
purpose, security need and public/institutional duty should be selected and
documented. Current values must not be mistaken for legal approval.

| Category | Current technical fact | Decision required |
|---|---|---|
| Sessions | Expiry/revocation enforced; old records opportunistically cleaned | Post-expiry evidence window and legal-hold rule |
| Password reset/contact challenges | Short validity enforced | Purge interval and minimal abuse evidence |
| Device tokens | Revoked on relevant account/session actions | Purge interval and delivery-evidence period |
| Notifications | User deletion and maintenance exist | Default age, dismissed/read treatment and exceptional evidence |
| API/Loki logs | Reference defaults are 14/30 days depending environment/component | Final app/security/audit periods, region, access and incident holds |
| Project exports | Reference file default is 7 days | Approve file and metadata periods; disclose downstream copies |
| Personal-data exports | Encrypted; configuration proposes 24-hour TTL | Counsel/owner approve TTL and minimal generation/download evidence |
| Imports/quarantine/temp files | Security and reconciliation controls exist | Successful, failed, rejected and malware-evidence periods |
| Private/rejected drafts and photos | Workflow/local cleanup exists | Project closure, rejection, account deletion and unsynced-device rules |
| Accepted GIS/review history | Proposed tombstone and masked attribution | Exact retained classes, basis, fields, visibility and period |
| AI artifacts | Lifecycle records persist | Per-model/output/training-evidence retention and retraction |
| Privacy/moderation/audit evidence | Status and audit history exist | Minimal proof period, access and legal holds without erased PII |
| Backups/PITR | Runbooks exist; real external values absent | Maximum ageing, restore suppression and deletion propagation |

Do not adopt the attachment's 30-day grace or 90-day completion figures merely
because they are concrete. Keep TerraLeb's ten-day internal operational target
until counsel approves a different interpretation and the workflow/documentation
is changed deliberately.

## Configuration and engineering work still required

### Release-candidate environment

Configure the exact three variables and five secrets listed under A8, required
reviewers, no administrator bypass where supported, and the exact RC tag policy.
Do not create or push an RC tag until the Phase 7 inputs are approved.

### Production runtime legal/privacy configuration

The following must be explicitly configured only after approvals exist:

```text
LEGAL_DRAFTS_PUBLIC_ENABLED=false
LEGAL_ENFORCEMENT_ENABLED=true
LEGAL_COUNSEL_APPROVAL_REFERENCE=<immutable approval reference>

PRIVACY_EXPORT_ENCRYPTION_KEY_BASE64=<secret 32-byte key>
PRIVACY_EXPORT_TTL_HOURS=<approved 1..168 value>
PRIVACY_EXPORT_RETENTION_APPROVAL_REFERENCE=<immutable approval reference>

ACCOUNT_DELETION_EXECUTION_ENABLED=true
ACCOUNT_DELETION_POLICY_APPROVAL_REFERENCE=<immutable approval reference>
ACCOUNT_DELETION_RETENTION_APPROVAL_REFERENCE=<immutable approval reference>
MASKED_CONTRIBUTOR_POLICY_APPROVAL_REFERENCE=<immutable approval reference>

IMPORT_PROVENANCE_ENFORCEMENT_ENABLED=true
```

Important engineering gap: `.env.example` and `apps/api/.env.example` include
the new legal/privacy values, but `.env.prod.example` and
`.env.staging.example` currently do not. The production Compose secret mounts
also do not provide a dedicated file-backed secret for the privacy-export
encryption key. Before Phase 7, update the templates, worker/API secret boundary,
configuration tests and runbooks without placing the key in Git or ordinary
evidence files.

### Map build configuration

For the signed candidate:

```text
LICENSED_ESRI_OFFLINE_BASEMAP_ENABLED=false
MAP_PROVIDER_USER_AGENT=<identifiable TerraLeb app and monitored contact>
```

The app lacks a corresponding fail-closed flag for **online** Esri. Add one if
the owner selects OSM-only v1, and test that Esri cannot be selected or fetched.
If Esri remains enabled, record exact online licence/terms and attribution.

Never use public `tile.openstreetmap.org` for offline packages. A paid/self-hosted
OSM-derived provider still requires a named contract, cache/offline/derived-use
terms and attribution evidence.

### Authentication and messaging

Do not remove the required phone field merely to reduce subprocessors. TerraLeb
currently supports explicitly selected `format_only` and provider-backed `sms_otp`
modes, while production password reset requires real SMTP delivery. The owner and
security owner must select and document the phone-assurance mode. If they want to
remove phone collection, conduct a separate security/product review, change signup
behavior explicitly, update policies/Data Safety and add tests.

Push requires final package-specific Firebase client configuration, a protected
Firebase Admin credential in the API notification boundary, generic previews,
user controls, real-device evidence and accurate Data Safety disclosure. Separate
Firebase projects are recommended for staging/production isolation but are not a
substitute for access controls and key restrictions.

### AI

Recommended default:

- AI training reuse disabled;
- public AI-layer publication fail-closed without authority;
- no private contribution/photo/location training under generic Terms;
- inference/validation enabled only for registered model artifacts, datasets,
  regions, evaluation, human reviewers and project authority.

Turning `AI_PIPELINE_ENABLED=false` for all v1 deployments is available as an
owner scope choice, but it changes a current feature and must be documented and
tested as such.

## Predeployment phases 0–8

These are the authoritative **predeployment** phases. Older feature-delivery
documents that say phases 0–8 are complete do not constitute current production
approval.

| Phase | Verified state | Remaining work |
|---|---|---|
| 0 Clean baseline | Complete in repository | Preserve protected history and review current uncommitted work before any commit/sync. Do not reset it. |
| 1 Data-safety foundation | Repository gate complete | Approve actual hosting/data regions, classifications, recovery targets, retention and external owners. |
| 2 Private storage/uploads | Repository gate complete | Deploy and prove private storage, scanner/quarantine, reconciliation and recovery in production-like staging. |
| 3 Mobile data at rest | Repository gate complete | Physical Android install/upgrade/account-switch/offline/device-loss evidence. iOS validation only if in scope; otherwise record N/A. |
| 4 Shared limits/workers | Repository gate complete | Real shared Valkey, multi-replica behavior, outage policy and workload-worker evidence. |
| 5 Infrastructure/observability | Repository gate complete | Real DNS/TLS, secrets, runtime DB role, alert delivery, log policy, off-server backup and restore. |
| 6 Full release verification | Repository/local verification complete | Re-run against the exact candidate and capture external staging, security and performance evidence. |
| 7 Release candidate/pilot | **Blocked/incomplete** | Supply the protected GitHub environment, final ID/version, signing/Firebase, real staging, device, backup, alert, cohort, soak, rollback and approvers. Complete legal/store gates applicable to a real-data pilot. |
| 8 Production rollout | **Not authorized** | Begin only after candidate evidence passes, Phase 7 completion is green/merged, legal readiness passes, and the legal/product owner signs the exact release. |

### Phase 7 external inputs still absent

The current Phase 7 runbook records all of these as unavailable:

- GitHub `release-candidate` environment;
- required GitHub variables and secrets;
- final Android application ID and version code;
- production upload keystore and custody/recovery evidence;
- final package-matching Firebase configuration;
- physical Android device evidence;
- macOS/Xcode/iOS signing/device evidence if Apple is in scope;
- real staging compute and database;
- staging DNS/TLS;
- private object storage;
- deployed malware scanner;
- shared Valkey;
- external alert delivery;
- off-server backup and isolated restore;
- authorized pilot users/devices/schedule; and
- named release, security, operations and legal/product approvers.

## Step-by-step closure plan

### Step 1 - Record owner scope decisions

The owner should approve, amend or reject each proposal separately:

- [ ] Lebanon-only availability and targeting.
- [ ] Android + authenticated web for v1; iOS deferred.
- [ ] 18+ only; no minors.
- [ ] Arabic and English at launch; French deferred.
- [ ] No analytics/advertising SDKs.
- [ ] No AI training reuse.
- [ ] Keep AI inference/validation in v1, or explicitly defer the whole AI feature.
- [ ] OSM-derived production basemap; Esri online/offline disabled unless licensed.
- [ ] One-time masked initials for approved retained records.
- [ ] Who may see masked attribution.
- [ ] Pilot institutions, account type, cohort, devices and soak.
- [ ] Named release/security/operations/privacy owners and alternates.

Record date, approver role and immutable decision reference. A checkbox in this
report is not itself approval.

### Step 2 - Give counsel a focused facts-and-decisions pack

Send the factual data inventory, processing register, transfer map, role/access
matrix, retention rows, deletion record-class table, GIS/map register, AI
provenance gaps, DPIA and exact draft documents. Ask the twelve concrete questions
listed above. Require review of the Arabic Law 81 text and exact approved wording,
not a generic “looks good.”

### Step 3 - Select and contract real vendors

Choose actual hosting/database/storage/backup/log, SMTP, phone verification,
Firebase, map and AI providers. Record legal entity, region, support access, DPA,
transfer basis, retention/deletion commitment, incident terms, subprocessor chain
and exit plan. Do not claim Lebanese data residency unless every path proves it.

### Step 4 - Finalize the retention matrix and deletion policy

Approve each category and the retained GIS/review record classes. Then configure
cleanup, export TTL, backup ageing and deletion approval references. Keep all
execution flags off until tests against approved values pass.

### Step 5 - Correct the readiness/configuration model

- version the readiness schema to represent `approved`, `not_applicable`,
  `disabled_with_evidence`, and `blocked` rather than abusing booleans;
- require evidence references for every non-blocking state;
- if Arabic is required, require current approved Arabic documents as well as
  English;
- add an online-Esri disable control;
- bring staging/production env templates up to date;
- add file-backed secret handling for the privacy-export encryption key; and
- correct the Law 81 Article 96 question.

These changes should be small, migration-safe and covered by release-gate tests.

### Step 6 - Finalize identities, signing and store configuration

Approve the Android ID, web origin, version policy, Play developer account type,
upload-key custody and Firebase package registration. Configure the exact A8
environment. Complete Play App Signing and Data Safety drafts. If iOS is deferred,
record that scope; do not claim Apple readiness.

### Step 7 - Publish counsel-approved documents

Create immutable Arabic/English versions as applicable, effective dates,
previous-version links and material-change classifications. Verify public HTTPS
Privacy and deletion pages without login. Verify signup acceptance is affirmative
and unchecked, and optional purposes remain separate.

### Step 8 - Deploy production-like staging and collect evidence

Deploy by immutable image digest and artifact hashes. Prove TLS, private storage,
scanner, Valkey, workers, SMTP/SMS, push, privacy rights, deletion, retention,
map restrictions, provenance, alert delivery, off-server restore, WebSocket and
real-device behavior. Capture no secrets or personal pilot data in evidence.

### Step 9 - Candidate, pilot and production authorization

Create an immutable RC only after approval. Run the applicable Play closed-test
cohort and at least the required 14-day continuous period when the newer-personal-
account rule applies. Exercise full collect/sync/review/export/privacy/deletion,
rollback and restore flows. Resolve all critical/high and data-integrity issues.
Then run the legal gate without `--allow-incomplete`, verify candidate evidence,
obtain final authorization, and roll out gradually with rollback authority named.

## Standards and policy baseline

These are control targets, not automatic certification requirements or legal
bases.

| Standard/policy | TerraLeb use | Required evidence |
|---|---|---|
| Lebanon Law No. 81/2018 | Binding legal assessment for Lebanese personal-data processing, subject to counsel | Arabic-law analysis, filings/licences if applicable, notices, rights, retention and transfer conclusions |
| Google Play policies | Mandatory for Play distribution | Data Safety, account deletion URLs, UGC, permissions, target audience, signed-AAB evidence |
| Apple guidelines | Mandatory only if App Store distribution is in scope | Labels, in-app deletion, privacy policy, manifests, purpose strings and signed IPA/device review |
| GDPR | Only when territorial/material scope applies | Counsel scope analysis; if applicable, lawful bases, rights, processors and transfer safeguards |
| ISO/IEC 27001:2022 | ISMS control framework | Risk register, owners, policies, audit evidence; do not claim certification without certification |
| ISO/IEC 27701:2025 | Privacy information management extension | Controller/processor controls, ROPA, rights, vendors and privacy governance |
| ISO/IEC 29184 | Online privacy notice/choice principles | Layered clear notice, timing, affirmative granular choices |
| OWASP ASVS 5 / MASVS 2 | API/web and mobile security verification | Versioned control mapping, test evidence and exceptions |
| NIST Privacy Framework | Privacy-risk governance | Govern/identify/control/communicate/protect evidence and DPIA links |
| NIST SSDF SP 800-218 | Secure development/release | protected source, reviews, dependency/SBOM, provenance, vulnerability response |
| NIST AI RMF / ISO 42001 | Enabled AI risk governance | model/data provenance, evaluation, human oversight, publication/retraction and incident ownership |
| WCAG 2.2 AA | Web/mobile legal and rights UX target | automated plus manual keyboard/screen-reader/text-scale/contrast/focus evidence |
| ISO 19115-1 / ISO 19157 | GIS metadata and quality principles | source, date, CRS, accuracy, lineage, licence, quality and redistribution metadata |

## Final decision summary

### Safe to use now

- The attachment's ENG/OWNER-DRAFT/COUNSEL separation.
- Android/web with iOS deferred as an owner proposal.
- 18+/no minors, Arabic+English, no analytics, no AI training, and OSM-derived
  basemap as owner proposals.
- Play App Signing, protected RC environment, real staging, physical-device,
  restore, rollback, named approver and pilot principles.
- The Law 81 article-numbering concern.
- A concise counsel memo built from verified facts and exact decisions.

### Use only after correction

- GitHub authentication instructions.
- Firebase setup and signing-fingerprint claims.
- application ID/version scheme;
- staging architecture details;
- GitHub environment branch/tag restrictions;
- physical-device/minSdk recommendations;
- pilot tester counts and measurement targets;
- OSM/Esri conclusions; and
- Apple “not applicable” handling.

### Do not use

- The proposed A8 variable/secret names.
- “Only seven blockers remain” as a release conclusion.
- “AI is not shipped” or “no AI v1 has zero product cost.”
- dropping phone/SMS assurance without a product/security decision.
- a new attribution snapshot containing optional real names.
- `Reviewer · NCRS · 2026-03` as if it were anonymous.
- 30-day deletion grace or 90-day completion as an established rule.
- the claim that public OSM tiles are prohibited for every real app at any volume.
- the claim that Play signing fingerprints are required for TerraLeb FCM.
- marking Apple or Esri as approved merely because they are deferred/disabled.

### Bottom line

The attachment narrows and organizes the work, but it does not legally or
operationally close production. Some issues need only an owner decision; some need
configuration and evidence; some require code/gate corrections; and the core legal
questions require Lebanese counsel. Passing engineering tests or accepting these
recommendations does not itself establish legal compliance.
