#!/bin/bash
# needs-reason-selftest.sh — WHY a window is red, end to end (issue #640).
#
# `needs` had one glyph and two meanings, and the two want opposite reflexes:
# an `AskUserQuestion` can be answered from the dash (#605, ⌃k), while a PERMISSION
# prompt can only be approved by a human standing at that pane. Told apart only by
# the red `!`, the operator had to attach to each red window to find out which —
# and on 2026-09-14 a worker sat on an unanswerable permission prompt while every
# other channel (SendMessage, the issue bridge, fleet-answer.sh, send-keys) failed
# in turn. This test pins the signal that ends the guessing.
#
# TWO HALVES, both hermetic (a PATH-shimmed `tmux`; no server, no Claude):
#
#   STAMP — bin/set-claude-state.sh writes @claude_needs beside every @claude_state.
#     * a permission Notification            → needs + `perm`
#     * a PreToolUse AskUserQuestion         → needs + `ask`
#     * a permission Notification whose TRANSCRIPT holds a pending AskUserQuestion
#                                            → needs + `ask` (issue #656). Claude Code
#       2.1.272 sends the identical `permission_prompt` Notification for a question
#       and for a blocked Bash call, so the wording cannot tell them apart and the
#       `perm` it produced buried #640's whole point: the dash said "go press it
#       yourself" about a question ⌃k could have answered. The transcript is the
#       arbiter — bin/fleet-pending-tool.sh, the same "tool_use with no tool_result"
#       rule bin/fleet-answer.sh and bin/fleet-permission.sh gate on, so the stamp
#       and the two tools that act on it can no longer disagree.
#     * any other PreToolUse / PostToolUse   → working + CLEARED
#     * a Stop                               → done    + CLEARED
#     * the benign idle_prompt Notification  → writes NOTHING (the #330/#105 rule:
#       it must not clobber the classifier's verdict — nor, now, its reason)
#     The clear-on-every-write is the freshness rail: no reader can ever pair a
#     fresh state with a stale reason, so no ts pairing and no extra read is needed.
#
#   GLYPH — bin/tmux-dashboard-rows.sh renders the subtype:
#     * needs + ask   → `?`   answerable from here
#     * needs + perm  → `⊘`   go press it yourself
#     * needs + blocked → `⊠` read the worker's issue (#704)
#     * needs + ''    → `!`   the historic undifferentiated red
#     …all four in the SAME red as before, all ONE display cell (the row's leading
#     glyph slot is a fixed width the right-pinned act/PR/ctx block is padded
#     against — a 2-cell emoji here would shear every red row), and the subtype must
#     never leak into a window that is not red.
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HOOK="$BIN/set-claude-state.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
[ -f "$HOOK" ] || { printf 'selftest: %s not found\n' "$HOOK" >&2; exit 2; }
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/needsreason.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$WORK/bin" "$WORK/.claude-dash/global" "$WORK/conf"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }

# ============================ STAMP =========================================
# Shim: record every set-window-option; answer display-message with nothing (so the
# auto-handoff nudge stays off — it needs a numeric @ctx_pct it will never get).
SETLOG="$WORK/setopts"
cat > "$WORK/bin/tmux" <<SHIM
#!/bin/sh
case "\${1:-}" in
  set-window-option) shift; printf '%s\n' "\$*" >> "$SETLOG" ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

# The CLEARED write is `@claude_needs` with an EMPTY value, so the recorded line
# ends in a space. Matching it needs that space AND the newline after it — without
# both, `@claude_needs perm` would satisfy the same test. The `END` sentinel keeps
# the last real line's newline, which `$( )` would otherwise strip.
CLEARED=$'@claude_needs \n'
hook() {  # hook <arg...> < payload — run the state hook against the shim
  : > "$SETLOG"
  env TMUX=fake TMUX_PANE='%3' PATH="$PATH" sh "$HOOK" "$@" >/dev/null 2>&1
  cat "$SETLOG" 2>/dev/null
  printf 'END\n'
}

out=$(printf '%s' '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}' | hook needs bell)
has "a permission Notification sets needs"          "$out" '@claude_state needs'
has "a permission Notification stamps perm"         "$out" '@claude_needs perm'

# --- #656: the SUBTYPE is settled by the TRANSCRIPT, never by the wording -----
# Every leg below sends the EXACT payload 2.1.272 emits for an open dialog (measured
# on an isolated socket): same message, same notification_type. Only the transcript
# differs — so if any of these four ever agree with each other again, the wording has
# crept back in as the discriminator.
mk_pending() {  # mk_pending <out> <tool> [answered] — newest tool_use is <tool>
  OUT="$1" TOOL="$2" ANS="${3:-}" python3 - <<'PY'
import json, os
rows = [{"type": "user", "message": {"role": "user", "content": "go"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_656", "name": os.environ["TOOL"], "input": {}}]}}]
if os.environ.get("ANS"):
    rows.append({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_656", "content": "done"}]}})
with open(os.environ["OUT"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}
notif() {  # notif [transcript_path] — the 2.1.272 open-dialog Notification, verbatim
  printf '{"session_id":"s","transcript_path":"%s","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}' "${1:-}"
}
T_ASK="$WORK/t-ask.jsonl";   mk_pending "$T_ASK"  AskUserQuestion
T_BASH="$WORK/t-bash.jsonl"; mk_pending "$T_BASH" Bash
T_DONE="$WORK/t-done.jsonl"; mk_pending "$T_DONE" AskUserQuestion answered

# The helper itself — the ONE rule, so a drift in it is caught before the stamp.
CHECKS=$((CHECKS+1))
[ "$(sh "$BIN/fleet-pending-tool.sh" "$T_ASK")" = AskUserQuestion ] \
  || fail "fleet-pending-tool.sh must name a pending AskUserQuestion" "$(sh "$BIN/fleet-pending-tool.sh" "$T_ASK")"
CHECKS=$((CHECKS+1))
[ "$(sh "$BIN/fleet-pending-tool.sh" "$T_BASH")" = Bash ] \
  || fail "fleet-pending-tool.sh must name a pending Bash" "$(sh "$BIN/fleet-pending-tool.sh" "$T_BASH")"
CHECKS=$((CHECKS+1))
sh "$BIN/fleet-pending-tool.sh" "$T_DONE" >/dev/null 2>&1 \
  && fail "fleet-pending-tool.sh must exit non-zero when the newest tool_use is answered"

out=$(notif "$T_ASK" | hook needs bell)
has "a question behind a permission_prompt still sets needs" "$out" '@claude_state needs'
has "a question behind a permission_prompt stamps ask"       "$out" '@claude_needs ask'
hasnt "…and must NOT stamp perm (that is the #656 regression)" "$out" '@claude_needs perm'

out=$(notif "$T_BASH" | hook needs bell)
has "a REAL permission prompt still stamps perm"             "$out" '@claude_needs perm'
hasnt "a real permission prompt must not stamp ask"          "$out" '@claude_needs ask'

# Fail-safe both ways: nothing pending, or no transcript at all, keeps the wording's
# answer (`perm`) — the direction that sends the operator to the pane rather than
# promising an answer channel that is not there.
out=$(notif "$T_DONE" | hook needs bell)
has "an already-answered transcript falls back to perm"      "$out" '@claude_needs perm'
out=$(notif "$WORK/nope.jsonl" | hook needs bell)
has "an unreadable transcript falls back to perm"            "$out" '@claude_needs perm'
out=$(notif | hook needs bell)
has "a payload with no transcript_path falls back to perm"   "$out" '@claude_needs perm'

out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}' | hook busy)
has "an AskUserQuestion PreToolUse sets needs"      "$out" '@claude_state needs'
has "an AskUserQuestion PreToolUse stamps ask"      "$out" '@claude_needs ask'

out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}' | hook busy)
has "an ordinary PreToolUse stays working"          "$out" '@claude_state working'
has "an ordinary PreToolUse CLEARS the reason"      "$out" "$CLEARED"
hasnt "an ordinary PreToolUse leaves no perm"       "$out" '@claude_needs perm'
hasnt "an ordinary PreToolUse leaves no ask"        "$out" '@claude_needs ask'

out=$(printf '%s' '{"hook_event_name":"PostToolUse"}' | hook working)
has "PostToolUse CLEARS the reason"                 "$out" "$CLEARED"
out=$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":false}' | hook 'done')
has "a Stop sets done"                              "$out" '@claude_state done'
has "a Stop CLEARS the reason"                      "$out" "$CLEARED"

# The benign idle_prompt must still write NOTHING AT ALL — the #105/#330 rule. If it
# started writing an empty @claude_needs it would erase the reason behind a state it
# deliberately refuses to touch, ~60s after any session went quiet.
out=$(printf '%s' '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}' | hook needs bell)
[ "$out" = END ] || fail "the idle_prompt Notification must write nothing at all" "$out"
CHECKS=$((CHECKS+1))
# 2.1.272 also labels it structurally; that spelling must stay just as silent, and it
# must not be dragged into the transcript read either (#656).
out=$(printf '%s' '{"hook_event_name":"Notification","message":"whatever it says now","notification_type":"idle_prompt","transcript_path":"'"$T_ASK"'"}' | hook needs bell)
[ "$out" = END ] || fail "a structurally-typed idle_prompt must write nothing at all" "$out"
CHECKS=$((CHECKS+1))
printf 'selftest: STAMP legs PASS (perm/ask stamped · subtype read off the TRANSCRIPT, not the wording · every other write clears · idle_prompt writes nothing)\n' >&2

# ============================ GLYPH =========================================
# Replay a fixture window list for the producer's 0x1f-separated list-windows read.
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037')
lw=0; fmt=0
for a in "$@"; do
  [ "$a" = list-windows ] && lw=1
  case "$a" in *"$US"*) fmt=1 ;; esac
done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"

US=$'\x1f'
RD='38;2;247;118;142m'      # the one red every `needs` row keeps
SESS=fleet-testrepo
WLIST_FILE="$WORK/wlist"; export WLIST_FILE
# Field order MUST match WFMT in tmux-dashboard-rows.sh:
#  session idx name path state state_ts wid @issue @origin @worktree @cc_agent @wid
#  @claude_needs @pin      (@claude_needs goes BEFORE @pin — see WFMT's note)
w() { printf '%s\n' "$SESS$US$1$US$2$US$3$US$4$US$US$5$US$6$US$US$7$US$US$US$8$US" >> "$WLIST_FILE"; }
: > "$WLIST_FILE"
#   idx name         cwd                state  wid @issue @worktree           @claude_needs
w 1 asking           /w/repo-issue-11   needs  @1  11  /w/repo-issue-11   ask
w 2 walled           /w/repo-issue-12   needs  @2  12  /w/repo-issue-12   perm
w 3 just-red         /w/repo-issue-13   needs  @3  13  /w/repo-issue-13   ''
w 4 busy-but-stamped /w/repo-issue-14   working @4 14  /w/repo-issue-14   perm
w 5 blocked          /w/repo-issue-15   needs  @5  15  /w/repo-issue-15   blocked
w 6 done-but-stamped /w/repo-issue-16   'done' @6  16  /w/repo-issue-16   blocked

out=$(FLEET_SESSION="$SESS" FZF_COLUMNS=120 bash "$ROWS" 2>&1) \
  || fail "rows producer exited non-zero" "$out"
row_of() { printf '%s\n' "$out" | grep -F "$SESS:$1$US"; }
r1=$(row_of 1); r2=$(row_of 2); r3=$(row_of 3); r4=$(row_of 4); r5=$(row_of 5); r6=$(row_of 6)
[ -n "$r1" ] && [ -n "$r2" ] && [ -n "$r3" ] && [ -n "$r4" ] && [ -n "$r5" ] && [ -n "$r6" ] \
  || fail "expected a row per fixture window" "$out"

# The glyph is asserted together with its colour escape, so a change that keeps the
# character but drops the red (or vice versa) fails here rather than silently.
has "ask  → a red ?"  "$r1" "${RD}?"
has "perm → a red ⊘"  "$r2" "${RD}⊘"
has "blocked → a red ⊠" "$r5" "${RD}⊠"
has "bare → the red ! it always had" "$r3" "${RD}!"
hasnt "ask must not render as !"  "$r1" "${RD}!"
hasnt "perm must not render as !" "$r2" "${RD}!"
hasnt "ask must not render as ⊘"  "$r1" "${RD}⊘"

# A stale-looking subtype on a window that is NOT red changes nothing: the reason is
# only ever consulted under `needs`, so a `working` row keeps its spinner.
hasnt "a working row must not take the perm glyph" "$r4" "⊘"
hasnt "a done row must not take the blocked glyph" "$r6" "⊠"

# Width: all four glyphs are ONE display cell, so the columns after them line up.
# Asserted by the `<glyph> <space> <grey handle cell>` shape every row shares.
for pair in "1:?" "2:⊘" "3:!" "5:⊠"; do
  idx=${pair%%:*}; g=${pair#*:}
  r=$(row_of "$idx")
  has "row $idx keeps the glyph slot's trailing space" "$r" "$g"$'\033'"[0m "
done
printf 'selftest: GLYPH legs PASS (? / ⊘ / ⊠ / ! · same red · one cell · never on a non-needs row)\n' >&2

printf 'selftest PASS: needs-reason — @claude_needs stamped+cleared by the hook, rendered by the dash (%s checks, #640)\n' "$CHECKS"
exit 0
