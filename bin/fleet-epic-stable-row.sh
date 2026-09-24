#!/bin/sh
# fleet-epic-stable-row.sh --repo <owner/name> --main <checkout> (--epic <N> | --merged <sha> ...)
#                          [--base <trunk>] [--remote <name>] [--timeout <s>]
#   — the 「挪稳定版」 row for /fleet-epic-report's 还差什么 table (issue #1124,
#     EPIC #1117 R2). Prints the row; NEVER moves the tag.
#
# The stable mark (fleet-stable.sh, #1118) is what every login follows, and the
# operator has to remember to move it. The natural moment is the one this skill
# already owns: a batch just finished and its report is being written. So the
# report asks ONE question — does `stable` already contain this batch's last
# merge? — and when it does not, the 还差什么 table gets one more row: what is
# missing (stable trails the batch) and the exact command that fixes it.
#
# Only the repo that carries the convention gets the row: <main>/bin/fleet-stable.sh
# must exist, else `kind: skip` — a team repo's own `stable` tag (if any) means
# something else, and this skill ships to team repos too.
#
# The batch's last merge = the merge commit every other member merge is an
# ancestor of (trunk is linear under squash merges, so one always is) — the
# members' MERGED PRs resolved with `gh` from --epic <N> (sub-issues →
# `gh pr list --head issue-<M> --state merged`, the fleet's one-issue-one-branch
# convention), or handed in as --merged <sha> (repeatable, any order).
#
# Output, line-anchored `key: value` (like fleet-stable.sh show):
#   kind:    behind|none|offtrunk|unknown  → a row is due (exit 0)
#            current|skip|nomerge          → no row (exit 1)
#   stable:  <short>|none|?     target:  <short> <subject>     behind:  <n>
#   cmd:     the fleet-stable.sh move command, as the operator would paste it
#   row:     <还差什么><TAB><建议下一步>   — the two cells, one clause each (#929)
#   tr:      the same row as a <tr> for the page
# Exit: 0 row due · 1 no row · 2 usage / could not read (gh, git)
#
# Reads only: `fleet-stable.sh show` (a remote-tracking fetch in <main>, nothing
# else changes there), `gh api`/`gh pr list` on the EPIC's repo.
set -u

BIN_DIR=$(cd "$(dirname "$0")" && pwd)
repo="" main="" epic="" merged="" base=master remote=origin timeout=15

die() { printf 'fleet-epic-stable-row: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

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
case "$epic" in *[!0-9]*) die "--epic wants a number, got $epic" ;; esac
git -C "$main" rev-parse --git-dir >/dev/null 2>&1 || die "$main is not a git checkout (--main)"

# ── 1. the convention gate ────────────────────────────────────────────────────
if [ ! -f "$main/bin/fleet-stable.sh" ]; then
  printf 'kind:    skip\nnote:    %s carries no bin/fleet-stable.sh — no stable mark to move here\n' "$repo"
  exit 1
fi
ST="$BIN_DIR/fleet-stable.sh"; [ -f "$ST" ] || ST="$main/bin/fleet-stable.sh"
case "$ST" in "$HOME"/*) st_disp="~${ST#"$HOME"}" ;; *) st_disp="$ST" ;; esac

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
  members=$(gh api "repos/$repo/issues/$epic/sub_issues" --paginate --jq '.[].number' 2>/dev/null) ||
    die "could not read #$epic's sub-issues on $repo (gh auth?)"
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
  printf 'kind:    nomerge\nstable:  %s\nnote:    no merged member PR to compare stable against — nothing to move for\n' "${st_short:-?}"
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
cmd="$st_disp move $t_short"

# ── 4. compare, and say it as a row ───────────────────────────────────────────
kind="" what="" next=""
case "$verdict" in
  NONE)
    kind=none
    what="还没有稳定版标记（refs/tags/stable），各 login 无从跟起"
    next="标稳定版到 ${t_short}（本批最后一次合并）：\`$cmd\`" ;;
  CURRENT|BEHIND|OFFTRUNK)
    st_full=$(g rev-parse -q --verify "$st_short^{commit}" 2>/dev/null) || st_full=""
    if [ -z "$st_full" ]; then
      kind=unknown
    elif g merge-base --is-ancestor "$target" "$st_full" 2>/dev/null; then
      kind=current
    elif [ "$verdict" = OFFTRUNK ]; then
      kind=offtrunk
      what="稳定版 $st_short 不在 $remote/$base 上，本批最后一次合并 $t_short 不在其中"
      next="先看 \`$st_disp show\` 弄清它为何离开主干；\`fleet-stable.sh move\` 只进不退，不会自动纠正"
    else
      kind=behind
      n=$(g rev-list --count "$st_full..$target" 2>/dev/null || echo '?')
      what="稳定版还停在 ${st_short}，落后本批最后一次合并 $t_short ${n} 个提交，各 login 还没跟上"
      next="挪稳定版到 ${t_short}：\`$cmd\`"
    fi ;;
  *) kind=unknown ;;
esac
if [ "$kind" = unknown ]; then
  what="稳定版位置读不出来（$remote 不可达或 refs/tags/stable 读失败），落后多少未知——不是 0"
  next="联网后 \`$st_disp show\`；落后本批最后一次合并 $t_short 就 \`$cmd\`"
fi

printf 'kind:    %s\nstable:  %s\ntarget:  %s %s\n' "$kind" "${st_short:-?}" "$t_short" "$t_subj"
case "$kind" in
  behind)  printf 'behind:  %s\n' "$n" ;;
  current) printf 'behind:  0\nnote:    stable already contains %s — no row\n' "$t_short"; exit 1 ;;
esac
printf 'cmd:     %s\n' "$cmd"
printf 'row:     %s\t%s\n' "$what" "$next"
# the <tr>: backticks become <code>; the cells carry no other markup-significant char
tr_what=$(printf '%s' "$what" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
tr_next=$(printf '%s' "$next" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/`\([^`]*\)`/<code>\1<\/code>/g')
printf 'tr:      <tr><td>%s</td><td>%s</td></tr>\n' "$tr_what" "$tr_next"
exit 0
