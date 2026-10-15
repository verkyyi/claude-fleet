#!/bin/bash
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/reap-norepo.XXXXXX")
SOCKET="scratch-reap-norepo-$$"
cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || :
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/conf"
for source in "$BIN"/*; do ln -s "$source" "$WORK/bin/${source##*/}"; done
rm "$WORK/bin/fleet-worker-stop.sh"
cat > "$WORK/bin/fleet-worker-stop.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$REAP_CALLS"
[ "$1" = "$REAP_EXPECT_SESSION" ] || { echo refused:not-found; exit 5; }
[ "$2" = "fid:$REAP_EXPECT_ID" ] || { echo refused:wrong-id; exit 5; }
echo stopped:closed
EOF
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
export FLEET_REAP_LOCAL=1 REAP_CALLS="$WORK/calls" REAP_EXPECT_SESSION="$SOCKET"
export REAP_EXPECT_ID=11111111-2222-4333-8444-555555555555
target=$(tmux -L "$SOCKET" -f /dev/null new-session -d -P -F '#{window_id}' -s "$SOCKET" 'sleep 600')
tmux -L "$SOCKET" set-window-option -t "$target" @norepo 1
tmux -L "$SOCKET" set-window-option -t "$target" @fleet_id "$REAP_EXPECT_ID"
tmux -L "$SOCKET" set-window-option -t "$target" @claude_state 'done'
tmux -L "$SOCKET" new-session -d -s "$SOCKET@view-test" -t "$SOCKET"
pool_pane=$(tmux -L "$SOCKET" new-session -d -P -F '#{pane_id}' -s "$SOCKET-pool" 'sleep 600')
socket_path=$(tmux -L "$SOCKET" display-message -p '#{socket_path}')
export TMUX="$socket_path,0,0" TMUX_PANE="$pool_pane"
result=$(bash "$WORK/bin/dash-reap.sh" "$target" --yes)
[ "$result" = reaped:full ] || { printf 'FAIL: %s\n' "$result"; exit 1; }
[ "$(cat "$REAP_CALLS")" = "$SOCKET fid:$REAP_EXPECT_ID" ]
unset TMUX_PANE
[ "$(tmux display-message -p '#{?#{session_group},#{session_group},#{session_name}}')" = "$SOCKET-pool" ]
result=$(bash "$WORK/bin/dash-reap.sh" "$target" --yes)
[ "$result" = reaped:full ] || { printf 'FAIL without caller pane: %s\n' "$result"; exit 1; }
tmux -L "$SOCKET" set-window-option -t "$target" @claude_state working
if result=$(bash "$WORK/bin/dash-reap.sh" "$target" --yes); then
  echo 'FAIL: busy no-repo session was accepted'
  exit 1
fi
[ "$result" = skip:live ]
[ "$(wc -l < "$REAP_CALLS" | tr -d ' ')" = 2 ]
echo 'PASS target fleet wins over pool caller and grouped view; busy session remains protected'
