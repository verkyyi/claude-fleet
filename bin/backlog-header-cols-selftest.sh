#!/bin/bash
# backlog-header-cols-selftest.sh — the backlog modal's column-title header row
# (issue #371) stays aligned to the fixed-width columns of the rows it heads.
#
# The backlog (bin/tmux-issues.sh) draws a dim column-title line — `# pri owner
# title` — via fleet_backlog_col_header; the rows (bin/tmux-issues-rows.sh) lay
# field-2 out with the SAME FLEET_BL_W_* widths (fleet-lib.sh). This test renders
# a REAL row and the REAL header, strips ANSI, and asserts each header label
# starts at the SAME visible column where that column begins in the row — so a
# future width change that touches only one side can't silently misalign them.
# It also cross-checks both against the constants' own arithmetic.
#
# tmux is isolated onto a private `-S` socket via a PATH shim (never the live
# server, per the repo rail) and left with NO windows, so the rows producer sees
# empty active-bindings and renders free/assigned rows (which is all we measure).
# tmux absent → the shim is skipped; bare `tmux` calls fail closed to the same
# empty bindings. Column widths are measured multibyte-safely by collapsing the
# 1-col glyphs (·/◦/▶/⇡/↳) to a single ASCII byte under LC_ALL=C, so a byte count
# equals the visible column count regardless of the runner's locale.
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
# ZZTITLE / alice are distinctive ASCII markers we locate after stripping ANSI.
# The '·' assignee is what the collector writes for unassigned (never empty).
{
  printf 'Week 1%s#40%s·%sZZTITLE\n'     "$TAB" "$TAB" "$TAB"   # free (unassigned ·, blank marker)
  printf 'Week 1%s#41%salice%sZZTITLE\n' "$TAB" "$TAB" "$TAB"   # foreign claim (◦ marker + name)
} > "$C/issues"

# strip ANSI, then collapse the 1-col multibyte glyphs to 1 ASCII byte (byte-matched
# under LC_ALL=C) so a plain byte count == the visible column count in any locale.
norm() { LC_ALL=C sed -e $'s/\033\\[[0-9;]*m//g' \
                      -e 's/·/./g' -e 's/◦/./g' -e 's/▶/./g' -e 's/⇡/./g' -e 's/↳/./g'; }
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
exp_own=$((exp_pri + FLEET_BL_W_PRI + 1 + FLEET_BL_W_MARK))
exp_title=$((exp_own + FLEET_BL_W_NAME + 1))

# --- REAL row column offsets match the constants ----------------------------
row_num=$(col_of "$r_free" '#40')       # num column
row_own=$(col_of "$r_asg" 'alice')      # owner-NAME column (past the ◦ marker)
row_title=$(col_of "$r_free" 'ZZTITLE') # title column
[ "$row_num"   = "$exp_num" ]   || fail "row #num starts at col $row_num, expected $exp_num" "$r_free"
[ "$row_own"   = "$exp_own" ]   || fail "row owner name starts at col $row_own, expected $exp_own" "$r_asg"
[ "$row_title" = "$exp_title" ] || fail "row title starts at col $row_title, expected $exp_title" "$r_free"

# --- REAL header label offsets match the constants (and thus the row) --------
hdr="$(fleet_backlog_col_header | norm)"
[ -n "$hdr" ] || fail "fleet_backlog_col_header produced nothing"
h_num=$(col_of "$hdr" '#')
h_pri=$(col_of "$hdr" 'pri')
h_own=$(col_of "$hdr" 'owner')
h_title=$(col_of "$hdr" 'title')
[ "$h_num"   = "$exp_num" ]   || fail "header '#' at col $h_num, expected $exp_num (num column)" "$hdr"
[ "$h_pri"   = "$exp_pri" ]   || fail "header 'pri' at col $h_pri, expected $exp_pri (priority column)" "$hdr"
[ "$h_own"   = "$exp_own" ]   || fail "header 'owner' at col $h_own, expected $exp_own (owner column)" "$hdr"
[ "$h_title" = "$exp_title" ] || fail "header 'title' at col $h_title, expected $exp_title (title column)" "$hdr"

# --- and, most importantly, header title aligns EXACTLY with the row title ----
[ "$h_title" = "$row_title" ] || fail "header title (col $h_title) misaligned from row title (col $row_title)"
[ "$h_own"   = "$row_own" ]   || fail "header owner (col $h_own) misaligned from row owner (col $row_own)"

printf 'selftest PASS: backlog column header aligns to the row widths (# %s · pri %s · owner %s · title %s)\n' \
  "$h_num" "$h_pri" "$h_own" "$h_title"
exit 0
