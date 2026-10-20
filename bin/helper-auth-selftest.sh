#!/bin/bash
# helper-auth-selftest.sh — a fleet helper `claude -p` rides the session credential
# it inherited, else this login's own login (issue #497; T550, EPIC T542 C4).
#
# The sleep digest (until T548) shelled out to `claude -p` through
# fleet_helper_claude_auth. Until T550 it exported the ACTIVE pool account's token
# (fleet-account.sh active); the pick is gone — the pool picks behind the
# credential proxy — so the helper keeps what it inherited and adds nothing.
#
# Asserted here:
#   • INHERIT-WINS an inherited session credential (CLAUDE_CODE_OAUTH_TOKEN +
#                  ANTHROPIC_BASE_URL) is never overwritten
#   • NO-PICK      with two accounts in accounts/ and nothing inherited, nothing is
#                  exported and fleet-account.sh is never asked (the own login)
#
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helper-auth-selftest.XXXXXX")" || exit 2

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export TMPDIR="$WORK"                       # FLEET_C → $WORK/.claude-dash
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_ACCOUNTS_DIR="$WORK/accounts"
unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR ANTHROPIC_BASE_URL

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# shellcheck source=/dev/null
. "$LIB"
command -v fleet_helper_claude_auth >/dev/null 2>&1 \
  || fail "fleet_helper_claude_auth not defined by fleet-lib.sh (issue #497)"
ok "fleet-lib.sh defines fleet_helper_claude_auth"

mkdir -p "$FLEET_ACCOUNTS_DIR"
printf 'tok-alpha\n' > "$FLEET_ACCOUNTS_DIR/alpha@example.com"
printf 'tok-beta\n'  > "$FLEET_ACCOUNTS_DIR/beta@example.com"
chmod 600 "$FLEET_ACCOUNTS_DIR"/*

# NO-PICK: two accounts, nothing inherited ⇒ nothing exported (this login's own).
got="$( fleet_helper_claude_auth; printf '%s|%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" )"
[ "$got" = '|' ] || fail "the helper picked an account out of accounts/ — got [$got]"
ok "two accounts in accounts/, nothing inherited ⇒ nothing exported (the own login)"

# INHERIT-WINS: the session credential a worker's hook inherits survives.
got="$( CLAUDE_CODE_OAUTH_TOKEN=tok-inherited ANTHROPIC_BASE_URL=http://127.0.0.1:1; export CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL
        fleet_helper_claude_auth; printf '%s %s' "$CLAUDE_CODE_OAUTH_TOKEN" "$ANTHROPIC_BASE_URL" )"
[ "$got" = 'tok-inherited http://127.0.0.1:1' ] \
  || fail "an inherited session credential was changed — got [$got]"
ok "an inherited session credential always wins"

printf 'selftest OK: %s checks — helper claude -p keeps its inherited credential (T550)\n' "$pass"
