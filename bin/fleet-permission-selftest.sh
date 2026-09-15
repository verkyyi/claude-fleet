#!/bin/bash
# fleet-permission-selftest.sh — hermetic smoke test for bin/fleet-permission.sh (issue #640).
#
# Drives the reader/refuser against a FAKE tmux and a HAND-WRITTEN transcript — no
# tmux server, no live Claude, no keystroke ever reaching a real pane. Every leg is
# one of the rails, because the rails are the whole point of the script: it can
# refuse a blocked command and it must never, under any input, approve one.
#
#   • USAGE        no verb / no target → exit 2, nothing sent.
#   • PENDING GATE a transcript whose tool_use already HAS its tool_result, and an
#                  empty one → exit 1, ZERO keystrokes.
#   • NOT-OURS     the pending tool_use is an AskUserQuestion → exit 1 and send
#                  NOTHING: that dialog belongs to fleet-answer.sh, and a digit typed
#                  at it would answer the wrong question.
#   • SHOW         the blocked command, its tool, and the on-screen reason are all
#                  readable WITHOUT attaching — the outage this issue is about — and
#                  --json emits the same as parseable JSON. No keystroke either way.
#   • KNOB GATE    --deny with FLEET_ALLOW_AUTO_DENY unset → exit 5, nothing sent,
#                  and it still says which key it WOULD have pressed.
#   • SCREEN GATE  armed, but no "Do you want to …" dialog on screen → exit 3,
#                  nothing sent.
#   • NO-ONLY      armed + a real dialog → exactly ONE keystroke, and it is the digit
#                  of the `No` row as the SCREEN numbers it (3 here, not 1).
#   • YES-NEVER    the adversarial legs. A dialog whose ONLY rows are Yes rows, one
#                  where the No row is missing, and one with TWO No rows → exit 3 and
#                  ZERO keystrokes in every case. There is no input shape in this
#                  file that gets a Yes digit sent, and that is the assertion.
#   • RENUMBERED   the same dialog with its rows in a different order still refuses
#                  by LABEL: the digit follows the screen, never arithmetic.
#   • VERIFY       a refusal whose tool_result never lands → exit 4 (keys sent, not
#                  confirmed), so the tool cannot claim a refusal it did not get.
#
# The fake tmux keeps a STEP counter that advances on every send-keys, and
# capture-pane answers from $WORK/screens/<step>.txt — the same harness shape
# bin/fleet-answer-selftest.sh uses. FAKE_RESULT_AT_STEP appends the tool_result at
# a given step, so the VERIFY/NO-ONLY legs exercise the real transcript wait.
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-permission.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fp-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/screens"
INJECT="$WORK/inject.log"
STEP="$WORK/step"
PANE='%9'

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '  got: %s\n' "$2" >&2; exit 1; }

# --- fake tmux ---------------------------------------------------------------
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
verb="\${1:-}"; args="\$*"
step_read() { cat "$STEP" 2>/dev/null || echo 0; }
case "\$verb" in
  send-keys)
    printf '%s\n' "\$args" >> "$INJECT"
    s=\$(( \$(step_read) + 1 )); printf '%s' "\$s" > "$STEP"
    if [ -n "\${FAKE_RESULT_AT_STEP:-}" ] && [ "\$s" -ge "\${FAKE_RESULT_AT_STEP}" ] \\
       && [ -n "\${FAKE_RESULT_LINE:-}" ] && [ -n "\${FAKE_TRANSCRIPT:-}" ]; then
      grep -qF 'tool_result' "\${FAKE_TRANSCRIPT}" 2>/dev/null || \\
        printf '%s\n' "\${FAKE_RESULT_LINE}" >> "\${FAKE_TRANSCRIPT}"
    fi ;;
  capture-pane)
    s=\$(step_read); f="$WORK/screens/\$s.txt"
    if [ ! -f "\$f" ]; then f=\$(ls "$WORK/screens"/*.txt 2>/dev/null | sort -V | tail -n1); fi
    [ -n "\$f" ] && [ -f "\$f" ] && cat "\$f" ;;
  display-message)
    [ -n "\${FAKE_PANE_DEAD:-}" ] && exit 1
    printf '%s\n' "$PANE" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# fleet-peer-send.sh must never be reached by this test's asserts, and must never
# touch the machine — shadow it on PATH is not enough (the script calls it by path),
# so the legs that would reach it pass --no-tell.

# --- transcript builders ------------------------------------------------------
TUID='toolu_BLOCKED1'
mk_transcript() {  # $1=out path, $2=tool name, $3=input JSON object
  OUT="$1" NAME="$2" INP="$3" TUID="$TUID" python3 - <<'PY'
import json, os
tu = {"type": "assistant", "timestamp": "2026-09-14T10:00:00.000Z",
      "message": {"role": "assistant", "content": [
          {"type": "tool_use", "id": os.environ["TUID"],
           "name": os.environ["NAME"], "input": json.loads(os.environ["INP"])}]}}
with open(os.environ["OUT"], "w") as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "go"}}) + "\n")
    f.write(json.dumps(tu) + "\n")
PY
}
result_line() {  # a transcript line carrying the rejection tool_result
  TUID="$TUID" python3 - <<'PY'
import json, os
print(json.dumps({"type": "user", "timestamp": "2026-09-14T10:00:09.000Z",
                  "toolDenialKind": "user-rejected",
                  "message": {"role": "user", "content": [
                      {"type": "tool_result", "tool_use_id": os.environ["TUID"],
                       "is_error": True,
                       "content": "The user doesn't want to proceed with this tool use."}]}}))
PY
}

IN_BASH='{"command":"rm \"$G\"/*.tick","description":"drop the stale tick files"}'
IN_ASK='{"questions":[{"question":"Red or blue?","header":"Color","options":[{"label":"Red"}]}]}'

# --- screens (the shape Claude Code 2.1.x renders for a guarded Bash call) -----
screen() { cat > "$WORK/screens/$1.txt"; }
clear_screens() { rm -f "$WORK/screens"/*.txt; }

SCR_PERM='⏺ Bash(rm "$G"/*.tick)

╭──────────────────────────────────────────────────────────────╮
│ Bash command                                                 │
│                                                              │
│   rm "$G"/*.tick                                             │
│   drop the stale tick files                                  │
│                                                              │
│ Dangerous rm operation on possibly-empty variable path:      │
│ "$G"/*.tick                                                  │
│                                                              │
│ Do you want to proceed?                                      │
│ ❯ 1. Yes                                                     │
│   2. Yes, and don'"'"'t ask again for rm commands in this repo   │
│   3. No, and tell Claude what to do differently (esc)         │
╰──────────────────────────────────────────────────────────────╯'

# The same dialog with the rows reordered — the No digit must FOLLOW the screen.
SCR_PERM_REORDERED='Do you want to proceed?
  1. No, and tell Claude what to do differently (esc)
❯ 2. Yes
  3. Yes, and don'"'"'t ask again'

SCR_YES_ONLY='Do you want to proceed?
❯ 1. Yes
  2. Yes, and don'"'"'t ask again for rm commands in this repo'

SCR_TWO_NOS='Do you want to proceed?
❯ 1. Yes
  2. No, and tell Claude what to do differently (esc)
  3. No, never mind'

SCR_IDLE='⏺ Done.

❯
  ◆ Opus 5'

run() {  # run <args...> — fake tmux on PATH, deterministic knobs
  : > "$INJECT"; printf '0' > "$STEP"
  env PATH="$WORK/fakepath:$PATH" \
    FLEET_ANSWER_POLL="${POLL:-0}" \
    FLEET_ANSWER_TIMEOUT="${TMO:-3}" \
    FLEET_ALLOW_SENDKEYS=1 \
    FLEET_ALLOW_AUTO_DENY="${ARM:-}" \
    FAKE_PANE_DEAD="${FAKE_PANE_DEAD:-}" \
    FAKE_RESULT_AT_STEP="${FAKE_RESULT_AT_STEP:-}" \
    FAKE_RESULT_LINE="${FAKE_RESULT_LINE:-}" \
    FAKE_TRANSCRIPT="${FAKE_TRANSCRIPT:-}" \
    "$SRC" "$@"
}
injected() { cat "$INJECT" 2>/dev/null; }
inject_count() { awk 'NF' "$INJECT" 2>/dev/null | wc -l | tr -d ' '; }
nothing_sent() { [ "$(inject_count)" = "0" ]; }
no_yes_digit() {  # the digits a Yes row carries in $SCR_PERM are 1 and 2
  case "$(injected)" in *' 1'|*' 2'|1|2) return 1 ;; *) return 0 ;; esac
}

T="$WORK/t-bash.jsonl";  mk_transcript "$T"  Bash            "$IN_BASH"
TQ="$WORK/t-ask.jsonl";  mk_transcript "$TQ" AskUserQuestion "$IN_ASK"
TD="$WORK/t-done.jsonl"; mk_transcript "$TD" Bash            "$IN_BASH"; result_line >> "$TD"
TE="$WORK/t-empty.jsonl"; : > "$TE"

# ============================ USAGE =========================================
run >/dev/null 2>&1;        [ $? = 2 ] || fail "no args must exit 2"
run --show >/dev/null 2>&1; [ $? = 2 ] || fail "--show without a target must exit 2"
run --deny >/dev/null 2>&1; [ $? = 2 ] || fail "--deny without a target must exit 2"
printf 'selftest: USAGE legs PASS (no verb / no target → exit 2)\n' >&2

# ============================ PENDING GATE ==================================
clear_screens; printf '%s\n' "$SCR_IDLE" | screen 0
ARM=1 run --show "$PANE" --transcript "$TD" >/dev/null 2>&1
[ $? = 1 ] || fail "--show on a settled tool_use must exit 1"
ARM=1 run --deny "$PANE" --transcript "$TD" --no-tell >/dev/null 2>&1
[ $? = 1 ] || fail "--deny on a settled tool_use must exit 1"
nothing_sent || fail "a settled tool_use must send nothing" "$(injected)"
ARM=1 run --deny "$PANE" --transcript "$TE" --no-tell >/dev/null 2>&1
[ $? = 1 ] || fail "--deny with an empty transcript must exit 1"
nothing_sent || fail "an empty transcript must send nothing" "$(injected)"
FAKE_PANE_DEAD=1 ARM=1 run --deny "$PANE" --transcript "$T" --no-tell >/dev/null 2>&1
[ $? = 1 ] || fail "a gone pane must exit 1"
nothing_sent || fail "a gone pane must send nothing" "$(injected)"
printf 'selftest: PENDING-GATE legs PASS (settled / empty / dead pane → exit 1, ZERO keystrokes)\n' >&2

# ============================ NOT-OURS ======================================
clear_screens; printf '%s\n' "$SCR_PERM" | screen 0
out=$(ARM=1 run --deny "$PANE" --transcript "$TQ" --no-tell 2>&1)
[ $? = 1 ] || fail "a pending AskUserQuestion must exit 1 here" "$out"
nothing_sent || fail "an AskUserQuestion must send NOTHING from this tool" "$(injected)"
case "$out" in *fleet-answer*) : ;; *) fail "it must point at fleet-answer.sh" "$out" ;; esac
printf 'selftest: NOT-OURS leg PASS (AskUserQuestion is fleet-answer.sh'"'"'s — refused, nothing sent)\n' >&2

# ============================ SHOW ==========================================
clear_screens; printf '%s\n' "$SCR_PERM" | screen 0
out=$(run --show "$PANE" --transcript "$T" 2>&1) || fail "--show must exit 0" "$out"
case "$out" in *'rm "$G"/*.tick'*) : ;; *) fail "--show must print the BLOCKED COMMAND" "$out" ;; esac
case "$out" in *Bash*) : ;; *) fail "--show must name the tool" "$out" ;; esac
case "$out" in *'Dangerous rm operation'*) : ;; *) fail "--show must print the on-screen reason" "$out" ;; esac
case "$out" in *'Do you want to proceed?'*) : ;; *) fail "--show must print the dialog" "$out" ;; esac
case "$out" in *FLEET_ALLOW_AUTO_DENY*) : ;; *) fail "--show unarmed must name the knob" "$out" ;; esac
nothing_sent || fail "--show must never send a keystroke" "$(injected)"
js=$(run --show "$PANE" --transcript "$T" --json 2>&1) || fail "--show --json must exit 0" "$js"
printf '%s' "$js" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["tool"]=="Bash", d
assert d["input"]["command"]=="rm \"$G\"/*.tick", d
' || fail "--show --json must carry the tool + command" "$js"
nothing_sent || fail "--show --json must never send a keystroke" "$(injected)"
printf 'selftest: SHOW legs PASS (command + tool + reason readable WITHOUT attaching · json · zero keystrokes)\n' >&2

# ============================ KNOB GATE =====================================
clear_screens; printf '%s\n' "$SCR_PERM" | screen 0
out=$(ARM='' run --deny "$PANE" --transcript "$T" --no-tell 2>&1)
[ $? = 5 ] || fail "--deny unarmed must exit 5" "$out"
nothing_sent || fail "--deny unarmed must send NOTHING" "$(injected)"
case "$out" in *'would press 3'*) : ;; *) fail "unarmed --deny must still say which key it would press" "$out" ;; esac
out=$(ARM=1 run --deny "$PANE" --transcript "$T" --dry-run --no-tell 2>&1) || fail "--dry-run must exit 0" "$out"
nothing_sent || fail "--dry-run must send NOTHING" "$(injected)"
printf 'selftest: KNOB-GATE legs PASS (default OFF → exit 5, nothing sent · --dry-run plan-only)\n' >&2

# ============================ SCREEN GATE ===================================
clear_screens; printf '%s\n' "$SCR_IDLE" | screen 0
ARM=1 run --deny "$PANE" --transcript "$T" --no-tell >/dev/null 2>&1
[ $? = 3 ] || fail "no dialog on screen must exit 3"
nothing_sent || fail "no dialog on screen must send nothing" "$(injected)"
printf 'selftest: SCREEN-GATE leg PASS (no dialog visible → exit 3, nothing sent)\n' >&2

# ============================ YES-NEVER =====================================
# The adversarial shapes. None of them may produce a keystroke, and in particular
# none may produce the digit of a Yes row.
adversarial() {  # adversarial <why> < screen
  clear_screens; cat > "$WORK/screens/0.txt"
  ARM=1 run --deny "$PANE" --transcript "$T" --no-tell >/dev/null 2>&1
  [ $? = 3 ] || fail "a dialog with $1 must exit 3"
  nothing_sent || fail "a dialog with $1 must send NOTHING" "$(injected)"
}
printf '%s\n' "$SCR_YES_ONLY" | adversarial "only Yes rows"
printf '%s\n' "$SCR_TWO_NOS"  | adversarial "two No rows"
printf 'selftest: YES-NEVER legs PASS (only-Yes · ambiguous-No → exit 3, ZERO keystrokes)\n' >&2

# ============================ NO-ONLY =======================================
TLIVE="$WORK/t-live.jsonl"; mk_transcript "$TLIVE" Bash "$IN_BASH"
RLINE="$(result_line)"
clear_screens; printf '%s\n' "$SCR_PERM" | screen 0
out=$(FAKE_TRANSCRIPT="$TLIVE" FAKE_RESULT_LINE="$RLINE" FAKE_RESULT_AT_STEP=1 \
      ARM=1 run --deny "$PANE" --transcript "$TLIVE" --no-tell 2>&1) \
  || fail "an armed --deny on a real dialog must exit 0" "$out"
[ "$(inject_count)" = "1" ] || fail "--deny must send EXACTLY one keystroke" "$(injected)"
case "$(injected)" in *3) : ;; *) fail "--deny must send the SCREEN's No digit (3)" "$(injected)" ;; esac
no_yes_digit || fail "--deny sent a Yes digit" "$(injected)"
printf 'selftest: NO-ONLY leg PASS (exactly one key, and it is the No row'"'"'s digit)\n' >&2

# ============================ RENUMBERED ====================================
# Same dialog, rows reordered: No is now 1 and Yes is 2. Following the SCREEN is
# the difference between refusing and approving.
TLIVE="$WORK/t-live2.jsonl"; mk_transcript "$TLIVE" Bash "$IN_BASH"
clear_screens; printf '%s\n' "$SCR_PERM_REORDERED" | screen 0
out=$(FAKE_TRANSCRIPT="$TLIVE" FAKE_RESULT_LINE="$RLINE" FAKE_RESULT_AT_STEP=1 \
      ARM=1 run --deny "$PANE" --transcript "$TLIVE" --no-tell 2>&1) \
  || fail "a reordered dialog must still be refusable" "$out"
[ "$(inject_count)" = "1" ] || fail "reordered: exactly one keystroke" "$(injected)"
case "$(injected)" in *1) : ;; *) fail "reordered: must send 1 (the No row), not a remembered 3" "$(injected)" ;; esac
printf 'selftest: RENUMBERED leg PASS (the digit follows the screen, never arithmetic)\n' >&2

# ============================ VERIFY ========================================
# The result never lands → the tool must NOT claim a refusal it did not get.
clear_screens; printf '%s\n' "$SCR_PERM" | screen 0
TMO=1 ARM=1 run --deny "$PANE" --transcript "$T" --no-tell >/dev/null 2>&1
[ $? = 4 ] || fail "an unconfirmed refusal must exit 4"
[ "$(inject_count)" = "1" ] || fail "VERIFY: the digit is still sent exactly once" "$(injected)"
printf 'selftest: VERIFY leg PASS (no tool_result → exit 4, never a false "refused")\n' >&2

printf 'selftest PASS: fleet-permission — pending/screen/knob gates + No-only label gate + transcript verify (#640)\n'
exit 0
