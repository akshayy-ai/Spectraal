#!/usr/bin/env bash
# Spectraal — OpenSpec Import
# ============================================
# Clones/copies an OpenSpec repository, reads its Markdown specs,
# and converts them to Spectraal JSON format via Claude.
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

if [[ "$OPENSPEC_SOURCE" =~ ^https?:// ]] || [[ "$OPENSPEC_SOURCE" =~ ^git@ ]]; then
  log_info "Cloning OpenSpec repository: $OPENSPEC_SOURCE"
  OPENSPEC_DIR="$BUILD_DIR/.openspec-repo"
  rm -rf "$OPENSPEC_DIR"

  if ! git clone --depth 1 "$OPENSPEC_SOURCE" "$OPENSPEC_DIR" 2>&1; then
    log_error "Failed to clone OpenSpec repository: $OPENSPEC_SOURCE"
    log_info "Check the URL and your access permissions"
    exit 1
  fi
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

# OpenSpec standard locations: specs/, then root .md files
if [[ -d "$OPENSPEC_DIR/specs" ]]; then
  while IFS= read -r f; do
    SPEC_FILES+=("$f")
  done < <(find "$OPENSPEC_DIR/specs" -name "*.md" -type f | sort)
fi

# Also check for changes/ directory (proposed changes)
if [[ -d "$OPENSPEC_DIR/changes" ]]; then
  while IFS= read -r f; do
    SPEC_FILES+=("$f")
  done < <(find "$OPENSPEC_DIR/changes" -name "*.md" -type f | sort)
fi

# If no specs/ directory, look for .md files at root (excluding README, CHANGELOG, etc.)
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

# ── Concatenate all spec content ────────────────────────────

COMBINED_SPECS=""
for f in "${SPEC_FILES[@]}"; do
  COMBINED_SPECS+="
---
## File: $(basename "$f")
---

$(cat "$f")

"
done

# ── Convert via Claude ──────────────────────────────────────

log_info "Converting OpenSpec Markdown → Spectraal JSON specs..."

CONVERT_PROMPT=$(cat "$SPECTRAAL_ROOT/prompts/openspec-convert.md")

SPECS_DIR="$BUILD_DIR/specs"
mkdir -p "$SPECS_DIR"

# Build the full prompt
FULL_PROMPT="$CONVERT_PROMPT

---

## OpenSpec Configuration

$OPENSPEC_CONFIG

## OpenSpec Markdown Content

$COMBINED_SPECS

---

Convert the above OpenSpec specifications into the 4 Spectraal JSON files. Output each as a fenced code block with a comment line like: // filename: prd.json"

# Call Claude for conversion
CONVERT_OUTPUT=$(claude_tracked "openspec-convert" -p \
  --output-format text \
  "$FULL_PROMPT" 2>&1) || {
  log_error "Claude conversion failed"
  echo "$CONVERT_OUTPUT" | tail -20
  exit 1
}

# ── Extract JSON files from Claude output ───────────────────

log_substep "Extracting generated spec files..."

extract_json() {
  local filename="$1"
  local output="$2"
  local target="$3"

  # Try to extract JSON block after the filename marker
  # Handles both // filename: X.json and ### X. or **X.json** patterns
  local json_content
  json_content=$(echo "$output" | \
    awk -v fname="$filename" '
      BEGIN { found=0; depth=0; collecting=0 }
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

  # Validate JSON
  if echo "$json_content" | jq empty 2>/dev/null; then
    echo "$json_content" | jq '.' > "$target"
    return 0
  fi

  return 1
}

EXTRACTED=0

for fname in prd.json architecture.json ui-spec.json tasks.json; do
  if extract_json "$fname" "$CONVERT_OUTPUT" "$SPECS_DIR/$fname"; then
    log_success "  ✓ $fname"
    EXTRACTED=$((EXTRACTED + 1))
  else
    log_warn "  ✗ $fname — extraction failed, retrying with fallback..."

    # Fallback: extract Nth JSON block (prd=1, arch=2, ui=3, tasks=4)
    case "$fname" in
      prd.json) N=1 ;;
      architecture.json) N=2 ;;
      ui-spec.json) N=3 ;;
      tasks.json) N=4 ;;
    esac

    BLOCK=$(echo "$CONVERT_OUTPUT" | \
      awk -v n="$N" '
        /^```json/ { count++; if (count==n) { collecting=1; next } }
        collecting && /^```/ { collecting=0; next }
        collecting { print }
      ')

    if [[ -n "$BLOCK" ]] && echo "$BLOCK" | jq empty 2>/dev/null; then
      echo "$BLOCK" | jq '.' > "$SPECS_DIR/$fname"
      log_success "  ✓ $fname (fallback extraction)"
      EXTRACTED=$((EXTRACTED + 1))
    else
      log_error "  ✗ $fname — could not extract valid JSON"
    fi
  fi
done

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
  "spec_files": ${#SPEC_FILES[@]},
  "extracted_specs": $EXTRACTED,
  "imported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# ── Cleanup cloned repo ────────────────────────────────────

if [[ -d "$BUILD_DIR/.openspec-repo" ]]; then
  rm -rf "$BUILD_DIR/.openspec-repo"
  log_substep "Cleaned up cloned repository"
fi

log_success "OpenSpec import complete — $EXTRACTED spec files ready"
log_info "Specs directory: $SPECS_DIR"
