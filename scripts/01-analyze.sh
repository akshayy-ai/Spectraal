#!/usr/bin/env bash
# Spectraal — Stage 1: Analyze Requirements
# =====================================================
# Input:  $1 = requirements text (string)
# Output: $BUILD_DIR/spec.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true

log_step "1" "ANALYZE REQUIREMENTS"

REQUIREMENTS="${1:?Usage: 01-analyze.sh 'your requirements text'}"
BUILD_DIR="${SPECTRAAL_BUILD_DIR:?SPECTRAAL_BUILD_DIR not set}"
SPECTRAAL_ROOT="$(get_sdd_root)"

mkdir -p "$BUILD_DIR"

log_info "Requirements: ${REQUIREMENTS:0:100}..."
log_substep "Generating structured spec from requirements..."

# Read the analysis prompt
ANALYZE_PROMPT=$(cat "$SPECTRAAL_ROOT/prompts/01-analyze.md")

# Read the JSON schema
SPEC_SCHEMA=$(cat "$SPECTRAAL_ROOT/schemas/spec.schema.json")

# Call Claude to analyze requirements and produce spec.json
FULL_PROMPT="$ANALYZE_PROMPT

---

## User Requirements:

$REQUIREMENTS

---

Produce the spec JSON now. Output ONLY the JSON object, no markdown fences, no explanation."

# Run Claude with JSON schema enforcement
RESULT=$(claude_tracked_json "analyze" -p \
  --dangerously-skip-permissions \
  --allowedTools "" \
  --output-format json \
  --json-schema "$SPEC_SCHEMA" \
  "$FULL_PROMPT" 2>/dev/null)

CLAUDE_EXIT=$?

if [ $CLAUDE_EXIT -ne 0 ]; then
  log_error "Claude CLI failed at analysis stage (exit code: $CLAUDE_EXIT)"
  exit 1
fi

# Extract the result JSON — claude --output-format json wraps in {"result": ...}
# Try to extract the inner result first
SPEC_JSON=$(echo "$RESULT" | jq -r '.result // .' 2>/dev/null)

if [ -z "$SPEC_JSON" ] || [ "$SPEC_JSON" = "null" ]; then
  log_error "Failed to parse spec from Claude output"
  echo "$RESULT" > "$BUILD_DIR/analyze-raw-output.txt"
  log_error "Raw output saved to $BUILD_DIR/analyze-raw-output.txt"
  exit 1
fi

# Validate it's valid JSON with required fields
if ! echo "$SPEC_JSON" | jq -e '.project_name and .stack and .features' &>/dev/null; then
  log_error "Spec JSON is missing required fields"
  echo "$SPEC_JSON" | jq '.' > "$BUILD_DIR/spec-invalid.json" 2>/dev/null
  exit 1
fi

# Save spec
echo "$SPEC_JSON" | jq '.' > "$BUILD_DIR/spec.json"

# Extract key info for logging
PROJECT_NAME=$(echo "$SPEC_JSON" | jq -r '.project_name')
STACK_FE=$(echo "$SPEC_JSON" | jq -r '.stack.frontend')
STACK_BE=$(echo "$SPEC_JSON" | jq -r '.stack.backend')
STACK_DB=$(echo "$SPEC_JSON" | jq -r '.stack.database')
FEATURE_COUNT=$(echo "$SPEC_JSON" | jq '.features | length')
ENTITY_COUNT=$(echo "$SPEC_JSON" | jq '.database_entities | length')

log_success "Spec generated successfully"
log_info "  Project:  $PROJECT_NAME"
log_info "  Stack:    $STACK_FE + $STACK_BE + $STACK_DB"
log_info "  Features: $FEATURE_COUNT"
log_info "  Entities: $ENTITY_COUNT"
log_info "  Saved to: $BUILD_DIR/spec.json"

# Export for next stage
echo "$PROJECT_NAME"
