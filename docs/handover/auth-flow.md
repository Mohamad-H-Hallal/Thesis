# Auth Flow

## Source of Truth

The authentication and approval workflow is implemented directly against:

- `user`
- `notification`
- `audit_log`

No auth-only shadow tables are used.

## Public Signup

Endpoint:

- `POST /api/v1/auth/register`

Accepted fields:

- `full_name`
- `email`
- `phone`
- `password`
- `role` with allowed values `contributor` or `viewer`

Rules:

- Public signup cannot create `admin`.
- Email must be unique in `"user".email`.
- Password must be at least 8 characters and include uppercase, lowercase, number, and special character.
- `viewer` signup creates:
  - `"user".role = 'viewer'`
  - `"user".is_active = true`
- `contributor` signup creates:
  - `"user".role = 'contributor'`
  - `"user".is_active = false`
  - admin-facing contributor request notifications
  - requester-facing confirmation notification
- Protected super admin cannot be created through public signup.

Responses:

- Viewer success:
  - `Account created successfully. You can log in now.`
- Contributor success:
  - `Account created successfully. Your contributor request is pending admin approval.`

Failure behavior:

- duplicate email stays on signup and maps to:
  - `This email is already registered.`
- the mobile UI keeps entered values and highlights the email field instead of redirecting to login

## Contributor Approval Workflow

Approve endpoint:

- `POST /api/v1/users/:userId/approve-contributor`

Reject endpoint:

- `POST /api/v1/users/:userId/reject-contributor`

Approval effects:

- sets `"user".is_active = true`
- keeps `"user".role = 'contributor'`
- writes a `notification` row with contributor approval context
- writes an `audit_log` approval entry

Rejection effects:

- keeps `"user".role = 'contributor'`
- keeps `"user".is_active = false`
- writes a `notification` row with contributor rejection context
- writes an `audit_log` rejection entry

## Login

Endpoint:

- `POST /api/v1/auth/login`

Checks:

- valid email format
- existing user in `"user"`
- password matches `"user".password_hash`
- `"user".is_active = true`

Runtime behavior:

- wrong credentials map to:
  - `Wrong email or password.`
- unknown account maps to:
  - `This account does not exist.`
- blocked account maps to:
  - `Your account has been blocked.`
- inactive account maps to:
  - `This account is inactive.`
- pending contributor login is blocked with:
  - `Your request is still pending approval. You cannot log in yet.`
- rejected contributor login is blocked with:
  - `Your contributor request was rejected. You cannot log in with contributor access.`
- successful login updates `"user".last_login`
- failed login does not create a session or token

## Self-Deactivate

Endpoint:

- `POST /api/v1/auth/self-deactivate`

Rules:

- available to `viewer` and `contributor`
- not available to admin or protected super admin
- contributor self-deactivation is blocked when the user still has approved assignments on active, paused, or draft projects
- successful self-deactivation sets `"user".is_active = false`
- inactive users cannot log in again until reactivated by an administrator flow

## Notifications and Audit

Notification events in active use include:

- `contributor_request`
- `contributor_approved`
- `contributor_rejected`
- project access request approved/rejected
- direct contributor assignment/unassignment
- feature review outcome with notes
- export ready / export failed

Notifications are persisted in `notification`, scoped by `user_id`, and remain available on the next app open. The mobile app also supports read / unread state through the API.

Audit coverage in this flow includes:

- user registration
- contributor approval and rejection
- admin creation
- role and activation updates
- self-deactivation
