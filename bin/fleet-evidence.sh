#!/bin/bash
# fleet-evidence.sh — what a change looks like ONCE IT IS LIVE, captured by the
# worker who made it and collected by the EPIC report (issue #810).
#
#   fleet-evidence.sh before|after|live [opts] <file>… | -   # store one or more captures
#   fleet-evidence.sh post   [opts]                           # ONE record-only issue comment: every row
#   fleet-evidence.sh list   [--epic E | --issue M] [opts]    # what exists — the report's read
#   fleet-evidence.sh export --epic E [opts] <dest-dir>       # copy the files beside a report page
#   fleet-evidence.sh dir    [opts]                           # print the resolved directory
#   fleet-evidence.sh line   [opts]                           # the issue body's 「上线证据:」 line
#
# WHY. The first EPIC report on a web product (#7579, 2026-09-19) had a page with
# a verdict, a member table, a quota curve and a dash before/after — and not one
# picture of the product. `commands/fleet-epic-report.md` said *"this fleet has
# no web UI; its interface is the dash"*: claude-fleet's own assumption written
# into a skill that ships to every fleet. The fix is not to have the report take
# the pictures — a report re-shooting "before" after the change has landed is
# fiction — but to have EACH WORKER capture its own before/after while the change
# is still in its hands, and to give the report a fixed place to collect from.
#
# THE THREE STAGES, and who captures each:
#   before  the worker, before touching code — the same URL / command / pane the
#           member's 上线证据 line names (or the worker's own judgment)
#   after   the worker, PR open, BEFORE landing — the same shot, from the branch
#   live    the hub, at report time, after the fleet's deploy signal went green
#           (FLEET_DEPLOY_REF / FLEET_DEPLOY_CHECK, #541) — from prod, once
# A member with none of them is reported as 无证据. Nothing here re-shoots or
# invents a missing stage: an honest gap beats a staged picture.
#
# WHERE IT LANDS (the report reads exactly these, so they are not negotiable):
#   $FLEET_CONF_DIR/fleets/<sess>/epic/<E>/evidence/<M>/   M is a member of EPIC E
#   $FLEET_CONF_DIR/fleets/<sess>/evidence/<M>/            M has no EPIC parent
# In a fleet hosting 2+ repos, a repo other than the conf's own FLEET_REPO puts
# both under fleets/<sess>/by-repo/<slug>/ instead — issue numbers repeat across
# repos, and B's #12 must never read as A's (issue #803).
# E is resolved from GitHub's parent link (GET …/issues/M/parent) unless given;
# an already-populated member dir under some epic/ wins, so a second capture
# needs no gh round-trip and works offline. Inside: the files, named
# `<stage>-<UTC>-<name>` so the stage and the order survive a plain `ls`, plus
# `manifest.tsv` (stage · ts · file · note). Nothing is committed to the repo:
# `gh` cannot attach an image to an issue comment, so the comment `post` writes
# carries the PATHS + one line each — that is the durable half — and committing
# evidence into the repo is a deliberate opt-in left for a follow-up.
#
# Options:
#   --issue M     the member issue (default: the pane's @issue, else the issue-<M>
#                 worktree in cwd — the same two reads fleet-claim-brief.sh makes)
#   --epic E      the EPIC parent (default: as above; `--epic none` forces the
#                 non-EPIC path without asking GitHub)
#   --session S   fleet session (default: the tmux session this pane is in)
#   --repo R      GitHub repo (default: FLEET_REPO of the session; in a 2+ repo
#                 fleet the pane's repo, then the dash's current one)
#   --note '…'    one line on what the capture shows (manifest + comment)
#   --name F      file name for a stdin capture (`-`) or a --pane capture
#   --pane T      capture `tmux capture-pane -p -t T` — the TUI form of evidence
#   --mv          MOVE the source file instead of copying it. A playwright-MCP
#                 screenshot lands under the worktree (`.playwright-mcp/`), and
#                 the ship step wants `git status --porcelain` empty
#   --post        after storing, also post the comment (same as a `post` call)
#   -q            quiet (no per-file line on stdout)
#
# Exit: 0 ok · 1 gh/copy failure · 2 usage · 4 no issue resolvable. `line` reads
# the labelled form first (`**上线证据**：…` / `evidence: …`, content on the line)
# and falls back to a `## 上线证据` heading with the line under it (issue #841);
# it exits 1 when the body has neither (print nothing) — the worker then judges.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-evidence: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,65p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"; [ -n "$cmd" ] || { usage >&2; exit 2; }
shift
case "$cmd" in
  before|after|live|post|list|export|dir|line) ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown command '$cmd' (before|after|live|post|list|export|dir|line)" 2 ;;
esac

issue_arg='' epic_arg='' sess_arg='' repo_arg='' note='' name='' pane='' do_mv=0 do_post=0 quiet=0
files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue)   shift; issue_arg="${1:-}" ;;
    --epic)    shift; epic_arg="${1:-}" ;;
    --session) shift; sess_arg="${1:-}" ;;
    --repo)    shift; repo_arg="${1:-}" ;;
    --note)    shift; note="${1:-}" ;;
    --name)    shift; name="${1:-}" ;;
    --pane)    shift; pane="${1:-}" ;;
    --mv)      do_mv=1 ;;
    --post)    do_post=1 ;;
    -q)        quiet=1 ;;
    -h|--help) usage; exit 0 ;;
    -)         files+=("-") ;;
    -*)        die "unknown flag $1" 2 ;;
    *)         files+=("$1") ;;
  esac
  shift
done
issue_arg="${issue_arg//[^0-9]/}"
case "$epic_arg" in none|NONE|-) epic_arg=none ;; *) epic_arg="${epic_arg//[^0-9]/}" ;; esac

# ---- fleet -------------------------------------------------------------------
sess="${sess_arg:-$(fleet_current_session)}"
[ -n "$sess" ] || die "no fleet session (not inside tmux — pass --session <fleet>)" 2
fleet_load_conf "$sess"
repo="${repo_arg:-${FLEET_REPO:-}}"
state="$FLEET_CONF_DIR/fleets/$sess"
# A fleet hosting 2+ repos (issue #803): the repo is the EPIC's, never just the
# conf's — so the report run from the hub reads repo B's sub-issues, and a worker
# gets its own window's repo. No --repo resolves like every repo-wide command
# (fleet_target_repo: the pane's repo, then the dash's current one); under `all`
# it refuses rather than filing B's evidence under A. Issue numbers repeat across
# repos, so every repo but the conf's own keeps its store under by-repo/<slug>/ —
# the conf repo's paths are the ones it always had. One-repo: untouched.
if fleet_multirepo "$sess"; then
  repo=$(fleet_target_repo "$sess" "$repo_arg"); _rc=$?
  case "$_rc" in
    0) ;;
    4) die "fleet $sess hosts several repos — pass --repo ($(fleet_repos "$sess" | tr '\n' ' '))" 2 ;;
    *) die "$repo_arg is not a repo fleet $sess hosts" 2 ;;
  esac
  [ "$repo" = "$(fleet_repos "$sess" | head -n1)" ] || state="$state/by-repo/$(fleet_slug "$repo")"
fi

# ---- the member issue: @issue wins, the issue-<M> worktree in cwd is the fallback
resolve_issue() {
  local at wt cwd n
  [ -n "$issue_arg" ] && { printf '%s' "$issue_arg"; return 0; }
  at=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null); at="${at//[^0-9]/}"
  [ -n "$at" ] && { printf '%s' "$at"; return 0; }
  cwd=$(pwd -P 2>/dev/null || pwd); wt=''
  case "$cwd" in
    */*issue-[0-9]*) n="${cwd##*issue-}"; wt="${n%%[!0-9]*}" ;;
  esac
  printf '%s' "$wt"
}

# ---- the EPIC parent: explicit → an existing populated dir → GitHub → none ----
# Prints the epic number, or nothing. Never fails: "no parent" is a normal answer.
resolve_epic() {
  local m="$1" hit='' d n
  [ "$epic_arg" = none ] && return 0
  [ -n "$epic_arg" ] && { printf '%s' "$epic_arg"; return 0; }
  for d in "$state"/epic/*/evidence/"$m"; do
    [ -d "$d" ] || continue
    [ -n "$hit" ] && { hit=''; break; }   # two epics claim it — ask GitHub
    hit="$d"
  done
  if [ -n "$hit" ]; then
    n="${hit#"$state"/epic/}"; n="${n%%/*}"; printf '%s' "$n"; return 0
  fi
  [ -n "$repo" ] && command -v gh >/dev/null 2>&1 || return 0
  n=$(gh api "repos/$repo/issues/$m/parent" --jq .number 2>/dev/null) || n=''
  printf '%s' "${n//[^0-9]/}"
}

evidence_dir() {   # $1 member, $2 epic-or-empty
  if [ -n "$2" ]; then printf '%s/epic/%s/evidence/%s' "$state" "$2" "$1"
  else printf '%s/evidence/%s' "$state" "$1"; fi
}

# one manifest row per capture; a note may not carry a tab or a newline
append_row() {   # $1 dir, $2 stage, $3 ts, $4 file, $5 note
  local n; n=$(printf '%s' "$5" | tr '\t\r\n' '   ')
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$n" >> "$1/manifest.tsv"
}

# print a member's rows as `member stage ts path note`, or ONE `none` row.
# Looks in the epic dir first, then the non-EPIC dir (a member whose parent
# link was added after its worker captured — the evidence must not go missing).
member_rows() {   # $1 member, $2 epic-or-empty
  local d f
  for d in "$(evidence_dir "$1" "$2")" "$(evidence_dir "$1" "")"; do
    f="$d/manifest.tsv"
    [ -s "$f" ] || continue
    while IFS=$'\t' read -r st ts fn nt; do
      [ -n "$st" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$st" "$ts" "$d/$fn" "$nt"
    done < "$f"
    return 0
  done
  printf '%s\tnone\t\t\t\n' "$1"
}

# ---- `line`: the member body's 上线证据 line ---------------------------------
if [ "$cmd" = line ]; then
  m=$(resolve_issue); [ -n "$m" ] || die "no issue bound (no @issue, cwd isn't an issue-<N> worktree) — pass --issue" 4
  [ -n "$repo" ] || die "no repo resolved (set --repo or FLEET_REPO)" 2
  command -v gh >/dev/null 2>&1 || die "gh not on PATH" 1
  body=$(gh issue view "$m" --repo "$repo" --json body --jq .body 2>/dev/null) || die "could not read issue #$m in $repo" 1
  # 1) the canonical shape — a LABELLED line: `- **上线证据**：…` / `evidence: …` /
  # `3. 上线证据: …` / `## 上线证据: …`; label variants, both colons, content on the
  # SAME line (spelled case-insensitively in the pattern itself: BSD sed has no `I`)
  pat='^[[:space:]]*(#+|[-*+]|[0-9]+[.)])?[[:space:]]*[*_`]*(上线证据|[Ee]vidence|EVIDENCE)[*_`]*[[:space:]]*[:：]'
  # first labelled line with something AFTER the colon — a bare `上线证据：` is not a
  # line, and must not shadow a real one further down (or the heading form below)
  l=$(printf '%s\n' "$body" | grep -E "$pat" | sed -E "s/${pat}[[:space:]]*//" \
        | grep -v '^[[:space:]]*$' | head -1)
  if [ -n "$l" ]; then printf '%s\n' "$l"; exit 0; fi
  # 2) the fallback — a HEADING-style section: `## 上线证据` with the line UNDER it
  # (issue #841). /fleet-epic-plan wrote that shape until #840 unified the write
  # side on the labelled line, and those members are already filed: on 2026-09-20
  # all 8 members of the two live EPICs on 24haowan-monorepo had it, so every one
  # of them read as 无证据. Read it back rather than asking the operator to rewrite
  # bodies. Blank lines under the heading are skipped; the next heading (or the end
  # of the body) ends the section and, with nothing in it, is still exit 1 — never
  # an empty string, never the next section's text.
  printf '%s\n' "$body" | awk '
    BEGIN { st = 1 }
    /^[[:space:]]*#+[[:space:]]*[*_`]*(上线证据|[Ee]vidence|EVIDENCE)[*_`]*[[:space:]]*(:|：)?[[:space:]]*$/ { seen = 1; next }
    seen {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*#/) exit
      line = $0
      sub(/^[[:space:]]+/, "", line)
      t = line; sub(/^([-*+]|[0-9]+[.)])[[:space:]]+/, "", t)
      if (t != "") line = t
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      print line; st = 0; exit
    }
    END { exit st }
  '
  exit $?
fi

# ---- `list` / `export`: the report's read -----------------------------------
if [ "$cmd" = list ] || [ "$cmd" = export ]; then
  dest=''
  if [ "$cmd" = export ]; then
    [ "${#files[@]}" -eq 1 ] || die "export needs exactly one <dest-dir>" 2
    dest="${files[0]}"
    [ -n "$epic_arg" ] && [ "$epic_arg" != none ] || die "export needs --epic <E>" 2
  fi
  if [ -n "$epic_arg" ] && [ "$epic_arg" != none ]; then
    e="$epic_arg"
    # members = every sub-issue GitHub knows of ∪ every dir already on disk, so a
    # member reads `none` rather than vanishing, and evidence never needs gh to show
    members=$( {
      for d in "$state/epic/$e/evidence"/*/; do
        [ -d "$d" ] || continue
        n="${d%/}"; n="${n##*/}"; [ "$n" = "${n//[^0-9]/}" ] && printf '%s\n' "$n"
      done
      if [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
        gh api "repos/$repo/issues/$e/sub_issues" --paginate --jq '.[].number' 2>/dev/null || true
      fi
    } | grep -E '^[0-9]+$' | sort -un)
    [ -n "$members" ] || { printf '# epic %s: no members and no evidence on disk\n' "$e"; exit 0; }
    printf '# member\tstage\tts\tpath\tnote   (epic %s · %s)\n' "$e" "$state/epic/$e/evidence"
    rows=$(printf '%s\n' "$members" | while read -r m; do member_rows "$m" "$e"; done)
  else
    m=$(resolve_issue); [ -n "$m" ] || die "no issue bound — pass --issue <M> or --epic <E>" 4
    e=$(resolve_epic "$m")
    printf '# member\tstage\tts\tpath\tnote   (issue %s%s)\n' "$m" "${e:+ · epic $e}"
    rows=$(member_rows "$m" "$e")
  fi
  if [ "$cmd" = list ]; then printf '%s\n' "$rows"; exit 0; fi
  # export: copy every file to <dest>/evidence/<M>/<file>; print rows with the RELATIVE path
  n=0
  printf '%s\n' "$rows" | while IFS=$'\t' read -r m st ts p nt; do
    if [ "$st" = none ] || [ -z "$p" ]; then printf '%s\t%s\t\t\t\n' "$m" "$st"; continue; fi
    rel="evidence/$m/${p##*/}"
    mkdir -p "$dest/evidence/$m" && cp -p "$p" "$dest/$rel" \
      || { printf 'fleet-evidence: copy failed: %s\n' "$p" >&2; continue; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$st" "$ts" "$rel" "$nt"
  done
  exit 0
fi

# ---- everything below is about ONE member ------------------------------------
m=$(resolve_issue); [ -n "$m" ] || die "no issue bound (no @issue, cwd isn't an issue-<N> worktree) — pass --issue" 4
e=$(resolve_epic "$m")
dir=$(evidence_dir "$m" "$e")

if [ "$cmd" = dir ]; then printf '%s\n' "$dir"; exit 0; fi

post_comment() {
  local f="$dir/manifest.tsv" body
  [ -s "$f" ] || die "nothing to post — no evidence captured for #$m yet" 2
  [ -n "$repo" ] || die "no repo resolved (set --repo or FLEET_REPO)" 2
  body=$( {
    printf '📎 上线证据 · #%s%s\n\n' "$m" "${e:+ (EPIC #$e)}"
    printf 'dir: `%s`\n\n' "$dir"
    while IFS=$'\t' read -r st ts fn nt; do
      [ -n "$st" ] || continue
      printf -- '- **%s** · %s · `%s`%s\n' "$st" "$ts" "$fn" "${nt:+ — $nt}"
    done < "$f"
    printf '\n_Files stay on this machine (gh cannot attach an image to a comment); the EPIC report collects them from the path above._\n'
    printf '<!-- fleet:evidence issue=%s epic=%s dir=%s -->\n' "$m" "${e:-none}" "$dir"
  } )
  printf '%s\n' "$body" | "$BIN/fleet-comment.sh" "$m" --repo "$repo" --note --body-file -
}

if [ "$cmd" = post ]; then post_comment; exit $?; fi

# ---- before | after | live: store the captures -------------------------------
stage="$cmd"
[ -n "$pane" ] || [ "${#files[@]}" -gt 0 ] || die "$stage: give one or more files, '-' for stdin, or --pane <target>" 2
mkdir -p "$dir" || die "cannot create $dir" 1
ts=$(date -u +%Y%m%dT%H%M%SZ)

# `<stage>-<UTC>-<name>`, unique within the dir (two captures in one second)
target_name() {   # $1 raw name → a name that does not yet exist in $dir
  local base n i=1
  base=$(printf '%s' "$1" | tr -s '[:space:]/\\' '_'); [ -n "$base" ] || base=capture
  n="$stage-$ts-$base"
  while [ -e "$dir/$n" ]; do i=$((i+1)); n="$stage-$ts-$i-$base"; done
  printf '%s' "$n"
}
store_ok=0
say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$1"; }

if [ -n "$pane" ]; then
  fn=$(target_name "${name:-pane-$(printf '%s' "$pane" | tr -c 'A-Za-z0-9._-' '_').txt}")
  if tmux capture-pane -p -t "$pane" > "$dir/$fn" 2>/dev/null; then
    append_row "$dir" "$stage" "$ts" "$fn" "$note"; say "$dir/$fn"; store_ok=1
  else rm -f "$dir/$fn"; printf 'fleet-evidence: capture-pane %s failed\n' "$pane" >&2; fi
fi
for src in ${files[@]+"${files[@]}"}; do
  if [ "$src" = "-" ]; then
    fn=$(target_name "${name:-capture.txt}")
    cat > "$dir/$fn" || { rm -f "$dir/$fn"; printf 'fleet-evidence: stdin capture failed\n' >&2; continue; }
  else
    [ -f "$src" ] || { printf 'fleet-evidence: not a file: %s\n' "$src" >&2; continue; }
    fn=$(target_name "${src##*/}")
    if [ "$do_mv" -eq 1 ]; then mv -- "$src" "$dir/$fn" || { printf 'fleet-evidence: move failed: %s\n' "$src" >&2; continue; }
    else cp -p -- "$src" "$dir/$fn" || { printf 'fleet-evidence: copy failed: %s\n' "$src" >&2; continue; }; fi
  fi
  append_row "$dir" "$stage" "$ts" "$fn" "$note"; say "$dir/$fn"; store_ok=1
done
[ "$store_ok" -eq 1 ] || die "$stage: nothing stored" 1
[ "$do_post" -eq 1 ] && post_comment
exit 0
