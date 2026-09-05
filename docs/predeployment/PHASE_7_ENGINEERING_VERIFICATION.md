# TerraLeb Phase 7 engineering verification

Recorded: 2026-08-26
Release scope: Android and web v1, Lebanon
Status: local engineering verification substantially complete; provider-backed staging and release authorization remain blocked

Passing this file's engineering checks does not establish legal compliance or authorize production.

## Architecture decision

- Selected host: OCI Saudi Arabia West (`me-jeddah-1`), `VM.Standard.E4.Flex`, `linux/amd64`, 4 OCPU/32 GB.
- Selected disk: 300 GB balanced block storage, with the boot volume sized separately.
- Selected object boundary: five private S3-compatible OCI buckets for uploads, exports, offline packages, AI outputs and backups. Backups use a separate identity and application encryption.
- The API image built and executed successfully on `linux/arm64`, but the exact pinned `postgis/postgis:16-3.5-alpine` production digest has no ARM64 manifest. The full A1 stack therefore failed its architecture gate and the documented E4 x86 fallback is mandatory for this release.
- No OCI resource has been created and no cost has been incurred.

At public list rates checked on 2026-08-26, 4 E4 OCPUs plus 32 GB memory are approximately USD 141.60/month, 300 GB balanced block is approximately USD 12.75/month, and a 50 GB boot volume at the same performance is approximately USD 2.13/month. A small fresh object/archive footprint adds only a few dollars, while DNS, email, requests and monitoring remain usage-dependent. Use USD 160–180/month before tax and optional providers as the working infrastructure estimate and USD 200 as the initial budget alert. A live OCI quote/plan remains mandatory before apply.

## Local verification results

| Area | Command/check | Result |
|---|---|---|
| API formatting/lint | `npm run lint` | Passed |
| API type checking | `npm run typecheck` | Passed |
| API build | `npm run build` | Passed |
| OpenAPI | `npm run openapi:check` | Passed; 182 operations |
| Migration chain | full-chain, integrity, runtime-grants, denied-DDL and no-loss credential rotation tests | Passed through migrations 0070–0072 |
| API full unit/integration/security suite | `npm run test:ci -- --silent --coverageReporters=json-summary` | Passed in 581.48 s; 51 suites passed, one skipped; 376 tests passed, two skipped, zero failed |
| API performance suites | bounding-box, export, concurrent workload and worker-restart suites | Passed on 2026-09-05; 69 ms, 482 ms, 3,769 ms and 989 ms respectively in the local environment |
| Production dependencies | npm audit and pinned OSV source scan | Passed on 2026-09-05; zero reported vulnerabilities |
| Flutter formatting/static analysis | formatter verification and `flutter analyze` | Passed; no issues |
| Flutter full suite | `flutter test --coverage` plus 19% coverage gate | Passed on 2026-09-05; 426/426 and 52.25% line coverage |
| Android validation build | development-defined debug APK | Passed |
| Android production bundle | signed release AAB | Correctly blocked by final application ID, Firebase file, keystore and signing custody |
| Web release validation | staging-flavor release build using non-routable `https://staging.invalid` | Passed; not deployable evidence |
| Web WASM compatibility | release dry run | Passed |
| Docker development render/runtime | `docker compose config --quiet`, live health, worker restart | Passed; API/database/Valkey/ClamAV healthy and workload worker restarted healthy |
| Production Compose | render with process-only non-secret validation placeholders | Passed; default invocation fails closed when mandatory external values/files are absent |
| Nginx | HTTP health/readiness and HTTP/1.1 WebSocket upgrade | Passed locally through `localhost:8088`; invalid token closed with 1008 |
| IaC | OpenTofu 1.12.6 `fmt -check` and `validate`, OCI provider 8.27.0 | Passed; no state/resources created |
| Storage/backup | local/S3 adapter and backup unit suites; backup image build | Passed locally; real OCI authorization and isolated restore blocked |
| Offline package | deterministic Python builder | Passed 2/2; no source scene downloaded/published |
| Software inventory | dependency license report generator | Passed 4/4; 292 npm and 136 Flutter packages, zero unresolved inventory entries; legal license review remains required |
| Release/readiness scripts | legal/readiness/release/config script suites | Script tests pass. Twelve owner-policy decisions now have immutable repository evidence; the CLI truthfully reports 30 remaining blocked items, including aggregate production authorization, counsel, providers, staging and final public documents. |
| Source and release-image security | Gitleaks full-history, OSV, npm audit and pinned Trivy scans | 251 commits: no secret leaks; source dependency findings: zero; API/Prometheus/Alertmanager/Blackbox/Loki: zero high/critical; Alloy: zero unsuppressed high/critical with exact expiring VEX and six reviewed medium records. |

## Runtime and performance observations

- A post-suite local Nginx sample recorded `/health` at p50 5.12 ms and p95 15.88 ms over 100 sequential requests, and `/ready` at p50 5.79 ms and p95 7.15 ms over 50 sequential requests. The `/health` maximum of 160.39 ms was a single local outlier. These are development-host smoke measurements, not staging/API workload SLO evidence.
- The idle WebSocket transport uses ping/pong and targeted revocation; the local upgrade path succeeded. Provider-backed multi-instance and reconnect-storm evidence still requires staging.
- Import/export polling calls are gated behind `REALTIME_POLLING_FALLBACK_ENABLED`; the production example disables the fallback. OTP countdowns and queued offline synchronization scheduling remain intentionally present.
- Large privacy exports, private media and offline packages are streamed or processed off the Flutter UI isolate at their boundaries. No large export artifact is parsed on the UI thread.
- The performance-suite durations above are regression thresholds, not API p50/p95 measurements. There is no comparable pre-change production/staging workload, so a less-than-five-percent before/after claim would be fabricated. The provider-backed staging load run must record p50/p95, query count, CPU, memory, object operations, WebSocket delivery and queue depth before production authorization.

## Staging evidence still blocked externally

- Empty production bootstrap on the selected OCI host and confirmation that only the protected super administrator is created.
- Real TLS/domain/host/Origin/WebSocket behavior.
- Real OCI IAM cross-bucket denial, private-object access, encrypted backup and isolated restore.
- ArcGIS credential, tile count, quota, 401/403/429/outage and attribution evidence.
- Copernicus/OSM source acquisition, package checksum, device airplane-mode and source/10 m notice evidence.
- Production AI image digest, exact payload, callback replay/restart, GEE quota/cost and publication/retraction evidence.
- Firebase push, signed AAB, Play internal/closed test and real-device permission behavior.
- SMTP delivery, bounce/rate limit and privacy evidence.
- Full load comparison and operational rollback exercise.

These items remain individually blocked; they do not invalidate completed local engineering work and must not be marked approved without their real evidence.
