#!/bin/bash
# fleet-migrate.sh — move LIVE Claude sessions onto the fleet's active subscription
# account (issue #512; `fleet-account.sh migrate …` delegates here).
#
# WHY a close + resume, never an in-place swap: a running `claude` bakes its OAuth
# token in at launch (CLAUDE_CODE_OAUTH_TOKEN, exported by fleet-claude.sh) and has
# no way to change accounts afterwards — apiKeyHelper carries API keys only
# (verified on #495). So "move this session" always means: end the process, start a
# new one on the new token, `--resume` the same transcript. And the #495 restart
# pass could not even do that on this install: the SessionEnd hook (session-end-
# hook.sh, #403) kill-windows the pane the instant Claude exits, so there was never
# a shell left to type a relaunch into. This script embraces the hook instead:
#
#   1. read everything about the window FIRST (name, cwd, @issue/@raw/@worktree/
#      @origin/@wid, state) and the session id off the Claude Code registry
#      (~/.claude/sessions/<pid>.json — exact, not "newest transcript");
#   2. ask Claude to exit — `/exit` typed at the prompt after an Escape (which also
#      cancels the "Usage limit reached · continuing automatically" wait, the very
#      state this is for) — and WAIT for the Claude pid to be gone, never typing
#      anything else while it lives (issue #511);
#   3. let the SessionEnd hook close the window (it also records the /fleet-history
#      row); when no hook closes it (FLEET_CLOSE_ON_EXIT=0) relaunch in the surviving
#      shell instead;
#   4. open a NEW window in the same cwd running
#      `fleet-claude.sh --resume <sid> [<nudge>]` — fleet-claude.sh exports the
#      ACTIVE account's token, applies the fleet model/MCP flags and stamps
#      @cc_account — re-bind the window options, then VERIFY by reading the new
#      process's token out of its environment (truth, not a stamp).
#
#   fleet-migrate.sh [opts] <window>…           a @wid handle (b3), tmux id or index
#   fleet-migrate.sh [opts] --limited           every window whose account is benched
#                                               (working ones included: their turn is dead)
#   fleet-migrate.sh [opts] --idle              done|needs windows NOT on the active account
#   fleet-migrate.sh [opts] --all               every window NOT on the active account
#   fleet-migrate.sh [opts] --account <label>   every window running on <label>
#   fleet-migrate.sh whoami <window>            print the account a window really runs
#                                               (token truth; re-stamps a stale @cc_account)
#   opts: --session <fleet>   target fleet when run outside tmux (default: the caller's)
#         --model <alias>     relaunch on THIS model (issue #524: a per-model cap —
#                             "hit your Fable 5 limit" — walled the session while the
#                             subscription is fine; the collector passes the
#                             FLEET_MODEL_FALLBACK). Rides ahead of --resume so the
#                             launcher takes it as the caller's explicit choice; the
#                             default nudge then names the MODEL cap, not the account.
#         --nudge <text>      first prompt of the resumed session (default: the
#                             interrupted-turn text for a `working` window; none if idle)
#         --dry-run           print the plan, touch nothing
#         --toast             tmux display-message the summary (for run-shell -b callers)
#
# Never touched: panels (dash/plan/backlog), the operator hub (@hub), windows with no
# Claude process, raw scratch windows whose cwd is FLEET_MAIN without a registry
# session id — and a window with NO MOVE AVAILABLE (issue #567): one already on
# the active account, or any window while the active account is itself benched.
# When every pool account is benched `fleet-account.sh active` keeps the current
# one (the right answer for a fresh spawn — there is no better), so an
# `--account X` / `--limited` fan-out would close N sessions and cold-boot each
# one (~25 s) straight back onto X — or onto another wall — still walled. Such a
# window is reported as a skip; only a `--model` move is exempt (it is a
# same-account relaunch on purpose, #524).
# Windows are moved ONE AT A TIME (each is a cold `claude` boot).
# Exit 0 (per-window outcomes are printed); 2 = usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

PANEL_RE='^(plan|dash|backlog)$'
ACCT_DIR="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}"
LAUNCH="${FLEET_MIGRATE_LAUNCH:-$BIN/fleet-claude.sh}"   # selftest seam: a fake launcher
EXIT_WAIT="${FLEET_MIGRATE_EXIT_WAIT:-30}"                 # s to wait for Claude to exit
CLOSE_WAIT="${FLEET_MIGRATE_CLOSE_WAIT:-15}"               # s to wait for the hook to close the window
BOOT_WAIT="${FLEET_MIGRATE_BOOT_WAIT:-15}"                 # s to wait for the resumed Claude to appear
# The resumed session's FIRST prompt. It ends with the language rule (issue #620)
# because this text is the most recent instruction a --resume'd model sees: the
# transcript above may be forty turns of Chinese, and an English tail with no such
# rule silently flips the rest of the session to English. The rule says "keep the
# language you had", never "use language X", so an English session is unaffected.
# Overridable per fleet via FLEET_MIGRATE_NUDGE / FLEET_MIGRATE_NUDGE_MODEL, which
# replace the whole string — language rule included (resolved after fleet_load_conf,
# below; the _BUILTIN pair is what those keys default to).
NUDGE_BUILTIN="Your previous turn was interrupted by a subscription usage limit. The fleet moved this session to another subscription account and resumed it in a new tmux window via claude --resume. First re-check git status, your branch, and your open PR to see where you left off. If the work is already complete, just stop. Otherwise continue the task. If you were running a /loop, re-enter it. Ignore any shell-command-looking junk message left by earlier tooling.${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"
# --model variant (#524): the account is fine, only one model is capped.
NUDGE_MODEL_BUILTIN="Your previous turn was interrupted by a per-model usage limit: the model this session ran on has hit its cap on this account (the subscription itself still has headroom). The fleet relaunched this session on __MODEL__ via claude --resume --model in a new tmux window, same transcript. First re-check git status, your branch, and your open PR to see where you left off. If the work is already complete, just stop. Otherwise continue the task on this model. If you were running a /loop, re-enter it. Ignore any shell-command-looking junk message left by earlier tooling.${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"
# Pre-seeded from the built-ins so a SOURCED run (fleet-migrate-selftest.sh pins
# the pure matrices) is safe under `set -u`; main() re-resolves them against the
# per-fleet conf once it has loaded.
NUDGE_DEFAULT="$NUDGE_BUILTIN"
NUDGE_MODEL_DEFAULT="$NUDGE_MODEL_BUILTIN"

# Sourced (fleet-migrate-selftest.sh pins the pure matrices) → define only; a
# direct run dispatches. Same guard idiom as fleet-account.sh.

# ---------------------------------------------------------------- helpers ----
# (file scope, so fleet-migrate-selftest.sh can source the pure ones)
note() { REPORT="${REPORT}${REPORT:+; }$1"; }
acct_benched() { [ "$("$BIN/fleet-account.sh" limited-until "$1" 2>/dev/null || echo 0)" -gt "$(now)" ]; }
# acct_of_pid <claude-pid> — the pool label whose token the process carries
# (empty: no token / not a pool token, i.e. the ambient login).
acct_of_pid() {
  local s; s=$(fleet_claude_token_sha "$1") || return 0
  printf '%s' "$SHA2LABEL" | awk -F'\t' -v s="$s" '$1==s{print $2; exit}'
}
# window_account <wid> <claude-pid> <stamp> — truth first, stamp as fallback; a
# stamp that disagrees with the truth is healed on the spot (issue #511 part A).
window_account() {
  local wid="$1" cpid="$2" stamp="$3" truth
  truth=$(acct_of_pid "$cpid")
  if [ -n "$truth" ]; then
    [ "$truth" != "$stamp" ] && TM set-window-option -t "$wid" @cc_account "$truth" 2>/dev/null
    printf '%s' "$truth"
  else
    printf '%s' "$stamp"
  fi
}
# --- session id -----------------------------------------------------------------
# The registry record is exact. Fallback: the newest top-level transcript in the
# cwd's project dir (Claude Code encodes the cwd by replacing / and . with -).
session_id_for() {
  local cpid="$1" cwd="$2" sid pdir f
  sid=$(fleet_cc_session_id "$cpid" 2>/dev/null)
  [ -n "$sid" ] && { printf '%s' "$sid"; return 0; }
  pdir="${FLEET_CC_PROJECTS_DIR:-$HOME/.claude/projects}/$(printf '%s' "$cwd" | tr '/.' '--')"
  [ -d "$pdir" ] || return 1
  f=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1); [ -n "$f" ] || return 1
  f=${f##*/}; printf '%s' "${f%.jsonl}"
}

# wopt <wid> <format> — one expanded format off a window (empty + exit 1 if gone).
wopt() { TM display-message -p -t "$1" "$2" 2>/dev/null; }

# window_closed <wid> — 0 iff the window is gone OR has no live pane. tmux keeps a
# window object around for a moment after its last pane exits (and for good on a
# remain-on-exit install): `display-message -t <wid>` still succeeds there, with
# an empty #{pane_pid} / #{pane_dead}=1 — that is "closed" for our purposes, never
# a shell to type into.
window_closed() {
  local o; o=$(TM display-message -p -t "$1" '#{pane_pid}|#{pane_dead}' 2>/dev/null) || return 0
  case "$o" in ''|'|'*|*'|1') return 0;; esac
  return 1
}

# --- eligibility (pure; pinned by fleet-migrate-selftest.sh) ---------------------
# migrate_eligible <name> <hub> <raw> <cwd> <main> <sid> → 0 iff a window may be moved
migrate_eligible() {
  local name="$1" hub="$2" raw="$3" cwd="$4" main="$5" sid="$6"
  printf '%s' "$name" | grep -qE "$PANEL_RE" && return 1
  [ "$hub" = 1 ] && return 1
  if [ "$raw" = 1 ] && [ -n "$main" ] && [ "${cwd%/}" = "${main%/}" ] && [ -z "$sid" ]; then return 1; fi
  return 0
}
# migrate_noop <label> <active> <model> <active-benched> → 0 iff there is no move
# to make (issue #567): the target is the account the window already runs on
# (target == source is "no move available", never a move), or the target is
# benched itself — `active` names a benched account only when NONE is eligible,
# and a cold boot onto another wall is no better than staying on this one. A
# --model relaunch is exempt (same account, other model — the #524 per-model cap
# fallback); no pool at all (empty active) is left alone so a pool-less install
# keeps its explicit-restart behaviour.
migrate_noop() { [ -z "$3" ] && [ -n "$2" ] && { [ "$1" = "$2" ] || [ "${4:-0}" = 1 ]; }; }
# migrate_selected <mode> <label> <state> <active> <benched> <wanted> → 0 iff selected
migrate_selected() {
  local mode="$1" label="$2" state="$3" active="$4" benched="$5" wanted="$6"
  case "$mode" in
    limited) [ -n "$label" ] && [ "$benched" = 1 ] ;;
    idle)    case "$state" in done|needs) [ "$label" != "$active" ] ;; *) return 1 ;; esac ;;
    all)     [ "$label" != "$active" ] ;;
    account) [ -n "$label" ] && [ "$label" = "$wanted" ] ;;
    explicit) return 0 ;;
    *) return 1 ;;
  esac
}

# --- the move -------------------------------------------------------------------

migrate_one() {
  local wid="$1" cpid="$2" label="$3" name cwd state raw iss wt origin hnd
  # One display-message per field — NOT a joined format split on a control byte:
  # tmux ≤3.4 prints a 0x1f in format output as the literal text `\037` (vis
  # escaping; 3.7 emits the byte), so a separator-based parse is not portable.
  name=$(wopt "$wid" '#{window_name}') || return 1
  cwd=$(wopt "$wid" '#{pane_current_path}'); state=$(wopt "$wid" '#{@claude_state}')
  raw=$(wopt "$wid" '#{@raw}'); iss=$(wopt "$wid" '#{@issue}'); wt=$(wopt "$wid" '#{@worktree}')
  origin=$(wopt "$wid" '#{@origin}')
  hnd=$(wopt "$wid" '#{@wid}')      # the fleet's short window handle (issue #566)
  local sid; sid=$(session_id_for "$cpid" "$cwd") || sid=""
  if ! migrate_eligible "$name" "$(TM display-message -p -t "$wid" '#{@hub}' 2>/dev/null)" "$raw" "$cwd" "${FLEET_MAIN:-}" "$sid"; then
    say "  – $name ($wid): not eligible (panel/hub/main-cwd) — skipped"; skipped=$((skipped+1)); return 0
  fi
  if migrate_noop "$label" "$ACTIVE" "$MODEL" "$ACTIVE_BENCHED"; then
    if [ "$label" = "$ACTIVE" ]; then say "  – $name ($wid): already on $label — skipped"
    else say "  – $name ($wid): nowhere to move (${label:-ambient login} → $ACTIVE, benched too) — skipped"; fi
    skipped=$((skipped+1)); return 0
  fi
  [ -n "$sid" ] || { say "  – $name ($wid): no session id (registry + transcript lookup failed) — skipped"; skipped=$((skipped+1)); return 0; }
  local nudge="$NUDGE"
  if [ "$NUDGE_SET" = 0 ]; then
    if [ "$state" = working ]; then
      if [ -n "$MODEL" ]; then nudge="${NUDGE_MODEL_DEFAULT//__MODEL__/$MODEL}"; else nudge="$NUDGE_DEFAULT"; fi
    else nudge=""; fi
  fi
  nudge=$(printf '%s' "$nudge" | tr -d "'\`")             # embedded single-quoted below
  # --model rides BEFORE --resume (and on the fresh-launch fallback too) so
  # fleet-claude.sh sees an explicit model and skips its FLEET_MODEL default.
  local mflag=""; [ -n "$MODEL" ] && mflag=" --model '$MODEL'"
  local cmd="'$LAUNCH'$mflag --resume '$sid'${nudge:+ '$nudge'} || '$LAUNCH'$mflag; exec \$SHELL"
  if [ "$DRY" = 1 ]; then
    say "  ↻ $name ($wid) [${label:-?} → ${ACTIVE:-?}${MODEL:+ on $MODEL}] would /exit pid $cpid and resume ${sid%%-*}… in $cwd${nudge:+ (nudged)}"
    return 0
  fi
  # A migrate is a CLOSE + RESUME, not a death: mark the window as already reported
  # (issue #574) so the SessionEnd hook's child-report backstop does not tell this
  # session's PARENT that its child was reaped — seconds before the same session
  # comes back in a new window. The resumed session reports for real when it ships,
  # and the new window below starts with the stamp cleared.
  TM set-window-option -t "$wid" @reported 1 2>/dev/null
  # 2. exit: Escape (cancels the auto-continue wait / any menu), then /exit + Enter.
  SK -t "$wid" Escape 2>/dev/null; sleep 0.6
  SK -t "$wid" -l '/exit' 2>/dev/null; sleep 0.6; SK -t "$wid" Enter 2>/dev/null
  local i alive=1
  for ((i=1; i<=EXIT_WAIT; i++)); do
    kill -0 "$cpid" 2>/dev/null || { alive=0; break; }
    # the slash-command menu may have swallowed the first Enter: one more at 6s
    [ "$i" = 6 ] && TM display-message -p -t "$wid" '#{pane_pid}' >/dev/null 2>&1 && SK -t "$wid" Enter 2>/dev/null
    sleep 1
  done
  if [ "$alive" = 1 ]; then
    say "  ✗ $name ($wid): Claude (pid $cpid) did not exit within ${EXIT_WAIT}s — left as is"; skipped=$((skipped+1)); return 0
  fi
  # 3. the SessionEnd hook closes the window (and records the ledger row) …
  for ((i=1; i<=CLOSE_WAIT; i++)); do
    window_closed "$wid" && break
    sleep 1
  done
  local nw
  if ! window_closed "$wid"; then
    # … or it doesn't (FLEET_CLOSE_ON_EXIT=0): Claude is verified gone, the pane is
    # at its `exec $SHELL` — relaunch right there, keeping the window.
    fleet_pane_claude_pid "$wid" "$SOCK" >/dev/null 2>&1 && { say "  ✗ $name ($wid): a Claude is back under the pane — not typing"; skipped=$((skipped+1)); return 0; }
    TM clear-history -t "$wid" 2>/dev/null || :     # drop the old limit banner (stale-banner cascade guard)
    SK -t "$wid" -l "$cmd" 2>/dev/null; SK -t "$wid" Enter 2>/dev/null
    nw="$wid"
  else
    # A window object can outlive its last pane for a few seconds (the pane died
    # before the hook's detached kill-window ran); reap the pane-less ghost so the
    # dash never shows it — nothing runs in it, so this is not a destructive kill.
    TM display-message -p -t "$wid" '' >/dev/null 2>&1 && TM kill-window -t "$wid" 2>/dev/null
    # 4. a NEW window, same name + cwd, resumed under the active account.
    nw=$(TM new-window -d -t "$SESS:" -n "$name" -c "$cwd" -P -F '#{window_id}' "$cmd" 2>/dev/null)
    [ -n "$nw" ] || { say "  ✗ $name ($wid): new-window failed — session ${sid%%-*}… is closed but NOT resumed (resume by hand: cd $cwd && claude --resume $sid)"; skipped=$((skipped+1)); return 0; }
    [ -n "$iss" ] && TM set-window-option -t "$nw" @issue "$iss" 2>/dev/null
    [ "$raw" = 1 ] && TM set-window-option -t "$nw" @raw 1 2>/dev/null
    [ -n "$wt" ] && TM set-window-option -t "$nw" @worktree "$wt" 2>/dev/null
    [ -n "$origin" ] && TM set-window-option -t "$nw" @origin "$origin" 2>/dev/null
    # @wid (issue #566): the WHOLE point of the handle is that it survives this —
    # a migrate closes the window and opens a new one, minting a new window_id,
    # and 21 windows went through here in a single night. Re-stamp the SAME handle
    # so "migrate b3" still means the same session afterwards. fleet_wid_stamp
    # takes it as a WANT: if something claimed it in the gap it allocates the next
    # free one instead of letting two windows answer to b3.
    [ -n "$hnd" ] && fleet_wid_stamp "$nw" "$SOCK" "$hnd" >/dev/null 2>&1
    TM set-window-option -t "$nw" @claude_state "${state:-done}" 2>/dev/null
    TM set-window-option -t "$nw" @claude_state_ts "$(now)" 2>/dev/null
  fi
  TM set-window-option -t "$nw" @migrated "$(now)" 2>/dev/null
  # …and clear the pre-exit suppression: the resumed session still owes its parent a
  # report, and (on the CLOSE_ON_EXIT=0 branch) $nw IS the window that carries it.
  TM set-window-option -t "$nw" -u @reported 2>/dev/null
  # 5. verify: the resumed process's token, read out of its environment.
  local ncp="" nl=""
  for ((i=1; i<=BOOT_WAIT; i++)); do
    ncp=$(fleet_pane_claude_pid "$nw" "$SOCK" 2>/dev/null) && [ -n "$ncp" ] && break
    sleep 1
  done
  [ -n "$ncp" ] && nl=$(acct_of_pid "$ncp")
  if [ -z "$ncp" ]; then
    say "  ? $name ($wid → $nw): resumed window opened but no Claude seen within ${BOOT_WAIT}s — check it"
  elif [ -n "$ACTIVE" ] && [ "$nl" != "$ACTIVE" ]; then
    say "  ? $name ($wid → $nw): resumed as pid $ncp on '${nl:-ambient login}', expected '$ACTIVE' — check it"
  else
    say "  ✓ $name ($wid → $nw): ${label:-?} → ${nl:-?}${MODEL:+ on $MODEL} (pid $ncp, session ${sid%%-*}…)"
  fi
  moved=$((moved+1)); note "$name"
  return 0
}


# ---------------------------------------------------------------------- main ----
# Sourced (fleet-migrate-selftest.sh pins the pure matrices) → define only; a
# direct run dispatches. Same guard idiom as fleet-account.sh.
migrate_main() {
  MODE=""; ACCOUNT=""; NUDGE=""; NUDGE_SET=0; DRY=0; TOAST=0; SESS=""; MODEL=""; WIDS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --limited|--idle|--all) MODE="${1#--}"; shift ;;
      --account) MODE=account; ACCOUNT="${2:-}"; shift 2 ;;
      --account=*) MODE=account; ACCOUNT="${1#--account=}"; shift ;;
      --session) SESS="${2:-}"; shift 2 ;;
      --session=*) SESS="${1#--session=}"; shift ;;
      --nudge) NUDGE="${2:-}"; NUDGE_SET=1; shift 2 ;;
      --nudge=*) NUDGE="${1#--nudge=}"; NUDGE_SET=1; shift ;;
      --model) MODEL="${2:-}"; shift 2 ;;
      --model=*) MODEL="${1#--model=}"; shift ;;
      --dry-run) DRY=1; shift ;;
      --toast) TOAST=1; shift ;;
      whoami) MODE=whoami; shift ;;
      -h|--help) sed -n '2,45p' "$0"; return 0 ;;
      --*) echo "fleet-migrate: unknown option '$1'" >&2; return 2 ;;
      *) WIDS+=("$1"); shift ;;
    esac
  done
  [ -n "$MODE" ] || [ "${#WIDS[@]}" -gt 0 ] || { sed -n '25,40p' "$0" >&2; return 2; }
  [ "$MODE" = account ] && [ -z "$ACCOUNT" ] && { echo "fleet-migrate: --account needs a label" >&2; return 2; }
  MODEL=$(printf '%s' "$MODEL" | LC_ALL=C tr -cd 'A-Za-z0-9._-')   # embedded single-quoted in the launch line

  [ -n "$SESS" ] || SESS=$(fleet_current_session)
  [ -n "$SESS" ] || { echo "fleet-migrate: no tmux session (pass --session <fleet>)" >&2; return 2; }
  fleet_load_conf "$SESS" 2>/dev/null || :
  # Now that the per-fleet overlay is loaded, let it override the resume nudges
  # (issue #620). An operator value replaces the built-in ENTIRELY, so a fleet that
  # customises one owns its language rule too — that is why the built-ins carry the
  # rule inline rather than appending it here.
  NUDGE_DEFAULT="${FLEET_MIGRATE_NUDGE:-$NUDGE_BUILTIN}"
  NUDGE_MODEL_DEFAULT="${FLEET_MIGRATE_NUDGE_MODEL:-$NUDGE_MODEL_BUILTIN}"
  SOCK=$(fleet_socket "$SESS")
  # A positional may be the fleet's short window HANDLE (`b3`, issue #566) instead
  # of a tmux window-id/index. Normalise once, here, so every path below (whoami
  # and the explicit walk alike) works on a real target; anything that is not a
  # handle passes through untouched, so `@382` / `3` / a name keep working.
  if [ "${#WIDS[@]}" -gt 0 ]; then
    _norm=(); for _w in "${WIDS[@]}"; do _norm+=("$(fleet_wid_target "$_w" "$SOCK")"); done
    WIDS=("${_norm[@]}")
  fi
  TM() { tmux -L "$SOCK" "$@"; }
  # Sanctioned keystrokes (issue #437): the ONLY keys ever typed are Escape + `/exit`
  # + Enter, and only while a Claude process is verified alive under the pane (the
  # relaunch line, when no hook closes the window, is typed only after it is gone).
  SK() { FLEET_ALLOW_SENDKEYS=1 tmux -L "$SOCK" send-keys "$@"; }

  say() { printf '%s\n' "$*"; }
  now() { date +%s; }

  # --- account truth -------------------------------------------------------------
  # label ↔ token sha map, built once (the token FILES are the pool; sha so the
  # secret never sits in a variable longer than needed).
  # (bash 3.2 on macOS: no associative arrays → one "sha<TAB>label" line per account)
  SHA2LABEL=""
  for f in "$ACCT_DIR"/*; do
    [ -f "$f" ] || continue
    l=${f##*/}; case "$l" in .*|*~|*.conf) continue;; esac
    s=$(sed -n '1{s/[[:space:]]*$//;p;}' "$f" | tr -d '\n' | fleet_sha12)
    [ -n "$s" ] && SHA2LABEL="${SHA2LABEL}${s}"$'\t'"${l}"$'\n'
  done
  ACTIVE=$("$BIN/fleet-account.sh" active 2>/dev/null)
  ACTIVE_BENCHED=0; [ -n "$ACTIVE" ] && acct_benched "$ACTIVE" && ACTIVE_BENCHED=1   # ⇒ no account is eligible (#567)

  moved=0; skipped=0; REPORT=""
  # --- whoami -----------------------------------------------------------------------
  if [ "$MODE" = whoami ]; then
    for wid in "${WIDS[@]}"; do
      cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || { echo "$wid: no Claude process" >&2; continue; }
      stamp=$(TM display-message -p -t "$wid" '#{@cc_account}' 2>/dev/null)
      printf '%s\n' "$(window_account "$wid" "$cpid" "$stamp")"
    done
    return 0
  fi

  # --- candidate walk ----------------------------------------------------------------
  [ -n "$MODE" ] || MODE=explicit
  targets=()
  if [ "$MODE" = explicit ]; then
    targets=("${WIDS[@]}")
  else
    # window ids only from list-windows (one per line, always printable); the
    # rest per field via wopt — see the escaping note in migrate_one.
    while IFS= read -r wid; do
      [ -n "$wid" ] || continue
      name=$(wopt "$wid" '#{window_name}'); state=$(wopt "$wid" '#{@claude_state}'); acct=$(wopt "$wid" '#{@cc_account}')
      printf '%s' "$name" | grep -qE "$PANEL_RE" && continue
      cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || continue
      [ -n "$cpid" ] || continue
      label=$(window_account "$wid" "$cpid" "$acct")
      benched=0; [ -n "$label" ] && acct_benched "$label" && benched=1
      migrate_selected "$MODE" "$label" "${state:--}" "$ACTIVE" "$benched" "$ACCOUNT" || continue
      targets+=("$wid")
    done < <(TM list-windows -t "$SESS" -F '#{window_id}' 2>/dev/null)
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    say "fleet-migrate: nothing to move ($MODE)"
    return 0
  fi
  say "fleet-migrate: $MODE → ${ACTIVE:-<no active account>} (${#targets[@]} window$([ "${#targets[@]}" = 1 ] || printf s))"
  for wid in "${targets[@]}"; do
    cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || { say "  – $wid: no Claude process — skipped"; skipped=$((skipped+1)); continue; }
    stamp=$(TM display-message -p -t "$wid" '#{@cc_account}' 2>/dev/null)
    label=$(window_account "$wid" "$cpid" "$stamp")
    migrate_one "$wid" "$cpid" "$label"
  done
  say "fleet-migrate: moved $moved, skipped $skipped"
  if [ "$TOAST" = 1 ] && [ "$moved" -gt 0 ]; then
    TM display-message "fleet: moved $moved session$([ "$moved" = 1 ] || printf s) onto ${ACTIVE:-the active account} ($REPORT)" 2>/dev/null || :
  fi
  return 0
}
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then migrate_main "$@"; exit $?; fi
