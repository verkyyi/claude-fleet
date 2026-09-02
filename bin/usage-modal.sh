#!/bin/bash
# usage-modal.sh — the consolidated Claude usage + subscription-account modal
# (issue #289; merges the old usage-popup.sh + account-pick.sh into ONE surface).
# Opened by clicking the footer usage stat OR the ◉ account chip
# (MouseDown1Status in conf/tmux-attention.conf) — there is no keyboard path any
# more (prefix A/u were dropped in the shortcut prune). It shows:
#   • usage DETAIL as the header — the local 5h/7d proxy + the official
#     weekly/N-hour limit line (which limit + reset), read via usage-lib.sh — the
#     SAME shared reader that colors the footer, so they can't drift;
#   • the account POOL as the selectable body — Enter switches the account new
#     sessions launch under (via bin/fleet-claude.sh) AND moves this fleet's
#     IDLE Claude windows onto it (`fleet-account.sh migrate --idle`: close +
#     `--resume` in a new window, issue #512); mid-turn (working) and looping
#     sessions keep their old account until their next natural restart or a
#     limit rotation; Esc cancels.
#     Picking a currently-limited account still rotates past it at spawn time.
# On a SINGLE-account install (no token files) there is no pool to pick: it shows
# the usage detail only + a pointer to register accounts, and holds for a key.
# Run inside `tmux display-popup -E`.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"

# --- colours (Tokyo Night; honour NO_COLOR + non-tty) -------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  UB=$'\033[1m'; UDIM=$'\033[38;2;86;95;137m'; UR=$'\033[0m'
  URED=$'\033[38;2;247;118;142m'; UYEL=$'\033[38;2;224;175;104m'
  UGRN=$'\033[38;2;158;206;106m'; UIND=$'\033[38;2;187;154;247m'
else
  UB=""; UDIM=""; UR=""; URED=""; UYEL=""; UGRN=""; UIND=""
fi

# Colour + one-word gloss for a severity token (shared shape with the footer).
_um_sev_color() { case "$1" in crit) printf '%s' "$URED";; warn) printf '%s' "$UYEL";; *) printf '%s' "$UGRN";; esac; }
_um_sev_word()  { case "$1" in crit) echo "at/near limit";; warn) echo "approaching limit";; *) echo "ok";; esac; }
_um_row()       { printf '  %s%-13s%s %s\n' "$UDIM" "$1" "$UR" "$2"; }

# render_usage_detail — the usage/limit header: the local 5h/7d proxy row + the
# official weekly/N-hour limit row (which limit + reset, colored by severity).
# The single source is usage-lib.sh (same reader the footer + account body use).
# This is the modal's whole body on a single-account install and its header text
# on a multi-account one.
render_usage_detail() {
  local proxy rl pct line sev
  printf '\n  %s%sClaude usage%s %s— this machine (one shared ~/.claude)%s\n\n' "$UB" "$UIND" "$UR" "$UDIM" "$UR"
  proxy=$(fleet_usage_proxy)
  if [ -n "$proxy" ]; then _um_row "rolling" "${proxy}"
  else _um_row "rolling" "${UDIM}no usage proxy yet (collector hasn't run)${UR}"; fi
  rl=$(fleet_usage_ratelimit)
  if [ -n "$rl" ]; then
    pct="${rl%%$'\t'*}"; line="${rl#*$'\t'}"
    sev=$(fleet_usage_severity "$pct")
    _um_row "limit" "$(_um_sev_color "$sev")${line}${UR}   ${UDIM}[$(_um_sev_word "$sev")]${UR}"
  else
    _um_row "limit" "${UDIM}no official limit signal in the last $(( ${FLEET_RATELIMIT_TTL:-21600} / 3600 ))h${UR}"
  fi
}

# The "move running sessions onto the new account" machinery (#263 `--continue`
# restart, #495 restart-after-rotate) lived here until issue #512: it could not
# work on an install whose SessionEnd hook closes the window on exit. It is now
# bin/fleet-migrate.sh (`fleet-account.sh migrate …`): close + `--resume` in a NEW
# window, token-verified. This file only dispatches it.

# Sourced by usage-modal-selftest.sh → define the helpers WITHOUT opening fzf or
# touching account state. Only a direct run drops into the interactive picker.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then

listing=$(bash "$BIN/fleet-account.sh" list 2>/dev/null)
case "$listing" in
  *OFF*|'')
    # SINGLE-account install (no token files): there's no pool to pick, so show
    # the usage/limit detail on its own + a pointer to register accounts, and hold
    # for a key — a read-only usage popup (issue #289 folded the old usage-popup
    # here). NB no `--summary` consumer remains, so that mode was dropped.
    render_usage_detail
    printf '\n  %sregister accounts to switch here — see docs/MULTI-ACCOUNT.md%s\n' "$UDIM" "$UR"
    printf '  %spress any key to close%s\n' "$UDIM" "$UR"
    IFS= read -rsn1 _ 2>/dev/null || true
    exit 0 ;;
esac

# --- MULTI-account: usage/limit DETAIL as the header, the account pool as the
# selectable body. The 5h/7d proxy + the official weekly/N-hour % (fresh-gated)
# come from usage-lib.sh, the same shared reader the footer colors and the
# single-account branch above renders, so the header can't drift. Empty when
# neither cache has anything. ---
usg=$(fleet_usage_summary_plain)

active=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
hdr="switch the account fleet sessions use  ·  enter=select · esc=cancel · [✕ close]   [now: ${active}]"
[ -n "$usg" ] && hdr="${usg}"$'\n'"${hdr}"

# --header-lines=1 pins the table's column-title row (line 1 of `list`) so it
# stays aligned with the data rows and out of the selectable set; the usage
# summary rides above it via --header. Data rows lead with the bare label, so
# `awk '{print $1}'` recovers the pick even with the trailing ANSI in STATE.
# The `[✕ close]` button chip in $hdr + the click-header bind add an iPad/Termius
# tap-to-dismiss where Escape is a reach (issue #346): tapping ✕/close aborts fzf
# → empty pick → exit. Bracketed as a button (issue #381), so the clicked word is
# `[✕` or `close]` — the case globs *✕*|*close*. The pinned column-title row
# carries no ✕/close, so a tap there never fires the bind.
pick=$(printf '%s\n' "$listing" \
  | fzf --ansi --no-sort --layout=reverse --height=100% --header-lines=1 \
        --prompt='active account ▸ ' \
        --header="$hdr" \
        --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac' \
  | awk '{print $1}')

[ -n "$pick" ] || exit 0
prev="$active"
if bash "$BIN/fleet-account.sh" use "$pick" >/dev/null 2>&1; then
  now=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
  if [ "$now" = "$pick" ]; then
    msg="fleet: new sessions now use  ${pick}"
  else
    msg="fleet: ${pick} is limited — new sessions use  ${now}"
  fi
  # Move this fleet's IDLE running sessions onto the new account too (issue #263,
  # now fleet-migrate.sh per #512: close + --resume in a new window), but only when
  # the active account actually changed — a re-pick of the current account moves
  # nothing. Backgrounded (issue #304): each move is a cold claude boot and would
  # otherwise hold the popup OPEN. run-shell -b returns instantly and sets $TMUX,
  # so migrate's bare tmux calls stay on THIS fleet's server; --toast reports.
  if [ -n "$now" ] && [ "$now" != "$prev" ]; then
    tmux run-shell -b "bash '$BIN/fleet-account.sh' migrate --idle --toast"
    msg="${msg}  ·  moving idle sessions…"
  fi
  tmux display-message "$msg"
fi

fi
