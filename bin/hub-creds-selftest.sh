#!/bin/bash
# hub-creds-selftest.sh — a hub-managed pool account (issue #1415) reaches
# claude through the FILE the ccquota agent keeps renewed, never as an env token.
#
# The ccquota agent (CCQUOTA_FLEET_CREDS=1) leases this login's short-lived
# Claude token from the hub and writes <accounts>/<label>.hub/.credentials.json,
# with `hub:<label>` in the pool file <accounts>/<label>. Measured on Claude Code
# 2.1.289 (issue #1415, first comment): a running session re-reads that file on
# its next request when pointed at it via CLAUDE_SECURESTORAGE_CONFIG_DIR, while
# CLAUDE_CODE_OAUTH_TOKEN is read once at launch — a session started on the env
# var would die at the token's expiry. So every place that hands a claude its
# account must branch on the marker, and every place that asks "which account is
# this process on" must read the directory back.
#
# Asserted here (no tmux, no network, no real credentials):
#   • EXPORT-HUB    fleet_claude_export_auth hub:<l> → CLAUDE_SECURESTORAGE_CONFIG_DIR
#                   at <accounts>/<l>.hub, and NO CLAUDE_CODE_OAUTH_TOKEN (an
#                   inherited one would win over the file)
#   • EXPORT-PLAIN  a plain token is exported exactly as before, and a stale
#                   hub directory from the parent is dropped
#   • HELPER        fleet_helper_claude_auth on a hub-managed active account, and
#                   an inherited hub directory is kept (the hook path)
#   • ENV           `fleet-account.sh env` prints the directory, not the marker
#   • LIST          `fleet-account.sh list` says the account is from the hub and
#                   when its token runs out; expired / nothing leased read as such
#   • TRUTH         fleet-account-truth.py maps a process's
#                   CLAUDE_SECURESTORAGE_CONFIG_DIR back to its label
#   • CLAUDE-SH     bin/fleet-claude.sh launches claude with the directory
#
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
ACCT="$BIN/fleet-account.sh"
TRUTH="$BIN/fleet-account-truth.py"
for f in "$LIB" "$ACCT" "$TRUTH" "$BIN/fleet-claude.sh"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-creds-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export TMPDIR="$WORK"
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_ACCOUNTS_DIR="$WORK/accounts"
unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR
mkdir -p "$FLEET_ACCOUNTS_DIR/hubbed.hub" "$FLEET_CONF_DIR"
printf 'hub:hubbed\n' > "$FLEET_ACCOUNTS_DIR/hubbed"
printf 'tok-plain\n'  > "$FLEET_ACCOUNTS_DIR/plain"
exp_ms=$(( ( $(date +%s) + 5 * 3600 ) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-short","refreshToken":null,"expiresAt":%s,"scopes":["user:inference"]}}' \
  "$exp_ms" > "$FLEET_ACCOUNTS_DIR/hubbed.hub/.credentials.json"
chmod 600 "$FLEET_ACCOUNTS_DIR/hubbed" "$FLEET_ACCOUNTS_DIR/plain" "$FLEET_ACCOUNTS_DIR/hubbed.hub/.credentials.json"

# shellcheck source=/dev/null
. "$LIB"
command -v fleet_claude_export_auth >/dev/null 2>&1 || fail "fleet-lib.sh does not define fleet_claude_export_auth"

# --- EXPORT-HUB / EXPORT-PLAIN ----------------------------------------------------
got="$( CLAUDE_CODE_OAUTH_TOKEN=tok-inherited; export CLAUDE_CODE_OAUTH_TOKEN
        fleet_claude_export_auth 'hub:hubbed'
        printf '%s|%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}" )"
[ "$got" = "$FLEET_ACCOUNTS_DIR/hubbed.hub|" ] || fail "hub marker exported [$got], want the .hub dir and no env token"
ok "a hub-managed account exports CLAUDE_SECURESTORAGE_CONFIG_DIR and drops any env token"

got="$( CLAUDE_SECURESTORAGE_CONFIG_DIR=/stale/x.hub; export CLAUDE_SECURESTORAGE_CONFIG_DIR
        fleet_claude_export_auth 'tok-plain'
        printf '%s|%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}" )"
[ "$got" = "|tok-plain" ] || fail "plain token exported [$got], want CLAUDE_CODE_OAUTH_TOKEN only"
ok "a plain token is exported as before, and a parent's hub dir does not leak through"

# --- HELPER -----------------------------------------------------------------------
bash "$ACCT" use hubbed >/dev/null 2>&1 || fail "could not pin the active account"
got="$( fleet_helper_claude_auth; printf '%s|%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}" )"
[ "$got" = "$FLEET_ACCOUNTS_DIR/hubbed.hub|" ] || fail "helper on a hub account exported [$got]"
ok "fleet_helper_claude_auth points a helper claude at the hub-managed file"
got="$( CLAUDE_SECURESTORAGE_CONFIG_DIR=/inherited/x.hub; export CLAUDE_SECURESTORAGE_CONFIG_DIR
        bash "$ACCT" use plain >/dev/null 2>&1; fleet_helper_claude_auth
        printf '%s|%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}" )"
[ "$got" = "/inherited/x.hub|" ] || fail "an inherited hub dir was overridden by the helper: [$got]"
ok "an inherited hub dir always wins (the hook path keeps its worker's account)"
bash "$ACCT" use hubbed >/dev/null 2>&1

# --- ENV --------------------------------------------------------------------------
got="$(bash "$ACCT" env 2>/dev/null)"
[ "$got" = "CLAUDE_SECURESTORAGE_CONFIG_DIR=$FLEET_ACCOUNTS_DIR/hubbed.hub" ] || fail "env printed [$got]"
ok "fleet-account.sh env prints the directory, never the marker as a token"

# --- LIST -------------------------------------------------------------------------
ESC=$(printf '\033')
strip() { sed "s/${ESC}\[[0-9;]*m//g"; }
row="$(bash "$ACCT" list 2>/dev/null | strip | awk '$1=="hubbed"')"
case "$row" in *'ok · hub · expires in ~'*) ;; *) fail "list row for a leased hub account: [$row]" ;; esac
ok "list shows a hub account as from the hub, with its token's time left"
row="$(bash "$ACCT" list 2>/dev/null | strip | awk '$1=="plain"')"
case "$row" in *hub*) fail "a plain account is listed as hub: [$row]" ;; *ok*) ;; *) fail "plain row: [$row]" ;; esac
ok "a plain account's row is unchanged"
printf '{"claudeAiOauth":{"accessToken":"x","expiresAt":1000}}' > "$FLEET_ACCOUNTS_DIR/hubbed.hub/.credentials.json"
row="$(bash "$ACCT" list 2>/dev/null | strip | awk '$1=="hubbed"')"
case "$row" in *'expired · hub'*) ;; *) fail "expired hub token row: [$row]" ;; esac
rm -f "$FLEET_ACCOUNTS_DIR/hubbed.hub/.credentials.json"
row="$(bash "$ACCT" list 2>/dev/null | strip | awk '$1=="hubbed"')"
case "$row" in *'NO TOKEN · hub, nothing leased yet'*) ;; *) fail "unleased hub row: [$row]" ;; esac
ok "list says expired / nothing leased — the agent is not keeping the account current"

# --- TRUTH ------------------------------------------------------------------------
got="$(python3 - "$TRUTH" "$FLEET_ACCOUNTS_DIR" <<'PY'
import hashlib, importlib.util, sys
spec = importlib.util.spec_from_file_location('truth', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tok = m.hub_token([b'PATH=/bin', b'CLAUDE_SECURESTORAGE_CONFIG_DIR=' + sys.argv[2].encode() + b'/hubbed.hub'])
idx = m.account_index(sys.argv[2])
print(idx.get(m.digest(tok)) if tok else 'none', m.hub_token([b'CLAUDE_SECURESTORAGE_CONFIG_DIR=/x/y']))
PY
)"
[ "$got" = "hubbed None" ] || fail "truth mapped a hub process to [$got], want 'hubbed None'"
ok "fleet-account-truth.py maps CLAUDE_SECURESTORAGE_CONFIG_DIR back to its pool label"

# --- CLAUDE-SH --------------------------------------------------------------------
# A leased token again, and hubbed re-pinned: while it had none, the pick moved
# the active account off it for its login (#1670).
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-short","refreshToken":null,"expiresAt":%s,"scopes":["user:inference"]}}' \
  "$exp_ms" > "$FLEET_ACCOUNTS_DIR/hubbed.hub/.credentials.json"
bash "$ACCT" use hubbed >/dev/null 2>&1
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<EOF
#!/bin/sh
printf '%s|%s' "\${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" "\${CLAUDE_CODE_OAUTH_TOKEN:-}" > "$WORK/claude-env"
EOF
chmod +x "$WORK/bin/claude"
( unset TMUX TMUX_PANE; PATH="$WORK/bin:$PATH" CLAUDE_CODE_OAUTH_TOKEN=tok-inherited \
    bash "$BIN/fleet-claude.sh" -p hi >/dev/null 2>&1 )
got="$(cat "$WORK/claude-env" 2>/dev/null)"
[ "$got" = "$FLEET_ACCOUNTS_DIR/hubbed.hub|" ] || fail "fleet-claude.sh launched claude with [$got]"
ok "fleet-claude.sh launches claude on the hub-managed file, not an env token"

printf 'selftest OK: %s checks — hub-managed accounts reach claude as a renewable file (issue #1415)\n' "$pass"
