#!/usr/bin/env bash
# Neon PostgreSQL quota probe.
# Returns JSON: {provider, tier, monthly_limit, used, remaining, reset_at, cred_source}
# Requires NEON_API_KEY env var or neon CLI.

set -u

PROVIDER="neon"
REQUIRED_CREDS="NEON_API_KEY"

# Try neon CLI first if available
if command -v neon &>/dev/null; then
  # List projects and get consumption for first project (requires NEON_API_KEY)
  PROJECTS=$(timeout 5 neon projects list --json 2>/dev/null) || PROJECTS=""

  if [ -n "$PROJECTS" ]; then
    PROJECT_ID=$(jq -r '.[0].id // empty' <<< "$PROJECTS" 2>/dev/null || echo "")

    if [ -n "$PROJECT_ID" ]; then
      CONSUMPTION=$(timeout 5 neon projects consumption "$PROJECT_ID" --json 2>/dev/null) || CONSUMPTION=""

      if [ -n "$CONSUMPTION" ]; then
        COMPUTE_HOURS=$(jq -r '.compute_hours // 0' <<< "$CONSUMPTION" 2>/dev/null || echo 0)
        DATA_TRANSFER=$(jq -r '.data_transfer_gb // 0' <<< "$CONSUMPTION" 2>/dev/null || echo 0)
        STORAGE=$(jq -r '.storage_gb // 0' <<< "$CONSUMPTION" 2>/dev/null || echo 0)

        # Neon free tier: 10 compute hours/month, 5GB storage, 1GB transfer
        jq -n \
          --arg provider "$PROVIDER" \
          --arg compute "$COMPUTE_HOURS" \
          --arg storage "$STORAGE" \
          '{
            provider: $provider,
            tier: "free_or_pro",
            monthly_limit: 10,
            used: ($compute | tonumber),
            remaining: (10 - ($compute | tonumber)),
            reset_at: null,
            cred_source: "neon:cli",
            note: "compute_hours_metric"
          }'
        exit 0
      fi
    fi
  fi
fi

# Fallback: API call directly
if [ -z "${NEON_API_KEY:-}" ]; then
  echo '{"error": "neon_api_key_not_set", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

# List projects and get consumption
PROJECTS=$(timeout 5 curl -s -H "Authorization: Bearer $NEON_API_KEY" \
  "https://console.neon.tech/api/v/projects" 2>/dev/null) || {
  echo '{"error": "neon_api_call_failed", "provider": "'$PROVIDER'"}' >&2
  exit 1
}

PROJECT_ID=$(jq -r '.[0].id // empty' <<< "$PROJECTS" 2>/dev/null || echo "")

if [ -z "$PROJECT_ID" ]; then
  # No projects; return defaults
  jq -n \
    --arg provider "$PROVIDER" \
    '{
      provider: $provider,
      tier: "free",
      monthly_limit: 10,
      used: 0,
      remaining: 10,
      reset_at: null,
      cred_source: "neon:api:token",
      note: "no_projects_found"
    }'
  exit 0
fi

CONSUMPTION=$(timeout 5 curl -s -H "Authorization: Bearer $NEON_API_KEY" \
  "https://console.neon.tech/api/v/projects/$PROJECT_ID/consumption" 2>/dev/null) || {
  echo '{"error": "neon_consumption_api_failed", "provider": "'$PROVIDER'"}' >&2
  exit 1
}

COMPUTE_HOURS=$(jq -r '.compute_hours // 0' <<< "$CONSUMPTION" 2>/dev/null || echo 0)

jq -n \
  --arg provider "$PROVIDER" \
  --arg compute "$COMPUTE_HOURS" \
  '{
    provider: $provider,
    tier: "free_or_pro",
    monthly_limit: 10,
    used: ($compute | tonumber),
    remaining: (10 - ($compute | tonumber)),
    reset_at: null,
    cred_source: "neon:api:token",
    note: "compute_hours_metric"
  }'
