# TerraLeb processing register (ROPA-style engineering draft)

This is an engineering register for legal completion. `DECISION REQUIRED`
means the controller, lawful basis or retention has not been approved.

| Activity | Data/subjects | Current purpose | Recipients | Retention | Legal/controller decision |
|---|---|---|---|---|---|
| Registration and contact assurance | Applicants; identity, phone, email, credentials, challenge/security data | Create and verify accounts; prevent abuse | Operator, SMTP/SMS provider | DECISION REQUIRED | Controller and lawful basis required |
| Authentication and RBAC | Users; sessions, role, assignments, IP/security events | Secure access and enforce project visibility | Operator/hosting | DECISION REQUIRED | Security/contract/public-task basis required |
| Field collection | Contributors; precise geometry, attributes, photos, device-local drafts | Collect project GIS evidence | Project team/operator | DECISION REQUIRED | Project purpose, field authority and notice required |
| Review/publication | Contributors/reviewers; submissions, notes, decisions, published layers | Quality control and authorized dissemination | Authorized team; public only when approved | DECISION REQUIRED | Publication authority and sensitive-site rules required |
| Imports | Uploaders and persons represented in source files | Bulk project ingestion | Operator/project reviewers | DECISION REQUIRED | Import provenance and third-party rights required |
| Exports | Requester and data represented in selected project | Authorized portability/distribution | Requester/admin and downstream recipient | Operational file default currently 7 days; policy unapproved | Redistribution/license rules required |
| AI analysis/validation | Contributors/reviewers; GIS inputs, photos/evidence where configured, predictions | Classification, quality improvement and reviewed mapping | Operator/AI service | DECISION REQUIRED | Model/data scope and lawful basis required |
| AI training reuse | Accepted contribution flags | Future model improvement | DECISION REQUIRED | DECISION REQUIRED | Must remain disabled without separate approval/basis |
| Notifications | Users; identifiers, workflow messages, device token | Inform users of workflow changes | Firebase when push enabled | DECISION REQUIRED | Generic preview is the safe default |
| Support/administration | Users/admins; account/support records | Resolve problems and administer service | Restricted staff | DECISION REQUIRED | Access and support vendor rules required |
| Security/audit/incident response | Users and attackers; IP, actions, identifiers, logs | Prevent, detect and investigate misuse | Restricted security/operations staff | Log default 14/30 days varies by component; policy unapproved | Legal hold and incident rules required |
| Offline operation | Signed-in user; cached projects, drafts, photos, maps | Continue authorized field work without connectivity | User device | DECISION REQUIRED | Device loss, logout and deletion behavior must be disclosed |

For every activity, counsel/owner must complete: controller, joint-controller or
processor status; categories of recipients; legal basis; mandatory/optional
fields; consequences of non-provision; source; transfer mechanism; retention;
rights/exceptions; and responsible owner.
