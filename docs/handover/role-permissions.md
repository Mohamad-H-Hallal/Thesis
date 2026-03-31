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
| Update support contact settings | Yes | No | No | No |
| Create project categories | Yes | Yes | No | No |
| Create projects | Yes | Yes | No | No |
| Assign contributors to projects | Yes | Yes | No | No |
| Review submitted features | Yes | Yes | No | No |
| Request exports | Yes | Yes | Yes, if allowed by API route | No |
| Collect field data | No | No | Yes, if assigned and project is active | No |
| Read assigned projects | Yes | Yes | Yes | No |
| Read viewer-published projects | Yes | Yes | Yes | Yes |
| Self-deactivate account | No | No | Yes, if no blocking assignments | No |

## Protected Super Admin

The protected super admin is the user whose email matches `SUPER_ADMIN_EMAIL`.

Protection rules enforced in service logic:

- cannot be created by public signup
- cannot be deactivated by standard admin flows
- cannot be demoted by standard admin flows
- only this identity can create other admin users
- only this identity can manage admin-role promotions/demotions
- is excluded from app-facing user lists, search results, assignment eligibility lists, and normal admin directory views

## Mobile Navigation

Super admin:

- Primary navigation: `Admin Panel`, `Projects`, `Requests`, `Notifications`, `Profile`
- Drawer sections: `Admin Panel`, `Users`, `Categories`, `Create Admin`, `Requests`, `Projects`, `Assignments`, `Reviews`, `Exports`, `Notifications`, `Profile`

Admin:

- Primary navigation: `Projects`, `Requests`, `Reviews`, `Notifications`, `Profile`
- Drawer sections: `Projects`, `Categories`, `Requests`, `Assignments`, `Reviews`, `Exports`, `Notifications`, `Profile`

Contributor:

- `Projects`
- `Assigned Projects`
- `Notifications`
- `Profile`

Viewer:

- `Projects`
- `Notifications`
- `Profile`
- Viewer project access is restricted to projects with `visible_to_viewers = true` and status `active`, `paused`, or `completed`.
- Contributor project access is split between `Projects` for viewer-visible public projects in read-only mode and `Assigned Projects` for approved contributor assignment work.
- Project map and feature-creation flows open from project details with back navigation instead of living as root shell tabs.
- Category creation, project provisioning, and project-scoped assignment management are available directly inside the mobile admin and super-admin runtime.

## Assignment Model

- `project_assignment` is used for contributor assignment and contributor project-access requests.
- Admins are not assigned to projects through `project_assignment`.
- All admins and the protected super admin can manage all projects globally.
- Project assignment management screens show contributor assignment state only:
  - assigned contributors
  - available eligible contributors
  - contributor self-requested project access remains in the `Requests` flow

## Project Status Rules

- `draft`: setup only, not visible to public users, no collection
- `active`: fully viewable and collectable
- `paused`: viewable but collection and submission are blocked
- `completed`: viewable, no new collection mutations
- `archived`: hidden from normal active work, may be restored to `completed`
- automatic lifecycle sync runs on project reads and project-scoped access checks:
  - `draft -> active` once `start_date` arrives
  - `draft|active|paused -> completed` once `end_date` has passed
- manual transitions remain limited to the API-enforced status rules
