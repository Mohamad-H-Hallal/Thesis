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
  - Wrong credentials -> backend 401 message shown.
  - Too many attempts -> backend 429 message shown.
- Screenshot placeholder:
  - `[Screenshot: Login form with validation]`

### Signup Screen
- Fields: full name, email, password, confirm password, terms checkbox.
- Actions:
  - Create account.
- Validation/Error behavior:
  - Password minimum length and confirm-match enforced.
  - Duplicate email returns conflict message.
  - Any admin role tampering is blocked by API.
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

### Home / Projects
- Actions:
  - Search assigned projects.
  - Open a project.
- Validation/Error behavior:
  - Empty list shows empty-state card.
  - API failure shows retry action.
- Screenshot placeholder:
  - `[Screenshot: Home projects list with status chips]`

### Project Details
- Actions:
  - Open map.
  - Start new feature.
  - Open drafts.
- Validation/Error behavior:
  - Access denied if assignment missing.
- Screenshot placeholder:
  - `[Screenshot: Project details quick actions]`

### Map Screen
- Actions:
  - View map context.
  - Tap Add Feature FAB.
- Validation/Error behavior:
  - GPS/sync placeholders indicate readiness.
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
  - Rejected draft shows reviewer notes.
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
- Project-admin: project-level review/coordination.
- Contributor: capture/edit/submit assigned data.
- Viewer: read-only assignment views.

Full matrix: `docs/user-manual/08-role-permissions-matrix.md`
