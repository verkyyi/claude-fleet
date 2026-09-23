#!/bin/bash
# forkless-hotpath-selftest.sh — pins issue #888: the background hot paths answer
# with shell builtins where they used to fork a `tr` / `date` / `cut` / `sed` /
# `dirname` / `cat`, and they answer EXACTLY what the forked version answered.
#
# Two halves, because either alone lets the regression back in:
#   EQUIVALENCE  every rewritten helper is run against the original pipeline it
#                replaced, over a corpus that includes the awkward inputs (empty,
#                no separator, trailing slashes, non-ASCII, empty tab fields).
#   BUDGET       the two producers that dominated the machine's exec rate are run
#                under a counting PATH shim and must not exec the tools they no
#                longer need: tmux-status.sh (every 5s per attached client) and
#                tmux-pr-refresh.sh's per-window @prci loop (every 15s, per window).
#                The pr-refresh half also replays a window list through a fake tmux
#                and checks every glyph it paints, so a builtin rewrite that drifts
#                from `sed`/`cut` shows up as a wrong @prci, not just a count.
#
# No live tmux, no network: tmux and gh are shims, TMPDIR is a sandbox.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; CHECKS=$((CHECKS+1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/forkless-selftest.XXXXXX") || exit 2
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT
TAB=$(printf '\t'); US=$(printf '\037')

# ================================================================ EQUIVALENCE
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-daemon-lib.sh"

ref_norm() { printf '%s' "$1" | sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##; s#/+$##'; }
ref_slug() { printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'; }
while IFS= read -r v; do
  eq "fleet_norm_repo [$v]" "$(ref_norm "$v")" "$(fleet_norm_repo "$v")"
  eq "fleet_slug [$v]"      "$(ref_slug "$v")" "$(fleet_slug "$v")"
done <<'EOF'

verkyyi/claude-fleet
git@github.com:verkyyi/claude-fleet.git
git@github.com
https://github.com/o/r.git
https://github.com/o/r/
https://github.com/o/r.git/
https://github.com
http://host/o/r.git//
ssh://git@github.com/o/r.git
git@h:https://a/b
o/r.git.git
.git
/
///
x//y
a b/c
café/x
ümlaut
/Users/v/p q/24haowan-monorepo
GuangZhouShanyouGame/24haowan-monorepo
o/r+1
EOF
nl_in="a/b
c.git"
eq "fleet_norm_repo keeps sed's per-line edits for a multi-line value" "$(ref_norm "$nl_in")" "$(fleet_norm_repo "$nl_in")"

# sessmap lookups: field N of the first row whose field 1 matches — empty fields kept
FLEET_C="$WORK/sm"; mkdir -p "$FLEET_C/global"
printf 'a\tsa\tra\nb\t\trb\nc\tsc\nd\n\tx\ty\ne\tse\tre\tmore\nlast\tsl\trl' > "$FLEET_C/global/sessmap"
for s in a b c d e '' last zz; do
  eq "fleet_slug_cached [$s]" "$(awk -F'\t' -v s="$s" '$1==s{print $2; exit}' "$FLEET_C/global/sessmap")" "$(fleet_slug_cached "$s")"
  eq "fleet_repo_cached [$s]" "$(awk -F'\t' -v s="$s" '$1==s{print $3; exit}' "$FLEET_C/global/sessmap")" "$(fleet_repo_cached "$s")"
done
unset FLEET_C

for u in collect quotawatch base-sync issue-bridge worktree-autoclean ledger-watch 'X-y_z9' ''; do
  eq "_fleet_daemon_key [$u]" "$(printf '%s' "$u" | tr 'a-z-' 'A-Z_')" "$(_fleet_daemon_key "$u")"
done

# fleet_now: unpinned = date; pinned = one shared clock that still advances; a
# child process never inherits the pin, even when it is exported.
d0=$(date +%s); n0=$(fleet_now)
[ "$n0" -ge "$d0" ] && [ "$n0" -le $((d0 + 1)) ] || fail "unpinned fleet_now must be date +%s" "$d0 vs $n0"; CHECKS=$((CHECKS+1))
fleet_now_pin
eq "a pinned fleet_now answers the pin" "$_FLEET_NOW" "$(fleet_now)"
leak=$(_FLEET_NOW=5 _FLEET_NOW_PID=$$ _FLEET_NOW_S0=0 bash -c ". '$BIN/fleet-daemon-lib.sh'; fleet_now")
[ "$leak" -gt 1000000000 ] || fail "an exported pin leaked into a child process" "$leak"; CHECKS=$((CHECKS+1))
_FLEET_NOW=$(( _FLEET_NOW - 100 ))   # the pin plus $SECONDS since pinning
adv=$(fleet_now); [ "$adv" -le $(( $(date +%s) - 99 )) ] && [ "$adv" -ge $(( $(date +%s) - 101 )) ] \
  || fail "a pinned clock must advance with \$SECONDS from its pin" "$adv"
CHECKS=$((CHECKS+1)); unset _FLEET_NOW _FLEET_NOW_PID _FLEET_NOW_S0

# tmux-status.sh's MEM figure: builtin tenths-rounding vs awk's printf "%.1f"
eval "$(sed -n '/^mb_to_g1()/,/^}/p' "$BIN/tmux-status.sh")"
command -v mb_to_g1 >/dev/null || fail "tmux-status.sh no longer defines mb_to_g1"
mine=$(for mb in $(seq 0 6000) 32767 32768 65536 99999 131072; do printf '%s ' "$mb"; mb_to_g1 "$mb"; echo; done)
ref=$(printf '%s\n' "$mine" | awk '{printf "%s %.1f\n", $1, $1/1024}')
[ "$mine" = "$ref" ] || fail "mb_to_g1 disagrees with awk %.1f" "$(diff <(printf '%s\n' "$ref") <(printf '%s\n' "$mine") | head -5)"
CHECKS=$((CHECKS+1))

# ================================================================ BUDGET shims
# Counting shims for the tools the hot paths must no longer exec: each logs its
# name, then runs the real binary (resolved BEFORE the shim dir goes on PATH).
mkdir -p "$WORK/bin"
for t in date tr cut sed dirname basename uname cat; do
  real=$(command -v "$t") || continue
  printf '#!/bin/sh\necho %s >> "%s/exec.log"\nexec %s "$@"\n' "$t" "$WORK" "$real" > "$WORK/bin/$t"
  chmod +x "$WORK/bin/$t"
done
count() { local n; n=$(grep -cx "$1" "$WORK/exec.log" 2>/dev/null); printf '%s' "${n:-0}"; }

# ---------------------------------------------------------------- tmux-status.sh
TMPD="$WORK/tmp"; G="$TMPD/.claude-dash/global"; mkdir -p "$G" "$WORK/acc"
now=$(date +%s)
for u in $(fleet_daemon_unit_names); do printf '%s\n' "$now" > "$G/$u.tick"; done
printf '%s\n' $((now - 10000)) > "$G/cleanup.tick"            # one overdue unit
printf '5h 1.0M · 7d 2.0M' > "$G/usage"
printf '%s\t42%% of weekly' "$now" > "$G/ratelimit"
printf '%s\n' $((now - 1000)) > "$G/account.quota.ts"          # stale watch → ⚠ quota stale
printf '0\t0\n' > "$G/account.quota.empty"
: > "$WORK/exec.log"
out=$(TMPDIR="$TMPD/" FLEET_LIVE_ROOT="$BIN/.." FLEET_ACCOUNTS_DIR="$WORK/acc" CCQUOTA_HUB_URL=http://127.0.0.1:9 \
      PATH="$WORK/bin:$PATH" bash "$BIN/tmux-status.sh" 2>&1) || fail "tmux-status.sh exited non-zero" "$out"
case "$out" in *"CPU "*"MEM "*"5h 1.0M · 7d 2.0M"*) ;; *) fail "tmux-status.sh lost a segment" "$out" ;; esac; CHECKS=$((CHECKS+1))
case "$out" in *"⚠ quota stale 16m"*) ;; *) fail "tmux-status.sh: the stale quota watch must still show" "$out" ;; esac; CHECKS=$((CHECKS+1))
case "$out" in *"⚠ daemon stale cleanup"*) ;; *) fail "tmux-status.sh: the overdue unit must still show" "$out" ;; esac; CHECKS=$((CHECKS+1))
[ "$(count date)" -le 1 ] || fail "tmux-status.sh forked date $(count date)× — one pinned clock per render (#888)"; CHECKS=$((CHECKS+1))
for t in tr cut dirname uname cat; do
  eq "tmux-status.sh execs no $t (#888)" 0 "$(count "$t")"
done

# ---------------------------------------------------------------- tmux-pr-refresh.sh
# One fake fleet `s1` on fake/repo; gh fails (offline — the loop reads the prmap we
# seed); tmux replays a window list and logs every set-window-option.
CONFD="$WORK/conf"; mkdir -p "$CONFD/fleets/s1"
printf 'FLEET_REPO="fake/repo"\n' > "$CONFD/fleets/s1/conf"
C="$TMPD/.claude-dash"; FD="$C/fleets/fake-repo"; mkdir -p "$FD"
printf 's1\tfake-repo\tfake/repo\n' > "$G/sessmap"
printf '%s\n' \
  "issue-1${TAB}#1${TAB}OPEN${TAB}✓${TAB}ready${TAB}" \
  "issue-2${TAB}#2${TAB}OPEN${TAB}✗${TAB}ready${TAB}" \
  "issue-3${TAB}#3${TAB}OPEN${TAB}✓${TAB}behind${TAB}" \
  "issue-4${TAB}#4${TAB}OPEN${TAB}✓${TAB}draft${TAB}" \
  "feat${TAB}#5${TAB}OPEN${TAB}✓${TAB}conflict${TAB}" \
  "issue-6${TAB}#6${TAB}MERGED${TAB}✓${TAB}${TAB}abc123" \
  "issue-8${TAB}#8${TAB}OPEN${TAB}✓${TAB}${TAB}" > "$FD/prmap"
printf '%s\n' "$now" > "$FD/prmap.ts"
gitc() { k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s\tx\n' "$2" > "$G/git_$k"; }
: > "$WORK/wlist"
win() { printf 's1%s%s%s%s%s%s\n' "$US" "s1:$1" "$US" "$2" "$US" "$4" >> "$WORK/wlist"; gitc "$2" "$3"; }
#    idx path          branch          current @prci
win 1 /w/one          issue-1+2       ''
win 2 /w/two          issue-2+3       ''
win 3 /w/three        issue-3-2       ''
win 4 "/w/fo ur"      issue-4+1-7     ''
win 5 /w/five         feat-2024       ''
win 6 /w/six          issue-6         '✓'
win 7 /w/seven        -               ''
win 8 /w/eight        issue-8-3       ''
win 10 /w/ten          issue-3         ''   # exact spelling wins (#792)
win 9 /w/nine         issue-9         ''   # no such PR, exact or stripped
cat > "$WORK/bin/tmux" <<SHIM
#!/bin/sh
case " \$* " in
  *" has-session "*) exit 0 ;;
  *" list-windows "*) while IFS= read -r l; do printf '%s\\n' "\$l"; done < "$WORK/wlist" ;;   # not \`cat\`: it is being counted
  *" set-window-option "*) printf '%s\n' "\$*" >> "$WORK/tmux.log" ;;
esac
exit 0
SHIM
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"
: > "$WORK/exec.log"; : > "$WORK/tmux.log"
out=$(TMPDIR="$TMPD/" FLEET_CONF_DIR="$CONFD" FLEET_LIVE_ROOT="$BIN/.." PATH="$WORK/bin:$PATH" \
      bash "$BIN/tmux-pr-refresh.sh" 2>&1 </dev/null) || fail "tmux-pr-refresh.sh exited non-zero" "$out"
prci() { awk -v w="s1:$1" '$5==w && $6=="@prci" {print $7; f=1} END{if(!f) print "<unset>"}' "$WORK/tmux.log"; }
eq "@prci: +N stripped → green + ready"                 '✓'      "$(prci 1)"
eq "@prci: +N suffix stripped → red CI"                 '✗'      "$(prci 2)"
eq "@prci: -N suffix stripped → green but behind"       '✓↑'     "$(prci 3)"
eq "@prci: +N-M stripped (path with a space) → draft"   '✓d'     "$(prci 4)"
eq "@prci: no exact row → the stripped spelling matches" '✓!'    "$(prci 5)"
eq "@prci: MERGED clears the glyph"                     ''       "$(prci 6)"
eq "@prci: no branch, glyph already empty → untouched"  '<unset>' "$(prci 7)"
eq "@prci: -N stripped; EMPTY readiness stays empty → ✓" '✓'     "$(prci 8)"
eq "@prci: no PR, glyph already empty → untouched"      '<unset>' "$(prci 9)"
eq "@prci: a clean issue-N matches exactly (#792)"      '✓↑'     "$(prci 10)"
for t in cut sed tr dirname basename cat; do
  eq "tmux-pr-refresh.sh execs no $t (#888)" 0 "$(count "$t")"
done
[ "$(count date)" -le 2 ] || fail "tmux-pr-refresh.sh forked date $(count date)× — one pinned clock per run (#888)"; CHECKS=$((CHECKS+1))

printf 'forkless-hotpath-selftest: OK (%d checks) — builtins where the hot paths forked, same answers (issue #888)\n' "$CHECKS"
