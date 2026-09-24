#!/bin/bash
# repo-view-all-selftest.sh — one view: the grouped `all` list (issues #793, #980, #1034).
#
# The footer repo picker (fleet-pick.sh, behind a tap on the fleet name and the
# dash's ⌃z) is gone: every repo this fleet hosts shows at once, grouped under a
# heading, and a heading picks where a new session goes. Pinned here:
#   A. GONE — fleet-pick.sh, the pick key, the `fleet` footer range, the
#      @fleet_repo_label wiring and fleet_current_repo_set / fleet_repo_label[_sync];
#      nothing in bin/ or conf/ still names them.
#   B. FOOTER — status-left renders byte for byte what it rendered before in a
#      one-repo fleet (the degenerate case) except that the middle chip names the
#      LOGIN (@login, issue #1099) instead of the fleet (#S); no "· all" tail in
#      a 2+ repo one; tmux-conf-reload.sh stamps @login.
#   C. ALWAYS ALL — fleet_current_repo answers `all`, a stale current-repo file
#      (a repo this fleet hosts) is ignored, and fleet-up.sh deletes it.
#   D. PER-SPAWN ASK — fleet-repo-ask.sh (the ⌃n "which repo?" prompt) lists the
#      hosted repos only, prints the pick, exits 1 on esc; fleet-list.sh shows a
#      fleet's further repos as ↳ rows and a one-repo fleet as its single row.
#   E. DASH — `all` groups the rows under a heading naming each repo (issue #995:
#      no per-row tag), puts no-repo sessions in their own group at the foot; a
#      child whose @origin is repo-qualified (`<slug>:issue-N`, #789) folds under
#      its parent in the rows AND the fold toggle; a one-repo fleet ignores a stale
#      current-repo file.
#   F. NAMES — fleet_repo_short and its collision fallback.
# fzf is shimmed (records its input, answers with the row a test names); tmux runs
# on a PRIVATE socket via a PATH shim that logs every call; gh fails.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ASK="$BIN/fleet-repo-ask.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
FOLD="$BIN/dash-fold-toggle.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

CHECKS=0 FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; FAILS=$((FAILS+1)); }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

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
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
unset TMUX TMUX_PANE FLEET_PICK_ONLY FLEET_SESSION FLEET_REPO FLEET_MAIN 2>/dev/null || true
mkdir -p "$TMPDIR" "$FLEET_CONF_DIR/fleets/alpha/repos" "$FLEET_CONF_DIR/fleets/beta" "$FLEET_CONF_DIR/fleets/gamma"
. "$BIN/fleet-lib.sh"

fconf() { printf 'FLEET_REPO="%s"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH=master\n' "$2" "$WORK/$3" > "$1"; }
fconf "$FLEET_CONF_DIR/fleets/alpha/conf"           o/claude-fleet cf
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf" o/tokenledger tl
printf 'FLEET_REPO_SHORT="tl"\n' >> "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf"
fconf "$FLEET_CONF_DIR/fleets/beta/conf"            o/cee  cee
fconf "$FLEET_CONF_DIR/fleets/gamma/conf"           o/gee  gee

"$REAL_TMUX" -S "$SOCK" new-session -d -s alpha -n plan -x 200 -y 40 || { echo "no isolated tmux" >&2; exit 1; }
tmux new-session -d -s beta -x 200 -y 40
tmux new-session -d -s gamma -x 200 -y 40

ask() {    # $1 = current fleet, $2 = FZF_PICK pattern ('' = esc)
  : > "$WORK/tmux.log"; rm -f "$WORK/fzf.in"
  env TMUX=/fake,1,0 FAKE_CUR="$1" FZF_PICK="$2" bash "$ASK" >"$WORK/ask.out" 2>&1
}
keys() { awk -F '\037' '{ print $1 }' "$WORK/fzf.in"; }
ROOT="$BIN/.."
CONF="$ROOT/conf/tmux-attention.conf"

# --- A. the picker is gone -----------------------------------------------------
CHECKS=$((CHECKS+1)); [ -e "$BIN/fleet-pick.sh" ] && fail "A: bin/fleet-pick.sh must be gone (#1034)"
CHECKS=$((CHECKS+1)); [ -e "$BIN/fleet-xfleet-jump.sh" ] && fail "A: fleet-xfleet-jump.sh must be gone (#980)"
# no live referrer (a selftest may name them, to forbid them)
refs=$(grep -rlE 'fleet-pick\.sh|fleet_repo_label|fleet_current_repo_set|DASH_KEY_PICK|range=user\|fleet[^a-z]|mouse_status_range\},fleet\}' \
         "$ROOT/bin" "$ROOT/conf" "$ROOT/hooks" "$ROOT/commands" 2>/dev/null \
       | grep -v -- '-selftest\.sh$')
eq    "A: nothing in bin/conf/hooks/commands names the picker" "$refs" ""
for fn in fleet_current_repo_set fleet_repo_label fleet_repo_label_sync; do
  CHECKS=$((CHECKS+1)); declare -F "$fn" >/dev/null && fail "A: fleet-lib.sh still defines $fn"
done
hasnt "A: the dash keymap has no pick action" "$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)" "PICK"
hasnt "A: ctrl-z is not bound on the dash" "$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)" "ctrl-z"

# --- B. the footer -------------------------------------------------------------
# Render status-left's TEXT (style/range markup stripped: it draws nothing) on a
# private server, the pre-#1034 format beside today's, and compare byte for byte.
# #1099 swapped the fleet name (#S) for the login (@login), so the old format's
# #S is read as the login: every OTHER byte must still match.
OLD_SL='#[range=user|hub]#{?#{==:#W,plan},#[fg=#1a1b26#,bg=#7aa2f7#,bold]  ⌂  ,#[fg=#7aa2f7#,bg=#414868]  ⌂  }#[default]#[norange]#[fg=#7aa2f7,bold]#[range=user|fleet]  #S#{?@fleet_repo_label, · #{@fleet_repo_label},}  #[default]#[norange]#[range=user|attn]#{?#{&&:#{==:#{@claude_state},needs},#{&&:#{!=:#W,dash},#{!=:#W,backlog}}},#{?@attn_needs,#{?#{e|-:#{@attn_needs},1},#[fg=#f7768e#,bold]  ● #{e|-:#{@attn_needs},1}  #[default],},},#{?@attn_needs,#[fg=#f7768e#,bold]  ● #{@attn_needs}  #[default],}}#[norange]#[fg=#565f89]│'
NEW_SL=$(sed -n 's/^set -g status-left "\(.*\)"$/\1/p' "$CONF")
CHECKS=$((CHECKS+1)); [ -n "$NEW_SL" ] || fail "B: could not read status-left from $CONF"
EXP_SL=$(printf '%s' "$OLD_SL" | sed 's/#S#{?@fleet_repo_label/#{@login}#{?@fleet_repo_label/')
render() { tmux display-message -p -t alpha:plan "$1" | sed 's/#\[[^]]*\]//g'; }
tmux set -gu @fleet_repo_label
tmux set -g @login op-login
eq    "B: one-repo fleet footer renders byte for byte as before" "$(render "$NEW_SL")" "$(render "$EXP_SL")"
tmux set -w -t alpha:plan @attn_needs 3 2>/dev/null; tmux set -t alpha @attn_needs 3
eq    "B: …with the needs badge up too" "$(render "$NEW_SL")" "$(render "$EXP_SL")"
tmux set -t alpha -u @attn_needs
has   "B: the login name is drawn" "$(render "$NEW_SL")" "  op-login  "
hasnt "B: the fleet name is not" "$(render "$NEW_SL")" "alpha"
hasnt "B: the hub border title names the login, not #S" \
      "$(sed -n 's/^set -g pane-border-format "\(.*\)"$/\1/p' "$CONF" | grep -o 'FLEET HUB · [^ ]*')" "#S"
tmux set -gu @login
me=$(id -un)
if [ -n "$(tmux display-message -p '#{user}')" ]; then    # tmux ≥ 3.3
  has "B: unstamped server falls back to #{user}" "$(render "$NEW_SL")" "  $me  "
fi
bash "$BIN/tmux-conf-reload.sh" /dev/null "$CONF" "$CONF" >/dev/null 2>&1
eq    "B: tmux-conf-reload.sh stamps @login" "$(tmux show -gv @login 2>/dev/null)" "$me"
grep -q 'set -g @login "$(id -un)"' "$BIN/fleet-up.sh"
eq    "B: fleet-up.sh stamps @login on the fleet's socket" "$?" 0
tmux set -g @fleet_repo_label all      # a stale value left on a live server
hasnt 'B: 2+ repo fleet: no "· all" tail, even from a stale option' "$(render "$NEW_SL")" " · "
tmux set -gu @fleet_repo_label
tmux source-file "$CONF" >/dev/null 2>&1
for tbl in root fleet-sidebar; do
  b=$(tmux list-keys -T "$tbl" 2>/dev/null | grep ' MouseDown1Status ')
  has   "B: $tbl MouseDown1Status is bound" "$b" "MouseDown1Status"
  hasnt "B: $tbl MouseDown1Status has no fleet range" "$b" ",fleet}"
done

# --- C. always all ------------------------------------------------------------
eq    "C: default is all" "$(fleet_current_repo alpha)" "all"
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
eq    "C: a stale file naming a hosted repo is ignored" "$(fleet_current_repo alpha)" "all"
eq    "C: …in a one-repo fleet too" "$(printf 'o/cee\n' > "$FLEET_CONF_DIR/fleets/beta/current-repo"; fleet_current_repo beta)" "all"
has   "C: fleet-up.sh deletes the stale file" "$(cat "$BIN/fleet-up.sh")" 'rm -f "$FLEET_CONF_DIR/fleets/$NAME/current-repo"'

# --- D. the per-spawn ask ------------------------------------------------------
ask alpha ''
eq    "D: ask lists each hosted repo, no all" "$(keys | tr '\n' ' ')" "o/claude-fleet o/tokenledger "
hasnt "D: …and no other fleet's repo" "$(keys)" "o/cee"
has   "D: header asks which repo" "$(cat "$WORK/fzf.args")" "which repo"
has   "D: display only (key hidden)" "$(cat "$WORK/fzf.args")" "--with-nth=2"
eq    "D: esc prints nothing" "$(cat "$WORK/ask.out")" ""
ask alpha 'tokenledger'
eq    "D: a pick prints the repo" "$(cat "$WORK/ask.out")" "o/tokenledger"
eq    "D: …and sets nothing" "$(fleet_current_repo alpha)" "all"
hasnt "D: …nor touches the footer" "$(cat "$WORK/tmux.log")" "set-option"
: > "$WORK/tmux.log"
env TMUX=/fake,1,0 FAKE_CUR=beta FZF_PICK='tokenledger' bash "$ASK" alpha >"$WORK/ask.out" 2>&1
eq    "D: an explicit session wins over the pane's" "$(cat "$WORK/ask.out")" "o/tokenledger"
has   "D: dash-issue-new.sh asks through it" "$(cat "$BIN/dash-issue-new.sh")" 'fleet-repo-ask.sh" "$FLEET_SESSION"'
# fleet-list.sh shows the fleet and its repos: a ↳ row per further hosted repo
fl=$(bash "$BIN/fleet-list.sh")
has   "D: fleet-list lists alpha's second repo under it" "$(printf '%s\n' "$fl" | grep -A1 ' alpha ')" "↳"
has   "D: …with its checkout" "$(printf '%s\n' "$fl" | grep 'o/tokenledger')" "$WORK/tl"
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
hasnt "E: all → no per-row tag on the no-repo row" "$(printf '%s\n' "$r" | grep norepo | sed 's/.*norepo//')" "no repo"
eq    "E: all → no-repo group at the foot" "$(printf '%s\n' "$r" | tail -n1 | grep -c norepo)" "1"
has   "E: qualified origin folds as a child (└)" "$(printf '%s\n' "$r" | grep 'kid')" "└"
has   "E: its parent carries the subtree badge" "$(printf '%s\n' "$r" | grep 'issue-2')" "0/1 ✓"
# a stale current-repo file naming a hosted repo filters nothing any more
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
eq    "E: a stale current-repo file changes no row" "$(rows)" "$r"
# the fold toggle agrees: ← from the child shuts its repo-qualified parent's block
FLEET_SESSION=alpha bash "$FOLD" collapse 'alpha:kid' '' >/dev/null 2>&1
eq    "E: fold toggle reaches the qualified parent" "$(tmux show -wv -t 'alpha:issue-2' @expand 2>/dev/null)" ""
hasnt "E: collapsed child hidden" "$(rows)" "kid"
# degenerate: no overlay → a stale current-repo file changes nothing
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
r=$(rows)
has   "E: one-repo fleet shows every window" "$r" "issue-1"
has   "E: …including no-repo" "$r" "norepo"
hasnt "E: …with no badge" "$(printf '%s\n' "$r" | grep norepo)" "no repo"
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

# --- F. short tags ------------------------------------------------------------
eq    "F: short of claude-fleet" "$(fleet_repo_short o/claude-fleet)" "cf"
eq    "F: short of 24haowan-monorepo" "$(fleet_repo_short o/24haowan-monorepo)" "2m"
eq    "F: short of one word"     "$(fleet_repo_short o/tokenledger)" "to"
eq    "F: override wins"         "$(fleet_repo_short o/tokenledger tl)" "tl"
eq    "F: short_of reads the overlay" "$(fleet_repo_short_of alpha o/tokenledger)" "tl"
printf 'FLEET_REPO_SHORT="cf"\n' >> "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf"
eq    "F: colliding shorts fall back to names" "$(fleet_repo_shorts alpha | cut -f3 | tr '\n' ' ')" "claude-fleet tokenledger "

if [ "$FAILS" -gt 0 ]; then printf 'repo-view-all-selftest: %d of %d checks FAILED\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'repo-view-all-selftest: %d checks passed\n' "$CHECKS"
