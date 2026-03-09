# Relay Backend

FastAPI service that acts as a relay between clients (iOS, web) and AI agents. Handles WebSocket connections, LLM routing, speech-to-text, text-to-speech, and session persistence.

---

## Stack

| Component | Technology |
|---|---|
| Framework | FastAPI 0.115 + Uvicorn |
| Database | PostgreSQL 16 (async via SQLAlchemy + asyncpg) |
| Cache | Redis 7 |
| LLM providers | OpenAI, Anthropic, Google Gemini |
| STT providers | OpenAI Whisper, ElevenLabs Scribe |
| TTS providers | OpenAI TTS, ElevenLabs |
| Auth | Single-user JWT (HS256, 7-day tokens) |

---

## Environment Variables

All variables are read from the environment or a `.env` file in the **project root** (one level above `backend/`). Pydantic Settings handles loading.

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `postgresql+asyncpg://hub:hub_dev_password@localhost:5432/hub` | Async PostgreSQL connection string |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection string |
| `ENVIRONMENT` | `development` | Runtime environment label (`development` / `production`) |
| `OPENAI_API_KEY` | _(empty)_ | Required for OpenAI LLM and TTS |
| `ANTHROPIC_API_KEY` | _(empty)_ | Required for Anthropic (Claude) LLM |
| `GEMINI_API_KEY` | _(empty)_ | Required for Google Gemini LLM |
| `ELEVENLABS_API_KEY` | _(empty)_ | Required for ElevenLabs STT/TTS |
| `OPERATOR_MODEL` | `gpt-4o-mini` | LLM model used by the Operator routing agent |
| `AUTH_USERNAME` | `admin` | Login username |
| `AUTH_PASSWORD` | `changeme` | Login password (bcrypt-hashed at startup) |
| `AUTH_JWT_SECRET` | `relay-dev-secret-change-in-production` | HMAC secret for signing JWTs — **must be changed in production** |

---

## Development

The recommended dev setup runs the full stack (postgres, redis, backend, frontend) via Docker Compose from the **project root**.

### Prerequisites

- Docker Desktop (or Docker Engine + Compose plugin)
- API keys for any LLM/STT/TTS providers you intend to use

### 1. Create a `.env` file in the project root

```bash
# Project root: relay/.env
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GEMINI_API_KEY=AIza...
ELEVENLABS_API_KEY=...

# Optional overrides (defaults shown)
AUTH_USERNAME=admin
AUTH_PASSWORD=changeme
AUTH_JWT_SECRET=relay-dev-secret-change-in-production
OPERATOR_MODEL=gpt-4o-mini
```

Only set the keys for providers you actually need. Agents that reference a missing key will show as unhealthy but won't crash the service.

### 2. Start the stack

```bash
# From the project root (relay/)
docker compose up -d --build
```

Services start in dependency order: postgres and redis come up first (with healthchecks), then the backend, then the frontend.

| Service | URL |
|---|---|
| Backend API | http://localhost:8000 |
| API docs (Swagger) | http://localhost:8000/docs |
| Frontend | http://localhost:5173 |

### 3. Verify

```bash
curl http://localhost:8000/health
# → {"status":"ok"}
```

### Hot reload

The dev Dockerfile runs Uvicorn with `--reload`. The `backend/app/` directory is bind-mounted into the container (`./backend/app:/app/app` in `docker-compose.yml`), so any change to a Python file under `backend/app/` restarts the server automatically — no rebuild needed.

For changes to `requirements.txt` or the Dockerfile itself, rebuild:

```bash
docker compose up -d --build backend
```

### Logs

```bash
docker logs -f relay-backend-1
```

### Restart backend only

```bash
docker restart relay-backend-1
```

### Database

On first startup the backend automatically:

1. Creates all tables via SQLAlchemy `create_all`
2. Seeds four default agents: **Operator**, **Vanto**, **Gemini**, **Claude**
3. Seeds default platform settings (STT provider = `openai`)

Seeding is idempotent — it only runs if the agents table is empty.

The postgres data lives in a Docker named volume (`relay_pgdata`). It persists across `docker compose down` and restarts. To wipe it:

```bash
docker compose down -v   # removes relay_pgdata
```

---

## Production

### Key differences from dev

| Concern | Dev | Production |
|---|---|---|
| Uvicorn reload | `--reload` (enabled) | Remove `--reload` |
| CORS | `allow_origins=["*"]` | Restrict to your actual client origins |
| JWT secret | Weak placeholder | Strong random secret (32+ bytes) |
| Auth credentials | `admin` / `changeme` | Strong unique credentials |
| TLS | None | Terminate at reverse proxy |
| Postgres | Containerised on same host | Managed DB (RDS, Supabase, etc.) recommended |

### 1. Build a production image

Create a separate Dockerfile or override the CMD to remove `--reload`:

```dockerfile
# In backend/Dockerfile, change the last line for production:
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

Alternatively, override the command in your production compose file:

```yaml
backend:
  build: ./backend
  command: uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1
```

`--workers 1` is recommended until the in-memory operator state is made Redis-backed. Multiple workers will not share WebSocket session state.

### 2. Set production environment variables

```bash
ENVIRONMENT=production
AUTH_USERNAME=<strong-username>
AUTH_PASSWORD=<strong-password>
AUTH_JWT_SECRET=<random-64-char-string>   # e.g. openssl rand -hex 32
DATABASE_URL=postgresql+asyncpg://<user>:<pass>@<host>:5432/<db>
REDIS_URL=redis://<host>:6379/0
OPENAI_API_KEY=...
ANTHROPIC_API_KEY=...
GEMINI_API_KEY=...
ELEVENLABS_API_KEY=...
```

Never commit these values. Inject them via your deployment platform's secrets manager (Fly.io secrets, AWS Secrets Manager, Docker Swarm secrets, etc.).

### 3. Reverse proxy + TLS

Run the backend behind Nginx, Caddy, or Traefik to handle TLS and forward traffic to port 8000. WebSocket upgrade headers must be proxied correctly.

**Nginx example:**

```nginx
location /v1/lobby {
    proxy_pass http://backend:8000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
}

location / {
    proxy_pass http://backend:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

### 4. Restrict CORS

`main.py` currently allows all origins. In production, update the middleware:

```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://your-frontend-domain.com"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

### 5. Database migrations

The backend uses `Base.metadata.create_all` on startup (not Alembic migrations). New columns are added with `ALTER TABLE … ADD COLUMN IF NOT EXISTS` statements in the lifespan handler. This is fine for a single-instance deployment but means:

- Dropping or renaming columns requires a manual migration
- Alembic is installed (`alembic==1.14.1`) if you want to formalise migrations later

---

## API Overview

All endpoints require a `Bearer <token>` header except `/v1/auth/login` and `/health`.

| Method | Path | Description |
|---|---|---|
| `POST` | `/v1/auth/login` | Exchange credentials for a JWT |
| `GET` | `/v1/auth/me` | Verify token, returns username |
| `GET` | `/v1/agents` | List all agents |
| `POST` | `/v1/agents` | Create an agent |
| `PUT` | `/v1/agents/{id}` | Update an agent |
| `DELETE` | `/v1/agents/{id}` | Delete an agent |
| `GET` | `/v1/sessions` | List sessions |
| `GET` | `/v1/sessions/{id}/messages` | Get session message history |
| `GET` | `/v1/platform` | Get platform settings |
| `PUT` | `/v1/platform/{key}` | Update a platform setting |
| `WS` | `/v1/lobby?token=<jwt>` | Main WebSocket connection |
| `GET` | `/health` | Health check (no auth) |

Full interactive docs at `http://localhost:8000/docs` when running.

---

## Project Structure

```
backend/
├── Dockerfile
├── requirements.txt
└── app/
    ├── main.py              # App setup, lifespan, seed data
    ├── config.py            # Pydantic Settings
    ├── models/              # SQLAlchemy ORM models
    │   ├── agent.py
    │   ├── session.py
    │   ├── message.py
    │   └── platform_setting.py
    ├── db/
    │   ├── database.py      # Async engine + session factory
    │   └── redis.py         # Redis connection
    ├── api/
    │   ├── auth.py          # JWT login endpoints
    │   ├── agents.py        # Agent CRUD
    │   ├── sessions.py      # Session history
    │   ├── platform.py      # Platform settings
    │   └── websocket.py     # /v1/lobby WebSocket handler
    └── services/
        ├── operator.py      # Routing logic (lobby agent)
        ├── agent_manager.py # Per-agent response generation
        ├── agent_health.py  # Provider health checks
        ├── conversation_manager.py
        ├── llm/             # anthropic.py, openai.py, gemini.py, openclaw.py
        ├── stt/             # elevenlabs.py, openai.py
        └── tts/             # elevenlabs.py, openai.py
```
