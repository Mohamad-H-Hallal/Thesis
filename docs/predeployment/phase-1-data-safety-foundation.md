# Phase 1 - Data-Safety Foundation

Status: engineering controls complete; managed cloud resources are deliberately
not provisioned yet.

This is the authoritative pre-deployment data-safety policy. Historical
handover documents describe earlier demo readiness and must not be treated as a
current production approval.

## 1. Environment and hosting decision

The recommended production target is AWS Middle East (Bahrain), `me-south-1`,
subject to NCRS ownership, budget, procurement, latency testing, and data
residency approval. The region has three Availability Zones. Amazon RDS for
PostgreSQL supports PostGIS, including PostgreSQL 16 extension releases.

Target architecture after the later infrastructure phases:

- two API tasks spread across at least two Availability Zones behind a managed
  HTTPS load balancer;
- a private RDS for PostgreSQL 16 instance with PostGIS and Multi-AZ enabled for
  production;
- private S3 buckets for uploads, photos, imports, exports, and backup copies;
- a managed Redis-compatible service for shared rate limits and job state;
- managed secrets and separate KMS keys for staging, production, and backups;
- DNS names `staging-collector.<approved-owned-domain>` and
  `collector.<approved-owned-domain>`;
- no public database endpoint and no direct public object-storage listing.

No AWS resource, domain, subscription, or production secret is created by this
phase. Provisioning is a later controlled infrastructure action.

Staging and production must use separate cloud accounts where governance allows
it. At minimum they must have separate VPCs, databases, buckets, KMS keys,
secrets, service identities, log groups, domains, and backup policies.
Production data must not be copied to staging unless it is explicitly approved
and irreversibly sanitized.

Sources:

- AWS region and Availability Zone list:
  https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html
- RDS PostgreSQL PostGIS guidance:
  https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.PostGIS.html
- RDS PostgreSQL extension versions:
  https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html

## 2. Data classification

| Class | Examples | Required handling |
| --- | --- | --- |
| Restricted | database/JWT/signing/encryption keys, SMTP and cloud credentials, password-reset tokens | managed secret store only; least privilege; rotation; never logs, Git, backups without encryption, or staging copies |
| Confidential | user identity/contact data, precise locations and geometries, field photos, AI evidence, audit records, private projects, imports and exports | encryption in transit and at rest; authenticated authorization; private storage; logged access; retention and deletion policy |
| Internal | schemas, non-secret configuration, operational metrics, sanitized test fixtures | staff/service access only; integrity controls; no public publication by default |
| Public | explicitly approved published layers, public metadata, released client assets | publication workflow and audit record required; no inference that a stored object is public |

The most restrictive class of any record or file controls its storage, backup,
logging, export, and deletion behavior.

## 3. Recovery objectives

These are release targets, not claims of achieved service levels. They become
binding only after the staging disaster-recovery test proves them.

| Asset | Production RPO | Production RTO | Staging target |
| --- | ---: | ---: | ---: |
| PostgreSQL/PostGIS | 15 minutes | 2 hours | RPO 24 hours / RTO 8 hours |
| Private media and imports | 1 hour | 4 hours | RPO 24 hours / RTO 8 hours |
| Audit logs | 15 minutes | 4 hours | RPO 24 hours / RTO 8 hours |
| Versioned code and infrastructure definitions | committed change | 2 hours | same |
| Secrets and signing material | no untracked loss; recover by controlled rotation | 4 hours | separate staging keys |

If monitoring shows that these targets cannot be met, deployment stops until
capacity, retention, or the targets are formally changed and approved.

## 4. Backup policy

Production database:

- enable RDS automated backups and point-in-time recovery with 35-day
  retention;
- retain a final snapshot before destructive maintenance or instance deletion;
- create a daily logical custom-format dump for portability;
- store logical dumps in a separate backup account/bucket encrypted with a
  backup-only KMS key;
- enable versioning and Object Lock governance retention on the backup bucket;
- prevent the application role and normal production administrators from
  deleting backup versions;
- copy outside the production failure boundary. Cross-region copies require
  data-residency approval first.

Private objects:

- enable bucket versioning;
- write inventory and checksum reports;
- copy recoverable versions to the locked backup bucket;
- keep database and object backups from the same recovery window together so
  file references do not restore without their objects.

RDS automated backups support point-in-time recovery within the configured
retention period. S3 Object Lock requires versioning and can prevent protected
versions from being overwritten or permanently deleted.

Sources:

- RDS automated backup and point-in-time recovery:
  https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html
- RDS backup retention:
  https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.BackupRetention.html
- S3 Object Lock:
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html

Local dumps under `backups/` are excluded from Git and are only engineering
rollback points. They do not satisfy the off-server encrypted production backup
requirement.

## 5. Verified local restore procedure

The default Windows drill never restores into the source database:

```powershell
.\scripts\dev\restore_drill.ps1 `
  -ContainerName gis_app-db-1 `
  -Database gis_app `
  -User gis_user
```

It:

1. creates a PostgreSQL custom-format dump;
2. validates the dump catalog with `pg_restore --list`;
3. calculates SHA-256 and writes a manifest;
4. restores into a uniquely named temporary database;
5. compares exact row counts for every public table;
6. removes only the temporary database; and
7. writes a machine-readable drill report beside the ignored dump.

On 2026-07-28, both the pre-migration and post-migration drills passed:

- dump size: 90.42 MB;
- public tables compared: 35;
- exact row counts: matched;
- temporary restore databases: removed;
- semantic clean-install/upgrade comparison: 1,740 schema objects matched;
- semantic schema fingerprint:
  `501f114389a3ec2da0916f185cb73dc5f9de99bfd478fd3824250c14b9109fe2`.

`scripts/dev/restore_db.ps1` and `scripts/restore.sh` are disaster-recovery
tools, not drill tools. They require an explicit destructive confirmation,
validate the checksum/catalog, and create a pre-restore backup. Prefer restoring
to a new database/instance and switching traffic after validation.

## 6. Migration and rollback policy

- `infra/migrations` is the only API migration source.
- Applied migrations are immutable. Add a new migration; do not edit, rename,
  reorder, or delete history.
- The runner verifies filename and SHA-256 before checking or applying pending
  migrations.
- Hashes are line-ending independent. A small source-pinned compatibility file
  records only proven pre-release development hashes; changing the current
  source invalidates its compatibility entry.
- Use expand/migrate/contract releases: add compatible structures, backfill in
  restart-safe batches, switch code, validate, and remove old structures only
  in a later release.
- Do not combine irreversible data deletion with the release that introduces
  the replacement path.
- Every data migration records before/after counts and aborts on failed
  validation.

Migration `0040_predeployment_schema_reconciliation.sql` makes the historical
development-upgrade path semantically equal to a clean 40-migration install. It
does not delete application data.

Rollback order:

1. stop or drain writes;
2. capture timestamps, release SHA, database state, and object-storage state;
3. roll application tasks back only when the database change is backward
   compatible;
4. for schema/data recovery, restore PITR/snapshot/dump into a new instance;
5. validate migrations, row counts, authorization, media references, and smoke
   tests;
6. switch traffic only after approval;
7. preserve the failed instance and audit evidence until incident review.

Never run a down migration or `pg_restore --clean` against the active production
database as an unreviewed automatic rollback.

## 7. Phase exit record

Completed engineering gates:

- checksummed and catalog-validated backup tooling;
- two successful isolated restore drills;
- exact table-count verification;
- semantic schema-equivalence gate;
- immutable migration integrity enforcement;
- additive reconciliation migration;
- API release gate: 25 suites and 205 tests passed, 69.69% line coverage,
  two performance tests passed, and full/production npm audits found zero
  vulnerabilities;
- clean production API image build: passed, including non-root runtime and all
  migration-integrity assets;
- documented classification, RPO/RTO, environment separation, and rollback.

External deployment gates intentionally remain for the infrastructure phase:

- approve cloud account, domain, budget, and data residency;
- provision staging and production separately;
- configure encrypted off-server database and media backups;
- perform an RDS/S3 staging restore and prove the targets above.
