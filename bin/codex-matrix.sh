#!/bin/bash
# codex-matrix.sh — render / check the Claude-vs-Codex capability matrix (issue #608).
#
# ONE source of truth for what the `FLEET_AGENT=codex` path can and cannot do:
# the MATRIX block in bin/fleet-codex.sh's header, next to the code whose
# behaviour it grades. README.md's "Agents: Claude Code and Codex" table is a
# RENDER of that block, kept honest mechanically instead of by hand — the failure
# this exists to prevent is the one teamai-cli shipped: a public feature table
# that quietly stops matching the adapter (issue #608).
#
#   codex-matrix.sh             print the markdown table on stdout
#   codex-matrix.sh --check     exit 1 (and diff) if README.md has drifted
#   codex-matrix.sh --write     re-render README.md's table in place
#
#   --source <file>   read the MATRIX block from this file (default bin/fleet-codex.sh)
#   --readme <file>   act on this README      (default the repo's README.md)
#
# The README region is delimited by `<!-- codex-matrix:begin -->` /
# `<!-- codex-matrix:end -->` HTML comments (invisible on GitHub). Everything
# between them is generated; prose around them is yours.
#
# bin/codex-matrix-selftest.sh runs --check, so CI fails the moment a row is
# edited in one file and not the other. Exit: 0 ok · 1 drift · 2 usage/parse error.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
SRC="$BIN/fleet-codex.sh"
README="$ROOT/README.md"
BEGIN='<!-- codex-matrix:begin -->'
END='<!-- codex-matrix:end -->'
mode='render'

die() { printf 'codex-matrix: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode='check' ;;
    --write) mode='write' ;;
    --source) [ $# -ge 2 ] || die "--source needs a file"; SRC="$2"; shift ;;
    --readme) [ $# -ge 2 ] || die "--readme needs a file"; README="$2"; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ -r "$SRC" ] || die "no such source file: $SRC"

# --- render: the MATRIX block, minus its comment prefix, as a markdown table ---
# First row is the header; the rest are body rows. The alignment row centres the
# two verdict columns so ✅/❌ line up under their agent name.
render() {
  awk '
    /^# MATRIX-BEGIN$/ { in_block = 1; next }
    /^# MATRIX-END$/   { in_block = 0; next }
    in_block {
      line = $0
      sub(/^# ?/, "", line)
      if (line == "") next
      n++
      printf "| %s |\n", line
      if (n == 1) print "|---|:--:|:--:|---|"
    }
    END { if (n < 2) exit 3 }
  ' "$SRC"
}

table="$(render)" || die "no MATRIX-BEGIN/END block with rows in $SRC"

# Every row must have the same four columns — a cell containing a stray pipe
# would silently produce a lopsided table on GitHub, so catch it here.
bad="$(printf '%s\n' "$table" | awk -F'|' '$0 !~ /^\|---\|/ && NF != 6 { print NR": "$0 }')"
[ -z "$bad" ] || die "row(s) with the wrong column count (a cell containing a pipe?):
$bad"

if [ "$mode" = render ]; then
  printf '%s\n' "$table"
  exit 0
fi

[ -r "$README" ] || die "no such readme: $README"
grep -qF "$BEGIN" "$README" || die "$README has no $BEGIN marker"
grep -qF "$END"   "$README" || die "$README has no $END marker"

current="$(awk -v b="$BEGIN" -v e="$END" '
  index($0, b) { on = 1; next }
  index($0, e) { on = 0; next }
  on { print }
' "$README")"

if [ "$mode" = check ]; then
  if [ "$current" = "$table" ]; then
    printf 'codex-matrix: README table matches %s\n' "${SRC#"$ROOT"/}"
    exit 0
  fi
  printf 'codex-matrix: DRIFT — %s and the MATRIX block in %s disagree.\n' \
    "${README#"$ROOT"/}" "${SRC#"$ROOT"/}" >&2
  printf 'codex-matrix: the block is the source of truth; run `bin/codex-matrix.sh --write`.\n' >&2
  if command -v diff >/dev/null 2>&1; then
    printf -- '--- README (generated region)\n+++ rendered from the MATRIX block\n' >&2
    diff -u <(printf '%s\n' "$current") <(printf '%s\n' "$table") | tail -n +3 >&2
  fi
  exit 1
fi

# --- write: splice the rendered table between the markers ----------------------
tmp="$(mktemp "${TMPDIR:-/tmp}/codex-matrix.XXXXXX")" || die "mktemp failed"
tbl="$(mktemp "${TMPDIR:-/tmp}/codex-matrix-tbl.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$tmp" "$tbl"' EXIT
# The table goes through a FILE, not `awk -v`: a -v assignment cannot carry
# newlines (one-true-awk rejects it outright).
printf '%s\n' "$table" > "$tbl"
awk -v b="$BEGIN" -v e="$END" -v f="$tbl" '
  index($0, b) { print; while ((getline line < f) > 0) print line; close(f); skip = 1; next }
  index($0, e) { skip = 0 }
  !skip { print }
' "$README" > "$tmp" || die "render failed"
if cmp -s "$tmp" "$README"; then
  printf 'codex-matrix: %s already up to date\n' "${README#"$ROOT"/}"
else
  cat "$tmp" > "$README" || die "cannot write $README"
  printf 'codex-matrix: rewrote the table in %s\n' "${README#"$ROOT"/}"
fi
