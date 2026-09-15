#!/bin/bash
# fleet-answer.sh — answer a worker's `AskUserQuestion` from outside its pane
# (issue #605). The one thing `SendMessage` structurally cannot do.
#
# WHY this exists. A peer message is delivered BETWEEN turns — `bin/fleet-peer-send.sh`
# says so itself: "the recipient sees it on its next turn (queued while it is
# mid-turn)". `AskUserQuestion` is mid-turn for its whole life: PreToolUse has fired,
# the tool is running, and `bin/set-claude-state.sh` is flipping the window to `needs`
# off exactly that. So:
#
#     the message waits for the question to be answered,
#     the question waits for the message.
#
# Measured on an isolated socket (Claude Code 2.1.270): with a question open, a
# peer-send frame REACHES the pane but only queues — the transcript shows
# `queue-operation enqueue`, then `remove … reason: "absorbed_mid_turn"` AFTER the
# question was answered. Not lost, just late. Somebody has to answer first, and
# before this script nothing in the fleet could.
#
# HOW the dialog is driven (all measured — first on 2.1.270, re-measured on 2.1.272
# for #656, unchanged):
#   • single-select     a DIGIT selects AND submits — no Enter. A TUI on which the
#                       digit only MOVES the selection (the `↑/↓ to navigate · Enter
#                       to select` shape) is already handled, and without a key table
#                       to go stale: see SUBMIT SHAPE below, which re-reads the pane
#                       and adds the Enter only when the cursor is read back parked on
#                       the row it chose. So both variants work off one code path.
#   • multi-question    a tab bar (`←  ☐ Fruit  ☐ Colors  ✔ Submit  →`); each tab's
#                       digit auto-advances to the next tab.
#   • multiSelect       a digit TOGGLES `[✔]` and leaves the cursor where it is; then
#                       ↓ to the `Submit` row and Enter.
#   • multi-question    ends on a "Review your answers" screen → its own submit digit.
#   • Esc               cancels the whole dialog.
#
# The footer HINT under the dialog is not the contract and must not be read as one.
# #656 was filed partly because a pane showed `Enter to select · ↑/↓ to navigate · n
# to add notes · Esc to cancel` and that was taken as "the digit no longer works" —
# it does; the same footer (minus the notes affordance) was already on the 2.1.270
# screens this script was written against. What the script does now is stop guessing
# either way: after the digit it RE-READS the pane, and it adds an Enter only when
# the dialog is still up with the cursor parked on the row it chose — the one state
# in which a digit demonstrably only moved the selection. See SUBMIT SHAPE below.
#
# THE TWO RAILS, both of which make a mistake impossible rather than unlikely:
#
#   1. PENDING GATE. Keys are sent only when the window's TRANSCRIPT shows an
#      `AskUserQuestion` tool_use with NO tool_result for its id. That is a harder
#      gate than `fleet-model-switch.sh`'s `@claude_state` check: `needs` is also how
#      a permission prompt looks, and a digit typed at one of THOSE answers the wrong
#      dialog. "tool_use without tool_result" is true only while a question is really
#      open. No pending question ⇒ exit 1 with zero keystrokes (#511's hazard, closed
#      by construction).
#
#   2. LABEL GATE. A pick names an index into the TRANSCRIPT's options array; the
#      script then finds THAT LABEL on the screen and sends the digit the screen
#      gives it. It never trusts its own arithmetic about row numbers. A TUI that
#      renumbers, reorders or truncates its rows therefore degrades to "not answered"
#      (exit 3, nothing sent) — never to "answered the wrong option".
#
#      THE ANCHOR IS THE ROW, NOT THE QUESTION (issue #702). Every screen check here
#      asks "is the row I am about to press on the screen?", never "is the question
#      text on the screen?". The question text is the weaker of the two — it proves
#      the dialog exists, not that the row exists — and it is also the part that
#      scrolls away first: options with per-option descriptions routinely run taller
#      than the pane, so the question goes off the top while every option row is
#      still visible. Anchored on the question, the gate refused dialogs that were
#      plainly on the screen; anchored on the row, it refuses exactly when it should.
#      `right_tab` retains the only thing the question text was load-bearing for —
#      that a multi-question dialog is on OUR tab.
#
#      WRAPPING IS NOT A MISMATCH (issue #656). Every screen comparison here is
#      whitespace-INSENSITIVE: both sides are squashed to their non-whitespace
#      characters before they are compared. A narrow pane wraps a long label or a
#      long question onto follow-on lines — and it does so WITHOUT inserting a space
#      when the text is CJK — so a literal `grep -F` for the question text misses,
#      and the gate refuses to answer a dialog that is in fact right there. That is
#      how #656's first real remote answer failed: the refusal was correct by its own
#      rule, and the rule was wrong. Squashing keeps the gate exactly as strong (two
#      dialogs that differ only in whitespace are not a hazard) while making a line
#      break a non-event. A wrapped label's continuation lines are absorbed the same
#      way, and only ever while the text so far is still a PREFIX of the label being
#      looked for — which is what stops the description line underneath from being
#      swallowed into the label.
#
# SUBMIT SHAPE. A single-select pick is followed by a re-read, and exactly three
# outcomes are allowed: the question is GONE (the digit submitted — today's TUI, and
# nothing further is sent); the question is still up with the cursor parked on the
# row we chose, seen on two consecutive reads (the digit only MOVED the selection —
# one Enter, and only then); or anything else, which is exit 4 with the dialog left
# for a human. So a TUI that changes its mind about whether the digit submits costs
# an extra keystroke, not a wrong answer — and Enter can never be pressed at a row
# this script has not just read back as the chosen one.
#
# Every step re-reads the pane (`capture-pane`) instead of firing a pre-computed key
# sequence blind, and the VERDICT comes from the transcript: success is the
# `tool_result` for that tool_use_id landing, with the recorded answer echoed back.
# So the tool is honest about the one thing that matters — whether the worker actually
# received the answer the operator chose.
#
# Sanctioned keystrokes only (#437): digits, Down, Enter, Escape. Nothing else, ever.
#
#   fleet-answer.sh [opts] --show   <target>            print the pending question(s)
#   fleet-answer.sh [opts] --answer <target> <pick>…    one pick per question, in order
#   fleet-answer.sh [opts] --cancel <target>            Esc the dialog
#
#   <target>  @<window-id> / %<pane-id> / <sess>:<idx>  (the fleet-peer-send grammar)
#   <pick>    an option number from --show; `1,3` toggles several in a multiSelect
#   opts: -L <label>          tmux socket label (outside a fleet pane)
#         --session <fleet>   fleet whose socket to use (default: the caller's)
#         --transcript <path> use this transcript instead of resolving it
#         --json              --show: emit the parsed questions as JSON
#         --dry-run           print the plan, send nothing
#
# Exit: 0 answered (and confirmed) · 1 no pending question / target unusable ·
#       2 usage or a malformed pick · 3 refused at the screen gate (nothing sent) ·
#       4 keystrokes sent but the answer was never confirmed in the transcript.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "fleet-answer: needs python3" >&2; exit 2; }

POLL="${FLEET_ANSWER_POLL:-1}"
TIMEOUT="${FLEET_ANSWER_TIMEOUT:-45}"
case "$POLL" in ''|*[!0-9.]*) POLL=1 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=45 ;; esac

VERB="" TARGET="" SOCK="" SESS="" TPATH="" AS_JSON=0 DRY=0
PICKS=()
usage() { sed -n '/^#   fleet-answer.sh \[opts\]/,/^#       4 keystrokes/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --show|--answer|--cancel)
      [ -z "$VERB" ] || usage
      VERB="${1#--}"; TARGET="${2:-}"; [ -n "$TARGET" ] || usage; shift 2 ;;
    -L) SOCK="${2:-}"; shift 2 ;;
    -L*) SOCK="${1#-L}"; shift ;;
    --session) SESS="${2:-}"; shift 2 ;;
    --transcript) TPATH="${2:-}"; shift 2 ;;
    --json) AS_JSON=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    -*) echo "fleet-answer: unknown option $1" >&2; usage ;;
    *) PICKS+=("$1"); shift ;;
  esac
done
[ -n "$VERB" ] || usage
[ "$VERB" = answer ] || [ ${#PICKS[@]} -eq 0 ] || usage

# --- socket: inside a fleet pane bare tmux is already this fleet's server -----
if [ -z "$SOCK" ] && [ -z "${TMUX:-}" ]; then
  [ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null)
  [ -n "$SESS" ] && SOCK=$(fleet_socket "$SESS" 2>/dev/null)
fi
TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }
SK() { FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" "$@" 2>/dev/null; }

# --- the pane must exist (a dead pane is nothing to answer) -------------------
PANE=$(TM display-message -p -t "$TARGET" '#{pane_id}' 2>/dev/null)
[ -n "$PANE" ] || { echo "fleet-answer: no live pane for '$TARGET'" >&2; exit 1; }

# --- resolve the transcript ---------------------------------------------------
# pane → Claude pid → the registry's sessionId → ~/.claude/projects/*/<sid>.jsonl.
# Exact and cwd-independent (a `cd` inside the pane cannot misresolve it).
if [ -z "$TPATH" ]; then
  pid=$(fleet_pane_claude_pid "$PANE" "$SOCK" 2>/dev/null)
  [ -n "$pid" ] || { echo "fleet-answer: no live Claude under pane $PANE" >&2; exit 1; }
  sid=$(fleet_cc_session_id "$pid" 2>/dev/null)
  [ -n "$sid" ] || { echo "fleet-answer: pid $pid is not a registered session (no sessionId)" >&2; exit 1; }
  for f in "$HOME/.claude/projects"/*/"$sid".jsonl; do [ -f "$f" ] && { TPATH="$f"; break; }; done
  [ -n "$TPATH" ] || { echo "fleet-answer: no transcript for session $sid" >&2; exit 1; }
fi
[ -f "$TPATH" ] || { echo "fleet-answer: transcript not readable: $TPATH" >&2; exit 1; }

# --- parse the PENDING question off the transcript ---------------------------
# A pending AskUserQuestion = the newest tool_use whose id has no tool_result yet.
# Emits TAB rows the shell reads: TUID / Q <qi> <multi> <header> <question> /
# O <qi> <oi> <label>. Exit 1 = nothing pending (the PENDING GATE).
PEND=$(FA_T="$TPATH" python3 - <<'PY'
import json, os, sys

path = os.environ["FA_T"]
uses, done = {}, set()
order = []
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "AskUserQuestion" not in line and "tool_result" not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            m = o.get("message")
            if not isinstance(m, dict):
                continue
            content = m.get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use" and c.get("name") == "AskUserQuestion":
                    uses[c.get("id")] = c.get("input") or {}
                    order.append(c.get("id"))
                elif c.get("type") == "tool_result":
                    done.add(c.get("tool_use_id"))
except OSError:
    sys.exit(1)

tuid = next((i for i in reversed(order) if i not in done and i is not None), None)
if tuid is None:
    sys.exit(1)
qs = uses[tuid].get("questions")
if not isinstance(qs, list) or not qs:
    sys.exit(1)

out = ["TUID\t%s" % tuid]
for qi, q in enumerate(qs):
    if not isinstance(q, dict):
        sys.exit(1)
    opts = q.get("options")
    if not isinstance(opts, list) or not opts:
        sys.exit(1)
    multi = "1" if q.get("multiSelect") else "0"
    out.append("Q\t%d\t%s\t%s\t%s" % (qi, multi, q.get("header") or "", q.get("question") or ""))
    for oi, o in enumerate(opts):
        if not isinstance(o, dict) or not isinstance(o.get("label"), str):
            sys.exit(1)
        out.append("O\t%d\t%d\t%s\t%s" % (qi, oi, o["label"], o.get("description") or ""))
print("\n".join(out))
PY
) || { echo "fleet-answer: no pending AskUserQuestion on this pane (a \`needs\` window may be waiting on a permission prompt instead)" >&2; exit 1; }

TUID=$(printf '%s\n' "$PEND" | awk -F'\t' '$1=="TUID"{print $2; exit}')
NQ=$(printf '%s\n' "$PEND" | awk -F'\t' '$1=="Q"' | wc -l | tr -d ' ')

q_field() { printf '%s\n' "$PEND" | awk -F'\t' -v q="$1" -v c="$2" '$1=="Q" && $2==q {print $c; exit}'; }
o_label() { printf '%s\n' "$PEND" | awk -F'\t' -v q="$1" -v o="$2" '$1=="O" && $2==q && $3==o {print $4; exit}'; }
o_count() { printf '%s\n' "$PEND" | awk -F'\t' -v q="$1" '$1=="O" && $2==q' | wc -l | tr -d ' '; }

# ============================== --show =======================================
if [ "$VERB" = show ]; then
  if [ "$AS_JSON" = 1 ]; then
    FA_T="$TPATH" FA_TUID="$TUID" python3 - <<'PY'
import json, os
path, tuid = os.environ["FA_T"], os.environ["FA_TUID"]
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if tuid not in line or "tool_use" not in line:
            continue
        o = json.loads(line)
        for c in o["message"]["content"]:
            if isinstance(c, dict) and c.get("id") == tuid:
                qs = c["input"]["questions"]
                for q in qs:
                    q["multiSelect"] = bool(q.get("multiSelect"))
                print(json.dumps({"tool_use_id": tuid, "questions": qs}, ensure_ascii=False))
                raise SystemExit(0)
raise SystemExit(1)
PY
    exit $?
  fi
  printf 'pane %s · %s pending question(s) · %s\n' "$PANE" "$NQ" "$TUID"
  qi=0
  while [ "$qi" -lt "$NQ" ]; do
    hdr=$(q_field "$qi" 4); qtext=$(q_field "$qi" 5)
    [ "$(q_field "$qi" 3)" = 1 ] && ms=' [multi-select]' || ms=''
    printf '\n[%s] %s%s\n  %s\n' "$((qi + 1))" "$hdr" "$ms" "$qtext"
    n=$(o_count "$qi"); oi=0
    while [ "$oi" -lt "$n" ]; do
      printf '    %s. %s\n' "$((oi + 1))" "$(o_label "$qi" "$oi")"
      oi=$((oi + 1))
    done
    qi=$((qi + 1))
  done
  printf '\nanswer with: fleet-answer.sh --answer %s %s\n' "$TARGET" \
    "$(awk -v n="$NQ" 'BEGIN{for(i=0;i<n;i++) printf "<pick> "}')"
  exit 0
fi

# ============================== --cancel =====================================
if [ "$VERB" = cancel ]; then
  if [ "$DRY" = 1 ]; then echo "plan: Escape (cancel the dialog on pane $PANE)"; exit 0; fi
  SK Escape || true
  echo "cancelled: sent Escape to pane $PANE (the worker sees the tool as cancelled)"
  exit 0
fi

# ============================== --answer =====================================
[ ${#PICKS[@]} -eq "$NQ" ] || {
  echo "fleet-answer: $NQ pending question(s) but ${#PICKS[@]} pick(s) — one per question, in order (see --show)" >&2
  exit 2
}

# Validate every pick BEFORE a single keystroke, and resolve it to labels.
WANT=()   # per question: TAB-joined labels, in pick order
qi=0
for p in "${PICKS[@]}"; do
  n=$(o_count "$qi"); multi=$(q_field "$qi" 3)
  labels=""
  IFS=',' read -r -a idxs <<< "$p"
  [ ${#idxs[@]} -gt 0 ] || { echo "fleet-answer: empty pick for question $((qi + 1))" >&2; exit 2; }
  [ ${#idxs[@]} -eq 1 ] || [ "$multi" = 1 ] || {
    echo "fleet-answer: question $((qi + 1)) is single-select — '$p' names several options" >&2; exit 2; }
  for i in "${idxs[@]}"; do
    case "$i" in ''|*[!0-9]*) echo "fleet-answer: pick '$i' is not a number" >&2; exit 2 ;; esac
    [ "$i" -ge 1 ] && [ "$i" -le "$n" ] || {
      echo "fleet-answer: pick $i is out of range for question $((qi + 1)) (1..$n)" >&2; exit 2; }
    lab=$(o_label "$qi" "$((i - 1))")
    [ -n "$lab" ] || { echo "fleet-answer: no label for pick $i of question $((qi + 1))" >&2; exit 2; }
    labels="${labels:+$labels$(printf '\t')}$lab"
  done
  WANT+=("$labels")
  qi=$((qi + 1))
done

CAP="$(mktemp "${TMPDIR:-/tmp}/fa-cap.XXXXXX")" || exit 2
trap 'rm -f "$CAP"' EXIT
grab() { TM capture-pane -p -t "$PANE" > "$CAP" 2>/dev/null || : > "$CAP"; }

# digit_for <label> — the number the SCREEN gives that label's row, or exit 1.
# Rows look like `❯ 1. Red` or `  2. [✔] Green`; the match must be unique.
#
# A long label WRAPS in a narrow pane (issue #656), onto follow-on lines that carry
# the same indent as the description lines under the row — so they cannot be told
# apart by shape. They are told apart by the LABEL WE ARE LOOKING FOR: a follow-on
# line is absorbed only while everything accumulated so far is still a prefix of that
# label, and absorption stops the instant the label is complete. Comparison is
# whitespace-insensitive throughout, because a CJK wrap inserts no space and a Latin
# one eats the space it broke at. An EXACT match outranks the `>= 3 chars` prefix
# fallback, so a label that is a prefix of another option no longer refuses.
#
# THE PREVIEW PANEL IS NOT PART OF THE ROW (issue #702). When the options carry
# `preview` text the dialog renders a bordered panel in a RIGHT-HAND COLUMN, so every
# option row — and every wrapped continuation of one — has a slice of that panel
# appended to it:
#     `  2. 只打印我自己这个窗口         ├─── ✂ ─── 12 lines hidden ────┤`
# "the row's text equals the label" is then false for EVERY row at once, and squashing
# the whitespace only pulls the panel's own words into the comparison. So each line is
# cut at its column boundary before anything else looks at it: the panel sits in a
# gutter, so its left border is a box-drawing character (U+2500–U+257F) preceded by
# whitespace, and everything from there rightwards belongs to another column. A label
# that itself contained a space-separated box-drawing character would be cut short —
# and that degrades to a PREFIX, i.e. to a refusal, never to a wrong row.
digit_for() {
  FA_LAB="$1" python3 - "$CAP" <<'PY'
import os, re, sys

def squash(t):
    return re.sub(r"\s+", "", t)

# everything from the first whitespace-preceded box-drawing char is another column
PANEL = re.compile(r"\s[\u2500-\u257f].*$")

def cut(t):
    return PANEL.sub("", t)

want = squash(os.environ["FA_LAB"])
OPT  = re.compile(r"^[\s❯>]*(\d+)\.\s+(?:\[[^\]]*\]\s+)?(.*)$")
RULE = re.compile(r"^[\s\u2500-\u257f]+$")

lines = [cut(l.rstrip("\n")) for l in open(sys.argv[1], encoding="utf-8", errors="replace")]
exact, prefix = [], []
for i, line in enumerate(lines):
    m = OPT.match(line)
    if not m:
        continue
    acc, j = m.group(2).strip(), i + 1
    while squash(acc) != want and j < len(lines):
        nxt = lines[j]
        if not nxt.strip() or OPT.match(nxt) or RULE.match(nxt):
            break
        if not want.startswith(squash(acc + nxt.strip())):
            break
        acc = acc + nxt.strip()
        j += 1
    text = squash(acc)
    if not text:
        continue
    if text == want:
        exact.append(m.group(1))
    elif want.startswith(text) and len(text) >= 3:
        prefix.append(m.group(1))
hits = exact or prefix
sys.exit(1) if len(set(hits)) != 1 else print(hits[0])
PY
}
# screen_has <text> — is <text> on the captured screen, ignoring every line break and
# run of spaces the pane's width introduced? This is the wrap-proof `grep -F` (#656),
# reading the same COLUMNS digit_for does (#702) — without the cut, a right-hand
# preview panel interleaves its own words between the halves of a wrapped question
# and the squashed haystack no longer contains it.
screen_has() {
  FA_NEEDLE="$1" python3 - "$CAP" <<'PY'
import os, re, sys
PANEL  = re.compile(r"\s[\u2500-\u257f].*$")   # the column cut — see digit_for
squash = lambda t: re.sub(r"\s+", "", t)
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    hay = squash("\n".join(PANEL.sub("", l.rstrip("\n")) for l in fh))
sys.exit(0 if squash(os.environ["FA_NEEDLE"]) in hay else 1)
PY
}
# cursor_digit — the number of the row the cursor (❯) is parked on, or nothing. The
# `<digit>.` is required, so the pane's own `❯ ` input prompt can never match.
cursor_digit() {
  python3 - "$CAP" <<'PY'
import re, sys
CUR = re.compile(r"^\s*[❯>]\s*(\d+)\.\s")
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = CUR.match(line)
    if m:
        print(m.group(1))
        break
PY
}
# cursor_submit — is the cursor parked on the multiSelect `Submit` row? Same pattern
# it has always used, but reading the same COLUMNS digit_for does (#702): the panel
# text is arbitrary — it is the option's own `preview` — so a preview containing the
# word "Submit" would otherwise satisfy this from an OPTION row, and the walk would
# stop early and press Enter there. The cut makes the panel unable to answer for the
# left column at all.
cursor_submit() {
  python3 - "$CAP" <<'PY'
import re, sys
PANEL = re.compile(r"\s[\u2500-\u257f].*$")   # the column cut — see digit_for
CUR   = re.compile(r"^\s*❯.*Submit")
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if CUR.match(PANEL.sub("", line.rstrip("\n"))):
        sys.exit(0)
sys.exit(1)
PY
}

# right_tab <qi> — is the dialog on question <qi>'s tab? A single-question dialog has
# no tab bar, so it is trivially true. For a multi-question one it is true when our
# question's text is on the screen and ALSO when NO question's text is — the whole
# header block can scroll off (issue #702), and that must not read as "wrong tab". It
# is false only when some OTHER question of this dialog is the one showing, which is
# the single hazard the old question-text gate was really guarding against.
right_tab() {
  [ "$NQ" -le 1 ] && return 0
  screen_has "$(q_field "$1" 5)" && return 0
  local i=0
  while [ "$i" -lt "$NQ" ]; do
    if [ "$i" != "$1" ] && screen_has "$(q_field "$i" 5)"; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

deadline=$(( $(date +%s) + TIMEOUT ))
nap() { sleep "$POLL" 2>/dev/null || true; }
expired() { [ "$(date +%s)" -ge "$deadline" ]; }

PLAN=()   # --dry-run collects instead of sending
SENT=0    # keystrokes actually delivered — the ONLY basis for "3 = nothing sent"
send() { if [ "$DRY" = 1 ]; then PLAN+=("$*"); else SK "$@" || true; SENT=$((SENT + 1)); fi; }
# A bail-out AFTER keys have gone out is exit 4 (the dialog is half-driven and a
# human must look); before any key it is exit 3 (refused, pane untouched). Deciding
# this from `SENT` rather than from which question we are on is what keeps the
# promise the exit codes make — a multiSelect whose SECOND pick is missing from the
# screen has already toggled the first one, and must not claim it sent nothing.
bail() { printf 'fleet-answer: %s\n' "$1" >&2; [ "$SENT" = 0 ] && exit 3 || exit 4; }

qi=0
while [ "$qi" -lt "$NQ" ]; do
  multi=$(q_field "$qi" 3)
  IFS=$'\t' read -r -a labs <<< "${WANT[$qi]}"

  # THE SCREEN GATE, anchored on THE ROW WE ARE ABOUT TO PRESS (issue #702).
  # It used to wait for the QUESTION TEXT, and that is the wrong anchor: options with
  # per-option descriptions routinely run longer than the pane is tall, so the
  # question scrolls off while every option row is still sitting right there — and a
  # dialog that was plainly visible, and that `--show` had just parsed correctly, got
  # refused. The gate's two purposes (#605) are "never type into a dialog we cannot
  # see" and "locate by label, never blind-press a number", and BOTH are served by the
  # chosen row being on the screen — neither is served by the question text, which
  # proves only that the dialog exists, not that the row we are aiming at does. So the
  # anchor is the label, and `right_tab` keeps the one thing the question text was
  # really buying: that a multi-question dialog is on OUR tab. Still on the wrong tab
  # (or the row still absent) when the budget runs out ⇒ refuse, nothing sent.
  seen=0 why=''
  while :; do
    grab
    if ! digit_for "${labs[0]}" >/dev/null 2>&1; then
      why="option \"${labs[0]}\" is not on the screen (or matches several rows) for question $((qi + 1)) — refusing to type at a row we cannot see"
    elif right_tab "$qi"; then
      seen=1; break
    else
      why="question $((qi + 1))'s text is off-screen while ANOTHER question of this dialog is the one showing — refusing to type at the wrong tab"
    fi
    expired && break
    nap
  done
  [ "$seen" = 1 ] || bail "$why"

  # Toggle / select each pick by the digit the SCREEN gives its label.
  d='' lab1=''
  for lab in "${labs[@]}"; do
    lab1="$lab"
    grab
    d=$(digit_for "$lab") \
      || bail "option \"$lab\" is not on the screen (or matches several rows) for question $((qi + 1))"
    send "$d"
    [ "$DRY" = 1 ] || nap
  done

  # SUBMIT SHAPE, single-select (issue #656). On every TUI measured so far the digit
  # both selects and submits, so the normal outcome is "the question is gone" and
  # nothing more is sent. But the footer hint has read `Enter to select` the whole
  # time, and #656 was filed on the belief that some variant only MOVES the cursor.
  # Rather than trust either reading, look: a question still on screen with the
  # cursor parked on the row we just chose — on two consecutive reads, so a redraw
  # racing the submit cannot fake it — is that variant, and the single Enter that
  # finishes it is safe precisely because the row was read back, not assumed. Neither
  # shape within the budget means the dialog is half-driven: exit 4, hands off.
  if [ "$multi" != 1 ] && [ "$DRY" != 1 ] && [ -n "$d" ]; then
    submitted=0; parked=0
    while :; do
      grab
      # "our row is still the one on offer" = the chosen LABEL still sitting on row
      # $d, on OUR tab, with the cursor on it. The LABEL is the load-bearing leg:
      # once answered the pane echoes `· <question> → <label>` in the transcript area,
      # which carries no `<digit>. ` prefix so no row matches, and on a multi-question
      # dialog the next tab is already up with different labels. No label on row $d ⇒
      # this dialog has moved on ⇒ submitted. The question text used to be a REQUIRED
      # leg here as well, and issue #702 is why it no longer is: with the question
      # scrolled off, a digit that had only MOVED the cursor read as "submitted", the
      # Enter that would have finished it was never sent, and the answer then timed out
      # unconfirmed. `right_tab` keeps the multi-question half of that leg.
      [ "$(digit_for "$lab1" 2>/dev/null)" = "$d" ] && right_tab "$qi" || { submitted=1; break; }
      if [ "$(cursor_digit)" = "$d" ]; then
        parked=$((parked + 1)); [ "$parked" -ge 2 ] && break
      else
        parked=0
      fi
      expired && break
      nap
    done
    if [ "$submitted" = 0 ]; then
      [ "$parked" -ge 2 ] || bail "question $((qi + 1)) is still showing \"$lab1\" on row $d after that digit was pressed, but the cursor never settled there — stopping (dialog left open)"
      send Enter
      nap
    fi
  fi

  # multiSelect does not submit on a digit: walk ↓ until the cursor sits on the
  # `Submit` row (read off the screen, never counted), then Enter.
  if [ "$multi" = 1 ]; then
    if [ "$DRY" = 1 ]; then
      PLAN+=("Down… until the cursor reaches Submit" "Enter")
    else
      steps=0; maxsteps=$(( $(o_count "$qi") + 4 ))
      while :; do
        grab
        cursor_submit && break
        [ "$steps" -ge "$maxsteps" ] && { echo "fleet-answer: could not reach the Submit row for question $((qi + 1)) after $steps ↓ — stopping (dialog left open)" >&2; exit 4; }
        expired && { echo "fleet-answer: timed out walking to Submit on question $((qi + 1)) (dialog left open)" >&2; exit 4; }
        send Down; steps=$((steps + 1)); nap
      done
      send Enter; nap
    fi
  fi
  qi=$((qi + 1))
done

# A multi-question dialog ends on a confirmation screen — submit it the same way,
# by the label the screen shows.
if [ "$DRY" = 1 ]; then
  [ "$NQ" -gt 1 ] && PLAN+=("the review screen's \"Submit answers\" digit")
  printf 'plan for pane %s (%s):\n' "$PANE" "$TUID"
  for s in "${PLAN[@]}"; do printf '  · %s\n' "$s"; done
  echo "nothing sent (--dry-run)"
  exit 0
fi
if [ "$NQ" -gt 1 ]; then
  # Same anchor as every other step (#702): the row we are about to press. The
  # "Ready to submit your answers?" line this used to wait for is one more thing a
  # long answer list scrolls off, while the `Submit answers` ROW is both what we need
  # and proof the review screen is up.
  ok=0
  while :; do
    grab
    if d=$(digit_for 'Submit answers'); then send "$d"; nap; ok=1; break; fi
    expired && break
    nap
  done
  [ "$ok" = 1 ] || bail 'the review screen never offered a "Submit answers" row — answers entered but NOT submitted'
fi

# --- the verdict comes from the TRANSCRIPT, not the screen -------------------
while :; do
  ans=$(FA_T="$TPATH" FA_TUID="$TUID" python3 - <<'PY'
import json, os, sys
path, tuid = os.environ["FA_T"], os.environ["FA_TUID"]
try:
    fh = open(path, encoding="utf-8", errors="replace")
except OSError:
    sys.exit(1)
for line in fh:
    if tuid not in line or "tool_result" not in line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    m = o.get("message")
    if not isinstance(m, dict):
        continue
    for c in m.get("content") or []:
        if isinstance(c, dict) and c.get("tool_use_id") == tuid:
            body = c.get("content")
            if isinstance(body, list):
                body = " ".join(str(b.get("text", "")) for b in body if isinstance(b, dict))
            print(str(body).strip())
            raise SystemExit(0)
raise SystemExit(1)
PY
) && { printf 'answered (pane %s): %s\n' "$PANE" "$ans"; exit 0; }
  expired && break
  nap
done
echo "fleet-answer: keystrokes sent but the answer was never confirmed in the transcript within ${TIMEOUT}s — check the pane by hand" >&2
exit 4
