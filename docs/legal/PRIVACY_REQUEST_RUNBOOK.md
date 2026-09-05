# Privacy request operations

Status: engineering runbook; final deadlines, retention, notices and lawful bases require owner/counsel approval.

Only the protected super administrator may use **Privacy & moderation**. Server authorization is authoritative. Every request is paginated and has immutable status history; changing a status is not proof that the requested action occurred.

## Intake and triage

1. Confirm the request type, identity-verification state, due indicator and current status.
2. Move `submitted` to `in_review` when review starts. Decide an in-review request by approving or rejecting it.
3. Keep personal details out of user-visible messages, logs and notifications. Use the request ID as the operational reference.
4. For correction, approve only the API allowlist. `full_name` uses the canonical profile service; verified phone changes remain in the existing Profile workflow.
5. For restriction or objection, record the independently completed authoritative action and a resolution summary before `completed`.
6. The ten-day target is an internal safety target until Lebanese counsel confirms the applicable rule.

## Access export

Approval schedules the background export. Do not mark it completed manually. A completed request must have a validated encrypted artifact. The user reauthenticates to create a short-lived, session-bound, single-use download grant. See `PERSONAL_DATA_EXPORT.md`.

## Account deletion

Approval requires explicit choices for unfinished work and responsibilities. Select **Require resolution first** when any work must be decided through its normal workflow. Select **Discard drafts and unapproved work** only when the protected administrator is authorized to permanently remove those records and files. Choose **Already transferred** only after the normal admin tools show no residual assignment, AI, privacy, or moderation responsibility; otherwise choose **Release**. No destructive option is preselected. Do not combine deletion with contributor deactivation. Production execution stays disabled until all configured approval references exist. See `ACCOUNT_DELETION_AND_PSEUDONYMIZATION.md`.

## Failure and evidence

Worker retries are bounded. Exhaustion changes the request to `failed`, appends worker history, sends a generic notification and updates the protected queue. Review the safe failure code and never place erased data or secrets in a user message. Retry only after the underlying cause is corrected. Preserve request history, artifact access evidence, backup-expiry scheduling and the final audit record according to approved retention.
