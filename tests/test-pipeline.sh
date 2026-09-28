#!/usr/bin/env bash
# Spectraal — Pipeline Integration Tests
# Validates core pipeline stages without invoking Claude API
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECTRAAL_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SPECTRAAL_ROOT/scripts/lib/logging.sh"

PASS=0
FAIL=0
TESTS_RUN=0

assert() {
  local desc="$1"
  local result="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$result" == "0" ]]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
  fi
}

assert_file() {
  local desc="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    assert "$desc" 0
  else
    assert "$desc (missing: $path)" 1
  fi
}

assert_json_key() {
  local desc="$1"
  local file="$2"
  local key="$3"
  local val
  val=$(jq -r "$key" "$file" 2>/dev/null || echo "__MISSING__")
  if [[ "$val" != "null" ]] && [[ "$val" != "__MISSING__" ]] && [[ -n "$val" ]]; then
    assert "$desc" 0
  else
    assert "$desc (key $key missing in $file)" 1
  fi
}

# ── Test Suite: Prerequisites ──────────────────────────────────

echo ""
log_info "Test Suite: Prerequisites"

command -v jq &>/dev/null
assert "jq is installed" $?

command -v docker &>/dev/null
assert "docker is installed" $?

[[ -f "$SPECTRAAL_ROOT/jarvis" ]] && [[ -x "$SPECTRAAL_ROOT/jarvis" ]]
assert "jarvis is executable" $?

for stage in 01 02 03 04 05 06 07 08 09 10; do
  STAGE_FILE=$(ls "$SPECTRAAL_ROOT/scripts/${stage}-"*.sh 2>/dev/null | head -1)
  [[ -n "$STAGE_FILE" ]]
  assert "Stage $stage script exists" $?
done

# ── Test Suite: Blueprints ─────────────────────────────────────

echo ""
log_info "Test Suite: Blueprint Integrity"

for bp in react-node-postgres react-python-fastapi; do
  BP_DIR="$SPECTRAAL_ROOT/blueprints/$bp"
  assert_file "$bp: blueprint exists" "$BP_DIR/docker-compose.yml"
  assert_file "$bp: frontend Dockerfile" "$BP_DIR/frontend/Dockerfile"
  assert_file "$bp: backend Dockerfile" "$BP_DIR/backend/Dockerfile"
  assert_file "$bp: .env template" "$BP_DIR/.env.template"

  if [[ "$bp" == "react-python-fastapi" ]]; then
    assert_file "$bp: requirements.txt" "$BP_DIR/backend/requirements.txt"
    grep -q "bcrypt==4.0.1" "$BP_DIR/backend/requirements.txt"
    assert "$bp: bcrypt pinned to 4.0.1" $?
  fi

  if [[ "$bp" == "react-node-postgres" ]]; then
    assert_file "$bp: package.json" "$BP_DIR/backend/package.json"
  fi
done

# ── Test Suite: Scaffold (dry run) ─────────────────────────────

echo ""
log_info "Test Suite: Scaffold Dry Run"

TEST_BUILD_DIR=$(mktemp -d)
TEST_SPEC_DIR="$TEST_BUILD_DIR/specs"
mkdir -p "$TEST_SPEC_DIR"

cat > "$TEST_SPEC_DIR/prd.json" <<'SPEC'
{
  "project_name": "test-app",
  "description": "Integration test application",
  "features": [
    {
      "name": "User Management",
      "priority": "must-have",
      "user_stories": [
        {"as": "admin", "i_want": "to manage users", "so_that": "I can control access"}
      ]
    }
  ]
}
SPEC

cat > "$TEST_SPEC_DIR/architecture.json" <<'SPEC'
{
  "stack": {
    "frontend": "react-tailwind",
    "backend": "node-express",
    "database": "postgresql"
  },
  "stack_profile": "full-stack",
  "data_model": {
    "entities": [
      {"name": "User", "fields": [{"name": "email", "type": "string"}, {"name": "password", "type": "string"}]}
    ]
  },
  "api_contracts": [
    {"method": "POST", "path": "/api/auth/login", "description": "Login"}
  ]
}
SPEC

cat > "$TEST_SPEC_DIR/ui-spec.json" <<'SPEC'
{
  "theme": {"primary": "#3B82F6", "style": "modern"},
  "pages": [{"name": "Dashboard", "route": "/", "layout": "sidebar"}],
  "navigation": {"type": "sidebar"}
}
SPEC

cat > "$TEST_SPEC_DIR/tasks.json" <<'SPEC'
{
  "phases": [
    {
      "name": "Setup",
      "tasks": [
        {"name": "Create models", "type": "backend", "file": "models.ts"}
      ]
    }
  ]
}
SPEC

export SPECTRAAL_BUILD_DIR="$TEST_BUILD_DIR"

# Stage 1 requires Claude API, so we test the merge logic by creating spec.json
# from the 4 spec files (same logic Stage 1 uses after Claude generates them)
log_substep "Testing spec merge logic..."

# Merge specs into spec.json (same as Stage 1 output)
jq -n \
  --slurpfile prd "$TEST_SPEC_DIR/prd.json" \
  --slurpfile arch "$TEST_SPEC_DIR/architecture.json" \
  --slurpfile ui "$TEST_SPEC_DIR/ui-spec.json" \
  --slurpfile tasks "$TEST_SPEC_DIR/tasks.json" \
  '{
    project_name: $prd[0].project_name,
    description: $prd[0].description,
    stack: $arch[0].stack,
    stack_profile: ($arch[0].stack_profile // "full-stack"),
    features: $prd[0].features,
    data_model: $arch[0].data_model,
    api_contracts: $arch[0].api_contracts,
    theme: $ui[0].theme,
    pages: $ui[0].pages,
    navigation: $ui[0].navigation,
    phases: $tasks[0].phases
  }' > "$TEST_BUILD_DIR/spec.json" 2>/dev/null

if [[ -f "$TEST_BUILD_DIR/spec.json" ]]; then
  assert "Stage 1: spec.json merge from 4 spec files" 0
  assert_json_key "Stage 1: project_name in spec.json" "$TEST_BUILD_DIR/spec.json" ".project_name"
  assert_json_key "Stage 1: stack.frontend in spec.json" "$TEST_BUILD_DIR/spec.json" ".stack.frontend"
  assert_json_key "Stage 1: stack_profile in spec.json" "$TEST_BUILD_DIR/spec.json" ".stack_profile"
  assert_json_key "Stage 1: features in spec.json" "$TEST_BUILD_DIR/spec.json" ".features[0].name"
  assert_json_key "Stage 1: data_model in spec.json" "$TEST_BUILD_DIR/spec.json" ".data_model.entities[0].name"
else
  assert "Stage 1: spec.json merge from 4 spec files" 1
fi

# Run Stage 2 (Scaffold) — test project structure
if [[ -f "$TEST_BUILD_DIR/spec.json" ]]; then
  bash "$SPECTRAAL_ROOT/scripts/02-scaffold.sh" 2>/dev/null || true
  PROJECT_DIR="$TEST_BUILD_DIR/test-app"
  if [[ -d "$PROJECT_DIR" ]]; then
    assert "Stage 2: project directory created" 0
    assert_file "Stage 2: build-meta.json" "$PROJECT_DIR/build-meta.json"
    assert_file "Stage 2: frontend Dockerfile" "$PROJECT_DIR/frontend/Dockerfile"
    assert_file "Stage 2: backend Dockerfile" "$PROJECT_DIR/backend/Dockerfile"
    assert_file "Stage 2: docker-compose.yml" "$PROJECT_DIR/docker-compose.yml"
    assert_file "Stage 2: backend .env" "$PROJECT_DIR/backend/.env"

    # Verify JWT secret is NOT "changeme"
    if [[ -f "$PROJECT_DIR/build-meta.json" ]]; then
      JWT=$(jq -r '.jwt_secret' "$PROJECT_DIR/build-meta.json")
      if [[ "$JWT" != "changeme" ]] && [[ ${#JWT} -ge 32 ]]; then
        assert "Stage 2: JWT secret is securely generated" 0
      else
        assert "Stage 2: JWT secret is securely generated (got: $JWT)" 1
      fi

      # Verify blueprint detected
      assert_json_key "Stage 2: blueprint in build-meta.json" "$PROJECT_DIR/build-meta.json" ".blueprint"
    fi
  else
    assert "Stage 2: project directory created" 1
  fi
fi

# Cleanup
rm -rf "$TEST_BUILD_DIR"

# ── Test Suite: Deploy Script Logic ────────────────────────────

echo ""
log_info "Test Suite: Deploy Script Utilities"

source "$SPECTRAAL_ROOT/scripts/lib/docker-utils.sh"

PORT=$(find_available_port 9900)
[[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 9900 ]]
assert "find_available_port returns valid port" $?

PORT2=$(find_available_port $((PORT + 1)))
[[ "$PORT2" != "$PORT" ]]
assert "find_available_port returns unique ports" $?

# ── Test Suite: Argument Parsing ───────────────────────────────

echo ""
log_info "Test Suite: CLI Arguments"

HELP_OUTPUT=$("$SPECTRAAL_ROOT/jarvis" --help 2>&1 || true)
echo "$HELP_OUTPUT" | grep -q "\-\-openspec"
assert "Help shows --openspec flag" $?

echo "$HELP_OUTPUT" | grep -q "\-\-dry-run"
assert "Help shows --dry-run flag" $?

echo "$HELP_OUTPUT" | grep -q "\-\-profile"
assert "Help shows --profile flag" $?

echo "$HELP_OUTPUT" | grep -q "railway"
assert "Help mentions railway target" $?

# ── Test Suite: Prompt Files ───────────────────────────────────

echo ""
log_info "Test Suite: Prompt Templates"

assert_file "Node generation prompt" "$SPECTRAAL_ROOT/prompts/03-generate-app.md"
assert_file "Python generation prompt" "$SPECTRAAL_ROOT/prompts/03-generate-python.md"
assert_file "OpenSpec conversion prompt" "$SPECTRAAL_ROOT/prompts/openspec-convert.md"
assert_file "Analyze prompt" "$SPECTRAAL_ROOT/prompts/01-analyze.md"

# ── Summary ────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $FAIL -eq 0 ]]; then
  log_success "All $TESTS_RUN tests passed"
else
  log_warn "$PASS/$TESTS_RUN passed, $FAIL failed"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FAIL
