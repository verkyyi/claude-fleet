#!/bin/bash
# helper-auth-selftest.sh — a fleet helper `claude -p` must ride the account POOL
# (issue #497).
#
# The sleep digest (bin/fleet-sleep.py) shells out to `claude -p` through
# fleet_helper_claude_auth; the screen classifier that first needed this wire
# retired with issue #2543. Every WORKER runs on a pool token
# (bin/fleet-claude.sh exports CLAUDE_CODE_OAUTH_TOKEN before exec'ing claude); the
# helpers used to run on the machine's AMBIENT login instead — the one credential
# nothing else in the fleet depends on. On 2026-08-25 that login lapsed and the
# helpers went dark while all eleven workers kept going.
#
# Asserted here:
#   • POOL-TOKEN   fleet_helper_claude_auth exports the ACTIVE account's token
#   • INHERIT-WINS an already-set CLAUDE_CODE_OAUTH_TOKEN is never overwritten (the
#                  hook path is a child of a worker's claude — re-resolving 'active'
#                  there could hand a hook the OTHER account mid-turn)
#   • POOL-OFF     no accounts configured ⇒ clean no-op (ambient login still correct)
#
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
ACCT="$BIN/fleet-account.sh"
for f in "$LIB" "$ACCT"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helper-auth-selftest.XXXXXX")" || exit 2

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export TMPDIR="$WORK"                       # FLEET_C → $WORK/.claude-dash
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_ACCOUNTS_DIR="$WORK/accounts"  # fleet-account.sh reads this
unset CLAUDE_CODE_OAUTH_TOKEN

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------- unit: the wire
# shellcheck source=/dev/null
. "$LIB"
command -v fleet_helper_claude_auth >/dev/null 2>&1 \
  || fail "fleet_helper_claude_auth not defined by fleet-lib.sh (issue #497)"
ok "fleet-lib.sh defines fleet_helper_claude_auth"

# POOL-OFF: no accounts dir at all ⇒ nothing exported, nothing broken.
( unset CLAUDE_CODE_OAUTH_TOKEN; fleet_helper_claude_auth
  [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ) \
  || fail "with no accounts configured the helper still exported a token"
ok "no pool configured ⇒ clean no-op (the ambient login stays correct)"

mkdir -p "$FLEET_ACCOUNTS_DIR"
printf 'tok-alpha\n' > "$FLEET_ACCOUNTS_DIR/alpha@example.com"
printf 'tok-beta\n'  > "$FLEET_ACCOUNTS_DIR/beta@example.com"
chmod 600 "$FLEET_ACCOUNTS_DIR"/*
bash "$ACCT" use beta@example.com >/dev/null 2>&1 \
  || fail "could not pin the active pool account"

# POOL-TOKEN: the ACTIVE account's token, not just any account's.
got="$( unset CLAUDE_CODE_OAUTH_TOKEN; fleet_helper_claude_auth; printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" )"
[ "$got" = 'tok-beta' ] || fail "helper did not export the ACTIVE account's token — got [$got]"
ok "fleet_helper_claude_auth exports the active pool account's token"

# INHERIT-WINS: a token already in the env is the hook path's, and it must survive.
got="$( CLAUDE_CODE_OAUTH_TOKEN=tok-inherited; export CLAUDE_CODE_OAUTH_TOKEN
        fleet_helper_claude_auth; printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" )"
[ "$got" = 'tok-inherited' ] \
  || fail "an inherited CLAUDE_CODE_OAUTH_TOKEN was overwritten — got [$got]"
ok "an inherited token always wins (the Stop hook keeps its worker's account)"

printf 'selftest OK: %s checks — helper claude -p rides the account pool (issue #497)\n' "$pass"
