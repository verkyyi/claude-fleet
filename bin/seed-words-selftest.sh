#!/bin/bash
# seed-words-selftest.sh — a worker whose first turn is the person's words opens
# with one grey line and NO injected flow (issue #3331, EPIC #3178 ⑧; T1470).
#
# The spawn half (dash-issue-session.sh writes the words AND stamps
# `@seed_words`, or neither) is dash-issue-session-prompt-selftest
# A / W. This is the other half — bin/fleet-worker-start-hook.sh — on an
# isolated tmux socket, plus the hook table wiring it:
#
#   T  hooks/settings-hooks.json runs it on SessionStart with no matcher (startup)
#   S  a stamped worker window at `startup` ⇒ JSON with the person's one grey
#      line (systemMessage) and NO additionalContext: Claude Code's default
#      behaviour is the guidance (T1470). An old stamp (/fleet-history) the same.
#   N  nothing printed: resume / compact, no stamp (a scratch, a no-repo session,
#      an old window), a desk ticket, no pane, a broken event — exit 0 every time
#   L  the line follows the interface language (en)
#   K  a development task with no issue (@task T<n> + @task_flow 1, issue #4897)
#      ⇒ the grey line names T<n>, no context; @task alone (no flow) ⇒ nothing
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$(cd "$BIN/.." && pwd)"
HOOK="$BIN/fleet-worker-start-hook.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/seedwords.XXXXXX")" || exit 2
SOCK="seedwords-$$"
# The fleet's tmux shim refuses nothing on a test socket, but keep the real tmux.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'tmux-shim' | paste -sd: -)
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }

# ===== T: wired in the one hook table, every SessionStart ======================
python3 - "$ROOT/hooks/settings-hooks.json" <<'EOF' || st_fail "T fleet-worker-start-hook.sh is not a matcher-less SessionStart hook"
import json, sys
t = json.load(open(sys.argv[1]))
groups = t.get("hooks", t)["SessionStart"]
ok = any("matcher" not in g and any("fleet-worker-start-hook.sh" in h.get("command", "") for h in g["hooks"])
         for g in groups)
sys.exit(0 if ok else 1)
EOF
ok "T the hook runs on every SessionStart (startup included)"

# The exception must reach every instruction source that still carries the flow
# (T1299); the worker hook carries none since T1470 — its issue ban is a rail
# (hooks/bash-guard.py, which names the one exception).
python3 - "$ROOT" <<'PY_POLICY' || st_fail "P the sole release-fragment exception must be scoped in every instruction source"
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in (
    "bin/dash-issue-session.sh", "bin/fleet-brief.sh", "conf/codex-preamble.md", "CLAUDE.md",
):
    s = (root / name).read_text().replace("\\`", "`")
    for token in ("GuangZhouShanyouGame/24haowan-monorepo",
                  "node tools/cd/fragments-migrate.js --new <file.md>",
                  "release-fragment", "doc/release-ledger/fragment-schema.md",
                  "The sole exception:", "then update that issue body",
                  "Claiming issues, posting progress comments, closing issues, and creating ordinary issues remain forbidden",
                  "this exception does not apply to any other repository"):
        assert token in s, (name, token)
g = (root / "hooks/bash-guard.py").read_text()
assert "guangzhoushanyougame/24haowan-monorepo" in g and "fragments-migrate.js" in g, "bash-guard: the exception"
h = (root / "bin/fleet-worker-start-hook.sh").read_text()
for token in ('"additionalContext"', "pr_merge", "brief", "Never claim"):
    assert token not in h, ("the worker hook still injects", token)
PY_POLICY
ok "P the exception stays scoped where the flow is still words; the worker hook injects none"

nocontext() { # <label> <json>
  printf '%s' "$2" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "hookSpecificOutput" not in d and set(d) == {"systemMessage"} else 1)' \
    || st_fail "$1: the hook must print only the grey line, no context (T1470)" "$2"
}

command -v tmux >/dev/null 2>&1 || { echo "seed-words-selftest: no tmux — S/P/N/L skipped"; echo "selftest OK: $pass"; exit 0; }
tmux -L "$SOCK" -f /dev/null new-session -d -s sw -x 80 -y 20 'sleep 600' || st_fail "could not start a test tmux server"
PANE=$(tmux -L "$SOCK" display-message -p -t sw: '#{pane_id}')
SP=$(tmux -L "$SOCK" display-message -p '#{socket_path}')
setw() { tmux -L "$SOCK" set-option -w -t "$PANE" "$@"; }
unsetw() { tmux -L "$SOCK" set-option -wu -t "$PANE" "$1"; }
hook() { # <source> — run the hook as the pane's own process would
  printf '{"hook_event_name":"SessionStart","source":"%s"}' "$1" \
    | env TMUX="$SP,1,0" TMUX_PANE="$PANE" FLEET_UI_LANG="${LANG_UI:-zh}" bash "$HOOK"
}
field() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1"; }

# ===== S: a stamped worker window ⇒ the grey line only =========================
setw @seed_words 1; setw @issue 3312; setw @repo acme/tokenledger; setw @agent_def fleet-worker
out=$(hook startup); rc=$?
[ "$rc" = 0 ] || st_fail "S the hook must exit 0" "$out"
nocontext S "$out"
line=$(printf '%s' "$out" | field 'd["systemMessage"]')
[ "$line" = "fleet-worker · tokenledger · 单 #3312" ] || st_fail "S the person's grey line" "$line"
setw @seed_words /fleet-history
nocontext "S an old stamp" "$(hook startup)"
ok "S startup on a stamped window: one grey line, no injected flow; an old stamp the same"

# ===== L: the line follows the interface language ==============================
line=$(LANG_UI=en hook startup | field 'd["systemMessage"]')
[ "$line" = "fleet-worker · tokenledger · #3312" ] || st_fail "L an English line in English" "$line"
ok "L the grey line is English when the person reads English"

# ===== N: nothing for anything else ============================================
for s in resume compact clear; do
  [ -z "$(hook "$s")" ] || st_fail "N source=$s must print nothing"
done
setw @desk 1; [ -z "$(hook startup)" ] || st_fail "N a desk ticket gets no flow"; unsetw @desk
unsetw @seed_words; [ -z "$(hook startup)" ] || st_fail "N no @seed_words (scratch / no-repo / old window) ⇒ nothing"
setw @seed_words /fleet-history; unsetw @issue; [ -z "$(hook startup)" ] || st_fail "N no @issue ⇒ nothing"
setw @issue 3312
[ -z "$(printf 'not json' | env TMUX="$SP,1,0" TMUX_PANE="$PANE" bash "$HOOK")" ] || st_fail "N a broken event ⇒ nothing"
[ -z "$(printf '{"source":"startup"}' | env -u TMUX -u TMUX_PANE bash "$HOOK")" ] || st_fail "N no pane ⇒ nothing"
printf '{"source":"startup"}' | env -u TMUX -u TMUX_PANE bash "$HOOK" >/dev/null; [ $? = 0 ] || st_fail "N must exit 0"
ok "N resume/compact/clear, desk, unstamped, broken event, no pane: nothing, exit 0"

# ===== K: a development task with no issue ⇒ the grey line names T<n> ==========
unsetw @seed_words; unsetw @issue
setw @task T42; setw @task_flow 1; setw @repo acme/tokenledger; setw @agent_def fleet-worker
out=$(hook startup); rc=$?
[ "$rc" = 0 ] || st_fail "K the hook must exit 0" "$out"
nocontext K "$out"
line=$(printf '%s' "$out" | field 'd["systemMessage"]')
[ "$line" = "fleet-worker · tokenledger · 任务 T42" ] || st_fail "K the person's grey line" "$line"
line=$(LANG_UI=en hook startup | field 'd["systemMessage"]')
[ "$line" = "fleet-worker · tokenledger · task T42" ] || st_fail "K an English line in English" "$line"
unsetw @task_flow; [ -z "$(hook startup)" ] || st_fail "K @task without @task_flow (a no-repo task, ⌘P) ⇒ nothing"
setw @task_flow 1; setw @task bogus; [ -z "$(hook startup)" ] || st_fail "K a malformed @task ⇒ nothing"
setw @task T42; [ -z "$(hook resume)" ] || st_fail "K resume ⇒ nothing"
setw @issue 3312; setw @seed_words /fleet-history
[ "$(hook startup | field 'd["systemMessage"]')" = "fleet-worker · tokenledger · 单 #3312" ] || st_fail "K an issue window that carries @task reads as the issue"
ok "K a task session (@task + @task_flow, no issue): the grey line names T<n>, no context"

printf '\nselftest OK: %s assertions passed (words first, nothing injected)\n' "$pass"
