#!/usr/bin/env bash
# Spectraal SpecPilot — Full Pipeline Orchestrator
# Usage: run-specpilot.sh <requirements-file> <build-dir>
#
# Runs all 5 stages sequentially:
#   0. Ingest requirements → prd.json
#   1. Architecture design → architecture.json
#   2. UI/UX specification → ui-spec.json
#   3. Task decomposition → tasks.json
#   4. Cross-validation   → validation.json
#
# On success, the build-dir/specs/ folder contains all artifacts
# ready for code generation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

REQ_FILE="${1:-}"
BUILD_DIR="${2:-}"

if [[ -z "$REQ_FILE" || -z "$BUILD_DIR" ]]; then
  echo ""
  echo "  Spectraal SpecPilot — Specification Pipeline"
  echo "  ───────────────────────────────────────"
  echo "  Usage: run-specpilot.sh <requirements-file> <build-dir>"
  echo ""
  echo "  Example:"
  echo "    ./specpilot/scripts/run-specpilot.sh requirements.txt builds/my-crm"
  echo ""
  exit 1
fi

# Resolve absolute paths
REQ_FILE="$(cd "$(dirname "$REQ_FILE")" && pwd)/$(basename "$REQ_FILE")"
BUILD_DIR="$(mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR" && pwd)"

START_TIME=$(date +%s)

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║       Spectraal SpecPilot — Specification Pipeline           ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "  📄 Requirements: $REQ_FILE"
echo "  📁 Build Dir:    $BUILD_DIR"
echo ""
echo "  ── Pipeline Stages ──────────────────────────────────────"
echo "  0. Requirements Ingestion  → prd.json"
echo "  1. Architecture Design     → architecture.json"
echo "  2. UI/UX Specification     → ui-spec.json"
echo "  3. Task Decomposition      → tasks.json"
echo "  4. Cross-Validation        → validation.json"
echo "  ──────────────────────────────────────────────────────────"
echo ""

# ── Stage 0 ───────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/00-ingest.sh" "$REQ_FILE" "$BUILD_DIR"
echo ""

# ── Stage 1 ───────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/01-architect.sh" "$BUILD_DIR"
echo ""

# ── Stage 2 ───────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/02-ui-designer.sh" "$BUILD_DIR"
echo ""

# ── Stage 3 ───────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/03-task-planner.sh" "$BUILD_DIR"
echo ""

# ── Stage 4 ───────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/04-validate.sh" "$BUILD_DIR"
echo ""

# ── Summary ───────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  ✅ SpecPilot Pipeline Complete                        ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "  ⏱️  Time: ${MINUTES}m ${SECONDS}s"
echo ""
echo "  📁 Generated Specifications:"
echo "     $BUILD_DIR/specs/prd.json"
echo "     $BUILD_DIR/specs/prd.md"
echo "     $BUILD_DIR/specs/architecture.json"
echo "     $BUILD_DIR/specs/ui-spec.json"
echo "     $BUILD_DIR/specs/tasks.json"
echo "     $BUILD_DIR/specs/validation.json"
echo ""
echo "  🚀 Ready for code generation — pass specs/ to factory.sh"
echo ""
