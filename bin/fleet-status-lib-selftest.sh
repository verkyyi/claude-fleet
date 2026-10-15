#!/bin/bash
# fleet-status-lib-selftest.sh — the hub summaries the home's refresh loop
# leaves on disk, and the status library's readers left after the old client's
# status bar went (issue #3008; the bar's legs A–F, I–L were its own — #1616).
#
#   G  fleet-hub-sessions.sh --refresh writes hub_nodes / hub_limits (+ hub_repos, #1927; its
#      #account line, #2069) from the
#      seams: the alias, mem %, newest login's version, the uuid → local label
#      map, rounding, skipped rows; a failed fetch keeps the last file; off
#      (CCQUOTA_FLEET unset) writes nothing; their own cadence (FLEET_HUB_SUMMARY_EVERY);
#      hub_ok written on a sessions round that stood, left alone on a failed one (#1483);
#      a connection certificate asks POST /v1/fleet/summary once for both and
#      never the token; refused → the viewer routes with it; no answer → nothing (#1502);
#      each version's word against the live install's local refs/tags/stable
#      (issue #644): ok / old:<n> / ahead:<n> / off / ? — and '' (unknown, never
#      current) with no live checkout or no stable tag
#   H  fleet_status_age: `3m` / `2h` / `1d`
#
# Drives bin/fleet-status-lib.sh and bin/fleet-hub-sessions.sh. ps / sysctl /
# vm_stat / free / df are shims; TMPDIR, FLEET_CONF_DIR and FLEET_ACCOUNTS_DIR are
# a sandbox.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; CHECKS=$((CHECKS+1)); }
has() { case "$3" in *"$2"*) CHECKS=$((CHECKS+1)) ;; *) fail "$1" "want a substring: [$2]
 got: [$3]" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "must not contain: [$2]
 got: [$3]" ;; *) CHECKS=$((CHECKS+1)) ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tmux-status-selftest.XXXXXX") || exit 2
T="$WORK/tmp"; G="$T/.claude-dash/global"; CONF="$WORK/conf"; ACC="$WORK/acc"
mkdir -p "$T" "$G" "$WORK/bin" "$CONF/fleets/f1" "$ACC"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
SOCK="$WORK/tmux.sock"
cleanup() {
  if [ -n "$REAL_TMUX" ]; then
    for s in "$SOCK" "$WORK"/l-*.sock; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  fi
  rm -rf "$WORK"
}
[ -n "${KEEP:-}" ] || trap cleanup EXIT
trap 'exit 130' INT TERM HUP
US=$'\x1f'
NOW=$(date +%s)

sh_shim() { printf '#!/bin/sh\n%s\n' "$2" > "$WORK/bin/$1"; chmod +x "$WORK/bin/$1"; }
sh_shim ps      'printf "%%CPU\n12.0\n28.0\n"'
sh_shim sysctl  'printf "4\n8589934592\n16384\n{ 1.20 1.00 0.90 }\n"'
sh_shim vm_stat 'printf "Pages active:  100000.\nPages wired down:  50000.\nPages occupied by compressor:  50000.\n"'
sh_shim free    'printf "       total used\nMem:    8192 3125\n"'
sh_shim df      "printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1 1 104857600 1%% /\n'"
# every `tmux` the bar runs goes to the private server, and is logged (leg F)
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$WORK/tmux.log'
exec '$REAL_TMUX' -S '$SOCK' "\$@"
EOF
chmod +x "$WORK/bin/tmux"; : > "$WORK/tmux.log"

# ---- G: fleet-hub-sessions.sh writes the two summaries
HUBS="$BIN/fleet-hub-sessions.sh"
HB=$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' $(( NOW - 7 )))
# The "live install" the loop judges every machine's version against (issue
# #644): c1 → c2 → c3 on trunk, refs/tags/stable at c2, and c4 a commit off c1
# on no branch — hermetic git (no user config, a fixed identity).
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"
LIVE="$WORK/live"; git init -q "$LIVE" || fail "G: git init"
for c in c1 c2 c3; do git -C "$LIVE" commit -q --allow-empty -m "$c" || fail "G: commit $c"; done
C1=$(git -C "$LIVE" rev-parse --short HEAD~2); C2=$(git -C "$LIVE" rev-parse --short HEAD~1); C3=$(git -C "$LIVE" rev-parse --short HEAD)
git -C "$LIVE" tag stable "$C2"
C4=$(git -C "$LIVE" commit-tree -p "$C1" -m c4 "$(git -C "$LIVE" rev-parse "$C1^{tree}")"); C4=$(git -C "$LIVE" rev-parse --short "$C4")
git init -q "$WORK/nostable"; git -C "$WORK/nostable" commit -q --allow-empty -m x
cat > "$WORK/nodes.json" <<EOF
{"at":"x","machines":[
 {"hostname":"mac-c","status":"online","sessions":14,"load1":5.65234375,"ncpu":15,"mem_free_bytes":29886201856,"mem_total_bytes":68719476736,"last_heartbeat":"$HB"},
 {"hostname":"mac-d","status":"lost","sessions":0,"load1":0,"ncpu":10,"mem_free_bytes":0,"mem_total_bytes":0,"last_heartbeat":null},
 {"hostname":"box3","status":"online","sessions":null,"sessions_unknown":["u/f: UNAVAILABLE"],"load1":1,"ncpu":10,"mem_free_bytes":0,"mem_total_bytes":0,"last_heartbeat":"$HB"},
 {"hostname":"box4","status":"maintenance","sessions":1,"load1":1,"ncpu":4,"mem_free_bytes":1,"mem_total_bytes":2,"last_heartbeat":"$HB"},
 {"hostname":"box5","status":"online","sessions":1,"load1":1,"ncpu":4,"mem_free_bytes":1,"mem_total_bytes":2,"last_heartbeat":"$HB"},
 {"hostname":"box6","status":"online","compute_off":true,"sessions":1,"load1":1,"ncpu":4,"mem_free_bytes":1,"mem_total_bytes":2,"last_heartbeat":"$HB"},
 {"hostname":"","status":"online"}],
 "nodes":[
 {"hostname":"mac-c","os_user":"a","fleet_version":"old","last_heartbeat":"2026-10-04T13:15:20Z"},
 {"hostname":"mac-c","os_user":"b","fleet_version":"$C2","last_heartbeat":"2026-10-04T13:15:25Z"},
 {"hostname":"mac-d","os_user":"c","fleet_version":"","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box3","os_user":"d","fleet_version":"$C1","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box4","os_user":"e","fleet_version":"$C3","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box5","os_user":"f","fleet_version":"$C4","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box6","os_user":"g","fleet_version":"deadbeef","last_heartbeat":"2026-10-04T13:15:23Z"}]}
EOF
cat > "$WORK/limits.json" <<'EOF'
{"per_account":[
 {"account_uuid":"7a7e6173-f07c-490f-844e-00c27c3f0844","label":"ylianghui@icloud.com","limits":{"available":true,"five_hour":{"utilization":63},"seven_day":{"utilization":65.4}}},
 {"account_uuid":"codex:ac","label":"carol.yi@gmail.com","limits":{"available":true,"source":"codex"}},
 {"account_uuid":"e69154ac","label":"carol@24helpful.com","limits":{"available":true,"five_hour":{"utilization":17},"seven_day":{"utilization":6}}},
 {"account_uuid":"5a77adb2","label":"ly297@georgetown.edu","limits":{"available":true,"five_hour":{"utilization":57.99999999999999},"seven_day":{"utilization":72}}},
 {"account_uuid":"gateway:x","label":"AI 网关 · aicall","limits":{"available":false}},
 {"account_uuid":"e58c","label":"tab\there","limits":{"available":true,"five_hour":{"utilization":1}}}]}
EOF
printf 'CCQUOTA_ACCOUNT="7a7e6173-f07c-490f-844e-00c27c3f0844"\n' > "$ACC/icloud.conf"
printf '{"sessions":[]}\n' > "$WORK/sessions.json"
hubs() { TMPDIR="$T/" FLEET_CONF_DIR="$CONF" FLEET_ACCOUNTS_DIR="$ACC" PATH="$WORK/bin:$PATH" CCQUOTA_FLEET="${CF-1}" \
         FLEET_HUB_SESSIONS_CMD="${SCMD-cat '$WORK/sessions.json'}" FLEET_HUB_NODES_CMD="${NCMD-cat '$WORK/nodes.json'}" \
         FLEET_HUB_LIMITS_CMD="${LCMD-cat '$WORK/limits.json'}" FLEET_NODE_ALIASES="mac-c=mac-b mac-d=mac-a" \
         FLEET_HUB_SUMMARY_EVERY="${SEVERY-0}" FLEET_LIVE_DIR="${LIVEDIR-$LIVE}" bash "$HUBS" --refresh 2>"$WORK/err"; }
rm -f "$G/hub_nodes" "$G/hub_limits" "$G/hub_ok"
CF='' hubs; [ -e "$G/hub_nodes" ] || [ -e "$G/hub_limits" ] || [ -e "$G/hub_ok" ] && fail "G: off (CCQUOTA_FLEET unset) wrote a summary or hub_ok"; CHECKS=$((CHECKS+1))
hubs || fail "G: --refresh failed" "$(cat "$WORK/err")"
OK=$(cat "$G/hub_ok" 2>/dev/null)
case "$OK" in
  [0-9]*) [ "$OK" -ge "$NOW" ] || fail "G: hub_ok is not a fresh epoch (#1483)" "$OK" ;;
  *) fail "G: a sessions round that stood must write global/hub_ok (#1483)" "$OK" ;;
esac; CHECKS=$((CHECKS+1))
SCMD=false hubs
eq "G: a failed sessions round leaves hub_ok as it was (#1483)" "$OK" "$(cat "$G/hub_ok")"
has "G: …and says how long the hub has been silent" "hub unreachable for" "$(cat "$WORK/err")"
rows=$(tr '\037' '|' < "$G/hub_nodes")
case "$rows" in "#ts|"[0-9]*) CHECKS=$((CHECKS+1)) ;; *) fail "G: hub_nodes starts with #ts" "$rows" ;; esac
row=$(printf '%s\n' "$rows" | grep '^mac-b|'); row=${row%|*|*|*|*|*}   # drop mem_used/mem_total/ver_state/place/hostname (exact below)
case "$row" in "mac-b|online|5.65|15|56|14|$C2|"[0-9]|"mac-b|online|5.65|15|56|14|$C2|"[0-9][0-9]) CHECKS=$((CHECKS+1)) ;;
  *) fail "G: mac-b's row: alias, mem %, the newest login's version, a small age" "$row" ;; esac
has "G: mac-b's memory in MB" "|37034|65536|" "$(printf '%s\n' "$rows" | grep '^mac-b|')"
eq "G: a lost machine with no reading: empty mem %, no version, no age, no version word" "mac-a|lost|0.00|10||0|||0|0|||mac-d" "$(printf '%s\n' "$rows" | grep '^mac-a|')"
# 「开在哪」's two columns (issue #1778): what may be placed there, and the hostname
pw() { printf '%s\n' "$rows" | awk -F'|' -v n="$1" '$1 == n { print $12 "|" $13 }'; }
eq "G: a machine that takes sessions → no place word, its hostname" "|mac-c" "$(pw mac-b)"
eq "G: compute_off (#1719) → coord" "coord|box6" "$(pw box6)"
eq "G: 维护中 (#1427) → maint, and still lost in field 2" "maint|box4|lost" "$(pw box4)|$(printf '%s\n' "$rows" | awk -F'|' '$1 == "box4" { print $2 }')"
has "G: sessions null (#1465) → ? in the sessions field, never 0" "box3|online|1.00|10||?|" "$(printf '%s\n' "$rows" | grep '^box3|')"
eq "G: a machine with no hostname is not a row" "7" "$(printf '%s\n' "$rows" | grep -c .)"
# the version's word (issue #644): judged against $LIVE's refs/tags/stable (c2)
vw() { printf '%s\n' "$rows" | awk -F'|' -v n="$1" '$1 == n { print $7 "|" $11 }'; }
eq "G: at stable → ok (a short sha against the tag's commit)" "$C2|ok" "$(vw mac-b)"
eq "G: one commit behind stable → old:1" "$C1|old:1" "$(vw box3)"
eq "G: one commit past stable → ahead:1" "$C3|ahead:1" "$(vw box4)"
eq "G: a commit on no line through stable → off" "$C4|off" "$(vw box5)"
eq "G: a sha this checkout does not have → ? (never 0, never ok)" "deadbeef|?" "$(vw box6)"
LIVEDIR="$WORK/nolive" hubs; rows=$(tr '\037' '|' < "$G/hub_nodes")
eq "G: no live checkout → every word empty (unknown), the rows otherwise the same" 0 "$(printf '%s\n' "$rows" | awk -F'|' 'NR > 1 && $11 != ""' | grep -c .)"
eq "G: … box3 still carries its version" "$C1|" "$(vw box3)"
LIVEDIR="$WORK/nostable" hubs; rows=$(tr '\037' '|' < "$G/hub_nodes")
eq "G: a checkout with no refs/tags/stable → every word empty" 0 "$(printf '%s\n' "$rows" | awk -F'|' 'NR > 1 && $11 != ""' | grep -c .)"
hubs; rows=$(tr '\037' '|' < "$G/hub_nodes")
eq "G: … and back with the tag" "$C1|old:1" "$(vw box3)"
# hub_repos (issue #1927): the repos the machines' fleets host, for an empty list
[ -e "$G/hub_repos" ] && fail "G: a hub older than \`repos\` (no key) wrote hub_repos"; CHECKS=$((CHECKS+1))
NCMD="printf '%s' '{\"machines\":[{\"hostname\":\"a\",\"status\":\"online\",\"repos\":[\"acme/web\",\"acme/api\"]},{\"hostname\":\"b\",\"status\":\"online\",\"repos\":[\"acme/web\",\"bad repo\"]}]}'" hubs
eq "G: hub_repos — #ts, then each repo once, sorted, a malformed one dropped" "#ts|acme/api|acme/web" "$(tr '\037' '|' < "$G/hub_repos" | sed '1s/|[0-9]*$//' | tr '\n' '|' | sed 's/|$//')"
NCMD="printf '%s' '{\"machines\":[{\"hostname\":\"a\",\"status\":\"online\",\"repos\":[]}]}'" hubs
eq "G: a hub that says none → hub_repos holds only #ts" "1" "$(grep -c . "$G/hub_repos")"
# a newcomer whose login the hub is opening (issue #2069): no machine yet, the #account line
NCMD="printf '%s' '{\"machines\":[],\"account\":{\"state\":\"opening\",\"eta_s\":42,\"machine\":\"mac-a\",\"ask\":\"dave\"}}'" hubs
eq "G: #2069 an opening login → #ts, then #account state|eta|machine|ask" "#ts|#account|opening|42|mac-a|dave" "$(tr '\037' '|' < "$G/hub_repos" | sed 's/|[0-9]*$//' | tr '\n' '|' | sed 's/|$//')"
NCMD="printf '%s' '{\"machines\":[{\"hostname\":\"a\",\"status\":\"online\",\"repos\":[\"acme/web\"]}]}'" hubs
eq "G: #2069 no account key → no #account line" "0" "$(grep -c '^#account' "$G/hub_repos")"
hubs; [ -e "$G/hub_repos" ] && fail "G: back to an older hub → hub_repos removed"; CHECKS=$((CHECKS+1))
hubs; rows=$(tr '\037' '|' < "$G/hub_nodes")
lrows=$(tr '\037' '|' < "$G/hub_limits")
has "G: a uuid this login has an accounts/<label>.conf for → that label; 65.4 → 65" "icloud|63|65|7a7e6173-f07c-490f-844e-00c27c3f0844|ylianghui@icloud.com" "$lrows"
has "G: an unmapped uuid → the hub's label" "carol@24helpful.com|17|6|e69154ac|carol@24helpful.com" "$lrows"
has "G: 57.999… → 58" "ly297@georgetown.edu|58|72|" "$lrows"
hasnt "G: a codex subscription (no utilization) is skipped" "codex:ac" "$lrows"
hasnt "G: an unavailable reading is skipped" "aicall" "$lrows"
has "G: a tab in a label is a space, the field count holds" "tab here|1||e58c|tab here" "$lrows"
eq "G: four rows + #ts" "5" "$(printf '%s\n' "$lrows" | grep -c .)"
cp "$G/hub_nodes" "$WORK/nodes.keep"; cp "$G/hub_limits" "$WORK/limits.keep"
NCMD='exit 1' LCMD="printf '{\"x\":1}'" hubs
cmp -s "$G/hub_nodes" "$WORK/nodes.keep" || fail "G: a failed /v1/nodes fetch must keep the last hub_nodes"
cmp -s "$G/hub_limits" "$WORK/limits.keep" || fail "G: a /v1/limits answer with no list must keep the last hub_limits"
CHECKS=$((CHECKS+2))
has "G: … and says so on stderr" "keeping the last hub_limits" "$(cat "$WORK/err")"
# their own cadence: the loop asks fleet_sessions every 2s while watched (#1481),
# the summaries keep the 10s pace — a stamp of the last attempt, hit or miss
: > "$WORK/ncalls"; rm -f "$G/hubsum.ts"
NCMD="echo n >> '$WORK/ncalls'; cat '$WORK/nodes.json'" SEVERY=10 hubs; NCMD="echo n >> '$WORK/ncalls'; cat '$WORK/nodes.json'" SEVERY=10 hubs
eq "G: two rounds inside FLEET_HUB_SUMMARY_EVERY fetch the summaries once" 1 "$(grep -c . "$WORK/ncalls")"
printf '%s\n' $(( $(date +%s) - 11 )) > "$G/hubsum.ts"
NCMD="echo n >> '$WORK/ncalls'; cat '$WORK/nodes.json'" SEVERY=10 hubs
eq "G: … and again once the stamp is older than it" 2 "$(grep -c . "$WORK/ncalls")"
# a connection-certificate identity (#1502): no seams, a hub URL, a valid
# certificate — the round asks POST /v1/fleet/summary ONCE for both summaries and
# never spends the viewer token; refused (401) → the two viewer routes with the
# token; no answer at all → nothing, the token untouched. curl / ssh-keygen are
# shims on a PATH of this leg's own; nothing reaches a network.
CB="$WORK/certbin"; mkdir -p "$CB"
for f in hub_nodes hub_limits hubsum.ts; do cp -p "$G/$f" "$WORK/$f.pre" 2>/dev/null; done   # the legs below read these
: > "$WORK/cert"; printf 'ssh-ed25519-cert-v01@openssh.com AAAA test\n' > "$WORK/cert-cert.pub"
cat > "$CB/ssh-keygen" <<'EOF'
#!/bin/sh
case "$1" in -L) printf '        Valid: forever\n' ;; -Y) cat >/dev/null; printf -- '-----BEGIN SSH SIGNATURE-----\nx\n-----END SSH SIGNATURE-----\n' ;; esac
EOF
cat > "$CB/curl" <<EOF
#!/bin/sh
out=''; url=''; auth=''; prev=''
for a in "\$@"; do
  [ "\$prev" = -o ] && out=\$a
  case "\$a" in http*) url=\$a ;; Authorization:*) auth=token ;; esac
  [ "\$prev" = -K ] && [ "\$a" = - ] && grep -q Authorization && auth=token   # the bearer on stdin (#2630)
  prev=\$a
done
printf '%s %s\n' "\${url#http://hub.test}" "\${auth:-cert}" >> '$WORK/curl.log'
case "\$url" in
  */v1/fleet/summary) code=\$(cat '$WORK/sumcode'); [ "\$code" = 200 ] && cat '$WORK/summary.json' > "\$out"; printf '%s' "\$code" ;;
  */v1/fleet/fleet_sessions*) cat '$WORK/sessions.json' > "\$out"; printf 200 ;;
  */v1/nodes) cat '$WORK/nodes.json' ;;
  */v1/limits*) cat '$WORK/limits.json' ;;
esac
EOF
chmod +x "$CB/ssh-keygen" "$CB/curl"
python3 - "$WORK/nodes.json" "$WORK/limits.json" > "$WORK/summary.json" <<'PY2'
import json, sys
n, l = (json.load(open(p)) for p in sys.argv[1:3])
print(json.dumps({"at": "x", "machines": n["machines"], "per_account": l["per_account"][:1]}))
PY2
chubs() { TMPDIR="$T/" FLEET_CONF_DIR="$CONF" FLEET_ACCOUNTS_DIR="$ACC" PATH="$CB:$WORK/bin:$PATH" CCQUOTA_FLEET=1 \
          CCQUOTA_HUB_URL=http://hub.test FLEET_CERT="$WORK/cert" CCQUOTA_VIEWER_TOKEN=tok FLEET_HUB_SUMMARY_EVERY=0 \
          FLEET_NODE_ALIASES="mac-c=mac-b mac-d=mac-a" bash "$HUBS" --refresh 2>"$WORK/err"; }
rm -f "$G/hub_nodes" "$G/hub_limits" "$G/hubsum.ts"; : > "$WORK/curl.log"; echo 200 > "$WORK/sumcode"
chubs || fail "G: a certificate round failed" "$(cat "$WORK/err")"
eq "G: a certificate asks the summary door once, the token never (#1502)" "/v1/fleet/summary cert" "$(grep -v fleet_sessions "$WORK/curl.log")"
rows=$(tr '\037' '|' < "$G/hub_nodes" 2>/dev/null)
has "G: … hub_nodes from its machines: mac-b" "mac-b|online|5.65|" "$rows"
has "G: … and mac-a" "mac-a|lost|" "$rows"
has "G: … hub_limits from its per_account: the person's account" "icloud|63|65|7a7e6173" "$(tr '\037' '|' < "$G/hub_limits" 2>/dev/null)"
left=''; for f in "$G"/hubsummary.*; do [ -e "$f" ] && left=$f; done
eq "G: … and its body is not left behind" "" "$left"
rm -f "$G/hub_nodes" "$G/hub_limits"; : > "$WORK/curl.log"; echo 401 > "$WORK/sumcode"
chubs
eq "G: a refused certificate falls back to the viewer routes with the token" "/v1/fleet/summary cert
/v1/nodes token
/v1/limits?account=all token" "$(grep -v fleet_sessions "$WORK/curl.log")"
has "G: … says so" "refused the connection certificate" "$(cat "$WORK/err")"
has "G: … and writes the summaries" "mac-b|online" "$(tr '\037' '|' < "$G/hub_nodes" 2>/dev/null)"
rm -f "$G/hub_nodes" "$G/hub_limits"; : > "$WORK/curl.log"; echo 000 > "$WORK/sumcode"
chubs
eq "G: a hub that does not answer is no answer — the token is not spent" "/v1/fleet/summary cert" "$(grep -v fleet_sessions "$WORK/curl.log")"
[ -e "$G/hub_nodes" ] && fail "G: no answer wrote hub_nodes"; CHECKS=$((CHECKS+1))
for f in hub_nodes hub_limits hubsum.ts; do rm -f "$G/$f"; cp -p "$WORK/$f.pre" "$G/$f" 2>/dev/null; done

# G2 (issue #2692): /v1/fleet/summary has no `nodes` — a machine carries its own
# fleet_version there, and the row reads it (it used to read "no version reported").
cp -p "$G/hub_nodes" "$WORK/hub_nodes.g2" 2>/dev/null
cat > "$WORK/summary-nodes.json" <<EOF
{"at":"x","machines":[
 {"hostname":"mac-c","status":"online","sessions":14,"load1":5.65234375,"ncpu":15,"mem_free_bytes":29886201856,"mem_total_bytes":68719476736,"last_heartbeat":"$HB","fleet_version":"$C2"},
 {"hostname":"mac-d","status":"online","sessions":0,"load1":1,"ncpu":10,"mem_free_bytes":1,"mem_total_bytes":2,"last_heartbeat":"$HB"}]}
EOF
NCMD="cat '$WORK/summary-nodes.json'" hubs || fail "G2: --refresh failed" "$(cat "$WORK/err")"
g2=$(tr '\037' '|' < "$G/hub_nodes")
eq "G2: the machine's own fleet_version → column 7, judged ok" "$C2|ok" "$(printf '%s\n' "$g2" | awk -F'|' '$1 == "mac-b" { print $7 "|" $11 }')"
eq "G2: a machine with none → empty, never guessed" "|" "$(printf '%s\n' "$g2" | awk -F'|' '$1 == "mac-a" { print $7 "|" $11 }')"
rm -f "$G/hub_nodes"; cp -p "$WORK/hub_nodes.g2" "$G/hub_nodes" 2>/dev/null

# ---- H: the age words
. "$BIN/fleet-status-lib.sh"
fleet_status_age 59; eq "H: 59s → 0m" 0m "$FSA"; fleet_status_age 7199; eq "H: 7199s → 119m" 119m "$FSA"
fleet_status_age 7200; eq "H: 2h" 2h "$FSA"; fleet_status_age 172800; eq "H: 2d" 2d "$FSA"; fleet_status_age x; eq "H: junk → 0m" 0m "$FSA"

printf 'fleet-status-lib-selftest: OK (%d checks) — the hub summaries on disk, the age words\n' "$CHECKS"
