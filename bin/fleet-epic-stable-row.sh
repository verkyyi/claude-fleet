#!/bin/sh
# fleet-epic-stable-row.sh --repo <owner/name> --main <checkout> (--epic <N> | --merged <sha> ...)
#                          [--base <trunk>] [--remote <name>] [--timeout <s>]
#   — the 列车结果 line for /fleet-epic-report (issue #4917; it was #1124's
#     「挪稳定版」 row). Reads only; NEVER moves the tag.
#
# stable is moved by the release train on its own (#3141); a person moving it by
# hand is the repair road only (release-rules «真等不了列车»). So a batch's report
# no longer asks anyone to move it: it says where the batch's last merge stands —
# 已随列车上线 (stable contains it), 列车在跑, or 卡在红车 <run> — read off
# `refs/tags/stable` and the repo's last release-train runs.
#
# Only the repo that carries the convention answers: <main>/bin/fleet-stable.sh
# must exist, else `kind: skip` — a team repo's own `stable` tag (if any) means
# something else, and this skill ships to team repos too.
#
# The batch's last merge = the merge commit every other member merge is an
# ancestor of (trunk is linear under squash merges, so one always is) — the
# members' MERGED PRs resolved with `gh` from --epic <N> (sub-issues →
# `gh pr list --head issue-<M> --state merged`, the fleet's one-issue-one-branch
# convention), or handed in as --merged <sha> (repeatable, any order).
# An EPIC may span repos (issue #1942): only the members filed in <repo> count
# (stable is per repo), and `--epic <owner/name>#<N>` names a parent that lives in
# another repo — so the report asks every repo its batch touched, not only the
# parent's.
#
# Output, line-anchored `key: value` (like fleet-stable.sh show):
#   kind:    current                       → 已随列车上线, no row (exit 1)
#            running|red|waiting|trainunknown|none|offtrunk|unknown
#                                          → a 还差什么 row (exit 0)
#            skip|nomerge                  → nothing to say (exit 1)
#   stable:  <short>|none|?     target:  <short> <subject>     behind:  <n>
#   train:   <status/conclusion> <run url>  — the last release-train run read
#   line:    the 列车结果 sentence for 交付了什么 / the durable comment
#   row:     <还差什么><TAB><建议下一步>   — the two cells, one clause each (#929)
#   tr:      the same row as a <tr> for the page
#   mark:    a `<!-- fleet:followup kind=human what=… -->` for the parent's
#            closing comment (issue #2672) — only when a person must look
#            (red / offtrunk / unknown); never a move to run
# Exit: 0 row due · 1 no row · 2 usage / could not read (gh, git)
#
# Reads only: `fleet-stable.sh show` (a remote-tracking fetch in <main>, nothing
# else changes there), `gh api`/`gh pr list` on the EPIC's repo.
set -u

BIN_DIR=$(cd "$(dirname "$0")" && pwd)
repo="" main="" epic="" epic_repo="" merged="" base=master remote=origin timeout=15

die() { printf 'fleet-epic-stable-row: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; }

[ "$#" -gt 0 ] || { usage; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    shift; repo="${1:-}" ;;
    --main)    shift; main="${1:-}" ;;
    --epic)    shift; epic="${1:-}" ;;
    --merged)  shift; [ -n "${1:-}" ] || die "--merged needs a sha"; merged="$merged
$1" ;;
    --base)    shift; base="${1:-master}" ;;
    --remote)  shift; remote="${1:-origin}" ;;
    --timeout) shift; timeout="${1:-15}" ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown argument $1" ;;
  esac
  shift
done
[ -n "$repo" ] || die "--repo <owner/name> is required"
[ -n "$main" ] || die "--main <checkout> is required"
[ -n "$epic" ] || [ -n "$merged" ] || die "need --epic <N> or --merged <sha>"
case "$epic" in ?*/?*'#'*) epic_repo="${epic%%#*}"; epic="${epic##*#}" ;; esac   # owner/name#N (#1942)
case "$epic" in *[!0-9]*) die "--epic wants a number, got $epic" ;; esac
[ -n "$epic_repo" ] || epic_repo="$repo"
git -C "$main" rev-parse --git-dir >/dev/null 2>&1 || die "$main is not a git checkout (--main)"

# ── 1. the convention gate ────────────────────────────────────────────────────
if [ ! -f "$main/bin/fleet-stable.sh" ]; then
  printf 'kind:    skip\nnote:    %s carries no bin/fleet-stable.sh — no release train here\n' "$repo"
  exit 1
fi
ST="$BIN_DIR/fleet-stable.sh"; [ -f "$ST" ] || ST="$main/bin/fleet-stable.sh"

# ── 2. where stable points (fetches trunk + the stable commit into <main>) ────
show=$(sh "$ST" show --dir "$main" --repo "$repo" --remote "$remote" --branch "$base" --timeout "$timeout" 2>/dev/null)
field() { printf '%s\n' "$show" | sed -n "s/^$1:[[:space:]]*//p" | sed -n 1p; }
verdict=$(field verdict); st_short=$(field stable)
[ -n "$verdict" ] || verdict=UNKNOWN

g() { git -C "$main" "$@"; }
short() { g rev-parse --short "$1" 2>/dev/null || printf '%.7s' "$1"; }
have_commit() {
  g cat-file -e "$1^{commit}" 2>/dev/null && return 0
  g -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$timeout" fetch --no-tags -q "$remote" "$1" 2>/dev/null
  g cat-file -e "$1^{commit}" 2>/dev/null
}

# ── 3. the batch's last merge ─────────────────────────────────────────────────
if [ -n "$epic" ]; then
  # only the members filed in THIS repo (issue #1942): an EPIC may span repos, and
  # another repo's #N is not this repo's issue-N branch — stable is per repo
  members=$(gh api "repos/$epic_repo/issues/$epic/sub_issues" --paginate \
      --jq '.[] | "\(.repository_url | sub("^.*/repos/"; ""))\t\(.number)"' 2>/dev/null) ||
    die "could not read #$epic's sub-issues on $epic_repo (gh auth?)"  # no-gh-ok: a hint
  members=$(printf '%s\n' "$members" | awk -F '\t' -v r="$repo" 'NF == 1 || $1 == r { print $NF }')
  for m in $members; do
    case "$m" in ''|*[!0-9]*) continue ;; esac
    sha=$(gh pr list --repo "$repo" --state merged --head "issue-$m" --limit 5 \
            --json mergeCommit,mergedAt --jq 'map(select(.mergeCommit != null)) | sort_by(.mergedAt) | last | .mergeCommit.oid // empty' 2>/dev/null) || sha=""
    [ -n "$sha" ] && merged="$merged
$sha"
  done
fi
have=""
for s in $merged; do
  if have_commit "$s"; then have="$have $s"
  else printf 'fleet-epic-stable-row: skipping %s — not a commit %s knows\n' "$s" "$remote" >&2; fi
done
if [ -z "$have" ]; then
  printf 'kind:    nomerge\nstable:  %s\nnote:    no merged member PR to compare stable against — no train result to give\n' "${st_short:-?}"
  exit 1
fi
# the last merge = the candidate every other candidate is an ancestor of (trunk is
# linear under squash merges, so one always is); ties never arise on commit time
target=""
for s in $have; do
  if [ -z "$target" ] || g merge-base --is-ancestor "$target" "$s" 2>/dev/null; then target="$s"; fi
done
target=$(g rev-parse --verify "$target^{commit}" 2>/dev/null) || die "could not resolve the merge commits in $main"
t_short=$(short "$target"); t_subj=$(g log -1 --format=%s "$target" 2>/dev/null)

# the last release-train runs (newest first): one TAB row each —
# status, conclusion, head sha, url. Unreadable ⇒ empty.
train_runs() {
  gh api "repos/$repo/actions/workflows/release-train.yml/runs?per_page=10" \
    --jq '.workflow_runs[] | "\(.status)\t\(.conclusion // "-")\t\(.head_sha)\t\(.html_url)"' 2>/dev/null
}

# ── 4. compare, and say it as the train's result ──────────────────────────────
kind="" what="" next="" line="" train="" mwhat=""
case "$verdict" in
  NONE)
    kind=none
    line="还没有稳定版标记（refs/tags/stable），列车尚未发过版"
    what="还没有稳定版标记，本批最后一次合并 $t_short 无处上线"
    next="看 release-train 为何没发版（runbook-train-stuck）" ;;
  CURRENT|BEHIND|OFFTRUNK)
    st_full=$(g rev-parse -q --verify "$st_short^{commit}" 2>/dev/null) || st_full=""
    if [ -z "$st_full" ]; then
      kind=unknown
    elif g merge-base --is-ancestor "$target" "$st_full" 2>/dev/null; then
      kind=current
      line="已随列车上线（stable = ${st_short}）"
    elif [ "$verdict" = OFFTRUNK ]; then
      kind=offtrunk
      line="未上线：稳定版 $st_short 不在 $remote/$base 上"
      what="稳定版 $st_short 不在 $remote/$base 上，本批最后一次合并 $t_short 不在其中"
      next="先看 \`fleet-stable.sh show\` 弄清它为何离开主干（release-rules 修复一节）"
    else
      n=$(g rev-list --count "$st_full..$target" 2>/dev/null || echo '?')
      runs=$(train_runs)
      live=$(printf '%s\n' "$runs" | awk -F '\t' 'NF >= 4 && $1 != "completed" { print; exit }')
      done1=$(printf '%s\n' "$runs" | awk -F '\t' 'NF >= 4 && $1 == "completed" { print; exit }')
      if [ -z "$runs" ]; then
        kind=trainunknown
        line="还没进稳定版（停在 ${st_short}），列车结论读不出来"
        what="本批最后一次合并 $t_short 还没进稳定版 ${st_short}，列车结论读不出来"
        next="看 \`gh run list --workflow release-train.yml\`"  # no-gh-ok: a hint
      elif [ -n "$live" ]; then
        kind=running url=$(printf '%s' "$live" | cut -f4)
        train="$(printf '%s' "$live" | cut -f1) $url"
        line="列车在跑（${url}）"
        what="本批最后一次合并 $t_short 还没进稳定版 ${st_short}，列车在跑"
        next="等它跑完，不用动手；卡住照 runbook-train-stuck"
      else
        concl=$(printf '%s' "$done1" | cut -f2) rsha=$(printf '%s' "$done1" | cut -f3) url=$(printf '%s' "$done1" | cut -f4)
        train="$concl $url"
        boarded=0
        [ -n "$rsha" ] && have_commit "$rsha" && g merge-base --is-ancestor "$target" "$rsha" 2>/dev/null && boarded=1
        case "$concl" in success|skipped|neutral) red=0 ;; *) red=1 ;; esac
        if [ "$red" = 1 ] && [ "$boarded" = 1 ]; then
          kind=red
          line="卡在红车 $url"
          what="本批最后一次合并 $t_short 卡在红车，稳定版停在 $st_short"
          next="照 runbook-train-stuck 修红；修好后下一趟列车自己带上"
          mwhat="列车红在 ${url}，本批没上线"
        else
          kind=waiting
          line="等下一趟列车（稳定版停在 ${st_short}）"
          what="本批最后一次合并 $t_short 还没上车，稳定版停在 $st_short"
          next="等下一趟（每小时 41 分兜底），急就 \`gh workflow run release-train.yml\`"  # no-gh-ok: a hint
        fi
      fi
    fi ;;
  *) kind=unknown ;;
esac
if [ "$kind" = unknown ]; then
  line="上线与否读不出来（$remote 不可达或 refs/tags/stable 读失败）"
  what="稳定版位置读不出来（$remote 不可达或 refs/tags/stable 读失败），落后多少未知——不是 0"
  next="联网后 \`fleet-stable.sh show\` 再看"
fi
case "$kind" in offtrunk|unknown) mwhat=$what ;; esac

printf 'kind:    %s\nstable:  %s\ntarget:  %s %s\n' "$kind" "${st_short:-?}" "$t_short" "$t_subj"
case "$kind" in running|red|waiting|trainunknown) printf 'behind:  %s\n' "$n" ;; esac
[ -n "$train" ] && printf 'train:   %s\n' "$train"
printf 'line:    %s\n' "$line"
[ "$kind" = current ] && { printf 'note:    stable already contains %s — no row\n' "$t_short"; exit 1; }
printf 'row:     %s\t%s\n' "$what" "$next"
# the <tr>: backticks become <code>; the cells carry no other markup-significant char
tr_what=$(printf '%s' "$what" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
tr_next=$(printf '%s' "$next" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/`\([^`]*\)`/<code>\1<\/code>/g')
printf 'tr:      <tr><td>%s</td><td>%s</td></tr>\n' "$tr_what" "$tr_next"
if [ -n "$mwhat" ]; then
  mwhat=$(printf '%s' "$mwhat" | sed 's/-->/—>/g' | tr -s '[:space:]' ' ' | cut -c1-200)
  printf 'mark:    <!-- fleet:followup kind=human what=%s -->\n' "$mwhat"
fi
exit 0
