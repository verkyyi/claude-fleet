#!/usr/bin/env bash
# sidebar-machine-tag-selftest.sh — every session says which machine it runs on
# (issue #1780, EPIC #1776 C4). The old client's sidebar and bar that drew the
# mark went with that client (issue #3008); what is left is
# bin/fleet-remote-view.sh's proxy title:
#   E. proxy title   — fleet-remote-view.sh titles a proxy `<name> · @mac-a`
#                      (`@本机` on this computer), never `mac-a <name>`
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0 FAIL=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*" >&2; }

# E. the proxy window's title (fleet-remote-view.sh): `<name> · @mac-a`, `@本机` here
CHECKS=$((CHECKS + 1))
src=$(sed -n '/^rv_machine_word()/,/^}/p' "$BIN/fleet-remote-view.sh")
[ -n "$src" ] || fail "E: fleet-remote-view.sh has rv_machine_word"
words=$(FLEET_UI_LANG=zh FLEET_SIDEBAR_HOST=mac-c.local FLEET_NODE_ALIASES="mac-c=mac-b mac-d=mac-a" BIN="$BIN" bash -c '
  . "$BIN/fleet-ui-lang.sh"; eval "$1"
  printf "%s|%s|%s|%s" "$(rv_machine_word mac-a)" "$(rv_machine_word mac-b)" "$(rv_machine_word MAC-B)" "$(rv_machine_word mac-c)"' _ "$src")
[ "$words" = "mac-a|本机|本机|本机" ] && printf 'ok   E: the title'"'"'s machine word: mac-a elsewhere, 本机 here\n' \
  || fail "E: the title's machine word — got [$words] want [mac-a|本机|本机|本机]"
CHECKS=$((CHECKS + 1))
if grep -q 'title="${name:-${wid#\*/}} · @$(rv_machine_word "$node")"' "$BIN/fleet-remote-view.sh" \
   && ! grep -q 'title="$node ' "$BIN/fleet-remote-view.sh"; then
  printf 'ok   E: a proxy is titled <name> · @<machine>, no machine prefix\n'
else
  fail "E: fleet-remote-view.sh titles a proxy <name> · @<machine>"
fi

if [ "$FAIL" -gt 0 ]; then
  printf 'sidebar-machine-tag selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'sidebar-machine-tag selftest: PASS (%d checks)\n' "$CHECKS"
