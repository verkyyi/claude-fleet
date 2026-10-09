#!/usr/bin/env bash
# sidebar-machine-tag-selftest.sh — every session says which machine it runs on
# (issue #1780, EPIC #1776 C4) — in the client's bar, for the highlighted row,
# since issue #2305 moved it off the row. Drives bin/fleet-sidebar.py's own
# functions (machine_tag / detail_line / row_glyph / row_text) and
# bin/fleet-remote-view.sh's proxy title:
#   A. three kinds   — another machine `@m4` · this computer `@本机` · a lost
#                      machine `@m4!` · `@m5~` heard over the shell's own
#                      connection — each in the bar's detail line
#   B. the row       — state · name · N/N only: no mark at any width, row_need
#                      asks nothing for it; a lost machine's row takes `⊘` as
#                      its state glyph
#   C. degenerate    — field 9 empty (a node's own row): no mark in the bar
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
    # A. the three kinds of machine (+ the via mark), and where they show: the bar
    check(m.machine_tag("m4") == "@m4", "A: another machine → @m4")
    check(m.machine_tag("MacBook") == "@本机", "A: this computer (its alias) → @本机")
    check(m.machine_tag("macbookpro") == "@本机", "A: this computer (its hostname, any case) → @本机")
    check(m.machine_tag("m4!") == "@m4!", "A: a lost machine → @m4!")
    check(m.machine_tag("m5~") == "@m5~", "A: heard over the shell's connection → @m5~")
    row = m.row_fields("\x1f".join(("wid:x/issue-1", "working", "●", "issue-1", " ", "", "0", "", "m4", "#1")))
    check(m.detail_line(row) == "issue-1 · #1 · @m4", "A: the bar names the machine: %r" % m.detail_line(row))
    here = row[:8] + ["MacBook"] + row[9:]
    check("@本机" in m.detail_line(here), "A: …@本机 for this computer's own: %r" % m.detail_line(here))

    # B. the row never carries the mark (issue #2305), at any width
    left = w(m.row_left(" ", "●", "└", ""))
    for badge in ("", "2/3", "12/13"):
        for width in (28, 30, 39):
            text = m.row_text(" ", "●", "└", "x" * 60, badge, width)
            check("@" not in text and w(text) <= width and (not badge or text.endswith("· " + badge)),
                  "B: %d cells, badge %r: name + badge only: %r" % (width, badge, text))
    lost = row[:8] + ["m4!"] + row[9:]
    check(m.row_glyph(lost) == (m.LOST_GLYPH, "lost") and m.LOST_GLYPH == "⊘",
          "B: a lost machine's row says so in its state glyph: %r" % (m.row_glyph(lost),))
    check(m.row_glyph(row) == ("●", ""), "B: …a live one keeps its own glyph")
    bare = row[:8] + [""] + row[9:10] + [""] * 2
    check(m.row_need(row) == m.row_need(bare), "B: row_need asks no cells for the machine")

    # C. degenerate: no machine field → nothing to name
    check(m.machine_tag("") == "" and "@" not in m.detail_line(bare), "C: no machine, no mark in the bar")
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
