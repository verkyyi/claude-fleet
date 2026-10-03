#!/bin/sh
# set-claude-state.sh <state> [bell]
# Stamps the current tmux window's @claude_state (semantic: working|done|needs).
# <state> is a hook verb (busy|working|done|needs) or the worker's own `blocked`
# (issue #704) — a red that the hook edges of the same turn do not erase; see below.
# The tmux-spinner.sh daemon reads @claude_state and renders ALL the visuals
# (spinner glyph + its pulsing font color + name color) via @spin, so this hook
# only sets the semantic state and (for needs) rings the bell.
# Registered as a Claude Code hook (see hooks/settings-hooks.json).
# Always exits 0 so it never blocks a turn.
set -u  # POSIX sh: pipefail is bash-only (dash has none)
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0
# A HEADLESS claude is NOT this pane's session (issue #571). A `claude -p` helper —
# the Stop-hook classifier (bin/classify-sessions.sh), or any headless claude a
# worker spawns from its Bash tool — inherits the pane's TMUX/TMUX_PANE *and* the
# global hooks, so its own Stop landed here: it flipped the pane's @claude_state,
# and (worse) read the PANE's @ctx_pct, got the auto-handoff block decision meant
# for the TUI, ran /fleet-handoff on ITSELF and /clear-ed the operator's pane —
# 16 cycles in one day, several under the operator's fingers. Claude Code marks
# the entrypoint in the environment its hooks inherit: `cli` for the interactive
# TUI, `sdk-cli` for `-p` (verified on 2.1.269). Only the TUI owns the pane;
# anything else touches nothing. Unset (an older CLI, the selftests' `env -i`) ⇒ TUI.
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) : ;; *) exit 0 ;; esac

handoff_prev=''   # prior @claude_state, captured in the done branch (issue #330)

# @claude_needs — WHY this window is red (issues #640, #704):
#
#   ask   an open AskUserQuestion  → answerable from outside the pane
#                                    (bin/fleet-answer.sh / dash ⌃k)
#   perm  an open permission prompt → a human decision by design; nothing in the
#                                    fleet may press Yes for it (bin/fleet-permission.sh
#                                    reads it out of band, and can only ever press No)
#   blocked  the worker declared a blocker → read the issue and send a new prompt
#   ''    anything else (the classifier's WAITING/ERROR verdict, an unrecognised
#         Notification) — the historic, undifferentiated `needs`.
#
# #605 pushed this back as "you'd have to tail a transcript for every needs row".
# Mostly you don't — `ask` still arrives free on the PreToolUse tool_name — but the
# Notification leg DOES have to read one, and #656 is why. The wording was the
# original discriminator, and it cannot work: measured on Claude Code 2.1.272, an open
# AskUserQuestion fires the SAME Notification a blocked Bash call does —
#
#     {"hook_event_name":"Notification","message":"Claude needs your permission",
#      "notification_type":"permission_prompt", …}
#
# — so the `*permission*` match below overwrote the `ask` that PreToolUse had just
# stamped, and the dash showed `⊘` ("only a human can press this") on a question the
# operator could have answered from the dash with ⌃k. That is #640's whole value
# inverted, and it cost a real worker its turn on 2026-09-14.
#
# So the Notification leg asks the TRANSCRIPT what is pending — bin/fleet-pending-tool.sh,
# the same "tool_use with no tool_result" rule bin/fleet-answer.sh and
# bin/fleet-permission.sh already gate on. One python3 read, on the Notification path
# only (never the per-tool hot path), and it is the judgement the two tools that ACT
# on this stamp already use, so the dash can no longer disagree with them. Any
# failure (no python3, no transcript_path, unreadable file) falls back to the wording,
# i.e. exactly today's behaviour.
#
# FRESHNESS BY CONSTRUCTION: it is written on EVERY non-`leave` state write, so it
# can never outlive the @claude_state it describes. The other two writers of
# @claude_state (bin/classify-sessions.sh, the spinner's stale-working demote)
# clear it for the same reason. Readers consult it only while the state is `needs`.
sub=''

case "${1:-}" in
  needs)
    # The Notification hook fires this path unconditionally, but Claude Code emits
    # a benign idle_prompt Notification ("Claude is waiting for your input") ~60s
    # after ANY session goes idle. Left unfiltered it flips every finished session
    # to needs+bell and re-flips the classifier's verdict — cry-wolf. Discriminate
    # on the payload (mirrors the AskUserQuestion stdin-inspection in 'busy'). 2.1.272
    # carries a structured `notification_type` beside `message` (#656), so the idle
    # leg matches EITHER spelling — the type survives a rewording of the message, and
    # the message covers CLIs older than the field. Neither matching ⇒ needs+bell,
    # the safe direction (an idle session rings, not a real prompt silently missed).
    # A benign idle prompt -> 'leave': DON'T write state, just drop the bell, so
    # whatever the Stop-hook classifier decided (done for finished, needs for a
    # real pending question) stays authoritative. A real permission/elicitation
    # prompt (and anything unrecognised) keeps needs+bell.
    # What the payload does NOT say is WHICH of the two `needs` this is — every
    # dialog arrives as `permission_prompt`, an AskUserQuestion included — so the
    # subtype is settled against the transcript below (#656). A payload we cannot
    # place at all costs the subtype (→ '' ⇒ today's plain `needs`), never the
    # state — the same fail-safe direction as the idle filter.
    sem="needs"
    if [ ! -t 0 ]; then
      _payload=$(cat 2>/dev/null)
      case "$_payload" in
        *'waiting for your input'*|*'"notification_type":"idle_prompt"'*)
          sem="leave"; set -- "leave" ;;   # idle_prompt: leave state as-is, no bell
        *permission*)
          # No `notification_type` alternative here: 2.1.272's value is literally
          # `permission_prompt`, so the substring already covers the structured form
          # (shellcheck SC2222 says so too). The idle leg above needs both spellings
          # because its message and its type share no substring.
          sub="perm" ;;                    # a dialog is open — WHICH one, the transcript says
      esac
      # …and the transcript overrules the wording. `permission_prompt` is what Claude
      # Code sends for an AskUserQuestion too (#656), so `perm` here is only ever a
      # first guess: if the newest tool_use still waiting for a result IS an
      # AskUserQuestion, this window is answerable from the dash and must say `ask`.
      # Nothing else can flip the guess — a pending Bash/Edit/anything keeps `perm`,
      # and an unresolvable transcript keeps it too (fail-safe: the wording's answer).
      if [ "$sub" = perm ]; then
        _tp=$(printf '%s' "$_payload" \
          | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p)
        if [ -n "$_tp" ]; then
          _bin0=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
          if [ -n "$_bin0" ] && [ -f "$_bin0/fleet-pending-tool.sh" ]; then
            case "$(sh "$_bin0/fleet-pending-tool.sh" "$_tp" 2>/dev/null)" in
              AskUserQuestion) sub="ask" ;;
            esac
          fi
        fi
      fi
    fi
    ;;
  blocked)
    # The worker's OWN red (issue #704): `/fleet-claim`'s blocked rail — "post a
    # `⛔ blocked:` comment, then set the window red". Not a hook verb: the worker
    # runs it from its Bash tool, and that is exactly why it needs its own subtype.
    # A plain `needs` here lived for ONE hook edge (measured on an isolated socket):
    # the same Bash call's PostToolUse wrote `working` over it, Stop wrote `done`,
    # and whether the dash ever showed red again was up to the screen classifier.
    # `blocked` is the subtype the sticky rule below keys on. It rings, like every
    # other `needs` the operator has to act on.
    sem="needs"; sub="blocked"; set -- blocked bell
    ;;
  done)
    sem="done"
    _stop_payload=''
    [ -t 0 ] || _stop_payload=$(cat 2>/dev/null)
    # Auto-handoff (issue #330): capture the PRIOR state BEFORE the write below
    # overwrites @claude_state — the nudge must not hijack a pane that stopped in
    # a needs-attention state (an open operator question). Only the Stop hook
    # passes 'done', so this one extra read never touches the per-tool hot path.
    handoff_prev=$(tmux display-message -p -t "$TMUX_PANE" '#{@claude_state}' 2>/dev/null)
    ;;
  busy)
    # PreToolUse heartbeat = working, EXCEPT the AskUserQuestion tool: it opens a
    # blocking multiple-choice popup mid-turn, so without this the window would
    # masquerade as 'working' the whole time it is really waiting on the user. A
    # Notification DOES follow (~60s later, as `permission_prompt` — #656 measured it;
    # the older note here said none fired), but this stamp is what makes the window
    # red IMMEDIATELY, and the `needs` branch above is careful to keep its `ask`.
    # PreToolUse is the only caller that passes 'busy'; its stdin JSON carries the
    # tool_name. PostToolUse (arg 'working') fires when the user answers -> working.
    sem="working"
    if [ ! -t 0 ]; then
      case "$(cat 2>/dev/null)" in
        *'"tool_name":"AskUserQuestion"'*|*'"tool_name": "AskUserQuestion"'*)
          sem="needs"; sub="ask"; set -- needs bell ;;
      esac
    fi
    ;;
  *)     sem="working" ;;   # PostToolUse / prompt submitted
esac

# ── `blocked` is STICKY (issue #704) ─────────────────────────────────────────
# Every write that is the ordinary traffic of ONE turn — PreToolUse → working,
# PostToolUse → working, Stop → done — leaves a `blocked` pane exactly as it is.
# The charter tells a blocked worker to comment, stamp, report to its parent and
# stop; each of those is a tool call with a `working` on either side of it and a
# `done` at the end, so without this rule the red was gone before the worker had
# finished saying why. What DOES clear it is a new prompt (UserPromptSubmit): the
# operator's answer relayed by the issue bridge, a message typed at the pane — the
# one event that means someone engaged. (A message that was NOT the answer, a
# `[child-report]` say, clears it too; the charter tells a still-blocked worker to
# re-stamp before it stops.) The other `needs` writers are NOT held back: a live
# dialog (a Notification's `perm`, an AskUserQuestion's `ask`) outranks a declaration
# made earlier, and both of those re-settle against the transcript.
#
# PostToolUse and UserPromptSubmit arrive with the same argument (`working` — the
# hook table is installed, and an older install must keep clearing), so the prompt
# is told apart on the hook's own stdin (`hook_event_name`), parsed ONLY once the pane
# is known to be blocked. The ordinary per-tool path pays one tmux read, no JSON parse.
# @claude_state_ts is left alone with the state, so the dash's "Nm ago" is how long
# the worker has been blocked. bin/classify-sessions.sh and the spinner's reconcile
# honour the subtype the same way (they skip it; only `dead` clears it).
case "$sem" in
  working|done)
    if [ "$(tmux display-message -p -t "$TMUX_PANE" '#{@claude_state}/#{@claude_needs}' 2>/dev/null)" = needs/blocked ]; then
      _ev=''
      # `busy` (PreToolUse) already drained its stdin above and is never a prompt.
      if [ "$sem" = working ] && [ "${1:-}" != busy ] && [ ! -t 0 ]; then
        # Parse the root field: JSON whitespace and a nested tool result mentioning
        # UserPromptSubmit must not change the meaning. Unreadable input stays red.
        _ev=$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("hook_event_name", ""))' 2>/dev/null)
      fi
      [ "$_ev" = UserPromptSubmit ] || sem="leave"
    fi ;;
esac

# 'leave' (benign idle_prompt, or a `blocked` pane mid-turn) intentionally writes
# nothing — it preserves the existing @claude_state and its timestamp so the
# classifier (or the worker's own declaration) stays authoritative.
if [ "$sem" != "leave" ]; then
  # A tool, new prompt, or needs-attention event invalidates the previous Stop.
  # In particular, a typing hold must not let a later stale `done` stamp reuse it.
  if [ "$sem" != "done" ]; then
    tmux set-window-option -u -t "$TMUX_PANE" @agent_transfer_ready 2>/dev/null
    tmux set-window-option -u -t "$TMUX_PANE" @sleep_evidence 2>/dev/null
  fi
  tmux set-window-option -t "$TMUX_PANE" @claude_state "$sem" 2>/dev/null
  # the `needs` subtype, ALWAYS written beside the state it qualifies (issue #640):
  # a working/done write clears it, so no reader can ever pair a fresh state with a
  # stale reason.
  tmux set-window-option -t "$TMUX_PANE" @claude_needs "$sub" 2>/dev/null
  # last-activity stamp (drives the dashboard's "Nm ago" column).
  tmux set-window-option -t "$TMUX_PANE" @claude_state_ts "$(date +%s)" 2>/dev/null
  # Wake the spinner (issue #887). It re-reads a QUIET fleet's windows only ~1/s;
  # this marker — `<socket path>.dirty`, beside tmux's own socket, the one path the
  # daemon and this pane are guaranteed to agree on — gets the change drawn on its
  # next tick instead. A builtin redirection: no fork on the per-tool hot path.
  _sockp=${TMUX%%,*}
  [ -n "$_sockp" ] && : > "$_sockp.dirty" 2>/dev/null
fi

# ── Auto-handoff nudge (issue #330) ──────────────────────────────────────────
# At a CLEAN Stop (done), if this session's context has crossed the operator's
# threshold, emit the Stop-hook block decision that steers the model into
# /fleet-handoff (cycle) — a structured handoff preserves task state far better
# than Claude's near-limit auto-compaction. This ONLY adds the trigger; the whole
# handoff/clear/resume machinery (commands/fleet-handoff.md + fleet-handoff-cycle.sh)
# is reused unchanged. Knobs: FLEET_AUTO_HANDOFF_PCT (0 = OFF; mirrors
# FLEET_RUNAWAY_CPU_PCT), or FLEET_AUTO_HANDOFF_TOKENS to set it in tokens used
# (issue #1317), and FLEET_HANDOFF_DEFER_SECS (the typing hold, issue #571).
# Only 'done' (the Stop hook) reaches here, so the JSON is only ever emitted in the
# Stop-hook context that parses it as a decision.
#
# THE KNOB IS READ FROM THE CONF, NOT THIS PROCESS'S ENVIRONMENT (issue #561). A
# hook inherits the pane's env, and nothing exports fleet.conf into it (the conf is
# assignments-only; the launcher never `set -a`s it) — so the original
# `${FLEET_AUTO_HANDOFF_PCT:-0}` read here was 0 in every real session while the
# operator's global conf said 60, and all 134 logged handoff cycles were the worker
# nudging itself. Resolution goes through bin/fleet-hook-conf.sh — the ONE
# hook-side path (global fleet.conf → this fleet's overlay via fleet_load_conf,
# global-only keys stripped per #237) that fleet-doctor.sh evaluates too. This
# script is `sh`-wired and cannot source the bash-only fleet-lib itself; the helper
# is the bash hop (≈20 ms, once per Stop — never on the per-tool hot path). Any
# failure (helper/lib missing, no server, no conf) yields '' ⇒ 0 ⇒ OFF: fail-open,
# exactly as before.
if [ "$sem" = "done" ]; then
  _bin=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  # The language rule this hook's directive ends with (issue #620). This script is
  # `sh`-wired and cannot source the bash-only fleet-lib.sh, which is exactly why
  # the rules live in their own POSIX file — sourcing it costs no fork, and the
  # ${VAR:+ …} at the call site means a missing file costs the rule, not the
  # directive (and leaves no dangling separator behind).
  # shellcheck source=/dev/null
  [ -n "$_bin" ] && [ -r "$_bin/fleet-lang.sh" ] && . "$_bin/fleet-lang.sh"
  _kv=''
  [ -n "$_bin" ] && [ -f "$_bin/fleet-hook-conf.sh" ] \
    && _kv=$(bash "$_bin/fleet-hook-conf.sh" FLEET_AUTO_HANDOFF_PCT FLEET_HANDOFF_DEFER_SECS FLEET_COMPACT_PREP_PCT FLEET_COMPACT_MAX \
         FLEET_AUTO_HANDOFF_TOKENS FLEET_COMPACT_PREP_TOKENS 2>/dev/null)
  _hp=$(printf '%s\n' "$_kv" | sed -n 1p)
  _ds=$(printf '%s\n' "$_kv" | sed -n 2p)             # typing-deferral window (issue #571)
  _cp=$(printf '%s\n' "$_kv" | sed -n 3p)             # compact-prep threshold (issue #1269)
  _cm=$(printf '%s\n' "$_kv" | sed -n 4p)             # compactions before a handoff (issue #1316)
  case "$_hp" in ''|*[!0-9]*) _hp=0 ;; esac          # unset / non-numeric → off
  # Unset ⇒ the 70 default, but only when the conf path is intact: a missing lib
  # resolves nothing, and that must stay fail-open OFF like the handoff knob.
  case "$_cp" in
    '') if [ -n "$_bin" ] && [ -f "$_bin/fleet-lib.sh" ] && [ -f "$_bin/fleet-hook-conf.sh" ]; then _cp=70; else _cp=0; fi ;;
    *[!0-9]*) _cp=0 ;;
  esac
  case "$_cm" in
    '') if [ -n "$_bin" ] && [ -f "$_bin/fleet-lib.sh" ] && [ -f "$_bin/fleet-hook-conf.sh" ]; then _cm=2; else _cm=0; fi ;;
    *[!0-9]*) _cm=0 ;;
  esac
  # Lines set in TOKENS (issue #1317) win over the % keys: converted here against
  # this pane's window size (@ctx_limit, stamped by the statusline), the same
  # rounded-up / clamped-to-100 arithmetic as fleet_ctx_line in fleet-lib.sh (this
  # `sh` script cannot source it; ctx-token-line-selftest.sh pins the lockstep).
  # 0/unset ⇒ the % key; no readable @ctx_limit ⇒ the % key. One tmux read, and
  # only when a token key is set — the unset path is byte-for-byte today's.
  _ht=$(printf '%s\n' "$_kv" | sed -n 5p)
  _ct=$(printf '%s\n' "$_kv" | sed -n 6p)
  case "$_ht" in ''|*[!0-9]*) _ht=0 ;; esac
  case "$_ct" in ''|*[!0-9]*) _ct=0 ;; esac
  if [ "$_ht" -gt 0 ] || [ "$_ct" -gt 0 ]; then
    _lim=$(tmux display-message -p -t "$TMUX_PANE" '#{@ctx_limit}' 2>/dev/null)
    case "$_lim" in ''|*[!0-9]*) _lim=0 ;; esac
    if [ "$_lim" -gt 0 ]; then
      if [ "$_ht" -gt 0 ]; then _hp=$(( (_ht * 100 + _lim - 1) / _lim )); [ "$_hp" -gt 100 ] && _hp=100; fi
      if [ "$_ct" -gt 0 ]; then _cp=$(( (_ct * 100 + _lim - 1) / _lim )); [ "$_cp" -gt 100 ] && _cp=100; fi
    fi
  fi
  _hp_conf=$_hp                                      # the configured line, before any suppression below
  _sha=0                                             # this Stop continues a prior Stop-hook block
  case "$_stop_payload" in
    *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) _sha=1 ;;
  esac
  _agent=$(tmux display-message -p -t "$TMUX_PANE" '#{@cc_agent}' 2>/dev/null)
  case "$_ds" in ''|*[!0-9]*) _ds=30 ;; esac         # unset / non-numeric → the 30s default
  # Explicit cross-agent handoff: only this Stop may release the detached waiter.
  # A stale `done` stamp or spinner demotion is NOT proof the arming turn ended.
  # Suppress the context-cycle nudge while the bounded request owns this Stop.
  _transfer_until=$(tmux display-message -p -t "$TMUX_PANE" '#{@agent_transfer_pending_until}' 2>/dev/null)
  case "$_transfer_until" in ''|*[!0-9]*) _transfer_until=0 ;; esac
  if [ "$_transfer_until" -gt "$(date +%s)" ]; then
    _transfer_request=$(tmux display-message -p -t "$TMUX_PANE" '#{@agent_transfer_request}' 2>/dev/null)
    if [ -n "$_transfer_request" ]; then
      _hp=0; _cp=0
      [ "$handoff_prev" = needs ] || tmux set-window-option -t "$TMUX_PANE" @agent_transfer_ready "$_transfer_request" 2>/dev/null
    fi
  fi
  # Loop-guard: the Stop-hook stdin carries stop_hook_active=true when the model is
  # ALREADY continuing because of a prior Stop-hook block — never re-block that
  # continuation (Claude Code's built-in anti-loop signal, belt-and-suspenders with
  # the @handoff_armed latch below). Read stdin only when armed and not a tty.
  [ "$_sha" = 1 ] && _hp=0
  # Compaction cap (issue #1316). Every in-place compaction loses a little detail;
  # by the third or fourth a session no longer remembers what it agreed to at the
  # start. refocus-hook.sh counts each fleet compaction that completes on
  # @compact_count (handoff-latch-reset-hook.sh zeroes it in a fresh session), and
  # once it reaches FLEET_COMPACT_MAX (unset ⇒ 2; 0 = no cap) a worker at the
  # compact-prep line is handed off instead: the handoff below fires with the prep
  # % as its line, through the same latch and typing hold, and the compaction
  # section skips. At/over the handoff % the plain handoff keeps its own line. Same
  # scope as compaction — a Claude worker (@issue) or scratch (@raw=1, issue #1318);
  # codex is untouched.
  _cmaxed=''
  if [ "$_cm" -gt 0 ] && [ "$_cp" -gt 0 ] && [ "$_sha" = 0 ] && [ "$_agent" != codex ] \
     && [ "$handoff_prev" != needs ] && { [ "$_hp" -eq 0 ] || [ "$_cp" -lt "$_hp" ]; }; then
    _ccv=$(tmux display-message -p -t "$TMUX_PANE" '#{@compact_count}|#{@issue}|#{@raw}|#{@ctx_pct}' 2>/dev/null)
    _ccn=${_ccv%%|*}; _ccv=${_ccv#*|}
    case "$_ccn" in ''|*[!0-9]*) _ccn=0 ;; esac
    _cci=${_ccv%%|*}; _ccv=${_ccv#*|}
    [ "${_ccv%%|*}" = 1 ] && _cci=${_cci:-raw}
    _ccx=${_ccv#*|}
    case "$_ccx" in ''|*[!0-9]*) _ccx=-1 ;; esac
    if [ "$_ccn" -ge "$_cm" ] && [ -n "$_cci" ] && [ "$_ccx" -ge "$_cp" ] \
       && { [ "$_hp" -eq 0 ] || [ "$_ccx" -lt "$_hp" ]; }; then
      _cmaxed=$_ccn; _hp=$_cp
    fi
  fi
  if [ "$_hp" -gt 0 ]; then
    # Debounce latch: arming the handoff does NOT drop the context (only the
    # post-turn /clear does), so the very next Stop would re-nudge → loop. Set
    # @handoff_armed on the first nudge and skip while set; the SessionStart hook
    # (bin/handoff-latch-reset-hook.sh) clears it in the fresh, cleared session.
    _armed=$(tmux display-message -p -t "$TMUX_PANE" '#{@handoff_armed}' 2>/dev/null)
    # Scope: only a worker (@issue) or scratch (@raw) pane HAS /fleet-handoff.
    # Panels (dash/plan/backlog) and the operator hub carry neither → never nudged.
    _issue=$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}' 2>/dev/null)
    _raw=$(tmux display-message -p -t "$TMUX_PANE" '#{@raw}' 2>/dev/null)
    # Measure: the statusline (conf/statusline.sh) stamps the rounded context %
    # onto @ctx_pct each render — the Stop-hook stdin doesn't carry it, but the
    # statusline does. Unstamped / non-numeric ⇒ -1 ⇒ never crosses a positive PCT.
    _ctx=$(tmux display-message -p -t "$TMUX_PANE" '#{@ctx_pct}' 2>/dev/null)
    if [ "$_agent" = codex ]; then
      # Stop hooks may run concurrently: read current telemetry directly rather
      # than depending on the identity hook having refreshed @ctx_pct already.
      _ctx=$(python3 "$_bin/fleet-codex-session.py" context --pane "$TMUX_PANE" --json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["pct"])' 2>/dev/null)
    fi
    case "$_ctx" in ''|*[!0-9]*) _ctx=-1 ;; esac
    if [ "$_armed" != "1" ] && [ "$handoff_prev" != "needs" ] \
       && { [ -n "$_issue" ] || [ "$_raw" = "1" ]; } \
       && [ "$_ctx" -ge "$_hp" ]; then
      # Operator-typing deferral (issue #571). A handoff cycle Esc+`/clear`s this
      # pane a minute from now; typed into an input line holding a half-written
      # draft, that keeps the draft (a single Esc does not clear it) and submits
      # it with "/clear" glued on, and a queued message dies with the old session.
      # Claude Code hands a hook no draft/queue signal, so the proxy is tmux: a
      # client whose CURRENT window is this one with a keypress (#{client_activity})
      # within FLEET_HANDOFF_DEFER_SECS ⇒ skip THIS Stop — no nudge, no latch (the
      # next Stop re-judges) — and stamp @handoff_deferred_ts so the hold is visible.
      # Ceiling: at threshold+10 the nudge fires anyway, or a long conversation
      # would defer itself straight into autocompact.
      _hold=''
      if [ "$_ds" -gt 0 ] && [ "$_ctx" -lt $(( _hp + 10 )) ]; then
        _wid=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
        _now=$(date +%s 2>/dev/null || echo 0)
        [ -n "$_wid" ] && _hold=$(tmux list-clients -F '#{client_activity} #{window_id}' 2>/dev/null \
          | awk -v w="$_wid" -v now="$_now" -v ds="$_ds" \
              '$2 == w && $1 ~ /^[0-9]+$/ && (now - $1) <= ds { print 1; exit }')
      fi
      if [ "$_hold" = "1" ]; then
        tmux set-window-option -t "$TMUX_PANE" @handoff_deferred_ts "$_now" 2>/dev/null
      else
        # Latch FIRST (idempotent) so the next Stop skips, THEN emit the directive.
        tmux set-window-option -t "$TMUX_PANE" @handoff_armed 1 2>/dev/null
        # The context-ladder ledger (issue #1320): one row per nudge. Silent — this
        # hook's stdout is the JSON below.
        _lreason=pct; [ -n "$_cmaxed" ] && _lreason=cap; [ "$_agent" = codex ] && _lreason=codex
        [ -f "$_bin/fleet-ladder-log.sh" ] && sh "$_bin/fleet-ladder-log.sh" handoff-nudge \
          --ctx "$_ctx" --reason "$_lreason >= $_hp%" </dev/null >/dev/null 2>&1
        # The trailing %s is the language rule: this directive is injected as the
        # LAST instruction of a turn, so without it a session held in Chinese
        # writes its handoff doc — and every turn after the pickup — in English.
        # It carries no quotes or backslashes, so it is safe inside this JSON.
        if [ "$_agent" = codex ]; then
          python3 - "$_bin/fleet-transfer.sh" "$TMUX_PANE" "$_ctx" "$_hp" "${FLEET_LANG_RULE_RESUME:-}" <<'PYCODEX'
import json, shlex, sys
script, pane, pct, threshold, language = sys.argv[1:]
command = shlex.join(['bash', script, '--window', pane, '--to', 'codex', '--handoff', 'NOTES_PATH', '--after-turn'])
reason = (f'Context is at {pct}% (>= {threshold}% auto-handoff threshold). Write durable handoff notes '
          'to a private file outside the worktree: latest user goal, decisions, changes, tests, running jobs '
          'and the next action. Replace NOTES_PATH in this command and run it as the final tool call: '
          + command + '. Check that it armed successfully, then end this turn. Fleet waits for this Stop, '
          'preserves the exact Codex transcript and account home, and starts a fresh context in this pane. '
          'Do not invoke Claude slash commands or exit the process yourself. ' + language)
print(json.dumps({'decision': 'block', 'reason': reason}, separators=(',', ':')))
PYCODEX
        elif [ -n "$_cmaxed" ]; then
        printf '{"decision":"block","reason":"Context is at %s%% (>= %s%% compact-prep threshold) and this session has already been compacted in place %s times (FLEET_COMPACT_MAX=%s) — a further compaction would lose more of what was agreed. Run /fleet-handoff now (cycle mode, no arguments): store a durable handoff, then this pane auto-clears and resumes clean. Do this instead of continuing.%s"}\n' "$_ctx" "$_hp" "$_cmaxed" "$_cm" "${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"
        else
        printf '{"decision":"block","reason":"Context is at %s%% (>= %s%% auto-handoff threshold). Run /fleet-handoff now (cycle mode, no arguments): store a durable handoff, then this pane auto-clears and resumes clean. Do this instead of continuing — a structured handoff preserves task state better than near-limit auto-compaction.%s"}\n' "$_ctx" "$_hp" "${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"
        fi
      fi
    fi
  fi

  # ── Compact in place before handing off (issue #1269, EPIC #1262 R1) ────────
  # A handoff makes the fresh session re-read the code and re-learn the task —
  # often dearer than the work left. So in the band [FLEET_COMPACT_PREP_PCT,
  # handoff %) a WORKER compacts in place first, in three steps on @compact_stage:
  #   ''|restored → prep   block this Stop: write a recovery map, end the turn
  #   prep → compacting    next clean Stop: bin/fleet-compact-send.sh (detached)
  #                        types `/compact <keep the map>` once the pane is idle
  #   compacting → restored  SessionStart(compact): bin/refocus-hook.sh re-states
  #                        the charter + asks for a check against the map
  # Still at/over the handoff % ⇒ none of this; the auto-handoff above owns it.
  # Re-armed (@compact_rearm=1) only once a Stop sees the context back below the
  # prep line, ≥ 600 s between compactions, 60 s dedup on each step, and the
  # operator-typing hold (#571) gates the keystrokes. Claude workers AND scratch
  # (@raw=1, issue #1318 — the long-lived window that drives a whole EPIC, where a
  # handoff's re-grounding costs most); a codex pane, hub, panels, a needs stop and
  # a pending transfer are untouched.
  # Unset knob ⇒ 70; 0 = off. Past the compaction cap (#1316) the handoff owns it.
  if [ "$_cp" -gt 0 ] && [ -z "$_cmaxed" ] && [ "$_agent" != codex ] && [ "$handoff_prev" != needs ]; then
    _cissue=$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}|#{@raw}' 2>/dev/null)
    _craw=${_cissue#*|}; _cissue=$(printf '%s' "${_cissue%%|*}" | tr -cd '0-9')
    [ -z "$_cissue" ] && [ "$_craw" = 1 ] || _craw=''
    if [ -n "$_cissue" ] || [ -n "$_craw" ]; then
      _cctx=$(tmux display-message -p -t "$TMUX_PANE" '#{@ctx_pct}' 2>/dev/null)
      case "$_cctx" in ''|*[!0-9]*) _cctx=-1 ;; esac
      _cst=$(tmux display-message -p -t "$TMUX_PANE" '#{@compact_stage}|#{@compact_rearm}|#{@compact_ts}|#{@compact_prep_ts}|#{@compact_send_ts}' 2>/dev/null)
      _cstage=$(printf '%s' "$_cst" | cut -d'|' -f1)
      _crearm=$(printf '%s' "$_cst" | cut -d'|' -f2)
      _cts=$(printf '%s' "$_cst" | cut -d'|' -f3)
      _cpts=$(printf '%s' "$_cst" | cut -d'|' -f4)
      _csts=$(printf '%s' "$_cst" | cut -d'|' -f5)
      case "$_cts" in ''|*[!0-9]*) _cts=0 ;; esac
      case "$_cpts" in ''|*[!0-9]*) _cpts=0 ;; esac
      case "$_csts" in ''|*[!0-9]*) _csts=0 ;; esac
      _cnow=$(date +%s 2>/dev/null || echo 0)
      if [ "$_cctx" -lt "$_cp" ]; then
        # Back below the line (a compaction worked, a /clear, an unstamped fresh
        # session): re-arm, and drop a step that can no longer complete.
        [ "$_crearm" = 0 ] && tmux set-window-option -t "$TMUX_PANE" @compact_rearm 1 2>/dev/null
        case "$_cstage" in prep|compacting) tmux set-window-option -u -t "$TMUX_PANE" @compact_stage 2>/dev/null ;; esac
      elif [ "$_hp_conf" -eq 0 ] || [ "$_cctx" -lt "$_hp_conf" ]; then
        # Where the map goes: fleet_recovery_map_path (fleet-lib.sh, issue #1318) —
        # the worktree's git dir, else (a scratch with none) the fleet's conf dir.
        # Only this in-band path pays the bash hop.
        _cmap=$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1 && fleet_recovery_map_path "$2"' \
          recovery-map "$_bin" "$TMUX_PANE" 2>/dev/null)
        case "$_cmap" in *'"'*|*'\'*) _cmap='' ;; esac   # it is printed into JSON below
        case "$_cstage" in
          prep)
            # The map turn has ended: compact once the pane is idle. 60 s dedup —
            # a sender that gave up (operator typing) is re-tried by a later Stop.
            if [ $(( _cnow - _csts )) -ge 60 ]; then
              tmux set-window-option -t "$TMUX_PANE" @compact_send_ts "$_cnow" 2>/dev/null
              FLEET_HANDOFF_DEFER_SECS="$_ds" sh "$_bin/fleet-compact-send.sh" "$TMUX_PANE" "$_cmap" \
                </dev/null >/dev/null 2>&1 &
            fi ;;
          compacting) : ;;   # /compact typed; SessionStart(compact) completes it
          *)
            if [ "$_crearm" != 0 ] && [ "$_sha" = 0 ] \
               && [ $(( _cnow - _cts )) -ge 600 ] && [ $(( _cnow - _cpts )) -ge 60 ]; then
              tmux set-window-option -t "$TMUX_PANE" @compact_stage prep 2>/dev/null
              tmux set-window-option -t "$TMUX_PANE" @compact_prep_ts "$_cnow" 2>/dev/null
              tmux set-window-option -t "$TMUX_PANE" @compact_rearm 0 2>/dev/null
              [ -f "$_bin/fleet-ladder-log.sh" ] && sh "$_bin/fleet-ladder-log.sh" prep \
                --ctx "$_cctx" --reason ">= $_cp%" </dev/null >/dev/null 2>&1
              _cwhere="to $_cmap (overwrite it)"
              [ -n "$_cmap" ] || _cwhere="as your reply"
              [ -n "$_cmap" ] && mkdir -p "$(dirname "$_cmap")" 2>/dev/null
              _cwhat="issue #$_cissue, branch"
              # A scratch has no issue: the map carries what it is driving instead.
              [ -n "$_cissue" ] || _cwhat="scratch session — the goal you are driving (EPIC / issues / PRs it covers), cwd + branch if any"
              printf '{"decision":"block","reason":"Context is at %s%% (>= %s%% compact-prep threshold). The fleet will compact this session IN PLACE instead of handing it off. First write a RECOVERY MAP %s: %s, PR (number + state, or none), what is done, what is in progress, the exact next step(s), and any background job still running — under 40 lines. Then end this turn; do not start new work. Once the pane is idle the fleet runs /compact keeping that map, and afterwards asks you to check it against git and the PR.%s"}\n' \
                "$_cctx" "$_cp" "$_cwhere" "$_cwhat" "${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"
            fi ;;
        esac
      fi
    fi
  fi
fi

[ "${2:-}" = "bell" ] && printf '\a' > /dev/tty 2>/dev/null

# A child that stopped before ship must still wake its parent once (#565).
# Keep this off the per-tool path and bound the complete report process tree;
# stdout belongs to Stop's JSON response, so reports never print into it.
if [ "$sem" = "done" ] && [ "$handoff_prev" != "looping" ]; then
  _origin=$(tmux display-message -p -t "$TMUX_PANE" '#{@origin}' 2>/dev/null)
  case "$_origin" in issue-*|scratch-*)
    _bin=$(cd "$(dirname "$0")" && pwd)
    bash -c '. "$1/fleet-lib.sh"; fleet_timebox 10 bash "$1/fleet-report-parent.sh" --state stopped --only-once --win "$2"' \
      report-stop "$_bin" "$TMUX_PANE" >/dev/null 2>&1 || : ;;
  esac
fi

# The pane's OWN session id (issue #1296) — what crash-restore resumes, instead of
# guessing "newest transcript in the worktree" (which a helper `claude -p` can be).
# SessionStart stamps it too (handoff-latch-reset-hook.sh); this Stop leg reaches
# CLIs started before that hook existed. Only a well-formed id is written.
if [ "$sem" = 'done' ] && [ -n "${_stop_payload:-}" ]; then
  _sid=$(printf '%s' "$_stop_payload" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("session_id"); print(v if isinstance(v,str) else "")' 2>/dev/null)
  case "$_sid" in *[!0-9a-fA-F-]*) _sid="" ;; esac
  case "$_sid" in
    ????????-????-????-????-????????????)
      tmux set-window-option -t "$TMUX_PANE" @cc_session_id "$_sid" 2>/dev/null ;;
  esac
fi

# A separate native proof, never populated by screen classifiers or stale-working
# reconciliation. Reusing this installed hook also reaches already-running CLIs.
if [ "$sem" = 'done' ] && [ -n "${_stop_payload:-}" ]; then
  _bin=$(cd "$(dirname "$0")" && pwd)
  [ ! -f "$_bin/fleet-sleep.py" ] || printf '%s' "$_stop_payload" \
    | python3 "$_bin/fleet-sleep.py" hook >/dev/null 2>&1 || :
fi
exit 0
