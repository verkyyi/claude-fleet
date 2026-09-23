#!/bin/bash
# fleet-pick-repo-selftest.sh — the repo picker (issues #793, #980).
#
# One picker (bin/fleet-pick.sh, behind the footer's fleet name and the dash's pick
# key) lists `all repos` + each repo THIS fleet hosts — no fleet rows: one fleet per
# login (EPIC #977), so there is nothing to switch to. Pinned here:
#   A. REPO-ONLY ROWS — `all repos` then each hosted repo, the current one marked;
#      no fleet row, not even for another live fleet on the machine.
#   B. PICK — a repo row sets this fleet's current repo, republishes the footer
#      label, and never reattaches.
#   C. NO SWITCHING — no row, key or header offers another fleet; nothing in the
#      picker detaches, and FLEET_PICK_ONLY (the retired ● jump) is not read.
#   D. DEGENERATE — a one-repo fleet gets a note and no picker; --repo-only still
#      asks for a repo (the new-issue path); fleet-list.sh shows a fleet's further
#      repos as ↳ rows and a one-repo fleet as its single row.
#   E. DASH — the rows follow the current repo: a picked repo shows its own
#      windows only; `all` groups the rows under a heading naming each repo
#      (issue #995: no per-row tag), puts no-repo sessions in their own group
#      at the foot; a child whose @origin is
#      repo-qualified (`<slug>:issue-N`, #789) folds under its parent in the rows
#      AND the fold toggle; a one-repo fleet ignores a stale current-repo file.
#   F. LABEL + NAMES — fleet_repo_label[_sync] (`· all` / `· <name>`, unset at one
#      repo), the status-left wiring, fleet_repo_short and its collision fallback.
# fzf is shimmed (records its input, answers with the row a test names); tmux runs
# on a PRIVATE socket via a PATH shim that logs every call; gh fails.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
PICK="$BIN/fleet-pick.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
FOLD="$BIN/dash-fold-toggle.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

CHECKS=0 FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; FAILS=$((FAILS+1)); }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fpick-repo.XXXXXX")" || exit 2
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

pick() {   # $1 = current fleet, $2 = FZF_PICK pattern ('' = esc); rest = env
  local cur=$1 pat=$2; shift 2
  : > "$WORK/tmux.log"; rm -f "$WORK/fzf.in"
  env TMUX=/fake,1,0 FAKE_CUR="$cur" FZF_PICK="$pat" "$@" bash "$PICK" >"$WORK/pick.out" 2>&1
}
disp() { awk -F '\037' '{ print $2 }' "$WORK/fzf.in"; }
keys() { awk -F '\037' '{ print $1 }' "$WORK/fzf.in"; }

# --- A. repo-only rows ---------------------------------------------------------
pick alpha ''
d=$(disp); k=$(keys)
eq    "A: rows = all + each repo, in order"       "$(printf '%s\n' "$k" | tr '\n' ' ')" "all o/claude-fleet o/tokenledger "
has   "A: the default current repo (all) marked"  "$(printf '%s\n' "$d" | grep 'all repos')" "← viewing"
hasnt "A: no fleet row for this fleet"            "$d" "alpha"
hasnt "A: no fleet row for another live fleet"    "$d" "beta"
hasnt "A: …nor its repo"                          "$k" "o/cee"
has   "A: header says repo"                       "$(cat "$WORK/fzf.args")" "pick a repo"
has   "A: display only (key hidden)"              "$(cat "$WORK/fzf.args")" "--with-nth=2"

# --- B. pick a repo: set, label, no reattach -----------------------------------
pick alpha 'tokenledger'
eq    "B: alpha's current repo"   "$(fleet_current_repo alpha)" "o/tokenledger"
has   "B: label republished"      "$(cat "$WORK/tmux.log")" "set-option -g @fleet_repo_label tokenledger"
hasnt "B: no reattach"            "$(cat "$WORK/tmux.log")" "detach-client"
pick alpha 'tokenledger'
has   "B: new current repo marked" "$(disp | grep tokenledger)" "← viewing"
pick alpha 'all repos'
eq    "B: back to all"            "$(fleet_current_repo alpha)" "all"
pick alpha ''
eq    "B: esc changes nothing"    "$(fleet_current_repo alpha)" "all"

# --- C. no switching -----------------------------------------------------------
pick alpha '' FLEET_PICK_ONLY='beta gamma'
eq    "C: FLEET_PICK_ONLY is ignored (same repo rows)" "$(keys | tr '\n' ' ')" "all o/claude-fleet o/tokenledger "
hasnt "C: no switch wording in the header" "$(cat "$WORK/fzf.args")" "switch"
for pat in 'detach-client' 'attach -t'; do
  CHECKS=$((CHECKS+1)); grep -qF -- "$pat" "$PICK" && fail "C: fleet-pick.sh still carries '$pat' (a fleet switch)"
done
CHECKS=$((CHECKS+1)); grep -q 'FLEET_PICK_ONLY\|fleet-list.sh' "$PICK" && fail "C: fleet-pick.sh still reads the fleet list / FLEET_PICK_ONLY"
CHECKS=$((CHECKS+1)); [ -e "$BIN/fleet-xfleet-jump.sh" ] && fail "C: fleet-xfleet-jump.sh must be gone (#980)"

# --- D. degenerate --------------------------------------------------------------
pick beta 'x'
has   "D: one-repo fleet → note, no picker" "$(cat "$WORK/pick.out")" "nothing to pick"
CHECKS=$((CHECKS+1)); [ -e "$WORK/fzf.in" ] && fail "D: a one-repo fleet must not open fzf"
: > "$WORK/tmux.log"
env TMUX=/fake,1,0 FAKE_CUR=alpha FZF_PICK='tokenledger' bash "$PICK" --repo-only >"$WORK/pick.out" 2>&1
eq    "D: --repo-only prints the picked repo" "$(cat "$WORK/pick.out")" "o/tokenledger"
hasnt "D: --repo-only offers no all"      "$(keys)" "all"
# fleet-list.sh shows the fleet and its repos: a ↳ row per further hosted repo
fl=$(bash "$BIN/fleet-list.sh")
has   "D: fleet-list lists alpha's second repo under it" "$(printf '%s\n' "$fl" | grep -A1 ' alpha ')" "↳"
has   "D: …with its checkout" "$(printf '%s\n' "$fl" | grep 'o/tokenledger')" "$WORK/tl"
eq    "D: one-repo fleets print one row each (no ↳)" "$(printf '%s\n' "$fl" | grep -c '↳')" "1"
tmux kill-session -t beta; tmux kill-session -t gamma

# --- E. the dash follows the current repo --------------------------------------
tmux new-window -d -t alpha -n 'cf·issue-1'
tmux set -w -t 'alpha:cf·issue-1' @repo o/claude-fleet; tmux set -w -t 'alpha:cf·issue-1' @issue 1
tmux new-window -d -t alpha -n 'tl·issue-2'
tmux set -w -t 'alpha:tl·issue-2' @repo o/tokenledger; tmux set -w -t 'alpha:tl·issue-2' @issue 2
tmux set -w -t 'alpha:tl·issue-2' @expand 1
tmux new-window -d -t alpha -n 'tl·kid'
tmux set -w -t 'alpha:tl·kid' @repo o/tokenledger; tmux set -w -t 'alpha:tl·kid' @issue 9
tmux set -w -t 'alpha:tl·kid' @origin o-tokenledger:issue-2
tmux new-window -d -t alpha -n norepo
tmux set -w -t alpha:norepo @norepo 1
rows() { FLEET_SESSION=alpha FZF_COLUMNS=120 bash "$ROWS" | tail -n +2 | awk -F '\037' '{ print $3 }' | sed "s/$(printf '\033')\[[0-9;]*m//g"; }
fleet_current_repo_set alpha all
r=$(rows)
eq    "E: all → claude-fleet row under its heading" "$(printf '%s\n' "$r" | grep -A1 '^claude-fleet (1)' | tail -n1 | grep -c 'cf·issue-1')" "1"
eq    "E: all → tokenledger row under its heading" "$(printf '%s\n' "$r" | grep -A1 '^tokenledger (2)' | tail -n1 | grep -c 'tl·issue-2')" "1"
eq    "E: all → no-repo row under its heading" "$(printf '%s\n' "$r" | grep -A1 '^no repo (1)' | tail -n1 | grep -c norepo)" "1"
hasnt "E: all → no per-row tag on the no-repo row" "$(printf '%s\n' "$r" | grep norepo | sed 's/.*norepo//')" "no repo"
eq    "E: all → no-repo group at the foot" "$(printf '%s\n' "$r" | tail -n1 | grep -c norepo)" "1"
has   "E: qualified origin folds as a child (└)" "$(printf '%s\n' "$r" | grep 'tl·kid')" "└"
has   "E: its parent carries the subtree badge" "$(printf '%s\n' "$r" | grep 'tl·issue-2')" "0/1 ✓"
fleet_current_repo_set alpha o/tokenledger
r=$(rows)
hasnt "E: tokenledger view hides claude-fleet" "$r" "cf·issue-1"
hasnt "E: …and the no-repo session" "$r" "norepo"
has   "E: …keeps its own rows" "$r" "tl·issue-2"
hasnt "E: no badge under a picked repo" "$(printf '%s\n' "$r" | grep 'tl·issue-2')" " tl "
# the fold toggle agrees: ← from the child shuts its repo-qualified parent's block
FLEET_SESSION=alpha bash "$FOLD" collapse 'alpha:tl·kid' '' >/dev/null 2>&1
eq    "E: fold toggle reaches the qualified parent" "$(tmux show -wv -t 'alpha:tl·issue-2' @expand 2>/dev/null)" ""
hasnt "E: collapsed child hidden" "$(rows)" "tl·kid"
fleet_current_repo_set alpha all
# degenerate: no overlay → a stale current-repo file changes nothing
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
r=$(rows)
has   "E: one-repo fleet shows every window" "$r" "cf·issue-1"
has   "E: …including no-repo" "$r" "norepo"
hasnt "E: …with no badge" "$(printf '%s\n' "$r" | grep norepo)" "no repo"
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

# --- F. label, status-left, short tags -----------------------------------------
fleet_current_repo_set alpha all
eq    "F: label under all"       "$(fleet_repo_label alpha)" "all"
fleet_current_repo_set alpha o/claude-fleet
eq    "F: label = repo name"     "$(fleet_repo_label alpha)" "claude-fleet"
eq    "F: one-repo fleet: no label" "$(fleet_repo_label beta)" ""
: > "$WORK/tmux.log"; fleet_repo_label_sync beta
has   "F: one-repo sync unsets"  "$(cat "$WORK/tmux.log")" "set-option -gu @fleet_repo_label"
has   "F: status-left shows <fleet> · <label>" "$(cat "$BIN/../conf/tmux-attention.conf")" '#S#{?@fleet_repo_label, · #{@fleet_repo_label},}'
eq    "F: short of claude-fleet" "$(fleet_repo_short o/claude-fleet)" "cf"
eq    "F: short of 24haowan-monorepo" "$(fleet_repo_short o/24haowan-monorepo)" "2m"
eq    "F: short of one word"     "$(fleet_repo_short o/tokenledger)" "to"
eq    "F: override wins"         "$(fleet_repo_short o/tokenledger tl)" "tl"
eq    "F: short_of reads the overlay" "$(fleet_repo_short_of alpha o/tokenledger)" "tl"
printf 'FLEET_REPO_SHORT="cf"\n' >> "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf"
eq    "F: colliding shorts fall back to names" "$(fleet_repo_shorts alpha | cut -f3 | tr '\n' ' ')" "claude-fleet tokenledger "

if [ "$FAILS" -gt 0 ]; then printf 'fleet-pick-repo-selftest: %d of %d checks FAILED\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'fleet-pick-repo-selftest: %d checks passed\n' "$CHECKS"
