#!/usr/bin/env bash
# Spectraal — Stage 6: Package (Docker Build)
# ========================================================
# Input:  $PROJECT_DIR with built code
# Output: Docker images for all services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/docker-utils.sh"

# Enable BuildKit for cache-mount support
export DOCKER_BUILDKIT=1

log_step "6" "PACKAGE"

PROJECT_DIR="${1:?Usage: 06-package.sh /path/to/project}"

if [ ! -f "$PROJECT_DIR/build-meta.json" ]; then
  log_error "build-meta.json not found — run Stage 2 first"
  exit 1
fi

# Read metadata
PROJECT_NAME=$(jq -r '.project_name' "$PROJECT_DIR/build-meta.json")

check_docker

# Stop any existing containers for this project
log_substep "Cleaning up existing containers..."
cleanup_project "$PROJECT_NAME" "$PROJECT_DIR/docker-compose.yml"

# ── Docker Build with Retry ──────────────────────────────────
# Retries handle transient pull timeouts (DeadlineExceeded)

docker_build_with_retry() {
  local context="$1"
  local tag="$2"
  local label="$3"
  local max_retries=3

  for attempt in $(seq 1 $max_retries); do
    log_substep "Building $label Docker image (attempt $attempt/$max_retries)..."
    if docker build \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        -t "$tag" "$context" 2>&1 | tail -5; then
      log_success "$label image built: $tag"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      log_warn "$label build failed — retrying in 5s..."
      # Try to pre-pull base image from Dockerfile
      local base_image
      base_image=$(grep -m1 '^FROM' "$context/Dockerfile" | awk '{print $2}' | sed 's/ AS.*//i')
      if [ -n "$base_image" ] && [ "$base_image" != "builder" ]; then
        log_substep "Pre-pulling $base_image..."
        docker pull "$base_image" 2>/dev/null || true
      fi
      # Also check for multi-stage second FROM
      local second_image
      second_image=$(grep '^FROM' "$context/Dockerfile" | tail -1 | awk '{print $2}' | sed 's/ AS.*//i')
      if [ -n "$second_image" ] && [ "$second_image" != "$base_image" ] && [ "$second_image" != "builder" ]; then
        log_substep "Pre-pulling $second_image..."
        docker pull "$second_image" 2>/dev/null || true
      fi
      sleep 5
    fi
  done

  log_error "$label Docker build failed after $max_retries attempts"
  return 1
}

# Profile-aware builds
STACK_PROFILE=$(jq -r '.stack_profile // "full-stack"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "full-stack")

if [ "$STACK_PROFILE" = "static" ]; then
  log_info "Static profile — building frontend only"
elif [ -d "$PROJECT_DIR/backend" ]; then
  docker_build_with_retry "$PROJECT_DIR/backend" "${PROJECT_NAME}-api:latest" "Backend" || exit 1
fi

# Build frontend
docker_build_with_retry "$PROJECT_DIR/frontend" "${PROJECT_NAME}-web:latest" "Frontend" || exit 1

# List built images
log_info "Docker images:"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep "$PROJECT_NAME" || true

log_success "All Docker images built successfully"
