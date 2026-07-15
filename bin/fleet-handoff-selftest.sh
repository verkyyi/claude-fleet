#!/bin/bash
# fleet-handoff-selftest.sh — hermetic smoke test for bin/fleet-handoff-cycle.sh.
#
# Asserts the detached cycle's contract (issue #273) against a FAKE tmux (no tmux
# server, no real pane, no live Claude) — the same mock-tmux shape the issue-bridge
# selftest uses (bin/fleet-issue-bridge-selftest.sh):
#   • REFUSE-NO-STORE   armed without --doc AND without --issue → refuses, no clear.
#   • REFUSE-EMPTY-DOC  --doc points at an empty file → refuses, never clears.
#   • REFUSE-OUTSIDE    no $TMUX and no --socket → refuses (nothing to drive).
#   • REFUSE-GONE-PANE  the target pane is dead → refuses, never clears.
#   • REFUSE-DOUBLE-ARM a live per-pane lock is present → refuses (no second clear).
#   • REFUSE-COMMENT-NOT-STORED  --issue but no `<!-- fleet:handoff -->` comment on
#                       the issue → refuses, never clears (issue #275 storage gate).
#   • ABORT-NEVER-IDLE  @claude_state stuck `working` past the idle timeout → exits
#                       0 (fail-safe) and NEVER sends the destructive /clear.
#   • KEY-SEQUENCE      (--doc, FILE storage) IDLE pane + fresh capture → the EXACT
#                       ordered key sequence: Escape · "/clear" · Enter ·
#                       "<pickup> <doc>" · Enter, each a SEPARATE send-keys (the
#                       bracketed-paste discipline), text and Enter never combined.
#   • KEY-SEQUENCE-COMMENT  (--issue, COMMENT storage) a marked comment round-trips →
#                       clears and injects an ARGUMENT-FREE pickup (no doc/issue arg;
#                       the cleared pane's @issue self-resolves it, issue #275).
#   • VERIFY-GATE       an IDLE pane with NO fresh marker AND a post-clear capture
#                       that never looks fresh → clears but WITHHOLDS pickup
#                       (fail-safe: manual pickup remains).
#   • VERIFY-DETERMINISTIC  the SessionStart(source=clear) marker @handoff_cleared_at
#                       is stamped >= the cycle's clear_t0 while the capture is NOT
#                       fresh → the cycle confirms via the marker and sends pickup,
#                       proving the deterministic verify replaces the scrape (#345).
#
# The fake tmux records every send-keys to an INJECT log and answers the helper's
# reads (pane-alive, @claude_state, @handoff_cleared_at, capture-pane) from FAKE_*
# env; a fake gh answers the comment-storage read from FAKE_COMMENTS. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-handoff-cycle.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fh-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/logs"
INJECT="$WORK/inject.log"; : > "$INJECT"
PANE='%7'

# --- fake tmux: records send-keys; answers display-message/capture-pane from env.
# Strips a leading global -L/-S <socket> (real tmux accepts it; the helper adds one
# only under --socket) so the verb still lands in $1 — mirrors the bridge fake.
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
verb="\${1:-}"; args="\$*"
case "\$verb" in
  send-keys)
    # record everything after the "-t <pane>" so order + literal payloads assert cleanly
    printf '%s\n' "\$args" >> "$INJECT" ;;
  display-message)
    case "\$args" in
      *pane_id*)             [ -n "\${FAKE_PANE_DEAD:-}" ] && exit 1; printf '%s\n' "$PANE" ;;
      *@claude_state*)       printf '%s\n' "\${FAKE_STATE:-done}" ;;
      *@handoff_cleared_at*) printf '%s\n' "\${FAKE_CLEARED_AT:-}" ;;
      *) : ;;   # a plain notify display-message (no -p) — no-op
    esac ;;
  capture-pane)
    printf '%b' "\${FAKE_CAP:-❯ \n  ? for shortcuts\n}" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- fake gh: the ONE read the helper makes in comment-storage mode —
# `gh issue view <N> --json comments -q '.comments[].body'`. Print FAKE_COMMENTS
# (the helper greps it for the `<!-- fleet:handoff -->` marker); empty = no comment.
cat > "$WORK/fakepath/gh" <<'FAKEGH'
#!/bin/bash
printf '%b' "${FAKE_COMMENTS:-}"
exit 0
FAKEGH
chmod +x "$WORK/fakepath/gh"

DOC="$WORK/handoff.md"; printf '# Handoff\n\n## NEXT ACTION\ndo the thing\n' > "$DOC"
EMPTY="$WORK/empty.md"; : > "$EMPTY"
MARKED='handoff body\n<!-- fleet:handoff -->\n'   # a comment body carrying the pickup marker

# run the cycle helper with the fake tmux on PATH and fast, deterministic tunables.
run() {  # usage: run [FAKE_STATE=..] [FAKE_CAP=..] -- <helper args...>
  : > "$INJECT"
  PATH="$WORK/fakepath:$PATH" \
  FLEET_HANDOFF_LOG_DIR="$WORK/logs" \
  FLEET_HANDOFF_IDLE_TIMEOUT="${IDLE:-2}" \
  FLEET_HANDOFF_VERIFY_TIMEOUT="${VF:-2}" \
  FLEET_HANDOFF_HARD_TIMEOUT="${HARD:-30}" \
  FLEET_HANDOFF_POLL="${POLL:-1}" \
  FAKE_STATE="${FAKE_STATE:-done}" \
  FAKE_CAP="${FAKE_CAP:-}" \
  FAKE_PANE_DEAD="${FAKE_PANE_DEAD:-}" \
  FAKE_COMMENTS="${FAKE_COMMENTS:-}" \
  FAKE_CLEARED_AT="${FAKE_CLEARED_AT:-}" \
  TMUX="${TMUX_OVERRIDE-fake,1,0}" \
    bash "$SRC" "$@"
}

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- inject ---\n' >&2; cat "$INJECT" >&2 2>/dev/null
         printf -- '--- log ---\n' >&2; cat "$WORK/logs/handoff-cycle.log" >&2 2>/dev/null; exit 1; }

cleared() { grep -q '/clear' "$INJECT" 2>/dev/null; }

# ---- REFUSE-NO-STORE (neither --doc nor --issue) ------------------------------
if run --pane "$PANE"; then fail "must refuse when armed with no --doc/--issue"; fi
cleared && fail "no-store refusal must not clear"

# ---- REFUSE-EMPTY-DOC ---------------------------------------------------------
if run --pane "$PANE" --doc "$EMPTY"; then fail "must refuse an empty handoff doc"; fi
cleared && fail "empty-doc refusal must not clear"

# ---- REFUSE-OUTSIDE (no $TMUX, no --socket) -----------------------------------
if TMUX_OVERRIDE='' run --pane "$PANE" --doc "$DOC"; then fail "must refuse outside tmux"; fi
cleared && fail "outside-tmux refusal must not clear"

# ---- REFUSE-GONE-PANE ---------------------------------------------------------
if FAKE_PANE_DEAD=1 run --pane "$PANE" --doc "$DOC"; then fail "must refuse a dead pane"; fi
cleared && fail "dead-pane refusal must not clear"

# ---- REFUSE-DOUBLE-ARM (a live lock is already held) --------------------------
pane_san="${PANE//[^A-Za-z0-9]/_}"
LOCK="$WORK/logs/handoff-cycle-${pane_san}.lock"
printf '%s\n' "$$" > "$LOCK"        # this test process is alive → kill -0 succeeds
if run --pane "$PANE" --doc "$DOC"; then fail "must refuse a double-arm (live lock)"; fi
cleared && fail "double-arm refusal must not clear"
[ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] || fail "double-arm refusal must not steal/rewrite the live lock"
rm -f "$LOCK"

# ---- REFUSE-COMMENT-NOT-STORED (--issue but no marked comment) ----------------
# Comment-storage gate (issue #275): the helper re-confirms a `<!-- fleet:handoff -->`
# comment is fetchable BEFORE clearing. No marker ⇒ refuse, never clear (the
# handoff is not durably stored — same fail-safe class as the empty-doc refusal).
if FAKE_COMMENTS='some unrelated comment\n' run --pane "$PANE" --issue 42 --repo o/r; then
  fail "must refuse --issue when no fleet:handoff comment is present"; fi
cleared && fail "comment-not-stored refusal must not clear"

printf 'selftest: refusal legs PASS (no-store / empty-doc / outside-tmux / gone-pane / double-arm / comment-not-stored)\n' >&2

# ---- ABORT-NEVER-IDLE (working forever) → exit 0, no clear --------------------
IDLE=1 POLL=1 FAKE_STATE=working run --pane "$PANE" --doc "$DOC" \
  || fail "never-idle must exit 0 (fail-safe), not error"
cleared && fail "never-idle must NOT clear (abort before the destructive /clear)"
grep -q 'Escape' "$INJECT" 2>/dev/null && fail "never-idle must send NO keys at all"

printf 'selftest: never-idle leg PASS (aborts without clearing)\n' >&2

# ---- KEY-SEQUENCE (idle + fresh capture) → exact ordered keys -----------------
FAKE_STATE='done' FAKE_CAP='❯ \n  ? for shortcuts\n' run --pane "$PANE" --doc "$DOC" \
  || fail "idle+fresh cycle must exit 0"
# The five ordered send-keys, in order, each on its own line:
#   1 Escape · 2 "-l -- /clear" · 3 Enter · 4 "-l -- <pickup> <doc>" · 5 Enter
KEYS=()
while IFS= read -r _ln; do KEYS+=("$_ln"); done < "$INJECT"
[ "${#KEYS[@]}" -eq 5 ] || fail "expected exactly 5 send-keys, got ${#KEYS[@]}: ${KEYS[*]}"
case "${KEYS[0]}" in *Escape*) : ;; *) fail "key1 must be Escape, got: ${KEYS[0]}";; esac
case "${KEYS[1]}" in *'-l'*'/clear'*) : ;; *) fail "key2 must type /clear literally, got: ${KEYS[1]}";; esac
case "${KEYS[2]}" in *Enter*) : ;; *) fail "key3 must be a SEPARATE Enter, got: ${KEYS[2]}";; esac
case "${KEYS[3]}" in *'-l'*'/fleet-handoff pickup'*"$DOC"*) : ;; *) fail "key4 must type the pickup cmd+doc, got: ${KEYS[3]}";; esac
case "${KEYS[4]}" in *Enter*) : ;; *) fail "key5 must be a SEPARATE Enter, got: ${KEYS[4]}";; esac
# text and Enter never combined
case "${KEYS[1]}" in *Enter*) fail "the /clear text must not carry an inline Enter";; esac
case "${KEYS[3]}" in *Enter*) fail "the pickup text must not carry an inline Enter";; esac

printf 'selftest: key-sequence leg PASS (Escape · /clear · Enter · pickup · Enter, all separate)\n' >&2

# ---- KEY-SEQUENCE-COMMENT (--issue + marker round-trip) → ARGUMENT-FREE pickup -
# Marker present (round-trip), idle, fresh capture → clears and injects a pickup
# with NO argument (the cleared pane's @issue self-resolves the comment, issue #275).
FAKE_STATE='done' FAKE_CAP='❯ \n  ? for shortcuts\n' FAKE_COMMENTS="$MARKED" \
  run --pane "$PANE" --issue 42 --repo o/r || fail "idle+marked comment cycle must exit 0"
KEYS=()
while IFS= read -r _ln; do KEYS+=("$_ln"); done < "$INJECT"
[ "${#KEYS[@]}" -eq 5 ] || fail "comment mode: expected exactly 5 send-keys, got ${#KEYS[@]}: ${KEYS[*]}"
case "${KEYS[0]}" in *Escape*) : ;; *) fail "comment key1 must be Escape, got: ${KEYS[0]}";; esac
case "${KEYS[1]}" in *'-l'*'/clear'*) : ;; *) fail "comment key2 must type /clear, got: ${KEYS[1]}";; esac
case "${KEYS[2]}" in *Enter*) : ;; *) fail "comment key3 must be a SEPARATE Enter, got: ${KEYS[2]}";; esac
# key4: the pickup must be ARGUMENT-FREE — the line ENDS at "pickup", no doc/issue.
case "${KEYS[3]}" in
  *'-l'*'/fleet-handoff pickup') : ;;
  *) fail "comment key4 must be an ARGUMENT-FREE pickup (no path/issue), got: ${KEYS[3]}";;
esac
case "${KEYS[4]}" in *Enter*) : ;; *) fail "comment key5 must be a SEPARATE Enter, got: ${KEYS[4]}";; esac

printf 'selftest: comment-mode leg PASS (marker round-trip → clears → argument-free pickup)\n' >&2

# ---- VERIFY-GATE (never-fresh capture, NO marker) → clears but WITHHOLDS pickup -
# No @handoff_cleared_at marker AND a never-fresh capture ⇒ neither signal fires ⇒
# the pickup is withheld (fail-safe). RETRY_AFTER defaults past this tiny VF window,
# so the /clear is sent exactly once.
VF=1 FAKE_STATE='done' FAKE_CAP='still churning...\n' run --pane "$PANE" --doc "$DOC" \
  || fail "verify-gate cycle must exit 0 (fail-safe)"
cleared || fail "verify-gate: the /clear must still have been sent (idle reached)"
grep -q '/fleet-handoff pickup' "$INJECT" 2>/dev/null \
  && fail "verify-gate: pickup must be WITHHELD when the fresh session can't be confirmed"

printf 'selftest: verify-gate leg PASS (clears, withholds pickup on unconfirmed fresh session)\n' >&2

# ---- VERIFY-DETERMINISTIC (marker path) → confirms via @handoff_cleared_at ------
# The fresh-session signal is now the SessionStart(source=clear) marker, not the
# capture-pane scrape (issue #345). With a NON-fresh capture but a marker stamped
# in the future (>= the cycle's clear_t0), the cycle must STILL confirm fresh and
# send pickup — proving the deterministic signal works independent of the scrape.
FAKE_STATE='done' FAKE_CAP='still churning...\n' FAKE_CLEARED_AT=9999999999 \
  run --pane "$PANE" --doc "$DOC" || fail "deterministic-verify cycle must exit 0"
cleared || fail "deterministic-verify: the /clear must have been sent"
grep -q '/fleet-handoff pickup' "$INJECT" 2>/dev/null \
  || fail "deterministic-verify: a marker >= clear_t0 must confirm fresh → pickup sent (not withheld)"

printf 'selftest: deterministic-verify leg PASS (@handoff_cleared_at marker confirms fresh → pickup)\n' >&2

printf 'selftest PASS: refusals + never-idle abort + exact key sequence + verify-gate + deterministic marker verified\n'
exit 0
