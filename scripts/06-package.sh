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

  # Use previous image as cache source for faster rebuilds
  local cache_args=""
  if docker image inspect "$tag" &>/dev/null 2>&1; then
    cache_args="--cache-from $tag"
  fi

  for attempt in $(seq 1 $max_retries); do
    log_substep "Building $label Docker image (attempt $attempt/$max_retries)..."
    if docker build \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        $cache_args \
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

# ── Patch nginx.conf BEFORE frontend build ──────────────────
# Claude's generated nginx.conf may have a hardcoded backend port
# that doesn't match the actual backend container port. Fix it now
# so the correct config is baked into the Docker image.
if [ -f "$PROJECT_DIR/frontend/nginx.conf" ] && [ -d "$PROJECT_DIR/backend" ]; then
  BE_CONTAINER_PORT="3001"
  if [ -f "$PROJECT_DIR/backend/Dockerfile" ]; then
    EXPOSED=$(grep -i '^EXPOSE' "$PROJECT_DIR/backend/Dockerfile" | head -1 | awk '{print $2}')
    if [[ -n "$EXPOSED" ]] && [[ "$EXPOSED" =~ ^[0-9]+$ ]]; then
      BE_CONTAINER_PORT="$EXPOSED"
    fi
  fi
  BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
  if [[ "$BLUEPRINT" != react-python-* ]] && [ -f "$PROJECT_DIR/backend/.env" ]; then
    ENV_PORT=$(grep '^PORT=' "$PROJECT_DIR/backend/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    if [[ -n "$ENV_PORT" ]] && [[ "$ENV_PORT" =~ ^[0-9]+$ ]]; then
      BE_CONTAINER_PORT="$ENV_PORT"
    fi
  fi
  log_substep "Patching nginx.conf: proxy_pass → backend:${BE_CONTAINER_PORT}"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' -E "s|proxy_pass http://[a-zA-Z0-9_-]+:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
      "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
  else
    sed -i -E "s|proxy_pass http://[a-zA-Z0-9_-]+:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
      "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
  fi
fi

# Build frontend
docker_build_with_retry "$PROJECT_DIR/frontend" "${PROJECT_NAME}-web:latest" "Frontend" || exit 1

# Tag images with version for rollback support
BUILD_VERSION=$(date -u +%Y%m%d-%H%M%S)
if docker image inspect "${PROJECT_NAME}-api:latest" &>/dev/null; then
  docker tag "${PROJECT_NAME}-api:latest" "${PROJECT_NAME}-api:${BUILD_VERSION}"
fi
docker tag "${PROJECT_NAME}-web:latest" "${PROJECT_NAME}-web:${BUILD_VERSION}"

# Save version to build-meta
jq --arg v "$BUILD_VERSION" '.build_version = $v' "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
  mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

# List built images
log_info "Docker images (version: $BUILD_VERSION):"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep "$PROJECT_NAME" || true

log_success "All Docker images built successfully"
