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
| Read viewer-published projects | Yes | Yes | Yes | Yes |

## Protected Super Admin

The protected super admin is the user whose email matches `SUPER_ADMIN_EMAIL`.

Protection rules enforced in service logic:

- cannot be created by public signup
- cannot be deactivated by standard admin flows
- cannot be demoted by standard admin flows
- only this identity can create other admin users
- only this identity can manage admin-role promotions/demotions

## Mobile Navigation

Super admin:

- Primary navigation: `Admin Panel`, `Projects`, `Requests`, `Notifications`, `Profile`
- Drawer sections: `Admin Panel`, `Users`, `Create Admin`, `Requests`, `Projects`, `Assignments`, `Reviews`, `Exports`, `Notifications`, `Profile`

Admin:

- Primary navigation: `Projects`, `Requests`, `Reviews`, `Notifications`, `Profile`
- Drawer sections: `Projects`, `Requests`, `Assignments`, `Reviews`, `Exports`, `Notifications`, `Profile`

Contributor:

- `Projects`
- `Assigned Projects`
- `Notifications`
- `Profile`

Viewer:

- `Projects`
- `Notifications`
- `Profile`
- Viewer project access is restricted to projects with `visible_to_viewers = true` and status `active` or `completed`.
- Contributor project access is split between `Projects` for viewer-visible public projects in read-only mode and `Assigned Projects` for approved assignment work.
- Project map and feature-creation flows open from project details with back navigation instead of living as root shell tabs.
