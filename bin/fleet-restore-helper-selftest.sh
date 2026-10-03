#!/bin/bash
# fleet-restore-helper-selftest.sh — crash-restore resumes each window's OWN
# conversation, never a helper `claude -p` transcript (issue #1296).
#
# On 2026-10-03 a restore reopened four windows — the memory-system owner's among
# them — on the status classifier's transcript: the helper ran from inside each
# worktree, so its transcript was the NEWEST *.jsonl in that worktree's project
# dir, and the snapshot picked "newest". Three layers, each asserted here:
#
#   • DETECT    fleet_is_helper_transcript (fleet-lib.sh) and the resolver's
#               helper_reason (.fleet-restore-resolve.py) agree on every fixture:
#               classifier/digest prompt ⇒ marker; <50 lines, no tool call ⇒ thin;
#               a working session ⇒ resumable
#   • SNAPSHOT  newer helper + older worker transcript ⇒ the worker's id; a hook-
#               recorded @cc_session_id wins outright, even over a newer real
#               transcript and even when short; a hook id whose transcript is a
#               helper, or missing, falls back; only-thin ⇒ the newest thin one
#   • RESTORE   a map naming a helper transcript (the 10-03 map) re-picks the next
#               resumable id in --dry-run and logs `repick` to restore.log; a
#               mapped short session is NOT second-guessed (only `marker` re-picks)
#   • HOOKS     SessionStart (handoff-latch-reset-hook.sh) and Stop
#               (set-claude-state.sh done) stamp @cc_session_id from the payload;
#               a headless `claude -p` (CLAUDE_CODE_ENTRYPOINT=sdk-cli) stamps nothing
#   • NO-PERSIST the sleep digest's helper `claude -p` carries
#               --no-session-persistence (stub claude records argv); the classifier's
#               leg is classify-backend-selftest.sh's
#
# tmux on a private -S socket via a PATH shim; CLAUDE_PROJECTS_DIR points every
# transcript lookup at a temp tree. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { echo 'selftest: tmux not installed — SKIP' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'selftest: python3 not installed — SKIP' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restore-helper-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export CLAUDE_PROJECTS_DIR="$WORK/projects"
mkdir -p "$WORK/shim" "$CLAUDE_PROJECTS_DIR"
cat > "$WORK/shim/tmux" <<EOS
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOS
chmod +x "$WORK/shim/tmux"

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# ---------------------------------------------------------------- fixtures ----
# id <n> → a well-formed session uuid
id() { printf '%08d-0000-4000-8000-000000000000' "$1"; }
CLASSIFIER='You are a status classifier for a coding-agent terminal session. The agent can be Claude Code or Codex.'
DIGEST='You write the status card of a paused coding assistant for a busy, NON-technical reader.'
# mk <file> <kind> [mtime-offset-seconds]: helper|digest|thin|thintool|real
mk() {
  local f="$1" kind="$2" i
  mkdir -p "$(dirname "$f")"
  case "$kind" in
    helper) { printf '{"type":"queue-operation","content":"%s"}\n' "$CLASSIFIER"
              for i in 1 2 3; do printf '{"type":"assistant","n":%s}\n' "$i"; done; } > "$f" ;;
    digest) { printf '{"type":"user","message":{"content":"%s"}}\n' "$DIGEST"
              for i in $(seq 1 80); do printf '{"type":"assistant","n":%s}\n' "$i"; done; } > "$f" ;;
    thin)   for i in 1 2 3 4; do printf '{"type":"user","n":%s}\n' "$i"; done > "$f" ;;
    thintool) { printf '{"type":"user"}\n'; printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}\n'; } > "$f" ;;
    real)   for i in $(seq 1 60); do printf '{"type":"assistant","message":{"content":[{"type":"tool_use","n":%s}]}}\n' "$i"; done > "$f" ;;
  esac
  [ -n "${3:-}" ] && touch -t "$(date -r "$(( $(date +%s) + $3 ))" +%Y%m%d%H%M.%S)" "$f"
  return 0
}

# ------------------------------------------------------------------ DETECT ----
D="$WORK/detect"
mk "$D/helper.jsonl" helper; mk "$D/digest.jsonl" digest; mk "$D/thin.jsonl" thin
mk "$D/thintool.jsonl" thintool; mk "$D/real.jsonl" real
for k in helper:marker digest:marker thin:thin thintool: real:; do
  name=${k%%:*} want=${k#*:}
  if fleet_is_helper_transcript "$D/$name.jsonl"; then got=$FLEET_HELPER_REASON; else got=''; fi
  [ "$got" = "$want" ] || fail "detect: shell says [$got] for $name, want [$want]"
  py=$(python3 - "$BIN/.fleet-restore-resolve.py" "$D/$name.jsonl" <<'PY'
import sys
# The resolver is a script, not a module: run its definitions (everything before
# the stdin loop) and call helper_reason directly.
path, f = sys.argv[1], sys.argv[2]
src = open(path).read().split("\nfor line in sys.stdin:")[0]
sys.argv = [path, ""]
ns = {"__name__": "resolve"}
exec(compile(src, path, "exec"), ns)
print(ns["helper_reason"](f))
PY
)
  [ "$py" = "$want" ] || fail "detect: resolver says [$py] for $name, want [$want] — the two copies drifted"
done
# the resolver's marker list must carry every marker the shell knows
for m in "You are a status classifier for a Claude Code" "You are a status classifier for a coding-agent" \
         "You are labeling a Claude Code session for a dashboard" "You write the status card of a paused coding assistant"; do
  grep -qF "$m" "$BIN/fleet-lib.sh" || fail "detect: fleet-lib.sh lost marker [$m]"
  grep -qF "$m" "$BIN/.fleet-restore-resolve.py" || fail "detect: resolver lost marker [$m]"
done
ok "detect: shell + resolver agree — classifier/digest=marker, short-no-tool=thin, worker=resumable"

# ---------------------------------------------------------------- SNAPSHOT ----
resolve() {   # <hook-sid> <worktree> → the WIN row's session id
  printf '%s||w|%s|7|done||||\n' "$1" "$2" | python3 "$BIN/.fleet-restore-resolve.py" "$WORK/main" --lead --sid | cut -f4
}
mkdir -p "$WORK/main"
WT="$WORK/wt/repo-issue-7"; mkdir -p "$WT"; P=$(fleet_transcript_dir "$WT")
mk "$P/$(id 1).jsonl" real -600; mk "$P/$(id 2).jsonl" helper -10
[ "$(resolve '' "$WT")" = "$(id 1)" ] || fail "snapshot: newer helper transcript won over the worker's" "$(resolve '' "$WT")"
ok "snapshot: newer helper + older worker transcript ⇒ the worker's id"

mk "$P/$(id 3).jsonl" thin -1200; mk "$P/$(id 4).jsonl" real -5
[ "$(resolve "$(id 3)" "$WT")" = "$(id 3)" ] || fail "snapshot: hook id did not win" "$(resolve "$(id 3)" "$WT")"
ok "snapshot: a hook-recorded @cc_session_id wins — over a newer real transcript, even when short"
[ "$(resolve "$(id 2)" "$WT")" = "$(id 4)" ] || fail "snapshot: a hook id naming a helper was trusted"
[ "$(resolve "$(id 9)" "$WT")" = "$(id 4)" ] || fail "snapshot: a hook id with no transcript was trusted"
[ "$(resolve 'not-a-uuid' "$WT")" = "$(id 4)" ] || fail "snapshot: a malformed hook id was trusted"
ok "snapshot: hook id naming a helper / missing / malformed ⇒ falls back to the newest resumable"

WT2="$WORK/wt/repo-issue-8"; mkdir -p "$WT2"; P2=$(fleet_transcript_dir "$WT2")
mk "$P2/$(id 5).jsonl" thin -300; mk "$P2/$(id 6).jsonl" thin -200; mk "$P2/$(id 7).jsonl" helper -1
[ "$(resolve '' "$WT2")" = "$(id 6)" ] || fail "snapshot: only-thin dir did not yield the newest thin" "$(resolve '' "$WT2")"
WT3="$WORK/wt/repo-issue-9"; mkdir -p "$WT3"; mk "$(fleet_transcript_dir "$WT3")/$(id 8).jsonl" helper
[ "$(resolve '' "$WT3")" = "-" ] || fail "snapshot: an all-helper dir resumed a helper"
ok "snapshot: only thin ones ⇒ the newest thin; only helpers ⇒ '-' (never a helper)"

grep -q -- '--lead --sid' "$BIN/fleet-restore.sh" && grep -q '#{@cc_session_id}|#{?@norepo' "$BIN/fleet-restore.sh" \
  || fail "snapshot: fleet-restore.sh no longer feeds @cc_session_id to the resolver"
ok "snapshot: fleet-restore.sh feeds the pane's @cc_session_id as the leading field"

# ----------------------------------------------------------------- RESTORE ----
# A map like 10-03's: issue-7 names the classifier's id 2; issue-8 names a short
# (thin) id 5 that must be left alone. The fleet has no live socket here.
C="$WORK/conf"; S="c7-restore-helper-$$"; mkdir -p "$C/fleets/$S"
{ printf 'FLEET\t%s\towner/repo\t%s\tmaster\n' "$S" "$WORK/main"
  printf 'WIN\tissue-7\t%s\t%s\t7\tdone\t-\t-\t-\n' "$WT" "$(id 2)"
  printf 'WIN\tissue-8\t%s\t%s\t8\tdone\t-\t-\t-\n' "$WT2" "$(id 5)"; } > "$C/fleets/$S/restore.map"
out=$(env -u TMUX -u TMUX_PANE FLEET_CONF_DIR="$C" PATH="$WORK/shim:$PATH" bash "$BIN/fleet-restore.sh" --dry-run 2>&1)
printf '%s\n' "$out" | grep -q "issue-7 → claude --resume $(id 4 | cut -d- -f1)…" \
  || fail "restore: a mapped helper transcript was not re-picked" "$out"
printf '%s\n' "$out" | grep -q "issue-8 → claude --resume $(id 5 | cut -d- -f1)…" \
  || fail "restore: a mapped short session was second-guessed" "$out"
grep -q "repick $S/issue-7 helper-transcript $(id 2) → $(id 4)" "$C/restore/restore.log" \
  || fail "restore: no repick line in restore.log" "$(cat "$C/restore/restore.log" 2>/dev/null)"
ok "restore: --dry-run re-picks a mapped helper transcript (logged), leaves a short real session alone"

# ------------------------------------------------------------------- HOOKS ----
"$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s hooks -x 80 -y 24 'sleep 600' || fail "tmux: cannot start"
PANE=$("$REAL_TMUX" -S "$SOCK" display-message -p -t hooks '#{pane_id}')
opt() { "$REAL_TMUX" -S "$SOCK" show-window-options -v -t "$PANE" @cc_session_id 2>/dev/null; }
hook() {   # <entrypoint> <script> [args…] — stdin = payload
  local ep="$1"; shift
  env PATH="$WORK/shim:$PATH" TMUX="$SOCK,1,0" TMUX_PANE="$PANE" CLAUDE_CODE_ENTRYPOINT="$ep" sh "$@" >/dev/null 2>&1
}
printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$(id 11)" \
  | hook cli "$BIN/handoff-latch-reset-hook.sh"
[ "$(opt)" = "$(id 11)" ] || fail "hooks: SessionStart did not stamp @cc_session_id" "$(opt)"
printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$(id 12)" \
  | hook sdk-cli "$BIN/handoff-latch-reset-hook.sh"
[ "$(opt)" = "$(id 11)" ] || fail "hooks: a headless claude -p SessionStart stamped the pane"
printf '{"hook_event_name":"SessionStart","session_id":"x; rm -rf /","source":"clear"}' \
  | hook cli "$BIN/handoff-latch-reset-hook.sh"
[ "$(opt)" = "$(id 11)" ] || fail "hooks: a malformed session_id was stamped"
printf '{"hook_event_name":"Stop","session_id":"%s","last_assistant_message":"\\"session_id\\": \\"%s\\""}' "$(id 13)" "$(id 14)" \
  | hook cli "$BIN/set-claude-state.sh" 'done'
[ "$(opt)" = "$(id 13)" ] || fail "hooks: Stop did not stamp the payload's own session_id" "$(opt)"
printf '{"hook_event_name":"Stop","session_id":"%s"}' "$(id 15)" | hook sdk-cli "$BIN/set-claude-state.sh" 'done'
[ "$(opt)" = "$(id 13)" ] || fail "hooks: a headless claude -p Stop stamped the pane"
ok "hooks: SessionStart + Stop stamp @cc_session_id; headless and malformed ids stamp nothing"

# -------------------------------------------------------------- NO-PERSIST ----
cat > "$WORK/shim/claude" <<EOS
#!/bin/sh
printf '%s\n' "\$*" > "$WORK/claude-argv"
cat >/dev/null
echo '{}'
EOS
chmod +x "$WORK/shim/claude"
(cd "$WORK" && env -u FLEET_SLEEP_DIGEST_CMD PATH="$WORK/shim:$PATH" python3 - "$BIN" <<'PY'
import sys, subprocess, importlib.util
spec = importlib.util.spec_from_file_location("fleet_sleep", sys.argv[1] + "/fleet-sleep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
subprocess.run(m.digest_argv(), input="prompt", text=True, capture_output=True, timeout=60)
PY
)
case " $(cat "$WORK/claude-argv" 2>/dev/null) " in
  *" -p "*) case " $(cat "$WORK/claude-argv") " in *" --no-session-persistence "*) : ;; *) fail "no-persist: digest argv lacks --no-session-persistence" ;; esac ;;
  *) fail "no-persist: the sleep digest's helper claude -p would leave a transcript" "$(cat "$WORK/claude-argv" 2>/dev/null)" ;;
esac
ok "no-persist: the sleep digest's helper claude -p carries --no-session-persistence"

printf 'fleet-restore-helper-selftest: %s passed\n' "$pass"
