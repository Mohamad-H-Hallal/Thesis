# TerraLeb privacy, incident, vendor and license operations

## Privacy request runbook

1. Confirm queue access is restricted to the approved privacy team.
2. Verify identity through the authenticated account or an approved ownership
   challenge; never disclose account existence to an unverified requester.
3. Acknowledge and classify the request; the service records a ten-day internal
   target pending counsel confirmation.
4. Locate account, local-device instructions, projects, drafts, media, imports,
   exports, AI records, notifications, audit/security records and backups.
5. Apply the approved correction, export, restriction, deletion, reassignment or
   pseudonymization rule. Exclude other users and security secrets.
6. Record exceptions/legal holds with an approved reason and reviewer.
7. Verify session/token revocation and downstream/vendor actions.
8. Notify the requester through an approved channel and close with evidence.

Detailed workflows:

- `PRIVACY_REQUEST_RUNBOOK.md`
- `CONTENT_MODERATION_RUNBOOK.md`
- `PERSONAL_DATA_EXPORT.md`
- `ACCOUNT_DELETION_AND_PSEUDONYMIZATION.md`

## Incident/breach triage

Contain access without destroying evidence; rotate exposed credentials; identify
affected systems/data/people/regions; preserve a privileged timeline; assess
confidentiality, integrity and availability impact; consult counsel on regulator,
customer and person notifications and deadlines; document decisions; remediate
root cause; validate restores; and complete a post-incident review. Do not place
personal data, tokens, raw photos or geometry in general incident chat/tickets.

## Map/provider outage or license revocation

Disable the affected source by configuration, retain attribution on cached data,
stop new offline/cache generation, identify distributed packages/exports, notify
operations and legal owners, switch only to a pre-approved source, and document
required purge or attribution propagation. Never evade provider limits by
rotating domains, user agents or credentials.

## Vendor/DPA checklist

Verify legal entity, service/data scope, documented instructions, security,
subprocessors, regions/transfers, retention/deletion, incident notice, audit
rights, government access, support access, availability/exit, map/data licenses,
AI training prohibition, and executed agreement/effective date.

## Policy review

Review at least annually and before new data, SDKs, vendors, territories,
permissions, public publication, AI purposes, map sources or material workflows.
Material Terms/consent changes require the approved notice/re-acceptance process;
minor clarifications retain version history without unnecessary re-consent.

## Production release checklist

- Run `npm run release:gate` in `apps/api`; do not waive a failed legal gate.
- Confirm the exact approved legal-document digests, effective dates, material-
  change classifications and counsel evidence reference.
- Verify public HTTPS legal/account-deletion pages and the non-enumerating
  `/legal/account-deletion/request` intake without authentication.
- Complete store disclosure, purpose-string, privacy-manifest, signing/bundle-ID,
  permission timing, notification-preview and account-deletion review.
- Confirm hosting regions, subprocessors/DPAs, incident contacts, backup expiry,
  approved retention rows and privacy-request fulfillment ownership.
- Set `IMPORT_PROVENANCE_ENFORCEMENT_ENABLED=true`; review legacy imports.
- Keep public OSM bulk download disabled; enable Esri offline only with recorded
  contractual rights and tested attribution.
- Verify AI model/dataset records, training authority, publication authority,
  human review, retraction and evaluation evidence.
- Run API/Flutter/security/integration/accessibility/build tests and archive the
  immutable results. A passing engineering gate is not a legal approval.

## Evidence-retention checklist

Retain access-controlled, integrity-protected evidence for the approved period:
policy versions/digests and acceptance records; owner/counsel approvals; vendor
contracts/DPAs and region evidence; map/data licenses; store submissions;
retention/hold/cleanup runs; privacy-request decisions; AI provenance,
evaluations and retractions; moderation/takedown decisions; incident timelines;
SBOM/license reports; test/build/signing attestations. Do not copy raw personal
data into evidence when an identifier, digest, count or privileged reference is
sufficient. Apply the approved evidence retention and legal-hold rules.

## Accessibility release review

Test legal, consent, permission, privacy-request, provenance and destructive-
action screens with screen readers, text scaling, keyboard/switch navigation,
focus order, color-contrast tooling and reduced-motion settings. Affirmative
controls must expose labels/state and must start unchecked. Record WCAG 2.2 AA
exceptions, owner, remediation date and retest evidence.
