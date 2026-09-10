<p align="center">
  <img src="https://img.shields.io/badge/Spectraal-Speak%20it.%20Ship%20it.-blueviolet?style=for-the-badge&logo=rocket" alt="Spectraal Badge" />
</p>

<h1 align="center">🚀 SPECTRAAL</h1>

<p align="center">
  <strong>Speak it. Ship it.</strong><br/>
  Natural language → Deployed application. Zero human intervention.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/bash-3.2%2B-green?style=flat-square" />
  <img src="https://img.shields.io/badge/docker-required-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/claude-CLI-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square" />
</p>

---

## What is Spectraal?

Spectraal is a fully automated software delivery pipeline that takes **natural language requirements** and outputs a **deployed, running application** — with zero human intervention.

You describe what you want in plain English. Spectraal handles everything: specification writing, architecture design, code generation, validation, linting, packaging, security scanning, deployment, testing, and self-repair.

```bash
./jarvis "Build a task management app with login, dashboard, and team collaboration"
```

☝️ That's it. A few minutes later, your app is live at `http://localhost:<port>`.

---

## ✨ Features

### 🧠 SpecPilot — AI Specification Engine

A 5-stage specification pipeline that transforms vague requirements into precise, validated specs:

| Stage | Name | Output |
|-------|------|--------|
| 0 | **PRD Writer** | Product Requirements Document (`prd.json`) |
| 1 | **Architect** | System architecture, data models, API contracts (`architecture.json`) |
| 2 | **UI Designer** | Pages, components, navigation, theme (`ui-spec.json`) |
| 3 | **Task Planner** | Implementation tasks with dependencies (`tasks.json`) |
| 4 | **Validator** | Cross-document validation with traceability matrix (`validation.json`) |

### 🎨 Design Archetypes

Every app gets a **domain-adaptive design** — not just color swaps:

| Archetype | Domains | Layout | Login Style |
|-----------|---------|--------|-------------|
| **DASHBOARD** | Government, analytics, IoT | Top nav, full-width | Centered institutional |
| **SAAS** | CRM, HR, project mgmt | Dark sidebar | Split-screen branding |
| **CONSUMER** | Games, social, fitness | Minimal/no nav | Centered playful |
| **MARKETPLACE** | E-commerce, food, travel | Top nav + search | Modal/minimal |
| **CLINICAL** | Healthcare, pharmacy | Muted sidebar | Centered, calm |

### ⚡ 10-Stage Build Pipeline

Fully automated from spec to deployment:

| Stage | Name | What It Does |
|-------|------|-------------|
| 1 | 🔍 **Analyze** | Parses requirements, generates `spec.json` |
| 2 | 🏗️ **Scaffold** | Copies blueprint, injects config, assigns ports |
| 3 | ⚡ **Generate** | Claude writes the full application code |
| 4 | 🔨 **Validate** | Syntax checks, import validation, TypeScript verify |
| 5 | 🧹 **Lint** | ESLint + auto-fix *(runs parallel with Package)* |
| 6 | 📦 **Package** | Docker build with BuildKit cache *(runs parallel with Lint)* |
| 7 | 🛡️ **Scan** | Security vulnerability scanning |
| 8 | 🚀 **Deploy** | Docker Compose up with health checks & rollback |
| 9 | 🧪 **Test** | Smoke tests against live endpoints |
| 10 | 🔧 **Repair** | Auto-fix failures and redeploy (self-healing loop) |

### 🏎️ Performance Optimizations

- **Docker BuildKit cache mounts** — npm installs cached across builds
- **Parallel stages** — Lint and Package run simultaneously
- **Prebuilt image reuse** — Deploy uses images from Package stage, no rebuild
- **Retry logic** — All Claude CLI calls retry up to 2× with error capture

### 📊 Cost & Token Tracking

Every Claude API call is tracked — input/output tokens, cost per stage, model used. A cost summary prints at the end of each build with a per-stage breakdown.

### 🎭 Stack Profiles

Three deployment profiles to match your needs:

| Profile | What's Included | Use Case |
|---------|----------------|----------|
| `full-stack` | React + Node + PostgreSQL + Auth | Complete apps with database |
| `frontend-only` | React + minimal backend (no DB) | Dashboards, mock-data apps |
| `static` | React only (no backend at all) | Landing pages, static sites |

---

## 📋 Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| **Bash** | 3.2+ | ✅ macOS default works |
| **Docker Desktop** | Latest | [docker.com/get-started](https://docker.com/get-started) |
| **Claude CLI** | Latest | `npm install -g @anthropic-ai/claude-code` |
| **jq** | 1.6+ | `brew install jq` |
| **Node.js** | 18+ | `brew install node` |

You also need an `ANTHROPIC_API_KEY` environment variable set.

---

## 🚀 Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/akshayy-ai/Spectraal.git
cd Spectraal
```

### 2. Make sure Docker is running

```bash
docker info > /dev/null 2>&1 && echo "✅ Docker is running" || echo "❌ Start Docker Desktop"
```

### 3. Build your first app

```bash
./jarvis "Build a todo app with user authentication and a clean dashboard"
```

### 4. Open it

The CLI prints the URL when done (e.g., `http://localhost:3008`). Default login: `admin@demo.com / demo123`

---

## 📖 Usage

### Basic Usage

```bash
# Simple — just describe what you want
./jarvis "Build a weather dashboard with city search and 5-day forecast"

# From a requirements file
./jarvis -f requirements.txt

# Frontend-only (no database, mock data)
./jarvis "Build an analytics dashboard with charts" --profile frontend-only

# Strict mode — abort on spec validation failures
./jarvis "Build a CRM" --strict

# Skip SpecPilot (faster, less precise specs)
./jarvis "Build a blog" --no-specpilot

# Skip specific stages
./jarvis "Build a chat app" --skip 5,7

# Deploy to Railway (coming soon)
./jarvis -t railway "Build a SaaS app"
```

### CLI Options

| Flag | Description |
|------|-------------|
| `-f, --file FILE` | Read requirements from a file |
| `-t, --target TARGET` | Deploy target: `local` (default), `railway`, `aws-ecs`, `gcp-cloudrun` |
| `--profile PROFILE` | Stack profile: `full-stack` (default), `frontend-only`, `static` |
| `--skip STAGES` | Comma-separated stages to skip (e.g., `--skip 5,7`) |
| `--strict` | Abort if SpecPilot finds critical issues |
| `--no-specpilot` | Skip the 5-stage spec pipeline |
| `-h, --help` | Show help |

### Managing Deployed Apps

```bash
# View logs
docker compose -p <project-name> logs -f

# Stop an app
docker compose -p <project-name> down

# Restart
docker compose -p <project-name> restart

# Database shell (full-stack only)
docker exec -it <project-name>-db psql -U postgres
```

---

## 🏗️ Architecture

```
spectraal/
├── jarvis                    # 🎯 Main CLI entry point
├── config.yaml               # ⚙️ Configuration
├── specpilot/                # 🧠 AI Spec Engine
│   ├── scripts/              #    Stage scripts (00-04)
│   ├── prompts/              #    Claude prompts per stage
│   └── schemas/              #    JSON schemas for validation
├── scripts/                  # ⚡ Build Pipeline
│   ├── 01-analyze.sh         #    Parse requirements → spec.json
│   ├── 02-scaffold.sh        #    Blueprint → project skeleton
│   ├── 03-generate.sh        #    Claude writes the app code
│   ├── 04-validate.sh        #    Syntax & import checks
│   ├── 05-lint.sh            #    ESLint + auto-fix
│   ├── 06-package.sh         #    Docker build (BuildKit)
│   ├── 07-scan.sh            #    Security scan
│   ├── 08-deploy.sh          #    Docker Compose deploy
│   ├── 09-test.sh            #    Smoke tests
│   ├── 10-repair.sh          #    Self-healing repair loop
│   └── lib/                  #    Shared utilities
│       ├── logging.sh        #    CLI output (banners, progress bars)
│       ├── claude-utils.sh   #    Claude CLI helpers
│       ├── cost-tracker.sh   #    Token & cost tracking
│       └── docker-utils.sh   #    Port finding, health checks
├── blueprints/               # 📦 Project Templates
│   └── react-node-postgres/  #    Default full-stack blueprint
│       ├── frontend/         #    React + Vite + Tailwind
│       ├── backend/          #    Node + Express + Prisma
│       └── docker-compose.yml
├── prompts/                  # 📝 Build pipeline prompts
├── schemas/                  # 📐 JSON schemas
└── runners/                  # 🔄 CI/CD templates
    ├── github-actions.yml
    ├── Jenkinsfile
    └── Dockerfile.runner
```

### How It Works

```
                    "Build me a task manager"
                              │
                    ┌─────────▼──────────┐
                    │   📝 SpecPilot     │
                    │   (5 AI stages)    │
                    │                    │
                    │  PRD → Arch → UI   │
                    │  → Tasks → Valid   │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │  🔍 Analyze        │
                    │  spec.json         │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │  🏗️ Scaffold       │
                    │  Project skeleton  │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │  ⚡ Generate       │
                    │  Full app code     │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │  🔨 Validate       │
                    └─────────┬──────────┘
                              │
                 ┌────────────┴────────────┐
                 │                         │
        ┌────────▼────────┐     ┌──────────▼────────┐
        │  🧹 Lint        │     │  📦 Package       │
        │  (parallel)     │     │  (parallel)       │
        └────────┬────────┘     └──────────┬────────┘
                 │                         │
                 └────────────┬────────────┘
                              │
              ┌───────────────▼───────────────┐
              │  🛡️ Scan → 🚀 Deploy → 🧪 Test │
              └───────────────┬───────────────┘
                              │
                    ┌─────────▼──────────┐
                    │  🔧 Repair         │
                    │  (if needed)       │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │  ✅ DEPLOYED!      │
                    │  http://localhost   │
                    └────────────────────┘
```

---

## 💡 Examples

### Full-Stack App
```bash
./jarvis "Build an employee management system with departments, roles, 
leave tracking, and an admin dashboard with charts"
```

### Frontend-Only Dashboard
```bash
./jarvis "Build an LLM observability dashboard showing model performance, 
token usage charts, and cost tracking with mock data" --profile frontend-only
```

### Quick Prototype
```bash
./jarvis "Build a kanban board with drag-and-drop columns" --no-specpilot
```

### From Requirements File
```bash
cat > requirements.txt << 'EOF'
Build a food delivery tracking app called FoodDash:
- Real-time order status with animated delivery map
- Restaurant menu browser with categories and search
- Shopping cart with add/remove/quantity controls
- Order history with ratings
- Estimated delivery countdown
- Driver info card
EOF

./jarvis -f requirements.txt
```

---

## 🔄 Running in CI/CD

### GitHub Actions
Copy `runners/github-actions.yml` to `.github/workflows/`. Requires:
- `ANTHROPIC_API_KEY` repository secret

### Jenkins
Copy `runners/Jenkinsfile` to your Jenkins pipeline. Requires:
- Docker access on the build agent
- `ANTHROPIC_API_KEY` credential

### Docker Runner (any CI)
```bash
docker build -t spectraal-runner -f runners/Dockerfile.runner .
docker run -v /var/run/docker.sock:/var/run/docker.sock \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  spectraal-runner "Build a project management tool"
```

---

## 🛠️ Troubleshooting

| Issue | Fix |
|-------|-----|
| `Docker daemon not running` | Start Docker Desktop |
| `Claude CLI not found` | `npm install -g @anthropic-ai/claude-code` |
| `Port already in use` | Pipeline auto-finds free ports. Stop old apps: `docker compose -p <name> down` |
| `SpecPilot stage fails` | Usually transient — retries automatically. Check `specs/*-stderr.log` |
| `Package stage fails` | Check Docker build logs. Common: missing dependency in `package.json` |
| `jq not found` | `brew install jq` (macOS) or `apt install jq` (Linux) |

---

## 🗺️ Roadmap

- [x] Local Docker deployment
- [x] SpecPilot 5-stage spec engine
- [x] Docker BuildKit caching
- [x] Parallel pipeline stages (Lint ∥ Package)
- [x] Cost & token tracking
- [x] Self-healing repair loop (Stage 10)
- [x] Stack profiles (full-stack / frontend-only / static)
- [x] Design archetypes (SAAS, Dashboard, Consumer, etc.)
- [ ] Cloud deployment (Railway, AWS ECS, GCP Cloud Run)
- [ ] Additional blueprints (Next.js, Python/FastAPI, static)
- [ ] Pipeline dashboard UI
- [ ] Multi-language support
- [ ] Plugin system for custom stages

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <strong>Spectraal</strong> — Speak it. Ship it. 🚀
</p>
