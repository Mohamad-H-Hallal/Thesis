# User Manual Overview

## Product Name
AI-Enhanced Geospatial Mobile GIS Collector (current runtime scope: non-AI collection, review, export).

## Platforms
- Flutter mobile app (Android focus)
- Flutter web build (browser)
- Backend API under `/api/v1`

## Core Workflow
1. User signs in.
2. User sees projects assigned to their account.
3. Contributor captures or edits features.
4. Drafts are submitted for review.
5. Admin approves or rejects.
6. Approved data can be exported.

## Roles
- Admin
- Project Admin
- Contributor
- Viewer

Detailed permissions are in `docs/user-manual/08-role-permissions-matrix.md`.

## Preconditions
- User account exists and is active.
- API is reachable.
- Mobile app configured with correct `API_BASE_URL`.

## Support
Use `docs/user-manual/07-troubleshooting.md` for common issues and escalation steps.
