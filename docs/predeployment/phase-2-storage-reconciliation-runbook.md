# Phase 2C — Storage Migration and Reconciliation Runbook

This runbook controls storage inventory, legacy-reference migration, rollback,
and reviewed orphan quarantine. It does not provide a permanent-delete
operation.

## Non-negotiable safety conditions

Run the tools from the same deployed API environment that has:

- the target database connection;
- the exact `UPLOAD_DIR` mounted at the target API upload root;
- the exact `EXPORT_DIR` mounted at the target API export root;
- a verified database backup and storage snapshot;
- an identified operator and independent reviewer.
- a maintenance window that stops API writes, background import/export work,
  uploads, cleanup workers, and all other processes that can change database
  references or the two storage roots.

Do not combine a database from one environment with storage roots from another.
That mismatch makes valid database references appear missing and valid files
appear unreferenced. Never use such a report to authorize a mutation.

Production execution requires explicit deployment approval. Complete the whole
procedure in production-like staging first.

## 1. Generate the read-only inventory

From `apps/api`:

```powershell
$env:LOG_LEVEL = 'error'
npm run --silent storage:inventory > storage-inventory.json
```

The command reads database references, walks the two configured storage roots
without following symbolic links, computes file SHA-256 values by default, and
writes JSON to standard output. It does not alter the database or filesystem.
The temporary log-level setting keeps informational application logs out of the
machine-readable JSON output; errors still fail the command.

Record:

- `manifestSha256`;
- target environment and release SHA;
- database identity;
- resolved upload and export volume identities;
- generation timestamp;
- counts for every classification;
- all missing and unresolved references.

Stop if any root, database, or environment identity is wrong. Missing or
unresolved references require investigation; they are not orphan approvals.

An exploratory host run on 2026-07-28 intentionally demonstrated this guard:
the host test-artifact folders contained 14,693 files while the connected
Docker database referenced paths in different mounted roots. The result
reported 14,675 unreferenced files, 9 missing references, and 25 unresolved
references. It is evidence of environment mismatch and must never be used for
quarantine.

## 2. Migrate a reviewed legacy reference

Create a regular JSON file no larger than 5 MiB. Unknown fields are rejected.
Every item must use an allowed table, column, object kind, destination prefix,
row UUID, exact source value, size, and lowercase SHA-256.

```json
{
  "version": 1,
  "operation": "copy_verify_switch",
  "approvedBy": "Independent reviewer name",
  "approvedAt": "2026-07-28T18:00:00.000Z",
  "rollbackRetentionDays": 30,
  "items": [
    {
      "objectKind": "feature_photo",
      "referenceTable": "photo",
      "referenceColumn": "file_path",
      "referenceRowId": "00000000-0000-4000-8000-000000000000",
      "sourceReference": "C:\\deployed\\uploads\\photos\\reviewed.jpg",
      "destinationKey": ".private/feature-photos/reviewed.jpg",
      "expectedSizeBytes": 12345,
      "expectedSha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
```

Allowed mappings are:

| Object kind | Database target | Destination |
| --- | --- | --- |
| `feature_photo` | `photo.file_path` | `uploads/.private/feature-photos/` |
| `feature_thumbnail` | `photo.thumbnail_path` | `uploads/.private/feature-thumbnails/` |
| `gis_import` | `gis_import_job.file_path` | `uploads/.private/imports/` |
| `export_file` | `shapefile_export.file_path` | `exports/completed/` |

Preflight without mutation:

```powershell
npm run --silent storage:reconcile -- validate-migration --manifest .\reviewed-migration.json
```

After the operator and reviewer compare the manifest hash, execute:

```powershell
npm run --silent storage:reconcile -- execute-migration --manifest .\reviewed-migration.json --confirm COPY_VERIFY_SWITCH_SOURCE_RETAINED
```

The preflight verifies the exact live database value, source size and SHA-256,
and any existing destination. The workflow is resumable. It copies exclusively,
verifies source and
destination size and SHA-256, locks the target row, requires its current value
to match the reviewed source or destination, switches the reference
transactionally, and retains the source. Conflicting reruns fail closed.

Exercise rollback in staging:

```powershell
npm run --silent storage:reconcile -- rollback-migration --manifest .\reviewed-migration.json --confirm ROLLBACK_REFERENCE_SWITCH_KEEP_DESTINATION
```

Rollback is allowed only during the recorded retention window. It verifies the
retained source and destination, switches the exact row back transactionally,
and keeps the destination for investigation or re-execution.

## 3. Quarantine explicitly reviewed orphans

Begin only from a checksummed inventory generated in the correct environment.
Create a separate reviewed manifest:

```json
{
  "version": 1,
  "operation": "quarantine_reviewed_orphans",
  "inventoryManifestSha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "reviewedBy": "Independent reviewer name",
  "reviewedAt": "2026-07-28T18:00:00.000Z",
  "reviewReason": "Confirmed absent from live references, backups, retention holds, and import/export operations.",
  "items": [
    {
      "sourceReference": "storage://uploads/imports/reviewed-orphan.geojson",
      "expectedSizeBytes": 12345,
      "expectedSha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
```

Preflight without mutation:

```powershell
npm run --silent storage:reconcile -- validate-orphans --manifest .\reviewed-orphans.json
```

The preflight regenerates the complete checksummed inventory, requires the
reviewed inventory hash to match, and verifies every selected object is still
unreferenced with the exact reviewed size and SHA-256. After independent
review, quarantine:

```powershell
npm run --silent storage:reconcile -- quarantine-orphans --manifest .\reviewed-orphans.json --confirm QUARANTINE_REVIEWED_ORPHANS_NO_DELETE
```

The tool regenerates a checksummed inventory and requires its hash to match the
reviewed report before starting. Each source must still be classified
`unreferenced` with the reviewed size and checksum. It copies the object to a
unique `.quarantine/legacy-orphans/...` reference, verifies the copy, records
the audit row, locks every supported reference table, checks again that the
source is unreferenced, and only then removes the source copy. The quarantine
copy remains recoverable.

There is no purge or permanent-delete command in Phase 2C. A future retention
policy must define backup confirmation, legal or operational holds, quarantine
duration, approval roles, and a separately reviewed opt-in purge before any
destructive capability is considered.

## Failure handling

- Inventory mismatch: stop and generate a new report; never override the hash.
- Source or destination checksum mismatch: stop, preserve both objects, and
  investigate storage integrity.
- Database reference changed: stop and review the newer business operation.
- Failed migration before reference switch: the original reference remains
  active; preserve the audit row and rerun only after diagnosis.
- Failed orphan move after the verified quarantine copy: preserve both
  locations and the audit row; the same reviewed manifest can resume only when
  the recorded state and checksums still agree.
- Unexpected source reappearance after quarantine: stop. The tool refuses to
  remove it.
- Expired migration rollback window: do not bypass it; perform a new reviewed
  recovery plan from verified backups.

## Phase 2C acceptance evidence

Record all of the following:

- focused adapter, inventory, migration, rollback, and orphan tests;
- symbolic-link escape regression tests;
- fresh-database migration application;
- complete API release gate and full dependency audit;
- full Flutter analysis and test suite;
- Compose rendering;
- production-like staging inventory with matching roots;
- staging copy/verify/switch and rollback proof;
- staging reviewed-orphan quarantine and recovery proof;
- required GitHub checks and merge commit.
