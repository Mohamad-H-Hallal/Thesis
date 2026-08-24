# TerraLeb initial DPIA and risk assessment template

Status: initial engineering assessment; controller/counsel approval required.

## Scope and necessity questions

Document the specific public/institutional task or contract for each project,
why precise location/photos/identity are necessary, why less precise or
anonymous data is insufficient, who can access it, and whether affected people
reasonably expect the processing. Re-run the assessment for materially different
project schemas, public publication, new AI training, new territories or vendors.

| Risk | Existing control | Required additional control | Residual decision |
|---|---|---|---|
| Precise locations expose homes, property or sensitive sites | Project RBAC, review states, private API/media | Classification, purpose-bound schemas, sensitive-site publication rules, export review | Controller approval required |
| Photos identify people/property or capture unintended details | Normalization/security scanning, private routes, encrypted draft copies | Field notice/training, minimization/redaction and subject/takedown process | Controller approval required |
| Device loss exposes offline work | SQLCipher, owner scoping, protected photo storage | Verified purge on deletion/managed-device policy and recovery guidance | Residual risk approval required |
| Unauthorized project visibility/export | Server RBAC and scoped real-time delivery | Privacy regression tests, periodic entitlement review and export provenance | Security owner approval required |
| Map provider observes viewed area | Direct tile requests | Approved provider/contract or proxy design; clear notice | Vendor/privacy owner decision required |
| Push leaks project context on lock screen | In-app notification controls | Generic transport text by default and user-controlled preview | Test before enabling push |
| Imported third-party data lacks authority | Admin/reviewer workflow | Provenance/license declaration, quarantine and takedown | Publication owner decision required |
| AI prediction causes harmful reliance | Human review/publication states | AI labeling, intended-use limits, evaluation/provenance, retraction | AI accountable owner required |
| AI training repurposes contributions | Training-use field exists | Separate legal basis/choice, purpose notice, withdrawal propagation | Must remain disabled until approved |
| Account deletion destroys institutional records or leaves identifiers | Reviewed queue, automatic release of eligible assignments, credential erasure, tombstone and masked label | Approve retained-record basis/period/visibility; free-text/photo/location review; backup expiry and restore suppression | Legal/public-record decision required; masked attribution is not anonymity |
| Staff misuse/overbroad admin access | RBAC, audit logs, protected super admin | Privacy queue restriction, access reviews, incident monitoring | Operations approval required |
| Cross-border vendor access | Configurable vendors/regions | Final transfer map, contracts and support-access controls | Counsel approval required |

## Sign-off

Record the controller, privacy/legal reviewer, security reviewer, project owner,
AI owner when applicable, date, scope/version, residual risks, mitigations and
decision. A generic approval cannot cover later high-risk project schemas.
