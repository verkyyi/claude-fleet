#!/bin/bash
# seed-words-selftest.sh — a worker whose first turn is the person's words still
# claims first (issue #3331, EPIC #3178 ⑧, D2 = ①).
#
# The spawn half (dash-issue-session.sh writes the words AND stamps
# `@seed_words <claim command>`, or neither) is dash-issue-session-prompt-selftest
# A / W. This is the other half — bin/fleet-worker-start-hook.sh, the only road
# the flow has into a fleet-worker (its body is empty) — on an isolated tmux
# socket, plus the hook table wiring it:
#
#   T  hooks/settings-hooks.json runs it on SessionStart with no matcher (startup)
#   S  a stamped worker window at `startup` ⇒ JSON: additionalContext tells the
#      agent to invoke the claim skill BEFORE anything else, naming the issue and
#      repo; systemMessage is the person's one grey line
#   P  the plugin form of the command (/fleet:fleet-claim) names that skill
#   N  nothing printed: resume / compact, no stamp (a scratch, a no-repo session,
#      an old window), a desk ticket, no pane, a broken event — exit 0 every time
#   L  the line follows the interface language (en)
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

# ===== S: a stamped worker window ⇒ claim first ================================
setw @seed_words /fleet-claim; setw @issue 3312; setw @repo acme/tokenledger; setw @agent_def fleet-worker
out=$(hook startup); rc=$?
[ "$rc" = 0 ] || fail "S the hook must exit 0" "$out"
ctx=$(printf '%s' "$out" | field 'd["hookSpecificOutput"]["additionalContext"]') || fail "S no additionalContext" "$out"
ev=$(printf '%s' "$out" | field 'd["hookSpecificOutput"]["hookEventName"]')
[ "$ev" = SessionStart ] || fail "S hookEventName must be SessionStart" "$out"
case "$ctx" in *"Before anything else"*'`fleet-claim` skill'*) ;; *) fail "S the context must make the claim skill the FIRST step" "$ctx" ;; esac
case "$ctx" in *"#3312"*"acme/tokenledger"*) ;; *) fail "S the context must name the issue and the repo" "$ctx" ;; esac
line=$(printf '%s' "$out" | field 'd["systemMessage"]')
[ "$line" = "fleet-worker · tokenledger · 单 #3312 · 做完开 PR，门绿了自己合" ] || fail "S the person's grey line" "$line"
ok "S startup on a stamped window: claim first + one grey line"

# ===== P: the plugin-installed command names its own skill =====================
setw @seed_words /fleet:fleet-claim
ctx=$(hook startup | field 'd["hookSpecificOutput"]["additionalContext"]')
case "$ctx" in *'`fleet:fleet-claim` skill'*) ;; *) fail "P a plugin install's skill is fleet:fleet-claim" "$ctx" ;; esac
setw @seed_words /fleet-claim
ok "P /fleet:fleet-claim names the fleet:fleet-claim skill"

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
setw @seed_words /fleet-claim; unsetw @issue; [ -z "$(hook startup)" ] || fail "N no @issue ⇒ nothing"
setw @issue 3312
[ -z "$(printf 'not json' | env TMUX="$SP,1,0" TMUX_PANE="$PANE" bash "$HOOK")" ] || fail "N a broken event ⇒ nothing"
[ -z "$(printf '{"source":"startup"}' | env -u TMUX -u TMUX_PANE bash "$HOOK")" ] || fail "N no pane ⇒ nothing"
printf '{"source":"startup"}' | env -u TMUX -u TMUX_PANE bash "$HOOK" >/dev/null; [ $? = 0 ] || fail "N must exit 0"
ok "N resume/compact/clear, desk, unstamped, broken event, no pane: nothing, exit 0"

printf '\nselftest OK: %s assertions passed (words first ⇒ claim next)\n' "$pass"
