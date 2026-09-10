#!/usr/bin/env bash
# Spectraal — Logging Utilities
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Stage icons — one per pipeline stage (bash 3.2 compatible)
stage_icon() {
  case "$1" in
    1) echo "🔍";; 2) echo "🏗️ ";; 3) echo "⚡";; 4) echo "🔨";; 5) echo "🧹";;
    6) echo "📦";; 7) echo "🛡️ ";; 8) echo "🚀";; 9) echo "🧪";; 10) echo "🔧";;
    *) echo "⚙️";;
  esac
}

TOTAL_STAGES=10

# Timestamps
timestamp() {
  date '+%H:%M:%S'
}

# Log levels
log_info() {
  echo -e "${BLUE}│${NC} $(timestamp) $*"
}

log_success() {
  echo -e "${GREEN}│${NC} $(timestamp) ${GREEN}$*${NC}"
}

log_warn() {
  echo -e "${YELLOW}│${NC} $(timestamp) ${YELLOW}⚠ $*${NC}"
}

log_error() {
  echo -e "${RED}│${NC} $(timestamp) ${RED}✗ $*${NC}"
}

log_step() {
  local num="$1"
  local name="$2"
  local icon
  icon=$(stage_icon "$num")
  local total="${TOTAL_STAGES}"

  # Build progress bar (bash 3.2 compatible)
  local filled=$((num * 2))
  local empty=$(( (total * 2) - filled ))
  local bar=""
  local i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$((i + 1)); done
  i=0
  while [ $i -lt $empty ]; do bar="${bar}░"; i=$((i + 1)); done

  echo ""
  echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}${BOLD}│  ${icon} STAGE ${num}/${total}  ${name}$(printf '%*s' $((30 - ${#name})) '')│${NC}"
  echo -e "${CYAN}${BOLD}│  ${DIM}${bar}${NC}${CYAN}${BOLD}$(printf '%*s' $((32 - total * 2)) '')│${NC}"
  echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────────┘${NC}"
  echo ""

  # Record stage start time
  eval "export SPECTRAAL_STAGE_${num}_START=$(date +%s)"
}

log_substep() {
  echo -e "${BLUE}│${NC}   ${MAGENTA}→${NC} $*"
}

# Progress spinner
spinner() {
  local pid=$1
  local msg="${2:-Working...}"
  local delay=0.15
  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    printf "${BLUE}│${NC}   ${CYAN}%c${NC} %s\r" "$spinstr" "$msg"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
  done
  printf "${BLUE}│${NC}   ${GREEN}✓${NC} %s\n" "$msg"
}

# Duration tracking
timer_start() {
  export SPECTRAAL_TIMER_START=$(date +%s)
}

timer_elapsed() {
  local start=${SPECTRAAL_TIMER_START:-$(date +%s)}
  local end=$(date +%s)
  local elapsed=$((end - start))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))
  if [ $minutes -gt 0 ]; then
    echo "${minutes}m ${seconds}s"
  else
    echo "${seconds}s"
  fi
}

# Stage duration helper
stage_elapsed() {
  local num="$1"
  local var_name="SPECTRAAL_STAGE_${num}_START"
  local start=${!var_name:-0}
  if [ "$start" -eq 0 ]; then
    echo "—"
    return
  fi
  local end=$(date +%s)
  local elapsed=$((end - start))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))
  if [ $minutes -gt 0 ]; then
    echo "${minutes}m ${seconds}s"
  else
    echo "${seconds}s"
  fi
}

# Final output banner
print_banner() {
  local project_name="$1"
  local fe_port="$2"
  local be_port="$3"
  local db_port="$4"
  local profile="${5:-full-stack}"

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔═══════════════════════════════════════════════════════╗"
  echo "  ║          ✦ SPECTRAAL — App Deployed ✦               ║"
  echo "  ╠═══════════════════════════════════════════════════════╣"
  echo "  ║                                                       ║"
  echo "  ║  Project:  ${project_name}"
  if [ "$profile" != "full-stack" ]; then
  echo "  ║  Profile:  ${profile}"
  fi
  echo "  ║                                                       ║"
  echo "  ║  🌐 Frontend:  http://localhost:${fe_port}"
  if [ "$be_port" != "0" ] && [ -n "$be_port" ]; then
  echo "  ║  🔌 Backend:   http://localhost:${be_port}"
  fi
  if [ "$db_port" != "0" ] && [ -n "$db_port" ] && [ "$profile" = "full-stack" ]; then
  echo "  ║  🗄️  Database:  localhost:${db_port}"
  fi
  echo "  ║                                                       ║"
  if [ "$profile" = "full-stack" ]; then
  echo "  ║  👤 Login:     admin@demo.com / demo123               ║"
  echo "  ║                                                       ║"
  fi
  echo "  ╚═══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# Error banner
print_error_banner() {
  local stage="$1"
  local message="$2"
  local log_file="$3"

  echo ""
  echo -e "${RED}${BOLD}"
  echo "  ╔═══════════════════════════════════════════════════════╗"
  echo "  ║          ✦ SPECTRAAL — Build Failed ✦               ║"
  echo "  ╠═══════════════════════════════════════════════════════╣"
  echo "  ║                                                       ║"
  echo "  ║  Failed at: Stage ${stage}"
  echo "  ║  Error:     ${message}"
  echo "  ║                                                       ║"
  if [ -n "$log_file" ]; then
  echo "  ║  Log: ${log_file}"
  fi
  echo "  ║                                                       ║"
  echo "  ╚═══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}
