#!/bin/bash
# fleet-quick-dispatch-selftest.sh — ⌘T 派一件事 (issue #2753): bin/fleet-quick-dispatch.py.
#
#   A. the payload: the writing area's own (fleet-compose.py payload) for one
#      line — title, repo, agent codex only when asked, `via: dispatch`
#   B. the repo a ↵ goes to untouched: the last one used (compose-state.json,
#      shared with the writing area) while the hub still names it, else the first
#   C. --send runs from here (FLEET_DISPATCH_SEND_CMD), and the last repo is
#      remembered (D — the old client's list taking the payload — went with that
#      client, issue #3008)
#   E. fleet-compose.py --send says the issue a `new` filed (`filed: #N` on
#      stderr); stdout stays the place's line
#   F. the key: the switch table's ⌘T row (the 看台's, conf/tmux-view.conf)
#   G. a 看台's ⌘T (issue #3097), as its key runs it — under run-shell: $TMUX set,
#      no $TMUX_PANE — for BOTH agents: the send goes out with that agent
#      (fleet-compose.py --send → fleet-client-place.sh, faked), fleet-compose
#      says the window opened here (`window: @N`) and the 看台 goes to it
#      (FLEET_DISPATCH_GO_CMD = fleet-view-go.sh); one that does not open is said
#      AND logged (`dispatch_failed` in logs/compose.ndjson, with the reason)
#   H. hub authority (issue #4965): a repo's send is a task record first —
#      fleet-task-record.sh dispatch --repo R --spawn --origin hub --via ⌘P
#      --print (FLEET_DISPATCH_TASK_CMD), never the place road; it says T<n> and
#      the 看台 goes to the window; a repo this machine does not host is said,
#      never tried; legacy authority keeps the place road; `authority` prints it
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (no '$3')" "$2" ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fdisp.XXXXXX") || fail "mktemp"
REAL_TMUX=$(command -v tmux || true)
cleanup() {
  [ -n "$REAL_TMUX" ] && TMUX_TMPDIR="$WORK/tt" "$REAL_TMUX" kill-server 2>/dev/null   # this test's own server
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
# never the server this test runs in: no $TMUX, a private TMUX_TMPDIR
unset TMUX TMUX_PANE
mkdir -p "$WORK/tt" "$WORK/state" "$WORK/g"
export TMUX_TMPDIR="$WORK/tt" FLEET_SWITCH_STATE="$WORK/state" FLEET_STATUS_G="$WORK/g" FLEET_UI_LANG=zh \
  FLEET_COMPOSE_LOG="$WORK/compose.ndjson"
printf 'acme/app\nacme/web\n' > "$WORK/g/hub_repos"
# the person's task authority is asked of no real hub: legacy, unless a leg says (H)
printf '#!/bin/sh\necho legacy\n' > "$WORK/legacy.sh"; chmod +x "$WORK/legacy.sh"
export FLEET_DISPATCH_AUTHORITY_CMD="$WORK/legacy.sh"
D() { python3 "$BIN/fleet-quick-dispatch.py" "$@"; }
J() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get(sys.argv[1]))' "$1"; }

# --- A. the payload --------------------------------------------------------------
p=$(D payload --title '  修 登录 bug  ' --repo acme/web) || fail "A: payload exited non-zero"
eq 'A: the title, one line, trimmed' '修 登录 bug' "$(printf '%s' "$p" | J title)"
eq 'A: the repo named' 'acme/web' "$(printf '%s' "$p" | J repo)"
eq 'A: no Codex asked → the fleet default (null)' 'None' "$(printf '%s' "$p" | J agent)"
eq 'A: the node is the hub'"'"'s pick (null)' 'None' "$(printf '%s' "$p" | J node)"
eq 'A: via dispatch' 'dispatch' "$(printf '%s' "$p" | J via)"
eq 'A: --codex → agent codex' 'codex' "$(D payload --title x --repo acme/web --codex | J agent)"
D payload --title '   ' --repo acme/web >/dev/null 2>&1 && fail "A: an empty title made a payload"
CHECKS=$((CHECKS + 1))

# --- B. the default repo -----------------------------------------------------------
rm -f "$WORK/state/compose-state.json"
eq 'B: nothing used yet → the first the hub names' 'acme/app' "$(D payload --title x | J repo)"
printf '{"repo": "acme/web"}\n' > "$WORK/state/compose-state.json"
eq 'B: the last one used' 'acme/web' "$(D payload --title x | J repo)"
printf '{"repo": "acme/gone"}\n' > "$WORK/state/compose-state.json"
eq 'B: a last one no longer hosted → the first' 'acme/app' "$(D payload --title x | J repo)"

# --- C. no list: --send here --------------------------------------------------------
cat > "$WORK/send.sh" <<EOF
#!/bin/bash
cp "\$1" "$WORK/sent.json"
printf 'REMOTE mac-b start done U/f1\n'
EOF
chmod +x "$WORK/send.sh"
out=$(FLEET_DISPATCH_SEND_CMD="$WORK/send.sh" D send --title '看日志' --repo acme/web --codex) \
  || fail "C: send with no list exited non-zero" "$out"
has 'C: said how it ended' "$out" 'mac-b'
eq 'C: the payload went out with its agent' 'codex' "$(J agent < "$WORK/sent.json")"
eq 'C: the last repo is remembered (compose-state.json)' 'acme/web' "$(J repo < "$WORK/state/compose-state.json")"
printf '#!/bin/sh\nprintf "没有机器有空\\n" >&2; exit 4\n' > "$WORK/nope.sh"; chmod +x "$WORK/nope.sh"
out=$(FLEET_DISPATCH_SEND_CMD="$WORK/nope.sh" D send --title '看日志' --repo acme/web 2>&1) \
  && fail "C: a refused send exited 0" "$out"
has 'C: a refusal says why' "$out" '没有机器有空'
CHECKS=$((CHECKS + 1)); [ -f "$WORK/state/compose-failed.json" ] || fail "C: a refused payload was not kept (compose-failed.json)"

# --- E. --send says the number filed ------------------------------------------------
QB="$WORK/q-bin"; mkdir -p "$QB"
for f in "$BIN"/*; do ln -sf "$f" "$QB/"; done
rm -f "$QB/fleet-client-place.sh"
cat > "$QB/fleet-client-place.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$Q_ARGS"
printf '{"key": "acme-web:issue-42", "filed": "https://github.com/acme/web/issues/42"}' > "$FLEET_PLACE_RESULT"
printf 'REMOTE mac-b start done U/f42\t\n'
EOF
chmod +x "$QB/fleet-client-place.sh"
printf '{"title":"看日志","body":"看日志","repo":"acme/web","via":"dispatch"}\n' > "$WORK/e.json"
export Q_ARGS="$WORK/q.args"; : > "$Q_ARGS"
python3 "$QB/fleet-compose.py" --send "$WORK/e.json" >"$WORK/e.out" 2>"$WORK/e.err" || fail "E: --send exited non-zero" "$(cat "$WORK/e.err")"
# ⌘P's words are a person's task (issue #3325): the hub writes the record first
has 'E: a dispatch is a task' "$(cat "$Q_ARGS")" 'acme/web new --title 看日志 --body-file '
has 'E: …asked as a task from ⌘P' "$(cat "$Q_ARGS")" ' --node auto --task --via ⌘P'
: > "$Q_ARGS"
printf '{"title":"看看风扇","body":"看看风扇","repo":null,"via":"dispatch"}\n' > "$WORK/e2.json"
python3 "$QB/fleet-compose.py" --send "$WORK/e2.json" >/dev/null 2>&1 || fail "E: a no-repo --send exited non-zero"
has 'E: a no-repo dispatch is a task too' "$(cat "$Q_ARGS")" '- scratch --name 看看风扇 --body-file '
has 'E: …the record alone' "$(cat "$Q_ARGS")" ' --task --via ⌘P'
: > "$Q_ARGS"
printf '{"title":"看日志","body":"看日志","repo":"acme/web"}\n' > "$WORK/e3.json"
python3 "$QB/fleet-compose.py" --send "$WORK/e3.json" >/dev/null 2>&1 || fail "E: a writing-area --send exited non-zero"
case "$(cat "$Q_ARGS")" in *--task*) fail "E: the writing area (not ⌘P) asked for a task" "$(cat "$Q_ARGS")" ;; esac
CHECKS=$((CHECKS + 1))
has 'E: stderr says the issue filed' "$(cat "$WORK/e.err")" 'filed: #42'
eq 'E: stdout stays the place'"'"'s one line' 'REMOTE mac-b start done U/f42' "$(tr -d '\t' < "$WORK/e.out")"

# --- G. a 看台's ⌘T under run-shell, both agents (issue #3097) ------------------------
GB="$WORK/g-bin"; mkdir -p "$GB"
for f in "$BIN"/*; do ln -sf "$f" "$GB/"; done
rm -f "$GB/fleet-client-place.sh"
cat > "$GB/fleet-client-place.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$G_ARGS"
case " $* " in *" --agent codex "*) w=@21 ;; *) w=@22 ;; esac
if [ "${G_FAIL:-}" = 1 ]; then
  printf 'DECLINED mini - 1\tstart: filed #9 but its session did not open (no Codex login) — it is on the backlog\n'; exit 5
fi
h=$(hostname -s); h=${h%%.*}
printf '{"window_id": "%s", "filed": "https://github.com/acme/web/issues/9", "machine": "%s"}' "$w" "$h" > "$FLEET_PLACE_RESULT"
printf 'LOCAL %s\thttps://github.com/acme/web/issues/9\n' "$h"
EOF
chmod +x "$GB/fleet-client-place.sh"
cat > "$WORK/go.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/go.log"
EOF
chmod +x "$WORK/go.sh"
: > "$WORK/go.log"
for ag in codex claude; do
  out=$(unset TMUX_PANE; TMUX="$WORK/tt/default,1,0" G_ARGS="$WORK/g-args" FLEET_DISPATCH_GO_CMD="$WORK/go.sh" \
        python3 "$GB/fleet-quick-dispatch.py" send --view 'fleet@view-t1' --client /dev/ttys009 --title "用 $ag 修" \
        --repo acme/web --agent "$ag" 2>&1) || fail "G: the 看台's $ag send under run-shell exited non-zero" "$out"
  has "G: $ag: the send went out with its agent" "$(cat "$WORK/g-args")" "--agent $ag"
done
eq 'G: the 看台 went to each window it opened' \
  "$(printf 'fleet@view-t1 @21 --how dispatch --client /dev/ttys009\nfleet@view-t1 @22 --how dispatch --client /dev/ttys009')" \
  "$(cat "$WORK/go.log")"
: > "$WORK/go.log"; : > "$WORK/compose.ndjson"
out=$(unset TMUX_PANE; TMUX="$WORK/tt/default,1,0" G_ARGS="$WORK/g-args" G_FAIL=1 FLEET_DISPATCH_GO_CMD="$WORK/go.sh" \
      python3 "$GB/fleet-quick-dispatch.py" send --view 'fleet@view-t1' --title '用 codex 修' --repo acme/web --agent codex 2>&1) \
  && fail "G: a send that did not open exited 0" "$out"
has 'G: a failure is said, with its reason' "$out" 'no Codex login'
has 'G: …and logged' "$(grep dispatch_failed "$WORK/compose.ndjson")" 'no Codex login'
eq 'G: …and the 看台 stays where it is' '' "$(cat "$WORK/go.log")"

# --- H. hub authority: the record first ------------------------------------------------
cat > "$WORK/auth.sh" <<'EOF'
#!/bin/sh
printf '{"mode": "%s", "ticket_ref": ""}\n' "${H_MODE:-hub}"
EOF
cat > "$WORK/task.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$WORK/task-args"
[ -n "\${H_FAIL:-}" ] && { printf 'fleet-task-record: the hub refused\n' >&2; exit 1; }
printf 'T77\n@31\tclaude-fleet-scratch-9\t/tmp/wt\tfid\n'
EOF
chmod +x "$WORK/auth.sh" "$WORK/task.sh"
: > "$WORK/go.log"; rm -f "${WORK:?}/task-args" "${WORK:?}/sent.json"
H() { FLEET_DISPATCH_AUTHORITY_CMD="$WORK/auth.sh" FLEET_DISPATCH_TASK_CMD="$WORK/task.sh" FLEET_DISPATCH_HOSTED=acme/web \
      FLEET_DISPATCH_SEND_CMD="$WORK/send.sh" FLEET_DISPATCH_GO_CMD="$WORK/go.sh" D "$@"; }
eq 'H: authority prints the mode' 'hub' "$(H authority --repo acme/web --view 'fleet@view-t1')"
out=$(H send --view 'fleet@view-t1' --client /dev/ttys009 --title '修 登录' --repo acme/web --agent codex --draft 2>&1) \
  || fail "H: a hub-authority send exited non-zero" "$out"
has 'H: says the record' "$out" 'T77'
eq 'H: the record-first road, as the person'"'"'s own task' \
  'dispatch --title 修 登录 --repo acme/web --spawn --origin hub --via ⌘P --print --agent codex --session fleet' \
  "$(cat "$WORK/task-args")"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/sent.json" ] && fail "H: the place road ran under hub authority"
eq 'H: the 看台 went to the window it opened' 'fleet@view-t1 @31 --how dispatch --client /dev/ttys009' "$(cat "$WORK/go.log")"
rm -f "${WORK:?}/task-args"
out=$(H send --view 'fleet@view-t1' --title '修' --repo acme/gone 2>&1) && fail "H: an unhosted repo exited 0" "$out"
has 'H: an unhosted repo is said' "$out" 'acme/gone 不在'
CHECKS=$((CHECKS + 1)); [ -f "$WORK/task-args" ] && fail "H: an unhosted repo was tried here"
long=$(printf '长%.0s' $(seq 1 90))
H send --title "$long" --repo acme/web >/dev/null 2>&1 || fail "H: long words exited non-zero"
has 'H: long words: a clipped title' "$(cat "$WORK/task-args")" "--body-file -"
CHECKS=$((CHECKS + 1)); grep -q "$long" "$WORK/task-args" && fail "H: long words went whole as the title"
out=$(H_FAIL=1 H send --title '修' --repo acme/web 2>&1) && fail "H: a refused dispatch exited 0" "$out"
has 'H: a refused dispatch says why' "$out" 'the hub refused'
out=$(H_MODE=legacy H send --title '看日志' --repo acme/web 2>&1) || fail "H: a legacy send exited non-zero" "$out"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/sent.json" ] || fail "H: legacy authority left the place road"

# --- F. the key ------------------------------------------------------------------------
eq 'F: the switch table row' 'dispatch ⌘T 0x74-0x100000 932 t' "$(bash "$BIN/dash-keymap.sh" --panel switch list | awk '$1 == "dispatch"')"

printf 'fleet-quick-dispatch-selftest: %d checks passed\n' "$CHECKS"
