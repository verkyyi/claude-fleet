#!/bin/bash
# fleet-node-role-selftest.sh — a client runs no task (issue #4886).
#
# The hub types every node managed or client (endpoints.role, GET /v1/node/self);
# fleet-client-core.sh's fleet_node_role keeps its word an hour and
# fleet_client_refuse turns the roads that would make a client a host away:
# fleet-repo.sh add, fleet-host.sh on, dash-issue-session.sh / dash-raw-session.sh
# opening here. Unknown is never client — no token, no hub, an untyped row: every
# road as before.
#
#   A  fleet_node_role: the hub's word, kept; the TTL; --fresh; --kept; unknown
#      cases; the diskguard tick (fleet-diskguard.sh node_role_watch) refreshes it
#   B  fleet_client_refuse: client ⇒ the one line; managed / unknown ⇒ nothing;
#      FLEET_ALLOW_CLIENT_TASKS=1 is the hatch
#   C  fleet-repo.sh add on a client: refused with the reason, before any fleet
#   D  the spawn scripts and fleet-host.sh carry the refusal
#   E  fleet-node-role.sh: plan prints the proposal; apply writes only untyped
#      rows, and only once confirmed
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/selftest-lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/node-role-st.XXXXXX")
trap 'rm -rf "${T:?}"' EXIT
pass=0 FAIL=0

# a fake curl: answers /v1/node/self with $FAKE_SELF, counts its calls; exit
# $FAKE_RC (7 = could not connect)
cat > "$T/curl" <<'EOF'
#!/bin/bash
cat >/dev/null
echo x >> "$FAKE_LOG"
[ "${FAKE_RC:-0}" = 0 ] || exit "$FAKE_RC"
printf '%s' "$FAKE_SELF"
EOF
chmod +x "$T/curl"

run() {   # run <conf dir> <shell snippet> — the core alone, as a client has it
  env -i HOME="$T" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$T" FLEET_CONF_DIR="$1" \
    FLEET_HUB_CURL="$T/curl" FAKE_LOG="$T/calls" FAKE_SELF="${FAKE_SELF:-}" FAKE_RC="${FAKE_RC:-0}" \
    FLEET_ALLOW_CLIENT_TASKS="${FLEET_ALLOW_CLIENT_TASKS:-0}" \
    bash -c ". '$BIN/fleet-client-core.sh'; $2"
}
calls() { [ -f "$T/calls" ] && wc -l < "$T/calls" | tr -d ' ' || echo 0; }

# ---- A ----
c="$T/a"; mkdir -p "$c"
printf 'CCQUOTA_TOKEN=tok\nCCQUOTA_HUB_URL=http://hub.invalid\n' > "$c/node.env"
: > "$T/calls"
out=$(FAKE_SELF='{"endpoint_id":"e1","role":"client"}' run "$c" 'fleet_node_role'); rc=$?
[ "$rc" = 0 ] && [ "$out" = client ] && [ "$(calls)" = 1 ] && st_pass "A1 the hub's word: client" || st_miss "A1 rc=$rc out=$out calls=$(calls)"
out=$(FAKE_SELF='{"role":"managed"}' run "$c" 'fleet_node_role')
[ "$out" = client ] && [ "$(calls)" = 1 ] && st_pass "A2 kept for the TTL (no second ask)" || st_miss "A2 out=$out calls=$(calls)"
out=$(FAKE_SELF='{"role":"managed"}' run "$c" 'fleet_node_role --fresh')
[ "$out" = managed ] && [ "$(calls)" = 2 ] && st_pass "A3 --fresh asks again" || st_miss "A3 out=$out calls=$(calls)"
out=$(FAKE_RC=7 run "$c" 'fleet_node_role --fresh'); rc=$?
[ "$rc" = 0 ] && [ "$out" = managed ] && st_pass "A4 hub down: the kept word" || st_miss "A4 rc=$rc out=$out"
printf 'client %s\n' "$(( $(date +%s) - 7200 ))" > "$c/node-role"
out=$(FAKE_SELF='{"role":"managed"}' run "$c" 'fleet_node_role')
[ "$out" = managed ] && st_pass "A5 past the TTL: asked again" || st_miss "A5 out=$out"
out=$(FAKE_SELF='{"endpoint_id":"e1"}' run "$c" 'fleet_node_role --fresh'); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q '^- ' "$c/node-role" && st_pass "A6 an untyped row: unknown (kept as -)" || st_miss "A6 rc=$rc out=$out $(cat "$c/node-role")"
c2="$T/a2"; mkdir -p "$c2"; : > "$T/calls"
out=$(FAKE_SELF='{"role":"client"}' run "$c2" 'fleet_node_role'); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && [ "$(calls)" = 0 ] && st_pass "A7 no node token: unknown, nothing asked" || st_miss "A7 rc=$rc out=$out calls=$(calls)"
c3="$T/a3"; mkdir -p "$c3"; cp "$c/node.env" "$c3/"; : > "$T/calls"
out=$(FAKE_RC=7 run "$c3" 'fleet_node_role; fleet_node_role'); rc=$?
[ -z "$out" ] && [ "$(calls)" = 1 ] && st_pass "A8 hub unreachable, nothing kept: unknown, one ask per TTL" || st_miss "A8 out=$out calls=$(calls)"
c4="$T/a4"; mkdir -p "$c4"; cp "$c/node.env" "$c4/"; : > "$T/calls"
out=$(FAKE_SELF='{"role":"client"}' run "$c4" 'fleet_node_role --kept'); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && st_pass "A10 --kept with nothing kept: unknown, the hub never asked" || st_miss "A10 rc=$rc calls=$(calls)"
printf 'client %s\n' "$(( $(date +%s) - 99999 ))" > "$c4/node-role"
out=$(FAKE_SELF='{"role":"managed"}' run "$c4" 'fleet_node_role --kept')
[ "$out" = client ] && [ "$(calls)" = 0 ] && st_pass "A11 --kept: the kept word, whatever its age, never asking" || st_miss "A11 out=$out calls=$(calls)"
grep -q '^    node_role_watch ' "$BIN/fleet-diskguard.sh" && st_pass "A12 the diskguard tick keeps the word fresh" || st_miss "A12 no node_role_watch on the tick"
out=$(env -i PATH=/usr/bin:/bin FLEET_CONF_DIR="$c2" FLEET_NODE_ROLE=client bash -c ". '$BIN/fleet-client-core.sh'; fleet_node_role")
[ "$out" = client ] && st_pass "A9 FLEET_NODE_ROLE answers for a test" || st_miss "A9 out=$out"

# ---- B ----
printf 'client %s\n' "$(date +%s)" > "$c/node-role"
err=$(run "$c" 'fleet_client_refuse "托管仓库 o/r"' 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && printf '%s' "$err" | grep -q '这台是客户端，任务在托管节点上跑' && st_pass "B1 client: refused, with the reason" || st_miss "B1 rc=$rc err=$err"
err=$(FLEET_ALLOW_CLIENT_TASKS=1 run "$c" 'fleet_client_refuse x' 2>&1); rc=$?
[ "$rc" = 1 ] && [ -z "$err" ] && st_pass "B2 the hatch" || st_miss "B2 rc=$rc err=$err"
printf 'managed %s\n' "$(date +%s)" > "$c/node-role"
err=$(run "$c" 'fleet_client_refuse x' 2>&1); rc=$?
[ "$rc" = 1 ] && [ -z "$err" ] && st_pass "B3 managed: nothing" || st_miss "B3 rc=$rc err=$err"
err=$(run "$c2" 'fleet_client_refuse x' 2>&1); rc=$?
[ "$rc" = 1 ] && [ -z "$err" ] && st_pass "B4 unknown: nothing" || st_miss "B4 rc=$rc err=$err"

# ---- C: fleet-repo.sh add on a client, no fleet here ----
err=$(env -u TMUX FLEET_CONF_DIR="$T/c" FLEET_NODE_ROLE=client bash "$BIN/fleet-repo.sh" add o/r 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$err" | grep -q '这台是客户端' && st_pass "C1 add refused on a client, with the reason" || st_miss "C1 rc=$rc err=$err"
err=$(env -u TMUX FLEET_CONF_DIR="$T/c" FLEET_NODE_ROLE=unknown bash "$BIN/fleet-repo.sh" add o/r 2>&1); rc=$?
printf '%s' "$err" | grep -q '这台是客户端' && st_miss "C2 unknown refused as a client: $err" || st_pass "C2 unknown: the old answer ($(printf '%s' "$err" | head -n 1))"

# ---- D: the roads carry it ----
grep -q 'fleet_client_refuse "开 #$num" --kept' "$BIN/dash-issue-session.sh" && st_pass "D1 dash-issue-session.sh refuses opening here" || st_miss "D1"
grep -q "fleet_client_refuse '开会话' --kept" "$BIN/dash-raw-session.sh" && st_pass "D2 dash-raw-session.sh refuses opening here" || st_miss "D2"
err=$(env -i HOME="$T" PATH=/usr/bin:/bin FLEET_CONF_DIR="$T/d" FLEET_NODE_ROLE=client bash "$BIN/fleet-host.sh" on --yes 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$err" | grep -q '这台是客户端' && st_pass "D3 fleet-host.sh on refused on a client" || st_miss "D3 rc=$rc err=$err"

# ---- E: fleet-node-role.sh ----
cat > "$T/hubcurl" <<'EOF'
#!/bin/bash
hdr=$(cat)
case "$hdr" in *"Bearer vt"*) ;; *) printf '{"error":"no"}\n401'; exit 0 ;; esac
post=0; prev=''
for a in "$@"; do
  [ "$a" = -X ] && post=1
  [ "$prev" = --data-binary ] && echo "$a" >> "$HUB_LOG"
  prev=$a
done
if [ "$post" = 1 ]; then printf '{}\n200'; exit 0; fi
printf '%s\n200' '{"nodes":[{"endpoint_id":"e1","hostname":"mini","os_user":"a","status":"online","role":"","proposed":"managed","why":"machine runs a node program"},{"endpoint_id":"e2","hostname":"laptop","os_user":"me","status":"online","role":"","proposed":"client","why":"x"},{"endpoint_id":"e3","hostname":"pod","os_user":"w","status":"online","role":"managed","proposed":"managed","why":"y"}]}'
EOF
chmod +x "$T/hubcurl"
nr() { env -i PATH=/usr/bin:/bin HUB_LOG="$T/posts" FLEET_HUB_CURL="$T/hubcurl" CCQUOTA_HUB_URL=http://hub.invalid CCQUOTA_VIEWER_TOKEN=vt bash "$BIN/fleet-node-role.sh" "$@" </dev/null; }
out=$(nr plan); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'laptop.*client' && printf '%s' "$out" | grep -q 'mini .*managed' && st_pass "E1 plan prints the proposal" || st_miss "E1 rc=$rc $out"
: > "$T/posts"; nr apply >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -s "$T/posts" ] && st_pass "E2 apply unconfirmed: nothing written" || st_miss "E2 rc=$rc $(cat "$T/posts")"
nr apply --yes >/dev/null; rc=$?
[ "$rc" = 0 ] && grep -q '"e1".*"managed"' "$T/posts" && grep -q '"e2".*"client"' "$T/posts" && ! grep -q '"e3"' "$T/posts" \
  && st_pass "E3 apply --yes writes only the untyped rows" || st_miss "E3 rc=$rc $(cat "$T/posts")"

printf '\nfleet-node-role-selftest: %d passed, %d failed\n' "$pass" "$FAIL"
st_done
