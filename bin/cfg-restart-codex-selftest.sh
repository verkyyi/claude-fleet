#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word, not the keyword
# cfg-restart-codex-selftest.sh — an idle Codex session on an old fleet version is
# reopened onto the same thread, and told what changed (issue #1896, EPIC #1906 C3).
#
# fleet-cfg-restart.sh → fleet-migrate.sh --cfg-stale, for real, on an isolated
# tmux server (-L, the label IS the session name, as fleet-migrate.sh expects),
# with a FAKE Codex: a runner that binds the window the way fleet-codex.sh's
# SessionStart does (@cc_agent codex, @cc_launcher_pid, @codex_identity) and
# exits on a pasted /exit, then closes its window (= the close-on-exit hook); a
# fake launcher (FLEET_MIGRATE_LAUNCH) that logs its argv and binds the thread it
# was asked to resume.
#   A. reopen   — 待换新 (an older @agent_ver), `done` and idle: the tick reopens
#                 it; the launcher gets `--agent codex --codex-home <its home>
#                 --resume <its thread>` and the one-line 「fleet 已从 X 更新到 Y」;
#                 the new window is bound to the SAME thread, keeps @issue /
#                 @worktree / @fleet_id, carries @ver_told; /fleet-history has a
#                 `reason=ver-stale` row; cfg-restart.log says so
#   B. never    — a working Codex, a looping one: migrate refuses (state:…),
#                 nothing launched, the window untouched
#   C. unbound  — a Codex window whose launcher is gone: skipped, nothing typed
#   D. notice   — cfg_update_nudge: ver-stale names both versions; cfg-stale
#                 names the configuration; one line; the language rule; a
#                 worker's open PR (@pr_num) turns it into the ship's go-on
#                 (issue #2189)
#   E. Claude   — fleet_cfg_restart_why answers a Claude window exactly as before
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'cfg-restart-codex selftest: python3 absent — SKIP'; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo 'cfg-restart-codex selftest: tmux absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cfgcdx.XXXXXX")" || exit 2
S="cfgcdx$$"
trap '"$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
unset TMUX TMUX_PANE FLEET_CFG_RESTART FLEET_CFG_RESTART_IDLE FLEET_CFG_RESTART_MAX FLEET_MIGRATE_NUDGE
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
export FLEET_HISTORY_LEDGER="$WORK/landed.tsv" FLEET_MIGRATE_BOOT_WAIT=5 FLEET_MIGRATE_EXIT_WAIT=10
mkdir -p "$WORK/conf/fleets/$S" "$WORK/conf/global" "$WORK/fb" "$WORK/home-a" "$WORK/wt1" "$WORK/wt2" "$WORK/wt3" "$WORK/wt4"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"
printf 'claude aaaaaaaaaaaa fleet=1\ncodex cccccccccccc fleet=1\nver 222222222222\n' > "$WORK/conf/global/agent-cfg.expected"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }
T() { "$REAL_TMUX" -L "$S" "$@"; }

# --- the fake Codex: bind the window like fleet-codex.sh + its SessionStart hook,
# then read the tty until a line carrying /exit; close the window on the way out.
# <thread> [state]. The runner's own pid is the launcher (@cc_launcher_pid).
cat > "$WORK/fb/codex-runner" <<EOS
#!/bin/bash
W=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
tmux set-option -w -t "\$W" @cc_agent codex
tmux set-option -w -t "\$W" @cc_launcher_pid "\$\$"
tmux set-option -w -t "\$W" @codex_identity "{\"owner\":\"\$\$\",\"session_id\":\"\$1\",\"home\":\"$WORK/home-a\",\"remote\":\"\",\"cwd\":\"\$PWD\"}"
tmux set-option -w -t "\$W" @codex_session_id "\$1"
[ -z "\${FAKE_NOBIND:-}" ] || tmux set-option -w -t "\$W" @cc_launcher_pid 1
printf 'fake codex thread=%s\n' "\$1"
while IFS= read -r l; do case "\$l" in */exit*) break ;; esac; done
tmux run-shell -b "tmux kill-window -t '\$W'"
EOS
# --- the fake launcher (= fleet-session-wrap.sh): log argv, bind the resumed thread
cat > "$WORK/fb/launcher" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/launched"
t=''; while [ \$# -gt 0 ]; do [ "\$1" = --resume ] && t=\$2; shift; done
W=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
tmux set-option -w -t "\$W" @cc_agent codex
tmux set-option -w -t "\$W" @cc_launcher_pid "\$\$"
tmux set-option -w -t "\$W" @codex_identity "{\"owner\":\"\$\$\",\"session_id\":\"\$t\",\"home\":\"$WORK/home-a\",\"remote\":\"\"}"
exec sleep 600
EOS
chmod +x "$WORK/fb/"*
export FLEET_MIGRATE_LAUNCH="$WORK/fb/launcher"

T new-session -d -s "$S" -n home -x 200 -y 50 2>/dev/null || fail "could not start an isolated tmux server"
OLD=$(( $(date +%s) - 3600 ))
TH1=11111111-2222-3333-4444-555555555555
TH2=21111111-2222-3333-4444-555555555555
TH3=31111111-2222-3333-4444-555555555555
TH4=41111111-2222-3333-4444-555555555555
mk() {   # <name> <thread> <state> <wt> [env] → window id
  local id
  id=$(T new-window -d -t "$S:" -n "$1" -c "$4" -P -F '#{window_id}' "${5:-} $WORK/fb/codex-runner $2")
  T set-option -w -t "$id" @agent_cfg cccccccccccc; T set-option -w -t "$id" @agent_ver 111111111111
  T set-option -w -t "$id" @claude_state "$3"; T set-option -w -t "$id" @claude_state_ts "$OLD"
  T set-option -w -t "$id" @issue "${1#w}"; T set-option -w -t "$id" @worktree "$4"
  T set-option -w -t "$id" @fleet_id "fid-$1"
  printf '%s' "$id"
}
W1=$(mk w41 "$TH1" done "$WORK/wt1")
W2=$(mk w42 "$TH2" working "$WORK/wt2")
W3=$(mk w43 "$TH3" looping "$WORK/wt3")
W4=$(mk w44 "$TH4" done "$WORK/wt4" FAKE_NOBIND=1)
sleep 1
# the runner's state options are written after the window opens: set them again
for w in "$W1" "$W4"; do T set-option -w -t "$w" @claude_state done; T set-option -w -t "$w" @claude_state_ts "$OLD"; done
why() { bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why "$2" "$3"; echo "rc=$?"' _ "$BIN" "$S" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
eq "A: the judge — an idle 待换新 Codex qualifies" "rc=0" "$(why "$W1")"

# ============================================================================
# B. never — working / looping: migrate itself refuses (the judge asked again)
# ============================================================================
mig() { bash "$BIN/fleet-migrate.sh" --cfg-stale --session "$S" "$@" 2>&1; }
o=$(mig "$W2")
has "B: working Codex — refused" "$o" "not reopened for its configuration — state:working"
o=$(mig "$W3")
has "B: looping Codex — refused" "$o" "not reopened for its configuration — state:looping"
eq "B: …nothing launched" "" "$(cat "$WORK/launched" 2>/dev/null)"
eq "B: …the working window untouched" "$W2" "$(T display-message -p -t "$W2" '#{window_id}' 2>/dev/null)"

# ============================================================================
# C. unbound — the window's launcher is not the identity's owner
# ============================================================================
o=$(mig "$W4")
has "C: no live Codex session bound — skipped" "$o" "no live Codex session bound — skipped"
eq "C: …nothing launched" "" "$(cat "$WORK/launched" 2>/dev/null)"

# ============================================================================
# A. reopen — through the tick, the real migrate, the fake Codex
# ============================================================================
o=$(bash "$BIN/fleet-cfg-restart.sh" -- "$S" 2>&1)
has "A: the tick reopens the idle Codex" "$o" "reopen: $S:w41 ($W1)"
for _ in $(seq 1 60); do [ -s "$WORK/launched" ] && T list-windows -t "$S" -F '#{window_name} #{@codex_identity}' | grep -q "w41 .*$TH1" && break; sleep 0.5; done
L=$(cat "$WORK/launched" 2>/dev/null)
has "A: codex resume — the explicit agent" "$L" "--agent codex"
has "A: …in its own CODEX_HOME" "$L" "--codex-home $WORK/home-a"
has "A: …the SAME thread" "$L" "--resume $TH1"
has "A: …told 「fleet 已从 X 更新到 Y」" "$L" "fleet 已从 111111111111 更新到 222222222222"
eq "A: …one launch, one line" "1" "$(printf '%s\n' "$L" | grep -c .)"
NW=$(T list-windows -t "$S" -F '#{window_id} #{window_name}' | awk '$2 == "w41" {print $1}')
[ -n "$NW" ] || fail "A: no w41 window after the reopen" "$(T list-windows -t "$S" -F '#{window_id} #{window_name}')"
hasnt "A: a NEW window" "$NW" "$W1"
has "A: bound to the same thread" "$(T display-message -p -t "$NW" '#{@codex_identity}')" "$TH1"
eq "A: keeps @issue / @worktree / @fleet_id" "41 $WORK/wt1 fid-w41" \
   "$(T display-message -p -t "$NW" '#{@issue} #{@worktree} #{@fleet_id}')"
eq "A: carries @cc_agent codex and @ver_told" "codex 222222222222" "$(T display-message -p -t "$NW" '#{@cc_agent} #{@ver_told}')"
for _ in $(seq 1 20); do grep -q "reason=ver-stale" "$FLEET_HISTORY_LEDGER" 2>/dev/null && break; sleep 0.3; done
has "A: /fleet-history row reason=ver-stale" "$(cat "$FLEET_HISTORY_LEDGER" 2>/dev/null)" "$TH1	reason=ver-stale	resumed"
has "A: cfg-restart.log says ver-stale" "$(cat "$BIN/../logs/cfg-restart.log" 2>/dev/null)" "$S:w41 ($W1) reason=ver-stale"

# ============================================================================
# D. the notice
# ============================================================================
n=$(bash -c 'set -u; . "$1/fleet-migrate.sh"; FLEET_LANG_RULE_RESUME=KEEP-LANG; cfg_update_nudge 111 222 ver-stale' _ "$BIN")
has "D: ver-stale names both versions" "$n" "fleet 已从 111 更新到 222"
has "D: …and the language rule" "$n" "KEEP-LANG"
eq "D: …one line" "1" "$(printf '%s\n' "$n" | wc -l | tr -d ' ')"
n=$(bash -c 'set -u; . "$1/fleet-migrate.sh"; cfg_update_nudge "" 222 ver-stale' _ "$BIN")
has "D: no old version stamped — 旧版" "$n" "fleet 已从 旧版 更新到 222"
n=$(bash -c 'set -u; . "$1/fleet-migrate.sh"; cfg_update_nudge 222 222 cfg-stale' _ "$BIN")
has "D: cfg-stale names the configuration" "$n" "fleet 的会话配置已更新"
hasnt "D: …no PR — nothing to act on stays" "$n" "fleet-claim ship"
has "D: …\"Nothing to act on\"" "$n" "Nothing to act on"
# a worker mid-ship (an OPEN PR on @pr_num, issue #2189): told to carry the ship on
n=$(bash -c 'set -u; . "$1/fleet-migrate.sh"; FLEET_LANG_RULE_RESUME=KEEP-LANG; cfg_update_nudge 222 222 cfg-stale "#77"' _ "$BIN")
has "D: an open PR — continue the ship" "$n" "Your PR #77 is still open"
has "D: …verdict → merge → report" "$n" "continue the /fleet-claim ship — read the verdict (pr_verdict, wait on PENDING), merge on READY, then report"
hasnt "D: …never \"nothing to act on\"" "$n" "Nothing to act on"
has "D: …the language rule" "$n" "KEEP-LANG"
eq "D: …one line" "1" "$(printf '%s\n' "$n" | wc -l | tr -d ' ')"
n=$(bash -c 'set -u; . "$1/fleet-migrate.sh"; cfg_update_nudge 111 222 ver-stale 77' _ "$BIN")
has "D: a bare number reads as #N, ver-stale too" "$n" "fleet 已从 111 更新到 222"
has "D: …" "$n" "Your PR #77 is still open"

# ============================================================================
# E. Claude — the judge answers a Claude window as before
# ============================================================================
WC=$(T new-window -d -t "$S:" -n claudew -P -F '#{window_id}' 'sleep 600')
T set-option -w -t "$WC" @agent_cfg bbbbbbbbbbbb; T set-option -w -t "$WC" @claude_state done; T set-option -w -t "$WC" @claude_state_ts "$OLD"
eq "E: Claude, 配置旧 + idle → reopen" "rc=0" "$(why "$WC")"
T set-option -w -t "$WC" @claude_state working
eq "E: Claude working → never" "state:working rc=1" "$(why "$WC")"

printf 'cfg-restart-codex selftest: PASS (%s checks)\n' "$CHECKS"
