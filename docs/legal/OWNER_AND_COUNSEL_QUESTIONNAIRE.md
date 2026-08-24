# TerraLeb production legal-policy answer sheet

Status: **Required before public production**

Territorial owner decision recorded: **Lebanon only**

Last updated: 2026-08-13

This is an engineering input form, not legal advice. The named legal owner and
qualified Lebanese counsel must approve the answers and the exact published
documents. Do not enter secrets or privileged legal correspondence here; use an
evidence reference to the controlled approval record.

## 1. Operator and contacts

- Exact legal operator/controller name:
- Legal form or public-body status and registration/reference:
- Registered/official physical address:
- General support email and phone:
- Public privacy-request email/address:
- Responsible privacy team/person:
- DPO or other representative, if required (otherwise counsel basis for “not required”):

## 2. Distribution, users and age

- Confirm app/store availability is restricted to Lebanon: yes / no
- Distribution: public Apple App Store / public Google Play / managed institutional / web / pilot (select all):
- May a person physically outside Lebanon use an existing account? If yes, under what rule?
- Minimum user age:
- Are minors permitted? If yes, what guardian/institution authorization and verification applies?
- Required policy/UI languages: English / Arabic / French / other
- Controlling language if translations differ:

## 3. Parties and roles

For TerraLeb operator, NCRS/CNRS, ministries, municipalities, project owners,
hosting provider, AI operator and each institutional partner, state:

- controller / joint controller / processor / independent controller role;
- processing instructions and decision authority;
- responsibility for privacy requests, security incidents and publication;
- contract/DPA or public-law authority reference.

## 4. Purposes, legal bases and optional choices

Approve a purpose and basis for each actual use:

- account creation, contact verification and security;
- role, assignment and project administration;
- precise GIS/location collection and offline synchronization;
- photos, attributes, comments, reviews and approvals;
- imports, exports and publication;
- push notifications;
- audit, fraud prevention, incident response and legal claims;
- AI inference/validation;
- AI training or model improvement, if allowed;
- public layer publication, if allowed;
- marketing, if ever allowed.

For each purpose identify whether the data is required for the service, optional,
or subject to a separate opt-in/authority record. Privacy-notice acknowledgement
must not be used as bundled consent for optional purposes.

## 5. Vendors, subprocessors and data locations

For every production vendor provide legal entity, service, data categories,
primary region, backup region, support-access countries, contract/DPA reference,
transfer basis if needed, deletion commitment and change-notice process:

- API/application hosting;
- PostgreSQL/database hosting;
- object/photo/import/export storage;
- backups and disaster recovery;
- logs, monitoring, crash reporting and support;
- email provider;
- SMS/phone verification provider;
- Firebase/Google push services;
- map, imagery and tile providers;
- AI service/model hosting;
- any analytics or third-party SDK.

“Lebanon-only distribution” does not mean data stays in Lebanon; vendor regions
must be answered separately.

## 6. Retention and deletion

For every row in `RETENTION_MATRIX.md`, approve:

- trigger event;
- retention duration;
- delete / anonymize / archive / manual-review action;
- legal or records basis;
- legal-hold rule;
- backup expiry/deletion propagation;
- approval owner and evidence reference.

Also decide:

- deletion grace/cancellation period, if any;
- completion target and user notifications;
- how active admin/project ownership is reassigned;
- how unsynced device drafts are warned about and erased;
- what minimal request-fulfillment evidence remains and for how long.

## 7. Retained records and masked attribution after account deletion

Complete one row for each record class: collected-by, reviewed-by, approvals,
comments, project creation/ownership, imports, exports, AI validation/publication,
moderation and audit/security records.

For each class answer:

- Is it an institutional/public record or ordinary user-generated content?
- Must the record itself remain after account deletion?
- Exact legal/public-record/contractual basis for retaining the record:
- Exact non-identifying fields retained:
- May the pseudonymous masked label be visible to protected administrators,
  project members, all authenticated users, or public exports?
- Retention duration and trigger:
- Correction, objection, takedown and legal-hold procedure:
- Is retaining the internal immutable UUID necessary for relational integrity,
  and how is it prevented from becoming a public identity?
- Treatment of photographs, precise location history and arbitrary free text:
- Exact contributor-enrollment and pre-deletion wording:

A statement in the Terms or contributor consent is disclosure, not by itself
authority for indefinite record retention. The proposed label is
pseudonymous - not legally anonymous - and production deletion execution remains
disabled until this table is approved.

## 8. GIS content, maps and publication

- Ownership/custodianship of user and institutional contributions:
- Limited license needed to host, process, review and export contributions:
- Separate authority and approver for public publication:
- Sensitive-location/site classification and publication rule:
- Importer warranties and takedown/appeal process:
- Production street-map/tile provider and contract:
- Production imagery provider and contract:
- Online caching rights:
- Offline/bulk-download rights:
- Export/derived-work/redistribution rights and required attribution:

## 9. AI decisions

- Approved AI use cases and prohibited reliance:
- Model/operator, hosting region and data recipients:
- Whether private contributions, photos or locations may train models:
- If training is allowed, exact authority/opt-in, eligible datasets and retention:
- Human reviewer/accountable owner:
- Evaluation, bias/error, retraction and incident procedure:
- Public labeling required for AI-derived layers:

## 10. User content, moderation and safety

- Moderation owner and coverage hours:
- Report acknowledgement and resolution targets:
- Emergency/illegal-content escalation:
- Appeal and restoration process:
- Blocking/protection rules:
- Copyright, privacy and sensitive-location takedown contacts:
- Evidence retention for moderation actions:

## 11. Terms of Use decisions

- Governing law:
- Courts/venue or dispute process:
- Mandatory-right carve-outs:
- Account eligibility and organization authority:
- Suspension/termination grounds and appeal:
- Warranty/service-availability language:
- Liability limitation and exclusions:
- Indemnity, if any:
- Policy-change notice method and lead time:
- What counts as a material Terms/AUP change requiring renewed acceptance:
- Service end-of-life/data retrieval process:

## 12. Lebanon Law No. 81/2018 and public records

Counsel must record:

- applicable controller/processor duties and information wording;
- Article 94/95 notification or permit conclusion;
- Article 96 exception or authorization conclusion, if relevant;
- Article 101 access/correction/erasure interpretation and response deadlines;
- public-record/archive rules for government or institutional GIS records;
- competent complaint/regulatory contact wording;
- any additional Lebanese consumer, telecom, photography, surveying, cadastral,
  public-sector or records law that applies.

## 13. Store and release evidence

- Apple developer legal entity and production bundle ID:
- Google Play developer legal entity and production application ID:
- Public, non-PDF Privacy Notice URL:
- Public account-deletion request URL:
- Approved Apple privacy-label answers and evidence date:
- Approved Google Data Safety answers and evidence date:
- Permission/purpose-string review:
- SDK privacy-manifest and data-disclosure review:
- Accessibility review result:
- Counsel approver name/role, approval date and immutable evidence reference:
- Product/legal owner final production authorization:

After all answers are approved, publish new immutable document versions, update
the release-readiness evidence, implement the approved deletion/attribution and
retention behavior, verify store configuration, and then run the production
release gate. Passing engineering tests alone does not authorize release.
