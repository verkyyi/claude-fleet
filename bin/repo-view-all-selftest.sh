#!/bin/bash
# repo-view-all-selftest.sh — one view: the grouped `all` list (issues #793, #980, #1034).
#
# The footer repo picker (fleet-pick.sh, behind a tap on the fleet name and the
# dash's ⌃z) is gone: every repo this fleet hosts shows at once, grouped under a
# heading, and a heading picks where a new session goes. Pinned here:
#   A. GONE — fleet-pick.sh, the pick key, the `fleet` footer range, the
#      @fleet_repo_label wiring and fleet_current_repo_set / fleet_repo_label[_sync];
#      nothing in bin/ or conf/ still names them.
#   B. FOOTER — status-left renders `  ☰  <login> ● N  ` (issue #1616; no client here,
#      so the < 60-column layout — tmux-status-selftest.sh leg L drives the wide one) (issue #1534's
#      one layout; the middle chip names the LOGIN, @login, issue #1099, never the
#      fleet #S); no "· all" tail in a 2+ repo one; tmux-conf-reload.sh stamps
#      @login.
#   C. ALWAYS ALL — fleet_current_repo is gone (#1038): nothing in bin/ reads the
#      retired picker's current-repo file, and fleet-up.sh deletes it.
#   D. fleet-list.sh shows a fleet's further repos as ↳ rows and a one-repo fleet as
#      its single row. (The ⌃n "which repo?" prompt went with the dash, issue #4902.)
#   E. DASH — `all` groups the rows under a heading naming each repo (issue #995:
#      no per-row tag), puts no-repo sessions in their own group at the foot; a
#      child whose @origin is repo-qualified (`<slug>:issue-N`, #789) folds under
#      its parent in the rows and goes when its block is shut; a one-repo fleet ignores a stale
#      current-repo file.
#   F. NAMES — fleet_repo_short and its collision fallback.
# fzf is shimmed (records its input, answers with the row a test names); tmux runs
# on a PRIVATE socket via a PATH shim that logs every call; gh fails.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
st_real_tmux

st_tally count miss
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || st_miss "$1: expected [$3], got [$2]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-view-all.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/s"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$WORK/bin"
# tmux shim: every call logged; `display-message -p` for the session name answers
# $FAKE_CUR (the picker runs as a plain process here, not in a pane).
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/tmux.log"
case "\$*" in
  *display-message*-p*'#S'*|*display-message*-p*'#{session_name}'*)
    [ -n "\${FAKE_CUR:-}" ] && { printf '%s\n' "\$FAKE_CUR"; exit 0; } ;;
  *detach-client*) exit 0 ;;
esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# fzf shim: record stdin; answer with the first data row whose DISPLAY field
# matches $FZF_PICK (an ERE), or nothing (= esc) when it is unset.
cat > "$WORK/bin/fzf" <<EOF
#!/bin/sh
cat > "$WORK/fzf.in"
printf '%s\n' "\$*" > "$WORK/fzf.args"
[ -n "\${FZF_PICK:-}" ] || exit 130
awk -F '\037' -v p="\$FZF_PICK" '\$2 ~ p { print; exit }' "$WORK/fzf.in"
EOF
st_fake_gh "$WORK/bin"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
unset TMUX TMUX_PANE FLEET_PICK_ONLY FLEET_SESSION FLEET_REPO FLEET_MAIN 2>/dev/null || true
mkdir -p "$TMPDIR" "$FLEET_CONF_DIR/fleets/alpha/repos" "$FLEET_CONF_DIR/fleets/beta" "$FLEET_CONF_DIR/fleets/gamma"
. "$BIN/fleet-lib.sh"

fconf() { printf 'FLEET_REPO="%s"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH=master\n' "$2" "$WORK/$3" > "$1"; }
mkdir -p "$FLEET_CONF_DIR/fleets/alpha/repos"; : > "$FLEET_CONF_DIR/fleets/alpha/conf"   # every repo is an overlay (#1937, #4806)
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/o-claude-fleet.conf" o/claude-fleet cf; printf 'o-claude-fleet\n' > "$FLEET_CONF_DIR/fleets/alpha/repos/.order"
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf" o/tokenledger tl
printf 'FLEET_REPO_SHORT="tl"\n' >> "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf"
mkdir -p "$FLEET_CONF_DIR/fleets/beta/repos"; : > "$FLEET_CONF_DIR/fleets/beta/conf"   # every repo is an overlay (#1937, #4806)
fconf "$FLEET_CONF_DIR/fleets/beta/repos/o-cee.conf" o/cee cee; printf 'o-cee\n' > "$FLEET_CONF_DIR/fleets/beta/repos/.order"
mkdir -p "$FLEET_CONF_DIR/fleets/gamma/repos"; : > "$FLEET_CONF_DIR/fleets/gamma/conf"   # every repo is an overlay (#1937, #4806)
fconf "$FLEET_CONF_DIR/fleets/gamma/repos/o-gee.conf" o/gee gee; printf 'o-gee\n' > "$FLEET_CONF_DIR/fleets/gamma/repos/.order"

"$REAL_TMUX" -S "$SOCK" new-session -d -s alpha -n plan -x 200 -y 40 || { echo "no isolated tmux" >&2; exit 1; }
tmux new-session -d -s beta -x 200 -y 40
tmux new-session -d -s gamma -x 200 -y 40

ROOT="$BIN/.."
CONF="$ROOT/conf/tmux-attention.conf"

# --- A. the picker is gone -----------------------------------------------------
# fleet-pick.sh, fleet-xfleet-jump.sh, every referrer and the fleet-lib functions
# (#1034, #980, #1038) are conf/gone.list's, read by gone-selftest.sh.
st_hasnt "A: the 看台's key table has no pick action" "$(bash "$BIN/dash-keymap.sh" --panel switch actions 2>/dev/null)" "pick"

# --- B. the footer -------------------------------------------------------------
# Render status-left's TEXT (style/range markup stripped: it draws nothing) on a
# private server and compare it with the mockup's text byte for byte. Until issue
# #1534 the reference was the pre-#1034 format; #1534 gave the footer its one
# layout, so the reference is now that layout.
BARCONF="$ROOT/conf/tmux-bar.conf"   # the bar's own file since issue #1534
NEW_SL=$(sed -n 's/^set -g status-left "\(.*\)"$/\1/p' "$BARCONF")
CHECKS=$((CHECKS+1)); [ -n "$NEW_SL" ] || st_miss "B: could not read status-left from $BARCONF"
. "$BIN/fleet-palette.sh"; fleet_palette_load; fleet_palette_expand "$NEW_SL"
# shellcheck disable=SC2154  # _fpe: fleet_palette_expand's result
NEW_SL=$_fpe
render() { tmux display-message -p -t alpha:plan "$1" | sed 's/#\[[^]]*\]//g'; }
tmux set -gu @fleet_repo_label
tmux set -g @login op-login
# A node's line is one hint since issue #1714 (the client draws the bar): it
# names the login, and a waiting session changes nothing on it.
eq    "B: one-repo fleet footer is the node's hint (#1714)" "$(render "$NEW_SL")" ' 请用 fleet 客户端 · run `fleet` · op-login 的节点会话，只跑执行会话 '
tmux set -w -t alpha:plan @attn_needs 3 2>/dev/null; tmux set -t alpha @attn_needs 3
st_hasnt "B: …with sessions waiting, still no badge" "$(render "$NEW_SL")" "●"
tmux set -t alpha -u @attn_needs
st_has   "B: the login name is drawn" "$(render "$NEW_SL")" " op-login "
st_hasnt "B: the fleet name is not" "$(render "$NEW_SL")" "alpha"
st_hasnt "B: the hub border title names the login, not #S" \
      "$(sed -n 's/^set -g pane-border-format "\(.*\)"$/\1/p' "$CONF" | grep -o 'FLEET HUB · [^ ]*')" "#S"
tmux set -gu @login
me=$(id -un)
if [ -n "$(tmux display-message -p '#{user}')" ]; then    # tmux ≥ 3.3
  st_has "B: unstamped server falls back to #{user}" "$(render "$NEW_SL")" " $me "
fi
bash "$BIN/tmux-conf-reload.sh" /dev/null "$CONF" "$CONF" >/dev/null 2>&1
eq    "B: tmux-conf-reload.sh stamps @login" "$(tmux show -gv @login 2>/dev/null)" "$me"
grep -q 'set -g @login "$(id -un)"' "$BIN/fleet-up.sh"
eq    "B: fleet-up.sh stamps @login on the fleet's socket" "$?" 0
tmux set -g @fleet_repo_label all      # a stale value left on a live server
st_hasnt 'B: 2+ repo fleet: no "· all" tail, even from a stale option' "$(render "$NEW_SL")" "· all"
tmux set -gu @fleet_repo_label
tmux source-file "$CONF" >/dev/null 2>&1
# A node binds no status click of its own since issue #1714 (root keeps tmux's
# stock click; the list's key table went with the list, #1713) — absence is
# dash-keymap-selftest.sh leg 8's, on a server no ~/.tmux.conf reached.
b=$(tmux list-keys -T root 2>/dev/null | grep ' MouseDown1Status ')
st_has   "B: root MouseDown1Status is bound" "$b" "MouseDown1Status"
st_hasnt "B: root MouseDown1Status has no fleet range" "$b" ",fleet}"

# --- C. always all ------------------------------------------------------------
# No script reads the retired picker's `current-repo` file (#1038, conf/gone.list):
# the one live mention is fleet-up.sh deleting it. (E below and the other multi-repo
# selftests pin the behaviour — a stale file changes no row, anchor, backlog or ledger.)
st_has   "C: …to delete the stale file" "$(cat "$BIN/fleet-up.sh")" 'rm -f "$FLEET_CONF_DIR/fleets/$NAME/current-repo"'

# --- D. fleet-list ---------------------------------------------------------------
# fleet-list.sh shows the fleet and its repos: a ↳ row per further hosted repo
fl=$(bash "$BIN/fleet-list.sh")
st_has   "D: fleet-list lists alpha's second repo under it" "$(printf '%s\n' "$fl" | grep -A1 ' alpha ')" "↳"
st_has   "D: …with its checkout" "$(printf '%s\n' "$fl" | grep 'o/tokenledger')" "$WORK/tl"
eq    "D: one-repo fleets print one row each (no ↳)" "$(printf '%s\n' "$fl" | grep -c '↳')" "1"
tmux kill-session -t beta; tmux kill-session -t gamma

# --- E. the dash: one grouped `all` list ---------------------------------------
tmux new-window -d -t alpha -n 'issue-1'
tmux set -w -t 'alpha:issue-1' @repo o/claude-fleet; tmux set -w -t 'alpha:issue-1' @issue 1
tmux new-window -d -t alpha -n 'issue-2'
tmux set -w -t 'alpha:issue-2' @repo o/tokenledger; tmux set -w -t 'alpha:issue-2' @issue 2
tmux set -w -t 'alpha:issue-2' @expand 1
tmux new-window -d -t alpha -n 'kid'
tmux set -w -t 'alpha:kid' @repo o/tokenledger; tmux set -w -t 'alpha:kid' @issue 9
tmux set -w -t 'alpha:kid' @origin o-tokenledger:issue-2
tmux new-window -d -t alpha -n norepo
tmux set -w -t alpha:norepo @norepo 1
rows() { FLEET_SESSION=alpha FZF_COLUMNS=120 bash "$ROWS" | tail -n +2 | awk -F '\037' '{ print $3 }' | sed "s/$(printf '\033')\[[0-9;]*m//g"; }
r=$(rows)
eq    "E: all → claude-fleet row under its heading" "$(printf '%s\n' "$r" | grep -A1 '^claude-fleet (1)' | tail -n1 | grep -c 'issue-1')" "1"
eq    "E: all → tokenledger row under its heading" "$(printf '%s\n' "$r" | grep -A1 '^tokenledger (2)' | tail -n1 | grep -c 'issue-2')" "1"
eq    "E: all → no-repo row under its heading" "$(printf '%s\n' "$r" | grep -A1 '^no repo (1)' | tail -n1 | grep -c norepo)" "1"
st_hasnt "E: all → no per-row tag on the no-repo row" "$(printf '%s\n' "$r" | grep norepo | sed 's/.*norepo//')" "no repo"
eq    "E: all → no-repo group at the foot" "$(printf '%s\n' "$r" | tail -n1 | grep -c norepo)" "1"
st_has   "E: qualified origin folds as a child (└)" "$(printf '%s\n' "$r" | grep 'kid')" "└"
st_has   "E: its parent carries the subtree badge" "$(printf '%s\n' "$r" | grep 'issue-2')" "0/1"
# a stale current-repo file naming a hosted repo filters nothing any more
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
eq    "E: a stale current-repo file changes no row" "$(rows)" "$r"
# the parent's block shut (its @expand off — ⌘P's fold; the dash's ←/→ went with
# the dash, issue #4902): the repo-qualified child goes with it
tmux set -wu -t 'alpha:issue-2' @expand
st_hasnt "E: collapsed child hidden" "$(rows)" "kid"
# degenerate: no overlay → a stale current-repo file changes nothing
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
r=$(rows)
st_has   "E: one-repo fleet shows every window" "$r" "issue-1"
st_has   "E: …including no-repo" "$r" "norepo"
st_hasnt "E: …with no badge" "$(printf '%s\n' "$r" | grep norepo)" "no repo"
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

# --- F. short tags ------------------------------------------------------------
eq    "F: short of claude-fleet" "$(fleet_repo_short o/claude-fleet)" "cf"
eq    "F: short of 24acme-monorepo" "$(fleet_repo_short o/24acme-monorepo)" "2m"
eq    "F: short of one word"     "$(fleet_repo_short o/tokenledger)" "to"
eq    "F: override wins"         "$(fleet_repo_short o/tokenledger tl)" "tl"
eq    "F: short_of reads the overlay" "$(fleet_repo_short_of alpha o/tokenledger)" "tl"
printf 'FLEET_REPO_SHORT="cf"\n' >> "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf"
eq    "F: colliding shorts fall back to names" "$(fleet_repo_shorts alpha | cut -f3 | tr '\n' ' ')" "claude-fleet tokenledger "

st_done
