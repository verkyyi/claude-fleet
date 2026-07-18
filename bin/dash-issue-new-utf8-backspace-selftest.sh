#!/bin/bash
# dash-issue-new-utf8-backspace-selftest.sh — the "⌃n popup survives CJK" rail
# (issues #408 backspace, #419 paste, #422 whole-char echo).
#
# dash-issue-new.sh is the ONLY text popup with a hand-rolled per-character input
# loop (read_title). On an SSH/Termius popup whose server started without a UTF-8
# LC_CTYPE/LC_ALL, the process ran in the C locale, where the old backspace
# `title="${title%?}"` stripped a single BYTE off a multibyte glyph — leaving a
# broken half-character in the buffer — and `printf '\b \b'` erased only 1 of the 2
# cells a CJK glyph occupies, so the cursor desynced and the popup appeared to hang.
#
# A THIRD path (issue #422) is the per-character input ECHO: bash 3.2 reads one BYTE
# per `read -rsn1` even in a UTF-8 locale, so echoing each byte split a multibyte glyph
# across terminal/tmux writes — rendering tofu boxes (□) / duplicated cells. The fix
# assembles a whole glyph (utf8_len + continuation reads) and echoes it in ONE write.
#
# The fix is two parts, both lifted from the REAL script and driven here (not a
# copy):
#   1. force a UTF-8 locale up top, so `${title%?}` strips a WHOLE character;
#   2. redraw the whole input line on backspace (\r + prefix+title + \033[K)
#      instead of the width-broken incremental `\b \b`.
#
# We extract JUST the locale export + utf8_len + read_title + read_paste out of
# dash-issue-new.sh, source them, reproduce the bug's C-locale popup env (LC_ALL/
# LC_CTYPE/LANG unset — as SSH leaves them), then feed read_title raw byte sequences
# and assert:
#   • UTF8LEN  utf8_len classifies ASCII/2/3/4-byte lead bytes as 1/2/3/4 (issue #422).
#   • WHOLECHAR read_title's ECHO of a mixed ASCII+CJK+emoji title is byte-identical to
#              the input and valid UTF-8 — whole glyphs, never a split write (issue #422).
#   • VALID    a CJK title + N backspaces leaves `title` VALID UTF-8 (iconv round
#              trip), never a partial-byte remnant, and empties cleanly.
#   • EVERYSTEP a mixed ASCII+CJK+emoji title stays valid UTF-8 after every backspace.
#   • NOUNDERFLOW over-backspacing an empty buffer never corrupts it.
#   • CONTROL  Esc (0x1b) still cancels (rc 1); Enter (newline) still submits (rc 0)
#              with the typed title; an empty title still reads back empty; a typed
#              space is preserved; the ASCII fast path is unregressed.
#   • PASTE    a bracketed multi-line paste (ESC[200~ … ESC[201~) folds every newline
#              to a SINGLE space (no leading/run/trailing), stays valid UTF-8 for CJK,
#              lands a single-line paste verbatim, does NOT auto-submit (issue #419) —
#              and a lone Esc after a paste still cancels.
#   • STRUCTURE the shipped code still carries the locale export, redraws the line (no
#              `\b \b`), keeps the paste path (?2004h enable + ESC[200~ hand-off +
#              ESC[201~ end marker), and assembles whole glyphs (utf8_len) in both input
#              paths, so a refactor dropping any of them trips this test.
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
  grep -E '^export LANG=.*LC_ALL=' "$NEW"                          # part 1: forced UTF-8 locale
  awk '/^utf8_len\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$NEW"     # part 2: utf8_len (issue #422) — defined before read_title uses it
  awk '/^read_title\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$NEW"   # part 3: read_title
  awk '/^read_paste\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$NEW"   # part 4: read_paste (issue #419)
} > "$SHIM"

grep -q 'LC_ALL='      "$SHIM" || fail "no UTF-8 locale export found in $NEW (part 1 regressed or moved?)"
grep -q 'utf8_len()'   "$SHIM" || fail "could not extract utf8_len() from $NEW (issue #422 helper moved/renamed?)"
grep -q 'read_title()' "$SHIM" || fail "could not extract read_title() from $NEW (moved/renamed?)"
grep -q 'read_paste()' "$SHIM" || fail "could not extract read_paste() from $NEW (moved/renamed?)"
# STRUCTURE: backspace must redraw the line (\033[K), NOT the old incremental erase.
grep -qF '[K'    "$SHIM" || fail "read_title backspace no longer redraws the line (\\033[K) — part 2 regressed" "$(cat "$SHIM")"
grep -qF '\b \b' "$SHIM" && fail "read_title still uses the width-broken '\\b \\b' erase — part 2 regressed" "$(cat "$SHIM")"
ok "STRUCTURE the shipped read_title carries the UTF-8 export + line-redraw erase (no \\b \\b)"
# STRUCTURE (issue #419): the paste fix must keep (a) the ?2004h enable that makes the
# terminal bracket a paste, (b) read_title's ESC[200~ paste-start hand-off, and (c)
# read_paste's ESC[201~ end-marker detection. Dropping any one silently reintroduces
# the first-newline truncation, so trip the test instead of no-op'ing.
grep -qF '2004h' "$NEW"  || fail "bracketed-paste enable (\\033[?2004h) dropped from $NEW — paste fix regressed"
grep -qF '200~'  "$SHIM" || fail "read_title no longer hands ESC[200~ paste-start to read_paste — regressed" "$(cat "$SHIM")"
grep -qF '201~'  "$SHIM" || fail "read_paste no longer detects the ESC[201~ end marker — regressed" "$(cat "$SHIM")"
ok "STRUCTURE the paste path is intact (?2004h enable + ESC[200~ hand-off + ESC[201~ end marker)"
# STRUCTURE (issue #422): the INPUT echo must assemble a WHOLE glyph before writing —
# read_title's ordinary-char case (and read_paste's) read the continuation bytes via
# utf8_len instead of echoing each byte, so a multibyte sequence never splits across a
# terminal/tmux write and renders □/dupes. A refactor back to per-byte echo drops the
# utf8_len call from these functions and trips this.
awk '/^read_title\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$NEW" > "$WORK/rt.sh"
awk '/^read_paste\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$NEW" > "$WORK/rp.sh"
grep -q 'utf8_len' "$WORK/rt.sh" || fail "read_title no longer assembles whole UTF-8 chars (utf8_len) — per-byte echo regressed (issue #422)" "$(cat "$WORK/rt.sh")"
grep -q 'utf8_len' "$WORK/rp.sh" || fail "read_paste no longer assembles whole UTF-8 chars (utf8_len) — per-byte echo regressed (issue #422)" "$(cat "$WORK/rp.sh")"
ok "STRUCTURE both input paths assemble whole UTF-8 glyphs (utf8_len) before echoing — no per-byte echo (issue #422)"

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
INF="$WORK/in"; ECHOF="$WORK/echo"
drive() { # $1 = raw input bytes (\0ooo octal escapes honored via %b)
  printf '%b' "$1" > "$INF"
  title=""
  # Capture the ECHO (stdout) too, into $ECHOF, so the whole-char echo assertion
  # (issue #422) can inspect exactly what read_title wrote to the terminal. title/rc
  # assertions are unaffected — they never read stdout.
  read_title 'title ▸ ' < "$INF" > "$ECHOF" 2>/dev/null
  rt_rc=$?
}
DEL='\0177'; ESC='\033'; NL='\n'; CR='\r'   # 0x7f backspace · 0x1b esc · 0x0a enter · 0x0d CR
PS='\033[200~'; PE='\033[201~'      # bracketed-paste start / end markers (issue #419)
CJK='中文标题'                       # 4 CJK glyphs, 3 bytes each
MIX='ab中😀c'                        # ASCII + CJK + 4-byte emoji + ASCII

# ============================ UTF8LEN: lead-byte length (issue #422) =========
# utf8_len classifies a LEAD byte into its glyph's total byte length (1..4). Passing the
# whole char is fine: in the C locale `printf '%d' "'X"` reads only the FIRST byte, which
# is the lead byte read_title actually hands it.
for pair in 'a:1' '£:2' '中:3' '😀:4'; do
  c="${pair%%:*}"; want="${pair##*:}"; got=$(utf8_len "$c")
  [ "$got" = "$want" ] || fail "utf8_len lead byte of [$c] must be $want, got $got"
done
ok "UTF8LEN classifies ASCII/2/3/4-byte lead bytes as 1/2/3/4 (a/£/中/😀)"

# ============================ WHOLECHAR: whole-glyph echo (issue #422) =======
# bash 3.2 reads one BYTE per `read -rsn1`, so the OLD code echoed each byte separately —
# splitting a multibyte glyph across terminal/tmux writes → □/duplicated cells. The fix
# assembles the whole glyph and writes it ONCE. Drive a mixed title and assert the ECHO
# (stdout, trailing \n stripped) is byte-identical to the input and valid UTF-8, and that
# $title matches. (Byte content equals the old code; the STRUCTURE anchor above guards the
# write-atomicity a pipe can't observe.)
drive "ab中文😀c${NL}"
[ "$rt_rc" -eq 0 ]            || fail "WHOLECHAR Enter must submit (rc 0), got $rt_rc"
echo_out=$(cat "$ECHOF")      # $(...) strips the single trailing newline read_title emits on submit
[ "$echo_out" = "ab中文😀c" ] || fail "echo must be byte-identical to 'ab中文😀c' (whole glyphs), got [$echo_out]" "$(printf '%s' "$echo_out" | (xxd 2>/dev/null || od -An -tx1))"
valid_utf8 "$echo_out"        || fail "the echoed bytes must be valid UTF-8 (no split multibyte sequence)" "$(printf '%s' "$echo_out" | (xxd 2>/dev/null || od -An -tx1))"
[ "$title" = "ab中文😀c" ]    || fail "WHOLECHAR \$title must be 'ab中文😀c', got [$title]"
ok "WHOLECHAR read_title echoes whole UTF-8 glyphs (ab中文😀c) — byte-identical + valid UTF-8"

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

# ============================ PASTE: multi-line → single line ================
# A bracketed multi-line paste folds EVERY newline to a single space; nothing is
# truncated at the first newline (issue #419). The paste does NOT auto-submit — the
# trailing real Enter does, so the operator can review/edit first.
drive "${PS}foo${NL}bar${NL}baz${PE}${NL}"
[ "$rt_rc" -eq 0 ]           || fail "PASTE multi-line must submit on the trailing Enter (rc 0), got $rt_rc"
[ "$title" = "foo bar baz" ] || fail "multi-line paste must fold newlines to single spaces → 'foo bar baz', got [$title]"
ok "PASTE multi-line bracketed paste folds newlines to spaces (foo bar baz) — no first-newline truncation"

# ============================ PASTE-CRLF: \r\n → ONE space ===================
drive "${PS}foo${CR}${NL}bar${PE}${NL}"
[ "$title" = "foo bar" ] || fail "CRLF paste must fold \\r\\n to a SINGLE space → 'foo bar', got [$title]"
ok "PASTE-CRLF a \\r\\n paste folds to a single space (no run, no double space)"

# ============================ PASTE-TRAILING-NL: no trailing space ==========
drive "${PS}foo${NL}${PE}${NL}"
[ "$title" = "foo" ] || fail "a paste ending in a newline must leave NO trailing space → 'foo', got [$title]"
ok "PASTE-TRAILING-NL a paste ending in a newline leaves no trailing space"

# ============================ PASTE-CJK: stays valid UTF-8 ==================
drive "${PS}中文${NL}标题${PE}${NL}"
valid_utf8 "$title"         || fail "CJK paste must stay valid UTF-8" "$(printf '%s' "$title" | (xxd 2>/dev/null || od -An -tx1))"
[ "$title" = $'中文 标题' ] || fail "CJK paste must fold to '中文 标题', got [$title]"
ok "PASTE-CJK a paste containing CJK folds correctly and stays valid UTF-8"

# ============================ PASTE-CJK-2: single-line CJK paste (issue #422) =
# A single-line CJK paste with an embedded literal space lands verbatim and stays valid
# UTF-8 — exercises read_paste's whole-glyph echo (utf8_len assembly) on the paste path.
drive "${PS}北京 上海${PE}${NL}"
[ "$rt_rc" -eq 0 ]         || fail "single-line CJK paste must submit on Enter (rc 0), got $rt_rc"
valid_utf8 "$title"        || fail "single-line CJK paste must stay valid UTF-8" "$(printf '%s' "$title" | (xxd 2>/dev/null || od -An -tx1))"
[ "$title" = $'北京 上海' ] || fail "single-line CJK paste must land verbatim → '北京 上海', got [$title]"
ok "PASTE-CJK-2 a single-line CJK paste (北京 上海) lands verbatim and stays valid UTF-8"

# ============================ PASTE-SINGLE: single-line paste ================
# A single-line bracketed paste (no newline) lands verbatim, keeping its literal
# space — this ALSO proves 2004h isn't cancelling pastes: without the ESC[200~
# handler, enabling 2004h would make this paste's leading ESC cancel the popup.
drive "${PS}hello world${PE}${NL}"
[ "$rt_rc" -eq 0 ]           || fail "single-line paste must submit on Enter (rc 0), got $rt_rc"
[ "$title" = "hello world" ] || fail "single-line paste must land verbatim → 'hello world', got [$title]"
ok "PASTE-SINGLE a single-line bracketed paste lands as the title (literal space kept, no cancel)"

# ============================ PASTE then Esc still cancels ===================
# After a paste, read_title is back in control: a lone Esc must still cancel cleanly.
drive "${PS}foo${PE}${ESC}"
[ "$rt_rc" -eq 1 ] || fail "a lone Esc after a paste must still cancel (rc 1), got $rt_rc"
ok "PASTE then lone Esc still cancels (rc 1) — read_title regains control after read_paste"

printf '\nselftest OK: %s assertions passed (⌃n popup echoes whole UTF-8 glyphs + survives CJK backspace + folds bracketed paste to one line, controls intact)\n' "$pass"
exit 0
