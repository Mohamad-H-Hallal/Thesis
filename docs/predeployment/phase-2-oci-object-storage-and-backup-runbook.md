# Phase 2 OCI object storage and encrypted backup runbook

TerraLeb production uses five private, versioned OCI Object Storage buckets in `me-jeddah-1`. Application credentials receive only the uploads, exports, offline-package and AI-object permissions required by the API/worker. A different credential pair receives only backup-bucket object permissions. No bucket is public.

Database backups remain separate from PostgreSQL block storage. The ephemeral `database-backup` Compose profile creates a PostgreSQL custom-format dump, validates its catalog, encrypts it with an independent AES-256-GCM key, calculates plaintext and encrypted SHA-256 digests, uploads the encrypted envelope, then uploads a manifest. Plaintext and encrypted working files are removed after the attempt. OCI server-side AES-256 encryption is applied in addition to application encryption.

## Safe preflight

0. Use the `VM.Standard.E4.Flex` x86 default. The TerraLeb API passed an actual
   ARM64 build/runtime smoke test on 2026-08-26, but the pinned production
   PostGIS image exposes no ARM64 manifest. A1 remains blocked until the entire
   pinned database and external AI stack passes ARM64 validation.
1. Apply no infrastructure until the owner has reviewed the OpenTofu plan and current OCI price estimate.
2. Keep populated `terraform.tfvars`, state, plans, OCI keys and encryption keys outside Git.
3. Generate application and backup Customer Secret Keys separately; never reuse them.
4. Keep the backup encryption key in an offline recovery escrow as well as the host secret store. Losing it makes backups unrecoverable.
5. Configure a lifecycle/retention rule only after the approved backup-ageing decision exists.

## Infrastructure validation

```powershell
cd D:\GIS_APP\infra\oci\terraform
tofu init
tofu fmt -check
tofu validate
tofu plan -out=terraleb.tfplan
```

Review every create/change and the OCI cost estimate before `tofu apply terraleb.tfplan`. Never use `tofu destroy` as an application rollback.

## Backup execution

After private secret files and the reviewed `.env.prod` exist:

```powershell
cd D:\GIS_APP
docker compose --env-file .env.prod -f compose.prod.yml --profile backup build database-backup
docker compose --env-file .env.prod -f compose.prod.yml --profile backup run --rm database-backup
```

Success is one JSON evidence line containing the two private `storage://backups/...` references, both checksums, sizes, encryption/key identifiers, `pg_dump` version, and `pgRestoreListValidated: true`. It contains no credential or database content. Capture it in the restricted release-evidence store.

## Restore validation and production recovery

Before relying on the backup, download it through the backup-only operator workflow, verify the encrypted checksum, decrypt it with the matching escrowed key, verify the plaintext checksum, run `pg_restore --list`, and restore into a new isolated database/host. Compare the migration history and exact critical-table counts. Never test by overwriting the active production database.

Production recovery creates a new database/container or block volume, restores there, runs migrations and smoke tests, then changes traffic only after approval. Application rollback uses prior immutable images and preserved database/object versions. Object Storage versioning protects application artifacts; destructive infrastructure teardown is not a rollback method.

The first real OCI backup and isolated restore remain Phase-8 evidence items until the owner supplies a tenancy and credentials and Codex verifies the exercise.
