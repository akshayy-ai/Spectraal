#!/usr/bin/env bash
# Spectraal SpecPilot — Stage 3: Task Decomposition
# Input:  specs/prd.json + specs/architecture.json + specs/ui-spec.json
# Output: specs/tasks.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/extract-json.sh"
source "$ROOT_DIR/scripts/lib/logging.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/claude-utils.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/cost-tracker.sh" 2>/dev/null || true

BUILD_DIR="${1:-}"
if [[ -z "$BUILD_DIR" ]]; then
  echo "Usage: 03-task-planner.sh <build-dir>"
  exit 1
fi

SPECS_DIR="$BUILD_DIR/specs"
PRD_FILE="$SPECS_DIR/prd.json"
ARCH_FILE="$SPECS_DIR/architecture.json"
UI_FILE="$SPECS_DIR/ui-spec.json"

for f in "$PRD_FILE" "$ARCH_FILE" "$UI_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "  ❌ Missing $f — run previous stages first"
    exit 1
  fi
done

PRD=$(cat "$PRD_FILE")
ARCH=$(cat "$ARCH_FILE")
UI=$(cat "$UI_FILE")
SCHEMA=$(cat "$ROOT_DIR/specpilot/schemas/03-tasks.schema.json")
PROMPT=$(cat "$ROOT_DIR/specpilot/prompts/03-task-planner.md")

echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Stage 3: Task Decomposition                            │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "  📄 Input:  prd.json + architecture.json + ui-spec.json"
echo "  📁 Output: $SPECS_DIR/tasks.json"
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

Produce ONLY the JSON object. No markdown fences, no explanation."

if command -v claude &>/dev/null; then
  PROMPT_FILE=$(mktemp)
  echo "$SYSTEM_PROMPT" > "$PROMPT_FILE"

  MAX_RETRIES=2
  TASKS_SUCCESS=false

  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "  🤖 Calling Claude CLI (attempt $attempt/$MAX_RETRIES)..."
    RESULT=$(claude_tracked_json "specpilot-tasks" -p "$(cat "$PROMPT_FILE")" \
      --output-format json 2>"$SPECS_DIR/tasks-stderr.log" || echo "CLAUDE_ERROR")

    if [[ "$RESULT" == "CLAUDE_ERROR" ]] || [[ -z "$RESULT" ]]; then
      echo "  ⚠️  Claude CLI returned error (attempt $attempt)"
      if [[ -f "$SPECS_DIR/tasks-stderr.log" ]] && [[ -s "$SPECS_DIR/tasks-stderr.log" ]]; then
        echo "  stderr: $(head -5 "$SPECS_DIR/tasks-stderr.log")"
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

    if extract_json_from_claude "$RESULT" "$SPECS_DIR/tasks.json"; then
      TASKS_SUCCESS=true
      break
    else
      echo "  ⚠️  Failed to extract JSON (attempt $attempt)"
      echo "$RESULT" > "$SPECS_DIR/tasks-raw-$attempt.txt"
      if [[ $attempt -lt $MAX_RETRIES ]]; then
        echo "  Retrying in 3s..."
        sleep 3
      fi
    fi
  done

  rm -f "$PROMPT_FILE"

  if ! $TASKS_SUCCESS; then
    echo "  ❌ Failed to extract valid JSON from Claude output after $MAX_RETRIES attempts"
    exit 1
  fi
else
  echo "  ⚠️  Claude CLI not available"
  exit 1
fi

# ── Validate ──────────────────────────────────────
if [[ -f "$SPECS_DIR/tasks.json" ]]; then
  TASKS=$(jq '.tasks | length' "$SPECS_DIR/tasks.json")
  TEST_CASES=$(jq '.test_cases | length' "$SPECS_DIR/tasks.json")
  PHASES=$(jq '[.tasks[].phase] | unique | length' "$SPECS_DIR/tasks.json")

  if [[ "$TASKS" -lt 5 ]]; then
    echo "  ❌ Validation failed: fewer than 5 tasks"
    exit 1
  fi

  echo ""
  echo "  ✅ Tasks generated successfully"
  echo "     Tasks:      $TASKS"
  echo "     Test Cases: $TEST_CASES"
  echo "     Phases:     $PHASES"
  echo ""
  echo "  📄 $SPECS_DIR/tasks.json"
else
  echo "  ❌ Failed to generate tasks"
  exit 1
fi

echo "  ✅ Stage 3 complete"
