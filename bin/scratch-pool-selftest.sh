#!/bin/bash
# scratch-pool-selftest.sh — hermetic tests for the WARM SCRATCH POOL
# (bin/scratch-pool.sh + the claim fast-path in bin/dash-raw-session.sh).
#
# No network, no real claude, no real tmux: a REAL local git repo stands in for
# $FLEET_MAIN (so `git worktree add` runs for real via fleet_scratch_alloc), and a
# fake `tmux` on PATH keeps window options in a state file so claim/usable/reap can
# be exercised end to end. What a fake CANNOT prove — that a claimed window is
# actually typeable — is covered by the numbers recorded in the PR/commit; what it
# CAN prove is every branch of the gating, which is where the bugs were.
#
#   A. pool off (FLEET_SCRATCH_POOL=0) → claim prints nothing, exit 0
#   B. no holding session               → claim prints nothing, exit 0
#   C. not-ready entry                  → not claimed
#   D. stale entry (older than MAX_AGE) → not claimed
#   E. geometry mismatch                → not claimed  (a resize on arrival wedges
#                                         Claude Code's TUI — the whole reason the
#                                         pool exists is to avoid a dead window)
#   F. ready+fresh+matching             → claimed: move-window issued, @pool_* keys
#                                         cleared, "<wid>\t<slug>\t<wt>" printed
#   G. dash-raw-session.sh + claim      → NO new-window (it reuses the warm pane)
#   H. dash-raw-session.sh, empty claim → falls back to the cold path (new-window)
#   I. fleet_scratch_alloc/free         → real worktree created, then fully removed
#   J. Codex provider/account gate
#   K–P. one pool per hosted repo (#797): a B claim gets a B window and never A's;
#        untagged entries by worktree origin; per-repo FLEET_SCRATCH_POOL; the
#        dash-raw-session claim; fan-out reap/status; one-repo fleet unchanged
#
# Exit 0 = pass; non-zero = fail.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
POOL="$BIN/scratch-pool.sh"; RAW="$BIN/dash-raw-session.sh"; LIB="$BIN/fleet-lib.sh"
for f in "$POOL" "$RAW" "$LIB"; do [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }; done
command -v git >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# ---- a real base repo -------------------------------------------------------
MAIN="$WORK/main"; mkdir -p "$MAIN"
( cd "$MAIN" && git init -q -b master . && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm init ) || { echo "selftest: git setup failed" >&2; exit 2; }

# ---- per-fleet conf ---------------------------------------------------------
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR/fleets/tf"
mkconf() {  # mkconf <pool-size> [max-age]
  cat > "$FLEET_CONF_DIR/fleets/tf/conf" <<EOF
FLEET_MAIN="$MAIN"
FLEET_BASE_BRANCH="master"
FLEET_SCRATCH_POOL=$1
FLEET_POOL_MAX_AGE=${2:-1800}
EOF
}

# ---- fake tmux --------------------------------------------------------------
# State: $STATE/win.<id>.<opt> files + $STATE/windows (id<TAB>session<TAB>name).
STATE="$WORK/tmuxstate"; mkdir -p "$STATE"; : > "$STATE/windows"; : > "$STATE/log"
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/tmux" <<'FAKE'
#!/bin/bash
S="$TMUX_FAKE_STATE"; echo "$*" >> "$S/log"
args=("$@"); [ "${args[0]}" = "-L" ] && args=("${args[@]:2}")
cmd="${args[0]}"; shift_args=("${args[@]:1}")
tgt=""; fmt=""; i=0
while [ $i -lt ${#shift_args[@]} ]; do
  case "${shift_args[$i]}" in
    -t) i=$((i+1)); tgt="${shift_args[$i]}" ;;
    -F|-p) : ;;
  esac
  i=$((i+1))
done
case "$cmd" in
  has-session) grep -q "	${tgt}	" "$S/windows" && exit 0; exit 1 ;;
  list-windows)
    while IFS=$'\t' read -r id sess name; do
      [ "$sess" = "$tgt" ] || continue
      echo "$id"
    done < "$S/windows" ;;
  display-message)
    # a session target resolves to that session's first window (real tmux does)
    case "$tgt" in
      @*) : ;;
      *) tgt=$(awk -F'\t' -v s="$tgt" '$2==s{print $1; exit}' "$S/windows") ;;
    esac
    f="${shift_args[${#shift_args[@]}-1]}"
    key="${f#\#\{}"; key="${key%\}}"
    case "$key" in
      window_name) awk -F'\t' -v i="$tgt" '$1==i{print $3}' "$S/windows" ;;
      window_width|window_height|pane_pid|pane_dead) cat "$S/win.${tgt}.$key" 2>/dev/null || echo "" ;;
      *) cat "$S/win.${tgt}.${key#@}" 2>/dev/null || echo "" ;;
    esac ;;
  set-window-option)
    unset_it=0; a=(); for x in "${shift_args[@]}"; do [ "$x" = "-u" ] && unset_it=1 || a+=("$x"); done
    # a = (-t <tgt> <opt> [val])
    opt="${a[2]}"; val="${a[3]:-}"; opt="${opt#@}"
    if [ "$unset_it" = 1 ]; then rm -f "$S/win.${tgt}.$opt"; else printf '%s' "$val" > "$S/win.${tgt}.$opt"; fi ;;
  move-window)
    src=""; dst=""; i=0
    while [ $i -lt ${#shift_args[@]} ]; do
      case "${shift_args[$i]}" in -s) i=$((i+1)); src="${shift_args[$i]}";; -t) i=$((i+1)); dst="${shift_args[$i]}";; esac
      i=$((i+1)); done
    dst="${dst%:}"
    awk -F'\t' -v i="$src" -v d="$dst" 'BEGIN{OFS="\t"} {if($1==i)$2=d; print}' "$S/windows" > "$S/windows.n" && mv "$S/windows.n" "$S/windows" ;;
  new-window|new-session|kill-window|rename-window|set-option|resize-window|run-shell|select-window) : ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakebin/tmux"
export TMUX_FAKE_STATE="$STATE"
export PATH="$WORK/fakebin:$PATH"

addwin() {  # addwin <id> <session> <name> [w] [h]
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE/windows"
  printf '%s' "${4:-100}" > "$STATE/win.$1.window_width"
  printf '%s' "${5:-30}"  > "$STATE/win.$1.window_height"
  printf '0' > "$STATE/win.$1.pane_dead"
}
setopt_() { printf '%s' "$3" > "$STATE/win.$1.$2"; }
reset_state() { : > "$STATE/windows"; rm -f "$STATE"/win.* ; : > "$STATE/log"; }

# The fleet session must exist so fleet_dims() can read its geometry.
mkfleet() { addwin '@0' 'tf' 'plan' "${1:-100}" "${2:-30}"; }

# ---- A: pool off ------------------------------------------------------------
reset_state; mkfleet; mkconf 0
out=$(bash "$POOL" claim tf 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ] || fail "A pool-off claim must be a silent no-op" "rc=$rc out=$out"; ok "A pool off → claim is a silent no-op"

# ---- B: no holding session --------------------------------------------------
reset_state; mkfleet; mkconf 1
out=$(bash "$POOL" claim tf 2>&1)
[ -z "$out" ] || fail "B claim with no pool session must print nothing" "$out"; ok "B no holding session → nothing claimed"

# ---- C: entry not ready -----------------------------------------------------
reset_state; mkfleet; mkconf 1
addwin '@9' 'tf-pool' 'warm-1'
setopt_ '@9' pool 1; setopt_ '@9' pool_slug scratch-1; setopt_ '@9' worktree "$WORK/wt1"
setopt_ '@9' pool_born "$(date +%s)"; setopt_ '@9' pool_account ""
out=$(bash "$POOL" claim tf 2>&1)
[ -z "$out" ] || fail "C an un-ready entry must not be claimed" "$out"; ok "C not-ready entry → not claimed"

# ---- D: stale entry ---------------------------------------------------------
reset_state; mkfleet; mkconf 1 60
addwin '@9' 'tf-pool' 'warm-1'
setopt_ '@9' pool 1; setopt_ '@9' pool_ready 1; setopt_ '@9' pool_slug scratch-1
setopt_ '@9' worktree "$WORK/wt1"; setopt_ '@9' pool_account ""
setopt_ '@9' pool_born "$(( $(date +%s) - 600 ))"
out=$(bash "$POOL" claim tf 2>&1)
[ -z "$out" ] || fail "D a stale entry must not be claimed" "$out"; ok "D stale entry → not claimed"

# ---- E: geometry mismatch ---------------------------------------------------
reset_state; mkfleet 100 30; mkconf 1
addwin '@9' 'tf-pool' 'warm-1' 80 24
setopt_ '@9' pool 1; setopt_ '@9' pool_ready 1; setopt_ '@9' pool_slug scratch-1
setopt_ '@9' worktree "$WORK/wt1"; setopt_ '@9' pool_account ""; setopt_ '@9' pool_born "$(date +%s)"
out=$(bash "$POOL" claim tf 2>&1)
[ -z "$out" ] || fail "E a differently-sized entry must not be claimed (resize wedges the TUI)" "$out"; ok "E geometry mismatch → not claimed"

# ---- F: a good entry is claimed --------------------------------------------
reset_state; mkfleet 100 30; mkconf 1
addwin '@9' 'tf-pool' 'warm-1' 100 30
setopt_ '@9' pool 1; setopt_ '@9' pool_ready 1; setopt_ '@9' pool_slug scratch-1
setopt_ '@9' worktree "$WORK/wt1"; setopt_ '@9' pool_account ""; setopt_ '@9' pool_born "$(date +%s)"
out=$(bash "$POOL" claim tf 2>&1)
printf '%s' "$out" | grep -q "^@9	scratch-1	$WORK/wt1$" || fail "F claim must print wid/slug/worktree" "$out"
grep -q " move-window " "$STATE/log" || fail "F claim must move the window into the fleet" "$(cat "$STATE/log")"
awk -F'\t' '$1=="@9"{print $2}' "$STATE/windows" | grep -qx tf || fail "F the window must end up in the fleet session"
[ -f "$STATE/win.@9.pool" ] && fail "F @pool must be cleared on claim"
[ -f "$STATE/win.@9.pool_ready" ] && fail "F @pool_ready must be cleared on claim"
ok "F ready+fresh+matching entry → claimed, moved, @pool_* cleared"

# ---- G/H: dash-raw-session.sh fast path vs cold fallback --------------------
reset_state; mkfleet 100 30; mkconf 1
addwin '@9' 'tf-pool' 'warm-1' 100 30
setopt_ '@9' pool 1; setopt_ '@9' pool_ready 1; setopt_ '@9' pool_slug scratch-1
setopt_ '@9' worktree "$WORK/wt1"; setopt_ '@9' pool_account ""; setopt_ '@9' pool_born "$(date +%s)"
FLEET_CONF_DIR="$FLEET_CONF_DIR" bash "$RAW" tf >/dev/null 2>&1
grep -q " new-window " "$STATE/log" && fail "G a claimed warm window must NOT be re-spawned" "$(cat "$STATE/log")"
grep -q " rename-window " "$STATE/log" || fail "G the claimed window must be renamed into the fleet" "$(cat "$STATE/log")"
ok "G dash-raw-session claims the warm entry instead of spawning"

reset_state; mkfleet 100 30; mkconf 0        # pool off ⇒ claim empty ⇒ cold path
FLEET_CONF_DIR="$FLEET_CONF_DIR" bash "$RAW" tf >/dev/null 2>&1
grep -q " new-window " "$STATE/log" || fail "H with no warm entry it must fall back to a cold spawn" "$(cat "$STATE/log")"
ok "H empty claim → cold spawn path still runs"

# ---- I: real worktree alloc/free -------------------------------------------
# shellcheck source=/dev/null
. "$LIB"
alloc=$(fleet_scratch_alloc "$MAIN" master) || fail "I fleet_scratch_alloc failed"
slug=${alloc%%	*}; wt=${alloc#*	}
[ -d "$wt" ] || fail "I the worktree was not created at $wt"
git -C "$MAIN" show-ref --verify --quiet "refs/heads/$slug" || fail "I the branch $slug was not created"
fleet_scratch_free "$MAIN" "$slug" "$wt"
[ -e "$wt" ] && fail "I fleet_scratch_free left the worktree behind"
git -C "$MAIN" show-ref --verify --quiet "refs/heads/$slug" && fail "I fleet_scratch_free left the branch behind"
ok "I fleet_scratch_alloc/free round-trips on a real repo"

# Provider and account-home ownership gate a warm Codex claim.
reset_state; mkfleet; mkconf 1
printf 'FLEET_AGENT=codex\nFLEET_CODEX_HOME=%q\n' "$WORK/codex-home" >> "$FLEET_CONF_DIR/fleets/tf/conf"
addwin '@9' 'tf-pool' 'warm-codex' 100 30
setopt_ '@9' pool 1; setopt_ '@9' pool_ready 1; setopt_ '@9' pool_slug scratch-1
setopt_ '@9' worktree "$WORK/wt1"; setopt_ '@9' pool_born "$(date +%s)"
setopt_ '@9' pool_account "codex:$WORK/codex-home"
out=$(bash "$POOL" claim tf); [ -z "$out" ] || fail 'Codex fleet claimed a Claude entry'
setopt_ '@9' pool_agent codex; setopt_ '@9' pool_account 'codex:another-home'
out=$(bash "$POOL" claim tf); [ -z "$out" ] || fail 'Codex fleet claimed another account home'
setopt_ '@9' pool_account "codex:$WORK/codex-home"
out=$(bash "$POOL" claim tf); [ -n "$out" ] || fail 'matching warm Codex entry was not claimed'
ok 'J Codex pool matches provider and account home before moving the window'

# ---- K–Q: one pool per hosted repo (issue #797) -----------------------------
# A second real repo, and a fleet that hosts both: the conf's own repo o/a plus an
# overlay for o/b. Pool entries of both repos share the one holding session.
MAIN_B="$WORK/main-b"; mkdir -p "$MAIN_B"
( cd "$MAIN_B" && git init -q -b main . && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm init ) || fail "K git setup (repo B) failed"
git -C "$MAIN" remote add origin https://github.com/o/a.git 2>/dev/null
git -C "$MAIN_B" remote add origin https://github.com/o/b.git 2>/dev/null
mkconf2() {  # mkconf2 <fleet pool> [<B overlay pool>]
  mkconf "$1"; printf 'FLEET_REPO="o/a"\n' >> "$FLEET_CONF_DIR/fleets/tf/conf"
  mkdir -p "$FLEET_CONF_DIR/fleets/tf/repos"
  { printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$MAIN_B"
    [ -n "${2:-}" ] && printf 'FLEET_SCRATCH_POOL=%s\n' "$2"; } > "$(fleet_repo_conf_file tf o/b)"
}
warm() {  # warm <wid> <repo|-> <worktree> — a ready, fresh, right-sized entry
  addwin "$1" 'tf-pool' "warm-$1" 100 30
  setopt_ "$1" pool 1; setopt_ "$1" pool_ready 1; setopt_ "$1" pool_slug "scratch-${1#@}"
  setopt_ "$1" worktree "$3"; setopt_ "$1" pool_account ""; setopt_ "$1" pool_born "$(date +%s)"
  [ "$2" = - ] || setopt_ "$1" repo "$2"
}
in_sess() { awk -F'\t' -v i="$1" '$1==i{print $2}' "$STATE/windows"; }

reset_state; mkfleet; mkconf2 1
warm '@11' o/a "$WORK/wt-a"; warm '@12' o/b "$WORK/wt-b"
out=$(bash "$POOL" claim tf --repo o/b 2>&1)
[ "${out%%	*}" = '@12' ] || fail "K claim --repo o/b must return B's entry" "$out"
[ "$(in_sess '@11')" = tf-pool ] && [ -f "$STATE/win.@11.pool_ready" ] || fail "K A's entry must stay warm in the pool"
[ "$(cat "$STATE/win.@12.repo" 2>/dev/null)" = o/b ] || fail "K the claimed window must keep @repo o/b"
out=$(bash "$POOL" claim tf --repo o/b 2>&1)
[ -z "$out" ] || fail "K with B's pool empty, a B claim must NOT fall back to A's entry" "$out"
out=$(bash "$POOL" claim tf --repo o/a 2>&1)
[ "${out%%	*}" = '@11' ] || fail "K claim --repo o/a must return A's entry" "$out"
ok "K 2-repo fleet: claim --repo B returns B's warm window; A's pool untouched"

# L: an entry warmed before #797 has no @repo — its worktree's origin says whose it is.
reset_state; mkfleet; mkconf2 1
LWT="$WORK/legacy-b"; git clone -q "$MAIN_B" "$LWT" 2>/dev/null && git -C "$LWT" remote set-url origin git@github.com:o/b.git
warm '@13' - "$LWT"
out=$(bash "$POOL" claim tf --repo o/a 2>&1); [ -z "$out" ] || fail "L an untagged B entry must not go to A" "$out"
out=$(bash "$POOL" claim tf --repo o/b 2>&1); [ "${out%%	*}" = '@13' ] || fail "L an untagged entry must be matched by its worktree's origin" "$out"
ok "L untagged (pre-#797) entry → repo read from its worktree origin"

# M: the overlay's FLEET_SCRATCH_POOL wins over the fleet value, per repo.
reset_state; mkfleet; mkconf2 1 0
warm '@11' o/a "$WORK/wt-a"; warm '@12' o/b "$WORK/wt-b"
out=$(bash "$POOL" claim tf --repo o/b 2>&1); [ -z "$out" ] || fail "M B's overlay turned its pool off" "$out"
out=$(bash "$POOL" claim tf --repo o/a 2>&1); [ "${out%%	*}" = '@11' ] || fail "M A's pool (fleet value) must still claim" "$out"
out=$(bash "$POOL" claim tf --repo o/nope 2>&1); [ -z "$out" ] || fail "M an unhosted repo claims nothing" "$out"
ok "M per-repo FLEET_SCRATCH_POOL: overlay off ⇒ that repo cold, the other still warm"

# N: dash-raw-session hands a B scratch B's warm window, never A's.
reset_state; mkfleet; mkconf2 1
warm '@11' o/a "$WORK/wt-a"; warm '@12' o/b "$WORK/wt-b"
FLEET_CONF_DIR="$FLEET_CONF_DIR" bash "$RAW" tf --repo o/b >/dev/null 2>&1
grep -q " new-window " "$STATE/log" && fail "N a B scratch with a warm B entry must not cold-spawn" "$(cat "$STATE/log")"
[ "$(in_sess '@12')" = tf ] && [ "$(in_sess '@11')" = tf-pool ] || fail "N dash-raw-session must move B's entry and leave A's" "$(cat "$STATE/windows")"
ok "N dash-raw-session --repo o/b claims B's warm window"

# O: fan-out reap retires an entry of a repo the fleet no longer hosts; status lists per repo.
reset_state; mkfleet; mkconf2 1
warm '@11' o/a "$WORK/wt-a"; warm '@12' o/b "$WORK/wt-b"; warm '@14' o/gone "$WORK/wt-g"
bash "$POOL" reap tf >/dev/null 2>&1
grep -q "kill-window -t @14" "$STATE/log" || fail "O an unhosted repo's entry must be retired" "$(cat "$STATE/log")"
grep -q "kill-window -t @1[12]" "$STATE/log" && fail "O hosted, usable entries must survive the reap" "$(cat "$STATE/log")"
: > "$STATE/log"; out=$(bash "$POOL" status tf 2>&1)
printf '%s\n' "$out" | grep -q "^@11 .* repo=o/a want=1$" && printf '%s\n' "$out" | grep -q "^@12 .* repo=o/b want=1$" \
  || fail "O status must list each repo's entries with its repo" "$out"
grep -q "kill-window" "$STATE/log" && fail "O status must never retire anything" "$(cat "$STATE/log")"
ok "O reap retires an unhosted repo's entry; status reports one pool per repo"

# P: degenerate — a one-repo fleet ignores --repo for its own repo, and has no pool
# for any other; no @repo is ever written by the pool.
rm -rf "$FLEET_CONF_DIR/fleets/tf/repos"
reset_state; mkfleet; mkconf 1; printf 'FLEET_REPO="o/a"\n' >> "$FLEET_CONF_DIR/fleets/tf/conf"
warm '@11' - "$WORK/wt-a"
out=$(bash "$POOL" claim tf --repo o/b 2>&1); [ -z "$out" ] || fail "P a one-repo fleet has no pool for another repo" "$out"
out=$(bash "$POOL" claim tf --repo o/a 2>&1); [ "${out%%	*}" = '@11' ] || fail "P --repo naming the fleet's own repo must claim as before" "$out"
grep -q "@repo" "$STATE/log" && fail "P a one-repo pool must not touch @repo" "$(cat "$STATE/log")"
out=$(bash "$POOL" status tf 2>&1); printf '%s' "$out" | grep -q "repo=" && fail "P one-repo status output must be unchanged" "$out"
ok "P one-repo fleet: unchanged (no @repo, no filter, no repo= in status)"

printf '\n%s tests passed\n' "$pass"
exit 0
