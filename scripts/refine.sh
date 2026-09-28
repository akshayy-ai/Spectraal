#!/usr/bin/env bash
# Spectraal — Iterative Refinement
# =====================================================================
# Applies a natural language change to an existing built application.
# Invokes Claude to modify the source code, then rebuilds and redeploys.
#
# Usage: refine.sh /path/to/project "change description"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/docker-utils.sh"

log_step "♻" "REFINE"

PROJECT_DIR="$(cd "${1:?Usage: refine.sh /path/to/project \"change description\"}" && pwd)"
CHANGE_DESC="${2:?Usage: refine.sh /path/to/project \"change description\"}"
SPECTRAAL_ROOT="$(get_sdd_root)"

# ── Validate inputs ─────────────────────────────────────────

if [ ! -f "$PROJECT_DIR/build-meta.json" ]; then
  log_error "build-meta.json not found in $PROJECT_DIR"
  exit 1
fi

if [ ${#CHANGE_DESC} -gt 5000 ]; then
  log_error "Change description too long (max 5000 chars)"
  exit 1
fi

# ── Read project state ──────────────────────────────────────

PROJECT_NAME=$(jq -r '.project_name' "$PROJECT_DIR/build-meta.json")
BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json")
STACK_PROFILE=$(jq -r '.stack_profile // "full-stack"' "$PROJECT_DIR/build-meta.json")
FE_PORT=$(jq -r '.ports.frontend // empty' "$PROJECT_DIR/build-meta.json")
BE_PORT=$(jq -r '.ports.backend // empty' "$PROJECT_DIR/build-meta.json")

log_info "Project: $PROJECT_NAME"
log_info "Blueprint: $BLUEPRINT ($STACK_PROFILE)"
log_info "Change: $CHANGE_DESC"

# ── Initialize cost tracking ────────────────────────────────

BUILD_DIR="$(dirname "$PROJECT_DIR")"
if [ -f "$BUILD_DIR/cost-tracking.json" ]; then
  export SPECTRAAL_COST_FILE="$BUILD_DIR/cost-tracking.json"
else
  cost_init "$BUILD_DIR" 2>/dev/null || true
fi

# ── Build the spec context (trimmed) ────────────────────────

SPEC_CONTEXT=""
if [ -f "$BUILD_DIR/spec.json" ]; then
  SPEC_CONTEXT=$(jq '{project_name, display_name, features: [.features[]? | {name, description}], entities: [.entities[]? | {name, fields: [.fields[]? | .name]}], api_groups: [.api_groups[]? | {group, base_path}], pages: [.pages[]? | {name, route}]}' "$BUILD_DIR/spec.json" 2>/dev/null || echo "{}")
fi

# ── Build file listing for context ──────────────────────────

FILE_LISTING=$(find "$PROJECT_DIR" -path "*/node_modules" -prune -o -path "*/.next" -prune -o -path "*/dist" -prune -o -path "*/__pycache__" -prune -o \( -name "*.ts" -o -name "*.tsx" -o -name "*.py" -o -name "*.css" -o -name "*.prisma" -o -name "*.json" -not -name "package-lock.json" -not -name "tsconfig.json" \) -print 2>/dev/null | sort | head -80)

# ── Load refinement system prompt ───────────────────────────

REFINE_PROMPT_FILE="$SPECTRAAL_ROOT/prompts/refine.md"
if [ ! -f "$REFINE_PROMPT_FILE" ]; then
  log_error "Refinement prompt not found at $REFINE_PROMPT_FILE"
  exit 1
fi
SYSTEM_PROMPT=$(cat "$REFINE_PROMPT_FILE")

# ── Invoke Claude ───────────────────────────────────────────

REFINE_START=$(date +%s)

log_substep "Applying changes via Claude..."

cd "$PROJECT_DIR"

claude_tracked "refine" -p \
  --dangerously-skip-permissions \
  --allowedTools "Read,Write,Edit,Bash" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  "# Change Request

$CHANGE_DESC

# Application Context

## Spec Summary
\`\`\`json
$SPEC_CONTEXT
\`\`\`

## Project Files
\`\`\`
$FILE_LISTING
\`\`\`

## Build Info
- Blueprint: $BLUEPRINT
- Profile: $STACK_PROFILE
- Backend port: ${BE_PORT:-none}
- Frontend port: ${FE_PORT:-none}

Apply the change described above. Read the relevant source files first to understand the current implementation, then make the minimal changes needed." 2>&1 | tail -30

CLAUDE_EXIT=$?
cd - >/dev/null

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  log_error "Claude refinement failed (exit $CLAUDE_EXIT)"
  exit 1
fi

# ── Rebuild and redeploy ────────────────────────────────────

log_substep "Rebuilding Docker containers..."

cd "$PROJECT_DIR"

if [ "$STACK_PROFILE" = "static" ]; then
  DOCKER_BUILDKIT=1 docker compose -p "$PROJECT_NAME" build frontend 2>&1 | tail -5
  docker compose -p "$PROJECT_NAME" up -d --force-recreate frontend 2>&1 | tail -3
elif [ "$STACK_PROFILE" = "frontend-only" ]; then
  DOCKER_BUILDKIT=1 docker compose -p "$PROJECT_NAME" build 2>&1 | tail -5
  docker compose -p "$PROJECT_NAME" up -d --force-recreate 2>&1 | tail -3
else
  DOCKER_BUILDKIT=1 docker compose -p "$PROJECT_NAME" build 2>&1 | tail -5
  docker compose -p "$PROJECT_NAME" up -d --force-recreate 2>&1 | tail -3
fi

cd - >/dev/null

# ── Wait for services ───────────────────────────────────────

log_substep "Waiting for services..."
sleep 3

if [ -n "$BE_PORT" ] && [ "$BE_PORT" != "0" ] && [ "$STACK_PROFILE" = "full-stack" ]; then
  wait_for_service "http://localhost:$BE_PORT/api/health" "Backend" 30 2>/dev/null || \
    wait_for_service "http://localhost:$BE_PORT" "Backend" 10 2>/dev/null || true
fi

if [ -n "$FE_PORT" ]; then
  wait_for_service "http://localhost:$FE_PORT" "Frontend" 20 2>/dev/null || true
fi

# ── Update build-meta.json ──────────────────────────────────

REFINE_END=$(date +%s)
REFINE_ELAPSED=$((REFINE_END - REFINE_START))

jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg desc "$CHANGE_DESC" --arg status "success" \
  '.refinements = (.refinements // []) + [{timestamp: $ts, description: $desc, status: $status}]' \
  "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
  mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

# ── Print summary ───────────────────────────────────────────

DEPLOYED_URL="http://localhost:${FE_PORT:-$BE_PORT}"

log_info ""
log_success "╔═══════════════════════════════════════════════════╗"
log_success "║          ✦ Refinement Complete ✦                 ║"
log_success "╠═══════════════════════════════════════════════════╣"
log_success "║  Project:  $PROJECT_NAME"
log_success "║  Change:   ${CHANGE_DESC:0:50}..."
log_success "║  Time:     ${REFINE_ELAPSED}s"
log_success "║  URL:      $DEPLOYED_URL"
log_success "╚═══════════════════════════════════════════════════╝"
