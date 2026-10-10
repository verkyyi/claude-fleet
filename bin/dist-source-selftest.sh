#!/bin/bash
# dist-source-selftest.sh — the fleet's versions come from the hub only: a new
# place in bin/ that fetches the fleet (or the code it installs) from GitHub is a
# regression (issue #2776, EPIC #2770 共同约定 2). Run on every PR through
# portability-selftest.sh (the always-run lint group), and on its own.
#
# A distribution reach is a line, outside a comment, in a bin/ file that is not a
# selftest, naming one of
#   api.github.com · raw.githubusercontent.com · codeload.github.com ·
#   objects.githubusercontent.com · a `https://github.com}` default (a git base) ·
#   a github.com/…​.git remote · `go install github.com/…`
# A link a person clicks (…/issues/N, …/pull/N, …/actions/runs/N) is none of them.
#
# Each reach must either carry `# dist-ok: <why>` on its line (a developer's
# road, the business repo a session clones, a drill's own host list, a message to
# a person) or be one DIST_PENDING still lists: today's reaches the batch's
# members take away. The count per file is a ratchet both ways — a file with MORE
# reaches than listed is a new one (FAIL, names the line); a file with FEWER
# means its member removed one, so lower the count here in the same PR (FAIL,
# until it does). The batch ends with DIST_PENDING empty.
#
# With no argument it also checks itself on a sandbox: a new `curl
# https://api.github.com/…` is a finding, its `# dist-ok:` twin and an issue link
# are not, and a pending file that lost a reach asks for the lower count.
#
# Usage: dist-source-selftest.sh [<bin dir>]   (default: this script's own)
# Exit 0 = clean · 1 = a finding (one line each).
set -uo pipefail

# <file> <reaches> <member who takes them away>
DIST_PENDING='
fleet-node-join.sh       2 #2862
'
DIST_RE='api\.github\.com|raw\.githubusercontent\.com|codeload\.github\.com|objects\.githubusercontent\.com|https://github\.com\}|github\.com[:/][^ "'"'"')]*\.git([^A-Za-z0-9_]|$)|go install github\.com'

SELF="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:-$SELF}"

# reaches <file> — `<line>:<text>` for every reach not marked dist-ok (on the
# line itself, or a `# dist-ok:` comment line right above it — a command that
# continues with `\` has no end of line to carry one)
reaches() {
  awk -v re="$DIST_RE" '
    $0 ~ re && $0 !~ /^[[:space:]]*(#|\/\/)/ && $0 !~ /# dist-ok:/ && prev !~ /^[[:space:]]*# dist-ok:/ { print NR ":" $0 }
    { prev = $0 }' "$1" 2>/dev/null
}

FAILS=0 N=0
finding() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; }
for f in "$DIR"/*; do
  [ -f "$f" ] || continue
  b=${f##*/}
  case "$b" in *selftest*) continue ;; esac
  N=$((N + 1))
  got=$(reaches "$f"); have=0
  [ -z "$got" ] || have=$(printf '%s\n' "$got" | grep -c .)
  want=$(printf '%s\n' "$DIST_PENDING" | awk -v b="$b" '$1 == b { print $2 " " $3 }')
  wn=${want%% *}; wm=${want#* }; [ -n "$want" ] || { wn=0; wm=''; }
  if [ "$have" -gt "$wn" ]; then
    finding "bin/$b reaches GitHub for the fleet's code ($have, $wn allowed) — take it from the hub, or mark the line \`# dist-ok: <why>\`:
$(printf '%s\n' "$got" | cut -c1-200 | sed 's/^/        /')"
  elif [ "$have" -lt "$wn" ]; then
    finding "bin/$b now reaches GitHub $have time(s), DIST_PENDING lists $wn ($wm) — lower it to $have in ${0##*/} (drop the row at 0)"
  fi
done
# the lint on a sandbox (only when run bare — the sandbox runs call it with a dir)
if [ -z "${1:-}" ]; then
  SB=$(mktemp -d "${TMPDIR:-/tmp}/dist-src.XXXXXX") || exit 2
  mkdir -p "$SB/new" "$SB/ok" "$SB/less"
  printf '#!/bin/sh\ns=$(curl -fsS https://api.github.com/repos/o/r/commits/stable)\n' > "$SB/new/fleet-x.sh"
  printf '#!/bin/sh\ncurl -fsS https://api.github.com/x  # dist-ok: a drill\necho https://github.com/o/r/issues/1\n# dist-ok: Homebrew, not the fleet\ncurl https://raw.githubusercontent.com/h/i \\\n  >/dev/null\n' > "$SB/ok/fleet-y.sh"
  # a file still pending (the first row; none left = nothing to lower)
  lessf=$(printf '%s\n' "$DIST_PENDING" | awk 'NF { print $1; exit }')
  [ -z "$lessf" ] || printf '#!/bin/sh\n: nothing from GitHub any more\n' > "$SB/less/$lessf"
  bash "$0" "$SB/new" >/dev/null 2>&1 && finding "the lint missed a new \`curl https://api.github.com\`"
  bash "$0" "$SB/ok" >/dev/null 2>&1 || finding "the lint flagged a dist-ok line or an issue link: $(bash "$0" "$SB/ok" 2>&1 | head -2)"
  [ -z "$lessf" ] || case "$(bash "$0" "$SB/less" 2>/dev/null)" in *'lower it to 0'*) ;; *) false ;; esac || finding "the lint did not ask to lower a pending count that fell"
  rm -rf "$SB"
fi
if [ "$FAILS" -gt 0 ]; then
  printf 'dist-source-selftest: %d finding(s) in %d file(s)\n' "$FAILS" "$N" >&2
  exit 1
fi
printf 'dist-source-selftest: OK (%d files, %d pending reach(es) listed)\n' "$N" \
  "$(printf '%s\n' "$DIST_PENDING" | awk 'NF { s += $2 } END { print s + 0 }')"
