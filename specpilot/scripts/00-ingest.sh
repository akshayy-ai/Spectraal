#!/usr/bin/env bash
# Spectraal SpecPilot — Stage 0: Requirements Ingestion
# Input:  Raw requirements text (file or stdin)
# Output: specs/prd.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/extract-json.sh"
source "$ROOT_DIR/scripts/lib/logging.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/claude-utils.sh" 2>/dev/null || true
source "$ROOT_DIR/scripts/lib/cost-tracker.sh" 2>/dev/null || true

# ── Args ──────────────────────────────────────────
REQ_FILE="${1:-}"
BUILD_DIR="${2:-}"

if [[ -z "$REQ_FILE" || -z "$BUILD_DIR" ]]; then
  echo "Usage: 00-ingest.sh <requirements-file> <build-dir>"
  exit 1
fi

SPECS_DIR="$BUILD_DIR/specs"
mkdir -p "$SPECS_DIR"

REQUIREMENTS=$(cat "$REQ_FILE")
SCHEMA=$(cat "$ROOT_DIR/specpilot/schemas/00-prd.schema.json")
PROMPT=$(cat "$ROOT_DIR/specpilot/prompts/00-ingest.md")

echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Stage 0: Requirements Ingestion → PRD                  │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "  📄 Input:  $REQ_FILE"
echo "  📁 Output: $SPECS_DIR/prd.json"
echo ""

# ── Call Claude ───────────────────────────────────
SYSTEM_PROMPT="$PROMPT

## JSON Schema for Output
The output MUST be a valid JSON object matching this schema:
\`\`\`json
$SCHEMA
\`\`\`

## Requirements from User
\`\`\`
$REQUIREMENTS
\`\`\`

Produce ONLY the JSON object. No markdown fences, no explanation."

if command -v claude &>/dev/null; then
  echo "  🤖 Calling Claude CLI (non-interactive)..."
  RESULT=$(claude_tracked_json "specpilot-ingest" -p "$SYSTEM_PROMPT" \
    --allowedTools "Read,Write,Edit,Bash" \
    --output-format json 2>/dev/null || echo "CLAUDE_ERROR")

  if [[ "$RESULT" == "CLAUDE_ERROR" ]]; then
    echo "  ❌ Claude CLI failed. Attempting fallback..."
    exit 1
  fi

  # Extract JSON from response (robust extraction)
  if ! extract_json_from_claude "$RESULT" "$SPECS_DIR/prd.json"; then
    echo "  ❌ Failed to extract valid JSON from Claude output"
    echo "$RESULT" > "$SPECS_DIR/prd-raw.txt"
    echo "  📄 Raw output saved to $SPECS_DIR/prd-raw.txt"
    exit 1
  fi
else
  echo "  ⚠️  Claude CLI not available. Place prd.json manually in $SPECS_DIR/"
  exit 1
fi

# ── Validate ──────────────────────────────────────
if [[ -f "$SPECS_DIR/prd.json" ]]; then
  # Basic validation: check required fields exist
  PROJECT_NAME=$(jq -r '.project_name // empty' "$SPECS_DIR/prd.json")
  USER_STORIES=$(jq '.user_stories | length' "$SPECS_DIR/prd.json")
  REQUIREMENTS=$(jq '.requirements | length' "$SPECS_DIR/prd.json")
  FEATURES=$(jq '.scope.features | length' "$SPECS_DIR/prd.json")

  if [[ -z "$PROJECT_NAME" ]]; then
    echo "  ❌ Validation failed: missing project_name"
    exit 1
  fi

  echo ""
  echo "  ✅ PRD generated successfully"
  echo "     Project:      $PROJECT_NAME"
  echo "     User Stories:  $USER_STORIES"
  echo "     Requirements:  $REQUIREMENTS"
  echo "     Features:      $FEATURES"
  echo ""
  echo "  📄 $SPECS_DIR/prd.json"
else
  echo "  ❌ Failed to generate PRD"
  exit 1
fi

# ── Generate Markdown (human-readable) ────────────
echo "  📝 Generating human-readable PRD markdown..."
jq -r '
  "# " + .display_name + "\n\n" +
  "> " + .description + "\n\n" +
  "**Domain:** " + .domain + " | **Complexity:** " + .scope.estimated_complexity + "\n\n" +
  "## Goals\n" + ([.goals[] | "- " + .] | join("\n")) + "\n\n" +
  "## Non-Goals\n" + ([.non_goals[] | "- " + .] | join("\n")) + "\n\n" +
  "## User Stories\n" +
  ([.user_stories[] |
    "### " + .id + ": " + .i_want + "\n" +
    "**As a** " + .as_a + ", **I want** " + .i_want + ", **so that** " + .so_that + "\n" +
    "**Priority:** " + .priority + "\n" +
    "**Acceptance Criteria:**\n" +
    ([.acceptance_criteria[] | "- [ ] " + .] | join("\n"))
  ] | join("\n\n")) + "\n\n" +
  "## Requirements\n" +
  ([.requirements[] |
    "### " + .id + "\n" +
    .description + "\n" +
    ([.scenarios[] |
      "#### Scenario: " + .name + "\n" +
      "- **GIVEN** " + .given + "\n" +
      "- **WHEN** " + .when + "\n" +
      "- **THEN** " + .then +
      (if .and then "\n" + ([.and[] | "- **AND** " + .] | join("\n")) else "" end)
    ] | join("\n\n"))
  ] | join("\n\n"))
' "$SPECS_DIR/prd.json" > "$SPECS_DIR/prd.md" 2>/dev/null || echo "  ⚠️  Markdown generation skipped"

echo "  ✅ Stage 0 complete"
