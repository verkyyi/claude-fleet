#!/bin/bash
# forkless-hotpath-selftest.sh — pins issue #888: the background hot paths answer
# with shell builtins where they used to fork a `tr` / `date` / `cut` / `sed` /
# `dirname` / `cat`, and they answer EXACTLY what the forked version answered.
#
#   EQUIVALENCE  every rewritten helper is run against the original pipeline it
#                replaced, over a corpus that includes the awkward inputs (empty,
#                no separator, trailing slashes, non-ASCII, empty tab fields).
#   (BUDGET left with the producers it counted: the old client's tmux-status.sh,
#   issue #3008, and tmux-pr-refresh.sh, issue #4899.)
#
# No live tmux, no network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; CHECKS=$((CHECKS+1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/forkless-selftest.XXXXXX") || exit 2
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT

# ================================================================ EQUIVALENCE
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-daemon-lib.sh"

ref_norm() { printf '%s' "$1" | sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##; s#/+$##'; }
ref_slug() { printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'; }
while IFS= read -r v; do
  eq "fleet_norm_repo [$v]" "$(ref_norm "$v")" "$(fleet_norm_repo "$v")"
  eq "fleet_slug [$v]"      "$(ref_slug "$v")" "$(fleet_slug "$v")"
done <<'EOF'

verkyyi/claude-fleet
git@github.com:verkyyi/claude-fleet.git
git@github.com
https://github.com/o/r.git
https://github.com/o/r/
https://github.com/o/r.git/
https://github.com
http://host/o/r.git//
ssh://git@github.com/o/r.git
git@h:https://a/b
o/r.git.git
.git
/
///
x//y
a b/c
café/x
ümlaut
/Users/v/p q/acme-monorepo
acme-org/acme-monorepo
o/r+1
EOF
nl_in="a/b
c.git"
eq "fleet_norm_repo keeps sed's per-line edits for a multi-line value" "$(ref_norm "$nl_in")" "$(fleet_norm_repo "$nl_in")"

# sessmap lookups: field N of the first row whose field 1 matches — empty fields kept
FLEET_C="$WORK/sm"; mkdir -p "$FLEET_C/global"
printf 'a\tsa\tra\nb\t\trb\nc\tsc\nd\n\tx\ty\ne\tse\tre\tmore\nlast\tsl\trl' > "$FLEET_C/global/sessmap"
for s in a b c d e '' last zz; do
  eq "fleet_slug_cached [$s]" "$(awk -F'\t' -v s="$s" '$1==s{print $2; exit}' "$FLEET_C/global/sessmap")" "$(fleet_slug_cached "$s")"
  eq "fleet_repo_cached [$s]" "$(awk -F'\t' -v s="$s" '$1==s{print $3; exit}' "$FLEET_C/global/sessmap")" "$(fleet_repo_cached "$s")"
done
unset FLEET_C

for u in collect quotawatch base-sync worktree-autoclean ledger-watch 'X-y_z9' ''; do
  eq "_fleet_daemon_key [$u]" "$(printf '%s' "$u" | tr 'a-z-' 'A-Z_')" "$(_fleet_daemon_key "$u")"
done

# fleet_now: unpinned = date; pinned = one shared clock that still advances; a
# child process never inherits the pin, even when it is exported.
d0=$(date +%s); n0=$(fleet_now)
[ "$n0" -ge "$d0" ] && [ "$n0" -le $((d0 + 1)) ] || fail "unpinned fleet_now must be date +%s" "$d0 vs $n0"; CHECKS=$((CHECKS+1))
fleet_now_pin
eq "a pinned fleet_now answers the pin" "$_FLEET_NOW" "$(fleet_now)"
leak=$(_FLEET_NOW=5 _FLEET_NOW_PID=$$ _FLEET_NOW_S0=0 bash -c ". '$BIN/fleet-daemon-lib.sh'; fleet_now")
[ "$leak" -gt 1000000000 ] || fail "an exported pin leaked into a child process" "$leak"; CHECKS=$((CHECKS+1))
_FLEET_NOW=$(( _FLEET_NOW - 100 ))   # the pin plus $SECONDS since pinning
adv=$(fleet_now); [ "$adv" -le $(( $(date +%s) - 99 )) ] && [ "$adv" -ge $(( $(date +%s) - 101 )) ] \
  || fail "a pinned clock must advance with \$SECONDS from its pin" "$adv"
CHECKS=$((CHECKS+1)); unset _FLEET_NOW _FLEET_NOW_PID _FLEET_NOW_S0

# The 负载 figure (issue #1534; an alert of fleet-alerts.sh's since #1616): the
# load per core, one decimal, by integer math on hundredths — the table below is
# what awk's arithmetic would say.
eval "$(sed -n '/^_fa_loadpc()/,/^}/p' "$BIN/fleet-alerts.sh")"
command -v _fa_loadpc >/dev/null || fail "fleet-alerts.sh no longer defines _fa_loadpc"
for c in '1.57 10 0.2' '9.00 10 0.9' '0.04 4 0.0' '12.5 4 3.1' '0.995 1 1.0' '3 2 1.5' '1.5 0 –' 'x 4 –' ' 4 –'; do
  set -- $c
  [ $# -eq 2 ] && set -- '' "$1" "$2"
  _fa_loadpc "$1" "$2"
  eq "_fa_loadpc $1 / $2 cores" "$3" "${FA_LOAD:-–}"
done

printf 'forkless-hotpath-selftest: OK (%d checks) — builtins where the hot paths forked, same answers (issue #888)\n' "$CHECKS"
