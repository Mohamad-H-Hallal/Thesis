# TerraLeb production AI integration status

Last reviewed: 2026-08-26
Application repository: `D:\GIS_APP`
Located AI source: `D:\AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS`
Source remote: `https://github.com/mribrahim314/AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS.git`
Audited source commit: `ed06c63a231e8d3d711239acbfa65f017ca7ac07`
Production authorization: blocked pending the source/image changes and external evidence below.

## What is complete in TerraLeb

- AI remains available and every project remains disabled by default in the database.
- Only the protected super administrator can enable project AI, create/start/resume/cancel runs, record data-use authority, review runs, and publish/unpublish run or layer results.
- The backend sends a versioned, explicit project/run payload. Model preferences are allowlisted; arbitrary extra fields are not forwarded.
- The initiating user's ID is no longer sent to the AI service. The callback secret is mounted separately in both services and is no longer included in the run payload or persisted in the AI run state.
- Concurrent and per-project daily run limits are checked transactionally with an advisory lock. The configured maximum estimated cost is included as a mandatory run boundary for the production image.
- Production Compose defines an internal, non-public AI service with a digest-required image, separate control/data networks, explicit outbound network, read-only root filesystem, dropped capabilities, `no-new-privileges`, health check, limits, persistent output volume, secret files and graceful shutdown.
- The API sends an internal service credential header on all AI requests. The approved Python image must validate it using constant-time comparison on every non-health endpoint.
- Existing review, validation, publication, retraction, notification and scoped real-time behavior is preserved.

## Exact production image contract still required

No production image digest exists yet. The located source is real and clean at the audited commit, but that commit cannot be approved unchanged because:

1. `ai_server.py` does not authenticate its `/api/*` endpoints. It must reject a missing or invalid `X-TerraLeb-Internal-Secret`, retain a minimal unauthenticated health response, never log the secret, and include authorization/replay tests.
2. `01_export_ground_truth.py` selects and exports `collected_by_user_id`. Remove that field from the query and generated GEE/GeoJSON artifacts. Retain only the approved feature ID, project/run identifiers, approved label and geometry needed for training.
3. Diagnostic SQL can enumerate unrelated projects and all attribute keys. Replace it with project-scoped, aggregate-only diagnostics that never print labels or arbitrary attribute names from unrelated projects.
4. The image base is a mutable `python:3.11-slim-bookworm` tag. Pin it by immutable digest and generate an SBOM, vulnerability report and dependency/license evidence for the exact built image.
5. The AI process uses the broad application database role and writes output tables directly. Before approval, create and use a dedicated least-privilege AI database role or move database writes behind the authoritative backend. The role must not read account, contact, session, notification, privacy, moderation or unrelated-project data.
6. Outputs currently originate on a shared filesystem. Add an idempotent, checksum-verified transfer into the private `ai` object-storage bucket and replace public/application references with `storage://ai/...` references before the local staging copy expires.
7. Enforce `max_estimated_cost_usd`, concurrency, timeout and project boundaries inside the Python service as defense in depth. Refuse unknown configuration keys and never accept client-supplied database, object-store, callback or GEE destinations.
8. Add callback replay protection using a stable callback event ID and authenticated timestamp/signature or an equivalently reviewed mechanism. Duplicate terminal callbacks must be idempotent.
9. Prove restart/resume, cancel, GEE failure, callback failure, object-storage failure and disk-full behavior without publishing partial output.

After these source changes are reviewed, build `linux/amd64`, run the complete AI source suite, scan it, push it to the operator-owned private registry and record `AI_SERVER_IMAGE` as `registry/repository@sha256:<64 hex>`. The selected DigitalOcean core and AI paths are x86. The 12 GiB AI service must not run on the 8 GiB core Droplet: deploy it on separately approved private on-demand compute, persist checksum-verified outputs before teardown, and destroy the worker after reconciliation because a powered-off Droplet remains billable. The starting AI worker candidate is 16 GiB; an 8 GiB worker is allowed only after representative profiling and failure tests support a lower memory limit. Separation must not grant general database or Internet access; retain the approved internal authentication and least-privilege project data boundary.

## Exact allowed input contract

- `run_id` and `project_id`.
- Approved project AOI/geometry or a reviewed project feature extent.
- Approved feature geometry and the one approved label field.
- Approved Sentinel/Landsat source and time windows.
- Approved feature groups/bands/indices, model choice, thresholds and run safety limits.
- Recorded project data-use and publication authorization references remain in TerraLeb; the full approval record is not sent to GEE.

The following are forbidden: names, email, phone, user IDs, credentials, sessions, device tokens, notification data, privacy/moderation data, contact/profile data, private or unsynchronized drafts, arbitrary form attributes, free text, unrelated projects and unapproved photos.

## External evidence required

- Operator-owned GEE/Google Cloud project, approved edition/plan, service account, asset folder, provider terms and cost/quota limits.
- Reviewed AI source commit and immutable image digest.
- Documented DigitalOcean x86 core and on-demand AI staging proof, including private connectivity, teardown/recovery, cost and memory evidence.
- Dataset/model provenance, exact source dates and licences, evaluation version/results and retraction test evidence.
- Owner/legal approval for project GIS training and separate publication policy. General or cross-project model training remains prohibited.

## Rollback

- Disable AI for the affected project or cancel the run through the protected-super-admin workflow.
- Revoke the AI internal credential and GEE service account if compromise is suspected.
- Roll back to the last approved immutable image digest. Do not reuse or overwrite image tags/digests.
- Keep results unpublished until review succeeds. Unpublishing removes viewer access without rewriting accepted field contributions.
