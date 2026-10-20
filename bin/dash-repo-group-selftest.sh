#!/bin/bash
# dash-repo-group-selftest.sh — the dash groups its rows by repo under `all`
# (issue #974).
#
# In a fleet hosting 2+ repos with the current repo = `all`, the row producer
# (bin/tmux-dashboard-rows.sh — the hub list AND the sidebar) opens each repo's
# rows with one inert heading row, `<name> (<n>)` — the repo's bare name,
# owner/name only when two hosted repos share it (issue #995) — in
# fleet_repos order; a window whose repo is not hosted sorts after them under
# `?`, and the no-repo group stays last. Pinned here:
#   A. HEADINGS — present only under `all` in a 2+ repo fleet, in repo order, each
#      with its session count (a collapsed parent's hidden child still counts);
#      every row sits under its OWN repo's heading and carries NO per-row repo
#      tag (issue #995: the heading names it); two hosted repos sharing a bare
#      name fall back to owner/name for those two only.
#   B. ROWS — the same groups in the --rows frame, its headings bare
#      (`tokenledger (2)`, no `── `, like the hub list: issue #998).
#   C. INERT — every row script (reap, restore, pin, rename, migrate) is a no-op
#      on a heading row's `hdr` keys:
#      no window selected, set, renamed, killed or restored, and no status nag.
#   D. DEGENERATE — a one-repo fleet renders BYTE-IDENTICAL to a producer with the
#      grouping switched off (both frames, hub + sidebar); a stale current-repo
#      file (the retired picker's, #1034) changes neither frame.
#   E. IDLE + EMPTY (issue #998) — under `all` every HOSTED repo keeps its
#      heading at `(0)` (the `?`/`no repo` ones still hide at 0), the sidebar
#      heading carries its repo in the state field, and a frame with no session
#      row gets ONE inert `hdr` hint row: `No sessions — …` under `all` and in a
#      one-repo fleet, in both frames; a frame WITH sessions never draws it.
#   F. CROSS-REPO CHILD (issue #1031) — a child whose parent lives in ANOTHER
#      hosted repo follows its parent: under `all` it renders directly under the
#      parent, in the parent's group, with `└` and a short repo tag (`⇢tok`) in
#      both frames; the parent's heading counts it, its own repo's does not; the
#      parent's default fold hides it and the caret there unfolds it. A same-repo
#      child wears no tag; an orphan (parent gone) drops back into its own group
#      with no `└` and no tag; a one-repo fleet stays
#      byte-identical to grouping switched off with the cross-repo child present.
#   G. Pinned (issue #1170) — a pinned row leaves its repo group for `Pinned (n)` at
#      the top, closed by one rule, wearing its repo tag (the heading names no
#      repo); its repo heading no longer counts it; unpinning restores the frame
#      byte for byte.
# tmux runs on a PRIVATE socket via a PATH shim that logs every call; gh fails.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
st_real_tmux

st_tally count miss
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || st_miss "$1: expected [$3], got [$2]"; }

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
st_fake_gh "$WORK/bin"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
# Headings are localized since #1188 (bin/fleet-ui-lang.sh: FLEET_UI_LANG, else the
# login locale) — pin the English every heading below asserts.
export FLEET_UI_LANG=en
unset TMUX TMUX_PANE FLEET_SESSION FLEET_REPO FLEET_MAIN FLEET_SIDEBAR_CURRENT 2>/dev/null || true
mkdir -p "$TMPDIR" "$FLEET_CONF_DIR/fleets/alpha/repos"
. "$BIN/fleet-lib.sh"

fconf() { printf 'FLEET_REPO="%s"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH=master\n' "$2" "$WORK/$3" > "$1"; }
mkdir -p "$FLEET_CONF_DIR/fleets/alpha/repos"; : > "$FLEET_CONF_DIR/fleets/alpha/conf"   # every repo is an overlay (#1937, #4806)
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/o-claude-fleet.conf" o/claude-fleet cf; printf 'o-claude-fleet\n' > "$FLEET_CONF_DIR/fleets/alpha/repos/.order"
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/o-tokenledger.conf" o/tokenledger tl

"$REAL_TMUX" -S "$SOCK" new-session -d -s alpha -n plan -x 200 -y 40 || { echo "no isolated tmux" >&2; exit 1; }
# Interleaved on purpose: window order alone would mix the repos.
win() { tmux new-window -d -t alpha -n "$1"; shift; local w; w=$(tmux list-windows -t alpha -F '#{window_id}' | tail -n1)
        while [ "$#" -gt 1 ]; do tmux set -w -t "$w" "$1" "$2"; shift 2; done; }
win 'issue-2' @repo o/tokenledger @issue 2
win 'issue-1' @repo o/claude-fleet @issue 1
win norepo       @norepo 1
win 'kid'     @repo o/tokenledger @issue 9 @origin o-tokenledger:issue-2
win 'issue-3' @repo o/claude-fleet @issue 3
win 'issue-4' @repo o/elsewhere @issue 4              # a repo this fleet does not host

strip() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
rows()  { FLEET_SESSION=alpha FZF_COLUMNS=120 bash "${1:-$ROWS}" | tail -n +2 | awk -F '\037' '{ print $1 "|" $3 }' | strip; }
side()  { FLEET_SESSION=alpha bash "${1:-$ROWS}" --rows | tr '\037' '|'; }
# a rows() line → its heading text, or the window name (glyph/issue/tree cells dropped)
names() { awk -F'|' '{ l = $2; if ($1 == "hdr") { print l; next }
                       sub(/^ *[^ ]+ +(#[0-9]+ +)?. +/, "", l); sub(/ .*/, "", l); print l }'; }

# --- A. headings under `all` ----------------------------------------------------
r=$(rows)
eq    "A: the tl parent is collapsed by default (kid hidden)" "$(printf '%s\n' "$r" | grep -c 'kid')" "0"
eq    "A: groups in fleet_repos order, no-repo last" "$(printf '%s\n' "$r" | names | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 tokenledger (2) issue-2 ? · unknown repo (1) issue-4 no repo (1) norepo "
eq    "A: every heading is keyed hdr" "$(printf '%s\n' "$r" | grep -Ec '^hdr\|.* \([0-9]+\)$')" "4"
eq    "A: …and nothing else is"       "$(printf '%s\n' "$r" | grep -c '^hdr|')" "4"
# the row's flex span (right of the name) carries no repo tag any more
tagcell() { printf '%s\n' "$r" | grep -- "$1" | awk -F'|' '{ print $2 }' | sed "s/.*$1//"; }
st_hasnt "A: no per-row tag (cf)"          "$(tagcell 'issue-3')" " cf "
st_hasnt "A: …in any group (tl)"           "$(tagcell 'issue-2')" " to "
st_hasnt "A: …nor the unknown one's slug"  "$(tagcell 'issue-4')" "o-elsewhere"
st_hasnt "A: …nor a no-repo row's"         "$(tagcell 'norepo')" "no repo"
# every heading fits the sidebar's 30 columns now (the #995 metric)
eq    "A: no heading over 30 columns" "$(side | awk -F'|' '$1 == "hdr" && length($4) > 30' | wc -l | tr -d ' ')" "0"
st_has   "A: the column header still leads" "$(FLEET_SESSION=alpha bash "$ROWS" | head -n1 | strip)" "window"
# an expanded parent shows its child INSIDE its repo group, count unchanged
tmux set -w -t 'alpha:issue-2' @expand 1
eq    "A: expanded child sits under its repo's heading" "$(rows | names | sed -n '4,6p' | tr '\n' ' ')" \
      "tokenledger (2) issue-2 kid "
tmux set -wu -t 'alpha:issue-2' @expand
# a repo with no session on screen draws no heading
tmux kill-window -t 'alpha:issue-4'
st_hasnt "A: an empty group has no heading" "$(rows)" "unknown repo"

# --- G. the Pinned group in a 2+ repo fleet (issue #1170) ---------------------------
# Its OWN windows, so nothing the legs above left behind shapes it: pinme
# (tokenledger) owns an expanded same-repo child, pkid — both float.
tlhead() { printf '%s\n' "$1" | names | grep '^tokenledger (' ; }
g_start=$(rows); tl_before=$(tlhead "$g_start")
win pinme @repo o/tokenledger @issue 20 @expand 1
win pkid  @repo o/tokenledger @issue 21 @origin o-tokenledger:issue-20
before_raw=$(FLEET_SESSION=alpha bash "$ROWS"); before_side=$(side)
tmux set -w -t 'alpha:pinme' @pin 1
r=$(rows)
eq    "G: Pinned heads the list with its subtree, then one rule" \
      "$(printf '%s\n' "$r" | names | sed 's/^──*$/RULE/' | sed -n '1,4p' | tr '\n' ' ')" \
      "Pinned (2) pinme pkid RULE "
eq    "G: exactly one rule" "$(printf '%s\n' "$r" | names | grep -c '^──*$')" "1"
eq    "G: its repo heading no longer counts it" "$(tlhead "$r")" "$tl_before"
st_has   "G: …the pinned row wears its repo tag" "$(printf '%s\n' "$r" | grep 'pinme')" "⇢tok"
st_hasnt "G: …and no pin mark" "$r" "📌"
s=$(side)
eq    "G: sidebar — heading keyed hdr:pin, then the unmarked row" \
      "$(printf '%s\n' "$s" | sed -n '1,2p' | awk -F'|' '{ print $1 ":" $2 ":" $4 }' | tr '\n' '/')" \
      "hdr:pin:Pinned (2)/$(tmux display -p -t 'alpha:pinme' '#{window_id}')::pinme ⇢tok/"
tmux set -w -t 'alpha:pinme' -u @pin
eq    "G: unpinned — raw bytes identical to before" "$(FLEET_SESSION=alpha bash "$ROWS")" "$before_raw"
eq    "G: unpinned — sidebar identical to before"   "$(side)" "$before_side"
tmux kill-window -t 'alpha:pkid'; tmux kill-window -t 'alpha:pinme'   # the legs below never saw them
eq    "G: …and the frame is A's again" "$(rows)" "$g_start"

# --- A2. a bare-name collision falls back to owner/name — for those two only ---
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/p-tokenledger.conf" p/tokenledger tl2
win 'issue-5' @repo p/tokenledger @issue 5
eq    "A2: colliding repos read owner/name, the rest stay bare" \
      "$(rows | grep '^hdr|' | awk -F'|' '{ print $2 }' | tr '\n' ' ')" \
      "claude-fleet (2) o/tokenledger (2) p/tokenledger (1) no repo (1) "
eq    "A2: fleet_repo_name — collision" "$(fleet_repo_name alpha o/tokenledger)" "o/tokenledger"
eq    "A2: fleet_repo_name — bare"      "$(fleet_repo_name alpha o/claude-fleet)" "claude-fleet"
eq    "A2: fleet_repo_name — not hosted" "$(fleet_repo_name alpha o/elsewhere)" ""
tmux kill-window -t 'alpha:issue-5'
rm "$FLEET_CONF_DIR/fleets/alpha/repos/p-tokenledger.conf"
eq    "A2: …and back to bare once it goes" "$(fleet_repo_name alpha o/tokenledger)" "tokenledger"

# --- B. the sidebar frame -------------------------------------------------------
s=$(side)
eq    "B: sidebar groups the same way" "$(printf '%s\n' "$s" | awk -F'|' '{ print $4 }' | tr '\n' ' ')" \
      "claude-fleet (2) issue-1 issue-3 tokenledger (2) issue-2 no repo (1) 我的会话 "
eq    "B: sidebar headings carry five fields" "$(printf '%s\n' "$s" | grep '^hdr|' | awk -F'|' '{ print NF }' | sort -u)" "5"
# --- C. every row script is inert on a heading ---------------------------------
mut='select-window|set-window-option|set-option|set -w|rename-window|kill-|new-window|respawn|swap-|move-|join-pane|display-message [^-]|display-message -[^p]'
inert() {   # $1 = label, rest = the command → $out; asserts no tmux mutation, no nag
  : > "$WORK/tmux.log"
  out=$(FLEET_SESSION=alpha TMUX=/fake,1,0 "${@:2}" 2>&1 </dev/null)
  CHECKS=$((CHECKS+1))
  if grep -Eq "$mut" "$WORK/tmux.log"; then st_miss "C: $1 touched tmux on a heading" "$(cat "$WORK/tmux.log")"; fi
}
inert reap    bash "$BIN/dash-reap.sh" hdr;                st_has "C: ⌃x reap refuses quietly" "$out" "refused:no-target"
inert restore bash "$BIN/dash-restore-session.sh" hdr;     eq  "C: ⌃o restore restores nothing" "$out" ""
inert pin     bash "$BIN/dash-pin-toggle.sh" hdr;          eq  "C: pin" "$out" ""
inert rename  bash "$BIN/dash-rename.sh" hdr;              eq  "C: rename arms nothing" "$out" ""
# (the dash's enter / PR / fold / answer binds went with the dash, issue #4902;
# these are the row scripts ⌘P still runs)

# --- D. degenerate frames are byte-identical to grouping switched off -----------
mkdir -p "$WORK/nogrp"
for f in "$BIN"/*; do ln -s "$f" "$WORK/nogrp/${f##*/}"; done
# the colour table beside the copy's bin/, as beside the real one (issue #1534)
mkdir -p "$WORK/conf"; ln -sf "$BIN/../conf/fleet-palette.conf" "$WORK/conf/fleet-palette.conf"
rm "$WORK/nogrp/tmux-dashboard-rows.sh"
sed 's/^RGRP=\$RMANY$/RGRP=0/' "$ROWS" > "$WORK/nogrp/tmux-dashboard-rows.sh"
CHECKS=$((CHECKS+1))
cmp -s "$ROWS" "$WORK/nogrp/tmux-dashboard-rows.sh" && st_miss "D: could not switch the grouping off (RGRP=\$RMANY line moved?)"
OFF="$WORK/nogrp/tmux-dashboard-rows.sh"
CHECKS=$((CHECKS+1))
[ "$(rows)" != "$(rows "$OFF")" ] || st_miss "D: the switch is real — \`all\` differs with grouping off"
# a stale current-repo file (the retired picker's, #1034) filters nothing
all_rows=$(rows); all_side=$(side)
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
eq  "D: stale current-repo — hub list unchanged" "$(rows)" "$all_rows"
eq  "D: stale current-repo — sidebar unchanged"  "$(side)" "$all_side"
rm -f "$FLEET_CONF_DIR/fleets/alpha/current-repo"
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
eq  "D: one-repo fleet — hub list identical" "$(rows)" "$(rows "$OFF")"
eq  "D: one-repo fleet — sidebar identical"  "$(side)" "$(side "$OFF")"
st_hasnt "D: one-repo fleet — no heading"       "$(rows)" "──"
eq  "D: one-repo fleet — raw bytes identical" "$(FLEET_SESSION=alpha bash "$ROWS" | od -c)" "$(FLEET_SESSION=alpha bash "$OFF" | od -c)"
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

# --- E. idle repos keep a heading; an empty frame says how to start (#998) -----
for w in $(tmux list-windows -t alpha -F '#{window_name}' | grep -v '^plan$'); do tmux kill-window -t "alpha:$w"; done
win 'issue-1' @repo o/claude-fleet @issue 1
eq    "E: an idle hosted repo keeps its (0) heading" "$(rows | names | tr '\n' ' ')" \
      "claude-fleet (1) issue-1 tokenledger (0) "
st_hasnt "E: no hint while a session is on screen" "$(rows)" "No sessions"
eq    "E: sidebar headings carry their repo" \
      "$(side | awk -F'|' '$1 == "hdr" { print $2 "=" $4 }' | tr '\n' ' ')" \
      "o/claude-fleet=claude-fleet (1) o/tokenledger=tokenledger (0) "
tmux kill-window -t 'alpha:issue-1'
r=$(rows)
eq    "E: all, no sessions — the hint, then every hosted heading at 0" "$(printf '%s\n' "$r" | tr '\n' '/')" \
      "hdr|  No sessions — start one from ⌘P/hdr|claude-fleet (0)/hdr|tokenledger (0)/"
st_has   "E: …under the column header" "$(FLEET_SESSION=alpha bash "$ROWS" | head -n1 | strip)" "window"
s=$(side)
eq    "E: sidebar, no sessions" "$(printf '%s\n' "$s" | awk -F'|' '{ print $1 ":" $4 }' | tr '\n' '/')" \
      "hdr:No sessions — ⌘N new session/hdr:claude-fleet (0)/hdr:tokenledger (0)/"
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
eq    "E: a stale current-repo file keeps every heading (#1034)" "$(rows)" "$r"
rm -f "$FLEET_CONF_DIR/fleets/alpha/current-repo"
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
eq    "E: one-repo fleet, no sessions — the bare hint" "$(rows)" \
      "hdr|  No sessions — start one from ⌘P"
eq    "E: …and in the sidebar" "$(side)" "hdr|||No sessions — ⌘N new session| "
win 'issue-1' @repo o/claude-fleet @issue 1
st_hasnt "E: one-repo fleet with a session — no hint" "$(rows)" "No sessions"
st_hasnt "E: …no heading"                             "$(rows)" "──"
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

# --- F. a cross-repo child follows its parent (#1031) --------------------------
for w in $(tmux list-windows -t alpha -F '#{window_name}' | grep -v '^plan$'); do tmux kill-window -t "alpha:$w"; done
win 'issue-1' @repo o/claude-fleet @issue 1
win 'issue-2' @repo o/tokenledger  @issue 2
win 'xkid'    @repo o/tokenledger  @issue 9 @origin o-claude-fleet:issue-1
win 'skid'    @repo o/tokenledger  @issue 8 @origin o-tokenledger:issue-2
r=$(rows)
eq    "F: collapsed — the child is hidden, counted under its PARENT's heading" \
      "$(printf '%s\n' "$r" | names | tr '\n' ' ')" "claude-fleet (2) issue-1 tokenledger (2) issue-2 "
st_has   "F: …and the caret that unfolds it sits on the parent" "$(printf '%s\n' "$r" | grep 'issue-1')" "▸  issue-1"
tmux set -w -t 'alpha:issue-1' @expand 1
tmux set -w -t 'alpha:issue-2' @expand 1
r=$(rows)
eq    "F: expanded — the child renders directly under its parent, in its group" \
      "$(printf '%s\n' "$r" | names | tr '\n' ' ')" "claude-fleet (2) issue-1 xkid tokenledger (2) issue-2 skid "
st_has   "F: …drawn as a child"                "$(printf '%s\n' "$r" | grep 'xkid')" "└  xkid"
st_has   "F: …with its repo tag"               "$(printf '%s\n' "$r" | grep 'xkid')" " ⇢tok"
st_hasnt "F: a same-repo child wears no tag"   "$(printf '%s\n' "$r" | grep 'skid')" "⇢"
st_hasnt "F: …nor does any root"               "$(printf '%s\n' "$r" | grep -E 'issue-[12]')" "⇢"
s=$(side)
eq    "F: sidebar — the same placement" "$(printf '%s\n' "$s" | awk -F'|' '{ print $4 }' | tr '\n' '/')" \
      "claude-fleet (2)/issue-1/xkid ⇢tok/tokenledger (2)/issue-2/skid/"
eq    "F: sidebar — the child's tree cell" "$(printf '%s\n' "$s" | awk -F'|' '$4 ~ /^xkid/ { print $5 }')" "└"
tmux kill-window -t 'alpha:issue-1'
r=$(rows)
eq    "F: orphaned — back in its own group" "$(printf '%s\n' "$r" | names | tr '\n' ' ')" \
      "claude-fleet (0) tokenledger (3) issue-2 skid xkid "
st_hasnt "F: …no └"                            "$(printf '%s\n' "$r" | grep 'xkid')" "└"
st_hasnt "F: …no repo tag"                     "$(printf '%s\n' "$r" | grep 'xkid')" "⇢"
st_hasnt "F: …and no ↳ parent tag (issue #1328)"   "$(printf '%s\n' "$r" | grep 'xkid')" "↳"
win 'issue-1' @repo o/claude-fleet @issue 1 @expand 1
all_rows=$(rows)
printf 'o/tokenledger\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"   # the retired picker's (#1034)
eq    "F: a stale current-repo file changes no row" "$(rows)" "$all_rows"
rm -f "$FLEET_CONF_DIR/fleets/alpha/current-repo"
mv "$FLEET_CONF_DIR/fleets/alpha/repos" "$WORK/repos.off"
eq    "F: one-repo fleet — raw bytes identical" "$(FLEET_SESSION=alpha bash "$ROWS" | od -c)" "$(FLEET_SESSION=alpha bash "$OFF" | od -c)"
eq    "F: one-repo fleet — sidebar identical"   "$(side)" "$(side "$OFF")"
mv "$WORK/repos.off" "$FLEET_CONF_DIR/fleets/alpha/repos"

st_done
