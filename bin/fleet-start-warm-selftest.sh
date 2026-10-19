#!/bin/bash
# fleet-start-warm-selftest.sh — 发出即开 (issue #2234, EPIC #2230 C4) on a REAL
# tmux server: fleet-control-read.sh `start … new` (and a seeded scratch) takes a
# ready window from the warm pool (scratch-pool.sh), submits the person's words
# into it as the FIRST TURN (dash-raw-session.sh --warm-only → fleet-pane-submit.sh)
# and answers at once. Since issue #4898 a new task files nothing: it opens on its
# hub record (FLEET_CONTROL_TASK → --task T<n>, stamped @task). Submission uses
# fleet-pane-submit.py + fleet-input.py.
# Same rig as scratch-pool-live-selftest.sh — an isolated `-L` socket, the real session wrapper launching a fake TUI — whose
# input box speaks bracketed paste and logs every submitted turn. The cold spawner
# (dash-raw-session.sh without --warm-only) is a stub in a shadow bin/ that logs its argv.
#
#   A. `start <s> new claude o/a … <title>` + body on stdin, its record T7, a ready
#      o/a entry: ONE stdout line `warm\t<window>\t<name>\t<worktree>\t<fid>\t
#      <t_window>\t<t_ready>\t<t_prompt>`; the window is in the fleet, named after
#      the title, stamped @task T7; its first turn is the body + a blank line + the
#      one note, byte for byte; t_prompt − the call's start ≤ 1 s on an idle box
#      (≤ 3 s loaded); nothing filed, no gh at all
#   B. no record: nothing opens (exit 7)
#   C. the slot is empty: the cold path (dash-raw-session.sh --repo --task), byte for
#      byte FLEET_START_WARM=0's output
#   D. a seeded HOME scratch (`scratch claude -`): the HOME entry, the text alone
#      as its first turn (no note — HOME has no record), the 7-field receipt
#   E. an entry that never shows an empty input (a draft already in it): nothing is
#      typed, the window is closed, and the start takes the cold path
#   F. the controller: a `warm` receipt becomes window_id / key / timing
#      {t_accepted, t_window, t_ready, t_prompt}; ops.log carries the timing
#   G. an UNSEEDED HOME start (`fleet claude`, issue #2339): the HOME entry, its
#      @fleet_id in the receipt, nothing typed, within 3 s
#   H. the controller: a no-repo receipt (no @raw, no key) is matched by its
#      @fleet_id — window_id, no key; nothing matching closes it (`stop fid:…`)
#   L. `fleet codex` (issue #2403): `scratch codex -` with only a Claude HOME entry
#      warm — opened cold, @cc_agent=codex; the Claude entry stays in the pool
#   M. a warm entry whose @cc_agent is not the asked agent is closed, never handed
#      out; the asked agent opens cold
#   N. the controller: a session of another agent than asked → `stop fid:…`, the
#      start failed (EXECUTION_FAILED); a close that fails is unknown; claude as before
#
# tmux / python3 / git absent → SKIP (exit 0).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-sections.sh"
selftest_sections 2
for t in tmux python3 git; do command -v "$t" >/dev/null 2>&1 || { echo "fleet-start-warm: $t absent — SKIP"; exit 0; }; done
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) continue ;; esac; REAL_TMUX=$t; break; done
[ -n "$REAL_TMUX" ] || { echo "fleet-start-warm: no tmux binary — SKIP"; exit 0; }

WORK="$(mktemp -d /tmp/fsw.XXXXXX)" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SESS="fsw$$"
export TMUX_TMPDIR="$WORK/t"; mkdir -p "$TMUX_TMPDIR"
cleanup() {
  "$REAL_TMUX" -L "$SESS" kill-server 2>/dev/null
  pkill -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT; [ -n "${KEEP:-}" ] && trap - EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
nt() { "$REAL_TMUX" -L "$SESS" "$@"; }
o()  { nt display-message -p -t "$1" "#{$2}" 2>/dev/null; }
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# ---- the sandbox --------------------------------------------------------------
mkdir -p "$WORK/b" "$WORK/home" "$WORK/sb" "$WORK/log"
ln -s "$REAL_TMUX" "$WORK/b/tmux"
# A fake agent TUI: bracketed paste on, an input box; a paste is ONE chunk
# (its CRs are newlines), a lone CR submits — the turn is logged (JSON per line).
cat > "$WORK/b/claude" <<'PY'
#!/usr/bin/env python3
import json, os, sys, tty
tty.setraw(0)
log = os.environ.get("FAKE_TURNS", "/dev/null")
buf, raw, paste = '', b'', False
def draw():
    shown = buf.replace('\n', ' ')
    sys.stdout.write('\x1b[?2004h\x1b[2J\x1b[H' + '-' * 20 + '\r\n❯ ' + shown + '\r\n' + '-' * 20 + '\x1b[2;%dH' % (3 + len(shown)))
    sys.stdout.flush()
draw()
while True:
    b = os.read(0, 4096)
    if not b:
        break
    raw += b
    while raw:
        if raw[:1] == b'\x1b':
            # A whole CSI sequence: the paste markers, else dropped (a terminal
            # report, a focus event) — never typed into the box.
            if len(raw) < 2 or (raw[1:2] == b'[' and len(raw) < 3):
                break
            if raw[1:2] != b'[':
                raw = raw[2:]; continue
            end = next((i for i in range(2, len(raw)) if 0x40 <= raw[i] <= 0x7e), None)
            if end is None:
                break
            seq, raw = raw[:end + 1], raw[end + 1:]
            if seq == b'\x1b[200~':
                paste = True
            elif seq == b'\x1b[201~':
                paste = False
            continue
        c, raw = raw[:1], raw[1:]
        if c == b'\x15':      # ^U clears the box (the pool's warm-up uses it)
            buf = ''
        elif c == b'\r' and not paste:
            with open(log, 'a') as f:
                f.write(json.dumps({"turn": buf}, ensure_ascii=False) + '\n')
            buf = ''
        elif c == b'\r':
            buf += '\n'
        else:
            buf += c.decode('utf-8', 'ignore') if c < b'\x80' else ''
            if c >= b'\x80':   # a UTF-8 sequence: take the rest of it
                n = 1 if c >= b'\xc0' else 0
                n = 2 if c >= b'\xe0' else n
                n = 3 if c >= b'\xf0' else n
                seq, raw = c + raw[:n], raw[n:]
                buf += seq.decode('utf-8', 'ignore')
    draw()
PY
chmod +x "$WORK/b/claude"
# The shadow bin: every script the real one, but the cold spawners log their argv
# (a new task's cold road is dash-raw-session.sh --task without --warm-only; its warm
# road, and every other start, is the real one).
for f in "$BIN"/*; do ln -s "$f" "$WORK/sb/${f##*/}"; done
rm -f "$WORK/sb/dash-issue-session.sh" "$WORK/sb/dash-raw-session.sh"
cat > "$WORK/sb/dash-raw-session.sh" <<SH
#!/bin/bash
case " \$* " in
  *" --warm-only "*) exec bash "$BIN/dash-raw-session.sh" "\$@" ;;
  *" --task "*) ;;
  *) exec bash "$BIN/dash-raw-session.sh" "\$@" ;;
esac
printf '%s\n' "\$*" >> "\$STUB_LOG/spawn"
echo "@999"
SH
# gh: logged — a new task never reaches it.
cat > "$WORK/b/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/gh"
SH
chmod +x "$WORK/b/gh"
cat > "$WORK/sb/dash-issue-session.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/spawn"
echo "@999"
SH
chmod +x "$WORK/sb/dash-issue-session.sh" "$WORK/sb/dash-raw-session.sh"
POOL="$WORK/sb/scratch-pool.sh"; CR="$WORK/sb/fleet-control-read.sh"

export PATH="$WORK/b:$PATH" HOME="$WORK/home" SHELL=/bin/sh STUB_LOG="$WORK/log" FAKE_TURNS="$WORK/turns"
export FLEET_CONF_DIR="$WORK/c" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ADMIT=0 FLEET_ORIGIN_GATE=0
export FLEET_WRAP_LAUNCH="$WORK/b/claude" FLEET_AGENT_CFG=0 FLEET_QUOTA_GATE=0
unset TMUX TMUX_PANE FLEET_SESSION FLEET_SCRATCH_POOL CCQUOTA_FLEET FLEET_START_WARM

git init -q --bare -b master "$WORK/o.git" 2>/dev/null || git init -q --bare "$WORK/o.git"
git clone -q "$WORK/o.git" "$WORK/m" 2>/dev/null
( cd "$WORK/m" && git config user.email t@t && git config user.name t && git checkout -q -b master 2>/dev/null
  echo one > f && git add f && git commit -qm one && git push -q origin master ) || fail "git setup"
mkdir -p "$FLEET_CONF_DIR/fleets/$SESS"
. "$BIN/selftest-repo-fixture.sh"; fx_repo "$FLEET_CONF_DIR" "$SESS" o/a FLEET_MAIN="$WORK/m" FLEET_BASE_BRANCH=master
{ printf 'FLEET_MAX_SESSIONS=20\n'
  printf 'FLEET_SCRATCH_POOL=1\nFLEET_POOL_SETTLE_MIN=1\nFLEET_POOL_STABLE_HITS=2\n'
  printf 'FLEET_POOL_PROBE_TIMEOUT=40\nFLEET_POOL_WARM_TIMEOUT=20\nFLEET_POOL_CLAIM_REFILL_DELAY=600\n'
  printf "FLEET_POOL_DISK_PROBE_CMD='echo 500'\nFLEET_LOAD_PROBE_CMD='echo 0.10'\n"
} > "$FLEET_CONF_DIR/fleets/$SESS/conf"
nt -f /dev/null new-session -d -s "$SESS" -n home -x 120 -y 30 'exec sleep 600' || fail "cannot start the isolated tmux server"
warm_up() {  # every slot one ready entry
  local _
  bash "$POOL" ensure "$SESS" --tick >/dev/null 2>&1
  for _ in $(seq 1 40); do
    [ "$(bash "$POOL" status "$SESS" 2>/dev/null | grep -c '^slot .* want=1 ready=1')" = 2 ] && return 0
    sleep 1
  done
  return 1
}
turns() { python3 -c 'import json,sys; [print(json.loads(l)["turn"]) for l in open(sys.argv[1])]' "$FAKE_TURNS" 2>/dev/null; }
warm_up || fail "the pool did not come up" "$(bash "$POOL" status "$SESS" 2>&1)"

NOTE='（这件事记在 hub 的任务记录上，先开始。）'

if selftest_section 1; then
# ---- A: a new task, answered from the warm o/a slot ---------------------------
body=$'修侧栏的刷新图标\n第二行：它转个不停'
t0=$(ms)
out=$(printf '%s' "$body" | FLEET_CONTROL_TASK=T7 bash "$CR" start "$SESS" new claude o/a '' '' '修侧栏的刷新图标' 2>"$WORK/errA"); rc=$?
[ "$rc" = 0 ] || fail "A the warm start exited $rc" "$out $(cat "$WORK/errA")"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "A one stdout line" "$out"
IFS=$'\t' read -r tag win _name _wt fid tw tr tp <<<"$out"
[ "$tag" = warm ] && case "$win" in @[0-9]*) true ;; *) false ;; esac || fail "A the line is warm + a window" "$out"
case "$tw$tr$tp" in *[!0-9]*|'') fail "A three epoch-ms stamps" "$out" ;; esac
[ "$(o "$win" session_name)" = "$SESS" ] || fail "A the window lives in the fleet"
[ "$(o "$win" window_name)" = '修侧栏的刷新图标' ] || fail "A the window is named after the title" "$(o "$win" window_name)"
[ "$(o "$win" @fleet_id)" = "$fid" ] && [ -n "$fid" ] || fail "A the receipt names the window's @fleet_id"
[ "$(o "$win" @reap_policy)" = merged ] || fail "A a new task closes when merged" "$(o "$win" @reap_policy)"
got=$(turns)
[ "$got" = "$body"$'\n\n'"$NOTE" ] || fail "A the first turn is the body + the note" "got=[$got]"
# The 1 s budget is judged on an idle box only (issue #2476): one sample on a
# loaded CI runner went 1070 ms with nothing changed, and passed at 795 ms on the
# next run. A loaded box still holds the CEILING — a warm start that took the
# seconds of a cold spawn is a regression whatever the load.
cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)
load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
[ -n "$load" ] || load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
budget="${FLEET_START_WARM_BUDGET_MS:-1000}"; ceiling="${FLEET_START_WARM_CEILING_MS:-3000}"
lat="t_prompt came $((tp - t0)) ms after the call: t_window +$((tw - t0)), t_ready +$((tr - t0)) (load $load / $cores cores)"
if [ "$(awk -v l="$load" -v c="$cores" 'BEGIN{print (l <= c / 2) ? 1 : 0}')" = 1 ]; then
  [ $((tp - t0)) -le "$budget" ] || fail "A $lat > $budget on an idle box"
else
  [ $((tp - t0)) -le "$ceiling" ] || fail "A $lat > the $ceiling ceiling"
  printf 'note A: %s — the %s ms budget NOT judged on a loaded box\n' "$lat" "$budget"
fi
[ "$tw" -le "$tr" ] && [ "$tr" -le "$tp" ] || fail "A t_window ≤ t_ready ≤ t_prompt" "$out"
[ ! -s "$WORK/log/spawn" ] || fail "A nothing cold-spawned" "$(cat "$WORK/log/spawn")"
[ "$(o "$win" @task)" = T7 ] || fail "A the window is stamped with its record" "$(o "$win" @task)"
[ ! -s "$WORK/log/gh" ] || fail "A a new task never reaches gh" "$(cat "$WORK/log/gh")"
ok "A new task: warm window in $((tp - t0)) ms (t_window +$((tw - t0)), t_ready +$((tr - t0)); load $load / $cores cores), first turn = body + note"

# ---- B: no record, nothing opens ----------------------------------------------
out=$(printf 'x' | bash "$CR" start "$SESS" new claude o/a '' '' 'no record' 2>"$WORK/errB"); rc=$?
[ "$rc" = 7 ] && [ -z "$out" ] || fail "B a new task with no record exits 7, nothing printed" "rc=$rc $out $(cat "$WORK/errB")"
[ ! -s "$WORK/log/spawn" ] || fail "B nothing spawned" "$(cat "$WORK/log/spawn")"
ok "B no record: nothing opens (exit 7)"

# ---- C: an empty slot is the cold path, byte for byte ------------------------
cold=$(printf 'x' | FLEET_CONTROL_TASK=T8 bash "$CR" start "$SESS" new claude o/a '' '' 'cold one' 2>&1); rc=$?
off=$(printf 'x' | FLEET_CONTROL_TASK=T8 FLEET_START_WARM=0 bash "$CR" start "$SESS" new claude o/a '' '' 'cold one' 2>&1); rc2=$?
[ "$rc" = 0 ] && [ "$rc2" = 0 ] || fail "C the cold starts exited $rc / $rc2" "$cold"
[ "$cold" = "$off" ] && [ "$cold" = '@999' ] || fail "C the empty slot's output is the cold path's" "[$cold] vs [$off]"
[ "$(grep -c -- '--repo o/a .*--task T8 --prompt-file=' "$WORK/log/spawn")" = 2 ] || fail "C the cold spawner ran each time, on the record" "$(cat "$WORK/log/spawn")"
ok "C an empty slot: the cold path, byte for byte FLEET_START_WARM=0"

# ---- D: a seeded HOME scratch takes the HOME entry ---------------------------
: > "$FAKE_TURNS"
t0=$(ms)
out=$(printf '帮我看看 ~/notes' | bash "$CR" start "$SESS" scratch claude - '' '' '看看笔记' 2>"$WORK/errD"); rc=$?
[ "$rc" = 0 ] || fail "D the HOME start exited $rc" "$out $(cat "$WORK/errD")"
IFS=$'\t' read -r win _name _wt fid tw tr tp <<<"$out"
case "$tp" in ''|*[!0-9]*) fail "D the 7-field receipt" "$out" ;; esac
[ "$(o "$win" @norepo)" = 1 ] && [ "$(o "$win" session_name)" = "$SESS" ] || fail "D the HOME entry, in the fleet"
[ "$(turns)" = '帮我看看 ~/notes' ] || fail "D the first turn is the text alone" "$(turns)"
ok "D a HOME task: the HOME entry, the text alone, in $((tp - t0)) ms"

# ---- E: an entry that will not take input is closed, then the cold path -------
warm_up || fail "E the pool did not refill" "$(bash "$POOL" status "$SESS" 2>&1)"
bad=$(nt list-windows -t "$SESS-pool" -F '#{window_id} #{@repo}' | awk '$2 == "o/a" { print $1 }')
nt send-keys -t "$bad" -l 'half a draft'; sleep 0.5
: > "$WORK/log/spawn"; : > "$FAKE_TURNS"
out=$(printf 'y' | FLEET_CONTROL_TASK=T9 FLEET_SUBMIT_WAIT_SECS=1 bash "$CR" start "$SESS" new claude o/a '' '' 'busy one' 2>"$WORK/errE"); rc=$?
[ "$rc" = 0 ] && [ "$out" = '@999' ] || fail "E fell back to the cold path" "rc=$rc $out"
nt list-windows -a -F '#{window_id}' | grep -qx "$bad" && fail "E the entry that would not take input is still open"
[ ! -s "$FAKE_TURNS" ] || fail "E nothing was submitted into it" "$(turns)"
ok "E an entry with a draft in it: nothing typed, closed, cold path"

# ---- F: the controller turns the receipt into the operation's result ----------
out=$(STUB_SESS="$SESS" python3 - "$BIN" <<'PY'
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import fleet_control as fc
tmp = tempfile.mkdtemp()
c = fc.Control.__new__(fc.Control)
class Store:
    root = __import__("pathlib").Path(tmp)
    def connect(self):
        import sqlite3
        db = sqlite3.connect(os.path.join(tmp, "s.db")); db.row_factory = sqlite3.Row
        return db
c.store = Store()
with c.store.connect() as db:
    db.execute("CREATE TABLE operations (id TEXT, action TEXT, request TEXT, status TEXT, result TEXT, created REAL, updated REAL)")
    req = {"fleet_id": "f", "action": "worker_start", "params": {"kind": "new", "title": "t", "body": "b", "repo": "o/a"}}
    db.execute("INSERT INTO operations VALUES ('0f0e0d0c-0b0a-4908-8706-050403020100','worker_start',?,'accepted','',?,?)", (json.dumps(req), fc.now() - 0.2, fc.now()))
fleet = {"name": "s", "fleet_id": "f"}
c.fleet = lambda fid: fleet
calls = []
def adapter(*a, **k):
    calls.append(a)
    if a[0] == "start":
        return 0, b"warm\t@5\tt\t/wt/a-scratch-3\tFID\t1000\t1100\t1200\n", b""
    return 1, b"", b""
c.adapter = adapter
c.workers = lambda fl, w="": {"observed_at": 1, "workers": [{"window_id": "@5", "scratch": True, "issue": None, "key": "a:scratch-3", "repo": "o/a"}]}
c.watch_ready = lambda *a: calls.append(("watch",))
c.execute("0f0e0d0c-0b0a-4908-8706-050403020100")
with c.store.connect() as db:
    row = db.execute("SELECT status, result FROM operations WHERE id='0f0e0d0c-0b0a-4908-8706-050403020100'").fetchone()
r = json.loads(row["result"])
print(row["status"], r.get("window_id"), r.get("key"),
      ",".join("%s=%s" % (k, r["timing"][k]) for k in sorted(r["timing"]) if k != "t_accepted"),
      "t_accepted" in r["timing"], any(x[0] == "watch" for x in calls))
print(open(os.path.join(tmp, "ops.log")).read().strip().splitlines()[-1])
PY
)
first=$(printf '%s\n' "$out" | head -1); logl=$(printf '%s\n' "$out" | sed -n 2p)
[ "$first" = 'succeeded @5 a:scratch-3 t_prompt=1200,t_ready=1100,t_window=1000 True False' ] || fail "F the warm result" "$out"
case "$logl" in *'succeeded window=@5 timing t_accepted='*' t_prompt=1200 t_ready=1100 t_window=1000') ;; *) fail "F ops.log carries the timing" "$logl" ;; esac
ok "F the controller: window_id / key / timing; ops.log has the timing line"

fi

if selftest_section 2; then
# ---- G: an unseeded HOME start (`fleet claude`, issue #2339) takes the HOME entry
warm_up || fail "G the pool did not refill" "$(bash "$POOL" status "$SESS" 2>&1)"
: > "$WORK/log/spawn"; : > "$FAKE_TURNS"
t0=$(ms)
out=$(bash "$CR" start "$SESS" scratch claude - '' '' '' </dev/null 2>"$WORK/errG"); rc=$?
[ "$rc" = 0 ] || fail "G the unseeded HOME start exited $rc" "$out $(cat "$WORK/errG")"
IFS=$'\t' read -r win _name _wt fid tw _ <<<"$out"
case "$tw" in ''|*[!0-9]*) fail "G the 7-field receipt (t_window)" "$out" ;; esac
[ "$(o "$win" @norepo)" = 1 ] && [ "$(o "$win" session_name)" = "$SESS" ] || fail "G the HOME entry, in the fleet"
[ -n "$fid" ] && [ "$(o "$win" @fleet_id)" = "$fid" ] || fail "G the receipt names the window's @fleet_id" "$out"
[ "$(o "$win" @fleet_role)" = worker ] || fail "G the claimed window is a worker" "$(o "$win" @fleet_role)"
[ ! -s "$FAKE_TURNS" ] || fail "G nothing typed into it" "$(turns)"
[ $(($(ms) - t0)) -le 3000 ] || fail "G the warm HOME start took $(($(ms) - t0)) ms (> 3000)"
ok "G an unseeded HOME start: the HOME entry in $(($(ms) - t0)) ms, nothing typed"

# ---- H: the controller finds a keyless no-repo session by its @fleet_id --------
# The receipt of a no-repo start (cold here): no @raw, no key — only its identity.
# Before #2339 the `scratch` test missed it: UNKNOWN, and the window stayed open.
out=$(python3 - "$BIN" <<'PY'
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import fleet_control as fc
FID = "c63813a3-3f3f-4cea-bec6-c12705d98fc3"
def run(rows):
    tmp = tempfile.mkdtemp()
    c = fc.Control.__new__(fc.Control)
    class Store:
        root = __import__("pathlib").Path(tmp)
        def connect(self):
            import sqlite3
            db = sqlite3.connect(os.path.join(tmp, "s.db")); db.row_factory = sqlite3.Row
            return db
    c.store = Store()
    with c.store.connect() as db:
        db.execute("CREATE TABLE operations (id TEXT, action TEXT, request TEXT, status TEXT, result TEXT, created REAL, updated REAL)")
        req = {"fleet_id": "f", "action": "worker_start", "params": {"kind": "scratch", "no_repo": True, "agent": "claude"}}
        db.execute("INSERT INTO operations VALUES ('0f0e0d0c-0b0a-4908-8706-050403020100','worker_start',?,'accepted','',?,?)", (json.dumps(req), fc.now() - 0.2, fc.now()))
    c.fleet = lambda fid: {"name": "s", "fleet_id": "f"}
    calls = []
    def adapter(*a, **k):
        calls.append(a)
        if a[0] == "start":
            return 0, ("@7\tnorepo\t/home\t%s\n" % FID).encode(), b""
        return 0, b"", b""
    c.adapter = adapter
    c.workers = lambda fl, w="": {"observed_at": 1, "workers": rows}
    c.watch_ready = lambda *a: None
    c.execute("0f0e0d0c-0b0a-4908-8706-050403020100")
    with c.store.connect() as db:
        row = db.execute("SELECT status, result FROM operations").fetchone()
    stops = [a[2] for a in calls if a[0] == "stop"]
    return row["status"], json.loads(row["result"]), stops
row = {"window_id": "@7", "scratch": False, "issue": None, "key": None, "repo": None, "identity": FID}
st, r, stops = run([row])
print(st, r.get("window_id"), "key" in r, stops)
st, r, stops = run([])
print(st, r["error"]["code"], stops, r["error"]["message"])
PY
)
l1=$(printf '%s\n' "$out" | sed -n 1p); l2=$(printf '%s\n' "$out" | sed -n 2p)
[ "$l1" = 'succeeded @7 False []' ] || fail "H a keyless no-repo session matched by @fleet_id" "$out"
case "$l2" in "unknown UNKNOWN_OUTCOME ['fid:c63813a3-3f3f-4cea-bec6-c12705d98fc3'] "*"its window was closed (fid:c63813a3-3f3f-4cea-bec6-c12705d98fc3)") ;; *) fail "H a miss closes the window it opened (fid:)" "$out" ;; esac
ok "H the controller: a no-repo start matched by identity (window_id, no key); a miss closes it"


# ---- L: `fleet codex` with only Claude in the HOME slot: cold codex (issue #2403)
warm_up || fail "L the pool did not refill" "$(bash "$POOL" status "$SESS" 2>&1)"
hwarm=$(nt list-windows -a -F '#{window_id} #{@norepo} #{@pool}' | awk '$2 == 1 && $3 == 1 { print $1; exit }')
[ -n "$hwarm" ] || fail "L a Claude HOME entry is ready" "$(nt list-windows -a -F '#{window_id} #{session_name} #{@norepo} #{@pool} #{@pool_agent}')"
out=$(bash "$CR" start "$SESS" scratch codex - '' '' '' </dev/null 2>"$WORK/errL"); rc=$?
[ "$rc" = 0 ] || fail "L the codex HOME start exited $rc" "$out $(cat "$WORK/errL")"
IFS=$'\t' read -r win _name _wt fid _ <<<"$out"
case "$win" in @[0-9]*) ;; *) fail "L the receipt names a window" "$out" ;; esac
[ "$win" != "$hwarm" ] || fail "L the Claude entry was handed out for codex"
[ "$(o "$win" @cc_agent)" = codex ] || fail "L the session opened runs codex" "[$(o "$win" @cc_agent)]"
[ "$(o "$win" @norepo)" = 1 ] && [ "$(o "$win" session_name)" = "$SESS" ] || fail "L a HOME session in the fleet"
[ "$(o "$hwarm" @pool)" = 1 ] && [ "$(o "$hwarm" @pool_agent)" = claude ] || fail "L the Claude entry is still in the pool"
ok "L codex asked, only Claude warm: codex opened cold (@cc_agent=codex), the Claude entry left in the pool"

# ---- M: a warm entry that runs another agent than the one asked is never handed out
out=$(bash "$CR" start "$SESS" scratch claude - '' '' '' </dev/null 2>/dev/null)
[ "$(printf '%s' "$out" | cut -f1)" = "$hwarm" ] || fail "M setup: claude takes the Claude entry" "$out"
warm_up || fail "M the pool did not refill" "$(bash "$POOL" status "$SESS" 2>&1)"
hwarm=$(nt list-windows -a -F '#{window_id} #{@norepo} #{@pool}' | awk '$2 == 1 && $3 == 1 { print $1; exit }')
nt set-window-option -t "$hwarm" @cc_agent codex      # the entry's launcher says codex, its slot says claude
out=$(bash "$CR" start "$SESS" scratch claude - '' '' '' </dev/null 2>"$WORK/errM"); rc=$?
IFS=$'\t' read -r win _ <<<"$out"
[ "$rc" = 0 ] && [ "$win" != "$hwarm" ] || fail "M the mismatched entry was handed out" "rc=$rc $out"
nt list-windows -a -F '#{window_id}' | grep -qxF "$hwarm" && fail "M the mismatched entry is closed"
grep -q 'runs codex, not claude' "$WORK/errM" || fail "M it says why" "$(cat "$WORK/errM")"
[ "$(o "$win" @cc_agent)" = claude ] || fail "M the cold session is a claude" "[$(o "$win" @cc_agent)]"
ok "M a warm entry running codex is closed for a claude ask; claude opened cold"

# ---- N: the controller: a session of another agent than asked fails, closed --
out=$(python3 - "$BIN" <<'PY'
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import fleet_control as fc
FID = "c63813a3-3f3f-4cea-bec6-c12705d98fc3"
def run(asked, got, stop_rc=0):
    tmp = tempfile.mkdtemp()
    c = fc.Control.__new__(fc.Control)
    class Store:
        root = __import__("pathlib").Path(tmp)
        def connect(self):
            import sqlite3
            db = sqlite3.connect(os.path.join(tmp, "s.db")); db.row_factory = sqlite3.Row
            return db
    c.store = Store()
    with c.store.connect() as db:
        db.execute("CREATE TABLE operations (id TEXT, action TEXT, request TEXT, status TEXT, result TEXT, created REAL, updated REAL)")
        req = {"fleet_id": "f", "action": "worker_start", "params": {"kind": "scratch", "no_repo": True, "agent": asked}}
        db.execute("INSERT INTO operations VALUES ('0f0e0d0c-0b0a-4908-8706-050403020100','worker_start',?,'accepted','',?,?)", (json.dumps(req), fc.now() - 0.2, fc.now()))
    c.fleet = lambda fid: {"name": "s", "fleet_id": "f", "agent": "claude"}
    calls = []
    def adapter(*a, **k):
        calls.append(a)
        if a[0] == "start":
            return 0, ("@7\tnorepo\t/home\t%s\n" % FID).encode(), b""
        return stop_rc, b"", b""
    c.adapter = adapter
    c.workers = lambda fl, w="": {"observed_at": 1, "workers": [{"window_id": "@7", "scratch": False, "issue": None,
                                                               "key": None, "repo": None, "identity": FID, "agent": got}]}
    c.watch_ready = lambda *a: None
    c.execute("0f0e0d0c-0b0a-4908-8706-050403020100")
    with c.store.connect() as db:
        row = db.execute("SELECT status, result FROM operations").fetchone()
    r = json.loads(row["result"])
    return row["status"], (r.get("error") or {}).get("code", r.get("window_id")), [a[2] for a in calls if a[0] == "stop"]
print(*run("codex", "codex"))
print(*run("codex", "claude"))
print(*run("codex", "claude", stop_rc=1))
print(*run("claude", "claude"))
PY
)
[ "$(printf '%s\n' "$out" | sed -n 1p)" = 'succeeded @7 []' ] || fail "N codex asked, codex opened: succeeded" "$out"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = "failed EXECUTION_FAILED ['fid:c63813a3-3f3f-4cea-bec6-c12705d98fc3']" ] || fail "N codex asked, claude opened: failed + closed" "$out"
[ "$(printf '%s\n' "$out" | sed -n 3p)" = "unknown UNKNOWN_OUTCOME ['fid:c63813a3-3f3f-4cea-bec6-c12705d98fc3']" ] || fail "N a close that fails is unknown" "$out"
[ "$(printf '%s\n' "$out" | sed -n 4p)" = 'succeeded @7 []' ] || fail "N claude unchanged" "$out"
ok "N the controller: another agent than asked is closed and the start failed; claude unchanged"

fi

printf 'fleet-start-warm: %d passed (section %s/2)\n' "$pass" "$SELFTEST_SECTION"
