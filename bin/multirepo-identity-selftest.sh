#!/bin/bash
# multirepo-identity-selftest.sh — no mix-ups by issue number (issue #790).
#
# A fleet hosting two repos can hold TWO windows bound to issue #12, one per repo.
# Every place that finds a session by its issue number must find the right one and
# never the other. Fleet M hosts o/a (its conf) + o/b (an overlay) and runs:
#   A12  @issue 12 @repo o/a          B12  @issue 12 @repo o/b
#   B14  @issue 14 @repo o/b          U16  @issue 16, repo unknown
#   CA   @issue 20 @repo o/a, spawned by A12 (@origin o-a:issue-12)
#   CB   @issue 21 @repo o/b, spawned by B12 (@origin o-b:issue-12)
# Fleet D is the degenerate case: ONE repo (o/c), no repos/ dir, the same shapes —
# every leg asserts it still behaves exactly as before #790.
#
# One leg per join the issue names:
#   keys       fleet_repos / fleet_issue_key / fleet_window_key /
#              fleet_bound_windows / fleet_repo_for_slug / fleet_okey_prefix
#   reap       fleet-reap-target.py: bare #12 refused as ambiguous, <repo>#12 exact
#   bridge     bridge_find_window (fleet-issue-bridge.sh --find-window)
#   ledger     fleet-ledger-watch.sh: key (repo, N), row to its own repo's ledger
#   dash       okey grouping (tmux-dashboard-rows.sh)
#   landed     the landed view's origin join + per-repo fold file (fleet-history.sh)
#   hub        fleet-control-read.sh resume/start use the WINDOW's repo
#
# tmux: a PATH shim maps every `-L <label>` to a private socket under $WORK, and a
# bare call made outside a pane to a socket nothing listens on — never the live
# server. gh is shimmed to fail, so nothing touches the network.
set -uo pipefail
export FLEET_GH_WRITE_GAP=0   # no write pacing here: the queue has its own test (fleet-gh-write-selftest.sh)

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
command -v jq  >/dev/null 2>&1 || { printf 'selftest: jq not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/multirepo-id-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then s="$WORK/sock.\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
[ -n "\${TMUX:-}" ] || exec "$REAL_TMUX" -S "$WORK/sock.none" "\$@"
exec "$REAL_TMUX" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

cleanup() {
  local s; for s in "$WORK"/sock.*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# tmux replaces a TAB in -F output with `_` outside a UTF-8 locale; the bridge's
# window read is TAB-separated, so pin one (the daemons run under one too).
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
# the ledger leg must not depend on the runner's free disk: the gate always opens
export FLEET_DISK_FLOOR_GB=0
export FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_DISPATCH_LEASE_DIR="$WORK/leases" FLEET_LEDGER_WATCH_LEASE_DIR="$WORK/leases"
mkdir -p "$FLEET_CONF_DIR" "$TMPDIR"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ;; *) fail "$1: [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1: [$3] unexpectedly in: $2" ;; esac; }
leg()  { # leg <name> — PASS when no new failure since the last leg
  if [ "$FAILS" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi
  _legf=$FAILS
}

mkrepo() { git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git"; }
mkrepo "$WORK/mainA" o/a; mkrepo "$WORK/mainB" o/b; mkrepo "$WORK/mainC" o/c

# --- fleets ------------------------------------------------------------------------
M=M D=D
mkdir -p "$FLEET_CONF_DIR/fleets/$M/repos" "$FLEET_CONF_DIR/fleets/$D"
fx_repo "$FLEET_CONF_DIR" "$M" o/a FLEET_MAIN="$WORK/mainA" FLEET_BASE_BRANCH=master
fx_repo "$FLEET_CONF_DIR" "$D" o/c FLEET_MAIN="$WORK/mainC" FLEET_BASE_BRANCH=master
cat > "$FLEET_CONF_DIR/fleets/$M/conf" <<EOF
FLEET_ISSUE_BRIDGE=1
FLEET_FAILOVER=0
EOF
cat > "$FLEET_CONF_DIR/fleets/$M/repos/o-b.conf" <<EOF
FLEET_REPO="o/b"
FLEET_MAIN="$WORK/mainB"
FLEET_BASE_BRANCH="main"
EOF
cp "$FLEET_CONF_DIR/fleets/$M/conf" "$FLEET_CONF_DIR/fleets/$D/conf"

# one tmux server per fleet, on its own label — the #159 shape
tmx() { local s="$1"; shift; tmux -L "$s" "$@"; }
for s in "$M" "$D"; do
  tmx "$s" -f /dev/null new-session -d -s "$s" -n plan -x 200 -y 50 || { echo "could not start isolated tmux" >&2; exit 1; }
done
win() { # win <sess> <name> [opt val]… → the new window's id
  local s="$1" n="$2" w; shift 2
  w=$(tmx "$s" new-window -d -P -F '#{window_id}' -t "$s:" -n "$n")
  tmx "$s" set-option -w -t "$w" @claude_state idle   # a live worker always has one
  while [ "$#" -ge 2 ]; do tmx "$s" set-option -w -t "$w" "$1" "$2"; shift 2; done
  printf '%s' "$w"
}
B12=$(win "$M" B12 @issue 12 @repo o/b)     # B's #12 FIRST: a bare join finds it first
A12=$(win "$M" A12 @issue 12 @repo o/a)
B14=$(win "$M" B14 @issue 14 @repo o/b)
U16=$(win "$M" U16 @issue 16)
win "$M" CA @issue 20 @repo o/a @origin o-a:issue-12 >/dev/null
CB=$(win "$M" CB @issue 21 @repo o/b @origin o-b:issue-12)
D12=$(win "$D" D12 @issue 12)
D14=$(win "$D" D14 @issue 14)
DC=$(win "$D" DC @issue 20 @origin o-c:issue-12)   # a spawn stamps the repo-qualified key (#1939)

paneOf() { tmx "$1" display-message -p -t "$2" '#{pane_id}'; }
in_pane() { # in_pane <sess> <window-id> <cmd…>
  local s="$1" w="$2"; shift 2
  ( export TMUX="$WORK/sock.$s,1,0" TMUX_PANE; TMUX_PANE=$(paneOf "$s" "$w"); "$@" )
}

# sessmap (the collector's cache): session → slug → repo
mkdir -p "$FLEET_C/global"
printf '%s\t%s\t%s\n' "$M" o-a o/a "$D" o-c o/c > "$FLEET_C/global/sessmap"

# --- keys -----------------------------------------------------------------------
eq "keys: M hosts two repos" "$(fleet_repos "$M" | grep -c .)" 2
eq "keys: D hosts one repo" "$(fleet_repos "$D" | grep -c .)" 1
eq "keys: issue key, multi"  "$(fleet_issue_key "$M" https://github.com/o/b.git 12)" "o/b#12"
eq "keys: issue key, one-repo carries its repo too (#1939)" "$(fleet_issue_key "$D" o/c 12)" "o/c#12"
eq "keys: window key A12" "$(fleet_window_key "$M" "$A12")" "o/a#12"
eq "keys: window key B12" "$(fleet_window_key "$M" "$B12")" "o/b#12"
eq "keys: unknown repo is #N, not a guess" "$(fleet_window_key "$M" "$U16")" "#16"
eq "keys: one-repo window key carries its repo" "$(fleet_window_key "$D" "$D12")" "o/c#12"
eq "keys: window key CB" "$(fleet_window_key "$M" "$CB")" "o/b#21"
eq "keys: one-repo D14 / DC carry it" "$(fleet_window_key "$D" "$D14") $(fleet_window_key "$D" "$DC")" "o/c#14 o/c#20"
eq "keys: panel has no key" "$(fleet_window_key "$M" "$M:plan")" ""
iw=$(fleet_bound_windows "$M" | cut -f1 | sort | tr '\n' ' ')
eq "keys: issue windows, multi" "$iw" "#16 o/a#12 o/a#20 o/b#12 o/b#14 o/b#21 "
iw=$(fleet_bound_windows "$D" | cut -f1 | sort | tr '\n' ' ')
eq "keys: issue windows, one-repo" "$iw" "o/c#12 o/c#14 o/c#20 "
eq "keys: repo by slug"  "$(fleet_repo_for_slug "$M" o-b)" "o/b"
eq "keys: repo by name"  "$(fleet_repo_for_slug "$M" a)" "o/a"
fleet_repo_for_slug "$M" o-z >/dev/null && fail "keys: an unhosted slug resolves"
eq "keys: okey prefix, multi" "$(fleet_okey_prefix "$M" o/b)" "o-b:"
eq "keys: okey prefix, one-repo" "$(fleet_okey_prefix "$D" o/c)" "o-c:"
leg keys

# --- reap: a destructive target never guesses ---------------------------------------
reap() { in_pane "$M" "$M:plan" python3 "$BIN/fleet-reap-target.py" "$1" 2>&1; }
out=$(reap '#12'); has "reap: bare #12 is ambiguous" "$out" "matched 2"
has "reap: ...and names the qualified form" "$out" "<repo>#12"
eq "reap: o/a#12"        "$(reap 'o/a#12')" "$A12"
eq "reap: o-b#12"        "$(reap 'o-b#12')" "$B12"
eq "reap: b:issue-12"    "$(reap 'b:issue-12')" "$B12"
out=$(reap 'o/a#16'); has "reap: unknown repo never matches" "$out" "matched 0"
eq "reap: unambiguous bare #14 still works" "$(reap '#14')" "$B14"
eq "reap: one-repo #12" "$(in_pane "$D" "$D:plan" python3 "$BIN/fleet-reap-target.py" '#12')" "$D12"
leg reap

# --- bridge: a comment on B#12 is never typed into A#12 ------------------------------
find() { bash "$BIN/fleet-issue-bridge.sh" --find-window "$1" "$2" | cut -f1,2; }
eq "bridge: o/a#12 → A12" "$(find 12 o/a)" "$M	$A12"
eq "bridge: o/b#12 → B12" "$(find 12 o/b)" "$M	$B12"
eq "bridge: o/a#14 → none (B14 is o/b's)" "$(find 14 o/a)" ""
eq "bridge: unknown-repo #16 → none" "$(find 16 o/a)" ""
eq "bridge: one-repo o/c#12 → D12" "$(find 12 o/c)" "$D	$D12"
leg bridge

# --- ledger: key (repo, N); each row to its own repo's ledger -------------------------
ledger() { printf '%s/logs/landed_%s.tsv' "$FLEET_CONF_DIR" "$1"; }
bash "$BIN/fleet-ledger-watch.sh" "$M" >/dev/null 2>&1        # tick 1: snapshot only
snap=$(cut -f1 "$(fleet_state_dir "$M")/ledgerwatch.snap" | sort | tr '\n' ' ')
eq "ledger: snapshot keys are repo-qualified; unknown skipped" "$snap" "o/a#12 o/a#20 o/b#12 o/b#14 o/b#21 "
tmx "$M" kill-window -t "$A12"
out=$(bash "$BIN/fleet-ledger-watch.sh" "$M" 2>&1)            # tick 2: A12 vanished, B12 lives
has "ledger: A#12 recorded" "$out" "1 vanished"
[ -f "$(ledger o-a)" ] && a=$(cut -f2 "$(ledger o-a)" | tr '\n' ' ') || a=''
[ -f "$(ledger o-b)" ] && b=$(cut -f2 "$(ledger o-b)" | tr '\n' ' ') || b=''
eq "ledger: o/a's ledger holds its #12" "$a" "12 "
eq "ledger: o/b's ledger untouched (B#12 lives)" "$b" ""
tmx "$M" kill-window -t "$B14"
bash "$BIN/fleet-ledger-watch.sh" "$M" >/dev/null 2>&1
b=$(cut -f2 "$(ledger o-b)" 2>/dev/null | tr '\n' ' ')
eq "ledger: o/b#14 lands in o/b's ledger" "$b" "14 "
a=$(cut -f2 "$(ledger o-a)" | tr '\n' ' ')
eq "ledger: ...not in o/a's" "$a" "12 "
# one-repo fleet: the same repo-qualified keys — one road (#1941)
bash "$BIN/fleet-ledger-watch.sh" "$D" >/dev/null 2>&1
eq "ledger: one-repo snapshot is repo-qualified too" "$(cut -f1 "$(fleet_state_dir "$D")/ledgerwatch.snap" | sort | tr '\n' ' ')" "o/c#12 o/c#14 o/c#20 "
leg ledger

# restore the windows the ledger leg closed, for the dash + hub legs
A12=$(win "$M" A12 @issue 12 @repo o/a)
B14=$(win "$M" B14 @issue 14 @repo o/b)

# --- dash: grouping keys --------------------------------------------------------------
# CA was spawned by A12 and CB by B12; both parents are "issue-12". Each child must
# render directly under ITS parent. Blocks start folded: open both parents, then
# read the order of names in the rendered list.
for w in "$A12" "$B12"; do tmx "$M" set-option -w -t "$w" @expand 1; done
tmx "$D" set-option -w -t "$D12" @expand 1
order() { in_pane "$1" "$1:plan" env FLEET_SESSION="$1" FZF_COLUMNS=160 bash "$BIN/tmux-dashboard-rows.sh" \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '(A12|B12|CA|CB|B14|U16|D12|D14|DC)( |$)' | tr -d ' ' | tr '\n' ' '; }
o=$(order "$M")
has "dash: CB under B12" "$o" "B12 CB "
has "dash: CA under A12" "$o" "A12 CA "
o=$(order "$D")
has "dash: one-repo child under its issue-12 parent" "$o" "D12 DC "
leg dash

# --- landed: the ledger's own <slug>: origins join; the fold file is per repo ----------
L=$(ledger o-a)
bash "$BIN/fleet-history.sh" record-closed --repo o/a --session "$M" --key 30 --worktree "$WORK/mainA" \
  --win @90 --title parent30 --origin '' >/dev/null 2>&1
bash "$BIN/fleet-history.sh" record-closed --repo o/a --session "$M" --key 31 --worktree "$WORK/mainA" \
  --win @91 --title child31 --origin o-a:issue-30 >/dev/null 2>&1
grep -q 'o-a:issue-30' "$L" || fail "landed: fixture origin not recorded"
lrows() { FLEET_SESSION="$M" FZF_COLUMNS=160 bash "$BIN/fleet-history.sh" rows 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
out=$(lrows)
has "landed: parent30 owns a block of 1" "$out" "0/1 ✓ parent30"
FLEET_SESSION="$M" bash "$BIN/fleet-history.sh" fold expand 'landed:issue:30' >/dev/null 2>&1
[ -f "$FLEET_C/global/dash_fold_landed_$M.o-a" ] || fail "landed: fold file is per repo (.o-a)"
[ -f "$FLEET_C/global/dash_fold_landed_$M" ] && fail "landed: multi-repo wrote the shared fold file"
out=$(lrows)
has "landed: child nests under its same-repo parent" "$out" "└  child31"
hasnt "landed: origin prefix is not shown raw" "$out" "o-a:issue-30"
leg landed

# --- hub adapter: the WINDOW's repo, not the fleet conf's ------------------------------
HB="$WORK/hubbin"; mkdir -p "$HB"
cp "$BIN/fleet-control-read.sh" "$BIN/fleet-lib.sh" "$BIN/fleet-client-core.sh" "$HB/"
printf '#!/bin/bash\nexit 0\n' > "$HB/fleet-diskguard.sh"; cp "$HB/fleet-diskguard.sh" "$HB/fleet-quotaguard.sh"
printf '#!/bin/bash\nprintf "restore %%s\\n" "$*"\n' > "$HB/dash-restore-session.sh"
printf '#!/bin/bash\nprintf "spawn %%s\\n" "$*"\n' > "$HB/dash-issue-session.sh"
# fake history: 12 is resumable in both repos, 40 only in o/b
cat > "$HB/fleet-history.sh" <<'EOF'
#!/bin/bash
repo=''; while [ "$#" -gt 1 ]; do case "$1" in --repo) repo=$2; shift ;; esac; shift; done
case "$repo:$1" in o/a:12|o/b:12|o/b:40|o/c:12) printf 'RESUME\tx\n' ;; *) printf 'REVIEW-ONLY\n' ;; esac
EOF
hub() { bash "$HB/fleet-control-read.sh" "$@" </dev/null 2>&1; }
out=$(hub resume "$M" issue-12); rc=$?
eq "hub: resume 12 resumable in two repos is refused" "$rc" 5
out=$(hub resume "$M" o-a:issue-12); has "hub: resume o-a:issue-12 → o/a" "$out" "restore landed:issue:12 $M --repo o/a"
out=$(hub resume "$M" issue-40);    has "hub: resume 40 → the one repo that has it" "$out" "restore landed:issue:40 $M --repo o/b"
out=$(hub resume "$D" issue-12);     eq "hub: one-repo resume names its only repo (#1938)" "$out" "restore landed:issue:12 $D --repo o/c"
# start (issue #984): a 2+ repo fleet needs the repo, resolved before any gate
hub start "$M" 12 claude >/dev/null; eq "hub: start with no repo in a 2-repo fleet is refused" "$?" 6
hub start "$M" 12 claude o/zz >/dev/null; eq "hub: start naming an unhosted repo is refused" "$?" 6
out=$(hub start "$M" 12 claude o-b); has "hub: start o-b → --repo o/b" "$out" "spawn 12 $M --print --agent claude --origin hub --repo o/b"
out=$(hub start "$M" 12 "" o/a);     has "hub: start o/a → --repo o/a" "$out" "--origin hub --repo o/a"
out=$(hub start "$D" 12 claude);     eq "hub: one-repo start names its only repo (#1938)" "$out" "spawn 12 $D --print --agent claude --origin hub --repo o/c"
out=$(hub start "$D" 12 claude o/c); eq "hub: one-repo start naming its repo" "$out" "spawn 12 $D --print --agent claude --origin hub --repo o/c"
hub start "$D" 12 claude o/a >/dev/null; eq "hub: one-repo start naming another repo is refused" "$?" 6
leg hub

if [ "$FAILS" -gt 0 ]; then printf 'multirepo-identity-selftest: %d FAIL\n' "$FAILS" >&2; exit 1; fi
printf 'multirepo-identity-selftest: all legs PASS\n'
