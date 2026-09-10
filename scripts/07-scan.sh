#!/usr/bin/env bash
# Spectraal — Stage 9: Security Scan
# =====================================================================
# Runs container vulnerability scanning on built Docker images.
# Supports Grype (preferred) and Trivy as fallback.
#
# Input:  $PROJECT_DIR with Docker images built (from package stage)
# Output: scan-report.json with vulnerability counts by severity
#
# Behavior:
#   - Scans ${PROJECT_NAME}-api:latest and ${PROJECT_NAME}-web:latest
#   - Fails pipeline on CRITICAL CVEs (configurable)
#   - Warns on HIGH CVEs
#   - Generates per-image JSON reports + combined summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/docker-utils.sh"

log_step "7" "SCAN"

PROJECT_DIR="$(cd "${1:?Usage: 07-scan.sh /path/to/project}" && pwd)"

if [ ! -f "$PROJECT_DIR/build-meta.json" ]; then
  log_error "build-meta.json not found"
  exit 1
fi

PROJECT_NAME=$(jq -r '.project_name' "$PROJECT_DIR/build-meta.json")

# ── Configuration ────────────────────────────────────────────

FAIL_ON="${SPECTRAAL_SCAN_FAIL_ON:-critical}"  # critical | high | medium | none
SCAN_TOOL=""

# ── Detect scanner ───────────────────────────────────────────

detect_scanner() {
  if command -v grype &>/dev/null; then
    SCAN_TOOL="grype"
    log_info "Scanner: Grype $(grype version 2>/dev/null | head -1 || echo '')"
  elif command -v trivy &>/dev/null; then
    SCAN_TOOL="trivy"
    log_info "Scanner: Trivy $(trivy version 2>/dev/null | grep -oP 'Version: \K.*' || echo '')"
  elif command -v docker &>/dev/null; then
    # Try docker scout as last resort
    if docker scout version &>/dev/null 2>&1; then
      SCAN_TOOL="docker-scout"
      log_info "Scanner: Docker Scout"
    fi
  fi

  if [ -z "$SCAN_TOOL" ]; then
    log_warn "No vulnerability scanner found (grype, trivy, or docker scout)"
    log_info "Install one:"
    log_info "  brew install grype        # Anchore Grype (recommended)"
    log_info "  brew install trivy        # Aqua Trivy"
    log_info "  docker scout version      # Docker Scout (built into Docker Desktop)"
    return 1
  fi
  return 0
}

# ── State ────────────────────────────────────────────────────

TOTAL_CRITICAL=0
TOTAL_HIGH=0
TOTAL_MEDIUM=0
TOTAL_LOW=0
TOTAL_NEGLIGIBLE=0
IMAGE_RESULTS="[]"

# ── Helper: scan one image with Grype ────────────────────────

scan_with_grype() {
  local image="$1"
  local label="$2"
  local report_file="$PROJECT_DIR/scan-${label}.json"

  log_substep "Scanning $label ($image) with Grype..."

  # Run grype and capture JSON output
  local grype_output
  if ! grype_output=$(grype "$image" -o json --fail-on "${FAIL_ON}" 2>&1); then
    # grype returns non-zero when fail-on threshold is hit
    true
  fi

  # Save raw output
  echo "$grype_output" > "$report_file" 2>/dev/null || true

  # Parse vulnerability counts
  local critical high medium low negligible
  if echo "$grype_output" | jq -e '.matches' &>/dev/null; then
    critical=$(echo "$grype_output" | jq '[.matches[] | select(.vulnerability.severity == "Critical")] | length' 2>/dev/null || echo "0")
    high=$(echo "$grype_output" | jq '[.matches[] | select(.vulnerability.severity == "High")] | length' 2>/dev/null || echo "0")
    medium=$(echo "$grype_output" | jq '[.matches[] | select(.vulnerability.severity == "Medium")] | length' 2>/dev/null || echo "0")
    low=$(echo "$grype_output" | jq '[.matches[] | select(.vulnerability.severity == "Low")] | length' 2>/dev/null || echo "0")
    negligible=$(echo "$grype_output" | jq '[.matches[] | select(.vulnerability.severity == "Negligible")] | length' 2>/dev/null || echo "0")
  else
    # Fallback: parse table output
    grype_table=$(grype "$image" 2>&1 || true)
    critical=$(echo "$grype_table" | grep -ci "critical" || echo "0")
    high=$(echo "$grype_table" | grep -ci "high" || echo "0")
    medium=$(echo "$grype_table" | grep -ci "medium" || echo "0")
    low=$(echo "$grype_table" | grep -ci "low" || echo "0")
    negligible=0
  fi

  echo "$critical $high $medium $low $negligible"
}

# ── Helper: scan one image with Trivy ────────────────────────

scan_with_trivy() {
  local image="$1"
  local label="$2"
  local report_file="$PROJECT_DIR/scan-${label}.json"

  log_substep "Scanning $label ($image) with Trivy..."

  # Run trivy with JSON output
  local trivy_output
  trivy_output=$(trivy image "$image" --format json --quiet 2>/dev/null || true)

  echo "$trivy_output" > "$report_file" 2>/dev/null || true

  # Parse vulnerability counts from Trivy JSON
  local critical high medium low negligible
  if echo "$trivy_output" | jq -e '.Results' &>/dev/null; then
    critical=$(echo "$trivy_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
    high=$(echo "$trivy_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo "0")
    medium=$(echo "$trivy_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' 2>/dev/null || echo "0")
    low=$(echo "$trivy_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "LOW")] | length' 2>/dev/null || echo "0")
    negligible=$(echo "$trivy_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "UNKNOWN")] | length' 2>/dev/null || echo "0")
  else
    critical=0; high=0; medium=0; low=0; negligible=0
  fi

  echo "$critical $high $medium $low $negligible"
}

# ── Helper: scan one image with Docker Scout ─────────────────

scan_with_docker_scout() {
  local image="$1"
  local label="$2"
  local report_file="$PROJECT_DIR/scan-${label}.txt"

  log_substep "Scanning $label ($image) with Docker Scout..."

  local scout_output
  scout_output=$(docker scout cves "$image" --only-severity critical,high 2>&1 || true)

  echo "$scout_output" > "$report_file" 2>/dev/null || true

  # Parse from scout text output
  local critical high medium low negligible
  critical=$(echo "$scout_output" | grep -oi "[0-9]* critical" | awk '{s+=$1} END {print s+0}' || echo "0")
  high=$(echo "$scout_output" | grep -oi "[0-9]* high" | awk '{s+=$1} END {print s+0}' || echo "0")
  medium=0; low=0; negligible=0

  echo "$critical $high $medium $low $negligible"
}

# ── Helper: scan one image (dispatch) ────────────────────────

scan_image() {
  local image="$1"
  local label="$2"

  # Check image exists
  if ! docker image inspect "$image" &>/dev/null; then
    log_warn "$label image not found: $image — skipping"
    return 0
  fi

  local counts
  case "$SCAN_TOOL" in
    grype)         counts=$(scan_with_grype "$image" "$label") ;;
    trivy)         counts=$(scan_with_trivy "$image" "$label") ;;
    docker-scout)  counts=$(scan_with_docker_scout "$image" "$label") ;;
  esac

  # Parse counts
  local critical high medium low negligible
  read -r critical high medium low negligible <<< "$counts"
  critical="${critical:-0}"; high="${high:-0}"; medium="${medium:-0}"
  low="${low:-0}"; negligible="${negligible:-0}"

  # Accumulate
  TOTAL_CRITICAL=$((TOTAL_CRITICAL + critical))
  TOTAL_HIGH=$((TOTAL_HIGH + high))
  TOTAL_MEDIUM=$((TOTAL_MEDIUM + medium))
  TOTAL_LOW=$((TOTAL_LOW + low))
  TOTAL_NEGLIGIBLE=$((TOTAL_NEGLIGIBLE + negligible))

  # Log per-image summary
  if [ "$critical" -gt 0 ]; then
    log_error "  $label: $critical CRITICAL, $high HIGH, $medium MEDIUM, $low LOW"
  elif [ "$high" -gt 0 ]; then
    log_warn  "  $label: $critical CRITICAL, $high HIGH, $medium MEDIUM, $low LOW"
  else
    log_success "  $label: $critical CRITICAL, $high HIGH, $medium MEDIUM, $low LOW"
  fi

  # Append to results array
  IMAGE_RESULTS=$(echo "$IMAGE_RESULTS" | jq \
    --arg image "$image" --arg label "$label" \
    --argjson c "$critical" --argjson h "$high" --argjson m "$medium" \
    --argjson l "$low" --argjson n "$negligible" \
    '. + [{image: $image, label: $label, critical: $c, high: $h, medium: $m, low: $l, negligible: $n}]')
}

# ══════════════════════════════════════════════════════════════
# EXECUTION
# ══════════════════════════════════════════════════════════════

if ! detect_scanner; then
  # No scanner available — generate skip report
  log_warn "Skipping security scan (no scanner installed)"

  cat > "$PROJECT_DIR/scan-report.json" <<REPORT
{
  "stage": "scan",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "skipped",
  "reason": "No vulnerability scanner installed (grype, trivy, or docker scout)",
  "scanner": null,
  "summary": {
    "critical": 0, "high": 0, "medium": 0, "low": 0
  },
  "images": []
}
REPORT

  if [ -f "$PROJECT_DIR/build-meta.json" ]; then
    jq '.scan_results = {status: "skipped", scanner: null, critical: 0, high: 0}' \
      "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
      mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"
  fi

  log_success "Scan stage complete (skipped — install grype: brew install grype)"
  exit 0
fi

# ── Scan images ──────────────────────────────────────────────

log_substep "Scanning Docker images..."

scan_image "${PROJECT_NAME}-api:latest" "backend"
scan_image "${PROJECT_NAME}-web:latest" "frontend"

# Also scan the database image if custom
if docker image inspect "${PROJECT_NAME}-db:latest" &>/dev/null 2>&1; then
  scan_image "${PROJECT_NAME}-db:latest" "database"
fi

# ── Determine status ─────────────────────────────────────────

SCAN_STATUS="pass"
if [ "$TOTAL_CRITICAL" -gt 0 ]; then
  SCAN_STATUS="fail-critical"
elif [ "$TOTAL_HIGH" -gt 0 ]; then
  SCAN_STATUS="warn-high"
fi

# ── Generate report ──────────────────────────────────────────

REPORT_FILE="$PROJECT_DIR/scan-report.json"

cat > "$REPORT_FILE" <<REPORT
{
  "stage": "scan",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "$SCAN_STATUS",
  "scanner": "$SCAN_TOOL",
  "fail_on": "$FAIL_ON",
  "summary": {
    "critical": $TOTAL_CRITICAL,
    "high": $TOTAL_HIGH,
    "medium": $TOTAL_MEDIUM,
    "low": $TOTAL_LOW,
    "negligible": $TOTAL_NEGLIGIBLE
  },
  "images": $IMAGE_RESULTS
}
REPORT

# Update build-meta
if [ -f "$PROJECT_DIR/build-meta.json" ]; then
  jq --argjson c "$TOTAL_CRITICAL" --argjson h "$TOTAL_HIGH" \
     --argjson m "$TOTAL_MEDIUM" --arg status "$SCAN_STATUS" \
     --arg scanner "$SCAN_TOOL" \
    '.scan_results = {status: $status, scanner: $scanner, critical: $c, high: $h, medium: $m}' \
    "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
    mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"
fi

# ── Print summary ────────────────────────────────────────────

log_info ""
log_info "┌─────────────────────────────────────┐"
log_info "│       SECURITY SCAN RESULTS         │"
log_info "├─────────────────────────────────────┤"

if [ "$TOTAL_CRITICAL" -gt 0 ]; then
  log_error "│  CRITICAL:  $TOTAL_CRITICAL ✗"
else
  log_success "│  CRITICAL:  0 ✓"
fi

if [ "$TOTAL_HIGH" -gt 0 ]; then
  log_warn  "│  HIGH:      $TOTAL_HIGH ⚠"
else
  log_success "│  HIGH:      0 ✓"
fi

log_info "│  MEDIUM:    $TOTAL_MEDIUM"
log_info "│  LOW:       $TOTAL_LOW"
log_info "│  Scanner:   $SCAN_TOOL"
log_info "└─────────────────────────────────────┘"
log_info "Report: $REPORT_FILE"

# ── Exit ─────────────────────────────────────────────────────

if [ "$SCAN_STATUS" = "fail-critical" ] && [ "$FAIL_ON" = "critical" ]; then
  log_error "Scan found $TOTAL_CRITICAL CRITICAL vulnerabilities"
  log_warn "Pipeline continues — review scan-report.json"
fi

log_success "Security scan complete"
exit 0
