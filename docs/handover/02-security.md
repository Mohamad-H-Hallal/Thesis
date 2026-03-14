# Security Controls and Risk Mitigation

## Implemented Controls
- Public registration role escalation blocked.
- Admin role assignment restricted to authenticated admin-only route path.
- Metrics endpoint protection enforced for production (`METRICS_ENABLED=true` requires `METRICS_TOKEN`).
- API hardening middleware active: helmet, CORS policy, per-scope rate limiting.
- JWT access and refresh token validation with configured secret rotation fields.
- Input validation middleware for key route payloads and params.
- Parameterized SQL query usage through `pg` query placeholders.
- Role-based access controls for admin/contributor/viewer use cases.
- Audit trail instrumentation for sensitive actions.

## Threat Highlights and Mitigations
| Threat | Impact | Mitigation | Status |
|---|---|---|---|
| Privilege escalation via signup role tampering | Critical | Public register ignores role and validation rejects `admin` role | Mitigated |
| Unauthenticated metrics exposure in production | High | Startup fails if token missing while metrics enabled | Mitigated |
| Migration drift due to dual migration trees | High | Single migration source (`infra/migrations`) + drift check run | Mitigated |
| Contract drift between runtime and docs | High | `/api/v1` alignment + OpenAPI check in CI | Mitigated |
| Misleading quality signal from dist coverage | Medium | Coverage moved to source files | Mitigated |
| Mobile fake repositories in production path | High | Real API repositories enabled by default, mock mode explicit | Mitigated |

## Security-Relevant Verification Commands
- `npm run test:ci` (includes auth security regression tests)
- `npm run openapi:check`
- `npm run audit:prod`
- `flutter analyze`
- `flutter doctor -v`

## Residual Risks (Non-Blocking)
- Mobile coverage is below ideal long-term target; quality gate is moderate and currently passing.
- Gradle reports deprecation warnings that should be cleaned before major toolchain upgrades.

## Security Evidence
- `docs/handover/evidence/backend-commands.log`
- `docs/handover/evidence/migrations.log`
- `docs/handover/backend_test.log`
- `docs/handover/backend_audit_prod.log`
