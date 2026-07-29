# Production Infrastructure and Observability Security Design

This document defines the Phase 5 repository controls and the staging proofs
required before release. It does not authorize a staging or production change.
The canonical single-server reference deployment is:

```text
compose.prod.yml + compose.observability.yml
```

`apps/api/docker-compose.integration.yml` is only a local API dependency
fixture. It has no TLS edge, database, secret manager, or monitoring stack and
must never be used as a release deployment.

## Security invariants

- Production startup fails unless HTTPS enforcement, a trusted proxy hop,
  strict explicit HTTPS CORS origins, shared rate limiting, an external worker,
  malware scanning, real password-reset delivery, protected metrics, and
  redacted JSON stdout logging are enabled.
- Reserved, localhost, test, invalid, and placeholder `example` hostnames are
  rejected by production environment validation.
- The API and worker receive a restricted database credential. Only the
  one-shot migration service receives the database-owner credential.
- Secret values are mounted as per-service files. They are not placed in
  Compose command lines, Redis URLs, image layers, or repository files.
- Public Nginx routing cannot reach readiness, metrics, or API documentation.
  API documentation is disabled by default and requires a separate token if
  deliberately enabled for an internal path.
- Production images and API base images are pinned by immutable SHA-256 digest.
- Application containers have read-only root filesystems, bounded temporary
  filesystems, dropped Linux capabilities, `no-new-privileges`, PID limits,
  memory limits, CPU limits, graceful shutdown windows, and bounded Docker log
  rotation.
- Logs contain normalized paths without query strings. Passwords, tokens,
  cookies, credentials, private keys, database/Redis URLs, request bodies,
  contact fields, and GIS geometry/coordinates are redacted.
- Request IDs accept only a bounded safe character set; invalid or oversized
  incoming IDs are replaced. Nginx forwards a request ID to the API.
- Monitoring services have no public ports. Alloy reads Docker JSON log files
  read-only and is not given the Docker control socket.

## TLS and edge behavior

The unprivileged Nginx edge:

- redirects HTTP to HTTPS except the ACME challenge path;
- accepts TLS 1.2 and 1.3;
- disables session tickets and server version tokens;
- sets HSTS and browser security headers;
- bounds request bodies, connections, rates, and upstream timeouts;
- logs `$uri`, not `$request_uri`, so query values are excluded;
- exposes only `/health`, `/api/*`, and the Flutter web application.

First certificate issuance is an explicit operator action:

1. Point the approved DNS name at the staging host and verify it externally.
2. Stop Nginx if it is already bound to the HTTP port.
3. Set the real `PUBLIC_HOSTNAME` and `CERTBOT_EMAIL`.
4. Run:

   ```bash
   docker compose --env-file .env -f compose.prod.yml \
     --profile certificate-bootstrap run --rm --service-ports certbot-bootstrap
   ```

5. Inspect certificate subject, SAN, chain, permissions, and expiry.
6. Start the normal stack. `certbot-renew` checks renewal twice daily and
   Nginx reloads periodically.
7. Trigger a staging renewal rehearsal and verify the public TLS probe and
   expiry alert.

Do not run bootstrap while Nginx owns the HTTP port. Do not use a production
ACME account during repeated test rehearsals; use the provider's staging
endpoint in an operator-reviewed rehearsal procedure.

The repository supplies a hardened reverse proxy, not a managed WAF. Selection,
DNS cutover, origin allow-listing, bot/DDoS controls, request-size parity, and a
false-positive exercise for the real WAF remain an external staging gate.

## Database and storage privilege boundary

`POSTGRES_USER` is the database owner used by the database and one-shot
migration service. `DB_RUNTIME_USER` is the non-owner login used by API and
worker processes. After migrations, `db-security` runs
`infra/db/security/apply-runtime-grants.sh`, which:

- creates or rotates the runtime login idempotently;
- denies superuser, database creation, role creation, and replication;
- grants only connect/temp, schema usage, table DML, sequence use, and function
  execution;
- applies matching default privileges for later migrations;
- makes migration history read-only to the runtime role;
- revokes public schema creation.

The local isolated test proves runtime DML, denied DDL, denied migration-history
mutation, restricted role flags, password rotation, and preserved data.

For an existing managed database, a DBA must review ownership and grants before
switching credentials. Do not point this script at production without an
approved privilege inventory, backup, rollback role, and maintenance plan.

Only API and worker services mount upload/export volumes. Nginx, monitoring,
Valkey, ClamAV, and the database do not. A managed object-storage release must
use separate application and backup identities, deny public listing, restrict
bucket/prefix actions, and test signed access, revocation, retention, and
rotation in staging.

## Secrets and rotation

Single-server Docker secret files are a reference implementation. Managed
staging/production must use its approved secret manager, audit access, restrict
each secret to its consuming service, and retain version metadata without
logging values.

Rotate one credential class at a time:

1. Capture a fresh encrypted backup and confirm rollback access.
2. Record the current secret version, dependants, owner, and rollback version.
3. Add the new version without removing the old version where dual validation
   is supported.
4. Restart/reload only consumers and verify health, readiness, logs, queue
   progress, and a representative data read/write.
5. Revoke the old value after the grace period.
6. Verify the old value fails and no data was lost.

Credential-specific rules:

- JWT access/refresh: deploy new current plus old previous, verify new and
  existing sessions, then remove previous after token expiry.
- Database runtime: create/grant a next runtime login for zero-downtime managed
  rotation, move replicas, verify data, then revoke the old login. The
  single-server reference performs a controlled restart and reapplies the
  restricted grants.
- Database owner: rotate through the database provider/DBA workflow; changing a
  Docker initialization file alone does not rotate an existing role.
- SMTP: verify an allowed sender, delivery, bounce handling, and password-reset
  flow before revoking the old credential.
- Firebase: upload the new service-account version to the secret manager,
  verify push delivery, then revoke/delete the prior key in Firebase/IAM.
- Object storage: use overlapping key/role versions, verify read/write/delete
  only within approved prefixes, then revoke the old identity.
- Redis/Valkey: verify two API replicas and workers with the new password/TLS
  identity before revoking the old value.
- Malware scanner: rotate scanner/network credentials, verify EICAR rejection
  and scanner-unavailable fail-closed behavior, then revoke the old value.
- Metrics/docs/AI callback: rotate the producer and consumer together; prove
  old-token rejection and query/payload-free logs.

No real credential rotation is claimed until it is exercised in an approved
staging environment.

## Metrics, logs, and alerts

Prometheus scrapes token-protected API metrics and an internal HTTPS blackbox
probe. API metrics include:

- request count, status, in-flight work, and latency histogram using normalized
  bounded-cardinality paths;
- database and shared-rate-limit readiness;
- queued/running/dead-letter workloads;
- media cleanup and upload-quarantine backlog;
- recent malware detections;
- upload/export filesystem availability;
- process uptime and memory.

The alert rules cover API/edge availability, TLS expiry, dependencies, 5xx
rate, p95 latency, authentication attacks, rate-limit pressure, storage,
dead-letter work, cleanup, quarantine, malware, and missing backup telemetry.
`promtool` unit tests deliberately trigger representative critical/warning
paths. The committed Alertmanager receiver intentionally performs no external
delivery; an approved real receiver and received-notification evidence are
mandatory staging gates.

Loki retains local reference logs for 30 days. Real retention, access control,
encryption, regional residency, legal holds, cost limits, and deletion policy
must be decided before choosing the managed log platform.

## Dependency-failure exercise

In production-like staging:

1. Confirm baseline health, readiness, alerts, queues, and a checksum-backed
   data sample.
2. Stop access to one dependency at a time: Valkey, database, worker, malware
   scanner, object storage, SMTP, alert receiver, and logging destination.
3. Verify documented fail-closed/retry behavior, bounded backoff, no duplicate
   work, no unscanned release, no lost queue rows, and actionable alerts.
4. Restore the dependency and verify automatic recovery or the documented
   operator action.
5. Compare database/file checksums and audit events with the baseline.

Never combine this exercise with a production deployment.

## Mandatory external gates

Phase 5 repository completion does not close these release gates:

- real DNS, trusted public certificate issuance, renewal, and expiry alarm;
- managed secret-manager access policy and actual rotation of every credential
  class;
- reviewed managed-database and object-storage least-privilege policies;
- real WAF/reverse-proxy cutover and false-positive/load testing;
- approved Alertmanager receiver with deliberately received critical and
  warning alerts;
- centralized log access/retention/residency review and redaction sampling;
- controlled dependency failure with data-integrity evidence;
- Phase 1 encrypted off-server backup/restore evidence;
- Phase 2 real scanner cold-start, EICAR, outage, and matched storage/database
  inventory evidence;
- Phase 3 macOS/iOS release validation;
- Phase 4 two-replica managed Valkey and independent-worker staging evidence.
