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
2. Enter your registered email.
3. Submit request.
4. If the email exists, the app shows a confirmation message.
5. Check your email for the one-time verification code.
6. In local Docker development, reset emails go to Mailpit at `http://localhost:8025` unless the backend is explicitly configured for real SMTP delivery.
7. For real inbox delivery, the backend must run with:
   - `MAIL_TRANSPORT=smtp`
   - valid `SMTP_HOST`
   - valid `SMTP_PORT`
   - valid `SMTP_FROM_EMAIL`
   - `SMTP_USER` / `SMTP_PASS` if required by the provider
8. If the email service is unavailable, the app stays on the email step and shows a delivery error instead of pretending success.

## Reset Password
1. Open the reset-password step from the app flow.
2. Enter only the verification code that was sent to your email.
3. If the code is valid, continue to the new-password step.
4. Enter new password and confirm password.
5. Submit.
6. Return to login and sign in with the new password.

## Error Cases
- Wrong password: show authentication error.
- User not found/inactive: show backend message.
- Rate limited (`429`): wait and retry.
- Network failure: show retryable error banner/snackbar.
