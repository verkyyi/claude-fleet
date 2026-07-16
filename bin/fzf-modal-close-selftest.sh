#!/bin/bash
# fzf-modal-close-selftest.sh — asserts every fzf-based fleet modal carries the
# iPad/Termius tap-to-close affordance (issue #346): a `[✕ close]` button chip in
# its --header PLUS the click-header→abort bind that dismisses the modal when the
# ✕/close header word is tapped (fzf ≥0.71 exposes $FZF_CLICK_HEADER_WORD).
#
# Button-styled tokens (issue #381): the token is now a BRACKETED chip `[✕ close]`
# so it reads as a button, not plain hint text. A tap therefore lands on the word
# `[✕` OR `close]`, so the case globs *✕*|*close* (was the exact ✕|close) to fire
# on either half. We assert the shared close CASE as a substring — the backlog
# (tmux-issues.sh) prepends a *＋*|*new* case in its POPUP branch (the `[＋ new]`
# chip, covered by fzf-new-chip-selftest.sh), so the whole bind is no longer
# byte-identical across modals, but the close CASE still is.
#
# Why static: click-header needs a real mouse tap in an interactive UI, which is
# not reproducible headlessly — so this greps the shipped scripts (hermetic: no
# tmux, no fzf UI, no network) for the chip + the byte-identical close case. When
# fzf IS installed it ALSO proves the bind still parses (filter mode validates
# --bind and rejects a malformed one), so a future fzf that drops the syntax is
# caught.
#
# Read-only / confirm popups (the `prefix ?` keys cheatsheet, y/n dialogs) are NOT
# fzf and keep Escape — they are intentionally absent from the modal list below.
#
# Exit 0 = pass. Non-zero = fail (prints which assertion).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

pass=0
ok()   { pass=$((pass+1)); }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# The pieces that MUST appear, byte-for-byte, in every modal: the bind head, the
# close CASE (globbed, so the bracketed chip is tappable), and the button chip.
HEAD='click-header:transform:case "$FZF_CLICK_HEADER_WORD" in'
CLOSE_CASE='*✕*|*close*) echo abort ;; esac'
TOKEN='[✕ close]'

# The fzf modals that MUST carry the tap-to-close affordance (each already passes
# a --header). tmux-issues.sh shows the chip only in its POPUP branch (a windowed
# abort just reopens the pane), but the close CASE is present in both branches
# (inert windowed — no ✕/close word to tap) — so the same static assertions hold.
MODALS='tmux-issues.sh tmux-config.sh dash-issue-spawn.sh fleet-pick.sh usage-modal.sh'

for m in $MODALS; do
  f="$BIN/$m"
  [ -f "$f" ] || fail "$m not found at $f"
  ok
  # header carries the bracketed, tappable button chip
  grep -qF -- "$TOKEN" "$f" || fail "$m: --header missing the '[✕ close]' button chip"
  ok
  # the click-header→abort bind is present, using the globbed close case
  grep -qF -- "$HEAD" "$f"       || fail "$m: missing the click-header:transform bind head"
  grep -qF -- "$CLOSE_CASE" "$f" || fail "$m: missing the *✕*|*close*→abort case"
  ok
done

# usage-modal keeps its pinned table-title row (--header-lines=1): the chip lives
# in --header, NOT the pinned row, so both must coexist (issue #346 scope).
grep -qF -- '--header-lines=1' "$BIN/usage-modal.sh" \
  || fail 'usage-modal.sh: lost its --header-lines=1 column-title pin'
ok

# With fzf present, prove the bind actually PARSES — filter mode (-f) validates
# every --bind and exits non-zero on a malformed one, without opening a UI. Skip
# cleanly when fzf is absent (the runner treats a clean skip as a pass).
BIND="$HEAD $CLOSE_CASE"
if command -v fzf >/dev/null 2>&1; then
  printf 'x\n' | fzf -f x --bind "$BIND" >/dev/null 2>&1 \
    || fail 'fzf rejected the click-header bind — the syntax is no longer valid'
  ok
else
  printf 'fzf-modal-close-selftest: fzf absent — skipped the live bind-parse check\n'
fi

printf 'selftest PASS: %d assertions (5 modals × {file · [✕ close] chip · close case} + header-lines pin + bind parse)\n' "$pass"
exit 0
