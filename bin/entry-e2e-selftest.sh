#!/bin/bash
# entry-e2e-selftest.sh — EPIC #3067 end to end (issue #3076, C10): a phone with
# no Tailscale adds a key → lands in the 看台 → the hub goes away and it still
# gets in → the key is revoked and the door refuses it; a Mac with no Tailscale
# picks the LAN at home and the person's address outside, never the relay. Then
# every BREAK-IT row the batch added (共同约定 10: entry-* · route-lan-elsewhere),
# each run by the drill file that owns it.
#
# The rig is bin/fleet-break-it-entry-selftest.sh's, sourced (BREAK_ENTRY_LIB=1):
# the real entry sshd as `fleet-node-supervisor.py run`'s child in a sandbox state
# dir on 127.0.0.1, a fake passwd, the system sshd and ~/.ssh checked byte for
# byte. The hub is a stand-in serving GET /v1/node/entry-keys in the hub's own
# shape (the node pulls it with `entry pull`, as `ccquota agent --machine` does on
# a push); the hub's halves — the keys page, the push to the home only, the DNS
# loop on a fake DNSPod, the reach probe, a device key on the door — are its Go
# tests, which the drills below run where a toolchain is (tokenledger.yml always).
# The two clients are bin/fleet-connect.py with this computer's addresses and
# network faked (FLEET_CONNECT_LOCAL_ADDRS / FLEET_CONNECT_NET_KEY, no 100.64/10:
# no Tailscale), and the outside one's ssh argv is RUN into the entry port.
#
#   chain   phone-adds-key · phone-lands · hub-down-still-in · revoke-refused (×5,
#           the median is the batch's ≤ 10 s metric) · mac-home-lan · mac-outside-entry
#   drills  every `entry-*` / `route-lan-elsewhere` row of docs/dev/BREAK-IT.md, by id
#
# Ends with the batch's metric table (what this rig can read; the rest is the
# drill on the real phone — docs/dev/MULTI-MACHINE-OPS.md «从外面连进来»).
# No sshd ≥ 9.8 / ssh / ssh-keygen → SKIP (exit 0), like the entry drills.
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-entry-selftest.sh
BREAK_ENTRY_LIB=1 . "$BIN/fleet-break-it-entry-selftest.sh"
E2E_ME="$ME"

# ---- the stand-in hub: GET /v1/node/entry-keys answers $E/hub.json; nothing else
hub_up() {   # the same port each time: machine.env names it
  HPORT="${HPORT:-$(free_port)}"
  python3 - "$E/hub.json" "$HPORT" "$E/hub.hits" <<'PY' &
import http.server, sys
lst, port, hits = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        open(hits, "a").write("GET %s\n" % self.path)
        if self.headers.get("Authorization") != "Bearer tok-e2e":
            return self.reply(401, b'{"error":"node token"}')
        if self.path != "/v1/node/entry-keys":
            return self.reply(404, b"{}")
        self.reply(200, open(lst, "rb").read())
    def do_POST(self):
        open(hits, "a").write("POST %s\n" % self.path)
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.reply(200, b'{"ok":true}')
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  HPID=$!; printf '%s\n' "$HPID" >> "$WORK/cred-pids"
  until_ok 5 python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$HPORT" 2>/dev/null
}
hub_down() { kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; }
# keys page: the person's list is now <version> with these keys → $E/hub.json
page() { cp "$(elist "$@")" "$E/hub.json"; }
pull() { python3 "$SUP" entry pull --version "$1" >>"$E/pull.out" 2>&1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %-22s %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); BAD_IDS="$BAD_IDS $1"; printf 'FAIL  %-22s %s\n' "$1" "$2"; }
BAD_IDS=""

# ================================================================= the chain ====
erig e2e
for k in phone mac r1 r2 r3 r4 r5; do ssh-keygen -q -t ed25519 -N '' -C "e2e-$k" -f "$E/$k"; done
mkdir -p "$E/rt/bin" "$E/conf"; ln -s "$BIN/fleet-entry.sh" "$E/rt/bin/fleet-entry.sh"
cat > "$E/view.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/view.args"
echo VIEW-STAND-IN
SH
chmod +x "$E/view.sh"
export FLEET_ENTRY_TEST_SETENV="FLEET_ENTRY_VIEW=$E/view.sh FLEET_CONF_DIR=$E/conf"
hub_up || { echo 'FAIL  stand-in hub never listened'; exit 1; }
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=tok-e2e\nFLEET_ENTRY_PULL_SECS=3\n' "$HPORT" > "$E/db/machine.env"
chmod 600 "$E/db/machine.env"
sshopts=(-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
         -o UserKnownHostsFile="$E/known_hosts" -o ConnectTimeout=5 -o LogLevel=ERROR -p "$EPORT")

# 1. the phone pastes its key on the keys page; the push makes the home pull
t0=$(now)
page 1 "$ME=phone,mac"
if pull 1 && eup && until_ok 10 listening && grep -q "$(cut -d' ' -f2 "$E/phone.pub")" "$E/db/entry/keys/$ME"; then
  ok phone-adds-key "钥匙页加一把 → 家机器拉到 v1、入口端口起来：$(since "$t0")s"
else
  bad phone-adds-key "pull: $(tail -2 "$E/pull.out") · sup: $(tail -2 "$E/sup.err" 2>/dev/null)"
fi

# 2. Termius: no command, a terminal ⇒ the 看台
out=$(ssh "${sshopts[@]}" -tt -i "$E/phone" "$ME@127.0.0.1" </dev/null 2>"$E/ssh.err")
case "$out" in
  *VIEW-STAND-IN*) case "$(head -n 1 "$E/view.args" 2>/dev/null)" in
      "attach --thin --view "*" --resume "*) ok phone-lands "不带命令有终端 ⇒ 看台（attach --thin --resume）" ;;
      *) bad phone-lands "the 看台 was called as [$(head -n 1 "$E/view.args")]" ;; esac ;;
  *) bad phone-lands "[$out] $(cat "$E/ssh.err")" ;;
esac

# 3. the hub goes away and the home restarts: the last list stands
hub_down
kill "$ESUP" 2>/dev/null; wait "$ESUP" 2>/dev/null
until_ok 5 sh -c '! pgrep -f "$1" >/dev/null' _ "$E/db/entry/sshd_config"
pull 2; rc=$?
eup
if [ "$rc" = 1 ] && until_ok 10 listening \
   && ssh "${sshopts[@]}" -tt -i "$E/phone" "$ME@127.0.0.1" </dev/null 2>"$E/ssh.err" | grep -q VIEW-STAND-IN; then
  ok hub-down-still-in "入口停掉、家机器重启：拉名单失败（最后一份 v1 照用），手机照样进看台"
else
  bad hub-down-still-in "pull rc $rc: $(tail -1 "$E/pull.out") · $(cat "$E/ssh.err")"
fi

# 4. revoke on the keys page ⇒ refused, five times; the median is the metric.
# The door is read per connection, so a key is refused from the moment its keys
# file no longer holds it — that moment is what is timed; ONE real ssh attempt
# then proves the refusal (five failed tries from 127.0.0.1 would trip sshd's own
# PerSourcePenalties and block this source — the defence working, not the drill)
hub_up || bad revoke-refused 'the stand-in hub never came back'
page 3 "$ME=phone,mac,r1,r2,r3,r4,r5"; pull 3
for k in r1 r2 r3 r4 r5; do
  ssh "${sshopts[@]}" -i "$E/$k" "$ME@127.0.0.1" true </dev/null 2>/dev/null || bad revoke-refused "$k never got in"
done
v=3; keep="phone,mac,r1,r2,r3,r4,r5"; lat=()
for k in r1 r2 r3 r4 r5; do
  v=$((v + 1)); keep=$(printf '%s' "$keep" | sed "s/,$k//")
  b64=$(cut -d' ' -f2 "$E/$k.pub")
  t0=$(now)
  page "$v" "$ME=$keep"; pull "$v" & ppid=$!   # the push → the node's pull
  until_ok 10 sh -c '! grep -q "$1" "$2"' _ "$b64" "$E/db/entry/keys/$ME" \
    && lat+=("$(since "$t0")") || { bad revoke-refused "$k still on the door 10 s after its revoke"; wait "$ppid"; break; }
  wait "$ppid"
done
if [ "${#lat[@]}" -eq 5 ]; then
  MED=$(printf '%s\n' ${lat[@]+"${lat[@]}"} | sort -n | sed -n 3p)
  if ssh "${sshopts[@]}" -i "$E/r5" "$ME@127.0.0.1" true </dev/null 2>"$E/ssh.err"; then
    bad revoke-refused "the revoked r5 still gets in"
  elif ! grep -q 'Permission denied' "$E/ssh.err"; then
    bad revoke-refused "r5: $(cat "$E/ssh.err")"
  elif le "$MED" 10 && ssh "${sshopts[@]}" -i "$E/phone" "$ME@127.0.0.1" true </dev/null 2>/dev/null; then
    ok revoke-refused "撤一把 → 家机器不认它：5 次 ${lat[*]-} 秒，中位 ${MED}s（≤10s），撤掉的得 Permission denied；没撤的照常进"
  else
    bad revoke-refused "median ${MED}s, or the phone's key stopped working"
  fi
fi
grep -q 'GET /v1/node/entry-keys' "$E/hub.hits" || bad revoke-refused "the node never asked the hub"

# 5–6. the Mac, no Tailscale (no 100.64/10 here): home LAN, then a hotspot
mac() {   # <dir> <local addrs> <net key> <lan host> <lan port> → the ssh argv on stdout
  # its routes are the snippet `fleet login` wrote (lan · entry · tailnet); the
  # hub not asked, so no relay line exists here — its last place is
  # fleet-connect-route-selftest.sh's to pin
  local d="$1"; mkdir -p "$d/.ssh" "$d/.cache/claude-fleet" "$d/.config/claude-fleet"
  cp "$E/mac" "$d/.ssh/fleet-cert"
  printf 'Host home fleet-home fleet-home-lan\n  HostName %s\n  Port %s\n  User %s\nHost fleet-home-entry\n  HostName 127.0.0.1\n  Port %s\n  User %s\nHost fleet-home-tailnet\n  HostName 100.101.2.3\n  User %s\n' \
    "$4" "$5" "$E2E_ME" "$EPORT" "$E2E_ME" "$E2E_ME" > "$d/.ssh/fleet-ssh-config"
  env -u FLEET_HUB_URL -u FLEET_HUB_TOKEN HOME="$d" XDG_CACHE_HOME="$d/.cache" XDG_CONFIG_HOME="$d/.config" \
    FLEET_CONF_DIR="$d/.config/claude-fleet" FLEET_CLIENT_LOG=0 FLEET_CONNECT_TIMEOUT=2 FLEET_CONNECT_PROBES=1 \
    FLEET_CONNECT_LOCAL_ADDRS="$2" FLEET_CONNECT_NET_KEY="$3" \
    python3 "$BIN/fleet-connect.py" home --print 2>"$d/err"
}
# a fake sshd for home's LAN line (loopback: always measured)
python3 - "$E/lan.port" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1])); s.settimeout(60)
try:
    while True:
        c, _ = s.accept(); c.sendall(b"SSH-2.0-fake\r\n"); c.close()
except Exception:
    pass
PY
printf '%s\n' "$!" >> "$WORK/cred-pids"
until_ok 5 test -s "$E/lan.port"; LPORT=$(cat "$E/lan.port")
RELAYS=0
out=$(mac "$E/mac-home" "127.0.0.9/8,192.168.1.235/24" "192.168.1.1@192.168.1.0/24" 127.0.0.1 "$LPORT")
case "$out" in
  *"-p $LPORT 127.0.0.1"*) ok mac-home-lan "家里同一局域网：选 lan（入口、Tailscale 都在后面），不绕中转" ;;
  *) bad mac-home-lan "not the LAN line: [$out] $(head -c 300 "$E/mac-home/err")"; RELAYS=$((RELAYS + 1)) ;;
esac
out=$(mac "$E/mac-out" "172.20.10.3/28" "172.20.10.1@172.20.10.0/28" 192.168.1.249 22)
case "$out" in
  *"-p $EPORT 127.0.0.1"*)
    # …and that ssh argv, run, gets into the entry port with the Mac's own key
    read -r -a argv <<< "$out"
    if [ "${argv[0]}" = ssh ] && printf '%s' "$out" | grep -q 'IdentitiesOnly=yes' \
       && ssh -F /dev/null -o BatchMode=yes -o IdentityAgent=none -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile="$E/known_hosts" -o LogLevel=ERROR "${argv[@]:1}" true </dev/null 2>"$E/ssh.err"; then
      ok mac-outside-entry "外面（热点、没 Tailscale）：家里的 lan 不试，选入口直连，用本机钥匙进了入口端口"
    else
      bad mac-outside-entry "the entry argv [$out] did not get in: $(cat "$E/ssh.err")"
    fi ;;
  *) bad mac-outside-entry "not the entry line: [$out] $(head -c 300 "$E/mac-out/err")"; RELAYS=$((RELAYS + 1)) ;;
esac
sys_same || bad system-untouched "$WHY"
hub_down; edown

# ================================================================= the drills ===
ROWS=$(grep -oE '\| `(entry-[a-z0-9-]+|route-lan-elsewhere)` \|$' "$DOC" | tr -d '|` ')
DRILL_PASS=0; DRILL_ALL=0
for f in "$BIN"/fleet-break-it-*-selftest.sh; do
  ids=""
  for r in $ROWS; do grep -q "^drill_$(printf '%s' "$r" | tr - _)() *{" "$f" && ids="$ids $r"; done
  [ -n "$ids" ] || continue
  printf -- '-- %s:%s\n' "$(basename "$f")" "$ids"
  res=$(BREAK_ONLY="$ids" bash "$f" 2>&1); rc=$?
  printf '%s\n' "$res" | sed 's/^/   /'
  for r in $ids; do
    DRILL_ALL=$((DRILL_ALL + 1))
    if printf '%s\n' "$res" | grep -qE "^PASS +$r "; then DRILL_PASS=$((DRILL_PASS + 1)); else bad "$r" "no PASS (rc $rc)"; fi
  done
done
n=$(printf '%s\n' $ROWS | grep -c .)
[ "$DRILL_ALL" -eq "$n" ] || bad drills "$n rows in docs/dev/BREAK-IT.md, $DRILL_ALL with a drill"

# ================================================================= the metrics ==
printf '\n指标（替身能读出的部分）\n'
printf '| 指标 | 读数 | 目标 |\n|---|---|---|\n'
printf '| 撤掉一把钥匙，到家机器不认它（5 次中位） | %ss | ≤ 10 s |\n' "${MED:-?}"
open=0
for r in entry-password entry-other-login entry-revoked-key entry-self-added-key entry-admin-login entry-keys-tampered; do
  case " $BAD_IDS " in *" $r "*) open=$((open + 1)) ;; esac
done
printf '| 不经入口登记也能从入口端口进来的办法 | %s 种（password · other-login · revoked-key · self-added-key · admin-login · keys-tampered 各一条演练） | 0 |\n' "$open"
case " $BAD_IDS " in *" mac-home-lan "*) tl=1 ;; *) tl=0 ;; esac
printf '| 同一局域网时绕经 Tailscale | %s / 1 | 0 |\n' "$tl"
printf '| 没 Tailscale 时绕入口中转的地点（家里 · 外面） | %s / 2 | 0 / 2 |\n' "$RELAYS"
printf '| BREAK-IT 行 | %s / %s PASS | 全部 |\n' "$DRILL_PASS" "$n"
printf '（手机步骤数、App 个数、宽带换地址的 DNS 跟上：真机演练读，见 docs/dev/MULTI-MACHINE-OPS.md「从外面连进来」）\n'

if [ "$FAIL" -gt 0 ]; then
  printf 'entry-e2e selftest: %d FAILED, %d passed\n' "$FAIL" "$PASS" >&2
  exit 1
fi
printf 'entry-e2e selftest: OK (%d legs · %d/%d drills green)\n' "$PASS" "$DRILL_PASS" "$n"
