#!/bin/bash
# dash-issue-priority-selftest.sh — hermetic tests for bin/dash-issue-priority.sh
# (issue #235). No network, no tmux server: gh + tmux + the sibling collector are
# faked; the real script + fleet-lib.sh are symlinked into a temp bin so BIN
# resolves the stubs.
#
#   A. CYCLE from none  → adds priority:p2 (none→p2→p1→p0→none).
#   B. CYCLE from p2    → removes p2, adds p1.
#   C. CYCLE from p0    → removes p0, adds nothing (wraps to none).
#   D. EXPLICIT no-op   → set p0 on a p0 issue makes NO gh edit call.
#   E. OPTIMISTIC CACHE → the issue's labels-cache row is rewritten in place
#                         (priority swapped, other labels kept) so the reload tags it.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured state).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/dash-issue-priority.sh"
LIB="$BIN/fleet-lib.sh"
[ -x "$SRC" ] || { printf 'selftest: %s missing\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prio-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- state ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fp" "$WORK/tmp/.claude-dash/fleets/fake-repo" "$WORK/tmp/.claude-dash/global"
ln -s "$SRC" "$WORK/bin/dash-issue-priority.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/tmux-dash-collect.sh"; chmod +x "$WORK/bin/tmux-dash-collect.sh"

FD="$WORK/tmp/.claude-dash/fleets/fake-repo"
LABELS="$FD/labels"
# The interactive path now cycles from the labels CACHE, so each case reseeds it —
# the fake gh view (below) is kept in agreement so the authoritative bg pass edits
# to the same target the cache-based cycle chose.
seed_labels() { printf '101\tenhancement,priority:p2\n102\tpriority:p0\n103\t\n' > "$LABELS"; : > "$LABELS.ts"; }
printf 'fakesess\tfake-repo\tfake/repo\n' > "$WORK/tmp/.claude-dash/global/sessmap"

GHLOG="$WORK/ghedit"; RSLOG="$WORK/rslog"
# fake gh: `issue view --json labels` → canned per-issue labels; `issue edit` → logged.
cat > "$WORK/fp/gh" <<GHFAKE
#!/bin/bash
case "\${1:-} \${2:-}" in
  "issue view")
    case "\$3" in
      101) printf 'enhancement\npriority:p2\n' ;;
      102) printf 'priority:p0\n' ;;
      103) : ;;
    esac ;;
  "issue edit") printf '%s\n' "\$*" >> "$GHLOG" ;;
esac
exit 0
GHFAKE
# fake tmux: answer session_name; LOG + EXECUTE run-shell (so the backgrounded
# `--commit` pass runs and its gh edit is observable); swallow display-message.
cat > "$WORK/fp/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  run-shell)
    shift; [ "\${1:-}" = "-b" ] && shift
    printf '%s\n' "\$1" >> "$RSLOG"          # prove the dispatch happened
    sh -c "\$1" ;;                            # mirror real run-shell: actually run it
  display-message) case "\$*" in *session_name*) echo fakesess ;; *) : ;; esac ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fp/gh" "$WORK/fp/tmux"

runp() { : > "$GHLOG"; : > "$RSLOG"; seed_labels; PATH="$WORK/fp:$PATH" TMPDIR="$WORK/tmp" \
  bash "$WORK/bin/dash-issue-priority.sh" "$@" >/dev/null 2>&1; }

# ============================ A: cycle from none =============================
runp 103 cycle
grep -q -- '--add-label priority:p2' "$GHLOG" || fail "A none→cycle should add priority:p2" "$(cat "$GHLOG")"
grep -q -- '--remove-label' "$GHLOG" && fail "A none→cycle should remove nothing" "$(cat "$GHLOG")"
ok "A cycle from none adds priority:p2"

# ============================ B: cycle from p2 ==============================
runp 101 cycle
grep -q -- '--remove-label priority:p2' "$GHLOG" || fail "B p2→cycle should remove p2" "$(cat "$GHLOG")"
grep -q -- '--add-label priority:p1'    "$GHLOG" || fail "B p2→cycle should add p1" "$(cat "$GHLOG")"
# The gh work must be BACKGROUNDED (issue #304): dispatched via run-shell -b as a
# `--commit` re-exec, never inline — so ⌃y returns instantly.
grep -q -- '--commit' "$RSLOG" || fail "B gh view+edit must be dispatched via run-shell -b (--commit)" "$(cat "$RSLOG")"
ok "B cycle from p2 → p1 (swap), backgrounded via run-shell -b"

# ============================ C: cycle from p0 (wrap) ========================
runp 102 cycle
grep -q -- '--remove-label priority:p0' "$GHLOG" || fail "C p0→cycle should remove p0" "$(cat "$GHLOG")"
grep -q -- '--add-label' "$GHLOG" && fail "C p0→cycle wraps to none — must add nothing" "$(cat "$GHLOG")"
ok "C cycle from p0 wraps to none (removes p0, adds nothing)"

# ============================ D: explicit no-op =============================
runp 102 p0
[ -s "$GHLOG" ] && fail "D set p0 on a p0 issue must make NO edit call" "$(cat "$GHLOG")"
ok "D explicit set to the current tier is a no-op"

# ============================ E: optimistic cache ==========================
# cycle #101 (p2→p1): its row must become enhancement,priority:p1 SYNCHRONOUSLY
# (the repaint can't wait on the backgrounded gh pass). runp reseeds first.
runp 101 cycle
row=$(grep '^101' "$LABELS")
[ "$row" = "$(printf '101\tenhancement,priority:p1')" ] \
  || fail "E labels cache row not optimistically rewritten (p2→p1, keep enhancement)" "$row"
grep -q '^102	priority:p0' "$LABELS" || fail "E unrelated rows must be untouched" "$(cat "$LABELS")"
ok "E optimistic cache rewrite swaps only the target row's priority"

printf '\nselftest OK: %s assertions passed (dash-issue-priority cycle + cache)\n' "$pass"
exit 0
