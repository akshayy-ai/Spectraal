#!/usr/bin/env bash
# Spectraal — OpenSpec Import
# ============================================
# Imports specs from an OpenSpec repository and converts them
# to Spectraal JSON format.
#
# Two modes:
#   1. CLI mode  — uses `openspec` CLI (faster, no Claude cost)
#   2. Claude mode — Claude reads Markdown and outputs JSON (no dependency)
#
# Automatically picks CLI mode when `openspec` is installed,
# falls back to Claude mode otherwise.
#
# Input:  OpenSpec source (GitHub URL or local path)
# Output: Spectraal specs in $BUILD_DIR/specs/
#
# Usage: openspec-import.sh <url-or-path> <build-dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECTRAAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true

OPENSPEC_SOURCE="${1:?Usage: openspec-import.sh <url-or-path> <build-dir>}"
BUILD_DIR="${2:?Usage: openspec-import.sh <url-or-path> <build-dir>}"

log_step "0" "OPENSPEC IMPORT"

# ── Resolve OpenSpec source ─────────────────────────────────

OPENSPEC_DIR=""
CLONED=false

if [[ "$OPENSPEC_SOURCE" =~ ^https?:// ]] || [[ "$OPENSPEC_SOURCE" =~ ^git@ ]]; then
  log_info "Cloning OpenSpec repository: $OPENSPEC_SOURCE"
  OPENSPEC_DIR="$BUILD_DIR/.openspec-repo"
  rm -rf "$OPENSPEC_DIR"

  if ! git clone --depth 1 "$OPENSPEC_SOURCE" "$OPENSPEC_DIR" 2>&1; then
    log_error "Failed to clone OpenSpec repository: $OPENSPEC_SOURCE"
    log_info "Check the URL and your access permissions"
    exit 1
  fi
  CLONED=true
  log_success "Repository cloned"
elif [[ -d "$OPENSPEC_SOURCE" ]]; then
  log_info "Using local OpenSpec directory: $OPENSPEC_SOURCE"
  OPENSPEC_DIR="$(cd "$OPENSPEC_SOURCE" && pwd)"
else
  log_error "OpenSpec source not found: $OPENSPEC_SOURCE"
  log_info "Provide a GitHub URL or a local directory path"
  exit 1
fi

# ── Discover spec files ─────────────────────────────────────

log_substep "Scanning for OpenSpec Markdown files..."

SPEC_FILES=()

if [[ -d "$OPENSPEC_DIR/specs" ]]; then
  while IFS= read -r f; do
    SPEC_FILES+=("$f")
  done < <(find "$OPENSPEC_DIR/specs" -name "*.md" -type f | sort)
fi

if [[ -d "$OPENSPEC_DIR/changes" ]]; then
  while IFS= read -r f; do
    SPEC_FILES+=("$f")
  done < <(find "$OPENSPEC_DIR/changes" -name "*.md" -type f | sort)
fi

if [[ ${#SPEC_FILES[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    basename_lower=$(basename "$f" | tr '[:upper:]' '[:lower:]')
    case "$basename_lower" in
      readme.md|changelog.md|contributing.md|license.md|code_of_conduct.md) continue ;;
      *) SPEC_FILES+=("$f") ;;
    esac
  done < <(find "$OPENSPEC_DIR" -maxdepth 2 -name "*.md" -type f | sort)
fi

if [[ ${#SPEC_FILES[@]} -eq 0 ]]; then
  log_error "No spec Markdown files found in: $OPENSPEC_SOURCE"
  log_info "Expected: specs/*.md or *.md files in the repository root"
  exit 1
fi

log_info "Found ${#SPEC_FILES[@]} spec file(s):"
for f in "${SPEC_FILES[@]}"; do
  log_substep "  $(basename "$f")"
done

# ── Read OpenSpec config if present ─────────────────────────

OPENSPEC_CONFIG=""
if [[ -f "$OPENSPEC_DIR/config.yaml" ]]; then
  OPENSPEC_CONFIG=$(cat "$OPENSPEC_DIR/config.yaml")
  log_info "Found OpenSpec config.yaml"
elif [[ -f "$OPENSPEC_DIR/openspec.yaml" ]]; then
  OPENSPEC_CONFIG=$(cat "$OPENSPEC_DIR/openspec.yaml")
  log_info "Found openspec.yaml"
fi

SPECS_DIR="$BUILD_DIR/specs"
mkdir -p "$SPECS_DIR"

# ── Detect import mode ──────────────────────────────────────

USE_CLI=false
if command -v openspec &>/dev/null; then
  OPENSPEC_VER=$(openspec --version 2>&1 | head -1 || echo "unknown")
  log_info "OpenSpec CLI detected: $OPENSPEC_VER"
  USE_CLI=true
else
  log_info "OpenSpec CLI not found — using Claude conversion mode"
  log_substep "Install openspec for faster imports: npm install -g @fission-ai/openspec"
fi

# ════════════════════════════════════════════════════════════
# MODE 1: OpenSpec CLI (fast, zero Claude cost)
# ════════════════════════════════════════════════════════════

import_via_cli() {
  log_info "Importing via OpenSpec CLI..."

  # Initialize openspec in the repo dir if not already
  if [[ ! -f "$OPENSPEC_DIR/.openspec" ]] && [[ ! -f "$OPENSPEC_DIR/config.yaml" ]]; then
    log_substep "Initializing OpenSpec in repo..."
    (cd "$OPENSPEC_DIR" && openspec init --quiet 2>/dev/null) || true
  fi

  # Use openspec context to extract structured spec data
  log_substep "Extracting spec context via CLI..."
  local context_output
  context_output=$(cd "$OPENSPEC_DIR" && openspec context 2>/dev/null) || context_output=""

  # Use openspec show on each spec to get parsed content
  local all_specs=""
  for f in "${SPEC_FILES[@]}"; do
    local spec_name
    spec_name=$(basename "$f" .md)
    local show_output
    show_output=$(cd "$OPENSPEC_DIR" && openspec show "$spec_name" 2>/dev/null) || show_output=""
    if [[ -n "$show_output" ]]; then
      all_specs+="$show_output"$'\n\n'
    fi
  done

  # If openspec show didn't produce useful output, read files directly
  if [[ -z "$all_specs" ]]; then
    log_substep "CLI show returned empty — reading spec files directly..."
    for f in "${SPEC_FILES[@]}"; do
      all_specs+="--- $(basename "$f") ---"$'\n'
      all_specs+="$(cat "$f")"$'\n\n'
    done
  fi

  # Validate specs if possible
  log_substep "Validating specs..."
  (cd "$OPENSPEC_DIR" && openspec validate 2>&1) || log_warn "Spec validation had warnings"

  # Now use Claude with the CLI-parsed context for a lighter conversion
  # The CLI already parsed the Markdown structure, so Claude just maps fields
  local cli_prompt="You have OpenSpec CLI-parsed specifications. Convert them to Spectraal JSON format.

## OpenSpec Context (from CLI)
${context_output}

## Parsed Specs
${all_specs}

## OpenSpec Config
${OPENSPEC_CONFIG}

$(cat "$SPECTRAAL_ROOT/prompts/openspec-convert.md")

Convert the above into the 4 Spectraal JSON files. Output each as a fenced code block with a comment line like: // filename: prd.json"

  CONVERT_OUTPUT=$(claude_tracked "openspec-cli-convert" -p \
    --output-format text \
    "$cli_prompt" 2>&1) || {
    log_warn "CLI-assisted conversion failed — falling back to full Claude mode"
    return 1
  }

  extract_all_specs
}

# ════════════════════════════════════════════════════════════
# MODE 2: Claude conversion (no dependency required)
# ════════════════════════════════════════════════════════════

import_via_claude() {
  log_info "Converting OpenSpec Markdown → Spectraal JSON via Claude..."

  local combined_specs=""
  for f in "${SPEC_FILES[@]}"; do
    combined_specs+="
---
## File: $(basename "$f")
---

$(cat "$f")

"
  done

  local convert_prompt
  convert_prompt=$(cat "$SPECTRAAL_ROOT/prompts/openspec-convert.md")

  local full_prompt="$convert_prompt

---

## OpenSpec Configuration

$OPENSPEC_CONFIG

## OpenSpec Markdown Content

$combined_specs

---

Convert the above OpenSpec specifications into the 4 Spectraal JSON files. Output each as a fenced code block with a comment line like: // filename: prd.json"

  CONVERT_OUTPUT=$(claude_tracked "openspec-convert" -p \
    --output-format text \
    "$full_prompt" 2>&1) || {
    log_error "Claude conversion failed"
    echo "$CONVERT_OUTPUT" | tail -20
    exit 1
  }

  extract_all_specs
}

# ════════════════════════════════════════════════════════════
# Shared: Extract JSON from Claude output
# ════════════════════════════════════════════════════════════

EXTRACTED=0
CONVERT_OUTPUT=""

extract_json() {
  local filename="$1"
  local output="$2"
  local target="$3"

  local json_content
  json_content=$(echo "$output" | \
    awk -v fname="$filename" '
      BEGIN { found=0; collecting=0 }
      /```json/ && !collecting {
        if (found || !fname) { collecting=1; next }
      }
      tolower($0) ~ tolower(fname) { found=1 }
      collecting && /^```$/ { collecting=0; found=0; next }
      collecting { print }
    ')

  if [[ -z "$json_content" ]]; then
    return 1
  fi

  if echo "$json_content" | jq empty 2>/dev/null; then
    echo "$json_content" | jq '.' > "$target"
    return 0
  fi

  return 1
}

extract_all_specs() {
  log_substep "Extracting generated spec files..."

  EXTRACTED=0

  for fname in prd.json architecture.json ui-spec.json tasks.json; do
    if extract_json "$fname" "$CONVERT_OUTPUT" "$SPECS_DIR/$fname"; then
      log_success "  ✓ $fname"
      EXTRACTED=$((EXTRACTED + 1))
    else
      # Fallback: extract Nth JSON block
      local n
      case "$fname" in
        prd.json) n=1 ;;
        architecture.json) n=2 ;;
        ui-spec.json) n=3 ;;
        tasks.json) n=4 ;;
      esac

      local block
      block=$(echo "$CONVERT_OUTPUT" | \
        awk -v n="$n" '
          /^```json/ { count++; if (count==n) { collecting=1; next } }
          collecting && /^```/ { collecting=0; next }
          collecting { print }
        ')

      if [[ -n "$block" ]] && echo "$block" | jq empty 2>/dev/null; then
        echo "$block" | jq '.' > "$SPECS_DIR/$fname"
        log_success "  ✓ $fname (positional extraction)"
        EXTRACTED=$((EXTRACTED + 1))
      else
        log_error "  ✗ $fname — could not extract valid JSON"
      fi
    fi
  done
}

# ── Run import ──────────────────────────────────────────────

if $USE_CLI; then
  import_via_cli || import_via_claude
else
  import_via_claude
fi

# ── Verify extraction ───────────────────────────────────────

if [[ $EXTRACTED -lt 2 ]]; then
  log_error "Only extracted $EXTRACTED/4 spec files — conversion failed"
  log_info "Raw output saved to: $BUILD_DIR/openspec-convert-raw.txt"
  echo "$CONVERT_OUTPUT" > "$BUILD_DIR/openspec-convert-raw.txt"
  exit 1
fi

if [[ $EXTRACTED -lt 4 ]]; then
  log_warn "Extracted $EXTRACTED/4 spec files — some may be missing"
fi

# ── Generate requirements.txt from PRD ──────────────────────

if [[ -f "$SPECS_DIR/prd.json" ]]; then
  DESCRIPTION=$(jq -r '.description // ""' "$SPECS_DIR/prd.json")
  FEATURES=$(jq -r '.scope.features[]?.name // empty' "$SPECS_DIR/prd.json" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
  DISPLAY_NAME=$(jq -r '.display_name // .project_name // "Application"' "$SPECS_DIR/prd.json")

  echo "Build ${DISPLAY_NAME}: ${DESCRIPTION} Features: ${FEATURES}" > "$BUILD_DIR/requirements.txt"
  log_success "Generated requirements.txt from PRD"
fi

# ── Save import metadata ────────────────────────────────────

cat > "$BUILD_DIR/openspec-import.json" <<EOF
{
  "source": "$OPENSPEC_SOURCE",
  "mode": "$(if $USE_CLI; then echo "cli"; else echo "claude"; fi)",
  "spec_files": ${#SPEC_FILES[@]},
  "extracted_specs": $EXTRACTED,
  "imported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# ── Cleanup cloned repo ────────────────────────────────────

if $CLONED && [[ -d "$BUILD_DIR/.openspec-repo" ]]; then
  rm -rf "$BUILD_DIR/.openspec-repo"
  log_substep "Cleaned up cloned repository"
fi

log_success "OpenSpec import complete — $EXTRACTED spec files ready (mode: $(if $USE_CLI; then echo "CLI"; else echo "Claude"; fi))"
log_info "Specs directory: $SPECS_DIR"
