#!/bin/bash
# fleet-host-tune-selftest.sh — bin/fleet-host-tune.sh (issue #1082, EPIC #1074).
#
# Pinned:
#   - --plan (and the bare default) CHANGES NOTHING: every tool it can reach is
#     a recording shim, and the log holds no write — no sudo, no `defaults
#     write`, no `pmset -a`, no `mdutil -i`, no `launchctl limit maxfiles <n>`,
#     no `-setairportpower`, no plist on disk;
#   - each item's row carries the SAME name as its doctor line (spotlight /
#     nofile / sleep / siri / icloud) and shows now → target → command;
#   - --apply asks per item and a "no" (or EOF) applies nothing; --apply --yes
#     runs exactly the planned commands; once the fixtures read "at target" the
#     plan says there is nothing to change;
#   - network (Wi-Fi off) is offered unasked in the doctor's WARN case (wired +
#     Wi-Fi to one gateway), is opt-in (--wifi-off) otherwise, and refused while
#     every default route is on Wi-Fi;
#   - a failed command is reported and exits 1; on Linux it says so and exits 0.
#
# Hermetic: fake uname/mdutil/launchctl/pmset/defaults/pgrep/networksetup/netstat/
# sudo on PATH, scratch plist path. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
TUNE="$BIN/fleet-host-tune.sh"
[ -f "$TUNE" ] || { printf 'selftest: %s not found\n' "$TUNE" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/host-tune-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
FP="$WORK/fakepath"; mkdir -p "$FP"
LOG="$WORK/calls.log"
PLIST="$WORK/com.claude-fleet.maxfiles.plist"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- output ---\n%s\n--- calls ---\n' "${2:-(none)}" >&2; cat "$LOG" >&2 2>/dev/null; exit 1; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2";; esac; }

# Every shim appends "<tool> <argv>" to $LOG and answers from a fixture file.
shim() { # shim <name> <body>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\n%s\n' "$1" "$LOG" "$2" > "$FP/$1"
  chmod +x "$FP/$1"
}
shim uname        "[ \"\$1\" = -s ] && { cat '$WORK/os'; exit 0; }; exec /usr/bin/uname \"\$@\""
shim mdutil       "cat '$WORK/mdutil.out'"
shim launchctl    "cat '$WORK/maxfiles.out'"
shim pmset        "cat '$WORK/pmset.out'"
shim defaults     "[ -s '$WORK/defaults.out' ] || exit 1; cat '$WORK/defaults.out'"
shim pgrep        "grep -qx \"\$2\" '$WORK/pgrep.out'"
shim networksetup "case \"\$1\" in -listallhardwareports) printf 'Hardware Port: Ethernet\nDevice: en0\n\nHardware Port: Wi-Fi\nDevice: en1\n' ;; -getairportpower) echo \"Wi-Fi Power (en1): \$(cat '$WORK/wifi.out')\" ;; esac"
shim netstat      "cat '$WORK/netstat.out'"
# sudo: records, lets `tee` really write (the plist lands in $WORK), fails when
# the fixture names the command, and otherwise succeeds without running it.
shim sudo         "grep -qx \"\$1\" '$WORK/sudo.fail' 2>/dev/null && exit 3; [ \"\$1\" = tee ] && exec \"\$@\"; exit 0"

bad_host() {  # every item off target
  echo Darwin > "$WORK/os"
  printf '/System/Volumes/Data:\n\tIndexing enabled. \n' > "$WORK/mdutil.out"
  printf '\tmaxfiles    256            unlimited      \n' > "$WORK/maxfiles.out"
  printf 'System-wide power settings:\nCurrently in use:\n sleep                10\n autorestart          0\n womp                 1\n' > "$WORK/pmset.out"
  echo 1 > "$WORK/defaults.out"
  printf 'bird\ncloudd\n' > "$WORK/pgrep.out"
  echo On > "$WORK/wifi.out"; printf 'default            192.168.1.1        UGScg                 en0       \n' > "$WORK/netstat.out"
  : > "$WORK/sudo.fail"; rm -f "$PLIST"; : > "$LOG"
}
good_host() {
  printf '/System/Volumes/Data:\n\tIndexing disabled.\n' > "$WORK/mdutil.out"
  printf '\tmaxfiles    65536          200000         \n' > "$WORK/maxfiles.out"
  printf ' sleep                0\n autorestart          1\n womp                 1\n' > "$WORK/pmset.out"
  echo 0 > "$WORK/defaults.out"
  : > "$WORK/pgrep.out"; echo Off > "$WORK/wifi.out"; : > "$LOG"
}
run() { PATH="$FP:$PATH" FLEET_HOST_TUNE_MAXFILES_PLIST="$PLIST" bash "$TUNE" "$@"; }
no_writes() {  # $1 = label
  local c; c=$(cat "$LOG")
  hasnt 'sudo ' "$c" "$1: sudo was invoked"
  hasnt 'defaults write' "$c" "$1: defaults write"
  hasnt 'pmset -a' "$c" "$1: pmset -a"
  hasnt 'mdutil -a' "$c" "$1: mdutil -a"
  hasnt 'launchctl limit maxfiles 6' "$c" "$1: launchctl limit write"
  hasnt 'setairportpower' "$c" "$1: networksetup write"
  CHECKS=$((CHECKS + 1)); [ ! -e "$PLIST" ] || fail "$1: plist was written" "$(cat "$PLIST")"
}

# 1. --plan on a host with every item off target: rows, commands, zero writes.
bad_host
# stdin says "y" to everything and --yes is set: a plan must still not act.
out=$(printf 'y\ny\ny\ny\ny\n' | run --plan --yes 2>&1); rc=$?
CHECKS=$((CHECKS + 1)); [ "$rc" = 0 ] || fail "--plan exit $rc" "$out"
has 'CHANGE spotlight' "$out" "spotlight row"
has 'sudo mdutil -a -i off' "$out" "spotlight command"
has 'CHANGE nofile' "$out" "nofile row"
has 'maxfiles 256' "$out" "nofile now"
has 'sudo launchctl limit maxfiles 65536 200000' "$out" "nofile command"
has 'CHANGE sleep' "$out" "sleep row"
has 'sleep=10 autorestart=0 womp=1' "$out" "sleep now"
has 'sudo pmset -a sleep 0 autorestart 1   (undo: sudo pmset -a sleep 10 autorestart 0)' "$out" "sleep command changes only what is off"
has 'CHANGE siri' "$out" "siri row"
has 'HINT   icloud    sync daemons resident: bird cloudd' "$out" "icloud hint"
has 'SKIP   network' "$out" "wifi-off is opt-in on a wired host"
has '4 item(s) to change — nothing was changed' "$out" "plan summary"
no_writes "--plan"

# 2. the bare default is --plan; --wifi-off only adds a row, still no writes.
out=$(printf 'y\ny\ny\ny\ny\n' | run --wifi-off --yes 2>&1)
has 'CHANGE network' "$out" "--wifi-off offers wifi on a wired host"
has 'networksetup -setairportpower en1 off' "$out" "wifi command"
no_writes "default mode"

# 3. --apply, answering no to everything (and EOF): nothing applied.
out=$(printf 'n\nn\nn\nn\n' | run --apply 2>&1)
has '0 applied, 4 skipped, 0 failed' "$out" "all declined"
no_writes "--apply declined"
out=$(run --apply </dev/null 2>&1)
has '0 applied, 4 skipped' "$out" "EOF declines"
no_writes "--apply EOF"

# 4. --apply, yes to the first item only.
out=$(printf 'y\nn\nn\nn\n' | run --apply 2>&1)
has '1 applied, 3 skipped' "$out" "one accepted"
c=$(cat "$LOG")
has 'sudo mdutil -a -i off' "$c" "spotlight applied"
hasnt 'sudo pmset' "$c" "sleep declined"

# 5. --apply --yes: exactly the planned commands.
bad_host
out=$(run --apply --yes 2>&1); rc=$?
CHECKS=$((CHECKS + 1)); [ "$rc" = 0 ] || fail "--apply --yes exit $rc" "$out"
has '4 applied, 0 skipped, 0 failed' "$out" "all applied"
c=$(cat "$LOG")
has 'sudo mdutil -a -i off' "$c" "mdutil applied"
has "sudo tee $PLIST" "$c" "plist written via sudo"
has "sudo chown root:wheel $PLIST" "$c" "plist owner"
has 'sudo launchctl limit maxfiles 65536 200000' "$c" "limit applied now"
has 'sudo pmset -a sleep 0 autorestart 1' "$c" "pmset applied"
has 'defaults write com.apple.assistant.support Assistant Enabled -bool false' "$c" "siri applied"
hasnt 'setairportpower' "$c" "wifi untouched without --wifi-off"
p=$(cat "$PLIST" 2>/dev/null)
has '<string>maxfiles</string><string>65536</string><string>200000</string>' "$p" "plist sets the limit"
has '<key>RunAtLoad</key><true/>' "$p" "plist runs at boot"
CHECKS=$((CHECKS + 1)); plutil -lint "$PLIST" >/dev/null 2>&1 || ! command -v plutil >/dev/null 2>&1 || fail "plist does not lint" "$p"

# 6. at target (plist present): nothing to change, all rows OK.
good_host
out=$(run 2>&1)
has 'nothing to change' "$out" "clean host"
for r in spotlight nofile sleep siri icloud network; do has "OK     $r" "$out" "$r OK at target"; done
hasnt CHANGE "$out" "no CHANGE at target"

# 7. a failed command: reported, the rest still offered, exit 1.
bad_host; echo pmset > "$WORK/sudo.fail"
out=$(run --apply --yes 2>&1); rc=$?
CHECKS=$((CHECKS + 1)); [ "$rc" = 1 ] || fail "failed apply exit $rc (want 1)" "$out"
has 'FAILED (exit 3)' "$out" "failure named"
has '3 applied, 0 skipped, 1 failed' "$out" "failure counted"

# 8. network: refused while Wi-Fi carries every default route ...
bad_host; printf 'default            192.168.1.1        UGScg                 en1       \n' > "$WORK/netstat.out"
out=$(run --apply --yes --wifi-off 2>&1)
has 'carries every default route' "$out" "wifi refusal"
hasnt 'setairportpower' "$(cat "$LOG")" "wifi not touched"
# ... applied on a wired host with --wifi-off ...
bad_host
out=$(run --apply --yes --wifi-off 2>&1)
has 'networksetup -setairportpower en1 off' "$(cat "$LOG")" "wifi applied when wired"
# ... and offered UNASKED in the doctor's WARN case: one gateway via en0 + en1.
bad_host
printf 'default            192.168.1.1        UGScg                 en0       \ndefault            192.168.1.1        UGScIg                en1       \ndefault            link#17            UCSIg             bridge100      !\n' > "$WORK/netstat.out"
out=$(run 2>&1)
has 'default route to 192.168.1.1 through Wi-Fi (en1) and en0' "$out" "shared gateway offered without --wifi-off"
has '5 item(s) to change' "$out" "network counted"
no_writes "--plan shared gateway"
out=$(run --apply --yes 2>&1)
has 'networksetup -setairportpower en1 off' "$(cat "$LOG")" "shared gateway applied by --yes"

# 9. Linux: says so, reads nothing, exit 0.
bad_host; echo Linux > "$WORK/os"
out=$(run --apply --yes 2>&1); rc=$?
CHECKS=$((CHECKS + 1)); [ "$rc" = 0 ] || fail "linux exit $rc" "$out"
has 'macOS only' "$out" "linux message"
hasnt 'mdutil' "$(cat "$LOG")" "linux probes nothing"

# 10. usage.
out=$(run --bogus 2>&1); rc=$?
CHECKS=$((CHECKS + 1)); [ "$rc" = 2 ] || fail "unknown arg exit $rc (want 2)" "$out"

printf 'fleet-host-tune-selftest: PASS (%s checks)\n' "$CHECKS"
