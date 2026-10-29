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
#   I. the 「新会话」 box's defaults (T670, EPIC T651 C2): grid --repo <the session
#      in view's> → that repo, else the last new session's (不绑仓库 counts), else
#      the only one; each repo's agent the one it last opened with (`remember`,
#      compose-state.json's agent_by_repo), else the fleet's, else a usable one
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_tally count

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fdisp.XXXXXX") || st_fail "mktemp"
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
p=$(D payload --title '  修 登录 bug  ' --repo acme/web) || st_fail "A: payload exited non-zero"
st_eq 'A: the title, one line, trimmed' '修 登录 bug' "$(printf '%s' "$p" | J title)"
st_eq 'A: the repo named' 'acme/web' "$(printf '%s' "$p" | J repo)"
st_eq 'A: no Codex asked → the fleet default (null)' 'None' "$(printf '%s' "$p" | J agent)"
st_eq 'A: the node is the hub'"'"'s pick (null)' 'None' "$(printf '%s' "$p" | J node)"
st_eq 'A: via dispatch' 'dispatch' "$(printf '%s' "$p" | J via)"
st_eq 'A: --codex → agent codex' 'codex' "$(D payload --title x --repo acme/web --codex | J agent)"
D payload --title '   ' --repo acme/web >/dev/null 2>&1 && st_fail "A: an empty title made a payload"
CHECKS=$((CHECKS + 1))

# --- B. the default repo -----------------------------------------------------------
rm -f "$WORK/state/compose-state.json"
st_eq 'B: nothing used yet → the first the hub names' 'acme/app' "$(D payload --title x | J repo)"
printf '{"repo": "acme/web"}\n' > "$WORK/state/compose-state.json"
st_eq 'B: the last one used' 'acme/web' "$(D payload --title x | J repo)"
printf '{"repo": "acme/gone"}\n' > "$WORK/state/compose-state.json"
st_eq 'B: a last one no longer hosted → the first' 'acme/app' "$(D payload --title x | J repo)"

# --- C. no list: --send here --------------------------------------------------------
cat > "$WORK/send.sh" <<EOF
#!/bin/bash
cp "\$1" "$WORK/sent.json"
printf 'REMOTE mac-b start done U/f1\n'
EOF
chmod +x "$WORK/send.sh"
out=$(FLEET_DISPATCH_SEND_CMD="$WORK/send.sh" D send --title '看日志' --repo acme/web --codex) \
  || st_fail "C: send with no list exited non-zero" "$out"
st_has 'C: said how it ended' "$out" 'mac-b'
st_eq 'C: the payload went out with its agent' 'codex' "$(J agent < "$WORK/sent.json")"
st_eq 'C: the last repo is remembered (compose-state.json)' 'acme/web' "$(J repo < "$WORK/state/compose-state.json")"
printf '#!/bin/sh\nprintf "没有机器有空\\n" >&2; exit 4\n' > "$WORK/nope.sh"; chmod +x "$WORK/nope.sh"
out=$(FLEET_DISPATCH_SEND_CMD="$WORK/nope.sh" D send --title '看日志' --repo acme/web 2>&1) \
  && st_fail "C: a refused send exited 0" "$out"
st_has 'C: a refusal says why' "$out" '没有机器有空'
CHECKS=$((CHECKS + 1)); [ -f "$WORK/state/compose-failed.json" ] || st_fail "C: a refused payload was not kept (compose-failed.json)"

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
python3 "$QB/fleet-compose.py" --send "$WORK/e.json" >"$WORK/e.out" 2>"$WORK/e.err" || st_fail "E: --send exited non-zero" "$(cat "$WORK/e.err")"
# ⌘P's words are a person's task (issue #3325): the hub writes the record first
st_has 'E: a dispatch is a task' "$(cat "$Q_ARGS")" 'acme/web new --title 看日志 --body-file '
st_has 'E: …asked as a task from ⌘P' "$(cat "$Q_ARGS")" ' --node auto --task --via ⌘P'
: > "$Q_ARGS"
printf '{"title":"看看风扇","body":"看看风扇","repo":null,"via":"dispatch"}\n' > "$WORK/e2.json"
python3 "$QB/fleet-compose.py" --send "$WORK/e2.json" >/dev/null 2>&1 || st_fail "E: a no-repo --send exited non-zero"
st_has 'E: a no-repo dispatch is a task too' "$(cat "$Q_ARGS")" '- scratch --name 看看风扇 --body-file '
st_has 'E: …the record alone' "$(cat "$Q_ARGS")" ' --task --via ⌘P'
: > "$Q_ARGS"
printf '{"title":"看日志","body":"看日志","repo":"acme/web"}\n' > "$WORK/e3.json"
python3 "$QB/fleet-compose.py" --send "$WORK/e3.json" >/dev/null 2>&1 || st_fail "E: a writing-area --send exited non-zero"
case "$(cat "$Q_ARGS")" in *--task*) st_fail "E: the writing area (not ⌘P) asked for a task" "$(cat "$Q_ARGS")" ;; esac
CHECKS=$((CHECKS + 1))
# a DeepSeek model (task J7BN) rides the place road as --model; none adds nothing
: > "$Q_ARGS"
printf '{"title":"看看风扇","body":"看看风扇","repo":null,"via":"dispatch","model":"deepseek"}\n' > "$WORK/e4.json"
python3 "$QB/fleet-compose.py" --send "$WORK/e4.json" >/dev/null 2>&1 || st_fail "E: a model --send exited non-zero"
st_has 'E: a model payload rides as --model' "$(cat "$Q_ARGS")" ' --model deepseek --task --via ⌘P'
: > "$Q_ARGS"
python3 "$QB/fleet-compose.py" --send "$WORK/e2.json" --model DeepSeek-Pro >/dev/null 2>&1 || st_fail "E: --send --model exited non-zero"
st_has 'E: --model on the command line too' "$(cat "$Q_ARGS")" ' --model deepseek-pro '
CHECKS=$((CHECKS + 1)); python3 "$QB/fleet-compose.py" --send "$WORK/e2.json" --model gpt-5 >/dev/null 2>&1 \
  && st_fail "E: --model gpt-5 was sent"
CHECKS=$((CHECKS + 1)); python3 "$QB/fleet-compose.py" --send "$WORK/e2.json" --model deepseek --agent codex >/dev/null 2>&1 \
  && st_fail "E: --model with codex was sent"
st_has 'E: stderr says the issue filed' "$(cat "$WORK/e.err")" 'filed: #42'
st_eq 'E: stdout stays the place'"'"'s one line' 'REMOTE mac-b start done U/f42' "$(tr -d '\t' < "$WORK/e.out")"

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
        --repo acme/web --agent "$ag" 2>&1) || st_fail "G: the 看台's $ag send under run-shell exited non-zero" "$out"
  st_has "G: $ag: the send went out with its agent" "$(cat "$WORK/g-args")" "--agent $ag"
done
st_eq 'G: the 看台 went to each window it opened' \
  "$(printf 'fleet@view-t1 @21 --how dispatch --client /dev/ttys009\nfleet@view-t1 @22 --how dispatch --client /dev/ttys009')" \
  "$(cat "$WORK/go.log")"
: > "$WORK/go.log"; : > "$WORK/compose.ndjson"
out=$(unset TMUX_PANE; TMUX="$WORK/tt/default,1,0" G_ARGS="$WORK/g-args" G_FAIL=1 FLEET_DISPATCH_GO_CMD="$WORK/go.sh" \
      python3 "$GB/fleet-quick-dispatch.py" send --view 'fleet@view-t1' --title '用 codex 修' --repo acme/web --agent codex 2>&1) \
  && st_fail "G: a send that did not open exited 0" "$out"
st_has 'G: a failure is said, with its reason' "$out" 'no Codex login'
st_has 'G: …and logged' "$(grep dispatch_failed "$WORK/compose.ndjson")" 'no Codex login'
st_eq 'G: …and the 看台 stays where it is' '' "$(cat "$WORK/go.log")"

# --- H. hub authority: the record first ------------------------------------------------
cat > "$WORK/auth.sh" <<'EOF'
#!/bin/sh
printf '{"mode": "%s", "ticket_ref": ""}\n' "${H_MODE:-hub}"
EOF
cat > "$WORK/task.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$WORK/task-args"
[ -n "\${H_FAIL:-}" ] && { printf 'fleet-task-record: the hub refused\n' >&2; exit 1; }
[ -n "\${H_CODE:-}" ] && printf 'K7W0\n'   # a hub with task codes (EPIC T644 C3)
# the hub placed it on another machine (T716, task J7BN): no window here, its worker_id
[ -n "\${H_REMOTE:-}" ] && { printf 'T78\nREMOTE\tu-sz\tU/scratch-4\t@4\n'; exit 0; }
printf 'T77\n@31\tclaude-fleet-scratch-9\t/tmp/wt\tfid\n'
EOF
chmod +x "$WORK/auth.sh" "$WORK/task.sh"
: > "$WORK/go.log"; rm -f "${WORK:?}/task-args" "${WORK:?}/sent.json"
H() { FLEET_DISPATCH_AUTHORITY_CMD="$WORK/auth.sh" FLEET_DISPATCH_TASK_CMD="$WORK/task.sh" FLEET_DISPATCH_HOSTED=acme/web \
      FLEET_DISPATCH_SEND_CMD="$WORK/send.sh" FLEET_DISPATCH_GO_CMD="$WORK/go.sh" D "$@"; }
st_eq 'H: authority prints the mode' 'hub' "$(H authority --repo acme/web --view 'fleet@view-t1')"
out=$(H send --view 'fleet@view-t1' --client /dev/ttys009 --title '修 登录' --repo acme/web --agent codex --draft 2>&1) \
  || st_fail "H: a hub-authority send exited non-zero" "$out"
st_has 'H: says the record' "$out" 'T77'
st_eq 'H: the record-first road, as the person'"'"'s own task' \
  'dispatch --title 修 登录 --repo acme/web --spawn --origin hub --via ⌘P --print --agent codex --session fleet' \
  "$(cat "$WORK/task-args")"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/sent.json" ] && st_fail "H: the place road ran under hub authority"
st_eq 'H: the 看台 went to the window it opened' 'fleet@view-t1 @31 --how dispatch --client /dev/ttys009' "$(cat "$WORK/go.log")"
rm -f "${WORK:?}/task-args"
out=$(H send --view 'fleet@view-t1' --title '修' --repo acme/gone 2>&1) && st_fail "H: an unhosted repo exited 0" "$out"
st_has 'H: an unhosted repo is said' "$out" 'acme/gone 不在'
CHECKS=$((CHECKS + 1)); [ -f "$WORK/task-args" ] && st_fail "H: an unhosted repo was tried here"
long=$(printf '长%.0s' $(seq 1 90))
H send --title "$long" --repo acme/web >/dev/null 2>&1 || st_fail "H: long words exited non-zero"
st_has 'H: long words: a clipped title' "$(cat "$WORK/task-args")" "--body-file -"
CHECKS=$((CHECKS + 1)); grep -q "$long" "$WORK/task-args" && st_fail "H: long words went whole as the title"
out=$(H_FAIL=1 H send --title '修' --repo acme/web 2>&1) && st_fail "H: a refused dispatch exited 0" "$out"
st_has 'H: a refused dispatch says why' "$out" 'the hub refused'
out=$(H_CODE=1 H send --view 'fleet@view-t1' --title '修' --repo acme/web 2>&1) || st_fail "H: a coded dispatch exited non-zero" "$out"
st_has 'H: a hub with task codes: the receipt names the code' "$out" 'K7W0'
CHECKS=$((CHECKS + 1)); printf '%s' "$out" | grep -q 'T77' && st_fail "H: …and no T<n>" "$out"
out=$(H_MODE=legacy H send --title '看日志' --repo acme/web 2>&1) || st_fail "H: a legacy send exited non-zero" "$out"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/sent.json" ] || st_fail "H: legacy authority left the place road"

# --- I. the 「新会话」 box's defaults (T670, EPIC T651 C2 — one reader, defaults()) -----
G() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); v=d
for k in sys.argv[1].split("."): v=v.get(k, "<none>") if isinstance(v, dict) else v
print(v)' "$1"; }
rm -f "$WORK/state/compose-state.json"
st_eq 'I: nothing yet, two repos → 不绑仓库' '' "$(D grid | G last)"
st_eq 'I: looking at a session of acme/web → acme/web' 'acme/web' "$(D grid --repo acme/web | G last)"
st_eq 'I: …its short name resolves too' 'acme/web' "$(D grid --repo web | G last)"
st_eq 'I: a session of a repo the hub does not name → the next rule' '' "$(D grid --repo acme/gone | G last)"
D remember --repo acme/app --agent codex || st_fail "I: remember exited non-zero"
st_eq 'I: the last new session'"'"'s repo' 'acme/app' "$(D grid | G last)"
st_eq 'I: …its agent, by repo' 'codex' "$(D grid | G agents.acme/app)"
st_eq 'I: another repo keeps the fleet'"'"'s agent' 'claude' "$(D grid | G agents.acme/web)"
st_eq 'I: the session in view wins over the last' 'acme/web' "$(D grid --repo acme/web | G last)"
D remember --repo acme/web --agent claude
st_eq 'I: B opened with Claude → B Claude; A still Codex' 'codex claude' \
  "$(D grid | G agents.acme/app) $(D grid | G agents.acme/web)"
D remember --repo '' --agent codex
st_eq 'I: 不绑仓库 is a choice, remembered' '' "$(D grid | G last)"
st_eq 'I: …with its own agent' 'codex' "$(D grid | G agents.)"
D remember --repo acme/web
st_eq 'I: no agent named → the repo'"'"'s agent stays' 'claude' "$(D grid | G agents.acme/web)"
st_eq 'I: an unusable remembered agent → the fleet'"'"'s' 'claude' \
  "$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("q", sys.argv[1]); q=importlib.util.module_from_spec(s); s.loader.exec_module(q)
print(q.defaults("acme/app", ["acme/app"], {"agent_by_repo": {"acme/app": "codex"}}, "claude", {"codex": "x"})[1])' "$BIN/fleet-quick-dispatch.py")"
st_eq 'I: one repo hosted, nothing remembered → it' 'acme/app' \
  "$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("q", sys.argv[1]); q=importlib.util.module_from_spec(s); s.loader.exec_module(q)
print(q.defaults("", ["acme/app"], {}, "claude", {})[0])' "$BIN/fleet-quick-dispatch.py")"
# a send keeps the per-repo agents (it merges compose-state.json, never rewrites it)
FLEET_DISPATCH_SEND_CMD="$WORK/send.sh" D send --title x --repo acme/app --agent claude >/dev/null 2>&1
st_eq 'I: a send merges: its repo, its agent, the others kept' 'acme/app claude claude' \
  "$(D grid | G last) $(D grid | G agents.acme/app) $(D grid | G agents.acme/web)"

# --- J. a DeepSeek session (task J7BN): offered only when the hub says so, record first, the hub places it
st_eq 'J: no view → no models offered' '[]' "$(D grid | G models)"
st_eq 'J: the hub offers none → none' '[]' "$(FLEET_DISPATCH_MODELS='' D grid --view 'fleet@view-t1' | G models)"
st_eq 'J: the hub offers both → both, in order' "['deepseek', 'deepseek-pro']" \
  "$(FLEET_DISPATCH_MODELS='deepseek-pro,deepseek,gpt-5' D grid --view 'fleet@view-t1' | G models)"
: > "$WORK/go.log"; rm -f "${WORK:?}/task-args" "${WORK:?}/sent.json"
out=$(H_MODE=legacy H_REMOTE=1 H send --view 'fleet@view-t1' --client /dev/ttys009 --blank --model DeepSeek 2>&1) \
  || st_fail "J: a blank DeepSeek send exited non-zero" "$out"
st_eq 'J: a blank DeepSeek session: record first, no repo, Claude on the model, whatever the authority' \
  'dispatch --title 新会话 --spawn --origin hub --via ⌘P --print --blank --agent claude --model deepseek --session fleet' \
  "$(cat "$WORK/task-args")"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/sent.json" ] && st_fail "J: a model send took the place road"
st_eq 'J: the 看台 went to the worker the hub placed' 'fleet@view-t1 U/scratch-4 --how dispatch --client /dev/ttys009' \
  "$(cat "$WORK/go.log")"
H send --view 'fleet@view-t1' --title '修 登录' --repo acme/web --agent codex --model deepseek-pro >/dev/null 2>&1 \
  || st_fail "J: a repo DeepSeek send exited non-zero"
st_has 'J: a repo'"'"'s DeepSeek task names its repo and the model, as Claude' "$(cat "$WORK/task-args")" \
  '--repo acme/web --spawn --origin hub --via ⌘P --print --agent claude --model deepseek-pro'
out=$(H send --view 'fleet@view-t1' --blank --model gpt-5 2>&1) && st_fail "J: --model gpt-5 exited 0" "$out"
st_has 'J: an unknown model is refused' "$out" 'deepseek or deepseek-pro'

# --- F. the key ------------------------------------------------------------------------
st_eq 'F: the switch table row' 'dispatch ⌘T 0x74-0x100000 932 t' "$(bash "$BIN/dash-keymap.sh" --panel switch list | awk '$1 == "dispatch"')"

printf 'fleet-quick-dispatch-selftest: %d checks passed\n' "$CHECKS"
