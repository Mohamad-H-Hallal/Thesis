# Login, Signup, and Password Recovery

## Login
1. Open the app.
2. On `Splash`, wait for token check.
3. If not authenticated, you are routed to `Login`.
4. Enter email and password.
5. Optional: toggle password visibility.
6. Tap `Sign In`.
7. On success, app opens the main shell (`/app`).

Validation:
- Email must be valid.
- Password is required.

## Signup
1. Tap `Create account` from login.
2. Fill full name, email, password, confirm password.
3. Accept terms checkbox (if shown in your build variant).
4. Tap `Create account`.
5. On success, account is created as contributor-level public account.

Important security behavior:
- Public signup cannot create admin accounts.

## Forgot Password
1. Tap `Forgot password?` on login.
2. Enter your email.
3. Submit request.
4. App shows confirmation state (`Check your email`).

## Reset Password (token simulation flow)
1. Open reset link route (`/reset-password`) from email/deep link simulation.
2. Enter new password and confirm password.
3. Submit.
4. Return to login and sign in with new password.

## Error Cases
- Wrong password: show authentication error.
- User not found/inactive: show backend message.
- Rate limited (`429`): wait and retry.
- Network failure: show retryable error banner/snackbar.
