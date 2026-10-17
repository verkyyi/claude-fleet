#!/bin/bash
# fleet-idle-daily-selftest.sh — bin/fleet-idle-daily.py, the diskguard tick's
# idle_daily_watch (bin/fleet-diskguard.sh) and the doctor's daily suffix
# (bin/fleet-doctor.sh) — issue #4361, EPIC #4354 C7.
#
#   A  a fake idle reading over the threshold ⇒ ONE issue (the marker
#      fleet:idle-cost node= day= in its body, the three sources listed), the
#      ndjson line carries it; a second try the same day files nothing — neither
#      the done day (--force) nor a lost day file (the filed record)
#   B  another login already filed it (the marker in the repo's issues) ⇒ no filing,
#      its URL kept
#   C  busy all day ⇒ the next day's first try writes ONE 「未量」 line for it
#      (state unmeasured, the busy reason), then measures the new day
#   D  under the threshold ⇒ a reading, no issue; not a host ⇒ nothing measured
#   E  the filer fails ⇒ the reading is kept and the filing retried on the next try
#   F  lines older than the keep window go; show / summary read the same file
#   G  idle_daily_watch: a gate in the future runs nothing; a gate passed runs one
#      detached try that lands in the ndjson
#
# All seams fake: no real measurement, no GitHub, no real repo. A sandbox
# FLEET_CONF_DIR; TZ pinned so the days are fixed.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PY="$BIN/fleet-idle-daily.py"
DG="$BIN/fleet-diskguard.sh"
for f in "$PY" "$DG"; do [ -f "$f" ] || { echo "selftest: $f not found" >&2; exit 2; }; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/idle-daily-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC
export FLEET_IDLE_DAILY_NODE=testbox
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# fakes: the measure prints $WORK/cost.json and exits $WORK/cost.rc; the filer logs
# its argv (one record a call) and prints a URL unless $WORK/file.fail exists; gh
# prints $WORK/gh.json
cat > "$WORK/cost" <<'EOF'
#!/bin/bash
cat "$(dirname "$0")/cost.json"; exit "$(cat "$(dirname "$0")/cost.rc" 2>/dev/null || echo 0)"
EOF
cat > "$WORK/filer" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/filed.log"; echo "---" >> "$d/filed.log"
[ -f "$d/file.fail" ] && exit 1
n=$(grep -c '^---$' "$d/filed.log"); echo "https://github.com/o/r/issues/$((900 + n))"
EOF
cat > "$WORK/gh" <<'EOF'
#!/bin/bash
cat "$(dirname "$0")/gh.json" 2>/dev/null || echo '[]'
EOF
printf '#!/bin/sh\necho "${FAKE_HOST:-1}"\n' > "$WORK/host"
chmod +x "$WORK/cost" "$WORK/filer" "$WORK/gh" "$WORK/host"
export FLEET_IDLE_DAILY_COST_CMD="$WORK/cost" FLEET_IDLE_DAILY_FILE_CMD="$WORK/filer"
export FLEET_IDLE_DAILY_GH="$WORK/gh" FLEET_IDLE_DAILY_HOST_CMD="$WORK/host"

reading() {  # rate → an idle reading
  printf '{"ts": %s, "host": "testbox", "state": "idle", "secs": 60.0, "new": 1, "method": "pid", "rate": %s, "fleet_cpu_pct": 3.1, "load": [1.0, 1.1, 1.2], "cores": 10, "spawn_top": [{"rank": 1, "rate": 40.0, "who": "spinner-a"}, {"rank": 2, "rate": 9.0, "who": "relay-b"}, {"rank": 3, "rate": 2.0, "who": "tick-c"}, {"rank": 4, "rate": 1.0, "who": "fourth-d"}]}\n' \
    "${2:-1792224000}" "$1" > "$WORK/cost.json"; echo 0 > "$WORK/cost.rc"
}
busyr() { printf '{"ts": 1, "state": "busy", "reason": "%s"}\n' "$1" > "$WORK/cost.json"; echo 3 > "$WORK/cost.rc"; }
fresh() { export FLEET_CONF_DIR="$WORK/conf-$1"; rm -f "$WORK/filed.log" "$WORK/file.fail" "$WORK/gh.json"; }
nd() { cat "$FLEET_CONF_DIR/global/idle-cost.ndjson" 2>/dev/null; }
calls() { grep -c '^---$' "$WORK/filed.log" 2>/dev/null || echo 0; }
D1=1792224000            # 2026-10-17 08:00 UTC (+ hours below)
T1=$((D1 + 3600 * 10)); T2=$((D1 + 86400 + 3600 * 9))

# --- A ----------------------------------------------------------------------
fresh a; reading 120
FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" tick --repo o/r >/dev/null
[ "$(calls)" = 1 ] && ok "A1 over the threshold ⇒ one issue filed" || bad "A1 one filing" "calls=$(calls)"
grep -q 'fleet:idle-cost node=testbox day=2026-10-17' "$WORK/filed.log" && grep -q 'spinner-a' "$WORK/filed.log" \
  && grep -q 'tick-c' "$WORK/filed.log" && ! grep -q 'fourth-d' "$WORK/filed.log" \
  && ok "A2 the body carries the marker and the top three sources" || bad "A2 body" "$(cat "$WORK/filed.log")"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert len(r)==1 and r[0]["state"]=="idle" and r[0]["over"] and r[0]["issue"].endswith("/901") and r[0]["day"]=="2026-10-17"' \
  "$FLEET_CONF_DIR/global/idle-cost.ndjson" 2>/dev/null && ok "A3 one ndjson line: the reading and its issue" || bad "A3 ndjson" "$(nd)"
FLEET_IDLE_DAILY_NOW=$((T1 + 3600)) python3 "$PY" tick --repo o/r --force >/dev/null
rm -f "$FLEET_CONF_DIR/global/idle-cost.day.json"
FLEET_IDLE_DAILY_NOW=$((T1 + 7200)) python3 "$PY" tick --repo o/r >/dev/null
[ "$(calls)" = 1 ] && [ "$(nd | wc -l | tr -d ' ')" = 1 ] && ok "A4 the same day again (done · day file lost) ⇒ no second issue, one line" \
  || bad "A4 same-day dedupe" "calls=$(calls) lines=$(nd | wc -l)"

# --- B ----------------------------------------------------------------------
fresh b; reading 99
printf '[{"html_url": "https://github.com/o/r/issues/77", "body": "x\\n<!-- fleet:idle-cost node=testbox day=2026-10-17 -->"}]\n' > "$WORK/gh.json"
FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" tick --repo o/r >/dev/null
[ "$(calls)" = 0 ] && nd | grep -q 'issues/77' && ok "B  another login's issue (the marker) ⇒ no filing, its URL kept" \
  || bad "B  remote dedupe" "calls=$(calls) $(nd)"

# --- C ----------------------------------------------------------------------
fresh c; busyr "working: 2 session(s)"
FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" tick --repo o/r >/dev/null
FLEET_IDLE_DAILY_NOW=$((T1 + 1000)) python3 "$PY" tick --repo o/r >/dev/null
[ -z "$(nd)" ] && ok "C1 busy ⇒ no line yet" || bad "C1 busy wrote" "$(nd)"
reading 5 "$T2"
FLEET_IDLE_DAILY_NOW=$T2 python3 "$PY" tick --repo o/r >/dev/null
python3 -c '
import json,sys
r=[json.loads(l) for l in open(sys.argv[1])]
assert len(r)==2, r
assert r[0]["day"]=="2026-10-17" and r[0]["state"]=="unmeasured" and "working: 2" in r[0]["reason"] and r[0]["tries"]==2, r[0]
assert r[1]["day"]=="2026-10-18" and r[1]["state"]=="idle" and not r[1]["over"], r[1]
' "$FLEET_CONF_DIR/global/idle-cost.ndjson" 2>"$WORK/err" && ok "C2 a day never idle ⇒ one 「未量」 line with the reason; the next day measured" \
  || bad "C2 unmeasured" "$(cat "$WORK/err"; nd)"

# --- D ----------------------------------------------------------------------
fresh d; reading 12
FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" tick --repo o/r >/dev/null
[ "$(calls)" = 0 ] && nd | grep -q '"over": false' && ok "D1 under the threshold ⇒ a reading, no issue" || bad "D1 under" "$(nd)"
fresh d2; reading 120
FAKE_HOST=0 FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" tick --repo o/r >/dev/null
[ -z "$(nd)" ] && [ "$(calls)" = 0 ] && ok "D2 not a host ⇒ nothing measured" || bad "D2 not host" "$(nd)"

# --- E ----------------------------------------------------------------------
fresh e; reading 120; touch "$WORK/file.fail"
FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" tick --repo o/r >/dev/null
rm -f "$WORK/file.fail"
FLEET_IDLE_DAILY_NOW=$((T1 + 1000)) python3 "$PY" tick --repo o/r >/dev/null
FLEET_IDLE_DAILY_NOW=$((T1 + 2000)) python3 "$PY" tick --repo o/r >/dev/null
[ "$(calls)" = 2 ] && [ "$(nd | wc -l | tr -d ' ')" = 1 ] && nd | grep -q 'issues/902' \
  && ok "E  a failed filing is retried once, then the line carries the issue" || bad "E  retry" "calls=$(calls) $(nd)"

# --- F ----------------------------------------------------------------------
fresh f; mkdir -p "$FLEET_CONF_DIR/global"
printf '{"day": "2026-09-01", "node": "testbox", "state": "idle", "rate": 1}\n{"day": "2026-10-16", "node": "testbox", "state": "unmeasured", "reason": "busy"}\n' \
  > "$FLEET_CONF_DIR/global/idle-cost.ndjson"
reading 3
FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" tick >/dev/null
! nd | grep -q 2026-09-01 && [ "$(nd | wc -l | tr -d ' ')" = 2 ] && ok "F1 a line past the 30-day window goes" || bad "F1 prune" "$(nd)"
s=$(FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" summary --days 7)
[ "$s" = "$(printf '1\t1\t2026-10-17\t3')" ] && ok "F2 summary: 1 measured · 1 unmeasured · last 2026-10-17 at 3" || bad "F2 summary" "$s"
FLEET_IDLE_DAILY_NOW=$T1 python3 "$PY" show | grep -q "^2026-10-16	unmeasured	busy" && ok "F3 show lists the 「未量」 day" || bad "F3 show"

# --- G ----------------------------------------------------------------------
fresh g; mkdir -p "$FLEET_CONF_DIR/global" "$FLEET_CONF_DIR/diskguard"; reading 4 "$(date +%s)"
(
  # shellcheck source=/dev/null
  FLEET_DISKGUARD_SOURCE=1 . "$DG"
  fleet_sockets() { :; }
  echo $(( $(date +%s) + 3600 )) > "$FLEET_CONF_DIR/global/idle-cost.gate"
  idle_daily_watch; sleep 1
  [ ! -s "$FLEET_CONF_DIR/diskguard/idle-daily.log" ] && [ -z "$(nd)" ] && echo G1ok
  echo 1 > "$FLEET_CONF_DIR/global/idle-cost.gate"
  idle_daily_watch
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(nd)" ] && break; sleep 0.5; done
  nd | grep -q '"state": "idle"' && grep -q 'idle-daily	idle' "$FLEET_CONF_DIR/diskguard/idle-daily.log" && echo G2ok
  g=$(cat "$FLEET_CONF_DIR/global/idle-cost.gate"); [ "$g" -gt "$(date +%s)" ] && echo G3ok
) > "$WORK/g.out" 2>&1
grep -q G1ok "$WORK/g.out" && ok "G1 the tick's gate in the future ⇒ nothing runs" || bad "G1 gate closed" "$(cat "$WORK/g.out")"
grep -q G2ok "$WORK/g.out" && ok "G2 the gate passed ⇒ one detached try lands in the ndjson" || bad "G2 tick ran" "$(cat "$WORK/g.out")"
grep -q G3ok "$WORK/g.out" && ok "G3 a day measured closes the gate till tomorrow" || bad "G3 gate reset" "$(cat "$WORK/g.out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
