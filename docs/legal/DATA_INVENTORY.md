# TerraLeb verified data inventory

Status: technical inventory for counsel/owner review. It describes repository
behavior inspected on 2026-08-12 and must be re-run before each public release.

| System/data class | Verified examples | Purpose in current implementation | Storage/recipient | Sensitivity and notes |
|---|---|---|---|---|
| Account identity | Full name, email variants, Lebanese phone, role, status | Authentication, contact assurance, access administration | PostgreSQL `user`; SMTP/SMS provider during verification | Direct identifiers. Viewer and contributor signup currently require a phone. |
| Credentials/session | Password hash, JWT session id, hashed refresh token, expiry, revocation | Account and session security | PostgreSQL `auth_session`; encrypted mobile secure storage | Tokens and passwords must never enter legal acceptances, events, analytics or exports. |
| Verification/recovery | OTP challenge hashes/provider references, masked target, IP, fingerprint hash, reset requests | Contact ownership and account recovery | PostgreSQL; configured SMTP/SMS provider | Security data with short operational usefulness. |
| Project and assignment | Project metadata, form schema, roles, approval state, dates | GIS work administration and authorization | PostgreSQL; authorized clients | Can expose private project membership and operational plans. |
| Precise GIS data | Geometry, coordinates, accuracy, collection timestamps, offline flag, feature attributes | Field collection, review, mapping and export | PostgreSQL/PostGIS; encrypted offline database; authorized exports | Precise location may identify people, property or sensitive sites. Form schemas can add new personal fields. |
| Photos/media | Normalized image, caption, location, timestamps, dimensions, security scan metadata | Evidence and feature review | Private server storage; encrypted app-owned draft files | Images can contain people/property. Normalization strips original metadata but location/time may still be stored separately. |
| Offline data | Cached projects, schemas, lookup values, drafts, sync queue, receipts, map tiles | Disconnected field work and reliable synchronization | SQLCipher/local app directories; server sync receipts | Owner-scoped. Logout does not imply deletion; deletion completion needs an explicit local purge. |
| Imports/comments | Uploaded GIS files, parsed attributes/geometry, uploader, processing state, comments | Bulk ingestion and review | Private upload storage and PostgreSQL | Imported files may contain third-party personal data or incompatible licenses. |
| Exports | Filters, requester, generated files, status, errors, expiry | Authorized data portability/project distribution | PostgreSQL and export storage | May combine precise location, attributes and provenance; download authorization is required. |
| AI | Settings, selected model, runs, metrics, artifacts, predicted geometry/classes, validation, training-use flag | Geospatial classification and review | PostgreSQL, AI server/output storage, optional external datasets | Model/dataset provenance and training authority are unresolved. Outputs can be inaccurate. |
| Notifications | Recipient, type, title, message, metadata, read state, device token snapshot, delivery status | In-app and optional push workflow alerts | PostgreSQL and Firebase Cloud Messaging | Existing message text may contain private project context; push payloads must be generic by default. |
| Device information | FCM token, platform, device label, app version | Push delivery and invalid-token cleanup | PostgreSQL/Firebase | Persistent device identifier; do not use for advertising or unrelated tracking. |
| Audit/security | Actor, action, entity id, redacted values, IP, request id, logs | Security, accountability and incident response | PostgreSQL audit log and rotating/Loki logs | Access and retention must be restricted; raw bodies/tokens must remain excluded. |
| Support | Support email, phone, hours and text | User assistance | PostgreSQL and app | Public/business contact data after approval. |
| Basemap requests | Tile coordinates, IP, client identifier | Display OSM/Esri basemaps | External map provider | Requested tiles can reveal viewed vicinity. Provider terms and attribution apply. |

## Third-party/code dependencies that can process data

- Firebase Cloud Messaging: device token, generic notification content and
  delivery metadata when enabled.
- Configured SMTP provider/Mailpit: recipient and authentication/security email.
- Configured SMS/phone assurance provider: phone and verification transaction.
- OpenStreetMap and Esri endpoints: IP, request metadata and tile coordinates.
- Production hosting, object storage, backup, monitoring and support vendors:
  names/regions are unresolved until provisioned and approved.
- External AI pipeline/data providers: not contained completely in this
  repository and require a separate inventory before real processing.

No advertising SDK, Firebase Analytics, Crashlytics, Sentry, Mixpanel or
PostHog client integration was found in the inspected mobile dependency list.
This must be re-verified from the resolved dependency/SBOM output.

## Collection-point requirements

Any new project form field, SDK, tile source, AI input, export field or log field
must update this inventory, the processing register, store disclosures,
retention matrix and DPIA before release. Free-form project schemas must not be
treated as permission to collect arbitrary sensitive data.
