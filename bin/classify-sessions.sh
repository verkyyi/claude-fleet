#!/bin/bash
# classify-sessions.sh — reconcile hook-derived @claude_state with reality using
# `claude -p` (haiku). Hooks are fast but semantically blind: a Stop between loop
# iterations looks like "done"/"needs" when the session is really LOOPING. This
# reads the pane and recovers the true intent for QUIET windows only. It is the
# ONLY way the purple 'looping' state gets set. OPTIONAL — everything else works
# without it; you just won't get looping detection or false-alarm correction.
#
# One mode:
#   --window <target>  — classify ONE window now. Fired by bin/classify-hook.sh on
#                        the Stop hook, so a stopped turn is disambiguated (done vs
#                        looping vs needs) within ~1-2s. This is the real-time path.
#                        The spinner's stuck-working demote also fires it directly.
#
# Cost gating (lazy):
#   * ONLY classifies windows whose state is done|needs|looping (ambiguous/quiet).
#     'working' windows are skipped entirely -> the hook heartbeat already knows them.
#   * Change-detected: a window is only sent to the LLM when its pane content
#     changed since last check. A loop paused between iterations has a static
#     screen -> classified once, then skipped -> steady-state cost ~= 0.
#   * Per-window lock so a Stop-hook fire and the spinner's demote can't double-run.
#
# Backends (issue #1229) — CLASSIFY_BACKEND, read AFTER fleet-lib.sh so the
# install's fleet.conf / fleet.settings can set it fleet-wide; the environment wins:
#   haiku   (default) `claude -p --model haiku` with the RUBRIC — today's behaviour,
#           byte for byte.
#   jev     Jev (TypeSafe System One, `POST /v1/systemone`): the SAME five rubric
#           lines as choice criteria, the SAME capture as its state. Measured on
#           39 real screens: 0.90 accuracy vs haiku's 0.79, 124ms p50 vs 6.7s —
#           and 100% on the 28/39 it was ≥0.7 confident about, so a verdict under
#           CLASSIFY_JEV_MIN_CONF (0.7) FALLS BACK to haiku. So does a missing key
#           (TYPESAFE_API_KEY, else CLASSIFY_JEV_KEY_FILE = ~/.config/typesafe/api_key),
#           a request that fails or times out (CLASSIFY_JEV_TIMEOUT, 1s), an http
#           error, or an answer outside the five — each with ONE log line. The
#           haiku call below is therefore never removed: it is the fallback path,
#           and with no key the script behaves exactly as `haiku`.
#   shadow  haiku decides, exactly as today; Jev is asked about the same capture and
#           {ts, window, hook state, haiku, jev, conf, capture hash, latencies} is
#           APPENDED to CLASSIFY_SHADOW_LOG (logs/classify-shadow.ndjson; the capture
#           text itself only on a DISAGREEMENT, so the rows to hand-label are
#           self-contained). Window state is never touched by the Jev half.
#           bin/classify-shadow-report.py turns a week of it into agreement, per-
#           confidence buckets, WORKING misreads and the disagreement list.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CACHE="$BIN/../logs/.classify-cache"; mkdir -p "$CACHE"
LOG="$BIN/../logs/classify.log"
MODEL="${CLASSIFY_MODEL:-haiku}"
SETTLE="${CLASSIFY_SETTLE:-0.5}"   # let the "scheduled/waiting" line render before capture

command -v claude >/dev/null 2>&1 || exit 0

# Helper `claude -p` calls carry NO MCP (issue #468). This is a screen classifier,
# not an agent: it needs the model and nothing else. Left unflagged, every call boots
# the operator's whole MCP set — 4+ node children (npx-resolved gmail/mcp-image/…),
# the remote connectors over the network, and a cold `rg` scan — measured at 5.2s and
# up to 517MB RSS for a one-word haiku answer, on EVERY Stop hook in EVERY window.
# `--strict-mcp-config` with an empty config pins MCP to nothing while leaving auth
# and settings intact (`--bare` is faster still but drops the login). Both call sites
# swallow stderr, so FLEET_HELPER_NO_MCP=0 is the no-edit escape hatch if a future
# CLI ever changes what these flags mean.
# =form, not two words: --mcp-config is variadic and would otherwise swallow a
# following positional (issue #476). Harmless here (the prompt arrives on stdin),
# kept identical to fleet-claude.sh so the safe shape is the one shape.
NOMCP=()
[ "${FLEET_HELPER_NO_MCP:-1}" = 1 ] && NOMCP=(--strict-mcp-config '--mcp-config={"mcpServers":{}}')

# Per-fleet tmux sockets (issue #159): each fleet is its own tmux server. The
# socket is inherited from $TMUX (the Stop hook fires in-pane) or handed in via
# CLASSIFY_SOCK (the spinner's stuck-demote fires out-of-band). TM() routes every
# tmux call to the right server accordingly.
TM() { if [ -n "${CLASSIFY_SOCK:-}" ]; then tmux -L "$CLASSIFY_SOCK" "$@"; else tmux "$@"; fi; }

# Authenticate the helper `claude -p` off the account POOL (issue #497). Bare, it
# rides the machine's AMBIENT login, which is the ONE credential no worker depends
# on — bin/fleet-claude.sh puts every worker on a pool token. When that ambient login
# lapsed on 2026-08-25 the fleet kept working and only this classifier (and the
# dash's since-retired summary column, #535) went dark. No-op when multi-account is off, or when a token is
# already inherited (the Stop-hook path runs inside a worker's claude).
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"
fleet_helper_claude_auth 2>/dev/null || :

# Backend knobs (issue #1229) — read AFTER the lib, so a line in the install's
# fleet.conf / fleet.settings sets them fleet-wide (and, as with every conf knob,
# a conf line outranks an inherited environment value: the conf assigns
# unconditionally). With neither, the environment is read — that is how the
# selftests and a one-off `CLASSIFY_BACKEND=jev bin/classify-sessions.sh …` drive it.
BACKEND="${CLASSIFY_BACKEND:-haiku}"
case "$BACKEND" in
  haiku|jev|shadow) : ;;
  *) printf '%s  %-10s CLASSIFY_BACKEND=%s unknown — using haiku\n' "$(date +%H:%M:%S)" - "$BACKEND" >> "$LOG"
     BACKEND=haiku ;;
esac
JEV_MIN_CONF="${CLASSIFY_JEV_MIN_CONF:-0.7}"
JEV_URL="${CLASSIFY_JEV_URL:-https://api.typesafe.ai/v1/systemone}"
JEV_MODEL="${CLASSIFY_JEV_MODEL:-jev-latest}"
JEV_TIMEOUT="${CLASSIFY_JEV_TIMEOUT:-1}"
JEV_KEY_FILE="${CLASSIFY_JEV_KEY_FILE:-$HOME/.config/typesafe/api_key}"
SHADOW_LOG="${CLASSIFY_SHADOW_LOG:-$BIN/../logs/classify-shadow.ndjson}"
SHADOW_MAX_MB="${CLASSIFY_SHADOW_MAX_MB:-64}"   # over this, keep the newest 20000 rows

RUBRIC='You are a status classifier for a coding-agent terminal session. The agent can be Claude Code or Codex. Based ONLY on the terminal screen below, reply with EXACTLY ONE word and nothing else:
WORKING - The agent is actively generating or a tool is running (e.g. shows "esc to interrupt", a live spinner, streaming output).
WAITING - The agent EXPLICITLY posed a question, requested specific input, or is blocked on a permission/confirmation prompt that stops progress until the user answers (e.g. "Do you want to proceed?", "Please provide the target path.", a numbered choice list awaiting a selection, "Allow this tool to run?"). This takes precedence: if the screen shows a real pending question OR permission prompt, it is WAITING even if a caret or chips are also visible. A bare idle prompt with only a recap and suggested commands is NOT waiting. The Codex hint "Ask Codex to do anything" is a placeholder, not a pending question.
LOOPING - idle right now but a scheduled wakeup or next loop iteration is pending (mentions waiting N seconds, scheduled, will continue, /loop).
STOPPED - finished; idle with nothing pending. This INCLUDES the normal post-turn idle screen: a recap/summary of the work the agent just COMPLETED, optionally followed by suggested-command chips (lines beginning "❯ ..." or "› ..."). Those chips are passive hints shown after a finished turn, not a question awaiting an answer — still STOPPED.
ERROR - a crash or error state.
Screen:
-----'

# norm_label <raw> — the one word the state table keys on, from whatever the model
# printed. Same precedence the historic `case` had (WAITING outranks LOOPING …), so
# "Stopped." and "The answer is STOPPED" still land on STOPPED; anything else is
# UNPARSED. Shared by every backend so the shadow log compares like with like.
norm_label() {
  case "$(printf '%s' "$1" | tr -d '[:space:].' | tr '[:lower:]' '[:upper:]')" in
    *WAITING*) echo WAITING ;;
    *LOOPING*) echo LOOPING ;;
    *STOPPED*) echo STOPPED ;;
    *ERROR*)   echo ERROR ;;
    *WORKING*) echo WORKING ;;
    *)         echo UNPARSED ;;
  esac
}

# jev_ask — the capture on stdin; the RUBRIC's five `WORD - text` lines become the
# choice criteria (ONE rubric, both backends), the capture is the `state`. Prints
# `CHOICE CONFIDENCE MS` and exits 0 on an answer; otherwise prints a short reason
# and exits 1 (no key / python3 missing / network / http NNN / timeout / a choice
# outside the five). One process, no curl: urllib is what the 124ms p50 was measured
# with. The key never touches argv.
JEV_PY='
import json, os, re, sys, time, urllib.request, urllib.error
rub = os.environ.get("JEV_RUBRIC", "")
crit = {}
for line in rub.splitlines():
    m = re.match(r"^([A-Z]+) - (.*)$", line)
    if m: crit[m.group(1)] = m.group(2)
state = sys.stdin.read()
body = {"model": os.environ["JEV_MODEL"], "state": state,
        "questions": {"status": {"type": "choice",
            "instructions": "You are a status classifier for a coding-agent terminal session (Claude Code or Codex). Based ONLY on the terminal screen in STATE, choose the status.",
            "criteria": crit}}}
req = urllib.request.Request(os.environ["JEV_URL"], data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + os.environ["JEV_KEY"], "Content-Type": "application/json"})
t = time.time()
try:
    with urllib.request.urlopen(req, timeout=float(os.environ["JEV_TIMEOUT"])) as r:
        ans = json.load(r)["answers"]["status"]
except urllib.error.HTTPError as e:
    print("http %s" % e.code); sys.exit(1)
except urllib.error.URLError as e:
    r = str(getattr(e, "reason", e)); print("timeout" if "timed out" in r else "net " + r[:60]); sys.exit(1)
except (TimeoutError, OSError) as e:
    print("timeout" if "timed out" in str(e) else "net " + str(e)[:60]); sys.exit(1)
except (ValueError, KeyError, TypeError):
    print("bad-response"); sys.exit(1)
ms = int((time.time() - t) * 1000)
choice = str(ans.get("choice", "")).upper()
if choice not in crit:
    print("bad-choice %s" % choice[:20]); sys.exit(1)
try: conf = float(ans.get("confidence", 0))
except (TypeError, ValueError): conf = 0.0
print("%s %.3f %d" % (choice, conf, ms))
'
jev_ask() {
  key="${TYPESAFE_API_KEY:-}"
  [ -n "$key" ] || key=$(head -n 1 "$JEV_KEY_FILE" 2>/dev/null | tr -d '[:space:]')
  [ -n "$key" ] || { echo "no key"; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "no python3"; return 1; }
  JEV_RUBRIC="$RUBRIC" JEV_URL="$JEV_URL" JEV_MODEL="$JEV_MODEL" JEV_TIMEOUT="$JEV_TIMEOUT" JEV_KEY="$key" \
    python3 -c "$JEV_PY" 2>/dev/null
}

# jev_confident <conf> — true when the answer clears CLASSIFY_JEV_MIN_CONF.
jev_confident() { awk -v c="$1" -v m="$JEV_MIN_CONF" 'BEGIN{exit !(c+0 >= m+0)}'; }

# shadow_row — append one ndjson row (issue #1229). Capture text rides along ONLY
# when the two disagree (or one side has no verdict), so a week of rows stays small
# and the disagreement list is labelable without a second capture. 0600 on create;
# past SHADOW_MAX_MB the file is trimmed to its newest 20000 rows.
# args: <target> <hook-state> <hash> <haiku-label> <haiku-secs> <jev-label> <conf> <jev-ms> <jev-err> <capture>
shadow_row() {
  command -v python3 >/dev/null 2>&1 || return 0
  ( umask 077
    SH_TS="$(date -u +%FT%TZ)" SH_WIN="$1" SH_ST="$2" SH_HASH="$3" SH_HAIKU="$4" SH_HAIKU_S="$5" \
    SH_JEV="$6" SH_CONF="$7" SH_JEV_MS="$8" SH_ERR="$9" SH_CAP="${10}" SH_LOG="$SHADOW_LOG" SH_MAX_MB="$SHADOW_MAX_MB" \
    python3 - <<'PY' 2>/dev/null
import json, os
e = os.environ
row = {"ts": e["SH_TS"], "window": e["SH_WIN"], "hook_state": e["SH_ST"], "hash": e["SH_HASH"],
       "haiku": e["SH_HAIKU"] or None, "haiku_s": int(e["SH_HAIKU_S"] or 0),
       "jev": e["SH_JEV"] or None, "conf": float(e["SH_CONF"]) if e["SH_CONF"] else None,
       "jev_ms": int(e["SH_JEV_MS"]) if e["SH_JEV_MS"] else None, "jev_err": e["SH_ERR"] or None}
if not row["haiku"] or not row["jev"] or row["haiku"] != row["jev"]:
    row["capture"] = e["SH_CAP"]
p = e["SH_LOG"]
with open(p, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
try:
    if os.path.getsize(p) > float(e["SH_MAX_MB"]) * 1024 * 1024:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines(True)[-20000:]
        with open(p + ".tmp", "w", encoding="utf-8") as f: f.writelines(lines)
        os.replace(p + ".tmp", p)
except OSError:
    pass
PY
  ) || :
}

# classify_one <target> — classify a single window (target = any tmux -t spec,
# e.g. a window id "@7" or "session:idx"). Honours the state gate, change-hash
# and a per-window lock. Never fails the caller.
classify_one() {
  target="$1"
  [ -z "$(TM display-message -p -t "$target" '#{@worker_lifecycle}' 2>/dev/null)" ] || return 0
  st=$(TM display-message -p -t "$target" '#{@claude_state}' 2>/dev/null)
  case "$st" in
    done|needs|looping) : ;;   # quiet/ambiguous -> candidate
    *) return 0 ;;             # working / empty -> skip (free)
  esac
  # A worker-declared `blocked` (issue #704) is not ambiguous: the worker wrote it
  # down, in so many words, and the screen it stops on is the ordinary post-turn
  # recap this rubric reads as STOPPED — so classifying it would wipe the red at the
  # very Stop the charter told the worker to make. Hook-declared outranks
  # screen-inferred; only a new prompt (UserPromptSubmit) or a dead pane clears it.
  [ "$(TM display-message -p -t "$target" '#{@claude_state}/#{@claude_needs}' 2>/dev/null)" = needs/blocked ] && return 0
  [ -z "$(TM display-message -p -t "$target" '#{@codex_attention}' 2>/dev/null)" ] || return 0
  observed=$(TM display-message -p -t "$target" '#{@cc_agent}|#{@cc_launcher_pid}|#{@codex_session_id}|#{@claude_state}|#{@claude_state_ts}' 2>/dev/null)

  # stable key for lock + hash: prefer the window id (survives re-slotting).
  wid=$(TM display-message -p -t "$target" '#{window_id}' 2>/dev/null)
  key=$(printf '%s' "${wid:-$target}" | tr '/:@' '___')
  lock="$CACHE/$key.lock"
  mkdir "$lock" 2>/dev/null || return 0            # someone else is on this window
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null" RETURN

  cap=$(TM capture-pane -p -t "$target" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -35)
  [ -z "$cap" ] && return 0

  h=$(printf '%s' "$cap" | cksum | awk '{print $1}')
  hf="$CACHE/$key.hash"
  [ "$h" = "$(cat "$hf" 2>/dev/null)" ] && return 0    # unchanged screen -> no LLM call

  # ---- the verdict: `label` is one of the five (or UNPARSED), `via` says who --------
  label=""; via=""; raw=""
  jev_label=""; jev_conf=""; jev_ms=""; jev_err=""
  if [ "$BACKEND" != haiku ]; then
    if jres=$(printf '%s' "$cap" | jev_ask); then
      set -- $jres; jev_label="$1"; jev_conf="$2"; jev_ms="$3"
      if [ "$BACKEND" = jev ]; then
        if jev_confident "$jev_conf"; then
          label="$jev_label"; via="jev"
        else
          printf '%s  %-10s jev %s conf=%s < %s — falling back to haiku\n' \
            "$(date +%H:%M:%S)" "$target" "$jev_label" "$jev_conf" "$JEV_MIN_CONF" >> "$LOG"
        fi
      fi
    else
      jev_err="${jres:-python3 error}"
      printf '%s  %-10s jev unavailable (%s) — %s\n' "$(date +%H:%M:%S)" "$target" "$jev_err" \
        "$([ "$BACKEND" = jev ] && echo 'falling back to haiku' || echo 'shadow row without a jev verdict')" >> "$LOG"
    fi
  fi

  haiku_label=""; haiku_s=""
  if [ -z "$label" ]; then
    # OUTSIDE tmux (issue #571): the helper inherits this pane's TMUX/TMUX_PANE and
    # the global hooks, so ITS SessionStart/Stop drove the PANE — cleared the
    # auto-handoff latch, read the pane's @ctx_pct, got nudged into /fleet-handoff
    # and /clear-ed the operator's session (16 cycles in a day). Every fleet hook
    # opens with `[ -n "$TMUX" ] || exit 0`, so stripping the two vars makes them
    # all no-ops in the helper; the hooks' own CLAUDE_CODE_ENTRYPOINT guard is the
    # second rail. The capture above already happened, in tmux.
    t0=$(date +%s)
    raw=$(printf '%s\n%s\n' "$RUBRIC" "$cap" \
          | env -u TMUX -u TMUX_PANE claude -p ${NOMCP[@]+"${NOMCP[@]}"} --model "$MODEL" 2>/dev/null)
    crc=$?
    haiku_s=$(( $(date +%s) - t0 ))
    # rc != 0 is NOT an unparseable answer, it is NO answer (issue #497) — `claude`
    # prints its auth failure on stdout, so the two are indistinguishable by text. Bail
    # before the hash is stamped: writing it would mark this screen "seen" and retire it
    # from every producer until the pane redraws, which is how a dead credential turned
    # a per-call failure into a permanently dark looping-detector.
    if [ "$crc" -ne 0 ]; then
      printf '%s  %-10s helper claude -p failed (rc=%s) — left unhashed for retry\n' \
        "$(date +%H:%M:%S)" "$target" "$crc" >> "$LOG"
      [ "$BACKEND" = shadow ] && shadow_row "$target" "$st" "$h" "" "$haiku_s" "$jev_label" "$jev_conf" "$jev_ms" "$jev_err" "$cap"
      return 0
    fi
    haiku_label=$(norm_label "$raw")
    label="$haiku_label"; via="haiku"
  fi
  # The helper may have started BEFORE the worker declared its blocker. Re-check
  # after the slow call, before either the verdict or its change-hash is committed.
  [ "$(TM display-message -p -t "$target" '#{@claude_state}/#{@claude_needs}' 2>/dev/null)" = needs/blocked ] && return 0
  [ -z "$(TM display-message -p -t "$target" '#{@codex_attention}' 2>/dev/null)" ] || return 0
  [ "$(TM display-message -p -t "$target" '#{@cc_agent}|#{@cc_launcher_pid}|#{@codex_session_id}|#{@claude_state}|#{@claude_state_ts}' 2>/dev/null)" = "$observed" ] || return 0
  echo "$h" > "$hf"     # rc=0 but unparseable: still "seen" — the model answered, we
                        # just could not use it, and re-asking the SAME screen won't help
  [ "$BACKEND" = shadow ] && shadow_row "$target" "$st" "$h" "$haiku_label" "$haiku_s" "$jev_label" "$jev_conf" "$jev_ms" "$jev_err" "$cap"
  tag=""; [ "$via" = jev ] && tag="  via=jev conf=$jev_conf"

  new=""
  case "$label" in
    WAITING) new="needs" ;;
    LOOPING) new="looping" ;;
    STOPPED) new="done" ;;
    ERROR)   new="needs" ;;
    WORKING) # A screen frame never PROMOTES a quiet window to working (issue
             # #846): only the UserPromptSubmit hook starts a turn, and this
             # path only ever runs on a done|needs|looping window (working is
             # skipped up top). A WORKING read here is a stale/misread frame
             # re-reddening what #806/#101 just demoted — record it, change
             # nothing, and let the hook own working-detection.
             printf '%s  %-10s working-read ignored (screen never promotes; #846)%s\n' "$(date +%H:%M:%S)" "$target" "$tag" >> "$LOG" ;;
    *) printf '%s  %-10s unparsed [%s]\n' "$(date +%H:%M:%S)" "$target" "${raw:0:40}" >> "$LOG" ;;
  esac

  if [ -n "$new" ] && [ "$new" != "$st" ]; then
    TM set-window-option -t "$target" @claude_state "$new" 2>/dev/null
    # This verdict comes from a screen read, not from the hook that knows WHY the
    # window went red, so it can never justify a `needs` SUBTYPE (issue #640) —
    # clear whatever bin/set-claude-state.sh left behind rather than let a stale
    # `ask`/`perm` ride a brand-new state. '' ⇒ the dash's plain `!`.
    TM set-window-option -t "$target" @claude_needs "" 2>/dev/null
    TM set-window-option -t "$target" @claude_state_ts "$(date +%s)" 2>/dev/null
    printf '%s  %-10s %-8s -> %s%s\n' "$(date +%H:%M:%S)" "$target" "$st" "$new" "$tag" >> "$LOG"
  fi
  return 0
}

# ---- single-window mode (event / Stop-hook path) ----------------------------
# The only mode: classify ONE window now, fired by the Stop hook (classify-hook.sh)
# or the spinner's stuck-working demote. A bare/unknown invocation is a clean no-op.
if [ "${1:-}" = "--window" ]; then
  [ -n "${2:-}" ] || exit 0
  sleep "$SETTLE" 2>/dev/null   # settle: let post-turn scheduling text land
  classify_one "$2"
  [ -f "$LOG" ] && { tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
fi
exit 0
