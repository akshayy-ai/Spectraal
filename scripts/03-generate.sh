#!/usr/bin/env bash
# Spectraal — Stage 3: Generate Application Code
# ===========================================================
# Input:  $PROJECT_DIR with scaffolded skeleton + spec.json
# Output: $PROJECT_DIR with fully generated application code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true

log_step "3" "GENERATE APPLICATION CODE"

PROJECT_DIR="${1:?Usage: 03-generate.sh /path/to/project}"
SPECTRAAL_ROOT="$(get_sdd_root)"

if [ ! -f "$PROJECT_DIR/spec.json" ]; then
  log_error "spec.json not found in $PROJECT_DIR"
  exit 1
fi

SPEC=$(cat "$PROJECT_DIR/spec.json")
PROJECT_NAME=$(echo "$SPEC" | jq -r '.project_name')

# Select the right generation prompt based on blueprint
BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")

if [[ "$BLUEPRINT" == react-python-* ]]; then
  SYSTEM_PROMPT=$(cat "$SPECTRAAL_ROOT/prompts/03-generate-python.md")
  IS_PYTHON_BACKEND=true
  log_info "Blueprint: $BLUEPRINT (Python FastAPI backend)"
else
  SYSTEM_PROMPT=$(cat "$SPECTRAAL_ROOT/prompts/03-generate-app.md")
  IS_PYTHON_BACKEND=false
  log_info "Blueprint: $BLUEPRINT (Node.js backend)"
fi

log_info "Generating code for: $PROJECT_NAME"
log_info "Working directory: $PROJECT_DIR"

# ── Check for SpecPilot documents ──────────────────────────────
BUILD_DIR="$(dirname "$PROJECT_DIR")"
SPECS_DIR="$BUILD_DIR/specs"
HAS_SPECPILOT=false

SPECPILOT_CONTEXT=""
if [[ -f "$SPECS_DIR/prd.json" ]] && [[ -f "$SPECS_DIR/architecture.json" ]] && \
   [[ -f "$SPECS_DIR/ui-spec.json" ]] && [[ -f "$SPECS_DIR/tasks.json" ]]; then
  HAS_SPECPILOT=true
  log_info "SpecPilot documents detected — using structured specs for generation"

  # Copy SpecPilot docs into project for Claude to read
  mkdir -p "$PROJECT_DIR/specs"
  cp "$SPECS_DIR/prd.json" "$PROJECT_DIR/specs/"
  cp "$SPECS_DIR/architecture.json" "$PROJECT_DIR/specs/"
  cp "$SPECS_DIR/ui-spec.json" "$PROJECT_DIR/specs/"
  cp "$SPECS_DIR/tasks.json" "$PROJECT_DIR/specs/"
  [[ -f "$SPECS_DIR/validation.json" ]] && cp "$SPECS_DIR/validation.json" "$PROJECT_DIR/specs/"
  [[ -f "$SPECS_DIR/validation-notes.md" ]] && cp "$SPECS_DIR/validation-notes.md" "$PROJECT_DIR/specs/"

  SPECPILOT_CONTEXT="
## SpecPilot Structured Specifications

You have DETAILED structured specifications in the specs/ directory. READ THEM before writing any code:

1. **specs/prd.json** — Product Requirements Document with user stories (US-xxx) and formal requirements (REQ-xxx) including GIVEN/WHEN/THEN scenarios
2. **specs/architecture.json** — Complete data model (entities, fields, relations, enums), ALL API endpoint contracts (method, path, request/response shapes), auth config, seed data plan
3. **specs/ui-spec.json** — Theme (colors, branding, gradients), navigation structure, page layouts section-by-section with data sources
4. **specs/tasks.json** — Implementation tasks in dependency order with file paths, acceptance criteria, and test cases

### HOW TO USE THESE:
- **Prisma schema**: Read architecture.json -> data_model.entities and data_model.enums. Create EXACTLY the entities and fields specified.
- **API routes**: Read architecture.json -> api_contracts. Implement EVERY endpoint listed with the exact method, path, query params, request body, and response shape.
- **Theme & UI**: Read ui-spec.json -> theme for colors. Use primary_color and accent_color throughout. Read pages[] for section-by-section layout.
- **Login/Register branding**: Read ui-spec.json -> theme.login_branding and theme.register_branding for headlines, accent text, and feature highlights.
- **Navigation**: Read ui-spec.json -> navigation.style (sidebar/top-nav/minimal/bottom-tabs) and navigation.items for labels, routes, icons. The style determines the Layout component pattern — do NOT default to sidebar.
- **Design archetype**: Read ui-spec.json -> theme.archetype (DASHBOARD/SAAS/CONSUMER/MARKETPLACE/CLINICAL). This determines the ENTIRE layout: login style, navigation style, page patterns. Follow the archetype in 03-generate-app.md.
- **Seed data**: Read architecture.json -> seed_data for exact demo data to create.
- **Build order**: Follow tasks.json -> execution_order for the correct implementation sequence.
- **Validation issues**: If specs/validation-notes.md exists, READ it — it contains gaps found during validation (missing pages, uncovered requirements). Address ALL issues listed there during code generation.
"
else
  log_info "No SpecPilot documents — using legacy single-spec mode"
fi

# Step 1: Install dependencies first
if [ "$IS_PYTHON_BACKEND" = true ]; then
  log_substep "Installing Python backend dependencies..."
  cd "$PROJECT_DIR/backend"
  python3 -m pip install -r requirements.txt --quiet 2>&1 | tail -3
  cd - >/dev/null
else
  log_substep "Installing backend dependencies..."
  cd "$PROJECT_DIR/backend"
  npm install --legacy-peer-deps 2>&1 | tail -3
  cd - >/dev/null
fi

log_substep "Installing frontend dependencies..."
cd "$PROJECT_DIR/frontend"
npm install --legacy-peer-deps 2>&1 | tail -3
cd - >/dev/null

# Step 2: Generate all application code using Claude
log_substep "Calling Claude to generate full application..."
log_info "This may take 3-10 minutes depending on complexity..."

if [ "$IS_PYTHON_BACKEND" = true ]; then
GENERATE_PROMPT="You are generating a complete full-stack application with a Python FastAPI backend.

## Application Specification:

$SPEC
$SPECPILOT_CONTEXT

## Project Structure:

The project is already scaffolded at this directory with:
- frontend/ — React + Vite + Tailwind (dependencies installed)
- backend/ — Python FastAPI + SQLAlchemy (dependencies installed via pip)
- backend/app/ — Python package for the application
- backend/app/main.py — stub FastAPI app (replace with full implementation)
- backend/app/models.py — stub (fill with SQLAlchemy models)
- backend/app/database.py — stub (fill with async engine + session)
- backend/seed.py — stub (fill with seed data script)
- docker-compose.yml — pre-configured
- backend/.env — pre-configured with DATABASE_URL and JWT_SECRET

## What You Must Do:

IMPORTANT: If specs/ directory exists, READ all JSON files in it FIRST. They contain the exact data model, API contracts, UI spec, and theme to implement.

1. **Backend — Config**: Create backend/app/config.py with pydantic-settings reading from .env

2. **Backend — Database**: Create backend/app/database.py with async SQLAlchemy engine, session factory, Base class, and get_db dependency

3. **Backend — Models**: Create backend/app/models.py with ALL SQLAlchemy models from the spec. Use proper Column types, ForeignKey relations, and Python Enum classes for status fields

4. **Backend — Schemas**: Create backend/app/schemas.py with Pydantic schemas (Create, Update, Response) for every entity

5. **Backend — Auth**: Create backend/app/auth.py with JWT (python-jose), passlib bcrypt, OAuth2PasswordBearer, get_current_user dependency

6. **Backend — Routes**: Create these files:
   - backend/app/routes/__init__.py (empty)
   - backend/app/routes/auth.py (POST register + login returning access_token, GET /me)
   - backend/app/routes/{entity}.py (full CRUD + stats endpoint for each entity)

7. **Backend — Main**: Rewrite backend/app/main.py with FastAPI app, CORS middleware, lifespan (create tables), mount all routers under /api

8. **Backend — Seed Data**: Create backend/seed.py with SYNCHRONOUS SQLAlchemy to seed demo data (admin@demo.com / demo123). Use Base.metadata.create_all first.

9. **Frontend — Core**: Create these files:
   - frontend/src/lib/api.ts (axios instance with auth interceptor, base URL /api)
   - frontend/src/lib/auth.tsx (AuthContext, useAuth hook, ProtectedRoute component)
   - IMPORTANT: FastAPI login returns {access_token, token_type, user} — read access_token not token

10. **Frontend — Components**: Create reusable UI components:
    - frontend/src/components/Layout.tsx (app shell — depends on archetype: SAAS=dark sidebar, DASHBOARD=top nav, CONSUMER=minimal, MARKETPLACE=top nav+search, CLINICAL=muted sidebar)

11. **Frontend — Pages**: Create ALL pages: Login, Register, Dashboard, entity CRUD pages, UserList

12. **Frontend — App.tsx**: Rewrite with React Router, AuthProvider, protected routes

13. **Verify**: After writing all files, run:
    - cd backend && python -c 'from app.main import app; print(\"OK\")'
    - cd frontend && npm run build

## Critical Rules:
- Write COMPLETE, WORKING Python code — no TODOs or placeholders
- ALL API calls must work end-to-end (frontend -> FastAPI backend -> PostgreSQL)
- Use Tailwind CSS for ALL frontend styling
- FastAPI errors use HTTPException with detail= parameter
- FastAPI returns {detail: \"message\"} for errors, NOT {error: \"message\"}
- The frontend Axios error handler must check error.response.data.detail
- Use /api prefix for all backend routes
- The app must work with nginx proxying /api to backend:8000
- If specs/ui-spec.json exists, read theme.archetype FIRST
- Do NOT default to split-screen login + dark sidebar — the archetype determines the pattern"
else
GENERATE_PROMPT="You are generating a complete full-stack application.

## Application Specification:

$SPEC
$SPECPILOT_CONTEXT

## Project Structure:

The project is already scaffolded at this directory with:
- frontend/ — React + Vite + Tailwind (dependencies installed)
- backend/ — Express + Prisma (dependencies installed)
- backend/prisma/schema.prisma — needs to be filled with the data models
- docker-compose.yml — pre-configured
- backend/.env — pre-configured with DATABASE_URL and JWT_SECRET

## What You Must Do:

IMPORTANT: If specs/ directory exists, READ all JSON files in it FIRST. They contain the exact data model, API contracts, UI spec, and theme to implement.

1. **Backend — Prisma Schema**: Edit backend/prisma/schema.prisma to add ALL models from the spec with proper fields, types, and relations. Then run: cd backend && npx prisma generate

2. **Backend — Source Code**: Create these files:
   - backend/src/lib/prisma.ts (Prisma client singleton)
   - backend/src/middleware/auth.ts (JWT auth middleware)
   - backend/src/routes/auth.ts (register + login routes)
   - backend/src/routes/{entity}.ts (CRUD routes for each entity in spec)
   - backend/src/index.ts (Express app setup — mount all routes, cors, json parsing)

3. **Backend — Seed Data**: Create backend/prisma/seed.ts with realistic demo data including admin user (admin@demo.com / demo123)

4. **Frontend — Core**: Create these files:
   - frontend/src/lib/api.ts (axios instance with auth interceptor, base URL /api)
   - frontend/src/lib/auth.tsx (AuthContext, useAuth hook, ProtectedRoute component)

5. **Frontend — Components**: Create reusable UI components:
   - frontend/src/components/Layout.tsx (app shell — the layout depends on the archetype from ui-spec.json: SAAS=dark sidebar, DASHBOARD=top nav bar, CONSUMER=minimal top bar or no nav, MARKETPLACE=top nav with search, CLINICAL=muted sidebar)
   - (any other shared components needed — do NOT create a separate Sidebar.tsx if the archetype doesn't use one)

6. **Frontend — Pages**: Create ALL pages:
   - frontend/src/pages/Login.tsx
   - frontend/src/pages/Register.tsx
   - frontend/src/pages/Dashboard.tsx (with stat cards and recent items)
   - frontend/src/pages/{Entity}List.tsx (table with all records)
   - frontend/src/pages/{Entity}Form.tsx (create/edit form)
   - frontend/src/pages/UserList.tsx (admin user management)

7. **Frontend — App.tsx**: Rewrite frontend/src/App.tsx with:
   - React Router setup with all routes
   - AuthProvider wrapper
   - Protected routes for authenticated pages
   - Redirect to login if not authenticated

8. **Verify**: After writing all files, run:
   - cd backend && npx prisma generate
   - cd frontend && npm run build

## Critical Rules:
- Write COMPLETE, WORKING code — no TODOs or placeholders
- ALL API calls must work end-to-end (frontend -> backend -> database)
- Use Tailwind CSS for ALL styling — make it look professional
- Handle loading states, error states, and empty states
- The app must work when accessed at http://localhost with nginx proxying /api to the backend
- Use /api prefix for all backend routes
- If specs/ui-spec.json exists, read theme.archetype FIRST to determine layout/login/nav style. Use primary_color, accent_color for theming.
- If specs/ui-spec.json has login_branding/register_branding, use those exact headlines and feature highlights
- IMPORTANT: Do NOT default to split-screen login + dark sidebar. The archetype determines the design pattern — read it from theme.archetype."
fi

# Run Claude with the generation prompt
cd "$PROJECT_DIR"
claude_tracked "generate" -p \
  --dangerously-skip-permissions \
  --allowedTools "Read,Write,Edit,Bash" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  "$GENERATE_PROMPT" 2>&1 | tee "$PROJECT_DIR/generate.log"

CLAUDE_EXIT=${PIPESTATUS[0]}
cd - >/dev/null

if [ $CLAUDE_EXIT -ne 0 ]; then
  log_error "Code generation failed (exit code: $CLAUDE_EXIT)"
  log_error "Check log: $PROJECT_DIR/generate.log"
  exit 1
fi

log_success "Code generation complete"
log_info "Log saved to: $PROJECT_DIR/generate.log"
