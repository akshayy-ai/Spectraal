#!/usr/bin/env bash
# Spectraal — Cost & Token Tracker
# =====================================================================
# Tracks Claude CLI cost/token usage across the pipeline.
#
# How it works:
#   1. cost_init creates a tracking file
#   2. A wrapper script intercepts `claude -p` calls
#   3. After the call, it parses Claude CLI's stderr/session for cost
#   4. cost_summary/cost_report generate the final numbers
#
# Strategy: Instead of modifying every script that calls Claude,
# we use a simple approach — each stage that calls Claude exports
# COST_STAGE, and we use `claude` session metadata after the fact.
# For the simplest implementation, we track cost by timing and
# estimating, OR by wrapping with --output-format stream-json.
#
# Usage:
#   source scripts/lib/cost-tracker.sh
#   cost_init "$BUILD_DIR"
#   cost_record "stage-name" "model" input_tokens output_tokens cost_usd
#   cost_summary
#   cost_report "$PROJECT_DIR"

COST_FILE=""

# ── Initialize ───────────────────────────────────────────────

cost_init() {
  local build_dir="$1"
  COST_FILE="$build_dir/cost-tracking.json"
  export SPECTRAAL_COST_FILE="$COST_FILE"

  cat > "$COST_FILE" <<INIT
{
  "pipeline_start": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "calls": [],
  "totals": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_tokens": 0,
    "cache_creation_tokens": 0,
    "total_cost_usd": 0,
    "call_count": 0
  }
}
INIT
}

# ── Record a Claude call ─────────────────────────────────────
# Called by individual stage scripts after running Claude CLI

cost_record() {
  local stage="$1"
  local model="${2:-unknown}"
  local input_tokens="${3:-0}"
  local output_tokens="${4:-0}"
  local cost_usd="${5:-0}"
  local cache_read="${6:-0}"
  local cache_create="${7:-0}"

  local cost_file="${SPECTRAAL_COST_FILE:-$COST_FILE}"

  if [ -z "$cost_file" ] || [ ! -f "$cost_file" ]; then
    return 0
  fi

  if jq --arg stage "$stage" --arg model "$model" \
     --argjson cost "${cost_usd:-0}" \
     --argjson inp "${input_tokens:-0}" --argjson out "${output_tokens:-0}" \
     --argjson cr "${cache_read:-0}" --argjson cc "${cache_create:-0}" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.calls += [{
      stage: $stage,
      model: $model,
      timestamp: $ts,
      input_tokens: $inp,
      output_tokens: $out,
      cache_read_tokens: $cr,
      cache_creation_tokens: $cc,
      cost_usd: $cost
    }] |
    .totals.input_tokens += $inp |
    .totals.output_tokens += $out |
    .totals.cache_read_tokens += $cr |
    .totals.cache_creation_tokens += $cc |
    .totals.total_cost_usd += $cost |
    .totals.call_count += 1' \
    "$cost_file" > "$cost_file.tmp" 2>/dev/null; then
    mv "$cost_file.tmp" "$cost_file"
  else
    rm -f "$cost_file.tmp"
  fi
}

# ── Run Claude with cost capture ─────────────────────────────
# Drop-in replacement: claude_tracked "stage" [all normal claude args...]
# Runs claude -p with stream-json capture, extracts cost, outputs text.

claude_tracked() {
  local stage="$1"
  shift

  local cost_file="${SPECTRAAL_COST_FILE:-$COST_FILE}"

  # If no cost tracking, just run normally
  if [ -z "$cost_file" ] || [ ! -f "$cost_file" ]; then
    claude "$@"
    return $?
  fi

  # Run with stream-json to capture usage
  local temp_out
  temp_out=$(mktemp)

  claude "$@" --output-format stream-json --verbose > "$temp_out" 2>/dev/null
  local exit_code=$?

  # Extract text result
  local result_line
  result_line=$(grep '"type":"result"' "$temp_out" 2>/dev/null | tail -1)

  # Output text (what the caller expects from -p)
  if [ -n "$result_line" ]; then
    echo "$result_line" | jq -r '.result // empty' 2>/dev/null || true
  fi

  # Extract and record cost
  if [ -n "$result_line" ]; then
    local cost_usd input_tokens output_tokens cache_read cache_create model
    cost_usd=$(echo "$result_line" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "0")
    input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
    output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
    cache_read=$(echo "$result_line" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo "0")
    cache_create=$(echo "$result_line" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo "0")
    model=$(echo "$result_line" | jq -r '.modelUsage | keys[0] // "unknown"' 2>/dev/null || echo "unknown")

    cost_record "$stage" "$model" "$input_tokens" "$output_tokens" "$cost_usd" "$cache_read" "$cache_create"
  fi

  rm -f "$temp_out"
  return $exit_code
}

# ── Run Claude with cost capture (JSON output mode) ──────────
# For scripts that need --output-format json (SpecPilot stages).
# Strips any existing --output-format from args, runs stream-json,
# extracts the JSON result field, and records cost.
#
# Usage: claude_tracked_json "stage" [all normal claude args...]

claude_tracked_json() {
  local stage="$1"
  shift

  local cost_file="${SPECTRAAL_COST_FILE:-$COST_FILE}"

  # If no cost tracking, just run normally with json output
  if [ -z "$cost_file" ] || [ ! -f "$cost_file" ]; then
    claude "$@"
    return $?
  fi

  # Strip any existing --output-format from args
  local new_args=()
  local skip_next=false
  for arg in "$@"; do
    if $skip_next; then
      skip_next=false
      continue
    fi
    if [ "$arg" = "--output-format" ]; then
      skip_next=true
      continue
    fi
    new_args+=("$arg")
  done

  # Run with stream-json to capture usage
  local temp_out
  temp_out=$(mktemp)

  claude "${new_args[@]}" --output-format stream-json --verbose > "$temp_out" 2>/dev/null
  local exit_code=$?

  # Extract result line
  local result_line
  result_line=$(grep '"type":"result"' "$temp_out" 2>/dev/null | tail -1)

  # Output the JSON result (what the caller expects from --output-format json)
  if [ -n "$result_line" ]; then
    # The result field contains the text — for JSON mode callers,
    # this is the JSON string that Claude produced
    echo "$result_line" | jq -r '.result // empty' 2>/dev/null || true
  fi

  # Extract and record cost
  if [ -n "$result_line" ]; then
    local cost_usd input_tokens output_tokens cache_read cache_create model
    cost_usd=$(echo "$result_line" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "0")
    input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
    output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
    cache_read=$(echo "$result_line" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo "0")
    cache_create=$(echo "$result_line" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo "0")
    model=$(echo "$result_line" | jq -r '.modelUsage | keys[0] // "unknown"' 2>/dev/null || echo "unknown")

    cost_record "$stage" "$model" "$input_tokens" "$output_tokens" "$cost_usd" "$cache_read" "$cache_create"
  fi

  rm -f "$temp_out"
  return $exit_code
}

# ── Print cost summary ───────────────────────────────────────

cost_summary() {
  local cost_file="${SPECTRAAL_COST_FILE:-$COST_FILE}"

  if [ -z "$cost_file" ] || [ ! -f "$cost_file" ]; then
    return 0
  fi

  local total_cost calls input_tokens output_tokens

  total_cost=$(jq -r '.totals.total_cost_usd' "$cost_file")
  calls=$(jq -r '.totals.call_count' "$cost_file")
  input_tokens=$(jq -r '.totals.input_tokens' "$cost_file")
  output_tokens=$(jq -r '.totals.output_tokens' "$cost_file")

  if [ "$calls" -eq 0 ]; then
    return 0
  fi

  local cost_display
  cost_display=$(printf '$%.4f' "$total_cost" 2>/dev/null || echo "\$0.00")

  echo ""
  echo "┌─────────────────────────────────────┐"
  echo "│       COST & TOKEN USAGE            │"
  echo "├─────────────────────────────────────┤"
  echo "│  Claude Calls: $calls"
  echo "│  Input Tokens: $input_tokens"
  echo "│  Output Tokens: $output_tokens"
  echo "│  Total Cost:   $cost_display"
  echo "├─────────────────────────────────────┤"

  # Per-stage breakdown
  jq -r '.calls[] | "│  \(.stage | .[0:16] | . + " " * (16 - length))  $\(.cost_usd | tostring | .[0:8] | . + " " * (8 - length))  \(.model)"' "$cost_file" 2>/dev/null || true

  echo "└─────────────────────────────────────┘"
}

# ── Generate cost report ─────────────────────────────────────

cost_report() {
  local cost_file="${SPECTRAAL_COST_FILE:-$COST_FILE}"

  if [ -z "$cost_file" ] || [ ! -f "$cost_file" ]; then
    return 0
  fi

  # Validate JSON before modifying
  if ! jq empty "$cost_file" 2>/dev/null; then
    echo "  ⚠️  Cost file is not valid JSON, skipping report" >&2
    return 0
  fi

  if jq --arg end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {pipeline_end: $end}' "$cost_file" > "$cost_file.tmp" 2>/dev/null; then
    mv "$cost_file.tmp" "$cost_file"
  else
    rm -f "$cost_file.tmp"
    echo "  ⚠️  Failed to update cost report" >&2
  fi
}

# ── Update build-meta with cost data ─────────────────────────

cost_update_meta() {
  local cost_file="${SPECTRAAL_COST_FILE:-$COST_FILE}"

  if [ -z "$cost_file" ] || [ ! -f "$cost_file" ]; then
    return 0
  fi

  # Find project dir's build-meta.json
  # cost_file is at BUILD_DIR/cost-tracking.json
  # build-meta is at BUILD_DIR/PROJECT_NAME/build-meta.json
  local build_dir
  build_dir=$(dirname "$cost_file")

  # Find any build-meta.json under the build dir
  local meta
  meta=$(find "$build_dir" -maxdepth 2 -name "build-meta.json" 2>/dev/null | head -1)

  if [ -z "$meta" ] || [ ! -f "$meta" ]; then
    return 0
  fi

  local total_cost calls input_tokens output_tokens models
  total_cost=$(jq -r '.totals.total_cost_usd' "$cost_file")
  calls=$(jq -r '.totals.call_count' "$cost_file")
  input_tokens=$(jq -r '.totals.input_tokens' "$cost_file")
  output_tokens=$(jq -r '.totals.output_tokens' "$cost_file")
  models=$(jq -r '[.calls[].model] | unique | join(", ")' "$cost_file" 2>/dev/null || echo "unknown")

  if jq --argjson cost "${total_cost:-0}" --argjson calls "${calls:-0}" \
     --argjson inp "${input_tokens:-0}" --argjson out "${output_tokens:-0}" \
     --arg models "${models:-unknown}" \
    '.cost = {total_usd: $cost, claude_calls: $calls, input_tokens: $inp, output_tokens: $out, models: $models}' \
    "$meta" > "$meta.tmp" 2>/dev/null; then
    mv "$meta.tmp" "$meta"
  else
    rm -f "$meta.tmp"
  fi
}
