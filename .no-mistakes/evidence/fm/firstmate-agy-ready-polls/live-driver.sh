#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
SCRATCH="$ROOT/.agy-live-check"
EVIDENCE=/home/ryzengrind/.no-mistakes/evidence/01M7E8T4DHZBQYYKAMDP18Y2YA
export HOME="$SCRATCH/home" TMPDIR="$SCRATCH/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 SHELL=/bin/bash TERM=xterm-256color
export TREEHOUSE_ROOT="$SCRATCH/pool" FM_HOME="$HOME"
export FM_STATE_OVERRIDE="$HOME/state" FM_DATA_OVERRIDE="$HOME/data"
export FM_PROJECTS_OVERRIDE="$HOME/projects" FM_CONFIG_OVERRIDE="$HOME/config"
export FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1
export TMUX_TMPDIR
TMUX_TMPDIR=$(mktemp -d /tmp/fm-agy-nm.XXXXXX)
mkdir -p "$HOME"/{state,data,projects,config} "$TMPDIR"
cleanup() {
  tmux kill-server 2>/dev/null || true
  rmdir "$TMUX_TMPDIR/tmux-$(id -u)" "$TMUX_TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT
if [ ! -d "$SCRATCH/project/.git" ]; then
  git -C "$SCRATCH/project" init -q -b main
  printf '# Readiness live fixture\n' > "$SCRATCH/project/README.md"
  git -C "$SCRATCH/project" add README.md
  git -C "$SCRATCH/project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
fi
tmux -f /dev/null new-session -d -x 120 -y 40 -s firstmate -c "$SCRATCH/project" 'bash --noprofile --norc'
tmux set-option -g default-shell /bin/bash
tmux set-option -g default-command 'bash --noprofile --norc'
tmux show-options -g default-size
for scenario in override default; do
  id="agy-live-$scenario"
  mkdir -p "$HOME/data/$id"
  printf '# Task\n\n## Captain\047s intent\nVerify readiness in an isolated fixture.\n\n## Firstmate spec\nDo not modify any files. Reply with READY.\n' > "$HOME/data/$id/brief.md"
  if [ "$scenario" = override ]; then
    export FM_AGY_READY_POLLS=5 FM_AGY_POLL_INTERVAL=.1
  else
    unset FM_AGY_READY_POLLS FM_AGY_POLL_INTERVAL
  fi
  printf 'Scenario: %s; started: %s\n' "$scenario" "$(date -u +%FT%TZ)"
  started=$SECONDS
  "$ROOT/bin/fm-spawn.sh" "$id" "$SCRATCH/project" --backend tmux --harness agy --mode no-mistakes --yolo off > "$EVIDENCE/live-$scenario-spawn.txt" 2>&1 &
  spawn_pid=$!
  while kill -0 "$spawn_pid" 2>/dev/null; do
    if tmux capture-pane -p -S -120 -t "firstmate:fm-$id" > "$SCRATCH/capture" 2>/dev/null; then
      cp "$SCRATCH/capture" "$EVIDENCE/live-$scenario-pane.txt"
    fi
    sleep .1
  done
  rc=0
  wait "$spawn_pid" || rc=$?
  printf 'Scenario: %s; exit=%s; elapsed=%ss\n' "$scenario" "$rc" "$((SECONDS-started))"
  cat "$EVIDENCE/live-$scenario-spawn.txt"
  if [ -f "$HOME/state/$id.status" ]; then
    cp "$HOME/state/$id.status" "$EVIDENCE/live-$scenario-status.txt"
    cat "$EVIDENCE/live-$scenario-status.txt"
  fi
  tmux list-windows -t firstmate -F '#{window_name}'
done
