#!/bin/bash
# fleet-spotlight-selftest.sh — bin/fleet-spotlight.sh (issue #3402): a managed Mac
# runs with Spotlight off, and the doctor's `spotlight` row says when it is not.
#
#   A  not a managed machine: status --check says nothing (2), off refuses (1)
#   B  a volume indexing → WARN naming it; off runs mdutil -a -i off + -E → PASS
#   C  a knowledge agent running (volumes already off — mini2, 2026-10-11) → WARN;
#      off disables + boots out every agent in gui/ and user/ for every uid → PASS
#   D  hot: fseventsd 115% for an hour → WARN; the same for 5 minutes → not hot
#   E  <state>/spotlight.keep: PASS «kept on», off touches nothing
#   F  off --tick with nothing to do prints nothing; off without root refuses
#   G  fleet-doctor.sh's `spotlight` row and the machine daemon's `spotlight` task
#      call this script
#
# Hermetic: fake mdutil / launchctl / ps over files in a temp dir. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SP="$BIN/fleet-spotlight.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spotlight-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
FAILS=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

mkdir -p "$WORK/state" "$WORK/bin"
# mdutil: $WORK/vols holds `<volume> on|off`; -i off turns all off, every call logged
cat > "$WORK/bin/mdutil" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/mdutil.log"
case "\$*" in
  "-as") while read -r v s; do echo "\$v:"; [ "\$s" = on ] && printf '\tIndexing enabled. \n' || printf '\tIndexing disabled.\n'; done < "$WORK/vols" ;;
  "-a -i off") sed -i.bak 's/ on\$/ off/' "$WORK/vols" ;;
esac
EOF
# launchctl: logged; a bootout of the knowledge agent removes its process row
cat > "$WORK/bin/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/launchctl.log"
case "\$1 \$2" in
  "bootout gui/"*com.apple.spotlightknowledged) grep -v '/spotlightknowledged\$' "$WORK/ps" > "$WORK/ps.n"; mv "$WORK/ps.n" "$WORK/ps" ;;
esac
EOF
chmod +x "$WORK/bin/"*
sp() {
  FLEET_NODE_STATE="$WORK/state" FLEET_NODE_TEST=1 FLEET_SPOTLIGHT_MDUTIL="$WORK/bin/mdutil" \
  FLEET_SPOTLIGHT_LAUNCHCTL="$WORK/bin/launchctl" FLEET_SPOTLIGHT_PS="cat $WORK/ps" \
  FLEET_SPOTLIGHT_UIDS="501 504" bash "$SP" "$@"
}
reset() {
  printf '/ off\n/System/Volumes/Data off\n' > "$WORK/vols"
  printf 'verky 01:00:00 0.5 /usr/bin/zsh\n' > "$WORK/ps"
  : > "$WORK/mdutil.log"; : > "$WORK/launchctl.log"
}

# A
reset
out=$(sp status --check); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok "A status --check off a managed machine: no row" || bad "A status rc=$rc out=[$out]"
sp off >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/mdutil.log" ] && ok "A off refuses a person's own Mac" || bad "A off rc=$rc, mdutil: $(cat "$WORK/mdutil.log")"
: > "$WORK/state/machine.env"

# B
reset
printf '/ off\n/System/Volumes/Data on\n' > "$WORK/vols"
out=$(sp status --check); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'indexing on: /System/Volumes/Data' && printf '%s' "$out" | grep -q 'fleet-spotlight.sh off' \
  && ok "B a volume indexing → WARN with the fix" || bad "B rc=$rc out=[$out]"
out=$(sp off); rc=$?
grep -qx -- '-a -i off' "$WORK/mdutil.log" && grep -qx -- '-a -E' "$WORK/mdutil.log" && [ "$rc" = 0 ] \
  && printf '%s' "$out" | grep -q 'index erased on: /System/Volumes/Data' \
  && ok "B off: mdutil -a -i off + -a -E" || bad "B off rc=$rc out=[$out] mdutil=[$(tr '\n' '|' < "$WORK/mdutil.log")]"
out=$(sp status --check); rc=$?
[ "$rc" = 0 ] && ok "B after off: PASS" || bad "B after rc=$rc out=[$out]"

# C
reset
printf 'verkyyi 07:13:04 0.4 /System/Library/Frameworks/CoreSpotlight.framework/spotlightknowledged\n' >> "$WORK/ps"
out=$(sp status --check); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'knowledge agent running for: verkyyi' && ok "C knowledge agent running (volumes off) → WARN" || bad "C rc=$rc out=[$out]"
sp off >/dev/null; rc=$?
n=0
for u in 501 504; do for s in com.apple.spotlightknowledged com.apple.spotlightknowledged.importer com.apple.spotlightknowledged.updater; do
  for d in gui user; do grep -qx "disable $d/$u/$s" "$WORK/launchctl.log" && grep -qx "bootout $d/$u/$s" "$WORK/launchctl.log" && n=$((n + 1)); done
done; done
if [ "$rc" = 0 ] && [ "$n" = 12 ] && ! grep -q -- '-a -i off' "$WORK/mdutil.log"; then
  ok "C off disables + boots out 3 agents × gui/user × each uid, leaves mdutil alone"
else bad "C off rc=$rc, $n/12 disable+bootout, mdutil=[$(tr '\n' '|' < "$WORK/mdutil.log")]"; fi
out=$(sp status --check); rc=$?
[ "$rc" = 0 ] && ok "C after off: PASS" || bad "C after rc=$rc out=[$out]"

# D
reset
printf 'root 01:02:03 115.0 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd\n' >> "$WORK/ps"
out=$(sp status --check); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'fseventsd(root) 115.0%' && ok "D fseventsd 115% for an hour → WARN" || bad "D rc=$rc out=[$out]"
reset
printf 'root 05:00 115.0 /x/mds_stores\nroot 2-01:00:00 3.0 /x/mds\n' >> "$WORK/ps"
out=$(sp status --check); rc=$?
[ "$rc" = 0 ] && ok "D 5 minutes hot, or days at 3%: not hot" || bad "D2 rc=$rc out=[$out]"

# E
reset
printf '/ on\n' > "$WORK/vols"
: > "$WORK/state/spotlight.keep"
out=$(sp status --check); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'kept on' && ok "E spotlight.keep: PASS «kept on»" || bad "E rc=$rc out=[$out]"
sp off >/dev/null; [ ! -s "$WORK/mdutil.log" ] && [ ! -s "$WORK/launchctl.log" ] && ok "E off leaves a kept machine alone" || bad "E off acted"
rm -f "$WORK/state/spotlight.keep"

# F
reset
out=$(sp off --tick); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "F tick with nothing to do is quiet" || bad "F rc=$rc out=[$out]"
if [ "$(id -u)" != 0 ]; then
  out=$(FLEET_NODE_STATE="$WORK/state" FLEET_SPOTLIGHT_MDUTIL="$WORK/bin/mdutil" bash "$SP" off 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'needs root' && ok "F off without root refuses" || bad "F root rc=$rc out=[$out]"
fi

# G
grep -q '/fleet-spotlight.sh"' "$BIN/fleet-doctor.sh" && grep -q '_nspot" status --check' "$BIN/fleet-doctor.sh" && grep -q 'warn spotlight' "$BIN/fleet-doctor.sh" \
  && ok "G doctor's spotlight row reads status --check" || bad "G doctor has no spotlight row"
grep -q '"fleet-spotlight.sh"), "off", "--tick"' "$BIN/fleet-node-supervisor.py" \
  && ok "G the machine daemon's spotlight task runs off --tick" || bad "G no spotlight task in the supervisor"

[ "$FAILS" = 0 ] && echo "fleet-spotlight-selftest: all passed" || { echo "fleet-spotlight-selftest: $FAILS failed"; exit 1; }
