# 07 - Field Collector Guide

## Audience
Contributors and field teams.

## Standard Collection Flow

### Step 1 - Prepare Session
- Login before leaving connectivity.
- Sync assignments and project list.
- Confirm target project appears in Home.
- Screenshot placeholder:
  - `[Screenshot: Home projects before field trip]`

### Step 2 - Capture Feature Draft
- Open project -> New Feature.
- Fill stepper screens:
  - Geometry
  - Attributes
  - Photos
  - Review and Save Draft
- Screenshot placeholder:
  - `[Screenshot: Feature stepper in progress]`

### Step 3 - Offline Handling
- Offline banner indicates no network.
- Continue saving drafts locally.
- Do not force-submit when network unavailable.
- Screenshot placeholder:
  - `[Screenshot: Offline banner + draft queue]`

### Step 4 - GPS and Photo Guidance
- Ensure GPS quality is acceptable before final save.
- Add required photos and verify metadata.
- Screenshot placeholder:
  - `[Screenshot: Photo capture and GPS indicator]`

### Step 5 - Submit Draft
- Reconnect to network.
- Open Drafts and submit pending items.
- Monitor status changes: draft -> pending_review.
- Screenshot placeholder:
  - `[Screenshot: Draft submit action and status]`

## Validation and Error Behavior
- Required field missing -> inline form error.
- Invalid geometry -> backend rejection (400).
- Upload/network failure -> retry prompt and queued sync.
- Conflict detected -> item marked conflict and requires review.

## Permissions for Field Collector
- Can:
  - view assigned projects
  - create/edit own drafts
  - submit for review
- Cannot:
  - approve/reject others' submissions
  - manage users or categories

## Troubleshooting in Field
- Login fails:
  - verify credentials and connectivity.
- Sync stuck:
  - wait for network, reopen app, retry submit.
- Rejected submission:
  - open notes, correct data, resubmit.
