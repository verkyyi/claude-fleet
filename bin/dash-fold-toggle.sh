#!/bin/bash
# dash-fold-toggle.sh <expand|collapse> <target> [query] — the dash's ←/→ fold.
#
# The dash groups a spawned session under the window that spawned it (#503) and
# reports the subtree's progress on the parent row (#624). Past a couple of
# parents that nesting is most of the list, and the operator reads the PARENTS —
# so a parent's subtree is now COLLAPSED BY DEFAULT and `→` / `←` open and shut
# it. The parent's `3/5 ✓ · 1!` badge is what a collapsed block says out loud,
# and a child in `needs` stays on the list regardless (the fold is the quiet
# layer; the red one never folds) — see the filter in tmux-dashboard-rows.sh.
#
# This is an fzf `transform` helper: it prints fzf ACTIONS on stdout, the same
# shape bin/dash-rename.sh and bin/dash-agent-prompt.sh use. Printing nothing is
# a no-op keystroke, which is what every "nothing to fold here" branch does.
#
# ARROWS ARE SHARED WITH THE PROMPT LINE. The dash's input row is always visible
# (#493) — it is the quick-scratch box — and fzf binds ←/→ to backward-char /
# forward-char for editing what you type there. So the FIRST thing this does is
# look at the query: non-empty ⇒ hand the key straight back as the cursor move it
# has always been, and only an EMPTY line folds. Exactly the transform the `?`
# bind already uses for its own printable-key clash (tmux-dashboard.sh).
#
# State lives on the WINDOW (`@expand`), for #623's reasons verbatim: it dies with
# the window (no file, marker or ledger row to clean up), it cannot be inherited by
# a recycled window INDEX because this addresses one by window_id, and it is
# per-fleet for free (one tmux server per fleet, #159). The polarity is inverted
# against @pin on purpose — ABSENT means collapsed, `1` means expanded — because
# the default is collapsed, so a window nobody has touched, and every freshly
# spawned parent, starts folded with no writer involved.
#
# WHO OWNS THE FOLD: the ULTIMATE LIVE ROOT of the chain, never a middle node.
# The dash's grouping is two-level-flat — a grandchild renders under, and counts
# toward, the same root as its parent — so a middle node's own bit would govern
# nothing and toggling it would look broken. Walking to the root here is what keeps
# `←` on ANY row in a block shut the block it is actually in.
#
# Target: what the dash row hands over ({1} = `sess:idx`), or the fleet's short
# window handle (`a1`, #566) — normalised through fleet_wid_target like every other
# target-taking script, so `dash-fold-toggle.sh collapse b3` works from a shell.
# The header row, an empty target and a landed-view row are silent no-ops.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
US=$'\x1f'

verb="${1:-}"; target="${2:-}"; query="${3:-}"

# Typing wins: ←/→ stay the query line's cursor keys the moment there is a query.
if [ -n "$query" ]; then
  case "$verb" in expand) echo 'forward-char' ;; collapse) echo 'backward-char' ;; esac
  exit 0
fi

case "$verb" in expand|collapse) ;; *) exit 0 ;; esac
case "$target" in ''|hdr|none) exit 0 ;; esac
# landed rows have no tmux window to hang @expand on — fleet-history.sh owns that
# view's fold, keyed by ledger key in a per-fleet file.
case "$target" in landed:*) exec bash "$BIN/fleet-history.sh" fold "$verb" "$target" ;; esac

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
command -v fleet_wid_target >/dev/null 2>&1 && target="$(fleet_wid_target "$target")"

# Strict per-fleet, the renderer's own rule: FLEET_SESSION is exported by
# tmux-dashboard.sh, so a transform child already has it; a shell invocation falls
# back to the current session, and outside tmux to none (⇒ every window, the
# single-fleet back-compat case).
SESS="${FLEET_SESSION:-}"
[ -n "$SESS" ] || SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null) || SESS=''

# --- the window table: key → window_id · origin · expand ----------------------
# ONE tmux read, same field set and same key derivation the renderer uses, so the
# two can never disagree about who a row's parent is.
WFMT="#{session_name}${US}#{window_id}${US}#{window_name}${US}#{pane_current_path}${US}#{@issue}${US}#{@origin}${US}#{@worktree}${US}#{@expand}${US}#{@repo}"
WLIST=$(tmux list-windows -a -F "$WFMT" 2>/dev/null) || exit 0
# tmux ≤3.4 escapes the control separator as the literal four bytes `\037` (the
# renderer normalizes the same way); without this every field lands in $wsess.
WLIST=${WLIST//\\037/$US}

# okey_v — byte-for-byte the renderer's key derivation (@issue, else the
# `scratch-<N>` slug from @worktree first and the pane cwd only as a fallback,
# issue #529). Kept identical on purpose; a divergence here would fold the
# wrong block.
okey_v() { okey=''
  if [ -n "$1" ]; then okey="${okp}issue-$1"; return; fi
  local cand bn sn
  for cand in "$2" "$3"; do
    bn=${cand##*/}
    case "$bn" in
      scratch-*)   sn=${bn#scratch-} ;;
      *-scratch-*) sn=${bn##*-scratch-} ;;
      *)           continue ;;
    esac
    case "$sn" in ''|*[!0-9]*) continue;; *) okey="${okp}scratch-$sn"; return;; esac
  done
}
# okp_v — the renderer's repo key prefix (issue #790), byte-for-byte: `<slug>:` of
# @repo in a fleet hosting 2+ repos, `?:` when @repo is unset (unknown/@norepo;
# pr-refresh stamps a derivable one within a tick), else nothing.
okp=''
MULTI=0
[ -n "$SESS" ] && command -v fleet_multirepo >/dev/null 2>&1 && fleet_multirepo "$SESS" && MULTI=1
okp_v() { okp=''
  [ "$MULTI" = 1 ] || return 0
  local r="$1"
  if [ -n "$r" ]; then r=${r//\//-}; okp="${r//[^[:alnum:]._-]/}:"; else okp='?:'; fi
}

# self's window_id, so the table lookup below is by identity, not by index.
selfwid=$(tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null) || exit 0
[ -n "$selfwid" ] || exit 0

KEYTAB=''      # key \t window_id \t origin \t expand
selfkey=''
while IFS=$US read -r wsess wid wname wpath wiss worig wwt wexp wrepo; do
  [ -n "$wname" ] || continue
  [ -n "$SESS" ] && [ "$wsess" != "$SESS" ] && continue
  case "$wname" in dash|plan|backlog) continue ;; esac
  okp_v "$wrepo"
  okey_v "$wiss" "$wwt" "$wpath"
  [ -n "$okey" ] || continue
  KEYTAB+="$okey"$'\t'"$wid"$'\t'"$worig"$'\t'"$wexp"$'\n'
  [ "$wid" = "$selfwid" ] && selfkey=$okey
done <<< "$WLIST"
[ -n "$selfkey" ] || exit 0

# look a key up in KEYTAB → $lwid / $lorig / $lexp; 1 when it is not on this dash.
lookup() {
  local t m row
  t=$'\n'"$KEYTAB"; m=${t#*$'\n'"$1"$'\t'}
  [ "$m" = "$t" ] && return 1
  row=${m%%$'\n'*}
  lwid=${row%%$'\t'*}; row=${row#*$'\t'}
  lorig=${row%%$'\t'*}; lexp=${row#*$'\t'}
  return 0
}

# --- the holder: walk to the ultimate live root (≤4 hops, the renderer's bound) -
holder=$selfkey
lookup "$selfkey" || exit 0
hwid=$lwid; hexp=$lexp; horig=$lorig
hops=0
while [ "$hops" -lt 4 ]; do
  case "$horig" in issue-*|scratch-*|*:issue-*|*:scratch-*) ;; *) break ;; esac
  lookup "$horig" || { holder=''; break; }        # chain left this dash ⇒ ORPHAN
  holder=$horig; hwid=$lwid; hexp=$lexp; horig=$lorig
  hops=$((hops+1))
done
# An orphan renders top-level with no parent above it — there is no block to fold.
[ -n "$holder" ] || exit 0

# Does the holder actually have a subtree? A direct live child is enough: a
# grandchild can only exist while its own parent window does, so "has children"
# and "has a direct child" coincide on the live list.
haskids=0
while IFS=$'\t' read -r _ _ korig _; do
  [ "$korig" = "$holder" ] && { haskids=1; break; }
done <<< "$KEYTAB"
[ "$haskids" = 1 ] || exit 0

ROWS="$BIN/tmux-dashboard-rows.sh"
case "$hexp" in 1) hexp=1 ;; *) hexp=0 ;; esac

if [ "$verb" = expand ]; then
  # `→` opens the block the cursor's row OWNS. On a child it is a no-op by
  # design: that row is only on screen because its holder is already open, and
  # jumping the fold somewhere else under the cursor would be a surprise.
  [ "$holder" = "$selfkey" ] || exit 0
  [ "$hexp" = 1 ] && exit 0
  tmux set-option -w -t "$hwid" @expand 1 2>/dev/null || exit 0
  echo "reload(bash $ROWS)"
  exit 0
fi

# `←` shuts the block the cursor is IN — from the parent row or from any row
# inside it, which is the gesture that actually gets used.
[ "$hexp" = 1 ] || exit 0
# -u rather than parking a 0: an unset @expand is the ordinary collapsed state
# (a window that was never expanded has none), so shutting a block must leave the
# window byte-identical to one that was never opened.
tmux set-option -w -t "$hwid" -u @expand 2>/dev/null || exit 0

if [ "$holder" = "$selfkey" ]; then
  echo "reload(bash $ROWS)"
  exit 0
fi
# Collapsed from INSIDE the block: the cursor's row just vanished, so put the
# cursor on the parent that swallowed it. That needs the parent's new INDEX, which
# only the producer knows — field1 of each row is its `sess:idx` target, and the
# index is its line number minus the one header line fzf consumes via
# --header-lines=1.
#
# ONE render, not two. The obvious shape — compute the index from a render here,
# then hand fzf `reload(bash <producer>)` — makes this the only keystroke on the
# dash that renders the list TWICE, and a render is the expensive thing here (the
# whole of issue #662). So the render is KEPT: it goes to a per-fleet snapshot and
# fzf is pointed at THAT. A second benefit falls out — the list fzf draws is
# byte-identical to the one the index was computed against, so the two cannot
# disagree about where the parent is, however busy the fleet is at that instant.
# The 1Hz tick repaints from the live producer a moment later, so the snapshot is
# never what is on screen for long. (Measured on a live fleet: the reload drops
# from 97ms to 6ms.)
# Written temp+mv so fzf can never cat a half-written file, and under ONE fixed
# name per fleet, so it is overwritten rather than accumulated — nothing to clean
# up. Any failure falls back to the plain reload: a keystroke that costs an extra
# render is fine, a blank list is not.
htgt=$(tmux display-message -p -t "$hwid" '#{session_name}:#{window_index}' 2>/dev/null) || htgt=''
SNAP="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/global/dash_fold_rows_${FLEET_SESSION:-default}"
pos=''
if [ -n "$htgt" ]; then
  mkdir -p "${SNAP%/*}" 2>/dev/null || true
  if bash "$ROWS" > "$SNAP.$$" 2>/dev/null && [ -s "$SNAP.$$" ]; then
    mv -f "$SNAP.$$" "$SNAP"
    # -F"$US", never -F'\x1f': `\x` in a field separator is a GAWK extension and BSD
    # awk (macOS) takes it literally, so the split never happens and every lookup
    # comes back empty — a silently pos()-less fold on exactly the operator's machine.
    pos=$(awk -F"$US" -v t="$htgt" 'NR>1 && $1==t {print NR-1; exit}' "$SNAP" 2>/dev/null)
  else
    rm -f "$SNAP.$$"
  fi
fi
# An fzf action's argument ends at the matching `)`, and its command is split on
# whitespace — so a snapshot path holding a paren or a space would truncate the
# action or turn `cat` into a two-file read. Neither happens under a normal TMPDIR,
# and if it ever does the plain reload is the right answer, not a mangled list.
case "$SNAP" in *' '*|*'('*|*')'*) pos='' ;; esac
case "$pos" in
  ''|*[!0-9]*) echo "reload(bash $ROWS)" ;;
  *)           echo "reload-sync(cat $SNAP)+pos($pos)" ;;
esac
exit 0
