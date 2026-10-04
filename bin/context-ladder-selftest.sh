#!/usr/bin/env bash
# context-ladder-selftest.sh — the compaction / handoff ledger (issue #1320, EPIC
# #1315 C5): logs/context-ladder.log gets one row per step, written by the script
# that performs it, and bin/fleet-doctor.sh's `context` row reads it.
#
#   PREP        a Stop in the compact-prep band (set-claude-state.sh) → `prep`
#   COMPACTING  the next clean Stop spawns fleet-compact-send.sh → `compacting`
#   RESTORED    SessionStart(compact) (refocus-hook.sh) → `restored` reason
#               `fleet` with the bumped count and ctx `-` (the pane's @ctx_pct is
#               still the pre-compaction reading, #1441); a compaction the fleet did NOT
#               start (Claude Code's own auto-compact) → `restored` reason `auto`
#   NUDGE       a Stop at/over the handoff % → `handoff-nudge` reason `pct`; past
#               FLEET_COMPACT_MAX at the prep line → reason `cap` (#1316)
#   COMPLETE    the handoff cycle's row takes the pre-/clear ctx % + count it
#               passes (--ctx/--count beat the live pane); the cycle wiring itself
#               is asserted by fleet-handoff-selftest.sh's key-sequence leg
#   FIELDS      every row has all 9 tab-separated columns, none empty; the `#`
#               header naming them is written once
#   ROTATION    over FLEET_LADDER_LOG_MAX_BYTES the ladder log is cut to the newest
#               rows filling half the cap (header kept) — and handoff-cycle.log gets the SAME cap
#   DOCTOR      empty/missing log ⇒ PASS 「近 24h 无」; populated ⇒ PASS with the
#               24h counts (a >24h row excluded); the doctor never writes the log;
#               a fleet restore with no `resumed` row 5 min on ⇒ WARN (#1441)
# No real tmux server, no gh, no live Claude.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
FILES="set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-compact-send.sh refocus-hook.sh handoff-latch-reset-hook.sh fleet-ladder-log.sh"
for f in $FILES fleet-doctor.sh fleet-daemon-lib.sh fleet-handoff-cycle.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/context-ladder-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/conf/fleets/s1" "$WORK/tmp" "$WORK/widgets-issue-12"
for f in $FILES; do cp "$BIN/$f" "$WORK/inst/bin/$f"; done
STATE="$WORK/inst/bin/set-claude-state.sh"
REFOCUS="$WORK/inst/bin/refocus-hook.sh"
LADDER="$WORK/inst/bin/fleet-ladder-log.sh"
GCONF="$WORK/inst/fleet.conf"
LOG="$WORK/inst/logs/context-ladder.log"     # the default dir: <bin>/../logs
OPTS="$WORK/opts"; SENDLOG="$WORK/send.log"
git -C "$WORK/widgets-issue-12" init -q -b issue-12 2>/dev/null || git -C "$WORK/widgets-issue-12" init -q
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s/main\nFLEET_BASE_BRANCH=trunk\n' "$WORK" > "$WORK/conf/fleets/s1/conf"

# --- stateful fake tmux: options in $OPTS ("key<TAB>value"), send-keys logged ----
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/usr/bin/env python3
import os, re, sys
a = sys.argv[1:]
if a[:1] in (["-L"], ["-S"]): a = a[2:]
path = os.environ["FAKE_OPTS"]
def load():
    d = {}
    try:
        for line in open(path):
            k, _, v = line.rstrip("\n").partition("\t"); d[k] = v
    except FileNotFoundError: pass
    return d
def save(d):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for k, v in d.items(): f.write("%s\t%s\n" % (k, v))
    os.replace(tmp, path)
# a format: innermost #{name} from the table; #{?cond,a,b} picks a or b — tmux's
# conditional, which the fleet's session read is since #1489
# (`#{?#{session_group},#{session_group},#{session_name}}`)
def _fx(d, f):
    r = re.compile(r"#\{([^#{}]*)\}")
    while True:
        m = r.search(f)
        if not m:
            return f
        k = m.group(1)
        if k.startswith("?"):
            p = k[1:].split(",", 2) + ["", ""]
            v = p[1] if p[0] else p[2]
        else:
            v = d.get(k, "")
        f = f[:m.start()] + v + f[m.end():]
verb = a[0] if a else ""
if verb == "display-message":
    d = load(); fmt = a[-1]
    print(_fx(d, fmt))
elif verb == "set-window-option":
    d = load(); unset = "-u" in a
    rest = [x for x in a[1:] if x != "-u"]
    i = rest.index("-t"); rest = rest[:i] + rest[i+2:]
    if unset: d.pop(rest[0], None)
    else: d[rest[0]] = rest[1] if len(rest) > 1 else ""
    save(d)
elif verb == "send-keys":
    with open(os.environ["FAKE_SENDLOG"], "a") as f: f.write(" ".join(a) + "\n")
elif verb == "list-clients":
    pass
else:
    sys.exit(1)
FAKE
chmod +x "$WORK/fakepath/tmux"

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- ladder log ---\n' >&2; cat "$LOG" >&2 2>/dev/null
         printf -- '--- opts ---\n' >&2; cat "$OPTS" >&2 2>/dev/null; exit 1; }

conf() {
  { printf 'FLEET_HANDOFF_DEFER_SECS=30\n'
    printf 'FLEET_COMPACT_PREP_PCT=%s\nFLEET_AUTO_HANDOFF_PCT=%s\n' "$1" "$2"
    printf 'FLEET_COMPACT_MAX=2\n'   # the cap leg below counts to 2, whatever the default
  } > "$GCONF"; }
reset() {
  printf 'session_name\ts1\n@issue\t12\n@claude_state\tdone\nwindow_id\t@1\nwindow_name\twidgets-12\n' > "$OPTS"
  for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$OPTS"; done
  : > "$SENDLOG"
}
getopt() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$OPTS"; }
penv() { env -i PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/tmp" \
           TMUX="$WORK/sock,1,0" TMUX_PANE='%9' FLEET_CONF_DIR="$WORK/conf" \
           FAKE_OPTS="$OPTS" FAKE_SENDLOG="$SENDLOG" FLEET_COMPACT_SEND_GRACE=0 "$@"; }
stop() { OUT=$(cd "$WORK/widgets-issue-12" && printf '{}' | penv sh "$STATE" 'done' 2>&1); }
compact_start() {
  OUT=$(cd "$WORK/widgets-issue-12" && printf '{"hook_event_name":"SessionStart","source":"compact"}' \
        | penv FLEET_SKIP_GLOBAL_CONF=1 bash "$REFOCUS" 2>&1)
}
# row <n> — the n-th data row (1-based), tab-separated.
row() { grep -v '^#' "$LOG" 2>/dev/null | sed -n "${1}p"; }
rows() { grep -vc '^#' "$LOG" 2>/dev/null; }
# expect <n> <step> <ctx> <count> <reason-glob> — check the n-th row's fields.
expect() {
  local r; r=$(row "$1")
  IFS=$'\t' read -r e_ep _ e_step e_sess e_pane e_win e_ctx e_cnt e_rsn <<<"$r"
  [ "$e_step" = "$2" ] || fail "row $1 step: want $2, got '$e_step'" "$r"
  [ "$e_sess" = s1 ] && [ "$e_pane" = '%9' ] && [ "$e_win" = widgets-12 ] \
    || fail "row $1 ($2): session/pane/window must be s1 / %9 / widgets-12" "$r"
  [ "$e_ctx" = "$3" ] || fail "row $1 ($2): ctx want $3, got '$e_ctx'" "$r"
  [ "$e_cnt" = "$4" ] || fail "row $1 ($2): count want $4, got '$e_cnt'" "$r"
  # shellcheck disable=SC2053
  [[ "$e_rsn" == $5 ]] || fail "row $1 ($2): reason want '$5', got '$e_rsn'" "$r"
  case "$e_ep" in ''|*[!0-9]*) fail "row $1 ($2): epoch not numeric" "$r" ;; esac
}

# ---- PREP ----------------------------------------------------------------------
conf 70 90
reset '@ctx_pct=75'
stop
[ "$(getopt @compact_stage)" = prep ] || fail "PREP: the Stop hook did not stamp prep" "$OUT"
[ "$(rows)" = 1 ] || fail "PREP: want exactly 1 row, got $(rows)"
expect 1 prep 75 0 '>= 70%'
case "$OUT" in '{"decision":"block"'*'RECOVERY MAP'*) : ;; *) fail "PREP: the hook's stdout must still be ONLY its JSON" "$OUT" ;; esac
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "PREP: the ladder write leaked onto the hook's stdout" "$OUT"
ok "PREP: the compact-prep Stop writes one prep row (stdout stays the JSON)"

# ---- COMPACTING ----------------------------------------------------------------
stop
for _ in $(seq 1 50); do [ "$(rows)" -ge 2 ] && break; sleep 0.1; done
[ "$(getopt @compact_stage)" = compacting ] || fail "COMPACTING: the sender did not stamp compacting"
expect 2 compacting 75 0 'map'
ok "COMPACTING: fleet-compact-send.sh writes the compacting row as it types /compact"

# ---- RESTORED (fleet, then auto) ----------------------------------------------
compact_start
[ "$(getopt @compact_count)" = 1 ] || fail "RESTORED: count not bumped" "$OUT"
expect 3 restored - 1 fleet
reset '@ctx_pct=31' '@compact_count=1'
compact_start
expect 4 restored - 1 auto
ok "RESTORED: SessionStart(compact) logs fleet (count bumped) and Claude's own auto-compact"

# ---- NUDGE (pct, then cap) -----------------------------------------------------
reset '@ctx_pct=92'
stop
[ "$(getopt @handoff_armed)" = 1 ] || fail "NUDGE: the handoff did not arm" "$OUT"
expect 5 handoff-nudge 92 0 'pct >= 90%'
reset '@ctx_pct=75' '@compact_count=2'
stop
case "$OUT" in *'compacted in place 2 times'*) : ;; *) fail "NUDGE cap: wrong directive" "$OUT" ;; esac
expect 6 handoff-nudge 75 2 'cap >= 70%'
ok "NUDGE: the auto-handoff Stop logs pct, and the #1316 cap logs cap with the count"

# ---- COMPLETE: the cycle's pre-/clear capture beats the zeroed live pane --------
reset '@ctx_pct=4'
penv sh "$LADDER" handoff-complete --pane '%9' --socket s1 --ctx 88 --count 2 --reason 'resumed from issue #12'
expect 7 handoff-complete 88 2 'resumed from issue #12'
grep -q 'fleet-ladder-log.sh" handoff-complete' "$BIN/fleet-handoff-cycle.sh" \
  || fail "COMPLETE: fleet-handoff-cycle.sh no longer writes the handoff-complete row"
ok "COMPLETE: handoff-complete carries the ctx % + count captured before the /clear"

# ---- FIELDS + HEADER -----------------------------------------------------------
bad=$(grep -v '^#' "$LOG" | awk -F '\t' 'NF != 9 { print; next } { for (i = 1; i <= 9; i++) if ($i == "") { print; next } }')
[ -z "$bad" ] || fail "FIELDS: a row lacks one of the 9 columns" "$bad"
[ "$(grep -c '^# epoch	time	step	session	pane	window	ctx_pct	count	reason$' "$LOG")" = 1 ] \
  || fail "FIELDS: the column header must be written exactly once"
# a pane-less, tmux-less write still yields a full row (dashes), never a short one
env -i PATH=/usr/bin:/bin FLEET_HANDOFF_LOG_DIR="$WORK/bare" sh "$LADDER" prep --reason $'a\tb'
r=$(grep -v '^#' "$WORK/bare/context-ladder.log")
[ "$(printf '%s' "$r" | awk -F '\t' '{ print NF }')" = 9 ] || fail "FIELDS: a tab in the reason split the row" "$r"
env -i PATH=/usr/bin:/bin FLEET_HANDOFF_LOG_DIR="$WORK/bare" sh "$LADDER" bogus-step
[ "$(grep -vc '^#' "$WORK/bare/context-ladder.log")" = 1 ] || fail "FIELDS: an unknown step must write nothing"
ok "FIELDS: 9 columns on every row, header once, free text flattened, unknown steps ignored"

# ---- ROTATION: the ladder log and handoff-cycle.log share one cap ---------------
R="$WORK/rot"; mkdir -p "$R"
for i in $(seq 1 200); do
  env -i PATH=/usr/bin:/bin FLEET_HANDOFF_LOG_DIR="$R" FLEET_LADDER_LOG_MAX_BYTES=4000 \
    sh "$LADDER" restored --reason "row-$i"
done
sz=$(wc -c < "$R/context-ladder.log" | tr -d ' ')
[ "$sz" -le 4000 ] || fail "ROTATION: ladder log $sz bytes, cap 4000"
[ "$(grep -c '^# epoch' "$R/context-ladder.log")" = 1 ] || fail "ROTATION: trimming dropped the header"
grep -q 'row-200$' "$R/context-ladder.log" || fail "ROTATION: the newest row must survive"
grep -q 'row-1$' "$R/context-ladder.log" && fail "ROTATION: the oldest row must be trimmed"
for i in $(seq 1 300); do printf '2026-10-03T00:00:00 [%%9] cycle line %s\n' "$i"; done > "$R/handoff-cycle.log"
env -i PATH=/usr/bin:/bin HOME="$WORK" FLEET_HANDOFF_LOG_DIR="$R" FLEET_LADDER_LOG_MAX_BYTES=4000 \
  bash "$BIN/fleet-handoff-cycle.sh" >/dev/null 2>&1   # no --pane: refuses, after the trim
sz=$(wc -c < "$R/handoff-cycle.log" | tr -d ' ')
[ "$sz" -le 4000 ] || fail "ROTATION: handoff-cycle.log $sz bytes — not under the same cap"
grep -q 'cycle line 300$' "$R/handoff-cycle.log" || fail "ROTATION: handoff-cycle.log lost its newest line"
ok "ROTATION: both logs cut to the newest rows filling half the cap past FLEET_LADDER_LOG_MAX_BYTES"

# ---- DOCTOR --------------------------------------------------------------------
D="$WORK/doc"; mkdir -p "$D/bin" "$D/conf" "$D/logs"
cp "$BIN/fleet-doctor.sh" "$BIN/fleet-daemon-lib.sh" "$D/bin/"
doctor() { env -i LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK" FLEET_CONF_DIR="$D/conf" \
             FAKE_OPTS="$WORK/doc-opts" FAKE_SENDLOG=/dev/null "$@" sh "$D/bin/fleet-doctor.sh" 2>&1 \
           | grep -E '^ *(PASS|WARN|FAIL) +context '; }
line=$(doctor)
case "$line" in *PASS*'近 24h 无'*) : ;; *) fail "DOCTOR: no log ⇒ PASS 「近 24h 无」" "$line" ;; esac
[ -e "$D/logs/context-ladder.log" ] && fail "DOCTOR: the doctor must not create the log"
now=$(date +%s)
{ printf '# epoch\ttime\tstep\tsession\tpane\twindow\tctx_pct\tcount\treason\n'
  printf '%s\tt\trestored\ts1\t%%9\tw\t70\t1\tfleet\n' $(( now - 90000 ))   # > 24h: excluded
  printf '%s\tt\tcompacting\ts1\t%%9\tw\t72\t0\tmap\n' $(( now - 60 ))
  printf '%s\tt\trestored\ts1\t%%9\tw\t40\t1\tfleet\n' $(( now - 50 ))
  printf '%s\tt\trestored\ts1\t%%9\tw\t35\t1\tauto\n' $(( now - 40 ))
  printf '%s\tt\thandoff-nudge\ts1\t%%9\tw\t91\t1\tpct >= 90%%\n' $(( now - 30 ))
  printf '%s\tt\thandoff-complete\ts1\t%%9\tw\t91\t1\tdoc\n' $(( now - 20 ))
} > "$D/logs/context-ladder.log"
before=$(cksum < "$D/logs/context-ladder.log")
line=$(doctor)
case "$line" in *PASS*'近 24h 压缩 2 次（发起 1）、交接 1 次（提示 1）'*) : ;;
  *) fail "DOCTOR: populated log ⇒ 24h counts (the >24h row excluded)" "$line" ;; esac
[ "$(cksum < "$D/logs/context-ladder.log")" = "$before" ] || fail "DOCTOR: the doctor wrote the log"
line=$(doctor FLEET_HANDOFF_LOG_DIR="$WORK/nowhere")
case "$line" in *PASS*'近 24h 无'*) : ;; *) fail "DOCTOR: FLEET_HANDOFF_LOG_DIR must steer the read" "$line" ;; esac
ok "DOCTOR: context row PASSes — 「近 24h 无」 when empty, 24h counts when not, read-only"

# ---- DOCTOR: a fleet compaction nobody resumed WARNs (issue #1441) --------------
{ printf '# epoch\ttime\tstep\tsession\tpane\twindow\tctx_pct\tcount\treason\n'
  printf '%s\tt\trestored\ts1\t%%9\tw9\t-\t1\tfleet\n' $(( now - 3000 ))
  printf '%s\tt\tresumed\ts1\t%%9\tw9\t30\t1\tmod\n' $(( now - 2990 ))
  printf '%s\tt\trestored\ts1\t%%7\tw7\t-\t1\tfleet\n' $(( now - 900 ))
  printf '%s\tt\trestored\ts1\t%%8\tw8\t-\t1\tauto\n' $(( now - 900 ))
} > "$D/logs/context-ladder.log"
line=$(doctor)
case "$line" in *WARN*'1 次压缩后没有续跑'*'s1:w7'*) : ;;
  *) fail "DOCTOR: a fleet restore with no resumed row after 5 min must WARN (auto restores never)" "$line" ;; esac
line=$(doctor FLEET_COMPACT_RESUME=0)
case "$line" in *PASS*) : ;; *) fail "DOCTOR: FLEET_COMPACT_RESUME=0 must not WARN" "$line" ;; esac
printf '%s\tt\tresumed\ts1\t%%7\tw7\t30\t1\tskip:operator\n' $(( now - 890 )) >> "$D/logs/context-ladder.log"
line=$(doctor)
case "$line" in *PASS*) : ;; *) fail "DOCTOR: a resumed row (even a skip) settles the restore" "$line" ;; esac
grep -v resumed "$D/logs/context-ladder.log" > "$D/logs/x" && mv "$D/logs/x" "$D/logs/context-ladder.log"
line=$(doctor)
case "$line" in *PASS*) : ;; *) fail "DOCTOR: a ledger with no resumed row yet (pre-#1441) must not WARN" "$line" ;; esac
ok "DOCTOR: an unresumed fleet compaction WARNs; resumed / off / pre-#1441 ledger PASS"

printf 'context-ladder-selftest: all legs PASS\n'
