#!/bin/bash
# fleet-history.sh — the landed-session history ledger + its reader/actions.
#
# When /fleet-land (or /fleet-land-train) merges a worker's PR it removes the
# `issue-<N>` worktree and kills the window — but the worker's Claude transcript
# SURVIVES cleanup under ~/.claude/projects/<encoded-cwd>/<session>.jsonl. This
# tool indexes that survivor at land time (`record`) and surfaces it afterward:
# list landed sessions (`list`/`rows`), and RESUME one by reconstructing the
# removed worktree off the squash SHA (`resume`). See issue #130.
#
# Single-writer: only the steward lands, so only the steward appends. The ledger
# is append-only and tolerant of missing fields (a row degrades to '-' rather
# than being dropped) — a landed session should always be listable even if its
# PR metadata or transcript can't be resolved.
#
# Subcommands:
#   record  --repo R --main M --pr N --issue N --worktree W [--win ID] [--session S] [--summary S]
#           Append one ledger row. Derives title/sha/mergedAt from `gh pr view`,
#           and transcript-dir + session-id from the worktree path. Run it BEFORE
#           `git worktree remove` in the land cleanup step.
#   list    [--repo R] [filter]      Human table, newest first (optional substring filter).
#   rows                             Dash US-delimited rows (landed view of the dashboard).
#   resume  --repo R --main M <issue|#pr>   Reconstruct the worktree off the SHA and
#           print how to resume (RESUME/FROM-PR/REVIEW-ONLY); --exec recreates the worktree.
#   path    <issue|#pr>              Print "<transcript-dir>\t<session-id>" for a landed row.
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
  printf '%s\n' "$out" | awk -F'\t' '
    {
      when=$1; iss=$2; title=$3; pr=$4; sha=$5; sid=$8; smry=$9
      short=substr(sha,1,7); if (sha=="-") short="-"
      if (length(title)>44) title=substr(title,1,43) "\xe2\x80\xa6"
      if (length(smry)>60)  smry=substr(smry,1,59) "\xe2\x80\xa6"
      printf "#%-4s  %-8s  %-44s  PR %-5s  %-7s  %s\n", iss, when, title, pr, short, smry
    }'
}

# ============================================================================
# rows — dash US-delimited landed rows (field1=landed:<pr|issue>, field3=display)
# ============================================================================
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
  local E=$'\033[' US=$'\x1f'
  local GN="${E}38;2;158;206;106m" IN="${E}38;2;187;154;247m" TX="${E}38;2;169;177;214m"
  local GY="${E}38;2;86;95;137m" R="${E}0m"
  local out; out=$(read_ledger "$repo")
  # header row (fzf --header-lines=1 pins it)
  printf '%s\n' "hdr${US}hdr${US}${E}4;38;2;86;95;137m  landed sessions — enter=open PR · ⌃t=back to live${R}"
  [ -z "$out" ] && { printf '%s\n' "none${US}none${US}${GY}  (no landed sessions recorded yet — land a PR to populate)${R}"; return 0; }
  printf '%s\n' "$out" | while IFS=$'\t' read -r when iss title pr sha _ _ sid smry; do
    [ -z "$iss" ] && continue
    local target key short
    key="${sid:--}"
    case "$pr" in ''|-) target="landed:issue:$iss";; *) target="landed:${pr#\#}";; esac
    short="${sha:0:7}"; [ "$sha" = "-" ] && short="-------"
    [ "${title:--}" = "-" ] && title="(untitled)"
    [ "${smry:--}" = "-" ] && smry=""
    printf '%s%s%s%s%s\n' \
      "$target" "$US" "$key" "$US" \
      "${GN}#${iss}${R} ${IN}PR${pr#\#}${R} ${GY}${short}${R} ${GY}${when}${R}  ${TX}${title}${R}${smry:+  ${GY}${smry}${R}}"
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
  # The land cleanup removed the worktree, so establish one: use it if it's still
  # on disk, else recreate it off the squash SHA (the branch is usually deleted
  # post-merge — use the SHA, not the branch). Only claim RESUME once a worktree
  # actually exists; if it can't be established (no SHA / no --main / add failed),
  # do NOT point the steward at a directory that isn't there — degrade instead.
  if [ -n "$sid" ] && [ "$sid" != "-" ] && [ -n "$tdir" ] && [ -d "$tdir" ]; then
    local have_wt=""
    if [ -n "$wt" ] && [ "$wt" != "-" ] && [ -d "$wt" ]; then
      have_wt=1                                    # already on disk (not yet cleaned / already recreated)
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
  ''|-h|--help|help) usage;;
  *) echo "fleet-history: unknown subcommand '$cmd' (record|list|rows|resume|path)" >&2; exit 2;;
esac
