# Phase 9 - Security, Reliability, Observability Baseline

## Security Controls Implemented
- HTTPS enforcement middleware for production (`ENFORCE_HTTPS=true`).
- Proxy-awareness for reverse-proxy deployment (`TRUST_PROXY=true`).
- Strict CORS mode (`CORS_STRICT=true`) with explicit origin allow-list.
- Tiered rate limiting:
  - Global API limiter
  - Auth-specific limiter
  - Export-specific limiter
- JWT secret rotation support:
  - Current signing secret
  - Previous verification secret(s) for rotation grace window

## Audit Logging
- Added route-level audit middleware for sensitive actions:
  - Auth register/login/profile update/password change/logout
  - Project create/update/archive
  - Assignment create/approve/reject/delete
  - Feature create/update/delete/submit/review approve/reject
  - Export request and download
- Audit data stored in `audit_log` with:
  - actor (`user_id`)
  - action type
  - entity type/id
  - sanitized old/new values
  - source IP

## Observability Baseline
- Request context middleware:
  - `x-request-id` propagation/generation
  - request lifecycle logging with latency and status
- Readiness endpoint:
  - `GET /ready` with DB connectivity check
- Metrics endpoint:
  - `GET /metrics` (can be protected with `METRICS_TOKEN`)
  - includes uptime, memory, request totals, status distribution, top routes

## Recommended Production Settings
- `NODE_ENV=production`
- `TRUST_PROXY=true`
- `ENFORCE_HTTPS=true`
- `CORS_STRICT=true`
- `METRICS_ENABLED=true`
- `METRICS_TOKEN=<strong-random-token>`
