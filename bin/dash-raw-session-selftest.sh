#!/bin/bash
# dash-raw-session-selftest.sh — hermetic tests for the RAW (non-issue-bound)
# scratch session (issues #214, #290). Two surfaces:
#   1. bin/dash-raw-session.sh spawns a plain claude window — marked @raw=1, NO
#      @issue, carrying @worktree, named `scratch-N`/custom — in its OWN
#      `scratch-<N>` git worktree off the base branch (issue #290), and cap-checked.
#   2. bin/.fleet-restore-resolve.py DROPS @raw=1 rows (raw WINDOWS are ephemeral,
#      never snapshotted/restored) while keeping normal WIN rows + old maps.
#
# No network: a REAL local git repo stands in for $FLEET_MAIN (git worktree add
# runs for real, creating sibling `main-scratch-N` worktrees under the temp dir),
# `origin` is absent so the spawner falls back to the local base branch. A fake
# `tmux` logs new-window/set-window-option/display-message so we can assert what it
# spawns; fleet-claude.sh is never executed (new-window is faked).
#
#   A. happy spawn        → worktree scratch-1 off base; new-window(-n scratch-1,
#                           -c <worktree>, -d), @raw=1 + @worktree set, no @issue
#   B. cap refusal        → per-fleet cap reached → NO new-window, NO worktree
#   C. N allocation        → an existing scratch-1 branch → next worktree is scratch-2
#   D. restore excludes    → resolver drops a @raw=1 row, keeps a normal WIN row
#   E. old-map back-compat → a 6-field WIN row (pre-#214, no @raw) is still kept
#
# Optional --name at creation (issue #225) — the name is display-only; the @raw=1
# / no-@issue / @worktree invariants hold regardless:
#   F. --name foo          → window named `foo`, still @raw=1 + @worktree + no @issue
#   G. empty --name        → auto `scratch-N`
#   H. custom collision    → a live `foo` window → the next one is `foo-2`
#   I. reserved name       → --name plan/dash/backlog → fallback `scratch-N` + note
#   J. empties-after-sanitize → --name '###' → fallback `scratch-N` + note
#   K. sanitization        → control chars / `#` stripped, case/spacing kept, ≤24 chars
#   L. positional target   → --name foo <sess> still spawns `foo` into <sess>
#   M. dash ⌃s (--bg, #444) → spawns instantly with NO prompt: the slow half is
#                           dispatched via run-shell -b (SILENCED — stdout would
#                           become a view-mode overlay on the dash, #446) and still
#                           lands scratch-N (a --bg --name flows through --name-file)
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RAW="$BIN/dash-raw-session.sh"
LIB="$BIN/fleet-lib.sh"
RESOLVE="$BIN/.fleet-restore-resolve.py"
for f in "$RAW" "$LIB" "$RESOLVE"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/raw-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/tmp/.claude-dash"
NEWWIN_LOG="$WORK/newwin"; OPTS_LOG="$WORK/opts"; DISPLAY_LOG="$WORK/display"; SELECT_LOG="$WORK/select"; RS_LOG="$WORK/runshell"

ln -s "$RAW" "$WORK/bin/dash-raw-session.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"

# --- a real base checkout stands in for $FLEET_MAIN (issue #290) ---------------
MAIN="$WORK/main"
git init -q "$MAIN"
git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
printf 'seed\n' > "$MAIN/f"; git -C "$MAIN" add f; git -C "$MAIN" commit -qm seed
BASE_BR="$(git -C "$MAIN" branch --show-current)"

reset_scratch() {   # drop every scratch-* worktree + branch so N is predictable per case
  local d b
  for d in "$WORK"/main-scratch-*; do
    [ -e "$d" ] && git -C "$MAIN" worktree remove --force "$d" >/dev/null 2>&1
  done
  for b in $(git -C "$MAIN" for-each-ref --format='%(refname:short)' 'refs/heads/scratch-*' 2>/dev/null); do
    git -C "$MAIN" branch -D "$b" >/dev/null 2>&1
  done
  git -C "$MAIN" worktree prune >/dev/null 2>&1
}

# --- fake tmux: strip -L/-S <sock>; answer session_name; LOG + EXECUTE run-shell
# (so the backgrounded ⌃s spawn, issue #304, actually runs and its new-window/
# worktree are observable, mirroring real `run-shell -b`); log the mutations. ----
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  run-shell)
    [ "${1:-}" = "-b" ] && shift
    printf '%s\n' "$1" >> "$RS_LOG"          # prove the spawn was backgrounded
    sh -c "$1" ;;                            # mirror real run-shell: actually run it
  display-message)
    case "$*" in
      *-p*) case "$*" in
              *session_name*) echo "${SESS_NAME:-testsess}";;
              *@issue*)       echo "${ORIGIN_PROBE:-}";;   # fleet_origin_key's caller-pane probe (case N)
              *) echo "";; esac ;;
      *)    printf '%s\n' "$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  list-windows)     printf '%s\n' "${WINS:-}" ;;                 # -F window_name (ignored: WINS is the name set)
  new-window)       printf 'NEWWIN %s\n' "$*" >> "$NEWWIN_LOG"; echo '@9' ;;   # -P -F window_id
  set-window-option) printf 'SETOPT %s\n' "$*" >> "$OPTS_LOG" ;;
  select-window)    printf 'SELECT %s\n' "$*" >> "$SELECT_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

# run the raw spawner. The per-case env (WINS, FLEET_MAX_SESSIONS,
# FLEET_SPAWN_FOCUS) is set as a prefix on the `run_raw` call — bash exports those
# into the function's command environment, so the child `bash` inherits them. Any
# args passed to run_raw are forwarded to the script (--name / --bg / positional
# <target-session>).
run_raw() {
  : > "$NEWWIN_LOG"; : > "$OPTS_LOG"; : > "$DISPLAY_LOG"; : > "$SELECT_LOG"; : > "$RS_LOG"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$MAIN" FLEET_BASE_BRANCH="$BASE_BR" \
  FLEET_GLOBAL_MAX_SESSIONS=0 \
  DISPLAY_LOG="$DISPLAY_LOG" NEWWIN_LOG="$NEWWIN_LOG" OPTS_LOG="$OPTS_LOG" SELECT_LOG="$SELECT_LOG" RS_LOG="$RS_LOG" \
    bash "$WORK/bin/dash-raw-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"
}

# ============================ A: happy spawn =================================
reset_scratch
WINS=$'plan\ndash' FLEET_MAX_SESSIONS=0 FLEET_SPAWN_FOCUS=1 run_raw
grep -q 'NEWWIN' "$NEWWIN_LOG"             || fail "A a raw window was not created" "$(cat "$WORK/err")"
grep -q -- '-n scratch-1\b' "$NEWWIN_LOG"  || fail "A window not named 'scratch-1'" "$(cat "$NEWWIN_LOG")"
grep -q -- "-c $WORK/main-scratch-1" "$NEWWIN_LOG" || fail "A window not opened in the scratch worktree" "$(cat "$NEWWIN_LOG")"
grep -q -- '-d' "$NEWWIN_LOG"              || fail "A raw spawn should be -d (non-invasive)" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@raw 1' "$OPTS_LOG"      || fail "A @raw=1 marker not set" "$(cat "$OPTS_LOG")"
grep -q "SETOPT .*@worktree $WORK/main-scratch-1" "$OPTS_LOG" || fail "A @worktree not set to the worktree path" "$(cat "$OPTS_LOG")"
grep -q '@issue' "$OPTS_LOG"               && fail "A a raw window must NOT get an @issue" "$(cat "$OPTS_LOG")"
grep -q 'SELECT .*@9' "$SELECT_LOG"        || fail "A FLEET_SPAWN_FOCUS=1 should jump to the new window" "$(cat "$SELECT_LOG")"
[ -d "$WORK/main-scratch-1" ]              || fail "A a real scratch-1 worktree must exist" "$(git -C "$MAIN" worktree list)"
git -C "$MAIN" show-ref --verify -q refs/heads/scratch-1 || fail "A a scratch-1 branch must exist"
# worktree is off the base branch (its HEAD == base tip)
[ "$(git -C "$WORK/main-scratch-1" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse "$BASE_BR")" ] \
  || fail "A scratch worktree must be created off the base branch"
# SILENCE (issue #446): a spawn must print NOTHING on stdout. Under `run-shell -b`
# (the ⌃s path) tmux turns a backgrounded job's stdout into a VIEW-MODE overlay on
# the invoking pane — i.e. one stray line (`git worktree add`'s "HEAD is now at …")
# covers the dash until the user presses Esc.
[ -s "$WORK/out" ] && fail "A the spawn must be silent on stdout (run-shell would overlay it on the dash)" "$(cat "$WORK/out")"
ok "A raw spawn creates a @raw scratch-1 WORKTREE off base, @worktree set, no @issue"

# ============================ B: cap refusal ================================
# per-fleet cap of 1 with one live non-panel worker window ⇒ refuse before spawning.
reset_scratch
WINS=$'plan\nworker-1' FLEET_MAX_SESSIONS=1 run_raw
[ -s "$NEWWIN_LOG" ] && fail "B a cap refusal must NOT create a window" "$(cat "$NEWWIN_LOG")"
[ -e "$WORK/main-scratch-1" ] && fail "B a cap refusal must NOT create a worktree" "$(git -C "$MAIN" worktree list)"
grep -qi 'capacity' "$DISPLAY_LOG"       || fail "B cap refusal should surface a capacity message" "$(cat "$DISPLAY_LOG")"
ok "B raw spawn honours the session cap (refuses, no window, no worktree)"

# ============================ C: N allocation ===============================
# a pre-existing scratch-1 branch/worktree ⇒ the next spawn allocates scratch-2.
reset_scratch
git -C "$MAIN" worktree add -q -b scratch-1 "$WORK/main-scratch-1" >/dev/null 2>&1
WINS=$'plan\ndash' FLEET_MAX_SESSIONS=0 run_raw
grep -q -- '-n scratch-2\b' "$NEWWIN_LOG" || fail "C an existing scratch-1 should push the next to scratch-2" "$(cat "$NEWWIN_LOG")"
[ -d "$WORK/main-scratch-2" ]             || fail "C a real scratch-2 worktree must exist" "$(git -C "$MAIN" worktree list)"
ok "C an existing scratch-1 branch makes the next worktree 'scratch-2'"

# ==================== F: --name names the window (issue #225) ================
reset_scratch
WINS=$'plan\ndash' FLEET_MAX_SESSIONS=0 run_raw --name foo
grep -q -- '-n foo\b' "$NEWWIN_LOG"    || fail "F --name foo should name the window foo" "$(cat "$NEWWIN_LOG")"
grep -q -- "-c $WORK/main-scratch-1" "$NEWWIN_LOG" || fail "F a named raw window still lives in a scratch worktree" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@raw 1' "$OPTS_LOG"  || fail "F a named raw window must still be @raw=1" "$(cat "$OPTS_LOG")"
grep -q 'SETOPT .*@worktree' "$OPTS_LOG" || fail "F a named raw window must still carry @worktree" "$(cat "$OPTS_LOG")"
grep -q '@issue' "$OPTS_LOG"           && fail "F a named raw window must NOT get an @issue" "$(cat "$OPTS_LOG")"
ok "F --name foo → window 'foo', still @raw=1 + @worktree and no @issue"

# ==================== G: empty --name keeps the auto name ====================
reset_scratch
WINS=$'plan\ndash' FLEET_MAX_SESSIONS=0 run_raw --name ''
grep -q -- '-n scratch-1\b' "$NEWWIN_LOG" || fail "G empty --name should fall back to auto scratch-N" "$(cat "$NEWWIN_LOG")"
ok "G an empty --name keeps the auto 'scratch-N' name"

# ==================== H: custom-name dedup ==================================
reset_scratch
WINS=$'plan\nfoo' FLEET_MAX_SESSIONS=0 run_raw --name foo
grep -q -- '-n foo-2\b' "$NEWWIN_LOG" || fail "H a taken custom name should get a -2 suffix" "$(cat "$NEWWIN_LOG")"
ok "H a live 'foo' window makes the next --name foo → 'foo-2'"

# ==================== I: reserved panel names fall back ======================
for r in plan dash backlog; do
  reset_scratch
  WINS=$'other' FLEET_MAX_SESSIONS=0 run_raw --name "$r"
  grep -q -- '-n scratch-1\b' "$NEWWIN_LOG" || fail "I reserved --name $r should fall back to scratch-N" "$(cat "$NEWWIN_LOG")"
  grep -qi 'reserved' "$DISPLAY_LOG"        || fail "I reserved --name $r should surface a note" "$(cat "$DISPLAY_LOG")"
done
ok "I --name plan/dash/backlog → fallback 'scratch-N' + a reserved note"

# ==================== J: empties-after-sanitize falls back ===================
reset_scratch
WINS=$'other' FLEET_MAX_SESSIONS=0 run_raw --name '###'
grep -q -- '-n scratch-1\b' "$NEWWIN_LOG"       || fail "J a name that sanitizes empty should fall back to scratch-N" "$(cat "$NEWWIN_LOG")"
grep -qi 'empty after sanitize' "$DISPLAY_LOG"  || fail "J empties-after-sanitize should surface a note" "$(cat "$DISPLAY_LOG")"
ok "J --name '###' (empties after sanitize) → fallback 'scratch-N' + note"

# ==================== K: sanitization (strip / preserve / cap) ===============
# tab (control char) + '#' stripped; internal space + casing preserved.
reset_scratch
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name $'A\tB C#D'
grep -qF -- '-n AB CD -c' "$NEWWIN_LOG" || fail "K control chars + '#' stripped, space/case kept" "$(cat "$NEWWIN_LOG")"
# length cap: a 36-char name is truncated to 24.
reset_scratch
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
grep -q -- '-n ABCDEFGHIJKLMNOPQRSTUVWX\b' "$NEWWIN_LOG" || fail "K a long name should be capped at ~24 chars" "$(cat "$NEWWIN_LOG")"
ok "K sanitize strips control chars + '#', preserves case/spacing, caps at ~24"

# ==================== L: positional target alongside --name ==================
reset_scratch
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name foo othersess
grep -q -- '-n foo\b' "$NEWWIN_LOG"       || fail "L --name foo <sess> should still name the window foo" "$(cat "$NEWWIN_LOG")"
grep -q -- '-t othersess:' "$NEWWIN_LOG"  || fail "L a positional <target-session> should still be honored" "$(cat "$NEWWIN_LOG")"
ok "L --name foo <target-session> spawns 'foo' into the target"

# ==================== N: spawn provenance across fleets =======================
# A raw scratch spawned FROM a scratch pane (@raw=1 + @worktree=…-scratch-5) is
# stamped @origin=scratch-5 — right when the target is the spawner's own fleet,
# wrong across fleets (the handoff pattern: a claude-fleet scratch seeding a
# monorepo scratch): `scratch-5` means a different window on the target's dash,
# which then nests the new row under an unrelated parent. Cross-fleet → the
# origin is the SOURCE FLEET name (rendered `↳<fleet>`, no nesting).
reset_scratch
TMUX=fake TMUX_PANE=%5 SESS_NAME=srcfleet ORIGIN_PROBE="|1|$WORK/main-scratch-5|$WORK/main-scratch-5"   WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name same srcfleet
grep -q 'SETOPT .*@origin scratch-5' "$OPTS_LOG" || fail "N same-fleet spawn from scratch-5 must stamp @origin scratch-5" "$(cat "$OPTS_LOG")"
reset_scratch
TMUX=fake TMUX_PANE=%5 SESS_NAME=srcfleet ORIGIN_PROBE="|1|$WORK/main-scratch-5|$WORK/main-scratch-5"   WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name cross dstfleet
grep -q 'SETOPT .*@origin srcfleet' "$OPTS_LOG"  || fail "N cross-fleet spawn must stamp the SOURCE FLEET as @origin, not scratch-5" "$(cat "$OPTS_LOG")"
reset_scratch
TMUX=fake TMUX_PANE=%5 SESS_NAME=srcfleet ORIGIN_PROBE="|1|$WORK/main-scratch-5|$WORK/main-scratch-5"   WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name explicit --origin issue-77 dstfleet
grep -q 'SETOPT .*@origin issue-77' "$OPTS_LOG"  || fail "N an explicit --origin is honoured as given across fleets" "$(cat "$OPTS_LOG")"
ok "N provenance: same-fleet → scratch-N; cross-fleet → the source fleet; --origin wins"

# ==================== M: dash ⌃s spawns instantly (--bg) =====================
# ⌃s has NO name popup any more (issue #444): the keypress runs the cheap refusals
# inline and hands the fetch + worktree add + window launch to run-shell -b (#304),
# so the dash returns instantly and the scratch lands in the background. --bg with
# a --name still stages the (arbitrary user) text through a --name-file re-exec
# rather than interpolating it into the run-shell string.
reset_scratch
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --bg
grep -q -- '-n scratch-1\b' "$NEWWIN_LOG" || fail "M --bg should still land an auto scratch-N window" "$(cat "$NEWWIN_LOG")"
grep -q 'dash-raw-session.sh' "$RS_LOG"    || fail "M the ⌃s spawn must be dispatched via run-shell -b" "$(cat "$RS_LOG")"
grep -q -- '--name-file=' "$RS_LOG"        && fail "M an unnamed --bg spawn should stage no name file" "$(cat "$RS_LOG")"
grep -q -- '>/dev/null 2>&1' "$RS_LOG"     || fail "M the backgrounded spawn must be redirected (run-shell stdout = view-mode overlay on the dash, #446)" "$(cat "$RS_LOG")"
[ -s "$WORK/out" ]                         && fail "M --bg must print nothing on stdout" "$(cat "$WORK/out")"
[ -d "$WORK/main-scratch-1" ]              || fail "M --bg must create the real scratch worktree" "$(git -C "$MAIN" worktree list)"
reset_scratch
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --bg --name mybox
grep -q -- '-n mybox\b' "$NEWWIN_LOG" || fail "M --bg --name should carry the name through" "$(cat "$NEWWIN_LOG")"
grep -q -- '--name-file=' "$RS_LOG"   || fail "M a named --bg spawn must pass the name via --name-file" "$(cat "$RS_LOG")"
# a cap refusal is still synchronous (visible), and never reaches the background.
reset_scratch
WINS=$'plan\nworker-1' FLEET_MAX_SESSIONS=1 run_raw --bg
[ -s "$RS_LOG" ]      && fail "M a cap refusal must NOT dispatch a background spawn" "$(cat "$RS_LOG")"
[ -s "$NEWWIN_LOG" ]  && fail "M a cap refusal must NOT create a window" "$(cat "$NEWWIN_LOG")"
grep -qi 'capacity' "$DISPLAY_LOG" || fail "M a --bg cap refusal should still surface a message" "$(cat "$DISPLAY_LOG")"
ok "M dash ⌃s (--bg) spawns instantly — backgrounded, no prompt, refusals stay sync"

# ==================== N: --prompt seeds the scratch (dash prompt line) ========
# The dash's always-visible prompt line hands its text over as --prompt (via
# dash-enter.sh). The seed rides in a task file read at launch — `fleet-claude.sh
# "$(cat <tf>)"`, the worker-seed handoff — never inline in the command string; a
# --bg --prompt stages it through --prompt-file (never into the run-shell string);
# the summary column is seeded with the task; a seeded scratch never claims a
# warm-pool window; a whitespace-only prompt is a plain scratch.
POOL_LOG="$WORK/pool"
cat > "$WORK/bin/scratch-pool.sh" <<POOLFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$POOL_LOG"    # log the call; answer with an EMPTY claim (cold path)
exit 0
POOLFAKE
chmod +x "$WORK/bin/scratch-pool.sh"
reset_scratch; : > "$POOL_LOG"; rm -rf "$WORK/tmp/.claude-dash/fleets" "$WORK/tmp/.claude-dash/global"
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --prompt $'audit the dash binds for "$(injection)" risks'
grep -q -- '-n scratch-1\b' "$NEWWIN_LOG"  || fail "N --prompt must still land a scratch-N window" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@raw 1' "$OPTS_LOG"      || fail "N a seeded scratch is still @raw=1" "$(cat "$OPTS_LOG")"
grep -q '@issue' "$OPTS_LOG"               && fail "N a seeded scratch must NOT get an @issue" "$(cat "$OPTS_LOG")"
grep -qF -- "fleet-claude.sh' \"\$(cat '" "$NEWWIN_LOG" || fail "N the seed must ride in a task file read at launch (\"\$(cat <tf>)\")" "$(cat "$NEWWIN_LOG")"
grep -qF -- 'injection' "$NEWWIN_LOG"      && fail "N the prompt text must NEVER be interpolated into the new-window command" "$(cat "$NEWWIN_LOG")"
tf="$(grep -o "cat '[^']*task_scratch-1.txt'" "$NEWWIN_LOG" | head -1 | sed "s/^cat '//; s/'$//")"
[ -n "$tf" ] && [ -f "$tf" ]               || fail "N the task file task_scratch-1.txt must exist" "$(cat "$NEWWIN_LOG")"
[ "$(cat "$tf")" = $'audit the dash binds for "$(injection)" risks' ] || fail "N the task file must hold the prompt verbatim" "$(cat "$tf")"
grep -qs 'claim' "$POOL_LOG"               && fail "N a seeded scratch must never claim a warm-pool window (the seed is a launch arg)" "$(cat "$POOL_LOG")"
grep -qs 'scratch-1: audit the dash binds' "$WORK/tmp/.claude-dash/global"/summary_* || fail "N the summary column must be seeded with the task" "$(ls "$WORK/tmp/.claude-dash/global" 2>/dev/null)"
grep -q 'seeded' "$DISPLAY_LOG"            || fail "N the status line should say the scratch was seeded" "$(cat "$DISPLAY_LOG")"
# …while an UNSEEDED spawn does consult the pool first
reset_scratch; : > "$POOL_LOG"
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw
grep -qs 'claim' "$POOL_LOG"               || fail "N a plain scratch should still try the warm pool first" "$(cat "$POOL_LOG")"
# --bg --prompt: staged through --prompt-file, lands, and the text never touches run-shell
reset_scratch
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --bg --prompt 'bg seeded task'
grep -q -- '-n scratch-1\b' "$NEWWIN_LOG"  || fail "N --bg --prompt must land the scratch" "$(cat "$NEWWIN_LOG")"
grep -q -- '--prompt-file=' "$RS_LOG"      || fail "N a --bg --prompt spawn must stage the prompt via --prompt-file" "$(cat "$RS_LOG")"
grep -qF 'bg seeded task' "$RS_LOG"        && fail "N the prompt text must not be interpolated into the run-shell string" "$(cat "$RS_LOG")"
tf="$(grep -o "cat '[^']*task_scratch-1.txt'" "$NEWWIN_LOG" | head -1 | sed "s/^cat '//; s/'$//")"
[ "$(cat "$tf" 2>/dev/null)" = 'bg seeded task' ] || fail "N the --bg seed must reach the task file" "$(cat "$NEWWIN_LOG")"
# whitespace-only prompt → plain scratch (no task file, plain launch)
reset_scratch
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --prompt '   '
grep -q -- '-n scratch-1\b' "$NEWWIN_LOG"  || fail "N a blank --prompt must still spawn" "$(cat "$NEWWIN_LOG")"
grep -qF -- '$(cat' "$NEWWIN_LOG"          && fail "N a blank --prompt is a PLAIN scratch — no task-file launch" "$(cat "$NEWWIN_LOG")"
rm -f "$WORK/bin/scratch-pool.sh"
ok "N --prompt seeds the scratch via a task file (never inline), skips the pool, --bg stages it"

# ============================ D: restore drops @raw ==========================
out=$(printf 'scratch|%s|-|done|-|-|1\nissue-7|%s|7|working|#12|✓|\n__HUB__|%s|-\n' \
        "$WORK/main-scratch-1" "$WORK/main-issue-7" "$WORK/main" | python3 "$RESOLVE")
printf '%s\n' "$out" | grep -q $'^WIN\tissue-7\t'  || fail "D a normal WIN row must survive" "$out"
printf '%s\n' "$out" | grep -q $'^HUB\t'           || fail "D the HUB row must survive" "$out"
printf '%s\n' "$out" | grep -q 'scratch'           && fail "D a @raw=1 row must be DROPPED (never restored)" "$out"
ok "D the restore resolver drops @raw=1 rows, keeps normal + hub rows"

# ============================ E: old-map back-compat ========================
# a pre-#214 WIN row has only 6 fields (no @raw) — raw defaults to '' → kept.
out=$(printf 'issue-9|%s|9|done|-|-\n' "$WORK/main-issue-9" | python3 "$RESOLVE")
printf '%s\n' "$out" | grep -q $'^WIN\tissue-9\t'  || fail "E a 6-field (pre-#214) WIN row must still parse+survive" "$out"
ok "E an old 6-field map row (no @raw) is unaffected"

printf '\nselftest OK: %s assertions passed (raw scratch worktree session, #214/#290)\n' "$pass"
exit 0
