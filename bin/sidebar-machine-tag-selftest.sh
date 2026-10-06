#!/usr/bin/env bash
# sidebar-machine-tag-selftest.sh — every session row says which machine it runs
# on (issue #1780, EPIC #1776 C4). Drives bin/fleet-sidebar.py's own layout
# (row_layout / machine_tag / tag_pair) and bin/tmux-dashboard-rows.sh's node row:
#   A. three kinds   — another machine `@m4` dim · this computer `@本机` magenta ·
#                      a lost machine `@m4!` dim (and the row dims) · `@m5~` heard
#                      over the shell's own connection
#   B. 40 cells      — the name keeps >= 18 cells beside the mark, badge or not;
#                      narrower, the mark is `@` + its first letter
#   C. degenerate    — field 9 empty (a node's own row): no mark, the row is
#                      byte for byte row_text as before
#   D. English       — `@here`
#   E. proxy title   — fleet-remote-view.sh titles a proxy `<name> · @m4`
#                      (`@本机` on this computer), never `m4 <name>`
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

CHECKS=0 FAIL=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*" >&2; }

run_py() {   # <lang> — the checks below, in that UI language
  FLEET_UI_LANG="$1" FLEET_SIDEBAR_HOST="MacBookPro.local" \
  FLEET_NODE_ALIASES="macmini=m5 mini2=m4 MacBookPro=MacBook" \
  python3 - "$BIN/fleet-sidebar.py" "$1" <<'PY'
import importlib.util, sys, unicodedata
spec = importlib.util.spec_from_file_location("sb", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lang = sys.argv[2]
n = 0
def check(cond, what):
    global n
    n += 1
    print(("ok   " if cond else "FAIL ") + what)
w = lambda t: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)

if lang == "zh":
    # A. the three kinds of row (+ the via mark)
    check(m.machine_tag("m4") == "@m4", "A: another machine → @m4")
    check(m.machine_tag("MacBook") == "@本机", "A: this computer (its alias) → @本机")
    check(m.machine_tag("macbookpro") == "@本机", "A: this computer (its hostname, any case) → @本机")
    check(m.machine_tag("m4!") == "@m4!", "A: a lost machine → @m4!")
    check(m.machine_tag("m5~") == "@m5~", "A: heard over the shell's connection → @m5~")
    check(m.tag_pair("m4") == m.PAIR_DIM, "A: @m4 is dim grey")
    check(m.tag_pair("MacBook") == m.PAIR_HERE, "A: @本机 is its own colour")
    check(m.PAIRS[m.PAIR_HERE][0] == "PAL_MAGENTA", "A: …magenta (the palette's)")
    check(m.tag_pair("m4!") == m.PAIR_DIM, "A: @m4! is dim")
    check(m.tag_pair("MacBook!") == m.PAIR_DIM, "A: this computer lost → dim, not magenta")
    check(m.tag_pair("MacBook", raised=True) == m.PAIR_HERE + m.SEL_GLYPH
          and m.PAIRS[m.PAIR_HERE + m.SEL_GLYPH] == ("PAL_MAGENTA", "PAL_SEL"), "A: raised @本机 keeps the row's ground")
    check(m.tag_pair("m4", raised=True) == m.PAIR_DIM_SEL
          and m.PAIRS[m.PAIR_DIM_SEL] == ("PAL_DIM", "PAL_SEL"), "A: raised @m4 keeps the row's ground")
    check(len(set(m.PAIRS)) == len(m.PAIRS) and m.PAIR_DIM_SEL not in (m.PAIR_HERE + m.SEL_GLYPH,)
          and all(p + m.SEL_GLYPH not in (m.PAIR_DIM_SEL, m.PAIR_HERE + m.SEL_GLYPH) for p in m.STATE_PAIR.values()),
          "A: the mark's pairs collide with no other pair")
    # the row's end: the mark sits in the last cells, the name before it
    text, tag = m.row_layout(" ", "●", " ", "issue-1780", "", 39, "", "m4")
    check(tag == "@m4" and w(text) <= 39 - 4, "A: the row leaves the mark its cells: %r %r" % (text, tag))
    text, tag = m.row_layout(" ", "●", " ", "issue-1780", "2/3", 39, "", "MacBook")
    check(tag == "@本机" and text.endswith("· 2/3") and w(text) == 39 - w("@本机") - 1,
          "A: the badge keeps its place left of the mark: %r" % text)

    # B. a 40-cell sidebar (39 drawable cells): the name keeps >= 18
    left = w(m.row_left(" ", "●", "└", ""))
    for badge in ("", "2/3", "12/13"):
        for node in ("m4", "MacBook", "m4!", "m5~"):
            name = "x" * 60
            text, tag = m.row_layout(" ", "●", "└", name, badge, 39, "", node)
            right = m.row_right(badge)
            room = w(text) - left - (w(right) + 1 if right else 0)
            check(tag and room >= m.NAME_MIN - 1 and w(text) + w(tag) + 1 <= 39,
                  "B: 40 cells, badge %r, %s: name column %d (>= 18 with its …), mark %r"
                  % (badge, node, room + 1, tag))
    check(m.NAME_MIN == 18, "B: the floor is 18 cells")
    # narrower: the mark gives way to `@` + its first letter, never the name's floor
    text, tag = m.row_layout(" ", "●", "└", "x" * 60, "2/3", 30, "", "m4")
    check(tag == "@m", "B: 30 cells with a badge → @m (%r)" % tag)
    text, tag = m.row_layout(" ", "●", "└", "x" * 60, "2/3", 30, "", "m4!")
    check(tag == "@m!", "B: …a lost one keeps its ! (%r)" % tag)
    text, tag = m.row_layout(" ", "●", "└", "x" * 60, "", 28, "", "MacBook")
    check(tag == "@本", "B: 28 cells, this computer → @本 (%r)" % tag)
    check(m.row_layout(" ", "●", " ", "abc", "", 4, "", "m4")[1] == "", "B: no room at all → no mark")
    # the auto width asks for the mark too
    row = m.row_fields("\x1f".join(("wid:x/issue-1", "working", "●", "issue-1", " ", "", "0", "", "m4")))
    bare = row[:8] + [""] * 4
    check(m.row_need(row) == m.row_need(bare) + 4, "B: row_need adds `@m4` + a gap")

    # C. degenerate: no machine field → no mark, row_text byte for byte
    for badge in ("", "1/2"):
        text, tag = m.row_layout("▶", "●", " ", "issue-7", badge, 29, "", "")
        check(tag == "" and text == m.row_text("▶", "●", " ", "issue-7", badge, 29),
              "C: an empty field 9 draws exactly the old row (badge %r)" % badge)
    check(m.machine_tag("") == "" and m.tag_need("") == 0, "C: no machine, no mark, no cells")
else:
    # D. English
    check(m.machine_tag("MacBook") == "@here", "D: English → @here")
    check(m.machine_tag("m4") == "@m4", "D: …another machine as ever")
print("CHECKS %d" % n)
PY
}

for lang in zh en; do
  out=$(run_py "$lang" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -v '^CHECKS'
  CHECKS=$((CHECKS + $(printf '%s\n' "$out" | sed -n 's/^CHECKS //p' | head -1 | grep -E '^[0-9]+$' || echo 0)))
  [ "$rc" = 0 ] || fail "python ($lang) exited $rc"
  FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^FAIL')))
done

# E. the proxy window's title (fleet-remote-view.sh): `<name> · @m4`, `@本机` here
CHECKS=$((CHECKS + 1))
src=$(sed -n '/^rv_machine_word()/,/^}/p' "$BIN/fleet-remote-view.sh")
[ -n "$src" ] || fail "E: fleet-remote-view.sh has rv_machine_word"
words=$(FLEET_UI_LANG=zh FLEET_SIDEBAR_HOST=macmini.local FLEET_NODE_ALIASES="macmini=m5 mini2=m4" BIN="$BIN" bash -c '
  . "$BIN/fleet-ui-lang.sh"; eval "$1"
  printf "%s|%s|%s|%s" "$(rv_machine_word m4)" "$(rv_machine_word m5)" "$(rv_machine_word M5)" "$(rv_machine_word macmini)"' _ "$src")
[ "$words" = "m4|本机|本机|本机" ] && printf 'ok   E: the title'"'"'s machine word: m4 elsewhere, 本机 here\n' \
  || fail "E: the title's machine word — got [$words] want [m4|本机|本机|本机]"
CHECKS=$((CHECKS + 1))
if grep -q 'title="${name:-${wid#\*/}} · @$(rv_machine_word "$node")"' "$BIN/fleet-remote-view.sh" \
   && ! grep -q 'title="$node ' "$BIN/fleet-remote-view.sh"; then
  printf 'ok   E: a proxy is titled <name> · @<machine>, no machine prefix\n'
else
  fail "E: fleet-remote-view.sh titles a proxy <name> · @<machine>"
fi

if [ "$FAIL" -gt 0 ]; then
  printf 'sidebar-machine-tag selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'sidebar-machine-tag selftest: PASS (%d checks)\n' "$CHECKS"
