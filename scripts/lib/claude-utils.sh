#!/usr/bin/env bash
# Spectraal — Claude CLI Utilities
# =============================================

# Source logging (use _CU_DIR to avoid clobbering caller's SCRIPT_DIR)
_CU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CU_DIR/logging.sh"
source "$_CU_DIR/cost-tracker.sh" 2>/dev/null || true

# Get Spectraal root directory
get_sdd_root() {
  local dir="$_CU_DIR"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/config.yaml" ] && [ -f "$dir/factory.sh" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  # Fallback: assume scripts/lib/ structure
  echo "$(cd "$SCRIPT_DIR/../.." && pwd)"
}

SPECTRAAL_ROOT="$(get_sdd_root)"

# Read config value using grep/sed (no yq dependency)
config_get() {
  local key="$1"
  local default="$2"
  local value
  value=$(grep -E "^\s*${key}:" "$SPECTRAAL_ROOT/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | tr -d '"' | tr -d "'")
  echo "${value:-$default}"
}

# Check Claude CLI is available
check_claude() {
  if ! command -v claude &>/dev/null; then
    log_error "Claude Code CLI not found. Install: npm install -g @anthropic-ai/claude-code"
    exit 1
  fi
  log_info "Claude Code CLI: $(claude --version 2>/dev/null)"
}

# Run Claude in non-interactive print mode
# Usage: run_claude "prompt" [--json-schema file] [--system-prompt file] [--workdir dir]
run_claude() {
  local prompt="$1"
  shift

  local json_schema=""
  local system_prompt=""
  local workdir="."
  local allowed_tools=""
  local model=""
  local timeout=""

  # Parse optional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json-schema)
        json_schema="$2"
        shift 2
        ;;
      --system-prompt)
        system_prompt="$2"
        shift 2
        ;;
      --workdir)
        workdir="$2"
        shift 2
        ;;
      --allowed-tools)
        allowed_tools="$2"
        shift 2
        ;;
      --model)
        model="$2"
        shift 2
        ;;
      --timeout)
        timeout="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  # Build command
  local cmd="claude -p"

  # Add model if specified
  if [ -n "$model" ]; then
    cmd="$cmd --model $model"
  fi

  # Add permission bypass for automation
  cmd="$cmd --dangerously-skip-permissions"

  # Add allowed tools
  if [ -n "$allowed_tools" ]; then
    cmd="$cmd --allowedTools \"$allowed_tools\""
  else
    local default_tools
    default_tools=$(config_get "allowed_tools" "Read,Write,Edit,Bash")
    cmd="$cmd --allowedTools \"$default_tools\""
  fi

  # Add JSON schema for structured output
  if [ -n "$json_schema" ]; then
    local schema_content
    schema_content=$(cat "$json_schema")
    cmd="$cmd --output-format json --json-schema '$schema_content'"
  fi

  # Add system prompt
  if [ -n "$system_prompt" ]; then
    local sp_content
    sp_content=$(cat "$system_prompt")
    cmd="$cmd --append-system-prompt '$sp_content'"
  fi

  # Set timeout
  local max_timeout="${timeout:-900}"

  # Execute
  log_substep "Running Claude CLI (timeout: ${max_timeout}s)..."

  cd "$workdir" || exit 1

  # Run with timeout
  if [ -n "$json_schema" ]; then
    # Structured output mode — need to capture JSON
    local schema_content
    schema_content=$(cat "$json_schema")
    timeout "$max_timeout" claude_tracked_json "claude-utils" -p \
      --dangerously-skip-permissions \
      --allowedTools "Read,Write,Edit,Bash" \
      --output-format json \
      --json-schema "$schema_content" \
      "$prompt" 2>/dev/null
  elif [ -n "$system_prompt" ]; then
    local sp_content
    sp_content=$(cat "$system_prompt")
    timeout "$max_timeout" claude_tracked "claude-utils" -p \
      --dangerously-skip-permissions \
      --allowedTools "Read,Write,Edit,Bash" \
      --append-system-prompt "$sp_content" \
      "$prompt" 2>/dev/null
  else
    timeout "$max_timeout" claude_tracked "claude-utils" -p \
      --dangerously-skip-permissions \
      --allowedTools "Read,Write,Edit,Bash" \
      "$prompt" 2>/dev/null
  fi

  local exit_code=$?
  cd - >/dev/null || true

  if [ $exit_code -eq 124 ]; then
    log_error "Claude CLI timed out after ${max_timeout}s"
    return 1
  elif [ $exit_code -ne 0 ]; then
    log_error "Claude CLI exited with code $exit_code"
    return $exit_code
  fi

  return 0
}

# Run Claude for code generation (in a working directory)
run_claude_generate() {
  local prompt="$1"
  local workdir="$2"
  local system_prompt_file="$3"
  local max_timeout="${4:-900}"

  log_substep "Generating code in $workdir..."

  local cmd_args=()
  cmd_args+=(-p)
  cmd_args+=(--dangerously-skip-permissions)
  cmd_args+=(--allowedTools "Read,Write,Edit,Bash")

  if [ -n "$system_prompt_file" ] && [ -f "$system_prompt_file" ]; then
    local sp_content
    sp_content=$(cat "$system_prompt_file")
    cmd_args+=(--append-system-prompt "$sp_content")
  fi

  cd "$workdir" || exit 1
  timeout "$max_timeout" claude "${cmd_args[@]}" "$prompt"
  local exit_code=$?
  cd - >/dev/null || true

  return $exit_code
}

# Extract JSON from Claude's output (handles markdown code blocks)
extract_json() {
  local input="$1"

  # Try direct JSON parse first
  if echo "$input" | jq '.' 2>/dev/null; then
    return 0
  fi

  # Try extracting from markdown code block
  echo "$input" | sed -n '/```json/,/```/p' | sed '1d;$d' | jq '.'
  return $?
}
