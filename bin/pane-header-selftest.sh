#!/bin/bash
# pane-header-selftest.sh — the top-of-window header contract (issues #267, #1452).
#
# Every window shows a top-of-pane header naming its session — its name plus the
# bound ##{@issue} when issue-bound — EXCEPT the hub, whose operator pane keeps
# its "▸ FLEET HUB" cue and whose dash pane stays empty. It lives in ONE line of
# conf/tmux-attention.conf: `set -g pane-border-format "…"`. This test takes that
# REAL line, sources it on a private tmux server — so the conf parser's treatment
# of the text (`$`, `%`, quotes) is what is tested, byte for byte — and asserts:
#
#   • the three-way role routing (#267): worker name + #issue, hub cue, dash empty
#   • no right segment (#2717): 剩余 % · model · effort (#1452, #2431) is the
#     client's top line's (bin/fleet-topbar.py) — a window with every
#     measurement stamp reads the plain ` name #issue `
#   • the PR segment (#1954): `PR #N` + ✓ 检查通过 (green) / … 检查中 (amber) /
#     ✗ <red checks> (red, cut at 24) off @pr_num/@pr_ci/@pr_fail; no @pr_num ⇒
#     the header is byte for byte the old one
#   • panels never show it: the hub / dash / sidebar panes, and a window NAMED
#     dash / plan / backlog
#
# Also guards `pane-border-status top` is set globally in the conf — without it the
# format renders nowhere.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="$BIN/../conf/tmux-attention.conf"
[ -f "$CONF" ] || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ph-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
tmux() { "$REAL_TMUX" -S "$SOCK" "$@"; }  # every tmux call → private socket

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
# render the border format for a pane, then strip #[...] style tokens → visible text
render() { tmux display-message -p -t "$1" "$FMT" | sed -E 's/#\[[^]]*\]//g'; }
# the same, styles kept — for the colour assertions
raw()    { tmux display-message -p -t "$1" "$FMT"; }

# --- pull the REAL conf lines (the thing we actually ship) --------------------
grep -qE '^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+pane-border-status[[:space:]]+top' "$CONF" \
  || fail "conf does not enable 'pane-border-status top' globally"

# extract the pane-border-format value (the string between the outer quotes)
FMT="$(sed -n 's/^[[:space:]]*set\(-option\)\{0,1\}[[:space:]]\{1,\}-g[[:space:]]\{1,\}pane-border-format[[:space:]]\{1,\}"\(.*\)"[[:space:]]*$/\2/p' "$CONF")"
[ -n "$FMT" ] || fail "could not extract pane-border-format from conf"
# …and the line verbatim, to source
grep -E '^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+pane-border-format[[:space:]]' "$CONF" > "$WORK/header.conf"
[ "$(wc -l < "$WORK/header.conf" | tr -d ' ')" = 1 ] || fail "expected exactly one pane-border-format line in the conf"

# --- build a fleet-shaped session on the private socket ----------------------
# -f /dev/null: a clean server (no ~/.tmux.conf bleed → base-index etc. stay
# default). We target windows/panes by captured id, never a numeric index, so the
# test is base-index-agnostic.
tmux -f /dev/null new-session -d -s s -x 120 -y 40 || fail "could not start isolated tmux server"
tmux source-file "$WORK/header.conf" || fail "the conf's header lines do not source cleanly"
[ "$(tmux show-options -gv pane-border-format)" = "$FMT" ] \
  || fail "the sourced pane-border-format differs from the conf's text — the conf parser mangled it ('\$' / '%' / quotes?)"

# an issue-bound worker window
ww="$(tmux display-message -p '#{window_id}')"
tmux rename-window -t "$ww" issue-267
tmux set-window-option -t "$ww" @issue 267

# the hub window: dash pane (top) + operator hub pane (bottom)
hw="$(tmux new-window -P -F '#{window_id}' -t s: -n plan)"
dp="$(tmux display-message -p -t "$hw" '#{pane_id}')"
tmux set-option -p -t "$dp" @dash 1
sp="$(tmux split-window -P -F '#{pane_id}' -v -t "$hw")"
tmux set-option -p -t "$sp" @hub 1

# a raw/scratch window (no @issue)
rw="$(tmux new-window -P -F '#{window_id}' -t s: -n scratch)"
tmux set-window-option -t "$rw" @raw 1

# --- assert the three-way routing --------------------------------------------
worker="$(render "$ww")"
case "$worker" in
  *"issue-267"*"#267"*) : ;;                       # name + bound issue
  *) fail "worker header missing name/issue — got [$worker]" ;;
esac
# issue #1023: just the name + #issue — no WORKER label, no index: prefix.
case "$worker" in
  *WORKER*|*[0-9]:issue-267*) fail "worker header still carries WORKER / index: — got [$worker]" ;;
esac
[ "$worker" = " issue-267 #267 " ] || fail "worker header is not exactly ' name #issue ' — got [$worker]"
# focus is colour only (#999): an inactive worker pane reads the same words
wp2="$(tmux split-window -d -P -F '#{pane_id}' -t "$ww")"
[ "$(render "$wp2")" = "$worker" ] || fail "inactive worker header words differ — got [$(render "$wp2")] vs [$worker]"
tmux kill-pane -t "$wp2"

hubpane="$(render "$sp")"
case "$hubpane" in
  *"FLEET HUB"*) : ;;                              # hub keeps its own cue
  *) fail "hub pane lost its hub cue — got [$hubpane]" ;;
esac
case "$hubpane" in
  *"plan"*) fail "hub pane leaked the window name — got [$hubpane]" ;;
esac

dash="$(render "$dp")"
[ -z "$(printf '%s' "$dash" | tr -d '[:space:]')" ] \
  || fail "hub dash pane should be empty (the 'except the hub' rule) — got [$dash]"

raw_hdr="$(render "$rw")"
case "$raw_hdr" in
  *"scratch"*) : ;;                                # names the scratch window
  *) fail "raw header missing window name — got [$raw_hdr]" ;;
esac
case "$raw_hdr" in
  *"#"*[0-9]*) fail "raw (no @issue) should show no issue number — got [$raw_hdr]" ;;
esac

# --- #2717: no right segment — 剩余 % · model · effort is the client's top line's
# (bin/fleet-topbar.py) to draw; a window with every stamp reads the plain header
tmux set-window-option -t "$ww" @ctx_pct 38 \; set-window-option -t "$ww" @ctx_left 62 \; set-window-option -t "$ww" @ctx_band handoff \; \
     set-window-option -t "$ww" @model 'Opus 5.5' \; set-window-option -t "$ww" @effort high \; set-window-option -t "$ww" @ctx_ts "$(date +%s)"
[ "$(render "$ww")" = " issue-267 #267 " ] || fail "the node header must not draw the ctx segment (#2717) — got [$(render "$ww")]"
grep -vE '^[[:space:]]*#' "$CONF" | grep -qE 'fleet_ctx_hdr|@pct_sign' \
  && fail "conf/tmux-attention.conf still carries the ctx segment (#2717)"
tmux set-window-option -u -t "$ww" @ctx_pct \; set-window-option -u -t "$ww" @ctx_left \; set-window-option -u -t "$ww" @ctx_band \; \
     set-window-option -u -t "$ww" @model \; set-window-option -u -t "$ww" @effort \; set-window-option -u -t "$ww" @ctx_ts

# --- #1954: the PR segment after the name — PR #N + its checks ----------------
# what bin/tmux-pr-refresh.sh stamps: @pr_num / @pr_ci / @pr_fail
tmux set-window-option -t "$ww" @pr_num '#1951' \; set-window-option -t "$ww" @pr_ci '✓' \; set-window-option -t "$ww" @pr_fail ''
[ "$(render "$ww")" = " issue-267 #267  PR #1951 ✓ 检查通过  " ] || fail "green PR segment — got [$(render "$ww")]"
case "$(raw "$ww")" in *'#[bg=#9ece6a]#[bold] PR #1951 ✓ 检查通过 '*) : ;; *) fail "✓ must draw on green — got [$(raw "$ww")]" ;; esac
tmux set-window-option -t "$ww" @pr_ci '…'
[ "$(render "$ww")" = " issue-267 #267  PR #1951 … 检查中  " ] || fail "pending PR segment — got [$(render "$ww")]"
case "$(raw "$ww")" in *'#[bg=#e0af68]#[bold] PR #1951 … 检查中 '*) : ;; *) fail "… must draw on amber — got [$(raw "$ww")]" ;; esac
tmux set-window-option -t "$ww" @pr_ci '✗' \; set-window-option -t "$ww" @pr_fail 'shellcheck'
[ "$(render "$ww")" = " issue-267 #267  PR #1951 ✗ shellcheck  " ] || fail "red PR segment names the red check — got [$(render "$ww")]"
case "$(raw "$ww")" in *'#[bg=#f7768e]#[bold] PR #1951 ✗ shellcheck '*) : ;; *) fail "✗ must draw on red — got [$(raw "$ww")]" ;; esac
# several red checks: the comma-joined names survive the #{?…} nesting; a long list is cut
tmux set-window-option -t "$ww" @pr_fail 'lint,selftests (1/8),selftests (2/8),selftests (3/8)'
case "$(render "$ww")" in
  *' PR #1951 ✗ lint,selftests (1/8),sel…  ') : ;;
  *) fail "a long red list must be cut to 24 columns, … included — got [$(render "$ww")]" ;;
esac
tmux set-window-option -t "$ww" @pr_fail ''
[ "$(render "$ww")" = " issue-267 #267  PR #1951 ✗ 检查没过  " ] || fail "red with no name → 检查没过 — got [$(render "$ww")]"
# a PR with no checks at all: just the number, muted
tmux set-window-option -t "$ww" @pr_ci ''
[ "$(render "$ww")" = " issue-267 #267  PR #1951  " ] || fail "no-checks PR segment — got [$(render "$ww")]"
# @pr_num empty (the refresher's 'no open PR') or unset → byte for byte the old header
tmux set-window-option -t "$ww" @pr_num ''
[ "$(render "$ww")" = " issue-267 #267 " ] || fail "an empty @pr_num must leave the header untouched — got [$(render "$ww")]"
tmux set-window-option -u -t "$ww" @pr_num \; set-window-option -u -t "$ww" @pr_ci \; set-window-option -u -t "$ww" @pr_fail
[ "$(render "$ww")" = " issue-267 #267 " ] || fail "no @pr_num must leave the header untouched — got [$(render "$ww")]"

# panels never show it: the hub + dash panes (their window stamped), the sidebar,
# and a window NAMED dash / plan / backlog
tmux set-window-option -t "$hw" @ctx_pct 62 \; set-window-option -t "$hw" @model 'Opus 5.5' \; set-window-option -t "$hw" @effort high \; set-window-option -t "$hw" @pr_num '#1' \; set-window-option -t "$hw" @pr_ci '✓'
case "$(render "$sp")" in *%*|*Opus*|*"PR #"*) fail "the hub pane must not show the segment — got [$(render "$sp")]" ;; esac
[ -z "$(render "$dp" | tr -d '[:space:]')" ] || fail "the dash pane must stay empty with stamps — got [$(render "$dp")]"
sw="$(tmux new-window -P -F '#{window_id}' -t s: -n sidebar)"
sbp="$(tmux display-message -p -t "$sw" '#{pane_id}')"
tmux set-option -p -t "$sbp" @sidebar 1
tmux set-window-option -t "$sw" @ctx_pct 62 \; set-window-option -t "$sw" @model 'Opus 5.5'
case "$(render "$sbp")" in
  *%*|*Opus*) fail "the sidebar pane must not show the segment — got [$(render "$sbp")]" ;;
esac
# its border says nothing at all (issue #2167 took the TASKS label away)
[ -z "$(render "$sbp" | tr -d '[:space:]')" ] || fail "the sidebar pane's border must be empty — got [$(render "$sbp")]"
for nm in dash plan backlog; do
  pw="$(tmux new-window -P -F '#{window_id}' -t s: -n "$nm")"
  tmux set-window-option -t "$pw" @ctx_pct 62 \; set-window-option -t "$pw" @model 'Opus 5.5' \; set-window-option -t "$pw" @effort high \; set-window-option -t "$pw" @pr_num '#1' \; set-window-option -t "$pw" @pr_ci '✓'
  case "$(render "$pw")" in
    *%*|*Opus*|*"PR #"*) fail "a window named $nm is a panel and must not show the segment — got [$(render "$pw")]" ;;
    *"$nm"*) : ;;
    *) fail "a window named $nm lost its name — got [$(render "$pw")]" ;;
  esac
done

printf 'selftest OK: top-of-window header routes worker/hub/dash/raw correctly (#267), leaves 剩余 %% · model · effort to the client (#2717) and carries PR #N + its checks after the name (#1954)\n'
