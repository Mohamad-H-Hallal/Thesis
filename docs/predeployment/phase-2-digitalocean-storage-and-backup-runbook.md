# Phase 2 DigitalOcean hosting, private storage and backup runbook

Status: engineering configuration complete; live provider evidence blocked  
Active target: DigitalOcean Frankfurt (`fra1`)  
Last reviewed: 2026-09-05

## Architecture

TerraLeb starts on one x86 Basic Droplet with 4 shared vCPUs, 8 GiB RAM and 160 GiB local SSD. PostgreSQL/PostGIS remains private on the host and is never published to the Internet. Nginx exposes only HTTP/HTTPS; the DigitalOcean Cloud Firewall restricts SSH to explicit operator CIDRs. A free assigned Reserved IP permits controlled host replacement without changing the public address.

Five private, versioned Spaces buckets separate uploads, exports, offline packages, AI artifacts and encrypted database backups. A sixth bootstrap Space stores encrypted, versioned Terraform state with a state-only key and SSE-C key. Runtime application credentials can access only the four application buckets. A different key can access only the backup bucket. A temporary provisioning key must be revoked after bucket setup. CDN and public file listing remain disabled.

The existing canonical `storage://` references, streamed transfers, content/size checks, immutable object keys and SHA-256 verification remain unchanged. DigitalOcean Spaces objects use SSE-C with a 32-byte customer key. Application and backup objects use different SSE-C keys. Privacy exports and database dumps retain their additional application-level AES-256-GCM envelopes. The non-current version lifecycle removes deleted versions after the approved 35-day backup-ageing boundary.

## Why 8 GiB is the minimum baseline

The production Compose ceilings are not reservations, but the active core can concurrently run PostgreSQL/PostGIS, ClamAV, Valkey, the API, workload worker, Nginx and operational agents. A 2 GiB host provides no safe memory margin. A 4 GiB host is permitted only for constrained staging and can become production only after representative imports, exports, photo scans, WebSockets and database load prove adequate memory, latency and no sustained swap/OOM behavior. No such evidence currently exists.

AI remains a product feature and stays disabled by default per project. The current 12 GiB AI service is not co-hosted on the 8 GiB core. Its separately approved on-demand compute, internal authentication, least-privilege data path and immutable image remain Phase-5 gates.

## Before any paid apply

1. Verify the real DigitalOcean account/team owner, MFA and DPA/terms evidence.
2. Measure network latency from Lebanon to `fra1`; record p50/p95 and packet loss.
3. Create a restricted Ed25519 operator key and determine the exact `/32` SSH source CIDR.
4. Generate a unique non-sensitive bucket prefix.
5. Run formatting, initialization and validation in `infra/digitalocean/terraform`.
6. Generate a saved plan and review every create/change plus provider checkout price.
7. Obtain explicit owner approval immediately before apply.

Never place provider tokens, Spaces secrets, SSE-C keys, SSH private keys, state or saved plans in Git or chat. Store Terraform state in an approved encrypted access-controlled backend before the first live apply; local state is permitted only for non-live validation.

## Post-apply verification

1. Revoke the provisioning token/key after use and record revocation timestamps.
2. Verify only ports 80/443 are public and SSH is accepted only from the reviewed source.
3. Confirm PostgreSQL, Valkey, ClamAV and internal AI/control ports are not Internet reachable.
4. Verify each Space is private, has versioning enabled and expires non-current versions after 35 days.
5. Create separate scoped app and backup keys; prove cross-bucket denial in both directions.
6. Generate separate app and backup SSE-C keys directly into the secret files named by `.env.prod.example`, with encrypted recovery copies in approved key custody.
7. Upload, range-read, checksum, delete and reconcile a non-sensitive test object in each bucket.
8. Run a database backup, validate the encrypted manifest, and restore it into an isolated empty database.
9. Prove an account-deletion ledger prevents erased identity from becoming active after restore.
10. Verify weekly Droplet backups and spend alerts, then record live storage and backup cost.

## Backup and restore

The `database-backup` Compose profile creates a PostgreSQL custom-format dump, validates it, applies an independent AES-256-GCM envelope, uploads it with the backup-only identity and records immutable checksums/manifest metadata. Plaintext and temporary encrypted files are removed after the attempt. Spaces SSE-C is an additional storage layer, not a replacement for the application envelope.

A restore requires both the backup envelope key and the backup Spaces SSE-C key. Recovery evidence must prove both are available from separate approved custody without copying either key into logs, screenshots or Git. Restore into a new isolated database first; validate migrations, constraints, protected-super-admin identity and deletion-ledger behavior before any traffic switch.

## Cost and scaling

Public prices reviewed on 2026-09-05:

- Basic 8 GiB / 4 vCPU Droplet: USD 48/month.
- Weekly basic backup: 20%, or USD 9.60/month for that Droplet.
- Standard Spaces: USD 5/month including 250 GiB; storage/transfer overage is additional.
- Assigned Reserved IP and base monitoring: no additional recurring charge.

Initial subtotal: approximately USD 62.60/month or USD 751.20/year before tax, domain, email/SMS, provider overage and on-demand AI. Checkout is authoritative. Configure USD 50 and USD 70 spend alerts. Resize only from measured CPU, memory, disk, DB and p95 evidence.

DigitalOcean also offers usage-based Droplet backups, but the pinned Terraform provider exposes the basic `daily`/`weekly` policy rather than the usage-based billing controls. Do not introduce unmanaged configuration drift merely to reduce the estimate. Re-evaluate the usage-based option after live restorable-size measurement, provider/API support validation and a reviewed recovery objective. Until then, USD 9.60 is the conservative predictable backup allowance.

Official sources: <https://www.digitalocean.com/pricing/droplets>, <https://docs.digitalocean.com/products/backups/details/pricing/>, <https://docs.digitalocean.com/products/spaces/details/pricing/>, and <https://docs.digitalocean.com/platform/regional-availability/>.

## Rollback

- Roll application containers back to the last reviewed immutable images; do not roll migrations backward destructively.
- Restore into an isolated database before a controlled Reserved-IP reassignment.
- The core Droplet is protected by Terraform `prevent_destroy` and buckets use `force_destroy = false`.
- Do not destroy the old host until the replacement, database, worker, storage, TLS, WebSocket and backup restore are verified.
- If DigitalOcean or `fra1` is rejected, retain this module and evidence as historical; select another provider only through a new hosting, transfer, cost and performance decision.

Passing these engineering checks does not establish legal compliance. Provider contracting, international-transfer treatment and final production authorization remain evidence-gated.
