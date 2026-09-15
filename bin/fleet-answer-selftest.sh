#!/bin/bash
# fleet-answer-selftest.sh — hermetic smoke test for bin/fleet-answer.sh (issue #605).
#
# Drives the answerer against a FAKE tmux and a HAND-WRITTEN transcript — no tmux
# server, no live Claude, no keystroke ever reaching a real pane. The legs pin the
# whole contract, and three of them are the safety rails:
#   • USAGE            no verb / no target / a malformed pick → exit 2, nothing sent.
#   • NO-PENDING       the transcript's AskUserQuestion already HAS its tool_result
#                      → --show exits 1 and --answer sends NOTHING. This is the gate
#                      that makes the tool safe on a pane with no question open: a
#                      `needs` window may be waiting on a permission prompt instead,
#                      and typing a digit there would answer the WRONG dialog.
#   • LABEL-GATE       the chosen option's label is not on the screen → refuse with
#                      exit 3 and send NOTHING. Picks are resolved by LABEL, never by
#                      blind index, so a TUI that renumbered or truncated its rows
#                      degrades to "not answered", never to "answered the wrong one".
#   • SHOW             a pending question renders header/question/options, and --json
#                      emits the same as parseable JSON.
#   • SINGLE           single-select: EXACTLY one send-keys, the digit, no Enter
#                      (the TUI selects and submits on the digit alone).
#   • MULTISELECT      multiSelect: a digit per pick (cursor does not move), then
#                      Down until the cursor sits on `Submit`, then Enter — the Down
#                      count comes from re-reading the SCREEN, never from arithmetic.
#   • MULTIQUESTION    two questions: each answered as its own tab appears, then the
#                      "Review your answers" screen's submit digit.
#   • WRAPPED          a 38-column pane wraps the question AND two option labels, one
#                      CJK (the break inserts no space) and one Latin (the break eats
#                      one) — both still resolve to the digit their row shows. This is
#                      #656: the screen gate used a literal grep, one line break made
#                      it miss, and the answerer refused a dialog that was on the
#                      screen and that --show had just parsed correctly.
#   • ENTER-VARIANT    a TUI where the digit only MOVES the cursor gets exactly one
#                      Enter, and only after the chosen row is read back off the
#                      screen; a cursor that never settles there gets exit 4 and no
#                      Enter at all — the footer hint is never the authority.
#   • VERIFY           success is the tool_result landing in the TRANSCRIPT (the
#                      recorded answer is echoed); a result that never lands → exit 4.
#   • CANCEL           --cancel sends exactly one Escape.
#   • DRY-RUN          prints the plan and sends NOTHING.
#
# The fake tmux keeps a STEP counter that advances on every send-keys, and
# capture-pane answers from $WORK/screens/<step>.txt (highest available when the
# step runs past the last screen) — that is how a leg models "the screen changes
# after each keystroke". FAKE_RESULT_AT_STEP appends the tool_result to the
# transcript at a given step, so the VERIFY leg exercises a real wait.
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-answer.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fa-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/screens"
INJECT="$WORK/inject.log"
STEP="$WORK/step"
PANE='%7'

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '  got: %s\n' "$2" >&2; exit 1; }

# --- fake tmux ---------------------------------------------------------------
# send-keys      → append the args to INJECT, advance STEP, maybe append the result
# capture-pane   → screens/<step>.txt, else the highest-numbered screen
# display-message → the pane id (exit 1 when FAKE_PANE_DEAD, i.e. a gone pane)
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
    if [ ! -f "\$f" ]; then f=\$(ls "$WORK/screens"/*.txt 2>/dev/null | sort -t/ -k9 -V | tail -n1); fi
    [ -n "\$f" ] && [ -f "\$f" ] && cat "\$f" ;;
  display-message)
    [ -n "\${FAKE_PANE_DEAD:-}" ] && exit 1
    printf '%s\n' "$PANE" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- transcript builders ------------------------------------------------------
# A pending question = an assistant tool_use with NO tool_result for its id.
TUID='toolu_PROBE1'
mk_transcript() {  # $1=out path, $2=questions JSON array
  QJSON="$2" OUT="$1" TUID="$TUID" python3 - <<'PY'
import json, os
tu = {"type": "assistant", "timestamp": "2026-09-13T10:00:00.000Z",
      "message": {"role": "assistant", "content": [
          {"type": "tool_use", "id": os.environ["TUID"],
           "name": "AskUserQuestion",
           "input": {"questions": json.loads(os.environ["QJSON"])}}]}}
with open(os.environ["OUT"], "w") as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "go"}}) + "\n")
    f.write(json.dumps(tu) + "\n")
PY
}
result_line() {  # $1=answer text → a transcript line carrying the tool_result
  TXT="$1" TUID="$TUID" python3 - <<'PY'
import json, os
print(json.dumps({"type": "user", "timestamp": "2026-09-13T10:00:09.000Z",
                  "message": {"role": "user", "content": [
                      {"type": "tool_result", "tool_use_id": os.environ["TUID"],
                       "content": os.environ["TXT"]}]}}))
PY
}

Q_SINGLE='[{"question":"Should the button be red or blue?","header":"Button color","multiSelect":false,
 "options":[{"label":"Red","description":"Use a red button"},{"label":"Blue","description":"Use a blue button"}]}]'
Q_MULTI='[{"question":"Which colors?","header":"Colors","multiSelect":true,
 "options":[{"label":"Red","description":"r"},{"label":"Green","description":"g"},{"label":"Blue","description":"b"}]}]'
Q_TWO='[{"question":"Which fruit?","header":"Fruit","multiSelect":false,
 "options":[{"label":"Apple","description":"a"},{"label":"Banana","description":"b"}]},
 {"question":"Which colors?","header":"Colors","multiSelect":true,
 "options":[{"label":"Red","description":"r"},{"label":"Green","description":"g"},{"label":"Blue","description":"b"}]}]'

# --- screens (verbatim shapes observed on Claude Code 2.1.270) ----------------
screen() { cat > "$WORK/screens/$1.txt"; }   # $1 = step number this screen is shown at
clear_screens() { rm -f "$WORK/screens"/*.txt; }

SCR_SINGLE='☐ Button color

Should the button be red or blue?

❯ 1. Red
     Use a red button
  2. Blue
     Use a blue button
  3. Type something.
────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel'

SCR_IDLE='⏺ Button color: Blue

❯
  ◆ Haiku 4.5'

run() {  # run <args...>  — fake tmux on PATH, deterministic knobs
  : > "$INJECT"; printf '0' > "$STEP"
  env PATH="$WORK/fakepath:$PATH" \
    FLEET_ANSWER_POLL="${POLL:-0}" \
    FLEET_ANSWER_TIMEOUT="${TMO:-3}" \
    FLEET_ALLOW_SENDKEYS=1 \
    FAKE_PANE_DEAD="${FAKE_PANE_DEAD:-}" \
    FAKE_RESULT_AT_STEP="${FAKE_RESULT_AT_STEP:-}" \
    FAKE_RESULT_LINE="${FAKE_RESULT_LINE:-}" \
    FAKE_TRANSCRIPT="${FAKE_TRANSCRIPT:-}" \
    "$SRC" "$@"
}
injected() { cat "$INJECT" 2>/dev/null; }
inject_count() { awk 'NF' "$INJECT" 2>/dev/null | wc -l | tr -d ' '; }
nothing_sent() { [ "$(inject_count)" = "0" ]; }

# ============================ USAGE =========================================
run >/dev/null 2>&1;                    [ $? = 2 ] || fail "no args must exit 2"
run --show >/dev/null 2>&1;             [ $? = 2 ] || fail "--show without a target must exit 2"
T="$WORK/t-single.jsonl"; mk_transcript "$T" "$Q_SINGLE"
clear_screens; printf '%s\n' "$SCR_SINGLE" | screen 0
run --answer "$PANE" --transcript "$T" 'x' >/dev/null 2>&1
[ $? = 2 ] || fail "a non-numeric pick must exit 2"
nothing_sent || fail "a malformed pick must send nothing" "$(injected)"
run --answer "$PANE" --transcript "$T" 9 >/dev/null 2>&1
[ $? = 2 ] || fail "a pick past the option count must exit 2"
nothing_sent || fail "an out-of-range pick must send nothing" "$(injected)"
run --answer "$PANE" --transcript "$T" 1 2 >/dev/null 2>&1
[ $? = 2 ] || fail "more picks than questions must exit 2"
printf 'selftest: USAGE legs PASS (no verb/target · non-numeric · out-of-range · pick arity — nothing sent)\n' >&2

# ============================ NO-PENDING ====================================
# The same tool_use, but its tool_result is present → the question is CLOSED.
TA="$WORK/t-answered.jsonl"; mk_transcript "$TA" "$Q_SINGLE"
result_line 'Your questions have been answered: "Should the button be red or blue?"="Blue".' >> "$TA"
clear_screens; printf '%s\n' "$SCR_IDLE" | screen 0
run --show "$PANE" --transcript "$TA" >/dev/null 2>&1
[ $? = 1 ] || fail "--show on an answered question must exit 1"
run --answer "$PANE" --transcript "$TA" 1 >/dev/null 2>&1
[ $? = 1 ] || fail "--answer on an answered question must exit 1"
nothing_sent || fail "NO-PENDING must send nothing — a needs pane may hold a permission prompt" "$(injected)"
TE="$WORK/t-empty.jsonl"; : > "$TE"
run --answer "$PANE" --transcript "$TE" 1 >/dev/null 2>&1
[ $? = 1 ] || fail "--answer with no AskUserQuestion at all must exit 1"
nothing_sent || fail "an empty transcript must send nothing" "$(injected)"
printf 'selftest: NO-PENDING legs PASS (answered / absent → exit 1, ZERO keystrokes)\n' >&2

# ============================ SHOW ==========================================
clear_screens; printf '%s\n' "$SCR_SINGLE" | screen 0
out=$(run --show "$PANE" --transcript "$T" 2>&1) || fail "--show on a pending question must exit 0" "$out"
case "$out" in *'Button color'*) : ;; *) fail "--show must print the header" "$out" ;; esac
case "$out" in *'Should the button be red or blue?'*) : ;; *) fail "--show must print the question" "$out" ;; esac
case "$out" in *Red*) : ;; *) fail "--show must print the option labels" "$out" ;; esac
case "$out" in *'2'*Blue*) : ;; *) fail "--show must number the options" "$out" ;; esac
nothing_sent || fail "--show must never send a keystroke" "$(injected)"
js=$(run --show "$PANE" --transcript "$T" --json 2>&1) || fail "--show --json must exit 0" "$js"
printf '%s' "$js" | python3 -c '
import json,sys
d=json.load(sys.stdin)
qs=d["questions"]
assert len(qs)==1, qs
assert qs[0]["header"]=="Button color", qs
assert [o["label"] for o in qs[0]["options"]]==["Red","Blue"], qs
assert qs[0]["multiSelect"] is False, qs
' || fail "--show --json must emit the parsed questions" "$js"
printf 'selftest: SHOW legs PASS (header · question · numbered labels · --json parses; no keystrokes)\n' >&2

# ============================ LABEL-GATE ====================================
# The screen shows a DIFFERENT dialog than the transcript's question → refuse.
clear_screens; printf '%s\n' 'Do you want to proceed?

❯ 1. Yes
  2. No

Enter to select · Esc to cancel' | screen 0
run --answer "$PANE" --transcript "$T" 2 >/dev/null 2>&1
[ $? = 3 ] || fail "a screen without the chosen label must exit 3"
nothing_sent || fail "LABEL-GATE must send nothing — never answer a dialog we cannot see" "$(injected)"
printf 'selftest: LABEL-GATE leg PASS (chosen label absent from the screen → exit 3, ZERO keystrokes)\n' >&2

# ============================ SINGLE ========================================
# Its own copy: the fake appends the tool_result, which would close $T for later legs.
TS="$WORK/t-single-run.jsonl"; cp "$T" "$TS"
clear_screens; printf '%s\n' "$SCR_SINGLE" | screen 0; printf '%s\n' "$SCR_IDLE" | screen 1
FAKE_TRANSCRIPT="$TS" FAKE_RESULT_AT_STEP=1 \
FAKE_RESULT_LINE="$(result_line 'Your questions have been answered: "Should the button be red or blue?"="Blue".')" \
  run --answer "$PANE" --transcript "$TS" 2 >"$WORK/out.txt" 2>&1 \
  || fail "single-select answer must exit 0" "$(cat "$WORK/out.txt")"
[ "$(inject_count)" = "1" ] || fail "single-select must send EXACTLY one keystroke (the digit)" "$(injected)"
case "$(injected)" in *' 2'*) : ;; *) fail "single-select must send the digit for the chosen label" "$(injected)" ;; esac
case "$(injected)" in *Enter*) fail "single-select must NOT send Enter (the digit submits)" "$(injected)" ;; esac
case "$(cat "$WORK/out.txt")" in *Blue*) : ;; *) fail "the recorded answer must be echoed" "$(cat "$WORK/out.txt")" ;; esac
printf 'selftest: SINGLE leg PASS (one digit, no Enter, answer echoed from the transcript)\n' >&2

# ============================ MULTISELECT ===================================
# Digits toggle without moving the cursor; Down walks to Submit; Enter submits.
TM="$WORK/t-multi.jsonl"; mk_transcript "$TM" "$Q_MULTI"
clear_screens
m_screen() {  # $1=step  $2=cursor row (1..3 options, 4 type-something, 5 submit) $3,$4=checked
  { printf '☐ Colors\n\nWhich colors?\n\n'
    for i in 1 2 3; do
      lab=$([ "$i" = 1 ] && echo Red; [ "$i" = 2 ] && echo Green; [ "$i" = 3 ] && echo Blue)
      chk=' '; case " $3 $4 " in *" $i "*) chk='✔' ;; esac
      cur='  '; [ "$2" = "$i" ] && cur='❯ '
      printf '%s%s. [%s] %s\n' "$cur" "$i" "$chk" "$lab"
    done
    cur='  '; [ "$2" = 4 ] && cur='❯ '; printf '%s4. [ ] Type something\n' "$cur"
    cur='     '; [ "$2" = 5 ] && cur='❯    '; printf '%sSubmit\n' "$cur"
    printf '────────────────────────────────────\n  5. Chat about this\n\nEnter to select · Tab/Arrow keys to navigate · Esc to cancel\n'
  } | screen "$1"
}
m_screen 0 1 '' ''          # fresh
m_screen 1 1 1 ''           # after digit 1 → Red checked, cursor still on 1
m_screen 2 1 1 3            # after digit 3 → Blue checked too
m_screen 3 2 1 3            # Down
m_screen 4 3 1 3            # Down
m_screen 5 4 1 3            # Down
m_screen 6 5 1 3            # Down → cursor on Submit
printf '%s\n' "$SCR_IDLE" | screen 7   # Enter → submitted
FAKE_TRANSCRIPT="$TM" FAKE_RESULT_AT_STEP=7 \
FAKE_RESULT_LINE="$(result_line 'Your questions have been answered: "Which colors?"="Red, Blue".')" \
  run --answer "$PANE" --transcript "$TM" '1,3' >"$WORK/out.txt" 2>&1 \
  || fail "multiSelect answer must exit 0" "$(cat "$WORK/out.txt")"
inj=$(injected)
[ "$(printf '%s\n' "$inj" | grep -c 'Down')" = "4" ] \
  || fail "multiSelect must walk Down until the cursor sits on Submit (4 here)" "$inj"
[ "$(printf '%s\n' "$inj" | grep -c 'Enter')" = "1" ] || fail "multiSelect must send exactly one Enter" "$inj"
printf '%s\n' "$inj" | head -2 | grep -q ' 1' || fail "multiSelect must toggle the first pick" "$inj"
printf '%s\n' "$inj" | head -2 | grep -q ' 3' || fail "multiSelect must toggle the second pick" "$inj"
printf '%s\n' "$inj" | tail -1 | grep -q 'Enter' || fail "Enter must come LAST" "$inj"
printf 'selftest: MULTISELECT leg PASS (digit per pick · Down to Submit read off the SCREEN · one trailing Enter)\n' >&2

# ============================ PARTIAL-SEND ==================================
# The SECOND pick's label is missing from the screen — but the FIRST toggle has
# already gone out. That is exit 4 (half-driven, a human must look), never exit 3
# ("nothing sent"): the exit codes are a promise about the pane's state, so the
# verdict comes from what was actually delivered, not from which question we are on.
TP="$WORK/t-partial.jsonl"; mk_transcript "$TP" "$Q_MULTI"
clear_screens
{ printf '☐ Colors\n\nWhich colors?\n\n❯ 1. [ ] Red\n  2. [ ] Green\n     Submit\n\nEnter to select · Esc to cancel\n'; } | screen 0
{ printf '☐ Colors\n\nWhich colors?\n\n❯ 1. [✔] Red\n  2. [ ] Green\n     Submit\n\nEnter to select · Esc to cancel\n'; } | screen 1
out=$(run --answer "$PANE" --transcript "$TP" '1,3' 2>&1); rc=$?
[ "$rc" = 4 ] || fail "a pick missing AFTER a keystroke already went out must exit 4 (got $rc)" "$out"
[ "$(inject_count)" = "1" ] || fail "PARTIAL-SEND must have delivered exactly the first toggle" "$(injected)"
printf 'selftest: PARTIAL-SEND leg PASS (label missing after the first toggle → exit 4, not 3)\n' >&2

# ============================ MULTIQUESTION =================================
TT="$WORK/t-two.jsonl"; mk_transcript "$TT" "$Q_TWO"
clear_screens
{ printf '←  ☐ Fruit  ☐ Colors  ✔ Submit  →\n\nWhich fruit?\n\n❯ 1. Apple\n  2. Banana\n  3. Type something.\n\nEnter to select · Esc to cancel\n'; } | screen 0
m_screen 1 1 '' ''                      # digit answered Fruit → auto-advanced to Colors
m_screen 2 1 2 ''                       # digit 2 → Green checked
m_screen 3 2 2 ''
m_screen 4 3 2 ''
m_screen 5 4 2 ''
m_screen 6 5 2 ''                       # cursor on Submit
{ printf 'Review your answers\n\n ● Which fruit?\n   → Apple\n ● Which colors?\n   → Green\n\nReady to submit your answers?\n\n❯ 1. Submit answers\n  2. Cancel\n'; } | screen 7
printf '%s\n' "$SCR_IDLE" | screen 8
FAKE_TRANSCRIPT="$TT" FAKE_RESULT_AT_STEP=8 \
FAKE_RESULT_LINE="$(result_line 'Your questions have been answered: "Which fruit?"="Apple", "Which colors?"="Green".')" \
  run --answer "$PANE" --transcript "$TT" 1 2 >"$WORK/out.txt" 2>&1 \
  || fail "two-question answer must exit 0" "$(cat "$WORK/out.txt")"
inj=$(injected)
printf '%s\n' "$inj" | head -1 | grep -q ' 1' || fail "question 1's pick must go first" "$inj"
printf '%s\n' "$inj" | grep -q 'Down' || fail "the multiSelect tab must still walk to Submit" "$inj"
printf '%s\n' "$inj" | tail -1 | grep -q ' 1' \
  || fail "the review screen's 'Submit answers' digit must come last" "$inj"
case "$(cat "$WORK/out.txt")" in *Apple*) : ;; *) fail "both recorded answers must be echoed" "$(cat "$WORK/out.txt")" ;; esac
printf 'selftest: MULTIQUESTION leg PASS (pick per tab in order · review screen submitted · answers echoed)\n' >&2

# ============================ WRAPPED =======================================
# A NARROW pane wraps both the question and the long option labels (issue #656).
# The screens below are the real 38-column render of a live Claude Code 2.1.272
# dialog, captured on an isolated socket — note that option 3's label continues on a
# line indented EXACTLY like the description under it, and that the CJK break inserts
# no space where the Latin one (option 4) eats the space it broke at. Before #656
# this was an outright outage, not a degradation: `grep -F` for the question text
# missed, so the gate refused with "the pane is not showing question 1" and the
# operator was sent to press it by hand — on a dialog that was right there, and that
# `--show` (which reads the transcript) had just printed correctly.
Q_WRAP='[{"question":"后台采集的 tick 间隔应该设成多少？改动会影响缓存新鲜度和 runs 贴合度","header":"tick 间隔","multiSelect":false,
 "options":[{"label":"120s：缓存最新鲜（推荐）","description":"设置 120 秒间隔"},
            {"label":"50s：runs 严格贴住 interval","description":"设置 50 秒间隔"},
            {"label":"120s + 后续单开 issue 压 tick 时长","description":"暂时采用 120 秒"},
            {"label":"Keep the current behaviour unchanged for now","description":"不做任何改动"}]}]'

# wrap_screen <cursor row> <step> — everything but the cursor is the live render.
wrap_screen() {
  { printf ' ☐ tick 间隔\n\n'
    printf '后台采集的 tick 间隔应该设成多少？改动会影\n响缓存新鲜度和 runs 贴合度\n\n'
    cur() { if [ "$1" = "$2" ]; then printf '❯ '; else printf '  '; fi; }
    cur "$1" 1; printf '1. 120s：缓存最新鲜（推荐）\n     设置 120 秒间隔，缓存数据保持最新\n'
    cur "$1" 2; printf '2. 50s：runs 严格贴住 interval\n     设置 50 秒间隔，runs\n     更严格地遵循间隔时间\n'
    cur "$1" 3; printf '3. 120s + 后续单开 issue 压 tick\n     时长\n     暂时采用 120 秒，后续开 issue\n     优化 tick 时长\n'
    cur "$1" 4; printf '4. Keep the current behaviour\n     unchanged for now\n     不做任何改动，维持现有配置\n'
    printf '  5. Type something.\n'
    printf '──────────────────────────────────────\n  6. Chat about this\n\n'
    printf 'Enter to select · ↑/↓ to navigate · n\nto add notes · Esc to cancel\n'
  } | screen "$2"
}

for pick in 3 4; do
  TW="$WORK/t-wrap-$pick.jsonl"; mk_transcript "$TW" "$Q_WRAP"
  clear_screens; wrap_screen 1 0; printf '%s\n' "$SCR_IDLE" | screen 1
  FAKE_TRANSCRIPT="$TW" FAKE_RESULT_AT_STEP=1 \
  FAKE_RESULT_LINE="$(result_line 'Your questions have been answered.')" \
    run --answer "$PANE" --transcript "$TW" "$pick" >"$WORK/out.txt" 2>&1 \
    || fail "a wrapped dialog must still answer (pick $pick)" "$(cat "$WORK/out.txt")"
  [ "$(inject_count)" = "1" ] || fail "pick $pick on a wrapped dialog must send exactly one digit" "$(injected)"
  case "$(injected)" in *" $pick"*) : ;; *) fail "pick $pick must resolve to the digit its WRAPPED row shows" "$(injected)" ;; esac
done

# …and the gate still refuses when the label genuinely is not there: whitespace is
# what stopped mattering, not the label.
TWX="$WORK/t-wrap-x.jsonl"; mk_transcript "$TWX" "$Q_WRAP"
clear_screens; printf '%s\n' 'Do you want to proceed?

❯ 1. Yes
  2. No' | screen 0
run --answer "$PANE" --transcript "$TWX" 3 >/dev/null 2>&1
[ $? = 3 ] || fail "a wrap-tolerant gate must still refuse a dialog that is not ours"
nothing_sent || fail "the wrap-tolerant gate must still send nothing when it refuses" "$(injected)"
printf 'selftest: WRAPPED legs PASS (CJK + Latin wrapped labels and a wrapped question resolve; a foreign dialog still refuses)\n' >&2

# ============================ ENTER-VARIANT =================================
# Today the digit selects AND submits, so nothing beyond it goes out (the SINGLE leg
# pins that). #656 read the footer `Enter to select · ↑/↓ to navigate · n to add
# notes` as proof that the digit no longer works. It does — but this leg is the TUI
# where it would not: after the digit the dialog is still up with the cursor parked
# on the chosen row. One Enter finishes it, reached only because the row was re-read.
TEV="$WORK/t-entervariant.jsonl"; mk_transcript "$TEV" "$Q_WRAP"
clear_screens; wrap_screen 1 0; wrap_screen 3 1; printf '%s\n' "$SCR_IDLE" | screen 2
FAKE_TRANSCRIPT="$TEV" FAKE_RESULT_AT_STEP=2 \
FAKE_RESULT_LINE="$(result_line 'Your questions have been answered.')" \
  run --answer "$PANE" --transcript "$TEV" 3 >"$WORK/out.txt" 2>&1 \
  || fail "a digit-only-moves TUI must still answer" "$(cat "$WORK/out.txt")"
inj=$(injected)
[ "$(inject_count)" = "2" ] || fail "the Enter variant must send the digit and ONE Enter" "$inj"
printf '%s\n' "$inj" | head -1 | grep -q ' 3' || fail "the digit must go first" "$inj"
printf '%s\n' "$inj" | tail -1 | grep -q 'Enter' || fail "Enter must come last" "$inj"

# A cursor that never settles on the chosen row is NOT an invitation to press Enter:
# the dialog is left open and a human is told, because Enter at a row we did not read
# back is precisely the "answered the wrong option" failure the gates exist to prevent.
TEX="$WORK/t-enterstuck.jsonl"; mk_transcript "$TEX" "$Q_WRAP"
clear_screens; wrap_screen 1 0; wrap_screen 1 1
out=$(run --answer "$PANE" --transcript "$TEX" 3 2>&1); rc=$?
[ "$rc" = 4 ] || fail "a dialog that neither closed nor moved the cursor must exit 4 (got $rc)" "$out"
[ "$(inject_count)" = "1" ] || fail "that case must have sent the digit and NOTHING else" "$(injected)"
case "$(injected)" in *Enter*) fail "Enter must never be sent at an unverified row" "$(injected)" ;; esac
printf 'selftest: ENTER-VARIANT legs PASS (digit-only-moves → one verified Enter · cursor never settles → exit 4, no Enter)\n' >&2

# ============================ VERIFY ========================================
# The keystrokes land but the tool_result NEVER does → exit 4, and say so.
clear_screens; printf '%s\n' "$SCR_SINGLE" | screen 0; printf '%s\n' "$SCR_IDLE" | screen 1
out=$(run --answer "$PANE" --transcript "$T" 2 2>&1); rc=$?
[ "$rc" = 4 ] || fail "an unconfirmed answer must exit 4 (got $rc)" "$out"
case "$out" in *confirm*) : ;; *) fail "exit 4 must say the answer was not confirmed" "$out" ;; esac
printf 'selftest: VERIFY leg PASS (no tool_result within the budget → exit 4, reported)\n' >&2

# ============================ CANCEL + DRY-RUN + GONE PANE ==================
clear_screens; printf '%s\n' "$SCR_SINGLE" | screen 0
run --cancel "$PANE" --transcript "$T" >/dev/null 2>&1 || fail "--cancel must exit 0"
[ "$(inject_count)" = "1" ] || fail "--cancel must send exactly one key" "$(injected)"
case "$(injected)" in *Escape*) : ;; *) fail "--cancel must send Escape" "$(injected)" ;; esac

out=$(run --answer "$PANE" --transcript "$T" 2 --dry-run 2>&1) || fail "--dry-run must exit 0" "$out"
nothing_sent || fail "--dry-run must send NOTHING" "$(injected)"
case "$out" in *2*) : ;; *) fail "--dry-run must print the planned keystroke" "$out" ;; esac

FAKE_PANE_DEAD=1 run --answer "$PANE" --transcript "$T" 2 >/dev/null 2>&1
[ $? = 1 ] || fail "a gone pane must exit 1"
nothing_sent || fail "a gone pane must send nothing" "$(injected)"
printf 'selftest: CANCEL/DRY-RUN/GONE-PANE legs PASS (one Escape · plan-only · dead pane refused)\n' >&2

printf 'selftest PASS: fleet-answer — pending gate + label gate + single/multiSelect/multi-question key plans + wrapped screens + transcript verify (#605, #656)\n'
exit 0
