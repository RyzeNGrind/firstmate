#!/usr/bin/env bash
# fm-oci-get.sh - signed GET against the Oracle Cloud API using ONLY openssl and
# coreutils. No OCI SDK and no oci CLI, deliberately: pc has 2 cores and alpha is at
# 92% disk, so a heavy client is not worth it for read calls.
#
# Reads ~/.oci/config (user, fingerprint, tenancy, region, key_file) and implements
# draft-cavage HTTP signatures: sign "(request-target)\nhost\ndate" with RSA-SHA256.
#
#   fm-oci-get.sh <host> <path-with-query>
#   fm-oci-get.sh identity.ca-toronto-1.oraclecloud.com /20160918/tenancies/$TENANCY
#   fm-oci-get.sh iaas.ca-toronto-1.oraclecloud.com "/20160918/instances?compartmentId=$TENANCY"
#
# Prints the HTTP status to stdout; the body lands in /tmp/oci.out.
# Verified 2026-09-25: tenancy read 200 (bakemono/YYZ), instance list 200 (alpha,
# oci-beta, oci-theta). GET only by design - state-changing calls (reboot, stop,
# start) are NOT in this script because leaving a host unbootable or unreachable is
# a reserved action per the operator-less doctrine.
set -u
CFG=${OCI_CONFIG:-$HOME/.oci/config}
get() { grep -E "^$1=" "$CFG" | head -1 | cut -d= -f2-; }
USER_OCID=$(get user); FP=$(get fingerprint); TEN=$(get tenancy); REG=$(get region); KEY=$(get key_file)
KEY=${KEY/#\~/$HOME}
HOST="$1"; PATHQ="$2"
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')
SIGSTR="(request-target): get ${PATHQ}
host: ${HOST}
date: ${DATE}"
SIG=$(printf '%s' "$SIGSTR" | openssl dgst -sha256 -sign "$KEY" 2>/dev/null | openssl base64 -A 2>/dev/null)
[ -n "$SIG" ] || { echo "SIGNING FAILED"; exit 1; }
KEYID="${TEN}/${USER_OCID}/${FP}"
curl -sS -m 30 -o /tmp/oci.out -w '%{http_code}' \
  -H "date: ${DATE}" \
  -H "host: ${HOST}" \
  -H "Authorization: Signature version=\"1\",keyId=\"${KEYID}\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date\",signature=\"${SIG}\"" \
  "https://${HOST}${PATHQ}"
