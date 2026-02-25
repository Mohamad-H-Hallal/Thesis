# Secret Rotation Runbook

## Scope
Rotate JWT access/refresh signing secrets with no immediate logout blast.

## Environment Variables
- `JWT_SECRET_CURRENT`
- `JWT_SECRET_PREVIOUS` (comma-separated old secrets for temporary verification)
- `JWT_REFRESH_SECRET_CURRENT`
- `JWT_REFRESH_SECRET_PREVIOUS` (comma-separated old refresh secrets)

Fallback compatibility:
- `JWT_SECRET` and `JWT_REFRESH_SECRET` remain supported as base values.

## Rotation Procedure
1. Generate new secrets (minimum 32 chars, high entropy).
2. Deploy with:
   - `JWT_SECRET_CURRENT=<new>`
   - `JWT_SECRET_PREVIOUS=<old>`
   - `JWT_REFRESH_SECRET_CURRENT=<new>`
   - `JWT_REFRESH_SECRET_PREVIOUS=<old>`
3. Keep previous values during grace period (for already-issued tokens).
4. After grace period:
   - Remove old values from `*_PREVIOUS`.
5. Verify:
   - New login creates tokens signed by current secret.
   - Existing sessions still validate during grace period.

## Rollback
- Restore previous `*_CURRENT` and keep problematic value in `*_PREVIOUS`.

## Operational Notes
- Store secrets in a vault/secret manager (not in repository).
- Track rotation date, operator, and incident ticket in change log.
