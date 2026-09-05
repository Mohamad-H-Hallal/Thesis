# TerraLeb Phase 8 assisted external-evidence register

Last updated: 2026-08-26
Release: Android and web v1, Lebanon
Production authorization: **blocked**

This register records facts and evidence that engineering cannot fabricate. It is not a self-service checklist and it is not a claim of legal compliance. Codex will present only the next small action in chat, wait for `continue`, verify the result, and update `docs/predeployment/MANUAL_SETUP_PROGRESS.md` before moving on.

Never put passwords, payment-card data, access tokens, customer secret keys, service-account JSON, private signing keys, recovery codes or two-factor codes in Git, this document or chat. A console screenshot used as evidence must be redacted first.

## Status summary

| Sequence | External item | Responsible person/provider | Status | Dependency |
|---:|---|---|---|---|
| 1 | OCI tenancy and Jeddah region | TerraLeb operations owner / Oracle | Awaiting assisted setup | None |
| 2 | Legal operator facts and production domain | TerraLeb legal/release owner | Awaiting owner facts and decision | None; needed before public DNS/Play |
| 3 | OCI compartment, IAM, storage and backup credentials | Operations owner / OCI | Blocked | 1 |
| 4 | ArcGIS online application | GIS owner / Esri | Engineering ready; external setup and live measurement blocked | Operator identity and account |
| 5 | Copernicus and OSM offline source evidence | GIS owner / Copernicus + Geofabrik/approved extract provider | Builder ready; source acquisition/package build blocked | Account/source approval |
| 6 | Production AI image and Earth Engine plan | AI owner / registry + Google Cloud | TerraLeb boundary ready; external AI source remediation/image/provider evidence blocked | Operator account and AI source work |
| 7 | Firebase, final Android ID, signing and Play organization | Release owner / Google | Awaiting assisted setup | 2 |
| 8 | SMTP sending domain | Operations owner / selected mail provider | Awaiting provider choice | 2 |
| 9 | Retention and deletion decisions | Legal owner + qualified Lebanese counsel | Owner policy adopted; counsel/staging evidence blocked | Engineering behavior is stable; owner record exists |
| 10 | Territory, age, GIS/publication and AI policy | Legal owner + counsel | Owner policy adopted; counsel/operator evidence blocked | 2 |
| 11 | Governing law, disputes and Law 81 formalities | Qualified Lebanese counsel | Awaiting authoritative review | 2, 9, 10 |
| 12 | Arabic and English final legal documents | Legal owner, translator and counsel | Awaiting approved facts and exact hashes | 2, 9–11 |
| 13 | Google Play declarations | Release owner / Google Play | Awaiting final build and policy hashes | 7, 12 |
| 14 | Staging proof and live measurements | Engineering/operations/GIS/AI owners | Awaiting accounts and credentials | 1–8 |
| 15 | Exact-build production authorization | Named TerraLeb release owner | Last action; blocked | Every applicable finding approved |

## 1. OCI tenancy and Jeddah home region

**Owner action sequence — perform only one numbered action when Codex asks for it:**

1. Open `https://cloud.oracle.com/`. Sign in to an organization-owned OCI account, or choose **Sign up** if none exists. Complete identity, password, payment and MFA privately.
2. During tenancy creation, select **Saudi Arabia West (Jeddah)** / `me-jeddah-1` as the home region. The home region cannot normally be changed after tenancy creation; stop before confirming if Jeddah is not shown.
3. After sign-in, open the region selector in the top bar and confirm **Saudi Arabia West (Jeddah)**.
4. Open **Profile → Tenancy: [name]** (or **Governance & Administration → Account Management → Tenancy Details**) and confirm the tenancy OCID and home region. Do not paste the full OCID in chat.
5. Open **Billing & Cost Management → Budgets → Create Budget**. Scope it to the future TerraLeb compartment. Before paid resources exist, set an initial monthly alert threshold of **USD 200** and notifications to an organization-controlled operations mailbox. Budget alerts do not cap usage.

**Cost/effect:** account creation may require payment verification. No compute/storage charge starts merely from validating the tenancy. The currently selected stack is OCI E4 Flex x86, 4 OCPU/32 GB, 300 GB balanced block plus private object/archive storage. At current public rates the infrastructure baseline is approximately **USD 160–180/month before tax, domain, SMTP, ArcGIS overage, Earth Engine and counsel**. Terraform `apply` is a separate paid action and requires explicit approval.

**Evidence:** redacted Tenancy Details showing `me-jeddah-1`; budget name/amount/alert recipients; accepted provider agreement/version. Store outside Git if the screenshot contains tenancy identifiers. Record an immutable evidence-system reference in the readiness file.

**Codex verification:** confirm the page through the signed-in browser when permitted; later run `tofu plan` with redacted output and `node scripts/verify-production-config.js`. Do not set `hostingRegionsAndSubprocessors` approved until the provider terms, data-flow and subprocessor records match the exact tenancy.

Official references: `https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm`, `https://www.oracle.com/sa/a/ocom/docs/corporate/pricing/oracle-paas-and-iaas-global-price-list.pdf`.

## 2. Legal operator facts and production domain

1. The legal owner completes only factual fields in `docs/legal/OWNER_AND_COUNSEL_QUESTIONNAIRE.md`: exact operator/controller name, legal form, public contact address, country, public privacy email and responsible owner. Do not invent a company or government affiliation.
2. The release owner decides a final domain controlled by that same operator. Codex will check availability/structure but will not purchase it without a price review and explicit approval.
3. If purchase is approved, open the selected registrar, search the exact domain, review first-year and renewal prices plus registry/WHOIS treatment, then purchase privately. Do not send payment or registrar login data.
4. Turn on MFA and registrar/domain lock. Do not change nameservers or create public records until the staging endpoint and rollback plan are ready.

**Cost/effect:** domain price depends on the selected name/TLD and must be shown immediately before purchase. A DNS change can make a public service reachable and therefore always requires explicit approval.

**Evidence:** registrar receipt with financial details redacted, registrant/operator ownership, renewal price/date, MFA/domain-lock confirmation, and the questionnaire decision record. Later configure `PUBLIC_HOSTNAME`, API/web origins, Android links and public policy URLs.

**Codex verification/gates:** DNS ownership lookup, TLS/host/origin/WebSocket tests, public logged-out legal routes and `productionIdentifiersVerified`. The domain is not evidence of legal-controller identity by itself.

## 3. OCI compartment, IAM and two storage identities

1. In OCI open **Identity & Security → Compartments → Create Compartment**. Name it `terraleb-prod`; place it under the operator tenancy; use a non-sensitive description.
2. Create separate groups/dynamic groups or workload identities for deployment, application-object access and backup-only access. Do not run TerraLeb using the tenancy administrator.
3. Apply the reviewed least-privilege policies generated by `infra/oci/terraform`; Codex must show the plan before any `apply`.
4. Open **Identity & Security → Domains → [default domain] → Users → [workload user] → Customer secret keys → Generate secret key**. Create separate S3-compatible keys for application buckets and backup bucket. The secret is shown once: place it directly into the organization password manager and later the server secret file; never send it to Codex.
5. Create private buckets through the reviewed Terraform: uploads, exports, offline packages, AI outputs and backups. Public access must remain disabled; versioning/lifecycle/encryption follow the runbook.

**Cost/effect:** this step starts charges only when Terraform creates compute/block/object resources. Estimated resources and rollback are in `docs/predeployment/phase-2-oci-object-storage-and-backup-runbook.md`.

**Evidence:** redacted IAM policies; bucket visibility/encryption/lifecycle pages; key-created timestamps (not key values); `tofu plan/apply` hash; object authorization and backup/restore results.

**Configuration:** secret paths named in `.env.prod.example`; S3 endpoint is `https://<namespace>.compat.objectstorage.me-jeddah-1.oraclecloud.com`. Codex verifies cross-bucket denial, checksum, streaming, expiry, encrypted backup and isolated restore before approval.

## 4. ArcGIS online Hybrid application

1. Open `https://location.arcgis.com/` and sign in with an operator-owned account.
2. From the ArcGIS Location Platform dashboard open **My portal → Content → My content → New item → Developer credentials → OAuth 2.0 credentials**.
3. Create a server-side application named `TerraLeb Production Map Proxy`. Grant only the supported basemap privileges required by the selected static-basemap tile service (currently `premium:user:staticbasemaptiles`, and `premium:user:basemaps` only if the chosen endpoint requires it).
4. Add the production application URL/redirect restriction when the console offers it. Do not put the client secret in Flutter or web assets. Store client ID and secret directly in the server’s protected secret files.
5. Open billing/usage settings. Review the actual free allowance and overage price shown for the account, create quota/budget notifications, and do not enable unrestricted pay-as-you-go without explicit approval.

**Cost/effect:** the current official static-basemap model states 2,000,000 returned tiles/month free, then USD 0.15 per 1,000 returned tiles. The provider bills returned tiles; viewing only Lebanon does not make requests free. Cache hits may reduce returned tiles, while zooming, panning, changing screens and the separate reference overlay can increase them. TerraLeb’s server soft limit defaults to 100,000/day and Hybrid falls back to Street on 401/403/429/quota/outage without losing drawings or forms.

**Evidence:** account/subscription terms version, non-secret application ID, exact privileges/restrictions, quota notification, provider attribution response and a 7–30 day staging metrics export. Never retain the client secret in evidence.

**Codex verification/gates:** enable Hybrid only in staging, test expiry/401/403/429/outage/fallback, and measure `gis_api_map_provider_requests_total` on every important map screen. Monthly overage formula: `max(0, returned_tiles - 2,000,000) / 1,000 × 0.15`. No quota projection becomes evidence until live returned-tile counts exist.

Official references: `https://developers.arcgis.com/rest/static-basemap-tiles/`, `https://developers.arcgis.com/documentation/security-and-authentication/app-authentication/`.

## 5. Copernicus imagery and OSM-derived offline labels

1. Open `https://dataspace.copernicus.eu/` and select **Register**. Create an operator-owned account and complete credentials/2FA privately.
2. Review and save the exact Copernicus Data Space terms and Sentinel data notice applicable on the acquisition date. Free access does not remove attribution, provenance or redistribution-record obligations.
3. In the Copernicus Browser select **Sentinel-2 L2A**, draw/select Lebanon, choose a low-cloud acquisition window, and record every selected product/scene ID, acquisition date, cloud percentage and download checksum. Do not select restricted contributing-mission imagery.
4. For labels use the Lebanon extract from `https://download.geofabrik.de/asia/lebanon.html`, not the public OSM tile endpoint. Save the extract URL/date/checksum and the ODbL/Geofabrik notice.
5. Codex runs the controlled builder in `infra/offline-map`, records tools/versions/mosaic/cloud-mask/reprojection/resampling/zoom/checksum, visually reviews the result, then uploads it privately and registers it through the authenticated package workflow.

**Cost/effect:** Sentinel-2 and the Geofabrik Lebanon extract are available without a dataset purchase; compute, temporary disk, object storage and bandwidth still cost money. The resulting 10 m orientation image is not cadastral/building/survey grade.

**Evidence/gates:** source terms hashes/URLs, scene/product IDs, source checksums, build manifest, final checksum/version, attribution screenshot, airplane-mode/account-isolation/interruption/storage-pressure tests. `offlinePackageSourceRights` remains blocked until the GIS/legal owner approves the exact evidence.

## 6. AI image and Google Earth Engine

1. The AI owner remediates or supplies a reviewed repository/image implementing the contract in `docs/predeployment/phase-5-production-ai.md`; the historical source at commit `ed06c63a231e8d3d711239acbfa65f017ca7ac07` is not production-authorized as-is.
2. Build a pinned `linux/amd64` image, produce SBOM/vulnerability scan, push it to an operator-controlled private registry and record its immutable `sha256` digest. Never use a mutable tag in production.
3. Open `https://console.cloud.google.com/`, create/select an operator-owned project, and enable **Earth Engine API**.
4. Open the Earth Engine registration page and truthfully select noncommercial eligibility or a commercial plan. Do not self-declare free/noncommercial eligibility merely to avoid charges. Commercial use requires billing; a Limited plan is usage-based.
5. Create a dedicated service account with only required Earth Engine/project access, restrict quotas/concurrency/daily EECU use, and store its JSON key privately in the server secret file. Prefer workload identity/keyless access if the final topology supports it.

**Cost/effect:** no AI production run is made during setup. Earth Engine cost depends on the truthful registration tier, EECU compute, storage and egress. The protected super administrator alone enables AI per project; AI remains default-off and data is allowlisted project GIS data, never general account/profile data.

**Evidence/gates:** source commit/image digest, dependency lock, SBOM/scan, image architecture, API/health/callback/replay/restart results, exact Earth Engine registration/plan, service-account role list, cost/quota alerts, project-isolation and exact-payload tests. Secrets are not evidence.

## 7. Firebase, Android identity, signing and Google Play organization

1. The release/legal owner first chooses whether the publisher is an organization or an individual based on real operator facts. Organization accounts require organization verification and normally a D-U-N-S number; do not misclassify the account.
2. Open `https://play.google.com/console/signup`, use an operator-controlled Google account, accept the displayed agreement, review the displayed one-time registration fee (commonly USD 25), and obtain explicit approval before payment.
3. Complete identity/contact verification privately. Use public contact details that the operator has approved for display.
4. Decide the final reverse-domain Android application ID once; Codex updates Gradle, Firebase and tests. Changing it after Play publication creates a different app.
5. Open `https://console.firebase.google.com/` → **Create a project** → **Add app → Android**; enter the exact final application ID. Download `google-services.json` directly to the expected private build location. Do not paste it in chat.
6. Generate the upload key locally into the organization’s protected password-manager/key-custody process. Enrol in Play App Signing. Never commit the keystore or passwords.

**Cost/effect:** no public release occurs at this stage. Registration/payment and the final app identity require explicit approval. Firebase Cloud Messaging has its own current provider terms and quotas.

**Evidence/gates:** Play/Firebase project IDs, verified account type, fee receipt redacted, final application ID decision, signing-custody record, SHA fingerprints, exact AAB hash and Play App Signing enrollment. Codex verifies release AAB, push delivery/privacy/session revocation and `productionIdentifiersVerified`.

## 8. SMTP provider and sending domain

1. Select an operator-contracted SMTP provider with suitable Lebanon delivery, DPA/terms, security, pricing and data region. Do not use a personal mailbox.
2. In the provider console add the approved sending domain/subdomain. Codex will prepare the required DNS records; no DNS change is performed without explicit approval.
3. Add SPF and DKIM exactly as issued; add DMARC initially in a monitored non-destructive policy agreed by operations, then verify provider status.
4. Create a least-privilege SMTP/API credential, store it privately in the `smtp_password` secret file, and configure the approved From address.

**Cost/effect:** provider-specific; Codex must show monthly/message price and retention/subprocessor implications before purchase. DNS changes affect mail reputation and require explicit approval.

**Evidence/gates:** contract/terms/DPA reference, data region, verified sender screenshot, redacted DNS results, test-delivery headers with addresses removed, bounce/rate-limit monitoring. Codex tests OTP/reset/notification mail without logging contact values.

## 9. Retention and deletion owner/counsel decisions

1. The owner-approved durations, purposes, triggers and actions are recorded in `docs/legal/RETENTION_MATRIX.md` and `docs/legal/TERRALEB_OWNER_POLICY_DECISION_RECORD_V1.md`. Verify that the final operator accepts that exact schedule; do not silently change it during provider setup.
2. Qualified Lebanese counsel reviews the owner decisions for retained accepted GIS/institutional provenance, masked-label visibility, accepted photo/precise-location/free-text treatment, 35-day backup ageing, and contributor/deletion notices against the implemented behavior.
3. Counsel requests any required changes and signs an approval/reference tied to the exact decision, retention, deletion-design, public-document and release hashes.

**Effect:** enabling the approval references allows reviewed asynchronous deletion to execute in production. It does not make retained masked records anonymous, and it does not erase accepted GIS geometry. Unapproved/pending/draft data can be discarded only after the protected admin makes the explicit non-preselected decision.

**Evidence/gates:** signed immutable decision files, approver identity/date/version/hash, retention worker and backup-expiry tests, role-by-role deletion tests. Configure the approval-reference variables only to real immutable records; rerun privacy execution, retention and readiness gates.

## 10. Territory, age, GIS/publication and AI policy

1. Record Lebanon as the intended v1 territory/distribution and whether access outside Lebanon is technically blocked or merely outside marketing scope.
2. Decide the real minimum age/minors policy. The conservative proposal is 18+ with no intentional minors processing, but the legal owner/counsel must approve it and application behavior must match.
3. Approve the contribution terms: authority to submit GIS source data, provider/source warranties, institutional review/provenance retention and separately controlled public publication.
4. Approve AI rules matching implementation: project-by-project protected-super-admin enablement; allowlisted GIS/project datasets; no account/profile data; no general/cross-project training; human validation before publication; retraction.

**Evidence/gates:** signed decision record and exact notice/policy hashes; test age/signup behavior, publication controls, AI allowlist and retraction. These decisions do not authorize external source data that the contributor did not have rights to submit.

## 11. Governing law, disputes and Lebanon Law 81 formalities

1. Give qualified Lebanese counsel the exact Arabic Official Gazette text relied on, current data inventory/flows/DPIA, target operator, hosting region/subprocessors, policies and actual app behavior.
2. Counsel verifies governing-law/dispute wording, rights/response procedure and any Ministry notification, exemption, permit/licensing or sensitive-site obligations. Do not rely on unverified translated article numbers.
3. Record counsel’s dated conclusion, limitations and required actions against exact document/build hashes. Complete any real formality and retain the official receipt/reference.

**Cost/effect:** professional/legal and possible filing costs are unknown until engagement. No filing or public legal claim is made automatically.

**Evidence/gates:** signed counsel memo and official receipts/references; update `lebanonLaw81Formalities`, `governingLawAndDisputes` and counsel approval only to evidence that directly covers the release.

## 12. Final Arabic and English legal documents

1. After behavior and decisions are stable, replace every production placeholder in Privacy, Terms, AUP, Important Notices, Account Deletion and Subprocessor content with approved facts.
2. Obtain professional Arabic translation/review, including right-to-left layout and consistent defined terms. The two languages must describe the same behavior.
3. Counsel approves exact hashes, versions and effective dates. Keep previous versions accessible.
4. Codex loads only counsel-approved documents, validates logged-out stable HTTPS routes and in-app links, and confirms the signup checkbox is affirmative and not bundled privacy consent.

**Effect:** publishing legal pages is a public legal action and requires explicit approval immediately beforehand.

**Evidence/gates:** final files/hashes, translation and counsel approvals, screenshots/accessibility tests, acceptance-version tests. Legal drafts remain unavailable in production.

## 13. Google Play declarations

1. In Play Console open the TerraLeb app → **Policy and programs → App content**. Complete Privacy Policy, Ads, App access, Target audience/content, Data Safety, Account deletion and any UGC/content declarations using the verified inventory—not guesses.
2. Open **Data Safety**, declare collection/sharing/processing by the app, backend and SDKs consistently with `docs/legal/STORE_DISCLOSURES.md` and `DATA_INVENTORY.md`.
3. Add the stable public privacy and account-deletion URLs. Provide reviewer access instructions without exposing a real user account or production secret.
4. Upload the exact tested AAB only after Codex presents its hash and all release gates pass. Start with internal/closed testing; production rollout needs separate approval.

**Evidence/gates:** submission receipts/screenshots, exact answers export, AAB/version/hash, policy hashes and review status. Codex cross-checks manifest permissions/SDKs/data flows and does not mark `googlePlayApproved` until the applicable store evidence exists.

## 14. Staging proof and live measurements

After items 1–8 are configured, Codex performs the deployment and tests. Owner actions are limited to private sign-in/approval prompts and physical-device observations requested one at a time.

Required evidence includes: empty database bootstrap with only protected super admin; TLS/host/Origin/WebSocket; storage authorization; encrypted backup and isolated restore; worker restart; disk-full and provider failure; Street/Hybrid tile counts by screen; offline package and airplane mode; AI lifecycle and quota failure; privacy export/correction/moderation/deletion; FCM; two-session real-time; Android/web builds; accessibility; performance/cost; rollback. An unexplained >5% regression blocks release.

## 15. Exact-build authorization

1. Codex produces the final report, all 44 statuses, exact Git/image/AAB/web/config/policy hashes and remaining risks.
2. The named release owner and counsel verify that every applicable record has matching immutable evidence.
3. The owner gives written authorization for that exact release only. Codex then updates `productionAuthorization`; any changed build/config/policy requires a new authorization.

Production authorization must never be inferred from tests, an account subscription, counsel discussion, a checkbox viewed in a console or completion of this register.

## Verification rule

After each assisted action, Codex validates the provider page or a safe API/configuration/log/test result, records an immutable evidence reference without secrets, updates `docs/predeployment/MANUAL_SETUP_PROGRESS.md`, and reruns the named gate. No blocked finding is approved merely to make the readiness command pass.
