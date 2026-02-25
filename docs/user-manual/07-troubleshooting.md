# Troubleshooting

## Authentication Issues
- Wrong password: verify credentials and caps lock.
- User not found/inactive: contact admin to verify account status.
- Too many attempts (`429`): wait for rate-limit window and retry.

## Sync Problems
- Pending items not syncing: verify connectivity and API health.
- Repeated failures: inspect error message and retry after correction.
- Conflict state: manually review and resolve data differences.

## Performance Issues
- Slow map/BBOX loads: confirm backend is healthy and DB indexes are present.
- Slow exports: check export queue and server resource usage.

## Build/Runtime Issues (Android)
- Ensure JDK 17 is active.
- Verify with `cd apps/mobile/android && .\gradlew -v`.

## Backend/Deployment Issues
- `docker compose -f docker-compose.yml logs -f api`
- `docker compose -f docker-compose.yml logs -f db`
- `docker compose -f docker-compose.yml logs -f nginx`

## Escalation Package
When escalating, include:
- Timestamp and user role
- Request ID (if available)
- Endpoint/screen involved
- Screenshot and steps to reproduce
- Relevant log excerpt
