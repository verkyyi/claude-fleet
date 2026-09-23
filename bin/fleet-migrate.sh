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
#   fleet-migrate.sh [opts] --stuck             every window whose quota failover request
#                                               is STUCK (@quota_stuck=1: the same veto
#                                               FLEET_FAILOVER_STUCK_ATTEMPTS times, #872)
#   fleet-migrate.sh whoami [<window>]          print the account a window really runs
#                                               (token truth; re-stamps a stale @cc_account).
#                                               NO window ⇒ the CALLER'S OWN pane (#703)
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
#         --force-bg          move even though the session owns background/tool
#                             processes (issue #873 — the dash's migrate key): they are
#                             inventoried BEFORE /exit, stopped after Claude is gone
#                             (start-fingerprint checked, SIGTERM then SIGKILL) and
#                             named in the resume nudge — the same helpers as the
#                             planner's hard-wall grace (#871). Without it the move
#                             does not look at background work at all (the historic
#                             behaviour). --dry-run lists what it would stop.
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
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"          # fleet_limit_banner — the wall this move leaves behind (#870)

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
# migrate_selected <mode> <label> <state> <active> <benched> <wanted> [<stuck>] → 0 iff selected
migrate_selected() {
  local mode="$1" label="$2" state="$3" active="$4" benched="$5" wanted="$6"
  case "$mode" in
    limited) [ -n "$label" ] && [ "$benched" = 1 ] ;;
    idle)    case "$state" in done|needs) [ "$label" != "$active" ] ;; *) return 1 ;; esac ;;
    all)     [ "$label" != "$active" ] ;;
    account) [ -n "$label" ] && [ "$label" = "$wanted" ] ;;
    stuck)   [ "${7:-}" = 1 ] ;;
    explicit) return 0 ;;
    *) return 1 ;;
  esac
}

# --- background work (--force-bg, issue #873) -----------------------------------
# One inventory of "what this move will terminate" (EPIC #875 contract 3): the
# planner's own walk (.fleet-failover.py → fleet-sleep's quiet_processes), so the
# popup, this move and the hard-wall grace can never disagree about what counts.
FAILOVER_PY="${FLEET_MIGRATE_FAILOVER_PY:-$BIN/.fleet-failover.py}"
BG_WHY='The operator forced this move with a background override (fleet-migrate --force-bg)'
# bg_inventory <claude-pid> <worktree> → the JSON list on stdout; exit 1 + why on stderr
bg_inventory() {
  FLEET_SLEEP_MCP_RESTARTABLE="${FLEET_SLEEP_MCP_RESTARTABLE:-}" \
    python3 "$FAILOVER_PY" background --pid "$1" --worktree "$2" --session "${SESS:-}"
}
# bg_lines <json> → one `  pid  argv  (cwd)` line per entry (for the plan + popup)
bg_lines() {
  printf '%s' "$1" | python3 -c 'import json,shlex,sys
for e in json.load(sys.stdin): print("      %s  %s  (cwd %s)" % (e["pid"], shlex.join(e.get("argv") or ["?"]), e.get("cwd") or "?"))'
}
# bg_count <json> → number of entries (0 on anything unreadable)
bg_count() { printf '%s' "$1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0; }

# --- the move -------------------------------------------------------------------

# Release a rotation lease if one was taken (issue #550). Never fails a migrate:
# a lease that outlives its move expires on its own, it just costs the janitor a
# cycle of caution in the meantime.
lease_drop() { [ -n "${1:-}" ] && fleet_rotate_lease_drop "$1"; return 0; }

# migrated_stamp <window> <wall> — when this window last received a moved session
# (@migrated_at, epoch; the dash can mark "just migrated") and the wall that
# session left behind (@migrated_banner — fleet_banner_replayed, issue #870). An
# empty wall UNSETS the stamp: a window reused by the no-hook branch must not keep
# an older move's banner.
migrated_stamp() {
  TM set-window-option -t "$1" @migrated_at "$(now)" 2>/dev/null
  if [ -n "$2" ]; then TM set-window-option -t "$1" @migrated_banner "$2" 2>/dev/null
  else TM set-window-option -t "$1" -u @migrated_banner 2>/dev/null; fi
  return 0
}

# reported_restore <window> <prior> — put back the @reported a window carried
# BEFORE this move stamped its own suppression (issue #936). @reported means one
# thing: "this session's outcome has reached its parent". The move's `1` is only
# a pre-exit mute for the SessionEnd backstop, so every path that leaves a window
# alive — the resumed one, or an old one left as is after a failed exit — hands
# back the prior value: a delivered MERGED stays delivered (no late "stopped"
# duplicate after the move), an unreported session still owes its report.
reported_restore() {
  if [ "${2:-}" = 1 ]; then TM set-window-option -t "$1" @reported 1 2>/dev/null
  else TM set-window-option -t "$1" -u @reported 2>/dev/null; fi
  return 0
}

migrate_one() {
  local lockdir rc
  lockdir=$(wopt "$1" '#{@worktree}')
  if [ -n "$lockdir" ] && [ -d "$lockdir" ]; then
    if ! fleet_transition_lock_take "$lockdir"; then
      say "  – $1: another transition owns this worktree — skipped"; skipped=$((skipped+1)); return 0
    fi
    FLEET_MIGRATION_LOCKED="$lockdir"
  fi
  migrate_one_body "$@"; rc=$?
  [ -z "${FLEET_MIGRATION_LOCKED:-}" ] || fleet_transition_lock_drop "$FLEET_MIGRATION_LOCKED"
  FLEET_MIGRATION_LOCKED=''
  return "$rc"
}

migrate_one_body() {
  local wid="$1" cpid="$2" label="$3" name cwd state raw iss wt origin hnd wrepo norepo nsid
  # One display-message per field — NOT a joined format split on a control byte:
  # tmux ≤3.4 prints a 0x1f in format output as the literal text `\037` (vis
  # escaping; 3.7 emits the byte), so a separator-based parse is not portable.
  name=$(wopt "$wid" '#{window_name}') || return 1
  cwd=$(wopt "$wid" '#{pane_current_path}'); state=$(wopt "$wid" '#{@claude_state}')
  raw=$(wopt "$wid" '#{@raw}'); iss=$(wopt "$wid" '#{@issue}'); wt=$(wopt "$wid" '#{@worktree}')
  origin=$(wopt "$wid" '#{@origin}')
  # The window's repo identity (issue #789) rides the move like @issue/@worktree: a
  # new window without it would load the fleet's default repo, or lose the no-repo
  # mark that keeps every reaper off a $HOME session.
  wrepo=$(wopt "$wid" '#{@repo}'); norepo=$(wopt "$wid" '#{@norepo}'); nsid=$(wopt "$wid" '#{@norepo_sid}')
  hnd=$(wopt "$wid" '#{@wid}')      # the fleet's short window handle (issue #566)
  local sid; sid=$(session_id_for "$cpid" "$cwd") || sid=""
  # A multi-repo fleet has one base checkout per hosted repo (issue #791): a raw
  # pane sitting in ANY of them is the "main-cwd" case, not only the conf repo's.
  local wmain="${FLEET_MAIN:-}"
  fleet_has_repo_overlays "$SESS" && wmain=$(fleet_repo_mains "$SESS" | grep -Fx -- "${cwd%/}" | head -n 1)
  if ! migrate_eligible "$name" "$(TM display-message -p -t "$wid" '#{@hub}' 2>/dev/null)" "$raw" "$cwd" "$wmain" "$sid"; then
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
  # --force-bg (issue #873): inventory the background work NOW, while Claude is
  # alive and still its parent — after /exit the survivors are PPID-1 orphans no
  # walk from this pid can find.
  local bgjson="" bgerr="" bgdir=""
  if [ "$FORCE_BG" = 1 ]; then
    bgjson=$(bg_inventory "$cpid" "${wt:-$cwd}" 2>"$MIGRATE_TMP/bg.err") \
      || { bgerr=$(tail -1 "$MIGRATE_TMP/bg.err" 2>/dev/null); bgjson=""; }
    [ "$(bg_count "$bgjson")" -gt 0 ] || bgjson=""
  fi
  if [ "$DRY" = 1 ]; then
    say "  ↻ $name ($wid) [${label:-?} → ${ACTIVE:-?}${MODEL:+ on $MODEL}] would /exit pid $cpid and resume ${sid%%-*}… in $cwd${nudge:+ (nudged)}"
    if [ "$FORCE_BG" = 1 ]; then
      if [ -n "$bgerr" ]; then say "    ! background inventory failed: ${bgerr#fleet-failover: } — whatever it owns is stopped UNLISTED"
      elif [ -n "$bgjson" ]; then say "    would stop $(bg_count "$bgjson") background command(s):"; bg_lines "$bgjson"
      else say "    no background commands to stop"; fi
    fi
    return 0
  fi
  if [ -n "$bgjson" ]; then
    bgdir="$MIGRATE_TMP/bg-${wid//[^A-Za-z0-9]/_}"; mkdir -p "$bgdir"
    printf '%s' "$bgjson" > "$bgdir/background.json"
  fi
  # A migrate is a CLOSE + RESUME, not a death: mark the window as already reported
  # (issue #574) so the SessionEnd hook's child-report backstop does not tell this
  # session's PARENT that its child was reaped — seconds before the same session
  # comes back in a new window. The resumed session reports for real when it ships,
  # and the new window below gets back the window's OWN prior value (issue #936):
  # read here, before the stamp overwrites it.
  local prior_reported; prior_reported=$(wopt "$wid" '#{@reported}')
  TM set-window-option -t "$wid" @reported 1 2>/dev/null
  # …and the same "not a death" fact, stated to the REAPERS (issue #550). From here
  # until the new window is bound, this worktree has no window and no @issue
  # binding, which is indistinguishable from a finished worker to anything that
  # scans on a timer: the worktree janitor ran inside one of these gaps on
  # 2026-09-11 and swept all 15 processes of a live worker. The lease says the gap
  # is deliberate; it is TTL-bounded, so a migrate that dies here cannot park the
  # worktree forever. Dropped on EVERY exit path below, including the failures.
  local ldir=""
  case "$wt" in ?*) ldir="$wt" ;; *) [ -n "$cwd" ] && [ "$cwd" != "${FLEET_MAIN:-}" ] && ldir="$cwd" ;; esac
  [ -n "$ldir" ] && fleet_rotate_lease_take "$ldir" "migrate $name ($wid)"
  # The wall this session is leaving (issue #870), read BEFORE it exits: the
  # resumed process re-renders its transcript tail — this very banner — onto the
  # new pane, where the collector would credit it to the NEW account and bench it.
  # Stamped on the new window below, before the resume can render anything. The
  # WHOLE history (-S -): with the classic line scrolled out, a 200-line capture
  # finds only the live-only sticky footer, while the replay renders the classic
  # line — and fleet_limit_banner prefers the newest classic line when there is one.
  local wall; wall=$(TM capture-pane -p -S - -t "$wid" 2>/dev/null | fleet_limit_banner)
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
    lease_drop "$ldir"; reported_restore "$wid" "$prior_reported"; say "  ✗ $name ($wid): Claude (pid $cpid) did not exit within ${EXIT_WAIT}s — left as is"; skipped=$((skipped+1)); return 0
  fi
  # --force-bg: Claude is verified gone — stop what it left running (only a pid
  # whose start fingerprint still matches; a reused pid is never touched) and
  # fold the note naming each command into the resume nudge (#871's helper).
  local bgnote=""
  if [ -n "$bgdir" ]; then
    bgnote=$(python3 "$FAILOVER_PY" terminate-background "$bgdir" --note "$BG_WHY" 2>/dev/null)
    say "  ⏹ $name ($wid): stopped $(bg_count "$bgjson") background command(s):"; bg_lines "$bgjson"
  elif [ -n "$bgerr" ]; then
    say "  ! $name ($wid): background inventory failed (${bgerr#fleet-failover: }) — nothing recorded"
    bgnote="Background commands this session was running may have been stopped by the move; the inventory failed, so check for any you started."
  fi
  if [ -n "$bgnote" ]; then
    # ONE line: the no-hook branch TYPES the command, and a newline would press Enter
    bgnote=$(printf '%s' "$bgnote" | tr '\n' ' ' | tr -s ' ')
    [ -n "$nudge" ] || nudge="The operator moved this session to another subscription account (a forced fleet migrate) and resumed it via claude --resume in a new tmux window. Re-check git status, your branch, and your open PR before continuing.${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"
    nudge="$nudge ${bgnote# }"
  fi
  nudge=$(printf '%s' "$nudge" | tr -d "'\`")             # embedded single-quoted below
  # --model rides BEFORE --resume (and on the fresh-launch fallback too) so
  # fleet-claude.sh sees an explicit model and skips its FLEET_MODEL default.
  local mflag=""; [ -n "$MODEL" ] && mflag=" --model '$MODEL'"
  local cmd="'$LAUNCH'$mflag --resume '$sid'${nudge:+ '$nudge'} || '$LAUNCH'$mflag; exec \$SHELL"
  # 3. the SessionEnd hook closes the window (and records the ledger row) …
  for ((i=1; i<=CLOSE_WAIT; i++)); do
    window_closed "$wid" && break
    sleep 1
  done
  local nw
  if ! window_closed "$wid"; then
    # … or it doesn't (FLEET_CLOSE_ON_EXIT=0): Claude is verified gone, the pane is
    # at its `exec $SHELL` — relaunch right there, keeping the window.
    fleet_pane_claude_pid "$wid" "$SOCK" >/dev/null 2>&1 && { lease_drop "$ldir"; reported_restore "$wid" "$prior_reported"; say "  ✗ $name ($wid): a Claude is back under the pane — not typing"; skipped=$((skipped+1)); return 0; }
    TM clear-history -t "$wid" 2>/dev/null || :     # drop the old limit banner (stale-banner cascade guard)
    migrated_stamp "$wid" "$wall"
    SK -t "$wid" -l "$cmd" 2>/dev/null; SK -t "$wid" Enter 2>/dev/null
    nw="$wid"
  else
    # A window object can outlive its last pane for a few seconds (the pane died
    # before the hook's detached kill-window ran); reap the pane-less ghost so the
    # dash never shows it — nothing runs in it, so this is not a destructive kill.
    TM display-message -p -t "$wid" '' >/dev/null 2>&1 && TM kill-window -t "$wid" 2>/dev/null
    # 4. a NEW window, same name + cwd, resumed under the active account.
    local stamp=''
    [ -n "$wrepo" ] && _fleet_hosts_many "$SESS" && stamp=$(fleet_win_stamp_cmd @repo "$wrepo")
    [ "$norepo" = 1 ] && stamp=$(fleet_win_stamp_cmd @norepo 1 ${nsid:+@norepo_sid "$nsid"})
    nw=$(TM new-window -d -t "$SESS:" -n "$name" -c "$cwd" -P -F '#{window_id}' "$stamp$cmd" 2>/dev/null)
    # Stamped first thing (issue #870): a cold `claude --resume` takes seconds to
    # render the old wall, this takes one tmux call.
    [ -n "$nw" ] && migrated_stamp "$nw" "$wall"
    [ -n "$nw" ] || { lease_drop "$ldir"; say "  ✗ $name ($wid): new-window failed — session ${sid%%-*}… is closed but NOT resumed (resume by hand: cd $cwd && claude --resume $sid)"; skipped=$((skipped+1)); return 0; }
    [ -n "$iss" ] && TM set-window-option -t "$nw" @issue "$iss" 2>/dev/null
    [ "$raw" = 1 ] && TM set-window-option -t "$nw" @raw 1 2>/dev/null
    [ -n "$wt" ] && TM set-window-option -t "$nw" @worktree "$wt" 2>/dev/null
    [ -n "$origin" ] && TM set-window-option -t "$nw" @origin "$origin" 2>/dev/null
    [ -n "$wrepo" ] && TM set-window-option -t "$nw" @repo "$wrepo" 2>/dev/null
    if [ "$norepo" = 1 ]; then
      TM set-window-option -t "$nw" @norepo 1 2>/dev/null
      [ -n "$nsid" ] && TM set-window-option -t "$nw" @norepo_sid "$nsid" 2>/dev/null
    fi
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
  # The window exists and carries @issue/@worktree again — the gap is over, so the
  # reapers get their normal signals back (issue #550). Dropped BEFORE the boot
  # verification below: that loop waits up to BOOT_WAIT seconds on a window whose
  # bindings are already in place, and a lease held across it would only delay the
  # janitor for no further protection.
  lease_drop "$ldir"
  # …and lift the pre-exit suppression back to the window's own value (issue #936):
  # a session that had NOT reported still owes its parent one — and (on the
  # CLOSE_ON_EXIT=0 branch) $nw IS the window that carries it — while one whose
  # MERGED/FAILED already reached the parent must not send a late "stopped".
  reported_restore "$nw" "$prior_reported"
  # 5. verify: the resumed process's token, read out of its environment.
  local ncp="" nl=""
  for ((i=1; i<=BOOT_WAIT; i++)); do
    ncp=$(fleet_pane_claude_pid "$nw" "$SOCK" 2>/dev/null) && [ -n "$ncp" ] && break
    sleep 1
  done
  [ -n "$ncp" ] && nl=$(acct_of_pid "$ncp")
  # The resumed process has rendered (or is rendering) its replay by now: drop
  # the scrollback so the old wall is not carried in history (issue #870). The
  # VISIBLE copy stays until the next redraw re-renders it — @migrated_banner
  # above is what keeps that one from benching anyone.
  [ -n "$ncp" ] && TM clear-history -t "$nw" 2>/dev/null
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
  MODE=""; ACCOUNT=""; NUDGE=""; NUDGE_SET=0; DRY=0; TOAST=0; SESS=""; MODEL=""; WIDS=(); FORCE_BG=0
  local pinned_target='' quota_request='' verified=0
  FLEET_MIGRATION_LOCKED=''
  MIGRATE_TMP=''
  trap '[ -z "${FLEET_MIGRATION_LOCKED:-}" ] || fleet_transition_lock_drop "$FLEET_MIGRATION_LOCKED"; [ -z "${MIGRATE_TMP:-}" ] || rm -rf "$MIGRATE_TMP"' EXIT
  while [ $# -gt 0 ]; do
    case "$1" in
      --limited|--idle|--all|--stuck) MODE="${1#--}"; shift ;;
      --force-bg) FORCE_BG=1; shift ;;
      --account) MODE=account; ACCOUNT="${2:-}"; shift 2 ;;
      --account=*) MODE=account; ACCOUNT="${1#--account=}"; shift ;;
      --session) SESS="${2:-}"; shift 2 ;;
      --session=*) SESS="${1#--session=}"; shift ;;
      --target-file) pinned_target="${2:-}"; shift 2 ;;
      --quota-request) quota_request="${2:-}"; shift 2 ;;
      --nudge) NUDGE="${2:-}"; NUDGE_SET=1; shift 2 ;;
      --nudge=*) NUDGE="${1#--nudge=}"; NUDGE_SET=1; shift ;;
      --model) MODEL="${2:-}"; shift 2 ;;
      --model=*) MODEL="${1#--model=}"; shift ;;
      --dry-run) DRY=1; shift ;;
      --toast) TOAST=1; shift ;;
      whoami) MODE=whoami; shift ;;
      --verified) verified=1; shift ;;
      -h|--help) sed -n '2,59p' "$0"; return 0 ;;
      --*) echo "fleet-migrate: unknown option '$1'" >&2; return 2 ;;
      *) WIDS+=("$1"); shift ;;
    esac
  done
  [ -n "$MODE" ] || [ "${#WIDS[@]}" -gt 0 ] || { sed -n '30,59p' "$0" >&2; return 2; }
  [ "$MODE" = account ] && [ -z "$ACCOUNT" ] && { echo "fleet-migrate: --account needs a label" >&2; return 2; }
  MODEL=$(printf '%s' "$MODEL" | LC_ALL=C tr -cd 'A-Za-z0-9._-')   # embedded single-quoted in the launch line

  [ -n "$SESS" ] || SESS=$(fleet_current_session)
  [ -n "$SESS" ] || { echo "fleet-migrate: no tmux session (pass --session <fleet>)" >&2; return 2; }
  fleet_load_conf "$SESS" 2>/dev/null || :
  # The quota planner pins ONE account for ONE exact session. Use the existing
  # transfer transaction for its locks, packet, draft and loop, while retaining
  # Claude's native --resume UUID (the legacy bulk mover below stays compatible).
  if [ -n "$pinned_target" ]; then
    [ "${#WIDS[@]}" = 1 ] && [ -n "$quota_request" ] || { echo 'fleet-migrate: pinned target needs one window and a quota request' >&2; return 2; }
    exec bash "$BIN/fleet-transfer.sh" --session "$SESS" --window "${WIDS[0]}" --to claude \
      --target-file "$pinned_target" --quota-request "$quota_request" --native-resume
  fi
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
    _norm=(); for _w in ${WIDS[@]+"${WIDS[@]}"}; do _norm+=("$(fleet_wid_target "$_w" "$SOCK")"); done
    WIDS=(${_norm[@]+"${_norm[@]}"})
  fi
  TM() { tmux -L "$SOCK" "$@"; }
  # Sanctioned keystrokes (issue #437): the ONLY keys ever typed are Escape + `/exit`
  # + Enter, and only while a Claude process is verified alive under the pane (the
  # relaunch line, when no hook closes the window, is typed only after it is gone).
  SK() { FLEET_ALLOW_SENDKEYS=1 tmux -L "$SOCK" send-keys "$@"; }

  say() { printf '%s\n' "$*"; LAST_SAY="$*"; }
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
  MIGRATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-migrate.XXXXXX") || return 1
  # --- whoami -----------------------------------------------------------------------
  if [ "$MODE" = whoami ]; then
    # No window given ⇒ the CALLER'S OWN pane (issue #703). `whoami` answers exactly
    # one question — "which account is THIS session on" — the one an operator asks
    # either side of a rotation; the fleet-wide table is `fleet-account.sh quota`'s
    # job, and the name would not survive meaning both. Only ever defaults to self
    # when the resolved fleet IS the caller's own: pane ids are per-SERVER, so
    # honouring $TMUX_PANE against another fleet's socket would answer confidently
    # about the wrong window. With no "me" to report — a daemon, a plain shell, a
    # --session pointing elsewhere — say so and exit 2. NEVER print nothing: the
    # silent empty is what this issue was, once the crash is gone.
    if [ "${#WIDS[@]}" -eq 0 ]; then
      # $TMUX_PANE, not tmux's idea of "current": with TMUX set but TMUX_PANE
      # empty, a bare `display-message` answers for whatever window the attached
      # CLIENT is looking at — a confident answer about someone else's session.
      _self=""
      [ -n "${TMUX_PANE:-}" ] && [ "$(fleet_current_session)" = "$SESS" ] \
        && _self=$(TM display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
      [ -n "$_self" ] || {
        echo "fleet-migrate: whoami has no window to report on — run it inside $SESS, or name one: whoami <window>" >&2
        return 2
      }
      WIDS=("$_self")
    fi
    for wid in ${WIDS[@]+"${WIDS[@]}"}; do
      cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || { echo "$wid: no Claude process" >&2; continue; }
      stamp=$(TM display-message -p -t "$wid" '#{@cc_account}' 2>/dev/null)
      if [ "$verified" = 1 ]; then
        truth=$(acct_of_pid "$cpid")
        [ -n "$truth" ] || return 1
        printf '%s\n' "$truth"
      else
        printf '%s\n' "$(window_account "$wid" "$cpid" "$stamp")"
      fi
    done
    return 0
  fi

  # --- candidate walk ----------------------------------------------------------------
  [ -n "$MODE" ] || MODE=explicit
  targets=()
  if [ "$MODE" = explicit ]; then
    targets=(${WIDS[@]+"${WIDS[@]}"})
  else
    # window ids only from list-windows (one per line, always printable); the
    # rest per field via wopt — see the escaping note in migrate_one.
    while IFS= read -r wid; do
      [ -n "$wid" ] || continue
      name=$(wopt "$wid" '#{window_name}'); state=$(wopt "$wid" '#{@claude_state}'); acct=$(wopt "$wid" '#{@cc_account}')
      stuck=$(wopt "$wid" '#{@quota_stuck}')
      printf '%s' "$name" | grep -qE "$PANEL_RE" && continue
      cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || continue
      [ -n "$cpid" ] || continue
      label=$(window_account "$wid" "$cpid" "$acct")
      benched=0; [ -n "$label" ] && acct_benched "$label" && benched=1
      migrate_selected "$MODE" "$label" "${state:--}" "$ACTIVE" "$benched" "$ACCOUNT" "$stuck" || continue
      targets+=("$wid")
    done < <(TM list-windows -t "$SESS" -F '#{window_id}' 2>/dev/null)
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    say "fleet-migrate: nothing to move ($MODE)"
    return 0
  fi
  say "fleet-migrate: $MODE → ${ACTIVE:-<no active account>} (${#targets[@]} window$([ "${#targets[@]}" = 1 ] || printf s))"
  for wid in ${targets[@]+"${targets[@]}"}; do
    cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || { say "  – $wid: no Claude process — skipped"; skipped=$((skipped+1)); continue; }
    stamp=$(TM display-message -p -t "$wid" '#{@cc_account}' 2>/dev/null)
    label=$(window_account "$wid" "$cpid" "$stamp")
    migrate_one "$wid" "$cpid" "$label"
  done
  LAST_SKIP="${LAST_SAY:-}"; LAST_SKIP="${LAST_SKIP#*: }"
  say "fleet-migrate: moved $moved, skipped $skipped"
  if [ "$TOAST" = 1 ] && [ "$moved" -gt 0 ]; then
    TM display-message "fleet: moved $moved session$([ "$moved" = 1 ] || printf s) onto ${ACTIVE:-the active account} ($REPORT)" 2>/dev/null || :
  elif [ "$TOAST" = 1 ] && [ "$skipped" -gt 0 ]; then
    # The dash key runs this detached (#873): a move that did not happen must still
    # say so, or the keypress looks dead.
    TM display-message "fleet: migrate moved nothing ($skipped skipped: ${LAST_SKIP:-see fleet-account.sh migrate --dry-run})" 2>/dev/null || :
  fi
  return 0
}
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then migrate_main "$@"; exit $?; fi
