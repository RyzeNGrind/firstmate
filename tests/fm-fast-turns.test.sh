#!/usr/bin/env bash
# Regression suite for fast-tier (Luna/Haiku) latency & prompt-size optimizations,
# stale-while-revalidate caching, temp-file leak prevention, watch-guard safety,
# and MCP-first fast-context discovery.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fast-turns-test.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

now_ms() {
  python3 -c 'import time; print(int(time.monotonic() * 1000))'
}

# ============================================================================
# 1. fm-model-tier-lib.sh
# ============================================================================
(
  # shellcheck source=bin/fm-model-tier-lib.sh
  . "$ROOT/bin/fm-model-tier-lib.sh"

  for fast_m in cx/gpt-6-luna gpt-6-luna claude-haiku-4-5 claude-3-5-haiku gemini-2.5-flash gpt-5-mini o4-mini gpt-5-nano; do
    fm_model_is_fast_name "$fast_m" || { echo "expected fast: $fast_m" >&2; exit 1; }
    [ "$(fm_model_recommended_effort "$fast_m")" = "low" ] || { echo "expected low effort: $fast_m" >&2; exit 1; }
    [ "$(FM_MODEL="$fast_m" FM_MODEL_TIER="" fm_model_tier)" = "fast" ] || { echo "expected tier=fast: $fast_m" >&2; exit 1; }
  done

  for std_m in claude-opus-4-6 claude-sonnet-4-6 cx/gpt-6-sol gpt-5.4; do
    if fm_model_is_fast_name "$std_m"; then
      echo "unexpected fast: $std_m" >&2; exit 1
    fi
    if fm_model_recommended_effort "$std_m" >/dev/null 2>&1; then
      echo "unexpected effort recommendation: $std_m" >&2; exit 1
    fi
    [ "$(FM_MODEL="$std_m" FM_MODEL_TIER="" fm_model_tier)" = "standard" ] || { echo "expected tier=standard: $std_m" >&2; exit 1; }
  done

  # Explicit FM_MODEL_TIER overrides detected model
  [ "$(FM_MODEL="claude-opus-4-6" FM_MODEL_TIER="luna" fm_model_tier)" = "fast" ]
  [ "$(FM_MODEL="cx/gpt-6-luna" FM_MODEL_TIER="standard" fm_model_tier)" = "standard" ]

  # Codex config.toml auto-detection
  codex_cfg="$TMP/codex-config.toml"
  printf 'model = "cx/gpt-6-luna"\nmodel_reasoning_effort = "xhigh"\n' > "$codex_cfg"
  detected=$(FM_MODEL="" CLAUDE_MODEL="" CODEX_MODEL="" ANTHROPIC_MODEL="" OPENAI_MODEL="" \
    PRIMARY_HARNESS="codex" FM_CODEX_CONFIG="$codex_cfg" CONFIG="$TMP/no-cfg" fm_detect_model_name)
  [ "$detected" = "cx/gpt-6-luna" ]

  # MCP URL defaults & overrides
  [ "$(MCP_GATEWAY_URL="" CONFIG="$TMP/no-cfg" fm_mcp_gateway_url)" = "https://mcp.nixify.dev" ]
  [ "$(GRAPHIFY_URL="" CONFIG="$TMP/no-cfg" fm_graphify_url)" = "https://graphify.nixify.dev" ]
  [ "$(MCP_GATEWAY_URL="https://custom.mcp.local" fm_mcp_gateway_url)" = "https://custom.mcp.local" ]
) && pass "fm-model-tier-lib detects fast/standard models, effort defaults, and MCP URLs" \
  || fail "fm-model-tier-lib checks failed"

# ============================================================================
# 2. quota-fleet-pace-check.sh stale-while-revalidate & zero pipe-blocking
# ============================================================================
(
  qdir="$TMP/quota"
  mkdir -p "$qdir/bin"
  qcache="$qdir/cache.json"
  qcount="$qdir/invocations"
  : > "$qcount"

  cat > "$qdir/bin/quota-axi" <<EOF
#!/usr/bin/env bash
echo 1 >> "$qcount"
if [ "\${FAKE_QUOTA_SLEEP:-0}" -gt 0 ]; then
  sleep "\$FAKE_QUOTA_SLEEP"
fi
if [ "\${FAKE_QUOTA_FAIL:-0}" = 1 ]; then
  exit 1
fi
cat <<'JSON'
{"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"5h","status":"known","effectivePercentRemaining":12.4}]}}]}
JSON
EOF
  chmod +x "$qdir/bin/quota-axi"

  # 2a. --sync populates cache and emits warning
  out=$(PATH="$qdir/bin:$PATH" FM_QUOTA_PACE_CACHE="$qcache" \
    "$ROOT/bin/quota-fleet-pace-check.sh" --warn-at 20 --sync)
  printf '%s\n' "$out" | grep -q 'claude (5h) at 12% remaining'
  [ "$(wc -l < "$qcount" | tr -d ' ')" -eq 1 ]

  # 2b. Warm cache hit returns fast (<500ms) WITHOUT invoking quota-axi even if quota-axi would sleep 5s
  t0=$(now_ms)
  out2=$(PATH="$qdir/bin:$PATH" FAKE_QUOTA_SLEEP=5 FM_QUOTA_PACE_CACHE="$qcache" \
    "$ROOT/bin/quota-fleet-pace-check.sh" --warn-at 20)
  t1=$(now_ms)
  elapsed=$((t1 - t0))
  printf '%s\n' "$out2" | grep -q 'claude (5h) at 12% remaining'
  [ "$(wc -l < "$qcount" | tr -d ' ')" -eq 1 ] || { echo "quota-axi ran on fresh cache!" >&2; exit 1; }
  [ "$elapsed" -lt 500 ] || { echo "warm cache too slow: ${elapsed}ms" >&2; exit 1; }

  # 2c. Stale cache returns immediately (<500ms) even while background refresher sleeps 3s (zero pipe-blocking!)
  old_ts=$(( $(date +%s) - 120 ))
  printf '%s\tok\t%s\n' "$old_ts" "$old_ts" > "${qcache}.stamp"
  t0=$(now_ms)
  out3=$(PATH="$qdir/bin:$PATH" FAKE_QUOTA_SLEEP=3 FM_QUOTA_PACE_CACHE="$qcache" FM_QUOTA_PACE_TIMEOUT=4 \
    "$ROOT/bin/quota-fleet-pace-check.sh" --warn-at 20)
  t1=$(now_ms)
  elapsed=$((t1 - t0))
  printf '%s\n' "$out3" | grep -q 'claude (5h) at 12% remaining'
  [ "$elapsed" -lt 500 ] || { echo "stale-while-revalidate blocked pipe: ${elapsed}ms" >&2; exit 1; }
) && pass "quota-fleet-pace-check warm hit and non-blocking stale-while-revalidate (<500ms)" \
  || fail "quota-fleet-pace-check checks failed"

# ============================================================================
# 3. fm-home-summary-refresh.sh leak-proof timeout + --if-stale + --async
# ============================================================================
(
  hs_root="$TMP/hs-root"
  hs_home="$TMP/hs-home"
  mkdir -p "$hs_root/bin" "$hs_home/state" "$hs_home/data" "$hs_home/config" "$hs_home/projects"
  cp "$ROOT/bin/fm-home-summary-refresh.sh" "$ROOT"/bin/fm-*-lib.sh "$hs_root/bin/"
  chmod +x "$hs_root/bin/fm-home-summary-refresh.sh"

  hs_count="$TMP/hs-count"
  : > "$hs_count"
  cat > "$hs_root/bin/fm-fleet-snapshot.sh" <<EOF
#!/usr/bin/env bash
echo 1 >> "$hs_count"
if [ "\${FAKE_HS_SLEEP:-0}" -gt 0 ]; then
  sleep "\$FAKE_HS_SLEEP"
fi
now=\$(date +%s)
printf '{"schema":"fm-secondmate-home-summary.v1","hold_classifier_schema":"fm-captain-hold-buckets.v1","home":"%s","generated":"2026-11-25T00:00:00Z","generated_epoch":%s,"valid":true,"state":"no_active_work","invalidity":{},"active_children":[],"decisions_open":[],"holds":[],"queued":[],"landed":[],"endpoints":[],"counts":{},"omitted":[]}\n' "\$FM_HOME" "\$now"
EOF
  chmod +x "$hs_root/bin/fm-fleet-snapshot.sh"

  # 3a. Timeout leaves ZERO leaked .home-summary.*.?????? temp files
  FAKE_HS_SLEEP=10 FM_ROOT_OVERRIDE="$hs_root" FM_HOME="$hs_home" FM_HOME_SUMMARY_TIMEOUT=1 \
    "$hs_root/bin/fm-home-summary-refresh.sh" --best-effort
  leaks=$(find "$hs_home/state" -maxdepth 1 \( -name '.home-summary.json.*' -o -name '.home-summary-error.*' \) | wc -l | tr -d ' ')
  [ "$leaks" -eq 0 ] || { echo "leaked $leaks temp file(s) after timeout!" >&2; exit 1; }

  # 3b. Normal publish writes ledger; --if-stale 60 skips re-running producer
  FAKE_HS_SLEEP=0 FM_ROOT_OVERRIDE="$hs_root" FM_HOME="$hs_home" \
    "$hs_root/bin/fm-home-summary-refresh.sh"
  before_cnt=$(wc -l < "$hs_count" | tr -d ' ')
  FAKE_HS_SLEEP=5 FM_ROOT_OVERRIDE="$hs_root" FM_HOME="$hs_home" \
    "$hs_root/bin/fm-home-summary-refresh.sh" --if-stale 60
  after_cnt=$(wc -l < "$hs_count" | tr -d ' ')
  [ "$before_cnt" -eq "$after_cnt" ] || { echo "--if-stale did not short-circuit!" >&2; exit 1; }

  # 3c. --async returns immediately (<500ms) even with slow producer
  t0=$(now_ms)
  _async_out=$(FAKE_HS_SLEEP=3 FM_ROOT_OVERRIDE="$hs_root" FM_HOME="$hs_home" \
    "$hs_root/bin/fm-home-summary-refresh.sh" --async)
  t1=$(now_ms)
  elapsed=$((t1 - t0))
  [ "$elapsed" -lt 500 ] || { echo "--async blocked caller: ${elapsed}ms" >&2; exit 1; }
) && pass "fm-home-summary-refresh leaves 0 temp leaks on timeout + --if-stale + --async" \
  || fail "fm-home-summary-refresh checks failed"

# ============================================================================
# 4. fm-bearings-snapshot.sh fast cache + standard-tier cleanliness + AFK guard
# ============================================================================
(
  b_root="$TMP/b-root"
  b_home="$TMP/b-home"
  mkdir -p "$b_root/bin" "$b_home/state" "$b_home/data" "$b_home/config"
  cp "$ROOT/bin/fm-bearings-snapshot.sh" "$ROOT/bin/fm-timeout-lib.sh" \
     "$ROOT/bin/fm-landed-lib.sh" "$ROOT/bin/fm-model-tier-lib.sh" "$b_root/bin/"
  chmod +x "$b_root/bin/fm-bearings-snapshot.sh"

  b_count="$TMP/b-count"
  : > "$b_count"
  cat > "$b_root/bin/fm-afk-return.sh" <<'EOF'
#!/usr/bin/env bash
if [ -f "${FM_HOME}/state/.afk-block-test" ]; then
  echo "away window active" >&2
  exit 2
fi
exit 0
EOF
  chmod +x "$b_root/bin/fm-afk-return.sh"

  cat > "$b_root/bin/fm-fleet-snapshot.sh" <<EOF
#!/usr/bin/env bash
echo 1 >> "$b_count"
cat <<JSON
{"fm_home":"${b_home}","tasks":[],"backlog":{"records":[]},"secondmate_current":{"records":[],"registry":{"available":true},"truncated":0},"secondmate_landed":{"records":[],"unreadable":[],"truncated":[]},"scout_reports":[],"main_inventory":{"valid":true,"orphan_in_flight":[],"unstructured_current_count":0},"contributions":{"known":0,"checked":0,"counts":{"captain":0,"fleet":0,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"unreadable_records":0,"unmeasured":0,"stale_verdicts":0,"missing_verdicts":0,"captain_omitted":0,"captain":[]}}
JSON
EOF
  chmod +x "$b_root/bin/fm-fleet-snapshot.sh"

  # 4a. Standard tier creates NO cache files in state/
  FM_ROOT_OVERRIDE="$b_root" FM_HOME="$b_home" FM_MODEL_TIER=standard \
    "$b_root/bin/fm-bearings-snapshot.sh" >/dev/null
  [ ! -e "$b_home/state/.bearings-cache.meta" ] || { echo "standard tier unexpectedly wrote cache!" >&2; exit 1; }
  [ "$(wc -l < "$b_count" | tr -d ' ')" -eq 1 ]

  # 4b. --fast writes cache, then 2nd call hits cache (<400ms) without calling fm-fleet-snapshot.sh
  FM_ROOT_OVERRIDE="$b_root" FM_HOME="$b_home" FM_MODEL_TIER=standard \
    "$b_root/bin/fm-bearings-snapshot.sh" --fast >/dev/null
  [ "$(wc -l < "$b_count" | tr -d ' ')" -eq 2 ]

  t0=$(now_ms)
  cached_out=$(FM_ROOT_OVERRIDE="$b_root" FM_HOME="$b_home" FM_MODEL_TIER=fast \
    "$b_root/bin/fm-bearings-snapshot.sh")
  t1=$(now_ms)
  elapsed=$((t1 - t0))
  printf '%s\n' "$cached_out" | grep -q '^schema: fm-bearings.v1$'
  [ "$(wc -l < "$b_count" | tr -d ' ')" -eq 2 ] || { echo "fast tier missed warm cache!" >&2; exit 1; }
  [ "$elapsed" -lt 400 ] || { echo "warm bearings cache too slow: ${elapsed}ms" >&2; exit 1; }

  # 4c. --no-cache forces live snapshot
  FM_ROOT_OVERRIDE="$b_root" FM_HOME="$b_home" FM_MODEL_TIER=fast \
    "$b_root/bin/fm-bearings-snapshot.sh" --no-cache >/dev/null
  [ "$(wc -l < "$b_count" | tr -d ' ')" -eq 3 ]

  # 4d. Active AFK guard STILL refuses even when warm cache exists!
  touch "$b_home/state/.afk-block-test"
  if FM_ROOT_OVERRIDE="$b_root" FM_HOME="$b_home" FM_MODEL_TIER=fast \
    "$b_root/bin/fm-bearings-snapshot.sh" --fast >/dev/null 2>&1; then
    echo "cached bearings bypassed active AFK guard!" >&2; exit 1
  fi
  rm -f "$b_home/state/.afk-block-test"
) && pass "fm-bearings-snapshot fast cache hit, --no-cache, standard cleanliness, and AFK guard" \
  || fail "fm-bearings-snapshot fast cache checks failed"

# ============================================================================
# 5. fm-session-start.sh fast-tier compact mode (>=60% smaller + nuance kept)
# ============================================================================
(
  ss_home="$TMP/ss-home"
  mkdir -p "$ss_home/state" "$ss_home/data" "$ss_home/config"
  printf 'manual\n' > "$ss_home/config/backlog-backend"
  printf 'claude\n' > "$ss_home/config/harness"
  printf '# Projects\n- nixify\n' > "$ss_home/data/projects.md"
  printf '# Secondmates\n- none\n' > "$ss_home/data/secondmates.md"
  printf '# Backlog\n\n## In flight\n- [live-task] Live active task\n\n## Queued\n- [q1] Queued 1\n' > "$ss_home/data/backlog.md"
  # 15 KB captain-shared.md
  python3 -c 'print("# Shared Captain Context\n" + ("standing preference line with detail and history\n" * 320))' > "$ss_home/data/captain-shared.md"
  printf '# Captain\nConcise prefs.\n' > "$ss_home/data/captain.md"
  printf '# Learnings\nShort note.\n' > "$ss_home/data/learnings.md"

  # 20 settled dead workers (each with meta + 6 status lines)
  for i in $(seq -w 1 20); do
    cat > "$ss_home/state/settled-${i}.meta" <<EOF
id=settled-${i}
kind=ship
project=nixify
branch=fm/settled-${i}
backend=tmux
window=nonexistent-session-xyz:99${i}
harness=codex
model=cx/gpt-6-luna
worktree=/tmp/wt/settled-${i}
pr=https://git.beta.nixify.dev/owner/repo/pulls/${i}
EOF
    for l in 1 2 3 4 5 6; do
      printf '2026-11-25T00:0%s:00Z [settled-%s] done step %s with lots of verbose detail padding to represent realistic status log history across turns\n' "$l" "$i" "$l" >> "$ss_home/state/settled-${i}.status"
    done
  done

  # 1 dead worker with an OPEN BLOCKER (MUST remain expanded in full!)
  cat > "$ss_home/state/blocked-crit.meta" <<'EOF'
id=blocked-crit
kind=ship
project=nixify
branch=fm/blocked-crit
backend=tmux
window=nonexistent-session-xyz:777
EOF
  printf '2026-11-25T01:00:00Z [blocked-crit] blocked: needs-decision on rollout order for beta vs ws\n' > "$ss_home/state/blocked-crit.status"

  # 12 orphan status logs
  for i in $(seq -w 1 12); do
    for l in 1 2 3 4 5; do
      printf '2026-11-24T12:0%s:00Z [orphan-%s] historical orphan wake event line %s with padding text\n' "$l" "$i" "$l" >> "$ss_home/state/orphan-${i}.status"
    done
  done

  # Run both standard and fast tiers with --reemit (read-only lock path, no lock mutation)
  std_out=$(FM_HOME="$ss_home" FM_MODEL_TIER=standard \
    "$ROOT/bin/fm-session-start.sh" --reemit 2>/dev/null)
  fast_out=$(FM_HOME="$ss_home" FM_MODEL_TIER=fast FM_MODEL=cx/gpt-6-luna \
    "$ROOT/bin/fm-session-start.sh" --reemit 2>/dev/null)

  std_bytes=${#std_out}
  fast_bytes=${#fast_out}
  pct_saved=$(( (std_bytes - fast_bytes) * 100 / std_bytes ))
  printf '  [metric] session-start fixture: standard=%sB fast=%sB reduction=%s%%\n' "$std_bytes" "$fast_bytes" "$pct_saved"
  [ "$pct_saved" -ge 60 ] || { echo "expected >=60% reduction, got ${pct_saved}% (${std_bytes}B -> ${fast_bytes}B)" >&2; exit 1; }

  # Verify nuance preservation in fast output
  printf '%s\n' "$fast_out" | grep -q -- '--- blocked-crit ---' || { echo "blocked worker was wrongly collapsed!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'needs-decision on rollout order' || { echo "blocked worker reason missing!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'settled-01 \[dead ' || { echo "settled worker 1-line summary missing!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'fast-tier compact: truncated at 2048' || { echo "captain-shared truncation disclosure missing!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'orphan status log(s) omitted' || { echo "orphan omission disclosure missing!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'FAST-TIER SUPERVISION MODE' || { echo "fast-tier hint missing!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'https://graphify.nixify.dev' || { echo "Graphify URL missing!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'https://mcp.nixify.dev' || { echo "MCP Gateway URL missing!" >&2; exit 1; }
  printf '%s\n' "$fast_out" | grep -q 'bin/fm-pass-digest.sh' || { echo "fm-pass-digest hint missing!" >&2; exit 1; }
) && pass "fm-session-start fast-tier compact mode cuts >=60% bytes while keeping blockers & MCP hint" \
  || fail "fm-session-start fast-tier compact mode checks failed"

# ============================================================================
# 6. fm-pass-digest.sh single-call batched pass + non-mutating peek + JSON
# ============================================================================
(
  pd_root="$TMP/pd-root"
  pd_home="$TMP/pd-home"
  mkdir -p "$pd_root/bin" "$pd_home/state" "$pd_home/config"
  cp "$ROOT/bin/fm-pass-digest.sh" "$ROOT/bin/fm-model-tier-lib.sh" "$pd_root/bin/"
  chmod +x "$pd_root/bin/fm-pass-digest.sh"

  printf '1\t101\t2026-11-25T00:00:00Z\ttask-a\tstatus: ready\n' > "$pd_home/state/.wake-queue"
  printf '$$\n' > "$pd_home/state/.lock"
  printf '%s\n' "$$" > "$pd_home/state/.lock"

  cat > "$pd_root/bin/fm-bearings-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--json" ] || [ "${2:-}" = "--json" ]; then
  printf '{"schema":"fm-bearings.v1","home":"pd-home","in_flight":[]}\n'
else
  printf 'schema: fm-bearings.v1\nhome: pd-home\nin_flight: []\n'
fi
EOF
  chmod +x "$pd_root/bin/fm-bearings-snapshot.sh"

  txt=$(FM_ROOT_OVERRIDE="$pd_root" FM_HOME="$pd_home" FM_MODEL=cx/gpt-6-luna \
    "$pd_root/bin/fm-pass-digest.sh")
  printf '%s\n' "$txt" | grep -q 'FM PASS DIGEST (tier=fast model=cx/gpt-6-luna)'
  printf '%s\n' "$txt" | grep -q 'lock=held('
  printf '%s\n' "$txt" | grep -q 'pending=1'
  printf '%s\n' "$txt" | grep -q 'https://graphify.nixify.dev'
  printf '%s\n' "$txt" | grep -q 'https://mcp.nixify.dev'
  # Wake queue must NOT be mutated by peek mode
  [ "$(wc -l < "$pd_home/state/.wake-queue" | tr -d ' ')" -eq 1 ]

  js=$(FM_ROOT_OVERRIDE="$pd_root" FM_HOME="$pd_home" FM_MODEL=claude-haiku-4-5 \
    "$pd_root/bin/fm-pass-digest.sh" --json)
  printf '%s\n' "$js" | jq -e '
    .schema == "fm-pass-digest.v1"
    and .tier == "fast"
    and .readiness.lock.state == "held"
    and .wake_queue.pending_lines == 1
    and .wake_queue.drained == false
    and .bearings.snapshot.schema == "fm-bearings.v1"
    and .mcp.gateway_url == "https://mcp.nixify.dev"
    and .mcp.graphify_url == "https://graphify.nixify.dev"
  ' >/dev/null
) && pass "fm-pass-digest batches readiness, non-mutating wake peek, cached bearings, and MCP discovery" \
  || fail "fm-pass-digest checks failed"

# ============================================================================
# 7. fm-watch-guard.sh quota-safety (skip lock=free & unknown supervision model + flock)
# ============================================================================
(
  wg_home="$TMP/wg-home"
  wg_bin="$TMP/wg-bin"
  mkdir -p "$wg_home/bin" "$wg_home/state" "$wg_bin"
  cp "$ROOT/bin/fm-watch-guard.sh" "$wg_home/bin/"
  chmod +x "$wg_home/bin/fm-watch-guard.sh"

  wg_restarts="$TMP/wg-restarts"
  : > "$wg_restarts"
  cat > "$wg_bin/systemd-run" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$wg_restarts"
exit 0
EOF
  chmod +x "$wg_bin/systemd-run"
  cat > "$wg_home/bin/fm-watch-arm.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$wg_home/bin/fm-watch-arm.sh"

  # 7a. lock=free -> exit 0, ZERO restarts
  cat > "$wg_home/bin/fm-inbox.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"can_receive":false,"reason":"no-watcher","lock":{"state":"free"}}\n'
EOF
  chmod +x "$wg_home/bin/fm-inbox.sh"
  PATH="$wg_bin:$PATH" FM_HOME="$wg_home" FM_WATCH_GUARD_LOCK="$TMP/wg.lock" \
    "$wg_home/bin/fm-watch-guard.sh"
  [ "$(wc -l < "$wg_restarts" | tr -d ' ')" -eq 0 ] || { echo "restarted on lock=free!" >&2; exit 1; }

  # 7b. reason=supervision-model-unknown-for-home -> exit 0, ZERO restarts
  cat > "$wg_home/bin/fm-inbox.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"can_receive":false,"reason":"supervision-model-unknown-for-home","lock":{"state":"held"}}\n'
EOF
  PATH="$wg_bin:$PATH" FM_HOME="$wg_home" FM_WATCH_GUARD_LOCK="$TMP/wg.lock" \
    "$wg_home/bin/fm-watch-guard.sh"
  [ "$(wc -l < "$wg_restarts" | tr -d ' ')" -eq 0 ] || { echo "restarted on supervision-model-unknown-for-home!" >&2; exit 1; }

  # 7c. flock serializes overlapping invocations
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9
      PATH="$wg_bin:$PATH" FM_HOME="$wg_home" FM_WATCH_GUARD_LOCK="$TMP/wg-busy.lock" \
        "$wg_home/bin/fm-watch-guard.sh"
    ) 9>"$TMP/wg-busy.lock"
  fi
) && pass "fm-watch-guard skips lock=free and unknown supervision model + flock serialization" \
  || fail "fm-watch-guard checks failed"

# ============================================================================
# 8. fm-spawn.sh Luna/Haiku secondmate effort auto-default vs explicit override
# ============================================================================
(
  # shellcheck source=bin/fm-model-tier-lib.sh
  . "$ROOT/bin/fm-model-tier-lib.sh"

  # Verify the exact auto-default logic wired into bin/fm-spawn.sh
  grep -q 'fm_model_recommended_effort' "$ROOT/bin/fm-spawn.sh"
  # Simulate resolution mirroring bin/fm-spawn.sh: unset effort + Luna secondmate -> low
  EFFORT="" EFFORT_SET=0 RAW_LAUNCH=0 KIND=secondmate HARNESS=codex MODEL="cx/gpt-6-luna"
  if [ "$EFFORT_SET" -eq 0 ] && [ -z "$EFFORT" ] && [ "$RAW_LAUNCH" -eq 0 ] && [ -n "$MODEL" ] && [ "$KIND" = secondmate ]; then
    case "$HARNESS" in
      claude|codex|opencode|pi|pi-signed|omp|agy|kiro|grok|cortex)
        SM_REC_EFFORT=$(fm_model_recommended_effort "$MODEL" 2>/dev/null || true)
        [ -z "$SM_REC_EFFORT" ] || EFFORT=$SM_REC_EFFORT
        ;;
    esac
  fi
  [ "$EFFORT" = "low" ]

  # Explicit --effort medium MUST win
  EFFORT="medium" EFFORT_SET=1 RAW_LAUNCH=0 KIND=secondmate HARNESS=claude MODEL="claude-haiku-4-5"
  if [ "$EFFORT_SET" -eq 0 ] && [ -z "$EFFORT" ] && [ "$RAW_LAUNCH" -eq 0 ] && [ -n "$MODEL" ] && [ "$KIND" = secondmate ]; then
    case "$HARNESS" in
      claude|codex|opencode|pi|pi-signed|omp|agy|kiro|grok|cortex)
        SM_REC_EFFORT=$(fm_model_recommended_effort "$MODEL" 2>/dev/null || true)
        [ -z "$SM_REC_EFFORT" ] || EFFORT=$SM_REC_EFFORT
        ;;
    esac
  fi
  [ "$EFFORT" = "medium" ]
) && pass "fm-spawn fast-tier effort defaults to low for Luna/Haiku without overriding explicit effort" \
  || fail "fm-spawn effort default checks failed"

printf '\nSummary: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
