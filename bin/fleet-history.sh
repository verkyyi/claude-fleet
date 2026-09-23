#!/bin/bash
# fleet-history.sh — the closed-session history ledger + its reader/actions.
#
# When the cleanup daemon (bin/fleet-cleanup.sh) reaps a merged worker's PR it removes the
# `issue-<N>` worktree and kills the window — but the worker's Claude transcript
# SURVIVES cleanup under ~/.claude/projects/<encoded-cwd>/<session>.jsonl. This
# tool indexes that survivor at land time (`record`) and surfaces it afterward:
# list closed sessions (`list`/`rows`), and RESUME one by reconstructing the
# removed worktree off the squash SHA (`resume`). See issue #130.
#
# WHAT gets indexed: every closed session in the fleet — issue-bound WORKERS and
# @raw SCRATCH sessions alike (issue #466). A scratch has no GitHub issue, so ledger
# column 2 is a KEY, not an issue number: `<N>` for a worker, `scratch-<N>` for a
# scratch (fleet_scratch_key). Everything downstream — list/rows/resume/path/meta —
# keys off that column, so a scratch row browses and RESUMES exactly like a worker
# row; the renderers print `#<N>` vs `~<N>` so the two kinds stay tellable apart.
#
# Two ways a session enters the ledger (the `state` column, #320, tells them apart):
#   * landed          — recorded on the LAND path (`record`, driven by fleet-cleanup.sh)
#                       when a merged PR is reaped: carries mergedAt/pr/sha.
#   * closed-unlanded — recorded by the ledger-watch daemon (`record-closed`,
#                       bin/fleet-ledger-watch.sh) when a worker window VANISHES
#                       without landing (closed by hand, crashed, abandoned): no
#                       mergedAt/pr/sha — its worktree usually still exists on disk
#                       (worktree-autoclean keeps unmerged), so it stays resumable.
# This closes the gap where a hand-closed / crashed worker left its transcript
# unindexed (invisible to /fleet-history, not resumable).
#
# Single-writer: BOTH writers serialize per repo (the cleanup daemon's own lease,
# the ledger-watch daemon's own lease) and `record-closed` is idempotent (it
# dedups on session-id / transcript-dir), so a session is recorded at most once —
# a landed row is never shadowed by a later closed-unlanded row for the same
# session. The ledger is append-only and tolerant of missing fields (a row
# degrades to '-' rather than being dropped) — a closed session should always be
# listable even if its PR metadata or transcript can't be resolved.
#
# Subcommands:
#   record  --repo R --main M --pr N --key K --worktree W [--win ID] [--session S] [--summary S] [--title T]
#           Append one LANDED ledger row. Derives title/sha/mergedAt from `gh pr
#           view` (--title is a fallback for when the PR doesn't resolve), and
#           transcript-dir + session-id from the worktree path. Run it
#           BEFORE `git worktree remove` in the cleanup teardown step.
#   record-closed --repo R --key K --worktree W [--win ID] [--session S] [--title T] [--summary S] [--sha SHA]
#           Append a landed-less CLOSED-UNLANDED row (mergedAt→now, pr='-'). Records
#           the worktree's HEAD sha so the row stays RESUMABLE even after a later
#           reap removes that worktree (issue #466) — resume rebuilds it off the sha.
#           Idempotent: a no-op if a row already exists for this session-id /
#           transcript-dir (so the daemon can call it every tick, and it never
#           shadows a landed row). A window with no resolvable transcript (a Codex
#           worker that never took a turn; a Claude one without a transcript) is recorded with
#           '-' for transcript/session — review-only, deduped on key + worktree/sha.
#           Resolves transcript-dir + session-id + summary the
#           same way `record` does.
#   list    [--repo R] [filter]      Human table, newest first (optional substring filter).
#   rows                             Dash US-delimited rows (closed view of the dashboard).
#           NESTED like the live list: ledger col 11 is the spawning session, so a
#           child renders under its parent (`↳` tag + `└` indent) and the parent
#           carries a `<landed>/<total> ✓` tally for the block. Blocks are FOLDED by
#           default — see `fold`.
#   fold    <expand|collapse> <landed:… target>
#           The landed view's ←/→. Prints fzf ACTIONS (nothing = a dead keystroke);
#           bin/dash-fold-toggle.sh delegates every `landed:*` target here. The live
#           dash keeps its fold bit on the tmux window (@expand); a landed row has
#           none, so the expanded set is one per-fleet file the dash clears at every
#           (re)launch.
#   resume  --repo R --main M <key|#pr>     Reconstruct the worktree off the SHA and
#           print how to resume (RESUME/CODEX-RESUME/FROM-PR/REVIEW-ONLY); --exec recreates the worktree.
#           Reuses an already-present worktree (skips the slow `git worktree add`, #319) —
#           which is also how a closed-unlanded row (no SHA) resumes: its worktree
#           is usually still on disk (worktree-autoclean keeps unmerged), #320.
#   path    <key|#pr>                Print "<transcript-dir>\t<session-id>" for a ledger row.
#   meta    <key|#pr>                Print "<key>\t<title>" for a ledger row — lets the
#           restorer name the resumed window from the title + bind @issue (#319).
# <key> is an issue number (a worker) or a `scratch-<N>` slug (a scratch, #466).
# `--key` is the flag name for it; `--issue` remains accepted as its alias so an
# older/live install's call sites keep working across a partial sync.
#
# Shell-options policy: this is EXECUTED (not sourced), so `set -uo pipefail` is fine.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# fleet-lib gives fleet_slug / fleet_repo_cached / fleet_load_conf; sourced
# best-effort (record/list work without it as long as --repo is passed).
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
# Global fleet.conf gives a single-fleet FLEET_REPO fallback (the dash rows
# producer execs into us WITHOUT exporting it — see cmd_rows). Multi-fleet still
# resolves per-session via the sessmap / per-session conf below.
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf" 2>/dev/null || true


# --- ledger location: per-fleet (a fleet ≡ a repo), durable across reboots -----
# ~/.claude/fleet/logs survives a TMPDIR wipe; keyed by repo slug so two fleets
# on one machine don't share a ledger. Override the whole path for tests.
ledger_path() {
  local repo="${1:-}"
  if [ -n "${FLEET_HISTORY_LEDGER:-}" ]; then printf '%s' "$FLEET_HISTORY_LEDGER"; return; fi
  local slug; slug=$(fleet_slug "$repo" 2>/dev/null)
  [ -z "$slug" ] && slug="default"
  printf '%s' "$HOME/.claude/fleet/logs/landed_${slug}.tsv"
}

# strip TAB/CR/LF so a free-text field can't break the TSV row layout.
oneline() { printf '%s' "${1:-}" | tr '\t\r\n' '   ' ; }

# ledger key (col 2) → the label the renderers and log lines print: `#<N>` for a
# worker row, `~<N>` for a scratch one (issue #466). `~` is the one-glyph tell that
# a row has no GitHub issue behind it, and it keeps the SAME width as `#<N>` — so
# the dash's 5-wide key column and the CLI list stay aligned for either kind.
key_label() {
  case "${1:-}" in
    scratch-*) printf '~%s' "${1#scratch-}" ;;
    *)         printf '#%s' "${1:-}" ;;
  esac
}
# is this ledger key a scratch (@raw) session rather than an issue-bound worker?
is_scratch_key() { case "${1:-}" in scratch-*) return 0 ;; *) return 1 ;; esac; }

# ledger key (col 2) → the @origin spelling of the SAME session. The two columns
# disagree on purpose and always have: col 2 holds a BARE issue number (`231`)
# while col 11 — the spawning session, #503 — holds the window-key form
# (`issue-231`), because that is what the tmux window option carries. Every
# parent/child lookup below crosses that boundary, so it crosses it here, once.
# A scratch key is already in window-key form (`scratch-5`) and passes through.
lkey_okey() { case "${1:-}" in scratch-*) printf '%s' "$1" ;; *) printf 'issue-%s' "${1:-}" ;; esac; }

# the dash row target for a ledger row — what ⌃o / Enter hand to
# dash-restore-session.sh, and what the fold below matches a keystroke against.
# A scratch row is addressed by its own key (#466) even when it escalated into a
# PR, so the restorer knows to rebuild an @raw window rather than bind a
# nonexistent @issue.
landed_target() { # <ledger key> <pr>
  if is_scratch_key "$1"; then printf 'landed:scratch:%s' "$1"; return; fi
  case "${2:-}" in ''|-) printf 'landed:issue:%s' "$1" ;; *) printf 'landed:%s' "${2#\#}" ;; esac
}

# --- the landed view's fold state --------------------------------------------
# The live dash hangs its fold bit on the tmux WINDOW (`@expand`, #623's pattern:
# it dies with the window, nothing to clean up). A landed row has no window — that
# is what "landed" means — so this view keeps the expanded set in one per-fleet
# file, one ledger key per line, absent ⇒ folded (the same default-collapsed
# polarity). The dash DELETES it on every (re)launch, exactly as it resets
# dash_view_<session>, so the landed peek always opens folded and the file can
# never accumulate keys for sessions nobody will look at again.
landed_fold_file() {
  printf '%s/global/dash_fold_landed_%s%s' "${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}" "${FLEET_SESSION:-default}" \
    "${LANDED_FOLD_SLUG:+.$LANDED_FOLD_SLUG}"
}

# landed_scope <repo> — a fleet hosting 2+ repos (issue #790). One ledger is one
# repo's, so its keys never collide with each other; what crosses repos is the
# ORIGIN column, which a multi-repo spawn stamps as `<slug>:issue-<N>` (#789), and
# the per-fleet fold file, which two repos' `issue-12` rows would share. So: the
# fold file gets the repo's slug as a suffix, and landed_local_origins drops THIS
# ledger's own `<slug>:` from col 11 — a parent in the same repo then joins by the
# bare key it always has, and a parent in ANOTHER repo keeps its prefix, matches no
# row here, and renders as the ↳ tag of an orphan. A one-repo fleet: both empty.
LANDED_FOLD_SLUG=''
landed_scope() {
  LANDED_FOLD_SLUG=''
  [ -n "${FLEET_SESSION:-}" ] && command -v fleet_multirepo >/dev/null 2>&1 \
    && fleet_multirepo "$FLEET_SESSION" || return 0
  LANDED_FOLD_SLUG=$(fleet_slug "$(fleet_norm_repo "${1:-}")")
}
landed_local_origins() {
  if [ -z "$LANDED_FOLD_SLUG" ]; then cat; return; fi
  awk -F'\t' -v OFS='\t' -v p="$LANDED_FOLD_SLUG:" \
    'NF >= 11 && index($11, p) == 1 { $11 = substr($11, length(p) + 1) } { print }'
}
landed_is_open() { # <root key, @origin spelling> → 0 when its block is unfolded
  local f; f=$(landed_fold_file)
  [ -f "$f" ] || return 1
  grep -qxF -- "${1:-}" "$f" 2>/dev/null
}

# lchain <parent key> — walk up to the ultimate root PRESENT IN THIS VIEW, ≤4 hops
# (the live dash's own bound), so a grandchild both nests under and counts toward
# the same row. Reads the caller's `$lkeytab` (key → seq · origin) and sets
# $lroot/$lrootseq; $lroot EMPTY ⇒ the chain leaves this list — the parent is still
# live, or was never recorded — and that row is an ORPHAN, rendered top-level with
# its ↳ tag intact. Unlike the live dash an orphan is NOT sunk to the bottom here:
# this list is ordered by when a session FINISHED, and a row whose parent is missing
# finished when it finished.
lchain() { lroot=''; lrootseq=0
  local cur="$1" t m row rseq rorg hops=0
  t=$'\n'"${lkeytab:-}"
  while [ "$hops" -lt 4 ]; do
    m=${t#*$'\n'"$cur"$'\t'}
    [ "$m" = "$t" ] && return
    row=${m%%$'\n'*}
    rseq=${row%%$'\t'*}; rorg=${row#*$'\t'}
    case "$rorg" in
      issue-*|scratch-*) cur=$rorg; hops=$((hops+1)) ;;
      *) lroot=$cur; lrootseq=$rseq; return ;;
    esac
  done
}

# worktree path → transcript dir under ~/.claude/projects. The encoding rule
# lives in fleet_transcript_dir (bin/fleet-lib.sh) so this and bin/fleet-context.sh
# share ONE copy of it; the helper honours the same CLAUDE_PROJECTS_DIR override
# this script used to read directly.
transcript_dir_for() {
  fleet_transcript_dir "${1:-}"
}

# newest HUMAN *.jsonl session id in a transcript dir, skipping the fleet's own
# helper (classifier — and the retired summarizer's leftovers) transcripts. The logic — including the
# SIGPIPE-under-pipefail trap and the helper-rubric filter — moved to
# fleet_newest_human_session in fleet-lib.sh so worktree-autoclean.sh (the
# conversation-scratch keep gate) shares ONE copy of it; this local name stays for
# the call sites below (record / record-closed).
newest_session_in() {
  fleet_newest_human_session "${1:-}"
}

# Does the ledger already carry a row for this session? Dedup key: session-id
# (col 8) when known, else transcript-dir (col 7). Used to keep record-closed
# idempotent AND to stop a closed-unlanded row from shadowing an existing landed
# row for the same session (the land path recorded the SAME session-id, resolved
# from the same worktree). Returns 0 (true) when a matching row exists.
ledger_has_session() {   # $1=ledger $2=session-id $3=transcript-dir [$4=key $5=worktree $6=pr $7=sha]
  local ledger="$1" sid="$2" tdir="$3" key="${4:-}" wt="${5:-}" pr="${6:-}" sha="${7:-}"
  [ -f "$ledger" ] || return 1
  # Primary key: session-id, else transcript-dir. A reused scratch slot keeps
  # the SAME directory across DIFFERENT sessions (#543); a known id must never
  # fall through to the directory match and disappear behind an older row.
  #
  # FALLBACK for a TRANSCRIPT-LESS record (both of those land as '-'): the primary
  # key can then never match, so every retry appended ANOTHER row for the same
  # session — in the wild, two `scratch-1` rows identical but for sid/tdir, the
  # second recorded by a caller that passed no --worktree. Match instead on the
  # key PLUS one corroborating identity (pr / sha / worktree), and only against a
  # row that is itself transcript-less. Key alone would be wrong: a scratch slot is
  # reused, so `scratch-1` legitimately recurs. And a row we suppress here has no
  # transcript by definition — there is nothing in it to resume.
  awk -F'\t' -v s="$sid" -v t="$tdir" -v k="$key" -v w="$wt" -v p="$pr" -v h="$sha" '
    function blank(v) { return (v == "" || v == "-") }
    { if (!blank(s) && $8 == s) { found = 1; exit }
      if (blank(s) && !blank(t) && $7 == t) { found = 1; exit }
      if (blank(s) && blank(t) && !blank(k) && $2 == k && blank($8) && blank($7) &&
          ((!blank(p) && $4 == p) || (!blank(h) && $5 == h) || (!blank(w) && $6 == w))) {
        found = 1; exit } }
    END { exit(found ? 0 : 1) }' "$ledger"
}

# ============================================================================
# record — append one ledger row (run BEFORE worktree removal)
# ============================================================================
history_source() {
  # Output HIST_* fields; a captured daemon identity takes precedence over a
  # live window lookup because that window may already be gone or replaced.
  HIST_AGENT="${1:-}"; HIST_HOME=''; HIST_TDIR=''; HIST_SID=''; HIST_TRANSCRIPT=''
  local win="$2" sess="$3" wt="$4" record="$5" owner="$6" raw sock
  if [ -z "$HIST_AGENT" ] && [ -n "$win" ]; then
    if [ -n "$sess" ]; then
      sock=$(fleet_socket "$sess")
      raw=$(tmux -L "$sock" display-message -p -t "$win" '#{@cc_agent}|#{@cc_launcher_pid}|#{@codex_identity}' 2>/dev/null)
    elif [ -n "${TMUX:-}" ]; then
      raw=$(tmux display-message -p -t "$win" '#{@cc_agent}|#{@cc_launcher_pid}|#{@codex_identity}' 2>/dev/null)
    else raw=''; fi
    IFS='|' read -r HIST_AGENT owner record <<< "$raw"
  fi
  [ -n "$HIST_AGENT" ] || HIST_AGENT="${FLEET_AGENT:-claude}"
  if [ "$HIST_AGENT" = codex ]; then
    [ -n "$record" ] || record='{}'
    raw=$(python3 "$BIN/fleet-codex-session.py" saved --identity "$record" --owner "$owner" 2>/dev/null) || raw=''
    IFS=$'\t' read -r HIST_SID HIST_HOME HIST_TDIR HIST_TRANSCRIPT <<< "$raw"
  elif [ -n "$wt" ]; then
    HIST_TDIR=$(transcript_dir_for "$wt")
    HIST_SID=$(newest_session_in "$HIST_TDIR")
    [ -n "$HIST_SID" ] || HIST_TDIR=''
  fi
}

history_source_suffix() {
  # Keep old Claude rows byte-compatible. Only Codex needs the extra provider,
  # account-home and full-rollout fields (12–14); no credentials are stored.
  if [ "$HIST_AGENT" = codex ]; then
    printf '\tcodex\t%s\t%s' "$(oneline "${HIST_HOME:--}")" "$(oneline "${HIST_TRANSCRIPT:--}")"
  fi
  printf '\n'
}

cmd_record() {
  local repo="" main="" pr="" key="" wt="" summary="" mergedat="" sess="" title_fb="" origin="" win="" agent="" identity="" owner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2;;
      --main) main="${2:-}"; shift 2;;
      --pr) pr="${2:-}"; shift 2;;
      # col-2 key: an issue number (worker) or a scratch-<N> slug (#466). --issue
      # is the pre-#466 spelling, kept as an alias so a partially-synced install
      # (older caller + newer script, or the reverse) never silently drops a row.
      --key|--issue) key="${2:-}"; shift 2;;
      --worktree) wt="${2:-}"; shift 2;;
      --win) win="${2:-}"; shift 2;;
      --agent) agent="${2:-}"; shift 2;;
      --agent-identity) identity="${2:-}"; shift 2;;
      --launcher-pid) owner="${2:-}"; shift 2;;
      --session) sess="${2:-}"; shift 2;;
      --summary) summary="${2:-}"; shift 2;;
      # FALLBACK title only (e.g. the window name the SessionEnd hook passes): the
      # gh-resolved PR title below still wins — it names the landed work, the
      # window name merely labels where it ran.
      --title) title_fb="${2:-}"; shift 2;;
      --mergedat) mergedat="${2:-}"; shift 2;;
      # spawn provenance (issue #503): who spawned the session this row records —
      # issue-<N> | scratch-<N> | autofill | bridge; absent/empty ≡ hub.
      --origin) origin="${2:-}"; shift 2;;
      *) shift;;
    esac
  done
  # The dash-summary cache is keyed by <session>_<window-id> (issue #208), so a
  # --win lookup needs the fleet session. Default to the caller's fleet when the
  # (in-pane) caller didn't pass --session: land runs in the fleet whose window
  # we're recording, so both resolve to the same session.
  [ -z "$sess" ] && sess="${FLEET_SESSION:-$(fleet_current_session 2>/dev/null)}"
  [ -z "$key" ] && { echo "fleet-history record: --key is required" >&2; return 2; }

  # Derive PR metadata from GitHub (best-effort; tolerate a missing/removed PR).
  local title="" sha="" mergedat_gh=""
  if [ -n "$pr" ] && [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
    local meta; meta=$(gh pr view "$pr" --repo "$repo" \
      --json title,mergedAt,mergeCommit \
      -q '[.title, (.mergedAt//""), (.mergeCommit.oid//"")] | @tsv' 2>/dev/null)
    if [ -n "$meta" ]; then
      IFS=$'\t' read -r title mergedat_gh sha <<<"$meta"
      [ -z "$mergedat" ] && mergedat="$mergedat_gh"
    fi
  fi
  # mergedAt fallback: now (UTC). date is fine here — this is a shell tool.
  [ -z "$mergedat" ] && mergedat=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  # title fallback: gh's PR title won above when it resolved; else --title.
  [ -z "$title" ] && title="$title_fb"

  # transcript dir + session id from the (still-present) worktree path.
  local tdir="" sid=""
  history_source "$agent" "$win" "$sess" "$wt" "$identity" "$owner"
  tdir="$HIST_TDIR"; sid="$HIST_SID"

  # summary (col 9): only an explicit --summary lands here — the dash summary
  # cache it used to fall back to retired with the summary column (issue #535).

  local ledger; ledger=$(ledger_path "$repo")
  # Idempotent like record-closed (#384): record-before-remove now runs from TWO
  # reapers — fleet-cleanup.sh on the merged PR AND worktree-autoclean.sh on its
  # scan (both via fleet_reap_record) — so guard on the same session/transcript key
  # to avoid a duplicate landed row when both record the same reap, or when a reaper
  # retries after a failed `git worktree remove`. Same dedup key as ledger-watch's
  # record-closed, so a session is recorded at most once regardless of the reaper.
  if ledger_has_session "$ledger" "$sid" "$tdir" "$key" "$wt" "${pr:-}" "${sha:-}"; then
    printf 'landed %s → already in ledger (session %s) — skipped\n' "$(key_label "$key")" "${sid:-none}"
    return 0
  fi
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true

  # 11 columns: mergedAt·key·title·pr·sha·worktree·transcript-dir·session-id·summary·state·origin
  # state=landed here; the ledger-watch daemon writes closed-unlanded (#320). Col 1
  # is the merge time for a landed row / the close time for a closed-unlanded one.
  # Col 11 (issue #503) is the spawn provenance ('-' ≡ hub); pre-#503 rows have 10
  # columns and every reader tolerates the missing field as empty.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' \
    "$(oneline "$mergedat")" \
    "$(oneline "$key")" \
    "$(oneline "${title:--}")" \
    "$(oneline "${pr:--}")" \
    "$(oneline "${sha:--}")" \
    "$(oneline "${wt:--}")" \
    "$(oneline "${tdir:--}")" \
    "$(oneline "${sid:--}")" \
    "$(oneline "${summary:--}")" \
    "landed" \
    "$(oneline "${origin:--}")" "$(history_source_suffix)" >> "$ledger" || return 1
  printf 'landed %s → ledger %s (session %s)\n' "$(key_label "$key")" "$ledger" "${sid:-none}"
}

# ============================================================================
# record-closed — append a CLOSED-UNLANDED row (idempotent; #320)
# ============================================================================
# The ledger-watch daemon (and the SessionEnd hook, and worktree-autoclean) calls
# this when a session's window VANISHES without landing — an issue-bound WORKER or
# an @raw SCRATCH alike (issue #466; --key carries which). No PR/merge, so
# mergedAt→close-time and pr degrades to '-'; the resumable fields
# (key/worktree/sha/transcript-dir/session-id/summary) are populated so
# /fleet-history can browse + resume it. Its worktree usually still exists
# (worktree-autoclean keeps unmerged/dirty, incl. scratch experiments) → resume
# reuses it; when a later reap DOES remove it, the recorded HEAD sha rebuilds it.
# Idempotent + non-shadowing: a no-op when the ledger already has a row for this
# session (landed OR a prior tick), and a skip when there is no resolvable
# transcript (nothing to index).
cmd_record_closed() {
  local repo="" key="" wt="" sess="" title="" summary="" closedat="" sha="" origin="" win="" agent="" identity="" owner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2;;
      --key|--issue) key="${2:-}"; shift 2;;   # issue number | scratch-<N> (#466)
      --sha) sha="${2:-}"; shift 2;;
      --worktree) wt="${2:-}"; shift 2;;
      --win) win="${2:-}"; shift 2;;
      --agent) agent="${2:-}"; shift 2;;
      --agent-identity) identity="${2:-}"; shift 2;;
      --launcher-pid) owner="${2:-}"; shift 2;;
      --session) sess="${2:-}"; shift 2;;
      --title) title="${2:-}"; shift 2;;
      --summary) summary="${2:-}"; shift 2;;
      --closedat) closedat="${2:-}"; shift 2;;
      # spawn provenance (issue #503) — see cmd_record.
      --origin) origin="${2:-}"; shift 2;;
      *) shift;;
    esac
  done
  [ -z "$sess" ] && sess="${FLEET_SESSION:-$(fleet_current_session 2>/dev/null)}"
  [ -z "$key" ] && { echo "fleet-history record-closed: --key is required" >&2; return 2; }

  # transcript dir + session id from the (still-present) worktree path. A window
  # with no transcript used to be SKIPPED ("nothing to index/resume"); since issue
  # #547 it is recorded TRANSCRIPT-LESS (cols 7/8 = '-'), because a Codex worker
  # (FLEET_AGENT=codex) never writes a ~/.claude/projects transcript, and a Claude
  # worker that died before its first turn is a closed session the operator should
  # see too. Such a row is review-only (resume has no session to reopen), and it
  # dedups on key + worktree/sha (ledger_has_session's transcript-less fallback),
  # so the reapers that all reach here stay idempotent. No session ⇒ no transcript
  # dir (the dir key is a dedup key — never store a speculative path, #492).
  local tdir="" sid=""
  history_source "$agent" "$win" "$sess" "$wt" "$identity" "$owner"
  tdir="$HIST_TDIR"; sid="$HIST_SID"

  local ledger; ledger=$(ledger_path "$repo")
  if ledger_has_session "$ledger" "$sid" "$tdir" "$key" "$wt" "${pr:-}" "${sha:-}"; then
    printf 'closed %s → already in ledger (session %s) — skipped\n' "$(key_label "$key")" "${sid:-none}"
    return 0
  fi
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true

  # summary (col 9): only an explicit --summary lands here (no dash-cache fallback, #535).
  # close time in col 1 so the reader's "act" (time-since) column is meaningful.
  [ -z "$closedat" ] && closedat=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

  # HEAD sha of the STILL-PRESENT worktree (issue #466). There is no merge commit to
  # record here, but the tip sha is what keeps this row resumable AFTER a later reaper
  # removes the worktree: `resume` reuses a worktree that is still on disk and rebuilds
  # one that is gone off this sha, at the SAME path (the path is what the transcript is
  # keyed to). Without it a reaped-clean session degraded to REVIEW-ONLY — the common
  # fate of a scratch, whose clean worktree worktree-autoclean prunes silently. Cheap
  # and best-effort: no worktree on disk / no git → '-', exactly as before.
  if [ -z "$sha" ] && [ -n "$wt" ] && [ -d "$wt" ] && command -v git >/dev/null 2>&1; then
    sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  fi

  # 11 columns: mergedAt·key·title·pr·sha·worktree·transcript-dir·session-id·summary·state·origin (#503)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' \
    "$(oneline "$closedat")" \
    "$(oneline "$key")" \
    "$(oneline "${title:--}")" \
    "-" \
    "$(oneline "${sha:--}")" \
    "$(oneline "${wt:--}")" \
    "$(oneline "${tdir:--}")" \
    "$(oneline "${sid:--}")" \
    "$(oneline "${summary:--}")" \
    "closed-unlanded" \
    "$(oneline "${origin:--}")" "$(history_source_suffix)" >> "$ledger" || return 1
  printf 'closed-unlanded %s → ledger %s (session %s)\n' "$(key_label "$key")" "$ledger" "$sid"
}

# read the ledger newest-first into stdout as raw TSV (optional substring filter).
# usage: read_ledger <repo> [filter]
# stdin → rows sorted newest-first by col 1 (ISO-8601, so lexical == chronological),
# ties broken by reversed append order. Rows with an unparseable/empty col 1 sort
# last but are never dropped (the ledger is tolerant of missing fields by design).
ledger_sort_desc() {
  awk -F'\t' '{ printf "%s\t%s\n", NR, $0 }' \
    | sort -t"$(printf '\t')" -k2,2r -k1,1nr \
    | cut -f2-
}

read_ledger() {
  local repo="${1:-}" filter="${2:-}" ledger
  ledger=$(ledger_path "$repo")
  [ -f "$ledger" ] || return 0
  # Newest first BY TIMESTAMP (col 1), not by file order. Append order is not
  # chronological: a row recorded late for an older session — a backfill, or a
  # closed-unlanded row written long after the window vanished — used to float to
  # the top of the list (a `~1 · 1 mo` row sitting above rows from 3 hours ago).
  # Ties keep append order (reversed), so same-second rows stay stable.
  if [ -n "$filter" ]; then
    grep -iF -- "$filter" "$ledger" 2>/dev/null | ledger_sort_desc
  else
    ledger_sort_desc < "$ledger"
  fi
}

# find one ledger row by issue number or #PR (arg like "231" or "#61"); newest wins.
# prints the raw TSV row or nothing.
find_row() {
  local repo="${1:-}" key="${2:-}"
  [ -z "$key" ] && return 0
  local by_pr=""; case "$key" in \#*) by_pr=1; key="${key#\#}";; esac
  read_ledger "$repo" | awk -F'\t' -v k="$key" -v pr="$by_pr" '
    { if (pr=="1") { p=$4; sub(/^#/,"",p); if (p==k) {print; exit} }
      else if ($2==k) {print; exit} }'
}

# ============================================================================
# list — human table, newest first
# ============================================================================
cmd_list() {
  local repo="" filter=""
  while [ $# -gt 0 ]; do
    case "$1" in --repo) repo="${2:-}"; shift 2;; *) filter="$1"; shift;; esac
  done
  local out; out=$(read_ledger "$repo" "$filter")
  if [ -z "$out" ]; then
    echo "no landed sessions recorded yet$( [ -n "$filter" ] && printf ' (filter: %s)' "$filter")."
    return 0
  fi
  # Render the merge time as a friendly relative span ("2 hours", "3 days") rather
  # than a raw ISO timestamp (issue #228), so the CLI list matches the dash's
  # last-activity column. Per-row (a bash loop, not the one-shot awk) since the
  # ISO→relative conversion needs fleet_epoch_from_iso + fleet_reltime.
  local now; now=$(date +%s 2>/dev/null)
  printf '%s\n' "$out" | while IFS=$'\t' read -r when iss title pr sha _ _ sid smry state origin _; do
    [ -z "$iss" ] && continue
    local ep rel; ep=$(fleet_epoch_from_iso "$when"); fleet_reltime "$ep" "$now"; rel="${reltime_out:-$when}"
    local short="${sha:0:7}"; [ "$sha" = "-" ] && short="-"
    [ "${title:--}" = "-" ] && title="(untitled)"
    [ "${smry:--}" = "-" ] && smry=""
    [ ${#title} -gt 44 ] && title="${title:0:43}…"
    [ ${#smry}  -gt 60 ] && smry="${smry:0:59}…"
    # glyph tells landed (✓) from closed-unlanded (✗); empty state == legacy landed.
    local glyph="✓"; [ "$state" = "closed-unlanded" ] && glyph="✗"
    # key cell: `#<issue>` for a worker, `~<N>` for a scratch (#466) — same width.
    printf '%s %-5s  %-8s  %-44s  PR %-5s  %-7s  %s\n' \
      "$glyph" "$(key_label "$iss")" "$rel" "$title" "$pr" "$short" "$smry"
  done
}

# ============================================================================
# rows — dash US-delimited closed rows (field1=landed:<pr|issue|scratch>, field3=display)
# ============================================================================
# The landed view shares the SAME aligned column skeleton as the live dash list
# (glyph·issue·window·title·act·PR·ctx) so toggling ⌃t reads as ONE list, not a
# separate ad-hoc format (issue #228). Finished-session specifics: the glyph is an
# indigo ✓ (merged/archived, vs live green ✓ = done); "window" mirrors the tmux
# window name the worker had (kebab of the title); "act" is time-since-merge; PR
# is the merged number; ctx has no live meaning → a muted dot (skeleton parity). A
# SCRATCH row (#466) fills the same skeleton: `~<N>` in the key column instead of
# `#<issue>`, its scratch-<N>/custom window name, and an em-dash PR.
# Column widths MUST match tmux-dashboard-rows.sh (LEFTW/ACTW/RIGHTW) or the two
# lists won't line up.
# Resolve the viewing fleet's repo so we read ITS ledger, not "default". The dash
# execs into us with FLEET_SESSION exported but NOT FLEET_REPO, so try, in order:
# the collector's sessmap (multi-fleet), the per-session conf overlay (fresh fleet
# the collector hasn't mapped yet), then the global FLEET_REPO (single-fleet, from
# the fleet.conf sourced at top). Shared by `rows` and `fold` so a keystroke can
# never read a different ledger than the list it was aimed at.
rows_repo() {
  local repo="${FLEET_REPO:-}"
  if [ -n "${FLEET_SESSION:-}" ]; then
    local r; r=$(fleet_repo_cached "$FLEET_SESSION" 2>/dev/null)
    if [ -n "$r" ]; then repo="$r"
    else fleet_load_conf "$FLEET_SESSION" 2>/dev/null; repo="${FLEET_REPO:-$repo}"; fi
  fi
  printf '%s' "$repo"
}

cmd_rows() {
  local repo; repo=$(rows_repo)
  export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # ${#s} counts chars
  local E=$'\033[' US=$'\x1f'
  local GN="${E}38;2;158;206;106m" IN="${E}38;2;187;154;247m" TX="${E}38;2;169;177;214m"
  local GY="${E}38;2;86;95;137m" RD="${E}38;2;247;118;142m" R="${E}0m"

  # Column widths — kept in step with tmux-dashboard-rows.sh so live & landed align.
  local COLS=${FZF_COLUMNS:-}
  case "$COLS" in ''|*[!0-9]*) COLS=$( { tput cols </dev/tty; } 2>/dev/null );; esac
  case "$COLS" in ''|*[!0-9]*) COLS=120;; esac
  # LEFTW = glyph1+sp + issue5+sp + tree1+sp + window26+sp = 37 (tree col, #836)
  local LEFTW=37 ACTW=8 RIGHTW=21 USABLE=$(( COLS - 4 ))
  [ "$USABLE" -lt $(( LEFTW + RIGHTW + 1 )) ] && USABLE=$(( LEFTW + RIGHTW + 1 ))
  # pad/truncate to N DISPLAY chars → $fld_out (mirror of the live producer's fld).
  local fld_out
  fld() { local w="$1" s="$2" n=${#2}
    if [ "$n" -gt "$w" ]; then fld_out="${s:0:$w}"
    else printf -v fld_out "%s%*s" "$s" $((w-n)) ''; fi; }
  local now; now=$(date +%s 2>/dev/null)

  landed_scope "$repo"
  local out; out=$(read_ledger "$repo" | landed_local_origins)

  # --- nesting (issue #503, applied to the closed list) ------------------------
  # Ledger col 11 IS the spawning session — recorded at land/close time from the
  # same @origin the live dash groups by — so the finished list can show the same
  # shape the live one does: a child under the parent that spawned it, `└` indent
  # and `↳` tag, its block folded by default.
  #
  # pass A — the parent table: key → seq · origin, keyed in @origin spelling.
  # `seq` is the row's position in the newest-first list, which is this view's sort
  # the way (rank, index) is the live one's. The ledger is append-only and a key can
  # recur (a reopened issue, a re-landed scratch), so the FIRST row wins — newest
  # first means the newest one, the one a reader means by that number.
  local lkeytab='' lseq=0 lk_o lorg0
  while IFS=$'\t' read -r _ lk0 _ _ _ _ _ _ _ _ lorg0; do
    [ -n "$lk0" ] || continue
    lseq=$((lseq+1))
    lk_o=$(lkey_okey "$lk0")
    case $'\n'"$lkeytab" in *$'\n'"$lk_o"$'\t'*) continue ;; esac
    lkeytab+="$lk_o"$'\t'"$lseq"$'\t'"${lorg0:--}"$'\n'
  done <<< "$out"

  # pass A2 — per-root subtree tally, the landed twin of the live badge (#624):
  # `<landed>/<total> ✓`, i.e. how many of the block actually merged (a
  # closed-unlanded row, the ✗ glyph, did not). Attribution is pass A's grouping
  # verbatim — a grandchild counts toward the ultimate root, the row it renders
  # under — so the badge always describes exactly the block beneath it, folded or
  # not. Each record carries its own leading AND trailing newline: the counting
  # substitutions below replace non-overlapping matches, so records sharing one
  # separator newline would count two in a row as ONE.
  local lkidtab='' lm
  while IFS=$'\t' read -r _ lk0 _ _ _ _ _ _ _ lst0 lorg0; do
    [ -n "$lk0" ] || continue
    case "${lorg0:-}" in issue-*|scratch-*) ;; *) continue ;; esac
    lchain "$lorg0"
    [ -n "$lroot" ] || continue
    case "$lst0" in closed-unlanded) lm=0 ;; *) lm=1 ;; esac
    lkidtab+=$'\n'"$lroot"$'\t'"$lm"$'\n'
  done <<< "$out"

  # deploy state per landed row (issue #541): the ledger's own sha is the pre-squash
  # worktree HEAD (never on master), so the merge sha comes from this fleet's prmap
  # (field 6, by PR number) and the verdict from the deploy_<sha> file beside it —
  # both read once/fork-free, the same way the live producer does. Rows whose PR
  # fell out of the 100-row prmap window, or fleets without the feature, stay `·`.
  # Narrowed ONCE, not scanned per row (issue #662). The lookup below is
  # `${prmapn#*$'\t'"#<num>"$'\t'}` — a leading-`*` pattern match, which bash walks
  # in time proportional to the string it is handed. Given the whole prmap that
  # makes ONE landed frame O(prmap × rows), and this list is the LONG one: a
  # ledger accumulates every session a fleet ever closed. So pull out just the
  # lines whose PR number some row on this list actually carries — one awk pass,
  # and the per-row logic below is untouched.
  # The wanted set rides the ENVIRONMENT, not `-v`: awk processes escape sequences
  # in a -v assignment.
  local _pf prdir prmapn='' prwant=''
  _pf=$(fleet_cache prmap "${FLEET_SESSION:-}" 2>/dev/null); prdir=${_pf%/*}
  if [ -s "$_pf" ]; then
    prwant=$(awk -F'\t' '{ p=$4; if (p != "" && p != "-") { sub(/^#/, "", p); print "#" p } }' <<< "$out" | LC_ALL=C sort -u)
    [ -n "$prwant" ] && prmapn=$'\n'$(PRWANT="$prwant" awk -F'\t' '
      BEGIN { n = split(ENVIRON["PRWANT"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
      ($2 in want)' "$_pf" 2>/dev/null)
  fi

  # header row (fzf --header-lines=1 pins it) — identical column layout to the live
  # list's header so the two read as one table.
  local h_i h_n h_a h_p h_c h_pad h_gap
  fld 5  "issue";  h_i=$fld_out
  fld 26 "window"; h_n=$fld_out
  fld "$ACTW" "act"; h_a=$fld_out
  fld 7  "PR";     h_p=$fld_out
  fld 4  "dep";    h_c=$fld_out   # a landed row has no ctx; the cell carries its deploy state (#541)
  # the flex span is labelled "title" here (a landed row shows its issue title);
  # the live list's flex span is blank since the summary column retired (#535).
  h_pad=$(( USABLE - LEFTW - 5 - RIGHTW )); [ "$h_pad" -lt 1 ] && h_pad=1   # 5 = len("title")
  printf -v h_gap '%*s' "$h_pad" ''
  # the two blanks after the issue column are the empty tree cell (#836) — the live
  # header's own spelling, so the two lists still read as one table.
  printf '%s\n' "hdr${US}hdr${US}${E}4;38;2;86;95;137m  ${h_i}   ${h_n} title${h_gap}${h_a} ${h_p} ${h_c}${R}"

  [ -z "$out" ] && { printf '%s\n' "none${US}none${US}${GY}  (no landed sessions recorded yet — land a PR to populate; ⌃t=back to live)${R}"; return 0; }
  # Rows are BUFFERED, not printed straight out (they used to be): nesting has to
  # re-order them — a child sorts under its parent rather than at its own merge
  # time — so the emit moved below the loop, behind one sort. `<<<` rather than a
  # pipe for the same reason: a piped `while` is a subshell and $lbuf would not
  # survive it.
  local lbuf='' lrow=0 ldepth lgrp lroot lrootseq
  while IFS=$'\t' read -r when iss title pr sha _ _ sid smry state origin _; do
    [ -z "$iss" ] && continue
    lrow=$((lrow + 1))
    local target fzfkey okey
    fzfkey="${sid:--}"
    okey=$(lkey_okey "$iss")
    target=$(landed_target "$iss" "$pr")
    # --- where this row nests ---------------------------------------------------
    # A child sorts under the ultimate root's slot (depth 1 breaks the tie, then its
    # own position); a root, and an orphan whose parent never reached this list,
    # keeps its own chronological slot at depth 0.
    ldepth=0; lgrp=$lrow; lroot=''
    case "${origin:-}" in
      issue-*|scratch-*)
        lchain "$origin"
        [ -n "$lroot" ] && { ldepth=1; lgrp=$lrootseq; } ;;
    esac
    # --- the fold ---------------------------------------------------------------
    # Folded by default, and only a `depth>0` row — one drawn with the `└` indent
    # under the line above — can hide. A root and an orphan carry depth 0 and are
    # never touched, so nothing disappears with no caret-marked row to open it
    # from. The block's tally below is counted over the WHOLE subtree either way,
    # so a shut block still says what is in it.
    if [ "$ldepth" -gt 0 ] && ! landed_is_open "$lroot"; then continue; fi
    # state glyph: indigo ✓ for a landed (merged) row, muted ✗ for a closed-unlanded
    # one (#320). Empty state == a legacy pre-#320 row → landed. The target/key
    # scheme is identical for both so the dash's resume action is unchanged.
    local glyph="✓" glyph_c="$IN"
    [ "$state" = "closed-unlanded" ] && { glyph="✗"; glyph_c="$GY"; }

    # window column: the kebab window name the session had (falls back to the
    # conventional one — issue-<N> for a worker, the scratch-<N> slug for a scratch).
    # `local wname=""` — the EMPTY assignment matters: a bare `local wname` inside
    # this loop does not clear the previous iteration's value (all iterations share
    # one function scope), so every untitled row inherited the row ABOVE's window
    # name and the scratch-<N> fallback below never fired.
    local wname=""; [ "${title:--}" != "-" ] && wname=$(fleet_win_name "$title" 2>/dev/null)
    if [ -z "${wname:-}" ]; then
      if is_scratch_key "$iss"; then wname="$iss"; else wname="issue-$iss"; fi
    fi
    # flex span: the issue title. The recorded one-liner (col 9) used to take
    # precedence; it retired with the dash's summary column (issue #535) and the
    # column stays in the ledger format unrendered.
    local dsmry="$title"
    { [ "${dsmry:--}" = "-" ] || [ -z "$dsmry" ]; } && dsmry="(untitled)"
    # activity = time since the merge (mergedAt → epoch → friendly span).
    local ep act; ep=$(fleet_epoch_from_iso "$when"); fleet_reltime "$ep" "$now"; act="${reltime_out:--}"
    # PR cell — the merged number (all landed rows merged); em-dash when PR-less.
    local prcell; case "$pr" in ''|-) prcell="—";; *) prcell="#${pr#\#}";; esac
    # dep cell (#541): prmap line for this PR → merge sha → deploy_<sha> verdict.
    local depc='·' depcol=$GY msha='' _t _l _r dst=''
    case "$pr" in ''|-) : ;; *)
      _t=${prmapn#*$'\t'"#${pr#\#}"$'\t'}
      if [ "$_t" != "$prmapn" ]; then
        _l=${_t%%$'\n'*}                       # state\tci\tready\tsha
        _r=${_l#*$'\t'}; _r=${_r#*$'\t'}       # ready\tsha (ready may be empty)
        case "$_r" in *$'\t'*) msha=${_r#*$'\t'}; msha=${msha%%$'\t'*};; esac
      fi;;
    esac
    [ -n "$msha" ] && [ -f "$prdir/deploy_$msha" ] && { read -r dst _ < "$prdir/deploy_$msha" || :; }
    case "$dst" in
      live)      depc='live'; depcol=$GN;;
      deploying) depc='…';    depcol=$TX;;
      failed)    depc='✗';    depcol=$RD;;
    esac

    # issue cell: `#<issue>` in GREEN for a worker, `~<N>` in INDIGO for a scratch
    # (issue #529). #502 blanked this cell and left a scratch with no id at all;
    # the tell is the COLOUR — green=issue, indigo=scratch — since a GREEN `~<N>`
    # was "indistinguishable from `#<N>` at a glance".
    # Live scratches use their task descriptions. A landed row has no live
    # window, so keep its historical key for CLI lookup and restoration.
    local issd icol=$GN
    issd=$(key_label "$iss")
    is_scratch_key "$iss" && icol=$IN
    # tree cell (issue #836): the fixed 2-cell column between issue and window, the
    # live list's own. `└` marks a nested row — only when the parent really is the
    # line above, which after the fold filter it always is — and the caret below
    # takes the same cell on a row that OWNS a block. It used to be an indent
    # spliced into the name (`wname="└ $wname"`), which cost a child row 2 of the
    # window column's 26 cells and started its name 2 columns right of a root's.
    local treed=''
    [ "$ldepth" -gt 0 ] && treed='└'
    local f_iss f_name f_act f_pr f_ctx
    fld 5  "$issd";   f_iss=$fld_out
    # window cell: pad/clip by DISPLAY width, not code points — the same #534 fix
    # the live dash carries. Since issue #579 fleet_win_name derives CJK names, so a
    # 2-column glyph counted as 1 by fld()'s ${#} pad would shove this list's
    # right-pinned act/PR/dep block over, exactly as it did on the live rows. ASCII
    # stays on fld()'s fork-free path; only a non-ASCII name pays the wcwidth fork.
    case "$wname" in
      *[![:ascii:]]*) fleet_clip_display 26 "$wname"
                      printf -v f_name '%s%*s' "${clip_out:-}" $(( 26 - ${clip_w:-0} )) '' ;;
      *)              fld 26 "$wname"; f_name=$fld_out ;;
    esac
    fld "$ACTW" "$act"; f_act=$fld_out
    fld 7  "$prcell"; f_pr=$fld_out
    fld 4  "$depc";   f_ctx=$fld_out
    # the title flexes into the gap; clip to the same avail the live list uses — by
    # DISPLAY width, via the shared helper the live producer uses (fleet-lib.sh).
    # The old char-clip's comment claimed it "may run a hair short — never
    # overruns"; the opposite was true (a CJK glyph is 1 char / 2 columns, so the
    # clip passed ~2x the width and the pad was computed from the short count).
    # spawn provenance (issue #503): same ↳ tag grammar as the live dash, before
    # the title. col 11 absent (pre-#503 row) / '-' ≡ hub → no tag. The tag
    # borrows its width from the flex span so act/PR/ctx stay pinned.
    local tagd='' tagpfx=''
    case "${origin:-}" in
      ''|-) : ;;
      issue-*)   tagd="↳#${origin#issue-}" ;;
      scratch-*) tagd="↳~${origin#scratch-}" ;;
      *)         tagd="↳$origin" ;;
    esac
    # DROP it where the `└` indent already says the same thing — the row is drawn
    # inside a block AND the session it came from IS the row that block hangs off.
    # It stays wherever the indent cannot say it: a GRANDCHILD (drawn at the same
    # indent as a child, so the tag is the only thing naming its real parent), an
    # ORPHAN (parent never reached this list, so no indent at all), and a
    # non-session origin. Same rule as the live list.
    [ "$ldepth" -gt 0 ] && [ -n "$lroot" ] && [ "${origin:-}" = "$lroot" ] && tagd=''
    # fold caret + subtree tally — ONLY on a row that owns a block, so the list
    # does not grow a mark on every line. `▸` shut / `▾` open, then `<landed>/<total>
    # ✓`: how many of the block merged (a ✗ closed-unlanded row did not). Counted
    # off lkidtab with the same fork-free length-delta idiom the live producer uses.
    # A count > 0 already implies depth 0 — pass A2 attributes every descendant to
    # its ULTIMATE root — so a caret is guaranteed present for every block the fold
    # above can hide.
    local carg='' kidd='' lkn lkt ltot lland lextra=0
    lkn=$'\n'"$okey"$'\t'; lkt=${lkidtab//"$lkn"/}
    ltot=$(( (${#lkidtab} - ${#lkt}) / ${#lkn} ))
    if [ "$ltot" -gt 0 ]; then
      lkn=$'\n'"$okey"$'\t1'$'\n'; lkt=${lkidtab//"$lkn"/}
      lland=$(( (${#lkidtab} - ${#lkt}) / ${#lkn} ))
      kidd="$lland/$ltot ✓"
      if landed_is_open "$okey"; then carg='▾'; else carg='▸'; fi
      # the caret takes the TREE CELL (#836), left of the name it folds, as on the
      # live list; only the tally still borrows width from the flex span. `ltot>0`
      # implies depth 0, so the caret and the `└` can never both want the cell.
      treed=$carg
      lextra=$(( ${#kidd} + 1 ))
    fi
    local avail=$(( USABLE - LEFTW - RIGHTW - 1 )); [ "$avail" -lt 0 ] && avail=0
    [ -n "$tagd" ] && { avail=$(( avail - ${#tagd} - 1 )); [ "$avail" -lt 0 ] && avail=0; }
    avail=$(( avail - lextra )); [ "$avail" -lt 0 ] && avail=0
    fleet_clip_display "$avail" "$dsmry"; dsmry="${clip_out:-}"
    local dw=${clip_w:-0}
    [ -n "$tagd" ] && { tagpfx="${IN}${tagd}${R} "; dw=$(( dw + ${#tagd} + 1 )); }
    [ -n "$carg" ] && { tagpfx+="${GY}${kidd}${R} "; dw=$(( dw + lextra )); }
    local pad=$(( USABLE - LEFTW - dw - RIGHTW )); [ "$pad" -lt 1 ] && pad=1
    local gap; printf -v gap '%*s' "$pad" ''
    lbuf+="$lgrp"$'\t'"$ldepth"$'\t'"$lrow"$'\t'
    # the tree cell is exactly one cell of source text (glyph, or a space on a
    # root/orphan) and a CONSTANT width inside LEFTW, never a ${#} count — `└`/`▸`/`▾`
    # are East-Asian AMBIGUOUS, so a CJK-wide terminal may draw them 2 cells.
    lbuf+="${target}${US}${fzfkey}${US}${glyph_c}${glyph}${R} ${icol}${f_iss}${R} ${GY}${treed:- }${R} ${TX}${f_name}${R} ${tagpfx}${TX}${dsmry}${R}${gap}${GY}${f_act}${R} ${IN}${f_pr}${R} ${depcol}${f_ctx}${R}"$'\n'
  done <<< "$out"

  # Emit newest-first, nested: the group slot first (a root's own position, which a
  # child inherits), then depth, then the row's own position — a lexical pre-order
  # walk, so a child lands directly under its parent and a childless row keeps the
  # chronological place it always had. LC_ALL=C: every sort key is ASCII digits, so
  # C byte order IS the intended numeric order, and it tolerates any invalid-UTF-8
  # byte elsewhere in a rendered title instead of aborting the whole list.
  printf '%s' "$lbuf" | LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2n -k3,3n | cut -f4-
}

# ============================================================================
# resume — reconstruct the removed worktree off the squash SHA, then say how to resume
# ============================================================================
# Prints one machine-parseable verdict line the /fleet-history skill relays:
#   RESUME\t<worktree>\t<session-id>\t<claude-cmd>     — worktree ready, resume by session id
#   FROM-PR\t<pr>\t<claude-cmd>                        — no SHA/transcript, but a PR to try
#   REVIEW-ONLY\t<reason>                              — nothing resumable; review the PR/transcript
# With --exec it actually recreates the worktree (git worktree add off the SHA).
cmd_resume() {
  local repo="" main="" key="" do_exec="" fork="--fork-session"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2;;
      --main) main="${2:-}"; shift 2;;
      --exec) do_exec=1; shift;;
      --no-fork) fork=""; shift;;
      *) key="$1"; shift;;
    esac
  done
  [ -z "$key" ] && { echo "fleet-history resume: need a <key|#pr> (issue number, scratch-<N>, or #PR)" >&2; return 2; }
  local row; row=$(find_row "$repo" "$key")
  [ -z "$row" ] && { printf 'REVIEW-ONLY\tno ledger row for %s\n' "$key"; return 0; }
  local iss pr sha wt tdir sid agent chome ctrans
  IFS=$'\t' read -r _ iss _ pr sha wt tdir sid _ _ _ agent chome ctrans <<<"$row"
  if [ "$agent" = codex ]; then
    ctrans=$(python3 "$BIN/fleet-codex-session.py" locate --session "$sid" --home "$chome" --transcript "$ctrans" 2>/dev/null) || ctrans=''
    if [ ! -d "${chome:-/nonexistent}" ] || [ -z "$ctrans" ]; then
      printf 'REVIEW-ONLY\tCodex session home or exact rollout is unavailable for %s\n' "$(key_label "$iss")"
      return 0
    fi
    tdir=${ctrans%/*}
  fi

  # Resume-by-session needs BOTH a surviving transcript AND a worktree to run in.
  # The land cleanup removed the worktree, so establish one: REUSE it if it's still
  # on disk (issue #319), else recreate it off the recorded SHA — the squash commit
  # for a landed row, the session's own HEAD for a closed-unlanded one (#466). Either
  # way it is the SHA, not the branch: the branch is usually deleted post-merge (a
  # landed worker) or on reap (a pruned scratch). Only claim RESUME once a
  # worktree actually exists; if it can't be established (no SHA / no --main / add
  # failed), do NOT point at a directory that isn't there — degrade.
  #
  # Reuse-if-present is the "faster" half of #319: `git worktree add` is a full
  # checkout (the dominant cost on a big monorepo), so when a worktree is already
  # at the target path — a not-yet-pruned original, or a prior resume — we skip the
  # add and open the window straight away (repeat resumes become near-instant). We
  # reuse it AS-IS rather than resetting it to the squash SHA: a present worktree
  # may hold in-progress state from an open resume, and the win that matters is the
  # path (claude --resume is cwd-scoped — the transcript is keyed to this path).
  if [ -n "$sid" ] && [ "$sid" != "-" ] && [ -n "$tdir" ] && [ -d "$tdir" ]; then
    local have_wt=""
    if [ -n "$wt" ] && [ "$wt" != "-" ] && [ -d "$wt" ]; then
      have_wt=1                                    # reuse-if-present: on disk already, skip the add (#319)
    elif [ -n "$wt" ] && [ "$wt" != "-" ] && [ -n "$main" ] && [ -n "$sha" ] && [ "$sha" != "-" ]; then
      if [ -n "$do_exec" ]; then                   # recreate for real
        if git -C "$main" worktree add "$wt" "$sha" >/dev/null 2>&1 && [ -d "$wt" ]; then
          have_wt=1
        else
          printf 'REVIEW-ONLY\tworktree add failed (SHA %s gone?) — review transcript %s/%s.jsonl\n' "$sha" "$tdir" "$sid"
          return 0
        fi
      else
        have_wt=1                                  # dry preview: reconstructable, not yet recreated
      fi
    fi
    if [ -n "$have_wt" ]; then
      if [ "$agent" = codex ]; then
        local mode=resume home_q sid_q
        [ -n "$fork" ] && mode=fork
        printf -v home_q '%q' "$chome"; printf -v sid_q '%q' "$sid"
        printf 'CODEX-RESUME\t%s\t%s\t%s\t%s\tCODEX_HOME=%s codex %s %s\n' "$wt" "$sid" "$chome" "$mode" "$home_q" "$mode" "$sid_q"
      else
        printf 'RESUME\t%s\t%s\tclaude --resume %s %s\n' "$wt" "$sid" "$sid" "$fork"
      fi
      return 0
    fi
    # transcript survives but the worktree can't be re-established — fall through.
  fi

  # No resumable worktree — fall back to --from-pr if we have a PR.
  if [ "$agent" != codex ] && [ -n "$pr" ] && [ "$pr" != "-" ]; then
    printf 'FROM-PR\t%s\tclaude --from-pr %s %s\n' "${pr#\#}" "${pr#\#}" "$fork"
    return 0
  fi
  printf 'REVIEW-ONLY\tno resumable worktree and no PR recorded for %s\n' "$(key_label "$iss")"
}

# ============================================================================
# path — "<transcript-dir>\t<session-id>" for a landed row (transcript review)
# ============================================================================
cmd_path() {
  local repo="" key=""
  while [ $# -gt 0 ]; do
    case "$1" in --repo) repo="${2:-}"; shift 2;; *) key="$1"; shift;; esac
  done
  local row; row=$(find_row "$repo" "$key")
  [ -z "$row" ] && return 0
  awk -F'\t' '{print $7 "\t" $8}' <<<"$row"
}

# ============================================================================
# meta — "<key>\t<title>" for a ledger row (faithful resume naming + @issue)
# ============================================================================
# The restorer (bin/dash-restore-session.sh) resumes by an issue number, a
# `scratch-<N>` key, OR a #PR, but wants the resumed window to read like the
# ORIGINAL session regardless: the same descriptive name (kebab of the title, #216)
# and @issue binding. The ledger row carries both the key (col 2) and the title
# (col 3), so expose them for EVERY key shape — a #PR resume resolves to its key
# here too (issue #319). A `scratch-<N>` key tells the restorer to rebuild an @raw
# window instead of binding @issue (#466).
# Prints one TSV line; nothing when there's no matching row.
cmd_meta() {
  local repo="" key=""
  while [ $# -gt 0 ]; do
    case "$1" in --repo) repo="${2:-}"; shift 2;; *) key="$1"; shift;; esac
  done
  local row; row=$(find_row "$repo" "$key")
  [ -z "$row" ] && return 0
  awk -F'\t' '{print $2 "\t" $3 "\t" $11}' <<<"$row"
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ============================================================================
# fold — the landed view's ←/→ (bin/dash-fold-toggle.sh delegates here)
# ============================================================================
# The live dash hangs its fold bit on the tmux window; a landed row has no window,
# so this side owns the state (landed_fold_file) and this command owns the writes.
# Same contract as the live toggle: print fzf ACTIONS on stdout, print NOTHING for
# a keystroke with nothing to do. The query check already happened upstream — by
# the time a landed target reaches here the prompt line was empty.
cmd_fold() {
  local verb="${1:-}" target="${2:-}"
  case "$verb" in expand|collapse) ;; *) return 0 ;; esac
  case "$target" in landed:*) ;; *) return 0 ;; esac

  local repo; repo=$(rows_repo)
  landed_scope "$repo"
  local out; out=$(read_ledger "$repo" | landed_local_origins); [ -n "$out" ] || return 0

  # the same key table cmd_rows builds — and, in the same pass, which key the
  # keystroke landed on, matched through landed_target so the mapping from a row to
  # its target can only ever be defined in one place.
  # Built WITHOUT a subshell per row (no $(lkey_okey) / $(landed_target) fork): this
  # runs on a keystroke, and a fleet with a few hundred landed rows would otherwise
  # pay a few hundred forks before the arrow did anything.
  local lkeytab='' lseq=0 lk0 pr0 lorg0 lk_o ltgt selfkey='' lroot lrootseq
  while IFS=$'\t' read -r _ lk0 _ pr0 _ _ _ _ _ _ lorg0; do
    [ -n "$lk0" ] || continue
    lseq=$((lseq+1))
    case "$lk0" in scratch-*) lk_o=$lk0; ltgt="landed:scratch:$lk0" ;;
      *) lk_o="issue-$lk0"
         case "${pr0:-}" in ''|-) ltgt="landed:issue:$lk0" ;; *) ltgt="landed:${pr0#\#}" ;; esac ;;
    esac
    [ -z "$selfkey" ] && [ "$ltgt" = "$target" ] && selfkey=$lk_o
    case $'\n'"$lkeytab" in *$'\n'"$lk_o"$'\t'*) continue ;; esac
    lkeytab+="$lk_o"$'\t'"$lseq"$'\t'"${lorg0:--}"$'\n'
  done <<< "$out"
  [ -n "$selfkey" ] || return 0

  # the block this row is in: itself when it is a root, else the ultimate root.
  # An orphan owns no block and is in none — nothing to fold either way.
  local holder=$selfkey selforg
  selforg=$(awk -F'\t' -v k="$selfkey" '$1==k{print $3; exit}' <<< "$lkeytab")
  case "${selforg:-}" in
    issue-*|scratch-*) lchain "$selforg"; [ -n "$lroot" ] || return 0; holder=$lroot ;;
  esac

  # does the holder actually have a block? A DIRECT child in the ledger is the
  # test: a grandchild whose own parent never landed has a broken chain and is an
  # orphan in this view, so it is not part of any block here either.
  local haskids=0 korg
  while IFS=$'\t' read -r _ _ korg; do
    [ "$korg" = "$holder" ] && { haskids=1; break; }
  done <<< "$lkeytab"
  [ "$haskids" = 1 ] || return 0

  local f; f=$(landed_fold_file)
  # The dash's producer, not this file's `rows`: in the landed view it is what fzf
  # reloads, and it execs straight into us. Kept as a PATH plus a separately built
  # command string so a repo path containing a space can never word-split.
  local ROWSBIN ROWSCMD
  ROWSBIN="$(cd "$(dirname "$0")" && pwd)/tmux-dashboard-rows.sh"
  ROWSCMD="bash $ROWSBIN"

  if [ "$verb" = expand ]; then
    # `→` opens the block the row OWNS; on a row inside one it is a no-op, since
    # that row is only on screen because its block is already open.
    [ "$holder" = "$selfkey" ] || return 0
    landed_is_open "$holder" && return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    printf '%s\n' "$holder" >> "$f"
    printf 'reload(%s)\n' "$ROWSCMD"
    return 0
  fi

  # `←` shuts the block the row is IN — from the parent row or from anywhere
  # inside it, which is the gesture that actually gets used.
  landed_is_open "$holder" || return 0
  local tmp="$f.$$"
  grep -vxF -- "$holder" "$f" > "$tmp" 2>/dev/null || :
  if [ -s "$tmp" ]; then mv -f "$tmp" "$f"; else rm -f "$tmp" "$f"; fi   # empty set ⇒ no file, the pristine state
  if [ "$holder" = "$selfkey" ]; then
    printf 'reload(%s)\n' "$ROWSCMD"
    return 0
  fi
  # Shut from INSIDE: the cursor's row just vanished, so put the cursor on the
  # parent that swallowed it. That needs the parent's new INDEX, which only the
  # row renderer knows — field1 of each row is its target, and the index is its
  # line number minus the one header line fzf consumes via --header-lines=1.
  #
  # ONE render, not two — the same rule the live side keeps (bin/dash-fold-toggle.sh):
  # rendering is the expensive thing (issue #662), so the render done to FIND the
  # index is the one fzf is then pointed at, via a per-fleet snapshot. That also
  # makes the list fzf draws byte-identical to the one the index was computed
  # against, so the two cannot disagree about where the parent is. Written temp+mv
  # so fzf can never cat a half-written file, under one fixed name per fleet so it
  # is overwritten rather than accumulated. Any failure falls back to the plain
  # reload: an extra render is fine, a blank list is not.
  #
  # cmd_rows, NOT a re-exec of the dash producer: that producer picks live-vs-landed
  # off the view toggle file, so asking it would tie this index to state that has
  # nothing to do with the fold — and would re-enter this script for no reason. The
  # FALLBACK action still names the producer, because that is what fzf must run.
  local htgt hpr pos='' US2 snap; US2=$(printf '\037')
  hpr=$(printf '%s\n' "$out" | awk -F'\t' -v k="$holder" '{ o=$2; if (o !~ /^scratch-/) o="issue-" o; if (o==k) {print $4; exit} }')
  case "$holder" in scratch-*) htgt=$(landed_target "$holder" "$hpr") ;;
                    *)         htgt=$(landed_target "${holder#issue-}" "$hpr") ;; esac
  snap="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/global/dash_fold_rows_${FLEET_SESSION:-default}"
  mkdir -p "${snap%/*}" 2>/dev/null || true
  if cmd_rows > "$snap.$$" 2>/dev/null && [ -s "$snap.$$" ]; then
    mv -f "$snap.$$" "$snap"
    pos=$(awk -F"$US2" -v t="$htgt" 'NR>1 && $1==t {print NR-1; exit}' "$snap" 2>/dev/null)
  else
    rm -f "$snap.$$"
  fi
  # An fzf action's argument ends at the matching `)`, and its command is split on
  # whitespace — a snapshot path holding a paren or a space would truncate the
  # action or turn `cat` into a two-file read. Fall back to the plain reload.
  case "$snap" in *' '*|*'('*|*')'*) pos='' ;; esac
  case "$pos" in
    ''|*[!0-9]*) printf 'reload(%s)\n' "$ROWSCMD" ;;
    *)           printf 'reload-sync(cat %s)+pos(%s)\n' "$snap" "$pos" ;;
  esac
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  record)        cmd_record "$@";;
  record-closed) cmd_record_closed "$@";;
  list)   cmd_list "$@";;
  rows)   cmd_rows "$@";;
  resume) cmd_resume "$@";;
  path)   cmd_path "$@";;
  meta)   cmd_meta "$@";;
  fold)   cmd_fold "$@";;
  ''|-h|--help|help) usage;;
  *) echo "fleet-history: unknown subcommand '$cmd' (record|record-closed|list|rows|resume|path|meta|fold)" >&2; exit 2;;
esac
