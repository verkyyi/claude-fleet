#!/usr/bin/env bash
# fleet-cred-noaccount-selftest.sh — a separated login that holds no Claude
# account is told WHY, never «run /login» (issue #3155). bin/fleet-cred-proxy.py
# serve in separated mode (FLEET_CRED_STORE=1, as fleet-credsep-launch.py starts
# it) with an empty store; the node agent's `lease` control op
# (tokenledger agent/node_creds.go credVerdict) carries the hub's verdict.
#
#   A  no verdict yet: 403 says no lease has run yet, try again, then the operator
#   B  refused (a drill person, the hub's own words): 403 names the refusal and the
#      operator — never /login as the fix
#   C  leased, but zero Claude accounts (the allowlists): 403 says none is allowed
#   D  a bad state is refused; a verdict that does not change is not rewritten
#   E  the 403 carries no token; the verdict file holds none
#   F  no pool, two labels in accounts/ (T550, EPIC T542 C4): bin/fleet-claude.sh
#      opens the session on the login's own login — it asks fleet-account.sh
#      nothing and exports no account's token; a NAMED account (a migrate /
#      handoff pin) is the one exception
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "/tmp/cred-noacct-st.XXXXXX")
cleanup() { kill "$(cat "$SB/proxy.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$SB"; }
trap cleanup EXIT
FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }
unset FLEET_CRED_AS FLEET_CRED_TEST_PEER_UID CCQUOTA_TOKEN FLEET_HUB_URL
C="$SB/conf"; ST="$SB/state"
mkdir -p "$C/accounts" "$ST"
export FLEET_CONF_DIR="$C" FLEET_CRED_STORE=1 FLEET_CRED_ACCOUNTS="$C/accounts" \
       FLEET_CRED_NODE_ENV="$C/node.env"   # no request reaches an upstream: each is refused first
python3 -I "$BIN/fleet-cred-proxy.py" --state "$ST" serve --log "$SB/proxy.log" 2>"$SB/serve.err" & echo $! > "$SB/proxy.pid"
for _ in $(seq 1 300); do [ -S "$ST/ctl.sock" ] && [ -s "$ST/port" ] && break; sleep 0.1; done
PORT=$(cat "$ST/port" 2>/dev/null)
[ -n "$PORT" ] || { fail "setup: proxy did not start: $(cat "$SB/serve.err")"; exit 1; }
TOK=$(python3 -I "$BIN/fleet-cred-proxy.py" --state "$ST" mint --provider claude --sid s1 2>&1)
case "$TOK" in fcp1.*) pass "setup: separated proxy on :$PORT, a session minted naming no account" ;;
  *) fail "setup: mint: $TOK"; exit 1 ;; esac
ask() { curl -s -m 10 -H "Authorization: Bearer $TOK" -H 'content-type: application/json' -d '{}' \
  -w ' HTTP%{http_code}' "http://127.0.0.1:$PORT/v1/messages"; }
ctl() { python3 - "$ST/ctl.sock" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode()); print(s.makefile().readline().strip())
PY
}

# A
out=$(ask)
case "$out" in *"has not leased an account from the hub yet"*"fleet operator"*HTTP403) pass "A no verdict yet: 403 says no lease ran yet" ;;
  *) fail "A: $out" ;; esac

# B
r=$(ctl '{"op":"lease","state":"refused","reason":"drill","message":"a drill person gets no credentials"}')
out=$(ask)
case "$r|$out" in *'"ok": true'*'|'*"hub refuses to lease"*"a drill person gets no credentials"*"/login cannot fix this"*"fleet operator"*HTTP403)
  pass "B refused: the hub's words + the operator, /login named as no fix" ;; *) fail "B: $r $out" ;; esac

# C
ctl '{"op":"lease","state":"ok","claude":"0"}' >/dev/null
out=$(ask)
case "$out" in *"leased this login no claude account"*"allowlists"*HTTP403) pass "C leased none: the allowlists named" ;;
  *) fail "C: $out" ;; esac

# D
r=$(ctl '{"op":"lease","state":"maybe"}')
case "$r" in *'"ok": false'*) pass "D a bad state is refused" ;; *) fail "D bad state: $r" ;; esac
n0=$(grep -c '"ev": "lease"' "$SB/proxy.log" 2>/dev/null)
ctl '{"op":"lease","state":"ok","claude":"0"}' >/dev/null
n1=$(grep -c '"ev": "lease"' "$SB/proxy.log" 2>/dev/null)
[ "$n0" = "$n1" ] && [ "$n0" = 2 ] && pass "D the same verdict again: not rewritten (2 lease lines)" || fail "D lease lines $n0 → $n1"

# E
! grep -q 'fcp1\.' "$ST/lease.json" "$SB/proxy.log" 2>/dev/null && pass "E no session credential in the verdict or the log" \
  || fail "E a credential leaked"

# F — the launcher picks no account (T550)
mkdir -p "$SB/fbin" "$SB/fconf" "$SB/facc"
ln -s "$BIN/fleet-claude.sh" "$SB/fbin/fleet-claude.sh"; ln -s "$BIN/fleet-lib.sh" "$SB/fbin/fleet-lib.sh"
[ -f "$BIN/fleet-client-core.sh" ] && ln -s "$BIN/fleet-client-core.sh" "$SB/fbin/fleet-client-core.sh"
cat > "$SB/fbin/fleet-account.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/account.calls"
case "\${1:-}" in active) echo acct-one ;; token) case "\${2:-}" in acct-one) echo tok-one ;; acct-two) echo tok-two ;; esac ;; esac
exit 0
EOF
cat > "$SB/fbin/claude" <<EOF
#!/bin/sh
printf '%s|%s' "\${CLAUDE_CODE_OAUTH_TOKEN:-}" "\${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" > "$SB/claude.env"
EOF
chmod +x "$SB/fbin/fleet-account.sh" "$SB/fbin/claude"
printf 'tok-one\n' > "$SB/facc/acct-one"; printf 'tok-two\n' > "$SB/facc/acct-two"
launch() { env -i HOME="$SB" PATH="$SB/fbin:/usr/bin:/bin" FLEET_CONF_DIR="$SB/fconf" FLEET_ACCOUNTS_DIR="$SB/facc" \
             FLEET_MOD=0 FLEET_AGENT_CFG=0 FLEET_PRETRUST=0 FLEET_STATUS_7501=0 "$@" bash "$SB/fbin/fleet-claude.sh" -p hi >/dev/null 2>&1; }
rm -f "$SB/account.calls" "$SB/claude.env"; launch
[ "$(cat "$SB/claude.env" 2>/dev/null)" = "|" ] && pass "F no pool, two accounts: the login's own login, no token exported" \
  || fail "F the launcher exported an account: '$(cat "$SB/claude.env" 2>/dev/null)'"
[ ! -s "$SB/account.calls" ] && pass "F …and fleet-account.sh was asked nothing (accounts/ unread)" \
  || fail "F the launcher asked fleet-account.sh: $(cat "$SB/account.calls")"
rm -f "$SB/account.calls" "$SB/claude.env"; launch FLEET_ACCOUNT_LABEL=acct-two
[ "$(cat "$SB/claude.env" 2>/dev/null)" = "tok-two|" ] && ! grep -q '^active' "$SB/account.calls" 2>/dev/null \
  && pass "F a named account (a handoff pin) is the one exported, never a pick" \
  || fail "F named: '$(cat "$SB/claude.env" 2>/dev/null)' calls: $(cat "$SB/account.calls" 2>/dev/null)"

[ "$FAIL" = 0 ] && echo "fleet-cred-noaccount-selftest: OK" || { echo "fleet-cred-noaccount-selftest: FAILED"; exit 1; }
