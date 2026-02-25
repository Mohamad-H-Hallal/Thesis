# Phase 1 - RBAC Matrix

## Roles

1. `admin`: system-level management and cross-project oversight.
2. `contributor`: field collection and own-data lifecycle.
3. `viewer`: read-only access for monitoring and supervision.

## Permission Matrix

| Capability | admin | contributor | viewer |
|---|---|---|---|
| Login/logout/refresh | Yes | Yes | Yes |
| View own profile | Yes | Yes | Yes |
| Update own profile | Yes | Yes | Yes |
| Create users | Yes | No | No |
| List users | Yes | No | No |
| Deactivate users | Yes | No | No |
| Manage project categories | Yes | No | No |
| Create project | Yes | No | No |
| Update/archive project | Yes | Project admin only | No |
| View project list | Yes | Assigned projects | Assigned projects |
| Assign users to project | Yes | Project admin only | No |
| Approve/reject assignment | Yes | Project admin only | No |
| Request join project | Yes | Yes | No |
| Create spatial feature | Yes | Yes (assigned project) | No |
| Edit own draft feature | Yes | Yes | No |
| Delete own draft feature | Yes | Yes | No |
| Submit feature for review | Yes | Yes | No |
| Review feature | Yes | Project admin only | No |
| View approved/pending features in assigned projects | Yes | Yes | Yes |
| Upload photos to own feature | Yes | Yes | No |
| Delete/update order of own photos | Yes | Yes | No |
| Request export | Yes | Yes (assigned project) | No |
| Download own export files | Yes | Yes | No |
| View notifications | Yes | Yes | Yes |
| Mark notifications read | Yes | Yes | Yes |
| View audit logs | Yes | No | No |

## Notes

1. "Project admin" is derived from `project_assignment.role = admin` with `status = approved`.
2. Viewer role remains read-only and cannot modify domain records.
3. System admin may bypass project scoping where required for operations/support.
