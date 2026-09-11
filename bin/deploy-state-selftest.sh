#!/bin/bash
# deploy-state-selftest.sh — "merged" ≠ "live" (issue #541): a MERGED PR's deploy
# state, from the probe through the cache to both dash views.
#
# What is pinned:
#   • RUNS-JQ     FLEET_DEPLOY_RUNS_JQ folds a merge sha's Actions runs to ONE word:
#                 all green → live · any running → deploying · any red → failed ·
#                 no runs → unknown (red beats running).
#   • PROBE-REF   fleet_deploy_probe in FLEET_DEPLOY_REF mode against a real temp
#                 git repo: an ancestor of HEAD → live, anything else → unknown, and
#                 never a network call. Feature off → "" (rc 0).
#   • PROBE-GH    actions mode routes through `gh api … --jq`; a failing gh (or a
#                 nonsense answer) is rc 1 with NO verdict, so a transient error
#                 can never downgrade a cached state.
#   • PRODUCER    bin/tmux-pr-refresh.sh (targeted `--repo` kick, fake gh/tmux)
#                 writes fleets/<slug>/deploy_<sha> = `<state>\t<epoch>` for the
#                 MERGED rows of a fleet that sets a knob; `live` is terminal (never
#                 re-probed); actions mode is TTL-gated; the newest-20 cap holds; a
#                 fleet with neither knob writes NOTHING.
#   • DASH        the live PR cell: `live` (green) / `deploy…` / `deploy✗` / `merged`
#                 (no verdict), a 5-field legacy prmap line still renders, and the
#                 OPEN-PR `#N✓` decoration survived the 6th field.
#   • LANDED      the ⌃t list's last column is `dep` (`live` / `…` / `✗` / `·`) and
#                 resolves the merge sha by PR NUMBER through prmap — the ledger's own
#                 sha is the pre-squash worktree HEAD and must not be used.
#
# Fully hermetic: gh/tmux are PATH shims, git runs on a throwaway repo under $WORK,
# every cache lands under TMPDIR=$WORK. No network, no live tmux. The RUNS-JQ block
# needs the system `jq` (skipped with a note without it, like pr-refresh-jq-selftest);
# everything else runs regardless. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
REFRESH="$BIN/tmux-pr-refresh.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
HIST="$BIN/fleet-history.sh"
for f in "$LIB" "$REFRESH" "$ROWS" "$HIST"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { printf 'deploy-state-selftest: git absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"                          # FLEET_C → $WORK/.claude-dash
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"
unset FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK FLEET_REPO FLEET_SESSION 2>/dev/null || true
C="$WORK/.claude-dash"; mkdir -p "$C/global" "$C/fleets/fake-repo" "$WORK/conf/fleets/s1" "$WORK/bin" "$WORK/api"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }

# shellcheck source=/dev/null
. "$LIB"
[ -n "${FLEET_DEPLOY_RUNS_JQ:-}" ] || fail "FLEET_DEPLOY_RUNS_JQ not defined by fleet-lib.sh (issue #541)"
command -v fleet_deploy_probe >/dev/null 2>&1 || fail "fleet_deploy_probe not defined by fleet-lib.sh (issue #541)"

# ============================================================ RUNS-JQ (needs jq)
if command -v jq >/dev/null 2>&1; then
  run() { printf '{"status":"%s","conclusion":%s}' "$1" "$2"; }   # status, conclusion(json)
  runs() { local j="" e; for e in "$@"; do j="${j:+$j,}$e"; done; printf '{"workflow_runs":[%s]}' "$j"; }
  fold() { printf '%s' "$1" | jq -r "$FLEET_DEPLOY_RUNS_JQ"; }
  ok=$(run completed '"success"'); sk=$(run completed '"skipped"'); nu=$(run completed '"neutral"')
  red=$(run completed '"failure"'); can=$(run completed '"cancelled"'); tmo=$(run completed '"timed_out"')
  act=$(run completed '"action_required"'); ip=$(run in_progress null); qd=$(run queued null); wt=$(run waiting null)
  eq "runs-jq: all success → live"                 live      "$(fold "$(runs "$ok" "$ok")")"
  eq "runs-jq: success + skipped + neutral → live"  live      "$(fold "$(runs "$ok" "$sk" "$nu")")"
  eq "runs-jq: one in_progress → deploying"         deploying "$(fold "$(runs "$ok" "$ip")")"
  eq "runs-jq: queued → deploying"                  deploying "$(fold "$(runs "$qd")")"
  eq "runs-jq: waiting (approval gate) → deploying" deploying "$(fold "$(runs "$ok" "$wt")")"
  eq "runs-jq: one failure → failed"                failed    "$(fold "$(runs "$ok" "$red")")"
  eq "runs-jq: cancelled → failed"                  failed    "$(fold "$(runs "$can" "$ok")")"
  eq "runs-jq: timed_out → failed"                  failed    "$(fold "$(runs "$tmo")")"
  eq "runs-jq: action_required → failed"            failed    "$(fold "$(runs "$act")")"
  eq "runs-jq: red beats running"                   failed    "$(fold "$(runs "$ip" "$red")")"
  eq "runs-jq: no runs → unknown"                   unknown   "$(fold '{"workflow_runs":[]}')"
  eq "runs-jq: missing key → unknown"               unknown   "$(fold '{}')"
else
  printf 'deploy-state-selftest: jq absent — RUNS-JQ block skipped\n'
fi

# ============================================================ PROBE-REF (real git)
REPO="$WORK/repo"
git init -q "$REPO" && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m A \
  && SHA_A=$(git -C "$REPO" rev-parse HEAD) \
  && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m B \
  && SHA_B=$(git -C "$REPO" rev-parse HEAD) || fail "could not build the temp git repo"
OTHER="$WORK/other"
git init -q "$OTHER" && git -C "$OTHER" -c user.name=t -c user.email=t@t commit -q --allow-empty -m X \
  && SHA_X=$(git -C "$OTHER" rev-parse HEAD) || fail "could not build the second temp git repo"
SHA_DEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

eq "probe-ref: an ancestor of HEAD → live"           live    "$(fleet_deploy_probe o/r "$SHA_A" "$REPO" '')"
eq "probe-ref: HEAD itself → live"                   live    "$(fleet_deploy_probe o/r "$SHA_B" "$REPO" '')"
eq "probe-ref: a sha from another repo → unknown"    unknown "$(fleet_deploy_probe o/r "$SHA_X" "$REPO" '')"
eq "probe-ref: a sha that exists nowhere → unknown"  unknown "$(fleet_deploy_probe o/r "$SHA_DEAD" "$REPO" '')"
eq "probe-ref: a ref dir that is not a repo → unknown" unknown "$(fleet_deploy_probe o/r "$SHA_A" "$WORK/nope" '')"
eq "probe: empty sha → no verdict"                   ""      "$(fleet_deploy_probe o/r '' "$REPO" '')"
eq "probe: neither knob → no verdict"                ""      "$(fleet_deploy_probe o/r "$SHA_A" '' '')"
eq "probe: an unknown check kind → no verdict"       ""      "$(fleet_deploy_probe o/r "$SHA_A" '' something)"
eq "probe-ref: ref wins over check"                  live    "$(fleet_deploy_probe o/r "$SHA_A" "$REPO" actions)"

# ============================================================ PROBE-GH (fake gh)
# fake gh: `api repos/<repo>/actions/runs?head_sha=<sha>…` → the word in $WORK/api/<sha>
# (missing file ⇒ exit 1, the transient-failure shape); `pr list` → the canned prmap
# TSV in $WORK/prmap.tsv (the --jq is gh's built-in — the shim just answers as gh would).
cat > "$WORK/bin/gh" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/gh.log"
case "\${1:-} \${2:-}" in
  "api "*) q="\$2"; sha="\${q##*head_sha=}"; sha="\${sha%%&*}"
           [ -f "$WORK/api/\$sha" ] || exit 1
           cat "$WORK/api/\$sha"; exit 0 ;;
  "pr list") cat "$WORK/prmap.tsv"; exit 0 ;;
esac
exit 0
SHIM
chmod +x "$WORK/bin/gh"
# fake tmux: no live fleet server (has-session fails) — the producer's targeted --repo
# path needs none; the dash producer's ONE call (list-windows) replays $WLIST_FILE.
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
for a in "$@"; do
  [ "$a" = list-windows ] && { cat "${WLIST_FILE:-/dev/null}"; exit 0; }
  [ "$a" = has-session ] && exit 1
done
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

printf 'live\n'      > "$WORK/api/aaaa"
printf 'deploying\n' > "$WORK/api/bbbb"
printf 'failed\n'    > "$WORK/api/cccc"
printf 'unknown\n'   > "$WORK/api/dddd"
printf 'purple monkey dishwasher\n' > "$WORK/api/eeee"
eq "probe-gh: live"      live      "$(fleet_deploy_probe fake/repo aaaa '' actions)"
eq "probe-gh: deploying" deploying "$(fleet_deploy_probe fake/repo bbbb '' actions)"
eq "probe-gh: failed"    failed    "$(fleet_deploy_probe fake/repo cccc '' actions)"
eq "probe-gh: unknown"   unknown   "$(fleet_deploy_probe fake/repo dddd '' actions)"
out=$(fleet_deploy_probe fake/repo eeee '' actions); rc=$?
eq "probe-gh: a nonsense answer → no verdict" "" "$out"; eq "probe-gh: … and rc 1" 1 "$rc"
out=$(fleet_deploy_probe fake/repo zzzz '' actions); rc=$?
eq "probe-gh: gh failing → no verdict" "" "$out"; eq "probe-gh: … and rc 1" 1 "$rc"
has "probe-gh: asks for the merge sha's runs" "$(cat "$WORK/gh.log")" "actions/runs?head_sha=aaaa"

# ============================================================ PRODUCER
printf 's1\tfake-repo\tfake/repo\n' > "$C/global/sessmap"
conf() { { printf 'FLEET_REPO="fake/repo"\n'; printf '%s\n' "$@"; } > "$WORK/conf/fleets/s1/conf"; }
FD="$C/fleets/fake-repo"
dep() { [ -f "$FD/deploy_$1" ] && cut -f1 < "$FD/deploy_$1"; }
dep_ts() { [ -f "$FD/deploy_$1" ] && cut -f2 < "$FD/deploy_$1"; }
run_refresh() { bash "$REFRESH" --repo fake/repo >"$WORK/refresh.out" 2>&1 || fail "tmux-pr-refresh.sh exited non-zero" "$(cat "$WORK/refresh.out")"; }
reset_dep() { rm -f "$FD"/deploy_* "$WORK/gh.log"; : > "$WORK/gh.log"; }

# --- ref mode: the temp repo IS the deployment ----------------------------------
printf 'issue-1\t#11\tMERGED\t✓\t\t%s\nissue-2\t#12\tMERGED\t✓\t\t%s\nissue-3\t#13\tOPEN\t✓\tready\t\nissue-4\t#14\tMERGED\t✓\t\n' \
  "$SHA_A" "$SHA_DEAD" > "$WORK/prmap.tsv"
conf "FLEET_DEPLOY_REF=\"$REPO\""
reset_dep; run_refresh
eq "producer: prmap carries the 6th field"      "$SHA_A"  "$(awk -F'\t' '$2=="#11"{print $6}' "$FD/prmap")"
eq "producer-ref: ancestor sha → live"           live      "$(dep "$SHA_A")"
eq "producer-ref: foreign sha → unknown"         unknown   "$(dep "$SHA_DEAD")"
for f in "$FD"/deploy_*; do
  case "$f" in *"deploy_$SHA_A"|*"deploy_$SHA_DEAD") : ;; *) fail "producer: only MERGED rows with a sha get a deploy file" "$(ls "$FD")" ;; esac
done
CHECKS=$((CHECKS+1))
has "producer: cache line is <state><TAB><epoch>" "$(cat "$FD/deploy_$SHA_A")" "$(printf 'live\t')"
hasnt "producer-ref: no gh api call in ref mode" "$(cat "$WORK/gh.log")" "actions/runs"
# `live` is terminal: a second tick leaves its file byte-identical, while the
# unknown sha is re-probed (ref mode re-checks every tick — one local git, cheap).
ts_live=$(dep_ts "$SHA_A"); ts_unk=$(dep_ts "$SHA_DEAD"); sleep 1
run_refresh
eq "producer: live is terminal (epoch untouched on the next tick)" "$ts_live" "$(dep_ts "$SHA_A")"
[ "$(dep_ts "$SHA_DEAD")" != "$ts_unk" ] || fail "producer-ref: an un-live sha must be re-probed every tick"
CHECKS=$((CHECKS+1))
# …and it flips to live once the deployment catches up (the ref repo gains the sha).
git -C "$OTHER" -c user.name=t -c user.email=t@t commit -q --allow-empty -m Y
SHA_Y=$(git -C "$OTHER" rev-parse HEAD)
printf 'issue-9\t#19\tMERGED\t✓\t\t%s\n' "$SHA_Y" > "$WORK/prmap.tsv"
reset_dep; run_refresh
eq "producer-ref: not yet fetched into the ref → unknown" unknown "$(dep "$SHA_Y")"
# -c user.*: this merge CREATES a commit, and a CI runner with an empty gecos has
# no identity to auto-derive (macOS does, which is why it only failed on Linux).
git -C "$REPO" fetch -q "$OTHER" && git -C "$REPO" -c user.name=t -c user.email=t merge -q --allow-unrelated-histories -m M FETCH_HEAD 2>/dev/null \
  || fail "could not merge the other repo's history into the ref repo"
run_refresh
eq "producer-ref: after the ref caught up → live" live "$(dep "$SHA_Y")"

# --- actions mode: TTL-gated gh reads ------------------------------------------
printf 'b-a\t#21\tMERGED\t✓\t\taaaa\nb-b\t#22\tMERGED\t✓\t\tbbbb\nb-c\t#23\tMERGED\t✓\t\tcccc\nb-z\t#24\tMERGED\t✓\t\tzzzz\n' > "$WORK/prmap.tsv"
conf 'FLEET_DEPLOY_CHECK="actions"'
reset_dep; run_refresh
eq "producer-gh: live"      live      "$(dep aaaa)"
eq "producer-gh: deploying" deploying "$(dep bbbb)"
eq "producer-gh: failed"    failed    "$(dep cccc)"
[ ! -f "$FD/deploy_zzzz" ] || fail "producer-gh: a failing gh read must leave NO file (nothing to downgrade to)"
CHECKS=$((CHECKS+1))
eq "producer-gh: one api read per candidate" 4 "$(grep -c 'actions/runs' "$WORK/gh.log")"
# within the TTL nothing is re-read even though the world changed…
printf 'live\n' > "$WORK/api/bbbb"; : > "$WORK/gh.log"
run_refresh
eq "producer-gh: inside the TTL → no re-read (still deploying)" deploying "$(dep bbbb)"
eq "producer-gh: inside the TTL → only the never-answered sha is retried" 1 "$(grep -c 'actions/runs' "$WORK/gh.log")"
has "producer-gh: … and that retry is the unanswered one" "$(cat "$WORK/gh.log")" "head_sha=zzzz"
# …past the TTL the non-terminal ones are, live stays untouched.
: > "$WORK/gh.log"
FLEET_DEPLOY_TTL=0 run_refresh
eq "producer-gh: past the TTL → deploying re-read → live" live "$(dep bbbb)"
hasnt "producer-gh: a live sha is never re-read" "$(cat "$WORK/gh.log")" "head_sha=aaaa"
has   "producer-gh: a failed sha is re-read"     "$(cat "$WORK/gh.log")" "head_sha=cccc"

# --- the newest-20 cap: 22 MERGED rows → the 2 lowest PR numbers are not probed ---
: > "$WORK/prmap.tsv"
i=1; while [ "$i" -le 22 ]; do printf 'br-%s\t#%s\tMERGED\t✓\t\ts%02d\n' "$i" "$((100+i))" "$i" >> "$WORK/prmap.tsv"; printf 'live\n' > "$WORK/api/$(printf 's%02d' "$i")"; i=$((i+1)); done
reset_dep; run_refresh
eq "producer: newest-20 cap → 20 probed" 20 "$(ls "$FD"/deploy_* | wc -l | tr -d ' ')"
[ ! -f "$FD/deploy_s01" ] && [ ! -f "$FD/deploy_s02" ] || fail "producer: the two OLDEST PRs must fall outside the cap"
CHECKS=$((CHECKS+1))
[ -f "$FD/deploy_s22" ] || fail "producer: the newest PR must be inside the cap"
CHECKS=$((CHECKS+1))

# --- feature off: a fleet with neither knob writes nothing -----------------------
conf; reset_dep; run_refresh
[ -z "$(ls "$FD"/deploy_* 2>/dev/null)" ] || fail "producer: neither knob set must write no deploy files" "$(ls "$FD")"
CHECKS=$((CHECKS+1))
hasnt "producer-off: no gh api calls either" "$(cat "$WORK/gh.log")" "actions/runs"

# ============================================================ DASH (live rows)
US=$'\x1f'
GN=$'\033[38;2;158;206;106m'; IN=$'\033[38;2;187;154;247m'; TX=$'\033[38;2;169;177;214m'
RD=$'\033[38;2;247;118;142m'; GY=$'\033[38;2;86;95;137m'; R=$'\033[0m'
# a hand-seeded cache (independent of the producer run above): one MERGED row per
# state, an OPEN row, and a 5-field legacy line.
printf 'issue-1\t#11\tMERGED\t✓\t\tlive1\nissue-2\t#12\tMERGED\t✓\t\tunkn2\nissue-5\t#15\tMERGED\t✓\t\tdepl5\nissue-6\t#16\tMERGED\t✓\t\tfail6\nissue-7\t#17\tMERGED\t✓\t\tnone7\nissue-3\t#13\tOPEN\t✓\tready\t\nissue-4\t#14\tMERGED\t✓\tready\n' > "$FD/prmap"
: > "$FD/prmap.ts"
rm -f "$FD"/deploy_*
printf 'live\t1\n'      > "$FD/deploy_live1"
printf 'unknown\t1\n'   > "$FD/deploy_unkn2"
printf 'deploying\t1\n' > "$FD/deploy_depl5"
printf 'failed\t1\n'    > "$FD/deploy_fail6"
# git_<key> caches (branch of each window's cwd) — cache_key: / → _s, _ → _u
gk() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }
for n in 1 2 3 4 5 6 7; do printf 'issue-%s\tclean\n' "$n" > "$C/global/git_$(gk "/w/repo-issue-$n")"; done
WLIST_FILE="$WORK/wlist"; export WLIST_FILE
w() { printf '%s\n' "s1$US$1$US$2$US$3$US$4$US$US$5$US$6$US$7$US$8" >> "$WLIST_FILE"; }
: > "$WLIST_FILE"
#   idx name      cwd              state wid @issue @origin @worktree
w 1 issue-1 /w/repo-issue-1 idle @1 1 '' /w/repo-issue-1
w 2 issue-2 /w/repo-issue-2 idle @2 2 '' /w/repo-issue-2
w 3 issue-3 /w/repo-issue-3 idle @3 3 '' /w/repo-issue-3
w 4 issue-4 /w/repo-issue-4 idle @4 4 '' /w/repo-issue-4
w 5 issue-5 /w/repo-issue-5 idle @5 5 '' /w/repo-issue-5
w 6 issue-6 /w/repo-issue-6 idle @6 6 '' /w/repo-issue-6
w 7 issue-7 /w/repo-issue-7 idle @7 7 '' /w/repo-issue-7
out=$(FLEET_SESSION=s1 FZF_COLUMNS=120 bash "$ROWS" 2>&1) || fail "live rows producer exited non-zero" "$out"
row_of() { printf '%s\n' "$out" | grep -F "s1:$1$US"; }
has "dash: live → green 'live'"               "$(row_of 1)" "${GN}live   ${R}"
has "dash: unknown → still 'merged'"           "$(row_of 2)" "${IN}merged ${R}"
has "dash: deploying → 'deploy…'"              "$(row_of 5)" "${TX}deploy…${R}"
has "dash: failed → red 'deploy✗'"             "$(row_of 6)" "${RD}deploy✗${R}"
has "dash: no verdict file → 'merged'"         "$(row_of 7)" "${IN}merged ${R}"
has "dash: 5-field legacy line → 'merged'"     "$(row_of 4)" "${IN}merged ${R}"
has "dash: OPEN row keeps its #N✓ decoration"  "$(row_of 3)" "#13✓"
hasnt "dash: the sha never leaks into the cell" "$out" "live1"

# ============================================================ LANDED (⌃t rows)
export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
{
  printf '2026-01-01T00:00:00Z\t1\tfix one\t11\twt-sha-1\t/w/repo-issue-1\t/nope\tsid-1\t-\t\n'
  printf '2026-01-02T00:00:00Z\t2\tfix two\t12\twt-sha-2\t/w/repo-issue-2\t/nope\tsid-2\t-\t\n'
  printf '2026-01-03T00:00:00Z\t5\tfix five\t15\twt-sha-5\t/w/repo-issue-5\t/nope\tsid-5\t-\t\n'
  printf '2026-01-04T00:00:00Z\t6\tfix six\t16\twt-sha-6\t/w/repo-issue-6\t/nope\tsid-6\t-\t\n'
  printf '2026-01-05T00:00:00Z\t8\tfix eight\t99\twt-sha-8\t/w/repo-issue-8\t/nope\tsid-8\t-\t\n'
  printf '2026-01-06T00:00:00Z\t4\tfix four\t14\twt-sha-4\t/w/repo-issue-4\t/nope\tsid-4\t-\t\n'
} > "$FLEET_HISTORY_LEDGER"
lout=$(FLEET_SESSION=s1 FLEET_REPO=fake/repo FZF_COLUMNS=120 bash "$HIST" rows 2>&1) \
  || fail "landed rows producer exited non-zero" "$lout"
lrow() { printf '%s\n' "$lout" | grep -F "landed:$1$US"; }
has "landed: header's last column is 'dep'"        "$(printf '%s\n' "$lout" | grep -F "hdr${US}hdr")" "dep"
has "landed: PR 11 → green 'live'"                  "$(lrow 11)" "${GN}live${R}"
has "landed: PR 12 unknown → '·'"                    "$(lrow 12)" "${GY}·   ${R}"
has "landed: PR 15 → '…'"                            "$(lrow 15)" "${TX}…   ${R}"
has "landed: PR 16 → red '✗'"                        "$(lrow 16)" "${RD}✗   ${R}"
has "landed: PR 99 not in prmap → '·'"               "$(lrow 99)" "${GY}·   ${R}"
has "landed: 5-field legacy prmap line → '·'"        "$(lrow 14)" "${GY}·   ${R}"
hasnt "landed: the ledger's own (worktree) sha is never used" "$lout" "wt-sha"
# the same ledger with NO prmap at all (no fleet resolution) still renders, all `·`
nout=$(FLEET_REPO=fake/repo FZF_COLUMNS=120 bash "$HIST" rows 2>&1) || fail "landed rows without a session exited non-zero" "$nout"
eq "landed: without a resolvable fleet every dep cell is '·'" 6 "$(printf '%s\n' "$nout" | grep -cF "${GY}·   ${R}")"

printf 'deploy-state-selftest: OK (%d checks) — merged ≠ live: probe → deploy_<sha> → dash + landed (issue #541)\n' "$CHECKS"
