#!/bin/bash
# pane-header-selftest.sh — the top-of-window header contract (issues #267, #1452).
#
# Every window shows a top-of-pane header naming its session — its name plus the
# bound ##{@issue} when issue-bound — EXCEPT the hub, whose operator pane keeps
# its "▸ FLEET HUB" cue and whose dash pane stays empty. Since issue #1452 a
# worker / scratch header also carries a RIGHT-aligned `NN% · <model> · <effort>`
# segment off the window options conf/statusline.sh stamps (@ctx_pct @ctx_band
# @model @effort) — it replaces the Claude Code bottom status line. All of that
# lives in ONE line of conf/tmux-attention.conf: `set -g pane-border-format "…"`
# (plus the `@pct_sign` option beside it). This test takes those REAL lines,
# sources them on a private tmux server — so the conf parser's treatment of the
# text (`$`, `%`, quotes) is what is tested, byte for byte — and asserts:
#
#   • the three-way role routing (#267): worker name + #issue, hub cue, dash empty
#   • the right segment (#1452): only with @ctx_pct; coloured by @ctx_band
#     (handoff red, watch amber, ok green), or by the 80/50 fallback without one;
#     drops the effort below pane_width 100 and the model below 70, never the %;
#     a Codex-shaped window (% alone) shows just the %; no @ctx_pct ⇒ the header
#     is byte for byte the pre-#1452 ` name #issue `
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
# …and the two lines verbatim, to source: the format and the @pct_sign it reads
grep -E '^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+(pane-border-format|@pct_sign)[[:space:]]' "$CONF" > "$WORK/header.conf"
[ "$(wc -l < "$WORK/header.conf" | tr -d ' ')" = 2 ] || fail "expected exactly one pane-border-format and one @pct_sign line in the conf"

# --- build a fleet-shaped session on the private socket ----------------------
# -f /dev/null: a clean server (no ~/.tmux.conf bleed → base-index etc. stay
# default). We target windows/panes by captured id, never a numeric index, so the
# test is base-index-agnostic.
tmux -f /dev/null new-session -d -s s -x 120 -y 40 || fail "could not start isolated tmux server"
tmux source-file "$WORK/header.conf" || fail "the conf's header lines do not source cleanly"
[ "$(tmux show-options -gv pane-border-format)" = "$FMT" ] \
  || fail "the sourced pane-border-format differs from the conf's text — the conf parser mangled it ('\$' / '%' / quotes?)"
[ "$(tmux show-options -gv @pct_sign)" = '%' ] || fail "@pct_sign must source as a lone '%' (got [$(tmux show-options -gv @pct_sign)])"

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

# --- #1452: the right segment — % · model · effort ----------------------------
# every stamp, at the session's 120 columns → all three, right-aligned
tmux set-window-option -t "$ww" @ctx_pct 62 \; set-window-option -t "$ww" @ctx_band watch \; \
     set-window-option -t "$ww" @model 'Opus 5.5' \; set-window-option -t "$ww" @effort high
full=" issue-267 #267 62% · Opus 5.5 · high "
[ "$(render "$ww")" = "$full" ] || fail "worker header with every stamp — got [$(render "$ww")] want [$full]"
case "$(raw "$ww")" in
  *'#[align=right]#[fg=#e0af68]62%'*) : ;;
  *) fail "the segment must be right-aligned and amber for band=watch — got [$(raw "$ww")]" ;;
esac
# the colour follows @ctx_band — the fleet's own handoff lines (statusline.sh)
tmux set-window-option -t "$ww" @ctx_band handoff
case "$(raw "$ww")" in *'#[fg=#f7768e]62%'*) : ;; *) fail "band=handoff must draw the % red — got [$(raw "$ww")]" ;; esac
tmux set-window-option -t "$ww" @ctx_band ok
case "$(raw "$ww")" in *'#[fg=#9ece6a]62%'*) : ;; *) fail "band=ok must draw the % green — got [$(raw "$ww")]" ;; esac
# no band at all (a Codex window stamps the % alone) → the 80 / 50 fallback
tmux set-window-option -u -t "$ww" @ctx_band
tmux set-window-option -t "$ww" @ctx_pct 85
case "$(raw "$ww")" in *'#[fg=#f7768e]85%'*) : ;; *) fail "no band, 85 → red — got [$(raw "$ww")]" ;; esac
tmux set-window-option -t "$ww" @ctx_pct 50
case "$(raw "$ww")" in *'#[fg=#e0af68]50%'*) : ;; *) fail "no band, 50 → amber — got [$(raw "$ww")]" ;; esac
tmux set-window-option -t "$ww" @ctx_pct 49
case "$(raw "$ww")" in *'#[fg=#9ece6a]49%'*) : ;; *) fail "no band, 49 → green — got [$(raw "$ww")]" ;; esac
tmux set-window-option -t "$ww" @ctx_pct 62 \; set-window-option -t "$ww" @ctx_band ok

# a narrow pane drops the effort first (below 100), then the model (below 70),
# and keeps the %. resize-window works as-is on a detached server; do NOT add
# `window-size manual` for it — on tmux 3.6a that plus a later new-window kills
# the (private) server outright.
tmux resize-window -t "$ww" -x 99
[ "$(tmux display-message -p -t "$ww" '#{pane_width}')" = 99 ] || fail "could not resize the worker window to 99 columns"
[ "$(render "$ww")" = " issue-267 #267 62% · Opus 5.5 " ] || fail "pane_width 99 must drop the effort — got [$(render "$ww")]"
tmux resize-window -t "$ww" -x 69
[ "$(render "$ww")" = " issue-267 #267 62% " ] || fail "pane_width 69 must drop the model too, keeping the %% — got [$(render "$ww")]"
tmux resize-window -t "$ww" -x 120
[ "$(render "$ww")" = "$full" ] || fail "back at 120 columns the header must carry all three — got [$(render "$ww")]"

# Codex-shaped: @ctx_pct alone → just the %, no stray separators
tmux set-window-option -u -t "$ww" @model \; set-window-option -u -t "$ww" @effort \; set-window-option -u -t "$ww" @ctx_band
[ "$(render "$ww")" = " issue-267 #267 62% " ] || fail "a %-only (Codex) window must show just the %% — got [$(render "$ww")]"
# @effort without @model never dangles
tmux set-window-option -t "$ww" @effort high
[ "$(render "$ww")" = " issue-267 #267 62% " ] || fail "@effort without @model must not render — got [$(render "$ww")]"
tmux set-window-option -u -t "$ww" @effort

# no @ctx_pct → byte for byte the pre-#1452 header
tmux set-window-option -u -t "$ww" @ctx_pct
[ "$(render "$ww")" = " issue-267 #267 " ] || fail "no @ctx_pct must leave the old header untouched — got [$(render "$ww")]"

# panels never show it: the hub + dash panes (their window stamped), the sidebar,
# and a window NAMED dash / plan / backlog
tmux set-window-option -t "$hw" @ctx_pct 62 \; set-window-option -t "$hw" @model 'Opus 5.5' \; set-window-option -t "$hw" @effort high
case "$(render "$sp")" in *%*|*Opus*) fail "the hub pane must not show the segment — got [$(render "$sp")]" ;; esac
[ -z "$(render "$dp" | tr -d '[:space:]')" ] || fail "the dash pane must stay empty with stamps — got [$(render "$dp")]"
sw="$(tmux new-window -P -F '#{window_id}' -t s: -n sidebar)"
sbp="$(tmux display-message -p -t "$sw" '#{pane_id}')"
tmux set-option -p -t "$sbp" @sidebar 1
tmux set-window-option -t "$sw" @ctx_pct 62 \; set-window-option -t "$sw" @model 'Opus 5.5'
case "$(render "$sbp")" in
  *%*|*Opus*) fail "the sidebar pane must not show the segment — got [$(render "$sbp")]" ;;
  *TASKS*) : ;;
  *) fail "the sidebar pane lost its TASKS cue — got [$(render "$sbp")]" ;;
esac
for nm in dash plan backlog; do
  pw="$(tmux new-window -P -F '#{window_id}' -t s: -n "$nm")"
  tmux set-window-option -t "$pw" @ctx_pct 62 \; set-window-option -t "$pw" @model 'Opus 5.5' \; set-window-option -t "$pw" @effort high
  case "$(render "$pw")" in
    *%*|*Opus*) fail "a window named $nm is a panel and must not show the segment — got [$(render "$pw")]" ;;
    *"$nm"*) : ;;
    *) fail "a window named $nm lost its name — got [$(render "$pw")]" ;;
  esac
done

printf 'selftest OK: top-of-window header routes worker/hub/dash/raw correctly (#267) and carries %% · model · effort on the right (#1452)\n'
