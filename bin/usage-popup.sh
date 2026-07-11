#!/bin/bash
# usage-popup.sh — the on-demand Claude usage / subscription-limit detail popup
# (issue #239). The footer usage stat now only CHANGES COLOR at the limit (no
# text); the full story lives here:
#   • the local 5h/7d token-consumption proxy,
#   • the official weekly/N-hour limit line — which limit + reset time, exactly
#     as the CLI printed it — colored by severity (green ok · yellow approaching
#     · red at/near the limit),
#   • on a multi-account install, the account pool + which one new sessions use.
#
# Opened on demand: click the footer usage stat (range=user|usage) or press
# prefix+u — both run this inside `tmux display-popup -E`. It holds open until a
# keypress. Severity math + the freshness gate are shared with the footer via
# usage-lib.sh, so the color you see here matches the color on the bar.
#
# Modes:
#   usage-popup.sh            # render the detail, then wait for a key (popup)
#   usage-popup.sh --summary  # print the one-line PLAIN summary and exit
#                             #   (reused by account-pick.sh's picker header)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"

# --- --summary: the plain one-liner (single source of truth in usage-lib.sh) ---
if [ "${1:-}" = "--summary" ]; then
  fleet_usage_summary_plain
  exit 0
fi

# --- colours (Tokyo Night; honour NO_COLOR + non-tty) -------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[38;2;86;95;137m'; R=$'\033[0m'
  RED=$'\033[38;2;247;118;142m'; YEL=$'\033[38;2;224;175;104m'
  GRN=$'\033[38;2;158;206;106m'; IND=$'\033[38;2;187;154;247m'
else
  B=""; DIM=""; R=""; RED=""; YEL=""; GRN=""; IND=""
fi

# Colour + one-word gloss for a severity token.
sev_color() { case "$1" in crit) printf '%s' "$RED";; warn) printf '%s' "$YEL";; *) printf '%s' "$GRN";; esac; }
sev_word()  { case "$1" in crit) echo "at/near limit";; warn) echo "approaching limit";; *) echo "ok";; esac; }

# label <text> <value...> — aligned two-column row.
row() { printf '  %s%-13s%s %s\n' "$DIM" "$1" "$R" "$2"; }

printf '\n  %s%sClaude usage%s %s— this machine (one shared ~/.claude)%s\n\n' "$B" "$IND" "$R" "$DIM" "$R"

# Local proxy (always shown when present).
proxy=$(fleet_usage_proxy)
if [ -n "$proxy" ]; then
  row "rolling" "${proxy}"
else
  row "rolling" "${DIM}no usage proxy yet (collector hasn't run)${R}"
fi

# Official weekly/N-hour limit line — which limit + reset, colored by severity.
rl=$(fleet_usage_ratelimit)
if [ -n "$rl" ]; then
  pct="${rl%%$'\t'*}"; line="${rl#*$'\t'}"
  sev=$(fleet_usage_severity "$pct")
  row "limit" "$(sev_color "$sev")${line}${R}   ${DIM}[$(sev_word "$sev")]${R}"
else
  row "limit" "${DIM}no official limit signal in the last $(( ${FLEET_RATELIMIT_TTL:-21600} / 3600 ))h${R}"
fi

# Multi-account: pool + active pointer. Silent on single-account installs.
listing=$(bash "$BIN/fleet-account.sh" list 2>/dev/null)
case "$listing" in
  ''|*OFF*) : ;;   # multi-account off → nothing to add
  *)
    active=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
    printf '\n  %s%saccounts%s %s(new sessions use %s)%s\n' "$B" "$IND" "$R" "$DIM" "${active:-?}" "$R"
    printf '%s\n' "$listing" | sed 's/^/    /'
    printf '  %sswitch with prefix A — running sessions keep theirs.%s\n' "$DIM" "$R"
    ;;
esac

printf '\n  %sthe proxy is a LOCAL estimate; the limit line is the official %% (scraped).%s\n' "$DIM" "$R"
printf '  %spress any key to close%s\n' "$DIM" "$R"
IFS= read -rsn1 _ 2>/dev/null || true
