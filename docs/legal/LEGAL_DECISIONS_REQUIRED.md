# TerraLeb legal decisions required before public production

Status: **BLOCKING - owner and qualified counsel approval required**

Last technical review: 2026-08-16

This register is a release control, not legal advice. Engineering must not replace
the `DECISION REQUIRED` entries with assumptions. The production legal-readiness
gate remains closed until every blocking item has an accountable owner, dated
decision, evidence reference, and legal approval where indicated.

| Decision | Current verified state | Required owner decision | Why it blocks production |
|---|---|---|---|
| Legal operator/controller | DECISION REQUIRED | Exact legal name, registration/public-body status, physical address and jurisdiction | Privacy notices, contracts, requests and store listings cannot identify a fictional controller. |
| Controller/processor roles | DECISION REQUIRED | Role of TerraLeb operator, NCRS/CNRS, ministries, project owners and hosting vendors | Determines instructions, data-subject handling, contracts and liability. |
| Distribution model | Controlled staging is documented; public government production is not approved | Private managed distribution, institutional pilot, public stores and/or public web | Store rules, consumer terms, moderation and territorial scope differ. |
| Target territories | **OWNER DECISION RECORDED 2026-08-13: TerraLeb is intended to be offered and targeted only in Lebanon. Counsel/store evidence is still pending.** | Confirm the Lebanon-only wording, configure Apple/Google storefront availability, and approve how access outside Lebanon is handled | Territorial targeting is decided, but store configuration and legal approval must match it. Public legal/privacy URLs must remain reachable where platform rules require them. |
| Minimum age | DECISION REQUIRED | Minimum age, whether minors are permitted and guardian/organization controls | Signup cannot make an unsupported age representation. |
| Privacy contact | DECISION REQUIRED | Public privacy email/address and responsible team; DPO/representative if required | Notices and rights workflows require a reachable contact. |
| Hosting and data regions | Proposed architecture exists; final production region is unapproved | Approved primary, backup, log and support-access regions | Required for transfer analysis, vendor contracts and notices. |
| Subprocessors | Firebase, SMTP/SMS providers, map providers and hosting are configurable | Approve the actual production vendor/legal-entity list and DPAs | Store disclosures and privacy notice must match actual processing. |
| Retention schedule | Export/log operational defaults exist; no complete approved schedule | Approve each category, trigger, period, action, legal hold and backup expiry | Automated deletion must not guess legal or public-record duties. |
| Account deletion and retained records | A reviewed, role-aware deletion pipeline now exists behind a disabled production flag. It erases direct identifiers and preserves justified institutional relationships using a non-authenticatable tombstone and a one-time pseudonymous masked label. | Approve the basis, exact retained record classes/fields, retention, visibility of masked attribution, photos/location/free-text treatment, responsibility-transfer rule, and user notices. | A Terms clause or contributor consent alone does not establish indefinite retention. A masked label reduces risk but is not legal anonymity. |
| Backup ageing after deletion | The pipeline records an expiry schedule but does not rewrite backups. | Maximum backup age, restore suppression procedure, evidence retention and exceptions | Completion wording and operations cannot promise an unapproved backup deadline. |
| GIS contribution ownership | DECISION REQUIRED | Ownership, custodianship, license, attribution and withdrawal rules | Terms cannot grant rights the operator has not chosen or does not possess. |
| Publication authority | Existing admin review exists | Who may publish, retract and approve sensitive/public layers | Prevents unauthorized disclosure and policy changes through code. |
| AI training | Existing schema contains future-training flags, but no approved legal basis | Whether contributions may train models, legal basis, opt-in/opt-out and retention | Private data must not become training data through an implied general license. |
| AI responsibility | Human review exists | Approved use cases, prohibited reliance, accountable reviewer and retraction process | Required for accurate notices and safe publication. |
| Basemap/provider rights | OSM and Esri endpoints are present; Esri offline entitlement is not evidenced | Licensed production provider, attribution text, cache/offline and export rights | Unlicensed bulk/offline use can violate provider terms. |
| Governing law/disputes | DECISION REQUIRED | Governing law, venue/process and mandatory-right carve-outs | Terms must not invent or waive rights incorrectly. |
| Required languages | English UI currently dominates | English/Arabic/French requirements and controlling-language rule | Users must receive comprehensible, consistent notices. |
| Lebanon Law 81 formalities | Technical assessment only | Counsel determination on Articles 94/95 notification or permit and Article 96 information | Engineering cannot determine the applicable legal exemption or authorization. |
| Government/public-record duties | DECISION REQUIRED | Classification, archival, access, sensitive-site and deletion rules | These duties may override ordinary deletion expectations. |
| Counsel approval | Not granted | Named approver, scope, date and immutable evidence reference for every published version | Draft engineering text must never be represented as final legal advice. |

## Required completion evidence

For each row, record the decision in the controlled legal repository and update
`apps/api/docs/legal/release-readiness.json`. Evidence references must not contain
secrets or personal legal correspondence. Policy files must be approved verbatim;
approval of a topic does not approve later text changes.

## Engineering constraints

- Draft policies may be served only outside production.
- Production must serve only a current, counsel-approved document version.
- Deactivation and deletion remain distinct.
- Production account-deletion execution and retention cleanup stay disabled until
  their policies are approved and evidence references configure the release;
  requests may still be received and tracked.
- Esri/offline basemap downloading stays disabled unless an approved license is
  recorded and the production build flag is explicitly enabled.
- A successful test suite does not change this register's legal status.

## Account deletion decisions still required

The owner has approved these product rules for engineering review:

- Every non-protected-super-admin role may initiate an in-app deletion request.
- Contributors may initiate a request, but fulfillment must wait until no pending
  or approved project assignment remains and no submitted contribution remains
  in `pending_review`.
- Deactivation remains separate and contributor-only.
- Direct identifiers, credentials, contact details and the full profile name are
  erased by the proposed execution pipeline.
- Justified contribution and decision records retain their internal relationship
  to a permanently non-authenticatable tombstone and display a one-time
  pseudonymous label: `Ali Hassan` becomes `A. H.`. The full name is not retained
  merely to regenerate the label.

The pipeline is implemented so it can be tested, but remains **disabled for
production**. The legal owner/counsel must answer, for each
comment/collection/review/approval/audit record class:

1. Is it an institutional/public record, ordinary user-generated content, or
   another record type?
2. What specific legal, contractual, public-interest, or records-management basis
   requires the record to remain after account deletion?
3. What exact non-identifying fields remain, for how long, who may see the masked
   label, and may it appear in public exports?
4. Must the former live user ID be severed and replaced by an immutable
   attribution snapshot?
5. What correction, objection, takedown, legal-hold, and appeal rules apply?
6. How should photographs, precise location history, identity in arbitrary free
   text, legal holds, and restored backups be handled?
7. What exact notice is shown before contributor enrollment and before deletion?

Until those answers and the retention matrix are approved, deletion requests may
be received and tracked, but deletion completion remains fail-closed.
