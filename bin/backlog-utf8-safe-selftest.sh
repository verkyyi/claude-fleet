#!/bin/bash
# backlog-utf8-safe-selftest.sh — the "byte-safe backlog render" rail (issue #382).
#
# A stray non-UTF-8 byte in an issue title/milestone (surfaced in the 24haowan
# monorepo fleet) made bin/tmux-issues-rows.sh abort the WHOLE panel with
# "Illegal byte sequence": under a UTF-8 locale its byte-shuffle ops validate
# UTF-8 and bail on a bad byte — `cut -f1 | grep -vxF | sort -Vu` (milestone rank)
# and the final `sort -t\t` (row order). The fix runs those pure byte ops under
# LC_ALL=C (they need byte splitting/ordering, not CJK collation), so they tolerate
# ANY bytes. This drives the REAL reader against a fixture cache that mixes an
# invalid \xff byte (in a title AND in a milestone) with VALID CJK, under a UTF-8
# locale (where the pre-fix code aborted), and asserts:
#   • NO-ABORT   the reader exits 0 with NO "Illegal byte sequence" on stderr.
#   • ROWS       every issue still renders (a bad byte doesn't drop a row).
#   • CJK-OK     valid CJK milestones/titles pass through intact (not scrubbed).
#
# A FAKE tmux (no server spawn, can't inherit ~/.tmux.conf, never hangs) isolates
# the reader exactly like the sibling backlog selftests. Runs under a real UTF-8
# locale from `locale -a` (prefers en_US.UTF-8) so it's a genuine regression test;
# if the box has no UTF-8 locale it still runs (the reader defaults to one) and
# notes it. Exit 0 = pass. Non-zero = fail (prints the assertion + rows/stderr).
set -uo pipefail

# The harness's OWN text matching (grep/awk over reader output) walks lines that
# carry a raw \xff on purpose — so run the harness under LC_ALL=C (pure byte match)
# or it would hit the very "Illegal byte sequence" it's here to guard against. The
# reader is still driven under a real UTF-8 locale: run() sets LC_ALL/LANG for that
# child explicitly, overriding this.
export LC_ALL=C LANG=C

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-issues-rows.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
[ -f "$LIB" ]  || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/utf8safe-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

TAB=$'\t'; US=$'\x1f'
mkdir -p "$WORK/bin" "$WORK/.claude-dash"
C="$WORK/.claude-dash"

# --- pick a real UTF-8 locale so the pre-fix abort would actually reproduce here.
# The reader forces LC_ALL="${LC_ALL:-en_US.UTF-8}", so a C-locale test harness
# would mask the bug entirely; we hand it a genuine UTF-8 locale from `locale -a`.
pick_utf8_locale() {
  local avail want l
  avail="$(locale -a 2>/dev/null)"   # capture ONCE — a `locale -a | grep -q` pipe
  for want in en_US.UTF-8 C.UTF-8; do # lets grep early-exit → SIGPIPE poisons the
    case $'\n'"$avail"$'\n' in        # && under pipefail → a flaky preferred-pick.
      *$'\n'"$want"$'\n'*) printf '%s' "$want"; return ;;
    esac
  done
  l=$(printf '%s\n' "$avail" | grep -iE '\.utf-?8$' | head -1); printf '%s' "$l"
}
LOC="$(pick_utf8_locale)"
if [ -z "$LOC" ]; then
  LOC='en_US.UTF-8'   # none installed → let the reader fall back to its own default
  printf 'note: no UTF-8 locale installed; running under the reader default (%s)\n' "$LOC"
fi

# --- fake tmux: list-windows prints the (empty) bindings file, every other
# subcommand no-ops. The reader reads ONLY list-windows → fully isolated.
WINFILE="$WORK/windows"; : > "$WINFILE"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
case "\${1:-}" in
  list-windows) cat "$WINFILE" 2>/dev/null ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/tmux"

# --- fixture issues cache (milestone<TAB>#num<TAB>assignee<TAB>title). #10 is a
# clean VALID-CJK row (milestone + title); #11 carries a stray \xff byte IN the
# title; #12 carries a \xff byte IN the milestone (exercising the cut/grep/sort
# milestone-rank path); #13 is a plain ASCII no-milestone row. '·' = unassigned.
MS_CJK='里程碑一'; T_CJK='中文任务标题'
seed_issues() {
  {
    printf '%s%s#10%s·%s%s\n'            "$MS_CJK" "$TAB" "$TAB" "$TAB" "$T_CJK"
    printf '%s%s#11%s·%sbad\xffbyte in title\n' "$MS_CJK" "$TAB" "$TAB" "$TAB"
    printf 'wk\xff2%s#12%s·%splain title\n'     "$TAB" "$TAB" "$TAB"
    printf '· no milestone%s#13%s·%sunplanned task\n' "$TAB" "$TAB" "$TAB"
  } > "$C/issues"
  {
    printf '10%spriority:p1\n' "$TAB"; printf '11%spriority:p0\n' "$TAB"
    printf '12%spriority:p2\n' "$TAB"; printf '13%s\n' "$TAB"
  } > "$C/labels"
}

# run the REAL reader under the UTF-8 locale; capture stdout, stderr, and rc.
run() {
  ERRF="$WORK/err"; : > "$ERRF"
  OUT="$(PATH="$WORK/bin:$PATH" TMPDIR="$WORK" FLEET_SESSION="" \
        LC_ALL="$LOC" LANG="$LOC" bash "$ROWS" "${1:-all}" 2>"$ERRF")"
  RC=$?
}
# field2 (display) of the row whose field1 == the issue number; empty if absent.
disp_of() { printf '%s\n' "$1" | awk -F"$US" -v n="$2" '$1==n{print $2; exit}'; }
# field3 (milestone metadata) of the row whose field1 == the issue number.
ms_of()   { printf '%s\n' "$1" | awk -F"$US" -v n="$2" '$1==n{print $3; exit}'; }
# the ordered issue numbers of the NON-header rows (headers carry an empty field1).
seq_of()  { printf '%s\n' "$1" | awk -F"$US" '$1 ~ /^[0-9]+$/{printf "%s ", $1}'; }

# ============================ mixed bad-byte + CJK ==========================
seed_issues
run all

# NO-ABORT: the whole point — a bad byte must not crash the panel.
[ "$RC" -eq 0 ] || fail "reader exited $RC under $LOC (want 0)" "$(cat "$ERRF")"
grep -qi 'illegal byte sequence' "$ERRF" \
  && fail "reader emitted 'Illegal byte sequence' under $LOC — byte ops are not byte-safe" "$(cat "$ERRF")"
[ -s "$ERRF" ] && fail "reader wrote to stderr under $LOC (want none)" "$(cat "$ERRF")"

# ROWS: every issue still renders — a bad byte in a field drops NOTHING.
seq="$(seq_of "$OUT")"
for n in 10 11 12 13; do
  case " $seq " in *" $n "*) : ;; *) fail "issue #$n missing from output (a bad byte dropped a row?) — got: $seq" "$OUT" ;; esac
done

# CJK-OK: valid CJK is NOT mangled — #10's title (untruncated, last field) and its
# milestone (field3, untruncated metadata) survive verbatim.
printf '%s' "$(disp_of "$OUT" 10)" | grep -qF "$T_CJK" \
  || fail "valid CJK title '$T_CJK' must render intact for #10" "$(disp_of "$OUT" 10)"
[ "$(ms_of "$OUT" 10)" = "$MS_CJK" ] \
  || fail "valid CJK milestone '$MS_CJK' must be preserved in #10's milestone field (got: $(ms_of "$OUT" 10))" "$OUT"

# The bad-byte rows still carry their issue number + (scrubbed/replacement) title —
# already covered by ROWS; assert #11's ASCII tail survived the stray byte.
printf '%s' "$(disp_of "$OUT" 11)" | grep -qF 'byte in title' \
  || fail "#11's ASCII title tail must survive the stray \\xff byte" "$(disp_of "$OUT" 11)"

ok "mixed invalid-\\xff + valid-CJK rows render with NO 'Illegal byte sequence', all rows present, CJK intact (locale=$LOC)"

# ============================ per-mode (roadmap/unplanned) ==================
# The abort fired in every mode (the milestone-rank + final sort run unconditionally).
for mode in roadmap unplanned all; do
  run "$mode"
  [ "$RC" -eq 0 ] || fail "reader exited $RC in mode '$mode' under $LOC" "$(cat "$ERRF")"
  grep -qi 'illegal byte sequence' "$ERRF" \
    && fail "reader emitted 'Illegal byte sequence' in mode '$mode'" "$(cat "$ERRF")"
done
ok "roadmap / unplanned / all modes all render byte-safe on bad-byte data"

printf '\nselftest PASS: the backlog reader is byte-safe on invalid-UTF-8 issue/milestone data — no "Illegal byte sequence", every row rendered, valid CJK preserved (%s assertions)\n' "$pass"
exit 0
