# Phase 1 - Scope Baseline (No AI)

## Goal
Define what the first production version includes for the Lebanese GIS Fruit Trees Data Collector before AI/classification modules.

## In Scope (Phase 1-8 delivery target)

1. Authentication and user profiles.
2. Role-based access control (admin, contributor, viewer).
3. Project and category management.
4. Project assignments and approval workflow.
5. Spatial feature collection:
   - Point, LineString, Polygon geometry
   - Dynamic attributes via `collection_form_schema`
   - Offline capture flags and sync metadata
6. Photo attachments with metadata and ordering.
7. Draft -> submit -> review -> approve/reject lifecycle.
8. Notifications for assignment/review/export events.
9. Export requests, async processing, file download.
10. Basic operational reporting dashboards (counts, statuses, activity).
11. Audit logging for sensitive actions.

## Explicitly Out of Scope (for now)

1. Any AI/ML pipeline (model training, prediction, confidence surfaces).
2. Satellite ingestion/classification workflows.
3. Automated agronomic recommendations.
4. Advanced BI analytics beyond baseline operational reporting.

## Non-Functional Baseline

1. Security: TLS in deployed environments, strict CORS allowlist, rate limiting.
2. Reliability: graceful shutdown, migration checks on startup, retry-safe sync contracts.
3. Performance: indexed PostGIS queries for map viewport and project filtering.
4. Observability: structured logs, health endpoints, baseline alerts.

## Phase-1 Exit Criteria

1. Scope approved by product owner and ministry technical stakeholders.
2. RBAC matrix approved.
3. Data dictionary v0.1 approved for pilot.
4. Form schema versioning rules approved.
