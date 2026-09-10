#!/usr/bin/env bash
# Spectraal — Stage 2: Scaffold Project
# ==================================================
# Input:  $BUILD_DIR/spec.json
# Output: $BUILD_DIR/{project_name}/ with blueprint skeleton

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/claude-utils.sh"
source "$SCRIPT_DIR/lib/docker-utils.sh"

log_step "2" "SCAFFOLD PROJECT"

BUILD_DIR="${SPECTRAAL_BUILD_DIR:?SPECTRAAL_BUILD_DIR not set}"
SPECTRAAL_ROOT="$(get_sdd_root)"
SPEC_FILE="$BUILD_DIR/spec.json"

if [ ! -f "$SPEC_FILE" ]; then
  log_error "spec.json not found at $SPEC_FILE — run Stage 1 first"
  exit 1
fi

# Read spec values
PROJECT_NAME=$(jq -r '.project_name' "$SPEC_FILE")
STACK_FE=$(jq -r '.stack.frontend' "$SPEC_FILE")
STACK_BE=$(jq -r '.stack.backend' "$SPEC_FILE")
STACK_DB=$(jq -r '.stack.database' "$SPEC_FILE")
STACK_PROFILE=$(jq -r '.stack_profile // "full-stack"' "$SPEC_FILE")

log_info "Project: $PROJECT_NAME"
log_info "Stack: $STACK_FE + $STACK_BE + $STACK_DB"
log_info "Profile: $STACK_PROFILE"

# Determine blueprint
BLUEPRINT=""
case "${STACK_FE}-${STACK_BE}-${STACK_DB}" in
  react-tailwind-node-express-postgresql)
    BLUEPRINT="react-node-postgres"
    ;;
  nextjs-tailwind-*-postgresql)
    BLUEPRINT="nextjs-fullstack"
    ;;
  *)
    # Default to react-node-postgres
    BLUEPRINT="react-node-postgres"
    log_warn "No exact blueprint match for $STACK_FE + $STACK_BE + $STACK_DB"
    log_warn "Falling back to react-node-postgres"
    ;;
esac

BLUEPRINT_DIR="$SPECTRAAL_ROOT/blueprints/$BLUEPRINT"

if [ ! -d "$BLUEPRINT_DIR" ]; then
  log_error "Blueprint not found: $BLUEPRINT_DIR"
  exit 1
fi

log_substep "Using blueprint: $BLUEPRINT"

# Create project directory
PROJECT_DIR="$BUILD_DIR/$PROJECT_NAME"

if [ -d "$PROJECT_DIR" ]; then
  log_warn "Project directory already exists, cleaning up..."
  rm -rf "$PROJECT_DIR"
fi

mkdir -p "$PROJECT_DIR"

# Copy blueprint (including dotfiles like .dockerignore)
log_substep "Copying blueprint skeleton..."
cp -r "$BLUEPRINT_DIR"/* "$PROJECT_DIR"/
cp -r "$BLUEPRINT_DIR"/.env.template "$PROJECT_DIR"/ 2>/dev/null || true
# Ensure .dockerignore files are copied (glob doesn't match dotfiles)
for subdir in backend frontend; do
  if [ -f "$BLUEPRINT_DIR/$subdir/.dockerignore" ]; then
    cp "$BLUEPRINT_DIR/$subdir/.dockerignore" "$PROJECT_DIR/$subdir/.dockerignore"
  fi
done

# Copy spec into project
cp "$SPEC_FILE" "$PROJECT_DIR/spec.json"

# ── Adapt blueprint to stack profile ────────────────────────
if [ "$STACK_PROFILE" = "frontend-only" ]; then
  log_substep "Adapting blueprint for frontend-only profile..."

  # Remove Prisma / database files from backend
  rm -rf "$PROJECT_DIR/backend/prisma" 2>/dev/null || true

  # Create a minimal backend that just serves the frontend
  mkdir -p "$PROJECT_DIR/backend/src"
  cat > "$PROJECT_DIR/backend/src/index.ts" <<'MINIMAL_BE'
import express from 'express';
import cors from 'cors';

const app = express();
const PORT = parseInt(process.env.PORT || '3001');

app.use(cors());
app.use(express.json());

// Health check
app.get('/api/health', (_req, res) => {
  res.json({ status: 'ok', profile: 'frontend-only', timestamp: new Date().toISOString() });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Static server running on port ${PORT}`);
});
MINIMAL_BE

  # Simplify backend package.json — remove Prisma dependencies
  if [ -f "$PROJECT_DIR/backend/package.json" ]; then
    jq 'del(.dependencies["@prisma/client"]) | del(.devDependencies.prisma) |
        .scripts.dev = "npx tsx src/index.ts" |
        .scripts.start = "node dist/index.js" |
        del(.scripts["prisma:generate"]) | del(.scripts["prisma:migrate"]) | del(.scripts["prisma:seed"])' \
      "$PROJECT_DIR/backend/package.json" > "$PROJECT_DIR/backend/package.json.tmp" && \
      mv "$PROJECT_DIR/backend/package.json.tmp" "$PROJECT_DIR/backend/package.json"
  fi

  # Rewrite backend Dockerfile for frontend-only (no Prisma, simple server)
  if [ -f "$PROJECT_DIR/backend/Dockerfile" ]; then
    cat > "$PROJECT_DIR/backend/Dockerfile" <<'DOCKERFILE'
# syntax=docker/dockerfile:1
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npx tsc || true

FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/src ./src

RUN npm install -g tsx

EXPOSE 3001

CMD ["sh", "-c", "npx tsx src/index.ts"]
DOCKERFILE
  fi

  log_success "Backend stripped to static server (no Prisma, no DB)"

elif [ "$STACK_PROFILE" = "static" ]; then
  log_substep "Adapting blueprint for static profile..."

  # Remove backend entirely
  rm -rf "$PROJECT_DIR/backend" 2>/dev/null || true

  log_success "Backend removed (static profile — frontend only)"
fi

# Find available ports (each starts after the previous to avoid collisions)
FE_PORT=$(find_available_port 3000)

if [ "$STACK_PROFILE" = "static" ]; then
  BE_PORT=0
  DB_PORT=0
elif [ "$STACK_PROFILE" = "frontend-only" ]; then
  BE_PORT=$(find_available_port $((FE_PORT + 1)))
  DB_PORT=0
else
  BE_PORT=$(find_available_port $((FE_PORT + 1)))
  DB_PORT=$(find_available_port 5432)
fi

log_info "Ports: Frontend=$FE_PORT, Backend=$BE_PORT, Database=$DB_PORT"

# Generate secrets
JWT_SECRET=$(openssl rand -hex 32)
DB_NAME="sdd_${PROJECT_NAME//-/_}"

# Replace template variables in all files
log_substep "Injecting configuration values..."

# Function to replace placeholders in a file
replace_placeholders() {
  local file="$1"
  if [ -f "$file" ]; then
    sed -i '' \
      -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
      -e "s|{{DB_NAME}}|$DB_NAME|g" \
      -e "s|{{DB_PORT}}|$DB_PORT|g" \
      -e "s|{{BE_PORT}}|$BE_PORT|g" \
      -e "s|{{FE_PORT}}|$FE_PORT|g" \
      -e "s|{{JWT_SECRET}}|$JWT_SECRET|g" \
      "$file" 2>/dev/null || true
  fi
}

# Replace in all relevant files
find "$PROJECT_DIR" -type f \( -name "*.yml" -o -name "*.yaml" -o -name "*.env*" -o -name "*.template" -o -name "*.conf" -o -name "*.json" -o -name "*.ts" -o -name "*.html" \) | while read -r file; do
  replace_placeholders "$file"
done

# Create .env from template
if [ -f "$PROJECT_DIR/.env.template" ]; then
  cp "$PROJECT_DIR/.env.template" "$PROJECT_DIR/backend/.env"
  replace_placeholders "$PROJECT_DIR/backend/.env"
  log_substep "Created backend/.env"
fi

# Save build metadata
cat > "$PROJECT_DIR/build-meta.json" <<EOF
{
  "project_name": "$PROJECT_NAME",
  "blueprint": "$BLUEPRINT",
  "stack_profile": "$STACK_PROFILE",
  "ports": {
    "frontend": $FE_PORT,
    "backend": $BE_PORT,
    "database": $DB_PORT
  },
  "database": {
    "name": "$DB_NAME",
    "user": "postgres",
    "password": "postgres"
  },
  "jwt_secret": "$JWT_SECRET",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sdd_version": "1.0"
}
EOF

log_success "Project scaffolded at $PROJECT_DIR"
log_info "  Blueprint: $BLUEPRINT"
log_info "  Directory: $PROJECT_DIR"
log_info "  Frontend port: $FE_PORT"
log_info "  Backend port: $BE_PORT"
log_info "  Database port: $DB_PORT"
log_info "  Database name: $DB_NAME"

echo "$PROJECT_DIR"
