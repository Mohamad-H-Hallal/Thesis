# TerraLeb outstanding legal facts and approvals

Status: **owner product policy adopted; public production remains blocked by the external items below**

Last review: **2026-09-05**
Owner policy: `TERRALEB_OWNER_POLICY_DECISION_RECORD_V1.md`

This is a release control, not legal advice. Product-policy questions that the
owner can decide are now answered. The remaining entries are facts, contracts,
provider evidence, formalities, or counsel conclusions that cannot be generated
truthfully by code. Each requires a responsible person, date, exact release or
document version, and immutable evidence reference.

## Owner policy now settled

| Topic | Adopted decision | Remaining verification |
|---|---|---|
| Distribution | Lebanon-only Android and authenticated web v1; iOS public release deferred | Configure final Google Play territory and verify the deployed web scope. |
| Minimum age | 18+; minors are not permitted; do not collect birth date solely for proof | Implement/verify the affirmative age control and obtain counsel review of wording. |
| Languages | Arabic and English on legal and decision-critical surfaces | Professional translation/RTL review and counsel approval of the controlling-language clause. |
| Role model | Operator controls accounts/security/platform operations; project institutions control or authorize project purpose/review/retention/publication; TerraLeb is a service operator for institution-directed project data | Bind each actual institution and vendor to a signed role/authority record. |
| Retention | The durations and actions in `RETENTION_MATRIX.md` are adopted | Complete every cleanup path, staging evidence, and counsel approval. |
| Deletion | Reviewed request; all roles except protected super admin; unfinished work may be explicitly discarded; direct identifiers removed; accepted GIS/minimum provenance retained | Counsel approval, enabled production references, and provider-backed end-to-end evidence. |
| Masked attribution | Authorized/internal retained records use a one-time Unicode-safe masked label; public layers/general exports use `Contributor`; never show deleted UUIDs | Counsel confirms retained-record basis and visibility wording. |
| Photos/location/free text | Rejected/private data follows shorter deletion; accepted records follow project sensitivity/retention; no automatic publication; structured snapshots are scrubbed; arbitrary free text creates restricted review tasks | Counsel confirms exceptional record classes and case/hold rules. |
| Backups | Automatic 35-day expiry; deletion ledger prevents restoration to active identity; no destructive backup rewrite | Prove DigitalOcean Droplet/Spaces lifecycle and isolated restore behavior. |
| GIS rights/publication | Limited operational licence for accepted contributions; uploader/source warranty; publication requires separate institutional and protected-super-admin approval; sensitive sites default private | Confirm each institution and imported dataset's actual authority and licence. |
| AI | Available, per-project default-off, protected-super-admin controlled, allowlisted GIS/project data only, human review, no general or cross-project training | Supply production image/GEE plan and provider/staging evidence. |
| Notifications/analytics/phone | Generic preview by default; push optional; no ads/analytics/SMS in v1; phone is format-validated only | Verify final Firebase terms/configuration and real-device behavior. |

## External facts and legal approvals still blocking production

| Item | Current state | Evidence required before approval |
|---|---|---|
| Legal operator/controller | Not supplied | Exact legal name and form/authority, registration or founding reference where applicable, jurisdiction, and the party authorized to publish/contract. |
| Serviceable operator address | Not supplied | Real approved public address tied to the operator. |
| Privacy/support contact | Proposed addresses are not evidence because the production domain is not yet controlled | Controlled domain, monitored mailboxes, accountable people, and coverage procedure. |
| Participating institutions | No role is inferred from NCRS/CNRS, ministry, municipality, or project names | Signed controller/processor/public-authority or project operating records for each project class. |
| Hosting/subprocessors/transfers | DigitalOcean FRA1 with an 8 GiB x86 core is the owner-selected candidate; no account or paid resource exists | Executed DigitalOcean terms/DPA, account owner, Frankfurt international-transfer/support-access facts, measured Lebanon latency, private storage/backup evidence, Firebase, ArcGIS, SMTP, and GEE entries. |
| Map/source rights | Engineering enforces online/offline separation; production account/source evidence is absent | OSM review, licensed ArcGIS online app, Copernicus/OSM source manifests, attribution, caching/offline/redistribution approvals. |
| Google Play | Organization/legal entity, final ID, signing and declarations not complete | Verified account, final app registration, policy URLs, Data Safety/account deletion/UGC declarations, signed AAB and review evidence. |
| Governing law/disputes | Owner selected Lebanon-only scope but no legal clause is approved | Lebanese counsel-approved governing law, venue/process, mandatory-right carve-outs, limitation/warranty language and change process. |
| Lebanon Law No. 81 formalities | Engineering assessment only | Counsel conclusion against the Arabic Official Gazette text, including applicable notification/exemption/permit/licensing and sensitive-site/public-record duties; official filing evidence if required. |
| Final public documents | Owner-reviewed English/Arabic drafts may be prepared, but no exact version is counsel-approved | Operator facts, professional language review, counsel approval tied to exact content hashes, effective date, publication authorization, and prior-version retention. |
| Production authorization | False | Named release owner authorizes the exact Git commit, images, signed build, configurations, documents, evidence set and rollback after every applicable gate passes. |

## Engineering rules

- Draft policies are unavailable in production.
- Production loads only an effective counsel-approved version.
- Privacy notice viewing is not bundled consent; Terms and Acceptable Use require
  affirmative acceptance and renewed acceptance only after material changes.
- Deactivation and deletion remain separate.
- Deletion, legal enforcement, provenance, map providers, and other gated
  capabilities remain fail-closed until their exact evidence references are
  configured.
- A passing test suite is engineering evidence, not legal compliance or
  production authorization.
