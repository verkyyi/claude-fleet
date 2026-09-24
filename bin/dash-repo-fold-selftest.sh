#!/bin/bash
# dash-repo-fold-selftest.sh — ←/→ on a repo heading fold / unfold that repo's
# whole group (issue #1037).
#
# Under `all` in a 2+ repo fleet the row producer (bin/tmux-dashboard-rows.sh —
# the hub list AND the sidebar) opens each repo with an inert heading (#974).
# Since the footer picker went (#1034) that heading is also the per-repo focus:
# `←` on it folds every row under it away and `→` brings them back — the same
# gesture as folding a parent row, through the same helper
# (bin/dash-fold-toggle.sh). The bit is ONE session option, `@repo_fold`: the
# space-separated slugs of the folded groups, UNSET once the last one opens.
# Pinned here:
#   A. HUB — the hub's shape (`collapse hdr '' <target>`: {1}=hdr, {q} empty,
#      {4}=the heading's spawn target) prints the reload, sets @repo_fold, and
#      the next frame draws the group as its heading alone — `▸ tokenledger (2)`,
#      the count still the rows it hides — in BOTH frames; the other groups are
#      untouched. With text on the prompt line ←/→ stay cursor keys and fold
#      nothing. A second `←` on a folded heading is a dead key.
#   B. SIDEBAR — its shape (`expand hdr:<target>`) opens the group, and opening
#      the LAST folded one UNSETS the option, so the frame is byte-identical to
#      one that was never folded. `→` on an open heading is a dead key.
#   C. SEVERAL — two folded groups list both slugs; opening one keeps the other
#      folded; `none` folds the no-repo group.
#   D. THE LOUD ROW — a `needs` row in a folded group stays on the list (the
#      quiet layer folds, the loud one never does — the parent fold's rule), and
#      the sidebar keeps its current window.
#   E. NO-OPS — a bare `hdr` with no target, `hdr:`, a repo the fleet does not
#      host: nothing printed, no tmux mutation, no option. fleet-sidebar.py's
#      folds() offers a `hdr:<target>` heading and never a bare `hdr`; acts()
#      still hands no other action a heading.
#   F. DEGENERATE — a one-repo fleet: `←` on a heading writes nothing, and even
#      with @repo_fold set by hand both frames are byte-identical to the same
#      fleet without it.
# tmux runs on a PRIVATE socket via a PATH shim that logs every call; gh fails.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
FOLD="$BIN/dash-fold-toggle.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

CHECKS=0 FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; FAILS=$((FAILS+1)); }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-repo-fold.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/s"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/tmux.log"
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
unset TMUX TMUX_PANE FLEET_SESSION FLEET_REPO FLEET_MAIN FLEET_SIDEBAR_CURRENT 2>/dev/null || true
mkdir -p "$TMPDIR" "$FLEET_CONF_DIR/fleets/alpha/repos"
. "$BIN/fleet-lib.sh"

fconf() { printf 'FLEET_REPO="%s"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH=master\n' "$2" "$WORK/$3" > "$1"; }
fconf "$FLEET_CONF_DIR/fleets/alpha/conf"                      o/claude-fleet cf
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf" o/tokenledger tl

"$REAL_TMUX" -S "$SOCK" new-session -d -s alpha -n plan -x 200 -y 40 || { echo "no isolated tmux" >&2; exit 1; }
win() { tmux new-window -d -t alpha -n "$1"; shift; local w; w=$(tmux list-windows -t alpha -F '#{window_id}' | tail -n1)
        while [ "$#" -gt 1 ]; do tmux set -w -t "$w" "$1" "$2"; shift 2; done; }
win 'issue-2' @repo o/tokenledger @issue 2
win 'issue-1' @repo o/claude-fleet @issue 1
win norepo       @norepo 1
win 'kid'     @repo o/tokenledger @issue 9 @origin o-tokenledger:issue-2
win 'issue-3' @repo o/claude-fleet @issue 3

strip() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
raw()   { FLEET_SESSION=alpha FZF_COLUMNS=120 bash "$ROWS"; }
rows()  { raw | tail -n +2 | awk -F '\037' '{ print $1 "|" $3 }' | strip; }
side()  { FLEET_SESSION=alpha bash "$ROWS" --sidebar | tr '\037' '|'; }
# a rows() line → its heading text, or the window name (glyph/issue/tree cells dropped)
names() { awk -F'|' '{ l = $2; if ($1 == "hdr") { print l; next }
                       sub(/^ *[^ ]+ +(#[0-9]+ +)?. +/, "", l); sub(/ .*/, "", l); print l }'; }
opt()   { tmux show-option -t '=alpha:' -qv @repo_fold; }
# fold VERB TARGET [QUERY [FIELD4]] → the fzf action the helper printed, as the hub
# or the sidebar would run it (FLEET_SESSION set, inside a fake tmux client)
fold()  { : > "$WORK/tmux.log"; FLEET_SESSION=alpha TMUX=/fake,1,0 bash "$FOLD" "$@" 2>&1 </dev/null; }
mut='select-window|set-window-option|set -w|rename-window|kill-|new-window|respawn|swap-|move-|join-pane|display-message [^-]|display-message -[^p]'
mutated() { grep -Eq "$mut|set-option" "$WORK/tmux.log"; }

before_hub=$(raw | od -c); before_side=$(side)
eq    "0: nothing folded to begin with" "$(opt)" ""
eq    "0: the grouped frame, kid folded under its parent" "$(rows | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 tokenledger (2) issue-2 no repo (1) norepo "

# --- A. the hub's shape: {1}=hdr, {q}='', {4}=target -----------------------------
out=$(fold collapse hdr '' o/tokenledger)
eq    "A: ← on the heading reloads the list" "$out" "reload(bash $ROWS)"
eq    "A: …and sets the session option to the repo's slug" "$(opt)" "o-tokenledger"
r=$(rows)
eq    "A: the group is its heading alone, with the fold caret and its count" \
      "$(printf '%s\n' "$r" | names | tr '\n' ' ')" "claude-fleet (2) issue-1 issue-3 ▸ tokenledger (2) no repo (1) norepo "
eq    "A: the folded heading is still keyed hdr" "$(printf '%s\n' "$r" | grep -c '^hdr|▸ tokenledger (2)$')" "1"
eq    "A: …and still carries its spawn target in the 4th field" \
      "$(raw | grep 'tokenledger' | awk -F '\037' '{ print $4 }')" "o/tokenledger"
hasnt "A: no empty-state hint while sessions are merely folded" "$r" "No sessions"
s=$(side)
eq    "A: the sidebar draws the same fold" "$(printf '%s\n' "$s" | awk -F'|' '{ print $4 }' | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 ▸ tokenledger (2) no repo (1) norepo "
eq    "A: …its heading keeps its repo in the state field" "$(printf '%s\n' "$s" | grep '▸ tokenledger' | awk -F'|' '{ print $2 }')" "o/tokenledger"
out=$(fold collapse hdr 'abc' o/tokenledger)
eq    "A: with text on the prompt line ← is the cursor key" "$out" "backward-char"
out=$(fold expand hdr 'abc' o/tokenledger)
eq    "A: …and so is →" "$out" "forward-char"
eq    "A: …and neither touched the option" "$(opt)" "o-tokenledger"
out=$(fold collapse hdr '' o/tokenledger)
eq    "A: ← on a folded heading is a dead key" "$out" ""
CHECKS=$((CHECKS+1)); mutated && fail "A: …that still wrote tmux" "$(cat "$WORK/tmux.log")"
eq    "A: …option unchanged" "$(opt)" "o-tokenledger"
# the parent fold inside the group is untouched by the group fold
tmux set -w -t 'alpha:issue-2' @expand 1
eq    "A: an expanded parent inside a folded group stays hidden" "$(rows | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 ▸ tokenledger (2) no repo (1) norepo "

# --- B. the sidebar's shape: hdr:<target> ---------------------------------------
out=$(fold expand hdr:o/tokenledger)
eq    "B: → on the folded heading reloads the list" "$out" "reload(bash $ROWS)"
eq    "B: opening the last folded group UNSETS the option" "$(opt)" ""
eq    "B: …no @repo_fold left on the session at all" "$(tmux show-options -t '=alpha:' | grep -c '@repo_fold')" "0"
eq    "B: the parent's own fold came back as it was left (expanded)" "$(rows | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 tokenledger (2) issue-2 kid no repo (1) norepo "
tmux set -wu -t 'alpha:issue-2' @expand
eq    "B: the hub frame is byte-identical to before any fold" "$(raw | od -c)" "$before_hub"
eq    "B: …and so is the sidebar's" "$(side)" "$before_side"
out=$(fold expand hdr:o/tokenledger)
eq    "B: → on an open heading is a dead key" "$out" ""
CHECKS=$((CHECKS+1)); mutated && fail "B: …that still wrote tmux" "$(cat "$WORK/tmux.log")"

# --- C. several groups folded ---------------------------------------------------
fold collapse hdr:o/tokenledger >/dev/null
fold collapse hdr:none >/dev/null
eq    "C: two folded groups list both, in fold order" "$(opt)" "o-tokenledger none"
eq    "C: …both groups are their headings alone" "$(rows | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 ▸ tokenledger (2) ▸ no repo (1) "
fold expand hdr:o/tokenledger >/dev/null
eq    "C: opening one keeps the other" "$(opt)" "none"
eq    "C: …tokenledger back, no-repo still folded" "$(rows | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 tokenledger (2) issue-2 ▸ no repo (1) "
eq    "C: the sidebar agrees" "$(side | awk -F'|' '{ print $4 }' | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 tokenledger (2) issue-2 · 0/1 ✓ ▸ no repo (1) "
fold collapse hdr:o/claude-fleet >/dev/null
fold collapse hdr:o/tokenledger >/dev/null
eq    "C: every group folded — only headings, never the empty-state hint" "$(rows | tr '\n' '/')" \
      "hdr|▸ claude-fleet (2)/hdr|▸ tokenledger (2)/hdr|▸ no repo (1)/"
fold expand hdr:o/claude-fleet >/dev/null
fold expand hdr:o/tokenledger >/dev/null
fold expand hdr:none >/dev/null
eq    "C: all open again — option gone" "$(opt)" ""

# --- D. the loud row never folds; the sidebar keeps its current window ----------
fold collapse hdr:o/tokenledger >/dev/null
tmux set -w -t 'alpha:issue-2' @claude_state needs
r=$(rows)
eq    "D: a needs row shows through a folded heading" "$(printf '%s\n' "$r" | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 ▸ tokenledger (2) issue-2 no repo (1) norepo "
has   "D: …drawn red" "$(printf '%s\n' "$r" | grep 'issue-2')" "!"
tmux set -wu -t 'alpha:issue-2' @claude_state
eq    "D: quiet again — hidden again" "$(rows | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 ▸ tokenledger (2) no repo (1) norepo "
cur=$(tmux list-windows -t alpha -F '#{window_id} #{window_name}' | awk '$2 == "issue-2" { print $1 }')
eq    "D: the sidebar keeps its current window inside a folded group" \
      "$(FLEET_SIDEBAR_CURRENT=$cur side | awk -F'|' '{ print $4 }' | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 ▸ tokenledger (2) issue-2 · 0/1 ✓ no repo (1) norepo "
eq    "D: …the hub does not (it has no current row)" "$(rows | grep -c 'issue-2')" "0"
fold expand hdr:o/tokenledger >/dev/null

# --- E. no-ops ------------------------------------------------------------------
noop() {   # $1 = label, rest = fold args → prints nothing, mutates nothing, sets nothing
  out=$(fold "$@")
  eq "E: $1 prints nothing" "$out" ""
  CHECKS=$((CHECKS+1)); mutated && fail "E: $1 touched tmux" "$(cat "$WORK/tmux.log")"
  eq "E: $1 set no option" "$(opt)" ""
}
noop "bare hdr, no 4th field"   collapse hdr ''
noop "hdr with an empty target" collapse hdr:
noop "an unhosted repo"         collapse hdr:o/elsewhere
noop "the ? heading (no target)" collapse hdr '' ''
noop "→ on an open group"       expand hdr '' o/claude-fleet
noop "a bogus verb"             toggle hdr:o/tokenledger
# the sidebar's helpers
sel=$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(repr([m.folds(k) for k in ("hdr:o/tokenledger", "hdr:none", "hdr", "", "@7")]),
      repr([m.acts(k) for k in ("hdr:o/tokenledger", "hdr:none", "hdr", "@7")]))' "$BIN/fleet-sidebar.py")
eq    "E: folds() offers a targeted heading and a row, never a bare hdr; acts() still no heading" "$sel" \
      "['hdr:o/tokenledger', 'hdr:none', '', '', '@7'] ['', '', '', '@7']"
# the hub hands the 4th field to both arrow binds
eq    "E: the hub's ←/→ binds pass {4}" "$(grep -c 'dash-fold-toggle.sh \(collapse\|expand\) {1} {q} {4}' "$BIN/tmux-dashboard.sh")" "2"

# --- F. degenerate: a one-repo fleet ---------------------------------------------
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
one_hub=$(raw | od -c); one_side=$(side)
hasnt "F: one-repo fleet — no heading" "$one_side" "hdr|o/"
noop  "one-repo fleet, ← on a heading" collapse hdr:o/claude-fleet
noop  "one-repo fleet, the hub's shape" collapse hdr '' o/claude-fleet
tmux set-option -t '=alpha:' @repo_fold 'o-claude-fleet none'
eq    "F: a hand-set @repo_fold changes not one byte of the hub frame" "$(raw | od -c)" "$one_hub"
eq    "F: …nor of the sidebar's" "$(side)" "$one_side"
tmux set-option -t '=alpha:' -u @repo_fold
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

if [ "$FAILS" -gt 0 ]; then printf 'dash-repo-fold-selftest: %d of %d checks FAILED\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'dash-repo-fold-selftest: %d checks passed\n' "$CHECKS"
