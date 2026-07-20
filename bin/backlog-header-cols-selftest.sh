#!/bin/bash
# backlog-header-cols-selftest.sh — the backlog modal's column-title header row
# (issue #371) stays aligned to the fixed-width columns of the rows it heads.
#
# The backlog (bin/tmux-issues.sh) draws a dim column-title line — `# pri
# milestone title` (the owner column was dropped in issue #389; the milestone
# column arrived with the flat list, issue #377) — via fleet_backlog_col_header;
# the rows (bin/tmux-issues-rows.sh) lay field-2 out with the SAME FLEET_BL_W_*
# widths (fleet-lib.sh). This test renders a REAL row and the REAL header, strips
# ANSI, and asserts each header label starts at the SAME visible column where that
# column begins in the row — so a future width change that touches only one side
# can't silently misalign them. It also cross-checks both against the constants'
# own arithmetic.
#
# It further asserts (issue #374) that the producer emits the column-title line as
# its FIRST output line in every mode — the backlog pins it at the TOP with
# `--header-lines=1`, so a leading milestone header / status line would pin the
# wrong row (the very bug #374 fixes, where the titles rendered at the bottom).
#
# And it asserts (issue #432) that the milestone column is padded to a fixed
# DISPLAY-cell width — CJK / mixed / emoji / over-long / no-milestone rows all keep
# the title pinned at the header's title offset. `printf %-N.Ns` counts BYTES, so a
# Chinese milestone (3 bytes but 2 cells/glyph) under-fills the column and shoves
# every following column left of the header; fleet_pad_display fixes it by padding
# to cells. Each such fixture's title STARTS with a distinct ASCII marker whose
# normed char-offset equals its screen-cell offset (see norm() below).
#
# tmux is isolated onto a private `-S` socket via a PATH shim (never the live
# server, per the repo rail) and left with NO windows, so the rows producer sees
# empty active-bindings and renders free/assigned rows (which is all we measure).
# tmux absent → the shim is skipped; bare `tmux` calls fail closed to the same
# empty bindings. Column widths are measured multibyte-safely by collapsing each
# fixture glyph to its CELL count in ASCII under LC_ALL=C — the 1-col glyphs
# (·/◦/▶/⇡/↳) to one byte, the 2-cell CJK/emoji fixture glyphs to two ("WW") — so a
# byte count equals the visible column count regardless of the runner's locale.
# Exit 0 = pass, non-zero = fail (prints which offset diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-issues-rows.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
[ -f "$LIB" ]  || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/blhdr-selftest.XXXXXX")" || exit 2
export TMPDIR="$WORK"            # points fleet_cache's $C ($FLEET_C) at our sandbox
C="$WORK/.claude-dash"; mkdir -p "$C"

# Isolate every tmux call (rows reads @issue bindings via `tmux list-windows`)
# onto a private, EMPTY socket so we never touch the user's live server.
REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -n "$REAL_TMUX" ]; then
  SOCK="$WORK/tmux.sock"; mkdir -p "$WORK/bin"
  cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
  chmod +x "$WORK/bin/tmux"
  PATH="$WORK/bin:$PATH"; export PATH
  cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
else
  cleanup() { rm -rf "$WORK"; }
fi
trap cleanup EXIT

. "$LIB"
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
TAB=$'\t'; US=$'\x1f'

# --- fixture issues (collector format: milestone<TAB>#num<TAB>assignee<TAB>title).
# ZZTITLE is a distinctive ASCII title we locate after stripping ANSI. The '·'
# assignee is what the collector writes for unassigned (never empty). The owner
# column was dropped in issue #389, so the assignee is no longer rendered — #41's
# `alice` claim just confirms an assigned issue still renders (identically to a
# free one) and stays column-aligned.
{
  printf 'Week 1%s#40%s·%sZZTITLE\n'     "$TAB" "$TAB" "$TAB"   # free (unassigned)
  printf 'Week 1%s#41%salice%sZZTITLE\n' "$TAB" "$TAB" "$TAB"   # assigned (owner no longer shown)
  # issue #432 — CJK-bearing milestone columns. Each milestone drives the column
  # whose byte-width ≠ cell-width; the title STARTS with a distinct ASCII marker so
  # its cell-offset is measurable after norm(). The wide glyphs used here (端口迁移测
  # 🚀) are exactly the ones norm() collapses to 2 ASCII bytes.
  printf '端口迁移测%s#50%s·%sZZCJK cjk\n'         "$TAB" "$TAB" "$TAB"   # pure CJK (5 glyphs, 10 cells)
  printf 'v2端口%s#51%s·%sZZMIX mix\n'             "$TAB" "$TAB" "$TAB"   # mixed ASCII+CJK (6 cells)
  printf '🚀端口%s#52%s·%sZZEMOJI emo\n'           "$TAB" "$TAB" "$TAB"   # emoji + CJK (6 cells)
  printf 'x端口迁移测口迁%s#53%s·%sZZTRUNC trn\n'  "$TAB" "$TAB" "$TAB"   # over-long → truncates mid-name, never mid-glyph
  printf '· no milestone%s#54%s·%sZZNOMS non\n'    "$TAB" "$TAB" "$TAB"   # no milestone → lone '·' (1 cell, 2 bytes)
} > "$C/issues"

# strip ANSI, then collapse each fixture glyph to its CELL count in ASCII (byte-
# matched under LC_ALL=C) so a plain byte count == the visible column count in any
# locale: the 1-col glyphs (·/◦/▶/⇡/↳) → 1 byte, the 2-cell CJK/emoji fixture glyphs
# → 2 bytes ("WW"). An unmapped wide glyph would survive and mismeasure — the #432
# loop below guards each measured prefix is pure ASCII to catch exactly that.
norm() { LC_ALL=C sed -e $'s/\033\\[[0-9;]*m//g' \
                      -e 's/·/./g' -e 's/◦/./g' -e 's/▶/./g' -e 's/⇡/./g' -e 's/↳/./g' \
                      -e 's/端/WW/g' -e 's/口/WW/g' -e 's/迁/WW/g' -e 's/移/WW/g' \
                      -e 's/测/WW/g' -e 's/🚀/WW/g'; }
# visible column at which SUBSTR begins in the (already-normed) STR, or -1 if absent.
col_of() { case "$1" in *"$2"*) local p="${1%%"$2"*}"; printf '%s' "${#p}";; *) printf '%s' -1;; esac; }
disp_of() { printf '%s\n' "$1" | awk -F"$US" -v k="$2" '$1==k{print $2; exit}' | norm; }

out="$(FLEET_SESSION='' bash "$ROWS" all 2>/dev/null)"
r_free="$(disp_of "$out" 40)"
r_asg="$(disp_of "$out" 41)"
[ -n "$r_free" ] || fail "free row #40 not rendered" "$out"
[ -n "$r_asg" ]  || fail "assigned row #41 not rendered" "$out"

# --- the constants' own arithmetic (the single source both sides derive from) ---
exp_num=0
exp_pri=$((FLEET_BL_W_NUM + 1))
exp_ms=$((exp_pri + FLEET_BL_W_PRI + 2))   # +2: 2-col gap so the 3-char 'pri' label clears 'milestone' (issue #389)
exp_title=$((exp_ms + FLEET_BL_W_MS + 1))

# --- REAL row column offsets match the constants ----------------------------
# The fixtures live in milestone "Week 1", so 'Week' locates the milestone column.
row_num=$(col_of "$r_free" '#40')       # num column
row_ms=$(col_of "$r_free" 'Week')       # milestone column (issue #377)
row_title=$(col_of "$r_free" 'ZZTITLE') # title column
[ "$row_num"   = "$exp_num" ]   || fail "row #num starts at col $row_num, expected $exp_num" "$r_free"
[ "$row_ms"    = "$exp_ms" ]    || fail "row milestone starts at col $row_ms, expected $exp_ms" "$r_free"
[ "$row_title" = "$exp_title" ] || fail "row title starts at col $row_title, expected $exp_title" "$r_free"

# --- REAL header label offsets match the constants (and thus the row) --------
hdr="$(fleet_backlog_col_header | norm)"
[ -n "$hdr" ] || fail "fleet_backlog_col_header produced nothing"
h_num=$(col_of "$hdr" '#')
h_pri=$(col_of "$hdr" 'pri')
h_ms=$(col_of "$hdr" 'milestone')
h_title=$(col_of "$hdr" 'title')
[ "$h_num"   = "$exp_num" ]   || fail "header '#' at col $h_num, expected $exp_num (num column)" "$hdr"
[ "$h_pri"   = "$exp_pri" ]   || fail "header 'pri' at col $h_pri, expected $exp_pri (priority column)" "$hdr"
[ "$h_ms"    = "$exp_ms" ]    || fail "header 'milestone' at col $h_ms, expected $exp_ms (milestone column)" "$hdr"
[ "$h_title" = "$exp_title" ] || fail "header 'title' at col $h_title, expected $exp_title (title column)" "$hdr"

# --- and, most importantly, header labels align EXACTLY with the row columns ---
[ "$h_title" = "$row_title" ] || fail "header title (col $h_title) misaligned from row title (col $row_title)"
[ "$h_ms"    = "$row_ms" ]    || fail "header milestone (col $h_ms) misaligned from row milestone (col $row_ms)"

# --- issue #432: CJK / mixed / emoji / over-long / no-milestone milestone columns
# all keep the title pinned at the header's title offset. The milestone column is
# padded to $FLEET_BL_W_MS *display cells* (fleet_pad_display), not bytes — so a
# 2-cell CJK glyph no longer under-fills the column and shoves the title left, and
# an over-long name truncates on a glyph boundary (never mid-glyph). Each fixture's
# title STARTS with a distinct ASCII marker whose normed char-offset == its cell
# offset. The pure-ASCII guard on the measured prefix catches an unmapped wide
# glyph (which would silently mismeasure) — a real bug masquerading as a pass.
for spec in '50 ZZCJK' '51 ZZMIX' '52 ZZEMOJI' '53 ZZTRUNC' '54 ZZNOMS'; do
  # shellcheck disable=SC2086  # spec is two space-free tokens by construction
  set -- $spec; n=$1; mk=$2
  rowd="$(disp_of "$out" "$n")"
  [ -n "$rowd" ] || fail "issue #432: row #$n not rendered" "$out"
  pre="${rowd%%"$mk"*}"
  [ "$pre" != "$rowd" ] || fail "issue #432: title marker '$mk' missing from row #$n" "$rowd"
  case "$pre" in
    *[![:ascii:]]*) fail "issue #432: unmapped wide glyph before '$mk' in row #$n — extend norm()" "$pre" ;;
  esac
  off=$(col_of "$rowd" "$mk")
  [ "$off" = "$exp_title" ] \
    || fail "issue #432: row #$n title ('$mk') starts at col $off, expected $exp_title — the CJK milestone column drifted" "$rowd"
done

# --- issue #374: the column-title row LEADS the producer output, in EVERY mode --
# The backlog pins the titles at the TOP with --header-lines=1, so the producer
# MUST emit the column-title line FIRST — before any milestone header (roadmap) or
# status line — or --header-lines=1 pins the wrong row (the bug this fixes, where
# the titles rendered at the bottom). Assert the first line of each mode has an
# EMPTY field1 (a non-spawn header, never an issue) and carries the #/pri/
# milestone/title labels in field2 — the header must lead regardless of how many
# data rows each mode yields (roadmap the milestoned fixtures, unplanned only #54).
for m in all roadmap unplanned; do
  mo="$(FLEET_SESSION='' bash "$ROWS" "$m" 2>/dev/null)"
  [ -n "$mo" ] || fail "mode '$m': producer emitted nothing (expected the column-title row to lead)"
  mf1="$(printf '%s\n' "$mo" | awk -F"$US" 'NR==1{print $1; exit}')"
  mf2="$(printf '%s\n' "$mo" | awk -F"$US" 'NR==1{print $2; exit}' | norm)"
  [ -z "$mf1" ] || fail "mode '$m': first line field1='$mf1', expected empty (header must not be spawnable)" "$mo"
  case "$mf2" in
    *'#'*pri*milestone*title*) : ;;
    *) fail "mode '$m': first output line is not the column-title row (field2='$mf2')" "$mo" ;;
  esac
done

printf 'selftest PASS: backlog column header aligns to the row widths (# %s · pri %s · milestone %s · title %s) and leads every mode\n' \
  "$h_num" "$h_pri" "$h_ms" "$h_title"
exit 0
