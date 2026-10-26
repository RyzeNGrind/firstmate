#!/usr/bin/env bash
set -eu
root=$PWD
state="$root/.test-phase/matrix-state"
mkdir -p "$state"
git show 225b5c52f36270cc56f4e2290261fb030d9451d6:bin/fm-busy-lib.sh > "$root/.test-phase/base-busy-lib.sh"
check() {
  local label=$1 expected=$2 tail=$3 got
  got=$(fm_busy_classify tmux unused:window agy matrix "$state" "$tail")
  printf '%s -> %s (expected %s)\n' "$label" "$got" "$expected"
  [ "$got" = "$expected" ]
}
footer='? for shortcuts                                                         Gemini 4 Argon · low'
. "$root/.test-phase/base-busy-lib.sh"
check 'BASE: exact idle footer reproduces false unknown' 'unknown agy-regex' "$footer"
. "$root/bin/fm-busy-lib.sh"
for effort in low medium high; do
  check "TARGET: exact idle footer ($effort)" 'idle agy-regex' "? for shortcuts      Gemini 4 Argon · $effort"
done
check 'TARGET: trailing blank rows' 'idle agy-regex' "$footer

   "
check 'TARGET: active turn' 'busy agy-regex' 'esc to cancel    Gemini 4 Argon · low'
check 'TARGET: busy evidence outranks apparent idle footer' 'busy agy-regex' "esc to cancel
$footer"
check 'TARGET: incomplete footer' 'unknown agy-regex' '? for shortcuts'
check 'TARGET: displaced footer' 'unknown agy-regex' "$footer
ordinary output"
check 'TARGET: prefixed ordinary output' 'unknown agy-regex' "ordinary output: $footer"
check 'TARGET: absent model' 'unknown agy-regex' '? for shortcuts Gemini · low'
check 'TARGET: unsupported effort' 'unknown agy-regex' '? for shortcuts Gemini 4 Argon · xhigh'
check 'TARGET: footer-like generating text' 'unknown agy-regex' 'Generating report...'
check 'TARGET: shell-only text' 'unknown agy-regex' '$ '
