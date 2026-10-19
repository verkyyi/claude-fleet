#!/bin/sh
# tokenledger-quarantine.sh — the ONE reader of tokenledger/test-quarantine.txt
# (claude-fleet#4679, EPIC #4810 C8): the Go tests the PR gate holds out.
#
# Usage:
#   tokenledger-quarantine.sh list  [FILE]   the quarantined test names, one a line
#   tokenledger-quarantine.sh skip  [FILE]   a `go test -skip` pattern for them,
#                                            ^(A|B)$ — nothing when the list is empty
#   tokenledger-quarantine.sh check [FILE]   exit 1 naming each malformed line
# FILE defaults to tokenledger/test-quarantine.txt beside this script. A line is
# `<TestName> #<issue> <why>`; `#` starts a comment. A malformed line is said on
# stderr and left out (never skips a test it cannot name).
set -eu

cmd=${1:-}
file=${2:-$(dirname "$0")/../tokenledger/test-quarantine.txt}  # release-tree-ok: CI-only, tokenledger/ never ships; absent file = no-op
[ -r "$file" ] || { [ "$cmd" = check ] && echo "tokenledger-quarantine: no $file" >&2 && exit 1; exit 0; }

entries() {
  awk -v f="$file" '
    { sub(/[ \t]+$/, "") }
    /^[ \t]*(#|$)/ { next }
    $1 ~ /^(Test|Example|Fuzz)[A-Za-z0-9_]*$/ && $2 ~ /^#[0-9]+$/ && NF >= 3 { print $1; next }
    { printf "tokenledger-quarantine: %s:%d: not `<TestName> #<issue> <why>`: %s\n", f, NR, $0 > "/dev/stderr"; bad = 1 }
    END { exit bad }
  ' "$file"
}

case "$cmd" in
  list) entries || true ;;
  skip)
    names=$(entries | sort -u | paste -sd'|' -) || true
    [ -z "$names" ] || printf '^(%s)$\n' "$names" ;;
  check) entries >/dev/null ;;
  *) echo "usage: tokenledger-quarantine.sh list|skip|check [FILE]" >&2; exit 2 ;;
esac
