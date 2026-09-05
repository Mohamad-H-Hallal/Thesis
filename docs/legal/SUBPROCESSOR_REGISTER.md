# TerraLeb subprocessor and external-recipient register

Status: architecture selected; production entities/contracts remain blocked
until copied from executed provider records and verified deployed configuration.
Product names below are not substitutes for the actual contracting legal entity.

| Service/function | Selected v1 solution | Data potentially disclosed | Region/rule | Evidence status |
|---|---|---|---|---|
| Infrastructure/compute | DigitalOcean 8 GiB x86 core Droplet candidate | Hosted application/account/GIS data processed by the VM | Frankfurt, Germany (`fra1`); international hosting for Lebanon | Account, terms/DPA, transfer/support-access, latency and live deployment evidence not yet supplied |
| Database | Private PostgreSQL/PostGIS on the production Droplet SSD | Account, authorization, GIS, workflow, and audit records | Frankfurt private Docker/VPC boundary; no public database endpoint | Live disk, network, backup and isolated-restore evidence not yet supplied |
| Object storage | Private DigitalOcean Spaces buckets with separate application/backup identities and SSE-C keys | Photos, imports, exports, offline packages, AI outputs, encrypted backups | Frankfurt (`fra1`); SSE-C plus application envelopes where required | IAM/key scope, privacy, version/lifecycle, key-recovery and contract evidence not yet supplied |
| Email | Contracted production SMTP provider | Recipient address/name and security/verification message | Provider/region not yet selected | Provider entity, terms/DPA, sender-domain and delivery evidence blocked |
| Phone assurance/SMS | No SMS service in v1 | Phone is validated locally for format; no SMS disclosure | Not applicable to v1 while `format_only` is enforced | Owner policy approved; configuration test required |
| Push | Firebase Cloud Messaging | Device token, notification identifier, generic alert, transport metadata | Provider-controlled route; detail fetched from authenticated API | Google contracting entity/terms and final Firebase project evidence blocked |
| Online Street map | OSM Foundation public Standard tile service for modest interactive use | IP, User-Agent/browser metadata, requested tile coordinates | Online only; no bulk/offline use; cache and attribution required | Technical controls exist; final usage/attribution review and staging evidence blocked |
| Online Hybrid map | Operator-owned ArcGIS Location Platform/Online integration through TerraLeb proxy | Provider request/session metadata and requested tile coordinates | Server-side restricted credentials; quota/budget/fallback controls | Account, terms, credential restrictions, live attribution and usage evidence blocked |
| Offline Hybrid package | TerraLeb-built Sentinel-2 true-colour mosaic with OSM-derived labels | Source/provider receives acquisition request; users download authenticated package | Copernicus/OSM source terms, scene IDs, checksums, 10 m notice | Source acquisition/build/license evidence blocked |
| AI/GIS processing | TerraLeb internal Python service plus approved Earth Engine plan when configured | Allowlisted approved project AOI, GIS labels/samples, imagery and outputs | Internal-only service; no account/profile/contact/session data | Production image digest, GEE plan/entity/roles/region and staging evidence blocked |
| Monitoring | Self-hosted Prometheus, Loki and Alloy; DigitalOcean host monitoring; external alert delivery only after approval | Redacted metrics, logs, and alerts; no geometry, contact data, secrets or free-text bodies | Frankfurt for stored production telemetry | Local image/config/security evidence complete; DigitalOcean and external receiver/staging evidence blocked |

Mailpit and mock/test services are development tools and are not production
subprocessors. GitHub processes source/CI data, not production application-user
records. The final public subprocessor document must contain exact provider
entities, effective dates, purposes, data, regions, safeguards, and change
notice only after those facts are evidenced.
