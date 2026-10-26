#!/usr/bin/env bash
set -eu
root=$PWD
lab="$root/.test-phase"
real_tmux=$(command -v tmux)
socket="$root/.t"
mkdir -p "$lab/home" "$lab/state"
cleanup() { "$real_tmux" -S "$socket" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
unset TMUX HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_HOME="$lab/home"
tmux() { "$real_tmux" -S "$socket" "$@"; }
export -f tmux
HOME="$lab/home" tmux -f /dev/null new-session -d -s agy-guard -n shell -x 120 -y 40 'exec bash --noprofile --norc'
. "$root/bin/fm-backend.sh"
. "$root/bin/fm-busy-lib.sh"
fm_backend_source tmux
sleep 0.3
printf 'Isolated terminal grid: '
tmux display-message -p -t agy-guard:shell '#{pane_width}x#{pane_height}'
printf 'Actual foreground command: '
tmux display-message -p -t agy-guard:shell '#{pane_current_command}'
got=$(fm_backend_agent_state tmux agy-guard:shell)
printf 'Recovery state of bare shell: %s\n' "$got"
[ "$got" = dead ]
got=$(fm_busy_classify_live tmux agy-guard:shell agy shell "$lab/state")
printf 'Agy turn state of bare shell with no footer: %s\n' "$got"
[ "$got" = 'unknown agy-regex' ]
printf 'Shell visible capture:\n'
fm_backend_capture tmux agy-guard:shell 40
# Real pane inventory must distinguish an absent window from the existing one.
got=$(fm_backend_agent_state tmux agy-guard:absent)
printf 'Recovery state of missing recorded window: %s\n' "$got"
[ "$got" = missing ]
got=$(fm_busy_classify_live tmux agy-guard:absent agy absent "$lab/state")
printf 'Agy turn state of missing recorded window: %s\n' "$got"
case "$got" in 'dead endpoint-gone'|'unknown capture-failed') ;; *) exit 1 ;; esac
printf 'Remaining windows: '
tmux list-windows -t agy-guard -F '#{window_name}'
cleanup
trap - EXIT
printf 'Isolated terminal server removed.\n'
