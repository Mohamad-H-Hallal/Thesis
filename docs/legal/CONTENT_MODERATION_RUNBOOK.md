# Content moderation operations

Status: engineering runbook; moderation policy, response targets, appeal rules and legal escalation require owner/counsel approval.

Reports are allegations, not automatic evidence. Submission never hides, edits or deletes content. Only the protected super administrator can view the queue or update a report.

## Workflow

1. Open the report and review only the entity information the current administrator is authorized to access. A deleted, archived or private target must fail safely.
2. Move `submitted` to `in_review` when an administrator starts the review.
3. Close the review as `resolved` only after selecting the completed action, or use `dismissed` when no supported issue is found.
4. Any actual project, feature, photo, import, AI or account mutation must be performed through that domain's existing authoritative service and authorization rules.
5. The reporter message defaults from the selected status and outcome. Keep any custom message brief and do not reveal another user's identity or private-project details.
6. Final reports cannot be reopened. Submit a new report only for a distinct issue or a later recurrence.

The report history records the responsible administrator, transition, outcome and user-visible message. Real-time events contain only identifiers and invalidation scope; report details are fetched through protected REST routes.
