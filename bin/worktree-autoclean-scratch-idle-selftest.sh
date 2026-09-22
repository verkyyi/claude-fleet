#!/bin/bash
# worktree-autoclean-scratch-idle-selftest.sh — hermetic tests for the janitor's
# scratch IDLE age gate (issue #884, FLEET_SCRATCH_MAX_IDLE). With the knob ON:
#   * clean ancestor + human session, idle past the age     → PRUNE into .fleet-trash
#     (+ `autoclean: scratch idle <Nd> → trash <path>` log line, history row kept)
#   * same, but the session spoke recently                  → KEEP + surface (#290)
#   * idle, but a live pane sits in it                      → KEEP (attached)
#   * idle, but an account-rotation lease is held           → KEEP (#550)
#   * clean, tip == base, idle                              → PRUNE (no work at all)
#   * dirty, idle                                           → KEEP + ONE daily digest
#     (every idle kept scratch in one message; a second sweep within 24h is quiet)
#   * unmerged commits, idle                                → KEEP + the same digest
# With the knob at its DEFAULT (unset / 0) the decisions are the #290 ones exactly:
# no age read, no digest, no idle tag — and the dry-run output is byte-identical.
#
# No network / no tmux server / no real GitHub: the real script + fleet-lib.sh are
# symlinked into a temp bin, a per-fleet conf drives fleet_sockets, and fake
# `tmux`/`gh` stand in. A REAL local git repo provides the worktrees; ageing is a
# plain `touch -t` on the worktree dir and its transcript.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/worktree-autoclean.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SRC" "$LIB"; do [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }; done
command -v git >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wac-idle.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/logs"
ln -s "$SRC" "$WORK/bin/worktree-autoclean.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
ln -s "$BIN/fleet-reap-live.py" "$WORK/bin/fleet-reap-live.py"
NOTIFY_LOG="$WORK/notify"; LIVE_FILE="$WORK/live"; : > "$NOTIFY_LOG"; : > "$LIVE_FILE"

BASE="$WORK/base"
git init -q "$BASE"
git -C "$BASE" config user.email t@t; git -C "$BASE" config user.name t
printf 'seed\n' > "$BASE/f"; git -C "$BASE" add f; git -C "$BASE" commit -qm seed
BASE_BR="$(git -C "$BASE" branch --show-current)"

PROJ="$WORK/projects"
enc() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'; }
OLD=202601010000   # far past any sane FLEET_SCRATCH_MAX_IDLE
human() {   # $1=worktree  $2=touch stamp (empty = now) — a real conversation's transcript
  local d; d="$PROJ/$(enc "$1")"; mkdir -p "$d"
  printf '{"type":"user","message":{"content":"a real conversation happened here"}}\n' > "$d/sess.jsonl"
  [ -n "${2:-}" ] && touch -t "$2" "$d/sess.jsonl"
  return 0
}
wt() { git -C "$BASE" worktree add -q -b "$1" "$WORK/base-$1" >/dev/null 2>&1; }

# scratch-1: clean strict ancestor, human session, OLD            → PRUNE (idle)
# scratch-2: clean strict ancestor, human session, RECENT         → KEEP + surface
# scratch-3: clean strict ancestor, human session, OLD, live pane → KEEP
# scratch-4: clean strict ancestor, human session, OLD, leased    → KEEP
# scratch-5: dirty, OLD                                           → KEEP + digest
# scratch-6: unmerged commit, OLD                                 → KEEP + digest
for n in 1 2 3 4 5 6; do wt "scratch-$n"; done
printf 'exp\n' > "$WORK/base-scratch-5/untracked"
printf 'x\n' > "$WORK/base-scratch-6/g"; git -C "$WORK/base-scratch-6" add g; git -C "$WORK/base-scratch-6" commit -qm work
git -C "$BASE" commit --allow-empty -qm base-advance   # 1–5 are now strict ancestors
# scratch-7: tip == base (created AFTER the advance), OLD, no transcript → PRUNE (idle)
wt scratch-7
human "$WORK/base-scratch-1" "$OLD"; human "$WORK/base-scratch-2" ""
human "$WORK/base-scratch-3" "$OLD"; human "$WORK/base-scratch-4" "$OLD"
for n in 1 3 4 5 6 7; do touch -t "$OLD" "$WORK/base-scratch-$n"; done
printf '%s\n' "$WORK/base-scratch-3" > "$LIVE_FILE"

cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
[ "\$1" = -L ] && shift 2
case "\$1" in
  has-session)     exit 0 ;;
  list-panes)      cat "$LIVE_FILE" 2>/dev/null ;;
  display-message) shift; printf 'NOTIFY %s\n' "\$*" >> "$NOTIFY_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"
printf '#!/bin/bash\nexit 0\n' > "$WORK/fakebin/gh"; chmod +x "$WORK/fakebin/gh"

write_conf() {   # $1 = FLEET_SCRATCH_MAX_IDLE line (empty = key absent)
  cat > "$WORK/conf/sess1.conf" <<EOF
FLEET_MAIN="$BASE"
FLEET_REPO="fake/repo"
FLEET_BASE_BRANCH="$BASE_BR"
$1
EOF
}
run_wac() {
  PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" CLAUDE_PROJECTS_DIR="$PROJ" \
    bash "$WORK/bin/worktree-autoclean.sh" "$@" 2>"$WORK/err"
}
norm() { sed -E 's/lease [0-9]+s/lease Ns/'; }   # the lease age ticks between runs
( export FLEET_CONF_DIR="$WORK/conf"; . "$LIB"; fleet_rotate_lease_take "$WORK/base-scratch-4" "selftest" ) \
  || fail "could not take a rotation lease on scratch-4"

# ======================= DEFAULT (key absent / 0): #290 exactly ==============
write_conf ""
out_absent="$(run_wac --dry-run | norm)"
write_conf "FLEET_SCRATCH_MAX_IDLE=0"
out_zero="$(run_wac --dry-run | norm)"
[ "$out_absent" = "$out_zero" ] || fail "FLEET_SCRATCH_MAX_IDLE=0 must equal the key being absent" "$out_absent
=== vs ===
$out_zero"
printf '%s\n' "$out_absent" | grep -Eq 'KEEP +scratch-1 .*session ran here — scratch experiment' \
  || fail "default: an old conversation scratch must stay KEEP+surface (#290)" "$out_absent"
printf '%s\n' "$out_absent" | grep -Eq 'KEEP +scratch-7 .*unmerged work — scratch experiment' \
  || fail "default: tip == base scratch must stay 'unmerged work' (#565)" "$out_absent"
printf '%s\n' "$out_absent" | grep -Eq 'KEEP +scratch-5 .*dirty — scratch experiment' \
  || fail "default: dirty scratch keeps the surface-once wording" "$out_absent"
printf '%s\n' "$out_absent" | grep -Eq 'scratch idle|^DIGEST|^PRUNE' \
  && fail "default: no idle tag, no digest, no prune on this fixture" "$out_absent"
ok "DEFAULT: key absent ≡ 0 ≡ the #290 decisions (no age gate, no digest)"

# ======================= ON: dry-run decisions ==============================
write_conf "FLEET_SCRATCH_MAX_IDLE=259200"
out="$(run_wac --dry-run)"
printf '%s\n' "$out" | grep -Eq 'PRUNE +scratch-1 .*scratch idle [0-9]+d' || fail "idle conversation scratch-1 should PRUNE" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-2 .*session ran here — scratch experiment' || fail "recent scratch-2 must stay KEEP+surface" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-3 .*live tmux session' || fail "live scratch-3 must KEEP" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-4 .*account rotation in flight' || fail "leased scratch-4 must KEEP" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-5 .*dirty — scratch idle [0-9]+d, in the daily digest' || fail "idle dirty scratch-5 → digest" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +scratch-6 .*unmerged work — scratch idle [0-9]+d, in the daily digest' || fail "idle unmerged scratch-6 → digest" "$out"
printf '%s\n' "$out" | grep -Eq 'PRUNE +scratch-7 .*scratch idle [0-9]+d' || fail "idle tip==base scratch-7 should PRUNE" "$out"
[ "$(printf '%s\n' "$out" | grep -c '^DIGEST')" = 1 ] || fail "exactly ONE digest line expected" "$out"
printf '%s\n' "$out" | grep -E '^DIGEST' | grep -q 'scratch-5.*scratch-6' || fail "the digest lists every idle kept scratch" "$out"
[ -d "$WORK/base-scratch-1" ] || fail "dry run must not remove anything"
[ -s "$NOTIFY_LOG" ] && fail "dry run must not notify" "$(cat "$NOTIFY_LOG")"
ok "DRY: idle clean → PRUNE; recent/live/leased → KEEP; idle dirty/unmerged → one digest"

# ======================= ON: real run =======================================
run_wac >/dev/null
[ -d "$WORK/base-scratch-1" ] && fail "idle scratch-1 should be gone"
[ -d "$WORK/base-scratch-7" ] && fail "idle scratch-7 should be gone"
for n in 2 3 4 5 6; do [ -d "$WORK/base-scratch-$n" ] || fail "scratch-$n must be KEPT"; done
# Recoverable = DROPPED into .fleet-trash (the run's own budgeted trash sweep may
# already have paid for the bytes by the time we look, so read the logged target).
LOG="$WORK/logs/worktree-autoclean.log"
grep -Eq 'autoclean: scratch idle [0-9]+d → trash .*/\.fleet-trash/base-scratch-1\.' "$LOG" \
  || fail "missing the 'autoclean: scratch idle <Nd> → trash <path>' line for scratch-1" "$(cat "$LOG")"
[ "$(grep -c 'autoclean: scratch idle' "$LOG")" = 2 ] || fail "exactly two idle-reclaim log lines expected" "$(cat "$LOG")"
[ "$(grep -c 'idle scratch worktree' "$NOTIFY_LOG")" = 1 ] || fail "ONE digest notify expected" "$(cat "$NOTIFY_LOG")"
grep -q 'scratch-2 kept (clean, but a session ran here)' "$NOTIFY_LOG" || fail "recent scratch-2 still surfaces once" "$(cat "$NOTIFY_LOG")"
grep -Eq 'scratch-(5|6) kept' "$NOTIFY_LOG" && fail "idle kept scratches go to the digest, not one notify each" "$(cat "$NOTIFY_LOG")"
ok "REAL: idle clean scratches trashed + logged; kept work announced in one digest"

# ======================= digest cadence: once per 24h ======================
n1="$(grep -c 'idle scratch worktree' "$NOTIFY_LOG")"
run_wac >/dev/null
[ "$(grep -c 'idle scratch worktree' "$NOTIFY_LOG")" = "$n1" ] || fail "a second sweep within 24h must not re-send the digest" "$(cat "$NOTIFY_LOG")"
touch -t "$OLD" "$WORK/logs/.scratch-idle-digest"   # the last digest is now > 24h old
run_wac >/dev/null
[ "$(grep -c 'idle scratch worktree' "$NOTIFY_LOG")" = $((n1 + 1)) ] || fail "after 24h the digest must repeat" "$(cat "$NOTIFY_LOG")"
ok "DIGEST: at most once per 24h, and it repeats while the work is still there"

printf '\nselftest OK: %s assertions passed (scratch idle age gate, #884)\n' "$pass"
exit 0
