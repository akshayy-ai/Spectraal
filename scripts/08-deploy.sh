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
source "$SCRIPT_DIR/lib/secrets.sh"

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

# Resolve JWT secret — try cloud secrets manager for cloud targets, fallback to build-meta
SECRETS_PROVIDER=$(secrets_provider_for_target "$DEPLOY_TARGET")
JWT_SECRET=$(jq -r '.jwt_secret // empty' "$PROJECT_DIR/build-meta.json")
if [[ -z "$JWT_SECRET" ]] || [[ "$JWT_SECRET" == "changeme" ]]; then
  if [[ "$SECRETS_PROVIDER" != "env" ]]; then
    JWT_SECRET=$(resolve_secret "spectraal-${PROJECT_NAME}-jwt-secret" "" "$SECRETS_PROVIDER")
  fi
  if [[ -z "$JWT_SECRET" ]]; then
    JWT_SECRET=$(openssl rand -hex 32)
    log_warn "JWT secret was missing or insecure — generated a new one"
    if [[ "$SECRETS_PROVIDER" != "env" ]]; then
      generate_project_secrets "$PROJECT_NAME" "$DEPLOY_TARGET" >/dev/null 2>&1 || true
      log_substep "Stored JWT secret in $SECRETS_PROVIDER secrets manager"
    fi
  fi
  jq --arg s "$JWT_SECRET" '.jwt_secret = $s' "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
    mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"
fi

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
    # For Node backends, also check .env PORT (Node reads process.env.PORT)
    # For Python/FastAPI, trust the Dockerfile EXPOSE (uvicorn uses --port flag)
    BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
    if [[ "$BLUEPRINT" != react-python-* ]] && [ -f "$PROJECT_DIR/backend/.env" ]; then
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
      BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
      if [[ "$BLUEPRINT" == react-python-* ]]; then
        FO_ENV_VARS="      PORT: \"${BE_CONTAINER_PORT}\"
      ENVIRONMENT: \"production\""
      else
        FO_ENV_VARS="      PORT: \"${BE_CONTAINER_PORT}\"
      NODE_ENV: \"production\""
      fi
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
${FO_ENV_VARS}
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
      # Detect blueprint for correct DATABASE_URL format
      BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
      if [[ "$BLUEPRINT" == react-python-* ]]; then
        DB_URL_PREFIX="postgresql+asyncpg"
        ENV_VARS="      DATABASE_URL: \"${DB_URL_PREFIX}://postgres:postgres@db:5432/${DB_NAME}\"
      JWT_SECRET: \"${JWT_SECRET}\"
      PORT: \"${BE_CONTAINER_PORT}\"
      ENVIRONMENT: \"production\"
      FRONTEND_URL: \"*\""
      else
        DB_URL_PREFIX="postgresql"
        ENV_VARS="      DATABASE_URL: \"${DB_URL_PREFIX}://postgres:postgres@db:5432/${DB_NAME}\"
      JWT_SECRET: \"${JWT_SECRET}\"
      PORT: \"${BE_CONTAINER_PORT}\"
      NODE_ENV: \"production\"
      FRONTEND_URL: \"*\""
      fi

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
${ENV_VARS}
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
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' -E "s|proxy_pass http://backend:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
          "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
        sed -i '' -E "s|proxy_pass http://${PROJECT_NAME}-api:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
          "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
      else
        sed -i -E "s|proxy_pass http://backend:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
          "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
        sed -i -E "s|proxy_pass http://${PROJECT_NAME}-api:[0-9]+|proxy_pass http://backend:${BE_CONTAINER_PORT}|g" \
          "$PROJECT_DIR/frontend/nginx.conf" 2>/dev/null || true
      fi
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
    log_info "Deploying to Railway..."

    if ! command -v railway &>/dev/null; then
      log_error "Railway CLI not found. Install: npm install -g @railway/cli"
      log_info "Then authenticate: railway login"
      exit 1
    fi

    if ! railway whoami &>/dev/null 2>&1; then
      log_error "Not logged in to Railway. Run: railway login"
      exit 1
    fi

    cd "$PROJECT_DIR"

    BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
    DB_NAME=$(jq -r '.database.name // "sdd_app"' "$PROJECT_DIR/build-meta.json")

    # Initialize Railway project if not already linked
    if [[ ! -f ".railway/config.json" ]] && [[ ! -f "railway.json" ]]; then
      log_substep "Creating Railway project: $PROJECT_NAME"
      railway init --name "$PROJECT_NAME" 2>&1 || {
        log_error "Failed to create Railway project"
        exit 1
      }
    fi

    # Add PostgreSQL plugin
    log_substep "Adding PostgreSQL database..."
    railway add --plugin postgresql 2>&1 || log_warn "PostgreSQL plugin may already exist"

    # Deploy backend
    log_substep "Deploying backend service..."
    cd "$PROJECT_DIR/backend"

    # Create railway.json for backend
    cat > railway.json <<RJSON
{
  "build": { "dockerfilePath": "Dockerfile" },
  "deploy": {
    "healthcheckPath": "/api/health",
    "restartPolicyType": "ON_FAILURE"
  }
}
RJSON

    railway up --service backend --detach 2>&1 | tail -5
    BE_EXIT=$?

    if [[ $BE_EXIT -ne 0 ]]; then
      log_error "Backend deployment failed"
      cd "$PROJECT_DIR"
      exit 1
    fi

    # Set backend environment variables
    railway variables set \
      JWT_SECRET="$JWT_SECRET" \
      ENVIRONMENT="production" \
      FRONTEND_URL="*" \
      --service backend 2>&1 || log_warn "Could not set env vars — set them manually in Railway dashboard"

    # Deploy frontend
    log_substep "Deploying frontend service..."
    cd "$PROJECT_DIR/frontend"

    cat > railway.json <<RJSON
{
  "build": { "dockerfilePath": "Dockerfile" },
  "deploy": { "restartPolicyType": "ON_FAILURE" }
}
RJSON

    railway up --service frontend --detach 2>&1 | tail -5
    FE_EXIT=$?

    cd "$PROJECT_DIR"

    if [[ $FE_EXIT -ne 0 ]]; then
      log_error "Frontend deployment failed"
      exit 1
    fi

    # Get deployment URLs
    log_substep "Fetching deployment URLs..."
    sleep 5
    BE_URL=$(railway domain --service backend 2>/dev/null || echo "pending")
    FE_URL=$(railway domain --service frontend 2>/dev/null || echo "pending")

    echo "$FE_URL" > "$PROJECT_DIR/deployed-url.txt"

    # Update build-meta with deployment info
    jq --arg fe "$FE_URL" --arg be "$BE_URL" --arg target "railway" \
      '.deploy_target = $target | .urls.frontend = $fe | .urls.backend = $be' \
      "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
      mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

    log_success "Railway deployment complete!"
    log_info ""
    log_info "  Frontend: $FE_URL"
    log_info "  Backend:  $BE_URL"
    log_info ""
    log_info "Useful commands:"
    log_info "  View logs:     railway logs --service backend"
    log_info "  Open dashboard: railway open"
    log_info "  Set env vars:  railway variables set KEY=VALUE --service backend"
    log_info "  Redeploy:      cd $PROJECT_DIR/backend && railway up --service backend"
    ;;

  aws-ecs)
    log_info "Deploying to AWS ECS (Fargate)..."

    if ! command -v aws &>/dev/null; then
      log_error "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      exit 1
    fi

    if ! aws sts get-caller-identity &>/dev/null 2>&1; then
      log_error "Not authenticated with AWS. Run: aws configure"
      exit 1
    fi

    AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    AWS_REGION="${AWS_REGION:-us-east-1}"
    BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
    DB_NAME=$(jq -r '.database.name // "sdd_app"' "$PROJECT_DIR/build-meta.json")
    ECR_REPO_BE="${PROJECT_NAME}-api"
    ECR_REPO_FE="${PROJECT_NAME}-web"
    CLUSTER_NAME="spectraal-${PROJECT_NAME}"

    # Create ECR repositories
    log_substep "Creating ECR repositories..."
    for repo in "$ECR_REPO_BE" "$ECR_REPO_FE"; do
      aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" &>/dev/null || \
        aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" --image-scanning-configuration scanOnPush=true --output text 2>&1 | tail -1
    done

    # Login to ECR
    log_substep "Authenticating with ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
      docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com" 2>&1 | tail -1

    # Tag and push images
    log_substep "Pushing Docker images to ECR..."
    ECR_URI="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    docker tag "${PROJECT_NAME}-api:latest" "${ECR_URI}/${ECR_REPO_BE}:latest"
    docker push "${ECR_URI}/${ECR_REPO_BE}:latest" 2>&1 | tail -3

    docker tag "${PROJECT_NAME}-web:latest" "${ECR_URI}/${ECR_REPO_FE}:latest"
    docker push "${ECR_URI}/${ECR_REPO_FE}:latest" 2>&1 | tail -3

    # Create ECS cluster
    log_substep "Creating ECS cluster: $CLUSTER_NAME"
    aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" --query 'clusters[0].status' --output text 2>/dev/null | grep -q "ACTIVE" || \
      aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --capacity-providers FARGATE --output text 2>&1 | tail -1

    # Create CloudWatch log group
    LOG_GROUP="/ecs/${CLUSTER_NAME}"
    aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || true

    # Create or find execution role
    EXEC_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT}:role/ecsTaskExecutionRole"
    if ! aws iam get-role --role-name ecsTaskExecutionRole &>/dev/null 2>&1; then
      log_substep "Creating ECS task execution role..."
      aws iam create-role --role-name ecsTaskExecutionRole \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --output text 2>&1 | tail -1
      aws iam attach-role-policy --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    fi
    EXEC_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.Arn' --output text)

    # Register backend task definition
    log_substep "Registering backend task definition..."
    cat > "/tmp/spectraal-${PROJECT_NAME}-be-task.json" <<TASKDEF
{
  "family": "${PROJECT_NAME}-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "api",
      "image": "${ECR_URI}/${ECR_REPO_BE}:latest",
      "essential": true,
      "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
      "environment": [
        {"name": "JWT_SECRET", "value": "${JWT_SECRET}"},
        {"name": "ENVIRONMENT", "value": "production"},
        {"name": "FRONTEND_URL", "value": "*"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "api"
        }
      }
    }
  ]
}
TASKDEF
    aws ecs register-task-definition --cli-input-json "file:///tmp/spectraal-${PROJECT_NAME}-be-task.json" \
      --region "$AWS_REGION" --output text --query 'taskDefinition.taskDefinitionArn' 2>&1 | tail -1

    # Register frontend task definition
    log_substep "Registering frontend task definition..."
    cat > "/tmp/spectraal-${PROJECT_NAME}-fe-task.json" <<TASKDEF
{
  "family": "${PROJECT_NAME}-web",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "web",
      "image": "${ECR_URI}/${ECR_REPO_FE}:latest",
      "essential": true,
      "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "web"
        }
      }
    }
  ]
}
TASKDEF
    aws ecs register-task-definition --cli-input-json "file:///tmp/spectraal-${PROJECT_NAME}-fe-task.json" \
      --region "$AWS_REGION" --output text --query 'taskDefinition.taskDefinitionArn' 2>&1 | tail -1

    # Get default VPC and subnets
    log_substep "Resolving VPC and subnets..."
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region "$AWS_REGION" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

    if [[ -z "$VPC_ID" ]] || [[ "$VPC_ID" == "None" ]]; then
      log_error "No default VPC found in $AWS_REGION. Create one or set AWS_VPC_ID"
      exit 1
    fi

    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region "$AWS_REGION" \
      --query 'Subnets[*].SubnetId' --output text 2>/dev/null | tr '\t' ',')

    # Create security group
    SG_NAME="spectraal-${PROJECT_NAME}-sg"
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
      --region "$AWS_REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

    if [[ -z "$SG_ID" ]] || [[ "$SG_ID" == "None" ]]; then
      SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Spectraal ${PROJECT_NAME}" \
        --vpc-id "$VPC_ID" --region "$AWS_REGION" --query 'GroupId' --output text)
      aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null || true
      aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8000 --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null || true
    fi

    # Create ECS services
    FIRST_SUBNET=$(echo "$SUBNETS" | cut -d',' -f1)

    log_substep "Creating backend ECS service..."
    aws ecs describe-services --cluster "$CLUSTER_NAME" --services "${PROJECT_NAME}-api-svc" \
      --region "$AWS_REGION" --query 'services[0].status' --output text 2>/dev/null | grep -q "ACTIVE" && \
      aws ecs update-service --cluster "$CLUSTER_NAME" --service "${PROJECT_NAME}-api-svc" \
        --task-definition "${PROJECT_NAME}-api" --force-new-deployment \
        --region "$AWS_REGION" --output text 2>&1 | tail -1 || \
      aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "${PROJECT_NAME}-api-svc" \
        --task-definition "${PROJECT_NAME}-api" --desired-count 1 --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$FIRST_SUBNET],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
        --region "$AWS_REGION" --output text 2>&1 | tail -1

    log_substep "Creating frontend ECS service..."
    aws ecs describe-services --cluster "$CLUSTER_NAME" --services "${PROJECT_NAME}-web-svc" \
      --region "$AWS_REGION" --query 'services[0].status' --output text 2>/dev/null | grep -q "ACTIVE" && \
      aws ecs update-service --cluster "$CLUSTER_NAME" --service "${PROJECT_NAME}-web-svc" \
        --task-definition "${PROJECT_NAME}-web" --force-new-deployment \
        --region "$AWS_REGION" --output text 2>&1 | tail -1 || \
      aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "${PROJECT_NAME}-web-svc" \
        --task-definition "${PROJECT_NAME}-web" --desired-count 1 --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$FIRST_SUBNET],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
        --region "$AWS_REGION" --output text 2>&1 | tail -1

    # Wait for tasks to get public IPs
    log_substep "Waiting for services to start (this may take 1-2 minutes)..."
    sleep 30

    # Get public IPs of running tasks
    BE_TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER_NAME" --service-name "${PROJECT_NAME}-api-svc" \
      --region "$AWS_REGION" --query 'taskArns[0]' --output text 2>/dev/null || echo "pending")
    FE_TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER_NAME" --service-name "${PROJECT_NAME}-web-svc" \
      --region "$AWS_REGION" --query 'taskArns[0]' --output text 2>/dev/null || echo "pending")

    BE_IP="pending"
    FE_IP="pending"
    if [[ "$BE_TASK_ARN" != "pending" ]] && [[ "$BE_TASK_ARN" != "None" ]]; then
      ENI=$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$BE_TASK_ARN" --region "$AWS_REGION" \
        --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text 2>/dev/null || echo "")
      if [[ -n "$ENI" ]] && [[ "$ENI" != "None" ]]; then
        BE_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --region "$AWS_REGION" \
          --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null || echo "pending")
      fi
    fi
    if [[ "$FE_TASK_ARN" != "pending" ]] && [[ "$FE_TASK_ARN" != "None" ]]; then
      ENI=$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$FE_TASK_ARN" --region "$AWS_REGION" \
        --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text 2>/dev/null || echo "")
      if [[ -n "$ENI" ]] && [[ "$ENI" != "None" ]]; then
        FE_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --region "$AWS_REGION" \
          --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null || echo "pending")
      fi
    fi

    FE_URL="http://${FE_IP}"
    BE_URL="http://${BE_IP}:8000"
    echo "$FE_URL" > "$PROJECT_DIR/deployed-url.txt"

    # Update build-meta
    jq --arg fe "$FE_URL" --arg be "$BE_URL" --arg target "aws-ecs" --arg cluster "$CLUSTER_NAME" --arg region "$AWS_REGION" \
      '.deploy_target = $target | .urls.frontend = $fe | .urls.backend = $be | .aws.cluster = $cluster | .aws.region = $region' \
      "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
      mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

    log_success "AWS ECS deployment complete!"
    log_info ""
    log_info "  Cluster:  $CLUSTER_NAME"
    log_info "  Region:   $AWS_REGION"
    log_info "  Frontend: $FE_URL"
    log_info "  Backend:  $BE_URL"
    log_info ""
    log_warn "Note: Public IPs may show 'pending' — tasks take 1-2 min to get IPs."
    log_warn "For production, add an ALB with a custom domain."
    log_info ""
    log_info "Useful commands:"
    log_info "  View services: aws ecs list-services --cluster $CLUSTER_NAME --region $AWS_REGION"
    log_info "  View logs:     aws logs tail $LOG_GROUP --region $AWS_REGION --follow"
    log_info "  Scale up:      aws ecs update-service --cluster $CLUSTER_NAME --service ${PROJECT_NAME}-api-svc --desired-count 2 --region $AWS_REGION"
    log_info "  Tear down:     aws ecs delete-service --cluster $CLUSTER_NAME --service ${PROJECT_NAME}-api-svc --force --region $AWS_REGION"
    ;;

  azure-aks)
    log_info "Deploying to Azure Kubernetes Service (AKS)..."

    if ! command -v az &>/dev/null; then
      log_error "Azure CLI not found. Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
      exit 1
    fi

    if ! az account show &>/dev/null 2>&1; then
      log_error "Not logged in to Azure. Run: az login"
      exit 1
    fi

    if ! command -v kubectl &>/dev/null; then
      log_error "kubectl not found. Install: az aks install-cli"
      exit 1
    fi

    AZURE_RG="${AZURE_RESOURCE_GROUP:-spectraal-${PROJECT_NAME}-rg}"
    AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
    ACR_NAME="${AZURE_ACR_NAME:-spectraal${PROJECT_NAME//[^a-zA-Z0-9]/}}"
    AKS_CLUSTER="spectraal-${PROJECT_NAME}"
    BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
    DB_NAME=$(jq -r '.database.name // "sdd_app"' "$PROJECT_DIR/build-meta.json")

    # Create resource group
    log_substep "Creating resource group: $AZURE_RG"
    az group create --name "$AZURE_RG" --location "$AZURE_LOCATION" --output none 2>/dev/null || true

    # Create Azure Container Registry
    log_substep "Creating container registry: $ACR_NAME"
    az acr create --resource-group "$AZURE_RG" --name "$ACR_NAME" --sku Basic --output none 2>/dev/null || true
    az acr login --name "$ACR_NAME" 2>&1 | tail -1

    ACR_SERVER="${ACR_NAME}.azurecr.io"

    # Tag and push images
    log_substep "Pushing Docker images to ACR..."
    docker tag "${PROJECT_NAME}-api:latest" "${ACR_SERVER}/${PROJECT_NAME}-api:latest"
    docker push "${ACR_SERVER}/${PROJECT_NAME}-api:latest" 2>&1 | tail -3

    docker tag "${PROJECT_NAME}-web:latest" "${ACR_SERVER}/${PROJECT_NAME}-web:latest"
    docker push "${ACR_SERVER}/${PROJECT_NAME}-web:latest" 2>&1 | tail -3

    # Create AKS cluster (if not exists)
    log_substep "Creating AKS cluster: $AKS_CLUSTER (this may take 3-5 minutes on first run)..."
    if ! az aks show --resource-group "$AZURE_RG" --name "$AKS_CLUSTER" &>/dev/null 2>&1; then
      az aks create \
        --resource-group "$AZURE_RG" \
        --name "$AKS_CLUSTER" \
        --node-count 1 \
        --node-vm-size Standard_B2s \
        --attach-acr "$ACR_NAME" \
        --generate-ssh-keys \
        --output none 2>&1
    else
      log_substep "AKS cluster already exists — attaching ACR..."
      az aks update --resource-group "$AZURE_RG" --name "$AKS_CLUSTER" --attach-acr "$ACR_NAME" --output none 2>/dev/null || true
    fi

    # Get kubeconfig
    log_substep "Configuring kubectl..."
    az aks get-credentials --resource-group "$AZURE_RG" --name "$AKS_CLUSTER" --overwrite-existing 2>&1 | tail -1

    # Create namespace
    kubectl create namespace "$PROJECT_NAME" 2>/dev/null || true

    # Generate Kubernetes manifests
    log_substep "Deploying Kubernetes manifests..."

    K8S_DIR="$PROJECT_DIR/k8s"
    mkdir -p "$K8S_DIR"

    # PostgreSQL deployment
    cat > "$K8S_DIR/postgres.yaml" <<K8S
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: ${PROJECT_NAME}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: ${PROJECT_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:17-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_USER
          value: "postgres"
        - name: POSTGRES_PASSWORD
          value: "postgres"
        - name: POSTGRES_DB
          value: "${DB_NAME}"
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: pgdata
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ${PROJECT_NAME}
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
K8S

    # Determine DATABASE_URL prefix
    if [[ "$BLUEPRINT" == react-python-* ]]; then
      DB_URL="postgresql+asyncpg://postgres:postgres@postgres:5432/${DB_NAME}"
    else
      DB_URL="postgresql://postgres:postgres@postgres:5432/${DB_NAME}"
    fi

    # Backend deployment
    cat > "$K8S_DIR/backend.yaml" <<K8S
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: ${PROJECT_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: api
        image: ${ACR_SERVER}/${PROJECT_NAME}-api:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          value: "${DB_URL}"
        - name: JWT_SECRET
          value: "${JWT_SECRET}"
        - name: ENVIRONMENT
          value: "production"
        - name: FRONTEND_URL
          value: "*"
        readinessProbe:
          httpGet:
            path: /api/health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: ${PROJECT_NAME}
spec:
  selector:
    app: backend
  ports:
  - port: 8000
K8S

    # Frontend deployment with LoadBalancer
    cat > "$K8S_DIR/frontend.yaml" <<K8S
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: ${PROJECT_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: web
        image: ${ACR_SERVER}/${PROJECT_NAME}-web:latest
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: ${PROJECT_NAME}
spec:
  type: LoadBalancer
  selector:
    app: frontend
  ports:
  - port: 80
    targetPort: 80
K8S

    # Apply manifests
    kubectl apply -f "$K8S_DIR/postgres.yaml" 2>&1 | tail -5
    log_substep "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=ready pod -l app=postgres -n "$PROJECT_NAME" --timeout=120s 2>/dev/null || log_warn "PostgreSQL pod not ready yet"

    kubectl apply -f "$K8S_DIR/backend.yaml" 2>&1 | tail -3
    kubectl apply -f "$K8S_DIR/frontend.yaml" 2>&1 | tail -3

    # Wait for LoadBalancer IP
    log_substep "Waiting for external IP (this may take 1-2 minutes)..."
    EXTERNAL_IP="pending"
    for i in $(seq 1 12); do
      EXTERNAL_IP=$(kubectl get svc frontend -n "$PROJECT_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
      if [[ -n "$EXTERNAL_IP" ]] && [[ "$EXTERNAL_IP" != "null" ]]; then
        break
      fi
      sleep 10
    done

    FE_URL="http://${EXTERNAL_IP}"
    echo "$FE_URL" > "$PROJECT_DIR/deployed-url.txt"

    # Update build-meta
    jq --arg fe "$FE_URL" --arg target "azure-aks" --arg cluster "$AKS_CLUSTER" --arg rg "$AZURE_RG" --arg loc "$AZURE_LOCATION" \
      '.deploy_target = $target | .urls.frontend = $fe | .azure.cluster = $cluster | .azure.resource_group = $rg | .azure.location = $loc' \
      "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
      mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

    log_success "Azure AKS deployment complete!"
    log_info ""
    log_info "  Cluster:        $AKS_CLUSTER"
    log_info "  Resource Group: $AZURE_RG"
    log_info "  Location:       $AZURE_LOCATION"
    log_info "  Frontend:       $FE_URL"
    log_info ""
    if [[ "$EXTERNAL_IP" == "pending" ]] || [[ -z "$EXTERNAL_IP" ]]; then
      log_warn "External IP still pending. Check with:"
      log_info "  kubectl get svc frontend -n $PROJECT_NAME"
    fi
    log_info ""
    log_info "Useful commands:"
    log_info "  Pod status:    kubectl get pods -n $PROJECT_NAME"
    log_info "  Backend logs:  kubectl logs -l app=backend -n $PROJECT_NAME -f"
    log_info "  Frontend logs: kubectl logs -l app=frontend -n $PROJECT_NAME -f"
    log_info "  Scale up:      kubectl scale deployment backend --replicas=3 -n $PROJECT_NAME"
    log_info "  DB shell:      kubectl exec -it \$(kubectl get pod -l app=postgres -n $PROJECT_NAME -o name) -n $PROJECT_NAME -- psql -U postgres"
    log_info "  Tear down:     az group delete --name $AZURE_RG --yes --no-wait"
    ;;

  gcp-cloudrun)
    log_info "Deploying to Google Cloud Run..."

    if ! command -v gcloud &>/dev/null; then
      log_error "Google Cloud SDK not found. Install: https://cloud.google.com/sdk/docs/install"
      exit 1
    fi

    if ! gcloud auth print-identity-token &>/dev/null 2>&1; then
      log_error "Not authenticated with GCP. Run: gcloud auth login"
      exit 1
    fi

    GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
    GCP_REGION="${GCP_REGION:-us-central1}"
    BLUEPRINT=$(jq -r '.blueprint // "react-node-postgres"' "$PROJECT_DIR/build-meta.json" 2>/dev/null || echo "react-node-postgres")
    DB_NAME=$(jq -r '.database.name // "sdd_app"' "$PROJECT_DIR/build-meta.json")

    if [[ -z "$GCP_PROJECT" ]] || [[ "$GCP_PROJECT" == "(unset)" ]]; then
      log_error "No GCP project set. Run: gcloud config set project YOUR_PROJECT_ID"
      exit 1
    fi

    log_info "Project: $GCP_PROJECT | Region: $GCP_REGION"

    # Enable required APIs
    log_substep "Enabling required GCP APIs..."
    gcloud services enable run.googleapis.com artifactregistry.googleapis.com sqladmin.googleapis.com \
      --project "$GCP_PROJECT" 2>&1 | tail -3

    # Create Artifact Registry repo (if not exists)
    AR_REPO="spectraal"
    log_substep "Creating Artifact Registry repository..."
    gcloud artifacts repositories describe "$AR_REPO" --location="$GCP_REGION" --project="$GCP_PROJECT" &>/dev/null 2>&1 || \
      gcloud artifacts repositories create "$AR_REPO" \
        --repository-format=docker \
        --location="$GCP_REGION" \
        --project="$GCP_PROJECT" \
        --output=none 2>&1

    # Configure Docker for Artifact Registry
    gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet 2>&1 | tail -1

    AR_URI="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}"

    # Tag and push images
    log_substep "Pushing Docker images to Artifact Registry..."
    docker tag "${PROJECT_NAME}-api:latest" "${AR_URI}/${PROJECT_NAME}-api:latest"
    docker push "${AR_URI}/${PROJECT_NAME}-api:latest" 2>&1 | tail -3

    docker tag "${PROJECT_NAME}-web:latest" "${AR_URI}/${PROJECT_NAME}-web:latest"
    docker push "${AR_URI}/${PROJECT_NAME}-web:latest" 2>&1 | tail -3

    # Create Cloud SQL PostgreSQL instance (if not exists)
    SQL_INSTANCE="spectraal-${PROJECT_NAME}-db"
    log_substep "Setting up Cloud SQL (PostgreSQL)..."

    if ! gcloud sql instances describe "$SQL_INSTANCE" --project="$GCP_PROJECT" &>/dev/null 2>&1; then
      log_substep "Creating Cloud SQL instance: $SQL_INSTANCE (this takes 3-5 minutes)..."
      gcloud sql instances create "$SQL_INSTANCE" \
        --database-version=POSTGRES_17 \
        --tier=db-f1-micro \
        --region="$GCP_REGION" \
        --root-password=postgres \
        --project="$GCP_PROJECT" \
        --output=none 2>&1

      gcloud sql databases create "$DB_NAME" \
        --instance="$SQL_INSTANCE" \
        --project="$GCP_PROJECT" \
        --output=none 2>&1
    else
      log_substep "Cloud SQL instance already exists"
    fi

    # Get Cloud SQL connection name
    SQL_CONNECTION=$(gcloud sql instances describe "$SQL_INSTANCE" --project="$GCP_PROJECT" \
      --format='value(connectionName)' 2>/dev/null)

    # Determine DATABASE_URL format
    if [[ "$BLUEPRINT" == react-python-* ]]; then
      DB_URL="postgresql+asyncpg://postgres:postgres@localhost:5432/${DB_NAME}"
    else
      DB_URL="postgresql://postgres:postgres@localhost:5432/${DB_NAME}"
    fi

    # Deploy backend to Cloud Run
    log_substep "Deploying backend to Cloud Run..."
    gcloud run deploy "${PROJECT_NAME}-api" \
      --image="${AR_URI}/${PROJECT_NAME}-api:latest" \
      --platform=managed \
      --region="$GCP_REGION" \
      --project="$GCP_PROJECT" \
      --allow-unauthenticated \
      --port=8000 \
      --memory=512Mi \
      --cpu=1 \
      --min-instances=0 \
      --max-instances=3 \
      --add-cloudsql-instances="$SQL_CONNECTION" \
      --set-env-vars="DATABASE_URL=${DB_URL},JWT_SECRET=${JWT_SECRET},ENVIRONMENT=production,FRONTEND_URL=*" \
      --quiet 2>&1 | tail -5
    BE_EXIT=$?

    if [[ $BE_EXIT -ne 0 ]]; then
      log_error "Backend deployment failed"
      exit 1
    fi

    BE_URL=$(gcloud run services describe "${PROJECT_NAME}-api" \
      --platform=managed --region="$GCP_REGION" --project="$GCP_PROJECT" \
      --format='value(status.url)' 2>/dev/null)

    # Deploy frontend to Cloud Run
    log_substep "Deploying frontend to Cloud Run..."
    gcloud run deploy "${PROJECT_NAME}-web" \
      --image="${AR_URI}/${PROJECT_NAME}-web:latest" \
      --platform=managed \
      --region="$GCP_REGION" \
      --project="$GCP_PROJECT" \
      --allow-unauthenticated \
      --port=80 \
      --memory=256Mi \
      --cpu=1 \
      --min-instances=0 \
      --max-instances=3 \
      --quiet 2>&1 | tail -5
    FE_EXIT=$?

    if [[ $FE_EXIT -ne 0 ]]; then
      log_error "Frontend deployment failed"
      exit 1
    fi

    FE_URL=$(gcloud run services describe "${PROJECT_NAME}-web" \
      --platform=managed --region="$GCP_REGION" --project="$GCP_PROJECT" \
      --format='value(status.url)' 2>/dev/null)

    echo "$FE_URL" > "$PROJECT_DIR/deployed-url.txt"

    # Update build-meta
    jq --arg fe "$FE_URL" --arg be "$BE_URL" --arg target "gcp-cloudrun" --arg project "$GCP_PROJECT" --arg region "$GCP_REGION" --arg sql "$SQL_INSTANCE" \
      '.deploy_target = $target | .urls.frontend = $fe | .urls.backend = $be | .gcp.project = $project | .gcp.region = $region | .gcp.sql_instance = $sql' \
      "$PROJECT_DIR/build-meta.json" > "$PROJECT_DIR/build-meta.json.tmp" && \
      mv "$PROJECT_DIR/build-meta.json.tmp" "$PROJECT_DIR/build-meta.json"

    log_success "GCP Cloud Run deployment complete!"
    log_info ""
    log_info "  Project:    $GCP_PROJECT"
    log_info "  Region:     $GCP_REGION"
    log_info "  Frontend:   $FE_URL"
    log_info "  Backend:    $BE_URL"
    log_info "  Database:   $SQL_INSTANCE ($SQL_CONNECTION)"
    log_info ""
    log_info "Useful commands:"
    log_info "  View services:  gcloud run services list --project $GCP_PROJECT --region $GCP_REGION"
    log_info "  Backend logs:   gcloud run services logs read ${PROJECT_NAME}-api --project $GCP_PROJECT --region $GCP_REGION"
    log_info "  Frontend logs:  gcloud run services logs read ${PROJECT_NAME}-web --project $GCP_PROJECT --region $GCP_REGION"
    log_info "  Scale backend:  gcloud run services update ${PROJECT_NAME}-api --max-instances=10 --project $GCP_PROJECT --region $GCP_REGION"
    log_info "  DB connect:     gcloud sql connect $SQL_INSTANCE --user=postgres --project $GCP_PROJECT"
    log_info "  Tear down:      gcloud run services delete ${PROJECT_NAME}-api ${PROJECT_NAME}-web --project $GCP_PROJECT --region $GCP_REGION --quiet"
    ;;

  *)
    log_error "Unknown deploy target: $DEPLOY_TARGET"
    log_info "Available targets: local, railway, aws-ecs, azure-aks, gcp-cloudrun"
    exit 1
    ;;
esac
