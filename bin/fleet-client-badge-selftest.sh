#!/usr/bin/env bash
# fleet-client-badge-selftest.sh — the status bar's left end, ⌂ = where the client
# runs (issue #1779, EPIC #1776 C3). Drives bin/fleet-client-badge.sh through the
# REAL bin/fleet-client-where.sh (its hub read faked by FLEET_CLIENT_WHERE_CMD):
#   A. three leases  — local iTerm2 / ssh from an iPhone in Termius / no lease
#   B. hub down      — orange 「⌂ <this machine> · 入口连不上」
#   B2. refused     — (#2112) the hub answered 401: orange 「入口不认这台电脑 · 请重新
#                     扫码（fleet login）」, a `rescan` range a tap turns into fleet login
#   C. narrow bar    — under 60 columns: ⌂ + the machine only
#   D. English       — the same words off fleet-ui-lang.sh
#   E. the cache     — one where read per TTL; a width change still redraws
#   F. wiring        — conf/tmux-shell.conf's status-left runs it; ⌂ only there
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/badge-selftest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

CHECKS=0 FAIL=0
eq() { CHECKS=$((CHECKS + 1)); if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$3" "$2" >&2; fi; }

. "$BIN/fleet-palette.sh"
fleet_palette_load "$ROOT/conf/fleet-palette.conf" || { echo "FAIL no palette" >&2; exit 1; }
OK="#[fg=$PAL_BLUE,bold]" WARN="#[fg=$PAL_YELLOW,bold]" TAIL="#[default]#[fg=$PAL_DIM]│"

cat > "$WORK/hubread" <<EOF
#!/bin/bash
cat "$WORK/lease.json"
EOF
chmod +x "$WORK/hubread"
export FLEET_CLIENT_WHERE_CMD="$WORK/hubread" FLEET_SHELL_SESSION="badge-st-none-$$" FLEET_SHELL_CACHE="$WORK/shell" \
  FLEET_CLIENT_BADGE_CACHE="$WORK/cache" FLEET_CLIENT_BADGE_HOST="MacBookPro.local" \
  FLEET_NODE_ALIASES="macmini=m5 mini2=m4 MacBookPro=MacBook" FLEET_UI_LANG=zh
badge() { FLEET_CLIENT_BADGE_TTL="${TTL:-0}" bash "$BIN/fleet-client-badge.sh" "cw=${CW:-120}"; }

# --- A. three leases ---------------------------------------------------------------
printf '%s\n' '{"state":"active","lease":{"id":"L1","device":"Verky Mac","os":"macOS","terminal":"iTerm2 3.7.3","via":"local","host":"MacBookPro","caps":["open_url","iterm2"]}}' > "$WORK/lease.json"
eq "A local iTerm2" "$OK ⌂ MacBook · iTerm2 $TAIL" "$(badge)"
printf '%s\n' '{"state":"active","lease":{"id":"L2","device":"iPhone","os":"iOS","terminal":"Termius","via":"tailnet","host":"macmini","caps":["link"]}}' > "$WORK/lease.json"
eq "A ssh from an iPhone in Termius" "$OK ⌂ m5 ← iPhone Termius $TAIL" "$(badge)"
printf '%s\n' '{"state":"none","lease":null}' > "$WORK/lease.json"
eq "A no lease → this machine, orange" "$WARN ⌂ MacBook $TAIL" "$(badge)"

# --- B. hub down ---------------------------------------------------------------------
printf '#!/bin/bash\nexit 1\n' > "$WORK/hubdown"; chmod +x "$WORK/hubdown"
eq "B hub out of reach → orange 入口连不上" "$WARN ⌂ MacBook · 入口连不上 $TAIL" "$(FLEET_CLIENT_WHERE_CMD="$WORK/hubdown" badge)"
eq "B the where itself could not be read → the same" "$WARN ⌂ MacBook · 入口连不上 $TAIL" \
  "$(FLEET_CLIENT_BADGE_WHERE_CMD=false badge)"

# --- B2. the hub refused this machine's credential (#2112) ---------------------------
printf '#!/bin/bash\nexit 4\n' > "$WORK/hubrefused"; chmod +x "$WORK/hubrefused"
R="#[range=user|rescan]"
eq "B2 401 → orange 请重新扫码, a tap range" "$R$WARN ⌂ MacBook · 入口不认这台电脑 · 请重新扫码（fleet login） #[norange]$TAIL" \
  "$(FLEET_CLIENT_WHERE_CMD="$WORK/hubrefused" badge)"
eq "B2 English" "$R$WARN ⌂ MacBook · the hub refused this computer · scan again (fleet login) #[norange]$TAIL" \
  "$(FLEET_UI_LANG=en FLEET_CLIENT_WHERE_CMD="$WORK/hubrefused" badge)"
eq "B2 narrow → ⌂ + machine, no range" "$WARN ⌂ MacBook $TAIL" "$(CW=40 FLEET_CLIENT_WHERE_CMD="$WORK/hubrefused" badge)"
case "$(cat "$ROOT/conf/tmux-shell.conf")" in
  *"#{==:#{mouse_status_range},rescan}' { display-popup -c '#{client_name}' -E"*"__BIN__/fleet login"*) eq "B2 a tap on it runs fleet login" 1 1 ;;
  *) eq "B2 a tap on it runs fleet login" "rescan bind" "missing" ;;
esac

# --- C. narrow -----------------------------------------------------------------------
printf '%s\n' '{"state":"active","lease":{"device":"iPhone","terminal":"Termius","via":"tailnet","host":"m5"}}' > "$WORK/lease.json"
eq "C narrow (59) → ⌂ + machine" "$OK ⌂ m5 $TAIL" "$(CW=59 badge)"
eq "C 60 is wide" "$OK ⌂ m5 ← iPhone Termius $TAIL" "$(CW=60 badge)"
eq "C narrow + hub down → orange ⌂ + machine" "$WARN ⌂ MacBook $TAIL" "$(CW=40 FLEET_CLIENT_WHERE_CMD="$WORK/hubdown" badge)"

# --- D. English ----------------------------------------------------------------------
eq "D English hub down" "$WARN ⌂ MacBook · hub unreachable $TAIL" "$(FLEET_UI_LANG=en FLEET_CLIENT_WHERE_CMD="$WORK/hubdown" badge)"

# --- E. the cache --------------------------------------------------------------------
rm -rf "$WORK/cache"
cat > "$WORK/counted" <<EOF
#!/bin/bash
echo x >> "$WORK/reads"
cat "$WORK/lease.json"
EOF
chmod +x "$WORK/counted"
: > "$WORK/reads"
TTL=600 FLEET_CLIENT_WHERE_CMD="$WORK/counted" badge >/dev/null
printf '%s\n' '{"state":"none","lease":null}' > "$WORK/lease.json"
out=$(TTL=600 CW=40 FLEET_CLIENT_WHERE_CMD="$WORK/counted" badge)
eq "E within the TTL: one where read" "1" "$(wc -l < "$WORK/reads" | tr -d ' ')"
eq "E a width change redraws off the cache" "$OK ⌂ m5 $TAIL" "$out"
eq "E TTL 0 reads again" "$WARN ⌂ MacBook $TAIL" "$(TTL=0 FLEET_CLIENT_WHERE_CMD="$WORK/counted" badge)"

# --- F. wiring -----------------------------------------------------------------------
eq "F status-left runs the badge" '1' \
  "$(grep -c '^set -g status-left "#(bash __BIN__/fleet-client-badge.sh cw=#{client_width})' "$ROOT/conf/tmux-shell.conf")"
eq "F the badge rides the client package" '1' \
  "$(grep -cx 'bin/fleet-client-badge.sh' "$ROOT/tokenledger/internal/api/fleetclient/manifest")"
# ⌂ is the client's place and nothing else on a bar: the node's bar and the
# client's status-right never draw it
eq "F no ⌂ on the node bar" '0' "$(grep -v '^ *#' "$ROOT/conf/tmux-bar.conf" | grep -c '⌂')"

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-client-badge selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'fleet-client-badge selftest: PASS (%d checks)\n' "$CHECKS"
