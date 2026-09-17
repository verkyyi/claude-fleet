#!/bin/bash
# fleet-permission.sh — read (and, only ever to REFUSE, answer) a worker's open
# PERMISSION prompt from outside its pane (issue #640).
#
# WHY this exists. #605 closed the `AskUserQuestion` half of the mid-turn deadlock
# and said so explicitly: a permission prompt is NOT an AskUserQuestion, and
# bin/fleet-answer.sh refuses one by construction. That left the other half open,
# and on 2026-09-14 it cost a real worker its session: a guarded `rm` raised a
# permission prompt, the window went `needs`, and every channel failed in turn —
#
#   SendMessage              reached the pane and QUEUED under the dialog. A message
#                            cannot press a key; the prompt is mid-turn for its whole
#                            life, so the message waits for the answer that waits for
#                            the message. (The same deadlock fleet-answer.sh measured.)
#   fleet-comment --to-worker the issue-bridge daemon was dead — and a relayed comment
#                            is still only a message.
#   fleet-answer.sh          refused: no pending AskUserQuestion. Correctly.
#   tmux send-keys           hook-blocked (#437), which points you back at the bridge.
#
# …so the worker sat there until a human walked over. In a system whose whole pitch
# is "a room full of unattended workers", that is a hole.
#
# WHAT THIS DOES *NOT* DO. It never approves anything. A permission prompt is a
# human decision BY DESIGN — auto-pressing Yes is precisely what the guard rails
# exist to prevent, and no knob in this file turns that on. What it does instead:
#
#   1. --show  makes the blocked command READABLE without attaching to the pane.
#              That is the expensive part of the outage: the operator could see a red
#              row and nothing else, and had to `capture-pane` by hand to guess.
#   2. --deny  presses **No**, and only No. Refusing a blocked operation destroys
#              nothing — it hands control back to the worker, which is then free to
#              rewrite the command safely (in the real case: `[ -n "$G" ] && rm -f
#              "$G"/*.tick`, one line). "May I auto-answer No?" and "may I auto-answer
#              Yes?" are different questions with different answers.
#
# THE RAILS on --deny, each of which makes a mistake impossible rather than unlikely:
#
#   KNOB GATE     FLEET_ALLOW_AUTO_DENY=1 (env, or this fleet's conf). DEFAULT OFF:
#                 without it --deny prints what it WOULD press and sends nothing.
#   PENDING GATE  the transcript must show a tool_use with no tool_result — and it
#                 must NOT be an AskUserQuestion (that one is fleet-answer.sh's, and
#                 a digit typed at the wrong dialog answers the wrong question).
#   SCREEN GATE   the pane must actually be showing a "Do you want to …" dialog.
#   NO-ONLY GATE  the digit is the one the SCREEN gives to the unique row whose text
#                 begins with `No`. Never arithmetic, never a remembered index — and
#                 a row that begins with `Yes` can never be selected, because the
#                 chosen row is re-asserted against /^No\b/ after it is found. Zero
#                 such rows, or several, ⇒ refuse with nothing sent.
#
# Sanctioned keystrokes only (#437): a single digit. No Enter, no Escape, nothing else.
#
# After a confirmed refusal the deadlock is GONE — the worker has its turn back — so
# the reason is handed to it over the ordinary peer channel (bin/fleet-peer-send.sh),
# which is what lets it fix its own command instead of asking why it was rejected.
#
#   fleet-permission.sh [opts] --show <target>      what is blocked, and why
#   fleet-permission.sh [opts] --deny <target>      press No (gated; never Yes)
#
#   <target>  @<window-id> / %<pane-id> / <sess>:<idx>  (the fleet-peer-send grammar)
#   opts: -L <label>          tmux socket label (outside a fleet pane)
#         --session <fleet>   fleet whose socket to use (default: the caller's)
#         --transcript <path> use this transcript instead of resolving it
#         --json              --show: emit the blocked tool call as JSON
#         --request-token T   Codex denial: fingerprint from --show --json
#         --no-tell           --deny: do NOT peer-send the reason afterwards
#         --dry-run           print the plan, send nothing
#
# Exit: 0 done · 1 nothing pending / target unusable · 2 usage · 3 refused at a gate
#       (nothing sent) · 4 the digit was sent but the refusal never landed in the
#       transcript · 5 --deny is not armed (FLEET_ALLOW_AUTO_DENY unset).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# The knob is a CONF key, but an operator running this by hand types it in the
# environment — so remember the env value and put it back after the confs land
# (a conf is plain assignments, and sourcing one would otherwise overwrite it).
_ENV_AUTO_DENY="${FLEET_ALLOW_AUTO_DENY-}"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "fleet-permission: needs python3" >&2; exit 2; }

POLL="${FLEET_ANSWER_POLL:-1}"
TIMEOUT="${FLEET_ANSWER_TIMEOUT:-45}"
case "$POLL"    in ''|*[!0-9.]*) POLL=1 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*)  TIMEOUT=45 ;; esac

VERB="" TARGET="" SOCK="" SESS="" TPATH="" AS_JSON=0 DRY=0 TELL=1 REQUEST_TOKEN=''
usage() { sed -n '/^#   fleet-permission.sh \[opts\] --show/,/^#       transcript/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --show|--deny)
      [ -z "$VERB" ] || usage
      VERB="${1#--}"; TARGET="${2:-}"; [ -n "$TARGET" ] || usage; shift 2 ;;
    -L) SOCK="${2:-}"; shift 2 ;;
    -L*) SOCK="${1#-L}"; shift ;;
    --session) SESS="${2:-}"; shift 2 ;;
    --transcript) TPATH="${2:-}"; shift 2 ;;
    --json) AS_JSON=1; shift ;;
    --request-token) REQUEST_TOKEN="${2:-}"; shift 2 ;;
    --no-tell) TELL=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "fleet-permission: unexpected argument $1" >&2; usage ;;
  esac
done
[ -n "$VERB" ] || usage

# --- socket: inside a fleet pane bare tmux is already this fleet's server -----
if [ -z "$SOCK" ] && [ -z "${TMUX:-}" ]; then
  [ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null)
  [ -n "$SESS" ] && SOCK=$(fleet_socket "$SESS" 2>/dev/null)
fi
# the per-fleet conf overlay, then the environment back on top of it.
[ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null)
[ -n "$SESS" ] && fleet_load_conf "$SESS" 2>/dev/null
[ -n "$_ENV_AUTO_DENY" ] && FLEET_ALLOW_AUTO_DENY="$_ENV_AUTO_DENY"
ARMED=0; [ "${FLEET_ALLOW_AUTO_DENY:-0}" = 1 ] && ARMED=1

TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }
SK() { FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" "$@" 2>/dev/null; }

# --- the pane must exist (a dead pane has nothing open) -----------------------
PANE=$(TM display-message -p -t "$TARGET" '#{pane_id}' 2>/dev/null)
[ -n "$PANE" ] || { echo "fleet-permission: no live pane for '$TARGET'" >&2; exit 1; }
if [ "$(TM display-message -p -t "$PANE" '#{@cc_agent}')" = codex ]; then
  NATIVE=("$VERB" --pane "$PANE" --socket "$SOCK" --category perm --request-token "$REQUEST_TOKEN")
  [ "$AS_JSON" = 0 ] || NATIVE+=(--json)
  [ "$DRY" = 0 ] || NATIVE+=(--dry-run)
  export FLEET_ALLOW_AUTO_DENY="$ARMED"
  exec python3 "$BIN/fleet-codex-attention.py" "${NATIVE[@]}"
fi

# --- resolve the transcript (identical path to fleet-answer.sh) ---------------
# pane → Claude pid → the registry's sessionId → ~/.claude/projects/*/<sid>.jsonl.
# Exact and cwd-independent: a `cd` inside the pane cannot misresolve it.
if [ -z "$TPATH" ]; then
  pid=$(fleet_pane_claude_pid "$PANE" "$SOCK" 2>/dev/null)
  [ -n "$pid" ] || { echo "fleet-permission: no live Claude under pane $PANE" >&2; exit 1; }
  sid=$(fleet_cc_session_id "$pid" 2>/dev/null)
  [ -n "$sid" ] || { echo "fleet-permission: pid $pid is not a registered session (no sessionId)" >&2; exit 1; }
  for f in "$HOME/.claude/projects"/*/"$sid".jsonl; do [ -f "$f" ] && { TPATH="$f"; break; }; done
  [ -n "$TPATH" ] || { echo "fleet-permission: no transcript for session $sid" >&2; exit 1; }
fi
[ -f "$TPATH" ] || { echo "fleet-permission: transcript not readable: $TPATH" >&2; exit 1; }

# --- PENDING GATE: the blocked tool call, off the transcript ------------------
# The newest tool_use with no tool_result. AskUserQuestion is excluded on purpose:
# that dialog belongs to fleet-answer.sh, and the two must never drive each other's.
# Emits TAB rows: TUID <id> / NAME <tool> / ONE <line> per rendered input line /
# JSON <compact input>.
PEND=$(FP_T="$TPATH" python3 - <<'PY'
import json, os, sys

path = os.environ["FP_T"]
uses, done, order = {}, set(), []
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"tool_use"' not in line and "tool_result" not in line:
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
                if c.get("type") == "tool_use":
                    uses[c.get("id")] = (c.get("name") or "?", c.get("input") or {})
                    order.append(c.get("id"))
                elif c.get("type") == "tool_result":
                    done.add(c.get("tool_use_id"))
except OSError:
    sys.exit(1)

tuid = next((i for i in reversed(order) if i not in done and i is not None), None)
if tuid is None:
    sys.exit(1)
name, inp = uses[tuid]
if name == "AskUserQuestion":
    # fleet-answer.sh's dialog, not ours.
    sys.exit(2)

# Render the input the way the operator needs to read it: the fields that say WHAT
# would run, first and unabridged-ish, then whatever else the call carried.
lines, seen = [], set()
for k in ("command", "file_path", "path", "url", "pattern", "description"):
    v = inp.get(k)
    if isinstance(v, str) and v.strip():
        seen.add(k)
        lines.append("%s\t%s" % (k, v if len(v) <= 2000 else v[:2000] + " …"))
for k in sorted(inp):
    if k in seen:
        continue
    v = inp[k]
    v = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    if len(v) > 300:
        v = v[:300] + " …"
    lines.append("%s\t%s" % (k, v))

out = ["TUID\t%s" % tuid, "NAME\t%s" % name]
out += ["ONE\t%s" % l.replace("\n", "\\n") for l in lines]
out.append("JSON\t%s" % json.dumps({"tool_use_id": tuid, "tool": name, "input": inp},
                                   ensure_ascii=False))
print("\n".join(out))
PY
)
rc=$?
case "$rc" in
  0) : ;;
  2) echo "fleet-permission: the pending dialog on this pane is an AskUserQuestion — answer it with fleet-answer.sh (dash ⌃k), not here" >&2; exit 1 ;;
  *) echo "fleet-permission: nothing is pending on this pane (no tool_use is waiting for a result)" >&2; exit 1 ;;
esac

TUID=$(printf '%s\n' "$PEND" | awk -F'\t' '$1=="TUID"{print $2; exit}')
TOOL=$(printf '%s\n' "$PEND" | awk -F'\t' '$1=="NAME"{print $2; exit}')

# --- SCREEN GATE: the dialog as the pane is rendering it ----------------------
# The reason a permission prompt gives ("Dangerous rm operation on possibly-empty
# variable path: …") is Claude Code's own text — it is on the SCREEN and nowhere in
# the transcript, so this is the only place to read it from. Anchor on the question
# line, which is stable across the dialog's shapes ("Do you want to proceed?", "Do
# you want to make this edit to …?").
CAP="$(mktemp "${TMPDIR:-/tmp}/fp-cap.XXXXXX")" || exit 2
trap 'rm -f "$CAP"' EXIT
grab() { TM capture-pane -p -t "$PANE" > "$CAP" 2>/dev/null || : > "$CAP"; }
grab

# dialog_text → the prompt block (a bounded run of lines ending at the last
# numbered option), or nothing when no dialog is on screen.
#
# Claude Code draws the prompt inside a box, so every row arrives wrapped in
# `│ … │`. The border comes off FIRST, and the stripped text is what both this
# function's output and the No-row parse below read — otherwise the question line
# never matches its anchor and `│ ❯ 3. No, …` never parses as an option row.
dialog_text() {
  python3 - "$CAP" <<'PY'
import re, sys

BORDER = "\u2502\u2503\u254e\u254f\u2551|"   # the box edges Claude Code draws the prompt in
def debox(l):
    """One captured row, minus the box border that wraps it."""
    l = l.rstrip("\n").rstrip()
    l = re.sub(r"^[" + BORDER + r"]\s?", "", l)
    l = re.sub(r"\s*[" + BORDER + r"]$", "", l)
    return l.rstrip()

lines = [debox(l) for l in open(sys.argv[1], encoding="utf-8", errors="replace")]
anchor = None
for i, l in enumerate(lines):
    if re.match(r"^\s*Do you want to .*\?$", l):
        anchor = i
if anchor is None:
    sys.exit(1)
# Start at the box's TOP EDGE when one is in reach — a horizontal rule of pure
# box-drawing characters — so the block is the dialog and not 24 lines of whatever
# scrolled above it. No edge (an unboxed or clipped prompt) ⇒ the bounded window.
rule = re.compile(r"^[\s\u2500-\u257f]+$")
start = max(0, anchor - 24)
for i in range(anchor - 1, start - 1, -1):
    if rule.match(lines[i]) and lines[i].strip():
        start = i + 1
        break
end = anchor
opt = re.compile(r"^[\s\u276f>]*\d+\.\s+")
for i in range(anchor + 1, min(len(lines), anchor + 16)):
    if opt.match(lines[i]):
        end = i
block = [l for l in lines[start:end + 1] if not (l.strip() and rule.match(l))]
while block and not block[0].strip():
    block.pop(0)
while block and not block[-1].strip():
    block.pop()
print("\n".join(block))
PY
}

# ============================== --show =======================================
if [ "$VERB" = show ]; then
  if [ "$AS_JSON" = 1 ]; then
    printf '%s\n' "$PEND" | awk -F'\t' '$1=="JSON"{sub(/^JSON\t/, ""); print; exit}'
    exit 0
  fi
  printf 'pane %s · blocked %s call · %s\n' "$PANE" "$TOOL" "$TUID"
  printf '%s\n' "$PEND" | awk -F'\t' '$1=="ONE"{printf "  %-12s %s\n", $2, $3}'
  if dlg=$(dialog_text) && [ -n "$dlg" ]; then
    printf '\n--- the prompt, as the pane is showing it -------------------------\n%s\n' "$dlg"
  else
    printf '\n(no "Do you want to …" dialog on screen — the call may be blocked on\n' >&2
    printf ' something else, or the pane has scrolled past it)\n' >&2
  fi
  if [ "$ARMED" = 1 ]; then
    printf '\nrefuse it with: fleet-permission.sh --deny %s   (No only — never Yes)\n' "$TARGET"
  else
    printf '\nOnly a human may approve this. Auto-refusal (No, never Yes) is available\nbut OFF: set FLEET_ALLOW_AUTO_DENY=1 to arm `--deny`.\n'
  fi
  exit 0
fi

# ============================== --deny =======================================
DLG=$(dialog_text) || { echo "fleet-permission: no permission dialog on pane $PANE's screen — refusing to type at a pane we cannot read" >&2; exit 3; }

# NO-ONLY GATE. Take the digit the SCREEN gives the row that begins with `No`, then
# re-assert the chosen row against /^No\b/ — so the only way to reach send() is with
# a row this script has twice agreed is a refusal. A `Yes` row has no path here.
NOROW=$(FP_DLG="$DLG" python3 - <<'PY'
import os, re, sys
opt = re.compile(r"^[\s❯>]*(\d+)\.\s+(?:\[[^\]]*\]\s+)?(.*)$")
hits = []
for line in os.environ["FP_DLG"].splitlines():
    m = opt.match(line)
    if not m:
        continue
    text = m.group(2).strip()
    if re.match(r"^No\b", text):
        hits.append((m.group(1), text))
if len(hits) != 1:
    sys.exit(1)
digit, text = hits[0]
# belt-and-braces: never emit a digit whose row is not, re-read, a refusal.
if not re.match(r"^No\b", text) or re.match(r"^Yes\b", text):
    sys.exit(1)
print("%s\t%s" % (digit, text))
PY
) || { echo "fleet-permission: the dialog shows no single row starting with \"No\" — refusing (nothing sent)" >&2; exit 3; }
DIGIT=${NOROW%%$'\t'*}
NOTEXT=${NOROW#*$'\t'}

if [ "$DRY" = 1 ] || [ "$ARMED" = 0 ]; then
  printf 'would press %s ("%s") on pane %s to REFUSE the blocked %s call.\n' \
    "$DIGIT" "$NOTEXT" "$PANE" "$TOOL"
  if [ "$ARMED" = 0 ]; then
    echo "not armed: set FLEET_ALLOW_AUTO_DENY=1 (env or this fleet's conf). Nothing sent." >&2
    exit 5
  fi
  echo "nothing sent (--dry-run)"
  exit 0
fi

SK "$DIGIT" || true

# --- the verdict comes from the TRANSCRIPT, not the screen -------------------
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  if FP_T="$TPATH" FP_TUID="$TUID" python3 - <<'PY'
import json, os, sys
path, tuid = os.environ["FP_T"], os.environ["FP_TUID"]
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
            raise SystemExit(0)
raise SystemExit(1)
PY
  then
    printf 'refused (pane %s): pressed %s — "%s"\n' "$PANE" "$DIGIT" "$NOTEXT"
    break
  fi
  [ "$(date +%s)" -ge "$deadline" ] && {
    echo "fleet-permission: pressed $DIGIT but no result landed in the transcript within ${TIMEOUT}s — check the pane by hand" >&2
    exit 4
  }
  sleep "$POLL" 2>/dev/null || true
done

# --- hand the reason back, now that the pane can receive one -----------------
# Before the refusal this message would have queued under the dialog forever (the
# #605 deadlock). After it, the worker has a turn — so this is the one moment the
# ordinary peer channel works, and it is what lets the worker fix its own command.
if [ "$TELL" = 1 ] && [ -x "$BIN/fleet-peer-send.sh" ]; then
  msg="[fleet] Your $TOOL call was REFUSED from the dash — a permission prompt was
blocking your pane and nothing in the fleet may press Yes on one. Nobody is
objecting to the work: rewrite the call so it does not trip the guard, then carry
on. This is what the prompt said:

$DLG"
  if [ -n "$SOCK" ]; then
    printf '%s' "$msg" | "$BIN/fleet-peer-send.sh" -L "$SOCK" "$TARGET" - >/dev/null 2>&1 \
      && echo "told the worker why (peer message)" \
      || echo "fleet-permission: refusal landed, but the reason could not be delivered — say it yourself" >&2
  else
    printf '%s' "$msg" | "$BIN/fleet-peer-send.sh" "$TARGET" - >/dev/null 2>&1 \
      && echo "told the worker why (peer message)" \
      || echo "fleet-permission: refusal landed, but the reason could not be delivered — say it yourself" >&2
  fi
fi
exit 0
