#!/bin/bash
# fleet-restore.sh — crash-safe recovery for the fleet.
#
# The tmux server is a single point of failure: if it dies (crash, a stray
# kill-server/killall, a terminal teardown) every Claude session in every fleet
# dies with it, and bringing them back is a manual slog — fleet-up each fleet,
# reopen each work window, `claude --resume <id>` each session by hand.
#
# This turns that into one command by continuously SNAPSHOTTING the live layout
# (which fleets, which work windows, which worktree, which Claude session id) to
# a DURABLE map, then RESTORING from it — rebuilding each fleet's hub via
# fleet-up.sh and reopening each work window with `claude --resume` so the
# conversation comes back with full context.
#
# Modes:
#   --snapshot        record the current live layout to the durable map (cheap;
#                     the collector calls this every cycle). No tmux changes.
#   (no args)         restore: for every mapped fleet not currently live, rebuild
#                     it and resume its work windows. Idempotent — a fleet that is
#                     already up is left untouched.
#   --dry-run         print what restore WOULD do; change nothing.
#   --if-down         restore ONLY if the tmux server is entirely absent AND
#                     auto-restore is armed. This is what the launchd watcher runs,
#                     so it never fights a healthy server or a deliberate shutdown.
#   --arm / --disarm  enable/disable --if-down auto-restore (boot + crash watcher).
#
# The map lives under $FLEET_CONF_DIR/restore/ (durable across reboots, unlike the
# $TMPDIR dash cache). One <session>.map per fleet so a fleet-down drops its own.
# See docs/ARCHITECTURE.md.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

RDIR="$FLEET_CONF_DIR/restore"
ARM="$RDIR/autorestore.on"
LOG="${FLEET_RESTORE_LOG:-$RDIR/restore.log}"
# window names that are fleet UI panels (rebuilt by fleet-up/steward-session),
# NOT Claude work sessions — never snapshotted or restored as sessions.
PANEL_RE='^(plan|dash|backlog)$'

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
say() { [ -n "${QUIET:-}" ] || echo "$*"; }

# ---------------------------------------------------------------- snapshot ----
# Write one $RDIR/<session>.map per live fleet:
#   FLEET   <TAB> session <TAB> repo <TAB> main-checkout-dir <TAB> base-branch
#   WIN     <TAB> window-name <TAB> worktree-path <TAB> claude-session-id <TAB> issue
#                 <TAB> @claude_state <TAB> @prci <TAB> @pfg   (state trio: issue #153)
#   STEWARD <TAB> steward-pane-cwd <TAB> claude-session-id   (0 or 1 per fleet)
# claude-session-id = newest transcript for that worktree/pane ('-' if none).
# The STEWARD row (issue #143) captures the hub's persistent steward session,
# which lives in the 'plan' PANEL window (excluded from WIN rows) — so a crash
# can `claude --resume` the steward with its live history, like a worker.
snapshot() {
  # Liveness gate: is the tmux server up with at least one session to snapshot?
  # Use list-sessions, NOT `tmux info` — `info` reports the CURRENT CLIENT and
  # exits non-zero ("no current client") on some tmux builds (e.g. 3.4) when the
  # caller isn't an attached client. snapshot runs from the collector DAEMON,
  # which is never a client, so an `info` gate silently skipped every snapshot on
  # those builds (and whenever the fleet was detached) — nothing to restore after
  # a crash. list-sessions is client-independent: rc 0 iff a live server has ≥1
  # session (exactly the set we iterate below), rc 1 if the server is down.
  tmux list-sessions -F '#{session_name}' >/dev/null 2>&1 || return 0
  mkdir -p "$RDIR" || return 0
  local sess
  for sess in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    local repo main base conf tmp
    conf="$FLEET_CONF_DIR/$sess.conf"
    repo=""; main=""; base=""
    if [ -f "$conf" ]; then
      # shellcheck source=/dev/null
      repo=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
      # shellcheck source=/dev/null
      main=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
      # shellcheck source=/dev/null
      base=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_BASE_BRANCH:-}" )
    fi
    [ -z "$repo" ] && repo=$(fleet_repo_cached "$sess")
    [ -z "$repo" ] && repo=$(fleet_resolve_repo_for_session "$sess")
    repo=$(fleet_norm_repo "$repo")
    [ -z "$repo" ] && continue        # can't rebuild a fleet with no repo
    # main checkout: conf FLEET_MAIN, else a live window whose path basename ==
    # repo basename (the base checkout, not a worktree suffix), else skip.
    if [ -z "$main" ]; then
      local rb; rb=$(basename "$repo")
      main=$(tmux list-windows -t "$sess" -F '#{pane_current_path}' 2>/dev/null \
             | awk -v rb="$rb" 'NF && (($0 ~ ("/" rb "$"))) {print; exit}')
    fi
    [ -z "$base" ] && base="${FLEET_BASE_BRANCH:-}"

    tmp="$RDIR/.$sess.$$.map"
    printf 'FLEET\t%s\t%s\t%s\t%s\n' "$sess" "$repo" "$main" "$base" > "$tmp"
    # steward hub pane (issue #143): find it by its @steward=1 marker, NOT the
    # 'plan' window name (panels are excluded by the resolver). Emit it as a
    # __STEWARD__ sentinel row appended to the window list so BOTH resolve in a
    # SINGLE python3 pass → a STEWARD row + the per-window WIN rows, newest
    # transcript id resolved for each.
    #
    # Delimiter INSIDE tmux -F formats: a pipe '|', NOT a tab. tmux < 3.5
    # sanitizes CONTROL characters in format OUTPUT — a literal tab becomes '_'
    # and other controls become octal escapes (verified on 3.4) — which collapsed
    # every field so the resolver saw one column and emitted nothing (snapshot
    # recorded no windows at all on those builds). Only PRINTABLE delimiters
    # survive; '|' is passed through by every tmux, is a literal single-char awk
    # FS (no regex), keeps a space-bearing path in one field, and does not occur
    # in this fleet's window names / worktree paths / numeric issues. The MAP FILE
    # itself stays TAB-delimited — it's written by printf/python, never through
    # tmux, and read back with awk -F'\t'.
    local spath
    spath=$(tmux list-panes -s -t "$sess" -F '#{@steward}|#{pane_current_path}' 2>/dev/null \
            | awk -F'|' '$1=="1"{print $2; exit}')
    # Trailing @claude_state|@prci|@pfg (issue #153) are per-window runtime state.
    # restore() re-stamps @claude_state after resume — without it a restored worker
    # comes back with a blank state the attention layer reads as "stuck idle" — and
    # uses a 'working' snapshot to auto-continue a mid-turn session. @prci/@pfg are
    # carried for map completeness/forensics but NOT replayed on restore (the
    # pr-refresh daemon is their single writer). The __STEWARD__ row omits the trio
    # (it's the hub, not a work window); the resolver defaults the missing fields to '-'.
    { tmux list-windows -t "$sess" -F '#{window_name}|#{pane_current_path}|#{@issue}|#{@claude_state}|#{@prci}|#{@pfg}' 2>/dev/null
      [ -n "$spath" ] && printf '__STEWARD__|%s|-\n' "$spath"
    } | python3 "$BIN/.fleet-restore-resolve.py" >> "$tmp" 2>/dev/null
    mv "$tmp" "$RDIR/$sess.map" 2>/dev/null || rm -f "$tmp"
  done
  # NB: do NOT prune maps for absent sessions here. A CRASHED fleet's session is
  # gone but its map MUST survive so --if-down can rebuild it. fleet-down.sh is the
  # sole map remover (drops its own map on deliberate teardown). Pruning here
  # destroyed the recovery data on a partial crash: after the server came back with
  # only the surviving fleet, the next snapshot deleted the down fleet's map before
  # restore could use it.
}

# ----------------------------------------------------------------- restore ----
restore() {
  local dry="${1:-}"
  mkdir -p "$RDIR"
  local mf found=0
  for mf in "$RDIR"/*.map; do
    [ -f "$mf" ] || continue
    found=1
    local sess repo main base
    IFS=$'\t' read -r _ sess repo main base < <(awk -F'\t' '$1=="FLEET"{print;exit}' "$mf")
    [ -z "$sess" ] && continue
    if tmux has-session -t "$sess" 2>/dev/null; then
      say "· $sess already up — skipping"
      continue
    fi
    say "▸ restoring fleet $sess ($repo)"
    # steward resume id (issue #143): if snapshot captured the steward's
    # transcript, hand it to fleet-up → steward-session.sh via STEWARD_RESUME_ID
    # so the hub comes back with `claude --resume`, not a fresh session. Absent
    # id ('-'/missing) falls through to the fresh + newest-handoff path.
    local sid
    sid=$(awk -F'\t' '$1=="STEWARD"{print $3; exit}' "$mf")
    [ "$sid" = "-" ] && sid=""
    log "restore fleet $sess repo=$repo main=$main base=$base steward=${sid:-none} dry=${dry:-0}"
    if [ -n "$dry" ]; then
      say "    would: fleet-up.sh $repo ${main:-<clone>} --name $sess ${base:+--base $base}"
      [ -n "$sid" ] && say "    would: steward → claude --resume ${sid%%-*}…"
    else
      # rebuild hub + steward. fleet-up refuses if the session exists (it doesn't).
      local args; args=("$repo"); [ -n "$main" ] && args+=("$main")
      args+=(--name "$sess"); [ -n "$base" ] && args+=(--base "$base")
      [ -n "$sid" ] && say "    ↻ steward → claude --resume ${sid%%-*}…"
      env -u TMUX ${sid:+STEWARD_RESUME_ID="$sid"} bash "$BIN/fleet-up.sh" "${args[@]}" >>"$LOG" 2>&1 \
        || { say "    ✗ fleet-up failed for $sess (see $LOG)"; continue; }
    fi
    # reopen each work window, resuming its Claude session. @prci/@pfg (the last
    # two WIN-row fields) are intentionally discarded — they ride the map for
    # completeness but restore does not replay them (see the re-stamp note below).
    local wname wpath wid wissue wstate
    while IFS=$'\t' read -r _ wname wpath wid wissue wstate _ _; do
      [ -z "$wname" ] && continue
      echo "$wname" | grep -qE "$PANEL_RE" && continue
      if [ ! -d "$wpath" ]; then
        say "    ⚠ $wname: worktree gone ($wpath) — skipped"
        log "skip $sess/$wname worktree-missing $wpath"
        continue
      fi
      # Auto-continue a window that was mid-turn at crash (issue #153): a snapshot
      # state of 'working' means the turn was interrupted, and `claude --resume`
      # restores context but leaves the session idle at the prompt. Hand claude a
      # re-orient NUDGE as its initial prompt arg — the same delivery the spawner
      # uses for a fresh seed (`claude "<prompt>"`), so it submits as the next turn
      # once the transcript loads. This sidesteps the send-keys/bracketed-paste
      # boot-timing race of injecting after the TUI comes up. The nudge only makes
      # sense when we actually have a transcript to RESUME — a window with no
      # transcript comes back as a FRESH, context-less claude, and telling that
      # session it was "restored … continue the task" would have it act on a task
      # it never saw (spurious tool use), so the no-transcript branch never nudges.
      # Idle/done/needs windows were awaiting input anyway → parked (no nudge). The
      # wording is deliberately safe for a window whose Stop hook was merely MISSED
      # at crash (snapshotted 'working' but actually finished): it says re-check
      # FIRST and stop if the work is already done, so it never re-does shipped work.
      # Keep the nudge free of single-quotes/backticks — it's embedded single-quoted.
      local nudge=""
      [ "$wstate" = "working" ] \
        && nudge="The tmux server crashed and this session was restored via claude --resume, so its turn was interrupted. First re-check git status, your branch, and your open PR to see where you left off. If the work is already complete (PR open, nothing left to do), just stop. Otherwise, continue the task."
      # Route through fleet-claude.sh like the spawner (dash-issue-session.sh) so a
      # restored worker launches under the active subscription account (multi-account
      # failover) + the fleet's default model — a bare `claude` would strand it on
      # an exhausted account. Transparent `exec claude` when no accounts registered.
      local launch="'$BIN/fleet-claude.sh'"
      local cmd
      if [ -n "$wid" ] && [ "$wid" != "-" ]; then
        # `|| fleet-claude.sh` fallback (mirrors steward-session.sh): a stale/pruned
        # id makes `--resume` exit non-zero — fall back to a FRESH (parked, un-nudged)
        # session instead of stranding the pane at a bare shell.
        cmd="$launch --resume '$wid'${nudge:+ '$nudge'} || $launch; exec \$SHELL"
        say "    ↻ $wname → claude --resume ${wid%%-*}…${nudge:+ (auto-continue)}"
      else
        cmd="$launch; exec \$SHELL"
        say "    + $wname → fresh claude (no transcript found)"
      fi
      if [ -z "$dry" ]; then
        # Capture the new window-id and target every follow-up option-set through
        # it: window names aren't unique handles (title-slug collisions), so a
        # "$sess:$wname" target could hit the wrong window once two restored
        # windows share a name.
        local nw
        nw=$(tmux new-window -t "$sess:" -n "$wname" -c "$wpath" -P -F '#{window_id}' "$cmd" 2>/dev/null)
        [ -z "$nw" ] && nw="$sess:$wname"   # fall back to name if -P yielded nothing
        [ -n "$wissue" ] && [ "$wissue" != "-" ] \
          && tmux set-window-option -t "$nw" @issue "$wissue" 2>/dev/null
        # Re-stamp @claude_state so the dash reflects reality instead of a blank row
        # (issue #153) — the bug this fixes is a restored worker coming back with an
        # empty state that the attention layer reads as "stuck idle". Stamp a fresh
        # @claude_state_ts too so the classifier/issue-bridge idle-gate see a current
        # timestamp. This is a BOOTSTRAP value: a genuinely-working resumed session's
        # own hooks re-stamp it within seconds, and if a stale-id resume fell through
        # to a parked fresh claude, the spinner's stuck-working demote (keyed on tmux
        # #{window_activity} going stale, NOT on @claude_state_ts) flips it to done.
        #
        # @prci/@pfg are deliberately NOT re-stamped: the pr-refresh daemon is their
        # single writer (CLAUDE.md) and re-derives them within ~15s. Replaying the
        # snapshot-time glyph could show a stale 'CI green / open PR' after the PR
        # merged or went red mid-crash — misleading a /fleet-land — and a brief blank
        # until the daemon ticks is the safe failure mode. (They still ride the WIN
        # row for map completeness + forensics.)
        if [ -n "$wstate" ] && [ "$wstate" != "-" ]; then
          tmux set-window-option -t "$nw" @claude_state "$wstate" 2>/dev/null
          tmux set-window-option -t "$nw" @claude_state_ts "$(date +%s)" 2>/dev/null
        fi
      fi
    done < <(awk -F'\t' '$1=="WIN"' "$mf")
  done
  [ "$found" = 0 ] && say "no restore maps under $RDIR — nothing to restore"
  return 0
}

# ------------------------------------------------------------------- main -----
case "${1:-}" in
  --snapshot) snapshot ;;
  --arm)      mkdir -p "$RDIR"; : > "$ARM"; echo "fleet-restore: auto-restore ARMED ($ARM)";;
  --disarm)   rm -f "$ARM"; echo "fleet-restore: auto-restore DISARMED";;
  --dry-run)  restore dry ;;
  --if-down)
    # launchd watcher: restore any MAPPED fleet whose tmux session is absent —
    # even when another fleet survived. A partial crash keeps the server "up" but
    # still loses fleets, so gating on whole-server-absence (the old behaviour)
    # left the down fleet stranded. restore() skips fleets already up, so acting
    # whenever ANY mapped fleet is down is safe.
    [ -f "$ARM" ] || exit 0
    ifd_down=0
    for ifd_mf in "$RDIR"/*.map; do
      [ -f "$ifd_mf" ] || continue
      ifd_s=$(awk -F'\t' '$1=="FLEET"{print $2; exit}' "$ifd_mf")
      [ -n "$ifd_s" ] && ! tmux has-session -t "$ifd_s" 2>/dev/null && ifd_down=1
    done
    [ "$ifd_down" = 0 ] && exit 0
    # Disk-pressure circuit-breaker: if a fleet died because the volume filled,
    # rebuilding straight back into a full disk just re-crashes it — a restore ⇄
    # crash LOOP every StartInterval. Refuse until there's room.
    if [ -x "$BIN/fleet-diskguard.sh" ] && ! bash "$BIN/fleet-diskguard.sh" --gate 2>/dev/null; then
      log "mapped fleet down + armed BUT disk below floor → NOT restoring (would crash-loop); see fleet-diskguard --free"
      exit 0
    fi
    log "mapped fleet down + armed → auto-restore"
    QUIET=1 restore ;;
  ""|--restore) restore ;;
  *) echo "usage: fleet-restore.sh [--snapshot|--dry-run|--if-down|--arm|--disarm]" >&2; exit 2;;
esac
