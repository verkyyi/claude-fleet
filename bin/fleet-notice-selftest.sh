#!/bin/bash
# fleet-notice-selftest.sh — the fleet's one on-screen notice (T675):
# bin/fleet_notice.py (fleet-notice.sh, fleet_notice in fleet-client-core.sh) and
# the 看台's top line that draws it (bin/fleet-topbar.py).
#
#   A. RECORD   every notice a row of $FLEET_CONF_DIR/logs/notices.ndjson; the same
#               level + text within 10 s one row; a row older than 7 days goes on the
#               next write; `list` newest first, `--n`; `unread` counts errors since
#               `read` (the page opening); `seen <tag>`.
#   B. TIERS    fleet-topbar.py notice: warn 6 s, info 3 s, `--secs` only lengthens;
#               an error stays past its 10 s while no key came after its hold
#               (ack=0), a key inside the 10 s does not clear it, one after does;
#               「还有 N 条 · ⌘P 看全部」 beside it; the line fits its width; the normal
#               line's unread count (fit … ur=N).
#   C. CLIENTS  on an isolated server with two 看台 and a plain client, each a pty:
#               --client draws on that 看台 only (@view_notice + hold), a second
#               notice while the first is live says more=1, --all reaches both
#               看台, a plain client gets a display-message HELD for its tier
#               (never tmux's ~0.75 s default), fleet_notice (fleet-client-core.sh)
#               and fleet-notice.sh reach the same road.
#   D. PANEL    ⌘P's bottom row (above ⏻) 「✉ 最近消息 · 未读错误 N」, found by the
#               words 消息 / message — fleet binds no key of its own for it.
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
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh NO_COLOR=1
unset TMUX TMUX_PANE FLEET_NOTICE_TAG

# --- A. the record -------------------------------------------------------------------
LOG="$FLEET_CONF_DIR/logs/notices.ndjson"
python3 "$NP" notify warn 'first one' --no-draw --source t
python3 "$NP" notify warn 'first one' --no-draw --source t
python3 "$NP" notify error 'first one' --no-draw --next 'do this' --tag T1
[ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] || fail "A a repeat within 10 s is one row; another level is its own" "$(cat "$LOG")"
python3 "$NP" seen T1 || fail "A seen T1: the tagged row is there"
python3 "$NP" seen T2 && fail "A seen T2: no such tag"
[ "$(python3 "$NP" unread)" = 1 ] || fail "A one error unread"
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

# --- B. the tiers on the top line --------------------------------------------------------
f0=$fails
enc() { python3 -c 'import base64,json,sys; print(base64.b64encode(json.dumps(json.loads(sys.argv[1]), ensure_ascii=False).encode()).decode())' "$1"; }
T0=1000000
W=$(enc '{"level":"warn","text":"heads up","ts":1000000,"until":1000006,"hold":1000006,"more":0}')
I=$(enc '{"level":"info","text":"fyi","ts":1000000,"until":1000003,"hold":1000003,"more":0}')
E=$(enc '{"level":"error","text":"暂停开新：内存紧张","next":"关掉一个会话再试","ts":1000000,"until":1000010,"hold":1000010,"more":2}')
nl() { python3 "$TB" notice "$1" "$2" "ack=$3" "now=$4"; }
case "$(nl 80 "$W" 0 $((T0 + 5)))" in *'! heads up'*'⌘P 看全部'*) ;; *) fail "B a warn is on the line at 5 s" "$(nl 80 "$W" 0 $((T0 + 5)))" ;; esac
[ "$(nl 80 "$W" 0 $((T0 + 7)))" = - ] || fail "B a warn is gone at 7 s"
case "$(nl 80 "$I" 1 $((T0 + 2)))" in *'i fyi'*) ;; *) fail "B an info is on the line at 2 s" ;; esac
[ "$(nl 80 "$I" 1 $((T0 + 4)))" = - ] || fail "B an info is gone at 4 s"
case "$(nl 80 "$E" 0 $((T0 + 100)))" in *'✗ 暂停开新：内存紧张 — 关掉一个会话再试'*'还有 2 条 · ⌘P 看全部'*) ;;
  *) fail "B an error no key answered stays — reason · next · 还有 N 条 · ⌘P 看全部" "$(nl 80 "$E" 0 $((T0 + 100)))" ;; esac
case "$(nl 80 "$E" 1 $((T0 + 5)))" in *暂停开新*) ;; *) fail "B a key inside the 10 s does not clear an error" ;; esac
[ "$(nl 80 "$E" 1 $((T0 + 11)))" = - ] || fail "B a key after the 10 s clears the error"
w=$(python3 -c 'import sys,unicodedata as u; print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in sys.argv[1]))' "$(nl 45 "$E" 0 $((T0 + 1)))")
[ "$w" -le 45 ] || fail "B the line fits a 45-column phone (got $w)"
python3 "$NP" notify info x --no-draw --no-record --secs 1 >/dev/null || fail "B --secs below a tier is no error"
printf '{"title":"t","state":"working"}' > "$WORK/rec.json"
case "$(python3 "$TB" fit 100 "$WORK/rec.json" ur=2)" in *'未读错误 2 · ⌘P'*) ;;
  *) fail "B the normal line carries the unread count" "$(python3 "$TB" fit 100 "$WORK/rec.json" ur=2)" ;; esac
case "$(python3 "$TB" fit 100 "$WORK/rec.json")" in *未读*) fail "B no unread, no count" ;; esac
[ "$fails" = "$f0" ] && st_pass "B warn 6 s, info 3 s, an error until a key after 10 s; 还有 N 条 · ⌘P 看全部; fits 45 columns; the unread count"

# --- D. ⌘P's 最近消息 row (fleet takes no key of its own for it) ----------------------
f0=$fails
python3 "$NP" notify error 'one unread' --no-draw
out=$(FLEET_STATUS_G="$WORK/g" python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_view as fv
rows = fv.panel_rows([], "", set(), cmds=("new", "quit"))
print(" ".join(e.get("cmd", "?") for e in rows))
print(next((e["text"] for e in rows if e.get("cmd") == "notices"), "-"))
for q in ("消息", "message", "zzz"):
    print(q, "notices" in [e.get("cmd") for e in fv.panel_rows([], q, set(), cmds=("new", "quit"))])
PY
)
case "$(printf '%s\n' "$out" | sed -n 1p)" in *'notices quit') ;; *) fail "D the 最近消息 row sits at the panel's bottom, above ⏻" "$out" ;; esac
printf '%s\n' "$out" | sed -n 2p | grep -q '最近消息 · 未读错误 1' || fail "D the row counts the unread errors" "$out"
printf '%s\n' "$out" | grep -qx '消息 True' || fail "D the words 消息 find it" "$out"
printf '%s\n' "$out" | grep -qx 'message True' || fail "D the words message find it" "$out"
printf '%s\n' "$out" | grep -qx 'zzz False' || fail "D other words do not" "$out"
grep -q 'notices' "$BIN/dash-keymap.sh" && fail "D dash-keymap.sh names a notices key — fleet takes no key for it"
[ "$fails" = "$f0" ] && st_pass "D ⌘P's bottom row 「最近消息 · 未读错误 N」, found by 消息 / message; no key of its own"

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

[ "$fails" = 0 ] || { printf 'selftest FAIL: %s failure(s)\n' "$fails" >&2; exit 1; }
printf 'selftest PASS: %s legs — one notice road: recorded, three tiers, only the asking client (T675)\n' "$pass"
