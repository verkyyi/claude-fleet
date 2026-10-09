#!/bin/bash
# dash-ended-group-selftest.sh — the 已结束 group (issue #2565, EPIC #2563 C2).
#
# The row producer (bin/tmux-dashboard-rows.sh — the sidebar AND the hub list)
# moves a ROOT row that is done / exited and carries no issue — a home or scratch
# session whose work is over — out of its repo group into ONE group at the foot,
# `已结束 (n)`, folded by default. Its fold bit has the opposite polarity to a
# repo heading's: the token `ended:open` in @repo_fold says it is OPEN.
# Pinned here:
#   A. DEFAULT — the done no-issue row and the exited one are gone from the list,
#      the foot reads `▸ 已结束 (2)` (sidebar key `hdr:ended`, hub 4th field
#      `ended`); a done row WITH an issue, a working no-issue row and a pinned
#      done row stay where they were.
#   B. OPEN / SHUT — `→` on the heading (both shapes) writes `ended:open`, the
#      rows show under an open heading; `←` drops the token (the option unset
#      once it was the last), and the frame is byte-identical to A's. A second
#      `←` is a dead key.
#   C. RAILS — the sidebar's current window stays on the list while folded; a
#      done row with a child keeps its place (its subtree is never split).
#   D. NOTHING ENDED — no heading at all; @repo_fold untouched.
#   E. fleet ls — hides the 已结束 rows; --all lists them.
#   F. THE SIDEBAR — fleet-sidebar.py taps `hdr:ended` as a fold stop only
#      (select, never a new session) and names no repo for it.
# tmux runs on a PRIVATE socket via a PATH shim; gh fails.
set -uo pipefail
export FLEET_DASH_ORDER=status

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
FOLD="$BIN/dash-fold-toggle.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

CHECKS=0 FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; FAILS=$((FAILS+1)); }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-ended.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/s"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
unset TMUX TMUX_PANE FLEET_SESSION FLEET_REPO FLEET_MAIN FLEET_SIDEBAR_CURRENT FLEET_SIDEBAR_CURRENT_ROW FLEET_SHELL 2>/dev/null || true
export FLEET_UI_LANG=zh
mkdir -p "$TMPDIR" "$FLEET_CONF_DIR/fleets/alpha"
printf 'FLEET_REPO="o/claude-fleet"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH=master\n' "$WORK/cf" > "$FLEET_CONF_DIR/fleets/alpha/conf"

"$REAL_TMUX" -S "$SOCK" new-session -d -s alpha -n plan -x 200 -y 40 || { echo "no isolated tmux" >&2; exit 1; }
win() { tmux new-window -d -t alpha -n "$1"; shift; local w; w=$(tmux list-windows -t alpha -F '#{window_id}' | tail -n1)
        while [ "$#" -gt 1 ]; do tmux set -w -t "$w" "$1" "$2"; shift 2; done; echo "$w"; }
win issue-1  @issue 1 @claude_state done >/dev/null
win live     @norepo 1 @claude_state working >/dev/null
W_DONE=$(win donehome @norepo 1 @claude_state done)
win gone     @norepo 1 @claude_state exited >/dev/null
win pinned   @norepo 1 @claude_state done @pin 1 >/dev/null

side()  { FLEET_SESSION=alpha bash "$ROWS" --sidebar | tr '\037' '|'; }
names() { side | awk -F'|' '{ print $4 }' | sed 's/^ *//' | tr '\n' ' '; }
keys()  { side | awk -F'|' '$1 == "hdr" { print "hdr:" $2; next } { print $1 }' | tr '\n' ' '; }
raw()   { FLEET_SESSION=alpha FZF_COLUMNS=120 bash "$ROWS"; }
opt()   { tmux show-option -t '=alpha:' -qv @repo_fold; }
fold()  { FLEET_SESSION=alpha TMUX=/fake,1,0 bash "$FOLD" "$@" 2>&1 </dev/null; }

# --- A. folded by default -------------------------------------------------------
s=$(side); n=$(names)
has   "A: the foot is the folded 已结束 heading with its count" "$n" "▸ 已结束 (2)"
hasnt "A: the done no-issue row is off the list" "$n" "donehome"
hasnt "A: …and so is the exited one" "$n" "gone"
has   "A: a done row WITH an issue stays" "$n" "issue-1"
has   "A: a working no-issue row stays" "$n" "live"
has   "A: a pinned done row stays in 置顶" "$n" "pinned"
eq    "A: the heading's sidebar key is hdr:ended, last" "$(keys | awk '{ print $NF }')" "hdr:ended"
eq    "A: the hub list's heading carries 'ended' as its 4th field" \
      "$(raw | grep '已结束' | awk -F '\037' '{ print $4 }')" "ended"
before=$(names)

# --- B. open / shut -------------------------------------------------------------
eq    "B: → on the sidebar heading reloads" "$(fold expand hdr:ended)" "reload(bash $ROWS)"
eq    "B: …and writes the open token" "$(opt)" "ended:open"
n=$(names)
has   "B: the heading is open" "$n" "已结束 (2) "
hasnt "B: …no fold caret" "$n" "▸ 已结束"
has   "B: the ended rows show under it" "$n" "donehome"
has   "B: …both of them" "$n" "gone"
eq    "B: → on an open heading is a dead key" "$(fold expand hdr:ended)" ""
eq    "B: ← (the hub's shape) shuts it" "$(fold collapse hdr '' ended)" "reload(bash $ROWS)"
eq    "B: …the last token gone, the option unset" "$(tmux show-options -t '=alpha:' | grep -c '@repo_fold')" "0"
eq    "B: the list is A's again" "$(names)" "$before"
eq    "B: a second ← is a dead key" "$(fold collapse hdr:ended)" ""

# --- C. rails -------------------------------------------------------------------
n=$(FLEET_SIDEBAR_CURRENT="$W_DONE" names)
has   "C: the sidebar's current window stays on the list while folded" "$n" "donehome"
win kid @issue 7 @claude_state working @origin o-claude-fleet:scratch-9 >/dev/null
tmux set -wu -t "$W_DONE" @norepo; tmux set -w -t "$W_DONE" @repo o/claude-fleet; tmux set -w -t "$W_DONE" @raw 1; tmux set -w -t "$W_DONE" @worktree "$WORK/cf-scratch-9"
n=$(names)
has   "C: a done row with a child keeps its place" "$n" "issue-1 donehome"
has   "C: …the heading counts only the one left" "$n" "▸ 已结束 (1)"

# --- D. nothing ended -----------------------------------------------------------
for w in $(tmux list-windows -t alpha -F '#{window_id}'); do
  case "$(tmux show -w -t "$w" -qv @claude_state)" in done|exited) tmux set -w -t "$w" @claude_state working ;; esac
done
n=$(names)
hasnt "D: no ended row, no heading" "$n" "已结束"
eq    "D: …and no option written" "$(opt)" ""

# --- E. fleet ls ----------------------------------------------------------------
TSV="$WORK/rows.tsv"
printf 'a1\tworking\t·\tlive\tm1\tclaude-fleet (1)\t\t\t\t\t\to/claude-fleet\nb2\tdone\t✓\tdonehome\tm1\t▸ 已结束 (1)\t\t\t\t\t\t\t1\n' > "$TSV"
out=$(FLEET_SESSION_CLI_ROWS="$TSV" python3 "$BIN/fleet-session-cli.py" ls --json)
has   "E: fleet ls lists the live session" "$out" '"live"'
hasnt "E: …and hides the ended one" "$out" 'donehome'
out=$(FLEET_SESSION_CLI_ROWS="$TSV" python3 "$BIN/fleet-session-cli.py" ls --all --json)
has   "E: fleet ls --all lists the ended one too" "$out" 'donehome'
FLEET_SESSION_CLI_ROWS="$TSV" python3 "$BIN/fleet-session-cli.py" ls --bogus >/dev/null 2>&1
eq    "E: an unknown flag is usage (2)" "$?" "2"
out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("qo", sys.argv[1] + "/fleet-quickopen.py")
qo = importlib.util.module_from_spec(spec); spec.loader.exec_module(qo)
rows = [["hdr", "o/claude-fleet", "", "claude-fleet (1)"], ["@1", "working", "·", "live"],
        ["hdr", "ended", "", "已结束 (1)"], ["@2", "done", "✓", "donehome"]]
for r in qo.parse_rows(qo.rows_text(rows)):
    print(r["name"], r["repo"] or "-", r["ended"] or "-")
PY
)
eq    "E: rows_text marks the 已结束 rows, names no repo for them" "$(printf '%s' "$out" | tr '\n' ';')" \
      "live o/claude-fleet -;donehome - 1"

# --- F. the sidebar's handling of the heading -------------------------------------
out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1] + "/fleet-sidebar.py")
sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
print(sb.tap("hdr:ended", "hdr:ended"), repr(sb.target_name("hdr:ended")), sb.folds("hdr:ended"))
PY
)
eq    "F: a tap on 已结束 only selects it, names no repo, folds" "$out" "select '' hdr:ended"

printf 'dash-ended-group-selftest: %d checks, %d failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
