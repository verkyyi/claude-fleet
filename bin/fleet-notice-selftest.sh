#!/bin/bash
# fleet-notice-selftest.sh — the fleet's one on-screen notice and its one book (T675,
# T701): bin/fleet_notice.py (fleet-notice.sh, fleet_notice in fleet-client-core.sh),
# the 看台's message row that draws it (bin/fleet-topbar.py inbox), and what feeds
# the book (bin/fleet_notify.py, bin/fleet_hub_common.py notices_cell).
#
#   A. RECORD   every notice a row of $FLEET_CONF_DIR/logs/notices.ndjson; the same
#               level + text within 10 s one row; a row older than 7 days goes on the
#               next write; `list` newest first, `--n`; `unread` counts errors since
#               `read` (the page opening); `seen <tag>`.
#   B. ROW      fleet-topbar.py inbox-text: an error until seen or 30 s, a warn 6 s; 「✦ N ·
#               ⌘P」, a phone's 「✦ N」 in 45 columns; FLEET_GLYPHS=ascii; seen, it
#               folds; the top line (fit) says no reminder at 45 / 80 / 140.
#   D. PANEL    ⌘P's FIRST row 「✦ 消息 N」, found by the words 消息 / message; a
#               click on the message row opens the page — fleet binds no key for it.
#   E. BOOK     a notice, an alert, ask · stuck · done (fleet_notify.book), a result
#               nobody took: six unseen in five classes; read <id> one fewer, an
#               orphan read in its own book too; the cell → fleet_hub_common → a
#               cache line counted by another home, a later read mark seeing it.
#   C. CLIENTS  on an isolated server with two 看台 and a plain client, each a pty:
#               --client draws on that 看台 only (@view_notice + hold), a second
#               notice while the first is live says more=1, --all reaches both
#               看台, a plain client gets a display-message HELD for its tier
#               (never tmux's ~0.75 s default), fleet_notice (fleet-client-core.sh)
#               and fleet-notice.sh reach the same road.
#   G. GUARD    a test's process never writes under the login's real conf dir (T909):
#               FLEET_SELFTEST_REAL_CONF stands in for it — `guard` says rc 3 and
#               `notify` records nothing there, run by hand (no FLEET_NOTICE_FORBID,
#               this file up the chain) and as a pane of a -S tmux server in a temp
#               dir; a book outside it is written as before.
# tmux absent → C SKIP.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
NP="$BIN/fleet_notice.py"; TB="$BIN/fleet-topbar.py"
fails=0; pass=0
fail() { fails=$((fails + 1)); printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; return 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/notice-selftest.XXXXXX") || exit 2
SD=$(mktemp -d /tmp/nst.XXXXXX) || exit 2
RT=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -) command -v tmux || :)
cleanup() { [ -n "$RT" ] && "$RT" -S "$SD/s" kill-server 2>/dev/null; rm -rf "$WORK" "$SD"; }
trap cleanup EXIT
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh NO_COLOR=1 FLEET_STATUS_G="$WORK/g"
mkdir -p "$FLEET_STATUS_G"  # no real remote notice cache in the first fixture
unset TMUX TMUX_PANE FLEET_NOTICE_TAG

# --- A. the record -------------------------------------------------------------------
LOG="$FLEET_CONF_DIR/logs/notices.ndjson"
python3 "$NP" notify warn 'first one' --no-draw --source t
python3 "$NP" notify warn 'first one' --no-draw --source t
python3 "$NP" notify error 'first one' --no-draw --next 'do this' --tag T1
[ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] || fail "A a repeat within 10 s is one row; another level is its own" "$(cat "$LOG")"
python3 "$NP" seen T1 || fail "A seen T1: the tagged row is there"
python3 "$NP" seen T2 && fail "A seen T2: no such tag"
[ "$(python3 "$NP" unread)" = 2 ] || fail "A both rows unseen (every kind counts, T701)"
python3 "$NP" read
[ "$(python3 "$NP" unread)" = 0 ] || fail "A read clears the unread count"
python3 "$NP" notify info 'second' --no-draw
out=$(python3 "$NP" list)
[ "$(printf '%s\n' "$out" | head -n 1 | grep -c 'second')" = 1 ] || fail "A list is newest first" "$out"
printf '%s\n' "$out" | grep -q '错误 first one — do this' || fail "A list carries level · text — next" "$out"
[ "$(python3 "$NP" list --n 1 | wc -l | tr -d ' ')" = 1 ] || fail "A list --n 1 is one row"
old=$(( $(date +%s) - 8 * 86400 ))
{ printf '{"ts":%s,"level":"info","text":"ancient"}\n' "$old"; cat "$LOG"; } > "$LOG.x" && mv "$LOG.x" "$LOG"
python3 "$NP" notify info 'third' --no-draw
grep -q ancient "$LOG" && fail "A a row older than 7 days goes on the next write" "$(cat "$LOG")"
[ "$(wc -l < "$LOG" | tr -d ' ')" = 4 ] || fail "A the prune keeps the week's rows" "$(cat "$LOG")"
[ "$(python3 "$NP" list --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 4 ] \
  || fail "A list --json is every row"
[ "$fails" = 0 ] && st_pass "A every notice recorded once, a week kept, newest first, unread / read / seen"

# --- B. the message row (T701): tiers, fit, the top line clean -------------------------
f0=$fails
export FLEET_STATUS_G="$WORK/g"; mkdir -p "$FLEET_STATUS_G"
B2="$WORK/b2"; mkdir -p "$B2"
ib() { FLEET_CONF_DIR="$B2" python3 "$TB" inbox-text "$1" "now=$2"; }
FLEET_CONF_DIR="$B2" python3 "$NP" notify warn 'heads up' --no-draw
T0=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["ts"])' "$B2/logs/notices.ndjson")
case "$(ib 80 "$T0")" in *'▲ heads up'*'✦ 1 · ⌘P'*) ;; *) fail "B a warn is on the message row with ✦ 1 · ⌘P" "$(ib 80 "$T0")" ;; esac
[ "$(ib 80 "$(python3 -c "print($T0 + 7)")")" = - ] || fail "B a warn folds after 6 s"
FLEET_CONF_DIR="$B2" python3 "$NP" notify error '暂停开新：内存紧张' --next '关掉一个会话再试' --no-draw
case "$(ib 140 "$(python3 -c "print($T0 + 20)")")" in *'✖ 暂停开新：内存紧张 — 关掉一个会话再试'*'✦ 2 · ⌘P'*) ;;
  *) fail "B an unseen error stays its 30 s — reason · next · ✦ N" "$(ib 140 "$(python3 -c "print($T0 + 20)")")" ;; esac
# …and then goes by itself (task NFVN), still unseen in 消息
[ "$(ib 140 "$(python3 -c "print($T0 + 40)")")" = - ] || fail "B an unseen error folds after its 30 s" "$(ib 140 "$(python3 -c "print($T0 + 40)")")"
[ "$(FLEET_NOTICE_STICKY_SECS=60 ib 140 "$(python3 -c "print($T0 + 40)")")" != - ] || fail "B FLEET_NOTICE_STICKY_SECS=60 holds it longer"
w=$(python3 -c 'import sys,unicodedata as u; print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in sys.argv[1]))' "$(ib 45 "$T0")")
[ "$w" -le 45 ] || fail "B the row fits a 45-column phone (got $w)"
case "$(ib 45 "$T0")" in *⌘P*) fail "B a phone's row says ✦ N, no ⌘P" "$(ib 45 "$T0")" ;; esac
FLEET_CONF_DIR="$B2" python3 "$NP" read
[ "$(ib 80 "$(python3 -c "print($T0 + 1000)")")" = - ] || fail "B seen, the row folds"
printf '{"title":"t","state":"working","orphans":3}' > "$WORK/rec.json"
for c in 45 80 140; do
  case "$(python3 "$TB" fit "$c" "$WORK/rec.json")" in *未读*|*无主*|*✦*|*✖*) fail "B the top line ($c cols) says a reminder" "$(python3 "$TB" fit "$c" "$WORK/rec.json")" ;; esac
done
FLEET_GLYPHS=ascii FLEET_CONF_DIR="$B2" python3 "$NP" notify error 'ascii one' --no-draw
case "$(FLEET_GLYPHS=ascii ib 80 "$(python3 -c "print($T0 + 20)")")" in *' x ascii one'*'* 1'*) ;;
  *) fail "B FLEET_GLYPHS=ascii: letters" "$(FLEET_GLYPHS=ascii ib 80 "$(python3 -c "print($T0 + 20)")")" ;; esac
[ "$fails" = "$f0" ] && st_pass "B the message row: error until seen or 30 s, warn 6 s, ✦ N · ⌘P, fits 45 columns, ascii; the top line says no reminder"

# --- B2. the one-line 看台 (task EQBE): the message on the top line, its time left, ⌃] x
f0=$fails
B3="$WORK/b3"; mkdir -p "$B3"
il() { FLEET_CONF_DIR="$B3" python3 "$TB" inline-text "$1" "now=$2"; }
FLEET_CONF_DIR="$B3" python3 "$NP" notify error '暂停开新：内存紧张' --no-draw
T3=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["ts"])' "$B3/logs/notices.ndjson")
case "$(il 140 "$(python3 -c "print($T3 + 18)")")" in ' tokenman '*'暂停开新：内存紧张'*'剩 12 秒'*'⌃] x 关闭'*) ;;
  *) fail "B2 the line: the brand, the message, 剩 N 秒, ⌃] x 关闭" "$(il 140 "$(python3 -c "print($T3 + 18)")")" ;; esac
w=$(python3 -c 'import sys,unicodedata as u; print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in sys.argv[1]))' "$(il 45 "$T3")")
[ "$w" -le 45 ] || fail "B2 the line fits a 45-column phone (got $w)"
[ "$(il 140 "$(python3 -c "print($T3 + 40)")")" = - ] || fail "B2 past its time the line is the session's again"
FLEET_CONF_DIR="$B3" python3 "$NP" dismiss || fail "B2 dismiss with a live message is rc 0"
[ "$(il 140 "$T3")" = - ] || fail "B2 ⌃] x: dismissed, the line is the session's again" "$(il 140 "$T3")"
FLEET_CONF_DIR="$B3" python3 "$NP" dismiss && fail "B2 dismiss with nothing live is rc 1"
[ "$fails" = "$f0" ] && st_pass "B2 one line (EQBE): the brand, the message, 剩 N 秒, ⌃] x 关闭; fits 45 columns; dismiss reads it"

# --- D. ⌘P's first row 「✦ 消息」 (fleet takes no key of its own for it) ------------------
f0=$fails
python3 "$NP" notify error 'one unread' --no-draw
out=$(python3 - "$BIN" <<'PY2'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_view as fv
rows = fv.panel_rows([], "", set(), cmds=("new", "quit"))
print(" ".join(e.get("cmd", "?") for e in rows))
print(next((fv.cmd_icons()["notices"] + " " + e["text"] for e in rows if e.get("cmd") == "notices"), "-"))   # T923: the icon is the table's
for q in ("消息", "message", "zzz"):
    print(q, "notices" in [e.get("cmd") for e in fv.panel_rows([], q, set(), cmds=("new", "quit"))])
PY2
)
case "$(printf '%s\n' "$out" | sed -n 1p)" in 'notices '*) ;; *) fail "D the 消息 row is the panel's first" "$out" ;; esac
n=$(python3 "$NP" unread)
printf '%s\n' "$out" | sed -n 2p | grep -q "✦ 消息 $n" || fail "D the row counts the unseen ($n)" "$out"
printf '%s\n' "$out" | grep -qx '消息 True' || fail "D the words 消息 find it" "$out"
printf '%s\n' "$out" | grep -qx 'message True' || fail "D the words message find it" "$out"
printf '%s\n' "$out" | grep -qx 'zzz False' || fail "D other words do not" "$out"
grep -q 'notices' "$BIN/dash-keymap.sh" && fail "D dash-keymap.sh names a notices key — fleet takes no key for it"
grep -q "mouse_status_range},inbox" "$BIN/fleet_view.py" || fail "D a click on the message row opens the page"
[ "$fails" = "$f0" ] && st_pass "D ⌘P's first row 「✦ 消息 N」, found by 消息 / message, a click on the row; no key of its own"

# --- E. one book (T701): six kinds, read by id, the other machines --------------------
f0=$fails
E2="$WORK/e2"; mkdir -p "$E2/global"; G2="$WORK/g2"; mkdir -p "$G2"
en() { FLEET_CONF_DIR="$E2" FLEET_STATUS_G="$G2" python3 "$NP" "$@"; }
en notify info '一条提示' --no-draw
en notify error '告警：磁盘红线' --no-draw --kind alert --source alert:appear
FLEET_CONF_DIR="$E2" FLEET_STATUS_G="$G2" FLEET_NOTIFY=1 python3 - "$BIN" <<'PY2'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_notify as fn
for k, t in (("ask", "#1 在问你"), ("stuck", "#2 卡住了"), ("done", "#3 做完了")):
    fn.book({"kind": k, "title": t, "body": "mac-a", "key": "u/" + k})
PY2
printf '{"ts":%s,"child_key":"r:issue-9","state":"REAPED","pr":"","summary":"nobody"}\n' "$(date +%s)" > "$E2/global/orphan-reports.ndjson"
page=$(FLEET_CONF_DIR="$E2" FLEET_STATUS_G="$G2" python3 "$NP" list --json >/dev/null; en unread)
[ "$page" = 6 ] || fail "E six kinds, six unseen (got $page)" "$(en list)"
pg=$(FLEET_CONF_DIR="$E2" FLEET_STATUS_G="$G2" python3 - "$BIN" <<'PY2'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_notice as N
ms = N.inbox()
print(" ".join(sorted({m["cls"] for m in ms})))
print([m["id"] for m in ms if m["cls"] == "info"][0])
print([m["wid"] for m in ms if m["cls"] == "ask"][0])
PY2
)
[ "$(printf '%s\n' "$pg" | sed -n 1p)" = "ask done error info orphan" ] || fail "E the classes ask error orphan done info (+ the alert's error)" "$pg"
[ "$(printf '%s\n' "$pg" | sed -n 3p)" = u/ask ] || fail "E a session's message keeps its wid (g goes there)" "$pg"
en read "$(printf '%s\n' "$pg" | sed -n 2p)"
[ "$(en unread)" = 5 ] || fail "E read <id>: one fewer" "$(en unread)"
oid=$(FLEET_CONF_DIR="$E2" python3 "$BIN/fleet-orphan-reports.py" list | cut -f1)
en read "$oid"
[ "$(FLEET_CONF_DIR="$E2" python3 "$BIN/fleet-orphan-reports.py" count)" = 0 ] || fail "E read on a result nobody took reads it in its own book too"
[ "$(en unread)" = 4 ] || fail "E … and it is seen" "$(en unread)"
# the inventory cell → the hub's parse → another home's cache line
cellv=$(en cell)
row=$(python3 - "$BIN" "$cellv" <<'PY2'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_hub_common as H
n = H.notices_cell(sys.argv[2])
print(len(n["rows"]), n["mark"])
r = n["rows"][0]
print("\x1f".join(str(v) for v in (r["id"], "mac-b", n["mark"], r["ts"], r["level"], r["kind"], r["sub"], r["wid"], r["text"], "0")))
PY2
)
[ "$(printf '%s\n' "$row" | sed -n 1p | cut -d' ' -f1)" = 4 ] || fail "E the cell carries the four unseen (no orphan)" "$row"
printf '%s\n' "$row" | sed -n 2p > "$G2/notices_fl"
F2="$WORK/f2"; mkdir -p "$F2"
[ "$(FLEET_CONF_DIR="$F2" FLEET_STATUS_G="$G2" python3 "$NP" unread)" = 1 ] || fail "E another home counts the far machine's message" "$(cat "$G2/notices_fl")"
# that machine read later than its message: seen everywhere (the latest mark wins)
python3 -c 'import sys; p=sys.argv[1]; f=open(p).read().split("\x1f"); f[2]=str(int(f[3])+5); f[0]="-"; open(p,"a").write("\x1f".join(f))' "$G2/notices_fl"
[ "$(FLEET_CONF_DIR="$F2" FLEET_STATUS_G="$G2" python3 "$NP" unread)" = 0 ] || fail "E a later read mark on any machine sees it here" "$(cat "$G2/notices_fl")"
[ "$fails" = "$f0" ] && st_pass "E one book: a notice, an alert, ask · stuck · done, a result nobody took; read <id>; the cell → the hub → another home, the latest mark"

# --- C. who sees it ---------------------------------------------------------------------
if [ -z "$RT" ]; then
  printf 'selftest: tmux absent — C SKIP\n' >&2
else
  f0=$fails
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\necho "$*" >> "%s"\nif [ "$1" = -L ]; then shift 2; fi\nexec "%s" -S "%s" "$@"\n' "$WORK/calls" "$RT" "$SD/s" > "$WORK/bin/tmux"
  chmod +x "$WORK/bin/tmux"
  TT() { "$RT" -S "$SD/s" "$@"; }
  TT -f /dev/null new-session -d -s fl -x 100 -y 30 'exec sleep 600'
  TT set -g message-limit 100
  for v in a b; do TT new-session -d -t fl -s "fl@view-$v"; TT set -t "fl@view-$v" @view_thin "$v"; done
  TT new-session -d -t fl -s plain
  cat > "$WORK/term.py" <<'PY'
import os, pty, select, sys, time
tmux, sock, sess = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-S", sock, "attach", "-t", sess])
end = time.time() + 60
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            os.read(fd, 65536)
        except OSError:
            break
PY
  # double-forked: the server's end ends them (no job of ours to reap)
  for s in fl@view-a fl@view-b plain; do ( (cd / && exec python3 "$WORK/term.py" "$RT" "$SD/s" "$s" </dev/null >/dev/null 2>&1) & ); done
  i=0; while [ "$i" -lt 50 ] && [ "$(TT list-clients 2>/dev/null | wc -l | tr -d ' ')" -lt 3 ]; do sleep 0.1; i=$((i + 1)); done
  cl() { TT list-clients -F '#{client_session} #{client_name}' | awk -v s="$1" '$1 == s { print $2 }'; }
  CA=$(cl fl@view-a); CP=$(cl plain)
  if [ -z "$CA" ] || [ -z "$CP" ]; then
    printf 'selftest: the pty clients never attached — C SKIP\n' >&2
  else
    vn() { TT show -qv -t "fl@view-$1:" @view_notice; }
    dec() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_notice as N; print(N.decode(sys.argv[2]).get(sys.argv[3], ""))' "$BIN" "$1" "$2"; }
    PATH="$WORK/bin:$PATH" python3 "$NP" notify error 'only a' --client "$CA" --sock fl
    [ "$(dec "$(vn a)" text)" = 'only a' ] || fail "C --client draws on its 看台" "$(vn a)"
    [ -z "$(vn b)" ] || fail "C --client never draws on another 看台" "$(vn b)"
    [ "$(TT show -qv -t 'fl@view-a:' @view_notice_hold)" -ge "$(( $(date +%s) + 8 ))" ] || fail "C an error's hold is ≥ 10 s out"
    PATH="$WORK/bin:$PATH" bash -c ". '$BIN/fleet-client-core.sh'; fleet_notice warn 'second on a' --client '$CA' --sock fl"
    [ "$(dec "$(vn a)" text)" = 'second on a' ] && [ "$(dec "$(vn a)" more)" = 1 ] \
      || fail "C a second while the first is live: the newest, more=1 (fleet_notice in the core)" "$(vn a)"
    PATH="$WORK/bin:$PATH" bash "$BIN/fleet-notice.sh" warn 'everyone' --all --sock fl
    [ "$(dec "$(vn b)" text)" = everyone ] || fail "C --all reaches every 看台 (fleet-notice.sh)"
    PATH="$WORK/bin:$PATH" python3 "$NP" notify warn 'plain one' --client "$CP" --sock fl
    TT show-messages | grep -q 'plain one' || fail "C a plain client gets a display-message" "$(TT show-messages | tail -3)"
    [ -z "$(TT show -qv -t 'plain:' @view_notice)" ] || fail "C a plain client's session is not dressed as a 看台"
    # held for the tier, never tmux's 0.75 s: the call carries -d <tier ms>
    grep -q 'display-message -c [^ ]* -d 6000 ' "$WORK/calls" || fail "C the plain client's message is held 6 s (-d 6000)" "$(grep display-message "$WORK/calls")"
    [ "$fails" = "$f0" ] && st_pass "C --client only its 看台, the newest + more, --all every 看台, a plain client a held display-message"
  fi
fi

# --- G. a test never writes the real record (T909) ---------------------------------------
f0=$fails; RC="$WORK/realconf"; mkdir -p "$RC/logs"
# outside the gate's environment: what is left is this selftest up the chain
G() { env -u FLEET_NOTICE_FORBID -u FLEET_NOTICE_FORBID_HIT -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_REAL_CONF="$RC" "$@"; }
out=$(G python3 "$NP" guard "$RC/logs/session-exit.log" 2>&1); rc=$?
[ "$rc" = 3 ] || fail "G guard: a test aiming at the real conf dir is refused (rc 3)" "rc=$rc $out"
case "$out" in *'run under a selftest'*fleet-notice-selftest.sh*) ;; *) fail "G guard names the selftest up the chain" "$out" ;; esac
G python3 "$NP" guard "$WORK/conf/logs/session-exit.log" 2>/dev/null || fail "G guard: the test's own conf is allowed"
G FLEET_CONF_DIR="$RC" python3 "$NP" notify error 'a test row' --no-draw 2>/dev/null
[ ! -e "$RC/logs/notices.ndjson" ] || fail "G notify: a test wrote the real record" "$(cat "$RC/logs/notices.ndjson")"
# a pane of a test's tmux server (a -S socket in a temp dir): refused on that alone
out=$(env -u FLEET_NOTICE_FORBID -u FLEET_SELFTEST_ROOT TMUX="$SD/s,1,0" FLEET_SELFTEST_REAL_CONF="$RC" \
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_notice as N
N._TEST_WHY = None; import subprocess; N.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0, "", "")
print(N.test_why())' "$BIN" 2>&1)
case "$out" in *"test's tmux server"*) ;; *) fail "G a -S temp socket is a test's" "$out" ;; esac
out=$(env -u FLEET_NOTICE_FORBID -u FLEET_SELFTEST_ROOT TMUX="/private/tmp/tmux-$(id -u)/fleet,1,0" \
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_notice as N
import subprocess; N.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0, "", "")
print("why=" + N.test_why())' "$BIN" 2>&1)
[ "$out" = "why=" ] || fail "G a fleet's -L socket is not a test's" "$out"
[ "$fails" = "$f0" ] && st_pass "G a test's process (by hand, or a -S temp server's pane) never writes the real conf dir"

[ "$fails" = 0 ] || { printf 'selftest FAIL: %s failure(s)\n' "$fails" >&2; exit 1; }
printf 'selftest PASS: %s legs — one notice road: recorded, three tiers, only the asking client (T675)\n' "$pass"
