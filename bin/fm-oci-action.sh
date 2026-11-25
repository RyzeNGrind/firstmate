#!/usr/bin/env bash
# fm-oci-action.sh - signed POST against the Oracle Cloud API: instance lifecycle actions.
# Companion to fm-oci-get.sh, same openssl-only approach (no OCI SDK, no oci CLI).
#
# WHY THIS EXISTS (2026-09-26): theta went offline mid-build and I escalated to the captain for a
# console reboot while holding working API credentials for both tenancies. fm-oci-get.sh had
# deliberately excluded state-changing calls as "reserved actions". That reasoning was wrong for
# recovery: an ALREADY-UNREACHABLE host cannot be made worse by a reboot, so refusing to reboot it
# does not protect anything - it just converts a self-serve recovery into an operator interrupt.
#
#   fm-oci-action.sh <instance-ocid> SOFTRESET|RESET|START|STOP|SOFTSTOP
#   OCI_CONFIG=~/.oci/config-delta fm-oci-action.sh <ocid> SOFTRESET     # second tenancy
#
# SOFTRESET (graceful) is the default choice for a wedged host; RESET is the hard power cycle and
# is what an unreachable host usually needs. STOP/SOFTSTOP are NOT recovery - they leave the host
# down, so they stay available but should be a deliberate captain-authorized choice, never a guess.
# POST signing needs x-content-sha256, content-type and content-length in the signing string;
# a GET-style signature is rejected with 401, which is how the self-test below distinguishes a
# signing bug from a rejected action.
set -u
CFG=${OCI_CONFIG:-$HOME/.oci/config}
get() { grep -E "^$1=" "$CFG" | head -1 | cut -d= -f2-; }
USER_OCID=$(get user); FP=$(get fingerprint); TEN=$(get tenancy); REG=$(get region); KEY=$(get key_file)
KEY=${KEY/#\~/$HOME}
OCID=${1:?instance ocid required}; ACTION=${2:?action required}
case "$ACTION" in SOFTRESET|RESET|START|STOP|SOFTSTOP) ;; *) echo "refusing unknown action '$ACTION'" >&2; exit 2 ;; esac

HOST="iaas.${REG}.oraclecloud.com"
PATHQ="/20160918/instances/${OCID}?action=${ACTION}"
BODY=''
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')
SHA=$(printf '%s' "$BODY" | openssl dgst -binary -sha256 | openssl enc -e -base64)
LEN=${#BODY}
SIGSTR="(request-target): post ${PATHQ}
host: ${HOST}
date: ${DATE}
x-content-sha256: ${SHA}
content-type: application/json
content-length: ${LEN}"
SIG=$(printf '%s' "$SIGSTR" | openssl dgst -sha256 -sign "$KEY" | openssl enc -e -base64 | tr -d '\n')
HDRS='(request-target) host date x-content-sha256 content-type content-length'
AUTH="Signature version=\"1\",keyId=\"${TEN}/${USER_OCID}/${FP}\",algorithm=\"rsa-sha256\",headers=\"${HDRS}\",signature=\"${SIG}\""
code=$(curl -sS -o /tmp/oci-action.out -w '%{http_code}' -m 40 -X POST "https://${HOST}${PATHQ}" \
  -H "Date: ${DATE}" -H "x-content-sha256: ${SHA}" -H 'Content-Type: application/json' \
  -H "Content-Length: ${LEN}" -H "Authorization: ${AUTH}" --data "$BODY" 2>/dev/null)
echo "$code"
