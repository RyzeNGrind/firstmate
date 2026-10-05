#!/usr/bin/env bash
# fm-plane-perturn-hook.sh — Per-turn Plane issue state upsert
# Reads plane_issue_id from state/<task-id>.meta
# Updates issue state to "In Progress" on every hook invocation
# Fail-quiet: always exits 0; API failures never block turn termination

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Skip in non-Claude harnesses
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0

# Debug logging function
debug_log() {
  if [[ "${FM_PLANE_PERTURN_DEBUG:-}" == "1" ]]; then
    echo "[Plane] $*" >&2
  fi
}

# Skip if not a crewmate task (main firstmate session has no CLAUDE_TASK_ID)
if [[ -z "${CLAUDE_TASK_ID:-}" ]]; then
  debug_log "No CLAUDE_TASK_ID (main session), skipping"
  exit 0
fi

# Skip if credentials file is absent
PLANE_ENV="${HOME}/.config/das/plane.env"
if [[ ! -f "$PLANE_ENV" ]]; then
  debug_log "Credentials file $PLANE_ENV not found"
  exit 0
fi

# Load credentials
source "$PLANE_ENV" || exit 0

PLANE_API_URL="${PLANE_API_URL:-https://plane.dasagency.ca}"
WORKSPACE="das"
PROJECT="DAS"

# Extract plane_issue_id from task metadata
META_FILE="state/${CLAUDE_TASK_ID}.meta"
if [[ ! -f "$META_FILE" ]]; then
  debug_log "Metadata file $META_FILE not found"
  exit 0
fi

ISSUE_KEY=$(grep "^plane_issue_id=" "$META_FILE" | cut -d= -f2 || echo "")
if [[ -z "$ISSUE_KEY" ]]; then
  debug_log "No plane_issue_id in metadata"
  exit 0
fi

# Validate DAS-N format
if ! [[ "$ISSUE_KEY" =~ ^DAS-[0-9]+$ ]]; then
  debug_log "Invalid plane_issue_id format: $ISSUE_KEY"
  exit 0
fi

SEQUENCE_ID="${ISSUE_KEY#DAS-}"
debug_log "Processing issue $ISSUE_KEY (sequence=$SEQUENCE_ID)"

# Fetch available states to get UUID for "In Progress"
debug_log "Fetching states from Plane API"
STATES_JSON=$(curl -s \
  --max-time 10 \
  -H "Authorization: Token ${PLANE_API_TOKEN}" \
  "${PLANE_API_URL}/api/v1/workspaces/${WORKSPACE}/projects/${PROJECT}/states/" \
  2>/dev/null || echo "{}")

STATE_UUID=$(echo "$STATES_JSON" | jq -r '.results[] | select(.name == "In Progress") | .id' 2>/dev/null || echo "")
if [[ -z "$STATE_UUID" ]]; then
  debug_log "Could not find 'In Progress' state UUID"
  exit 0
fi
debug_log "Found 'In Progress' state UUID: $STATE_UUID"

# Fetch issues with pagination to find the matching issue
debug_log "Fetching issues from Plane API"
ISSUE_UUID=""
NEXT_CURSOR=""

while true; do
  CURSOR_PARAM=""
  if [[ -n "$NEXT_CURSOR" ]]; then
    CURSOR_PARAM="&cursor=${NEXT_CURSOR}"
  fi

  ISSUES_JSON=$(curl -s \
    --max-time 10 \
    -H "Authorization: Token ${PLANE_API_TOKEN}" \
    "${PLANE_API_URL}/api/v1/workspaces/${WORKSPACE}/projects/${PROJECT}/issues/?per_page=250${CURSOR_PARAM}" \
    2>/dev/null || echo "{}")

  # Find the issue by sequence_id
  ISSUE_UUID=$(echo "$ISSUES_JSON" | jq -r ".results[] | select(.sequence_id == $SEQUENCE_ID) | .id" 2>/dev/null || echo "")
  if [[ -n "$ISSUE_UUID" ]]; then
    debug_log "Found issue UUID: $ISSUE_UUID"
    break
  fi

  # Check for pagination
  NEXT_CURSOR=$(echo "$ISSUES_JSON" | jq -r '.next_cursor // ""' 2>/dev/null || echo "")
  if [[ -z "$NEXT_CURSOR" ]]; then
    debug_log "Issue DAS-$SEQUENCE_ID not found in Plane"
    exit 0
  fi

  debug_log "Paginating to next cursor: $NEXT_CURSOR"
done

# Update issue state to "In Progress"
debug_log "Updating issue state to 'In Progress'"
curl -s \
  --max-time 10 \
  -X PATCH \
  -H "Authorization: Token ${PLANE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"state_id\": \"$STATE_UUID\"}" \
  "${PLANE_API_URL}/api/v1/workspaces/${WORKSPACE}/projects/${PROJECT}/issues/${ISSUE_UUID}/" \
  2>/dev/null || true

debug_log "Upsert complete for $ISSUE_KEY"
exit 0
