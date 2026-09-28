#!/usr/bin/env bash
# Spectraal — Secrets Management
# Resolves secrets from cloud providers or local .env files

# Resolve a secret value from the appropriate provider
# Usage: resolve_secret <key> <default> [provider]
# Provider: env (default), aws, azure, gcp
resolve_secret() {
  local key="$1"
  local default="${2:-}"
  local provider="${3:-env}"

  case "$provider" in
    aws)
      _resolve_aws_secret "$key" "$default"
      ;;
    azure)
      _resolve_azure_secret "$key" "$default"
      ;;
    gcp)
      _resolve_gcp_secret "$key" "$default"
      ;;
    env|*)
      _resolve_env_secret "$key" "$default"
      ;;
  esac
}

# Detect secrets provider from deploy target
secrets_provider_for_target() {
  local target="$1"
  case "$target" in
    aws-ecs)    echo "aws" ;;
    azure-aks)  echo "azure" ;;
    gcp-cloudrun) echo "gcp" ;;
    *)          echo "env" ;;
  esac
}

# Generate all required secrets for a project
# Usage: generate_project_secrets <project_name> <deploy_target>
generate_project_secrets() {
  local project_name="$1"
  local deploy_target="$2"
  local provider
  provider=$(secrets_provider_for_target "$deploy_target")

  local jwt_secret
  jwt_secret=$(openssl rand -hex 32)

  case "$provider" in
    aws)
      _store_aws_secret "$project_name" "jwt-secret" "$jwt_secret"
      ;;
    azure)
      _store_azure_secret "$project_name" "jwt-secret" "$jwt_secret"
      ;;
    gcp)
      _store_gcp_secret "$project_name" "jwt-secret" "$jwt_secret"
      ;;
    *)
      echo "$jwt_secret"
      ;;
  esac
}

# ── Provider implementations ──────────────────────────────────

_resolve_env_secret() {
  local key="$1"
  local default="$2"
  local val="${!key:-$default}"
  echo "$val"
}

_resolve_aws_secret() {
  local key="$1"
  local default="$2"

  if ! command -v aws &>/dev/null; then
    echo "$default"
    return
  fi

  local secret_name="spectraal/${key}"
  local val
  val=$(aws secretsmanager get-secret-value \
    --secret-id "$secret_name" \
    --query 'SecretString' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$val" ]] && [[ "$val" != "None" ]]; then
    echo "$val"
  else
    echo "$default"
  fi
}

_store_aws_secret() {
  local project="$1"
  local key="$2"
  local value="$3"
  local secret_name="spectraal/${project}/${key}"

  aws secretsmanager describe-secret --secret-id "$secret_name" &>/dev/null 2>&1 && \
    aws secretsmanager put-secret-value --secret-id "$secret_name" --secret-string "$value" --output none 2>/dev/null || \
    aws secretsmanager create-secret --name "$secret_name" --secret-string "$value" --output none 2>/dev/null

  echo "$value"
}

_resolve_azure_secret() {
  local key="$1"
  local default="$2"

  if ! command -v az &>/dev/null; then
    echo "$default"
    return
  fi

  local vault_name="${AZURE_KEY_VAULT:-spectraal-vault}"
  local val
  val=$(az keyvault secret show --vault-name "$vault_name" --name "$key" \
    --query 'value' --output tsv 2>/dev/null || echo "")

  if [[ -n "$val" ]]; then
    echo "$val"
  else
    echo "$default"
  fi
}

_store_azure_secret() {
  local project="$1"
  local key="$2"
  local value="$3"
  local vault_name="${AZURE_KEY_VAULT:-spectraal-vault}"

  az keyvault create --name "$vault_name" --resource-group "${AZURE_RESOURCE_GROUP:-spectraal-rg}" \
    --location "${AZURE_LOCATION:-eastus}" --output none 2>/dev/null || true

  az keyvault secret set --vault-name "$vault_name" --name "${project}-${key}" \
    --value "$value" --output none 2>/dev/null || true

  echo "$value"
}

_resolve_gcp_secret() {
  local key="$1"
  local default="$2"

  if ! command -v gcloud &>/dev/null; then
    echo "$default"
    return
  fi

  local project="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
  local val
  val=$(gcloud secrets versions access latest --secret="$key" --project="$project" 2>/dev/null || echo "")

  if [[ -n "$val" ]]; then
    echo "$val"
  else
    echo "$default"
  fi
}

_store_gcp_secret() {
  local project_name="$1"
  local key="$2"
  local value="$3"
  local gcp_project="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
  local secret_id="spectraal-${project_name}-${key}"

  gcloud secrets describe "$secret_id" --project="$gcp_project" &>/dev/null 2>&1 || \
    gcloud secrets create "$secret_id" --replication-policy=automatic --project="$gcp_project" --quiet 2>/dev/null

  echo -n "$value" | gcloud secrets versions add "$secret_id" --data-file=- --project="$gcp_project" --quiet 2>/dev/null

  echo "$value"
}
