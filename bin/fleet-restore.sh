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

# One directory per fleet (issue #181): each fleet's restore map lives at
# fleets/<sess>/restore.map. The global auto-restore ARM flag + log stay under the
# shared restore/ dir. each_restore_map() enumerates maps in BOTH layouts (new
# preferred) so recovery still works across the land→migrate window.
RDIR="$FLEET_CONF_DIR/restore"
ARM="$RDIR/autorestore.on"
LOG="${FLEET_RESTORE_LOG:-$RDIR/restore.log}"

# session → its restore map path for READING (new fleets/<sess>/restore.map if it
# exists, else the legacy restore/<sess>.map).
restore_map_file() {
  local new="$FLEET_CONF_DIR/fleets/$1/restore.map" old="$RDIR/$1.map"
  if [ -f "$new" ]; then printf '%s' "$new"; else printf '%s' "$old"; fi
}
# emit "<sess>\t<mapfile>" for every mapped fleet, new layout preferred, each once.
each_restore_map() {
  local d mf sess
  for d in "$FLEET_CONF_DIR"/fleets/*/; do
    [ -d "$d" ] || continue
    mf="${d}restore.map"; [ -f "$mf" ] || continue
    sess=${d%/}; sess=${sess##*/}
    fleet_is_pool_session "$sess" && continue      # a pool is not a fleet (#1020)
    printf '%s\t%s\n' "$sess" "$mf"
  done
  for mf in "$RDIR"/*.map; do
    [ -f "$mf" ] || continue
    sess=$(basename "$mf" .map)
    [ -f "$FLEET_CONF_DIR/fleets/$sess/restore.map" ] && continue
    fleet_is_pool_session "$sess" && continue
    printf '%s\t%s\n' "$sess" "$mf"
  done
}
# sweep_state_dirs — snapshot's own litter (issue #1020). A snapshot killed
# between writing .restore.<pid>.map and its mv (the collector's time budget, a
# reboot) leaks the temp for good: dozens piled up per fleet dir. Any older than
# FLEET_RESTORE_TMP_MAX_MIN minutes (default 30) is orphaned — a live snapshot
# holds its temp for seconds. And a warm-pool dir left by the pre-#1020 snapshot
# loses its map + temps, then the dir itself once empty (rmdir: never recursive,
# so anything else parked there survives).
sweep_state_dirs() {
  local d n
  for d in "$FLEET_CONF_DIR"/fleets/*/; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f -name '.restore.*.map' \
      -mmin +"${FLEET_RESTORE_TMP_MAX_MIN:-30}" -exec rm -f {} + 2>/dev/null
    n=${d%/}; n=${n##*/}
    fleet_is_pool_session "$n" || continue
    rm -f "${d}restore.map" "${d}.snapshot-rejects" "$d".restore.*.map 2>/dev/null
    rmdir "$d" 2>/dev/null && log "snapshot: removed warm-pool state dir $n (not a fleet, issue #1020)"
  done
  return 0
}

# window names that are fleet UI panels (rebuilt by fleet-up/hub-session),
# NOT Claude work sessions — never snapshotted or restored as sessions.
PANEL_RE='^(plan|dash|backlog)$'

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
say() { [ -n "${QUIET:-}" ] || echo "$*"; }

# ---------------------------------------------------------------- snapshot ----
# Write one $RDIR/<session>.map per live fleet:
#   FLEET   <TAB> session <TAB> repo <TAB> main-checkout-dir <TAB> base-branch
#   WIN     <TAB> window-name <TAB> worktree-path <TAB> claude-session-id <TAB> issue
#                 <TAB> @claude_state <TAB> @prci <TAB> @pfg   (state trio: issue #153)
#                 … <TAB> repo (column 16, issue #789: owner/name, `-` = a no-repo
#                 session; absent in a one-repo fleet's rows and in old maps)
#   HUB     <TAB> hub-pane-cwd <TAB> claude-session-id       (0 or 1 per fleet)
# claude-session-id = newest transcript for that worktree/pane ('-' if none).
# The HUB row (issue #143) captures the operator's persistent hub session,
# which lives in the 'plan' PANEL window (excluded from WIN rows) — so a crash
# can `claude --resume` the hub with its live history, like a worker.
snapshot() {
  # No single-server liveness gate anymore: each fleet has its OWN socket (issue
  # #159), so the loop below fans out over fleet_sockets (per-conf has-session,
  # which is client-independent — unlike `tmux info`, which reports the current
  # client and fails in the collector daemon). No live fleet → the loop is empty
  # and snapshot writes nothing, exactly the old return-early behaviour.
  mkdir -p "$RDIR" || return 0
  sweep_state_dirs
  # Each fleet runs on its OWN tmux server/socket now (issue #159), so there is no
  # single `tmux list-sessions` that sees them all — fan out over the live fleet
  # sockets and snapshot each one against its own `-L` socket.
  local sock sess
  for sock in $(fleet_sockets); do
  for sess in $(tmux -L "$sock" list-sessions -F '#{session_name}' 2>/dev/null); do
    # The warm pool's holding session shares this socket but is NOT a fleet
    # (issue #1020): snapshotting it minted fleets/<sess>-pool/ + a map that
    # --if-down saw as a fleet DOWN on every tick, and restore() would fleet-up it.
    fleet_is_pool_session "$sess" "$sock" && continue
    local repo main base conf tmp
    conf=$(fleet_conf_file "$sess")
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
      main=$(tmux -L "$sock" list-windows -t "$sess" -F '#{pane_current_path}' 2>/dev/null \
             | awk -v rb="$rb" 'NF && (($0 ~ ("/" rb "$"))) {print; exit}')
    fi
    [ -z "$base" ] && base="${FLEET_BASE_BRANCH:-}"

    local sdir; sdir="$(fleet_state_dir "$sess")"       # fleets/<sess>/ (issue #181)
    tmp="$sdir/.restore.$$.map"
    printf 'FLEET\t%s\t%s\t%s\t%s\n' "$sess" "$repo" "$main" "$base" > "$tmp"
    # operator hub pane (issue #143): find it by its @hub=1 marker, NOT the
    # 'plan' window name (panels are excluded by the resolver). Emit it as a
    # __HUB__ sentinel row appended to the window list so BOTH resolve in a
    # SINGLE python3 pass → a HUB row + the per-window WIN rows, newest
    # transcript id resolved for each.
    #
    # Since the hub went DASH-ONLY nothing sets @hub automatically, so this
    # normally finds no pane, emits no __HUB__ row, and the map carries no HUB
    # row — the capture self-disables rather than needing a flag. It still fires
    # for a pane an operator marked @hub by hand, which is the only case where a
    # hub transcript exists to be worth preserving. The RESUME side is gone
    # regardless (see restore() below): hub-session.sh no longer accepts
    # HUB_RESUME_ID, because a dash-only hub has no session to resume.
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
    spath=$(tmux -L "$sock" list-panes -s -t "$sess" -F '#{@hub}|#{pane_current_path}' 2>/dev/null \
            | awk -F'|' '$1=="1"{print $2; exit}')
    # Trailing @claude_state|@prci|@pfg (issue #153) are per-window runtime state.
    # restore() re-stamps @claude_state after resume — without it a restored worker
    # comes back with a blank state the attention layer reads as "stuck idle" — and
    # uses a 'working' snapshot to auto-continue a mid-turn session. @prci/@pfg are
    # carried for map completeness/forensics but NOT replayed on restore (the
    # pr-refresh daemon is their single writer). The __HUB__ row omits the trio
    # (it's the hub, not a work window); the resolver defaults the missing fields to '-'.
    # Raw scratch windows have independent worktrees (#290/#680). Prefer their
    # stamped @worktree over a wandered cwd; give the resolver THIS fleet's base
    # so legacy shared-base raw windows stay excluded. The map appends @raw at
    # column 14, after provider/home/transcript and handoff_manifest (column 13).
    # Leading field (issue #789): the window's repo — `@repo` in a fleet hosting 2+
    # repos, `norepo:<sid>` for a no-repo session, empty otherwise, so a one-repo
    # fleet's WIN rows stay byte-identical (the resolver writes column 16 only when
    # it is non-empty). An unstamped window in a 2+ repo fleet gets it derived once
    # through fleet_window_repo, which stamps it, before the list is read.
    local rfmt='' _w
    if _fleet_hosts_many "$sess"; then
      rfmt='#{@repo}'
      for _w in $(tmux -L "$sock" list-windows -t "$sess" -F '#{?@repo,,#{?@norepo,,#{window_id}}}' 2>/dev/null); do
        TMUX='' fleet_window_repo "$sess" "$_w" >/dev/null
      done
    fi
    { tmux -L "$sock" list-windows -t "$sess" -F "#{?@norepo,norepo:#{@norepo_sid},$rfmt}|"'#{window_name}|#{?@raw,#{?@worktree,#{@worktree},#{pane_current_path}},#{pane_current_path}}|#{@issue}|#{@claude_state}|#{@prci}|#{@pfg}|#{@raw}|#{@origin}|#{@cc_agent}|#{@cc_launcher_pid}|#{@handoff_manifest}|#{?@worker_lifecycle,#{@sleep_record},}|#{@codex_identity}' 2>/dev/null
      [ -n "$spath" ] && printf '|__HUB__|%s|-\n' "$spath"
    } | python3 "$BIN/.fleet-restore-resolve.py" "$main" --lead >> "$tmp" 2>/dev/null
    # Destructive-shrink guard (issue #160): a fleet caught MID-RESTORE is
    # hub-only — fleet-up has rebuilt its panels but restore hasn't reopened the
    # work windows yet — so a snapshot taken in that window has FEWER WIN rows
    # than the durable map and would blow the recovery data (the claude --resume
    # ids) away before restore can use it. Only overwrite when the live snapshot
    # has at least as many WIN rows as the stored map; otherwise the live layout
    # is suspect, so keep the richer prior map.
    #
    # But row COUNT alone froze maps for good (issue #504): a fleet that
    # permanently shrank (workers landed, windows closed) never "grows back to
    # its prior size", so every later snapshot was rejected — for a week, one
    # silent log line per cycle — and a real crash would have restored a set of
    # long-dead windows while losing every live one. Two staleness escapes:
    #
    #   1) DEAD-ROW: compare against only the stored WIN rows whose worktree
    #      still EXISTS. Mid-restore rows have live worktrees, so #160's
    #      protection is intact; a row whose worktree is gone is dead weight
    #      (restore skips it anyway) and must not block the overwrite.
    #   2) AGE: a mid-restore lasts minutes; a map not successfully rewritten
    #      for FLEET_RESTORE_STALE_MAP_AGE seconds (default 1 day) is stale,
    #      not mid-restore — accept the live layout as truth. This also covers
    #      windows closed on purpose whose worktrees were kept.
    #
    # A rejection that survives both escapes is COUNTED (consecutive, reset on
    # any successful write); at FLEET_RESTORE_REJECT_ALARM rejects (default 20
    # ≈ 20min at the collector's 60s tick) it logs an ALARM line and fires the
    # best-effort FLEET_NOTIFY_CMD — so a frozen map is seen in minutes, long
    # before the age escape would overwrite anything.
    local dest="$sdir/restore.map"
    local rejf="$sdir/.snapshot-rejects"
    # shrink guard compares against whichever map currently holds recovery data —
    # the new-layout map, or a not-yet-migrated legacy one (issue #181).
    local prior; prior=$(restore_map_file "$sess")
    if [ -f "$prior" ]; then
      local new_wins old_wins
      new_wins=$(awk -F'\t' '$1=="WIN"' "$tmp"   2>/dev/null | wc -l | tr -d ' ')
      old_wins=$(awk -F'\t' '$1=="WIN"' "$prior" 2>/dev/null | wc -l | tr -d ' ')
      if [ "${new_wins:-0}" -lt "${old_wins:-0}" ]; then
        local live_old
        live_old=$(awk -F'\t' '$1=="WIN"{print $3}' "$prior" 2>/dev/null \
                   | { n=0; while IFS= read -r _wt; do [ -n "$_wt" ] && [ -d "$_wt" ] && n=$((n+1)); done; printf '%s' "$n"; })
        # mtime probe: GNU first (-c %Y), BSD/macOS fallback (-f %m). NEVER the
        # other way round — GNU `stat -f %m` SUCCEEDS and prints the MOUNT POINT,
        # and a non-numeric operand aborts the non-interactive shell at $((…)).
        # The numeric case guard is the belt to that braces.
        local max_age="${FLEET_RESTORE_STALE_MAP_AGE:-86400}" age=-1 pmt
        pmt=$(stat -c %Y "$prior" 2>/dev/null || stat -f %m "$prior" 2>/dev/null)
        case "$pmt" in (''|*[!0-9]*) pmt='';; esac
        [ -n "$pmt" ] && age=$(( $(date +%s) - pmt ))
        if [ "${new_wins:-0}" -ge "${live_old:-0}" ]; then
          log "snapshot $sess: accepting shrink ${old_wins}→${new_wins} WIN rows — only ${live_old} stored rows still have a worktree (dead rows, issue #504)"
        elif [ "$age" -ge "$max_age" ]; then
          log "snapshot $sess: accepting shrink ${old_wins}→${new_wins} WIN rows — stored map ${age}s old > ${max_age}s, stale not mid-restore (issue #504)"
        else
          local rejects; rejects=$(cat "$rejf" 2>/dev/null)
          case "$rejects" in (''|*[!0-9]*) rejects=0;; esac
          rejects=$((rejects + 1))
          printf '%s\n' "$rejects" > "$rejf" 2>/dev/null || true
          log "snapshot $sess: live has ${new_wins:-0} WIN rows < stored ${old_wins:-0} — keeping richer map (mid-restore?; reject #$rejects)"
          if [ "$rejects" = "${FLEET_RESTORE_REJECT_ALARM:-20}" ]; then
            log "snapshot $sess: ALARM — $rejects consecutive snapshots rejected; restore.map may be frozen at a stale layout (issue #504)"
            if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
              "$FLEET_NOTIFY_CMD" "# ⚠ fleet restore.map frozen: $sess
$rejects consecutive snapshots rejected by the shrink guard — the durable recovery map may be stuck at a stale layout (issue #504). See $LOG." >/dev/null 2>&1 || true
            fi
          fi
          rm -f "$tmp"
          continue
        fi
      fi
    fi
    # Drop the stale legacy map ONLY when the new one actually landed — a failed mv
    # (ENOSPC/read-only/EXDEV) must NOT leave the fleet with no recovery map at all.
    if mv "$tmp" "$dest" 2>/dev/null; then
      rm -f "$rejf" 2>/dev/null || true      # successful write breaks the reject streak
      [ "$dest" = "$RDIR/$sess.map" ] || rm -f "$RDIR/$sess.map" 2>/dev/null || true
    else
      rm -f "$tmp"
    fi
  done
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
  local found=0 _msess mf
  while IFS=$'\t' read -r _msess mf; do
    [ -f "$mf" ] || continue
    found=1
    local sess repo main base
    IFS=$'\t' read -r _ sess repo main base < <(awk -F'\t' '$1=="FLEET"{print;exit}' "$mf")
    [ -z "$sess" ] && continue
    # Reconcile, don't skip (issue #160): a fleet whose session `has-session`
    # reports as up may still be HUB-ONLY — a prior restore rebuilt its hub but
    # never reopened the work windows (e.g. fleet-up ran, restore was interrupted,
    # or the hub was brought up by hand). Treating any live session as fully
    # restored stranded those windows. So when the session is live we skip only
    # the hub REBUILD and still reconcile the work windows below,
    # reopening any mapped WIN whose window isn't currently present.
    local sock; sock=$(fleet_socket "$sess")   # this fleet's own socket (== session, issue #159)
    local live=0 livewins="" livewt=""
    if tmux -L "$sock" has-session -t "$sess" 2>/dev/null; then
      live=1
      livewins=$(tmux -L "$sock" list-windows -t "$sess" -F '#{window_name}' 2>/dev/null)
      livewt=$(tmux -L "$sock" list-windows -t "$sess" -F '#{window_name}|#{?@worktree,#{@worktree},#{pane_current_path}}' 2>/dev/null)
      say "▸ reconciling fleet $sess ($repo) — already up, checking for missing work windows"
    else
      say "▸ restoring fleet $sess ($repo)"
    fi
    # NO hub resume (was issue #143). The hub is DASH-ONLY: it has no Claude
    # session, so there is nothing to bring back with `claude --resume` and
    # hub-session.sh no longer accepts HUB_RESUME_ID. A HUB row left in an OLD
    # map by a pre-change snapshot is simply ignored — restoring a fleet rebuilds
    # the dash and stops there, instead of silently re-spawning the hub Claude an
    # operator had closed on purpose.
    log "restore fleet $sess repo=$repo main=$main base=$base live=$live dry=${dry:-0}"
    if [ "$live" = 0 ]; then
      if [ -n "$dry" ]; then
        say "    would: fleet-up.sh $repo ${main:-<clone>} --name $sess ${base:+--base $base}"
      else
        # rebuild the hub (dash only). fleet-up refuses if the session exists (it doesn't).
        local args; args=("$repo"); [ -n "$main" ] && args+=("$main")
        args+=(--name "$sess"); [ -n "$base" ] && args+=(--base "$base")
        env -u TMUX bash "$BIN/fleet-up.sh" "${args[@]}" >>"$LOG" 2>&1 \
          || { say "    ✗ fleet-up failed for $sess (see $LOG)"; continue; }
      fi
    fi
    # reopen each MISSING work window, resuming its Claude session. @prci/@pfg
    # (the last two WIN-row fields) are intentionally discarded — they ride the
    # map for completeness but restore does not replay them (see the re-stamp
    # note below). `reopened` tracks whether the reconcile path (issue #160)
    # actually had a window to reopen, for the "fully up" note after the loop.
    local wname wpath wid wissue wstate wagent whome wmanifest wraw wsleep wrepo reopened=0 multi=0
    _fleet_hosts_many "$sess" && multi=1
    while IFS=$'\t' read -r _ wname wpath wid wissue wstate _ _ worigin wagent whome _ wmanifest wraw wsleep wrepo; do
      [ -z "$wname" ] && continue
      # A no-repo session (issue #789) lives in $HOME, not a worktree: its transcript
      # belongs to $HOME's project dir, so it resumes there whatever its cwd was.
      [ "${wrepo:-}" = - ] && wpath="$HOME"
      echo "$wname" | grep -qE "$PANEL_RE" && continue
      # reconcile path: a window with this name is already live — don't duplicate.
      # In a fleet hosting 2+ repos (issue #789) a name is not an identity — A#12
      # and B#12 are both `issue-12` — so a live window counts only when it also
      # sits in this row's worktree.
      if [ "$multi" = 1 ]; then
        [ -n "$livewins" ] && printf '%s\n' "$livewt" | grep -qxF "$wname|$wpath" && continue
      elif [ -n "$livewins" ] && printf '%s\n' "$livewins" | grep -qxF "$wname"; then
        continue
      fi
      if [ ! -d "$wpath" ]; then
        say "    ⚠ $wname: worktree gone ($wpath) — skipped"
        log "skip $sess/$wname worktree-missing $wpath"
        continue
      fi
      reopened=1
      # Auto-continue a window that was mid-turn at crash (issue #153): a snapshot
      # state of 'working' means the turn was interrupted, and `claude --resume`
      # restores context but leaves the session idle at the prompt. Hand claude a
      # re-orient NUDGE as its initial prompt arg — the same delivery the spawner
      # uses for a fresh seed (`claude "<prompt>"`), so it submits as the next turn
      # once the transcript loads. This sidesteps the send-keys/bracketed-paste
      # boot-timing race of injecting after the TUI comes up. (So fleet-restore
      # uses NO `tmux send-keys` at all — it needs no FLEET_ALLOW_SENDKEYS hatch
      # for the issue-#437 rail, and must NOT export one: a restored worker would
      # inherit it and forfeit its own shell-guard send-keys belt.) The nudge only makes
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
        && nudge="The tmux server crashed and this session was restored via claude --resume, so its turn was interrupted. First re-check git status, your branch, and your open PR to see where you left off. If the work is already complete (PR open, nothing left to do), just stop. Otherwise, continue the task.${FLEET_LANG_RULE_RESUME:+ $FLEET_LANG_RULE_RESUME}"
      # Route through fleet-claude.sh like the spawner (dash-issue-session.sh) so a
      # restored worker launches under the active subscription account (multi-account
      # failover) + the fleet's default model — a bare `claude` would strand it on
      # an exhausted account. Transparent `exec claude` when no accounts registered.
      local launch="'$BIN/fleet-claude.sh'"
      local cmd
      local agent_label=claude resume_flag=--resume home_arg
      if [ "$wagent" = codex ]; then
        launch="$launch --agent codex"
        if [ -n "$whome" ] && [ "$whome" != '-' ]; then
          printf -v home_arg '%q' "$whome"
          launch="$launch --codex-home $home_arg"
        fi
        agent_label=codex; resume_flag=resume
        nudge=${nudge/claude --resume/codex resume}
      fi
      if [ -n "$wid" ] && [ "$wid" != "-" ]; then
        # `|| fleet-claude.sh` fallback (mirrors hub-session.sh): a stale/pruned
        # id makes `--resume` exit non-zero — fall back to a FRESH (parked, un-nudged)
        # session instead of stranding the pane at a bare shell.
        cmd="$launch $resume_flag '$wid'${nudge:+ '$nudge'} || $launch; exec \$SHELL"
        say "    ↻ $wname → $agent_label $resume_flag ${wid%%-*}…${nudge:+ (auto-continue)}"
      else
        cmd="$launch; exec \$SHELL"
        say "    + $wname → fresh $agent_label (no transcript found)"
      fi
      if [ -n "$wsleep" ] && [ "$wsleep" != - ]; then
        cmd='exec "$SHELL"'
        say "    z $wname → retained sleeping worker"
      fi
      # The window stamps its repo identity BEFORE its launcher reads the conf (issue
      # #789): a no-repo session anywhere; in a 2+ repo fleet @worktree (+ @repo when
      # the row carries it — an old row's repo is derived from @worktree by
      # fleet_window_repo). A one-repo fleet's command is unchanged.
      local stamp=''
      if [ "${wrepo:-}" = - ]; then
        stamp=$(fleet_win_stamp_cmd @norepo 1)
        [ -n "$wid" ] && [ "$wid" != - ] && stamp="$stamp$(fleet_win_stamp_cmd @norepo_sid "$wid")"
      elif [ "$multi" = 1 ]; then
        stamp=$(fleet_win_stamp_cmd @worktree "$wpath")
        [ -n "${wrepo:-}" ] && stamp="$stamp$(fleet_win_stamp_cmd @repo "$wrepo")"
      fi
      cmd="$stamp$cmd"
      if [ -z "$dry" ]; then
        # Capture the new window-id and target every follow-up option-set through
        # it: window names aren't unique handles (title-slug collisions), so a
        # "$sess:$wname" target could hit the wrong window once two restored
        # windows share a name. -L "$sock": each fleet is its own server (#159).
        local nw
        nw=$(tmux -L "$sock" new-window -t "$sess:" -n "$wname" -c "$wpath" -P -F '#{window_id}' "$cmd" 2>/dev/null)
        [ -z "$nw" ] && nw="$sess:$wname"   # fall back to name if -P yielded nothing
        if [ -n "$wsleep" ] && [ "$wsleep" != - ]; then
          tmux -L "$sock" set-option -w -t "$nw" @worktree "$wpath"
          tmux -L "$sock" set-option -w -t "$nw" @cc_agent "${wagent:-claude}"
          if [ "$wraw" = 1 ]; then tmux -L "$sock" set-option -w -t "$nw" @raw 1
          else tmux -L "$sock" set-option -w -t "$nw" @issue "$wissue"; fi
          python3 "$BIN/fleet-sleep.py" restore --session "$sess" "$nw" --record "$wsleep" || {
            tmux -L "$sock" set-option -w -t "$nw" @worker_lifecycle failed
            say "    ⚠ sleep restore failed; record retained: $wsleep"
          }
        fi

        [ -n "$wissue" ] && [ "$wissue" != "-" ] \
          && tmux -L "$sock" set-window-option -t "$nw" @issue "$wissue" 2>/dev/null
        # Re-stamp the spawn provenance too (issue #503) so a crash-restored
        # worker keeps its dash grouping; old maps (pre-#503, 8-field WIN rows)
        # leave $worigin empty → nothing stamped, exactly as before.
        [ -n "${worigin:-}" ] && [ "$worigin" != "-" ] \
          && tmux -L "$sock" set-window-option -t "$nw" @origin "$worigin" 2>/dev/null
        if [ "$wraw" = 1 ]; then
          tmux -L "$sock" set-window-option -t "$nw" @raw 1 2>/dev/null
          tmux -L "$sock" set-window-option -t "$nw" @worktree "$wpath" 2>/dev/null
        fi
        if [ -n "$wmanifest" ] && [ "$wmanifest" != '-' ] && [ -f "$wmanifest" ]; then
          tmux -L "$sock" set-option -w -t "$nw" @handoff_manifest "$wmanifest" 2>/dev/null
          tmux -L "$sock" set-option -w -t "$nw" @worktree "$wpath" 2>/dev/null
          tmux -L "$sock" set-option -w -t "$nw" @cc_agent "${wagent:-claude}" 2>/dev/null
        fi
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
        # merged or went red mid-crash — misleading your review — and a brief blank
        # until the daemon ticks is the safe failure mode. (They still ride the WIN
        # row for map completeness + forensics.)
        # The repo (issue #789), re-stamped from outside too — the self-stamp above
        # is the launch-time half; this one holds when the window command is a shell.
        if [ "${wrepo:-}" = - ]; then
          tmux -L "$sock" set-window-option -t "$nw" @norepo 1 2>/dev/null
          [ -n "$wid" ] && [ "$wid" != - ] && tmux -L "$sock" set-window-option -t "$nw" @norepo_sid "$wid" 2>/dev/null
        elif [ -n "${wrepo:-}" ]; then
          tmux -L "$sock" set-window-option -t "$nw" @repo "$wrepo" 2>/dev/null
        fi
        [ "$multi" = 1 ] && [ "${wrepo:-}" != - ] \
          && tmux -L "$sock" set-window-option -t "$nw" @worktree "$wpath" 2>/dev/null
        if [ -n "$wstate" ] && [ "$wstate" != "-" ]; then
          tmux -L "$sock" set-window-option -t "$nw" @claude_state "$wstate" 2>/dev/null
          tmux -L "$sock" set-window-option -t "$nw" @claude_state_ts "$(date +%s)" 2>/dev/null
        fi
      fi
    done < <(awk -F'\t' '$1=="WIN"' "$mf")
    [ "$live" = 1 ] && [ "$reopened" = 0 ] && say "· $sess fully up — no missing work windows"
  done < <(each_restore_map)
  [ "$found" = 0 ] && say "no restore maps under $FLEET_CONF_DIR/fleets/*/ — nothing to restore"
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
    while IFS=$'\t' read -r _ifd_s ifd_mf; do
      [ -f "$ifd_mf" ] || continue
      ifd_s=$(awk -F'\t' '$1=="FLEET"{print $2; exit}' "$ifd_mf")
      # -L "$(fleet_socket "$ifd_s")": each fleet is its own server now (issue #159)
      [ -n "$ifd_s" ] && ! tmux -L "$(fleet_socket "$ifd_s")" has-session -t "$ifd_s" 2>/dev/null && ifd_down=1
    done < <(each_restore_map)
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
