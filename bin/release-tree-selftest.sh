#!/bin/bash
# release-tree-selftest.sh — conf/release-tree.list holds every top-level item
# of the repo an install reads (claude-fleet#2771, EPIC #2770 C1).
#
# The hub builds each stable's release from that list alone, and a login's
# install will come from the release only — so an item a script reads but the
# list leaves out is a file missing on every machine, found on the day the
# script runs there. Before the list, the hub's fixed set lacked .claude-plugin/
# (fleet-lib.sh reads it) and extras/ (fleet-doctor.sh, open-url.sh).
#
# The read points it scans:
#   every bin/ script        $BIN/../<item>  ${…BIN…}/../<item>  $(dirname …)/../<item>
#   install-apply · doctor · lib   any $var/<item>  $var/../<item>  $(…)/<item>
# where <item> is a TRACKED top-level name of the repo (runtime state such as
# logs/ or fleet.conf is not in the repo and is never asked about). A line that
# names one for another reason carries `# release-tree-ok: <why>`; `.gitignore`
# never counts (a script writes its own dir's, it never reads the repo's).
#
# Legs: A the repo's list covers every read point; B .claude-plugin/ and
# extras/ are in it and tokenledger/ deploy/ .github/ are not; C the lint reds
# on a list that drops a read item (it can fail).
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)
LIST="$ROOT/conf/release-tree.list"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-tree-st.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

[ -f "$LIST" ] || { echo "FAIL  no $LIST"; exit 1; }

# tracked top-level names (git, else what is there)
if ! git -C "$ROOT" ls-tree --name-only HEAD > "$WORK/top" 2>/dev/null || [ ! -s "$WORK/top" ]; then
  ls -A "$ROOT" > "$WORK/top"
fi

# read points: "<item> <file>:<line>"
: > "$WORK/reads"
for f in "$BIN"/*; do
  [ -f "$f" ] || continue
  case ${f##*/} in *selftest*) continue ;; esac
  case ${f##*/} in
    fleet-install-apply.sh|fleet-doctor.sh|fleet-lib.sh)
      re='(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$\([^)]*\))/(\.\./)?[A-Za-z0-9._-]+' ;;
    *) re='(\$\{?[A-Za-z_]*BIN[A-Za-z0-9_]*\}?|\$\(dirname [^)]*\))/\.\./[A-Za-z0-9._-]+' ;;
  esac
  grep -nE "$re" "$f" 2>/dev/null | grep -v 'release-tree-ok' | grep -vE '^[0-9]+:[[:space:]]*#' \
    | while IFS= read -r line; do
        ln=${line%%:*}
        printf '%s\n' "${line#*:}" | grep -oE "$re" | sed -E 's#.*/##' \
          | while IFS= read -r item; do printf '%s %s:%s\n' "$item" "bin/${f##*/}" "$ln"; done
      done >> "$WORK/reads"
done

# covered <list> <item>: the list ships the top-level <item>
covered() {
  awk -v it="$2" -v isdir="$3" '
    { sub(/#.*/, ""); gsub(/[ \t]/, "") }
    $0 == "" { next }
    $0 == "*" { star = 1; next }
    /^!/ { e = substr($0, 2); if (e == it || e == it "/") no = 1; next }
    $0 == it "/" || $0 == it { yes = 1 }
    END { if (no) exit 1
          if (yes) exit 0
          if (star && isdir == 0 && substr(it, 1, 1) != ".") exit 0
          exit 1 }' "$1"
}

# lint <list>: one line per read item the list leaves out
lint() {
  sort -u "$WORK/reads" | while read -r item where; do
    grep -qxF -- "$item" "$WORK/top" || continue
    [ "$item" = .gitignore ] && continue
    isdir=0; [ -d "$ROOT/$item" ] && isdir=1
    covered "$1" "$item" "$isdir" || echo "$item  ($where)"
  done
}

# A
n=$(cut -d' ' -f1 "$WORK/reads" | sort -u | grep -cxFf "$WORK/top")
lint "$LIST" > "$WORK/miss"
if [ -s "$WORK/miss" ]; then
  fail "A conf/release-tree.list leaves out what bin/ reads — add it to the list:"
  sed 's/^/        /' "$WORK/miss"
else
  pass "A conf/release-tree.list covers every top-level item bin/ reads ($n items)"
fi

# B
for it in .claude-plugin extras bin conf hooks mod; do
  covered "$LIST" "$it" 1 || fail "B $it/ is not in the list"
done
for it in tokenledger deploy .github; do
  covered "$LIST" "$it" 1 && fail "B $it/ is in the list (never shipped)"
done
[ "$fails" -eq 0 ] && pass "B .claude-plugin/ extras/ shipped; tokenledger/ deploy/ .github/ not"

# C: a list without extras/ must red
grep -v '^extras/' "$LIST" > "$WORK/drop.list"
if grep -q '^extras$' "$WORK/top" && grep -q '^extras ' "$WORK/reads" && lint "$WORK/drop.list" | grep -q '^extras '; then
  pass "C a list that drops extras/ is caught"
else
  fail "C the lint did not catch a list without extras/"
fi

[ "$fails" -eq 0 ] && { echo "release-tree-selftest: OK"; exit 0; }
echo "release-tree-selftest: $fails failure(s)"
exit 1
