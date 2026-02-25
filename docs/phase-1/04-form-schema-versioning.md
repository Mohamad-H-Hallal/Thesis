# Phase 1 - Form Schema Versioning Policy

## Objective
Define how `collection_form_schema` changes are introduced safely while mobile clients may be offline.

## Versioning Model

1. Use semantic-style schema versions: `major.minor.patch`.
2. Store explicit schema metadata in each project:
   - `schema_version` (string)
   - `schema_status` (draft, active, deprecated)
   - `published_at` timestamp

## Change Rules

1. Patch (`x.y.z -> x.y.z+1`):
   - Typo fixes, labels/help text updates.
   - No key/type/required changes.

2. Minor (`x.y -> x.y+1`):
   - Add optional fields.
   - Add non-breaking validation constraints.

3. Major (`x -> x+1`):
   - Rename/remove fields.
   - Change required/optional in a breaking way.
   - Change field types or cardinality.

## Compatibility Contract

1. API accepts submissions from current active schema and configurable set of legacy versions.
2. Mobile app sends `schema_version` with each feature payload.
3. Server validates payload against the declared schema version.
4. If schema version is unsupported, server returns explicit upgrade error.

## Offline Safety Rules

1. Do not force major schema switch during active field campaign window.
2. Keep previous major version accepted for a grace period.
3. Sync response should include latest schema metadata so clients can update forms.

## Governance Workflow

1. Author change proposal (reason, impact, migration).
2. Review by product + technical owner.
3. Publish schema with version bump and release note.
4. Update mobile renderer compatibility matrix.

## Freeze Milestone

1. During pilot: allow controlled `v0.x` updates.
2. After pilot sign-off: freeze `v1.0` and only apply hotfixes unless change board approves.
