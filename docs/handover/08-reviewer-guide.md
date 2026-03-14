# 08 - Review Guide

## Audience
System admins responsible for feature review and approval.

## Review Workflow

### 1) Open Review Queue
- Navigate to Review Queue section.
- Filter pending submissions.
- Screenshot placeholder:
  - `[Screenshot: Review queue list]`

### 2) Inspect Submission
- Open feature details.
- Validate geometry, attributes, and photo evidence.
- Check submission timeline metadata.
- Screenshot placeholder:
  - `[Screenshot: Submission detail for review]`

### 3) Approve or Reject
- Approve if quality rules are met.
- Reject with specific notes if corrections are required.
- Timeline behavior:
  - pending_review -> approved
  - pending_review -> rejected
- Screenshot placeholder:
  - `[Screenshot: Approve/Reject dialog with notes]`

### 4) Post-Review Follow-up
- Confirm notifications are dispatched.
- For rejected items, ensure notes are clear and actionable.
- Screenshot placeholder:
  - `[Screenshot: Status timeline after review]`

## Validation and Error Behavior
- Missing review status -> validation error.
- Missing/invalid feature ID -> 400/404.
- Unauthorized role -> 403.

## Review Permissions
- Can:
  - review pending submissions for authorized scope
  - approve/reject with notes
- Cannot:
  - bypass project assignment restrictions (unless admin)
  - alter platform security settings (unless admin)

## Quality Criteria Checklist
- Geometry validity and SRID consistency
- Required attributes complete
- Photo count/policy compliance
- Logical consistency with project objectives
