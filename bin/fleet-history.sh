#!/bin/bash
# fleet-history.sh — the landed-session history ledger + its reader/actions.
#
# When the cleanup daemon (bin/fleet-cleanup.sh) reaps a merged worker's PR it removes the
# `issue-<N>` worktree and kills the window — but the worker's Claude transcript
# SURVIVES cleanup under ~/.claude/projects/<encoded-cwd>/<session>.jsonl. This
# tool indexes that survivor at land time (`record`) and surfaces it afterward:
# list landed sessions (`list`/`rows`), and RESUME one by reconstructing the
# removed worktree off the squash SHA (`resume`). See issue #130.
#
# Single-writer: the cleanup daemon serializes per repo (its own lease), so the
# ledger row is written once per merge. The ledger is append-only and tolerant of
# missing fields (a row degrades to '-' rather
# than being dropped) — a landed session should always be listable even if its
# PR metadata or transcript can't be resolved.
#
# Subcommands:
#   record  --repo R --main M --pr N --issue N --worktree W [--win ID] [--session S] [--summary S]
#           Append one ledger row. Derives title/sha/mergedAt from `gh pr view`,
#           and transcript-dir + session-id from the worktree path. Run it BEFORE
#           `git worktree remove` in the cleanup teardown step.
#   list    [--repo R] [filter]      Human table, newest first (optional substring filter).
#   rows                             Dash US-delimited rows (landed view of the dashboard).
#   resume  --repo R --main M <issue|#pr>   Reconstruct the worktree off the SHA and
#           print how to resume (RESUME/FROM-PR/REVIEW-ONLY); --exec recreates the worktree.
#           Reuses an already-present worktree (skips the slow `git worktree add`, #319).
#   path    <issue|#pr>              Print "<transcript-dir>\t<session-id>" for a landed row.
#   meta    <issue|#pr>              Print "<issue>\t<title>" for a landed row — lets the
#           restorer name the resumed window from the title + bind @issue (#319).
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

C="${TMPDIR:-/tmp}/.claude-dash/global"   # dash summary cache lives here (summary_<winid>, issue #181)
PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

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

# worktree path → transcript dir under ~/.claude/projects. Claude Code encodes a
# cwd into its project-dir name by replacing EVERY non-alphanumeric byte with '-'
# (verified on-disk: '/', '.', '_' and spaces all collapse to '-'), not just '/'.
# LC_ALL=C so tr's class is byte-wise ASCII — matches the CLI's per-char rule for
# the (near-universal) ASCII path case.
transcript_dir_for() {
  local wt="${1:-}"; [ -z "$wt" ] && return 0
  local enc; enc=$(printf '%s' "$wt" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
  printf '%s/%s' "$PROJECTS" "$enc"
}

# newest *.jsonl session id in a transcript dir (basename sans .jsonl), or empty.
newest_session_in() {
  local dir="${1:-}" f
  [ -d "$dir" ] || return 0
  f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -n1) || return 0
  [ -n "$f" ] && basename "$f" .jsonl
}

# ============================================================================
# record — append one ledger row (run BEFORE worktree removal)
# ============================================================================
cmd_record() {
  local repo="" main="" pr="" issue="" wt="" win="" summary="" mergedat="" sess=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2;;
      --main) main="${2:-}"; shift 2;;
      --pr) pr="${2:-}"; shift 2;;
      --issue) issue="${2:-}"; shift 2;;
      --worktree) wt="${2:-}"; shift 2;;
      --win) win="${2:-}"; shift 2;;
      --session) sess="${2:-}"; shift 2;;
      --summary) summary="${2:-}"; shift 2;;
      --mergedat) mergedat="${2:-}"; shift 2;;
      *) shift;;
    esac
  done
  # The dash-summary cache is keyed by <session>_<window-id> (issue #208), so a
  # --win lookup needs the fleet session. Default to the caller's fleet when the
  # (in-pane) caller didn't pass --session: land runs in the fleet whose window
  # we're recording, so both resolve to the same session.
  [ -z "$sess" ] && sess="${FLEET_SESSION:-$(fleet_current_session 2>/dev/null)}"
  [ -z "$issue" ] && { echo "fleet-history record: --issue is required" >&2; return 2; }

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

  # transcript dir + session id from the (still-present) worktree path.
  local tdir="" sid=""
  if [ -n "$wt" ]; then
    tdir=$(transcript_dir_for "$wt")
    sid=$(newest_session_in "$tdir")
  fi

  # summary: explicit --summary wins, else the dash summary cache for --win.
  if [ -z "$summary" ] && [ -n "$win" ]; then
    local smk; smk=$(fleet_summary_key "$sess" "$win")
    [ -n "${win//[^0-9]/}" ] && [ -f "$C/summary_$smk" ] && read -r summary < "$C/summary_$smk"
  fi

  local ledger; ledger=$(ledger_path "$repo")
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true

  # 9 columns: mergedAt·issue·title·pr·sha·worktree·transcript-dir·session-id·summary
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(oneline "$mergedat")" \
    "$(oneline "$issue")" \
    "$(oneline "${title:--}")" \
    "$(oneline "${pr:--}")" \
    "$(oneline "${sha:--}")" \
    "$(oneline "${wt:--}")" \
    "$(oneline "${tdir:--}")" \
    "$(oneline "${sid:--}")" \
    "$(oneline "${summary:--}")" \
    >> "$ledger"
  printf 'landed #%s → ledger %s (session %s)\n' "$issue" "$ledger" "${sid:-none}"
}

# read the ledger newest-first into stdout as raw TSV (optional substring filter).
# usage: read_ledger <repo> [filter]
read_ledger() {
  local repo="${1:-}" filter="${2:-}" ledger
  ledger=$(ledger_path "$repo")
  [ -f "$ledger" ] || return 0
  # newest first: the file is append-order (oldest→newest), so reverse it.
  if [ -n "$filter" ]; then
    grep -iF -- "$filter" "$ledger" 2>/dev/null | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}'
  else
    awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}' "$ledger"
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
  printf '%s\n' "$out" | while IFS=$'\t' read -r when iss title pr sha _ _ sid smry; do
    [ -z "$iss" ] && continue
    local ep rel; ep=$(fleet_epoch_from_iso "$when"); fleet_reltime "$ep" "$now"; rel="${reltime_out:-$when}"
    local short="${sha:0:7}"; [ "$sha" = "-" ] && short="-"
    [ "${title:--}" = "-" ] && title="(untitled)"
    [ "${smry:--}" = "-" ] && smry=""
    [ ${#title} -gt 44 ] && title="${title:0:43}…"
    [ ${#smry}  -gt 60 ] && smry="${smry:0:59}…"
    printf '#%-4s  %-8s  %-44s  PR %-5s  %-7s  %s\n' "$iss" "$rel" "$title" "$pr" "$short" "$smry"
  done
}

# ============================================================================
# rows — dash US-delimited landed rows (field1=landed:<pr|issue>, field3=display)
# ============================================================================
# The landed view shares the SAME aligned column skeleton as the live dash list
# (glyph·issue·window·summary·act·PR·ctx) so toggling ⌃t reads as ONE list, not a
# separate ad-hoc format (issue #228). Finished-session specifics: the glyph is an
# indigo ✓ (merged/archived, vs live green ✓ = done); "window" mirrors the tmux
# window name the worker had (kebab of the title); "act" is time-since-merge; PR
# is the merged number; ctx has no live meaning → a muted dot (skeleton parity).
# Column widths MUST match tmux-dashboard-rows.sh (LEFTW/ACTW/RIGHTW) or the two
# lists won't line up.
cmd_rows() {
  # Resolve the viewing fleet's repo so we read ITS ledger, not "default". The
  # dash execs into us with FLEET_SESSION exported but NOT FLEET_REPO, so try, in
  # order: the collector's sessmap (multi-fleet), the per-session conf overlay
  # (fresh fleet the collector hasn't mapped yet), then the global FLEET_REPO
  # (single-fleet, from the fleet.conf sourced at top).
  local repo="${FLEET_REPO:-}"
  if [ -n "${FLEET_SESSION:-}" ]; then
    local r; r=$(fleet_repo_cached "$FLEET_SESSION" 2>/dev/null)
    if [ -n "$r" ]; then repo="$r"
    else fleet_load_conf "$FLEET_SESSION" 2>/dev/null; repo="${FLEET_REPO:-$repo}"; fi
  fi
  export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # ${#s} counts chars
  local E=$'\033[' US=$'\x1f'
  local GN="${E}38;2;158;206;106m" IN="${E}38;2;187;154;247m" TX="${E}38;2;169;177;214m"
  local GY="${E}38;2;86;95;137m" R="${E}0m"

  # Column widths — kept in step with tmux-dashboard-rows.sh so live & landed align.
  local COLS=${FZF_COLUMNS:-}
  case "$COLS" in ''|*[!0-9]*) COLS=$( { tput cols </dev/tty; } 2>/dev/null );; esac
  case "$COLS" in ''|*[!0-9]*) COLS=120;; esac
  local LEFTW=31 ACTW=8 RIGHTW=21 USABLE=$(( COLS - 4 ))
  [ "$USABLE" -lt $(( LEFTW + RIGHTW + 1 )) ] && USABLE=$(( LEFTW + RIGHTW + 1 ))
  # pad/truncate to N DISPLAY chars → $fld_out (mirror of the live producer's fld).
  local fld_out
  fld() { local w="$1" s="$2" n=${#2}
    if [ "$n" -gt "$w" ]; then fld_out="${s:0:$w}"
    else printf -v fld_out "%s%*s" "$s" $((w-n)) ''; fi; }
  local now; now=$(date +%s 2>/dev/null)

  local out; out=$(read_ledger "$repo")

  # header row (fzf --header-lines=1 pins it) — identical column layout to the live
  # list's header so the two read as one table.
  local h_i h_n h_a h_p h_c h_pad h_gap
  fld 5  "issue";  h_i=$fld_out
  fld 22 "window"; h_n=$fld_out
  fld "$ACTW" "act"; h_a=$fld_out
  fld 7  "PR";     h_p=$fld_out
  fld 4  "ctx";    h_c=$fld_out
  h_pad=$(( USABLE - LEFTW - 7 - RIGHTW )); [ "$h_pad" -lt 1 ] && h_pad=1   # 7 = len("summary")
  printf -v h_gap '%*s' "$h_pad" ''
  printf '%s\n' "hdr${US}hdr${US}${E}4;38;2;86;95;137m  ${h_i} ${h_n} summary${h_gap}${h_a} ${h_p} ${h_c}${R}"

  [ -z "$out" ] && { printf '%s\n' "none${US}none${US}${GY}  (no landed sessions recorded yet — land a PR to populate; ⌃t=back to live)${R}"; return 0; }
  printf '%s\n' "$out" | while IFS=$'\t' read -r when iss title pr sha _ _ sid smry; do
    [ -z "$iss" ] && continue
    local target key
    key="${sid:--}"
    case "$pr" in ''|-) target="landed:issue:$iss";; *) target="landed:${pr#\#}";; esac

    # window column: the kebab window name the worker had (falls back to issue-<N>).
    local wname; [ "${title:--}" != "-" ] && wname=$(fleet_win_name "$title" 2>/dev/null)
    [ -z "${wname:-}" ] && wname="issue-$iss"
    # summary column: the recorded one-line summary, else the title so it's not blank.
    local dsmry="$smry"; { [ "${dsmry:--}" = "-" ] || [ -z "$dsmry" ]; } && dsmry="$title"
    [ "${dsmry:--}" = "-" ] && dsmry="(untitled)"
    # activity = time since the merge (mergedAt → epoch → friendly span).
    local ep act; ep=$(fleet_epoch_from_iso "$when"); fleet_reltime "$ep" "$now"; act="${reltime_out:--}"
    # PR cell — the merged number (all landed rows merged); em-dash when PR-less.
    local prcell; case "$pr" in ''|-) prcell="—";; *) prcell="#${pr#\#}";; esac

    local issd="#$iss"
    local f_iss f_name f_act f_pr f_ctx
    fld 5  "$issd";   f_iss=$fld_out
    fld 22 "$wname";  f_name=$fld_out
    fld "$ACTW" "$act"; f_act=$fld_out
    fld 7  "$prcell"; f_pr=$fld_out
    fld 4  "·";       f_ctx=$fld_out
    # summary flexes into the gap; clip to the same avail the live list uses. Char
    # clip (ASCII-fast); a rare wide glyph may run a hair short — never overruns.
    local avail=$(( USABLE - LEFTW - RIGHTW - 1 )); [ "$avail" -lt 0 ] && avail=0
    [ ${#dsmry} -gt "$avail" ] && dsmry="${dsmry:0:$avail}"
    local pad=$(( USABLE - LEFTW - ${#dsmry} - RIGHTW )); [ "$pad" -lt 1 ] && pad=1
    local gap; printf -v gap '%*s' "$pad" ''
    printf '%s%s%s%s%s\n' \
      "$target" "$US" "$key" "$US" \
      "${IN}✓${R} ${GN}${f_iss}${R} ${TX}${f_name}${R} ${TX}${dsmry}${R}${gap}${GY}${f_act}${R} ${IN}${f_pr}${R} ${GY}${f_ctx}${R}"
  done
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
  [ -z "$key" ] && { echo "fleet-history resume: need an <issue|#pr>" >&2; return 2; }
  local row; row=$(find_row "$repo" "$key")
  [ -z "$row" ] && { printf 'REVIEW-ONLY\tno landed row for %s\n' "$key"; return 0; }
  local iss pr sha wt tdir sid
  IFS=$'\t' read -r _ iss _ pr sha wt tdir sid _ <<<"$row"

  # Resume-by-session needs BOTH a surviving transcript AND a worktree to run in.
  # The land cleanup removed the worktree, so establish one: REUSE it if it's still
  # on disk (issue #319), else recreate it off the squash SHA (the branch is usually
  # deleted post-merge — use the SHA, not the branch). Only claim RESUME once a
  # worktree actually exists; if it can't be established (no SHA / no --main / add
  # failed), do NOT point the steward at a directory that isn't there — degrade.
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
      printf 'RESUME\t%s\t%s\tclaude --resume %s %s\n' "$wt" "$sid" "$sid" "$fork"
      return 0
    fi
    # transcript survives but the worktree can't be re-established — fall through.
  fi

  # No resumable worktree — fall back to --from-pr if we have a PR.
  if [ -n "$pr" ] && [ "$pr" != "-" ]; then
    printf 'FROM-PR\t%s\tclaude --from-pr %s %s\n' "${pr#\#}" "${pr#\#}" "$fork"
    return 0
  fi
  printf 'REVIEW-ONLY\tno resumable worktree and no PR recorded for #%s\n' "$iss"
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
# meta — "<issue>\t<title>" for a landed row (faithful resume naming + @issue)
# ============================================================================
# The restorer (bin/dash-restore-session.sh) resumes by an issue number OR a #PR,
# but wants the resumed window to read like the ORIGINAL worker regardless: the
# same descriptive name (kebab of the title, #216) and @issue binding. The ledger
# row carries both the issue (col 2) and the title (col 3), so expose them for
# EITHER key shape — a #PR resume resolves to its issue here too (issue #319).
# Prints one TSV line; nothing when there's no matching row.
cmd_meta() {
  local repo="" key=""
  while [ $# -gt 0 ]; do
    case "$1" in --repo) repo="${2:-}"; shift 2;; *) key="$1"; shift;; esac
  done
  local row; row=$(find_row "$repo" "$key")
  [ -z "$row" ] && return 0
  awk -F'\t' '{print $2 "\t" $3}' <<<"$row"
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  record) cmd_record "$@";;
  list)   cmd_list "$@";;
  rows)   cmd_rows "$@";;
  resume) cmd_resume "$@";;
  path)   cmd_path "$@";;
  meta)   cmd_meta "$@";;
  ''|-h|--help|help) usage;;
  *) echo "fleet-history: unknown subcommand '$cmd' (record|list|rows|resume|path|meta)" >&2; exit 2;;
esac
