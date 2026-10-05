#!/bin/bash
# fleet-degenerate-selftest.sh — the degenerate-output watchdog (issue #1557).
#
# Replays #1498's 2026-10-04 failure — one sentence, then `<br>` streamed until
# somebody presses Esc — in a fake pane on an ISOLATED tmux socket, and drives the
# spinner's sweep (bin/tmux-spinner.sh --degenerate-check, the same degen_check the
# frame loop calls) one pass at a time, so the two-sweep rule is pinned by COUNT:
#   A  the detector (bin/fleet-degenerate.awk via fleet-degenerate.sh --detect):
#      the replay, a token on rows of its own, a tag, words — hit; an ASCII
#      table's data rows and empty rows, a separator, a repeated log line, 11 rows
#      — no hit
#   B  pass 1 arms, pass 2 sends ONE Escape: @degenerate_ts stamped, the pane shows
#      the interrupt, a DEGENERATE row (lines + sample) in the parent's ledger,
#      `⟲` at the end of the sidebar row; a STALE strike table is not "pass 1"
#   C  the cooldown: the screen still degenerate, the window still `working` — no
#      second Escape until @degenerate_ts is FLEET_DEGENERATE_COOLDOWN_SECS old
#   D  an ASCII table's repeated rows and a window that is not `working` are never
#      interrupted
#   E  the cadence: two default sweeps fit inside the 60 s the issue asks for
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPINNER="$BIN/tmux-spinner.sh"
command -v tmux >/dev/null 2>&1 || { echo 'selftest: tmux not installed — SKIP' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'selftest: python3 not installed — SKIP' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/degen.XXXXXX")" || exit 2
export TMUX_TMPDIR="$WORK/t"; mkdir -p "$TMUX_TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
LBL=degenT
printf 'FLEET_REPO="acme/degen"\n' > "$FLEET_CONF_DIR/$LBL.conf"
trap 'tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
TM() { tmux -L "$LBL" "$@"; }

FAIL=0 CHECKS=0
ok()   { CHECKS=$((CHECKS + 1)); }
fail() { CHECKS=$((CHECKS + 1)); FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '      %s\n' "$2" >&2; }
check() { if eval "$1"; then ok; else fail "$2" "${3:-}"; fi; }

# --- A: the detector ------------------------------------------------------------
det() { bash "$BIN/fleet-degenerate.sh" --detect >/dev/null 2>&1; }
rows() { local i; for i in $(seq "$1"); do printf '%s\n' "$2"; done; }
{ printf '⏺ CI 红在 shard 3：计时窗口太紧，'; yes '<br>' | head -600 | tr -d '\n' | fold -w 97; echo; } > "$WORK/replay.txt"
det < "$WORK/replay.txt";                                check '[ $? = 0 ]' 'A: the #1498 replay (soft-wrapped <br>, phase shifting every row) is degenerate'
rows 14 '<br>' | det;                                    check '[ $? = 0 ]' 'A: <br> on rows of its own is degenerate'
{ for i in $(seq 13); do echo '<section>'; echo; done; } | det; check '[ $? = 0 ]' 'A: one tag repeated, blank rows between, is degenerate'
printf 'the %.0s' $(seq 300) | fold -w 80 | det; check '[ $? = 0 ]' 'A: a word repeated is degenerate'
rows 20 '│ ok   │ ok   │' | det;                         check '[ $? = 1 ]' 'A: an ASCII table data row repeated must NOT hit'
rows 20 '│      │      │' | det;                         check '[ $? = 1 ]' 'A: an ASCII table empty row repeated must NOT hit'
rows 20 '────────────────────' | det;                    check '[ $? = 1 ]' 'A: a separator must NOT hit'
rows 20 '2026-10-04 step failed: timeout' | det;          check '[ $? = 1 ]' 'A: a repeated LONG line (a log line) must NOT hit'
rows 11 '<br>' | det;                                    check '[ $? = 1 ]' 'A: 11 rows are under the 12-row floor'

# --- the fixture: fake panes on an isolated server --------------------------------
# fakepane.py <keys-log> <mode>: `br` prints one sentence, then streams <br> until
# an Escape arrives, prints the interrupt line and stops streaming; `table` prints
# an ASCII table with 20 identical rows. Either way every key it receives is
# appended to <keys-log> for as long as it lives.
cat > "$WORK/fakepane.py" <<'PY'
import os, select, sys, termios, tty
log, mode = sys.argv[1], sys.argv[2]
fd = sys.stdin.fileno()
tty.setcbreak(fd)
out = sys.stdout
if mode == 'table':
    out.write('┌──────┬──────┐\n' + '│ ok   │ ok   │\n' * 20 + '└──────┴──────┘\n')
else:
    out.write('⏺ CI 红在 shard 3：fleet-collect-stale-selftest 的计时窗口太紧，')
out.flush()
streaming, n = mode == 'br', 0
while True:
    r, _, _ = select.select([fd], [], [], 0.003 if streaming else 1)
    if r:
        b = os.read(fd, 64)
        with open(log, 'ab') as fh:
            fh.write(b)
        if streaming and b'\x1b' in b:
            streaming = False
            out.write('\n  ⎿  Interrupted · What should Claude do instead?\n[Request interrupted by user]\n')
            out.flush()
    if streaming and n < 16822:
        out.write('<br>'); out.flush(); n += 1
PY
TM new-session -d -s "$LBL" -x 100 -y 30 -n w-br "python3 '$WORK/fakepane.py' '$WORK/keys-br' br" || { echo 'selftest: cannot start tmux' >&2; exit 2; }
TM new-window -d -t "$LBL" -n w-table "python3 '$WORK/fakepane.py' '$WORK/keys-table' table"
TM new-window -d -t "$LBL" -n w-idle "python3 '$WORK/fakepane.py' '$WORK/keys-idle' br"
WBR=$(TM display-message -p -t "$LBL:w-br" '#{window_id}')
TM set-window-option -t w-br @claude_state working
TM set-window-option -t w-br @issue 1557
TM set-window-option -t w-br @origin issue-77
TM set-window-option -t w-table @claude_state working
TM set-window-option -t w-idle @claude_state 'done'
touch "$WORK/keys-br" "$WORK/keys-table" "$WORK/keys-idle"

i=0
until [ "$(TM capture-pane -p -t w-br | grep -c '<br><br>')" -ge 20 ] && TM capture-pane -p -t w-table | grep -q '└'; do
  i=$((i + 1)); [ "$i" -lt 100 ] || { fail 'fixture: the fake panes never filled'; break; }; sleep 0.1
done

STRIKE_F="$BIN/../logs/.degenerate-strikes"
mkdir -p "$BIN/../logs"
one_pass() { sh "$SPINNER" --degenerate-check >/dev/null 2>&1; }
escs() { LC_ALL=C tr -cd '\033' < "$1" | wc -c | tr -d ' '; }
dts() { TM display-message -p -t "$1" '#{@degenerate_ts}'; }

# --- B: two passes, one Escape --------------------------------------------------
# A strike table from long ago naming this very window is not the previous sweep.
printf '%s |%s:%s|\n' "$(( $(date +%s) - 3600 ))" "$LBL" "$WBR" > "$STRIKE_F"
one_pass
check '[ "$(escs "$WORK/keys-br")" = 0 ]' 'B: pass 1 (behind a STALE strike table) may only arm, never press Esc' "escs=$(escs "$WORK/keys-br")"
check '[ -z "$(dts w-br)" ]' 'B: pass 1 must not stamp @degenerate_ts'
one_pass
check '[ "$(escs "$WORK/keys-br")" = 1 ]' 'B: pass 2 agreeing with pass 1 sends exactly ONE Escape' "escs=$(escs "$WORK/keys-br")"
check '[ -n "$(dts w-br)" ]' 'B: the interrupt stamps @degenerate_ts'
i=0; until TM capture-pane -p -t w-br | grep -q 'Request interrupted'; do i=$((i + 1)); [ "$i" -lt 50 ] || break; sleep 0.1; done
check 'TM capture-pane -p -t w-br | grep -q "Request interrupted"' 'B: the pane shows the interrupt after the Escape'
LEDGER="$FLEET_CONF_DIR/fleets/$LBL/children/issue-77.ndjson"
check 'grep -q "\"state\": \"DEGENERATE\"" "$LEDGER" 2>/dev/null' 'B: a DEGENERATE row lands in the parent (issue-77) ledger' "$(cat "$LEDGER" 2>/dev/null)"
check 'python3 -c "import json,sys; e=json.loads(open(sys.argv[1]).read().splitlines()[-1]); sys.exit(0 if e[\"child\"]==\"issue-1557\" and int(e[\"lines\"])>=12 and e[\"sample\"]==\"‹br›\" and e[\"tier\"]==\"silent\" else 1)" "$LEDGER" 2>/dev/null' \
  'B: the row carries child / lines / sample and is tier silent' "$(tail -1 "$LEDGER" 2>/dev/null)"
# The sidebar row ends in ⟲ (the producer reads the window through $TMUX).
SOCKP="$TMUX_TMPDIR/tmux-$(id -u)/$LBL"
srow=$(TMUX="$SOCKP,0,0" FLEET_SESSION="$LBL" bash "$BIN/tmux-dashboard-rows.sh" --sidebar 2>/dev/null | grep -a "$WBR" | head -1)
check 'case "$srow" in *"w-br ⟲"*) true ;; *) false ;; esac' 'B: the sidebar row of the interrupted window ends in ⟲' "row=$srow"

# --- C: the cooldown ------------------------------------------------------------
# Still `working` (no Stop hook in a fake pane), still a screen of <br>: nothing.
one_pass; one_pass
check '[ "$(escs "$WORK/keys-br")" = 1 ]' 'C: within the cooldown a still-degenerate window gets no second Escape' "escs=$(escs "$WORK/keys-br")"
TM set-window-option -t w-br @degenerate_ts "$(( $(date +%s) - 301 ))"
one_pass; one_pass
check '[ "$(escs "$WORK/keys-br")" = 2 ]' 'C: past the 300 s cooldown the rule applies again' "escs=$(escs "$WORK/keys-br")"

# --- D: never the table, never a window that is not working ----------------------
check '[ "$(escs "$WORK/keys-table")" = 0 ]' 'D: an ASCII table with repeated rows is never interrupted'
check '[ -z "$(dts w-table)" ]' 'D: the table window carries no @degenerate_ts'
check '[ "$(escs "$WORK/keys-idle")" = 0 ]' 'D: a `done` window is never interrupted, whatever its screen'

# --- E: the cadence -------------------------------------------------------------
dflt=$(sed -n 's/^DEGEN_SECS="\${FLEET_DEGENERATE_SECS:-\([0-9]*\)}"$/\1/p' "$SPINNER")
check '[ -n "$dflt" ] && [ $(( dflt * 2 )) -le 60 ]' 'E: two default sweeps must fit in 60 s' "default=$dflt"
grep -q 'degen_check; }' "$SPINNER"; check '[ $? = 0 ]' 'E: the frame loop calls degen_check'

rm -f "$STRIKE_F"
if [ "$FAIL" -gt 0 ]; then printf 'fleet-degenerate-selftest: %d/%d FAILED\n' "$FAIL" "$CHECKS"; exit 1; fi
printf 'fleet-degenerate-selftest: %d checks passed\n' "$CHECKS"
