#!/bin/bash
# fleet-trial-egress-selftest.sh — a trial login's way out (WACK C3):
# bin/fleet_trial_egress.py, the root core's `egress` op (bin/fleet-node-core.py,
# bin/fleet_node_core.py) and the supervisor's pass (bin/fleet-node-supervisor.py
# egress_pass / egress_ctx), against a fake pfctl in a sandbox — never the
# machine's pf.
#
#   A  off (the default): no rule is loaded, nothing hooked, no logger
#   B  block: the trial uid's TCP / UDP reaches only the allowlist (+ the hub, DNS),
#      mail ports refused, its refusals logged; the member's and the admin's uids
#      are in no rule — an admin the hub lists anyway is skipped (not managed)
#   C  log: the same rules pass instead of block, still logged
#   D  back to off: the anchor is flushed (`-a fleet-trial -s rules` prints
#      nothing), the pf reference given back, the logger stopped
#   E  a recycled login (gone from the hub's list) leaves the anchor in one pass;
#      a hub not heard from past FLEET_TRIAL_EGRESS_STALE_SECS flushes it
#   F  pflog lines → egress-deny.log lines (the anchor's numbering, both spellings)
#   G  FLEET_TRIAL_EGRESS in machine.env overrides the hub's mode on the machine
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_sandbox "${TMPDIR:-/tmp}/trial-egress.XXXXXX"

# fake pfctl: the anchor and the main ruleset are files under $PFDIR
mkdir -p "$WORK/pf" "$WORK/state" "$WORK/log" "$WORK/rt/conf"
cat > "$WORK/pfctl" <<'SH'
#!/bin/bash
d="$PFDIR"; a="$*"
printf '%s\n' "$a" >> "$d/calls"
case "$a" in
  "-a fleet-trial -s rules") grep -v '^table ' "$d/anchor" 2>/dev/null ;;
  "-a fleet-trial -vv -s rules") grep -v '^table ' "$d/anchor" 2>/dev/null | awk '{gsub(/user /, "user = "); print "@" NR-1 " " $0}' ;;
  "-a fleet-trial -f -") cat > "$d/anchor" ;;
  "-a fleet-trial -F all") : > "$d/anchor" ;;
  "-s rules") cat "$d/main" 2>/dev/null ;;
  "-f -") cat > "$d/main" ;;
  "-E") echo "pf enabled" >&2; echo "Token : 4242" >&2 ;;
  "-X "*) rm -f "$d/enabled" ;;
  "-s References") cat "$d/refs" 2>/dev/null ;;
  *) echo "fake pfctl: $a" >&2; exit 1 ;;
esac
SH
printf '#!/bin/sh\nexec sleep 300\n' > "$WORK/tcpdump"
printf '#!/bin/sh\nexit 0\n' > "$WORK/ifconfig"
chmod +x "$WORK/pfctl" "$WORK/tcpdump" "$WORK/ifconfig"
printf 'scrub-anchor "com.apple/*"\nanchor "com.apple/*"\n' > "$WORK/pf.conf"
printf 'github.com\n10.9.0.0/16\nnot a host!\n' > "$WORK/rt/conf/trial-egress.allow"
printf '{"github.com": ["140.82.112.3"], "hub.example.com": ["203.0.113.7"]}\n' > "$WORK/resolve.json"
printf 'CCQUOTA_HUB_URL=https://hub.example.com\nCCQUOTA_TOKEN=x\n' > "$WORK/state/machine.env"

export PFDIR="$WORK/pf" FLEET_PFCTL="$WORK/pfctl" FLEET_TCPDUMP="$WORK/tcpdump" FLEET_IFCONFIG="$WORK/ifconfig" \
  FLEET_PF_CONF="$WORK/pf.conf" FLEET_TRIAL_EGRESS_RESOLVE="$WORK/resolve.json" WORK BIN
unset FLEET_TRIAL_EGRESS

python3 - <<'PY' || st_fail "trial egress" "see above"
import json, os, sys, time
W, BIN = os.environ["WORK"], os.environ["BIN"]
sys.path.insert(0, BIN)
import fleet_trial_egress as eg

fails = []
def check(leg, ok, why):
    print(("ok   " if ok else "FAIL ") + leg + ("" if ok else ": " + why))
    if not ok:
        fails.append(leg)

UIDS = {"trial1": 601, "member1": 602, "admin1": 501}
hub = {"answer": ("off", [], "")}
eg.pull = lambda me: hub["answer"]
ctx = eg.Ctx(W + "/state", W + "/log", W + "/rt",
             lambda: dict(l.split("=", 1) for l in open(W + "/state/machine.env").read().split()),
             lambda: ["trial1", "member1"],            # admin1 is never a managed login
             lambda login: UIDS.get(login))
anchor = lambda: open(W + "/pf/anchor").read() if os.path.exists(W + "/pf/anchor") else ""
calls = lambda: open(W + "/pf/calls").read() if os.path.exists(W + "/pf/calls") else ""

# A — off: nothing loaded, nothing hooked
b = eg.converge(ctx)
check("A off loads nothing", anchor() == "" and "-f -" not in calls() and "-E" not in calls(), calls())
check("A off starts no logger", not eg.logger_alive(ctx), "a logger runs")

# B — block over trial1 (the hub also lists admin1: skipped)
hub["answer"] = ("block", ["trial1", "admin1"], "")
b = eg.converge(ctx)
a = anchor()
check("B hooked into the main ruleset", 'anchor "fleet-trial"' in open(W + "/pf/main").read(), calls())
check("B pf enabled by reference", "-E" in calls() and b.get("token") == "4242", str(b))
check("B allow table: list + hub, unresolvable left out",
      "table <fleet_trial_allow> const { 140.82.112.3, 10.9.0.0/16, 203.0.113.7 }" in a, a)
check("B mail ports refused before the allowlist",
      a.index("port { 25 465 587 } user 601") < a.index("to <fleet_trial_allow> user 601")
      and "block return out log quick on ! lo0 proto { tcp udp } to any port { 25 465 587 } user 601" in a, a)
check("B allowlist + DNS pass", "pass out quick on ! lo0 proto { tcp udp } to <fleet_trial_allow> user 601" in a
      and "port 53 user 601" in a, a)
check("B everything else refused and logged", a.rstrip().endswith("block return out log quick on ! lo0 proto { tcp udp } all user 601"), a)
check("B member and admin untouched", "602" not in a and "501" not in a and "user 6" in a, a)
check("B admin skipped, named", b.get("skipped") == ["admin1"] and b.get("logins") == ["trial1"], str(b))
check("B unusable allowlist line named", "not a host!" in b.get("note", ""), str(b))
m = json.load(open(W + "/state/trial-egress.map.json"))
check("B rule map: logged rules → uid", set(m["rules"].values()) == {601} and m["names"] == {"601": "trial1"}, str(m))
check("B logger running", bool(eg.logger_alive(ctx)), "no logger")
n_loads = calls().count("-a fleet-trial -f -")
eg.converge(ctx)
check("B the same list reloads nothing", calls().count("-a fleet-trial -f -") == n_loads, calls())

# C — log: same shape, pass instead of block
hub["answer"] = ("log", ["trial1"], "")
eg.converge(ctx)
a = anchor()
check("C log passes and logs", "block" not in a and a.rstrip().endswith("pass out log quick on ! lo0 proto { tcp udp } all user 601"), a)

# D — back to off: flushed, reference given back, logger gone
open(W + "/pf/refs", "w").write("4242\n")
hub["answer"] = ("off", [], "")
b = eg.converge(ctx)
check("D off flushes the anchor", anchor() == "" and "-a fleet-trial -F all" in calls(), calls())
check("D off gives the reference back", "-X 4242" in calls() and not b.get("token"), str(b))
time.sleep(0.2)
check("D off stops the logger", not eg.logger_alive(ctx), "logger still running")

# E — recycled: gone from the list ⇒ gone from the anchor; stale hub ⇒ flushed
hub["answer"] = ("block", ["trial1"], "")
eg.converge(ctx)
check("E block again", "user 601" in anchor(), anchor())
hub["answer"] = ("block", [], "")
eg.converge(ctx)
check("E recycled login leaves within one pass", anchor() == "", anchor())
hub["answer"] = ("block", ["trial1"], "")
eg.converge(ctx)
hub["answer"] = (None, None, "the hub: 503")
os.environ["FLEET_TRIAL_EGRESS_STALE_SECS"] = "900"
b = eg.converge(ctx)
check("E a fresh last list holds while the hub is away", "user 601" in anchor(), str(b))
b = eg.converge(ctx, t=time.time() + 901)
check("E a stale list flushes (open, the default)", anchor() == "" and "stale" in b.get("note", ""), str(b))

# F — pflog → egress-deny.log
m = {"7": 601}
names = {"601": "trial1"}
l1 = eg.parse_pflog("2026-10-21 10:00:01.123456 rule 0.fleet-trial.7/0(match): block out on en0: "
                    "192.168.1.5.50123 > 93.184.215.14.443: Flags [S], seq 1, win 65535, length 0", m, names)
check("F block line", l1 == "2026-10-21T10:00:01Z deny trial1 uid=601 tcp 93.184.215.14:443", str(l1))
l2 = eg.parse_pflog("2026-10-21 10:00:02.5 rule 7/0(match): pass out on en0: 10.0.0.2.5353 > 1.1.1.1.25: UDP, length 30", m, names)
check("F pass (log mode) line", l2 == "2026-10-21T10:00:02Z would-deny trial1 uid=601 udp 1.1.1.1:25", str(l2))
check("F another anchor's rule is not ours",
      eg.parse_pflog("2026-10-21 10:00:03.1 rule 0.com.apple.7/0(match): block out on en0: 1.2.3.4.1 > 5.6.7.8.80: Flags [S]", m, names) is None, "matched")
check("F rule map off -vv", eg.rule_map("@0 block return out log quick on ! lo0 proto tcp all user = 601\n@1 pass out quick all user = 601\n")
      == {"0": 601}, "map")

# G — machine.env's FLEET_TRIAL_EGRESS wins on the machine
hub["answer"] = ("off", ["trial1"], "")
with open(W + "/state/machine.env", "a") as f:
    f.write("FLEET_TRIAL_EGRESS=block\n")
eg.converge(ctx)
check("G machine.env block over the hub's off", "user 601" in anchor(), anchor())
with open(W + "/state/machine.env", "w") as f:
    f.write("CCQUOTA_HUB_URL=https://hub.example.com\nCCQUOTA_TOKEN=x\nFLEET_TRIAL_EGRESS=off\n")
hub["answer"] = ("block", ["trial1"], "")
eg.converge(ctx)
check("G machine.env off over the hub's block", anchor() == "", anchor())
eg.logger_stop(ctx)
sys.exit(1 if fails else 0)
PY

# the op is on the core's table, with no args — nothing about the list rides the socket
python3 - "$BIN" <<'PY' || st_fail "core op table"
import sys
sys.path.insert(0, sys.argv[1])
import fleet_node_core as w
assert w.OPS.get("egress") == {}, w.OPS.get("egress")
PY
grep -q 'def op_egress' "$BIN/fleet-node-core.py" || st_fail "core" "no op_egress in fleet-node-core.py"
grep -q 'self.tend_egress(t)' "$BIN/fleet-node-supervisor.py" || st_fail "supervisor" "the pass is not on the daemon's loop"
st_ok "core op egress + the daemon's pass"
echo "fleet-trial-egress-selftest: PASS"
