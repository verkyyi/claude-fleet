#!/bin/bash
# fleet-debug-drill-selftest.sh — bin/fleet-debug-drill.sh (claude-fleet#2895,
# EPIC #2889 C6) without a real machine: a fake hub on 127.0.0.1, sandbox dirs.
#
#   A  usage: no command / a bad scenario / a bad --login are exit 2, and `run`
#      without --yes changes nothing (exit 2, says why)
#   B  check against a hub with none of C1–C5 / C7: RED, exit 1, each member named
#   C  check against a hub that has them all: every member line PASS
#   C2 check against a hub whose code is merged but not deployed (debug switch
#      off, stable behind): no FAIL, each gap a GAP line, NOT DEPLOYED, exit 3
#   H  the client's real words (fleet-ui-lang.sh): the 3-failure question reads y,
#      the stuck page's 「按 d」 reads d, a plain screen nothing
#   D  the page: its four sections, 是什么问题 against each day's cause, 请你做's commands
#   E  the leak count: a bundle with a planted credential counts it, a clean one is 0
#   F  the readings: results.tsv → the EPIC's five readings
#   G  teardown --out: every armed line put back (gate, proxy, sandbox), each
#      uploaded report checked gone on the hub WITH the admin's token (/s/<id>
#      is 404 to anyone else either way); no token = not deleted, exit 1
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
D="$BIN/fleet-debug-drill.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fdd-selftest.XXXXXX") || exit 2
HUBPID=''
hub_stop() { [ -n "$HUBPID" ] || return 0; kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null; HUBPID=''; }
trap 'hub_stop; rm -rf "$T"' EXIT
pass=0
ok()   { pass=$((pass + 1)); }
fail() { printf 'fleet-debug-drill-selftest FAIL: %s\n' "$1" >&2; exit 1; }

# fake_hub <mode none|all|off>: sets port (never in a $(…): the parent must hold its pid)
fake_hub() {
  hub_stop
  rm -f "$T/port"
  python3 - "$1" "$T/port" "$BIN/fleet-ui-lang.sh" <<'PY' >/dev/null 2>&1 &
import http.server, sys
mode, portf, langf = sys.argv[1], sys.argv[2], sys.argv[3]
LANG_REAL = open(langf).read()          # C5's own words, as the client carries them
MAN_ALL = "# manifest\nbin/fleet\nbin/fleet-debug\nbin/fleet-debug-prompt.sh\nbin/fleet_clientlog.py\nconf/secret-shapes.list\nconf/debug-collect.list\n"
# off: the image's pack has every member, stable (client_url) only the first ones
STABLE_HAS = {"bin/fleet", "bin/fleet_clientlog.py", "conf/secret-shapes.list", "conf/debug-collect.list"}
deleted = set()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype="text/plain"):
        b = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def viewer(self): self.send(401, '{"error":"a viewer token is required"}', "application/json")
    def admin(self): return self.headers.get("Authorization") == "Bearer drill-viewer"
    def do_GET(self):
        p = self.path
        if p == "/install/manifest": return self.send(200, "# manifest\nbin/fleet\n" if mode == "none" else MAN_ALL)
        if p == "/version" and mode == "off":
            return self.send(200, '{"client_version":"0123456789ab","client_url":"http://%s/install/stable/0123456789ab"}' % self.headers.get("Host"), "application/json")
        if p.startswith("/install/stable/0123456789ab/"):
            f = p.split("/", 4)[4]
            if f == "bin/fleet-ui-lang.sh": return self.send(200, "x=1\n")
            return self.send(200, "x\n") if f in STABLE_HAS else self.send(404, "")
        if p == "/install/bin/fleet-ui-lang.sh":
            return self.send(200, LANG_REAL if mode == "all" else "x=1\n")
        if p == "/debug": return self.send(200, "#!/bin/sh\necho fleet-debug\n") if mode == "all" else self.send(404, "")
        if p.startswith("/v1/fleet/debug/"):
            return self.send(401, "票无效：请管理员补发\n") if mode == "all" else self.viewer()
        if p.startswith("/s/"):
            return self.send(200, "<h1>远端诊断</h1>") if self.admin() and p[3:] not in deleted else self.send(404, "")
        if p.startswith("/v1/"): return self.viewer()
        self.send(404, "")
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); self.rfile.read(n)
        if self.path == "/v1/fleet/debug/ticket" and mode == "all":
            return self.send(400, "fp 要是这台电脑安装指纹的 SHA-256（64 位十六进制）\n")   # the real hub on the probe's fake fp
        if self.path.startswith("/v1/"): return self.viewer()
        self.send(404, "")
    def do_DELETE(self):
        if mode != "all" or not self.admin(): return self.viewer()
        deleted.add(self.path.rsplit("/", 1)[-1]); self.send(200, '{"deleted":true}', "application/json")
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portf, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  HUBPID=$!
  for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
  [ -s "$T/port" ] || fail 'the fake hub did not start'
  port=$(cat "$T/port")
}

# --- A usage ------------------------------------------------------------------------
bash "$D" >/dev/null 2>&1; [ $? = 2 ] || fail 'A: no command is not exit 2'; ok
bash "$D" run nope --yes --hub http://127.0.0.1:1 >/dev/null 2>&1; [ $? = 2 ] || fail 'A: a bad scenario is not exit 2'; ok
bash "$D" run tls --yes --login 'Bad!' --hub http://127.0.0.1:1 >/dev/null 2>&1; [ $? = 2 ] || fail 'A: a bad --login is not exit 2'; ok
out=$(bash "$D" run all --hub http://127.0.0.1:1 --out "$T/A" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "A: run without --yes exit $rc"; ok
printf '%s' "$out" | grep -q -- '--yes' || fail "A: run without --yes does not say why: $out"; ok
[ ! -e "$T/A" ] || fail 'A: run without --yes wrote its out dir'; ok

# --- B check, nothing there: red, each member named -----------------------------------
fake_hub none
mkdir -p "$T/root/agents"
out=$(FLEET_DEBUG_DRILL_ROOT="$T/root" bash "$D" check --hub "http://127.0.0.1:$port" 2>&1); rc=$?
[ "$rc" = 1 ] || fail "B: check on an empty hub exit $rc: $out"; ok
for m in C1 C2 C3 C4 C5 C7; do
  printf '%s\n' "$out" | grep -Eq "FAIL +$m " || fail "B: $m is not named red: $out"; ok
done
printf '%s\n' "$out" | grep -q '^RED' || fail "B: no RED line: $out"; ok
printf '%s\n' "$out" | grep -Eq 'PASS +C' && fail "B: a member reads PASS on an empty hub: $out"; ok

# --- C check, everything there: each member PASS ------------------------------------------
fake_hub all
: > "$T/root/agents/debugger.md"
out=$(FLEET_DEBUG_DRILL_ROOT="$T/root" bash "$D" check --hub "http://127.0.0.1:$port" 2>&1)
for m in C1 C2 C3 C4 C5 C7; do
  printf '%s\n' "$out" | grep -Eq "FAIL +$m " && fail "C: $m reads red on a full hub: $out"
  printf '%s\n' "$out" | grep -Eq "PASS +$m " || fail "C: $m has no PASS: $out"; ok
done

# --- C2 check, merged but not deployed: GAP lines only, exit 3 --------------------------------
fake_hub off
mkdir -p "$T/root/bin" "$T/root/tokenledger/internal/api"
for f in bin/fleet-debug bin/fleet-debug-prompt.sh tokenledger/internal/api/fleet_debug_ticket.go tokenledger/internal/api/fleet_debug.go; do
  : > "$T/root/$f"
done
out=$(FLEET_DEBUG_DRILL_ROOT="$T/root" bash "$D" check --hub "http://127.0.0.1:$port" 2>&1); rc=$?
[ "$rc" = 3 ] || fail "C2: check on an undeployed hub exit $rc: $out"; ok
printf '%s\n' "$out" | grep -Eq '^ +FAIL +C' && fail "C2: a merged member reads FAIL: $out"; ok
printf '%s\n' "$out" | grep -Eq 'GAP +C2 .*CCQUOTA_FLEET_DEBUG_DIR' || fail "C2: the debug switch is not named: $out"; ok
for m in C3 C5; do
  printf '%s\n' "$out" | grep -Eq "GAP +$m .*not on stable yet \(01234567\)" || fail "C2: $m not named stable-behind: $out"; ok
done
printf '%s\n' "$out" | grep -Eq 'PASS +C7 ' || fail "C2: a file stable has reads other than PASS: $out"; ok
printf '%s\n' "$out" | grep -q '^NOT DEPLOYED' || fail "C2: no NOT DEPLOYED line: $out"; ok

# --- H the client's real words ----------------------------------------------------------
L="$BIN/fleet-ui-lang.sh"
for lang in zh en; do
  q=$(FLEET_UI_LANG=$lang sh "$L" t debug_prompt_q_fmt 3); k=$(FLEET_UI_LANG=$lang sh "$L" t debug_prompt_keys)
  w=$(FLEET_UI_LANG=$lang sh "$L" t debug_prompt_what)
  [ "$(printf 'newcomer%% fleet claude\n\n%s\n%s\n%s \n\n\n' "$q" "$w" "$k" | bash "$D" --ask)" = y ] || fail "H: $lang question not read as y: $q"; ok
  d=$(FLEET_UI_LANG=$lang sh "$L" t debug_stall_key_fmt 40)
  [ "$(printf '正在连接…\n%s\n\n' "$d" | bash "$D" --ask)" = d ] || fail "H: $lang stall key not read as d: $d"; ok
done
[ -z "$(printf 'newcomer%% fleet claude\n连不上\n' | bash "$D" --ask)" ] || fail 'H: a plain screen read as a question'; ok

# --- D the page ---------------------------------------------------------------------------
page() {  # page <cause text>
  cat <<EOF
<html><body><h1>诊断 · abcd2345</h1>
<h2>是什么问题</h2><p>$1</p>
<h2>证据</h2><ul><li>login.log: CERTIFICATE_VERIFY_FAILED</li></ul>
<h2>请你做</h2><ol><li>为什么：用系统自带的 python3<br><code>fleet update</code></li>
<li><code>fleet doctor &amp;&amp; fleet claude</code></li></ol>
<h2>要我们改的</h2><p>无</p></body></html>
EOF
}
page '你电脑上 python3 是 python.org 装的，没有证书库，认不出入口的证书' > "$T/tls.html"
page '你开着的代理软件每隔 1 秒 / 11 秒就把到入口的连接断开' > "$T/conn.html"
page '没有机器肯接：唯一有你登录的机器 CPU 繁忙超过门槛' > "$T/cap.html"
[ "$(bash "$D" --sections < "$T/tls.html" | wc -l | tr -d ' ')" = 4 ] || fail 'D: four sections not found'; ok
sed 's#<h2>证据</h2>#<p>证据</p>#' "$T/tls.html" > "$T/three.html"
[ "$(bash "$D" --sections < "$T/three.html" | wc -l | tr -d ' ')" = 3 ] || fail 'D: a missing section still counted'; ok
for s in tls cap conn; do
  [ "$(bash "$D" --cause "$s" < "$T/$s.html")" = PASS ] || fail "D: the $s page's cause not matched"; ok
done
[ "$(bash "$D" --cause tls < "$T/conn.html")" = FAIL ] || fail 'D: a proxy cause passed for tls'; ok
[ "$(bash "$D" --cause cap < "$T/tls.html")" = FAIL ] || fail 'D: a certificate cause passed for cap'; ok
cmds=$(bash "$D" --section '请你做' code < "$T/tls.html")
[ "$cmds" = "$(printf 'fleet update\nfleet doctor && fleet claude')" ] || fail "D: 请你做's commands: $cmds"; ok

# --- E leaks ------------------------------------------------------------------------------
mkdir -p "$T/E/home" "$T/E/b1" "$T/E/b2" "$T/E/stage"
bash "$D" --plant "$T/E/home" "$T/E/planted" || fail 'E: --plant failed'
[ "$(wc -l < "$T/E/planted" | tr -d ' ')" -ge 7 ] || fail 'E: fewer than seven planted shapes'; ok
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$T/E/planted")" = 600 ] || fail 'E: the planted list is not 0600'; ok
echo 'system: macOS 15' > "$T/E/stage/system.txt"
tar czf "$T/E/b1/clean.tar.gz" -C "$T/E/stage" system.txt
[ "$(bash "$D" --leaks "$T/E/b1" "$T/E/planted" 2>/dev/null)" = 0 ] || fail 'E: a clean bundle counted a leak'; ok
cp "$T/E/home/.config/claude-fleet/hub.json" "$T/E/stage/"
tar czf "$T/E/b2/leaky.tar.gz" -C "$T/E/stage" system.txt hub.json
n=$(bash "$D" --leaks "$T/E/b2" "$T/E/planted" 2>"$T/E/err")
[ "$n" -ge 1 ] || fail "E: a bundle carrying hub.json's token counted $n"; ok
grep -q 'hub.json' "$T/E/err" || fail 'E: the leak does not name its file'; ok
grep -q 'hubtok-drill' "$T/E/err" && fail 'E: the leak line prints the whole value'; ok

# --- F readings ---------------------------------------------------------------------------
mkdir -p "$T/F"
{ printf 'scenario\t布置\t触发\t读页\t复原\tupload_s\tconcluded_s\tcause\tleaks\tasked\n'
  printf 'tls\tPASS\tPASS\tPASS\tPASS\t1000\t1120\tPASS\t0\t1\n'
  printf 'cap\tPASS\tPASS\tPASS\tPASS\t2000\t2200\tPASS\t0\t1\n'
  printf 'conn\tPASS\tPASS\tFAIL\tPASS\t3000\t\tFAIL\t0\t0\n'; } > "$T/F/results.tsv"
r=$(bash "$D" --readings "$T/F")
printf '%s\n' "$r" | grep -q '| 诊断页给对修法（机判） | 2 / 3 |' || fail "F: 给对修法: $r"; ok
printf '%s\n' "$r" | grep -q '| 已上传 → 已出结论（最长） | 200s |' || fail "F: 最长: $r"; ok
printf '%s\n' "$r" | grep -q '| 三次合计 | 320s |' || fail "F: 合计: $r"; ok
printf '%s\n' "$r" | grep -q '| 包里漏掉的密码 | 0 |' || fail "F: 漏掉: $r"; ok
printf '%s\n' "$r" | grep -q '| 群里来回（最多的一次） | 2 |' || fail "F: 来回: $r"; ok
printf '%s\n' "$r" | grep -q '| conn | PASS · PASS · FAIL · PASS | — |' || fail "F: an unconcluded row: $r"; ok

# --- G teardown ---------------------------------------------------------------------------
fake_hub all
mkdir -p "$T/G" "$T/G/sb"
sleep 300 & SPID=$!; disown "$SPID" 2>/dev/null
{ printf 'sandbox %s\n' "$T/G/sb"; printf 'cap %s\n' "$T/G/machine.env"; printf 'proxy %s\n' "$SPID"; } > "$T/G/armed"
printf 'tls\tabcd2345\thttp://127.0.0.1:%s/s/abcd2345\n' "$port" > "$T/G/reports.tsv"
out=$(CCQUOTA_VIEWER_TOKEN=drill-viewer FLEET_DEBUG_DRILL_CAP_DISARM="touch '$T/G/disarmed'" bash "$D" teardown --out "$T/G" --hub "http://127.0.0.1:$port" 2>&1); rc=$?
[ "$rc" = 0 ] || fail "G: teardown exit $rc: $out"; ok
[ -e "$T/G/disarmed" ] || fail 'G: the gate was not put back'; ok
sleep 0.3; kill -0 "$SPID" 2>/dev/null && { kill "$SPID"; fail 'G: the proxy is still running'; }; ok
[ ! -d "$T/G/sb" ] || fail 'G: the sandbox is still there'; ok
[ ! -e "$T/G/armed" ] || fail 'G: armed was not cleared'; ok
printf '%s\n' "$out" | grep -q 'report abcd2345: gone' || fail "G: the report not checked gone: $out"; ok
# the order: newest first — the proxy before the gate before the sandbox
printf '%s\n' "$out" | grep -E '^(stopped|restored|removed)' | head -n 1 | grep -q '^stopped proxy' || fail "G: not undone newest first: $out"; ok
# no admin token: the report cannot be deleted, and the teardown says so (exit 1) —
# never «gone» off an anonymous /s/ 404
printf 'tls\tefgh2345\thttp://127.0.0.1:%s/s/efgh2345\n' "$port" > "$T/G/reports.tsv"
out=$(CCQUOTA_VIEWER_TOKEN='' FLEET_HUB_TOKEN='' bash "$D" teardown --out "$T/G" --hub "http://127.0.0.1:$port" 2>&1); rc=$?
[ "$rc" = 1 ] || fail "G: teardown with no admin token exit $rc: $out"; ok
printf '%s\n' "$out" | grep -q 'efgh2345: not deleted' || fail "G: no token not said: $out"; ok
# a second run with nothing armed is a no-op, still exit 0
rm -f "$T/G/reports.tsv"
FLEET_DEBUG_DRILL_CAP_DISARM=false bash "$D" teardown --out "$T/G" --hub "http://127.0.0.1:$port" >/dev/null 2>&1 \
  || fail 'G: a second teardown is not a no-op'; ok
# a run left armed refuses to start over it
{ printf 'proxy 1\n'; } > "$T/G/armed"
out=$(bash "$D" run tls --yes --out "$T/G" --hub "http://127.0.0.1:$port" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "G: run over a left armed file exit $rc"; ok
printf '%s' "$out" | grep -q 'teardown --out' || fail "G: does not say how to clean it: $out"; ok
rm -f "$T/G/armed"

printf 'fleet-debug-drill-selftest: %s passed\n' "$pass"
