#!/usr/bin/env bash
# Spectraal — Stage 8: Deploy
# ========================================
# Input:  $PROJECT_DIR with Docker images built
# Output: Running application with URL
#
# KEY DESIGN: docker-compose.yml is REGENERATED here with fresh
# free ports every time. This avoids all port collision issues
# caused by Claude's code gen overwriting scaffold's ports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/docker-utils.sh"

log_step "8" "DEPLOY"

PROJECT_DIR="${1:?Usage: 08-deploy.sh /path/to/project}"
DEPLOY_TARGET="${2:-local}"

if [ ! -f "$PROJECT_DIR/build-meta.json" ]; then
  log_error "build-meta.json not found"
  exit 1
fi

# Read metadata
PROJECT_NAME=$(jq -r '.project_name' "$PROJECT_DIR/build-meta.json")
DB_NAME=$(jq -r '.database.name // "sdd_app"' "$PROJECT_DIR/build-meta.json")
JWT_SECRET=$(jq -r '.jwt_secret // "changeme"' "$PROJECT_DIR/build-meta.json")

case "$DEPLOY_TARGET" in
  local)
    log_info "Deploying locally with Docker Compose..."
    log_info "Project: $PROJECT_NAME"

    # Stop existing containers first
    cleanup_project "$PROJECT_NAME" "$PROJECT_DIR/docker-compose.yml"

    # ── Find 3 guaranteed-free ports ─────────────────────────
    FE_PORT=$(find_available_port 3000)
    BE_PORT=$(find_available_port $((FE_PORT + 1)))
    DB_PORT=$(find_available_port 5432)

    # Safety: ensure all 3 are distinct
    if [[ "$BE_PORT" == "$FE_PORT" ]]; then
      BE_PORT=$(find_available_port $((FE_PORT + 1)))
    fi
    if [[ "$DB_PORT" == "$FE_PORT" ]] || [[ "$DB_PORT" == "$BE_PORT" ]]; then
      DB_PORT=$(find_available_port $((BE_PORT + 1)))
    fi

    log_info "Assigned ports: Frontend=$FE_PORT, Backend=$BE_PORT, Database=$DB_PORT"

    # ── Detect backend container port from Dockerfile ────────
    # Claude may expose 3000, 3001, 4000, etc. inside the container
    BE_CONTAINER_PORT="3001"
    if [ -f "$PROJECT_DIR/backend/Dockerfile" ]; then
      EXPOSED=$(grep -i '^EXPOSE' "$PROJECT_DIR/backend/Dockerfile" | head -1 | awk '{print $2}')
      if [[ -n "$EXPOSED" ]] && [[ "$EXPOSED" =~ ^[0-9]+$ ]]; then
        BE_CONTAINER_PORT="$EXPOSED"
      fi
    fi
    # Also check if the backend .env or index.ts uses a different port
    if [ -f "$PROJECT_DIR/backend/.env" ]; then
      ENV_PORT=$(grep '^PORT=' "$PROJECT_DIR/backend/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
      if [[ -n "$ENV_PORT" ]] && [[ "$ENV_PORT" =~ ^[0-9]+$ ]]; then
        BE_CONTAINER_PORT="$ENV_PORT"
      fi
    fi

    # ── Generate fresh docker-compose.yml ────────────────────
    # This is the single source of truth — not Claude's version
    # Profile-aware: frontend-only skips DB, static skips backend+DB
    STACK_PROFILE=$(jq -r '.stack_profile // "full-stack"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "full-stack")
    log_substep "Generating docker-compose.yml ($STACK_PROFILE profile)..."

    if [ "$STACK_PROFILE" = "frontend-only" ]; then
      # No database, backend is a simple static server
      cat > "$PROJECT_DIR/docker-compose.yml" <<COMPOSE
version: "3.9"

services:
  backend:
    image: "${PROJECT_NAME}-api:latest"
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: "${PROJECT_NAME}-api"
    restart: unless-stopped
    environment:
      PORT: "${BE_CONTAINER_PORT}"
      NODE_ENV: "production"
    ports:
      - "${BE_PORT}:${BE_CONTAINER_PORT}"

  frontend:
    image: "${PROJECT_NAME}-web:latest"
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: "${PROJECT_NAME}-web"
    restart: unless-stopped
    ports:
      - "${FE_PORT}:80"
    depends_on:
      - backend
COMPOSE

    elif [ "$STACK_PROFILE" = "static" ]; then
      # Frontend only — no backend, no database
      cat > "$PROJECT_DIR/docker-compose.yml" <<COMPOSE
version: "3.9"

services:
  frontend:
    image: "${PROJECT_NAME}-web:latest"
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: "${PROJECT_NAME}-web"
    restart: unless-stopped
    ports:
      - "${FE_PORT}:80"
COMPOSE

    else
      # Full-stack: frontend + backend + database
      cat > "$PROJECT_DIR/docker-compose.yml" <<COMPOSE
version: "3.9"

services:
  db:
    image: postgres:17-alpine
    container_name: "${PROJECT_NAME}-db"
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: "${DB_NAME}"
    ports:
      - "${DB_PORT}:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  backend:
    image: "${PROJECT_NAME}-api:latest"
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: "${PROJECT_NAME}-api"
    restart: unless-stopped
    environment:
      DATABASE_URL: "postgresql://postgres:postgres@db:5432/${DB_NAME}"
      JWT_SECRET: "${JWT_SECRET}"
      PORT: "${BE_CONTAINER_PORT}"
      NODE_ENV: "production"
      FRONTEND_URL: "*"
    ports:
      - "${BE_PORT}:${BE_CONTAINER_PORT}"
    depends_on:
      db:
        condition: service_healthy

  frontend:
    image: "${PROJECT_NAME}-web:latest"
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: "${PROJECT_NAME}-web"
    restart: unless-stopped
    ports:
      - "${FE_PORT}:80"
    depends_on:
      - backend

volumes:
  pgdata:
COMPOSE
    fi

    log_substep "docker-compose.yml generated: FE=$FE_PORT BE=$BE_PORT DB=$DB_PORT (profile=$STACK_PROFILE)"

    # ── Patch nginx.conf to proxy to correct backend port ────
    if [ -f "$PROJECT_DIR/frontend/nginx.conf" ]; then
      # Update proxy_pass to point to backend container's port
      sed -i '' -E "s|proxy_pass http://backend:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
        "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
      # Also handle host.docker.internal or api references
      sed -i '' -E "s|proxy_pass http://${PROJECT_NAME}-api:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
        "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
    fi

    # ── Update build-meta.json with final ports ──────────────
    jq --argjson fe "$FE_PORT" --argjson be "$BE_PORT" --argjson db "$DB_PORT" \
      '.ports.frontend = $fe | .ports.backend = $be | .ports.database = $db' \
      "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
      mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

    # ── Start services (with rollback on failure) ─────────────
    cd "$PROJECT_DIR"

    # Snapshot: remember if containers were running before
    RUNNING_BEFORE=$(docker compose -p "$PROJECT_NAME" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')

    # Images already built in Stage 6 — just start containers
    docker compose -p "$PROJECT_NAME" up -d 2>&1 | tail -10
    COMPOSE_EXIT=$?
    cd - >/dev/null

    if [ $COMPOSE_EXIT -ne 0 ]; then
      log_error "Docker Compose failed — rolling back"
      docker compose -p "$PROJECT_NAME" logs 2>&1 | tail -30

      # Rollback: tear down partial containers to avoid broken state
      log_warn "Cleaning up partial deployment..."
      docker compose -p "$PROJECT_NAME" down --remove-orphans 2>/dev/null || true
      exit 1
    fi

    # Wait for services
    log_substep "Waiting for services to start..."
    sleep 5

    if [ "$STACK_PROFILE" = "full-stack" ]; then
      wait_for_postgres "$DB_PORT" 30 || true
    fi

    # Backend health check with rollback (skip for static profile)
    BE_HEALTHY=false
    if [ "$STACK_PROFILE" = "static" ]; then
      BE_HEALTHY=true  # No backend to check
    elif wait_for_service "http://localhost:$BE_PORT/api/health" "Backend API" 45 2>/dev/null; then
      BE_HEALTHY=true
    elif wait_for_service "http://localhost:$BE_PORT" "Backend API" 15 2>/dev/null; then
      BE_HEALTHY=true
    fi

    if ! $BE_HEALTHY; then
      log_warn "Backend failed to start — checking container status"
      BACKEND_STATUS=$(docker compose -p "$PROJECT_NAME" ps backend --format json 2>/dev/null | jq -r '.State // .status // "unknown"' 2>/dev/null || echo "unknown")

      if [ "$BACKEND_STATUS" = "exited" ] || [ "$BACKEND_STATUS" = "dead" ]; then
        log_error "Backend container crashed — rolling back"
        log_info "Backend logs:"
        docker compose -p "$PROJECT_NAME" logs backend 2>&1 | tail -20
        docker compose -p "$PROJECT_NAME" down --remove-orphans 2>/dev/null || true
        exit 1
      else
        log_warn "Backend not healthy but container running ($BACKEND_STATUS) — continuing"
      fi
    fi

    wait_for_service "http://localhost:$FE_PORT" "Frontend" 30 || true

    # Save deployed URL
    echo "http://localhost:$FE_PORT" > "$PROJECT_DIR/deployed-url.txt"

    # Print success banner
    print_banner "$PROJECT_NAME" "$FE_PORT" "$BE_PORT" "$DB_PORT"

    # Show container status
    log_info "Container status:"
    docker compose -p "$PROJECT_NAME" ps 2>/dev/null || docker ps --filter "name=$PROJECT_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    log_info ""
    log_info "Useful commands:"
    log_info "  View logs:     docker compose -p $PROJECT_NAME logs -f"
    log_info "  Stop app:      docker compose -p $PROJECT_NAME down"
    log_info "  Restart:       docker compose -p $PROJECT_NAME restart"
    log_info "  DB shell:      docker exec -it ${PROJECT_NAME}-db psql -U postgres"
    ;;

  railway)
    log_warn "Railway deployment not yet implemented (Phase 3)"
    log_info "To deploy manually: cd $PROJECT_DIR && railway up"
    exit 1
    ;;

  aws-ecs)
    log_warn "AWS ECS deployment not yet implemented (Phase 3)"
    exit 1
    ;;

  gcp-cloudrun)
    log_warn "GCP Cloud Run deployment not yet implemented (Phase 3)"
    exit 1
    ;;

  *)
    log_error "Unknown deploy target: $DEPLOY_TARGET"
    log_info "Available targets: local, railway, aws-ecs, gcp-cloudrun"
    exit 1
    ;;
esac
