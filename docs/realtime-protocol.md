# Realtime invalidation protocol

TerraLeb keeps REST endpoints authoritative and uses one authenticated foreground
WebSocket as a low-latency invalidation channel. Events contain identifiers and
durable scope revisions, not complete records.

## Protocol v1

`domain_changed` messages contain:

- `protocolVersion`: currently `1`.
- `eventId`: UUID used for deduplication.
- `action`: bounded lowercase state transition name.
- `entityType` and optional `entityId`.
- `scopeType`, `scopeId`, and positive `revision`.
- optional `projectId`.
- `occurredAt`.
- `originatedByCurrentSession`: safe boolean; another session identifier is never exposed.

The wire payload is limited to 4 KiB. Geometry, media, credentials, contact
details, form values, and full database rows are prohibited.

## Reliability

`realtime_scope_revision` is updated in the same transaction as an explicitly
instrumented domain mutation. PostgreSQL delivers `NOTIFY` only after commit.
The Flutter client sends revisions for its active scopes when authenticating or
changing subscriptions. A newer server revision produces a targeted stale-scope
response and one silent REST refresh. The client therefore does not depend on
event replay and remains correct across offline periods or server restarts.

## Authorization

The server targets events to user, session, administrator, or authorized project
audiences. Project subscriptions are checked against current project visibility
and assignment rules. Events are invalidation hints only and never grant access;
every REST refresh still applies normal authentication and RBAC.

### Scope catalogue

| Scope | Identifier | Typical consumers |
| --- | --- | --- |
| `projects` | `all` | visible project lists |
| `project` | project UUID | one project/detail screen |
| `categories` | `all` | category lists and live form options |
| `assignments` | user UUID or `all` | contributor/admin assignment views |
| `users` / `user` | `all` or user UUID | managed-user list / affected account |
| `features` | project UUID | project feature list and map |
| `feature` | feature UUID | one feature and its photos |
| `reviews` | project UUID or `all` | project/global review queues |
| `imports` | user UUID or `all` | uploader/admin import lists |
| `import` | import UUID | one authorized import detail/map/review view |
| `imports_project` | project UUID | authorized project import reviewers |
| `exports` | user UUID or `all` | owner/admin export lists |
| `export` | export UUID | one owner/admin export view |
| `ai` | project UUID | project AI lifecycle and validation state |
| `ai_run` | run UUID | one AI run, layers, logs, and reviews |
| `notifications` | user UUID | notification list and unread count |
| `settings` | `support` or `all` | support settings |
| `offline_map` | `all` | offline package metadata |
| `session` | session UUID | exact-session security revocation |

Project-derived scopes are authorized when subscribed and re-evaluated after
assignment or project-access changes. User and session scopes must match the
authenticated token; administrator scopes are derived from the database role,
never client claims.

### Mutation coverage

Explicit aggregate events are emitted for projects and schedules, categories,
assignments and contributor access, managed users and session revocation,
features/photos/reviews/offline bundles, import and export workers including
dead-letter transitions, AI runs/callbacks/validation/publication, notification
state, support settings, and offline-map packages. Bulk imports and AI task
generation publish aggregate scope invalidations rather than one event per
generated feature/task.

## Compatibility and rollback

The legacy `workflow_changed` message remains available behind deployment flags
during rollout. Polling fallback can also remain enabled per environment until
worker lifecycle and reconnect tests pass. Protocol changes require a new
`protocolVersion` or backward-compatible optional fields.
