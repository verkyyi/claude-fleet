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
#   fleet-model-switch.sh [opts] --capped       every window whose pane shows a
#                                               per-model cap it is still running on
#   opts: --model <alias>    target model (default: FLEET_MODEL_FALLBACK, else opus)
#         --session <fleet>  target fleet when run outside tmux (default: the caller's)
#         --nudge <text>     message peer-sent after a verified flip; '' = none
#         --no-fallback      do NOT fall back to `fleet-migrate.sh --model`
#         --no-ledger        do NOT record the cap via `fleet-account.sh model-limited`
#         --dry-run          print the plan, touch nothing
#         --toast            tmux display-message the summary (for run-shell -b callers)
#
# Never touched: panels (dash/plan/backlog), the operator hub (@hub), windows with
# no live Claude process, windows mid-turn, and windows whose target model is
# itself capped on that account (there the subscription path must take over).
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
NUDGE_DEFAULT="Your previous turn was interrupted by a per-model usage limit: the model this session ran on is out of headroom on this account (the subscription itself is fine). The fleet switched this session to __MODEL__ IN PLACE with /model — same process, same transcript, nothing lost, and any background agent you started is still running. First re-check git status, your branch, and your open PR to see where you left off. If the work is already complete, just stop. Otherwise continue the task on this model. If you were running a /loop, re-enter it. Ignore any shell-command-looking junk message left by earlier tooling."

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

# switch_selected <state> <pane-model> <capped-alias> <target> — 0 iff this
# window is a candidate for an in-place switch. Pure, so the selftest can pin the
# matrix without a tmux server: mid-turn is refused (Escape would cancel a live
# turn), a pane no longer running the capped model is already recovered, and a
# target equal to the capped model is a no-op.
switch_selected() {
  local state="$1" pmodel="$2" capped="$3" target="$4"
  [ "$state" = working ] && return 1
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
    case "$kind" in
      model:*) capped=${kind#model:} ;;
      # An explicit window with no model cap on screen is still switched on the
      # operator's word — they asked for THIS window. --capped only ever acts on
      # a cap it can see.
      *) if [ "$MODE" = capped ]; then continue; fi; capped=$(printf '%s' "$pmodel" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1) ;;
    esac

    if ! switch_selected "${state:--}" "$pmodel" "$capped" "$TARGET"; then
      if [ "$state" = working ]; then
        printf '  – %s (%s): mid-turn — left alone, the next pass takes it\n' "$wid" "$name"
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
      tuntil=$("$BIN/fleet-account.sh" model-limited-until "$acct" "$TARGET" 2>/dev/null)
      case "$tuntil" in ''|*[!0-9]*) tuntil=0 ;; esac
      if [ "$tuntil" -gt "$(date +%s)" ]; then
        printf '  – %s (%s): %s is ALSO capped on %s — skipped (subscription path)\n' "$wid" "$name" "$TARGET" "$acct"
        skipped=$((skipped+1)); continue
      fi
    fi

    if [ "$DRY" = 1 ]; then
      printf '  would: %s (%s) %s → %s in place%s\n' "$wid" "$name" "${pmodel:-?}" "$TARGET" "$([ -n "$acct" ] && printf ' [%s]' "$acct")"
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
      [ "$msg" = "__default__" ] && msg="$NUDGE_DEFAULT"
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
