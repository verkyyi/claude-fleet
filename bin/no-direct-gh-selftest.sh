#!/bin/bash
# no-direct-gh-selftest.sh — who still talks to GitHub directly (issue #3595, EPIC
# #3570 共同约定 2: 一扇门). The ticket door left with issue #4898 (the hub task
# record is the only ticket); a forge (branches, PRs, checks) is reached only
# through the GitHub layer. Everything else that spells a `gh issue|pr|api|search|
# label|repo|run|auth` call is counted here, and the count only goes DOWN:
#
#   • a file that is not in bin/no-direct-gh.baseline and calls gh ⇒ FAIL (a new
#     direct road — go through the door, or the GitHub layer);
#   • a file in the baseline that no longer calls gh ⇒ FAIL until its line is
#     deleted (the ratchet: the number the EPIC reads is the baseline's length).
#
# Counted: bin/*.sh, bin/*.py and hooks/*, selftests aside. A whole-line comment
# is not a call, nor a line marked `no-gh-ok: <why>` (a message that names a gh
# command without running it). This refines the EPIC's 读数口径 grep — which
# counts comments too — to code; the same files, the same regex.
#
# WHITELIST — the layer that IS the road, never counted:
#   the GitHub layer   fleet-gh-lib.sh fleet-gh.sh fleet-pr-verdict.sh fleet-pr-merge.sh mcp-github.sh
#                      fleet_gh.py (#4842: the same layer for a Python caller)
#   fleet's own release fleet-release.sh fleet-stable.sh fleet-train-failfast.sh
#                      fleet-train-macos.sh fleet-train-quarantine.sh fleet-macos-watch.sh
#                      fleet-train-runner.sh (#3864: the Linux half's runners)
#                      fleet-train-reuse.sh (#4794: the PR runs it reuses)
#                      tokenledger-flaky.sh (#4679: the CI runs' job logs it counts)
#
# 开发侧 / 演练 / 装机 — reach GitHub on purpose, never on a session's road (issue
# #4842; one line each, why):
#   fleet-release-rollback.sh  开发侧: a rollback IS a revert PR opened and merged on GitHub
#   fleet-hub-pause.sh         开发侧: the release train's hub-deploy gate, run inside CI
#   fleet-gh-blackhole.sh      演练: fetches GitHub's address list (api.github.com/meta) to block it
#   go-test-durations.sh       开发侧: reads a CI run's Go test logs (its artifacts) for the cost table (#4817)
#   nogh-task-deny-probe.py    演练: runs gh only to prove the sandbox refuses it
#   fleet-node-join.sh         装机: downloaded and run alone, before any layer exists; its
#                              GitHub roads are the developer's (go build) and Homebrew's
#                              installer — the join line's own road is C9's (#4848)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NO_DIRECT_GH_ROOT:-$BIN/..}"
BASE="${NO_DIRECT_GH_BASELINE:-$BIN/no-direct-gh.baseline}"
WHITELIST=' bin/fleet-gh-lib.sh bin/fleet-gh.sh bin/fleet-pr-verdict.sh bin/fleet-pr-merge.sh bin/mcp-github.sh bin/fleet-release.sh bin/fleet-stable.sh bin/fleet-train-failfast.sh bin/fleet-train-macos.sh bin/fleet-train-quarantine.sh bin/fleet-macos-watch.sh bin/fleet-train-runner.sh bin/fleet-train-reuse.sh bin/tokenledger-flaky.sh bin/fleet_gh.py bin/fleet-release-rollback.sh bin/fleet-hub-pause.sh bin/fleet-gh-blackhole.sh bin/go-test-durations.sh bin/nogh-task-deny-probe.py bin/fleet-node-join.sh '
# What counts as a call (issue #4842, EPIC #4839 C3 — the old regex saw only a bare
# `gh <sub>`):
#   RE_GH   gh <sub>, also with gh's own -R / --repo first (`gh -R "$repo" issue …`)
#   RE_VAR  a gh held in a variable: `$GH api …`, `"$GH" issue …`, `${GH} pr …`
#   RE_PY   Python handing gh an argv: `["gh", …]`, `run("gh", …)`, `… or "gh"`
#   RE_NET  git / curl / wget (Python urlopen / requests) at github.com, api. ·
#           raw.githubusercontent · codeload — a line that says fleet_gh_git /
#           fleet_gh_curl is the layer's own bounded road and is not counted
SUB='(issue|pr|api|search|label|repo|run|auth|workflow|release)'
RE_GH='(^|[^a-zA-Z0-9_.$-])gh( +(-R|--repo)(=| +)[^ ]+)? +'"$SUB"'([^a-z_-]|$)'
RE_VAR='[$][{]?GH[}]?"? +'"$SUB"'([^a-z_-]|$)'
RE_PY="[[] *['\"]gh['\"] *[],]|(run|call|check_call|check_output|Popen)[(] *['\"]gh['\"]|or +['\"]gh['\"]"
RE_NET='(^|[^a-zA-Z0-9_-])(curl|wget|git) +[^=+ #][^#]*(https?://|git@)([a-z]+[.])?github(usercontent)?[.]com|(urlopen|requests[.][a-z]+)[(][^#]*github(usercontent)?[.]com'
RE="$RE_GH|$RE_VAR|$RE_PY|$RE_NET"
[ -f "$BASE" ] || { echo "no-direct-gh: $BASE missing" >&2; exit 1; }

# direct <root> → every counted file that calls gh, relative, sorted
direct() {
  local f rel
  for f in "$1"/bin/*.sh "$1"/bin/*.py "$1"/hooks/*; do
    [ -f "$f" ] || continue
    rel=${f#"$1"/}
    case "$rel" in *selftest*|*_test.py) continue ;; esac
    case "$WHITELIST" in *" $rel "*) continue ;; esac
    grep -vE '^[[:space:]]*#' "$f" | grep -v 'no-gh-ok:' | grep -vE 'fleet_gh_(git|curl)' | grep -E "$RE" >/dev/null && printf '%s\n' "$rel"
  done | LC_ALL=C sort
}

# the counter itself: a call counts, a comment / a marked message does not
T="$(mktemp -d "${TMPDIR:-/tmp}/no-direct-gh.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hooks"
printf '#!/bin/bash\nx=$(gh issue view 1)\n' > "$T/bin/a.sh"
printf '#!/bin/bash\n# gh issue view is how it used to go\n' > "$T/bin/b.sh"
printf "#!/bin/bash\nprintf 'gh issue create failed'  # no-gh-ok: a message\n" > "$T/bin/c.sh"
printf '#!/bin/bash\nfleet_gh_write issue edit 1\n' > "$T/bin/d.sh"
printf 'gh pr view 1\n' > "$T/bin/x-selftest.sh"
printf 'gh api user\n' > "$T/bin/fleet-gh.sh"
printf 'subprocess.run(["gh", "api"])\ngh_out = "gh pr list"\n' > "$T/bin/e.py"
# the forms the widened counter reads (issue #4842) — and the ones it must not
printf '#!/bin/bash\ns=$(gh -R "$repo" issue view 1 --json state)\n' > "$T/bin/f.sh"
printf '#!/bin/bash\n"$GH" api "repos/o/r/issues"\n' > "$T/bin/g.sh"
printf '#!/bin/bash\nout=$($GH pr list --repo o/r)\n' > "$T/bin/h.sh"
printf 'json.loads(run("gh", "pr", "list"))\n' > "$T/bin/i.py"
printf 'argv = [os.environ.get("X_GH") or "gh", "api"]\n' > "$T/bin/j.py"
printf '#!/bin/bash\ncurl -fsS https://api.github.com/repos/o/r\n' > "$T/bin/k.sh"
printf '#!/bin/bash\ngit clone "https://github.com/$repo.git" "$dir"\n' > "$T/bin/l.sh"
printf '#!/bin/bash\nfleet_gh -R "$repo" issue view 1\nfleet_gh_curl -fsS https://api.github.com/x\nfleet_gh_git clone https://github.com/o/r.git d\n' > "$T/bin/m.sh"
printf '#!/bin/bash\ngit -C d -c user.email=x@users.noreply.github.com commit -m x\necho "https://github.com/o/r/issues/1"\n' > "$T/bin/n.sh"
printf 'code = self.adapter("gh", name)\ngit += ["[http \\"https://github.com/\\"]"]\n' > "$T/bin/o.py"
printf 'run(["gh", "api"])\n' > "$T/bin/p_test.py"
got=$(direct "$T" | tr '\n' ' ')
[ "$got" = 'bin/a.sh bin/e.py bin/f.sh bin/g.sh bin/h.sh bin/i.py bin/j.py bin/k.sh bin/l.sh ' ] || { echo "no-direct-gh: the counter misreads its fixtures: [$got]" >&2; exit 1; }

# the GitHub layer itself (issue #3721): fleet_gh (bin/fleet-gh-lib.sh, sourced by
# bin/fleet-lib.sh) is gh byte for byte, and refuses a FLEET_FORGE=none target
# without running gh; `fleet-gh.sh run` is the same road for a non-lib caller.
mkdir -p "$T/conf/fleets/f/repos" "$T/fp"
printf 'FLEET_FORGE="none"\n' > "$T/conf/fleets/f/repos/o-nogh.conf"
printf '#!/bin/sh\necho "gh:$*"\n' > "$T/fp/gh"; chmod +x "$T/fp/gh"
lay=$(env -i HOME="$T" PATH="$T/fp:/usr/bin:/bin" FLEET_CONF_DIR="$T/conf" bash -c '. "$1/fleet-lib.sh"
  fleet_gh pr list -R o/gh; echo "rc=$?"
  fleet_gh issue view 1 --repo o/nogh 2>/dev/null; echo "rc=$?"
  fleet_gh api "repos/o/nogh/pulls?state=open" 2>/dev/null; echo "rc=$?"
  fleet_gh issue list --repo=o/nogh 2>/dev/null; echo "rc=$?"
  fleet_gh auth status; echo "rc=$?"' _ "$BIN" | tr '\n' ' ')
[ "$lay" = 'gh:pr list -R o/gh rc=0 rc=78 rc=78 rc=78 gh:auth status rc=0 ' ] \
  || { echo "no-direct-gh: fleet_gh misroutes: [$lay]" >&2; exit 1; }
lay=$(env -i HOME="$T" PATH="$T/fp:/usr/bin:/bin" FLEET_CONF_DIR="$T/conf" bash "$BIN/fleet-gh.sh" run pr view 3 --repo o/nogh 2>/dev/null; echo "rc=$?")
[ "$lay" = 'rc=78' ] || { echo "no-direct-gh: fleet-gh.sh run reached gh for a none repo: [$lay]" >&2; exit 1; }

now=$(direct "$ROOT")
base=$(grep -vE '^[[:space:]]*(#|$)' "$BASE" | LC_ALL=C sort)
new=$(LC_ALL=C comm -23 <(printf '%s\n' "$now" | sed '/^$/d') <(printf '%s\n' "$base" | sed '/^$/d'))
gone=$(LC_ALL=C comm -13 <(printf '%s\n' "$now" | sed '/^$/d') <(printf '%s\n' "$base" | sed '/^$/d'))
n=$(printf '%s\n' "$now" | sed '/^$/d' | wc -l | tr -d ' ')
rc=0
if [ -n "$new" ]; then
  printf 'no-direct-gh: FAIL — a new direct gh call outside the door (EPIC #3570 共同约定 2):\n' >&2
  printf '  %s\n' $new >&2
  printf '  reach a branch, PR or check through the GitHub layer (bin/fleet-gh-lib.sh)\n' >&2
  rc=1
fi
if [ -n "$gone" ]; then
  printf 'no-direct-gh: FAIL — these no longer call gh: delete their lines from %s (the count only goes down)\n' "${BASE##*/}" >&2
  printf '  %s\n' $gone >&2
  rc=1
fi
[ "$rc" = 0 ] && printf 'no-direct-gh selftest: OK — %s programs still call gh directly (baseline %s)\n' "$n" "$(printf '%s\n' "$base" | sed '/^$/d' | wc -l | tr -d ' ')"
exit "$rc"
