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

printf '\n%s tests passed\n' "$pass"
exit 0
