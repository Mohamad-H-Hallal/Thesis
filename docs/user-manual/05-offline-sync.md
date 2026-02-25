# Offline and Sync Guide

## What Works Offline
- Draft capture and local edits are supported by local storage/sync queue design.
- UI shows offline banner placeholders and sync status indicators.

## Sync Queue Basics
- New/edited records are queued with retry/backoff policy.
- States transition through pending, processing, success, failed/conflict.

## Recommended Field Workflow
1. Before leaving connectivity, sign in and refresh assignments.
2. Capture features/photos as drafts.
3. Keep GPS and attribute completeness checks visible.
4. When online again, trigger sync and monitor statuses.

## Conflict Handling
- If conflict occurs, app marks record for review (conflict state).
- User should inspect latest server copy and merge manually through app workflow.

## Reliability Notes
- Idempotency keys prevent duplicate pushes from retries.
- Retry windows increase with backoff across attempts.
