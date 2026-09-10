#!/usr/bin/env bash
# Spectraal SpecPilot — Stage 4: Cross-Validation
# Input:  specs/prd.json + specs/architecture.json + specs/ui-spec.json + specs/tasks.json
# Output: specs/validation.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/extract-json.sh"
source "$ROOT_DIR/scripts/lib/logging.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/claude-utils.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/cost-tracker.sh" 2>/dev/null || true

BUILD_DIR="${1:-}"
if [[ -z "$BUILD_DIR" ]]; then
  echo "Usage: 04-validate.sh <build-dir>"
  exit 1
fi

SPECS_DIR="$BUILD_DIR/specs"
PRD_FILE="$SPECS_DIR/prd.json"
ARCH_FILE="$SPECS_DIR/architecture.json"
UI_FILE="$SPECS_DIR/ui-spec.json"
TASKS_FILE="$SPECS_DIR/tasks.json"

for f in "$PRD_FILE" "$ARCH_FILE" "$UI_FILE" "$TASKS_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "  ❌ Missing $f — run previous stages first"
    exit 1
  fi
done

PRD=$(cat "$PRD_FILE")
ARCH=$(cat "$ARCH_FILE")
UI=$(cat "$UI_FILE")
TASKS=$(cat "$TASKS_FILE")
SCHEMA=$(cat "$ROOT_DIR/specpilot/schemas/04-validation.schema.json")
PROMPT=$(cat "$ROOT_DIR/specpilot/prompts/04-validator.md")

echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Stage 4: Cross-Validation                              │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "  📄 Input:  all 4 spec documents"
echo "  📁 Output: $SPECS_DIR/validation.json"
echo ""

SYSTEM_PROMPT="$PROMPT

## JSON Schema for Output
\`\`\`json
$SCHEMA
\`\`\`

## PRD Document
\`\`\`json
$PRD
\`\`\`

## Architecture Document
\`\`\`json
$ARCH
\`\`\`

## UI Specification
\`\`\`json
$UI
\`\`\`

## Tasks Document
\`\`\`json
$TASKS
\`\`\`

Produce ONLY the JSON object. No markdown fences, no explanation."

if command -v claude &>/dev/null; then
  PROMPT_FILE=$(mktemp)
  echo "$SYSTEM_PROMPT" > "$PROMPT_FILE"

  MAX_RETRIES=2
  VAL_SUCCESS=false

  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "  🤖 Calling Claude CLI (attempt $attempt/$MAX_RETRIES)..."
    RESULT=$(claude_tracked_json "specpilot-validate" -p "$(cat "$PROMPT_FILE")" \
      --output-format json 2>"$SPECS_DIR/validate-stderr.log" || echo "CLAUDE_ERROR")

    if [[ "$RESULT" == "CLAUDE_ERROR" ]] || [[ -z "$RESULT" ]]; then
      echo "  ⚠️  Claude CLI returned error (attempt $attempt)"
      if [[ -f "$SPECS_DIR/validate-stderr.log" ]] && [[ -s "$SPECS_DIR/validate-stderr.log" ]]; then
        echo "  stderr: $(head -5 "$SPECS_DIR/validate-stderr.log")"
      fi
      if [[ $attempt -lt $MAX_RETRIES ]]; then
        echo "  Retrying in 3s..."
        sleep 3
        continue
      fi
      echo "  ❌ Claude CLI failed after $MAX_RETRIES attempts"
      rm -f "$PROMPT_FILE"
      exit 1
    fi

    if extract_json_from_claude "$RESULT" "$SPECS_DIR/validation.json"; then
      VAL_SUCCESS=true
      break
    else
      echo "  ⚠️  Failed to extract JSON (attempt $attempt)"
      echo "$RESULT" > "$SPECS_DIR/validation-raw-$attempt.txt"
      if [[ $attempt -lt $MAX_RETRIES ]]; then
        echo "  Retrying in 3s..."
        sleep 3
      fi
    fi
  done

  rm -f "$PROMPT_FILE"

  if ! $VAL_SUCCESS; then
    echo "  ❌ Failed to extract valid JSON from Claude output after $MAX_RETRIES attempts"
    exit 1
  fi
else
  echo "  ⚠️  Claude CLI not available"
  exit 1
fi

# ── Check Validation Result ──────────────────────
if [[ -f "$SPECS_DIR/validation.json" ]]; then
  STATUS=$(jq -r '.status' "$SPECS_DIR/validation.json")
  CRITICAL=$(jq '[.issues[] | select(.severity == "critical")] | length' "$SPECS_DIR/validation.json")
  WARNINGS=$(jq '[.issues[] | select(.severity == "warning")] | length' "$SPECS_DIR/validation.json")
  SUGGESTIONS=$(jq '[.issues[] | select(.severity == "suggestion")] | length' "$SPECS_DIR/validation.json")
  COVERAGE_FULL=$(jq '[.traceability_matrix[] | select(.coverage == "full")] | length' "$SPECS_DIR/validation.json")
  COVERAGE_TOTAL=$(jq '.traceability_matrix | length' "$SPECS_DIR/validation.json")

  echo ""
  echo "  ╔═══════════════════════════════════════╗"
  if [[ "$STATUS" == "pass" ]]; then
    echo "  ║  ✅ VALIDATION PASSED                 ║"
  elif [[ "$STATUS" == "pass-with-warnings" ]]; then
    echo "  ║  ⚠️  VALIDATION PASSED (with warnings) ║"
  else
    echo "  ║  ❌ VALIDATION FAILED                 ║"
  fi
  echo "  ╚═══════════════════════════════════════╝"
  echo ""
  echo "     Critical Issues:   $CRITICAL"
  echo "     Warnings:          $WARNINGS"
  echo "     Suggestions:       $SUGGESTIONS"
  echo "     Coverage:          $COVERAGE_FULL / $COVERAGE_TOTAL requirements fully traced"
  echo ""

  if [[ "$STATUS" == "fail" ]]; then
    echo "  ── Critical Issues ──"
    jq -r '.issues[] | select(.severity == "critical") | "  ❌ [" + .category + "] " + .description + "\n     Fix: " + .fix_suggestion' "$SPECS_DIR/validation.json"
    echo ""

    # Check for SPECPILOT_STRICT mode — default is lenient (proceed with warnings)
    if [[ "${SPECPILOT_STRICT:-false}" == "true" ]]; then
      echo "  ⛔ SPECPILOT_STRICT=true — aborting on critical issues"
      exit 1
    fi

    # Lenient mode: downgrade to pass-with-warnings, inject issues into a
    # validation-notes.md file so code generation can address them
    echo "  ⚠️  Critical issues found — proceeding with warnings injected for code generation"
    echo ""

    # Generate a markdown file with all issues for the code generator to read
    {
      echo "# SpecPilot Validation Issues"
      echo ""
      echo "The following issues were detected during specification validation."
      echo "Address these during code generation:"
      echo ""
      jq -r '.issues[] | "## [" + .severity + "] " + .category + "\n" + .description + "\n\n**Fix:** " + .fix_suggestion + "\n"' "$SPECS_DIR/validation.json"
    } > "$SPECS_DIR/validation-notes.md"

    echo "  📄 Issues saved to $SPECS_DIR/validation-notes.md"
  fi

  echo "  📄 $SPECS_DIR/validation.json"
else
  echo "  ❌ Failed to generate validation"
  exit 1
fi

echo "  ✅ Stage 4 complete — specifications are ready for code generation"
