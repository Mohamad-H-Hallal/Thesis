# Role Permissions Matrix

## RBAC Matrix (Current Backend Enforcement)

| Capability | Admin | Project Admin | Contributor | Viewer |
|---|---|---|---|---|
| Public signup/login | Yes | Yes | Yes | Yes |
| Create system admin user via public signup | No | No | No | No |
| List users / update users | Yes | No | No | No |
| Create categories | Yes | No | No | No |
| Create project | Yes | No | No | No |
| Update/archive project | Yes | Yes (assigned project only) | No | No |
| View assigned project | Yes | Yes | Yes | Yes (if assigned) |
| Create assignment | Yes | No (current route policy) | No | No |
| Approve/reject assignment | Yes | No (current route policy) | No | No |
| Create/edit own feature draft | Yes | Yes | Yes | No |
| Submit feature for review | Yes | Yes | Yes | No |
| Review/approve/reject feature | Yes | Yes (project-admin assignment) | No | No |
| Upload/delete photos | Yes | Limited by ownership rules | Limited by ownership rules | No |
| Request export for accessible project | Yes | Yes | Yes (if assigned) | No |
| View notifications | Yes | Yes | Yes | Yes |

Notes:
- "Project Admin" means user has approved `project_assignment.role='admin'` for that project.
- Some assignment-management actions are intentionally system-admin-only by route guard.
