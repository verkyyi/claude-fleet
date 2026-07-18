#!/bin/bash
# dash-issue-new-utf8-backspace-selftest.sh — the "⌃n popup survives CJK backspace"
# rail (issue #408).
#
# dash-issue-new.sh is the ONLY text popup with a hand-rolled per-character input
# loop (read_title). On an SSH/Termius popup whose server started without a UTF-8
# LC_CTYPE/LC_ALL, the process ran in the C locale, where the old backspace
# `title="${title%?}"` stripped a single BYTE off a multibyte glyph — leaving a
# broken half-character in the buffer — and `printf '\b \b'` erased only 1 of the 2
# cells a CJK glyph occupies, so the cursor desynced and the popup appeared to hang.
#
# The fix is two parts, both lifted from the REAL script and driven here (not a
# copy):
#   1. force a UTF-8 locale up top, so `${title%?}` strips a WHOLE character;
#   2. redraw the whole input line on backspace (\r + prefix+title + \033[K)
#      instead of the width-broken incremental `\b \b`.
#
# We extract JUST the locale export + read_title out of dash-issue-new.sh, source
# them, reproduce the bug's C-locale popup env (LC_ALL/LC_CTYPE/LANG unset — as SSH
# leaves them), then feed read_title raw byte sequences and assert:
#   • VALID    a CJK title + N backspaces leaves `title` VALID UTF-8 (iconv round
#              trip), never a partial-byte remnant, and empties cleanly.
#   • EVERYSTEP a mixed ASCII+CJK+emoji title stays valid UTF-8 after every backspace.
#   • NOUNDERFLOW over-backspacing an empty buffer never corrupts it.
#   • CONTROL  Esc (0x1b) still cancels (rc 1); Enter (newline) still submits (rc 0)
#              with the typed title; an empty title still reads back empty; a typed
#              space is preserved; the ASCII fast path is unregressed.
#   • STRUCTURE the shipped code still carries the locale export and redraws the line
#              (no `\b \b`), so a future refactor that drops either trips this test.
#
# No network, no tmux server, no real repo — read_title reads from a byte file. Runs
# genuinely only where a UTF-8 locale is installed (so the forced locale can engage);
# on a box without one it SKIPs cleanly (exit 0) after the structural checks, per the
# suite convention. Exit 0 = pass; non-zero = fail (prints the failing assertion).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
NEW="$BIN/dash-issue-new.sh"
[ -f "$NEW" ] || { printf 'selftest: %s missing\n' "$NEW" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/newutf8-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
skip() { printf 'SKIP %s\n' "$1"; exit 0; }

# ============================ extract the fix under test =====================
# read_title lives INSIDE dash-issue-new.sh (it isn't a library), so lift only the
# UTF-8 locale export (part 1) + the read_title function (part 2) into a sourceable
# shim — we drive the ACTUAL shipped code, not a hand-copied duplicate. Fail loud if
# either anchor moves so a future refactor trips this test instead of no-op'ing.
SHIM="$WORK/shim.sh"
{
  grep -E '^export LANG=.*LC_ALL=' "$NEW"                          # part 1
  awk '/^read_title\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$NEW"   # part 2
} > "$SHIM"

grep -q 'LC_ALL='      "$SHIM" || fail "no UTF-8 locale export found in $NEW (part 1 regressed or moved?)"
grep -q 'read_title()' "$SHIM" || fail "could not extract read_title() from $NEW (moved/renamed?)"
# STRUCTURE: backspace must redraw the line (\033[K), NOT the old incremental erase.
grep -qF '[K'    "$SHIM" || fail "read_title backspace no longer redraws the line (\\033[K) — part 2 regressed" "$(cat "$SHIM")"
grep -qF '\b \b' "$SHIM" && fail "read_title still uses the width-broken '\\b \\b' erase — part 2 regressed" "$(cat "$SHIM")"
ok "STRUCTURE the shipped read_title carries the UTF-8 export + line-redraw erase (no \\b \\b)"

# ============================ reproduce the C-locale popup ===================
# SSH/Termius forward LANG but usually not LC_CTYPE/LC_ALL, so a popup off a server
# started without them defaults to the C locale — the bug's habitat. Unset them all
# so that WITHOUT the export the shim would run in C (byte-strip); WITH it, part 1
# must convert to UTF-8. Then source the shim: its export runs in THIS shell.
unset LC_ALL LC_CTYPE LANG LC_MESSAGES LC_COLLATE LC_NUMERIC 2>/dev/null || true
# shellcheck disable=SC1090
. "$SHIM"

# Did the forced locale actually engage on this box? (${x%?} char-aware ⇒ UTF-8.)
_p=$'中'                     # 中
if [ -n "${_p%?}" ]; then
  if locale -a 2>/dev/null | grep -qix 'en_US.UTF-8'; then
    fail "forced UTF-8 locale did not engage though en_US.UTF-8 is installed — part 1 broken"
  fi
  skip "no en_US.UTF-8 installed; the script's forced locale can't engage here (structural checks passed)"
fi

HAVE_ICONV=0; command -v iconv >/dev/null 2>&1 && HAVE_ICONV=1
valid_utf8() { # 0 = valid UTF-8. Falls back to a permissive pass if iconv is absent.
  [ "$HAVE_ICONV" = 1 ] || return 0
  printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}

# drive the REAL read_title on a raw byte string. read_title assigns the GLOBAL
# `title`; we call it in THIS shell (no pipe/subshell), so $title + $rt_rc survive.
INF="$WORK/in"
drive() { # $1 = raw input bytes (\0ooo octal escapes honored via %b)
  printf '%b' "$1" > "$INF"
  title=""
  read_title 'title ▸ ' < "$INF" >/dev/null 2>&1
  rt_rc=$?
}
DEL='\0177'; ESC='\033'; NL='\n'    # 0x7f backspace · 0x1b esc · 0x0a enter
CJK='中文标题'                       # 4 CJK glyphs, 3 bytes each
MIX='ab中😀c'                        # ASCII + CJK + 4-byte emoji + ASCII

# ============================ VALID: CJK + partial backspace ================
# 中文标题 then 2 backspaces (EOF) → the buffer holds 中文, VALID UTF-8, no half-char.
drive "${CJK}${DEL}${DEL}"
[ "$rt_rc" -eq 0 ]        || fail "VALID EOF should submit (rc 0), got $rt_rc"
valid_utf8 "$title"       || fail "CJK title after 2 backspaces must be valid UTF-8 (no partial byte)" "$(printf '%s' "$title" | (xxd 2>/dev/null || od -An -tx1))"
[ "$title" = $'中文' ] || fail "expected 中文 after 2 backspaces, got [$title]"
ok "VALID CJK title + 2 backspaces leaves a valid-UTF-8 buffer (中文, no half-char)"

# ============================ VALID: empties cleanly ========================
drive "${CJK}${DEL}${DEL}${DEL}${DEL}"
valid_utf8 "$title" || fail "emptied CJK buffer must be valid UTF-8"
[ -z "$title" ]     || fail "4 backspaces over a 4-char CJK title must empty it, got [$title]"
ok "VALID CJK title empties cleanly after enough backspaces (no dangling bytes)"

# ============================ NOUNDERFLOW ===================================
# more backspaces than characters must never corrupt or dip below empty.
drive "${CJK:0:1}${DEL}${DEL}${DEL}"     # one glyph (中), 3 backspaces
valid_utf8 "$title" || fail "over-backspaced buffer must stay valid UTF-8"
[ -z "$title" ]     || fail "over-backspacing a 1-char title must leave it empty, got [$title]"
ok "NOUNDERFLOW over-backspacing an empty buffer never corrupts it"

# ============================ EVERYSTEP: mixed script, each step ============
# ab中😀c backspaced one glyph at a time — the buffer is valid UTF-8 at EVERY step.
for k in 0 1 2 3 4 5 6; do
  bs=""; i=0; while [ "$i" -lt "$k" ]; do bs="${bs}${DEL}"; i=$((i+1)); done
  drive "${MIX}${bs}"
  valid_utf8 "$title" || fail "mixed ASCII+CJK+emoji invalid UTF-8 after $k backspace(s)" "$(printf '%s' "$title" | (xxd 2>/dev/null || od -An -tx1))"
done
ok "EVERYSTEP mixed ASCII+CJK+emoji stays valid UTF-8 after every backspace (0..6)"

# ============================ CONTROL: Esc cancels ==========================
drive "${CJK}${ESC}"
[ "$rt_rc" -eq 1 ] || fail "Esc after a partial title must cancel (rc 1), got $rt_rc"
drive "${ESC}"
[ "$rt_rc" -eq 1 ] || fail "Esc as the first key must cancel (rc 1), got $rt_rc"
ok "CONTROL Esc (0x1b) cancels (rc 1) — first key and mid-title"

# ============================ CONTROL: Enter submits ========================
drive "hello${CJK:0:1}${NL}"             # hello中 then Enter
[ "$rt_rc" -eq 0 ]              || fail "Enter must submit (rc 0), got $rt_rc"
[ "$title" = "hello"$'中' ] || fail "Enter must submit the typed title 'hello中', got [$title]"
ok "CONTROL Enter (newline) submits the typed title (rc 0)"

# ============================ CONTROL: empty + space =========================
drive "${NL}"                            # bare Enter → empty title (caller cancels)
[ "$rt_rc" -eq 0 ] || fail "bare Enter must return rc 0, got $rt_rc"
[ -z "$title" ]    || fail "bare Enter must leave an empty title, got [$title]"
drive "a b${NL}"                         # a<space>b → the space is preserved (IFS=)
[ "$title" = "a b" ] || fail "a typed space must be preserved, got [$title]"
ok "CONTROL empty title reads back empty; a typed space is preserved"

# ============================ ASCII fast path (no regression) ================
drive "fix bug${NL}"
[ "$rt_rc" -eq 0 ] && [ "$title" = "fix bug" ] || fail "ASCII fast path regressed: rc=$rt_rc title=[$title]"
drive "widget${DEL}${DEL}${NL}"          # widg after 2 ASCII backspaces
[ "$title" = "widg" ] || fail "ASCII backspace regressed, expected 'widg', got [$title]"
ok "ASCII fast path (type + backspace + submit) is unregressed"

printf '\nselftest OK: %s assertions passed (⌃n popup survives CJK backspace — valid-UTF-8 buffer + width-correct erase, controls intact)\n' "$pass"
exit 0
