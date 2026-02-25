# Phase 11: Operations Checklists

## Pre-Deploy Checklist
- [ ] DB backup completed and artifact verified.
- [ ] Pending migrations reviewed.
- [ ] `npm run release:gate` passed on release candidate.
- [ ] Staging verification passed (`npm run staging:verify`).
- [ ] Rollback procedure and version confirmed.
- [ ] Deployment communication sent to stakeholders.

## Post-Deploy Checklist
- [ ] `/health` and `/ready` endpoints returning success.
- [ ] Auth/login smoke flow validated.
- [ ] Feature create/submit/review smoke flow validated.
- [ ] Export request/download smoke flow validated.
- [ ] Error-rate and latency dashboards checked.
- [ ] No critical alerts within first monitoring window.

## Incident Checklist
- [ ] Severity assigned (Sev-1/2/3/4).
- [ ] Request IDs captured from failing flows.
- [ ] Immediate mitigation applied.
- [ ] Root cause documented.
- [ ] Corrective actions added to backlog.
- [ ] Post-incident review completed with owners.
