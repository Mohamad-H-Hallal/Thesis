# TerraLeb data flows and transfer inventory

## Verified flows

1. Flutter mobile/web sends account, project, GIS, review, import/export and AI
   requests to the Node/Express API over the configured HTTPS origin.
2. The API authorizes the request and reads/writes PostgreSQL/PostGIS.
3. Private photos/imports/exports/AI artifacts are stored through the configured
   server storage paths/adapters and retrieved through authorized endpoints.
4. Offline projects, drafts, sync queues and photos are stored in an owner-scoped
   encrypted mobile store and synchronized later through the API.
5. Email/phone verification transmits the destination and message/challenge to
   the configured delivery provider.
6. Push delivery transmits the FCM token, notification id and privacy-filtered
   notification presentation to Firebase when enabled.
7. Map clients send tile requests directly to the configured OSM/Esri host.
8. The Node API dispatches approved AI workloads to the separately operated AI
   service; callbacks and registered artifacts return to the API.
9. Logs/metrics are collected by the documented observability stack; production
   external retention and support access are not yet approved.

## Transfer decisions still required

- Exact countries/regions for API, database, object storage, backup, logs,
  Firebase, SMTP/SMS, support and AI processing.
- Each vendor legal entity, subprocessor chain, DPA and transfer mechanism.
- Whether EU/EEA persons are targeted or monitored and, if so, the applicable
  transfer assessment/safeguards.
- Government restrictions on sensitive locations, public records and foreign
  hosting/support access.
- Whether map-provider request metadata is acceptable for the intended users.

No production notice may state that all data remains in Lebanon until the
complete runtime, backup, notification, mail, map, AI and support paths prove it.
