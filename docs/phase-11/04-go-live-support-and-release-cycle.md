# Phase 11: Go-Live, Support Model, and Monthly Release Cycle

## Production Go-Live Checklist
1. Release gate green on final candidate.
2. Staging sign-off completed with pilot data profile.
3. Disaster recovery contacts and runbook verified.
4. TLS/certs/secrets rotation dates verified.
5. Observability dashboards and alert channels active.
6. Backup job success confirmed in the last 24h.
7. Rollback artifact/version identified before deployment.

## Hypercare (First 30 Days)
- Dedicated support window each business day.
- SLA targets by severity:
  - Sev-1: immediate response, continuous until mitigation.
  - Sev-2: response within agreed business window.
  - Sev-3/4: queued into next release train.
- Daily health review:
  - API readiness and error rate
  - sync queue backlog and dead-letter counts
  - export queue processing and failures

## Monthly Release Cycle
1. Week 1:
   - collect backlog and classify risk.
   - finalize candidate scope and test plan.
2. Week 2:
   - implementation freeze for release branch.
   - full phase 10 gates on candidate builds.
3. Week 3:
   - staging soak and UAT sign-off.
   - run deployment rehearsal.
4. Week 4:
   - production deploy window.
   - post-release verification + incident review.

## Release Governance
- No production release without:
  - technical sign-off (engineering lead)
  - operational sign-off (ministry ops owner)
  - product sign-off (program owner)
- Every release includes:
  - release notes
  - migration notes
  - rollback notes
  - known issues and mitigations
