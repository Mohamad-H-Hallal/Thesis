# TerraLeb DigitalOcean hosting decision v2

Decision date: 2026-09-05  
Decision authority: TerraLeb product owner  
Release: Android and web v1, Lebanon  
Legal/production status: blocked pending external evidence

## Owner decision

The owner rejects the prior OCI production target because its reviewed deployable x86 configuration was above the approved budget. DigitalOcean is selected as the new production candidate. No OCI or DigitalOcean paid resource has been created.

The initial candidate is:

- Frankfurt (`fra1`), subject to live latency testing from Lebanon and acceptance of international hosting/transfer facts;
- one Basic x86 Droplet, 4 shared vCPUs, 8 GiB RAM and 160 GiB SSD;
- one assigned Reserved IP;
- weekly Droplet backups;
- Standard Spaces with five private purpose-separated buckets;
- self-hosted PostgreSQL/PostGIS, Valkey, API, worker, Nginx and the existing protected security controls;
- AI available in the product but run on separately approved private on-demand compute, not continuously co-hosted on the 8 GiB core.

The 2 GiB/1 vCPU plan is approved only for development or demonstration. It is not a production option. The 4 GiB/2 vCPU plan may be evaluated as constrained staging but cannot become production without representative memory, swap, OOM, database, worker, WebSocket and p95 evidence.

A local serialized full-suite sample reinforces that boundary: during the large-import segment, the in-process test/API runner used about 1.37 GiB working set and PostgreSQL about 585 MiB at roughly one CPU core. That already approaches 2 GiB before the host OS, Docker, the separate production worker, ClamAV, Valkey, Nginx and monitoring. This is rejection evidence for 2 GiB, not a substitute for DigitalOcean staging capacity tests.

## Cost decision

Public DigitalOcean prices reviewed on 2026-09-05 produce this baseline:

| Resource | Monthly estimate |
|---|---:|
| Basic 8 GiB / 4 vCPU Droplet | USD 48.00 |
| Weekly basic backups (20%) | USD 9.60 |
| Standard Spaces (first 250 GiB) | USD 5.00 |
| Assigned Reserved IP and base monitoring | USD 0.00 |
| Initial infrastructure subtotal | **USD 62.60** |

The annual subtotal is approximately USD 751.20 before tax, domain, mail/SMS, ArcGIS/GEE/provider overage, registry, counsel and on-demand AI. Provider checkout is authoritative and requires explicit approval immediately before resource creation. Configure spend alerts at USD 50 and USD 70 per month.

## Security and storage decision

Every Space remains private and has no CDN/public listing. Five buckets separate uploads, exports, offline packages, AI artifacts and database backups. Application and backup runtime access use different scoped credentials. DigitalOcean Spaces uses separate 32-byte SSE-C keys for application and backup objects. Privacy exports and database backups retain their independent application-level AES-256-GCM encryption. Versioning is enabled and deleted/non-current versions expire after the owner-approved 35-day backup-ageing boundary.

Provider tokens, Spaces secrets, SSE-C keys, SSH private keys, Terraform state and plans are never committed or sent through chat. Loss of an SSE-C key makes protected objects unrecoverable, so encrypted recovery copies need approved key custody and a tested recovery procedure.

## AI decision

AI is not disabled. Every project remains AI-off by default, and only the protected super administrator controls project activation, runs, review and publication. The existing 12 GiB service cannot share the 8 GiB core. It will use separately approved on-demand compute after the AI source/image, internal authentication, callback replay protection, least-privilege project data path, object transfer, GEE plan and restart tests pass. Powered-off Droplets remain billable, so temporary AI workers must be destroyed after safe artifact persistence and run reconciliation.

## Evidence still required

This owner decision does not approve DigitalOcean as an active subprocessor and does not establish legal compliance. The following remain blocked:

- real operator/controller identity and account ownership;
- DigitalOcean terms/DPA and support/subprocessor facts;
- Frankfurt international-transfer assessment and Lebanon latency measurements;
- real plan/checkout/apply evidence, firewall and restore tests;
- scoped Spaces authorization, SSE-C key recovery and lifecycle proof;
- production domain, SMTP, Firebase/Play, ArcGIS, offline source and AI/GEE evidence;
- exact Arabic/English policies and qualified Lebanese counsel approval;
- exact-build production authorization.

The legal-review banner must remain until the exact public document versions contain verified facts and the readiness evidence marks those versions approved. Removing the banner before that point would falsely present drafts as approved. When the gate passes, production configuration—not a UI bypass—publishes the approved versions without the draft banner.

## Provider sources reviewed

- Droplet sizes and prices: <https://www.digitalocean.com/pricing/droplets>
- Backup pricing: <https://docs.digitalocean.com/products/backups/details/pricing/>
- Spaces pricing: <https://docs.digitalocean.com/products/spaces/details/pricing/>
- Regions and product availability: <https://docs.digitalocean.com/platform/regional-availability/>
- Provider DPA: <https://www.digitalocean.com/legal/data-processing-agreement>

The links record the source, not approval evidence. Preserve dated terms/DPA copies and the real checkout/plan output during assisted setup.

## Compatibility

No business role, form, map mode, offline workflow, privacy request, deletion workflow, import/export behavior, notification flow or real-time contract is intentionally changed. The change affects hosting/provider configuration, object-storage encryption, infrastructure sizing, operational evidence and AI placement.
