# Auth Flow

## Source of Truth

The authentication and approval workflow is implemented against the PostgreSQL schema below without renaming tables or columns:

- `user`
- `notification`
- `audit_log`

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
  - admin notifications in `notification`
  - contributor request notification for the requester in `notification`

Responses:

- Viewer success: `Viewer account created successfully. You can log in now.`
- Contributor success: `Your contributor request is pending admin approval.`

## Contributor Approval Workflow

Approve endpoint:

- `POST /api/v1/users/:userId/approve-contributor`

Reject endpoint:

- `POST /api/v1/users/:userId/reject-contributor`

Approval effects:

- sets `"user".is_active = true`
- keeps `"user".role = 'contributor'`
- writes a `notification` row with type `contributor_approved`
- writes an `audit_log` approval entry

Rejection effects:

- keeps `"user".role = 'contributor'`
- keeps `"user".is_active = false`
- writes a `notification` row with type `contributor_rejected`
- writes an `audit_log` rejection entry

## Login

Endpoint:

- `POST /api/v1/auth/login`

Checks:

- valid email format
- existing user in `"user"`
- password matches `"user".password_hash`
- `"user".is_active = true`

Behavior:

- pending contributor login is blocked with:
  - `Your request is still pending approval. You cannot log in yet.`
- rejected contributor login is blocked with:
  - `Your contributor request was rejected. You cannot log in with contributor access.`
- successful login updates `"user".last_login`

## Notifications and Audit

Notification events in use:

- `contributor_request`
- `contributor_approved`
- `contributor_rejected`
- `assignment`
- `review_completed`
- `export_ready`

Audit coverage in this flow:

- user registration
- admin creation
- contributor approval
- contributor rejection
- role and activation updates
