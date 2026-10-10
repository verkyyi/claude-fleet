#!/bin/bash
# hub-sessions-cert-scope-selftest.sh — whose rows the shell keeps (issue #2388).
#
# cj opened a session from his own computer and it never showed among the running
# ones: fleet-hub-sessions.sh kept only the hub's rows whose os_user was `id -un`
# — the name of the computer he sits at, not his login on the node. Over a
# connection certificate the hub has already cut the answer to the person's own
# (machine, login) pairs (FleetScope; a certificate is never the operator), so
# the shell keeps every row then.
#
#   A. client + certificate → a row whose login is not `id -un` is kept
#   B. client + viewer token (the operator's: every login) → still `id -un` only
#   C. FLEET_HUB_SESSIONS_USER still wins over the certificate
#   D. a node (no client mode) + certificate → `id -un` only, as before
#   F. a node + its node token (issue #3001: the hub cut the answer to the login's
#      PERSON) → every login of theirs is kept: another login's row elsewhere, and
#      one on THIS machine — never mistaken for this login's local row, even when
#      its fleet shares this one's name, and no #node line for this machine; a
#      login no person holds is refused (401) and reads as before
#
# Hermetic: curl is a PATH shim that answers 200 with a fixture; leg A mints its
# own throwaway CA + certificate. No network. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
HUBS="$BIN/fleet-hub-sessions.sh"
command -v python3 >/dev/null 2>&1 || { echo 'hub-sessions-cert-scope selftest: python3 absent — SKIP'; exit 0; }
command -v ssh-keygen >/dev/null 2>&1 || { echo 'hub-sessions-cert-scope selftest: ssh-keygen absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/certscope-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
unset CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_CLIENT FLEET_HUB_SESSIONS_LOCAL TMUX TMUX_PANE \
      FLEET_HUB_URL FLEET_CERT XDG_CONFIG_HOME
S="cscope$$"
export TMPDIR="$WORK/t" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home" \
       CCQUOTA_FLEET=1 CCQUOTA_HUB_URL=http://hub.test
G="$TMPDIR/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/bin" "$HOME/.ssh" "$HOME/.ccquota"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/$S/conf"

ME=$(id -un)
F=11111111-1111-4111-8111-111111111111
cat > "$WORK/sessions.json" <<EOF
{"sessions": [
 {"worker_id": "$F/issue-7", "machine_name": "m5", "os_user": "cj", "availability": "online",
  "worker": {"issue": 7, "repo": "acme/app", "state": "working", "agent": "claude", "name": "cj-new", "needs": ""}},
 {"worker_id": "$F/issue-9", "machine_name": "m5", "os_user": "$ME", "availability": "online",
  "worker": {"issue": 9, "repo": "acme/app", "state": "working", "agent": "claude", "name": "mine", "needs": ""}}],
 "nodes": [{"machine_name": "m5", "availability": "online", "sessions": 2}]}
EOF
# curl: write the fixture to -o, print 200
cat > "$WORK/bin/curl" <<SHIM
#!/bin/sh
out=''
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { out=\$2; shift; }; shift; done
[ -n "\$out" ] && cat '$WORK/sessions.json' > "\$out"
code=\$(cat '$WORK/code' 2>/dev/null); printf '%s' "\${code:-200}"
SHIM
chmod +x "$WORK/bin/curl"
PATH="$WORK/bin:$PATH"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
has()   { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want: $3)" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (unwanted: $3)" "$2" ;; esac; }
client() { rm -f "$G/remote_$S" "$G"/hubsess.etag* 2>/dev/null
           FLEET_HUB_SESSIONS_CLIENT="$S" bash "$HUBS" --refresh 2>"$WORK/err"; cat "$G/remote_$S" 2>/dev/null; }

ssh-keygen -q -t ed25519 -N '' -f "$WORK/ca" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/fleet-cert" >/dev/null 2>&1
ssh-keygen -q -s "$WORK/ca" -I 'gh:cj' -n cj -V '-5m:+1h' "$HOME/.ssh/fleet-cert.pub" >/dev/null 2>&1 \
  || fail "could not sign a test certificate"

out=$(client)
has   "A: client + certificate keeps the row of the node's login (cj ≠ $ME)" "$out" "wid:$F/issue-7"
has   "A: …and the one of this computer's name" "$out" "wid:$F/issue-9"

rm -f "$HOME/.ssh/fleet-cert" "$HOME/.ssh/fleet-cert-cert.pub"
printf 'tok-123\n' > "$HOME/.ccquota/viewer-token"
out=$(client)
has   "B: client + viewer token keeps \`id -un\`'s row" "$out" "wid:$F/issue-9"
hasnt "B: …and drops another login's (the operator sees every login)" "$out" "wid:$F/issue-7"

ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/fleet-cert" >/dev/null 2>&1
ssh-keygen -q -s "$WORK/ca" -I 'gh:cj' -n cj -V '-5m:+1h' "$HOME/.ssh/fleet-cert.pub" >/dev/null 2>&1
out=$(FLEET_HUB_SESSIONS_USER="$ME" client)
hasnt "C: FLEET_HUB_SESSIONS_USER wins over the certificate" "$out" "wid:$F/issue-7"

rm -f "$G/remote_$S"
bash "$HUBS" --refresh 2>"$WORK/err"
out=$(cat "$G/remote_$S" 2>/dev/null)
has   "D: a node + certificate still writes its cache" "$out" "wid:$F/issue-9"
hasnt "D: …with \`id -un\`'s rows only, as before" "$out" "wid:$F/issue-7"

# F (issue #3001): node mode over the node token keeps the person's other logins.
HERE=$(hostname 2>/dev/null); HERE=${HERE%%.*}
G2=22222222-2222-4222-8222-222222222222
cat > "$WORK/sessions.json" <<EOF
{"sessions": [
 {"worker_id": "$F/issue-7", "machine_name": "m5", "os_user": "admin", "availability": "online",
  "worker": {"issue": 7, "repo": "acme/app", "state": "working", "agent": "claude", "name": "admin-m5", "needs": ""}},
 {"worker_id": "$G2/issue-8", "machine_name": "$HERE", "os_user": "admin", "fleet_id": "$G2",
  "fleet_name": "$S", "availability": "online",
  "worker": {"issue": 8, "repo": "acme/app", "state": "working", "agent": "claude", "name": "admin-here", "needs": ""}},
 {"worker_id": "$F/issue-9", "machine_name": "m5", "os_user": "$ME", "availability": "online",
  "worker": {"issue": 9, "repo": "acme/app", "state": "working", "agent": "claude", "name": "mine", "needs": ""}}],
 "nodes": [{"machine_name": "m5", "availability": "online", "sessions": 2}]}
EOF
rm -f "$G/remote_$S" "$G"/hubsess.etag* "$G/fleet_logins" "$G/hubsess.nodetok.refused"
printf 'CCQUOTA_TOKEN=node-tok\n' > "$WORK/conf/node.env"
bash "$HUBS" --refresh 2>"$WORK/err"
out=$(cat "$G/remote_$S" 2>/dev/null)
has   "F: node + node token keeps another login's row elsewhere" "$out" "wid:$F/issue-7"
has   "F: …and this login's own" "$out" "wid:$F/issue-9"
row=$(printf '%s\n' "$out" | grep "^wid:$G2/issue-8")
has   "F: …and another login's row on THIS machine" "$row" "admin-here"
CHECKS=$((CHECKS + 1)); [ "$(printf '%s' "$row" | cut -d$'\037' -f11)" = 0 ] \
  || fail "F: another login's row here is not this login's local row" "$row"
hasnt "F: no #node line for this machine" "$out" "#node"$'\037'"$HERE"$'\037'
has   "F: the fleet → login map carries the other login" "$(cat "$G/fleet_logins" 2>/dev/null)" "$G2	admin"
printf 401 > "$WORK/code"; rm -f "$G/remote_$S" "$G"/hubsess.etag*
bash "$HUBS" --refresh 2>/dev/null
CHECKS=$((CHECKS + 1)); [ -f "$G/hubsess.nodetok.refused" ] \
  || fail "F: a login no person holds is refused (401) and remembered, as before"
rm -f "$WORK/conf/node.env" "$WORK/code" "$G/hubsess.nodetok.refused"

# E (issue #2465): WHY a round did not stand sits beside hub_ok — refused (401)
# told apart from no answer, its since kept while the reason holds, gone on 200.
printf 401 > "$WORK/code"; rm -f "$G/hub_why"
bash "$HUBS" --refresh 2>/dev/null
w=$(cat "$G/hub_why" 2>/dev/null)
has   "E: a 401 writes hub_why refused" "$w" "refused	"
has   "E: …with the code" "$w" "HTTP 401"
since1=$(printf '%s' "$w" | cut -f2)
sleep 1; bash "$HUBS" --refresh 2>/dev/null
CHECKS=$((CHECKS + 1)); [ "$(cut -f2 "$G/hub_why")" = "$since1" ] || fail "E: the since holds while the hub keeps refusing" "$(cat "$G/hub_why")"
printf 000 > "$WORK/code"
bash "$HUBS" --refresh 2>/dev/null
has   "E: no answer writes hub_why unreachable" "$(cat "$G/hub_why" 2>/dev/null)" "unreachable	"
printf 200 > "$WORK/code"
bash "$HUBS" --refresh 2>/dev/null
CHECKS=$((CHECKS + 1)); [ ! -f "$G/hub_why" ] || fail "E: an answer that stands removes hub_why" "$(cat "$G/hub_why")"

printf 'hub-sessions-cert-scope selftest: PASS (%d checks)\n' "$CHECKS"
