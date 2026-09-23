#!/bin/bash
# dash-repo-group-selftest.sh — the dash groups its rows by repo under `all`
# (issue #974).
#
# In a fleet hosting 2+ repos with the current repo = `all`, the row producer
# (bin/tmux-dashboard-rows.sh — the hub list AND the sidebar) opens each repo's
# rows with one inert heading row, `── <name> (<n>)` — the repo's bare name,
# owner/name only when two hosted repos share it (issue #995) — in
# fleet_repos order; a window whose repo is not hosted sorts after them under
# `?`, and the no-repo group stays last. Pinned here:
#   A. HEADINGS — present only under `all` in a 2+ repo fleet, in repo order, each
#      with its session count (a collapsed parent's hidden child still counts);
#      every row sits under its OWN repo's heading and carries NO per-row repo
#      tag (issue #995: the heading names it); two hosted repos sharing a bare
#      name fall back to owner/name for those two only.
#   B. SIDEBAR — the same groups in the --sidebar frame, and fleet-sidebar.py's
#      selectable() never lets the cursor rest on a heading.
#   C. INERT — every dash bind target (enter, ⌃x reap, ⌃p PR, ⌃o restore, fold
#      ←/→, pin, rename, answer, migrate) is a no-op on a heading row's `hdr` keys:
#      no window selected, set, renamed, killed or restored, and no status nag.
#   D. DEGENERATE — a one-repo fleet and a picked repo render BYTE-IDENTICAL to a
#      producer with the grouping switched off (both frames, hub + sidebar).
# tmux runs on a PRIVATE socket via a PATH shim that logs every call; gh fails.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

CHECKS=0 FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; FAILS=$((FAILS+1)); }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-repo-group.XXXXXX")" || exit 2
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
# Interleaved on purpose: window order alone would mix the repos.
win() { tmux new-window -d -t alpha -n "$1"; shift; local w; w=$(tmux list-windows -t alpha -F '#{window_id}' | tail -n1)
        while [ "$#" -gt 1 ]; do tmux set -w -t "$w" "$1" "$2"; shift 2; done; }
win 'tl·issue-2' @repo o/tokenledger @issue 2
win 'cf·issue-1' @repo o/claude-fleet @issue 1
win norepo       @norepo 1
win 'tl·kid'     @repo o/tokenledger @issue 9 @origin o-tokenledger:issue-2
win 'cf·issue-3' @repo o/claude-fleet @issue 3
win 'xx·issue-4' @repo o/elsewhere @issue 4              # a repo this fleet does not host

strip() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
rows()  { FLEET_SESSION=alpha FZF_COLUMNS=120 bash "${1:-$ROWS}" | tail -n +2 | awk -F '\037' '{ print $1 "|" $3 }' | strip; }
side()  { FLEET_SESSION=alpha bash "${1:-$ROWS}" --sidebar | tr '\037' '|'; }
# a rows() line → its heading text, or the window name (glyph/issue/tree cells dropped)
names() { awk -F'|' '{ l = $2; if (l ~ /^── /) { print l; next }
                       sub(/^ *[^ ]+ +(#[0-9]+ +)?. +/, "", l); sub(/ .*/, "", l); print l }'; }

# --- A. headings under `all` ----------------------------------------------------
fleet_current_repo_set alpha all
r=$(rows)
eq    "A: the tl parent is collapsed by default (kid hidden)" "$(printf '%s\n' "$r" | grep -c 'tl·kid')" "0"
eq    "A: groups in fleet_repos order, no-repo last" "$(printf '%s\n' "$r" | names | tr '\n' ' ')" \
      "── claude-fleet (2) cf·issue-1 cf·issue-3 ── tokenledger (2) tl·issue-2 ── ? · unknown repo (1) xx·issue-4 ── no repo (1) norepo "
eq    "A: every heading is keyed hdr" "$(printf '%s\n' "$r" | grep -c '^hdr|── ')" "4"
eq    "A: …and nothing else is"       "$(printf '%s\n' "$r" | grep -c '^hdr|')" "4"
# the row's flex span (right of the name) carries no repo tag any more
tagcell() { printf '%s\n' "$r" | grep -- "$1" | awk -F'|' '{ print $2 }' | sed "s/.*$1//"; }
hasnt "A: no per-row tag (cf)"          "$(tagcell 'cf·issue-3')" " cf "
hasnt "A: …in any group (tl)"           "$(tagcell 'tl·issue-2')" " to "
hasnt "A: …nor the unknown one's slug"  "$(tagcell 'xx·issue-4')" "o-elsewhere"
hasnt "A: …nor a no-repo row's"         "$(tagcell 'norepo')" "no repo"
# every heading fits the sidebar's 30 columns now (the #995 metric)
eq    "A: no heading over 30 columns" "$(side | awk -F'|' '$1 == "hdr" && length($4) > 30' | wc -l | tr -d ' ')" "0"
has   "A: the column header still leads" "$(FLEET_SESSION=alpha bash "$ROWS" | head -n1 | strip)" "window"
# an expanded parent shows its child INSIDE its repo group, count unchanged
tmux set -w -t 'alpha:tl·issue-2' @expand 1
eq    "A: expanded child sits under its repo's heading" "$(rows | names | sed -n '4,6p' | tr '\n' ' ')" \
      "── tokenledger (2) tl·issue-2 tl·kid "
tmux set -wu -t 'alpha:tl·issue-2' @expand
# a repo with no session on screen draws no heading
tmux kill-window -t 'alpha:xx·issue-4'
hasnt "A: an empty group has no heading" "$(rows)" "unknown repo"

# --- A2. a bare-name collision falls back to owner/name — for those two only ---
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/p-tokenledger.conf" p/tokenledger tl2
win 'p·issue-5' @repo p/tokenledger @issue 5
eq    "A2: colliding repos read owner/name, the rest stay bare" \
      "$(rows | grep '^hdr|' | awk -F'|' '{ print $2 }' | tr '\n' ' ')" \
      "── claude-fleet (2) ── o/tokenledger (2) ── p/tokenledger (1) ── no repo (1) "
eq    "A2: fleet_repo_name — collision" "$(fleet_repo_name alpha o/tokenledger)" "o/tokenledger"
eq    "A2: fleet_repo_name — bare"      "$(fleet_repo_name alpha o/claude-fleet)" "claude-fleet"
eq    "A2: fleet_repo_name — not hosted" "$(fleet_repo_name alpha o/elsewhere)" ""
tmux kill-window -t 'alpha:p·issue-5'
rm "$FLEET_CONF_DIR/fleets/alpha/repos/p-tokenledger.conf"
eq    "A2: …and back to bare once it goes" "$(fleet_repo_name alpha o/tokenledger)" "tokenledger"

# --- B. the sidebar frame -------------------------------------------------------
s=$(side)
eq    "B: sidebar groups the same way" "$(printf '%s\n' "$s" | awk -F'|' '{ print $4 }' | tr '\n' ' ')" \
      "── claude-fleet (2) cf·issue-1 cf·issue-3 ── tokenledger (2) tl·issue-2 · 0/1 ✓ ── no repo (1) norepo "
eq    "B: sidebar headings carry five fields" "$(printf '%s\n' "$s" | grep '^hdr|' | awk -F'|' '{ print NF }' | sort -u)" "5"
sel=$(printf '%s\n' "$s" | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows = [l.split("|", 4) for l in sys.stdin.read().split("\n") if len(l.split("|", 4)) == 5]
print(len(rows), len(m.selectable(rows)), "hdr" in m.selectable(rows))' "$BIN/fleet-sidebar.py")
eq    "B: selectable() skips every heading" "$sel" "7 4 False"

# --- C. every bind target is inert on a heading ---------------------------------
mut='select-window|set-window-option|set-option|set -w|rename-window|kill-|new-window|respawn|swap-|move-|join-pane|display-message [^-]|display-message -[^p]'
inert() {   # $1 = label, rest = the command → $out; asserts no tmux mutation, no nag
  : > "$WORK/tmux.log"
  out=$(FLEET_SESSION=alpha TMUX=/fake,1,0 "${@:2}" 2>&1 </dev/null)
  CHECKS=$((CHECKS+1))
  if grep -Eq "$mut" "$WORK/tmux.log"; then fail "C: $1 touched tmux on a heading" "$(cat "$WORK/tmux.log")"; fi
}
inert enter   bash "$BIN/dash-enter.sh" hdr '';            eq  "C: enter only clears the query" "$out" "clear-query"
inert reap    bash "$BIN/dash-reap.sh" hdr;                has "C: ⌃x reap refuses quietly" "$out" "refused:no-target"
inert pr      bash "$BIN/dash-open-pr.sh" hdr;             eq  "C: ⌃p PR opens nothing" "$out" ""
inert restore bash "$BIN/dash-restore-session.sh" hdr;     eq  "C: ⌃o restore restores nothing" "$out" ""
inert fold-l  bash "$BIN/dash-fold-toggle.sh" collapse hdr ''; eq "C: ← fold" "$out" ""
inert fold-r  bash "$BIN/dash-fold-toggle.sh" expand hdr '';   eq "C: → fold" "$out" ""
inert pin     bash "$BIN/dash-pin-toggle.sh" hdr;          eq  "C: pin" "$out" ""
inert rename  bash "$BIN/dash-rename.sh" hdr;              eq  "C: rename arms nothing" "$out" ""
inert answer  bash "$BIN/dash-answer.sh" hdr;              eq  "C: answer" "$out" ""
inert migrate bash "$BIN/dash-migrate.sh" hdr;             eq  "C: migrate" "$out" ""
# every --bind in the dash that hands a row field to a script is covered above
binds=$(grep -oE 'dash-[a-z-]+\.sh( (collapse|expand))? \{[12]\}' "$BIN/tmux-dashboard.sh" | sed -E 's/ \{[12]\}//; s/ (collapse|expand)//' | sort -u | tr '\n' ' ')
eq  "C: the bind targets under test are the dash's" "$binds" \
    "dash-answer.sh dash-enter.sh dash-fold-toggle.sh dash-migrate.sh dash-open-pr.sh dash-pin-toggle.sh dash-reap.sh dash-rename.sh dash-restore-session.sh "

# --- D. degenerate frames are byte-identical to grouping switched off -----------
mkdir -p "$WORK/nogrp"
for f in "$BIN"/*; do ln -s "$f" "$WORK/nogrp/${f##*/}"; done
rm "$WORK/nogrp/tmux-dashboard-rows.sh"
sed 's/&& RGRP=1$/\&\& :/' "$ROWS" > "$WORK/nogrp/tmux-dashboard-rows.sh"
CHECKS=$((CHECKS+1))
cmp -s "$ROWS" "$WORK/nogrp/tmux-dashboard-rows.sh" && fail "D: could not switch the grouping off (RGRP=1 line moved?)"
OFF="$WORK/nogrp/tmux-dashboard-rows.sh"
CHECKS=$((CHECKS+1))
[ "$(rows)" != "$(rows "$OFF")" ] || fail "D: the switch is real — \`all\` differs with grouping off"
fleet_current_repo_set alpha o/tokenledger
eq  "D: picked repo — hub list identical"  "$(rows)" "$(rows "$OFF")"
eq  "D: picked repo — sidebar identical"   "$(side)" "$(side "$OFF")"
hasnt "D: picked repo — no heading"        "$(rows)" "──"
fleet_current_repo_set alpha all
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
eq  "D: one-repo fleet — hub list identical" "$(rows)" "$(rows "$OFF")"
eq  "D: one-repo fleet — sidebar identical"  "$(side)" "$(side "$OFF")"
hasnt "D: one-repo fleet — no heading"       "$(rows)" "──"
eq  "D: one-repo fleet — raw bytes identical" "$(FLEET_SESSION=alpha bash "$ROWS" | od -c)" "$(FLEET_SESSION=alpha bash "$OFF" | od -c)"
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

if [ "$FAILS" -gt 0 ]; then printf 'dash-repo-group-selftest: %d of %d checks FAILED\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'dash-repo-group-selftest: %d checks passed\n' "$CHECKS"
