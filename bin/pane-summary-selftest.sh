#!/bin/bash
# pane-summary-selftest.sh — the live-summary pane header contract (issue #455).
#
# A worker's pane header now carries what the session is DOING, not just who it is:
# bin/tmux-summarize.sh republishes the one-liner it already computes for the dash
# column as a `@summary` WINDOW option, and conf/tmux-attention.conf's
# pane-border-format renders it in the worker/scratch branch only.
#
# The rail this guards is that the summary rides its OWN token and never the window
# NAME: bin/fleet-restore.sh reconciles already-open windows by name (a drifting name
# reopens a SECOND Claude on the same worktree), fleet_hub_sessions/fleet_session_count
# key the panels off the literal names dash/plan/backlog, and ⌃e's manual rename
# (#449/#452) has to stick. So this test drives the REAL summarizer against a REAL,
# isolated tmux server (its own socket via a PATH shim, torn down at exit — never the
# user's live server) with a FAKE `claude` on PATH, and asserts:
#
#   • PUBLISH    --window mode sets @summary on the right window_id AND still writes
#                the summary_<sess>_<id> file the dash reads (both, from one call).
#   • NO-RENAME  window_name is byte-identical before/after a summarize run.
#   • SANITIZE   a summary carrying '#' / newlines / 200 chars lands as one clipped
#                line with no '#' — the border re-parses its expanded string, so a
#                stray '#[' would leak a style into the header.
#   • ROUTING    the REAL conf format renders the summary for a worker window and
#                renders NOTHING for @hub=1 / @dash=1 panes.
#   • INERT      ',' '{' '%' in a summary render literally (substituted values are
#                not re-expanded) — no broken border, no format leakage.
#   • GUARD      a window with no @summary renders the pre-#455 header exactly (no
#                dangling ' · ' separator).
#   • NO-MCP     the `claude -p` it shells out to carries --strict-mcp-config with an
#                empty config (issue #468) — a screen classifier must not boot the
#                operator's MCP set on every Stop hook — and FLEET_HELPER_NO_MCP=0
#                still drops the flags for a no-edit rollback.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/tmux-summarize.sh"
LIB="$BIN/fleet-lib.sh"
CONF="$BIN/../conf/tmux-attention.conf"
[ -f "$SUT" ]  || { printf 'selftest: %s not found\n' "$SUT"  >&2; exit 2; }
[ -f "$LIB" ]  || { printf 'selftest: %s not found\n' "$LIB"  >&2; exit 2; }
[ -f "$CONF" ] || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pane-sum-selftest.XXXXXX")" || exit 2

# Isolate every tmux call onto a private socket. tmux-summarize.sh calls bare `tmux`
# whenever SUMMARIZE_SOCK is unset (the --window / $TMUX-inherited path), so a PATH
# shim is what routes it here — exactly how it inherits its fleet's socket in
# production. The same shim covers this harness's own calls.
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"

# FAKE claude: drains stdin (the summarizer pipes a prompt in) and echoes whatever
# fixture the current assertion parked in \$WORK/claude-out. No network, no tokens.
cat > "$WORK/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$WORK/claude-argv"
cat >/dev/null
cat "$WORK/claude-out"
EOF
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

# The summarizer derives its cache root from TMPDIR — point it inside \$WORK so the
# run never touches the machine's real ~/.claude-dash cache.
export TMPDIR="$WORK"
export SUMMARIZE_DEBOUNCE=0        # consecutive runs in one test must not coalesce
unset SUMMARIZE_SOCK               # force the bare-`tmux` (PATH shim) path

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does not fire when bash is killed by a signal — turn INT/TERM/HUP
# into a normal exit so cleanup still reaps the isolated server (issue #152).
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# shellcheck source=/dev/null
. "$LIB"
command -v fleet_summary_sanitize >/dev/null 2>&1 \
  || fail "fleet_summary_sanitize not defined by fleet-lib.sh (issue #455)"

wopt() { tmux show-options -w -t "$1" -v "$2" 2>/dev/null; }   # window option (empty if unset)

# --- pull the REAL conf format (the thing we actually ship) -------------------
FMT="$(sed -n 's/^[[:space:]]*set\(-option\)\{0,1\}[[:space:]]\{1,\}-g[[:space:]]\{1,\}pane-border-format[[:space:]]\{1,\}"\(.*\)"[[:space:]]*$/\2/p' "$CONF")"
[ -n "$FMT" ] || fail "could not extract pane-border-format from $CONF"
case "$FMT" in
  *'@summary'*) ok "conf pane-border-format references @summary" ;;
  *) fail "conf pane-border-format does not render @summary (issue #455)" ;;
esac
# The rail itself: no spawn/summarize path may rename a window to the summary.
if grep -rn 'rename-window' "$BIN/tmux-summarize.sh" >/dev/null 2>&1; then
  fail "tmux-summarize.sh must never rename a window (issue #455)"
fi
ok "summarizer contains no rename-window"

# raw() is the border string tmux would hand format_draw (styles still embedded);
# render() strips the #[...] style tokens off it → the visible text.
raw()    { tmux display-message -p -t "$1" "$FMT"; }
render() { raw "$1" | sed -E 's/#\[[^]]*\]//g'; }

# --- build a fleet-shaped session on the isolated server ----------------------
# -f /dev/null: a clean server (no ~/.tmux.conf bleed). Everything is targeted by
# captured id, never a numeric index, so the test is base-index-agnostic.
tmux -f /dev/null new-session -d -s fleet-t -x 140 -y 40 \
  || fail "could not start isolated tmux server"
SESS=fleet-t

# a worker window whose pane prints stable text for capture-pane to hash
ww="$(tmux display-message -p '#{window_id}')"
tmux rename-window -t "$ww" issue-455
tmux set-window-option -t "$ww" @issue 455
tmux set-window-option -t "$ww" @claude_state working
tmux respawn-pane -k -t "$ww" "printf 'grinding on the pane header\n'; sleep 300" 2>/dev/null \
  || fail "could not seed worker pane content"
tmux send-keys -t "$ww" '' 2>/dev/null    # nudge the pane to draw

# a second worker window, so "the RIGHT window_id" is a real assertion
w2="$(tmux new-window -P -F '#{window_id}' -t "$SESS:" -n other-worker \
      "printf 'a different worker\n'; sleep 300")"
tmux set-window-option -t "$w2" @claude_state working

# wait for the pane to actually have text (capture-pane is what gates a summary)
i=0
while [ "$i" -lt 40 ]; do
  [ -n "$(tmux capture-pane -p -t "$ww" 2>/dev/null | tr -d '[:space:]')" ] && break
  i=$((i+1)); sleep 0.1
done
[ -n "$(tmux capture-pane -p -t "$ww" 2>/dev/null | tr -d '[:space:]')" ] \
  || fail "isolated worker pane never rendered content"

G="$WORK/.claude-dash/global"
key="$(fleet_summary_key "$SESS" "$ww")"

# summarize <fixture> — park a fake-LLM answer and run the REAL --window path.
# Each call varies the fixture, and the change-gate hashes the SCREEN (not the
# answer), so the hash file is cleared to force a fresh summary every time.
summarize() {
  printf '%s' "$1" > "$WORK/claude-out"
  rm -f "$WORK/.claude-dash/global/sumhash/$key.hash" "$G/summary_$key"
  bash "$SUT" --window "$ww" || fail "summarizer exited non-zero"
}

# --- PUBLISH: one call feeds BOTH the option and the file --------------------
name_before="$(tmux display-message -p -t "$ww" '#{window_name}')"
summarize 'wiring the pane header summary token'
[ "$(wopt "$ww" @summary)" = 'wiring the pane header summary token' ] \
  || fail "@summary not published on the worker window — got [$(wopt "$ww" @summary)]"
ok "--window publishes @summary on the summarized window"
[ -f "$G/summary_$key" ] || fail "the dash summary FILE ($G/summary_$key) was not written"
[ "$(cat "$G/summary_$key")" = 'wiring the pane header summary token' ] \
  || fail "summary file content changed — got [$(cat "$G/summary_$key")]"
ok "the dash summary file is still written with the unchanged key/format"
[ -z "$(wopt "$w2" @summary)" ] \
  || fail "@summary leaked onto a DIFFERENT window — got [$(wopt "$w2" @summary)]"
ok "@summary lands on the right window_id only"

# --- NO-RENAME: the window name is untouched ---------------------------------
name_after="$(tmux display-message -p -t "$ww" '#{window_name}')"
[ "$name_before" = "$name_after" ] \
  || fail "window_name changed across a summarize run: [$name_before] → [$name_after]"
[ "$name_after" = issue-455 ] || fail "window_name drifted — got [$name_after]"
ok "window_name is byte-identical before/after a summarize run"

# --- ROUTING: worker renders it; hub + dash panes do not ---------------------
worker="$(render "$ww")"
case "$worker" in
  *"issue-455"*"#455"*"wiring the pane header"*) ok "worker header shows name + issue + summary" ;;
  *) fail "worker header missing name/issue/summary — got [$worker]" ;;
esac

hw="$(tmux new-window -P -F '#{window_id}' -t "$SESS:" -n plan)"
tmux set-window-option -t "$hw" @summary 'should never be drawn'
dp="$(tmux display-message -p -t "$hw" '#{pane_id}')"
tmux set-option -p -t "$dp" @dash 1
sp="$(tmux split-window -P -F '#{pane_id}' -v -t "$hw")"
tmux set-option -p -t "$sp" @hub 1

hubpane="$(render "$sp")"
case "$hubpane" in
  *"FLEET HUB"*) : ;;
  *) fail "hub pane lost its hub cue — got [$hubpane]" ;;
esac
case "$hubpane" in
  *"should never be drawn"*) fail "hub pane leaked the summary — got [$hubpane]" ;;
esac
ok "hub pane keeps its own cue and renders no summary"

dash="$(render "$dp")"
[ -z "$(printf '%s' "$dash" | tr -d '[:space:]')" ] \
  || fail "hub dash pane must stay empty — got [$dash]"
ok "dash pane header stays empty"

# --- GUARD: no @summary ⇒ exactly the pre-#455 header ------------------------
gw="$(tmux new-window -P -F '#{window_id}' -t "$SESS:" -n scratch)"
bare="$(render "$gw")"
case "$bare" in
  *"scratch"*) : ;;
  *) fail "bare header lost the window name — got [$bare]" ;;
esac
case "$bare" in
  *"·"*) fail "un-summarized window renders a dangling separator — got [$bare]" ;;
esac
ok "a window with no @summary renders the pre-#455 header"

# --- SANITIZE: '#', newlines and overlong text can't reach the border --------
# The summarizer's own pipeline keeps only the first line; hand the sanitizer the
# multi-line/'#'-bearing cases directly, and drive the '#' + length cases end to end.
long="$(awk 'BEGIN{s="";for(i=0;i<200;i++)s=s "x";print s}')"
summarize "#[fg=red]#{window_name} danger $long"
got="$(wopt "$ww" @summary)"
case "$got" in
  *"#"*) fail "a '#' survived into @summary — got [$got]" ;;
esac
[ "${#got}" -le 60 ] || fail "@summary not clipped (${#got} chars) — got [$got]"
ok "sanitize strips '#' and clips the option to <=60 chars"

multi="$(printf 'first line\nsecond line\twith tab')"
clean="$(fleet_summary_sanitize "$multi")"
[ "$clean" = 'first line second line with tab' ] \
  || fail "newline/tab not collapsed to one line — got [$clean]"
ok "sanitize collapses newlines/tabs into one line"
[ "$(fleet_summary_sanitize '  #[bold]#{q}  spaced   out  ')" = '[bold]{q} spaced out' ] \
  || fail "sanitize trim/squeeze diverged — got [$(fleet_summary_sanitize '  #[bold]#{q}  spaced   out  ')]"
ok "sanitize squeezes runs and trims"

# The '#'-bearing summary must still render a well-formed border: the identity half
# survives, and what the LLM wrote arrives as INERT TEXT — no '#[' style token and no
# '#{' format token reach format_draw, so "#[fg=red]" draws as a literal "[fg=red]"
# and "#{window_name}" as "{window_name}" instead of being interpreted.
rendered="$(render "$ww")"
case "$rendered" in
  *"issue-455"*"#455"*) : ;;
  *) fail "border broke on a '#'-bearing summary — got [$rendered]" ;;
esac
case "$(raw "$ww")" in
  *'#[fg=red]'*) fail "a style token leaked into the border — got [$(raw "$ww")]" ;;
esac
case "$rendered" in
  *'[fg=red]{window_name}'*) : ;;
  *) fail "the '#'-stripped summary did not render as inert text — got [$rendered]" ;;
esac
ok "a '#'-bearing summary renders as inert text — no style/format leak"

# --- INERT: ',' '{' '%' are data, not syntax ---------------------------------
summarize 'landed 3 PRs, {rebasing} 50% done'
[ "$(wopt "$ww" @summary)" = 'landed 3 PRs, {rebasing} 50% done' ] \
  || fail "punctuation mangled in @summary — got [$(wopt "$ww" @summary)]"
meta="$(render "$ww")"
case "$meta" in
  *"landed 3 PRs, {rebasing} 50% done"*) ok "',' '{' '%' render literally in the border" ;;
  *) fail "punctuation did not render literally — got [$meta]" ;;
esac

# --- NO-MCP: the helper `claude -p` boots no MCP server (issue #468) ---------
summarize 'no mcp on the classifier call'
argv="$(cat "$WORK/claude-argv" 2>/dev/null)"
case "$argv" in
  *--strict-mcp-config*) : ;;
  *) fail "helper claude -p is missing --strict-mcp-config" "$argv" ;;
esac
case "$argv" in
  *'"mcpServers":{}'*|*'{"mcpServers": {}}'*) : ;;
  *) fail "--strict-mcp-config was passed without an empty --mcp-config to pin it to" "$argv" ;;
esac
ok "the helper claude -p call carries --strict-mcp-config + an empty --mcp-config"

FLEET_HELPER_NO_MCP=0 summarize 'escape hatch'
argv="$(cat "$WORK/claude-argv" 2>/dev/null)"
case "$argv" in
  *--strict-mcp-config*) fail "FLEET_HELPER_NO_MCP=0 did not drop the MCP flags" "$argv" ;;
esac
case "$argv" in
  *--model*) ok "FLEET_HELPER_NO_MCP=0 drops the MCP flags and still passes --model" ;;
  *) fail "the escape hatch dropped more than the MCP flags" "$argv" ;;
esac

printf 'selftest OK: %s checks — pane header carries @summary and never renames a window (issue #455)\n' "$pass"
