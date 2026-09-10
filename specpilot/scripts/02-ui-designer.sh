#!/usr/bin/env bash
# Spectraal SpecPilot — Stage 2: UI/UX Specification
# Input:  specs/prd.json + specs/architecture.json
# Output: specs/ui-spec.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/extract-json.sh"
source "$ROOT_DIR/scripts/lib/logging.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/claude-utils.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/cost-tracker.sh" 2>/dev/null || true

BUILD_DIR="${1:-}"
if [[ -z "$BUILD_DIR" ]]; then
  echo "Usage: 02-ui-designer.sh <build-dir>"
  exit 1
fi

SPECS_DIR="$BUILD_DIR/specs"
PRD_FILE="$SPECS_DIR/prd.json"
ARCH_FILE="$SPECS_DIR/architecture.json"

for f in "$PRD_FILE" "$ARCH_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "  ❌ Missing $f — run previous stages first"
    exit 1
  fi
done

PRD=$(cat "$PRD_FILE")
ARCH=$(cat "$ARCH_FILE")
SCHEMA=$(cat "$ROOT_DIR/specpilot/schemas/02-ui-spec.schema.json")
PROMPT=$(cat "$ROOT_DIR/specpilot/prompts/02-ui-designer.md")

echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Stage 2: UI/UX Specification                           │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "  📄 Input:  prd.json + architecture.json"
echo "  📁 Output: $SPECS_DIR/ui-spec.json"
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

Produce ONLY the JSON object. No markdown fences, no explanation."

if command -v claude &>/dev/null; then
  PROMPT_FILE=$(mktemp)
  echo "$SYSTEM_PROMPT" > "$PROMPT_FILE"

  MAX_RETRIES=2
  UI_SUCCESS=false

  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "  🤖 Calling Claude CLI (attempt $attempt/$MAX_RETRIES)..."
    RESULT=$(claude_tracked_json "specpilot-ui" -p "$(cat "$PROMPT_FILE")" \
      --output-format json 2>"$SPECS_DIR/ui-stderr.log" || echo "CLAUDE_ERROR")

    if [[ "$RESULT" == "CLAUDE_ERROR" ]] || [[ -z "$RESULT" ]]; then
      echo "  ⚠️  Claude CLI returned error (attempt $attempt)"
      if [[ -f "$SPECS_DIR/ui-stderr.log" ]] && [[ -s "$SPECS_DIR/ui-stderr.log" ]]; then
        echo "  stderr: $(head -5 "$SPECS_DIR/ui-stderr.log")"
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

    if extract_json_from_claude "$RESULT" "$SPECS_DIR/ui-spec.json"; then
      UI_SUCCESS=true
      break
    else
      echo "  ⚠️  Failed to extract JSON (attempt $attempt)"
      echo "$RESULT" > "$SPECS_DIR/ui-spec-raw-$attempt.txt"
      if [[ $attempt -lt $MAX_RETRIES ]]; then
        echo "  Retrying in 3s..."
        sleep 3
      fi
    fi
  done

  rm -f "$PROMPT_FILE"

  if ! $UI_SUCCESS; then
    echo "  ❌ Failed to extract valid JSON from Claude output after $MAX_RETRIES attempts"
    exit 1
  fi
else
  echo "  ⚠️  Claude CLI not available"
  exit 1
fi

# ── Validate ──────────────────────────────────────
if [[ -f "$SPECS_DIR/ui-spec.json" ]]; then
  PAGES=$(jq '.pages | length' "$SPECS_DIR/ui-spec.json")
  NAV_ITEMS=$(jq '(.navigation.items // .navigation.sidebar_items) | length' "$SPECS_DIR/ui-spec.json")
  PRIMARY=$(jq -r '.theme.primary_color' "$SPECS_DIR/ui-spec.json")
  ARCHETYPE=$(jq -r '.theme.archetype // "SAAS"' "$SPECS_DIR/ui-spec.json")

  if [[ "$PAGES" -lt 3 ]]; then
    echo "  ❌ Validation failed: fewer than 3 pages"
    exit 1
  fi

  echo ""
  echo "  ✅ UI Spec generated successfully"
  echo "     Archetype: $ARCHETYPE"
  echo "     Theme:     $PRIMARY"
  echo "     Pages:     $PAGES"
  echo "     Nav Items: $NAV_ITEMS"
  echo ""
  echo "  📄 $SPECS_DIR/ui-spec.json"
else
  echo "  ❌ Failed to generate UI spec"
  exit 1
fi

echo "  ✅ Stage 2 complete"
