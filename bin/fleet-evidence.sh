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
# A repo other than the conf's own FLEET_REPO (a second hosted repo) puts
# both under fleets/<sess>/by-repo/<slug>/ instead — issue numbers repeat across
# repos, and B's #12 must never read as A's (issue #803).
# An EPIC may span repos (issue #1942): its parent is in repo A, a member M in
# repo B. Every member's evidence lands under the EPIC's tree (A's), so the report
# collects one directory — a member of another repo as `<slug-of-B>.<M>/`, with
# `.repo` / `.epic-repo` beside its manifest, and listed as `owner/B#M`.
# E is resolved from GitHub's parent link (GET …/issues/M/parent, which names the
# parent's repo too) unless given;
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
#                 non-EPIC path without asking GitHub). `owner/name#E` names a
#                 parent in another repo than the member's (issue #1942)
#   --session S   fleet session (default: the tmux session this pane is in)
#   --repo R      GitHub repo, one the fleet hosts (default: the pane's repo, else
#                 the fleet's only repo — fleet_target_repo, issue #1938)
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
epic_arg_repo=''
case "$epic_arg" in
  none|NONE|-) epic_arg=none ;;
  ?*/?*#*) epic_arg_repo=$(fleet_norm_repo "${epic_arg%%#*}"); epic_arg="${epic_arg##*#}"; epic_arg="${epic_arg//[^0-9]/}" ;;
  *) epic_arg="${epic_arg//[^0-9]/}" ;;
esac

# ---- fleet -------------------------------------------------------------------
sess="${sess_arg:-$(fleet_current_session)}"
[ -n "$sess" ] || die "no fleet session (not inside tmux — pass --session <fleet>)" 2
fleet_load_conf "$sess"
state="$FLEET_CONF_DIR/fleets/$sess"
# The repo is the EPIC's, never just the conf's (issue #803) — so the report run
# from the hub reads repo B's sub-issues, and a worker gets its own window's repo.
# ONE rule however many repos the fleet hosts (fleet_target_repo, issue #1938): a
# --repo must be hosted, else the pane's repo, else the fleet's only repo, else it
# refuses rather than filing B's evidence under A. Issue numbers repeat across
# repos, so every repo but the conf's own keeps its store under by-repo/<slug>/ —
# the conf repo's paths are the ones it always had.
repo=$(fleet_target_repo "$sess" "$repo_arg"); _rc=$?
case "$_rc" in
  0) ;;
  4) die "fleet $sess hosts several repos — pass --repo ($(fleet_repos "$sess" | tr '\n' ' '))" 2 ;;
  *) [ -n "$repo_arg" ] && die "$repo_arg is not a repo fleet $sess hosts" 2
     repo='' ;;   # a fleet with no repo: before/after still capture; post/line refuse
esac
_first=$(fleet_repos "$sess" | head -n1)
# repo_state <repo> → the store root of <repo>: the conf repo's is the fleet's own
# dir, every other repo's is by-repo/<slug>/ (issue #803)
repo_state() {
  if [ -z "$_first" ] || [ -z "${1:-}" ] || [ "$1" = "$_first" ]; then printf '%s' "$FLEET_CONF_DIR/fleets/$sess"
  else printf '%s/by-repo/%s' "$FLEET_CONF_DIR/fleets/$sess" "$(fleet_slug "$1")"; fi
}
state=$(repo_state "$repo")

# ---- the member issue: @issue wins, the issue-<M> worktree in cwd is the fallback
resolve_issue() {
  local at wt cwd n
  [ -n "$issue_arg" ] && { printf '%s' "$issue_arg"; return 0; }
  at=$(fleet_pane_fmt '#{@issue}'); at="${at//[^0-9]/}"     # this pane only (issue #1537)
  [ -n "$at" ] && { printf '%s' "$at"; return 0; }
  cwd=$(pwd -P 2>/dev/null || pwd); wt=''
  case "$cwd" in
    */*issue-[0-9]*) n="${cwd##*issue-}"; wt="${n%%[!0-9]*}" ;;
  esac
  printf '%s' "$wt"
}

# ---- the EPIC parent: explicit → an existing populated dir → GitHub → none ----
# Prints `<epic-repo>\t<epic>`, or nothing. Never fails: "no parent" is a normal
# answer. The parent may live in another repo than the member (issue #1942).
resolve_epic() {
  local m="$1" hit='' hrepo='' d n r cross
  [ "$epic_arg" = none ] && return 0
  [ -n "$epic_arg" ] && { printf '%s\t%s' "${epic_arg_repo:-$repo}" "$epic_arg"; return 0; }
  for d in "$state"/epic/*/evidence/"$m"; do
    [ -d "$d" ] || continue
    [ -n "$hit" ] && { hit=''; hrepo=''; break; }   # two epics claim it — ask GitHub
    hit="$d"; hrepo="$repo"
  done
  if [ -n "$repo" ] && [ -z "$hrepo" ] && [ -z "$hit" ]; then   # a member of another repo's EPIC
    cross="$(fleet_slug "$repo").$m"
    for d in "$FLEET_CONF_DIR/fleets/$sess"/epic/*/evidence/"$cross" "$FLEET_CONF_DIR/fleets/$sess"/by-repo/*/epic/*/evidence/"$cross"; do
      [ -f "$d/.epic-repo" ] || continue
      [ -n "$hit" ] && { hit=''; break; }
      hit="$d"; hrepo=$(head -n1 "$d/.epic-repo")
    done
  fi
  if [ -n "$hit" ]; then
    n="${hit%/evidence/*}"; n="${n##*/}"; printf '%s\t%s' "$hrepo" "$n"; return 0
  fi
  [ -n "$repo" ] && command -v gh >/dev/null 2>&1 || return 0
  n=$(gh api "repos/$repo/issues/$m/parent" \
        --jq '"\(.repository_url | sub("^.*/repos/"; ""))\t\(.number)"' 2>/dev/null) || n=''
  r=''; case "$n" in *$'\t'*) r="${n%%$'\t'*}"; n="${n##*$'\t'}" ;; esac
  n="${n//[^0-9]/}"
  [ -n "$n" ] && printf '%s\t%s' "${r:-$repo}" "$n"
  return 0
}

# member_dir <member-repo> <epic-repo> <M> → M's dir name under the EPIC's tree:
# `<M>` when both are the same repo (every one-repo EPIC), `<slug>.<M>` otherwise
member_dir() {
  if [ -z "$1" ] || [ "$1" = "$2" ]; then printf '%s' "$3"
  else printf '%s.%s' "$(fleet_slug "$1")" "$3"; fi
}

evidence_dir() {   # $1 member, $2 epic-or-empty, $3 epic repo
  if [ -n "$2" ]; then printf '%s/epic/%s/evidence/%s' "$(repo_state "${3:-$repo}")" "$2" "$(member_dir "$repo" "${3:-$repo}" "$1")"
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
# A member of another repo (issue #1942) passes its label (`owner/name#M`), its
# dir under the EPIC's tree and its own repo's non-EPIC dir.
member_rows() {   # $1 member, $2 epic-or-empty, $3 epic repo · or: $1 label, $4 epic dir, $5 non-EPIC dir
  local d f
  for d in "${4:-$(evidence_dir "$1" "$2" "${3:-}")}" "${5:-$(evidence_dir "$1" "")}"; do
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
  erepo="$repo"
  if [ -n "$epic_arg" ] && [ "$epic_arg" != none ]; then
    e="$epic_arg"; erepo="${epic_arg_repo:-$repo}"
    eroot="$(repo_state "$erepo")/epic/$e/evidence"
    subs=''
    if [ -n "$erepo" ] && command -v gh >/dev/null 2>&1; then subs=$(fleet_sub_issues "$erepo" "$e") || subs=''; fi
    # members = every sub-issue GitHub knows of ∪ every dir already on disk, so a
    # member reads `none` rather than vanishing, and evidence never needs gh to show.
    # The EPIC's own repo's members are bare numbers (as always); a member filed in
    # another repo (issue #1942) is `owner/name#M`, its dir `<slug>.<M>`.
    own=$( {
      for d in "$eroot"/*/; do
        [ -d "$d" ] || continue
        n="${d%/}"; n="${n##*/}"; [ "$n" = "${n//[^0-9]/}" ] && printf '%s\n' "$n"
      done
      [ -z "$subs" ] || printf '%s\n' "$subs" | awk -F '\t' -v r="$erepo" 'NF == 1 { print $1; next } $1 == r { print $2 }'
    } | grep -E '^[0-9]+$' | sort -un)
    other=$( {   # `<label>\t<dir>\t<member repo>`
      for d in "$eroot"/*/; do
        [ -f "$d.repo" ] || continue
        n="${d%/}"; n="${n##*/}"; r=$(head -n1 "$d.repo")
        [ -n "$r" ] && printf '%s#%s\t%s\t%s\n' "$r" "${n##*.}" "$n" "$r"
      done
      [ -z "$subs" ] || printf '%s\n' "$subs" | while IFS=$'\t' read -r r n _; do
        [ -n "$n" ] && [ -n "$r" ] && [ "$r" != "$erepo" ] || continue   # a bare number is the EPIC's own
        printf '%s#%s\t%s\t%s\n' "$r" "$n" "$(member_dir "$r" "$erepo" "$n")" "$r"
      done
    } | sort -t $'\t' -u -k1,1)
    [ -n "$own$other" ] || { printf '# epic %s: no members and no evidence on disk\n' "$e"; exit 0; }
    printf '# member\tstage\tts\tpath\tnote   (epic %s · %s)\n' "$e" "$eroot"
    rows=$( {
      [ -z "$own" ] || printf '%s\n' "$own" | while read -r m; do member_rows "$m" "$e" "$erepo"; done
      [ -z "$other" ] || printf '%s\n' "$other" | while IFS=$'\t' read -r lb dn r; do
        member_rows "$lb" '' '' "$eroot/$dn" "$(repo_state "$r")/evidence/${lb##*#}"
      done
    } )
  else
    m=$(resolve_issue); [ -n "$m" ] || die "no issue bound — pass --issue <M> or --epic <E>" 4
    er=$(resolve_epic "$m"); e="${er##*$'\t'}"; erepo="${er%%$'\t'*}"; [ -n "$er" ] || erepo="$repo"
    elabel="$e"; [ -z "$e" ] || [ "$erepo" = "$repo" ] || elabel="$erepo#$e"
    printf '# member\tstage\tts\tpath\tnote   (issue %s%s)\n' "$m" "${e:+ · epic $elabel}"
    rows=$(member_rows "$m" "$e" "$erepo")
  fi
  # A member with nothing HERE may have run on another machine of this owner
  # (issue #1609): its worker's machine handed the files to the hub at its ship
  # report / reap. Ask once, only when some member reads `none`; a remote row's
  # note starts `[@<machine>]`, and a member the hub knows ran elsewhere but left
  # no capture reads `none` with 「在 <machine> 上跑过，没拍」. Not a hub node →
  # nothing asked, every row as before.
  case "$rows" in
    *$'\tnone\t'*)
      if [ -f "$BIN/fleet-worker-records.sh" ] && [ -n "$repo" ]; then
        if [ -n "$epic_arg" ] && [ "$epic_arg" != none ]; then set -- --epic "$e"; else set -- --issue "$m"; fi
        rem=$(bash "$BIN/fleet-worker-records.sh" fetch --session "$sess" --repo "${erepo:-$repo}" "$@" 2>/dev/null); rrc=$?
        if [ "$rrc" -eq 0 ] || [ "$rrc" -eq 1 ]; then
          rows=$(FE_ROWS="$rows" FE_REM="$rem" FE_RC="$rrc" python3 -c '
import os
rem, by = os.environ["FE_REM"], {}
ran = {}
for l in rem.split("\n"):
    f = l.split("\t")
    if f[0] == "evidence" and len(f) >= 7:
        by.setdefault(f[1], []).append("%s\t%s\t%s\t%s\t%s" % (f[1], f[2], f[3], f[4], ("[@%s] %s" % (f[6], f[5])).rstrip()))
    elif f[0] == "history" and len(f) >= 3:
        ran.setdefault(f[1], f[2])
for l in os.environ["FE_ROWS"].split("\n"):
    f = l.split("\t")
    if len(f) >= 2 and f[1] == "none":
        if f[0] in by:
            print("\n".join(by[f[0]])); continue
        if f[0] in ran:
            print("%s\tnone\t\t\t在 %s 上跑过，没拍" % (f[0], ran[f[0]])); continue
        if os.environ["FE_RC"] == "1":
            print("%s\tnone\t\t\t别机未查（入口不可达）" % f[0]); continue
    print(l)
')
        fi
      fi ;;
  esac
  if [ "$cmd" = list ]; then printf '%s\n' "$rows"; exit 0; fi
  # export: copy every file to <dest>/evidence/<M>/<file>; print rows with the RELATIVE path
  n=0
  printf '%s\n' "$rows" | while IFS=$'\t' read -r m st ts p nt; do
    # a none row's ts/path are empty, and a tab IFS folds empty fields — so its
    # note (issue #1609) lands in whichever of the three read it
    if [ "$st" = none ] || [ -z "$p" ]; then printf '%s\t%s\t\t\t%s\n' "$m" "$st" "$ts$p$nt"; continue; fi
    md=$(printf '%s' "$m" | tr '/#' '-.')   # owner/name#M → owner-name.M, a path-safe dir
    rel="evidence/$md/${p##*/}"
    mkdir -p "$dest/evidence/$md" && cp -p "$p" "$dest/$rel" \
      || { printf 'fleet-evidence: copy failed: %s\n' "$p" >&2; continue; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$st" "$ts" "$rel" "$nt"
  done
  exit 0
fi

# ---- everything below is about ONE member ------------------------------------
m=$(resolve_issue); [ -n "$m" ] || die "no issue bound (no @issue, cwd isn't an issue-<N> worktree) — pass --issue" 4
er=$(resolve_epic "$m"); e="${er##*$'\t'}"; erepo="${er%%$'\t'*}"; [ -n "$er" ] || erepo="$repo"
dir=$(evidence_dir "$m" "$e" "$erepo")
eref="#$e"; [ "$erepo" = "$repo" ] || eref="$erepo#$e"   # an EPIC in another repo (issue #1942)
emark="${eref#\#}"; [ -n "$e" ] || emark=none

if [ "$cmd" = dir ]; then printf '%s\n' "$dir"; exit 0; fi

post_comment() {
  local f="$dir/manifest.tsv" body
  [ -s "$f" ] || die "nothing to post — no evidence captured for #$m yet" 2
  [ -n "$repo" ] || die "no repo resolved (set --repo or FLEET_REPO)" 2
  body=$( {
    printf '📎 上线证据 · #%s%s\n\n' "$m" "${e:+ (EPIC $eref)}"
    printf 'dir: `%s`\n\n' "$dir"
    while IFS=$'\t' read -r st ts fn nt; do
      [ -n "$st" ] || continue
      printf -- '- **%s** · %s · `%s`%s\n' "$st" "$ts" "$fn" "${nt:+ — $nt}"
    done < "$f"
    printf '\n_Files stay on this machine (gh cannot attach an image to a comment); the EPIC report collects them from the path above._\n'
    printf '<!-- fleet:evidence issue=%s epic=%s dir=%s -->\n' "$m" "$emark" "$dir"
  } )
  printf '%s\n' "$body" | "$BIN/fleet-comment.sh" "$m" --repo "$repo" --note --body-file -
}

if [ "$cmd" = post ]; then post_comment; exit $?; fi

# ---- before | after | live: store the captures -------------------------------
stage="$cmd"
[ -n "$pane" ] || [ "${#files[@]}" -gt 0 ] || die "$stage: give one or more files, '-' for stdin, or --pane <target>" 2
mkdir -p "$dir" || die "cannot create $dir" 1
if [ -n "$e" ] && [ "$erepo" != "$repo" ]; then   # a member of another repo's EPIC: say whose
  printf '%s\n' "$repo" > "$dir/.repo"; printf '%s\n' "$erepo" > "$dir/.epic-repo"
fi
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
