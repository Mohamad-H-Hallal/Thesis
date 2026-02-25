# QA Checklist (End-to-End)

## Authentication
- [ ] Login succeeds with valid credentials.
- [ ] Login fails with wrong password (401).
- [ ] Login fails for inactive user (401).
- [ ] Public signup with `role=admin` is blocked (400) or downgraded safely.
- [ ] Signup with valid data creates contributor account.
- [ ] Forgot-password flow reaches success confirmation screen.
- [ ] Reset-password flow validates confirm password mismatch.

## Authorization / RBAC
- [ ] Contributor cannot access admin user-management endpoints.
- [ ] Contributor cannot modify another user's role.
- [ ] Project-admin can review project submissions.
- [ ] Viewer cannot create/edit submissions.

## Projects / Features / Drafts
- [ ] Assigned projects list loads.
- [ ] Project details open correctly.
- [ ] Add feature stepper allows draft save.
- [ ] Draft status transitions display correctly.
- [ ] Submit draft changes status to pending review.

## Geospatial and API
- [ ] BBOX endpoint returns paginated GeoJSON.
- [ ] Invalid geometry payload is rejected with 400.
- [ ] Pagination bounds enforced for list endpoints.

## Sync / Offline
- [ ] Offline banner appears when network unavailable.
- [ ] Pending queue transitions to success on reconnect.
- [ ] Failed item follows retry/backoff schedule.
- [ ] Conflict state is surfaced to user.
- [ ] Idempotent push avoids duplicate record creation.

## Exports
- [ ] Export request accepted (202).
- [ ] Export status transitions pending -> processing -> completed.
- [ ] Failed export reports error message.
- [ ] Download endpoint works for completed exports.

## Notifications / Profile
- [ ] Notifications list loads and unread state updates.
- [ ] Mark read / mark all read works.
- [ ] Profile shows role + identity info.
- [ ] Logout clears session and returns to login.

## Reliability / Security
- [ ] `/health` and `/ready` pass under normal load.
- [ ] `/metrics` returns 401 without token in production config.
- [ ] Rate-limit triggers on repeated auth attempts.
- [ ] Audit logs are written for sensitive actions.

## Deployment Validation
- [ ] `docker compose -f docker-compose.yml up -d --build` completes.
- [ ] `db` and `api` services are healthy.
- [ ] Smoke test script passes.
