#!/bin/bash
# dash-issue-new-fzf-input-selftest.sh — the "⌃n popup input is fzf, not a hand-rolled
# read loop" rail (issue #429; supersedes the old utf8-backspace/read_title selftest).
#
# dash-issue-new.sh used to read the title char-by-char with a hand-rolled `read -rsn1`
# loop (read_title/read_paste + utf8_len/bytelen). That loop fought three structural bugs
# it could not fully fix in place:
#   • CJK/IME DOUBLE-ECHO — the manual `printf '%s'` echo fought the terminal's own IME
#     rendering, so an IME-committed glyph was drawn twice (issues #422, #429).
#   • Esc NOT INSTANT — bash 3.2 has no sub-second `read -t`, so a lone Esc waited ~1s,
#     and a non-'[' byte after Esc was silently ignored instead of cancelling (#419, #429).
#   • fragile bracketed-paste bookkeeping to fold a multi-line paste to one line (#419).
#
# The fix (issue #429) replaces the whole loop with `fzf --print-query`: fzf owns its own
# UTF-8/IME/paste-aware echo (no double-echo), cancels on Esc/Ctrl-C INSTANTLY (exit 130),
# and folds a paste into its single-line query. Interactive fzf can't be unit-driven in CI
# (it reads keys from /dev/tty), so this is a STRUCTURE selftest: it greps the SHIPPED
# script and asserts the new shape is present and the old hand-rolled loop is gone. The
# behavioural exit-code handling (130 = cancel, query accepted) is driven hermetically —
# with a STUB fzf — in dash-issue-new-spawn-selftest.sh.
#
# Asserts, against bin/dash-issue-new.sh:
#   • FZF-INPUT     the interactive read is `fzf --print-query` (the one input widget).
#   • ESC-CANCEL    exit code 130 (Esc/Ctrl-C) is treated as cancel.
#   • EMPTY-CANCEL  an empty query still cancels (unchanged ⌃n contract).
#   • NO-READLOOP   the hand-rolled per-byte `read -rsn1` input loop and its helpers
#                   (read_title/read_paste/utf8_len/bytelen) are GONE — a refactor that
#                   reintroduces a manual echo loop (the double-echo habitat) trips this.
#   • NO-BRACKET    the DEC-2004 bracketed-paste enable/disable is gone (fzf folds paste).
#   • FZF-GUARD     a `command -v fzf` guard toasts + exits if fzf is absent (now required).
#   • LOCALE        the forced UTF-8 locale export is kept (non-interactive create/naming).
#   • SHELLCHECK    the shipped script is shellcheck-clean (skipped if shellcheck absent).
#
# No network, no tmux server, no real repo. Exit 0 = pass; non-zero = fail (prints the
# failing assertion).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
NEW="$BIN/dash-issue-new.sh"
[ -f "$NEW" ] || { printf 'selftest: %s missing\n' "$NEW" >&2; exit 2; }

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# ============================ FZF-INPUT: fzf is the widget ===================
# The interactive title read must be `fzf --print-query` — fzf owns the echo (UTF-8/IME/
# paste-aware), so the CJK double-echo can't recur (issue #429).
grep -Eq 'fzf .*--print-query' "$NEW" \
  || fail "interactive read is no longer 'fzf --print-query' — issue #429 input regressed"
ok "FZF-INPUT the interactive title read is 'fzf --print-query'"

# ============================ ESC-CANCEL: exit 130 → cancel ==================
# fzf exits 130 on Esc/Ctrl-C; the script must treat that as an instant cancel (the whole
# point of the switch — no 1-second Esc wait, no swallowed cancel). Pin the specific check.
grep -Eq -- '-eq 130|130[[:space:]]*\][[:space:]]*&&|"130"' "$NEW" \
  || fail "fzf exit 130 (Esc/Ctrl-C) is no longer treated as cancel — issue #429 Esc-instant regressed" "$(grep -n 130 "$NEW" || true)"
ok "ESC-CANCEL fzf exit 130 (Esc/Ctrl-C) cancels the create instantly"

# ============================ EMPTY-CANCEL: empty query cancels ==============
# An empty title (bare Enter, or an fzf error → empty output) still cancels — the ⌃n
# one-line-filer contract (issue #297) is unchanged by the input swap.
# shellcheck disable=SC2016  # the $-token is a literal grep pattern, not a shell expansion
grep -Eq '\[ -z "\$title" \][[:space:]]*&&[[:space:]]*exit' "$NEW" \
  || fail "an empty title no longer cancels the create — ⌃n contract regressed" "$(grep -n 'title' "$NEW" || true)"
ok "EMPTY-CANCEL an empty title still cancels (⌃n one-line-filer contract intact)"

# ============================ NO-READLOOP: the hand-rolled loop is gone ======
# The old per-byte input loop is exactly what produced the double-echo / 1s-Esc / paste
# fragility. It must be DELETED, not merely bypassed — assert its function defs and the
# tell-tale `read -rsn1` per-char read are gone from the shipped script. Grep CODE only
# (full-line comments stripped): the shipped header comment legitimately DESCRIBES the old
# hand-rolled approach, so we assert on executable lines, not the prose that names it.
code=$(grep -vE '^[[:space:]]*#' "$NEW")
for fn in 'read_title()' 'read_paste()' 'utf8_len()' 'bytelen()'; do
  printf '%s\n' "$code" | grep -qF "$fn" && fail "hand-rolled input helper '$fn' still present — should be deleted (issue #429)" "$(grep -n "$fn" "$NEW")"
done
printf '%s\n' "$code" | grep -qE 'read -[a-z]*n1' && fail "a per-char 'read -rsn1' input loop is still present — the double-echo habitat is back (issue #429)" "$(grep -nE 'read -[a-z]*n1' "$NEW")"
ok "NO-READLOOP read_title/read_paste/utf8_len/bytelen + the per-byte 'read -rsn1' loop are all gone"

# ============================ NO-BRACKET: DEC-2004 paste bookkeeping gone ====
# fzf folds a paste into its single-line query, so the terminal bracketed-paste
# enable/disable (ESC[?2004h / ?2004l) and the ESC[200~/201~ marker handling are no longer
# needed. Their presence would mean a stale hybrid — assert they're removed (code only).
printf '%s\n' "$code" | grep -qF '2004h' && fail "DEC-2004 bracketed-paste ENABLE (\\033[?2004h) still present — fzf owns paste now (issue #429)" "$(grep -n '2004' "$NEW")"
printf '%s\n' "$code" | grep -qF '200~'  && fail "ESC[200~ paste-start handling still present — fzf owns paste now (issue #429)" "$(grep -n '200~' "$NEW")"
ok "NO-BRACKET the DEC-2004 bracketed-paste enable + ESC[200~/201~ handling are gone (fzf folds paste)"

# ============================ FZF-GUARD: fzf now required ====================
# fzf is required by this path now, so a `command -v fzf` guard must toast + exit if it's
# absent — mirroring the sibling `gh` guard so the popup fails cleanly, not opaquely.
grep -Eq 'command -v fzf[^|]*\|\|' "$NEW" \
  || fail "no 'command -v fzf' guard — an absent fzf would break the popup opaquely (issue #429)" "$(grep -n 'fzf' "$NEW" || true)"
ok "FZF-GUARD a 'command -v fzf' guard toasts + exits when fzf is absent (mirrors the gh guard)"

# ============================ LOCALE: forced UTF-8 export kept ===============
# fzf owns the interactive editing, but the forced UTF-8 locale still matters for the
# non-interactive paths (create channel, window/branch naming, optimistic cache row) — so
# it must stay (issue #408).
grep -Eq '^export LANG=.*LC_ALL=' "$NEW" \
  || fail "the forced UTF-8 locale export was dropped — the non-interactive create/naming paths need it (issue #408)"
ok "LOCALE the forced UTF-8 locale export is retained for the non-interactive paths"

# ============================ SHELLCHECK: shipped script is clean ============
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$NEW" >/dev/null 2>&1 || fail "shellcheck is not clean on $NEW" "$(shellcheck -x "$NEW" 2>&1 || true)"
  ok "SHELLCHECK the shipped script is shellcheck-clean"
else
  printf 'SKIP SHELLCHECK (shellcheck not installed)\n'
fi

printf '\nselftest OK: %s assertions passed (⌃n popup input is fzf --print-query — no hand-rolled read loop, Esc instant via exit 130, no CJK double-echo)\n' "$pass"
exit 0
