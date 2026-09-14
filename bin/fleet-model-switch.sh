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
pane_model_of() {
  printf '%s\n' "${1:-}" \
    | sed -nE 's/.*◆ ([A-Za-z0-9][A-Za-z0-9.]*([ ][A-Za-z0-9.]+)*)[[:space:]][[:space:]]+.*/\1/p' \
    | tail -1
}

# ledger_until <account> <model> — `fleet-account.sh model-limited-until`, memoized
# for the life of this run. NOT pure (it forks), so it lives out here rather than
# with the helpers above. The memo is the whole point: every window on a fleet
# normally shares one account and one model, so the banner-less ledger probe and the
# is-my-fallback-also-capped check would otherwise fork fleet-account.sh (which
# sources fleet-lib + usage-lib each time) once per window — measured at roughly
# doubling the sweep's dry-run probe on a 14-window fleet, and that probe runs
# SYNCHRONOUSLY inside the 60 s quotawatch tick. One fork per distinct pair instead.
# A cap cannot meaningfully expire inside a single sweep, so a run-scoped cache is
# exact. bash 3.2 (macOS) has no associative arrays — hence the delimited string.
_LEDGER_MEMO="|"
ledger_until() {
  local a="${1:-}" m="${2:-}" key hit v
  [ -n "$a" ] && [ -n "$m" ] || { printf '0'; return 0; }
  key="$a/$m"
  case "$_LEDGER_MEMO" in
    *"|$key="*) hit=${_LEDGER_MEMO#*"|$key="}; printf '%s' "${hit%%|*}"; return 0 ;;
  esac
  v=$("$BIN/fleet-account.sh" model-limited-until "$a" "$m" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  _LEDGER_MEMO="${_LEDGER_MEMO}$key=$v|"
  printf '%s' "$v"
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

  local targets=() wid
  if [ "$MODE" = explicit ]; then targets=("${WIDS[@]}"); else
    while IFS= read -r wid; do [ -n "$wid" ] && targets+=("$wid"); done \
      < <(TM list-windows -t "$SESS" -F '#{window_id}' 2>/dev/null)
  fi

  for wid in "${targets[@]}"; do
    local name state acct cpid text pmodel banner kind capped tuntil
    local settled=0 vis=0 sts="" via=banner lcap lu reason
    name=$(wopt "$wid" '#{window_name}')
    printf '%s' "$name" | grep -qE "$PANEL_RE" && continue
    [ -n "$(wopt "$wid" '#{@hub}')" ] && continue
    cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || { [ "$MODE" = explicit ] && { printf '  – %s: no Claude process — skipped\n' "$wid"; skipped=$((skipped+1)); }; continue; }
    [ -n "$cpid" ] || continue
    state=$(wopt "$wid" '#{@claude_state}')
    acct=$(wopt "$wid" '#{@cc_account}')
    text=$(TM capture-pane -p -S "$SCROLL" -t "$wid" 2>/dev/null)
    pmodel=$(pane_model_of "$text")
    banner=$(printf '%s\n' "$text" | fleet_limit_banner)
    kind=$(printf '%s\n' "$banner" | fleet_limit_kind)
    # cap_settled is consulted ONLY for a `working` window, so nothing below it is
    # worth paying for on any other window — and most windows are not working. This
    # probe runs synchronously inside the 60 s quotawatch tick, so it stays cheap:
    # one extra capture-pane and two window options for the working few, nothing for
    # everyone else.
    if [ "$state" = working ]; then
      sts=$(wopt "$wid" '#{@claude_state_ts}')
      # Is the cap the pane's CURRENT tail (the VISIBLE screen, no -S) rather than a
      # line somewhere back in the scrollback? That is cap_settled's recency half.
      case "$(TM capture-pane -p -t "$wid" 2>/dev/null | fleet_limit_banner | fleet_limit_kind)" in
        model:*) vis=1 ;;
      esac
      cap_settled "$vis" "$sts" "$(date +%s)" "${FLEET_STUCK_WORKING_SECS:-120}" && settled=1
    fi
    case "$kind" in
      model:*) capped=${kind#model:} ;;
      *)
        # An explicit window with no model cap on screen is still switched on the
        # operator's word — they asked for THIS window.
        if [ "$MODE" != capped ]; then
          capped=$(printf '%s' "$pmodel" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1)
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
            lcap=$(printf '%s' "$pmodel" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1)
            lu=$(ledger_until "$acct" "$lcap")
            [ "$lu" -gt "$(date +%s)" ] || lcap=""
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
        [ "$vis" = 1 ] && reason=$(printf ' (cap on screen, but @claude_state_ts is %ss old — still inside FLEET_STUCK_WORKING_SECS=%s)' "$(( $(date +%s) - ${sts:-0} ))" "${FLEET_STUCK_WORKING_SECS:-120}")
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
      tuntil=$(ledger_until "$acct" "$TARGET")
      if [ "$tuntil" -gt "$(date +%s)" ]; then
        printf '  – %s (%s): %s is ALSO capped on %s — skipped (subscription path)\n' "$wid" "$name" "$TARGET" "$acct"
        skipped=$((skipped+1)); continue
      fi
    fi

    if [ "$DRY" = 1 ]; then
      printf '  would: %s (%s) %s → %s in place [via %s]%s\n' "$wid" "$name" "${pmodel:-?}" "$TARGET" "$via" "$([ -n "$acct" ] && printf ' [%s]' "$acct")"
      switched=$((switched+1)); continue
    fi

    # Record the cap so the SPAWN path agrees with us: fleet-claude.sh launches
    # new sessions on FLEET_MODEL_FALLBACK while the (account, model) row holds.
    if [ "$LEDGER" = 1 ] && [ -n "$acct" ] && [ -n "$banner" ]; then
      "$BIN/fleet-account.sh" model-limited "$acct" "$capped" "$banner" >/dev/null 2>&1 || :
    fi
    # Shared with the collector's #524 branch, so the two callers cannot both
    # act on the same window inside its 180 s guard window.
    TM set-window-option -t "$wid" @model_migrating "$(date +%s)" 2>/dev/null

    # --- the four sanctioned keystrokes -------------------------------------
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
        printf '    → handing %s to fleet-migrate.sh --model %s (close + --resume)\n' "$wid" "$TARGET"
        "$BIN/fleet-migrate.sh" --model "$TARGET" --session "$SESS" "$wid" 2>&1 | sed 's/^/    /'
        handed=$((handed+1))
      fi
    fi
  done

  local sum
  sum="fleet-model-switch: $switched switched, $skipped skipped, $failed unverified$([ "$handed" -gt 0 ] && printf ', %s handed to migrate' "$handed")"
  printf '%s%s\n' "$sum" "$([ -n "$REPORT" ] && printf ' (%s)' "$REPORT")"
  [ "$TOAST" = 1 ] && [ "$switched" -gt 0 ] && TM display-message "$sum" 2>/dev/null
  return 0
}

case "${0##*/}" in
  fleet-model-switch.sh) main "$@" ;;
esac
