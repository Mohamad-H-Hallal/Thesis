# Changelog

## Unreleased release candidate

This release candidate consolidates the completed pre-deployment hardening work
from Phases 0–6. The final version and release date are assigned only by an
annotated `vMAJOR.MINOR.PATCH-rc.NUMBER` tag created from protected
`handover-ready`.

### Security

- Updated and audited JavaScript and Flutter dependencies.
- Isolated offline projects and encrypted mobile databases and local photos.
- Added private upload quarantine, malware-scanning policy, reconciliation, and
  recovery controls.
- Added shared Valkey-backed rate limits and durable background workers.
- Added production secret, storage, database-role, observability, backup, and
  alerting contracts.
- Added dependency, secret, SAST, container, release-image, and configuration
  gates.

### Reliability

- Added migration, restore, rollback, performance, and release verification.
- Added fail-closed Android release signing and non-placeholder application-ID
  enforcement.
- Added content-addressed release manifests, checksums, SBOMs, and GitHub build
  provenance attestations.

### External release gates

- A real staging environment, external storage, DNS/TLS, Valkey, malware
  scanner, alert delivery, off-server backup restore, physical Android device,
  macOS/iOS release environment, authorized pilot cohort, and release approvals
  remain mandatory evidence. They are not represented as complete by repository
  or local test results.
