# System Admin Guide

## Administrative Scope
System Admin is the top backend RBAC role with platform-wide permissions.

## User Management
1. Access admin user endpoints.
2. List users, review status/activity.
3. Update role and activation state.
4. Deactivate compromised/inactive accounts.

## Category and Project Governance
1. Create and maintain project categories.
2. Create new projects.
3. Update/archive projects.

## Assignment Governance
- Create, approve/reject, and remove project assignments.
- Ensure least-privilege role assignment.

## Security Operations
- Rotate JWT and refresh secrets.
- Keep `METRICS_TOKEN` non-empty in production.
- Enforce strict CORS allow-list.

## Audit and Compliance
- Review audit logs for sensitive actions.
- Validate export requests and approvals.
- Ensure backups and restore drills are executed.
