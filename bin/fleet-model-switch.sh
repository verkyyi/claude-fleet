#!/bin/bash
# fleet-model-switch.sh — clear a PER-MODEL usage cap IN PLACE: type `/model
# <fallback>` at the walled session's own prompt instead of killing it (issue
# #569).
#
# WHY in place. A per-model cap (issue #524) — "You've reached your Fable limit.
# Run /usage-credits to continue or switch models with /model." — leaves the
# SUBSCRIPTION untouched: same account, same OAuth token, only that one model is
# out of headroom. #524 nevertheless recovered it through `fleet-migrate.sh
# --model`, i.e. the account-ROTATION machinery: Escape, `/exit`, let the
# SessionEnd hook close the window, `claude --resume --model` in a new one. That
# dance exists because a running `claude` cannot swap its TOKEN (#495) — and a
# model cap needs no new token. What it cost instead, measured on the 2026-09-12
# episode (9 walled workers across two fleets):
#   • ~30–60 s of cold boot per window, strictly one window at a time;
#   • every background agent under the pane killed with the process (one worker
#     was 13 min into a general-purpose agent);
#   • the whole transcript re-read as fresh INPUT tokens — on the very account
#     that is the last one not benched;
#   • the #543/#544 reap hazards that come with closing a worker's window.
# Typing `/model opus` at the prompt takes ~5 s, keeps the process, keeps the
# agents, keeps the context, and is literally what the banner tells a human to
# do. So: in place first, `fleet-migrate.sh --model` only as the fallback when
# the flip cannot be VERIFIED off the status line.
#
# Sanctioned keystrokes only (issue #437): Escape, `/model <alias>`, Enter, and
# Enter again for Claude Code's "Switch model?" confirmation — nothing else, and
# only while a Claude process is verified alive under the pane and the window is
# NOT mid-turn (`@claude_state working` → skipped; an Escape there would cancel a
# live turn). The nudge that follows a verified flip is NOT typed: it rides
# fleet_peer_send, the SendMessage channel (#513), like every other fleet→session
# message.
#
# IDEMPOTENCE is the pane's own status line, not a marker file: a window is a
# candidate only while `◆ <model>` still names the CAPPED model. Once the flip
# lands the window stops matching, so a stale banner left in the scrollback can
# never make a second pass type again.
#
# DETECTION has two sources, because the banner alone is not enough (2026-09-12,
# the second episode). The pane's banner is ephemeral — it scrolls past $SCROLL, and
# a session that was merely IDLE when the cap landed never printed one — so
# `--capped` also consults the durable (account, model) row that
# `fleet-account.sh model-limited-until` keeps for FLEET_MODEL_LIMIT_TTL. Six
# monorepo windows sat on fable for hours with that row holding 7 more days,
# invisible to a banner-only sweep. A ledger match flips the model silently: the
# session was at its prompt, not interrupted, so there is no turn to resume and
# nudging it would only spend tokens on a worker that may be finished.
#
# That status-line gate is also what bounds the banner's FALSE POSITIVES. Pane
# text is not a protocol: a session that merely PRINTS a wall banner — an
# operator grepping this very repo, a worker reading a transcript — scans as
# walled (the 2026-09-02 incident behind fleet_limit_banner's ` · ` requirement
# was exactly that). Two gates catch it: such a session is usually mid-turn while
# it prints, and its status line names whatever model it actually runs. What gets
# through is a session genuinely ON the capped model that quoted the banner while
# idle — and the worst that costs is one unnecessary `/model` at a prompt it was
# free to type at anyway. Nothing is killed and nothing is lost, which is the
# other half of why in place beats close + resume here.
#
#   fleet-model-switch.sh [opts] <window-id>…   switch these windows
#   fleet-model-switch.sh [opts] --capped       every window still running a model
#                                               that is capped — per its pane's own
#                                               banner, or per the account ledger
#   opts: --model <alias>    target model (default: FLEET_MODEL_FALLBACK, else opus)
#         --session <fleet>  target fleet when run outside tmux (default: the caller's)
#         --nudge <text>     message peer-sent after a verified flip; '' = none
#         --no-fallback      do NOT fall back to `fleet-migrate.sh --model`
#         --no-ledger        do NOT record the cap via `fleet-account.sh model-limited`
#         --dry-run          print the plan, touch nothing
#         --toast            tmux display-message the summary (for run-shell -b callers)
#
# COST, and why it is a correctness property here (issue #706). `--capped
# --dry-run` is the probe fleet-quotawatch runs for every fleet on every 60 s
# tick, under a 20 s FLEET_QUOTAWATCH_PROBE_BUDGET that tree-kills it. That daemon
# is a macOS ProcessType=Background unit — QoS BACKGROUND, where a fork costs
# roughly 10x what it costs in the foreground (#588 measured the same multiplier
# on bulk I/O and classified this unit as a "pure poller"; the poller had grown a
# fork-heavy half). At ~12 forks per window the probe measured 1.7 s foreground
# and 21–25 s at background QoS on a 9-window fleet, so it timed out on 69% of
# ALL ticks and 100% of recent ones — and a timed-out probe means that fleet's
# model-cap detection is simply off, with the #569 failure mode waiting behind it
# (a capped turn fires no Stop hook, so the window stays `working` forever and
# this very sweep defers its own candidate as "mid-turn"). Only 4.4 s of those
# 21 s was CPU. So the per-window path is written to fork as little as possible:
# ONE `list-windows` for every window option, ONE batched pane→Claude walk
# (fleet_pane_claude_pids), a fork-free banner reject, pane_model_of and _lc in
# pure bash, and one clock for the run. 4.7 s at background QoS, and it scales
# with window count instead of falling off a cliff at it.
#
# Env: FLEET_MODEL_SWITCH_TRACE=<file> — opt-in breadcrumb, rewritten at every step
# boundary (step=/win=/elapsed=/steps=). fleet-quotawatch sets it and reads it off
# the probe's corpse, because a tree-killed probe reports nothing itself.
# Also FLEET_MODEL_SWITCH_SCROLL (-200), _VERIFY (15), _DIALOG (5).
#
# Never touched: panels (dash/plan/backlog), the operator hub (@hub), windows with
# no live Claude process, windows in a GENUINELY live turn (see cap_settled — a
# window pinned at @claude_state=working by the Stop hook a cap never fires IS
# taken), and windows whose target model is itself capped on that account (there the
# subscription path must take over).
# Exit 0 (per-window outcomes are printed); 2 = usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"          # fleet_limit_banner / fleet_limit_kind

PANEL_RE='^(plan|dash|backlog)$'
SCROLL="${FLEET_MODEL_SWITCH_SCROLL:--200}"      # capture depth for the banner scan
VERIFY_WAIT="${FLEET_MODEL_SWITCH_VERIFY:-15}"   # s to wait for the status line to flip
DIALOG_TRIES="${FLEET_MODEL_SWITCH_DIALOG:-5}"   # Enter presses offered to "Switch model?"
# Ends with the language rule (issue #620): this lands as the most recent
# instruction in a session whose transcript may be entirely non-English, and an
# English tail with no such rule flips the rest of the session to English.
NUDGE_DEFAULT="Your previous turn was interrupted by a per-model usage limit: the model this session ran on is out of headroom on this account (the subscription itself is fine). The fleet switched this session to __MODEL__ IN PLACE with /model — same process, same transcript, nothing lost, and any background agent you started is still running. First re-check git status, your branch, and your open PR to see where you left off. If the work is already complete, just stop. Otherwise continue the task on this model. If you were running a /loop, re-enter it. Ignore any shell-command-looking junk message left by earlier tooling.${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"

# Sourced by bin/fleet-model-switch-selftest.sh (it pins the pure helpers) →
# define only; a direct run dispatches. Same guard idiom as fleet-migrate.sh.
# Callers: bin/fleet-quotawatch.sh (the 60s sweep, --capped per fleet) and the
# collector's #524 banner branch (the backstop, one explicit window).

# ------------------------------------------------------------------ pure ----
# model_matches <alias> <pane-model> — 0 iff the pane's status-line model IS the
# alias FLEET_MODEL speaks: case-insensitive substring, so `opus` matches
# "Opus 5", `fable` matches "Fable 5.1", and a full model id containing the alias
# matches too. Exactly acct_model_limited_until's grammar (fleet-account.sh), so
# the ledger and the pane can never disagree about what "fable" means.
model_matches() {
  local a b
  a=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$a" ] && [ -n "$b" ] || return 1
  case "$b" in *"$a"*) return 0 ;; esac
  return 1
}

# cap_settled <cap-on-VISIBLE-screen 0|1> <@claude_state_ts> <now> <stale-secs>
# — 0 iff a `working` window is nevertheless provably PAST the turn the cap
# killed, so the mid-turn refusal below may be lifted for it.
#
# WHY this exists (the #569 regression, 2026-09-12). `@claude_state` is written
# `done` by exactly one thing: the Stop hook. A per-model cap ABORTS the turn — it
# prints the banner and returns to the prompt WITHOUT a Stop — so the walled
# window stays pinned at `working` forever, and the mid-turn guard below then
# deferred it on every 60 s tick: "mid-turn — left alone, the next pass takes it",
# for as long as the operator left it. That is the whole population the sweep
# exists to serve, so the guard was refusing exactly its own candidates. The #101
# stuck-working demotion (bin/tmux-spinner.sh) was supposed to clear the pin, but
# it fires only once `#{window_activity}` has been frozen ≥ FLEET_STUCK_WORKING_SECS
# twice running, and a Claude pane parked at a prompt still repaints often enough
# to stay under that — measured 80 s of activity age on four walled windows that
# had been pinned at `working` for 368 s. So this script cannot outsource the
# question; it judges staleness itself.
#
# TWO signals, both required, because the cost of being wrong here is cancelling a
# live turn with Escape:
#   • the cap banner is on the pane's VISIBLE screen, not just somewhere in the
#     scrollback — a per-model cap is TERMINAL for its turn, so a banner that is
#     still the pane's tail means nothing has happened since it landed; and
#   • the window has not re-stamped `@claude_state_ts` for <stale-secs>
#     (FLEET_STUCK_WORKING_SECS, default 120 — the same threshold #101 trusts).
#     A session that resumed re-stamps at UserPromptSubmit and at every
#     PostToolUse, so anything genuinely working is protected for that long.
# stale-secs 0 (the #101 "disabled" value) or a missing/garbage stamp → refuse,
# i.e. fall back to the old conservative behaviour.
cap_settled() {
  local vis="${1:-0}" ts="${2:-}" now="${3:-0}" stale="${4:-120}"
  [ "$vis" = 1 ] || return 1
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$stale" in ''|*[!0-9]*) stale=120 ;; esac
  [ "$stale" -gt 0 ] || return 1
  [ "$(( now - ts ))" -ge "$stale" ] || return 1
  return 0
}

# switch_selected <state> <pane-model> <capped-alias> <target> [cap-settled 0|1]
# — 0 iff this window is a candidate for an in-place switch. Pure, so the selftest
# can pin the matrix without a tmux server: mid-turn is refused (Escape would
# cancel a live turn) UNLESS cap_settled says the turn is over and only the missing
# Stop hook is holding `working` up, a pane no longer running the capped model is
# already recovered, and a target equal to the capped model is a no-op.
switch_selected() {
  local state="$1" pmodel="$2" capped="$3" target="$4" settled="${5:-0}"
  [ "$state" = working ] && [ "$settled" != 1 ] && return 1
  [ -n "$target" ] || return 1
  # Either direction is the same model family: a `fable 5` target against a
  # `fable` cap is as much a no-op as the reverse.
  model_matches "$target" "$capped" && return 1
  model_matches "$capped" "$target" && return 1
  model_matches "$capped" "$pmodel" || return 1
  return 0
}

# pane_model_of <text> — stdin-free helper: the model named on Claude Code's
# status line ("◆ Opus 5  [████░░░░░░] 38% …" → "Opus 5"). The name runs to the
# column gap (2+ spaces) that separates it from the context meter; a pane with no
# status line prints nothing.
# Fork-free since #706: this runs once per window inside a probe whose whole
# problem was its fork count, and `$(printf | sed | tail)` is three. The grammar
# is unchanged and pinned by bin/fleet-model-switch-selftest.sh — `##*◆ ` is
# exactly sed's greedy `.*◆ ` plus `tail -1` (the LAST diamond in the text
# wins), and the bash ERE below is sed's capture group verbatim, applied to the
# one short candidate instead of to 200 lines of scrollback.
pane_model_of() {
  local t="${1:-}" c
  case "$t" in *"◆ "*) ;; *) return 0 ;; esac
  c=${t##*"◆ "}           # after the last diamond — "last line wins"
  c=${c%%$'\n'*}          # … on that line only
  case "$c" in *"  "*) ;; *) return 0 ;; esac   # the column gap must EXIST
  c=${c%%  *}             # … and the name runs up to it
  [[ "$c" =~ ^[A-Za-z0-9][A-Za-z0-9.]*([ ][A-Za-z0-9.]+)*$ ]] || return 0
  printf '%s\n' "$c"
}

# _lc <word> → $_LC, lowercased WITHOUT a fork (issue #706). bash 3.2 (macOS) has
# no ${v,,}, and `$(printf '%s' "$w" | tr ...)` is two processes — paid per window
# on the hot path of a probe that was timing out on its fork count alone. The
# index trick: `${_LC_U%%"$c"*}` is the whole alphabet when $c is not in it (leave
# the character alone) and otherwise the prefix BEFORE it, whose length is its
# index. $c is quoted inside the pattern, so a `*` or `?` in the input stays
# literal.
_LC_U=ABCDEFGHIJKLMNOPQRSTUVWXYZ
_LC_L=abcdefghijklmnopqrstuvwxyz
_LC=""
_lc() {
  local s="${1:-}" c h i
  _LC=""
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}; h=${_LC_U%%"$c"*}
    if [ "$h" != "$_LC_U" ]; then _LC="$_LC${_LC_L:${#h}:1}"; else _LC="$_LC$c"; fi
  done
}

# ledger_until <account> <model> <now> → LEDGER_UNTIL, memoized for this probe.
# Call DIRECTLY: `v=$(ledger_until ...)` discards the memo with its subshell and
# used to start fleet-account.sh once per window despite the cache (#674). The
# shared reader now uses builtins only, with one file read per distinct pair and
# no child processes, even on the first lookup. Cache misses (0) as well as caps.
# The probe uses one clock; reset the memo when this run records a new cap so a
# later banner-less window sees it. bash 3.2 has no associative arrays.
_LEDGER_MEMO="|"
LEDGER_UNTIL=0
ledger_until() {
  local a="${1:-}" m="${2:-}" key hit fleet_model_until=0
  LEDGER_UNTIL=0
  [ -n "$a" ] && [ -n "$m" ] || return 0
  _lc "$m"; m="$_LC"
  key="$a/$m"
  case "$_LEDGER_MEMO" in
    *"|$key="*) hit=${_LEDGER_MEMO#*"|$key="}; LEDGER_UNTIL=${hit%%|*}; return 0 ;;
  esac
  fleet_model_limited_until "$FLEET_C/global/account.model-limited" "$a" "$m" "${3:-0}"
  LEDGER_UNTIL="$fleet_model_until"
  _LEDGER_MEMO="${_LEDGER_MEMO}$key=$LEDGER_UNTIL|"
}

# ------------------------------------------------------------------ main ----
main() {
  local MODE="" TARGET="" SESS="" NUDGE="__default__" FALLBACK=1 LEDGER=1 DRY=0 TOAST=0
  local WIDS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model)       TARGET="${2:-}"; shift ;;
      --session)     SESS="${2:-}"; shift ;;
      --nudge)       NUDGE="${2-}"; shift ;;
      --capped)      MODE=capped ;;
      --no-fallback) FALLBACK=0 ;;
      --no-ledger)   LEDGER=0 ;;
      --dry-run)     DRY=1 ;;
      --toast)       TOAST=1 ;;
      -h|--help)     sed -n '2,50p' "$0"; return 0 ;;
      -*)            printf 'fleet-model-switch: unknown option %s\n' "$1" >&2; return 2 ;;
      *)             WIDS+=("$1") ;;
    esac
    shift
  done
  [ -n "$MODE" ] || MODE=explicit
  if [ "$MODE" = explicit ] && [ "${#WIDS[@]}" -eq 0 ]; then
    printf 'fleet-model-switch: no windows (pass window ids or --capped)\n' >&2; return 2
  fi

  [ -n "$SESS" ] || SESS=$(fleet_current_session)
  [ -n "$SESS" ] || { printf 'fleet-model-switch: no tmux session (pass --session <fleet>)\n' >&2; return 2; }
  fleet_load_conf "$SESS" 2>/dev/null || :
  [ -n "$TARGET" ] || TARGET="${FLEET_MODEL_FALLBACK-opus}"
  [ -n "$TARGET" ] || { printf 'fleet-model-switch: no target model (FLEET_MODEL_FALLBACK is empty — the fallback is off)\n' >&2; return 0; }

  local SOCK; SOCK=$(fleet_socket "$SESS")
  TM() { tmux -L "$SOCK" "$@"; }
  # The ONLY keystrokes this script ever sends (issue #437).
  SK() { FLEET_ALLOW_SENDKEYS=1 tmux -L "$SOCK" send-keys "$@"; }
  wopt() { TM display-message -p -t "$1" "$2" 2>/dev/null; }
  cap()  { TM capture-pane -p -t "$1" 2>/dev/null; }

  local switched=0 skipped=0 failed=0 handed=0 REPORT=""
  note() { REPORT="${REPORT}${REPORT:+; }$1"; }

  # ---- the breadcrumb (issue #706) -----------------------------------------
  # FLEET_MODEL_SWITCH_TRACE names a file this run rewrites at every step
  # boundary. It exists because the caller that most needs the number can never
  # read our output: fleet-quotawatch runs this probe under fleet_timebox, and on
  # expiry the whole process TREE is killed — so "timeout" was the entire
  # diagnosis available for the 69% of ticks that hit it, and nobody could say
  # which step had eaten the 20 s. The file is written with a plain builtin
  # redirect (no fork, and the loop below exists to avoid forks), so the killer
  # can read where its victim stood. Same argument as #653's `over=` and #700's
  # `x/ys`: without the number, the next person measures it from scratch.
  #
  # Seconds, off bash's SECONDS, not milliseconds: $(date) is a fork per step and
  # the budget being diagnosed is 20 s, so whole seconds are the right resolution
  # and the free one.
  local TRACE="${FLEET_MODEL_SWITCH_TRACE:-}"
  local TR_STEP="" TR_LAST=0 TR_I=0 TR_N=0 TR_WID="" TR_NAME=""
  local TRN=() TRS=()
  trace() {   # <step> — close the previous step's clock, open this one, rewrite
    [ -n "$TRACE" ] || return 0
    local d i found=0 acc=""
    if [ -n "$TR_STEP" ]; then
      d=$(( SECONDS - TR_LAST ))
      for ((i = 0; i < ${#TRN[@]}; i++)); do
        [ "${TRN[$i]}" = "$TR_STEP" ] || continue
        TRS[$i]=$(( ${TRS[$i]} + d )); found=1; break
      done
      [ "$found" = 1 ] || { TRN+=("$TR_STEP"); TRS+=("$d"); }
    fi
    TR_STEP="$1"; TR_LAST=$SECONDS
    for ((i = 0; i < ${#TRN[@]}; i++)); do acc="$acc t_${TRN[$i]}=${TRS[$i]}"; done
    printf 'step=%s\nwin=%s/%s\nwid=%s\nelapsed=%s\nsteps=%s\nname=%s\n' \
      "$1" "$TR_I" "$TR_N" "$TR_WID" "$SECONDS" "${acc# }" "$TR_NAME" >"$TRACE" 2>/dev/null || :
  }

  # ---- ONE round trip for every window option the loop reads (issue #706) ----
  # This used to be five `display-message` per window, i.e. 5N round trips, and
  # this probe runs inside a daemon at QoS BACKGROUND where each one costs ~10x.
  # Tab-separated with the window NAME last — the idiom fleet-dispatch.sh's
  # trust_sweep already uses, for the same reason: a name is the only field that
  # can contain the separator. The split below is parameter expansion rather than
  # `read -r a b c …` BECAUSE tab is IFS whitespace, so `read` COLLAPSES the empty
  # fields this is full of (an unset @hub next to an unset @claude_state) and every
  # column after the first empty one would shift. Same trap fleet-dispatch.sh
  # documents; it escapes via `awk -F'\t'`, this escapes without the fork.
  local W_ID=() W_PPID=() W_HUB=() W_STATE=() W_STS=() W_ACCT=() W_NAME=()
  local _row _r TB=$'\t'
  while IFS= read -r _row; do
    [ -n "$_row" ] || continue
    _r="$_row"
    W_ID+=("${_r%%$'\t'*}");    _r="${_r#*$'\t'}"
    W_PPID+=("${_r%%$'\t'*}");  _r="${_r#*$'\t'}"
    W_HUB+=("${_r%%$'\t'*}");   _r="${_r#*$'\t'}"
    W_STATE+=("${_r%%$'\t'*}"); _r="${_r#*$'\t'}"
    W_STS+=("${_r%%$'\t'*}");   _r="${_r#*$'\t'}"
    W_ACCT+=("${_r%%$'\t'*}");  _r="${_r#*$'\t'}"
    W_NAME+=("$_r")
  done < <(TM list-windows -t "$SESS" -F "#{window_id}$TB#{pane_pid}$TB#{@hub}$TB#{@claude_state}$TB#{@claude_state_ts}$TB#{@cc_account}$TB#{window_name}" 2>/dev/null)

  # load_meta <wid> → M_* . From the batch; an EXPLICIT window the batch does not
  # cover (another session on this socket — the fleet's own callers never do this,
  # but the old per-window path accepted it) still resolves the slow way, so this
  # is a speedup on the hot path and not a narrowing of what the script accepts.
  local M_PPID M_HUB M_STATE M_STS M_ACCT M_NAME
  load_meta() {
    local w="$1" i
    for ((i = 0; i < ${#W_ID[@]}; i++)); do
      [ "${W_ID[$i]}" = "$w" ] || continue
      M_PPID="${W_PPID[$i]}"; M_HUB="${W_HUB[$i]}";   M_STATE="${W_STATE[$i]}"
      M_STS="${W_STS[$i]}";   M_ACCT="${W_ACCT[$i]}"; M_NAME="${W_NAME[$i]}"
      return 0
    done
    M_PPID=$(wopt "$w" '#{pane_pid}');        M_HUB=$(wopt "$w" '#{@hub}')
    M_STATE=$(wopt "$w" '#{@claude_state}');  M_STS=$(wopt "$w" '#{@claude_state_ts}')
    M_ACCT=$(wopt "$w" '#{@cc_account}');     M_NAME=$(wopt "$w" '#{window_name}')
  }

  local targets=() wid
  # ${a[@]+"${a[@]}"}: bash 3.2 (macOS) treats an EMPTY array expansion as an
  # unbound variable under `set -u` — a fleet whose list-windows came back empty
  # must yield an empty sweep, not a crash.
  if [ "$MODE" = explicit ]; then targets=(${WIDS[@]+"${WIDS[@]}"}); else targets=(${W_ID[@]+"${W_ID[@]}"}); fi
  TR_N=${#targets[@]}
  trace meta

  # ---- the pane→Claude walk, ONCE for every window (issue #706) -------------
  # The single-pane form costs a `ps` plus two forked `awk`s per tree NODE, and it
  # was called per window: measured at 4.3 s of the probe's 21 s at background QoS
  # on a 9-window fleet, the single largest item. fleet_pane_claude_pids does the
  # whole sweep in three forks. Panels and the hub are filtered out FIRST so their
  # trees are never walked at all.
  local ppids=()
  for wid in ${targets[@]+"${targets[@]}"}; do
    load_meta "$wid"
    [[ "$M_NAME" =~ $PANEL_RE ]] && continue
    [ -n "$M_HUB" ] && continue
    [ -n "$M_PPID" ] && ppids+=("$M_PPID")
  done
  # "|<pane-pid>=<claude-pid>|…" — the `case` memo idiom ledger_until uses, because
  # bash 3.2 (macOS) has no associative arrays.
  local CPIDS="|"
  if [ "${#ppids[@]}" -gt 0 ]; then
    while IFS= read -r _row; do
      [ -n "$_row" ] || continue
      CPIDS="$CPIDS${_row%% *}=${_row##* }|"
    done < <(fleet_pane_claude_pids ${ppids[@]+"${ppids[@]}"} 2>/dev/null)
  fi
  cpid_of() {   # <pane-pid> → the Claude pid under it, or nothing (exit 1)
    local hit
    case "$CPIDS" in
      *"|$1="*) hit=${CPIDS#*"|$1="}; printf '%s' "${hit%%|*}"; return 0 ;;
    esac
    return 1
  }
  trace panepids

  # One clock for the whole run, not a `date` fork per comparison per window: a
  # probe lasts seconds, so a single stamp is both cheaper and more self-consistent
  # than five that disagree by a second.
  local NOW_S; NOW_S=$(date +%s)
  _LEDGER_MEMO="|"

  for wid in ${targets[@]+"${targets[@]}"}; do
    local name state acct cpid text pmodel banner kind capped tuntil
    local settled=0 vis=0 sts="" via=banner lcap lu reason
    TR_I=$((TR_I + 1)); TR_WID="$wid"
    load_meta "$wid"
    name="$M_NAME"; TR_NAME="$name"
    # bash's own regex match, not `printf | grep -qE`: two forks per window bought
    # nothing a builtin cannot do (issue #706).
    [[ "$name" =~ $PANEL_RE ]] && continue
    [ -n "$M_HUB" ] && continue
    cpid=$(cpid_of "$M_PPID") || { [ "$MODE" = explicit ] && { printf '  – %s: no Claude process — skipped\n' "$wid"; skipped=$((skipped+1)); }; continue; }
    [ -n "$cpid" ] || continue
    state="$M_STATE"
    acct="$M_ACCT"
    trace capture
    text=$(TM capture-pane -p -S "$SCROLL" -t "$wid" 2>/dev/null)
    trace banner
    pmodel=$(pane_model_of "$text")
    # The same fork-free reject usage-lib's fleet_limit_banner now opens with, and
    # here it skips the SUBSHELLS too: a pane with no `limit` anywhere in $SCROLL
    # lines — nearly every window, nearly every tick — costs zero processes to
    # classify instead of ten (issue #706). Empty banner → empty kind is exactly
    # what the pipeline produced for this input.
    banner=""; kind=""
    case "$text" in
      *limit*)
        banner=$(printf '%s\n' "$text" | fleet_limit_banner)
        [ -n "$banner" ] && kind=$(printf '%s\n' "$banner" | fleet_limit_kind) ;;
    esac
    # cap_settled is consulted ONLY for a `working` window, so nothing below it is
    # worth paying for on any other window — and most windows are not working. This
    # probe runs synchronously inside the 60 s quotawatch tick, so it stays cheap:
    # one extra capture-pane and two window options for the working few, nothing for
    # everyone else.
    if [ "$state" = working ]; then
      sts="$M_STS"
      trace visible
      # Is the cap the pane's CURRENT tail (the VISIBLE screen, no -S) rather than a
      # line somewhere back in the scrollback? That is cap_settled's recency half.
      case "$(TM capture-pane -p -t "$wid" 2>/dev/null | fleet_limit_banner | fleet_limit_kind)" in
        model:*) vis=1 ;;
      esac
      cap_settled "$vis" "$sts" "$NOW_S" "${FLEET_STUCK_WORKING_SECS:-120}" && settled=1
      # A5: a per-model cap ABORTS the turn with no Stop hook, so a settled window
      # is pinned at `working` though its turn is provably over. Record the truth
      # now — `done` — rather than leave a false `working` for #806/#101 to clear a
      # grace-period later. It is the correct state, it lets the in-place switch
      # below proceed, and it satisfies the quota failover's done-check when the
      # target model is also capped and the window is handed to the subscription
      # path. Only on a confirmed-settled cap; a genuinely-live turn is untouched.
      if [ "$settled" = 1 ] && [ "${DRY:-0}" != 1 ]; then
        TM set-window-option -t "$wid" @claude_state done 2>/dev/null
        TM set-window-option -t "$wid" @claude_needs '' 2>/dev/null
        TM set-window-option -t "$wid" @claude_state_ts "$NOW_S" 2>/dev/null
      fi
      trace banner
    fi
    case "$kind" in
      model:*) capped=${kind#model:} ;;
      *)
        # An explicit window with no model cap on screen is still switched on the
        # operator's word — they asked for THIS window.
        if [ "$MODE" != capped ]; then
          _lc "${pmodel%% *}"; capped="$_LC"
        else
          # --capped used to `continue` here, i.e. act ONLY on a banner it could
          # see. But the banner is not the durable fact — the LEDGER is. A
          # (account, model) cap row lives for FLEET_MODEL_LIMIT_TTL, so a window
          # still running a model this account is walled on is walled whether or
          # not its banner survived. On 2026-09-12 six monorepo windows sat on
          # fable for hours with the cap recorded and 7 days left to run, and this
          # sweep never considered them for the single reason that their banner had
          # scrolled past $SCROLL. A session that was merely IDLE when the cap
          # landed never printed a banner at all, so the scrollback can never be
          # the whole answer.
          lcap=""
          if [ -n "$acct" ] && [ -n "$pmodel" ]; then
            # Only the model's alias word is needed, not its display version.
            trace ledger
            _lc "${pmodel%% *}"; lcap="$_LC"
            ledger_until "$acct" "$lcap" "$NOW_S"; lu="$LEDGER_UNTIL"
            [ "$lu" -gt "$NOW_S" ] || lcap=""
            trace banner
          fi
          [ -n "$lcap" ] || continue
          capped="$lcap"; via=ledger
        fi ;;
    esac

    if ! switch_selected "${state:--}" "$pmodel" "$capped" "$TARGET" "$settled"; then
      # Ordered by the ACTUAL refusal, not by state: `working` is only the reason
      # while cap_settled has not lifted it, otherwise a settled window refused for
      # some other reason would be mislabelled "mid-turn".
      if [ "$state" = working ] && [ "$settled" != 1 ]; then
        reason=""
        [ "$vis" = 1 ] && reason=$(printf ' (cap on screen, but @claude_state_ts is %ss old — still inside FLEET_STUCK_WORKING_SECS=%s)' "$(( NOW_S - ${sts:-0} ))" "${FLEET_STUCK_WORKING_SECS:-120}")
        printf '  – %s (%s): mid-turn — left alone, the next pass takes it%s\n' "$wid" "$name" "$reason"
      elif ! model_matches "$capped" "$pmodel"; then
        printf '  – %s (%s): already off %s (now %s) — nothing to do\n' "$wid" "$name" "$capped" "${pmodel:-?}"
      else
        printf '  – %s (%s): target %s IS the capped model — skipped\n' "$wid" "$name" "$TARGET"
      fi
      skipped=$((skipped+1)); continue
    fi

    # A fallback that is itself capped on this account is no fallback: hand the
    # window to the subscription path rather than flip it onto a second wall.
    if [ -n "$acct" ]; then
      trace ledger
      ledger_until "$acct" "$TARGET" "$NOW_S"; tuntil="$LEDGER_UNTIL"
      trace select
      if [ "$tuntil" -gt "$NOW_S" ]; then
        printf '  – %s (%s): %s is ALSO capped on %s — skipped (subscription path)\n' "$wid" "$name" "$TARGET" "$acct"
        skipped=$((skipped+1)); continue
      fi
    fi

    if [ "$DRY" = 1 ]; then
      printf '  would: %s (%s) %s → %s in place [via %s]%s\n' "$wid" "$name" "${pmodel:-?}" "$TARGET" "$via" "$([ -n "$acct" ] && printf ' [%s]' "$acct")"
      switched=$((switched+1)); continue
    fi

    local transition_wt
    transition_wt=$(TM display-message -p -t "$wid" '#{@worktree}' 2>/dev/null)
    if [ -n "$transition_wt" ] && [ -d "$transition_wt" ]; then
      if ! fleet_transition_lock_take "$transition_wt"; then
        printf '  – %s: another transition owns this worktree — skipped\n' "$wid"
        skipped=$((skipped+1)); continue
      fi
      trap '[ -z "${transition_wt:-}" ] || fleet_transition_lock_drop "$transition_wt"' EXIT
    else
      transition_wt=''
    fi
    # Record the cap so the SPAWN path agrees with us: fleet-claude.sh launches
    # new sessions on FLEET_MODEL_FALLBACK while the (account, model) row holds.
    if [ "$LEDGER" = 1 ] && [ -n "$acct" ] && [ -n "$banner" ]; then
      if "$BIN/fleet-account.sh" model-limited "$acct" "$capped" "$banner" >/dev/null 2>&1; then
        _LEDGER_MEMO="|"
      fi
    fi
    # Shared with the collector's #524 branch, so the two callers cannot both
    # act on the same window inside its 180 s guard window.
    TM set-window-option -t "$wid" @model_migrating "$(date +%s)" 2>/dev/null

    # --- the four sanctioned keystrokes -------------------------------------
    trace switch
    SK -t "$wid" Escape 2>/dev/null; sleep 0.4
    SK -t "$wid" -l -- "/model $TARGET" 2>/dev/null; sleep 1.2
    SK -t "$wid" Enter 2>/dev/null; sleep 2
    local tries="$DIALOG_TRIES"
    while [ "$tries" -gt 0 ]; do
      cap "$wid" | grep -q 'Switch model?' || break
      SK -t "$wid" Enter 2>/dev/null; sleep 1.5
      tries=$((tries - 1))
    done

    # --- verify off the status line, never off our own keystrokes ------------
    trace verify
    local ok=0 waited=0 nowm
    while [ "$waited" -lt "$VERIFY_WAIT" ]; do
      nowm=$(pane_model_of "$(cap "$wid")")
      if model_matches "$TARGET" "$nowm" && ! model_matches "$capped" "$nowm"; then ok=1; break; fi
      sleep 1; waited=$((waited+1))
    done

    if [ "$ok" = 1 ]; then
      TM set-window-option -t "$wid" @cc_model "$TARGET" 2>/dev/null
      printf '  ✓ %s (%s): %s → %s in place (%ss)\n' "$wid" "$name" "$capped" "$nowm" "$waited"
      # ${name} braced on purpose: bash 3.2 (macOS) swallows the following
      # multibyte arrow into the variable NAME otherwise, and set -u then fires.
      switched=$((switched+1)); note "${name}→$TARGET"
      local msg="$NUDGE"
      # The default nudge tells the session its TURN was interrupted and to pick the
      # work back up. That is true of a banner detection and false of a ledger one:
      # a window matched off the ledger printed no banner, so it was sitting IDLE at
      # its prompt when the cap landed — possibly because it was finished. Waking a
      # finished worker to "continue the task" spends tokens on nothing, so a ledger
      # detection flips the model silently and lets the session notice on its own
      # next turn. An explicit --nudge is still honoured either way.
      [ "$msg" = "__default__" ] && { if [ "$via" = ledger ]; then msg=""; else msg="$NUDGE_DEFAULT"; fi; }
      if [ -n "$msg" ]; then
        msg=${msg//__MODEL__/$TARGET}
        # The SendMessage channel, never send-keys (#513): queued if the session
        # is already working again, and it never lands in a TUI dialog.
        fleet_peer_send "$cpid" "$msg" fleet-model-switch >/dev/null 2>&1 \
          || printf '    (nudge not delivered — no peer inbox for pid %s)\n' "$cpid"
      fi
    else
      printf '  ✗ %s (%s): still on %s after %ss\n' "$wid" "$name" "${nowm:-?}" "$VERIFY_WAIT"
      failed=$((failed+1))
      if [ "$FALLBACK" = 1 ]; then
        [ -z "$transition_wt" ] || fleet_transition_lock_drop "$transition_wt"
        transition_wt=''
        printf '    → handing %s to fleet-migrate.sh --model %s (close + --resume)\n' "$wid" "$TARGET"
        "$BIN/fleet-migrate.sh" --model "$TARGET" --session "$SESS" "$wid" 2>&1 | sed 's/^/    /'
        handed=$((handed+1))
      fi
    fi
    [ -z "$transition_wt" ] || fleet_transition_lock_drop "$transition_wt"
    transition_wt=''
  done

  trace 'done'
  local sum
  sum="fleet-model-switch: $switched switched, $skipped skipped, $failed unverified$([ "$handed" -gt 0 ] && printf ', %s handed to migrate' "$handed")"
  printf '%s%s\n' "$sum" "$([ -n "$REPORT" ] && printf ' (%s)' "$REPORT")"
  [ "$TOAST" = 1 ] && [ "$switched" -gt 0 ] && TM display-message "$sum" 2>/dev/null
  return 0
}

case "${0##*/}" in
  fleet-model-switch.sh) main "$@" ;;
esac
