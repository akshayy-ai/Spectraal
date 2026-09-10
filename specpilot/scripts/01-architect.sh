#!/usr/bin/env bash
# Spectraal SpecPilot — Stage 1: Architecture Design
# Input:  specs/prd.json
# Output: specs/architecture.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/extract-json.sh"
source "$ROOT_DIR/scripts/lib/logging.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/claude-utils.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/cost-tracker.sh" 2>/dev/null || true

BUILD_DIR="${1:-}"
if [[ -z "$BUILD_DIR" ]]; then
  echo "Usage: 01-architect.sh <build-dir>"
  exit 1
fi

SPECS_DIR="$BUILD_DIR/specs"
PRD_FILE="$SPECS_DIR/prd.json"

if [[ ! -f "$PRD_FILE" ]]; then
  echo "  ❌ Missing $PRD_FILE — run Stage 0 first"
  exit 1
fi

PRD=$(cat "$PRD_FILE")
SCHEMA=$(cat "$ROOT_DIR/specpilot/schemas/01-architecture.schema.json")
PROMPT=$(cat "$ROOT_DIR/specpilot/prompts/01-architect.md")

echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Stage 1: Architecture Design                           │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "  📄 Input:  $PRD_FILE"
echo "  📁 Output: $SPECS_DIR/architecture.json"
echo ""

# ── Call Claude ───────────────────────────────────
SYSTEM_PROMPT="$PROMPT

## JSON Schema for Output
The output MUST be a valid JSON object matching this schema:
\`\`\`json
$SCHEMA
\`\`\`

## PRD Document
\`\`\`json
$PRD
\`\`\`

Produce ONLY the JSON object. No markdown fences, no explanation."

if command -v claude &>/dev/null; then
  # Write prompt to temp file to avoid ARG_MAX issues with large PRDs
  PROMPT_FILE=$(mktemp)
  echo "$SYSTEM_PROMPT" > "$PROMPT_FILE"

  MAX_RETRIES=2
  ARCH_SUCCESS=false

  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "  🤖 Calling Claude CLI (attempt $attempt/$MAX_RETRIES)..."
    RESULT=$(claude_tracked_json "specpilot-architect" -p "$(cat "$PROMPT_FILE")" \
      --output-format json 2>"$SPECS_DIR/architect-stderr.log" || echo "CLAUDE_ERROR")

    if [[ "$RESULT" == "CLAUDE_ERROR" ]] || [[ -z "$RESULT" ]]; then
      echo "  ⚠️  Claude CLI returned error (attempt $attempt)"
      if [[ -f "$SPECS_DIR/architect-stderr.log" ]] && [[ -s "$SPECS_DIR/architect-stderr.log" ]]; then
        echo "  stderr: $(head -5 "$SPECS_DIR/architect-stderr.log")"
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

    if extract_json_from_claude "$RESULT" "$SPECS_DIR/architecture.json"; then
      ARCH_SUCCESS=true
      break
    else
      echo "  ⚠️  Failed to extract JSON (attempt $attempt)"
      echo "$RESULT" > "$SPECS_DIR/architecture-raw-$attempt.txt"
      if [[ $attempt -lt $MAX_RETRIES ]]; then
        echo "  Retrying in 3s..."
        sleep 3
      fi
    fi
  done

  rm -f "$PROMPT_FILE"

  if ! $ARCH_SUCCESS; then
    echo "  ❌ Failed to extract valid JSON from Claude output after $MAX_RETRIES attempts"
    exit 1
  fi
else
  echo "  ⚠️  Claude CLI not available"
  exit 1
fi

# ── Validate ──────────────────────────────────────
if [[ -f "$SPECS_DIR/architecture.json" ]]; then
  ENTITIES=$(jq '.data_model.entities | length' "$SPECS_DIR/architecture.json")
  ENDPOINTS=$(jq '[.api_contracts[].endpoints[]] | length' "$SPECS_DIR/architecture.json")
  ENUMS=$(jq '.data_model.enums | length' "$SPECS_DIR/architecture.json")
  STACK=$(jq -r '.stack.frontend' "$SPECS_DIR/architecture.json")

  if [[ "$ENTITIES" -lt 1 ]]; then
    echo "  ❌ Validation failed: no entities in data model"
    exit 1
  fi

  echo ""
  echo "  ✅ Architecture generated successfully"
  echo "     Stack:      $STACK"
  echo "     Entities:   $ENTITIES"
  echo "     Enums:      $ENUMS"
  echo "     Endpoints:  $ENDPOINTS"
  echo ""
  echo "  📄 $SPECS_DIR/architecture.json"
else
  echo "  ❌ Failed to generate architecture"
  exit 1
fi

echo "  ✅ Stage 1 complete"
