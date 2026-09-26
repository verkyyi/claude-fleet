#!/bin/bash
# fleet-alerts-selftest.sh — pins issue #1238: ONE producer (bin/fleet-alerts.sh)
# writes $G/alerts.ndjson; the status bar only COUNTS it, at a fixed width; the
# `prefix !` popup lists it, one action per row; an alarm cannot be muted; a
# cleared alert leaves a ↻ trace; the old sentence wording is gone from bin/.
#
#   1. width    — `✖ N ▲ N` is the SAME width with 0 / 1 / 7 / 12 alerts
#   2. quota    — hub gone: `✖ 1`, first popup row `quota · stale`; back: that
#                 row carries ↻ (healed) until FLEET_ALERTS_TRACE, then drops
#   3. since    — a standing alert keeps its first-seen time across writes
#   4. mute     — a warning mutes out of the count for FLEET_ALERTS_MUTE_SECS;
#                 an alarm refuses (exit 3) and keeps counting; expiry restores
#   5. actions  — every row names one action the popup can run
#   6. accounts — .fleet-account.py's all-capped stamp → `accounts · all capped`;
#                 an account.model-limited row → `model · capped · fable → opus`
#   7. needs    — @claude_state needs/failed windows → ● rows (question /
#                 permission / blocked / waiting / failed; empty @issue safe);
#                 a writer with no tmux keeps the previous needs rows
#   8. degenerate — nothing configured: no rows, blank fixed-width bar
#  10. act      — ↵ on a kick row returns at once (the kick runs detached and
#                 toasts its outcome); kick-daemons passes ONLY the row's
#                 detail units as --unit, never --force; a healed row kicks
#                 nothing; kick-collect is `--unit collect --force` (#1242)
#   9. wording  — `pace spread` / `quota blind` / `via banner` /
#                 `no locally reachable` appear nowhere in bin/; `prefix !` is
#                 bound and on the cheatsheet
#
# No live tmux, no network: tmux is a shim, TMPDIR is a sandbox.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
ok() { CHECKS=$((CHECKS+1)); }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; ok; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-alerts-selftest.XXXXXX") || exit 2
WORK="$(cd "$WORK" && pwd -P)"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT
G="$WORK/.claude-dash/global"; mkdir -p "$G" "$WORK/acc" "$WORK/shim"
export TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" FLEET_STATUS_DISK=0
unset TMUX CCQUOTA_HUB_URL FLEET_ACCOUNTS_DIR 2>/dev/null
FA="$BIN/fleet-alerts.sh"
fa() { bash "$FA" "$@"; }
now() { date +%s; }
# Visible width of a tmux-format string: styles/ranges draw nothing.
# Characters, not bytes (✖ ▲ are 3 each): wc -m under a UTF-8 locale.
vis() { printf '%s' "$1" | sed 's/#\[[^]]*\]//g' | LC_ALL=C.UTF-8 wc -m | tr -d ' '; }
row() {  # id severity subject condition value since action → one ndjson row
  printf '{"id":"%s","severity":"%s","subject":"%s","condition":"%s","value":"%s","since":%s,"action":"%s","healed_at":0,"target":"","detail":""}\n' "$@"
}

# ------------------------------------------------------------------ 1. width ----
: > "$G/alerts.ndjson"
w0=$(vis "$(fa bar)")
row a1 alarm quota stale 47m "$(now)" accounts > "$G/alerts.ndjson"
w1=$(vis "$(fa bar)")
{ for i in 1 2 3; do row "a$i" alarm dash stale 1m "$(now)" kick-collect; done
  for i in 1 2 3 4; do row "w$i" warning quota uneven '37 pts' "$(now)" accounts; done; } > "$G/alerts.ndjson"
b7=$(fa bar); w7=$(vis "$b7")
{ for i in $(seq 1 12); do row "a$i" alarm dash stale 1m "$(now)" kick-collect; row "w$i" warning disk low '11 GB' "$(now)" disk; done; } > "$G/alerts.ndjson"
w12=$(vis "$(fa bar)")
[ "$w0" -gt 0 ] || fail "1: the bar rendered nothing"
eq "1: width with 1 alert = width with 0" "$w0" "$w1"
eq "1: width with 7 alerts = width with 0" "$w0" "$w7"
eq "1: width with 24 alerts = width with 0" "$w0" "$w12"
case "$b7" in *"✖ 3"*"▲ 4"*) ok ;; *) fail "1: the 7-alert bar does not read ✖ 3 ▲ 4" "$b7" ;; esac
case "$b7" in *"range=user|alarm"*"range=user|warning"*) ok ;; *) fail "1: the counts are not clickable ranges" "$b7" ;; esac
case "$(fa bar)" in *quota*|*stale*|*"·"*) fail "1: a sentence leaked onto the bar" "$(fa bar)" ;; *) ok ;; esac

# ------------------------------------------------------------------ 2. quota ----
rm -f "$G"/alerts.*
export FLEET_ACCOUNTS_DIR="$WORK/acc" CCQUOTA_HUB_URL=http://127.0.0.1:9
printf '%s\n' $(( $(now) - 1800 )) > "$G/account.quota.ts"      # no tick for 30m
fa write
eq "2: hub gone → one alarm" "1 0 0" "$(fa counts)"
case "$(fa bar)" in *"✖ 1 "*) ok ;; *) fail "2: the bar does not read ✖ 1" "$(fa bar)" ;; esac
first=$(fa list --plain | head -1 | cut -f2-)
case "$first" in *"✖  quota · stale · 30m"*"see accounts"*) ok ;; *) fail "2: first popup row is not quota · stale" "$first" ;; esac
printf '%s\n' "$(now)" > "$G/account.quota.ts"                    # the watch is back
printf '0\t0\n' > "$G/account.quota.empty"
fa write
eq "2: recovered → nothing counted" "0 0 0" "$(fa counts)"
case "$(fa list --plain)" in *"↻  quota · stale"*"healed"*) ok ;; *) fail "2: recovery left no ↻ trace" "$(fa list --plain)" ;; esac
FLEET_ALERTS_TRACE=0 fa write
eq "2: the trace ends at FLEET_ALERTS_TRACE" "" "$(fa list --plain)"
unset FLEET_ACCOUNTS_DIR CCQUOTA_HUB_URL

# ------------------------------------------------------------------ 3. since ----
rm -f "$G"/alerts.*
printf 'a\t90\t40\tahead\nb\t10\t-5\tbehind\n' > "$G/quota.pace"
fa write
s1=$(sed -n 's/.*"id":"quota-uneven".*"since":\([0-9]*\).*/\1/p' "$G/alerts.ndjson")
[ -n "$s1" ] || fail "3: the pace spread raised no quota-uneven row" "$(cat "$G/alerts.ndjson")"
sed "s/\"since\":$s1/\"since\":$(( s1 - 600 ))/" "$G/alerts.ndjson" > "$G/x" && mv "$G/x" "$G/alerts.ndjson"
fa write
eq "3: a standing alert keeps its first-seen time" "$(( s1 - 600 ))" \
  "$(sed -n 's/.*"id":"quota-uneven".*"since":\([0-9]*\).*/\1/p' "$G/alerts.ndjson")"
case "$(fa list --plain)" in *"▲  quota · uneven · 45 pts"*"10m"*) ok ;; *) fail "3: row wording/duration" "$(fa list --plain)" ;; esac

# ------------------------------------------------------------------- 4. mute ----
{ row q1 alarm quota stale 5m "$(now)" accounts; row w1 warning quota uneven '37 pts' "$(now)" accounts; } > "$G/alerts.ndjson"
eq "4: before muting" "1 1 0" "$(fa counts)"
fa mute q1 2>/dev/null; eq "4: an alarm refuses to mute (exit 3)" 3 "$?"
fa mute w1 || fail "4: muting a warning failed"
eq "4: a muted warning leaves the count; the alarm stays" "1 0 0" "$(fa counts)"
case "$(fa list --plain)" in *"(muted)"*) ok ;; *) fail "4: the popup does not mark the muted row" "$(fa list --plain)" ;; esac
case "$(cat "$G/alerts.mute")" in "w1	"*) ok ;; *) fail "4: mute file shape" "$(cat "$G/alerts.mute")" ;; esac
printf 'w1\t%s\n' $(( $(now) - 1 )) > "$G/alerts.mute"
eq "4: an expired mute counts again" "1 1 0" "$(fa counts)"

# ---------------------------------------------------------------- 5. actions ----
rm -f "$G/alerts.mute"
export FLEET_STATUS_DISK=1 FLEET_DISK_FLOOR_GB=99999999
printf '%s\t0\n' "$(now)" > "$G/account.all-capped"
fa write
unset FLEET_DISK_FLOOR_GB; export FLEET_STATUS_DISK=0
n=0
while IFS= read -r l; do
  n=$((n+1))
  case "$l" in *'"action":""'*) fail "5: a row with no action" "$l" ;; esac
  case "$l" in *'"action":"accounts"'*|*'"action":"kick-collect"'*|*'"action":"kick-daemons"'*|*'"action":"disk"'*|*'"action":"jump"'*) ok ;;
    *) fail "5: unknown action" "$l" ;; esac
done < "$G/alerts.ndjson"
[ "$n" -ge 3 ] || fail "5: expected at least disk + uneven + all-capped rows" "$(cat "$G/alerts.ndjson")"
case "$(fa list --plain)" in *"✖  disk · low · "*" GB"*"see disk"*) ok ;; *) fail "5: disk under the floor is not an alarm" "$(fa list --plain)" ;; esac

# --------------------------------------------------------------- 6. accounts ----
rm -f "$G"/alerts.* "$G/quota.pace"
if command -v python3 >/dev/null 2>&1; then
  FLEET_C="$WORK/.claude-dash" python3 - "$BIN" <<'PY' || fail "6: stamp_all_capped raised"
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location('fa', sys.argv[1] + '/.fleet-account.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t = int(time.time())
m.stamp_all_capped({'accounts': [{'reset_at': t + 7200}, {'limited_until': t + 3600}, {'hold_until': t - 5}]})
PY
  nf=$(cut -f2 "$G/account.all-capped")
  [ "$nf" -gt "$(( $(now) + 3000 ))" ] && [ "$nf" -lt "$(( $(now) + 3700 ))" ] \
    || fail "6: next-free is not the earliest future reset" "$(cat "$G/account.all-capped")"; ok
fi
printf 'acctA\tfable\t%s\tbanner\nacctB\tfable\t%s\tb\nacctC\tsonnet\t%s\told\n' \
  $(( $(now) + 3600 )) $(( $(now) + 60 )) $(( $(now) - 60 )) > "$G/account.model-limited"
FLEET_MODEL_FALLBACK=opus fa write
out=$(fa list --plain)
case "$out" in *"▲  accounts · all capped · next free "[0-9][0-9]:[0-9][0-9]*) ok ;; *) fail "6: no accounts · all capped row" "$out" ;; esac
case "$out" in *"▲  model · capped · fable → opus"*) ok ;; *) fail "6: no model · capped row" "$out" ;; esac
eq "6: one row per capped model; an expired cap is none" 1 "$(printf '%s\n' "$out" | grep -c 'model · capped')"
if command -v python3 >/dev/null 2>&1; then
  FLEET_C="$WORK/.claude-dash" python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('fa', sys.argv[1] + '/.fleet-account.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.stamp_all_capped(None)
PY
  [ ! -e "$G/account.all-capped" ] || fail "6: a successful pick did not clear the stamp"; ok
fi
rm -f "$G/account.model-limited"

# ------------------------------------------------------------------ 7. needs ----
rm -f "$G"/alerts.*
T="$(printf '\t')"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
case "\$1" in list-windows) cat <<'ROWS'
s1${T}@1${T}plan${T}-${T}needs${T}ask${T}$(( $(now) - 120 ))
s1${T}@2${T}issue-7${T}7${T}needs${T}perm${T}$(( $(now) - 60 ))
s1${T}@3${T}issue-8${T}8${T}needs${T}blocked${T}0
s1${T}@4${T}issue-9${T}9${T}failed${T}-${T}0
s1${T}@5${T}issue-10${T}10${T}needs${T}-${T}0
s1${T}@6${T}dash${T}-${T}needs${T}-${T}0
s1${T}@7${T}issue-11${T}11${T}working${T}-${T}0
ROWS
;; esac
EOF
chmod +x "$WORK/shim/tmux"
TMUX=/tmp/fake,1,0 PATH="$WORK/shim:$PATH" fa write
out=$(fa list --plain)
eq "7: five needs rows (dash panel + a working window excluded)" "0 0 5" "$(fa counts)"
case "$out" in *"●  plan · question"*) ok ;; *) fail "7: a window with no @issue is named by its window" "$out" ;; esac
case "$out" in *"●  #7 · permission"*"↵ go to window"*) ok ;; *) fail "7: perm → permission + jump" "$out" ;; esac
case "$out" in *"●  #8 · blocked"*) ok ;; *) fail "7: blocked" "$out" ;; esac
case "$out" in *"●  #9 · failed"*) ok ;; *) fail "7: failed" "$out" ;; esac
case "$out" in *"●  #10 · waiting"*) ok ;; *) fail "7: undifferentiated needs → waiting" "$out" ;; esac
case "$(cat "$G/alerts.ndjson")" in *'"target":"s1:@2"'*) ok ;; *) fail "7: jump target" "$(cat "$G/alerts.ndjson")" ;; esac
fa write                                                      # no $TMUX: the quota watch's view
eq "7: a writer that cannot see tmux keeps the needs rows" "0 0 5" "$(fa counts)"

# ------------------------------------------------------------- 8. degenerate ----
rm -f "$G"/*
fa write
eq "8: nothing configured → no rows" "" "$(cat "$G/alerts.ndjson")"
eq "8: …and the bar is blank slots of the same width" "$w0" "$(vis "$(fa bar)")"
case "$(fa bar | sed 's/#\[[^]]*\]//g')" in *✖*|*▲*|*[0-9]*) fail "8: a count on an empty fleet" "$(fa bar)" ;; *) ok ;; esac

# ------------------------------------------------------------------- 10. act ----
# A sandbox bin/: the real producer + libs, a fake fleet-daemon-watch.sh that is
# slow (so a blocking act shows) and answers each unit the way the real one does.
SB="$WORK/sbin"; mkdir -p "$SB"
for f in fleet-alerts.sh usage-lib.sh fleet-daemon-lib.sh; do ln -s "$BIN/$f" "$SB/$f"; done
cat > "$SB/fleet-daemon-watch.sh" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >> "$WORK/watch.args"
sleep 3
while [ \$# -gt 0 ]; do
  [ "\$1" = --unit ] && case "\$2" in
    pr-refresh) echo "fleet-daemon-watch: pr-refresh stale 400s but a tick is RUNNING — not kicked (wedged at 900s; --force --now aborts it now)" >&2 ;;
    cleanup)    echo "fleet-daemon-watch: cleanup — skip, kicked 20s ago (cooldown 180s); still stale 300s" >&2 ;;
    collect)    echo "fleet-daemon-watch: collect stale 0s — kicked gui/501/com.claude-fleet.collect (launchd), rc=0" >&2 ;;
  esac
  shift
done
exit 0
EOF
chmod +x "$SB/fleet-daemon-watch.sh"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
case "\$1" in
  display-message) printf '%s\\n' "\$2" >> "$WORK/toasts" ;;
  run-shell) [ "\$2" = -b ] && { sh -c "\$3" </dev/null >/dev/null 2>&1 & } ;;
esac
exit 0
EOF
chmod +x "$WORK/shim/tmux"
sact() { TMUX=/tmp/fake,1,0 PATH="$WORK/shim:$PATH" bash "$SB/fleet-alerts.sh" act "$1"; }
await_toast() {  # <pattern> — the background half's closing toast, ≤10s
  local i=0
  while [ "$i" -lt 50 ]; do grep -q "$1" "$WORK/toasts" 2>/dev/null && return 0; i=$((i+1)); sleep 0.2; done
  return 1
}
rm -f "$G"/alerts.* "$WORK/toasts" "$WORK/watch.args"
printf '{"id":"daemon-stale","severity":"alarm","subject":"daemon","condition":"stale","value":"2 units","since":%s,"action":"kick-daemons","healed_at":0,"target":"","detail":"pr-refresh,cleanup,bogus"}\n' "$(now)" > "$G/alerts.ndjson"
t0=$(now); sact daemon-stale; t1=$(now)
[ $(( t1 - t0 )) -lt 2 ] || fail "10: act blocked on the kick ($(( t1 - t0 ))s; the watch sleeps 3s)"; ok
case "$(cat "$WORK/toasts" 2>/dev/null)" in *"requested: pr-refresh,cleanup"*) ok ;; *) fail "10: no immediate toast naming the units" "$(cat "$WORK/toasts" 2>/dev/null)" ;; esac
await_toast 'daemon restart ·' || fail "10: the background kick never toasted its outcome" "$(cat "$WORK/toasts" 2>/dev/null)"; ok
eq "10: only the row's units, no --force, unknown names dropped" "--unit pr-refresh --unit cleanup" "$(cat "$WORK/watch.args")"
last=$(tail -1 "$WORK/toasts")
case "$last" in *"running, not touched pr-refresh"*"cooldown cleanup"*) ok ;; *) fail "10: outcome toast" "$last" ;; esac
case "$last" in *kicked*) fail "10: nothing was kicked, the toast says kicked" "$last" ;; *) ok ;; esac
rm -f "$WORK/toasts" "$WORK/watch.args"
printf '{"id":"daemon-stale","severity":"healed","subject":"daemon","condition":"stale","value":"kicked","since":%s,"action":"kick-daemons","healed_at":%s,"target":"","detail":"self-healed by a kick"}\n' "$(now)" "$(now)" > "$G/alerts.ndjson"
sact daemon-stale
case "$(cat "$WORK/toasts")" in *"nothing to do"*) ok ;; *) fail "10: a healed row should kick nothing" "$(cat "$WORK/toasts")" ;; esac
sleep 0.5; [ ! -e "$WORK/watch.args" ] || fail "10: a healed row ran the watch" "$(cat "$WORK/watch.args")"; ok
printf '{"id":"dash-stale","severity":"alarm","subject":"dash","condition":"stale","value":"5m","since":%s,"action":"kick-collect","healed_at":0,"target":"","detail":"x"}\n' "$(now)" > "$G/alerts.ndjson"
t0=$(now); sact dash-stale; t1=$(now)
[ $(( t1 - t0 )) -lt 2 ] || fail "10: kick-collect blocked ($(( t1 - t0 ))s)"; ok
await_toast 'kicked collect' || fail "10: kick-collect outcome toast" "$(cat "$WORK/toasts" 2>/dev/null)"; ok
eq "10: kick-collect = --unit collect --force" "--unit collect --force" "$(cat "$WORK/watch.args")"
rm -f "$G"/alerts.* "$WORK/toasts"

# ---------------------------------------------------------------- 9. wording ----
hits=$(grep -rn 'pace spread\|quota blind\|via banner\|no locally reachable' "$BIN" 2>/dev/null | grep -v 'fleet-alerts-selftest.sh')
eq "9: the old wording is gone from bin/" "" "$hits"
grep -q '^bind ! .*fleet-alerts.sh popup' "$BIN/../conf/tmux-attention.conf" || fail "9: prefix ! is not bound to the popup"; ok
[ "$(grep -c 'mouse_status_range},alarm},' "$BIN/../conf/tmux-attention.conf")" = 2 ] \
  || fail "9: both MouseDown1Status tables must open the popup from a count"; ok
[ "$(grep -c 'key "prefix !"' "$BIN/fleet-keys.sh")" = 2 ] || fail "9: prefix ! missing from the cheatsheet (zh + en)"; ok
grep -q 'fleet_alerts_refresh --kick' "$BIN/tmux-status.sh" || fail "9: the bar no longer refreshes the producer"; ok

printf 'selftest PASS: %d assertions (width · quota · since · mute · actions · accounts · needs · degenerate · act · wording)\n' "$CHECKS"
