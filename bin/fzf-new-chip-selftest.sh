#!/bin/bash
# fzf-new-chip-selftest.sh — the tappable `[＋ new]` button chip (issue #381) on
# the two surfaces that file/spawn a session — with OPPOSITE contracts since #536:
#   * the backlog POPUP (tmux-issues.sh) STILL carries it in its hint line;
#   * the dash (tmux-dashboard.sh) carries NO hint line at all any more, so no
#     chip and no header-tap bind — ⌃n is the dash's only new-issue+worker path.
#
# Why the chip (backlog): on Termius/iPad ⌃n (new issue/session) is swallowed by
# Termius's own new-tab shortcut and has no keyboard fallback, so a TAP path is the
# only way to create a session there. The chip rides the SAME click-header:transform
# mechanism as the `[✕ close]` chip (issue #346, fzf-modal-close-selftest.sh):
# tapping ＋/new transforms into the action that ⌃n runs. ADDITIVE — ⌃n stays bound.
#
# Why NOT on the dash (#536): the dash's bottom row is an always-visible prompt
# line (#493), and the hint line above it — `↵ jump · [＋ new] · ? keys` — had gone
# stale against it: `↵ jump` contradicted the ghost text's `↵ → scratch`, `? keys`
# only fires on an EMPTY line, and the `? keys` token was never tappable. The
# operator chose to drop the row outright rather than relocate its content, so this
# half of the test is a NEGATIVE contract: the row, the chip and the tap bind must
# not quietly come back.
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

# --- DASH: NO hint line, NO chip, NO header-tap bind (issue #536) ----------------
# `--header=` is the hint-line flag; `--header-lines=1` (the pinned column-title
# row from the rows producer) is a different flag and is expected to stay.
grep -q -- '--header=' "$DASH" \
  && fail "dash: the --header hint line is back (dropped in #536 — the prompt line's ghost text carries the ↵ hint)"
grep -qF -- '[＋ new]' "$DASH" \
  && fail "dash: the '[＋ new]' chip is back (dropped with the hint line in #536)"
grep -q -- 'click-header' "$DASH" \
  && fail "dash: a click-header bind is back — there is no hint row to tap since #536"
ok
# ⌃n is the dash's ONLY new-issue+worker path now — same assertion as
# dash-issue-new-spawn-selftest.sh test E.
# the key is `$DASH_KEY_NEW` (ctrl-n by default), resolved against the tmux
# prefix by dash-keymap.sh (#556) — never a literal chord in the dash source.
grep -Eq -- '\$DASH_KEY_NEW:.*dash-issue-new\.sh.*--spawn' "$DASH" \
  || fail "dash: ⌃n (\$DASH_KEY_NEW) bind lost — it is the dash's only new-issue+worker path since #536"
ok
# the ghost text carries the ↵ hint (the hint line used to say `↵ jump`). Since
# #554 it is DERIVED — bin/dash-agent-prompt.sh names the OTHER agent's one-off
# prefix after the ↵ hint — so pin (a) that the dash takes it from the helper, not
# a literal, and (b) the helper's claude-default wording, run from a sandboxed bin
# (no ../fleet.conf, no conf estate) so a live install's FLEET_AGENT can't skew it.
grep -qF -- '--ghost="$GHOST_NOW"' "$DASH" \
  || fail "dash: the prompt-line ghost must come from dash-agent-prompt.sh (#554), not a literal"
GW="$(mktemp -d "${TMPDIR:-/tmp}/chip-ghost.XXXXXX")" || fail "mktemp failed"
mkdir -p "$GW/bin"; ln -s "$BIN/dash-agent-prompt.sh" "$GW/bin/"; ln -s "$BIN/fleet-lib.sh" "$GW/bin/"
ghost="$(FLEET_SESSION=chipsess FLEET_CONF_DIR="$GW/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$GW" bash "$GW/bin/dash-agent-prompt.sh" ghost)"
rm -rf "$GW"
[ "$ghost" = '↵ empty scratch · codex: prefix for a one-off' ] \
  || fail "dash: the prompt-line ghost text must read '↵ empty scratch · codex: prefix for a one-off' under a claude default (#536 ↵ hint; #554 one-off prefix) — got: $ghost"
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

# --- the shipped backlog bind must PARSE (filter mode validates --bind). The form
# below mirrors what the script builds after shell expansion (abs paths standin). --
BACKLOG_BIND="click-header:transform:case \"\$FZF_CLICK_HEADER_WORD\" in *＋*|*new*) printf 'new' > '/tmp/act'; echo abort ;; *✕*|*close*) echo abort ;; esac"
if command -v fzf >/dev/null 2>&1; then
  printf 'x\n' | fzf -f x --bind "$BACKLOG_BIND" >/dev/null 2>&1 \
    || fail 'fzf rejected the backlog ＋ new bind — the syntax is no longer valid'
  ok
else
  printf 'fzf-new-chip-selftest: fzf absent — skipped the live bind-parse check\n'
fi

printf 'selftest PASS: %d assertions (backlog [＋ new] chip wired + parses; dash has no hint line/chip/tap bind, ⌃n kept, ghost carries ↵)\n' "$pass"
exit 0
