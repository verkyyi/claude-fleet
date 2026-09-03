#!/bin/bash
# dash-enter.sh <target sess:idx> <query> — Enter handler for the dash.
# Emits fzf actions on stdout (called from an fzf `transform` binding) and does
# the tmux side-effect. Modes:
#   bind mode    (bind flag, set by ctrl-g): bind/unbind <target> to issue query
#   rename mode  (rename flag, set by ctrl-e): rename <stored target> to query
#   typed task   (no flag, query non-empty): spawn a scratch session SEEDED with
#                the query (dash-raw-session.sh --prompt) — the dash's always-
#                visible prompt line is the quick-scratch box
#   jump         (default, empty query): select the target window
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"; flag="$C/rename_target"; bindflag="$C/bind_target"
target="${1:-}"; q="${2:-}"
PROMPT='▸ '
# `rebind(?)` pairs with the `unbind(?)` dash-rename.sh emits when it arms: `?` is
# the dash's cheatsheet bind, and a bound printable key keeps firing its action
# instead of typing (fzf 0.74.3), so it is unbound for the length of the edit and
# restored here. Rebinding a key that was never unbound (a stale flag inherited by
# a freshly relaunched dash) is a harmless no-op. (The input line itself is always
# visible now — there is no show/hide to undo, only the prompt label.)
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"    # fleet_bg / fleet_now_ms / fleet_spawn_is_burst (#531)

# Typed task → seeded scratch. Checked FIRST, before any view logic: the prompt line
# means the same thing in the live and the landed view, and it is mode-free — a
# rename/bind in progress owns the query line instead (those branches below).
#
# Paste-storm guard (issue #531): a terminal delivers a MULTI-LINE PASTE into this
# fzf input as one Enter PER LINE, and fzf has no bracketed-paste awareness on the
# input line — so pasting a ~250-line stack trace once fired 250 seeded spawns (244
# concurrent `git worktree add`s, the global cap bypassed, disk 30→6 GB). So the
# spawn is DEBOUNCED, timestamp-based: an Enter that trails the previous one by
# < FLEET_SPAWN_GUARD_MS is a burst line and is DROPPED; an Enter with quiet before
# it DEFERS FLEET_SPAWN_GUARD_SLEEP and then spawns IFF nothing followed within the
# guard (it was isolated). Net: a lone task spawns after a ~1s wait, a paste spawns
# nothing (one explanatory message), and two tasks typed > guard apart both spawn.
# Timestamp-based, not a counter — a counter drops the EARLIER of two spaced tasks
# (a later Enter exists ⇒ "not newest" ⇒ wrongly dropped). The query is only ever
# handed over via a FILE (--prompt-file), never interpolated into a command string.
if [ ! -f "$flag" ] && [ ! -f "$bindflag" ] && [ -n "${q//[[:space:]]/}" ]; then
  GUARD_MS="${FLEET_SPAWN_GUARD_MS:-1000}"
  case "$GUARD_MS" in ''|*[!0-9]*) GUARD_MS=1000;; esac
  # The defer is the guard, expressed in seconds — derived, so operators tune ONE
  # knob. FLEET_SPAWN_GUARD_SLEEP is an undocumented override the selftest uses to
  # keep a wide gap-window while sleeping only a fraction of a second.
  GUARD_SLEEP="${FLEET_SPAWN_GUARD_SLEEP:-$(printf '%d.%03d' $((GUARD_MS/1000)) $((GUARD_MS%1000)))}"
  gdir="$C/global"; mkdir -p "$gdir" 2>/dev/null
  key=$(fleet_slug "${FLEET_SESSION:-default}")
  lastf="$gdir/spawn_last_ms_$key"
  now=$(fleet_now_ms)
  last=$(cat "$lastf" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0;; esac
  printf '%s' "$now" > "$lastf" 2>/dev/null
  if fleet_spawn_is_burst "$now" "$last" "$GUARD_MS"; then
    :   # trailing line of a paste — drop; the candidate's deferred decider reports it
  else
    # A candidate: quiet before it. Stage the query in a file (never interpolated),
    # then defer the decision. On wake, spawn IFF `lastf` is still ≤ our timestamp
    # (nothing followed us within the guard — we were isolated, a real lone task);
    # else a burst formed around us → drop it and surface ONE message. Backgrounded
    # via fleet_bg so the keystroke returns now; $now is digits-only (safe to embed).
    qf=$(mktemp "$gdir/spawn_q.XXXXXX" 2>/dev/null)
    if [ -n "$qf" ]; then
      printf '%s' "$q" > "$qf" 2>/dev/null
      fleet_bg "sleep $GUARD_SLEEP; _l=\$(cat '$lastf' 2>/dev/null); case \"\$_l\" in ''|*[!0-9]*) _l=0;; esac; if [ \"\$_l\" -le $now ]; then bash '$BIN/dash-raw-session.sh' --prompt-file='$qf' >/dev/null 2>&1; else rm -f '$qf'; tmux display-message 'dash: pasted text is not a task — the prompt line takes ONE task. Paste long text into a Claude window or the file inbox (see ONBOARDING).' 2>/dev/null; fi"
    fi
  fi
  echo "clear-query+reload(bash $ROWS)"; exit 0
fi

# LANDED view (dash ⌃t): rows carry a `landed:<pr>` / `landed:issue:<n>` /
# `landed:scratch:scratch-<n>` (#466) target, not a
# live window — Enter RESUMES that finished session, identical to ⌃o: it hands the target
# to dash-restore-session.sh, which reconstructs the removed worktree off the squash SHA and
# reopens a `claude --resume` window (#261). Every row shape resumes (dash-restore-session.sh's
# restore_key_for handles landed:issue:<n>, landed:<pr> and landed:scratch:<key>). Open the row's PR in the browser
# with ⌃p (dash-open-pr.sh) — the pre-#261 Enter behavior (#130), relocated so Enter can jump.
# Per-fleet keyed (FLEET_SESSION), matching dash-view-toggle.sh. Clear any half-set rename/bind
# flag first so a mode toggled in landed view can't leak into the next live-view Enter.
#
# Dropping the flag is NOT the whole undo (issue #454). Arming rename also UNBOUND `?` —
# the dash's cheatsheet key, which fzf otherwise keeps firing instead of typing
# (dash-rename.sh) — and relabelled the prompt. Only an explicit rebind puts it back, and
# this branch used to emit none: arm ⌃e → toggle ⌃t → Enter left `?` DEAD (and the
# `rename ▸ ` prompt up) for the rest of that fzf's life, one of the two ways `?`
# silently stopped opening the cheatsheet. So carry the same restore the Enter/Esc
# rename branches emit — but only when a flag was actually live, so a plain landed
# Enter keeps emitting exactly what it always did.
RESTORE=""
if [ "$(cat "$C/global/dash_view_${FLEET_SESSION:-default}" 2>/dev/null)" = landed ]; then
  if [ -f "$flag" ] || [ -f "$bindflag" ]; then
    RESTORE="rebind(?)+change-prompt($PROMPT)+"
  fi
  rm -f "$flag" "$bindflag"
  case "$target" in
    landed:*)   # landed:<pr> | landed:issue:<n> | landed:scratch:<key> — resume it (= ⌃o, #261)
      bash "$BIN/dash-restore-session.sh" "$target" >/dev/null 2>&1
      echo "${RESTORE}clear-query+reload(bash $ROWS)"; exit 0 ;;
  esac
fi

if [ -f "$bindflag" ]; then                       # bind-issue mode (empty q unbinds)
  t=$(cat "$bindflag"); rm -f "$bindflag"
  tmux set-window-option -t "$t" @issue "$q" 2>/dev/null
  echo "rebind(?)+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
elif [ -f "$flag" ]; then                         # rename mode
  t=$(cat "$flag"); rm -f "$flag"
  # `--` ends the flag list: without it a name starting with `-` is parsed as a
  # tmux flag ("unknown flag -d") and the rename silently fails.
  if [ -n "$q" ]; then tmux rename-window -t "$t" -- "$q" 2>/dev/null
    echo "rebind(?)+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
  else echo "rebind(?)+change-prompt($PROMPT)+clear-query"; fi
else                                              # jump (empty query)
  # $RESTORE is empty on every normal jump; it is non-empty only for the landed-view
  # fall-through above (a non-`landed:` row while a rename/bind was armed), which must
  # put `?` and the prompt back just like the branches that own those modes (#454).
  tmux select-window -t "$target" 2>/dev/null
  echo "${RESTORE}clear-query"
fi
