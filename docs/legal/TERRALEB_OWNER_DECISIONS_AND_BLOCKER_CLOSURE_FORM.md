# TerraLeb owner decisions and blocker-closure form

Status: **revised owner-policy proposal; production remains fail-closed**

Prepared: **2026-08-16; owner direction revised 2026-08-18**

Territorial scope: **Lebanon only**

Initial release: **Android and authenticated web; iOS deferred**

## Purpose and authority boundary

This document answers every question that can reasonably be answered as a
TerraLeb product owner, selects a practical low-exposure v1 operating model,
maps every current production gate to the evidence needed to close it, and
records the exact engineering changes still required.

It does **not** pretend that an automated review is the legal operator, Lebanese
counsel, a vendor contracting party, a store-account owner, or a deployment
witness. It therefore does not invent an operator name, address, registration
number, contract, legal opinion, approval reference, domain ownership, or test
result. Those facts must be supplied and signed by the responsible people.

The decisions below are intentionally proportional. TerraLeb is a controlled
GIS and project-workflow application, not a social network, ad platform,
consumer-tracking product, cadastral authority, emergency-navigation service,
or autonomous AI decision maker. Lebanon may have a different enforcement
environment from the EU or United States, but a lower perceived enforcement
risk is not a sound reason to publish inaccurate notices, mishandle credentials,
use unlicensed maps, or make deletion claims the product cannot perform.

Passing the engineering gate will not itself establish legal compliance. Final
Lebanese-law conclusions and final public wording require approval by the real
operator and qualified Lebanese counsel.

The costed implementation and manual deployment companion is
[`TERRALEB_REVISED_OWNER_POLICY_COST_AND_DEPLOYMENT_PLAN.md`](TERRALEB_REVISED_OWNER_POLICY_COST_AND_DEPLOYMENT_PLAN.md).
It records the later owner direction that AI and all map modes remain available,
and that accepted GIS is retained while unfinished content is removed on an
approved account deletion.

## Decision legend

- **OWNER-DECIDED** - the product-policy answer is selected in this document.
- **ENGINEERING** - the answer is selected, but code/configuration/evidence must
  make the deployed product match it.
- **EXTERNAL FACT** - a real name, contract, account, address, region, or other
  fact must be supplied; it cannot be generated truthfully.
- **COUNSEL** - the selected owner policy is usable as drafting input, but a
  narrow legal conclusion or final wording still needs Lebanese counsel.
- **EVIDENCE** - the feature must be exercised in a production-like environment
  and the immutable result recorded before its boolean can become `true`.

## Executive owner decision

TerraLeb v1 will use the following conservative operating model:

| Area | Owner decision | Reason |
|---|---|---|
| Market | Offered and targeted only in Lebanon | Matches the stated product region and avoids making broader territorial claims. |
| Platforms | Android and authenticated web at v1; iOS source remains but public iOS release is deferred | Closes an unnecessary launch dependency without deleting iOS work. |
| Users | 18 years or older; minors are not permitted | Avoids building parental-consent and child-safety processing that TerraLeb does not need at launch. |
| Product type | Controlled institutional/project workflow; no public social feed or direct messaging | Matches the current architecture and narrows moderation obligations. |
| Analytics/ads | No advertising, marketing tracking, analytics SDK, or behavioral profiling | They are not needed for core GIS operation. |
| AI | AI service available in production; disabled by default for every project; only the protected super-admin may enable a project, start a run, validate results, and decide whether to publish | Preserves the intended AI workflow while preventing automatic or contributor-triggered processing. AI receives approved project GIS inputs, not account credentials/contact/session data. |
| Maps | Preserve the verified workflow: Street online, Hybrid online, and the existing Hybrid offline option; make each delivery path provider-compliant instead of removing a feature | Online OSM may be used within its tile policy. Online Hybrid uses an approved ArcGIS account/token and attribution. Offline Hybrid uses a TerraLeb-controlled Copernicus Sentinel-2 package with OSM-derived labels. The app does not currently provide an offline OSM Street download. |
| Authentication | Email verification plus format-validated phone number at v1; no SMS provider until one is approved | Matches current `PHONE_ASSURANCE_MODE=format_only` and avoids pretending the number was possession-verified. |
| Hosting | Use OCI Saudi Arabia West (Jeddah) as the recommended low-cost regional initial target: A1 ARM 4 OCPU/32 GB after compatibility proof, with E4 x86 in the same region as fallback; retain Hetzner EU as the lowest-cost non-regional alternative and AWS Bahrain as the managed/regional growth option | The complete Compose stack needs more than 16 GB. Jeddah must pass Lebanon latency, capacity and full-container compatibility tests before purchase. |
| Deletion | Reviewed deletion for all supported users except the protected super-admin identity; accepted GIS/provenance stays, while drafts, pending submissions and other unapproved project content are removed once the protected administrator approves deletion | Protects official project integrity without unnecessarily retaining unfinished user work. |
| Attribution after deletion | Delete direct identifiers; retain justified project records under a one-time masked contributor label such as `A. H.` | Reduces identification without falsely calling the record anonymous. |
| Public attribution | Default public layers/exports to the generic label `Contributor`; masked initials are limited to authorized project members, protected administrators, and justified institutional records | Reduces re-identification risk while retaining internal accountability. |
| Languages | Arabic and English for legal, consent, deletion, privacy-right, permission, and safety surfaces; Arabic is the recommended controlling version, subject to counsel | The app is Lebanon-only and the current English-only legal surface is inadequate for a public release. |

These choices do not remove underlying application capabilities. They define
what is enabled in the initial production environment. AI and map modes remain
features, but their project/provider controls are fail-closed. Enabling iOS,
analytics, minors, other territories, public social functionality, AI training,
or a new map/data provider is a material-change review rather than an ordinary
configuration toggle.

## Completed owner and counsel answer form

### 1. Operator and contacts

| Question | TerraLeb answer | Closure requirement |
|---|---|---|
| Exact legal operator/controller | **EXTERNAL FACT:** `[ENTER EXACT REGISTERED LEGAL NAME AND LEGAL FORM]` | Must be the entity/person that controls the store account, contracts with vendors, publishes the policies, and can answer privacy requests. |
| Registration/public-body reference | **EXTERNAL FACT:** `[ENTER REGISTRATION OR FOUNDING AUTHORITY; OR DOCUMENT WHY NONE EXISTS]` | Do not write “NCRS”, “CNRS”, a ministry, or a company unless that body has accepted the role. |
| Official address | **EXTERNAL FACT:** `[ENTER SERVICEABLE PHYSICAL ADDRESS IN LEBANON]` | Must be real and approved for public notices. |
| General contact | **OWNER-DECIDED:** `support@terraleb.lb`; public phone optional | Domain must first be registered and controlled by the operator. Use a monitored replacement if this domain is not acquired. |
| Privacy contact | **OWNER-DECIDED:** `privacy@terraleb.lb` | Must route to a trained person with absence coverage and a case queue. |
| Responsible role | **OWNER-DECIDED:** `TerraLeb Privacy and Security Owner` | Name the actual accountable person internally before launch. |
| DPO/representative | **OWNER-DECIDED:** no public DPO title unless counsel concludes one is required; assign the privacy owner regardless | **COUNSEL:** record the conclusion and authority. Do not present an unqualified person as a statutory DPO. |

Proposed public identity endpoints, conditional on domain ownership:

- Website: `https://terraleb.lb`
- API: `https://api.terraleb.lb`
- Privacy Notice: `https://terraleb.lb/legal/privacy`
- Account deletion information/request: `https://terraleb.lb/legal/account-deletion`
- Android application ID: `lb.terraleb.app`

### 2. Distribution, users and age

- **OWNER-DECIDED:** store availability, marketing, onboarding, institutions,
  support promises, and public policy scope are Lebanon only.
- **OWNER-DECIDED:** an already-authorized adult may temporarily access their
  account while travelling. TerraLeb does not target or establish service in the
  visited country merely because an existing account connects from there. This
  owner intention does not override any mandatory rule that may apply from the
  user's actual location; counsel should reassess if foreign use becomes regular.
- **OWNER-DECIDED:** launch channels are Google Play production and an
  authenticated web deployment. Managed institutional distribution and a closed
  pilot may also be used. Public Apple App Store distribution is deferred.
- **OWNER-DECIDED:** minimum age is 18. Signup must state this and require the
  user to confirm it. No date of birth should be collected merely to prove age.
- **OWNER-DECIDED:** minors cannot create or use accounts. If an institution
  later needs minors, stop and design a separate verified guardian/institution
  authorization process before enabling them.
- **OWNER-DECIDED:** Arabic and English are required on public policies and
  decision-critical legal/privacy/safety screens. Arabic is the recommended
  controlling version. **COUNSEL** must approve the controlling-language and
  discrepancy clause.

### 3. Parties and roles

The intended allocation is:

| Party | Owner policy | Required record |
|---|---|---|
| TerraLeb legal operator | Controller for accounts, authentication, security, platform administration, support, privacy requests, and TerraLeb operational logs | Exact operator identity and signed policy approval. |
| Project-owning institution | Controller or competent institutional authority for project purpose, contributor assignment, review, GIS content, retention, and publication | Project agreement/authority record naming the responsible institution. |
| TerraLeb when operating institutional projects | Processor/service operator for institution-directed project data, except where TerraLeb independently decides account/security processing | DPA or public/institutional operating agreement. |
| Ministry, municipality, NCRS/CNRS or other partner | No role is assumed from its name alone | Role must be recorded per participating institution. |
| AWS and Firebase/Google push | Processor/service provider for the services actually enabled | Executed terms/DPA, region, and subprocessor entry. |
| Google Play | Distribution/platform provider; its independent roles are governed by its terms | Developer-account legal entity and store disclosure evidence. |
| OpenStreetMap contributors/OSMF | Licensed data source, not TerraLeb's application-user processor when TerraLeb self-hosts derived tiles | Source, database date, ODbL compliance, attribution and derived-database assessment. |
| AI/GEE operator | The TerraLeb AI service is an internal processor component; Google Earth Engine is an external processing service when real runs use it | Record the actual GEE edition/account, project, region/data flow, terms and billing eligibility before production runs. |

No screen label or database role replaces this contractual/public-law allocation.

### 4. Purposes and product choices

| Processing | Status | Owner purpose and restriction |
|---|---|---|
| Account, email verification, phone format validation | Required | Create and protect an account and contact the user about service/security. Do not say the phone is ownership-verified. |
| Role, assignment, project administration | Required for assigned users | Authorize institutional work and protect private projects. |
| Precise GIS/location and offline sync | Optional action within an assigned project | Collect only when the user deliberately captures/edits project data; no continuous background tracking. |
| Photos, attributes, comments, reviews | Optional action within an assigned workflow | Use for project evidence/review; show contextual notice before capture/upload. |
| Imports and exports | Role-gated | Operate approved project workflows; preserve source/license/provenance. |
| Public publication | Separate institutional authority per layer/release | User signup acceptance is not publication consent. |
| Push notifications | Optional | Ask contextually; generic lock-screen text by default; disabling push must not disable in-app notifications. |
| Audit/security | Required and access-restricted | Detect abuse, investigate incidents, preserve necessary integrity evidence. |
| AI inference/validation | Available but project-disabled by default | Only the protected super-admin may enable a project and start/validate/publish a run. Limit inputs to approved project geometry/attributes and approved imagery/datasets. |
| AI project classification/training | Available but project-disabled by default | The protected super-admin may use approved GIS samples solely for that project's controlled run and reviewed output. |
| General/external/cross-project AI training or model improvement | Prohibited | Private contributions, photos, locations and comments may not be reused to improve a general model or another project. A generic Terms clause cannot override this. |
| Marketing/advertising/analytics | Not used | Any later introduction requires a separate inventory, notice/store update, and optional choice where required. |

The public notice must describe the actual purposes. It must not call every
processing purpose “consent.” Required service processing, institutional
authority, optional device permissions, publication authorization, and any
future optional choice must remain distinct.

### 5. Vendors, subprocessors and data locations

The minimum v1 vendor model is:

| Capability | Selected solution | Data/region rule | Status |
|---|---|---|---|
| API/worker/container hosting | **Cost decision pending:** AWS Bahrain for managed regional resilience, or the recommended low-cost initial deployment on Hetzner Cloud in Germany/Finland | The final selected country and provider must be disclosed and contracted | **OWNER SELECTION; EXTERNAL CONTRACT REQUIRED** |
| PostgreSQL/PostGIS | Start inside the hardened single-host Compose deployment for the low-cost pilot; move to a dedicated/managed database when measured load or uptime requires it | Private networking; encryption at rest/in transit; off-host encrypted backups | **ENGINEERING/CONTRACT** |
| Object storage | Private S3-compatible object storage supplied by the selected provider | Photos/imports/exports; authenticated or signed short-lived access only | **ENGINEERING/CONTRACT** |
| Backups | Same-region encrypted, separate-account/immutable controls where feasible | Natural expiry after 35 days; restore suppression for deleted identities | **ENGINEERING** |
| Email | Amazon SES `me-south-1` | Verification, reset, rights and security messages | **CONTRACT/CONFIGURATION** |
| SMS | None at v1 | Phone number is format-validated, not possession-verified | **OWNER-DECIDED** |
| Push | Firebase Cloud Messaging | Device token and privacy-preserving payload only; fetch details after authentication | **CONTRACT/DISCLOSURE** |
| Monitoring | Platform/self-hosted operational metrics and redacted logs; no third-party crash/analytics SDK at v1 | No tokens, contact data, geometry or free-text bodies in telemetry | **ENGINEERING** |
| Online street tiles | Public OSM Standard tiles for a small initial load, with required attribution/User-Agent/caching and no bulk/offline use; move to a paid or controlled endpoint before material scale | Provider receives tile coordinates, IP and User-Agent | **ENGINEERING/POLICY EVIDENCE** |
| Online imagery/Esri | ArcGIS Location Platform/Online basemap service with a real restricted credential or session model, usage monitoring and complete attribution | Provider receives tile/session request metadata; project GIS data is not uploaded merely to display tiles | **ACCOUNT/CONFIGURATION REQUIRED** |
| Offline Street tiles | Not part of the verified initial workflow | Public OSM bulk/offline download remains prohibited. A future Street package would require a TerraLeb-generated OSM-derived source. | **NOT IN INITIAL SCOPE** |
| Offline Hybrid imagery/labels | TerraLeb-generated Copernicus Sentinel-2 true-colour Lebanon mosaic with OSM-derived reference labels | Record scene IDs/date/processing/10 m resolution/Copernicus and ODbL terms; never bulk-download anonymous Esri or public OSM tiles | **ENGINEERING/LICENSE EVIDENCE** |
| AI service | TerraLeb Python AI service plus GEE when configured | Approved project GIS/imagery input only; exclude user account/contact/session data and private drafts | **ENGINEERING/GEE ACCOUNT REQUIRED** |

The exact AWS contracting legal entity, account owner, executed DPA/terms,
support-access locations, Firebase terms, and Google Play entity are **EXTERNAL
FACTS**. They must be copied from executed records - not guessed from a product
name. GitHub may remain a software-development vendor but production user data
must never be placed in issues, source control or CI artifacts.

### 6. Approved owner retention schedule

The following is TerraLeb's minimization-oriented owner policy. It becomes the
operational schedule only after counsel ratification and configuration/testing.
“Delete” means deletion from active systems followed by natural backup expiry;
it does not mean destructive rewriting of backups.

| Record | Trigger | Owner duration | Action at expiry |
|---|---|---:|---|
| Email/phone verification and password-reset challenges | Expiry or successful use | 30 days | Delete challenge, code hash and delivery metadata. |
| Inactive unverified signup | Last activity | 30 days | Delete account shell and unused contact data unless abuse evidence is separately justified. |
| Expired/revoked sessions and refresh families | Expiry/revocation | 30 days | Delete; preserve only a non-reversible security event if needed. |
| Device tokens | Revocation/logout/deletion or invalid-token response | Immediate disable; purge within 7 days | Delete token and destination. |
| Notifications | Creation | 180 days | Delete message body and user copy; preserve a minimal audit event only where necessary. |
| Password/security operational logs | Event | 30 days for routine logs; 1 year for security events | Delete or aggregate; never retain secrets or full payloads. |
| Audit/admin decision history | Event | 7 years | Delete or archive under restricted access, unless a documented legal hold applies. |
| Privacy/moderation case | Closure | 3 years | Delete submitted PII and internal detail; retain minimal fulfillment/outcome evidence. |
| Personal-data export artifact | Successful generation | 24 hours | Delete encrypted artifact; retain access/fulfillment audit for 2 years. |
| Project export artifact | Generation/expiry | 7 days | Delete file; retain non-PII provenance metadata for 2 years. |
| Temporary import/quarantine upload | Completion/failure | 30 days | Delete temporary file. |
| Rejected import source | Final rejection | 90 days | Delete source; retain minimum rejection/provenance record. |
| Approved import source/provenance | Project archive | Active project plus 2 years for source artifact; 10 years for provenance metadata | Delete source artifact, retain justified provenance fields. |
| Unsynchronized/private draft | Last activity or account deletion | 90 days inactive, or immediate at completed deletion after warning | Delete server and affected user's local encrypted copy. |
| Rejected/private photo | Final rejection | 90 days | Delete file and thumbnails unless an active case/hold applies. |
| Accepted GIS contribution/photo/review/comment/provenance | Project archive | Active project plus 10 years | Retain under project-integrity policy using the masked identity rules below; then review/delete. |
| Published GIS record | Publication withdrawal | While published plus 10 years | Retain provenance and decision record; do not expose a deleted person's UUID. |
| AI temporary/failed artifact | Completion/failure | 30 days | Delete. No training reuse. |
| Model/dataset/evaluation provenance, if AI is later enabled | Model retirement/publication withdrawal | 10 years | Retain restricted evidence; review/delete at expiry. |
| Database/object backups | Backup creation | 35 days | Automatic expiry; deletion ledger prevents identity restoration into active state. |
| Legal hold | Approved hold start | Case-specific expiry; review every 6 months | Restricted, encrypted, audited exception; release promptly when the hold ends. |

System configuration must use approved values rather than hard-coded legal
claims. Cleanup jobs must be idempotent, auditable and tested. A retention row
that cannot yet be automated remains a production blocker or must be disabled.

### 7. Deletion and masked attribution

#### Eligibility and workflow

- The protected super-admin identity cannot be deleted while it is the protected
  recovery/ownership account. If it belongs to a departing human, create and
  verify a replacement protected identity, transfer custody, then handle the old
  human account through the reviewed workflow.
- Viewers may normally proceed after reauthentication and review.
- Contributors may submit a request at any time. The protected administrator
  reviews active assignments and responsibilities, but drafts, unsynchronized
  data, pending requests, pending/unapproved submissions, and other unfinished
  contributor work do not have to be completed: the approval screen must state
  that they will be permanently removed with the account.
- Administrators require protected-super-admin review. Eligible assignments and
  queue ownership are released automatically; blocking work must be resolved first.
- Deactivation remains a separate contributor access control. It is not deletion.
- A user may cancel while a request is `pending_verification`, `submitted` or
  `in_review`. It cannot be cancelled after execution is scheduled or processing.
- TerraLeb acknowledges a request immediately and targets a decision/fulfillment
  within 10 calendar days when eligible. If blocking work must be resolved,
  the user receives the exact safe reason and next action within that target.

#### Data removed

On completed deletion TerraLeb removes the password hash, email, phone,
verification state/challenges, password-reset records, sessions, refresh-token
families, device tokens, notification destinations, private profile fields,
unneeded contact snapshots, every private/unsynchronized draft, pending or
unapproved contribution, pending assignment/request owned solely by that user,
unapproved upload/photo/comment, temporary upload, personal export artifact, and
the affected account's local encrypted/cache data. Deleted accounts are
non-authenticatable and cannot be reactivated. A narrowly restricted copy may
remain only for an already-approved legal hold or open abuse/privacy case, never
as ordinary application content.

#### Data retained

Only accepted GIS contributions and the minimum final review/approval,
collected-by, source, import, publication and AI-validation provenance needed to
show why that accepted record became official remain under the approved
role/retention model. Rejected, pending and draft project content is removed
unless it is part of an approved case/hold. The internal immutable UUID remains
only where necessary for relational integrity and is never presented as a public
identity or export identifier.

#### Display identity

- Generate a one-time Unicode-safe masked label from the name immediately before
  erasing it: `Ali Hassan` becomes `A. H.`. Never retain the full name to
  regenerate initials.
- The label is **pseudonymous**, not anonymous.
- Authorized project members and protected administrators may see the masked
  label where accountability requires it.
- Public layers and public/general exports show `Contributor` by default, not the
  initials and never the internal UUID.
- Full name, email and phone are removed from structured snapshots,
  notifications, metadata and caches.
- Arbitrary free-text comments are not silently rewritten. A restricted review
  task identifies likely direct identifiers and supports a documented decision.
- Photos and exact location records follow the record's project status,
  sensitivity classification and retention rule. Private/rejected material is
  removed earlier; accepted material is not automatically public.

This approach materially reduces risk but does not make retained records legally
anonymous. **COUNSEL** must approve the basis and final wording for retained
institutional records, photos, precise location and free text.

### 8. GIS, maps, ownership and publication

- Contributors keep any rights they actually hold and grant the project
  institution/TerraLeb a clear, non-exclusive, worldwide, royalty-free licence
  to receive, store, validate, transform for GIS interoperability, review,
  analyze with the approved AI workflow, display, back up, publish when separately
  authorized, and export accepted project contributions. For accepted official
  GIS records, the licence must survive account deletion for the approved
  retention period. TerraLeb must not claim ownership of third-party or
  institutional data merely because a user uploaded it.
- Contributors/importers warrant that they have authority to submit the data and
  must record source, provider, acquisition/dataset date, accuracy/quality,
  license, attribution, permitted uses, redistribution and offline rights.
- Public publication is a separate act requiring a recorded project-institution
  authority and protected-super-admin approval. Signup acceptance is not enough.
- Sensitive sites, personal addresses, vulnerable ecological/cultural sites,
  critical infrastructure and security-relevant locations default to private
  and require an explicit classification/release decision.
- TerraLeb is not a cadastral/title authority, legal survey, emergency-navigation
  system, or guarantee of GPS, imagery, source or AI accuracy.
- Keep both Street and Satellite choices. Every map and applicable export shows
  the exact provider/data attribution without being covered by navigation UI.
- Small-scale online street display may use `tile.openstreetmap.org` only with an
  identifying User-Agent, normal HTTP caching, attribution, no prefetch/bulk
  requests and usage monitoring. Move to a paid or controlled endpoint before
  traffic becomes material or availability becomes operationally important.
- Production clients must never use `tile.openstreetmap.org` as the offline tile
  source. Generate a Lebanon package from an OSM database extract under ODbL,
  retain its source/date/derived-database record, host it in controlled storage,
  and download that package through the authenticated offline-map workflow.
- Online satellite remains, but the anonymous raw World Imagery URL must be
  replaced by a supported ArcGIS Location Platform/Online access-token or
  session integration with usage limits and dynamic provider attribution.
- Offline satellite remains a visible capability, but a package may be made
  downloadable only from imagery TerraLeb or its institution owns or licenses
  for offline/device redistribution. A public Esri URL is not that licence.
- Reports/takedowns do not automatically delete content. Authorized reviewers
  use the existing correction, restriction, unpublication and escalation paths.

### 9. AI

- **OWNER-DECIDED:** deploy the AI service and allow production inference, but
  create every project with AI disabled. Only the protected super-admin may
  enable it for that project, start/resume/cancel runs, validate/reject outputs,
  and decide whether to publish through the existing review workflow.
- **OWNER-DECIDED:** inputs are approved project AOI/geometries, approved label
  fields/training samples and approved imagery/datasets. Do not send names,
  emails, phones, credentials, session/device data, contributor UUIDs, private
  drafts, notification content, or unrelated comments/photos to AI/GEE.
- GIS data can still expose property, habitat, infrastructure or other sensitive
  sites even when it has no account PII. Project authorization and sensitive-site
  classification therefore remain required.
- **OWNER-DECIDED:** AI training/model improvement outside the project run is
  prohibited. The project-specific classification/training operation may use the
  approved GIS samples solely to create that project's reviewed output; it may
  not feed a general external model or unrelated project.
- Record the model/operator/version, GEE account/edition, dataset sources and
  licenses, hosting/recipients, evaluation version, accuracy/error limitations,
  human reviewer, retraction/incident process, retention and public `AI-derived`
  label before the first real production run.
- AI assists a human reviewer; it must not autonomously determine land title,
  legal boundaries, project eligibility, account sanctions or public release.
- `AI_PIPELINE_ENABLED=true` makes the service available. It must not override
  the per-project default-off flag or protected-super-admin authorization.

### 10. Content, moderation and safety

- The protected super-admin/privacy-moderation queue is the accountable workflow.
  Ordinary administrators see only cases their existing authorization permits.
- Automated acknowledgement is immediate. Human triage target: 2 business days;
  routine resolution target: 10 calendar days. Urgent safety, privacy or
  credible illegal-content reports are escalated promptly to the designated
  owner and counsel/institution as applicable.
- A report is an allegation, not proof. TerraLeb does not automatically delete,
  hide, block or punish merely because a report was submitted.
- Supported outcomes are dismiss, request information, review, correct through
  the canonical workflow, restrict/unpublish through existing authority,
  escalate, or close after the action is independently completed.
- Affected users receive a safe reason and review/appeal route unless disclosure
  would expose another person, project security or a lawful investigation.
- There is no public feed, stranger discovery or one-to-one chat at v1; an
  end-user social blocking feature is therefore not needed. Existing account
  block/restriction and project authorization controls remain.
- Evidence for moderation outcomes follows the three-year closed-case rule,
  subject to the seven-year audit rule only where a protected administrative
  decision record is genuinely required.

### 11. Terms of Use decisions

- Governing law: laws of the Lebanese Republic, subject to mandatory law.
- Venue: competent courts of Beirut, Lebanon, unless mandatory law requires
  another venue. No mandatory consumer arbitration is introduced.
- No term waives non-excludable statutory rights or liability for fraud,
  intentional misconduct, gross negligence, or other liability that cannot
  lawfully be excluded.
- Users must be adults, provide accurate account information, protect
  credentials, act only within assigned authority, respect access/property/
  photography/safety rules, and submit data they are authorized to provide.
- TerraLeb may suspend access for security, abuse, false authorization,
  confidentiality breach or material Terms/AUP violation. Provide a safe reason
  and review route unless security/legal restrictions prevent it.
- Service/map/GPS/offline/AI accuracy and availability are not guaranteed. This
  does not excuse TerraLeb from reasonable security, contractual commitments or
  mandatory duties.
- Do not add broad user indemnities or unlimited exclusions by default. Any
  narrow infringement/misuse indemnity requires counsel review.
- Give at least 14 days' notice for ordinary material Terms/AUP changes where
  practicable; urgent security/legal changes may apply sooner with prompt notice.
- Renewed acceptance is required for material changes to eligibility, user
  obligations, publication/content license, dispute terms, liability allocation,
  account termination/deletion, or new data reuse such as AI training. Editorial
  clarifications do not require renewed acceptance.
- For service end-of-life, give reasonable notice and an export window, preserve
  institutional handover, revoke credentials, and execute the retention/deletion
  plan. **COUNSEL** must approve the exact notice period and final clauses.

### 12. Lebanon Law No. 81/2018 questions for counsel

The product answer is to disclose processing accurately, minimize collection,
protect the data, support access/correction/deletion, and keep the ten-day
internal response target. The final legal memorandum should be narrow:

1. Confirm the exact Arabic Official Gazette article numbering and whether any
   notification, declaration, permit, licence or exemption applies to this exact
   account/GIS/photo/location/security processing.
2. Determine whether precise or security-relevant national-site data changes the
   conclusion, including any special authorization or public-sector rule.
3. Approve the interpretation and wording for access, correction and erasure and
   the internal ten-day target.
4. Determine the institutional/public-record basis, if any, for retained project
   contributions and decisions after account deletion.
5. Approve the complaint/competent-authority wording.
6. Check photography, property access, surveying/cadastral, copyright/database,
   consumer, telecom and public-record rules for the actual deployment.

Do not publish a guessed Article 94/95/96/97 conclusion. The owner policy remains
fail-closed if counsel says a formal step applies.

### 13. Store and release evidence

| Item | Owner answer | Evidence before release |
|---|---|---|
| Google Play legal entity | Same exact legal operator as the public policies | Developer account screenshot/export and authorized signer. |
| Android ID | `lb.terraleb.app` | Build, Play Console and Firebase registration all match; owner confirms the ID is controlled. |
| Apple | Public iOS release deferred | Readiness schema must represent `not_in_release_scope` with reason/evidence instead of falsely marking `appleApproved=true`. |
| Public policy URL | `https://terraleb.lb/legal/privacy` | Stable unauthenticated HTTPS page, not a PDF, from production. |
| Public deletion URL | `https://terraleb.lb/legal/account-deletion` | Explains deletion and permits initiating a request without requiring app installation; enumeration-safe. |
| Google Data Safety | Disclose the verified collection listed below | Console export/screenshots tied to app version and SDK inventory. |
| Permissions | Contextual notification/camera/photo/location explanation; no background location | Device tests and manifest diff. |
| Accessibility | WCAG 2.2 AA target for web and legal/privacy flows | Automated checks plus keyboard, screen-reader, text-scale, contrast and device evidence. |
| Approval | Exact named product/legal owner and Lebanese counsel | Date, document hashes/version IDs and immutable references. |

Preliminary Google Data Safety input, to be reconciled with the final binary and
contracts:

- Data collected: name, email, phone number, account identifiers, precise
  GIS/location content when deliberately captured, photos/files, project
  attributes/comments/reviews, app interactions/security events, diagnostics and
  device push token.
- Purposes: app functionality, account management, security/fraud prevention,
  institutional project workflow, and optional notifications.
- Not used for ads, marketing, analytics profiling, general model improvement or
  cross-project AI training. Approved project GIS may be processed by the
  protected-super-admin-controlled project AI workflow as app functionality.
- Encryption in transit is required; sensitive local data uses the existing
  encrypted storage design; server storage requires encryption and least
  privilege.
- Users can request deletion in-app and on the public web page.
- AWS and Firebase/Google handling must be classified according to the final
  service contracts and Play's definitions. Do not claim “not shared” until that
  contract-based classification is checked.

## Exact user-facing consent and notice decisions

### Signup

Use one unchecked checkbox, with account creation disabled until selected:

> I confirm that I am 18 or older. I agree to the Terms of Use and Acceptable
> Use Policy, and I acknowledge that I have read the Privacy Notice.

“Acknowledge” is used for the Privacy Notice because it is a notice, not bundled
consent. Terms and AUP acceptance records store the document type, version,
locale, user, time, and safe request/session evidence. Optional notification
permission is requested later in context. There is no generic-AI-reuse,
marketing or public-publication checkbox at signup. The project-specific GIS
licence and AI-processing notice belongs in contributor enrolment/project
participation, where it is relevant and specific.

### Contributor enrollment

> As a contributor, your submitted project records may become part of the
> institution's review and GIS history. If you later delete your account, your
> contact details and sign-in credentials will be removed. Records needed for
> project integrity may remain under a masked contributor label, subject to the
> project's retention and publication rules. Public release requires separate
> project authorization.

### Deletion confirmation

> Deleting your account removes your sign-in credentials, contact details and
> private account data. Project records that must remain for review, provenance
> or institutional integrity may be kept under a masked contributor label. Your
> request may wait while active responsibilities are safely transferred. You can
> cancel before it is approved or scheduled.

### Permission explanations

- Camera/photos: “Allow access only when you choose to add a project photo.”
- Foreground location: “Allow location while using TerraLeb to place or verify a
  project feature. TerraLeb does not need background location.”
- Notifications: “Allow notifications for assignment, review, request and
  security updates. Lock-screen previews are private by default and can be
  turned off.”

## Full 44-finding gate disposition

The current gate must remain at 44 findings until the decision, implementation,
approval and evidence layers are all true. Editing JSON booleans is not closure.

### Final authorization and counsel - 2

| Gate | Owner disposition | May become true when |
|---|---|---|
| `productionAuthorized` | Final action, not a policy question | All in-scope gates pass; named owner signs the exact build/config/documents. |
| `counselApproval` | Counsel pack is narrowed by this form | Lebanese counsel approves final Arabic/English documents and issues an immutable reference. |

### Owner/legal decisions - 18

| Gate | Selected answer | Remaining closure |
|---|---|---|
| `legalOperatorController` | Operator controls accounts/platform; project institution controls project purposes | Enter exact legal entities and execute role records. |
| `controllerProcessorRoles` | Allocation in section 3 | Contract/public-authority and counsel confirmation. |
| `targetTerritoriesAndDistribution` | Lebanon-only; Android/web; iOS deferred | Store-country and deployment evidence. |
| `minimumAgeAndMinors` | 18+; minors prohibited | Implement/test age confirmation and publish wording. |
| `privacyContact` | `privacy@terraleb.lb`, monitored owner role | Register domain, provision mailbox, run request test. |
| `hostingRegionsAndSubprocessors` | OCI Jeddah A1/32 GB is the selected regional initial target after ARM proof; OCI E4 x86 is its regional fallback; Hetzner EU remains the lowest-cost non-regional alternative; FCM/Play and GEE are the other enabled external services; no SMS/analytics | Create the operator tenancy, test Lebanon latency/capacity, execute terms/DPA and record account/region/architecture evidence. |
| `retentionMatrix` | Schedule in section 6 | Counsel ratification, configuration and cleanup evidence. |
| `retainedInstitutionalRecordBasis` | Retain narrowly for project integrity/institution authority | Institution agreement and counsel conclusion. |
| `maskedContributorDisplayPolicy` | Initials internally; generic `Contributor` publicly | Implement visibility policy and regression tests. |
| `photosPreciseLocationFreeTextTreatment` | Status/sensitivity-based retention; no automatic free-text rewriting | Counsel approval and operational privacy-review test. |
| `backupAgeingPeriod` | 35 days | Infrastructure lifecycle and restore-suppression evidence. |
| `contributorAndDeletionNoticeWording` | Wording in this form | Counsel/legal-owner approval and UI/version tests. |
| `mapAndOfflineRights` | Preserve online Street and online/offline Hybrid; use OSM online, credentialed ArcGIS online and a Copernicus/OSM-derived TerraLeb offline package | OSM policy/ODbL evidence, ArcGIS online account/token, Copernicus scene/terms/provenance record and package tests. |
| `gisOwnershipAndPublication` | Limited operational license; institution-authorized publication only | Project terms/authority and tests. |
| `aiTrainingAndPublication` | Project AI is default-off and protected-super-admin controlled; project-specific GIS processing is allowed; general/cross-project training is prohibited; publication remains separately reviewed | Data-minimization tests, GEE/account terms, provenance/evaluation evidence and authorization tests. |
| `governingLawAndDisputes` | Lebanese law; Beirut courts; mandatory-right carve-out | Counsel approves exact Terms wording. |
| `requiredLanguages` | Arabic + English legal/critical flows; Arabic recommended controlling | Translation, RTL/accessibility tests and counsel approval. |
| `lebanonLaw81Formalities` | No guessed conclusion | Counsel memorandum on the exact facts in section 12. |

### Store disclosures - 2

| Gate | Disposition |
|---|---|
| `appleApproved` | iOS is out of v1 scope. Change the gate schema to an evidence-bearing `not_in_release_scope`; do not lie by marking it approved. If iOS is later released, complete Apple labels, manifests, review, IDs and deletion evidence. |
| `googlePlayApproved` | Complete Data Safety, account-deletion, content/permission, target-audience 18+, production access/testing and privacy URL declarations against the signed binary; retain console evidence. |

### Platform readiness - 11

| Gate | Required proof |
|---|---|
| `accountDeletionVerified` | Enable only after signed retention/record policy; exercise viewer, contributor, admin, protected-super-admin rejection, retry, backup ledger and multi-device revocation. |
| `iosPurposeStringsVerified` | iOS is out of v1. Represent N/A with reason. Before any iOS release, verify source strings and final archive manifests. |
| `privacyManifestInventoryVerified` | For Android/web v1, preserve full SDK/data inventory. For a later iOS archive, validate `PrivacyInfo.xcprivacy` and every SDK manifest. |
| `productionIdentifiersVerified` | Replace `com.example...` and placeholder iOS IDs; verify `lb.terraleb.app`, Firebase registration, signing, domain links and store ownership. |
| `privacyRightsFulfillmentVerified` | End-to-end access export, correction and deletion tests with authorization, artifact isolation, expiry and evidence. |
| `retentionAutomationVerified` | Every enabled row mapped to idempotent cleanup, dry-run, audit, rollback and alert evidence. |
| `notificationPrivacyVerified` | Generic push body by default, authenticated detail fetch, preview toggle, permission timing and token cleanup on real devices. |
| `ugcModerationVerified` | Protected queue, authorization, report lifecycle, canonical actions, appeal/review, no automatic deletion and safe notification tests. |
| `accessibilityVerified` | Legal/consent/deletion/moderation flows pass text scaling, screen reader, keyboard/focus, contrast and responsive-dialog checks. |
| `softwareLicenseAndSbomVerified` | Flutter/backend/container dependency/SBOM reports reviewed; prohibited or incompatible license findings resolved; notices published. |
| `importProvenanceEnforcementVerified` | Enable fail-closed import provenance after migration/backfill; reject restricted/unknown sources where policy requires; test exports and attribution. |

### Maps and attribution - 4

| Gate | Disposition |
|---|---|
| `openstreetmapOnlineReviewed` | Keep online OSM for modest interactive use with an identifying User-Agent, normal caching, attribution, monitoring and no prefetch/offline use; prepare a paid/controlled fallback. |
| `esriOnlineLicensed` | Keep Satellite online through a real ArcGIS Location Platform/Online account, supported token/session endpoint, quota/budget alert and complete attribution. |
| `esriOfflineLicensed` | Esri is not the offline source. Change this boolean-only gate to evidence-bearing `not_applicable_replaced` and reference the Copernicus/OSM package approval; do not falsely mark Esri offline as licensed or bulk-download it. |
| `attributionVerified` | Device/screen/export/offline-package tests show OSM and any dataset-specific attribution without drawer/sidebar obstruction. |

### Legal documents - 7

Create immutable version `1.0` Arabic and English documents for Privacy Notice,
Terms, Acceptable Use, Important Notices, Account Deletion, Subprocessors and
Open Source. Use the decisions in this form, remove placeholders only after the
operator facts are inserted, set the effective date to launch, retain prior
versions, and obtain counsel approval. Terms and AUP require renewed acceptance
only on the material changes defined above. The Privacy Notice is acknowledged,
not accepted as optional consent.

## Repository implementation check

The owner decisions are not yet the deployed behavior. The current repository
check found the following material gaps:

1. The public documents are still English drafts with owner/counsel placeholders;
   no counsel-approved effective version exists.
2. The Flutter legal experience has no Arabic localization/RTL implementation.
3. Android still has the fallback `com.example.lebanese_gis_mobile` application
   ID and iOS identifiers are placeholders.
4. Production/staging examples do not yet contain the complete legal/privacy,
   deletion, retention, provenance, domain and provider configuration contract.
5. `LEGAL_ENFORCEMENT_ENABLED=false`,
   `ACCOUNT_DELETION_EXECUTION_ENABLED=false`, and
   `IMPORT_PROVENANCE_ENFORCEMENT_ENABLED=false` correctly keep unfinished
   behavior fail-closed.
6. `AI_PIPELINE_ENABLED=false` in production examples no longer matches the
   revised owner decision. The production overlay must enable the service while
   keeping every project's stored AI setting default-off and enforcing protected-
   super-admin enable/run/review/publication controls.
7. `PHONE_ASSURANCE_MODE=format_only` matches the v1 decision, but policies/UI
   must not claim SMS or possession verification.
8. Offline Esri already has a feature flag. Online Esri currently calls an
   anonymous legacy endpoint and must move to supported credentialed ArcGIS
   access. The selected Copernicus/OSM offline Hybrid package is not yet built or
   evidenced.
9. The map User-Agent is partly configurable but several widgets retain a
   hard-coded package value. The online OSM policy, controlled offline street
   package and provider budget/failover behavior are not yet evidenced.
10. The current readiness schema treats deferred/not-applicable Apple and Esri
    work as a required `true`. It should use explicit status, reason, approver and
    evidence fields instead of encouraging false approvals.
11. The account-deletion/export pipelines have substantial implementation and
    tests, but their production flags must remain false until policy, migration,
    end-to-end staging, backup and operational evidence are complete.
12. Store console declarations, signed build verification, domain/DNS ownership,
    AWS/Firebase agreements, staging metrics, pilot evidence and counsel approval
    are external artifacts and are not present in source control.

## Required engineering and configuration work

Complete in this order, preserving feature flags and rollback:

1. **Readiness schema v2:** represent `approved`, `blocked`,
   `not_in_release_scope`, `owner`, `reviewedAt`, `reason`, and immutable
   `evidence[]` for every gate. Migrate the verifier/tests without automatically
   approving anything.
2. **Operator configuration:** after the real operator is supplied, update public
   identity/contact/domain configuration and validate that placeholders cannot
   ship.
3. **Bilingual legal catalog:** produce counsel-reviewed Arabic/English v1
   documents, RTL-capable screens and consistent versioned acceptance. Do not
   translate names/clauses ad hoc in code.
4. **Release scope:** make Android/web the explicit v1 matrix. Keep iOS source and
   tests healthy, but exclude public iOS evidence from the v1 candidate gate.
5. **Production identifiers:** adopt the controlled Android ID, signing key,
   Firebase app, domain/app links and store record. Do not rename until ownership
   is confirmed because application IDs are effectively permanent.
6. **Vendor/region configuration:** provision Bahrain infrastructure, private
   network/storage, encryption, secrets, SES, backup lifecycle, restore
   suppression and redacted monitoring; record contracts and regions.
7. **Map source control:** preserve both styles; centralize every tile layer on
   the configured identifying User-Agent/provider adapter; use OSM online within
   policy, credentialed ArcGIS online imagery, and a controlled Copernicus
   Sentinel-2/OSM-derived offline Hybrid package. Fail downloads closed when the
   selected package lacks source, terms, checksum or attribution evidence.
8. **Provenance:** backfill valid source/license metadata, enable fail-closed
   import provenance, and propagate attribution/restrictions into maps, offline
   packages, publications and exports.
9. **Retention:** turn the approved table into validated configuration, map each
   row to cleanup/anonymization jobs and test dry run, retry, transaction rollback,
   metrics, alerts and legal holds.
10. **Rights/deletion:** execute production-like access, correction and deletion
    cases; validate tombstones/initials, internal/public visibility, export
    isolation, backup ledger, session/device revocation and local-device cleanup.
11. **AI production overlay:** harden and deploy the Python service, GEE
    credentials, callback secret, persistent outputs, restart/resume handling,
    input-field allowlist, per-project default-off state, protected-super-admin
    authorization, provenance/evaluation, cost quotas and human publication gate.
12. **Moderation/privacy operations:** staff and exercise the protected queue,
    mailbox, escalation, appeal, correction, export and deletion runbooks.
13. **Store/binary reconciliation:** inventory the final Android manifest and all
    dependencies, generate SBOM/license notices, complete Data Safety/account
    deletion declarations, test permissions/accessibility, and archive evidence.
14. **Staging/pilot:** measure security, performance, WebSocket privacy, worker
    recovery, cleanup, map attribution and privacy-right workflows on the exact
    candidate. Correct failures; never weaken the gate.
15. **Final approval:** hash the exact policy catalog and build/configuration,
    collect owner/counsel signatures and only then set production authorization.

### Release-candidate variables and secrets

The existing release workflow expects this exact non-secret variable contract in
the protected GitHub environment named `release-candidate`:

```text
ANDROID_APPLICATION_ID=lb.terraleb.app
ANDROID_VERSION_CODE=<MONOTONIC INTEGER ASSIGNED BY RELEASE OWNER>
RC_API_BASE_URL=https://<REAL APPROVED STAGING API HOST>
```

It expects these secret names:

```text
ANDROID_KEYSTORE_BASE64
ANDROID_GOOGLE_SERVICES_JSON_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

Do not put values in this document or source control. The Firebase client file,
signed bundle and Play application ID must match. `ANDROID_VERSION_CODE` must be
larger than every version previously uploaded to the selected Play application;
no report can safely guess it without the Play history. Use independent
reviewers, restrict secret access, and preserve the generated AAB, image digest,
SBOM, attestations and manifest evidence.

## Existing feature or behavior changes

These are the only intentional initial-production behavior decisions in this
form. They are configuration/release-scope changes, not removal of code.

| Previous/current capability | Initial-production behavior | Why necessary | Compatibility and proof |
|---|---|---|---|
| AI inference/validation code and workflows exist, while the production example disables the service | AI service is enabled in production, but every project starts AI-disabled and only the protected super-admin may enable/run/review/publish | This is the intended product workflow and prevents automatic processing | Authorization, default-state, input-minimization, GEE, restart, cost-limit and publication tests prove the boundary. General/cross-project training remains prohibited. |
| Esri World Imagery is selectable online; offline satellite is feature-flagged | Keep both modes: move online imagery to supported credentialed ArcGIS usage; source offline imagery only under explicit redistribution rights | Public URL reachability does not grant bulk/offline rights | Online functionality remains. Provider adapter, token/session, attribution, quota and offline-package licence tests are required. |
| Public OSM tile endpoint is used online and blocked for offline download | Keep modest interactive OSM online; generate controlled OSM-derived packages for offline Street | The public service permits policy-compliant interactive display but prohibits bulk/offline prefetch | No map mode is removed. User-Agent/caching/load tests and offline source assertions prove separation. |
| iOS project/source exists | No public iOS v1 release | Avoid a false Apple-readiness claim while identifiers/archive evidence remain incomplete | Source is preserved and may still be built in CI. Readiness records `not_in_release_scope`; later iOS release reopens Apple gates. |
| Current legal content is English | Arabic and English are required for legal and critical privacy/consent/safety flows | Lebanon-only users must receive understandable, consistent information | Add localization/RTL/accessibility tests and keep version/acceptance records locale-specific. Broader product translation can be phased separately. |
| Accounts do not currently enforce an 18+ owner policy | Signup requires an unchecked 18+ confirmation with Terms/AUP acceptance | The owner has selected a no-minors release | Existing adult accounts receive the approved material-policy notice/acceptance path; tests cover disabled signup and existing-user handling. |
| Current production defaults use `format_only` phone assurance | Keep format validation and do not claim SMS/ownership verification | Avoid an unnecessary SMS processor while remaining honest about assurance | No data-field removal. UI/policy wording and authentication tests must match the actual mode. |
| Masked initials may be usable wherever retained identity is shown | Masked initials are internal/authorized; public layers/exports use `Contributor` by default | Lower re-identification risk after deletion | Project/audit integrity remains. Authorization and export tests prove UUID/full identity are not exposed. |
| Contributor deletion eligibility currently waits for unfinished work/responsibilities | Protected-admin approval may intentionally discard drafts, pending/unapproved contributions and unfinished contributor-owned work; only accepted GIS and minimum final provenance remain | Matches the revised owner retention policy and avoids retaining unfinished user content | Confirmation UI must list what will be lost; transaction/idempotency tests prove accepted records stay, unapproved records disappear, responsibilities transfer and open holds/cases remain restricted. |
| Deletion and provenance execution flags are false | They remain false until the revised policy, schema/query behavior and evidence pass; then enable in a controlled rollout | Existing fail-closed design correctly prevents unsupported completion | No bypass. Tests, runbooks and rollback evidence are prerequisites for each flag. |

No project visibility, role, approval/rejection, offline collection, synchronization,
import/export, review, notification, moderation or account-security rule is
otherwise intentionally changed by this report. If implementation reveals that
one must change, document the old/new behavior, necessity, compatibility, tests,
deployment impact and user communication before merging it.

## Predeployment phases 0–8 closure

| Phase | Owner answer | What still closes it |
|---|---|---|
| 0 - clean baseline | No commit/push/reset is authorized by this report; preserve the dirty worktree | Review/commit existing changes in scoped commits; rerun clean-tree baseline. |
| 1 - architecture/security | Existing Node/Flutter/PostgreSQL architecture remains | Close current failing/conditional checks and retain evidence. |
| 2 - data/legal inventory | Use actual inventory; no analytics/ads/SMS/external AI at v1 | Reconcile inventory with final binary and AWS/FCM contracts. |
| 3 - public legal documents | Decisions and required wording are supplied here | Insert operator facts, translate, counsel approve, publish immutable v1. |
| 4 - privacy rights/retention | Deletion, masked identity and durations are selected | Configure, enable and prove only after approval. |
| 5 - maps/store/mobile | Verified Street online and Hybrid online/offline workflow remains; Android/web; iOS deferred | OSM online/ODbL evidence, ArcGIS online account, Copernicus/OSM offline-package evidence, IDs, attribution, permissions and Play evidence. |
| 6 - full verification | Scope is now defined | Run full backend/mobile/web/migration/security/performance suite on the candidate. |
| 7 - production-like pilot | Closed institutional Lebanon pilot | Real devices, real HTTPS/domain, production-like Bahrain services and signed evidence. |
| 8 - authorization/release | No automatic authorization | Named owner/counsel approve exact artifacts, rollback and operations. |

## Remaining facts that no responsible report can invent

This list is intentionally short. Everything else has a default decision above.

1. Exact legal operator/controller name, legal form, registration/authority and
   serviceable Lebanese address.
2. Actual accountable owner/privacy person and monitored contact details.
3. Confirmation that `terraleb.lb` (or replacement) is registered and controlled.
4. Exact participating institutions and their signed controller/authority/DPA
   roles for each project class.
5. AWS/Google legal entities, account owners, executed terms/DPA references,
   support/transfer details and paid service configuration.
6. Google Play developer legal entity, production account, application-ID
   ownership and console declarations.
7. Lebanese counsel's answers to the six narrow Law No. 81/public-record questions
   and approval of the Arabic/English policies.
8. Named approvers, approval dates, document/build hashes and immutable evidence
   references.
9. Actual staging/pilot results, backup restore test, security/performance results
   and operational staffing/on-call contacts.

These are facts and acts, not policy harshness. Marking them complete without
evidence would create a false release record and weaken TerraLeb's position.

## Owner approval block

This document can be adopted by the real owner after filling the external facts:

- Legal operator: `[REQUIRED]`
- Authorized owner name and role: `[REQUIRED]`
- Approval date: `[REQUIRED]`
- Version/hash approved: `[REQUIRED]`
- Exceptions accepted: `[NONE, OR LIST WITH OWNER/EXPIRY]`
- Signature/evidence reference: `[REQUIRED]`
- Lebanese counsel and role: `[REQUIRED FOR FINAL POLICIES/LAW CONCLUSIONS]`
- Counsel approval date/reference: `[REQUIRED]`

Until those fields, the engineering work and the evidence are complete,
`productionAuthorized` must remain `false`.

## Authoritative reference set

- [Lebanese Parliament - Law No. 81/2018 publication record](https://www.lp.gov.lb/PublicationDetails?Id=544)
- [Law No. 81/2018 English translation used only as a working aid](https://smex.org/wp-content/uploads/2018/10/E-transaction-law-Lebanon-Official-Gazette-English.pdf)
- [Google Play - Data Safety form requirements](https://support.google.com/googleplay/android-developer/answer/10787469)
- [Google Play - account-deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111)
- [Google Play - user-generated content policy](https://support.google.com/googleplay/android-developer/answer/9876937)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [OpenStreetMap copyright and ODbL attribution](https://www.openstreetmap.org/copyright)
- [OpenStreetMap Foundation public tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [AWS Regions - Bahrain `me-south-1`](https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html)
- [AWS service endpoints - Amazon SES](https://docs.aws.amazon.com/general/latest/gr/ses.html)
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/)
- [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/)
- [OWASP MASVS](https://mas.owasp.org/MASVS/)
- [NIST Privacy Framework](https://www.nist.gov/privacy-framework)
- [NIST Secure Software Development Framework](https://csrc.nist.gov/Projects/ssdf)
- [NIST AI Risk Management Framework](https://www.nist.gov/itl/ai-risk-management-framework)

The Arabic Official Gazette text and signed vendor/store records control over
summaries, translations or planning documents. Standards are used as control
baselines; TerraLeb must not claim ISO, OWASP, NIST or WCAG certification merely
because this report references them.
