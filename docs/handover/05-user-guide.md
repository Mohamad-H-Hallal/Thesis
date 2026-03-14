# 05 - User Guide

## Audience
All authenticated users (admin, project-admin, contributor, viewer).

## App Screens and Main Actions

### Splash Screen
- Purpose: session bootstrap and token check.
- Actions:
  - Wait for auth check.
  - Auto-route to login or app shell.
- Validation/Error behavior:
  - Invalid/expired token routes to login.
  - API unavailable shows retryable error state.
- Screenshot placeholder:
  - `[Screenshot: Splash - token check state]`

### Login Screen
- Fields: email, password, remember-me toggle.
- Actions:
  - Enter credentials and tap Sign In.
  - Show/hide password.
  - Navigate to Forgot Password / Create Account.
- Validation/Error behavior:
  - Invalid email format -> inline validation error.
  - Empty password -> required-field error.
  - Wrong credentials -> `Wrong email or password.`
  - Missing account -> `This account does not exist.`
  - Pending contributor -> `Your request is still pending approval. You cannot log in yet.`
  - Inactive account -> `This account is inactive.`
  - Too many attempts -> backend 429 message shown.
- Screenshot placeholder:
  - `[Screenshot: Login form with validation]`

### Signup Screen
- Fields: full name, phone, email, password, confirm password, role selector (`viewer` or `contributor`).
- Actions:
  - Create account.
- Validation/Error behavior:
  - Password strength and confirm-match enforced.
  - Duplicate email returns conflict message.
  - Any admin role tampering is blocked by API.
  - Viewer signup activates immediately.
  - Contributor signup requires admin approval before login.
- Screenshot placeholder:
  - `[Screenshot: Signup success and error states]`

### Forgot Password / Reset Password
- Actions:
  - Request reset via email input.
  - Complete reset with new password + confirm.
- Validation/Error behavior:
  - Invalid email rejected.
  - Password mismatch rejected.
- Screenshot placeholder:
  - `[Screenshot: Forgot password flow]`

### Projects
- Actions:
  - Search available projects for the signed-in role.
  - Open a project.
- Validation/Error behavior:
  - Empty list shows empty-state card.
  - API failure shows retry action.
- Screenshot placeholder:
  - `[Screenshot: Projects list with status chips]`

### Project Details
- Actions:
  - Open map.
  - Start new feature when assigned as contributor.
  - Open drafts when assigned as contributor.
- Validation/Error behavior:
  - Viewer and public-project contributor access is read-only.
  - Feature actions stay disabled unless assignment exists.
- Screenshot placeholder:
  - `[Screenshot: Project details quick actions]`

### Map Screen
- Actions:
  - View the Lebanon basemap.
  - Switch project layer.
  - Review project feature overlays.
  - Tap Add Feature FAB when collection is allowed.
- Validation/Error behavior:
  - If a project has no features yet, a real empty-state card is shown over the basemap.
- Screenshot placeholder:
  - `[Screenshot: Map screen with GPS/sync status]`

### Add Feature Stepper
- Steps:
  1. Geometry
  2. Attributes
  3. Photos
  4. Review & Save Draft
- Validation/Error behavior:
  - Required fields block next step.
  - Invalid geometry is rejected server-side.
  - Upload/photo errors shown inline/snackbar.
- Screenshot placeholder:
  - `[Screenshot: Add feature stepper]`

### Drafts Screen
- Actions:
  - View/edit draft.
  - Submit for review.
- Statuses: draft, pending_review, rejected.
- Validation/Error behavior:
  - Rejected draft shows admin review notes.
- Screenshot placeholder:
  - `[Screenshot: Draft list and status timeline]`

### Notifications Screen
- Actions:
  - Read notifications.
  - Mark read/mark all read.
- Validation/Error behavior:
  - Empty state if no notifications.
- Screenshot placeholder:
  - `[Screenshot: Notifications list]`

### Profile Screen
- Actions:
  - View user identity + role.
  - Logout.
- Validation/Error behavior:
  - Logout clears local auth state and routes to login.
- Screenshot placeholder:
  - `[Screenshot: Profile with logout action]`

## Role-Based Access (User-Level Summary)
- Admin: full platform management.
- Contributor:
  - `Projects`: read-only public/viewer-visible projects
  - `Assigned Projects`: capture/edit/submit assigned data
- Viewer: read-only access to projects explicitly marked visible by admins and only while those projects are active or completed.

Full matrix: `docs/user-manual/08-role-permissions-matrix.md`
