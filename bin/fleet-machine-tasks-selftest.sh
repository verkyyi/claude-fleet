#!/bin/bash
# fleet-machine-tasks-selftest.sh — the machine's ONE reading (issue #3546, EPIC
# #3500 C1): bin/fleet-machine-tasks.py (table · probe · tick), conf/node-tasks.tsv,
# fleet_machine_reading in bin/fleet-lib.sh (fleet_mem_probe · fleet_mem_total_mb ·
# _fleet_load_per_core), the node daemon's machine-reading task and its
# table_machine_units in bin/fleet-node-supervisor.py, and the FLEET_MACHINE_TASKS
# line bin/fleet-install-apply.sh writes. BREAK-IT row per-login-machine-loops.
#
#   A  table --check: green on this tree; a launchd template with no row, a row
#      naming nothing, a machine-table task marked login — each red, named
#   B  the node daemon never runs a unit the table marks `machine` per login
#   C  tick → machine.json (0644, one rename) carrying the probes' own answers
#   D  FLEET_MACHINE_TASKS=off: a fresh reading answers the three probes and the
#      login runs no probe of its own; stale / from the future / an empty value /
#      switch unset ⇒ the probe runs here, byte for byte as before; a copy in the
#      login's own cluster/ wins
#   E  the daemon's machine-reading task (15 s, the seat's), kept off a user pod;
#      install-apply writes and takes back the switch
#   G  a user pod's copy (#3734): the file the node program writes from fleet-ops'
#      reading (tokenledger/agent/node_cluster_reading.go
#      renderMachineReading) is fleet-machine-tasks.py's render, byte for byte,
#      and the reader takes it
#   F  class session (#3671): the spinner serves only a login's sessions — the
#      daemon runs it only while it has one; class worker (#4231) has no unit left
#      since #4899; a session row on a machine-table task
#      is red; bin/fleet-node-supervisor-selftest.py V (session units, a restart
#      adopts instead of doubling, an orphaned copy stops, a task is not doubled)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/machine-tasks-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
MT="$BIN/fleet-machine-tasks.py"

# ---- A: the table -----------------------------------------------------------
out=$(python3 "$MT" table --check "$ROOT" 2>&1) && ok "A table --check green on this tree" || bad "A table --check on this tree: $out"
fake="$WORK/root"; mkdir -p "$fake/conf" "$fake/launchd" "$fake/bin"
cp "$ROOT/conf/node-tasks.tsv" "$fake/conf/"; cp "$ROOT/launchd/"*.tmpl "$fake/launchd/"
cp "$BIN/fleet-node-supervisor.py" "$fake/bin/"
: > "$fake/launchd/com.claude-fleet.newloop.plist.tmpl"
out=$(python3 "$MT" table --check "$fake" 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'newloop: launchd template with no row' \
  && ok "A a new launchd template with no row is red, named" || bad "A new template unflagged (rc $rc): $out"
rm -f "$fake/launchd/com.claude-fleet.newloop.plist.tmpl"
printf 'ghost\tunit\tlogin\tnothing\n' >> "$fake/conf/node-tasks.tsv"
out=$(python3 "$MT" table --check "$fake" 2>&1)
printf '%s' "$out" | grep -q 'ghost: row names no launchd template' && ok "A a row naming nothing is red" || bad "A ghost row unflagged: $out"
cp "$ROOT/conf/node-tasks.tsv" "$fake/conf/"
sed -i.bak 's/^orphans	machine	machine	/orphans	machine	login	/' "$fake/conf/node-tasks.tsv"
out=$(python3 "$MT" table --check "$fake" 2>&1)
printf '%s' "$out" | grep -q "orphans: a machine-table task is the machine's" && ok "A a machine-table task marked login is red" || bad "A machine task as login unflagged: $out"

# ---- B: the daemon skips a machine-class unit per login ------------------------
units() {   # <runtime> → the account unit names the daemon would run per login
  python3 - "$BIN/fleet-node-supervisor.py" "$1" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("sup", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(" ".join(sorted(u["name"] for u in m.account_units(types.SimpleNamespace(runtime=sys.argv[2])))))
PY
}
rt="$WORK/rt"; mkdir -p "$rt/conf" "$rt/launchd"; cp "$ROOT/launchd/"*.tmpl "$rt/launchd/"
base=$(units "$rt")   # no table: MACHINE_UNITS alone, as before
case " $base " in *" spinner "*) case " $base " in *" memguard "*) bad "B memguard runs per login with no table" ;; *) ok "B no table: every template but MACHINE_UNITS, as before" ;; esac ;;
  *) bad "B no table: spinner missing: $base" ;; esac
sed 's/^spinner	unit	session	/spinner	unit	machine	/' "$ROOT/conf/node-tasks.tsv" > "$rt/conf/node-tasks.tsv"
now_u=$(units "$rt")
case " $now_u " in *" spinner "*) bad "B a unit the table marks machine still runs per login: $now_u" ;; *) ok "B a unit the table marks machine is not run per login" ;; esac
cp "$ROOT/conf/node-tasks.tsv" "$rt/conf/"
[ "$(units "$rt")" = "$base" ] && ok "B this tree's table runs exactly the old per-login set" || bad "B per-login set changed: $(units "$rt") vs $base"

# ---- C: tick ----------------------------------------------------------------
cl="$WORK/state/cluster"
python3 "$MT" tick --out "$cl" || bad "C tick failed"
mode=$(stat -c '%a' "$cl/machine.json" 2>/dev/null || stat -f '%Lp' "$cl/machine.json")
[ "$mode" = 644 ] && ok "C machine.json 0644" || bad "C machine.json mode $mode"
left=$(find "$cl" -name '.machine.json.*' | head -1)
[ -z "$left" ] && ok "C written through one rename, nothing left" || bad "C a temporary file left behind: $left"
live=$(FLEET_SKIP_GLOBAL_CONF=1 bash -c '. "$1"; FLEET_MACHINE_TASKS=; fleet_mem_total_mb' _ "$BIN/fleet-lib.sh")
grep -q "^\"mem_total_mb\": \"$live\"" "$cl/machine.json" && ok "C carries fleet_mem_total_mb's own answer ($live)" || bad "C mem_total_mb: $(cat "$cl/machine.json")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["v"]==1 and d["ts"]>0' "$cl/machine.json" && ok "C valid JSON, v 1, ts" || bad "C not the format"

# ---- D: the reader ------------------------------------------------------------
put() {   # <dir> <ts> → a reading with markers no probe would print
  mkdir -p "$1"; printf '{\n"v": 1,\n"ts": %s,\n"mem_probe": "2 41 0 7",\n"mem_total_mb": "4242",\n"load_per_core": "9.99"\n}\n' "$2" > "$1/machine.json"
}
mkdir -p "$WORK/shim"
for c in nproc sysctl getconf; do printf '#!/bin/sh\necho %s >> "%s/probed"\nexit 1\n' "$c" "$WORK" > "$WORK/shim/$c"; chmod +x "$WORK/shim/$c"; done
rd() {   # <switch> → "load|mem|total" as a login reads them
  rm -f "$WORK/probed"
  PATH="$WORK/shim:$PATH" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_NODE_STATE="$WORK/state" \
    FLEET_MACHINE_TASKS="$1" \
    bash -c '. "$1"; printf "%s|%s|%s" "$(_fleet_load_per_core)" "$(fleet_mem_probe)" "$(fleet_mem_total_mb)"' _ "$BIN/fleet-lib.sh"
}
chmod 755 "$cl"; put "$cl" "$(date +%s)"; mkdir -p "$WORK/conf"
got=$(rd off)
[ "$got" = "9.99|2 41 0 7|4242" ] && ok "D switch off: the three probes answer the machine's reading" || bad "D reading not used: $got"
[ ! -s "$WORK/probed" ] && ok "D switch off: the login ran no load probe of its own" || bad "D the login probed anyway: $(tr '\n' ' ' < "$WORK/probed")"
got=$(rd '')
case "$got" in 9.99*|*4242) bad "D switch unset read the reading: $got" ;; *) ok "D switch unset: probes run here, as before" ;; esac
put "$cl" "$(( $(date +%s) - 120 ))"
case "$(rd off)" in 9.99*) bad "D a 120 s old reading was used" ;; *) ok "D a stale reading is no reading" ;; esac
put "$cl" "$(( $(date +%s) + 120 ))"
case "$(rd off)" in 9.99*) bad "D a reading from the future was used" ;; *) ok "D a reading from the future is no reading" ;; esac
put "$cl" "$(date +%s)"
# the pushed copy names a reading no probe here can make (a Linux probe always says
# compressor 0): "1 80 0 0" is a plain runner at 80% free, so D's empty-value check
# once read the real probe as the copy (#3904)
mkdir -p "$WORK/conf/cluster"; printf '{\n"v": 1,\n"ts": %s,\n"mem_probe": "1 80 37 5",\n"mem_total_mb": "1111",\n"load_per_core": "0.11"\n}\n' "$(date +%s)" > "$WORK/conf/cluster/machine.json"
[ "$(rd off)" = "0.11|1 80 37 5|1111" ] && ok "D a copy pushed into the login's own cluster/ wins" || bad "D pushed copy: $(rd off)"
printf '{\n"v": 1,\n"ts": %s,\n"mem_probe": "",\n"mem_total_mb": "1111",\n"load_per_core": "0.11"\n}\n' "$(date +%s)" > "$WORK/conf/cluster/machine.json"
got=$(rd off)
case "$got" in "0.11|1 80 37 5|"*) bad "D an empty value was used: $got" ;;
  "0.11|"*"|1111") grep -q sysctl "$WORK/probed" 2>/dev/null || [ -r /proc/meminfo ] \
       && ok "D an empty value: that probe (and only it) runs here" || bad "D empty mem_probe, yet no probe ran" ;;
  *) bad "D an empty value spoiled the others: $got" ;; esac

# ---- E: the daemon's task, install-apply's switch ----------------------------------
tbl() { FLEET_NODE_PROFILE="${1:-}" python3 - "$BIN/fleet-node-supervisor.py" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("sup", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
t = m.default_table(types.SimpleNamespace(runtime="/rt", state="/st"))
for x in t["tasks"]:
    if x["name"] == "machine-reading":
        print(x["every"], x.get("seat"), " ".join(x["cmd"][2:]))
PY
}
got=$(tbl)
[ "$got" = "15 True /rt/bin/fleet-machine-tasks.py tick --out /st/cluster" ] && ok "E the daemon runs machine-reading every 15 s, the seat's" || bad "E machine-reading task: '$got'"
if [ "$(uname -s)" = Linux ]; then
  [ -z "$(tbl user-pod)" ] && ok "E a user pod does not run it (the cluster's one copy)" || bad "E a user pod runs machine-reading"
fi
grep -q "_seat_dir(os.path.join(paths.state, \"cluster\"), 0, gid, 0o775)" "$BIN/fleet-node-supervisor.py" \
  && ok "E the seat's layout makes cluster/ root's, the seat's group may write" || bad "E no cluster/ in the seat layout"
grep -q 'fleet_node_manages "$LOGIN" || \[ "${FLEET_USER_POD:-}" = 1 \]; then' "$BIN/fleet-install-apply.sh" \
  && grep -q "set-line FLEET_MACHINE_TASKS 'FLEET_MACHINE_TASKS=off'" "$BIN/fleet-install-apply.sh" \
  && grep -q "drop-line FLEET_MACHINE_TASKS" "$BIN/fleet-install-apply.sh" \
  && ok "E install-apply writes the switch for a managed login or a user pod's (#3734) and takes it back" || bad "E install-apply's switch lines missing"
# set-line / drop-line on a real fleet.conf, as install-apply calls them
cd_="$WORK/cfg"; mkdir -p "$cd_"; printf '# fleet.conf\n# ---- [common] ----\nFLEET_HOST=1\n' > "$cd_/fleet.conf"
FLEET_CONF_DIR="$cd_" bash "$BIN/fleet-conf.sh" set-line FLEET_MACHINE_TASKS 'FLEET_MACHINE_TASKS=off' >/dev/null 2>&1
got=$(unset FLEET_SKIP_GLOBAL_CONF; FLEET_CONF_DIR="$cd_" bash -c '. "$1" >/dev/null 2>&1; printf %s "${FLEET_MACHINE_TASKS:-}"' _ "$BIN/fleet-lib.sh")
[ "$got" = off ] && ok "E the line set-line writes reaches fleet-lib.sh" || bad "E FLEET_MACHINE_TASKS after set-line: '$got'"
FLEET_CONF_DIR="$cd_" bash "$BIN/fleet-conf.sh" drop-line FLEET_MACHINE_TASKS >/dev/null 2>&1
grep -q FLEET_MACHINE_TASKS "$cd_/fleet.conf" && bad "E drop-line left the switch" || ok "E drop-line takes it back"

# ---- F: class session (#3671) ------------------------------------------------------
sess=$(python3 - "$BIN/fleet-node-supervisor.py" "$ROOT" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("sup", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
us = m.account_units(types.SimpleNamespace(runtime=sys.argv[2]))
print(" ".join(sorted(u["name"] for u in us if u.get("session") and not u.get("asleep"))) + " | "
      + " ".join(sorted(u["name"] for u in us if u.get("asleep"))))
PY
)
[ "$sess" = "spinner | " ] \
  && ok "F the spinner runs only while the login has a session; no class-worker unit is left (#4899)" \
  || bad "F session units: '$sess'"
cp "$ROOT/conf/node-tasks.tsv" "$fake/conf/"
sed -i.bak 's/^orphans	machine	machine	/orphans	machine	session	/' "$fake/conf/node-tasks.tsv"
out=$(python3 "$MT" table --check "$fake" 2>&1)
printf '%s' "$out" | grep -q "orphans: only a launchd unit serves a login's sessions" && ok "F a machine-table task marked session is red" || bad "F session on a machine task unflagged: $out"
out=$(python3 "$BIN/fleet-node-supervisor-selftest.py" V_SessionUnits 2>&1) && ok "F the daemon: session units, adopt after a restart, strays stop, no doubled task" \
  || bad "F fleet-node-supervisor-selftest.py V_SessionUnits: $(printf '%s' "$out" | grep -E '^(FAIL|ERROR|AssertionError)' | head -3 | tr '\n' ' ')"

# ---- G: a user pod's copy (#3734) ------------------------------------------------
GO="$ROOT/tokenledger/agent/node_cluster_reading.go"
want=$(python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("mt", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
sys.stdout.write(m.render({"v": 1, "ts": 1760000000, "mem_probe": "1 60 0 0", "mem_total_mb": "6144", "load_per_core": "0.25"}))' "$MT")
# the literal the Go side's test holds its render to (node_cluster_reading_test.go)
lit=$(printf '{\n"v": 1,\n"ts": 1760000000,\n"mem_probe": "1 60 0 0",\n"mem_total_mb": "6144",\n"load_per_core": "0.25"\n}')
[ "$want" = "$lit" ] && grep -q 'func renderMachineReading' "$GO" \
  && grep -qF '"{\n\"v\": 1,\n\"ts\": 1760000000,\n\"mem_probe\": \"1 60 0 0\",\n\"mem_total_mb\": \"6144\",\n\"load_per_core\": \"0.25\"\n}\n"' "${GO%.go}_test.go" \
  && ok "G the node program's copy is fleet-machine-tasks.py's render, byte for byte" || bad "G render drift between Python and Go"
rm -rf "$WORK/conf/cluster" "$cl/machine.json"
mkdir -p "$WORK/conf/cluster"
printf '{\n"v": 1,\n"ts": %s,\n"mem_probe": "2 9 0 0",\n"mem_total_mb": "8192",\n"load_per_core": "0.80"\n}\n' "$(date +%s)" > "$WORK/conf/cluster/machine.json"
[ "$(rd off)" = "0.80|2 9 0 0|8192" ] && ok "G a user pod with no machine reading of its own reads fleet-ops' copy" || bad "G pod copy: $(rd off)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
