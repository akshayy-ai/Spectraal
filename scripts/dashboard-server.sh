#!/usr/bin/env bash
# Spectraal — Dashboard Server Launcher
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$SCRIPT_DIR/dashboard"
SPECTRAAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NODE="${HOME}/.node-arm64/bin/node"
NPM="${HOME}/.node-arm64/bin/npm"

if [ ! -x "$NODE" ]; then
  NODE="$(command -v node 2>/dev/null || true)"
  NPM="$(command -v npm 2>/dev/null || true)"
fi

if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  echo "Error: Node.js not found"
  exit 1
fi

if [ ! -d "$DASHBOARD_DIR/node_modules/express" ]; then
  echo "Installing Express..."
  cd "$DASHBOARD_DIR"
  "$NPM" init -y --silent 2>/dev/null || true
  "$NPM" install express --silent 2>/dev/null
  cd - >/dev/null
fi

PORT="${DASHBOARD_PORT:-9000}"

if lsof -i :"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Dashboard already running at http://localhost:$PORT"
  open "http://localhost:$PORT" 2>/dev/null || true
  exit 0
fi

echo ""
echo "  ✦ Spectraal Dashboard"
echo "  http://localhost:$PORT"
echo "  Press Ctrl+C to stop"
echo ""

( sleep 2 && open "http://localhost:$PORT" 2>/dev/null ) &

export SPECTRAAL_ROOT
export DASHBOARD_PORT="$PORT"
exec "$NODE" "$DASHBOARD_DIR/server.js"
