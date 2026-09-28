#!/usr/bin/env bash
# fm-ask-ledger-check.sh - check for CAPTAIN ASK notes without backlog rows.
#
# Scans the deputy inbox for CAPTAIN ASK notes with no corresponding backlog row.
# Emits fm-wake check: signal only when unreconciled asks exist.
#
# Usage:
#   fm-ask-ledger-check.sh [check]
#   fm-ask-ledger-check.sh arm
#   fm-ask-ledger-check.sh disarm
#   fm-ask-ledger-check.sh --help
#
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INBOX="$STATE/inbox"
BACKLOG="$DATA/backlog.md"

RECORD="$STATE/.ask-ledger-check"
CHECK_ID=ask-ledger-reconcile
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-ask-ledger-check.sh [check]   scan inbox for unreconciled CAPTAIN ASK notes
  fm-ask-ledger-check.sh arm       write and register state/ask-ledger-reconcile.check.sh
  fm-ask-ledger-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-ask-ledger-check.sh --help    print this help
EOF
}

# Extract metadata field value from a note file.
read_note_field() {  # <file> <field>
  sed -n "/^--$/q;/^$2=/p" "$1" | cut -d= -f2-
}

# Read and return the note body (everything after --)
read_note_body() {  # <file>
  awk 'found { print; next } /^--$/ { found=1 }' "$1"
}

# Check if a note ID appears in the backlog as a checkbox item or section heading.
note_in_backlog() {  # <id>
  [ -f "$BACKLOG" ] || return 1
  grep -qE "^- *\[.*\] *$1( |$)" "$BACKLOG" || return 1
  return 0
}

# Main check logic: find unreconciled asks.
check_asks() {
  local unreconciled=()
  local note_file note_id source

  [ -d "$INBOX" ] || return 0

  while IFS= read -r note_file; do
    note_id=$(basename "$note_file" .note)
    source=$(read_note_field "$note_file" source)

    # Only check CAPTAIN ASK notes.
    if [ "$source" = "CAPTAIN ASK" ]; then
      if ! note_in_backlog "$note_id"; then
        unreconciled+=("$note_id")
      fi
    fi
  done < <(find "$INBOX" -maxdepth 2 -type f -name "*.note" 2>/dev/null | sort)

  # Report only if there are unreconciled asks.
  if [ "${#unreconciled[@]}" -gt 0 ]; then
    local line="unreconciled asks: ${unreconciled[*]}"
    fm_cap_line "$line" 240
  fi
}

# Compare with previous record to avoid duplicate wakes.
check_with_dedup() {
  local current_output record_output
  current_output=$(check_asks)
  record_output=

  [ -f "$RECORD" ] && record_output=$(cat "$RECORD")

  if [ "$current_output" != "$record_output" ]; then
    [ -n "$current_output" ] && printf '%s\n' "$current_output" >"$RECORD"
    printf '%s\n' "$current_output"
  fi
}

cmd_check() {
  check_with_dedup
}

cmd_arm() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'FM_HOME=%s exec %s check\n' "$(printf '%q' "$FM_HOME")" "$(printf '%q' "$0")"
  } >"$CHECK_SHIM" || return 1
  chmod 0700 "$CHECK_SHIM" || return 1
  "$REGISTER_BIN" "$CHECK_ID" || return 1
  printf 'armed: %s\n' "$CHECK_SHIM"
}

cmd_disarm() {
  rm -f "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: %s\n' "$CHECK_ID"
}

if [ $# -eq 0 ]; then
  cmd_check
else
  case "$1" in
    check)  cmd_check ;;
    arm)    cmd_arm ;;
    disarm) cmd_disarm ;;
    --help|-h) usage ;;
    *) usage >&2; exit 2 ;;
  esac
fi
