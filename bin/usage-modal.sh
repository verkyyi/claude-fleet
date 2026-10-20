#!/bin/bash
# usage-modal.sh — the consolidated Claude usage + subscription-account modal
# (issue #289; merges the old usage-popup.sh + account-pick.sh into ONE surface).
# Opened by `prefix u` until issue #1714 took the person's keys off the node (the
# client binds none for it). Its older door, a click on the
# footer's 5h/7d usage stat, went with the stat (issue #1100); there is no ◉
# account chip either (dropped: see the "no fixed account" note below). It shows:
#   • usage DETAIL as the header — the local 5h/7d proxy + the official
#     weekly/N-hour limit line (which limit + reset), read via usage-lib.sh — the
#     SAME shared reader the status bar's limit alarms use, so they can't drift;
#   • this login's accounts as a READ-ONLY table (fleet-account.sh list): nothing
#     here picks one since T550 — the pool picks behind the credential proxy.
# On a SINGLE-account install (no token files) there is no pool to pick: it shows
# the usage detail only + a pointer to register accounts, and holds for a key.
# Run inside a fleet popup.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

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
    printf '\n  %sno accounts registered on this login — the pool picks the subscription%s\n' "$UDIM" "$UR"
    printf '  %spress any key to close%s\n' "$UDIM" "$UR"
    IFS= read -rsn1 _ 2>/dev/null || true
    exit 0 ;;
esac

# --- MULTI-account: the usage detail, then this login's accounts as a READ-ONLY
# table. Nothing here picks one any more (T550, EPIC T542 C4): a session's
# subscription is the pool's pick behind the credential proxy, else this login's
# own login — so there is nothing to choose, only to read.
render_usage_detail
printf '\n%s\n' "$listing"
printf '\n  %s订阅由池子挑 · the pool picks the subscription%s\n' "$UDIM" "$UR"
printf '  %spress any key to close%s\n' "$UDIM" "$UR"
IFS= read -rsn1 _ 2>/dev/null || true

fi
