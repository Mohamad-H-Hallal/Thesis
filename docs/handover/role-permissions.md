# Role Permissions

## System Roles

The system user role enum is fixed to:

- `admin`
- `contributor`
- `viewer`

## Matrix

| Capability | super admin | admin | contributor | viewer |
| --- | --- | --- | --- | --- |
| Login | Yes | Yes | Only after approval | Yes |
| Public signup | No | No | Yes | Yes |
| Create admin users | Yes | No | No | No |
| Manage other admin users | Yes | No | No | No |
| Approve/reject contributor requests | Yes | Yes | No | No |
| Create project categories | Yes | Yes | No | No |
| Create projects | Yes | Yes | No | No |
| Assign users to projects | Yes | Yes | No | No |
| Review submitted features | Yes | Yes | No | No |
| Request exports | Yes | Yes | Yes, if allowed by API route | No |
| Collect field data | Yes, if assigned | Yes, if assigned | Yes, if assigned | No |
| Read assigned projects | Yes | Yes | Yes | No |
| Read viewer-published projects | Yes | Yes | No | Yes |

## Protected Super Admin

The protected super admin is the user whose email matches `SUPER_ADMIN_EMAIL`.

Protection rules enforced in service logic:

- cannot be created by public signup
- cannot be deactivated by standard admin flows
- cannot be demoted by standard admin flows
- only this identity can create other admin users
- only this identity can manage admin-role promotions/demotions

## Mobile Navigation

Admin:

- `Home/Projects`
- `Review Queue`
- `Exports`
- `Notifications`
- `Profile`

Contributor:

- `Home/Projects`
- `Map`
- `My Drafts`
- `My Submissions`
- `Notifications`
- `Profile`

Viewer:

- `Home/Projects`
- `Notifications`
- `Profile`
- Viewer project access is restricted to projects with `visible_to_viewers = true` and status `active` or `completed`.
