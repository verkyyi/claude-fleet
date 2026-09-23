#!/bin/bash
# multirepo-e2e-selftest.sh — one fleet, two repos, end to end (issue #795).
#
# The per-slice selftests (#788–#794) each prove one piece alone. This one runs the
# whole path on ONE throwaway fleet hosting two repos, through the real scripts, and
# reads out the EPIC #787 metric "known ways work leaks across repos": each of the
# nine collision classes the planning survey found gets an assertion here, and the
# test prints `leaks: <n>/9` — 0 is the target.
#
#   setup  fleet-repo.sh add registers the second repo with NO gate (FLEET_MULTIREPO
#          is gone). Both checkouts share a basename (…/a/app, …/b/app) and the
#          fleet sets FLEET_WORKTREE_ROOT, so a worktree path keyed on the basename
#          alone would collide.
#   spawn  issue #12 in BOTH repos, a scratch in both, a no-repo session.
#   (a) PR/CI by branch name     each issue-12 row shows its OWN repo's PR.
#   (b) cleanup by bare number   A's PR merges; one cleanup tick reaps A's #12
#                                window + worktree, B's #12 window + worktree live.
#   (c) issue-number collisions  spawn dedup, the backlog's bound map and the
#                                ledger row are keyed on (repo, 12).
#   (d) scratch/origin keys      origin keys are repo-qualified and resolve back
#                                to the right repo's window.
#   (e) one MAIN per reaper      the cleanup tick runs a pass per hosted repo.
#   (f) worktree-name clash      same basename + a worktree root → two distinct
#                                worktrees, each registered to its own checkout.
#   (g) guard / trust            the base guard refuses an edit into EITHER base
#                                checkout; B's worktree is pre-trusted.
#   (h) collector/backlog/hub    `all` lists both repos' backlog and dash rows;
#                                picking B filters both to B.
#   (i) restore                  snapshot → kill → restore brings B's windows back
#                                with @repo, and the no-repo session with @norepo.
#   (z) degenerate               a one-repo fleet beside it keeps bare keys,
#                                three-field backlog rows, no repo column, and its
#                                hub in its checkout (a 2-repo fleet's hub: $HOME).
#
# Real git, a real tmux server on a PRIVATE socket (PATH shim folds every -L/-S —
# never the live server); `gh` is a stub serving per-repo PR / issue JSON through
# the caller's own --jq, the collector and pr-refresh run for real; `claude` is a
# recorder; HOME / CLAUDE_CONFIG_DIR / FLEET_CONF_DIR
# are inside the sandbox; GIT_ALLOW_PROTOCOL=file keeps every fetch off the network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { printf 'selftest: jq not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/multirepo-e2e.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/cc" "$WORK/rec" "$WORK/leases" "$WORK/tmp"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
while [ "\${1:-}" = -L ] || [ "\${1:-}" = -S ]; do shift 2; done
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# gh: per-repo JSON folded by the caller's own --jq — o/alpha#101 MERGED at A's
# issue-12 head, o/beta#201 OPEN (red CI) on B's own issue-12, an open-issue list per
# repo, each with its own #12. Everything else fails.
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
repo=""; jqx=""; prev=""
for a in "$@"; do
  { [ "$prev" = --repo ] || [ "$prev" = -R ]; } && repo="$a"
  [ "$prev" = --jq ] && jqx="$a"
  prev="$a"
done
out() { if [ -n "$jqx" ]; then jq -r "$jqx"; else cat; fi; }
iss() { printf '{"number":%s,"title":"%s","labels":[],"assignees":[],"milestone":null}' "$1" "$2"; }
case "$1 $2" in
  "pr view")
    [ "$repo" = o/alpha ] && [ "$3" = 101 ] || exit 1
    printf 'MERGED\t%s\tissue-12\t-\t2020-01-01T00:00:00Z\n' "$(cat "$GH_SHA_A")" ;;
  "pr list")
    case "$repo" in
      o/alpha) printf '[{"number":101,"headRefName":"issue-12","state":"MERGED","isDraft":false,"statusCheckRollup":[],"mergeCommit":{"oid":"%s"}}]' \
                 "$(cat "$GH_SHA_A" 2>/dev/null)" | out ;;
      o/beta)  printf '[{"number":201,"headRefName":"issue-12","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}],"mergeCommit":null}]' | out ;;
      *)       printf '[]' | out ;;
    esac ;;
  "issue list")
    case "$repo" in
      o/alpha) printf '[%s,%s]' "$(iss 12 'ALPHA twelve')" "$(iss 30 'ALPHA thirty')" | out ;;
      o/beta)  printf '[%s,%s]' "$(iss 12 'BETA twelve')" "$(iss 31 'BETA thirty-one')" | out ;;
      o/solo)  printf '[%s,%s]' "$(iss 12 'SOLO twelve')" "$(iss 5 'SOLO five')" | out ;;
      *)       printf '[]' | out ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/ccquota"
# The agent: records its argv and what its OWN window said at launch, then idles.
cat > "$WORK/bin/claude" <<EOF
#!/bin/bash
w=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
printf '%s\n' "\$*" > "$WORK/rec/\$w.args"
tmux display-message -p -t "\$TMUX_PANE" '#{@repo}|#{@norepo}|#{@worktree}' > "$WORK/rec/\$w.seen"
exec sleep 300
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh" "$WORK/bin/claude" "$WORK/bin/ccquota"

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export PATH="$WORK/bin:$PATH" HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/cc"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export FLEET_GLOBAL_MAX_SESSIONS=999 FLEET_PRESPAWN_DEDUP=0 FLEET_SCRATCH_POOL=0
export FLEET_DISPATCH_LEASE_DIR="$WORK/leases" FLEET_LAND_LEASE_DIR="$WORK/leases"
export FLEET_TRASH_SWEEP_BUDGET=0 GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0
export GH_LOG="$WORK/gh.log" GH_SHA_A="$WORK/sha-a"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_MODEL FLEET_AGENT FLEET_SESSION CF_REPO
mkdir -p "$FLEET_CONF_DIR"
. "$BIN/fleet-lib.sh"

FAILS=0
LEAKS=""   # the classes with at least one failed assertion
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
ok()   { printf 'ok   %s\n' "$*"; }
leak() {   # $1=class letter, rest=message — a failure that is also a cross-repo leak
  local c="$1"; shift; fail "($c) $*"
  case " $LEAKS " in *" $c "*) ;; *) LEAKS="$LEAKS $c" ;; esac
}
chk()  { if [ "$3" = "$4" ]; then ok "($1) $2"; else leak "$1" "$2: expected [$4], got [$3]"; fi; }
has()  { case "$3" in *"$4"*) ok "($1) $2" ;; *) leak "$1" "$2: [$4] not in: $3" ;; esac; }
hasnt(){ case "$3" in *"$4"*) leak "$1" "$2: [$4] found in: $3" ;; *) ok "($1) $2" ;; esac; }

g() { git -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
mkrepo() {   # $1=dir $2=owner/name — a base checkout with an origin/master
  mkdir -p "$(dirname "$1")"
  g init -q "$1" && g -C "$1" commit -q --allow-empty -m init && g -C "$1" branch -q -M master \
    && g -C "$1" remote add origin "https://github.com/$2.git" \
    && g -C "$1" update-ref refs/remotes/origin/master HEAD
}
MA="$WORK/a/app"; MB="$WORK/b/app"; MD="$WORK/d/solo"
mkrepo "$MA" o/alpha; mkrepo "$MB" o/beta; mkrepo "$MD" o/solo
WT="$WORK/wt.noindex"

S=ft; D=fd
mkdir -p "$FLEET_CONF_DIR/fleets/$S" "$FLEET_CONF_DIR/fleets/$D"
cat > "$FLEET_CONF_DIR/fleets/$S/conf" <<EOF
FLEET_REPO="o/alpha"
FLEET_MAIN="$MA"
FLEET_BASE_BRANCH="master"
FLEET_WORKTREE_ROOT="$WT"
FLEET_CLEANUP_MERGED_GRACE=0
FLEET_REAP_MIN_AGE=0
EOF
printf 'FLEET_REPO="o/solo"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$MD" > "$FLEET_CONF_DIR/fleets/$D/conf"

"$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s "$S" -n plan -x 200 -y 50 || { echo "could not start isolated tmux" >&2; exit 1; }
tmux new-session -d -s "$D" -n plan -x 200 -y 50

opt()   { tmux display-message -p -t "$1" "#{$2}"; }
has_win() { tmux list-windows -a -F '#{window_id}' | grep -qxF "$1"; }
registered() { git -C "$1" worktree list --porcelain | grep -qxF "worktree $2"; }
wait_rec() { local _; for _ in $(seq 1 100); do [ -s "$WORK/rec/$1.seen" ] && return 0; sleep 0.1; done; return 1; }
win_of() {   # $1=sess $2=repo $3=issue → the window id
  tmux list-windows -t "$1" -F '#{@repo} #{@issue} #{window_id}' | awk -v r="$2" -v n="$3" '$1==r && $2==n {print $3; exit}'
}
newest() { tmux list-windows -t "$1" -F '#{window_id}' | tail -1; }
spawn()  { bash "$BIN/dash-issue-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"; }
raw()    { bash "$BIN/dash-raw-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"; }
inpane() { local w="$1"; shift; TMUX="$SOCK,1,0" TMUX_PANE="$(opt "$w" pane_id)" "$@"; }
strip()  { sed $'s/\x1b\\[[0-9;]*m//g'; }

# ==== setup: the second repo, with no gate ==========================================
out=$(bash "$BIN/fleet-repo.sh" add --session "$S" o/beta "$MB" --base master 2>&1) \
  && ok "setup: fleet-repo.sh add o/beta — no FLEET_MULTIREPO needed" \
  || fail "setup: fleet-repo.sh add refused: $out"
[ "$(fleet_repos "$S" | tr '\n' ' ')" = "o/alpha o/beta " ] || fail "setup: fleet_repos: $(fleet_repos "$S")"
lbl=$(tmux show-option -gqv @fleet_repo_label)
[ "$lbl" = all ] && ok "setup: the footer reads '$S · all'" || fail "setup: footer label [$lbl]"

hub_cwd() { HUB_SESSION="$1" HUB_PRINT_CMD=cwd bash "$BIN/hub-session.sh" 2>/dev/null; }
[ "$(hub_cwd "$S")" = "$HOME" ] && ok "setup: a 2-repo fleet's hub opens in \$HOME (no main repo)" \
  || fail "setup: 2-repo hub cwd [$(hub_cwd "$S")]"
[ "$(hub_cwd "$D")" = "$MD" ] && ok "(z) a one-repo fleet's hub still opens in its checkout" \
  || fail "(z) one-repo hub cwd [$(hub_cwd "$D")]"

# ==== spawn: #12 in both repos, a scratch in both, a no-repo session ================
spawn 12 "$S" --repo o/alpha || fail "spawn A#12: $(cat "$WORK/err")"
spawn 12 "$S" --repo o/beta  || fail "spawn B#12: $(cat "$WORK/err")"
wA=$(win_of "$S" o/alpha 12); wB=$(win_of "$S" o/beta 12)
[ -n "$wA" ] && [ -n "$wB" ] || { fail "spawn: missing a #12 window (A=$wA B=$wB)"; tmux list-windows -t "$S" -F '#{window_name} #{@repo} #{@issue}' >&2; exit 1; }
raw --repo o/alpha "$S" || fail "scratch A: $(cat "$WORK/err")"; sA=$(newest "$S")
raw --repo o/beta  "$S" || fail "scratch B: $(cat "$WORK/err")"; sB=$(newest "$S")
raw --no-repo "$S"      || fail "no-repo: $(cat "$WORK/err")";   wN=$(newest "$S")
nsid=$(opt "$wN" @norepo_sid)
for w in "$wA" "$wB" "$sA" "$sB" "$wN"; do wait_rec "$w" || { fail "spawn: $w never reached claude"; (cd "$(opt "$w" @worktree)" && inpane "$w" bash -x "$BIN/fleet-claude.sh" hi 2>&1 | tail -40) >&2; tmux display-message -p -t "$w" "#{pane_start_command}" >&2; exit 1; }; done

# ==== (f) worktree-name clash =========================================================
tA=$(opt "$wA" @worktree); tB=$(opt "$wB" @worktree)
[ "$tA" != "$tB" ] && ok "(f) A#12 and B#12 get distinct worktrees" || leak f "A#12 and B#12 share a worktree: $tA"
registered "$MA" "$tA" && ok "(f) A#12's worktree registered to A" || leak f "A#12's worktree $tA not registered to A"
registered "$MB" "$tB" && ok "(f) B#12's worktree registered to B" || leak f "B#12's worktree $tB not registered to B"
chk f "B#12's worktree is B's checkout" "$(git -C "$tB" remote get-url origin 2>/dev/null)" https://github.com/o/beta.git
chk f "the launcher in B#12 saw its own repo + worktree" "$(cat "$WORK/rec/$wB.seen" 2>/dev/null)" "o/beta||$tB"
ssA=$(opt "$sA" @worktree); ssB=$(opt "$sB" @worktree)
[ -n "$ssA" ] && [ "$ssA" != "$ssB" ] && ok "(f) the two scratches get distinct worktrees" || leak f "scratch worktrees collide: [$ssA] [$ssB]"
registered "$MB" "$ssB" && ok "(f) B's scratch registered to B" || leak f "B's scratch $ssB not registered to B"

# ==== (g) guard / trust ================================================================
guard() {   # $1=window $2=file → the guard's exit code for a Write there
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$2" \
    | inpane "$1" env FLEET_LIB="$BIN/fleet-lib.sh" python3 "$BIN/../hooks/base-readonly-guard.py" >/dev/null 2>&1
}
guard "$wA" "$MB/x.txt"; chk g "an A pane cannot write into B's base checkout" "$?" 2
guard "$wB" "$MA/x.txt"; chk g "a B pane cannot write into A's base checkout" "$?" 2
guard "$wB" "$tB/x.txt"; chk g "a B pane can write its own worktree" "$?" 0
grep -qF "\"$tB\"" "$WORK/cc/.claude.json" 2>/dev/null && ok "(g) B's worktree pre-trusted" \
  || leak g "B's worktree not pre-trusted: $(cat "$WORK/cc/.claude.json" 2>/dev/null)"

# ==== (c) issue-number collisions: spawn dedup =========================================
spawn 12 "$S" --repo o/beta
chk c "a second B#12 spawn is deduped" "$(tmux list-windows -t "$S" -F '#{@issue}' | grep -cx 12)" 2
chk c "A#12 and B#12 keys differ" "$(fleet_window_key "$S" "$wA") $(fleet_window_key "$S" "$wB")" "o/alpha#12 o/beta#12"

# ==== (d) scratch/origin keys ===========================================================
kB=$(inpane "$wB" fleet_origin_key); kS=$(inpane "$sB" fleet_origin_key)
chk d "B#12's origin key is repo-qualified" "$kB" o-beta:issue-12
case "$kS" in o-beta:scratch-*) ok "(d) B's scratch key is repo-qualified" ;; *) leak d "B's scratch key: [$kS]" ;; esac
chk d "o-beta:issue-12 resolves to B's window" "$(fleet_win_for_key o-beta:issue-12 "$S")" "$wB"
chk d "o-alpha:issue-12 resolves to A's window" "$(fleet_win_for_key o-alpha:issue-12 "$S")" "$wA"
chk d "B's scratch key resolves to B's scratch" "$(fleet_win_for_key "$kS" "$S")" "$sB"

# ==== (a) PR/CI by branch name ==========================================================
# The prmaps pr-refresh writes, one per repo: A's #12 merged, B's #12 open.
git -C "$tA" rev-parse HEAD > "$GH_SHA_A"
# One tick of each real daemon: the collector (sessmap, every window's git_<key>,
# every hosted repo's issues cache) and pr-refresh (every hosted repo's prmap).
collect() {
  FLEET_ACCOUNTS_DIR="$WORK/accounts" FLEET_NOTIFY_CMD="" GH_TTL=0 \
    bash "$BIN/tmux-dash-collect.sh" >"$WORK/collect.out" 2>&1
  bash "$BIN/tmux-pr-refresh.sh" >"$WORK/refresh.out" 2>&1
}
collect
dash() { FLEET_SESSION="$S" FZF_COLUMNS=160 bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null | tail -n +2 | strip; }
rows=$(dash)
rA=$(printf '%s\n' "$rows" | grep -F "$(opt "$wA" window_name)" | head -1)
rB=$(printf '%s\n' "$rows" | grep -F "$(opt "$wB" window_name)" | head -1)
has   a "A#12's row shows A's PR merged" "$rA" "merged"
hasnt a "A#12's row shows no B PR"     "$rA" "#201"
has   a "B#12's row shows B's PR"      "$rB" "#201"
hasnt a "B#12's row shows no A PR"     "$rB" "#101"
rN=$(printf '%s\n' "$rows" | grep -F "$(opt "$wN" window_name)" | head -1)
hasnt a "the no-repo row shows no PR"  "$rN" "#"

# ==== (h) collector/backlog/hub: `all` and a picked repo ===============================
backlog() { FLEET_SESSION="$1" bash "$BIN/tmux-issues-rows.sh" all 2>/dev/null; }
f14() { tail -n +2 | awk -F '\037' '{ print $1 "|" $4 }' | tr '\n' ' '; }
chk h "backlog under all: both repos, bound #12s hidden" "$(backlog "$S" | f14)" "30|o/alpha 31|o/beta "
has h "dash under all: A's scratch listed" "$rows" "$(opt "$sA" window_name)"
has h "dash under all: B's scratch listed" "$rows" "$(opt "$sB" window_name)"
fleet_current_repo_set "$S" o/beta
chk h "the footer follows the pick" "$(tmux show-option -gqv @fleet_repo_label)" beta
chk h "backlog with B picked: B only" "$(backlog "$S" | f14)" "31|o/beta "
rows=$(dash)
has   h "dash with B picked: B#12 shown"  "$rows" "$(opt "$wB" window_name)"
hasnt h "dash with B picked: A#12 hidden" "$rows" "$(opt "$wA" window_name)"
hasnt h "dash with B picked: A's scratch hidden" "$rows" "$(opt "$sA" window_name)"
fleet_current_repo_set "$S" all

# ==== (b)+(e) A's PR merges → one cleanup tick ==========================================
old=$(( $(date +%s) - 7200 )); now=$(date +%s)
for w in "$wA" "$wB"; do
  tmux set-option -w -t "$w" @claude_state done
  tmux set-option -w -t "$w" @claude_state_ts "$old"
done
# The notice the daemon shows one tick before it reaps (#565) — already served on A.
tmux set-option -w -t "$wA" @reap_key "merged:101:$(cat "$GH_SHA_A")"
tmux set-option -w -t "$wA" @reap_due $((now - 5))
tmux set-option -w -t "$wA" @reap_seen "$now"
tmux set-option -w -t "$wA" @reap_state_ts "$old"
export FLEET_HISTORY_LEDGER="$WORK/ledger.tsv"
log=$(bash "$BIN/fleet-cleanup-daemon.sh" "$S" 2>&1)
unset FLEET_HISTORY_LEDGER
has_win "$wA" && leak b "A#12's window survived A's merge: $log" || ok "(b) A#12's window reaped on A's merge"
registered "$MA" "$tA" && leak b "A#12's worktree still registered" || ok "(b) A#12's worktree removed"
has_win "$wB" && ok "(b) B#12's window untouched" || leak b "B#12's window was killed by A's merge"
[ -d "$tB" ] && registered "$MB" "$tB" && ok "(b) B#12's worktree untouched" || leak b "B#12's worktree lost to A's merge"
has_win "$sB" && ok "(b) B's scratch untouched" || leak b "B's scratch was killed"
has_win "$wN" && ok "(b) the no-repo session untouched" || leak b "the no-repo session was killed"
has e "the tick ran a pass for A" "$log" "PR #101"
has e "the tick ran a pass for B" "$log" "[o/beta]"
hasnt e "no pass reaped under B's MAIN" "$log" "PR #201"

# (c) the backlog's bound map and the ledger: A#12 is free again, B#12 still bound.
chk c "backlog after the merge: A#12 back, B#12 still bound" "$(backlog "$S" | f14)" "12|o/alpha 30|o/alpha 31|o/beta "

# ==== (i) restore round-trip =============================================================
bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1
MAP="$FLEET_CONF_DIR/fleets/$S/restore.map"
rowB=$(awk -F'\t' -v p="$tB" '$1=="WIN" && $3==p' "$MAP" 2>/dev/null)
chk i "B#12's snapshot row carries its repo" "$(printf '%s' "$rowB" | awk -F'\t' '{print $16}')" o/beta
nameB=$(opt "$wB" window_name); nameS=$(opt "$sB" window_name); nameN=$(opt "$wN" window_name)
tmux kill-window -t "$wB"; tmux kill-window -t "$sB"; tmux kill-window -t "$wN"
rm -f "$WORK/rec/"*
bash "$BIN/fleet-restore.sh" >/dev/null 2>&1
by_name() { tmux list-windows -t "$S" -F '#{window_name}	#{window_id}' | awk -F'\t' -v n="$1" '$1==n {print $2; exit}'; }
rB=$(by_name "$nameB"); rS=$(by_name "$nameS"); rN=$(by_name "$nameN")
[ -n "$rB" ] && chk i "B#12 restored with @repo" "$(opt "$rB" @repo)|$(opt "$rB" @worktree)" "o/beta|$tB" || leak i "B#12 not restored"
[ -n "$rS" ] && chk i "B's scratch restored with @repo" "$(opt "$rS" @repo)" o/beta || leak i "B's scratch not restored"
if [ -n "$rN" ]; then
  chk i "the no-repo session restored as no-repo" "$(opt "$rN" @norepo)|$(opt "$rN" @repo)" "1|"
  wait_rec "$rN"; has i "…resumed by its own id" "$(cat "$WORK/rec/$rN.args" 2>/dev/null)" "--resume $nsid"
else leak i "the no-repo session not restored"; fi
[ -n "$rB" ] && { wait_rec "$rB"; chk i "restored B#12's launcher saw B" "$(cut -d'|' -f1 "$WORK/rec/$rB.seen" 2>/dev/null)" o/beta; }

# ==== (z) degenerate: a one-repo fleet beside it =========================================
spawn 12 "$D" || fail "(z) one-repo spawn: $(cat "$WORK/err")"
wD=$(tmux list-windows -t "$D" -F '#{@issue} #{window_id}' | awk '$1==12 {print $2; exit}')
if [ -n "$wD" ]; then
  case "$(opt "$wD" window_name)" in *·*) fail "(z) one-repo window name carries a repo tag: $(opt "$wD" window_name)" ;;
    *) ok "(z) one-repo window name has no repo tag" ;; esac
  [ "$(inpane "$wD" fleet_origin_key)" = issue-12 ] && ok "(z) one-repo origin key is bare" || fail "(z) one-repo origin key: $(inpane "$wD" fleet_origin_key)"
  case "$(opt "$wD" @worktree)" in "$WORK/d/solo-issue-12") ok "(z) one-repo worktree in the sibling layout" ;;
    *) fail "(z) one-repo worktree: $(opt "$wD" @worktree)" ;; esac
else fail "(z) no one-repo #12 window"; fi
zrows=$(backlog "$D" | tail -n +2)
[ -n "$zrows" ] && [ "$(printf '%s\n' "$zrows" | awk -F '\037' '{print NF}' | sort -u)" = 3 ] \
  && ok "(z) one-repo backlog rows keep three fields" || fail "(z) one-repo backlog rows: $zrows"
bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1
chk z "one-repo restore rows carry no repo column" "$(awk -F'\t' '$1=="WIN" && NF>15' "$FLEET_CONF_DIR/fleets/$D/restore.map" 2>/dev/null | wc -l | tr -d ' ')" 0
[ -e "$FLEET_CONF_DIR/fleets/$D/repos" ] && fail "(z) the one-repo fleet grew a repos/ dir" || ok "(z) the one-repo fleet has no repos/ dir"

# ==== the readout ===========================================================================
n=0; for c in $LEAKS; do [ "$c" = z ] || n=$((n+1)); done
printf 'leaks: %s/9 known ways work leaks across repos%s\n' "$n" "${LEAKS:+ (classes:$LEAKS)}"
[ "$FAILS" = 0 ] && { printf 'PASS multirepo-e2e-selftest\n'; exit 0; }
printf '%s failure(s)\n' "$FAILS" >&2; exit 1
