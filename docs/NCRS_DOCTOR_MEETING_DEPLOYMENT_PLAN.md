# NCRS Doctor Meeting Deployment Plan

Last updated: 2026-05-21

This document is the short production-like staging plan for the NCRS doctor/team demo. It intentionally does not include passwords, tokens, `.env` contents, database dumps, APK binaries, or backup files.

## 1. Current App Status

The app is ready for a controlled NCRS staging/demo review:

- Backend API, database migrations, authentication, role access, imports, exports, maps, notifications, and review workflows are implemented.
- Browser/Chrome runtime was stabilized and validated in previous phases.
- Android emulator runtime was stabilized and validated in previous phases.
- The current Docker dev/staging runtime database has been reset to a clean state with only the protected NCRS super-admin account.
- No Redis has been added.
- No AI/GEE classification pipeline has been added in this branch.

The protected demo/staging super-admin account is:

- Email: `ncrsadmin@gmail.com`
- Full name: `NCRS Administrator`
- Password: stored only in the local/server `.env` used for bootstrap, not in this document.

The database stores only a bcrypt password hash. Change the temporary password inside the app immediately after the first successful login.

## 2. What Is Ready

- Role-based access for viewer, contributor, admin, and protected super-admin behavior.
- Project/category administration.
- Contributor assignment workflow.
- Project map with approved official features only.
- Import workflow with staged features separate from official map data.
- Import map with staged import features plus approved project context.
- Review/approval/rejection flows.
- Open on Map behavior that focuses geometry and opens the feature detail sheet.
- Export workflow for GeoJSON/Shapefile outputs.
- Browser and Android builds.
- Docker Compose local/staging stack.

## 3. What Is Not Yet Public Production

This is not yet a public government production deployment. Before public production, add or harden:

- HTTPS-backed VPS/domain staging first.
- Private upload/object storage instead of public or local filesystem-only uploads.
- Malware scanning and file magic-number validation for uploaded files.
- Production monitoring, alerting, and centralized logs.
- External backup storage and restore drills.
- Redis or another shared cache only when moving beyond one backend instance or higher traffic.
- Dedicated background workers if import/export workloads grow.
- Physical Android device testing and iOS runtime testing on macOS/Xcode.

## 4. Recommended Staging Deployment

Recommended demo path:

1. Use one small VPS.
2. Deploy with Docker Compose.
3. Use a real subdomain such as `gis-demo.ncrs.example`.
4. Put Nginx/Caddy/Traefik in front for HTTPS.
5. Configure SMTP for transactional authentication and password workflows.
6. Bootstrap only `ncrsadmin@gmail.com`.
7. Let the NCRS admin create real demo categories/projects/users during the meeting.

This keeps the demo clean and avoids showing seeded dummy data to the doctor/team.

## 5. Exact VPS Deployment Steps

### 5.1 Create VPS

Recommended minimum for staging:

- Ubuntu 22.04 or 24.04 LTS
- 2 vCPU / 2 GB RAM / 50 GB disk preferred
- 1 vCPU / 1 GB RAM can work for a light demo, but imports/maps may feel tighter

### 5.2 Install Docker

On the VPS:

```bash
sudo apt update
sudo apt install -y ca-certificates curl git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Log out and back in after adding the Docker group.

### 5.3 Clone and Checkout

```bash
git clone <repo-url> gis-app
cd gis-app
git checkout handover-ready
```

### 5.4 Create Production/Staging Env

Create a server `.env` from the example file, then edit it with real values:

```bash
cp .env.prod.example .env
nano .env
```

Set at minimum:

- `NODE_ENV=production` or staging-equivalent if supported
- database user/password/name
- JWT/access/refresh secrets
- `SUPER_ADMIN_EMAIL=ncrsadmin@gmail.com`
- `SUPER_ADMIN_FULL_NAME=NCRS Administrator`
- strong temporary `SUPER_ADMIN_PASSWORD`
- SMTP host/user/password/from address
- CORS origins for the deployed web domain
- public API URL used by the web/mobile clients

Never commit `.env`.

### 5.5 Start Docker Compose

```bash
docker compose up -d --build
```

Check containers:

```bash
docker compose ps
docker compose logs -f api
```

### 5.6 Run Migrations / Bootstrap

If migrations are not automatically run by compose:

```bash
docker compose run --rm migrate
```

The API bootstrap should create `ncrsadmin@gmail.com` if it does not already exist.

### 5.7 Health Check

```bash
curl http://localhost:3000/health
```

Through HTTPS after reverse proxy:

```bash
curl https://api.your-domain.example/health
```

### 5.8 Build and Deploy Web

Build web with the staging API URL:

```bash
cd apps/mobile
flutter build web \
  --dart-define=APP_FLAVOR=staging \
  --dart-define=API_BASE_URL=https://api.your-domain.example
```

Deploy `apps/mobile/build/web` behind Nginx/Caddy/Traefik or to a static host.

### 5.9 Build Android APK for Staging URL

```bash
cd apps/mobile
flutter build apk --release \
  --dart-define=APP_FLAVOR=staging \
  --dart-define=API_BASE_URL=https://api.your-domain.example
```

The APK output is:

```text
apps/mobile/build/app/outputs/flutter-apk/app-release.apk
```

Rename it before sharing, for example:

```text
ncrs-demo-staging.apk
```

Do not commit APK files.

### 5.10 Test First Login

1. Open the browser staging URL.
2. Login as `ncrsadmin@gmail.com`.
3. Change the temporary password immediately.
4. Create one admin/contributor/viewer account if needed for the meeting.
5. Create one real NCRS category and project if desired.

## 6. Android APK Testing Plan

### Option A: Local/Laptop Backend APK

Use this only when the Android emulator/phone can reach the laptop backend.

Built local artifact:

```text
<local-backup-folder>\apks\ncrs-demo-local-backend.apk
```

It was built with:

```bash
flutter build apk --release \
  --dart-define=APP_FLAVOR=dev \
  --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Install on emulator:

```bash
adb install -r <local-backup-folder>\apks\ncrs-demo-local-backend.apk
```

Replace the path above with the exact local artifact path reported in the Phase 12 completion notes.

For a physical Android phone, `10.0.2.2` is emulator-only. Build another APK using the laptop LAN IP, for example:

```bash
flutter build apk --release \
  --dart-define=APP_FLAVOR=dev \
  --dart-define=API_BASE_URL=http://192.168.1.50:3000
```

### Option B: Remote Staging Server APK

Build only after the staging API domain is final:

```bash
flutter build apk --release \
  --dart-define=APP_FLAVOR=staging \
  --dart-define=API_BASE_URL=https://api.your-domain.example
```

This APK can be shared manually, through Firebase App Distribution, or later through Google Play testing tracks.

Firebase App Distribution is appropriate for a doctor/team demo because it can distribute pre-release Android builds without publishing to Google Play. Google Play is not needed yet unless public/internal Play-track distribution is required.

## 7. Browser Testing Plan

### Local Browser

```bash
cd apps/mobile
flutter run -d chrome \
  --dart-define=APP_FLAVOR=dev \
  --dart-define=API_BASE_URL=http://localhost:3000
```

Open the URL printed by Flutter, usually:

```text
http://localhost:<port>
```

### Remote Browser

Build with:

```bash
flutter build web \
  --dart-define=APP_FLAVOR=staging \
  --dart-define=API_BASE_URL=https://api.your-domain.example
```

Serve `build/web` over HTTPS. HTTPS is required for a production-like browser demo to avoid mixed-content/security issues and to behave like a real deployment.

## 8. Cost Table for Doctor Meeting

These are realistic estimates, not guaranteed prices. Confirm prices at purchase time.

| Item                      | Recommended demo option                  |        Estimated cost | Notes                                                                                                                      |
| ------------------------- | ---------------------------------------- | --------------------: | -------------------------------------------------------------------------------------------------------------------------- |
| Local laptop demo         | Existing machine                         |                    $0 | Best for private presentation, no hosting needed.                                                                          |
| Low-cost VPS staging      | DigitalOcean basic droplet or equivalent |    about $6-$24/month | DigitalOcean lists Droplets from $4/month and common small plans around $6/month+. Choose 2GB+ if imports/maps feel heavy. |
| Domain                    | Namecheap/Porkbun/Cloudflare Registrar   |    about $10-$20/year | Namecheap `.com` examples are around low-teens first year, renewals can be higher.                                         |
| HTTPS                     | Let's Encrypt                            |                    $0 | Free TLS certificates.                                                                                                     |
| SMTP                      | Brevo free tier or similar               | $0 to about $10/month | Brevo free plan includes 300 daily email sends; paid plans start higher if needed.                                         |
| Firebase App Distribution | Firebase                                 |                    $0 | Firebase lists App Distribution as a no-cost Firebase tool.                                                                |
| Google Play               | Play Console                             |          $25 one-time | Not needed for the doctor/team demo.                                                                                       |
| Apple Developer           | Apple Developer Program                  |              $99/year | Needed for TestFlight/App Store distribution; iOS also requires macOS/Xcode.                                               |
| Production pilot          | VPS + domain + backups + SMTP            |   about $20-$80/month | Depends on upload volume, backup storage, monitoring, and traffic.                                                         |

Reference sources:

- DigitalOcean Droplets pricing: https://www.digitalocean.com/pricing/droplets
- Namecheap domain pricing: https://www.namecheap.com/domains/
- Let's Encrypt: https://letsencrypt.org/
- Brevo pricing: https://www.brevo.com/pricing/
- Firebase App Distribution: https://firebase.google.com/products/app-distribution
- Google Play Console: https://play.google.com/console/about/
- Apple Developer Program: https://developer.apple.com/programs/

## 9. Security Explanation for Staging

For staging/demo:

- No dummy data should exist in the clean staging database.
- Only the protected super-admin should exist at initial bootstrap.
- The super-admin temporary password must live only in `.env` and should be changed after first login.
- The database stores bcrypt hashes, not plaintext passwords.
- `.env`, backup files, uploaded files, Firebase admin files, and signing keys must stay private.
- HTTPS is required for remote staging.
- CORS should allow only the staging web origin.
- SMTP credentials must be staging-specific if possible.
- Uploads are currently suitable for controlled staging, but public production should use private object storage, malware scanning, stricter magic-number checks, and backup/retention policies.
- Redis is not needed for this staging step.

## 10. Future AI Branch Plan

AI/GEE classification is a future thesis module/integration, not part of this staging branch.

Recommended future approach:

1. Keep the current stable app on `handover-ready`.
2. Create a separate branch, for example `feature/ai-gee-classification`.
3. Add GEE/cloud classification behind admin-only controls.
4. Store model/classification jobs separately from official spatial features until reviewed.
5. Add clear provenance, confidence, and review workflow.
6. Merge only after the normal app remains stable.

## 11. Future Redis/Scaling Plan

Do not add Redis for the doctor/team demo.

Add Redis later when:

- More than one API instance is deployed.
- Map/import aggregation endpoints receive sustained high traffic.
- WebSocket/event fan-out needs shared state across instances.
- Background workers need shared queues/rate limits.

Safe future design:

- `REDIS_URL` optional.
- If Redis is missing/down, app falls back to in-process cache.
- No startup crash when Redis is unavailable.
- Docker Compose production profile can include Redis.
- Cache invalidation tests must cover project updates, import approval/rejection, feature creation/deletion, and assignment changes.

Likely Redis candidates later:

- Map aggregate summaries.
- Large import feature aggregate/viewport queries.
- Notifications/unread counts.
- Real-time event fan-out state.
- Rate-limit/session metadata.

## 12. Backup and Restore Notes

Current Phase 12 backups are outside the repo. The exact local path is reported in the Phase 12 completion notes and should not be committed or shared publicly.

```text
<local-backup-folder>\phase12-staging-prep-<timestamp>
```

The previous NCRS demo-seeded DB dump is preserved there. The current Docker runtime DB was reset only after that backup existed.

Never store backups inside Git. For production, schedule daily encrypted database dumps to private storage and test restore before relying on the backup plan.

## 13. Final Recommendation

For the doctor/team meeting:

1. Use the clean staging DB with only `ncrsadmin@gmail.com`.
2. Present the app by creating real demo data live or with a small curated NCRS dataset.
3. Use browser over HTTPS if a VPS/domain is ready.
4. Use the local APK only for emulator/laptop-backed testing.
5. Build a new remote APK after the staging API URL is final.
6. Do not add Redis or AI before the meeting; keep them as future scaling/thesis modules.
