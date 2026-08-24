# Realtime v2 operations and rollout

TerraLeb realtime v2 uses the existing Node `ws` endpoint, Flutter
`web_socket_channel`, and PostgreSQL `LISTEN/NOTIFY`. REST remains authoritative;
no SignalR, .NET service, sticky session, or event-body replay store is required.

## Request and delivery path

1. A business transaction changes its records, increments only its affected
   rows in `realtime_scope_revision`, and calls `pg_notify` before commit.
2. PostgreSQL exposes the notification only after the transaction commits. Each
   API instance receives it through its dedicated listener connection.
3. The local socket process deduplicates the `eventId`, resolves an indexed
   user/session/admin/project group, checks the exact subscribed scope and cached
   server-derived access, then sends a payload capped at 4 KiB.
4. Flutter coalesces the same scope for 175 ms and advances that scope's
   Riverpod revision. Only watched data reloads, and paginated controllers keep
   their existing contents while the REST refresh completes.
5. On reconnect, the active scopes and their known durable revisions are
   compared. Newer server revisions are returned as stale scopes for targeted
   silent refresh; event replay is unnecessary.

An idle connection uses WebSocket ping/pong only. It makes no HTTP request and
performs no per-connection heartbeat database query.

## Deployment prerequisites

Apply migrations before enabling v2 on any API instance:

1. `0057_realtime_scope_revisions.sql`
2. `0058_mutable_entity_versions.sql`

Deploy all API instances with the same protocol and migration level. Confirm
the `realtime_domain_changed` listener is healthy on every instance, and then
deploy the Flutter build. Existing REST clients remain compatible because
`expected_version` is optional; the new Flutter editor supplies it.

## Configuration

| Setting | Default | Production guidance |
| --- | ---: | --- |
| `REALTIME_V2_ENABLED` | `true` | canary on after migrations |
| `REALTIME_LEGACY_BROADCAST_ENABLED` | `true` | keep on through the mixed-client pilot |
| `REALTIME_POLLING_FALLBACK_ENABLED` | `false` | Flutter `--dart-define`; enable only for rollback |
| `REALTIME_AUTH_TIMEOUT_MS` | `5000` | keep short enough to limit unauthenticated sockets |
| `REALTIME_HEARTBEAT_INTERVAL_MS` | `30000` | keep below the proxy read timeout |
| `REALTIME_MAX_CONNECTIONS_PER_USER` | `5` | size for expected foreground devices/tabs |
| `REALTIME_MAX_CONNECTIONS_PER_IP` | `30` | account for legitimate shared networks |
| `REALTIME_MAX_BUFFERED_BYTES` | `262144` | slow clients close with `resync_required` |

`APP_PUBLIC_API_URL` and `CORS_ORIGIN` determine allowed production host/origin
values. Native clients may omit `Origin`, but the HTTP `Host` must still match.
Do not put access tokens in URLs, Nginx logs, metric labels, or application logs.

Per-IP limits use the direct peer unless `TRUST_PROXY=true`. Behind Nginx, the
validated `TRUST_PROXY_HOPS` value selects the corresponding address from the
right side of `X-Forwarded-For`; malformed forwarded values fail closed to the
direct peer address.

The dedicated Nginx location must use HTTP/1.1 upgrade headers, disable proxy
and request buffering, and keep its 75-second read timeout above the heartbeat.
The included development and production configurations implement these rules.

## Rollout

Use independently reversible stages:

1. Enable v2 for import/export worker status while leaving legacy events and
   polling fallback available.
2. Enable projects, categories, assignments, and managed users.
3. Enable features, photos, maps, reviews, and offline synchronization.
4. Enable AI, notifications, settings, and offline maps.
5. Ship the scoped Riverpod build and confirm no global refresh-tick consumers.
6. Disable `REALTIME_LEGACY_BROADCAST_ENABLED` after the client pilot.
7. Disable `REALTIME_POLLING_FALLBACK_ENABLED` after stable staging/pilot data.

For each stage, verify another session receives the change, an unrelated private
project does not, reconnect reconciliation succeeds, and event-to-visible-update
p95 remains below one second.

## Rollback

1. Turn `REALTIME_POLLING_FALLBACK_ENABLED=true` in the Flutter build/config if
   import/export status recovery is needed.
2. Leave or turn `REALTIME_LEGACY_BROADCAST_ENABLED=true` for older clients.
3. Turn `REALTIME_V2_ENABLED=false` on API instances if v2 delivery itself is
   faulty. REST and manual refresh remain authoritative and available.
4. Do not roll back or delete the two additive tables/columns during an incident;
   they are backward-compatible and retain harmless revision/version metadata.

## Monitoring

Prometheus exports low-cardinality connection attempts, authenticated active
connections, reconnects, auth failures, disconnect reasons, events published by
bounded entity type, deliveries, coalesced/dropped events, slow-client closes,
payload-size buckets, aggregate publish-to-delivery latency, stale-scope
reconciliations, buffered socket count, and listener health. User, project,
session, and event identifiers are never metric labels.

The alert rules cover listener failure, reconnect storms, abnormal realtime
authentication failures, buffered/slow clients, and dropped events. During a
pilot also compare domain-event rate with normalized REST route rate to detect
event-to-refetch amplification.

## Verification commands

```text
cd apps/api
npm run test:db:prepare
npm run lint
npm run typecheck
npm run test:ci
npm run test:perf
npm run production:config:check

cd ../mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test
```

Run the WebSocket through staging Nginx with two API instances and verify TLS,
upgrade, server restart, listener failure alerts, reconnect storms, expected
peak connections, twice-peak safety load, burst changes, and slow clients before
removing legacy/fallback flags.
