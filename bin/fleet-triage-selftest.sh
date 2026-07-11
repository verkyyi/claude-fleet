#!/bin/bash
# fleet-triage-selftest.sh — hermetic tests for bin/fleet-triage.sh (issue #235).
#
# The auto-triage helper's whole value is the VALIDATION rail: whatever the model
# returns, only real milestones/labels leave the script, control labels never do,
# and priority comes from the PRIORITY field (not a stray label). We prove that
# without a network or a real model by injecting the valid sets (TRIAGE_MILESTONES
# / TRIAGE_LABELS) and putting a canned `claude` on PATH.
#
#   A. HAPPY PATH — refined title kept; a real milestone canonicalised; a valid
#      type label kept; a bogus label dropped; a priority label the model wrongly
#      put in LABELS dropped; the PRIORITY field's tier added; body elaborated
#      (internal paragraph break preserved).
#   B. INVALID MILESTONE — a milestone not in the set is dropped (empty), not invented.
#   C. NO MODEL OUTPUT — an empty model reply exits 3 so the caller falls back to
#      a raw create.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-triage.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/triage-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fp"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

MS=$'Dashboard & modals\nDaemons & automation\nReliability & state'
LB=$'bug\nenhancement\ndocumentation\ncleanup\npriority:p0\npriority:p1\npriority:p2\nsteward-control\nblocked\nscout'

# canned `claude` — prints whatever CLAUDE_OUT holds (its stdin, the prompt, is ignored)
cat > "$WORK/fp/claude" <<'FAKE'
#!/bin/bash
cat >/dev/null            # drain the prompt on stdin
printf '%s\n' "$CLAUDE_OUT"
FAKE
chmod +x "$WORK/fp/claude"

run() { # $1 = canned model output → runs triage, captures stdout
  CLAUDE_OUT="$1" PATH="$WORK/fp:$PATH" \
  TRIAGE_MILESTONES="$MS" TRIAGE_LABELS="$LB" \
    bash "$SRC" --repo fake/repo --line "add a keybind to jump to newest worker"
}
field() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{sub($1"\t","");print;exit}'; }
body_of() { printf '%s\n' "$1" | sed -n '/^@@FLEET_TRIAGE_BODY@@$/,$p' | sed '1d'; }

# ============================ A: happy path ==================================
OUT_A=$(run "$(cat <<'MODEL'
TITLE: Add a keybind to jump to the newest worker window
MILESTONE: dashboard & modals
LABELS: enhancement, totally-bogus, priority:p0
PRIORITY: p1
BODY:
Jumping to the freshest worker should take one keystroke.

It saves hunting the window list when a new session spawns.
MODEL
)") || fail "A triage exited non-zero" "$OUT_A"

[ "$(field "$OUT_A" TITLE)" = "Add a keybind to jump to the newest worker window" ] \
  || fail "A refined TITLE not passed through" "$OUT_A"
[ "$(field "$OUT_A" MILESTONE)" = "Dashboard & modals" ] \
  || fail "A milestone should canonicalise to the repo's spelling" "$OUT_A"
LBLS_A=$(field "$OUT_A" LABELS)
case ",$LBLS_A," in *,enhancement,*) : ;; *) fail "A valid type label 'enhancement' dropped" "$OUT_A" ;; esac
case ",$LBLS_A," in *,priority:p1,*) : ;; *) fail "A PRIORITY field p1 not applied" "$OUT_A" ;; esac
case ",$LBLS_A," in *totally-bogus*) fail "A bogus label must be dropped" "$OUT_A" ;; esac
case ",$LBLS_A," in *priority:p0*) fail "A stray priority:p0 in LABELS must be dropped (PRIORITY field wins)" "$OUT_A" ;; esac
BODY_A=$(body_of "$OUT_A")
printf '%s' "$BODY_A" | grep -q 'one keystroke' || fail "A elaborated body missing" "$OUT_A"
printf '%s' "$BODY_A" | grep -q 'hunting the window list' || fail "A body 2nd paragraph missing (internal break lost?)" "$OUT_A"
ok "A happy path: title/milestone/label/priority validated, body elaborated"

# ============================ B: invalid milestone ===========================
OUT_B=$(run "$(cat <<'MODEL'
TITLE: Something
MILESTONE: Nonexistent Area
LABELS: none
PRIORITY: none
BODY:
A body.
MODEL
)") || fail "B triage exited non-zero" "$OUT_B"
[ -z "$(field "$OUT_B" MILESTONE)" ] || fail "B an unknown milestone must be dropped (empty), not invented" "$OUT_B"
[ -z "$(field "$OUT_B" LABELS)" ]    || fail "B LABELS should be empty ('none' + no priority)" "$OUT_B"
ok "B invalid milestone dropped; no labels invented"

# ============================ C: empty model output ==========================
rc=0
OUT_C=$(run "") || rc=$?
[ "$rc" = 3 ] || fail "C empty model output should exit 3 (caller falls back), got $rc" "$OUT_C"
ok "C empty model output → exit 3 (raw-create fallback)"

printf '\nselftest OK: %s assertions passed (fleet-triage validation rail)\n' "$pass"
exit 0
