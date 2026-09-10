#!/usr/bin/env bash
# Spectraal — Stage 10: Auto-Repair (Test-Driven Fix Loop)
# =====================================================================
# Reads test-report.json, feeds failed tests back to Claude for repair,
# then re-runs the failed tests to verify fixes.
#
# Input:  $PROJECT_DIR with deployed app + test-report.json
# Output: Updated test-report.json with improved pass rate
#
# Flow:
#   1. Read test-report.json for failures
#   2. Categorize failures (500=crash, 404=missing route, 403=RBAC)
#   3. Feed failures + source code to Claude for targeted fix
#   4. Rebuild + redeploy (hot-reload containers)
#   5. Re-run only the previously failed tests
#   6. Repeat up to MAX_RETRIES

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true

log_step "10" "AUTO-REPAIR"

PROJECT_DIR="$(cd "${1:?Usage: 10-repair.sh /path/to/project}" && pwd)"
SPECTRAAL_ROOT="$(get_sdd_root)"
MAX_RETRIES="${SPECTRAAL_REPAIR_RETRIES:-2}"

# ── Check prerequisites ──────────────────────────────────────

REPORT_FILE="$PROJECT_DIR/test-report.json"

if [ ! -f "$REPORT_FILE" ]; then
  log_warn "No test-report.json found — skipping auto-repair"
  exit 0
fi

INITIAL_FAILED=$(jq '[.results[] | select(.status == "FAIL")] | length' "$REPORT_FILE")
INITIAL_TOTAL=$(jq '.summary.total' "$REPORT_FILE")
INITIAL_PASSED=$(jq '.summary.passed' "$REPORT_FILE")

if [ "$INITIAL_FAILED" -eq 0 ]; then
  log_success "All tests passed — no repair needed"
  exit 0
fi

log_info "Test failures to repair: $INITIAL_FAILED / $INITIAL_TOTAL"

# ── Read build metadata ──────────────────────────────────────

PROJECT_NAME=$(jq -r '.project_name' "$PROJECT_DIR/build-meta.json")
BE_PORT=$(jq -r '.ports.backend // empty' "$PROJECT_DIR/build-meta.json")
BASE_URL="http://localhost:$BE_PORT"

if [ -z "$BE_PORT" ]; then
  log_error "Cannot determine backend port"
  exit 1
fi

# ── Build failure summary for Claude ─────────────────────────

build_failure_summary() {
  local report="$1"

  echo "## Test Failures to Fix"
  echo ""

  # Group by status code
  local code_500 code_404 code_403 code_other

  code_500=$(jq -r '[.results[] | select(.status == "FAIL" and .actual_status == 500)] | length' "$report")
  code_404=$(jq -r '[.results[] | select(.status == "FAIL" and .actual_status == 404)] | length' "$report")
  code_403=$(jq -r '[.results[] | select(.status == "FAIL" and (.actual_status == 200 or .actual_status == 403))] | length' "$report")

  if [ "$code_500" -gt 0 ]; then
    echo "### SERVER CRASHES (500) — Fix these first!"
    jq -r '.results[] | select(.status == "FAIL" and .actual_status == 500) | "- \(.id) \(.title): got 500 (expected \(.expected_status)). Detail: \(.detail)"' "$report"
    echo ""
  fi

  if [ "$code_404" -gt 0 ]; then
    echo "### MISSING ROUTES (404) — Add these endpoints"
    jq -r '.results[] | select(.status == "FAIL" and .actual_status == 404) | "- \(.id) \(.title): got 404 (expected \(.expected_status)). The route does not exist."' "$report"
    echo ""
  fi

  # Remaining failures
  jq -r '.results[] | select(.status == "FAIL" and .actual_status != 500 and .actual_status != 404) | "- \(.id) \(.title): expected \(.expected_status), got \(.actual_status). Detail: \(.detail)"' "$report" | head -20

  echo ""
  echo "## Rules"
  echo "1. Fix the BACKEND code only (backend/src/routes/*.ts, backend/src/index.ts)"
  echo "2. For 404 errors: add the missing route (GET /:id, PUT /:id, DELETE /:id, etc.)"
  echo "3. For 500 errors: fix the crash — check Prisma schema field names, required fields, relations"
  echo "4. For RBAC (expected 403 got 200): add requireRole('admin') middleware to admin-only routes"
  echo "5. Do NOT change the database schema or Prisma migrations"
  echo "6. Do NOT restructure existing working routes"
  echo "7. After fixing, run: cd backend && npx prisma generate && npx tsc --noEmit"
}

# ── Repair loop ──────────────────────────────────────────────

for attempt in $(seq 1 "$MAX_RETRIES"); do
  CURRENT_FAILED=$(jq '[.results[] | select(.status == "FAIL")] | length' "$REPORT_FILE")

  if [ "$CURRENT_FAILED" -eq 0 ]; then
    log_success "All tests passing after repair!"
    break
  fi

  log_substep "Repair attempt $attempt/$MAX_RETRIES ($CURRENT_FAILED failures remaining)..."

  # Build the failure summary
  FAILURE_SUMMARY=$(build_failure_summary "$REPORT_FILE")

  # Get list of backend route files for context
  ROUTE_FILES=$(find "$PROJECT_DIR/backend/src/routes" -name "*.ts" 2>/dev/null | sort | tr '\n' ', ')
  INDEX_FILE="$PROJECT_DIR/backend/src/index.ts"

  # Call Claude to fix
  cd "$PROJECT_DIR"

  claude_tracked "repair-$attempt" -p \
    --dangerously-skip-permissions \
    --allowedTools "Read,Write,Edit,Bash" \
    "You are fixing a Node.js/Express/Prisma backend API. The automated test suite found failures.

$FAILURE_SUMMARY

Backend route files: $ROUTE_FILES
Entry point: $INDEX_FILE
Prisma schema: backend/prisma/schema.prisma

Fix ALL the issues listed above. Focus on:
1. Adding missing CRUD routes (GET /:id, PUT /:id, DELETE /:id)
2. Fixing 500 crashes (check field names match Prisma schema)
3. Adding requireRole middleware where admin-only access is needed

After ALL fixes, verify: cd backend && npx prisma generate && npx tsc --noEmit" 2>&1 | tail -20

  REPAIR_EXIT=$?
  cd - >/dev/null

  if [ "$REPAIR_EXIT" -ne 0 ]; then
    log_warn "Claude repair attempt $attempt failed (exit $REPAIR_EXIT)"
    continue
  fi

  # ── Rebuild backend container ─────────────────────────────

  log_substep "Rebuilding backend after repairs..."

  cd "$PROJECT_DIR"

  # Rebuild just the backend (BuildKit for cache-mount reuse)
  DOCKER_BUILDKIT=1 docker compose -p "$PROJECT_NAME" build backend 2>&1 | tail -5
  docker compose -p "$PROJECT_NAME" up -d backend 2>&1 | tail -3

  cd - >/dev/null

  # Wait for backend to be ready
  log_substep "Waiting for backend restart..."
  sleep 5

  # Wait for health endpoint
  for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/health" 2>/dev/null | grep -q "200"; then
      break
    fi
    sleep 1
  done

  # ── Re-run tests ──────────────────────────────────────────

  log_substep "Re-running tests after repair..."
  "$SCRIPT_DIR/09-test.sh" "$PROJECT_DIR" 2>&1 | tail -15

  # Check improvement
  NEW_FAILED=$(jq '[.results[] | select(.status == "FAIL")] | length' "$REPORT_FILE")
  NEW_PASSED=$(jq '.summary.passed' "$REPORT_FILE")
  NEW_RATE=$(jq '.summary.pass_rate' "$REPORT_FILE")

  FIXED_COUNT=$((CURRENT_FAILED - NEW_FAILED))

  if [ "$FIXED_COUNT" -gt 0 ]; then
    log_success "Repair $attempt fixed $FIXED_COUNT test(s) — now $NEW_PASSED/$INITIAL_TOTAL passed ($NEW_RATE%)"
  else
    log_warn "Repair $attempt: no improvement ($NEW_FAILED still failing)"
  fi

done

# ── Final summary ────────────────────────────────────────────

FINAL_FAILED=$(jq '[.results[] | select(.status == "FAIL")] | length' "$REPORT_FILE")
FINAL_PASSED=$(jq '.summary.passed' "$REPORT_FILE")
FINAL_RATE=$(jq '.summary.pass_rate' "$REPORT_FILE")
TOTAL_FIXED=$((INITIAL_FAILED - FINAL_FAILED))

# Update build-meta with repair results
if [ -f "$PROJECT_DIR/build-meta.json" ]; then
  jq --argjson fixed "$TOTAL_FIXED" --argjson attempts "$MAX_RETRIES" \
     --argjson final_passed "$FINAL_PASSED" --argjson final_rate "$FINAL_RATE" \
    '.repair_results = {fixed: $fixed, attempts: $attempts, final_passed: $final_passed, final_pass_rate: $final_rate}' \
    "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
    mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

  # Also update the test_results in build-meta with final numbers
  jq --argjson passed "$FINAL_PASSED" --argjson failed "$FINAL_FAILED" --argjson rate "$FINAL_RATE" \
    '.test_results.passed = $passed | .test_results.failed = $failed | .test_results.pass_rate = $rate' \
    "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
    mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"
fi

log_info ""
log_info "┌─────────────────────────────────────┐"
log_info "│       AUTO-REPAIR RESULTS           │"
log_info "├─────────────────────────────────────┤"

if [ "$TOTAL_FIXED" -gt 0 ]; then
  log_success "│  Before:  $INITIAL_PASSED/$INITIAL_TOTAL passed"
  log_success "│  After:   $FINAL_PASSED/$INITIAL_TOTAL passed ($FINAL_RATE%)"
  log_success "│  Fixed:   $TOTAL_FIXED test(s) ✓"
else
  log_warn    "│  Before:  $INITIAL_PASSED/$INITIAL_TOTAL passed"
  log_warn    "│  After:   $FINAL_PASSED/$INITIAL_TOTAL passed ($FINAL_RATE%)"
  log_warn    "│  Fixed:   0 tests"
fi

log_info "│  Rounds:  $MAX_RETRIES"
log_info "└─────────────────────────────────────┘"

log_success "Auto-repair complete"
exit 0
