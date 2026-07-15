#!/bin/bash
# fzf-modal-close-selftest.sh — asserts every fzf-based fleet modal carries the
# iPad/Termius tap-to-close affordance (issue #346): a "✕ close" token in its
# --header PLUS the click-header→abort bind that dismisses the modal when the
# ✕/close header word is tapped (fzf ≥0.71 exposes $FZF_CLICK_HEADER_WORD).
#
# Why static: click-header needs a real mouse tap in an interactive UI, which is
# not reproducible headlessly — so this greps the shipped scripts (hermetic: no
# tmux, no fzf UI, no network) for the token + the byte-identical bind. When fzf
# IS installed it ALSO proves the bind still parses (filter mode validates --bind
# and rejects a malformed one), so a future fzf that drops the syntax is caught.
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

# The canonical bind — byte-for-byte identical in every modal. Grepping each file
# for this exact string is the drift guard: a copy that diverges fails here.
BIND='click-header:transform:case "$FZF_CLICK_HEADER_WORD" in ✕|close) echo abort ;; esac'

# The fzf modals that MUST carry the tap-to-close affordance (each already passes
# a --header). tmux-issues.sh shows the ✕ only in its POPUP branch (a windowed
# abort just reopens the pane), but the bind is inert there — no ✕/close word to
# tap — so the same static assertions hold for the file.
MODALS='tmux-issues.sh tmux-config.sh dash-issue-spawn.sh fleet-pick.sh usage-modal.sh'

for m in $MODALS; do
  f="$BIN/$m"
  [ -f "$f" ] || fail "$m not found at $f"
  ok
  # header carries a tappable "✕ close" token
  grep -qF -- '✕ close' "$f" || fail "$m: --header missing the '✕ close' token"
  ok
  # the click-header→abort bind is present, byte-identical across modals
  grep -qF -- "$BIND" "$f" || fail "$m: missing the click-header→abort bind"
  ok
done

# usage-modal keeps its pinned table-title row (--header-lines=1): the ✕ token
# lives in --header, NOT the pinned row, so both must coexist (issue #346 scope).
grep -qF -- '--header-lines=1' "$BIN/usage-modal.sh" \
  || fail 'usage-modal.sh: lost its --header-lines=1 column-title pin'
ok

# With fzf present, prove the bind actually PARSES — filter mode (-f) validates
# every --bind and exits non-zero on a malformed one, without opening a UI. Skip
# cleanly when fzf is absent (the runner treats a clean skip as a pass).
if command -v fzf >/dev/null 2>&1; then
  printf 'x\n' | fzf -f x --bind "$BIND" >/dev/null 2>&1 \
    || fail 'fzf rejected the click-header bind — the syntax is no longer valid'
  ok
else
  printf 'fzf-modal-close-selftest: fzf absent — skipped the live bind-parse check\n'
fi

printf 'selftest PASS: %d assertions (5 modals × {file · ✕ token · bind} + header-lines pin + bind parse)\n' "$pass"
exit 0
