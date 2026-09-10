#!/usr/bin/env bash
# Spectraal — Stage 5: Lint (Static Analysis)
# =====================================================================
# Runs TypeScript strict checks + ESLint on generated code.
# Auto-fixes issues with Claude CLI (up to MAX_RETRIES).
#
# Input:  $PROJECT_DIR with generated + validated code
# Output: lint-report.json with issue counts
#
# Checks:
#   - TypeScript: tsc --noEmit with strict settings
#   - ESLint: if eslint config exists in the project
#   - Auto-fix: Claude repairs TS/lint errors (up to 2 rounds)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true

log_step "5" "LINT"

PROJECT_DIR="$(cd "${1:?Usage: 05-lint.sh /path/to/project}" && pwd)"
SPECTRAAL_ROOT="$(get_sdd_root)"
ORIG_DIR="$(pwd)"
MAX_RETRIES="${SPECTRAAL_LINT_RETRIES:-2}"

FIX_PROMPT=$(cat "$SPECTRAAL_ROOT/prompts/04-fix-errors.md")

# ── State tracking ───────────────────────────────────────────

BE_TS_ERRORS=0
FE_TS_ERRORS=0
BE_LINT_ERRORS=0
FE_LINT_ERRORS=0
BE_TS_WARNINGS=0
FE_TS_WARNINGS=0
BE_FIXED=false
FE_FIXED=false

# ── Helper: count TS errors ──────────────────────────────────

count_ts_errors() {
  local output="$1"
  local count
  count=$(echo "$output" | grep -c "error TS" 2>/dev/null) || true
  echo "${count:-0}"
}

count_ts_warnings() {
  local output="$1"
  # Count total diagnostic lines minus errors
  local total errors
  total=$(echo "$output" | grep -cE "\.(ts|tsx)\(" 2>/dev/null) || true
  total="${total:-0}"
  errors=$(echo "$output" | grep -c "error TS" 2>/dev/null) || true
  errors="${errors:-0}"
  local warns=$(( total - errors ))
  echo $(( warns > 0 ? warns : 0 ))
}

# ══════════════════════════════════════════════════════════════
# BACKEND ANALYSIS
# ══════════════════════════════════════════════════════════════

if [ -d "$PROJECT_DIR/backend" ] && [ -f "$PROJECT_DIR/backend/tsconfig.json" ]; then
  log_substep "Analyzing backend TypeScript..."

  for attempt in $(seq 1 $((MAX_RETRIES + 1))); do
    cd "$PROJECT_DIR/backend"

    # Ensure Prisma client exists
    npx prisma generate 2>/dev/null | tail -1 || true

    # Run strict TypeScript check
    TS_OUTPUT=$(npx tsc --noEmit --pretty false 2>&1 || true)
    BE_TS_ERRORS=$(count_ts_errors "$TS_OUTPUT")
    BE_TS_WARNINGS=$(count_ts_warnings "$TS_OUTPUT")

    if [ "$BE_TS_ERRORS" -eq 0 ]; then
      log_success "Backend TypeScript: 0 errors"
      BE_FIXED=true
      break
    fi

    log_warn "Backend TypeScript: $BE_TS_ERRORS error(s)"

    if [ "$attempt" -le "$MAX_RETRIES" ]; then
      log_substep "Auto-fixing backend (attempt $attempt/$MAX_RETRIES)..."

      # Truncate error output to avoid token overflow
      errors_truncated=$(echo "$TS_OUTPUT" | grep "error TS" | head -40)

      claude_tracked "lint-be" -p \
        --dangerously-skip-permissions \
        --allowedTools "Read,Write,Edit,Bash" \
        --append-system-prompt "$FIX_PROMPT" \
        "Fix these TypeScript errors in the backend. Only fix the errors — do not refactor or restructure working code.

ERRORS:
$errors_truncated

After fixing, verify with: npx prisma generate && npx tsc --noEmit" 2>&1 | tail -10
    else
      log_warn "Backend still has $BE_TS_ERRORS TS error(s) after $MAX_RETRIES fix attempts"
    fi

    cd "$ORIG_DIR"
  done

  # ── ESLint (backend) ──────────────────────────────────────

  cd "$PROJECT_DIR/backend"
  if [ -f "eslint.config.js" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ]; then
    log_substep "Running ESLint on backend..."
    LINT_OUTPUT=$(npx eslint src/ --format compact 2>&1 || true)
    BE_LINT_ERRORS=$(echo "$LINT_OUTPUT" | grep -c "Error -" 2>/dev/null || echo "0")

    if [ "$BE_LINT_ERRORS" -eq 0 ]; then
      log_success "Backend ESLint: 0 errors"
    else
      log_warn "Backend ESLint: $BE_LINT_ERRORS error(s)"
    fi
  else
    log_info "Backend: no ESLint config found (skipping)"
  fi
  cd "$ORIG_DIR"

else
  log_warn "No backend tsconfig.json found — skipping backend analysis"
fi

# ══════════════════════════════════════════════════════════════
# FRONTEND ANALYSIS
# ══════════════════════════════════════════════════════════════

if [ -d "$PROJECT_DIR/frontend" ] && [ -f "$PROJECT_DIR/frontend/tsconfig.json" ]; then
  log_substep "Analyzing frontend TypeScript..."

  for attempt in $(seq 1 $((MAX_RETRIES + 1))); do
    cd "$PROJECT_DIR/frontend"

    # Run TypeScript check
    TS_OUTPUT=$(npx tsc --noEmit --pretty false 2>&1 || true)
    FE_TS_ERRORS=$(count_ts_errors "$TS_OUTPUT")
    FE_TS_WARNINGS=$(count_ts_warnings "$TS_OUTPUT")

    if [ "$FE_TS_ERRORS" -eq 0 ]; then
      log_success "Frontend TypeScript: 0 errors"
      FE_FIXED=true
      break
    fi

    log_warn "Frontend TypeScript: $FE_TS_ERRORS error(s)"

    if [ "$attempt" -le "$MAX_RETRIES" ]; then
      log_substep "Auto-fixing frontend (attempt $attempt/$MAX_RETRIES)..."

      errors_truncated=$(echo "$TS_OUTPUT" | grep "error TS" | head -40)

      claude_tracked "lint-fe" -p \
        --dangerously-skip-permissions \
        --allowedTools "Read,Write,Edit,Bash" \
        --append-system-prompt "$FIX_PROMPT" \
        "Fix these TypeScript errors in the React frontend. Only fix the errors — do not refactor or restructure working code.

ERRORS:
$errors_truncated

After fixing, verify with: npx tsc --noEmit" 2>&1 | tail -10
    else
      log_warn "Frontend still has $FE_TS_ERRORS TS error(s) after $MAX_RETRIES fix attempts"
    fi

    cd "$ORIG_DIR"
  done

  # ── ESLint (frontend) ─────────────────────────────────────

  cd "$PROJECT_DIR/frontend"
  if [ -f "eslint.config.js" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ]; then
    log_substep "Running ESLint on frontend..."
    LINT_OUTPUT=$(npx eslint src/ --format compact 2>&1 || true)
    FE_LINT_ERRORS=$(echo "$LINT_OUTPUT" | grep -c "Error -" 2>/dev/null || echo "0")

    if [ "$FE_LINT_ERRORS" -eq 0 ]; then
      log_success "Frontend ESLint: 0 errors"
    else
      log_warn "Frontend ESLint: $FE_LINT_ERRORS error(s)"
    fi
  else
    log_info "Frontend: no ESLint config found (skipping)"
  fi
  cd "$ORIG_DIR"

else
  log_warn "No frontend tsconfig.json found — skipping frontend analysis"
fi

# ══════════════════════════════════════════════════════════════
# REPORT
# ══════════════════════════════════════════════════════════════

TOTAL_ERRORS=$((BE_TS_ERRORS + FE_TS_ERRORS + BE_LINT_ERRORS + FE_LINT_ERRORS))
TOTAL_WARNINGS=$((BE_TS_WARNINGS + FE_TS_WARNINGS))

# Determine status
STATUS="pass"
if [ "$TOTAL_ERRORS" -gt 0 ]; then
  STATUS="fail"
elif [ "$TOTAL_WARNINGS" -gt 0 ]; then
  STATUS="pass-with-warnings"
fi

# Generate report
REPORT_FILE="$PROJECT_DIR/lint-report.json"
cat > "$REPORT_FILE" <<REPORT
{
  "stage": "lint",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "$STATUS",
  "auto_fix_attempts": $MAX_RETRIES,
  "summary": {
    "total_errors": $TOTAL_ERRORS,
    "total_warnings": $TOTAL_WARNINGS
  },
  "backend": {
    "typescript_errors": $BE_TS_ERRORS,
    "typescript_warnings": $BE_TS_WARNINGS,
    "eslint_errors": $BE_LINT_ERRORS,
    "auto_fixed": $BE_FIXED
  },
  "frontend": {
    "typescript_errors": $FE_TS_ERRORS,
    "typescript_warnings": $FE_TS_WARNINGS,
    "eslint_errors": $FE_LINT_ERRORS,
    "auto_fixed": $FE_FIXED
  }
}
REPORT

# Update build-meta
if [ -f "$PROJECT_DIR/build-meta.json" ]; then
  jq --argjson errs "$TOTAL_ERRORS" --argjson warns "$TOTAL_WARNINGS" \
     --arg status "$STATUS" \
    '.lint_results = {errors: $errs, warnings: $warns, status: $status}' \
    "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
    mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"
fi

# Print summary
log_info ""
log_info "┌─────────────────────────────────────┐"
log_info "│      STATIC ANALYSIS RESULTS        │"
log_info "├─────────────────────────────────────┤"

if [ "$TOTAL_ERRORS" -eq 0 ]; then
  log_success "│  Status:    $STATUS"
  log_success "│  TS Errors: 0 ✓"
else
  log_warn    "│  Status:    $STATUS"
  log_warn    "│  TS Errors: $TOTAL_ERRORS ✗"
fi

if [ "$TOTAL_WARNINGS" -gt 0 ]; then
  log_warn    "│  Warnings:  $TOTAL_WARNINGS"
else
  log_success "│  Warnings:  0 ✓"
fi

log_info "│  ESLint:    BE=$BE_LINT_ERRORS FE=$FE_LINT_ERRORS"
log_info "└─────────────────────────────────────┘"
log_info "Report: $REPORT_FILE"

# Exit
if [ "$TOTAL_ERRORS" -gt 0 ]; then
  log_warn "Lint stage completed with $TOTAL_ERRORS error(s) remaining"
fi

log_success "Static analysis complete"
exit 0
