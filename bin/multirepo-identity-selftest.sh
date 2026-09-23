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
#   keys       fleet_multirepo / fleet_issue_key / fleet_window_key /
#              fleet_bound_windows / fleet_repo_for_slug / fleet_okey_prefix
#   dispatch   autofill dedup (fleet-dispatch.sh)
#   backlog    the ACTIVE map (tmux-issues-rows.sh)
#   reap       fleet-reap-target.py: bare #12 refused as ambiguous, <repo>#12 exact
#   bridge     bridge_find_window (fleet-issue-bridge.sh --find-window)
#   ledger     fleet-ledger-watch.sh: key (repo, N), row to its own repo's ledger
#   dash       okey grouping (tmux-dashboard-rows.sh) + fold (dash-fold-toggle.sh)
#   landed     the landed view's origin join + per-repo fold file (fleet-history.sh)
#   hub        fleet-control-read.sh message/resume use the WINDOW's repo
#
# tmux: a PATH shim maps every `-L <label>` to a private socket under $WORK, and a
# bare call made outside a pane to a socket nothing listens on — never the live
# server. gh is shimmed to fail, so nothing touches the network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
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
cat > "$FLEET_CONF_DIR/fleets/$M/conf" <<EOF
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/mainA"
FLEET_BASE_BRANCH="master"
FLEET_AUTOFILL=1
FLEET_ISSUE_BRIDGE=1
FLEET_AUTOFILL_MAX_PER_TICK=9
FLEET_FAILOVER=0
EOF
cat > "$FLEET_CONF_DIR/fleets/$M/repos/o-b.conf" <<EOF
FLEET_REPO="o/b"
FLEET_MAIN="$WORK/mainB"
FLEET_BASE_BRANCH="main"
EOF
sed 's#o/a#o/c#; s#mainA#mainC#' "$FLEET_CONF_DIR/fleets/$M/conf" > "$FLEET_CONF_DIR/fleets/$D/conf"

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
CA=$(win "$M" CA @issue 20 @repo o/a @origin o-a:issue-12)
CB=$(win "$M" CB @issue 21 @repo o/b @origin o-b:issue-12)
D12=$(win "$D" D12 @issue 12)
D14=$(win "$D" D14 @issue 14)
DC=$(win "$D" DC @issue 20 @origin issue-12)

paneOf() { tmx "$1" display-message -p -t "$2" '#{pane_id}'; }
in_pane() { # in_pane <sess> <window-id> <cmd…>
  local s="$1" w="$2"; shift 2
  ( export TMUX="$WORK/sock.$s,1,0" TMUX_PANE; TMUX_PANE=$(paneOf "$s" "$w"); "$@" )
}

# sessmap (the collector's cache): session → slug → repo
mkdir -p "$FLEET_C/global"
printf '%s\t%s\t%s\n' "$M" o-a o/a "$D" o-c o/c > "$FLEET_C/global/sessmap"

# --- keys -----------------------------------------------------------------------
fleet_multirepo "$M" || fail "keys: M hosts two repos"
fleet_multirepo "$D" && fail "keys: D hosts one repo"
eq "keys: issue key, multi"  "$(fleet_issue_key "$M" https://github.com/o/b.git 12)" "o/b#12"
eq "keys: issue key, one-repo" "$(fleet_issue_key "$D" o/c 12)" "12"
eq "keys: window key A12" "$(fleet_window_key "$M" "$A12")" "o/a#12"
eq "keys: window key B12" "$(fleet_window_key "$M" "$B12")" "o/b#12"
eq "keys: unknown repo is #N, not a guess" "$(fleet_window_key "$M" "$U16")" "#16"
eq "keys: one-repo window key stays bare" "$(fleet_window_key "$D" "$D12")" "12"
eq "keys: window key CB" "$(fleet_window_key "$M" "$CB")" "o/b#21"
eq "keys: one-repo D14 / DC stay bare" "$(fleet_window_key "$D" "$D14") $(fleet_window_key "$D" "$DC")" "14 20"
eq "keys: panel has no key" "$(fleet_window_key "$M" "$M:plan")" ""
iw=$(fleet_bound_windows "$M" | cut -f1 | sort | tr '\n' ' ')
eq "keys: issue windows, multi" "$iw" "#16 o/a#12 o/a#20 o/b#12 o/b#14 o/b#21 "
iw=$(fleet_bound_windows "$D" | cut -f1 | sort | tr '\n' ' ')
eq "keys: issue windows, one-repo" "$iw" "12 14 20 "
eq "keys: repo by slug"  "$(fleet_repo_for_slug "$M" o-b)" "o/b"
eq "keys: repo by name"  "$(fleet_repo_for_slug "$M" a)" "o/a"
fleet_repo_for_slug "$M" o-z >/dev/null && fail "keys: an unhosted slug resolves"
eq "keys: okey prefix, multi" "$(fleet_okey_prefix "$M" o/b)" "o-b:"
eq "keys: okey prefix, one-repo" "$(fleet_okey_prefix "$D" o/c)" ""
leg keys

# --- dispatch: autofill dedup ------------------------------------------------------
# M dispatches for BOTH o/a and o/b (o/b's overlay inherits FLEET_AUTOFILL=1, #799).
# A12 binds o/a#12; B14 binds only o/b#14; U16's repo is unknown, so it blocks #16
# everywhere (conservative). D: the legacy bare set, bare log lines.
cat > "$WORK/issues.json" <<'JSON'
[ {"number":12,"labels":[{"name":"autofill"}],"assignees":[]},
  {"number":14,"labels":[{"name":"autofill"}],"assignees":[]},
  {"number":16,"labels":[{"name":"autofill"}],"assignees":[]},
  {"number":18,"labels":[{"name":"autofill"}],"assignees":[]} ]
JSON
cat > "$WORK/bin/gh" <<EOF
#!/bin/bash
expr=''
while [ "\$#" -gt 0 ]; do case "\$1" in --jq) shift; expr="\$1" ;; esac; shift; done
[ -n "\$expr" ] && jq -r "\$expr" "$WORK/issues.json"
exit 0
EOF
out=$(bash "$BIN/fleet-dispatch.sh" --dry-run "$M" 2>&1)
has   "dispatch: A#12 bound"              "$out" "skip o/a#12"
has   "dispatch: B#12 bound"              "$out" "skip o/b#12"
has   "dispatch: B#14 does not bind A#14" "$out" "would spawn o/a#14 (p3) --repo o/a"
has   "dispatch: B#14 bound"              "$out" "skip o/b#14"
has   "dispatch: unknown-repo #16 blocks A" "$out" "skip o/a#16"
has   "dispatch: unknown-repo #16 blocks B" "$out" "skip o/b#16"
has   "dispatch: free A#18"               "$out" "would spawn o/a#18 (p3) --repo o/a"
has   "dispatch: free B#18"               "$out" "would spawn o/b#18 (p3) --repo o/b"
hasnt "dispatch: #12 never spawned"       "$out" "#12 (p3) --repo"
out=$(bash "$BIN/fleet-dispatch.sh" --dry-run "$D" 2>&1)
has   "dispatch: one-repo #12 bound"      "$out" "skip #12"
has   "dispatch: one-repo #14 bound"      "$out" "skip #14"
has   "dispatch: one-repo #16 free"       "$out" "would spawn #16 (p3)  [slot"
hasnt "dispatch: one-repo never --repo"   "$out" "--repo"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
leg dispatch

# --- backlog: the ACTIVE map -------------------------------------------------------
# The list is o/a's issues (its cache). Bound rows are hidden by default: o/a#12 is
# bound (A12); #14 is bound only in o/b — so it must SHOW.
for sl in o-a o-c; do
  mkdir -p "$FLEET_C/fleets/$sl"
  printf 'v1\t#12\t\tt12\nv1\t#14\t\tt14\nv1\t#18\t\tt18\n' > "$FLEET_C/fleets/$sl/issues"
  : > "$FLEET_C/fleets/$sl/issues.ts"
done
# field1 of a row is the bare issue number
rows=" $(in_pane "$M" "$M:plan" env FLEET_SESSION="$M" bash "$BIN/tmux-issues-rows.sh" all | cut -d$'\x1f' -f1 | tr '\n' ' ')"
hasnt "backlog: o/a#12 bound → hidden"         "$rows" " 12 "
has   "backlog: o/b#14 does not bind o/a#14"   "$rows" " 14 "
has   "backlog: free #18"                      "$rows" " 18 "
rows=" $(in_pane "$D" "$D:plan" env FLEET_SESSION="$D" bash "$BIN/tmux-issues-rows.sh" all | cut -d$'\x1f' -f1 | tr '\n' ' ')"
hasnt "backlog: one-repo #12 hidden" "$rows" " 12 "
hasnt "backlog: one-repo #14 hidden" "$rows" " 14 "
has   "backlog: one-repo #18 shows"  "$rows" " 18 "
leg backlog

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
ledger() { printf '%s/.claude/fleet/logs/landed_%s.tsv' "$HOME" "$1"; }
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
# the tick a fleet gains its second repo: a bare-key snapshot must not read as
# every live window vanishing.
sd=$(fleet_state_dir "$M"); sed -E 's/^o\/[ab]#//' "$sd/ledgerwatch.snap" > "$sd/x" && mv "$sd/x" "$sd/ledgerwatch.snap"
out=$(bash "$BIN/fleet-ledger-watch.sh" "$M" 2>&1)
has "ledger: bare→qualified switch records nothing" "$out" "no session window vanished"
# one-repo fleet: bare keys, the conf repo's ledger
bash "$BIN/fleet-ledger-watch.sh" "$D" >/dev/null 2>&1
eq "ledger: one-repo snapshot stays bare" "$(cut -f1 "$(fleet_state_dir "$D")/ledgerwatch.snap" | sort | tr '\n' ' ')" "12 14 20 "
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
has "dash: one-repo child under its bare issue-12 parent" "$o" "D12 DC "
# fold: ← from INSIDE A12's block (on CA) shuts A12's block — and only A12's
in_pane "$M" "$CA" env FLEET_SESSION="$M" bash "$BIN/dash-fold-toggle.sh" collapse "$CA" >/dev/null
eq "dash: fold from CA shut A12" "$(tmx "$M" display-message -p -t "$A12" '#{@expand}')" ""
eq "dash: fold left B12 open" "$(tmx "$M" display-message -p -t "$B12" '#{@expand}')" "1"
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
has "landed: child nests under its same-repo parent" "$out" "└ child31"
hasnt "landed: origin prefix is not shown raw" "$out" "o-a:issue-30"
leg landed

# --- hub adapter: the WINDOW's repo, not the fleet conf's ------------------------------
HB="$WORK/hubbin"; mkdir -p "$HB"
cp "$BIN/fleet-control-read.sh" "$BIN/fleet-lib.sh" "$HB/"
printf '#!/bin/bash\nprintf "comment %%s\\n" "$*"\n' > "$HB/fleet-comment.sh"
printf '#!/bin/bash\nexit 0\n' > "$HB/fleet-diskguard.sh"; cp "$HB/fleet-diskguard.sh" "$HB/fleet-quotaguard.sh"
printf '#!/bin/bash\nprintf "restore %%s\\n" "$*"\n' > "$HB/dash-restore-session.sh"
# fake history: 12 is resumable in both repos, 40 only in o/b
cat > "$HB/fleet-history.sh" <<'EOF'
#!/bin/bash
repo=''; while [ "$#" -gt 1 ]; do case "$1" in --repo) repo=$2; shift ;; esac; shift; done
case "$repo:$1" in o/a:12|o/b:12|o/b:40|o/c:12) printf 'RESUME\tx\n' ;; *) printf 'REVIEW-ONLY\n' ;; esac
EOF
hub() { bash "$HB/fleet-control-read.sh" "$@" </dev/null 2>&1; }
out=$(hub message "$M" 12); rc=$?
eq "hub: bare 12 in two repos is refused" "$rc" 2
out=$(hub message "$M" o-b:issue-12); has "hub: o-b:issue-12 → o/b" "$out" "comment 12 --repo o/b"
out=$(hub message "$M" 14);          has "hub: bare 14 → its window's repo o/b" "$out" "comment 14 --repo o/b"
hub message "$M" 16 >/dev/null;      eq "hub: unknown-repo 16 is refused" "$?" 2
out=$(hub resume "$M" issue-12); rc=$?
eq "hub: resume 12 resumable in two repos is refused" "$rc" 5
out=$(hub resume "$M" o-a:issue-12); has "hub: resume o-a:issue-12 → o/a" "$out" "restore landed:issue:12 $M --repo o/a"
out=$(hub resume "$M" issue-40);    has "hub: resume 40 → the one repo that has it" "$out" "restore landed:issue:40 $M --repo o/b"
out=$(hub message "$D" 12);          has "hub: one-repo message unchanged" "$out" "comment 12 --repo o/c"
out=$(hub resume "$D" issue-12);     eq "hub: one-repo resume unchanged" "$out" "restore landed:issue:12 $D"
leg hub

if [ "$FAILS" -gt 0 ]; then printf 'multirepo-identity-selftest: %d FAIL\n' "$FAILS" >&2; exit 1; fi
printf 'multirepo-identity-selftest: all legs PASS\n'
