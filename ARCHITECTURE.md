# Spectraal — Speak it. Ship it.

## Architecture & Design Document

**Version:** 1.0  
**Date:** 2026-09-09  
**Author:** Akshay Shitole + Claude (Architect Review)  
**Classification:** Internal  

---

## 1. Vision

Spectraal is a **fully automated software factory** that accepts natural language
requirements and produces a deployed, running application — no human
intervention after the initial input.

```
INPUT:  "Build a ticket management system with login, dashboard,
         role-based access, and PostgreSQL"

OUTPUT: http://localhost:3000  (local)
        https://app-xyz.railway.app  (cloud — future)
```

---

## 2. Core Principles

| # | Principle | Rationale |
|---|-----------|-----------|
| 1 | **Runner-agnostic** | Same pipeline runs on local shell, Jenkins, GitHub Actions, GitLab CI, Tekton |
| 2 | **Fully non-interactive** | Zero human input after requirements are submitted |
| 3 | **Blueprint-driven** | Pre-tested project templates reduce AI hallucination risk |
| 4 | **Sandboxed execution** | AI code generation runs inside Docker containers — safe by design |
| 5 | **Incremental scope** | Start with 3-4 stacks, expand with community blueprints |
| 6 | **Deployment-target pluggable** | Local Docker today, AWS/GCP/Azure tomorrow — same pipeline |

---

## 3. Supported Technology Stacks

### 3.1 Scope Matrix

#### Phase 1 — MVP (Current Build)

| Layer | Technology | Build Tool | Container Base |
|-------|-----------|-----------|----------------|
| **Frontend** | React 19 + Vite + Tailwind CSS | `npm` | `node:22-alpine` |
| **Frontend** | Next.js 15 (App Router) | `npm` | `node:22-alpine` |
| **Backend** | Node.js + Express + Prisma ORM | `npm` | `node:22-alpine` |
| **Database** | PostgreSQL 17 | — | `postgres:17-alpine` |
| **Auth** | JWT + bcrypt (built-in) | — | — |
| **Proxy** | Nginx (reverse proxy) | — | `nginx:alpine` |

#### Phase 2 — Expansion

| Layer | Technology | Build Tool | Container Base |
|-------|-----------|-----------|----------------|
| **Frontend** | Angular 19 | `npm` | `node:22-alpine` |
| **Frontend** | Vue.js 3 + Nuxt | `npm` | `node:22-alpine` |
| **Backend** | Python + FastAPI + SQLAlchemy | `pip` / `uv` | `python:3.12-slim` |
| **Backend** | Java 21 + Spring Boot 3 | `mvn` / `gradle` | `eclipse-temurin:21-jre` |
| **Database** | MongoDB 8 | — | `mongo:8` |
| **Database** | MySQL 9 | — | `mysql:9` |
| **Cache** | Redis 7 | — | `redis:7-alpine` |

#### Phase 3 — Enterprise

| Layer | Technology | Notes |
|-------|-----------|-------|
| **Microservices** | Multi-container with API Gateway | Traefik / Kong |
| **Message Queue** | RabbitMQ / Kafka | Event-driven architectures |
| **Search** | Elasticsearch / Meilisearch | Full-text search requirements |
| **Monitoring** | Prometheus + Grafana | Auto-generated dashboards |
| **CI/CD Gen** | Generate Jenkinsfile / GitHub Actions | Self-deploying apps |

### 3.2 Stack Selection Logic

The AI analyzes requirements and picks the stack using this decision tree:

```
Requirements Input
│
├─ Has "Next.js" / "SSR" / "SEO" mentioned?
│  └─ YES → nextjs-fullstack blueprint
│
├─ Has "Angular" mentioned?
│  └─ YES → angular-node blueprint
│
├─ Has "Spring Boot" / "Java" / "enterprise" mentioned?
│  └─ YES → java-spring blueprint
│
├─ Has "FastAPI" / "Python" / "ML" / "data" mentioned?
│  └─ YES → python-fastapi blueprint
│
├─ Has "microservices" / "multiple services" mentioned?
│  └─ YES → microservices blueprint (Phase 3)
│
├─ Has "MongoDB" / "NoSQL" / "document store" mentioned?
│  └─ YES → [selected-fe]-node-mongo blueprint
│
├─ Has "simple" / "landing" / "static" mentioned?
│  └─ YES → static-html blueprint
│
└─ DEFAULT → react-node-postgres blueprint
     (Most versatile, most reliable generation)
```

---

## 4. Pipeline Architecture

### 4.1 Pipeline Stages

```
┌─────────────────────────────────────────────────────────────────┐
│                     SPECTRAAL PIPELINE (6 Stages)                     │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ STAGE 1  │─▶│ STAGE 2  │─▶│ STAGE 3  │─▶│ STAGE 4  │       │
│  │ ANALYZE  │  │ SCAFFOLD │  │ GENERATE │  │ VALIDATE │       │
│  │          │  │          │  │          │  │          │       │
│  │ Parse    │  │ Copy     │  │ Claude   │  │ Lint     │       │
│  │ require- │  │ blueprint│  │ Code CLI │  │ Build    │       │
│  │ ments    │  │ template │  │ writes   │  │ Test     │       │
│  │ into     │  │ into     │  │ all app  │  │ Fix      │       │
│  │ spec.yml │  │ build/   │  │ code     │  │ loops    │       │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘       │
│                                                                 │
│  ┌──────────┐  ┌──────────┐                                    │
│  │ STAGE 5  │─▶│ STAGE 6  │                                    │
│  │ PACKAGE  │  │ DEPLOY   │                                    │
│  │          │  │          │                                    │
│  │ Docker   │  │ Compose  │                                    │
│  │ build    │  │ up       │                                    │
│  │ images   │  │ Return   │                                    │
│  │          │  │ URL      │                                    │
│  └──────────┘  └──────────┘                                    │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Stage Details

#### Stage 1: ANALYZE (Requirements → Structured Spec)

**Tool:** Claude Code CLI in print mode with JSON schema enforcement

```bash
claude -p \
  --json-schema "$SPEC_SCHEMA" \
  --dangerously-skip-permissions \
  --allowedTools "" \
  "Analyze these requirements and produce a structured spec: $REQUIREMENTS"
```

**Output:** `spec.json`
```json
{
  "project_name": "ticket-manager",
  "description": "Ticket management system with role-based access",
  "stack": {
    "frontend": "react-tailwind",
    "backend": "node-express",
    "database": "postgresql"
  },
  "features": [
    {
      "name": "authentication",
      "type": "auth",
      "details": "JWT-based login with email/password, role-based (admin, agent, user)"
    },
    {
      "name": "ticket-crud",
      "type": "crud",
      "entity": "ticket",
      "fields": ["title", "description", "status", "priority", "assignee"]
    },
    {
      "name": "dashboard",
      "type": "dashboard",
      "widgets": ["ticket-count-by-status", "recent-tickets", "assigned-to-me"]
    }
  ],
  "database_entities": [
    {
      "name": "User",
      "fields": ["id", "email", "password", "role", "name", "createdAt"]
    },
    {
      "name": "Ticket",
      "fields": ["id", "title", "description", "status", "priority", "assigneeId", "creatorId", "createdAt", "updatedAt"]
    }
  ],
  "auth_type": "jwt",
  "estimated_complexity": "medium"
}
```

#### Stage 2: SCAFFOLD (Blueprint → Project Skeleton)

- Copies the matching blueprint template into `builds/{project_name}/`
- Injects `spec.json` values into template placeholders
- Sets up `package.json`, `docker-compose.yml`, `.env`, Prisma schema stub

#### Stage 3: GENERATE (AI Writes the Application Code)

**Tool:** Claude Code CLI — fully non-interactive

```bash
cd builds/ticket-manager

claude -p \
  --dangerously-skip-permissions \
  --allowedTools "Read,Write,Edit,Bash(npm *),Bash(npx *)" \
  --system-prompt "$(cat $SPECTRAAL_ROOT/prompts/generate-app.md)" \
  "Generate the complete application from this spec: $(cat spec.json)

   The project skeleton is already scaffolded in this directory.
   
   RULES:
   - Use ONLY the files and dependencies in the scaffold
   - Implement every feature in spec.json
   - Write working code — no TODOs, no placeholders
   - Include seed data for demo purposes
   - All API routes must handle errors properly
   - Frontend must be responsive and polished"
```

**Key: Why `--dangerously-skip-permissions` is SAFE here:**
- This runs inside a Docker container (Stage 5)
- The container has no network access except to Anthropic API
- The container has no access to host filesystem
- It's literally a sandbox — exactly what this flag is designed for

#### Stage 4: VALIDATE (Build + Test + Self-Heal)

```bash
# Retry loop — AI fixes its own mistakes
MAX_RETRIES=3
for i in $(seq 1 $MAX_RETRIES); do
  npm run build 2>&1 | tee build.log
  if [ $? -eq 0 ]; then break; fi
  
  claude -p \
    --dangerously-skip-permissions \
    --allowedTools "Read,Write,Edit,Bash(npm *)" \
    "The build failed. Fix ALL errors: $(cat build.log)"
done
```

#### Stage 5: PACKAGE (Docker Images)

- Builds Docker images for frontend, backend
- Tags with build ID
- Local: images stay local
- Cloud: pushes to container registry

#### Stage 6: DEPLOY

- Local: `docker compose up -d` → returns `localhost:3000`
- Cloud: pushes to Railway/Render API or applies K8s manifests

---

## 5. Non-Interactive Execution — Deep Analysis

### 5.1 Claude Code CLI Modes for Automation

| Mode | Command | Use Case | Interactive? |
|------|---------|----------|-------------|
| **Print mode** | `claude -p "prompt"` | Single-shot generation | ❌ No |
| **Print + JSON** | `claude -p --json-schema '{...}'` | Structured output (spec gen) | ❌ No |
| **Print + Stream** | `claude -p --output-format stream-json` | Real-time progress | ❌ No |
| **Print + Tools** | `claude -p --allowedTools "Edit,Write,Bash"` | Code generation | ❌ No |
| **Print + Skip Perms** | `claude -p --dangerously-skip-permissions` | Full automation in sandbox | ❌ No |
| **Background agent** | `claude --bg "prompt"` | Long-running builds | ❌ No |
| **Agent SDK** | TypeScript/Python programmatic | Orchestrated multi-step | ❌ No |

### 5.2 Recommended Approach: Layered

```
┌─────────────────────────────────────────────────┐
│            ORCHESTRATOR (shell script)            │
│                                                   │
│  factory.sh — controls the pipeline flow          │
│  • Reads requirements                            │
│  • Calls Claude CLI at each stage                │
│  • Handles retries and error recovery            │
│  • Manages Docker lifecycle                      │
│  • Reports progress                              │
└─────────┬────────────────────────────┬───────────┘
          │                            │
          ▼                            ▼
┌─────────────────┐          ┌─────────────────────┐
│  Claude CLI      │          │  Docker             │
│  (print mode)    │          │  (build + deploy)   │
│                  │          │                     │
│  --dangerously-  │          │  Container sandbox  │
│  skip-permissions│          │  for safe execution │
│  --allowedTools  │          │                     │
│  --json-schema   │          │                     │
└─────────────────┘          └─────────────────────┘
```

### 5.3 Why NOT OpenSpec for V1

| Factor | OpenSpec | Custom spec.json |
|--------|---------|-----------------|
| **Dependency** | External tool to install/maintain | Zero dependencies |
| **Control** | Their lifecycle, their schema | Our schema, our rules |
| **AI compatibility** | AI must learn OpenSpec format | JSON schema — AI knows it natively |
| **Automation** | Requires interactive CLI commands | Pure JSON — fully scriptable |
| **Future** | Can wrap OpenSpec as an input adapter later | Already the native format |

**Decision:** Use a custom `spec.json` schema for V1. OpenSpec can be added as
an optional "input adapter" in Phase 2 — users who have OpenSpec files can
feed them in, and we convert to our internal format.

---

## 6. Runner Portability

### 6.1 Abstraction Layer

The pipeline is a sequence of shell scripts. Each runner just calls them differently:

```
┌──────────────────────────────────────────────────────────┐
│                   PIPELINE DEFINITION                     │
│                                                           │
│  stages:                                                  │
│    - name: analyze                                       │
│      script: scripts/01-analyze.sh                       │
│      inputs: [requirements.txt]                          │
│      outputs: [spec.json]                                │
│                                                           │
│    - name: scaffold                                      │
│      script: scripts/02-scaffold.sh                      │
│      inputs: [spec.json]                                 │
│      outputs: [builds/{project}/]                        │
│                                                           │
│    - name: generate                                      │
│      script: scripts/03-generate.sh                      │
│      inputs: [spec.json, builds/{project}/]              │
│      outputs: [builds/{project}/ (with code)]            │
│                                                           │
│    - name: validate                                      │
│      script: scripts/04-validate.sh                      │
│      inputs: [builds/{project}/]                         │
│      outputs: [build.log, test.log]                      │
│                                                           │
│    - name: package                                       │
│      script: scripts/05-package.sh                       │
│      inputs: [builds/{project}/]                         │
│      outputs: [docker images]                            │
│                                                           │
│    - name: deploy                                        │
│      script: scripts/06-deploy.sh                        │
│      inputs: [docker images, deploy-target.yaml]         │
│      outputs: [deployed-url.txt]                         │
│                                                           │
│  Each script is self-contained. Runners just execute      │
│  them in order. Failures are exit codes.                  │
└──────────────────────────────────────────────────────────┘
```

### 6.2 Runner Adapters

#### Local (Shell — Default)

```bash
# factory.sh just runs scripts in sequence
./scripts/01-analyze.sh "$REQUIREMENTS"
./scripts/02-scaffold.sh
./scripts/03-generate.sh
./scripts/04-validate.sh
./scripts/05-package.sh
./scripts/06-deploy.sh local
echo "App deployed at $(cat deployed-url.txt)"
```

#### Jenkins

```groovy
// Jenkinsfile — auto-generated or hand-maintained
pipeline {
    agent { docker { image 'spectraal-runner:latest' } }
    
    parameters {
        text(name: 'REQUIREMENTS', description: 'App requirements')
    }
    
    stages {
        stage('Analyze')  { steps { sh './scripts/01-analyze.sh "${REQUIREMENTS}"' } }
        stage('Scaffold') { steps { sh './scripts/02-scaffold.sh' } }
        stage('Generate') { steps { sh './scripts/03-generate.sh' } }
        stage('Validate') { steps { sh './scripts/04-validate.sh' } }
        stage('Package')  { steps { sh './scripts/05-package.sh' } }
        stage('Deploy')   { steps { sh './scripts/06-deploy.sh cloud' } }
    }
    
    post {
        success { echo "Deployed: ${readFile('deployed-url.txt')}" }
    }
}
```

#### GitHub Actions

```yaml
# .github/workflows/sdd-build.yml
name: Spectraal Build
on:
  workflow_dispatch:
    inputs:
      requirements:
        description: 'Application requirements'
        required: true
        type: string

jobs:
  build:
    runs-on: ubuntu-latest
    container: spectraal-runner:latest
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/01-analyze.sh "${{ inputs.requirements }}"
      - run: ./scripts/02-scaffold.sh
      - run: ./scripts/03-generate.sh
      - run: ./scripts/04-validate.sh
      - run: ./scripts/05-package.sh
      - run: ./scripts/06-deploy.sh cloud
      - run: echo "::notice::Deployed at $(cat deployed-url.txt)"
    env:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

#### GitLab CI

```yaml
# .gitlab-ci.yml
stages: [analyze, scaffold, generate, validate, package, deploy]

analyze:
  stage: analyze
  script: ./scripts/01-analyze.sh "$REQUIREMENTS"
  artifacts:
    paths: [spec.json]

# ... same pattern for each stage
```

### 6.3 Spectraal Runner Docker Image

All runners use the same base image:

```dockerfile
# Dockerfile.runner
FROM node:22-alpine

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Install build tools
RUN apk add --no-cache \
    docker-cli \
    docker-compose \
    python3 \
    py3-pip \
    openjdk21-jre \
    maven \
    git \
    curl \
    jq

# Copy Spectraal framework
COPY blueprints/ /sdd/blueprints/
COPY prompts/ /sdd/prompts/
COPY scripts/ /sdd/scripts/
COPY config.yaml /sdd/config.yaml

WORKDIR /sdd
ENTRYPOINT ["./scripts/factory.sh"]
```

---

## 7. Deployment Targets

### 7.1 Pluggable Deploy Adapters

```
┌────────────────────────────────────────────────────┐
│  deploy-target.yaml                                 │
│                                                     │
│  target: local          # or: railway, aws, gcp,   │
│                         #     azure, render         │
│  config:                                            │
│    # Local                                          │
│    port_frontend: 3000                              │
│    port_backend: 3001                               │
│    port_db: 5432                                    │
│                                                     │
│    # Cloud (future)                                 │
│    # provider: aws                                  │
│    # region: us-east-1                              │
│    # credentials_secret: AWS_CREDENTIALS            │
│    # cluster: my-ecs-cluster                        │
└────────────────────────────────────────────────────┘
```

### 7.2 Deployment Flow per Target

| Target | How It Works | URL Format |
|--------|-------------|------------|
| **Local** | `docker compose up -d` | `http://localhost:3000` |
| **Railway** | `railway up` via API | `https://app-xyz.up.railway.app` |
| **Render** | Push to Render via API | `https://app-xyz.onrender.com` |
| **AWS ECS** | Build image → push ECR → update ECS service | Custom domain or ALB URL |
| **AWS EKS** | Build image → push ECR → apply K8s manifests | Ingress URL |
| **GCP Cloud Run** | Build image → push GCR → deploy service | `https://app-xyz-abc.run.app` |
| **Azure AKS** | Build image → push ACR → apply K8s manifests | Ingress URL |

---

## 8. Security Model

### 8.1 AI Sandbox

```
┌──────────────────────────────────────────────────────────┐
│  HOST SYSTEM (your MacBook)                               │
│                                                           │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  DOCKER CONTAINER (sandbox)                          │ │
│  │                                                      │ │
│  │  • Claude CLI runs HERE with --dangerously-skip-     │ │
│  │    permissions (safe — it's sandboxed)                │ │
│  │                                                      │ │
│  │  • Network: ONLY outbound to api.anthropic.com       │ │
│  │  • Filesystem: ONLY /workspace (ephemeral)           │ │
│  │  • No access to host files, secrets, or network      │ │
│  │                                                      │ │
│  │  ┌────────────────────┐                              │ │
│  │  │  /workspace/       │  Generated code lives here   │ │
│  │  │  ├── frontend/     │  Destroyed after build       │ │
│  │  │  ├── backend/      │  unless explicitly exported  │ │
│  │  │  └── spec.json     │                              │ │
│  │  └────────────────────┘                              │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                           │
│  Only the final Docker images and docker-compose.yml      │
│  leave the sandbox → deployed to target                   │
└──────────────────────────────────────────────────────────┘
```

### 8.2 Secrets Management

| Secret | Where Stored | How Accessed |
|--------|-------------|-------------|
| `ANTHROPIC_API_KEY` | Host env / CI secret | Passed to build container |
| DB passwords | Auto-generated per build | Written to `.env`, never hardcoded |
| Cloud credentials | CI secrets / env vars | Injected at deploy stage only |
| JWT secret | Auto-generated per build | Written to `.env` |

---

## 9. Risk Analysis & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| AI generates broken code | High (early) | Medium | Stage 4 retry loop (3 attempts), blueprint constraints |
| AI installs malicious packages | Low | High | Allowlisted dependencies in blueprints, network sandbox |
| Build takes too long | Medium | Low | Timeout per stage (15 min), cancel + report |
| Generated app has security holes | Medium | High | Automated SAST scan in Stage 4, auth blueprint is pre-tested |
| Docker resource exhaustion | Low | Medium | Resource limits per container (2 CPU, 4GB RAM) |
| Claude API rate limits | Medium | Medium | Retry with backoff, queue builds |
| Spec misinterprets requirements | Medium | Medium | Structured JSON schema forces explicit fields |

---

## 10. Phased Roadmap

### Phase 1 — Foundation (Week 1-2) ← START HERE

- [ ] Project structure and config
- [ ] `factory.sh` orchestrator script
- [ ] Stage 1: Analyze (Claude CLI + JSON schema → spec.json)
- [ ] Stage 2: Scaffold (copy blueprint, inject spec values)
- [ ] Blueprint: `react-node-postgres` (the default stack)
- [ ] Stage 3: Generate (Claude CLI writes code)
- [ ] Stage 4: Validate (build + test + retry loop)
- [ ] Stage 5: Package (Docker build)
- [ ] Stage 6: Deploy local (docker compose up)
- [ ] End-to-end test: requirements in → localhost URL out

### Phase 2 — More Stacks (Week 3-4)

- [ ] Blueprint: `nextjs-fullstack`
- [ ] Blueprint: `python-fastapi-postgres`
- [ ] Blueprint: `java-spring-postgres`
- [ ] Blueprint: `react-node-mongodb`
- [ ] OpenSpec input adapter (optional)
- [ ] Progress streaming (WebSocket/SSE)

### Phase 3 — Cloud Deployment (Week 5-6)

- [ ] Deploy adapter: Railway
- [ ] Deploy adapter: Render
- [ ] Deploy adapter: AWS ECS
- [ ] Deploy adapter: GCP Cloud Run
- [ ] Cloud credentials management
- [ ] Custom domain support

### Phase 4 — Enterprise Features (Week 7-8)

- [ ] Web UI (frontend for submitting requirements)
- [ ] Build history and logs
- [ ] Microservices blueprint
- [ ] Jenkins runner adapter
- [ ] GitHub Actions runner adapter
- [ ] Monitoring + alerting on deployed apps

---

## 11. Folder Structure (Final)

```
sdd/
├── ARCHITECTURE.md              ← This document
├── config.yaml                  ← Global configuration
├── factory.sh                   ← Main entry point
│
├── blueprints/                  ← Project templates
│   ├── _base/                   ← Shared configs (Dockerfile, .dockerignore, etc.)
│   ├── react-node-postgres/     ← Phase 1 default
│   │   ├── frontend/            ← React + Vite + Tailwind skeleton
│   │   ├── backend/             ← Express + Prisma skeleton
│   │   ├── docker-compose.yml   ← Pre-wired compose file
│   │   ├── blueprint.yaml       ← Blueprint metadata
│   │   └── .env.template        ← Environment variable template
│   ├── nextjs-fullstack/        ← Phase 2
│   ├── python-fastapi-postgres/ ← Phase 2
│   ├── java-spring-postgres/    ← Phase 2
│   └── react-node-mongodb/      ← Phase 2
│
├── prompts/                     ← AI instruction templates
│   ├── 01-analyze.md            ← Requirements → spec.json
│   ├── 03-generate-frontend.md  ← Frontend code generation
│   ├── 03-generate-backend.md   ← Backend code generation
│   ├── 03-generate-database.md  ← Schema + seed generation
│   ├── 03-wire-together.md      ← Connect FE ↔ BE ↔ DB
│   └── 04-fix-errors.md         ← Self-healing prompt
│
├── schemas/                     ← JSON schemas
│   └── spec.schema.json         ← Enforced output format for Stage 1
│
├── scripts/                     ← Pipeline stage scripts
│   ├── 01-analyze.sh
│   ├── 02-scaffold.sh
│   ├── 03-generate.sh
│   ├── 04-validate.sh
│   ├── 05-package.sh
│   ├── 06-deploy.sh
│   └── lib/                     ← Shared functions
│       ├── logging.sh
│       ├── docker-utils.sh
│       └── claude-utils.sh
│
├── runners/                     ← CI/CD adapters
│   ├── Jenkinsfile
│   ├── github-actions.yml
│   ├── gitlab-ci.yml
│   └── Dockerfile.runner        ← Self-contained runner image
│
├── deployers/                   ← Deployment target adapters
│   ├── local.sh
│   ├── railway.sh
│   ├── render.sh
│   ├── aws-ecs.sh
│   └── gcp-cloudrun.sh
│
└── builds/                      ← Generated projects (gitignored)
    └── {project-name}/
        ├── frontend/
        ├── backend/
        ├── spec.json
        ├── docker-compose.yml
        ├── .env
        └── build.log
```

---

## 12. Key Technical Decisions Summary

| Decision | Choice | Why |
|----------|--------|-----|
| AI Agent | Claude Code CLI (`claude -p`) | Best autonomous code gen, non-interactive mode, JSON schema output |
| Skip OpenSpec for V1 | Custom `spec.json` | Zero dependencies, fully scriptable, AI-native |
| Execution | Shell scripts per stage | Universal — works in any runner |
| Sandbox | Docker containers | Safe to run `--dangerously-skip-permissions` |
| Default stack | React + Node + PostgreSQL | Most versatile, highest AI generation quality |
| Pipeline format | Simple YAML + shell scripts | Jenkins/GitHub/GitLab/local all use same scripts |
| Local deploy | Docker Compose | Zero cloud cost, instant startup |
| Cloud deploy (future) | Railway API first | Simplest API, free tier, no K8s needed |

---

## 13. How to Run (Target UX)

```bash
# One command. That's it.
./factory.sh "Build a customer support portal with:
  - User registration and login
  - Ticket submission with priority and category
  - Admin dashboard with ticket stats
  - Agent assignment and status tracking
  - Email notifications on status change
  - PostgreSQL database
  - Responsive design"

# Output:
# ╔═══════════════════════════════════════════════════╗
# ║  Spectraal — Build Complete            ║
# ╠═══════════════════════════════════════════════════╣
# ║                                                   ║
# ║  Project: customer-support-portal                 ║
# ║  Stack:   React + Express + PostgreSQL             ║
# ║                                                   ║
# ║  🌐 Frontend:  http://localhost:3000              ║
# ║  🔌 API:       http://localhost:3001              ║
# ║  🗄️  Database:  localhost:5432                     ║
# ║                                                   ║
# ║  👤 Admin Login:                                  ║
# ║     Email:    admin@demo.com                      ║
# ║     Password: demo123                             ║
# ║                                                   ║
# ║  📁 Code: builds/customer-support-portal/         ║
# ║  📋 Logs: builds/customer-support-portal/build.log║
# ║                                                   ║
# ╚═══════════════════════════════════════════════════╝
```

---

*This document will evolve as implementation progresses.*
