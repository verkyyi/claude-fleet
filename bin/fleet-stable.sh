#!/bin/sh
# fleet-stable.sh show | move [<sha>] [--dry-run] [--allow-no-checks] [--force]
#                 [--dir <checkout>] [--remote <name>] [--branch <trunk>]
#                 [--repo <owner/name>] [--timeout <s>] [--macos-timeout <s>]
#                 [--ignore-check <name>]
#   — the "stable" mark every install follows (issue #1118, EPIC #1117 C1).
#
# Merging to master used to be the same event as "this reaches all my machines"
# — or nothing did. There was no place that said "this version, I vouch for it".
# `refs/tags/stable` on the public repo is that place: the operator moves it with
# ONE command, and every login/machine follows the tag (C3, #1120), never master.
#
#   show   where `stable` points and how many commits it trails origin/<trunk>.
#          A missing tag is said out loud (`stable: none`), never read as 0.
#   move   move `stable` to <sha> (default: origin/<trunk>). Refuses unless ALL of:
#            1. the target is a commit on origin/<trunk> (no PR branch, no
#               local-only commit — every install fast-forwards along trunk);
#            2. FORWARD ONLY — the old stable is an ancestor of the target
#               (moving back, or sideways, is refused; the same target is a no-op);
#            3. the target's CI is all green: every check run on it (gh api
#               repos/<repo>/commits/<sha>/check-runs) is completed with
#               success / neutral / skipped. Pending = not green. ZERO check runs
#               is refused too — push CI is path-filtered, so a docs-only commit
#               has none; `--allow-no-checks` accepts that deliberately. The
#               `macOS shard *` runs are not counted here: gate 5 owns them, and
#               neither is the one run `--ignore-check <name>` names exactly —
#               the caller's own job, when the caller is CI (stable-auto.yml): it
#               runs on the commit it moves to and is never finished yet;
#            4. an old session of the current stable keeps working on the target
#               (issue #2075, EPIC #2074 C2): bin/fleet-oldcfg-replay.py replays
#               stable's hook table, the mod's tool list and the MCP servers
#               against the target's tree in a sandbox — a script gone, a hook
#               erroring or hanging, a tool with no handler REFUSES (reason
#               `oldcfg:`), and so does a replay that cannot run (no evidence is
#               not green). --force moves anyway and appends one line to
#               logs/stable-move.log (FLEET_STABLE_LOG): the operator's call, on
#               the record (EPIC #2074 决定 2);
#            5. the BSD half is green ON THE TARGET (issue #2286): since the macOS
#               job left the PR (it runs on master after the merge), this is the
#               one place it gates anything. The newest run of the macOS workflow
#               (FLEET_STABLE_MACOS_WORKFLOW, default selftests-macos.yml) that is
#               about the target — a push / nightly run whose head is the target,
#               or a dispatch whose name says `@ <target sha>` — must be completed
#               + success; a cancelled run (a newer push superseded it) counts as
#               none. Red REFUSES (reason `macos:`); a run still going is waited
#               for; NO run (path-filtered, cancelled) dispatches the FULL suite on
#               exactly the target (`gh workflow run … -f sha=<target>`) and waits
#               for it, up to --macos-timeout (default 3600s) — a run that does
#               not finish in time refuses. --dry-run never dispatches or waits:
#               no green run = refused. --force moves past it and logs one line,
#               like gate 4. A target whose tree has no such workflow has no BSD
#               half to wait for and passes.
#            6. a tree that ships the machine updater (bin/fleet-node-update.py,
#               issue #2334) carries a release.json its one validator accepts
#               (`fleet-node-update.py check-release`): what every managed machine
#               installs from this release. Missing / invalid REFUSES (reason
#               `release:`); --force moves anyway and logs, like gates 4 and 5. A
#               tree without the updater has nothing to declare and passes.
#          Then pushes <sha>:refs/tags/stable with --force-with-lease pinned to
#          the value it read, so two concurrent moves cannot both win — the
#          loser's push is rejected and nothing is overwritten.
#          --dry-run runs every check and prints the push, without pushing.
#
# The tag is lightweight. The source of truth is the REMOTE ref (read with
# `git ls-remote`, https, no credentials); no local `stable` tag is written, so
# the checkout this runs in is never changed beyond a remote-tracking fetch.
#
# `show` prints line-anchored `key: value` lines (fleet-doctor parses them):
#   stable:  <sha>|none      subject: <first line>     trunk: origin/<b> <sha>
#   behind:  <n>|?           verdict: CURRENT|BEHIND|NONE|OFFTRUNK|UNKNOWN
#
# Exit codes:
#   show  0 tag read (CURRENT/BEHIND/OFFTRUNK) · 1 NONE · 2 UNKNOWN / usage
#   move  0 moved (or already there, or dry-run passed) · 2 usage / read error
#         3 refused (not on trunk / backward / CI not green / oldcfg red / macos not
#           green / release.json missing or invalid) · 4 push failed
#           (lease lost to a concurrent move, or no push rights)
set -u

BIN_DIR=$(cd "$(dirname "$0")" && pwd)
dir="$(cd "$BIN_DIR/.." && pwd)"
remote=origin branch=master repo="" timeout=15 dry=0 allow_nochecks=0 force=0 macos_timeout=3600 ignore_check=""
cmd="" target=""
TAG=stable

die() { printf 'fleet-stable: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'fleet-stable: REFUSED — %s\n' "$*" >&2; exit 3; }

[ "$#" -gt 0 ] || { sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    show|move)         [ -z "$cmd" ] || die "one subcommand only"; cmd="$1" ;;
    --dry-run|-n)      dry=1 ;;
    --allow-no-checks) allow_nochecks=1 ;;
    --force)           force=1 ;;
    --dir)             shift; dir="${1:-}" ;;
    --remote)          shift; remote="${1:-}" ;;
    --branch)          shift; branch="${1:-}" ;;
    --repo)            shift; repo="${1:-}" ;;
    --timeout)         shift; timeout="${1:-15}" ;;
    --macos-timeout)   shift; macos_timeout="${1:-3600}" ;;
    --ignore-check)    shift; ignore_check="${1:-}" ;;
    -h|--help)         sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                die "unknown flag $1" ;;
    *)                 [ "$cmd" = move ] && [ -z "$target" ] || die "unexpected argument $1"
                       target="$1" ;;
  esac
  shift
done
[ -n "$cmd" ] || die "usage: fleet-stable.sh show | move [<sha>] [--dry-run] [--force]"
case "$timeout" in ''|*[!0-9]*|0) timeout=15 ;; esac
case "$macos_timeout" in ''|*[!0-9]*) macos_timeout=3600 ;; esac
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "$dir is not a git checkout (--dir)"

# git's own stall abort bounds every network call — macOS has no timeout(1).
g() { git -C "$dir" -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$timeout" "$@"; }

# The remote tag's commit. Prints the sha, or nothing when the tag is absent;
# returns 2 when the remote could not be read (which is NOT "absent").
remote_stable() {
  _ls=$(g ls-remote "$remote" "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null) || return 2
  # An annotated tag lists its peeled commit as ^{}; prefer that line.
  _peeled=$(printf '%s\n' "$_ls" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')
  [ -n "$_peeled" ] && { printf '%s\n' "$_peeled"; return 0; }
  printf '%s\n' "$_ls" | awk 'NF {print $1; exit}'
}

fetch_trunk() {
  g fetch --no-tags -q "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null
}

# Make sure <sha> exists locally (a tag may point at a commit this clone lacks).
have_commit() {
  git -C "$dir" cat-file -e "$1^{commit}" 2>/dev/null && return 0
  g fetch --no-tags -q "$remote" "$1" 2>/dev/null
  git -C "$dir" cat-file -e "$1^{commit}" 2>/dev/null
}

short() { git -C "$dir" rev-parse --short "$1" 2>/dev/null || printf '%.7s' "$1"; }
subject() { git -C "$dir" log -1 --format=%s "$1" 2>/dev/null; }

do_show() {
  old=$(remote_stable); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'stable:  ?\nverdict: UNKNOWN\nnote:    could not read refs/tags/%s from %s\n' "$TAG" "$remote"
    exit 2
  fi
  if fetch_trunk; then tip=$(git -C "$dir" rev-parse -q --verify "refs/remotes/$remote/$branch^{commit}"); else tip=""; fi
  if [ -z "$old" ]; then
    printf 'stable:  none\ntrunk:   %s/%s %s\nverdict: NONE\nnote:    no refs/tags/%s on %s yet — nothing to follow; set it with: fleet-stable.sh move <sha>\n' \
      "$remote" "$branch" "$(short "${tip:-?}")" "$TAG" "$remote"
    exit 1
  fi
  printf 'stable:  %s\n' "$(short "$old")"
  if [ -z "$tip" ] || ! have_commit "$old"; then
    printf 'behind:  ?\nverdict: UNKNOWN\nnote:    could not fetch %s/%s or the stable commit — behind count unknown, NOT 0\n' "$remote" "$branch"
    exit 2
  fi
  printf 'subject: %s\ntrunk:   %s/%s %s\n' "$(subject "$old")" "$remote" "$branch" "$(short "$tip")"
  behind=$(git -C "$dir" rev-list --count "$old..$tip")
  printf 'behind:  %s\n' "$behind"
  if ! git -C "$dir" merge-base --is-ancestor "$old" "$tip"; then
    printf 'verdict: OFFTRUNK\nnote:    stable is not on %s/%s — the next move must come from trunk and descend from it\n' "$remote" "$branch"
  elif [ "$behind" -eq 0 ]; then
    printf 'verdict: CURRENT\n'
  else
    printf 'verdict: BEHIND\n'
  fi
  exit 0
}

# owner/name from the remote URL, unless --repo said so.
repo_slug() {
  [ -n "$repo" ] && { printf '%s\n' "$repo"; return; }
  git -C "$dir" remote get-url "$remote" 2>/dev/null |
    sed -n 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | sed 's#\.git$##'
}

# Every check run on <sha>, one "status conclusion name" line each.
check_runs() {
  gh api --paginate "repos/$1/commits/$2/check-runs?per_page=100" \
    --jq '.check_runs[] | "\(.status) \(.conclusion) \(.name)"'
}

# One line per FORCED move past gate 4 or 5 is kept (FLEET_STABLE_LOG).
force_log() {   # force_log <old> <new> <gate> <why> <what was forced past>
  _log="${FLEET_STABLE_LOG:-$BIN_DIR/../logs/stable-move.log}"
  mkdir -p "$(dirname "$_log")" 2>/dev/null
  printf '%s\tforced\told=%s\tnew=%s\tby=%s\t%s=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(short "$1")" "$(short "$2")" "${USER:-?}" "$3" "$4" >> "$_log" 2>/dev/null
  printf '%s: FORCED past %s — one line in %s\n' "$3" "$5" "$_log" >&2
}

# 6. A tree that ships the machine updater declares what a managed machine runs
# (issue #2334): release.json, checked by the updater's own validator.
release_gate() {   # release_gate <old> <new>
  git -C "$dir" cat-file -e "$2:bin/fleet-node-update.py" 2>/dev/null || return 0
  if _rj=$(git -C "$dir" show "$2:release.json" 2>/dev/null) && [ -n "$_rj" ]; then
    if _why=$(printf '%s\n' "$_rj" | python3 "$BIN_DIR/fleet-node-update.py" check-release - 2>&1 >/dev/null); then
      printf 'release: %s carries a valid release.json\n' "$(short "$2")"; return 0
    fi
    _why="$(short "$2"): ${_why:-release.json could not be checked}"
  else
    _why="$(short "$2") ships bin/fleet-node-update.py but no release.json — a managed machine cannot tell what to install"
  fi
  if [ "$force" -eq 1 ]; then force_log "$1" "$2" release "$_why" "release.json"; return 0; fi
  refuse "release: $_why — fix it (docs/MANAGED-NODE.md §7), or --force to move anyway (logged)"
}

# 4. An old session of the current stable, run on the target (issue #2075): the
# replay's findings are printed as they came.
oldcfg_log() { force_log "$1" "$2" oldcfg "$3" "the replay"; }
oldcfg_gate() {   # oldcfg_gate <old> <new>
  _rep="$BIN_DIR/fleet-oldcfg-replay.py"
  if [ ! -f "$_rep" ] || ! command -v python3 >/dev/null 2>&1; then
    _why="cannot replay an old session (bin/fleet-oldcfg-replay.py or python3 missing) — no evidence it keeps working"
    if [ "$force" -eq 1 ]; then oldcfg_log "$1" "$2" "not run: $_why"; return 0; fi
    refuse "oldcfg: $_why; --force moves anyway (logged)"
  fi
  _out=$(python3 "$_rep" --dir "$dir" --old "$1" --new "$2" -q 2>&1); _rc=$?
  _last=$(printf '%s\n' "$_out" | tail -n 1)
  if [ "$_rc" -eq 0 ]; then printf '%s\n' "$_last"; return 0; fi
  printf '%s\n' "$_out" | sed 's/^/  /' >&2
  if [ "$force" -eq 1 ]; then oldcfg_log "$1" "$2" "$_last"; return 0; fi
  refuse "oldcfg: an old session of stable $(short "$1") would break on $(short "$2") — fix the findings above (CONTRIBUTING «老会话兼容», #2068), or --force to move anyway (logged)"
}

# 5. The BSD half, on the target (issue #2286).
MACOS_WF="${FLEET_STABLE_MACOS_WORKFLOW:-selftests-macos.yml}"
# The newest run of the macOS workflow ABOUT <sha>, as
# "status<TAB>conclusion<TAB>event<TAB>id": a non-PR run whose head is <sha>, or a
# dispatch named `… @ <sha>` (a dispatch attaches to the branch head, so its name
# is the only place the commit is). Cancelled runs are skipped — superseded by a
# newer push, they say nothing. Prints nothing when there is none; rc 2 = unread.
macos_row() {   # macos_row <slug> <sha>
  _rows=$(gh api "repos/$1/actions/workflows/$MACOS_WF/runs?per_page=100" \
    --jq '.workflow_runs[] | [.head_sha, .status, (.conclusion // ""), .event, (.id|tostring), (.display_title // "")] | @tsv') || return 2
  printf '%s\n' "$_rows" | awk -F'\t' -v sha="$2" '
    NF < 5 || $4 ~ /^pull_request/ || $3 == "cancelled" { next }
    $1 == sha || $6 ~ ("@ " sha "$") { print $2 "\t" $3 "\t" $4 "\t" $5; exit }'
}
macos_pace() { _p="${FLEET_STABLE_MACOS_POLL:-30}"; case "$_p" in ''|*[!0-9]*|0) _p=30 ;; esac; printf '%s' "$_p"; }
macos_gate() {   # macos_gate <old> <new> <slug>
  if ! git -C "$dir" cat-file -e "$2:.github/workflows/$MACOS_WF" 2>/dev/null; then
    printf 'macos: %s carries no .github/workflows/%s — no BSD half to wait for\n' "$(short "$2")" "$MACOS_WF"; return 0
  fi
  _row=$(macos_row "$3" "$2") || die "could not read the $MACOS_WF runs on $3 (gh auth?)"
  if [ -z "$_row" ]; then
    if [ "$force" -eq 1 ]; then force_log "$1" "$2" macos "no macOS run on the target" "the BSD half (no run)"; return 0; fi
    [ "$dry" -eq 0 ] || refuse "macos: no green macOS run on $(short "$2") yet — a real move dispatches the full suite on it and waits; --dry-run does neither"
    gh workflow run "$MACOS_WF" --repo "$3" --ref "$branch" -f "sha=$2" >/dev/null 2>&1 ||
      refuse "macos: no macOS run on $(short "$2") and the dispatch failed (gh workflow run $MACOS_WF -f sha=$2) — no evidence the BSD half is green"
    printf 'macos: no run on %s — dispatched the full suite on it; waiting up to %ss\n' "$(short "$2")" "$macos_timeout" >&2
  fi
  _waited=0 _said=''
  while :; do
    case "$_row" in completed"	"*) break ;; esac
    [ -z "$_row" ] || [ -n "$_said" ] || { printf 'macos: run %s on %s is %s — waiting\n' "$(printf '%s' "$_row" | cut -f4)" "$(short "$2")" "${_row%%	*}" >&2; _said=1; }
    if [ "$dry" -eq 1 ] && [ -n "$_row" ]; then
      refuse "macos: the macOS run on $(short "$2") is still ${_row%%	*} — --dry-run does not wait"
    fi
    if [ "$_waited" -ge "$macos_timeout" ]; then
      [ "$force" -eq 0 ] || { force_log "$1" "$2" macos "not finished in ${macos_timeout}s" "the BSD half (unfinished)"; return 0; }
      refuse "macos: the macOS run on $(short "$2") did not finish in ${macos_timeout}s — run move again later (it waits for the same run)"
    fi
    sleep "$(macos_pace)"; _waited=$((_waited + $(macos_pace)))
    _row=$(macos_row "$3" "$2") || _row=''
  done
  _concl=$(printf '%s' "$_row" | cut -f2) _ev=$(printf '%s' "$_row" | cut -f3) _id=$(printf '%s' "$_row" | cut -f4)
  if [ "$_concl" = success ]; then
    printf 'macos: green on %s (run %s, %s)\n' "$(short "$2")" "$_id" "$_ev"; return 0
  fi
  [ "$force" -eq 0 ] || { force_log "$1" "$2" macos "run $_id $_concl" "the BSD half ($_concl)"; return 0; }
  refuse "macos: the newest macOS run on $(short "$2") is $_concl (run $_id, $_ev: https://github.com/$3/actions/runs/$_id) — fix it (its breakage issue), or --force to move anyway (logged)"
}

do_move() {
  old=$(remote_stable) || die "could not read refs/tags/$TAG from $remote — not moving blind"
  fetch_trunk || die "could not fetch $remote/$branch"
  tip=$(git -C "$dir" rev-parse --verify "refs/remotes/$remote/$branch^{commit}") || die "no $remote/$branch"
  if [ -z "$target" ]; then new="$tip"
  else
    have_commit "$target" || :
    new=$(git -C "$dir" rev-parse -q --verify "$target^{commit}") || die "unknown commit $target"
  fi

  git -C "$dir" merge-base --is-ancestor "$new" "$tip" ||
    refuse "$(short "$new") is not on $remote/$branch — stable only ever names a trunk commit"
  if [ -n "$old" ]; then
    have_commit "$old" || die "could not fetch the current stable commit $(short "$old")"
    if [ "$old" = "$new" ]; then
      printf 'stable already at %s — nothing to move\n' "$(short "$new")"; exit 0
    fi
    git -C "$dir" merge-base --is-ancestor "$old" "$new" ||
      refuse "$(short "$new") does not descend from the current stable $(short "$old") — stable only moves FORWARD"
  fi

  slug=$(repo_slug); [ -n "$slug" ] || die "cannot tell the GitHub repo from $remote — pass --repo owner/name"
  runs=$(check_runs "$slug" "$new") || die "could not read check runs for $(short "$new") on $slug (gh auth?)"
  # The macOS shards are gate 5's (issue #2286): a push run a later push cancelled
  # is no verdict, and a running one is waited for there, not refused here.
  # So is the one run --ignore-check names (the CI job running this move).
  runs=$(printf '%s\n' "$runs" | awk -v ign="$ignore_check" '
    NF && !($3 == "macOS" && $4 == "shard") {
      n = $0; sub(/^[^ ]+ [^ ]+ /, "", n)
      if (ign != "" && n == ign) next
      print
    }')
  bad=$(printf '%s\n' "$runs" | awk 'NF && !($1=="completed" && ($2=="success" || $2=="neutral" || $2=="skipped"))')
  total=$(printf '%s\n' "$runs" | awk 'NF' | wc -l | tr -d ' ')
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | sed 's/^/  not green: /' >&2
    refuse "$(short "$new") has check runs that are not green — CI must be all green to move stable"
  fi
  if [ "$total" -eq 0 ] && [ "$allow_nochecks" -ne 1 ]; then
    refuse "$(short "$new") has NO check runs (path-filtered CI?) — no evidence it is green; pick a commit CI ran on, or pass --allow-no-checks"
  fi
  release_gate "$old" "$new"
  [ -z "$old" ] || oldcfg_gate "$old" "$new"
  macos_gate "$old" "$new" "$slug"

  # Lease: the tag must still hold exactly what we read ("" = must not exist).
  lease="refs/tags/$TAG:$old"
  if [ -n "$old" ]; then from=$(short "$old"); else from=none; fi
  printf 'stable: %s -> %s  (%s)\n' "$from" "$(short "$new")" "$(subject "$new")"
  printf 'checks: %s green on %s\n' "$total" "$slug"
  if [ "$old" ]; then printf 'forward: +%s commit(s)\n' "$(git -C "$dir" rev-list --count "$old..$new")"; fi
  if [ "$dry" -eq 1 ]; then
    printf 'dry-run: would run: git push --force-with-lease=%s %s %s:refs/tags/%s\n' "$lease" "$remote" "$new" "$TAG"
    exit 0
  fi
  if ! g push -q "--force-with-lease=$lease" "$remote" "$new:refs/tags/$TAG"; then
    printf 'fleet-stable: push FAILED — stable moved under us (lease lost) or no push rights; re-run show and try again\n' >&2
    exit 4
  fi
  printf 'moved: refs/tags/%s = %s\n' "$TAG" "$(short "$new")"
}

case "$cmd" in
  show) do_show ;;
  move) do_move ;;
esac
