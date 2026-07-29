# AI Server Deployment

The AI server is a backend service. Flutter never starts it and never calls it
directly.

```text
Flutter -> Node/Express API -> Python FastAPI AI server -> pipeline/GEE/DB
        <- run details refresh <- backend callback <-
```

## Manual Dev Mode

Start the backend in one terminal:

```powershell
cd D:\GIS_APP\apps\api
npm run dev
```

The backend uses real process environment first, then `apps/api/.env`, then the
root `.env` as fallback. For manual AI mode the active backend env must include:

```env
AI_SERVER_URL=http://127.0.0.1:8000
AI_CALLBACK_BASE_URL=http://127.0.0.1:3000
APP_PUBLIC_API_URL=http://127.0.0.1:3000
AI_CALLBACK_SECRET=dev-ai-callback-secret-change-me
AI_SERVER_TIMEOUT_MS=30000
```

Start the AI server in another terminal:

```powershell
cd D:\AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS
.\scripts\start_ai_server.ps1
```

Equivalent command:

```powershell
python -m uvicorn ai_server:app --host 127.0.0.1 --port 8000 --reload
```

The AI server local env should include:

```env
AI_DRY_RUN=false
APP_BACKEND_URL=http://127.0.0.1:3000
AI_CALLBACK_SECRET=dev-ai-callback-secret-change-me
DATABASE_URL=postgresql://<user>:<password>@127.0.0.1:<host-postgres-port>/<database>
OUTPUTS_DIR=outputs
```

The AI repo `.env` provides the GEE values (`GEE_PROJECT_ID`,
`GEE_SERVICE_ACCOUNT`, and `GEE_KEY_FILE`/`GEE_PRIVATE_KEY_PATH`). Keep those in
the ignored AI repo env/key directory, not in this app repository.

Convenience helper:

```powershell
cd D:\GIS_APP
.\scripts\dev\start_ai_stack.ps1
```

Run Flutter separately. For Android emulator, Flutter may need
`http://10.0.2.2:3000` as its backend URL. Do not use `10.0.2.2` for
`AI_SERVER_URL`; that URL is used by the backend process.

## Docker Compose Dev Mode

Compose starts the backend and AI server automatically:

```powershell
cd D:\GIS_APP
docker compose -f docker-compose.dev.yml up --build
docker compose -f docker-compose.dev.yml logs -f api ai-server
docker compose -f docker-compose.dev.yml down
```

Compose service URLs:

```env
api:       AI_SERVER_URL=http://ai-server:8000
api:       AI_CALLBACK_BASE_URL=http://api:3000
api:       APP_PUBLIC_API_URL=http://localhost:3000
ai-server: APP_BACKEND_URL=http://api:3000
ai-server: AI_DRY_RUN=false
ai-server: DATABASE_URL=postgresql://<user>:<password>@db:5432/<database>
```

AI run output files persist in the named `ai_outputs` volume at `/app/outputs`
inside the AI container. GEE credentials are read from the AI pipeline repo
`.env`, and the local `GEE-KEY` directory is mounted read-only into the AI
container.

Smoke check:

```powershell
.\scripts\dev\smoke_ai_compose.ps1 -Start
```

The final real-mode Compose smoke command is:

```powershell
cd D:\GIS_APP
.\scripts\dev\smoke_ai_compose.ps1 -Start -StartRun -AutoAuth -AutoProject
```

`-AutoAuth` logs in through the real backend. It uses `TEST_EMAIL` and
`TEST_PASSWORD` when set; otherwise it tries `SUPER_ADMIN_EMAIL` and
`SUPER_ADMIN_PASSWORD` from the active env files. The account must be the
protected super-admin because AI settings and AI run creation use protected
backend endpoints. The script never prints the token or password.

`TEST_AUTH_TOKEN` is only an optional smoke-script shortcut. It is the normal
JWT access token returned by `POST /api/v1/auth/login`; its lifetime follows
the backend `JWT_EXPIRE` setting. The Flutter app does not need this variable:
it receives the token from app login.

`TEST_PROJECT_ID` is only an optional smoke-script shortcut. It is the project
UUID from the backend `project` table/API. The project must have AI enabled,
valid AI settings, a label field, approved/labeled ground-truth samples,
readiness that is not blocked, a connected AI server, and no active AI run.
The Flutter app does not need this variable: it uses the project selected by
the user.

`-AutoProject` lists projects through the authenticated backend API and selects
the first AI-ready project. If no project qualifies, the script prints the
missing data/readiness reason. Set `AI_DRY_RUN=true` explicitly only for a
test-only smoke run without GEE/database writes.

## Health Checks

Host manual mode:

```powershell
Invoke-RestMethod http://127.0.0.1:3000/health
Invoke-RestMethod http://127.0.0.1:8000/health
.\scripts\dev\check_ai_stack.ps1
```

Compose mode:

```powershell
docker compose -f docker-compose.dev.yml ps
docker compose -f docker-compose.dev.yml exec ai-server python -c "import json,urllib.request; print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/health')))"
```

Readiness behavior:

- Missing `AI_SERVER_URL`: backend readiness reports the URL is not configured
  and Start AI Run is rejected before dispatch.
- AI server down: backend readiness reports unavailable and Start AI Run fails
  fast instead of leaving a fake queued run.
- AI server connected: readiness reports connected and may still block on AOI,
  settings, or training-sample requirements.
- AI server degraded: readiness reports degraded when health returns degraded;
  real-mode GEE/DB configuration should be fixed before production runs.

## Restart Behavior

After env changes, restart the service that reads that env:

- Change `apps/api/.env` or root `.env` for host backend: restart `npm run dev`.
- Change AI repo `.env`: restart uvicorn or `scripts/start_ai_server.ps1`.
- Change Compose env: run `docker compose -f docker-compose.dev.yml up -d --force-recreate`.

Backend restart reloads env deterministically and existing runs remain visible
from the database.

AI server restart scans persisted
`outputs/projects/{project_id}/runs/{run_id}/status.json` files. If a run was
`accepted`, `queued`, `starting`, `running`, or `cancelling` but no local
background task survived the restart, it is marked `failed` with stage
`interrupted`, `can_resume: true`, and message:

```text
AI server restarted before this run completed.
```

The AI server calls the backend callback if the persisted status has
`callback_url`. Resume restarts from the earliest safe stage.

## Production Compose

`docker-compose.ai-research.example.yml` is retained only for controlled local
AI research/demo reproduction. It is not a production template. A release AI
integration must be redesigned as a hardened overlay on the canonical
`compose.prod.yml` and `compose.observability.yml` stack after model/data
governance and external staging gates are approved.
Provide real values through an ignored `.env` file or a secret manager:

- `DATABASE_URL` or DB service credentials
- `AI_CALLBACK_SECRET`
- `APP_PUBLIC_API_URL`
- GEE project/service-account/key path
- reverse proxy/TLS settings
- `AI_DRY_RUN=false` for real production

Production service URLs remain internal:

```env
api:       AI_SERVER_URL=http://ai-server:8000
api:       AI_CALLBACK_BASE_URL=http://api:3000
ai-server: APP_BACKEND_URL=http://api:3000
```

Use `restart: unless-stopped`, persistent database storage, persistent
`ai_outputs`, and healthchecks for both `api` and `ai-server`.

## Future Deployment Options

Kubernetes or systemd can replace Compose as long as the same boundaries hold:

- keep Python AI server as a managed backend service
- keep Flutter pointed only at the Node/Express API
- keep `AI_CALLBACK_SECRET` shared only by backend and AI server
- persist AI outputs across container or service restarts
- expose health checks to the platform

## Troubleshooting

- Backend health works but readiness says URL missing: set `AI_SERVER_URL` in
  the backend's active env and restart the backend.
- AI health works from host but backend in Compose cannot connect: use
  `http://ai-server:8000` inside Compose, not `127.0.0.1`.
- AI server cannot callback backend in Compose: use
  `AI_CALLBACK_BASE_URL=http://api:3000`.
- Android emulator cannot reach backend: set Flutter API URL to
  `http://10.0.2.2:3000`; leave backend `AI_SERVER_URL` unchanged.
- Real production health is degraded: check DB config, GEE credentials, and
  mounted key path.
