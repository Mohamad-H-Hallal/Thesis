# TerraLeb processing register (owner-approved operational model)

Status: product purposes and minimization rules adopted 2026-09-05; final legal
bases, named controllers/processors, contracts, and counsel approval remain
external release evidence.

| Activity | Data/subjects | Purpose and mandatory/optional status | Recipients | Owner retention | Outstanding legal/provider evidence |
|---|---|---|---|---|---|
| Registration/contact assurance | Applicant name, email, phone, credentials, challenge/security metadata | Required to create/protect an account. Email verification is required; phone is format-validated only. | Operator; contracted SMTP provider | Challenges 30 days; inactive unverified shell 30 days | Named operator, SMTP contract, exact account notice/legal basis |
| Authentication/RBAC | User, session, role, assignment, IP/security event | Required to secure access and private-project visibility | Operator and contracted host | Sessions 30 days after expiry/revocation; routine logs 30 days; restricted security events 1 year | Named operator/host roles and counsel review |
| Field collection | Contributor, deliberate precise geometry/accuracy, attributes, optional photos, local drafts | Optional user action within an assigned project; no continuous location tracking | Authorized project team/operator | Drafts 90 inactive days; accepted record active project plus 10 years after archive | Project authority, field notice, sensitivity classification |
| Review/publication | Submission, comment, decision, approved layer | Institutional quality control; public publication is a separate recorded decision | Authorized project team; public only when approved | Accepted record active project plus 10 years; published provenance while public plus 10 years after withdrawal | Institution/publication authority and sensitive-site rules |
| Imports | Uploader and data represented in source | Role-gated ingestion with source/right/provenance attestation and review | Authorized operator/reviewers | Temporary source 30 days; rejected source 90 days; approved source active project plus 2 years; provenance plus 10 years | Actual source rights; attestation alone is not approval |
| Ordinary exports | Requester and authorized project data | Role-gated operational export | Requester and authorized downstream recipient | Artifact 7 days; non-PII provenance 2 years | Redistribution/attribution terms per source |
| Personal-data access export | Requester and their own account/activity data | User-initiated privacy-right fulfillment; reauthenticated and user-isolated | Requesting user only | Encrypted artifact 24 hours; fulfillment/access evidence 2 years | Final operator/counsel notice and production key/approval references |
| AI analysis/validation | Approved project AOI, GIS labels/samples, imagery, predictions | Project-disabled by default; protected-super-admin controlled inference/validation/publication | Internal TerraLeb AI service and approved GEE/provider | Temporary/failed artifact 30 days; approved provenance/evaluation 10 years after retirement/withdrawal | Production image, GEE account/plan, dataset rights, counsel review |
| General/cross-project AI training | None authorized | Prohibited in v1 | None | None | Requires a new explicit decision before implementation |
| Notifications | User destination/token, notification identifier, generic transport message | Optional push; required in-app workflow messages remain in the authenticated app | Firebase only when enabled | User copy 180 days; token disabled immediately and deleted within 7 days after invalidation | Firebase entity/terms/region and real-device evidence |
| Support/privacy/moderation | Requester and case information | Resolve support, privacy, correction, deletion, and content reports | Restricted authorized personnel | Closed case 3 years, then remove PII/detail and retain minimum outcome evidence | Named operator, staff/role record, counsel review |
| Security/audit/incidents | Actor/security metadata and minimized logs | Prevent, detect, investigate, and evidence authorized decisions | Restricted security/operations staff | Routine 30 days; security 1 year; admin/audit decision 7 years | Incident/hold authority and named accountable owner |
| Offline operation | Signed-in owner-scoped cached projects, maps, drafts, encrypted photos | Continue authorized field work without connectivity | User's device | Draft rules above; affected owner's local data removed on completed deletion/logout rules | Final device-loss and user notice review |

For every deployed project/provider, the final release evidence must bind the
actual operator, institution and vendor roles; legal basis; mandatory/optional
fields; data sources; recipients/regions; transfer safeguards; retention;
rights/exceptions; and accountable owner. This register does not infer a legal
role from a screen label or database role.
