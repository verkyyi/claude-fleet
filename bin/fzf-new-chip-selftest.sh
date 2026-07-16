#!/bin/bash
# fzf-new-chip-selftest.sh — asserts the tappable `[＋ new]` button chip (issue
# #381) is wired on the two surfaces that file/spawn a session: the dash
# (tmux-dashboard.sh) and the backlog POPUP (tmux-issues.sh).
#
# Why: on Termius/iPad ⌃n (new issue/session) is swallowed by Termius's own
# new-tab shortcut and has no keyboard fallback, so a TAP path is the only way to
# create a session there. The chip rides the SAME click-header:transform mechanism
# as the `[✕ close]` chip (issue #346, fzf-modal-close-selftest.sh): tapping ＋/new
# transforms into the action that ⌃n runs. The chip is ADDITIVE — ⌃n stays bound.
#
# A bracketed multi-word chip `[＋ new]` is split by fzf into the header words `[＋`
# and `new]`, so $FZF_CLICK_HEADER_WORD is one or the other; the case globs
# *＋*|*new* so a tap ANYWHERE on the chip fires. This test proves that match holds
# and that both shipped binds still parse (fzf ≥0.71 exposes the click var).
#
# Hermetic: greps the shipped scripts + exercises the case logic and (when fzf is
# present) the live --bind parse. No tmux, no fzf UI, no network.
#
# Exit 0 = pass. Non-zero = fail (prints which assertion).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

pass=0
ok()   { pass=$((pass+1)); }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

DASH="$BIN/tmux-dashboard.sh"
BACKLOG="$BIN/tmux-issues.sh"
for f in "$DASH" "$BACKLOG"; do [ -f "$f" ] || fail "missing $f"; done
ok

# --- DASH: chip in the header + click-header emits the file+spawn action --------
grep -qF -- '[＋ new]' "$DASH" \
  || fail "dash: --header missing the '[＋ new]' button chip"
ok
# a click-header:transform bind whose ＋/new case runs the very file+spawn action
# (dash-issue-new.sh confirm --spawn) — the same one ⌃n runs.
grep -- 'click-header:transform' "$DASH" | grep -qF -- '*＋*|*new*)' \
  || fail "dash: click-header has no *＋*|*new* case"
grep -- 'click-header:transform' "$DASH" | grep -qF -- 'dash-issue-new.sh confirm --spawn' \
  || fail "dash: the ＋/new case must emit the file+spawn action (dash-issue-new.sh --spawn)"
ok
# ⌃n stays bound (additive, not a replacement) — same assertion as
# dash-issue-new-spawn-selftest.sh test E.
grep -Eq -- 'ctrl-n:.*dash-issue-new\.sh.*--spawn' "$DASH" \
  || fail "dash: ⌃n bind lost — the chip must be additive to ⌃n"
ok

# --- BACKLOG: chip in the POPUP header + click-header drops the 'new' sentinel ---
grep -qF -- '[＋ new]' "$BACKLOG" \
  || fail "backlog: POPUP --header missing the '[＋ new]' button chip"
ok
# the ＋/new case mirrors the POPUP ⌃n N_BIND: drop the 'new' sentinel + abort, so
# run_action files it in the gap (a nested popup can't open here, #123/#122).
grep -- 'click-header:transform' "$BACKLOG" | grep -qF -- "*＋*|*new*) printf 'new'" \
  || fail "backlog: the ＋/new case must drop the 'new' sentinel (mirror the popup ⌃n)"
ok
# ⌃n stays bound (additive).
grep -Eq -- 'ctrl-n:.*dash-issue-new\.sh' "$BACKLOG" \
  || fail "backlog: ⌃n bind lost — the chip must be additive to ⌃n"
ok

# --- behaviour: a tap on ANY word of `[＋ new]` (or a bare ＋/new) must match, and
# unrelated header words must NOT. This is the glob-vs-clicked-word contract. -----
case_new() { FZF_CLICK_HEADER_WORD="$1" bash -c \
  'case "$FZF_CLICK_HEADER_WORD" in *＋*|*new*) echo NEW ;; *) echo MISS ;; esac'; }
for w in '[＋' 'new]' '＋' 'new'; do
  [ "$(case_new "$w")" = NEW ] || fail "chip word '$w' should fire the new action"
done
for w in '↵' 'jump' 'work' 'keys' '?'; do
  [ "$(case_new "$w")" = MISS ] || fail "header word '$w' must NOT fire the new action"
done
ok

# --- both shipped binds must PARSE (filter mode validates --bind). The forms below
# mirror what the scripts build after shell expansion (abs paths standin). --------
DASH_BIND="click-header:transform:case \"\$FZF_CLICK_HEADER_WORD\" in *＋*|*new*) echo 'execute(tmux display-popup -w 72 -h 12 -E \"bash /b/dash-issue-new.sh confirm --spawn\")+reload(bash /b/rows)' ;; esac"
BACKLOG_BIND="click-header:transform:case \"\$FZF_CLICK_HEADER_WORD\" in *＋*|*new*) printf 'new' > '/tmp/act'; echo abort ;; *✕*|*close*) echo abort ;; esac"
if command -v fzf >/dev/null 2>&1; then
  printf 'x\n' | fzf -f x --bind "$DASH_BIND" >/dev/null 2>&1 \
    || fail 'fzf rejected the dash ＋ new bind — the syntax is no longer valid'
  printf 'x\n' | fzf -f x --bind "$BACKLOG_BIND" >/dev/null 2>&1 \
    || fail 'fzf rejected the backlog ＋ new bind — the syntax is no longer valid'
  ok
else
  printf 'fzf-new-chip-selftest: fzf absent — skipped the live bind-parse check\n'
fi

printf 'selftest PASS: %d assertions (dash + backlog [＋ new] chip: wiring, additive ⌃n, glob match, bind parse)\n' "$pass"
exit 0
