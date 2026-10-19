#!/bin/bash
# seed-words-selftest.sh — a worker whose first turn is the person's words is given
# its flow by a hook (issue #3331, EPIC #3178 ⑧, D2 = ①; no claim since #4898).
#
# The spawn half (dash-issue-session.sh writes the words AND stamps
# `@seed_words`, or neither) is dash-issue-session-prompt-selftest
# A / W. This is the other half — bin/fleet-worker-start-hook.sh, the only road
# the flow has into a fleet-worker (its body is empty) — on an isolated tmux
# socket, plus the hook table wiring it:
#
#   T  hooks/settings-hooks.json runs it on SessionStart with no matcher (startup)
#   S  a stamped worker window at `startup` ⇒ JSON: additionalContext tells the
#      agent to read `brief` FIRST, then PR (`Closes #N`) → pr_verdict / pr_merge →
#      report, naming the issue and repo — no claim skill (issue #4898);
#      systemMessage is the person's one grey line. An old stamp (/fleet-history)
#      counts the same.
#   N  nothing printed: resume / compact, no stamp (a scratch, a no-repo session,
#      an old window), a desk ticket, no pane, a broken event — exit 0 every time
#   L  the line follows the interface language (en)
#   K  a development task with no issue (@task T<n> + @task_flow 1, issue #4897)
#      ⇒ the task flow: read the record with `brief`, PR, pr_verdict / pr_merge,
#      report merged; @task alone (no flow) ⇒ nothing
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
HOOK="$BIN/fleet-worker-start-hook.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/seedwords.XXXXXX")" || exit 2
SOCK="seedwords-$$"
# The fleet's tmux shim refuses nothing on a test socket, but keep the real tmux.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'tmux-shim' | paste -sd: -)
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# ===== T: wired in the one hook table, every SessionStart ======================
python3 - "$ROOT/hooks/settings-hooks.json" <<'EOF' || fail "T fleet-worker-start-hook.sh is not a matcher-less SessionStart hook"
import json, sys
t = json.load(open(sys.argv[1]))
groups = t.get("hooks", t)["SessionStart"]
ok = any("matcher" not in g and any("fleet-worker-start-hook.sh" in h.get("command", "") for h in g["hooks"])
         for g in groups)
sys.exit(0 if ok else 1)
EOF
ok "T the hook runs on every SessionStart (startup included)"

command -v tmux >/dev/null 2>&1 || { echo "seed-words-selftest: no tmux — S/P/N/L skipped"; echo "selftest OK: $pass"; exit 0; }
tmux -L "$SOCK" -f /dev/null new-session -d -s sw -x 80 -y 20 'sleep 600' || fail "could not start a test tmux server"
PANE=$(tmux -L "$SOCK" display-message -p -t sw: '#{pane_id}')
SP=$(tmux -L "$SOCK" display-message -p '#{socket_path}')
setw() { tmux -L "$SOCK" set-option -w -t "$PANE" "$@"; }
unsetw() { tmux -L "$SOCK" set-option -wu -t "$PANE" "$1"; }
hook() { # <source> — run the hook as the pane's own process would
  printf '{"hook_event_name":"SessionStart","source":"%s"}' "$1" \
    | env TMUX="$SP,1,0" TMUX_PANE="$PANE" FLEET_UI_LANG="${LANG_UI:-zh}" bash "$HOOK"
}
field() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1"; }

# ===== S: a stamped worker window ⇒ brief first, then the flow ================
setw @seed_words 1; setw @issue 3312; setw @repo acme/tokenledger; setw @agent_def fleet-worker
out=$(hook startup); rc=$?
[ "$rc" = 0 ] || fail "S the hook must exit 0" "$out"
ctx=$(printf '%s' "$out" | field 'd["hookSpecificOutput"]["additionalContext"]') || fail "S no additionalContext" "$out"
ev=$(printf '%s' "$out" | field 'd["hookSpecificOutput"]["hookEventName"]')
[ "$ev" = SessionStart ] || fail "S hookEventName must be SessionStart" "$out"
case "$ctx" in *"Before anything else"*'the fleet tool `brief`'*'Closes #3312'*'`pr_merge`'*'`state: merged`'*) ;; *) fail "S the context: brief first, then PR → merge → report" "$ctx" ;; esac
case "$ctx" in *fleet-claim-*|*"claim skill"*) fail "S no claim skill any more (issue #4898)" "$ctx" ;; esac
case "$ctx" in *"#3312"*"acme/tokenledger"*) ;; *) fail "S the context must name the issue and the repo" "$ctx" ;; esac
line=$(printf '%s' "$out" | field 'd["systemMessage"]')
[ "$line" = "fleet-worker · tokenledger · 单 #3312 · 做完开 PR，门绿了自己合" ] || fail "S the person's grey line" "$line"
setw @seed_words /fleet-history
case "$(hook startup | field 'd["hookSpecificOutput"]["additionalContext"]')" in *'the fleet tool `brief`'*) ;; *) fail "S an old stamp gets the same flow" ;; esac
ok "S startup on a stamped window: brief first, the flow, one grey line; an old stamp the same"

# ===== L: the line follows the interface language ==============================
line=$(LANG_UI=en hook startup | field 'd["systemMessage"]')
case "$line" in "fleet-worker · tokenledger · #3312 · "*merges*) ;; *) fail "L an English line in English" "$line" ;; esac
ok "L the grey line is English when the person reads English"

# ===== N: nothing for anything else ============================================
for s in resume compact clear; do
  [ -z "$(hook "$s")" ] || fail "N source=$s must print nothing"
done
setw @desk 1; [ -z "$(hook startup)" ] || fail "N a desk ticket gets no flow"; unsetw @desk
unsetw @seed_words; [ -z "$(hook startup)" ] || fail "N no @seed_words (scratch / no-repo / old window) ⇒ nothing"
setw @seed_words /fleet-history; unsetw @issue; [ -z "$(hook startup)" ] || fail "N no @issue ⇒ nothing"
setw @issue 3312
[ -z "$(printf 'not json' | env TMUX="$SP,1,0" TMUX_PANE="$PANE" bash "$HOOK")" ] || fail "N a broken event ⇒ nothing"
[ -z "$(printf '{"source":"startup"}' | env -u TMUX -u TMUX_PANE bash "$HOOK")" ] || fail "N no pane ⇒ nothing"
printf '{"source":"startup"}' | env -u TMUX -u TMUX_PANE bash "$HOOK" >/dev/null; [ $? = 0 ] || fail "N must exit 0"
ok "N resume/compact/clear, desk, unstamped, broken event, no pane: nothing, exit 0"

# ===== K: a development task with no issue ⇒ the task flow (issue #4897) ========
unsetw @seed_words; unsetw @issue
setw @task T42; setw @task_flow 1; setw @repo acme/tokenledger; setw @agent_def fleet-worker
out=$(hook startup); rc=$?
[ "$rc" = 0 ] || fail "K the hook must exit 0" "$out"
ctx=$(printf '%s' "$out" | field 'd["hookSpecificOutput"]["additionalContext"]') || fail "K no additionalContext" "$out"
case "$ctx" in *"T42"*"acme/tokenledger"*"NOT to a GitHub issue"*) ;; *) fail "K the context must name the record and the repo, and no issue" "$ctx" ;; esac
case "$ctx" in *'the fleet tool `brief`'*'`pr_verdict`'*'`pr_merge`'*'`state: merged`'*) ;; *) fail "K the flow: brief → PR → pr_verdict/pr_merge → report merged" "$ctx" ;; esac
case "$ctx" in *"Closes #"[0-9]*) fail "K a task's PR carries no Closes" "$ctx" ;; esac
line=$(printf '%s' "$out" | field 'd["systemMessage"]')
[ "$line" = "fleet-worker · tokenledger · 任务 T42 · 做完开 PR，门绿了自己合" ] || fail "K the person's grey line" "$line"
line=$(LANG_UI=en hook startup | field 'd["systemMessage"]')
case "$line" in "fleet-worker · tokenledger · task T42 · "*merges*) ;; *) fail "K an English line in English" "$line" ;; esac
unsetw @task_flow; [ -z "$(hook startup)" ] || fail "K @task without @task_flow (a no-repo task, ⌘P) ⇒ nothing"
setw @task_flow 1; setw @task bogus; [ -z "$(hook startup)" ] || fail "K a malformed @task ⇒ nothing"
setw @task T42; [ -z "$(hook resume)" ] || fail "K resume ⇒ nothing"
setw @issue 3312; setw @seed_words /fleet-history
case "$(hook startup | field 'd["hookSpecificOutput"]["additionalContext"]')" in *'Closes #3312'*) ;; *) fail "K an issue window that carries @task gets the issue flow" ;; esac
ok "K a task session (@task + @task_flow, no issue): read the record, PR, merge, report merged"

printf '\nselftest OK: %s assertions passed (words first ⇒ brief next)\n' "$pass"
