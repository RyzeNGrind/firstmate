#!/usr/bin/env bash
# fm-mint-forgejo-token.sh - mint scoped Forgejo PATs without admin credentials in every home.
# Usage: fm-mint-forgejo-token.sh --user <forgejo-user> --name <token-label> \
#          --scope <scope-csv> [--ttl-days <N>]
# Reads FORGEJO_URL and FORGEJO_TOKEN from ~/.config/das/forgejo.env.
# Prints only the token sha1 to stdout; logs metadata to ~/.config/das/forgejo-minted-tokens.log.

set -euo pipefail

# Defaults
ttl_days=""
user=""
name=""
scope=""

usage() {
	cat <<'EOF'
Usage: fm-mint-forgejo-token.sh --user <forgejo-user> --name <token-label> \
         --scope <scope-csv> [--ttl-days <N>]

Arguments:
  --user <forgejo-user>    Target Forgejo user for the token
  --name <token-label>     Label for the new token
  --scope <scope-csv>      Comma-separated list of scopes (e.g., "read:repository,write:repository")
  --ttl-days <N>           Optional: token expiration in days

Requires ~/.config/das/forgejo.env with FORGEJO_URL and FORGEJO_TOKEN.
EOF
	exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
		--user)
			user="$2"
			shift 2
			;;
		--name)
			name="$2"
			shift 2
			;;
		--scope)
			scope="$2"
			shift 2
			;;
		--ttl-days)
			ttl_days="$2"
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage
			;;
	esac
done

# Validate required arguments
if [[ -z "$user" ]] || [[ -z "$name" ]] || [[ -z "$scope" ]]; then
	echo "Error: --user, --name, and --scope are required" >&2
	usage
fi

# Source Forgejo config
config_file="$HOME/.config/das/forgejo.env"
if [[ ! -f "$config_file" ]]; then
	echo "Error: $config_file not found" >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$config_file"

# Check required environment variables
if [[ -z "${FORGEJO_URL:-}" ]]; then
	echo "Error: FORGEJO_URL not set in $config_file" >&2
	exit 1
fi

if [[ -z "${FORGEJO_TOKEN:-}" ]]; then
	echo "Error: FORGEJO_TOKEN not set in $config_file" >&2
	exit 1
fi

# Build JSON request body
json_body="{\"name\": \"$name\", \"scopes\": ["
# Convert comma-separated scopes to JSON array
IFS=',' read -ra scope_array <<<"$scope"
for i in "${!scope_array[@]}"; do
	if [[ $i -gt 0 ]]; then
		json_body+=","
	fi
	# Trim whitespace from each scope
	trimmed_scope="${scope_array[$i]// /}"
	json_body+="\"$trimmed_scope\""
done
json_body+="]"

# Add TTL if specified
if [[ -n "$ttl_days" ]]; then
	json_body+=", \"token_expiration_days\": $ttl_days"
fi

json_body+="}"

# Call Forgejo API
api_url="${FORGEJO_URL}/api/v1/user/tokens"
response_file=$(mktemp)
http_code_file=$(mktemp)

trap 'rm -f "$response_file" "$http_code_file"' EXIT

# Use curl to POST and capture response + HTTP code
if ! http_code=$(curl -sf \
	-X POST \
	-H "Authorization: token $FORGEJO_TOKEN" \
	-H "Content-Type: application/json" \
	-d "$json_body" \
	-w "%{http_code}" \
	-o "$response_file" \
	"$api_url" 2>&1); then
	echo "Error: curl request failed" >&2
	exit 1
fi

# Check HTTP status code
if [[ "${http_code: -3}" != "201" ]]; then
	echo "Error: API returned HTTP ${http_code: -3}" >&2
	if [[ -s "$response_file" ]]; then
		cat "$response_file" >&2
	fi
	exit 1
fi

# Parse the response to extract token and metadata
if ! command -v jq &>/dev/null; then
	echo "Error: jq not found" >&2
	exit 1
fi

token=$(jq -r '.sha1' <"$response_file")
token_last_eight=$(jq -r '.token_last_eight' <"$response_file")

if [[ -z "$token" ]] || [[ "$token" == "null" ]]; then
	echo "Error: Failed to extract token from API response" >&2
	exit 1
fi

# Print token to stdout (the only output consumers should depend on)
echo "$token"

# Log metadata
log_file="$HOME/.config/das/forgejo-minted-tokens.log"
log_dir=$(dirname "$log_file")
mkdir -p "$log_dir"

# Create log file with secure permissions if it doesn't exist
if [[ ! -f "$log_file" ]]; then
	touch "$log_file"
	chmod 0600 "$log_file"
fi

# Prepare log entry
epoch=$(date +%s)
ttl_display="${ttl_days:-never}"
log_entry="$epoch	$user	$name	$scope	$ttl_display	$token_last_eight"

# Append log entry
echo "$log_entry" >>"$log_file"

exit 0
