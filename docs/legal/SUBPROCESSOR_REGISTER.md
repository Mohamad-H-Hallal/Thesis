# TerraLeb subprocessor and external-recipient register

Status values are intentionally unresolved. Replace only from executed vendor
documents and deployed configuration.

| Service/function | Repository evidence | Data potentially disclosed | Production vendor/entity | Region | DPA/terms approval |
|---|---|---|---|---|---|
| Infrastructure/hosting | Docker/Compose production reference | All hosted application data | DECISION REQUIRED | DECISION REQUIRED | BLOCKING |
| Database/backups/object storage | Postgres, private storage and backup design | Account, GIS, photos, imports, exports, AI, audit | DECISION REQUIRED | DECISION REQUIRED | BLOCKING |
| Email delivery | Nodemailer SMTP configuration | Recipient, name, security/authentication message | DECISION REQUIRED | DECISION REQUIRED | BLOCKING |
| Phone assurance/SMS | Configurable verification provider | Phone, verification metadata | DECISION REQUIRED | DECISION REQUIRED | BLOCKING when enabled |
| Push notifications | Firebase Cloud Messaging | Device token, notification id, generic alert, transport metadata | Google entity/terms to confirm for controller | Provider-dependent | BLOCKING when enabled |
| Online street map | OpenStreetMap public tile endpoint | IP, user agent/browser metadata, tile coordinates | OSMF service | Provider-dependent | Attribution/usage review required |
| Satellite/reference map | Esri ArcGIS Online endpoints | IP, request metadata, tile coordinates | Contracting Esri entity | Provider-dependent | BLOCKING, especially offline use |
| AI service/datasets | Separate Python service and external dataset configuration | Project/GIS inputs and AI artifacts | DECISION REQUIRED | DECISION REQUIRED | BLOCKING for real data |
| Monitoring/support | Loki/Prometheus/Alloy reference; external alert delivery unresolved | Redacted logs, metrics, operational alerts | DECISION REQUIRED | DECISION REQUIRED | BLOCKING |

Mailpit and mock/test services are development tools, not production
subprocessors. Do not list a vendor merely because the software supports it;
the final register must match active configuration and contracts.
