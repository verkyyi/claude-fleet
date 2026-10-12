#!/bin/bash
# no-direct-gh-selftest.sh — who still talks to GitHub directly (issue #3595, EPIC
# #3570 共同约定 2: 一扇门). A ticket is touched only through the ticket door
# (bin/fleet-ticket.sh, bin/fleet_ticket.py); a forge (branches, PRs, checks) only
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
# WHITELIST — the two layers that ARE the road, never counted:
#   the door           fleet-ticket.sh fleet_ticket.py
#   the GitHub layer   fleet-gh-lib.sh fleet-gh.sh fleet-pr-verdict.sh fleet-pr-merge.sh mcp-github.sh
#   fleet's own release fleet-release.sh fleet-stable.sh fleet-train-failfast.sh
#                      fleet-train-macos.sh fleet-train-quarantine.sh fleet-macos-watch.sh
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NO_DIRECT_GH_ROOT:-$BIN/..}"
BASE="${NO_DIRECT_GH_BASELINE:-$BIN/no-direct-gh.baseline}"
WHITELIST=' bin/fleet-ticket.sh bin/fleet_ticket.py bin/fleet-gh-lib.sh bin/fleet-gh.sh bin/fleet-pr-verdict.sh bin/fleet-pr-merge.sh bin/mcp-github.sh bin/fleet-release.sh bin/fleet-stable.sh bin/fleet-train-failfast.sh bin/fleet-train-macos.sh bin/fleet-train-quarantine.sh bin/fleet-macos-watch.sh '
RE='(^|[^a-z_-])gh (issue|pr|api|search|label|repo|run|auth)'
[ -f "$BASE" ] || { echo "no-direct-gh: $BASE missing" >&2; exit 1; }

# direct <root> → every counted file that calls gh, relative, sorted
direct() {
  local f rel
  for f in "$1"/bin/*.sh "$1"/bin/*.py "$1"/hooks/*; do
    [ -f "$f" ] || continue
    rel=${f#"$1"/}
    case "$rel" in *selftest*) continue ;; esac
    case "$WHITELIST" in *" $rel "*) continue ;; esac
    grep -vE '^[[:space:]]*#' "$f" | grep -v 'no-gh-ok:' | grep -E "$RE" >/dev/null && printf '%s\n' "$rel"
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
got=$(direct "$T" | tr '\n' ' ')
[ "$got" = 'bin/a.sh bin/e.py ' ] || { echo "no-direct-gh: the counter misreads its fixtures: [$got]" >&2; exit 1; }

now=$(direct "$ROOT")
base=$(grep -vE '^[[:space:]]*(#|$)' "$BASE" | LC_ALL=C sort)
new=$(LC_ALL=C comm -23 <(printf '%s\n' "$now" | sed '/^$/d') <(printf '%s\n' "$base" | sed '/^$/d'))
gone=$(LC_ALL=C comm -13 <(printf '%s\n' "$now" | sed '/^$/d') <(printf '%s\n' "$base" | sed '/^$/d'))
n=$(printf '%s\n' "$now" | sed '/^$/d' | wc -l | tr -d ' ')
rc=0
if [ -n "$new" ]; then
  printf 'no-direct-gh: FAIL — a new direct gh call outside the door (EPIC #3570 共同约定 2):\n' >&2
  printf '  %s\n' $new >&2
  printf '  touch a ticket through bin/fleet-ticket.sh / bin/fleet_ticket.py; a branch, PR or check through the GitHub layer\n' >&2
  rc=1
fi
if [ -n "$gone" ]; then
  printf 'no-direct-gh: FAIL — these no longer call gh: delete their lines from %s (the count only goes down)\n' "${BASE##*/}" >&2
  printf '  %s\n' $gone >&2
  rc=1
fi
[ "$rc" = 0 ] && printf 'no-direct-gh selftest: OK — %s programs still call gh directly (baseline %s)\n' "$n" "$(printf '%s\n' "$base" | sed '/^$/d' | wc -l | tr -d ' ')"
exit "$rc"
