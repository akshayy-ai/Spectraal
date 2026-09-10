#!/usr/bin/env bash
# Spectraal — Docker Utilities
# =========================================

_DU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DU_DIR/logging.sh"

# Check Docker is available and running
check_docker() {
  if ! command -v docker &>/dev/null; then
    log_error "Docker not found. Install Docker Desktop: https://docker.com/get-started"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    log_error "Docker daemon is not running. Start Docker Desktop first."
    exit 1
  fi

  log_info "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
}

# Find available port starting from a given port
# Checks lsof, nc, and Docker containers to avoid collisions
find_available_port() {
  local port="$1"
  local max_attempts=30

  for i in $(seq 0 $max_attempts); do
    local check_port=$((port + i))
    local taken=false

    # Check lsof (catches most processes)
    if lsof -i ":$check_port" &>/dev/null 2>&1; then
      taken=true
    fi

    # Check nc (catches Docker-published ports lsof may miss)
    if ! $taken && nc -z localhost "$check_port" 2>/dev/null; then
      taken=true
    fi

    # Check Docker containers publishing this port
    if ! $taken && docker ps --format '{{.Ports}}' 2>/dev/null | grep -q "0.0.0.0:${check_port}->"; then
      taken=true
    fi

    if ! $taken; then
      echo "$check_port"
      return 0
    fi
  done

  log_error "No available port found starting from $port" >&2
  return 1
}

# Stop and remove containers for a project
cleanup_project() {
  local project_name="$1"
  local compose_file="$2"

  if [ -f "$compose_file" ]; then
    log_substep "Stopping existing containers for $project_name..."
    docker compose -f "$compose_file" -p "$project_name" down --remove-orphans 2>/dev/null || true
  fi
}

# Wait for a service to be healthy
wait_for_service() {
  local url="$1"
  local service_name="$2"
  local max_wait="${3:-60}"
  local interval=2
  local elapsed=0

  log_substep "Waiting for $service_name to be ready..."

  while [ $elapsed -lt $max_wait ]; do
    if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -qE "^(200|301|302|304)$"; then
      log_success "$service_name is ready at $url"
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  log_warn "$service_name not responding after ${max_wait}s (may still be starting)"
  return 1
}

# Wait for PostgreSQL to accept connections
wait_for_postgres() {
  local port="${1:-5432}"
  local max_wait="${2:-30}"
  local elapsed=0

  log_substep "Waiting for PostgreSQL on port $port..."

  while [ $elapsed -lt $max_wait ]; do
    if docker exec "$(docker ps -q --filter "publish=$port")" pg_isready -U postgres &>/dev/null 2>&1; then
      log_success "PostgreSQL is ready on port $port"
      return 0
    fi
    # Fallback: try direct connection check
    if nc -z localhost "$port" 2>/dev/null; then
      sleep 2  # Give it a moment after port opens
      log_success "PostgreSQL port $port is open"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log_warn "PostgreSQL not ready after ${max_wait}s"
  return 1
}

# Get container logs
get_container_logs() {
  local project_name="$1"
  local service="$2"
  local lines="${3:-50}"

  docker compose -p "$project_name" logs --tail "$lines" "$service" 2>/dev/null
}

# Check if a Docker network exists, create if not
ensure_network() {
  local network_name="${1:-sdd-network}"

  if ! docker network inspect "$network_name" &>/dev/null; then
    docker network create "$network_name" &>/dev/null
    log_substep "Created Docker network: $network_name"
  fi
}
