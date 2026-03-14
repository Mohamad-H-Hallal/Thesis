# 06 - Admin Guide

## Audience
System administrators and operations leads.

## Admin Workflows

### 1) User Administration
- List users.
- Inspect activity/role/active status.
- Update role and activation state.
- Deactivate compromised accounts.
- Expected errors:
  - 401 if token invalid.
  - 403 for non-admin callers.
  - 404 for missing user.
- Screenshot placeholder:
  - `[Screenshot: Admin users management]`

### 2) Category Management
- Create/update/delete project categories.
- Expected errors:
  - 409 for duplicate category names.
  - 400 for invalid payload.
- Screenshot placeholder:
  - `[Screenshot: Category management]`

### 3) Project Governance
- Create new projects.
- Update/archive projects.
- Toggle whether a project is visible to viewers.
- Validate collection schema settings.
- Expected errors:
  - 403 for unauthorized role.
  - 404 for missing project.
- Screenshot placeholder:
  - `[Screenshot: Project create/edit]`

### 4) Assignment Governance
- Create assignments.
- Approve/reject join requests.
- Remove assignments.
- Expected errors:
  - 409 duplicate assignment.
  - 400 invalid status transition.
- Screenshot placeholder:
  - `[Screenshot: Assignment workflow]`

### 5) Security Operations
- Verify admin cannot be self-registered from public endpoint.
- Confirm metrics access requires token when enabled in production.
- Rotate JWT and refresh secrets according to policy.
- Screenshot placeholder:
  - `[Screenshot: Security settings checklist]`

### 6) Operational Troubleshooting
- API health fails:
  - Check `docker compose -f compose.prod.yml logs api`.
- DB unhealthy:
  - Check `docker compose -f compose.prod.yml logs db`.
- Migration stuck:
  - Check `docker compose -f compose.prod.yml logs migrate`.
- Reverse-proxy issues:
  - Check `docker compose -f compose.prod.yml logs nginx`.

## Role Permissions (Admin Context)
- Admin can:
  - manage users/categories/projects/assignments globally
  - mark projects as viewer-visible or contributor-only
  - review/approve/reject all submissions
  - request and download exports
- Admin cannot:
  - bypass auth/audit controls
  - avoid rate limits and policy checks

## Screenshot Placeholders Summary
- `[Screenshot: User list + role edit]`
- `[Screenshot: Assignment approval panel]`
- `[Screenshot: Export dashboard (admin view)]`
