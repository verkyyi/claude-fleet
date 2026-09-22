#!/bin/bash
# fleet-epic-preflight.sh [--session S] [--repo R] [--fix] [-h] — CAN THIS REPO RUN AN EPIC?
# (issue #678). The first thing `/fleet-epic plan` does, and the reason it is a
# separate script: the answer has to land in front of the operator during PHASE1,
# while they are awake, not at 03:00 when PHASE2 discovers the repo has no `epic`
# label / no sub-issues API / no account left under the ceiling.
#
# `/fleet-epic` is a GENERIC fleet skill — it ships to every fleet (claude-fleet,
# 24haowan-monorepo, tokenledger, whatever is created next), so it may assume
# NOTHING about the target repo. This is the assumption check, one screen, in
# fleet-doctor.sh's `TAG  STATE  detail` shape.
#
# What it reads, and what a miss means:
#   gh        gh on PATH + authed                     missing ⇒ blocker
#   perm      viewerPermission ≥ WRITE                read-only ⇒ blocker
#   subissue  the sub-issues API answers for this repo 404 ⇒ blocker (falling back
#             to a flat checklist is the operator's call, not this script's)
#   labels    `epic` + `autofill` + `blocked` exist   missing ⇒ FIXABLE (--fix)
#   base      FLEET_BASE_BRANCH == the repo default   drift ⇒ warn (#603)
#   deploy    FLEET_DEPLOY_REF / _CHECK (#541)        neither ⇒ merged ≡ done
#   slots     the effective concurrent-session cap    stated, never warned (#881)
#   quota     pool accounts under FLEET_ACCOUNT_CEILING  none ⇒ warn (waits for a window)
#
# Half these rows are REPO facts (gh, perm, subissue, labels) and half are FLEET
# facts (base, deploy, slots, quota) — so the two have to be resolved together or
# the screen quietly describes two different fleets. By default both come from the
# session you are standing in, which is the normal case: `/fleet-epic plan` runs
# inside the fleet it is planning for. `--session <fleet-name>` reads ANOTHER
# fleet's conf (repo included) — that is how you preflight the monorepo from the
# claude-fleet hub without moving. A bare `--repo` that disagrees with the loaded
# conf says so on its own line rather than pretending the mix is one fleet.
#
# DEFAULT IS READ-ONLY. `--fix` is the only thing that writes, and it writes
# exactly one thing: bin/fleet-labels-seed.sh against this repo. That is opt-in
# because seeding is not surgical — it creates the WHOLE canonical set, and a
# team repo sprouting a dozen unexplained labels overnight is how an operator
# loses the room. So the labels row reports, and the operator nods in PHASE1.
#
# Exit codes — the three-way verdict the skill branches on:
#   0  READY    every gate clear; plan away
#   1  FIXABLE  nothing is broken that `--fix` cannot seed (missing labels only)
#   3  BLOCKED  a real blocker; an EPIC cannot run here until a human changes something
#   2  usage / no fleet resolved (cannot tell you anything about a repo it can't name)
# Warnings never change the verdict: they are the "this will hurt" column, and
# whether it hurts enough to wait is the operator's call, not a script's.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

repo_arg='' sess_arg='' do_fix=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    shift; repo_arg="${1:-}" ;;
    --session) shift; sess_arg="${1:-}" ;;
    --fix)     do_fix=1 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-epic-preflight: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)         printf 'fleet-epic-preflight: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# --- output helpers (color only on a tty), deliberately fleet-doctor's shape ---
if [ -t 1 ]; then
  R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
  C=$(printf '\033[36m'); B=$(printf '\033[1m'); Z=$(printf '\033[0m')
else
  R=''; G=''; Y=''; C=''; B=''; Z=''
fi
fails=0; warns=0; fixes=0
pass() { printf '  %sPASS%s  %-9s %s\n' "$G" "$Z" "$1" "$2"; }
warn() { printf '  %sWARN%s  %-9s %s\n' "$Y" "$Z" "$1" "$2"; warns=$((warns+1)); }
fixme() { printf '  %sFIX %s  %-9s %s\n' "$C" "$Z" "$1" "$2"; fixes=$((fixes+1)); }
fail() { printf '  %sFAIL%s  %-9s %s\n' "$R" "$Z" "$1" "$2"; fails=$((fails+1)); }
note() { printf '        %s\n' "$1"; }

# --- which fleet, which repo --------------------------------------------------
# Repo resolution mirrors fleet-pr-verdict.sh / fleet-issue-file.sh: an explicit
# --repo wins, then the conf's FLEET_REPO, then this fleet's cached repo.
sess="${sess_arg:-$(fleet_current_session)}"
if [ -n "$sess_arg" ] && [ ! -f "$(fleet_conf_file "$sess_arg")" ]; then
  printf 'fleet-epic-preflight: no conf for fleet "%s" (%s) — name it exactly as fleet-up.sh created it\n' \
    "$sess_arg" "$(fleet_conf_file "$sess_arg")" >&2
  exit 2
fi
fleet_load_conf "$sess"
conf_repo="${FLEET_REPO:-}"
repo="${repo_arg:-$conf_repo}"
if [ -z "$repo" ]; then
  _r=$(fleet_repo_cached "$sess" 2>/dev/null); [ -n "$_r" ] && repo="$_r"
fi
[ -n "$repo" ] || {
  printf 'fleet-epic-preflight: no repo resolved (pass --repo or --session, or run inside a fleet)\n' >&2; exit 2; }

printf '%sepic preflight%s  %s%s\n' "$B" "$Z" "$repo" "${sess:+  (fleet $sess)}"
[ "$do_fix" = 1 ] && printf '  %s--fix: missing labels WILL be seeded%s\n' "$Y" "$Z"
# An explicit --repo does NOT re-point the conf, so the fleet rows below still
# describe $sess. Say it out loud rather than letting the screen read as one fleet.
if [ -n "$repo_arg" ] && [ -n "$conf_repo" ] && [ "$repo_arg" != "$conf_repo" ]; then
  note "--repo overrides the repo only: base/deploy/slots/quota below are still fleet $sess's (conf repo $conf_repo). Use --session for the other fleet's own knobs."
fi

# --- gh: everything downstream is a gh call ------------------------------------
gh_ok=0
if ! command -v gh >/dev/null 2>&1; then
  fail gh "not on PATH — an EPIC is issues, sub-issues and PRs end to end; none of it works without gh"
elif ! gh auth status >/dev/null 2>&1; then
  fail gh "installed but NOT authed — \`gh auth login\` (cannot file, label, link or land)"
else
  gh_ok=1
  pass gh "authed"
fi

# --- repo: one read, three answers (permission, trunk, issues on/off) ----------
perm=''; defbranch=''; hasissues=''
if [ "$gh_ok" = 1 ]; then
  rv=$(gh repo view "$repo" --json viewerPermission,defaultBranchRef,hasIssuesEnabled \
        -q '[(.viewerPermission // ""), (.defaultBranchRef.name // ""), (.hasIssuesEnabled|tostring)] | @tsv' 2>/dev/null)
  IFS=$'\t' read -r perm defbranch hasissues <<<"$rv"
  case "$perm" in
    ADMIN|MAINTAIN|WRITE)
      pass perm "$repo: $perm — can file sub-issues, label them and land their PRs" ;;
    '')
      fail perm "$repo: could not read viewerPermission — no such repo, offline, or the token lacks \`repo\` scope" ;;
    *)
      fail perm "$repo: $perm — an EPIC files sub-issues and merges PRs here; that needs WRITE or better" ;;
  esac
fi

# --- sub-issues API: the one capability with no workaround ---------------------
# The EPIC shape IS parent→child (bin/fleet-issue-file.sh --parent). Where the API
# is absent the batch degrades to a flat checklist in one issue body — workable,
# but a different plan, so the operator has to agree to it. Hence: blocker.
# Probing read-only means probing against an issue that already exists; the POST
# side is covered by `perm` above.
if [ "$gh_ok" = 1 ] && [ -n "$perm" ]; then
  if [ "$hasissues" = false ]; then
    fail subissue "$repo has ISSUES DISABLED — an EPIC is one parent issue plus a sub-issue per slice; turn issues on first"
  else
    owner="${repo%%/*}"; name="${repo#*/}"
    probe=$(gh issue list --repo "$repo" --state all --limit 1 --json number -q '.[0].number' 2>/dev/null)
    probe="${probe//[^0-9]/}"
    if [ -z "$probe" ]; then
      warn subissue "no issue in $repo to probe against — sub-issue linking is UNVERIFIED here (GA on github.com; older GitHub Enterprise 404s). The first \`--parent\` filing finds out."
    elif sub_err=$(gh api "repos/$owner/$name/issues/$probe/sub_issues" 2>&1 >/dev/null); then
      pass subissue "the sub-issues API answers for $repo (probed #$probe) — parent→child linking works"
    else
      case "$sub_err" in
        *404*|*"Not Found"*)
          fail subissue "the sub-issues API 404s for $repo — every slice would file standalone with no parent link. Falling back to a flat checklist in the EPIC body is a DIFFERENT plan: get the operator's nod before running one." ;;
        *)
          warn subissue "could not probe the sub-issues API on #$probe (${sub_err%%$'\n'*}) — treat parent→child linking as unverified" ;;
      esac
    fi
  fi
fi

# --- labels: the only row `--fix` can clear ------------------------------------
# `epic` marks the tracking parent, `autofill` is how a planned slice gets picked
# up hands-off, `blocked` is how `run` marks a slice it had to stop. All three are
# in fleet_labels_canonical, so the seeder installs them; the check is whether
# THIS repo has been seeded at all.
EPIC_LABELS='epic autofill blocked'
labels_missing() {
  local have miss='' l
  have=$(gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null)
  for l in $EPIC_LABELS; do
    printf '%s\n' "$have" | grep -qxF -- "$l" || miss="$miss $l"
  done
  printf '%s' "${miss# }"
}
if [ "$gh_ok" = 1 ] && [ -n "$perm" ]; then
  missing=$(labels_missing)
  if [ -n "$missing" ] && [ "$do_fix" = 1 ]; then
    # The seeder is idempotent (`gh label create --force`) and reconciles the WHOLE
    # canonical set, not just the missing three — that breadth is exactly why this
    # needs --fix. Re-read afterwards rather than trusting its exit code.
    n_canon=$(fleet_labels_allowed | grep -c .)
    note "--fix: seeding this repo's canonical label set ($n_canon labels) via fleet-labels-seed.sh …"
    bash "$BIN/fleet-labels-seed.sh" --repo "$repo" >/dev/null 2>&1
    missing=$(labels_missing)
  fi
  if [ -z "$missing" ]; then
    pass labels "epic · autofill · blocked all present in $repo"
  elif [ "$do_fix" = 1 ]; then
    fail labels "still missing after --fix:$missing — \`gh label create\` failed (rerun \`bash $BIN/fleet-labels-seed.sh --repo $repo\` to see why)"
  else
    fixme labels "missing in $repo: $missing — rerun with --fix to seed them (that seeds the FULL canonical set, so on a team repo get the nod first)"
  fi
fi

# --- base branch: an EPIC is a whole batch aimed at one branch (#603) ----------
cbase="${FLEET_BASE_BRANCH:-}"
if [ -z "$cbase" ]; then
  warn base "this fleet's conf has no FLEET_BASE_BRANCH — every EPIC slice would branch from a guess; set it (dash prefix+c)"
elif [ -z "$defbranch" ]; then
  warn base "base \"$cbase\" from the conf — could not read $repo's default branch, so it is unverified"
elif [ "$cbase" = "$defbranch" ]; then
  pass base "$cbase — the repo default; every slice forks from and lands on the trunk"
else
  warn base "base \"$cbase\" is NOT $repo's default (\"$defbranch\") — an ENTIRE batch would land where nobody ships (#603); fix the conf before planning"
fi

# --- deploy: what "done" means for a slice in this repo (#541) -----------------
dref="${FLEET_DEPLOY_REF:-}"
# A conf-written "~/..." is a LITERAL tilde (a quoted assignment never expanded it).
# shellcheck disable=SC2088
case "$dref" in "~/"*) dref="$HOME/${dref#\~/}" ;; esac
dchk="${FLEET_DEPLOY_CHECK:-}"
if [ -n "$dref" ]; then
  if git -C "$dref" rev-parse --git-dir >/dev/null 2>&1; then
    pass deploy "FLEET_DEPLOY_REF=$dref — a slice is DONE when its merge sha is an ancestor of that checkout's HEAD"
  else
    warn deploy "FLEET_DEPLOY_REF=$dref is not a git checkout — every slice's deploy state reads \`unknown\`, so \`report\` can never say live"
  fi
elif [ "$dchk" = actions ]; then
  pass deploy "FLEET_DEPLOY_CHECK=actions — a slice is DONE when the post-merge Actions runs for its sha go green"
elif [ -n "$dchk" ]; then
  warn deploy "FLEET_DEPLOY_CHECK=\"$dchk\" is not a mode this fleet knows (only \`actions\`) — deploy state stays off"
else
  pass deploy "neither FLEET_DEPLOY_REF nor FLEET_DEPLOY_CHECK is set — in this repo MERGED ≡ done"
fi

# --- slots: how many slices can actually run at once ---------------------------
# The per-fleet cap only ever LOWERS the machine-wide one (fleet_capacity_block),
# so the effective ceiling is the min. It is STATED, never warned about (issue
# #881): the caps are the operator's own settings, and an EPIC works inside them —
# the run keeps 4–6 busy within the cap and retries a full one next tick. A WARN
# here read as advice to change the cap, and the plan page turned it into a
# 「开跑前要处理」 the operator never asked for.
fmax="${FLEET_MAX_SESSIONS:-0}"; gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}"
case "$fmax" in ''|*[!0-9]*) fmax=0 ;; esac
case "$gmax" in ''|*[!0-9]*) gmax=8 ;; esac
if [ "$fmax" -gt 0 ]; then
  eff=$fmax; [ "$gmax" -lt "$eff" ] && eff=$gmax
  src="FLEET_MAX_SESSIONS=$fmax, global $gmax"
else
  eff=$gmax
  src="this fleet sets no FLEET_MAX_SESSIONS, so the machine-wide $gmax applies"
fi
if [ "$eff" -lt 4 ]; then
  pass slots "up to $eff concurrent session(s) — the run keeps as many busy as the cap allows ($src)"
else
  pass slots "up to $eff concurrent sessions — the run keeps 4–6 busy within it ($src)"
fi

# --- quota: is there room to START a batch right now? --------------------------
# Cached read only (the quotawatch daemon owns the refresh) — a preflight must
# never be the thing that stalls on ccquota. No pool ⇒ no opinion, not a fault.
ceiling="${FLEET_ACCOUNT_CEILING:-85}"
case "$ceiling" in ''|*[!0-9]*) ceiling=85 ;; esac
qrows=$(bash "$BIN/fleet-account.sh" quota --cached 2>/dev/null)
n_rows=$(printf '%s' "$qrows" | grep -c .)
if [ -z "${CCQUOTA_HUB_URL:-}" ]; then
  # No pool and a blind pool both produce zero rows, and for a BATCH they are
  # opposite answers: "nothing to schedule around" vs "I cannot tell you whether
  # there is room". Split them on the hub URL, the same gate fleet-doctor.sh uses.
  pass quota "no ccquota pool configured for this fleet — sessions run on whatever account they get; nothing to schedule a batch around"
elif [ "$n_rows" -eq 0 ]; then
  warn quota "a ccquota pool IS configured but its cached reading is empty — nothing here can say whether there is room to start a batch; \`bash $BIN/fleet-quotawatch.sh --status\` says which kind of blind it is (\`stale\` = no tick has run at all, #551; \`blind\` = every tick ran and came back with nothing, #684)"
else
  under=$(printf '%s\n' "$qrows" | awk -F'\t' -v c="$ceiling" \
            '{u=($2+0>$3+0)?$2+0:$3+0; if(u<c) n++} END{print n+0}')
  if [ "$under" -eq 0 ]; then
    warn quota "all $n_rows pool account(s) are at or over ${ceiling}% — a batch started NOW immediately waits for a window; check \`fleet-account.sh quota\` for the nearest reset"
  elif [ "$under" -eq 1 ]; then
    warn quota "only 1 of $n_rows pool accounts is under ${ceiling}% — 4–6 concurrent slices will exhaust it mid-run and stall the batch"
  else
    pass quota "$under of $n_rows pool accounts under ${ceiling}% — room to open a 4–6 slice batch"
  fi
fi

# --- verdict -------------------------------------------------------------------
printf '\n'
if [ "$fails" -gt 0 ]; then
  printf '%sBLOCKED%s — %d blocker(s), %d warn. An EPIC cannot run in %s until those are fixed by hand.\n' \
    "$R" "$Z" "$fails" "$warns" "$repo"
  exit 3
elif [ "$fixes" -gt 0 ]; then
  # The rerun hint has to be COPY-PASTEABLE, which means carrying --session: a
  # preflight of another fleet that suggests a bare --fix would seed the wrong repo.
  printf '%sFIXABLE%s — %d gap(s) --fix can seed, %d warn. Show the operator, then rerun: %s%s%s --fix\n' \
    "$C" "$Z" "$fixes" "$warns" "$0" \
    "${sess_arg:+ --session $sess_arg}" "${repo_arg:+ --repo $repo_arg}"
  exit 1
elif [ "$warns" -gt 0 ]; then
  printf '%sREADY%s — %d warn; an EPIC can run in %s, with the caveats above.\n' "$Y" "$Z" "$warns" "$repo"
  exit 0
else
  printf '%sREADY%s — %s can run an EPIC.\n' "$G" "$Z" "$repo"
  exit 0
fi
