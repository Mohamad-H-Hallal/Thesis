# Phase 1 - Survey Data Dictionary v0.1 (Soft Freeze)

## Status
Draft `v0.1` for pilot. This version may evolve based on field pilot findings.

## Entity: `project`

| Field | Type | Required | Description |
|---|---|---|---|
| id | uuid | Yes | Project identifier |
| category_id | uuid | Yes | FK to project category |
| created_by_user_id | uuid | Yes | Creator user |
| name | string | Yes | Project name |
| description | text | No | Project summary |
| objectives | text | No | Collection objectives |
| status | enum | Yes | draft, active, paused, completed, archived |
| start_date | date | No | Planned start |
| end_date | date | No | Planned end |
| collection_form_schema | json | Yes | Dynamic form definition |
| requires_photos | boolean | Yes | Whether photos are mandatory |
| min_photos | int | No | Minimum photos per feature |
| max_photos | int | No | Maximum photos per feature |

## Entity: `spatial_feature`

| Field | Type | Required | Description |
|---|---|---|---|
| id | uuid | Yes | Feature identifier |
| project_id | uuid | Yes | FK to project |
| collected_by_user_id | uuid | Yes | Collector |
| geom | geometry | Yes | Point, LineString, or Polygon (SRID 4326) |
| attributes | json | Yes | Dynamic survey attributes |
| status | enum | Yes | draft, pending_review, approved, rejected |
| collected_at | timestamp | Yes | Capture timestamp |
| submitted_at | timestamp | No | Submission timestamp |
| reviewed_at | timestamp | No | Review timestamp |
| reviewed_by_user_id | uuid | No | Reviewer |
| review_notes | text | No | Reviewer comments |
| accuracy_meters | float | No | GPS accuracy |
| collected_offline | boolean | Yes | Captured while offline |
| synced_at | timestamp | No | Last sync timestamp |
| version | int | Yes | Optimistic concurrency / conflict handling |

## Entity: `photo`

| Field | Type | Required | Description |
|---|---|---|---|
| id | uuid | Yes | Photo identifier |
| feature_id | uuid | Yes | FK to spatial feature |
| file_path | string | Yes | Original image path |
| thumbnail_path | string | No | Thumbnail path |
| location | geometry | No | Optional photo location |
| accuracy_meters | float | No | GPS accuracy for photo |
| taken_at | timestamp | No | Camera capture time |
| exif_data | json | No | Camera metadata |
| file_size_bytes | int | Yes | File size |
| status | enum | Yes | pending, approved, rejected |
| display_order | int | Yes | Sort order in UI |

## Dynamic Attribute Guidelines (`attributes`)

1. Keys must be snake_case.
2. Values allowed: string, number, boolean, null, array of primitives.
3. Required fields are enforced by `collection_form_schema`, not DB columns.
4. Unit-bearing fields should include a unit suffix where applicable (`*_ha`, `*_m`, `*_kg`).

## Pilot Notes

1. New fields may be added in `v0.x` with schema version increment.
2. Breaking field changes require migration plan and app compatibility update.
3. Freeze to `v1.0` will happen after pilot feedback and data quality review.
