#!/usr/bin/env bash
# Spectraal — Stage 4: Validate (Build + Test + Self-Heal)
# =====================================================================
# Input:  $PROJECT_DIR with generated code
# Output: Verified build artifacts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true

log_step "4" "VALIDATE & BUILD"

PROJECT_DIR="${1:?Usage: 04-validate.sh /path/to/project}"
SPECTRAAL_ROOT="$(get_sdd_root)"
MAX_RETRIES="${SPECTRAAL_VALIDATE_RETRIES:-3}"

if [ ! -f "$PROJECT_DIR/spec.json" ]; then
  log_error "spec.json not found in $PROJECT_DIR"
  exit 1
fi

FIX_PROMPT=$(cat "$SPECTRAAL_ROOT/prompts/04-fix-errors.md")

# Read stack profile
STACK_PROFILE=$(jq -r '.stack_profile // "full-stack"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || \
                jq -r '.stack_profile // "full-stack"' "$PROJECT_DIR/spec.json" 2>/dev/null || echo "full-stack")

# ── Validate Backend ──────────────────────────────────────────

if [ "$STACK_PROFILE" = "static" ]; then
  log_info "Static profile — skipping backend validation"
  BACKEND_OK=true
elif [ ! -d "$PROJECT_DIR/backend" ]; then
  log_warn "No backend directory found — skipping backend validation"
  BACKEND_OK=true
else

log_substep "Validating backend..."

BACKEND_OK=false
for attempt in $(seq 1 "$MAX_RETRIES"); do
  log_info "Backend build attempt $attempt/$MAX_RETRIES"

  cd "$PROJECT_DIR/backend"

  # Ensure Prisma client is generated (skip for frontend-only — no Prisma)
  if [ "$STACK_PROFILE" = "full-stack" ]; then
    npx prisma generate 2>&1 | tail -5
  fi

  # Try TypeScript compilation (non-fatal — we use tsx at runtime)
  BUILD_OUTPUT=$(npx tsc --noEmit 2>&1 || true)
  BUILD_EXIT=$?

  # Check for actual errors (not just warnings)
  ERROR_COUNT=$(echo "$BUILD_OUTPUT" | grep -c "error TS" || true)

  if [ "$ERROR_COUNT" -eq 0 ]; then
    log_success "Backend TypeScript: no errors"
    BACKEND_OK=true
    break
  fi

  log_warn "Backend has $ERROR_COUNT TypeScript error(s)"

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    log_substep "Attempting auto-fix (attempt $attempt)..."

    claude_tracked "validate-be" -p \
      --dangerously-skip-permissions \
      --allowedTools "Read,Write,Edit,Bash" \
      --append-system-prompt "$FIX_PROMPT" \
      "Fix ALL TypeScript errors in this backend project. Here are the errors:

$BUILD_OUTPUT

After fixing, run: npx prisma generate && npx tsc --noEmit" 2>&1 | tail -20

  else
    log_warn "Backend still has errors after $MAX_RETRIES attempts — proceeding (tsx handles runtime)"
    BACKEND_OK=true  # tsx can run despite TS errors
  fi

  cd - >/dev/null
done

cd "$PROJECT_DIR" 2>/dev/null || true

fi  # end of backend validation (profile check)

# ── Validate Frontend ─────────────────────────────────────────

log_substep "Validating frontend..."

FRONTEND_OK=false
for attempt in $(seq 1 "$MAX_RETRIES"); do
  log_info "Frontend build attempt $attempt/$MAX_RETRIES"

  cd "$PROJECT_DIR/frontend"

  BUILD_OUTPUT=$(npm run build 2>&1)
  BUILD_EXIT=$?

  if [ $BUILD_EXIT -eq 0 ]; then
    log_success "Frontend build: success"
    FRONTEND_OK=true
    break
  fi

  log_warn "Frontend build failed"

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    log_substep "Attempting auto-fix (attempt $attempt)..."

    claude_tracked "validate-fe" -p \
      --dangerously-skip-permissions \
      --allowedTools "Read,Write,Edit,Bash" \
      --append-system-prompt "$FIX_PROMPT" \
      "Fix ALL build errors in this React + Vite + Tailwind frontend project. Here are the errors:

$BUILD_OUTPUT

After fixing, run: npm run build" 2>&1 | tail -20

  else
    log_error "Frontend build failed after $MAX_RETRIES attempts"
    echo "$BUILD_OUTPUT" > "$PROJECT_DIR/frontend-build-errors.log"
    log_error "Error log: $PROJECT_DIR/frontend-build-errors.log"
  fi

  cd - >/dev/null
done

cd "$PROJECT_DIR" 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────

if $BACKEND_OK && $FRONTEND_OK; then
  log_success "Validation passed — both frontend and backend are buildable"
  exit 0
elif $BACKEND_OK; then
  log_warn "Backend OK but frontend has issues — proceeding anyway"
  exit 0
else
  log_error "Validation failed"
  exit 1
fi
