#!/bin/bash
# fleet-cn-probe-selftest.sh — the China real-user path's patrol and its test road
# (issue #4180), offline: bin/fleet-cn-probe-watch.sh and bin/fleet-cn-probe-env.sh
# against a stub probe, gh, filer, ssh and kubectl. bin/fleet-cn-probe.sh itself
# walks a real machine in China and is run by hand / by the patrol, never here;
# only its syntax (bash 3.2 too) and its usage are checked. Gate 9 (`cn:`) is
# bin/fleet-stable-selftest.sh's section S.
#
#   A  off: no client key here, or FLEET_CN_PROBE=0 → nothing runs
#   B  green: `cn path` success on stable, last.json green, no issue filed
#   C  throttle: a second run inside FLEET_CN_PROBE_SECS walks nothing
#   D  red: one breakage per layer (cn-path-<layer>), failure status naming it,
#      one alert per issue, re-walked after FLEET_CN_PROBE_RED_SECS
#   E  --dry-run: says what it would post / file, changes nothing
#   F  green after red forgets the red; a probe with no verdict is red at `probe`
#   G  env ensure: the test pod rolled onto stable's `node image`; a pod already
#      on it is left; no status → left; client + identity ok read as ok
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cnprobe-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — does not contain [$3]:
$2" ;; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — contains [$3]:
$2" ;; esac; }

for f in fleet-cn-probe.sh fleet-cn-probe-watch.sh fleet-cn-probe-env.sh; do
  bash -n "$BIN/$f" || fail "syntax: $f"
  [ ! -x /bin/bash ] || /bin/bash -n "$BIN/$f" || fail "syntax (/bin/bash): $f"
done
out=$(bash "$BIN/fleet-cn-probe.sh" --layers 'view' --repo nope 2>&1); eq "probe: --repo is owner/name" 2 "$?"
out=$(bash "$BIN/fleet-cn-probe.sh" --help 2>&1); contains "probe: help names the codex layer" "$out" "codex:<route>"

export FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home" TMPDIR="$WORK/tmp"   # alerts.events lives under TMPDIR
mkdir -p "$FLEET_CONF_DIR" "$HOME" "$TMPDIR" "$WORK/shim"
SD="$FLEET_CONF_DIR/global/cn-probe"
SHA=0123456789abcdef0123456789abcdef01234567

# --- stubs ----------------------------------------------------------------------
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/gh.log"
case "\$*" in
  *'commits/stable'*) echo $SHA ;;
  *'-X POST'*statuses*) [ -f "$WORK/gh.postfail" ] && exit 1; exit 0 ;;
  *'commits/$SHA/statuses'*) cat "$WORK/nodeimage" 2>/dev/null ;;
esac
SH
cat > "$WORK/probe" <<SH
#!/bin/sh
echo run >> "$WORK/probe.runs"
cat "$WORK/probe.out"
SH
cat > "$WORK/ensure" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/ensure.log"
echo "pod ok"
SH
cat > "$WORK/filer" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/filer.log"
echo "https://github.com/o/r/issues/91"
SH
chmod +x "$WORK/shim/gh" "$WORK/probe" "$WORK/ensure" "$WORK/filer"
export PATH="$WORK/shim:$PATH"
export FLEET_CN_PROBE_CMD="$WORK/probe" FLEET_CN_PROBE_ENV_CMD="$WORK/ensure" FLEET_CN_PROBE_FILE_CMD="$WORK/filer"
export FLEET_CN_PROBE_KEY="$WORK/key"
W="$BIN/fleet-cn-probe-watch.sh"
runs() { if [ -f "$WORK/probe.runs" ]; then wc -l < "$WORK/probe.runs" | tr -d ' '; else echo 0; fi; }
watch() { OUT=$(bash "$W" --repo o/r "$@" 2>&1); RC=$?; }
json() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$SD/last.json" "$1"; }
green_out() { printf 'PASS client x\nPASS view:entry y\n通：自动选 entry；entry 通\n' > "$WORK/probe.out"; }
red_out() { printf 'PASS client x\nFAIL codex:entry no answer\n不通：卡在 codex:entry — no answer carrying CNP1 __CNP_EXIT=4\n' > "$WORK/probe.out"; }

# --- A. off -----------------------------------------------------------------------
green_out
watch; eq "A: no client key → exit 0" 0 "$RC"; eq "A: …and no walk" 0 "$(runs)"
: > "$WORK/key"
FLEET_CN_PROBE=0 bash "$W" --repo o/r >/dev/null 2>&1; eq "A: FLEET_CN_PROBE=0 walks nothing" 0 "$(runs)"
watch --repo; eq "A: --repo needs owner/name" 2 "$RC"

# --- B. green ---------------------------------------------------------------------
watch
eq "B: green exits 0" 0 "$RC"; eq "B: walked once" 1 "$(runs)"
contains "B: says green" "$OUT" "green	0123456"
eq "B: last.json green" green "$(json verdict)"; eq "B: last.json names stable" "$SHA" "$(json stable)"
contains "B: success status on stable" "$(cat "$WORK/gh.log")" "-X POST repos/o/r/statuses/$SHA -f state=success -f context=cn path"
contains "B: ensure told the stable" "$(cat "$WORK/ensure.log")" "--repo o/r --stable $SHA"
[ ! -f "$WORK/filer.log" ] || fail "B: a green walk filed something"
contains "B: last.txt keeps the ensure lines" "$(cat "$SD/last.txt")" "ENSURE pod ok"
[ ! -d "$SD/lock" ] || fail "B: the lock was left behind"

# --- C. throttle ------------------------------------------------------------------
watch; eq "C: inside the interval → exit 0" 0 "$RC"; eq "C: …walks nothing" 1 "$(runs)"
FLEET_CN_PROBE_SECS=0 bash "$W" --repo o/r >/dev/null 2>&1; eq "C: interval 0 walks again" 2 "$(runs)"
mkdir "$SD/lock"; watch --now; eq "C: a fresh lock → nothing" 2 "$(runs)"; rmdir "$SD/lock"

# --- D. red -------------------------------------------------------------------------
red_out; : > "$WORK/gh.log"
watch --now
eq "D: red handled → exit 0 ($OUT)" 0 "$RC"; contains "D: says red" "$OUT" "red	0123456	codex:entry	https://github.com/o/r/issues/91"
fl=$(cat "$WORK/filer.log")
contains "D: one breakage per layer" "$fl" "--breakage --breakage-key cn-path-codex --fault-sha $SHA --repo o/r"
contains "D: titled by the layer" "$fl" "国内真实用户路径不通：卡在 codex"
g=$(cat "$WORK/gh.log")
contains "D: failure status" "$g" "-f state=failure -f context=cn path"
contains "D: …targets the issue" "$g" "target_url=https://github.com/o/r/issues/91"
lacks "D: the pty sentinel is not in the status" "$g" "__CNP_EXIT"
eq "D: last.json red" red "$(json verdict)"; eq "D: last.json stuck" codex:entry "$(json stuck)"
eq "D: last.json issue" https://github.com/o/r/issues/91 "$(json issue)"
[ -f "$SD/red" ] || fail "D: no red mark"
eq "D: the alert's memo" https://github.com/o/r/issues/91 "$(cat "$SD/filed")"
events() { find "$WORK" -name alerts.events -exec cat {} + 2>/dev/null; }
ev=$(events)
contains "D: one breakage alert" "$ev" "国内真实用户路径不通"
n=$(runs); watch; eq "D: red re-walks only after FLEET_CN_PROBE_RED_SECS" "$n" "$(runs)"
FLEET_CN_PROBE_RED_SECS=0 bash "$W" --repo o/r >/dev/null 2>&1; eq "D: …then it does" $((n + 1)) "$(runs)"
ev2=$(events)
eq "D: the same issue alerts once" "$(printf '%s\n' "$ev" | grep -c 国内真实用户路径不通)" "$(printf '%s\n' "$ev2" | grep -c 国内真实用户路径不通)"
: > "$WORK/gh.postfail"; watch --now; eq "D: a status that cannot be posted → exit 1" 1 "$RC"; rm -f "$WORK/gh.postfail"

# --- E. --dry-run ---------------------------------------------------------------------
: > "$WORK/gh.log"; rm -f "$WORK/filer.log" "$WORK/ensure.log"; cp "$SD/last.json" "$WORK/last.before"
watch --dry-run
eq "E: dry-run exits 0" 0 "$RC"
contains "E: says what it would file" "$OUT" "would-file	cn-path-codex"
contains "E: says what it would post" "$OUT" "would-post	$SHA	red"
lacks "E: posts nothing" "$(cat "$WORK/gh.log")" "-X POST"
[ ! -f "$WORK/filer.log" ] || fail "E: dry-run filed"
[ ! -f "$WORK/ensure.log" ] || fail "E: dry-run ran ensure"
cmp -s "$SD/last.json" "$WORK/last.before" || fail "E: dry-run rewrote last.json"

# --- F. green after red, no verdict -------------------------------------------------
green_out; watch --now
eq "F: green again" green "$(json verdict)"
[ ! -f "$SD/red" ] && [ ! -f "$SD/filed" ] || fail "F: the red was not forgotten"
printf 'PASS client x\nssh: dead\n' > "$WORK/probe.out"; watch --now
eq "F: no verdict line → red" red "$(json verdict)"; eq "F: …at probe" probe "$(json stuck)"
contains "F: filed under cn-path-probe" "$(cat "$WORK/filer.log")" "--breakage-key cn-path-probe"

# --- G. env ensure: the test pod follows stable's node image -------------------------
IMG=registry.example/fleet-managed-node
cat > "$WORK/shim/kubectl" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/kubectl.log"
case "\$*" in
  *'get deploy'*) cat "$WORK/deploy" 2>/dev/null ;;
  *'set image'*|*'rollout status'*) exit 0 ;;
esac
SH
# ssh to the China client: the login exists with fleet; the hub lists the machine
cat > "$WORK/shim/ssh" <<'SH'
#!/bin/sh
in=$(cat)
case "$in" in
  *'id -u'*) printf 'USER\n/home/x/.local/bin/fleet\n' ;;
  *'cert-check'*) printf 'PASS\tok\n{"machine": "u-test1"}\n' ;;
esac
SH
chmod +x "$WORK/shim/kubectl" "$WORK/shim/ssh"
E="$BIN/fleet-cn-probe-env.sh"
export FLEET_CN_PROBE_MACHINE=u-test1 FLEET_CN_PROBE_KNOWN_HOSTS=''
printf 'fleet=%s@sha256:aaaa\nsshd=%s@sha256:aaaa\ninit:pod-etc=%s@sha256:aaaa\n' "$IMG" "$IMG" "$IMG" | sed 's/^init://' > "$WORK/deploy"
echo "$IMG@sha256:bbbb" > "$WORK/nodeimage"
out=$(bash "$E" status --repo o/r --stable $SHA 2>&1); rc=$?
eq "G: status on an old pod → 1" 1 "$rc"; contains "G: status says it would roll" "$out" "ensure would roll it"
lacks "G: status sets no image" "$(cat "$WORK/kubectl.log")" "set image"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1); rc=$?
eq "G: ensure rolls → 0" 0 "$rc"; contains "G: says rolled" "$out" "ENSURE pod rolled u-test1"
k=$(cat "$WORK/kubectl.log")
contains "G: every container onto stable's image" "$k" "set image deploy/u-test1 fleet=$IMG@sha256:bbbb pod-etc=$IMG@sha256:bbbb sshd=$IMG@sha256:bbbb"
contains "G: waits for the rollout" "$k" "rollout status deploy/u-test1"
contains "G: client ok" "$out" "ENSURE client ok"; contains "G: identity ok" "$out" "ENSURE identity ok"
printf 'fleet=%s@sha256:bbbb\nsshd=%s@sha256:bbbb\n' "$IMG" "$IMG" > "$WORK/deploy"; : > "$WORK/kubectl.log"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1)
contains "G: a pod on stable's image is ok" "$out" "ENSURE pod ok"; lacks "G: …and not touched" "$(cat "$WORK/kubectl.log")" "set image"
: > "$WORK/nodeimage"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1)
contains "G: no node image status → left" "$out" "ENSURE pod skip stable 0123456 carries no node image status"
: > "$WORK/deploy"; echo "$IMG@sha256:bbbb" > "$WORK/nodeimage"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1); rc=$?
eq "G: no Deployment, no manifest → 1" 1 "$rc"; contains "G: says so" "$out" "no FLEET_CN_PROBE_POD_MANIFEST"

printf 'fleet-cn-probe-selftest OK (%d checks)\n' "$CHECKS"
