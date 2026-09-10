#!/usr/bin/env bash
# Spectraal SpecPilot — Robust JSON Extraction from Claude CLI Output
#
# Claude --output-format json wraps the response in {"result": "..."}.
# The inner string may contain markdown fences, trailing text, or escaped content.
# This function handles all those cases.

extract_json_from_claude() {
  local raw_output="$1"
  local output_file="$2"
  local tmp_file="${output_file}.tmp"

  # Strategy 1: Claude wraps in {"result": "..."}
  # NOTE: Use printf instead of echo throughout — zsh's echo interprets
  # \n inside JSON strings as real newlines, breaking the JSON.
  if printf '%s\n' "$raw_output" | jq -e '.result' &>/dev/null 2>&1; then
    local result_text
    result_text=$(printf '%s\n' "$raw_output" | jq -r '.result')

    # 1a: Result is already valid JSON
    if printf '%s\n' "$result_text" | jq '.' > "$tmp_file" 2>/dev/null; then
      mv "$tmp_file" "$output_file"
      return 0
    fi

    # 1b: Strip markdown fences
    local cleaned
    cleaned=$(printf '%s\n' "$result_text" | sed 's/^```json[[:space:]]*//; s/^```[[:space:]]*//; s/```[[:space:]]*$//')
    if printf '%s\n' "$cleaned" | jq '.' > "$tmp_file" 2>/dev/null; then
      mv "$tmp_file" "$output_file"
      return 0
    fi

    # 1c: Use Python to extract first complete JSON object
    if command -v python3 &>/dev/null; then
      if printf '%s\n' "$result_text" | python3 -c "
import sys, json
text = sys.stdin.read()
# Strip markdown fences
for fence in ['\`\`\`json', '\`\`\`']:
    text = text.replace(fence, '')
text = text.strip()
start = text.find('{')
if start == -1:
    sys.exit(1)
depth = 0
in_str = False
escape = False
for i in range(start, len(text)):
    c = text[i]
    if escape:
        escape = False
        continue
    if c == '\\\\':
        escape = True
        continue
    if c == '\"':
        in_str = not in_str
        continue
    if in_str:
        continue
    if c == '{': depth += 1
    elif c == '}': depth -= 1
    if depth == 0:
        obj = json.loads(text[start:i+1])
        json.dump(obj, sys.stdout, indent=2)
        sys.exit(0)
sys.exit(1)
" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$output_file"
        return 0
      fi
    fi
  fi

  # Strategy 2: Raw output is already valid JSON (no wrapper)
  if printf '%s\n' "$raw_output" | jq '.' > "$tmp_file" 2>/dev/null; then
    # Check it's actual spec content, not the wrapper
    if printf '%s\n' "$raw_output" | jq -e 'has("project_name") or has("stack") or has("theme") or has("tasks") or has("status") or has("pages")' &>/dev/null 2>&1; then
      mv "$tmp_file" "$output_file"
      return 0
    fi
  fi

  # Strategy 3: Strip all markdown fences from raw output
  local stripped
  stripped=$(printf '%s\n' "$raw_output" | sed '/^```/d')
  if printf '%s\n' "$stripped" | jq '.' > "$tmp_file" 2>/dev/null; then
    mv "$tmp_file" "$output_file"
    return 0
  fi

  # Cleanup
  rm -f "$tmp_file"
  return 1
}
