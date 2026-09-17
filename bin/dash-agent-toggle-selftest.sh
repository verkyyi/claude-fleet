#!/bin/bash
# dash-agent-toggle-selftest.sh — the dash prompt line's agent label + the ⌃v
# fleet-agent flip (issue #554).
#
# Two scripts under test:
#   bin/dash-agent-prompt.sh  — ONE derivation of the label: effective FLEET_AGENT
#                               (global fleet.conf → per-fleet overlay → claude) →
#                               `claude ▸ ` / `codex ▸ ` (codex in the #547 row-tag
#                               colour) + the ghost `↵ 新开 scratch（预填不发送） · 切换 agent:
#                               <key>` naming the RESOLVED toggle key (#559 — the
#                               `<agent>:` one-off prefix hint is gone with the
#                               prefix); `actions` = the change-prompt/change-ghost
#                               pair the dash's load/⌃r ticks apply.
#   bin/dash-agent-toggle.sh  — ⌃v: flip FLEET_AGENT in the fleet's conf through
#                               the config-modal write path (fcfg_validate +
#                               fcfg_write — atomic, backup-first, other keys kept),
#                               toast, emit the relabel actions.
#
# Hermetic: a fake `tmux` answers session_name and logs display-message; the conf
# estate lives in a temp FLEET_CONF_DIR; TMPDIR is sandboxed so the rename flag
# the helper honours can never be the live dash's. No network, no git, no claude.
# A LIVE tail (skipped when tmux or fzf is absent — CI has no fzf) launches real
# fzf on a private `-S` socket with the dash's own bind and presses ⌃v: the pane
# must show the recoloured prompt — the first-')' truncation class of bug (#449)
# only surfaces inside fzf. A second live tail sets THAT server's prefix to C-v
# (issue #556): the bind resolved inside the pane must land on ⌥v, ⌥v must flip,
# and a bare ⌃v must do nothing — tmux eats it. Exit 0 = pass (or SKIP); non-zero
# = the failing assert.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PROMPT="$BIN/dash-agent-prompt.sh"; TOGGLE="$BIN/dash-agent-toggle.sh"
for f in "$PROMPT" "$TOGGLE" "$BIN/fleet-lib.sh" "$BIN/fleet-config-lib.sh" "$BIN/../fleet.conf.example" \
         "$BIN/tmux-dashboard.sh" "$BIN/dash-enter.sh" "$BIN/dash-esc.sh" "$BIN/fleet-keys.sh"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-agent-selftest.XXXXXX")" || exit 2
REAL_TMUX="$(command -v tmux 2>/dev/null || true)"
LIVE_SOCK="$WORK/live.sock"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$LIVE_SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# --- sandbox --------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/.claude-dash/global"
for f in dash-agent-prompt.sh dash-agent-toggle.sh dash-keymap.sh fleet-lib.sh fleet-config-lib.sh; do ln -s "$BIN/$f" "$WORK/bin/$f"; done
ln -s "$BIN/../fleet.conf.example" "$WORK/fleet.conf.example"   # fcfg_default / fcfg_validate read it off ../
DISPLAY_LOG="$WORK/display"
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  display-message)
    case "$*" in
      *-p*) case "$*" in *session_name*) printf '%s\n' "${SESS_NAME:-}";; *) echo "";; esac ;;
      *)    printf '%s\n' "$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  *) : ;;
esac
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"
export PATH="$WORK/fakebin:$PATH" DISPLAY_LOG
export TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
export FLEET_SESSION=testsess SESS_NAME=testsess
# pin the tmux prefix the resolver sees (issue #556) so the toast's key glyph is
# deterministic here — the live tails below unset it and use the real server's
export FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2=''
unset FLEET_AGENT 2>/dev/null || true
KM="$WORK/bin/dash-keymap.sh"
CONF="$WORK/conf/fleets/testsess/conf"
P="$WORK/bin/dash-agent-prompt.sh"; T="$WORK/bin/dash-agent-toggle.sh"
E=$'\033['; IN="${E}38;2;187;154;247m"; RD="${E}38;2;247;118;142m"; RS="${E}0m"
CODEX_PROMPT="${IN}codex${RS} ▸ "
agent_line() { grep -E '^[[:space:]]*FLEET_AGENT=' "$CONF" 2>/dev/null; }

# --- A. unset conf → claude, plain; ghost = ↵ hint + the RESOLVED toggle key -------
out=$(bash "$P" agent)  || fail "A: prompt helper (agent) exited non-zero" "$out"
[ "$out" = claude ] || fail "A: unset conf must resolve to claude (got: $out)"
out=$(bash "$P" prompt) || fail "A: prompt helper (prompt) exited non-zero" "$out"
[ "$out" = 'claude ▸ ' ] || fail "A: prompt for claude must be the plain 'claude ▸ ' (got: $(printf '%q' "$out"))"
out=$(bash "$P" ghost)
[ "$out" = '↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v' ] || fail "A: ghost must be ONE line — ↵ meaning + the resolved toggle key (⌃v under a C-b prefix), #559" "$(printf '%q' "$out")"
case "$out" in *'codex:'*|*'claude:'*) fail "A: the ghost must NOT advertise a codex:/claude: prefix (removed in #559)" "$out" ;; esac
# the key is the resolver's, never a literal: under a C-v prefix it must say ⌥v …
out=$(FLEET_TMUX_PREFIX=C-v bash "$P" ghost)
[ "$out" = '↵ 新开 scratch（预填不发送） · 切换 agent: ⌥v' ] || fail "A: with ⌃v as the tmux prefix the ghost must name ⌥v (#556 remap)" "$(printf '%q' "$out")"
# … and the dash's exported launch-time glyph wins over a fresh resolve, so the
# ghost names the key fzf actually BOUND even if the prefix changed mid-dash.
out=$(DASH_GLYPH_AGENT='⌥v' bash "$P" ghost)
[ "$out" = '↵ 新开 scratch（预填不发送） · 切换 agent: ⌥v' ] || fail "A: DASH_GLYPH_AGENT from the launcher must win over the resolver" "$(printf '%q' "$out")"
out=$(DASH_GLYPH_AGENT='⌃v (x)' bash "$P" ghost)
case "$out" in *'('*|*')'*) fail "A: parens in the glyph must be stripped (fzf stops change-ghost at the first ')')" "$out" ;; esac
out=$(bash "$P" actions)
[ "$out" = 'change-prompt(claude ▸ )+change-ghost(↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v)' ] \
  || fail "A: actions for an unset conf" "$(printf '%q' "$out")"
ok "A unset conf → 'claude ▸ ', ghost = ↵ hint + resolved key (⌃v / ⌥v / launcher env), no prefix hint"

# --- B. ⌃a → codex written to the fleet conf, other keys kept, relabel emitted --
# seed the overlay with a neighbour key + a comment so a clobbering write shows.
mkdir -p "$(dirname "$CONF")"
printf '# seeded by the selftest\nFLEET_MODEL="fable"\n' > "$CONF"
out=$(bash "$T") || fail "B: toggle exited non-zero" "$out"
[ "$(agent_line)" = 'FLEET_AGENT="codex"' ] || fail "B: conf must now carry FLEET_AGENT=\"codex\"" "$(cat "$CONF")"
[ "$(agent_line | wc -l | tr -d ' ')" = 1 ] || fail "B: exactly one FLEET_AGENT line" "$(cat "$CONF")"
grep -qx 'FLEET_MODEL="fable"' "$CONF" || fail "B: the neighbour key FLEET_MODEL must survive the write" "$(cat "$CONF")"
grep -qx '# seeded by the selftest' "$CONF" || fail "B: the comment line must survive the write" "$(cat "$CONF")"
[ -f "$CONF.bak" ] || fail "B: fcfg_write backs the conf up first (.bak missing)"
[ "$out" = "change-prompt(${CODEX_PROMPT})+change-ghost(↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v)" ] \
  || fail "B: toggle must emit change-prompt(<IN>codex<reset> ▸ )+change-ghost(↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v) — same ghost either way (#559)" "$(printf '%q' "$out")"
grep -q 'new sessions → codex' "$DISPLAY_LOG" || fail "B: toast 'fleet: new sessions → codex' missing" "$(cat "$DISPLAY_LOG")"
grep -q '⌃v flips back' "$DISPLAY_LOG" || fail "B: the toast must name the resolved key (⌃v under a C-b prefix)" "$(cat "$DISPLAY_LOG")"
grep -Eq 'codex:|claude:' "$DISPLAY_LOG" && fail "B: the toast must not advertise a codex:/claude: prefix (removed in #559)" "$(cat "$DISPLAY_LOG")"
[ "$(bash "$P" agent)" = codex ] || fail "B: the helper must now read codex from the conf"
[ "$(bash "$P" prompt)" = "$CODEX_PROMPT" ] || fail "B: prompt for codex must be coloured IN (#547 tag colour)" "$(bash "$P" prompt | od -c | head -3)"
ok "B ⌃v → FLEET_AGENT=\"codex\" (neighbours + comment kept, .bak), coloured relabel + toast"

# --- B2. the toast follows the resolver: with ⌃v as the tmux prefix it says ⌥v ------
# (issue #556 — never tell the operator to press a key tmux will eat). Two flips
# so the conf is back on codex for C.
: > "$DISPLAY_LOG"
out=$(FLEET_TMUX_PREFIX=C-v bash "$T") || fail "B2: toggle under a C-v prefix exited non-zero" "$out"
[ "$(agent_line)" = 'FLEET_AGENT="claude"' ] || fail "B2: the flip itself is unaffected by the prefix" "$(cat "$CONF")"
grep -q '⌥v flips back' "$DISPLAY_LOG" || fail "B2: with prefix C-v the toast must say ⌥v flips back" "$(cat "$DISPLAY_LOG")"
grep -q '⌃v flips back' "$DISPLAY_LOG" && fail "B2: … and must NOT still advertise ⌃v" "$(cat "$DISPLAY_LOG")"
[ "$out" = "change-prompt(claude ▸ )+change-ghost(↵ 新开 scratch（预填不发送） · 切换 agent: ⌥v)" ] \
  || fail "B2: the change-ghost the toggle emits must name ⌥v too (same resolver as the toast)" "$(printf '%q' "$out")"
out=$(FLEET_TMUX_PREFIX=C-v bash "$T") || fail "B2: second toggle exited non-zero" "$out"
[ "$(agent_line)" = 'FLEET_AGENT="codex"' ] || fail "B2: back on codex" "$(cat "$CONF")"
ok "B2 toast + ghost name the RESOLVED key: ⌥v when ⌃v is the tmux prefix"

# --- C. ⌃a again → back to claude ---------------------------------------------------
: > "$DISPLAY_LOG"
out=$(bash "$T") || fail "C: second toggle exited non-zero" "$out"
[ "$(agent_line)" = 'FLEET_AGENT="claude"' ] || fail "C: conf must flip back to FLEET_AGENT=\"claude\"" "$(cat "$CONF")"
[ "$(agent_line | wc -l | tr -d ' ')" = 1 ] || fail "C: still exactly one FLEET_AGENT line (in-place replace)" "$(cat "$CONF")"
grep -qx 'FLEET_MODEL="fable"' "$CONF" || fail "C: FLEET_MODEL must survive the second write" "$(cat "$CONF")"
[ "$out" = 'change-prompt(claude ▸ )+change-ghost(↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v)' ] \
  || fail "C: second toggle must relabel back to the plain claude prompt" "$(printf '%q' "$out")"
grep -q 'new sessions → claude' "$DISPLAY_LOG" || fail "C: toast 'fleet: new sessions → claude' missing" "$(cat "$DISPLAY_LOG")"
ok "C ⌃v again → FLEET_AGENT=\"claude\", plain relabel + toast"

# --- D. unknown value renders as-is (no crash) and toggles to claude ---------------
printf '# seeded by the selftest\nFLEET_MODEL="fable"\nFLEET_AGENT="gemini (beta)"\n' > "$CONF"
out=$(bash "$P" agent); rc=$?
[ "$rc" -eq 0 ] || fail "D: an unknown FLEET_AGENT must not crash the helper (rc=$rc)" "$out"
[ "$out" = 'gemini beta' ] || fail "D: unknown value renders as-is, parens stripped (fzf stops at the first ')')" "$(printf '%q' "$out")"
out=$(bash "$P" prompt)
[ "$out" = "${RD}gemini beta${RS} ▸ " ] || fail "D: unknown value is drawn red, as-is" "$(printf '%q' "$out")"
out=$(bash "$P" actions)
case "$out" in 'change-prompt('*'gemini beta'*" ▸ )+change-ghost(↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v)") ;; *) fail "D: actions for an unknown value" "$(printf '%q' "$out")" ;; esac
out=$(bash "$T") || fail "D: toggle on an unknown value exited non-zero" "$out"
[ "$(agent_line)" = 'FLEET_AGENT="claude"' ] || fail "D: an unknown value must toggle to claude" "$(cat "$CONF")"
ok "D unknown conf value renders as-is (red, parens stripped), toggles to claude"

# --- E. rename/bind armed → the tick emits nothing, ⌃a is a no-op ------------------
: > "$WORK/.claude-dash/rename_target"
before=$(cat "$CONF")
out=$(bash "$P" actions) || fail "E: actions with a rename armed exited non-zero" "$out"
[ -z "$out" ] || fail "E: with a rename armed the load tick must emit NO action (it would clobber 'rename ▸ ')" "$out"
out=$(bash "$T") || fail "E: toggle with a rename armed exited non-zero" "$out"
[ -z "$out" ] || fail "E: ⌃v during a rename must be a no-op (emit nothing)" "$out"
[ "$(cat "$CONF")" = "$before" ] || fail "E: ⌃v during a rename must not touch the conf" "$(cat "$CONF")"
rm -f "$WORK/.claude-dash/rename_target"
[ -n "$(bash "$P" actions)" ] || fail "E: once the flag is gone the tick emits again"
ok "E rename armed → no tick action, ⌃v no-op; resumes when the flag clears"

# --- F. outside a fleet → toast, nothing written ---------------------------------------
: > "$DISPLAY_LOG"
out=$(env -u FLEET_SESSION SESS_NAME= bash "$T") || fail "F: toggle outside a fleet exited non-zero" "$out"
[ -z "$out" ] || fail "F: outside a fleet ⌃v must emit no action" "$out"
grep -q 'not inside a fleet' "$DISPLAY_LOG" || fail "F: outside a fleet the toast must say so" "$(cat "$DISPLAY_LOG")"
[ "$(find "$WORK/conf" -type f -name conf | wc -l | tr -d ' ')" = 1 ] || fail "F: no conf may be created outside a fleet" "$(find "$WORK/conf" -type f)"
out=$(env -u FLEET_SESSION SESS_NAME= bash "$P" prompt) || fail "F: helper outside a fleet exited non-zero" "$out"
[ "$out" = 'claude ▸ ' ] || fail "F: outside a fleet the label falls back to claude" "$(printf '%q' "$out")"
ok "F outside a fleet → toast, nothing written, label falls back to claude"

# --- G. the global layer counts, the fleet overlay wins ----------------------------------
rm -f "$CONF" "$CONF.bak"
printf 'FLEET_AGENT="codex"\n' > "$WORK/fleet.conf"      # = $BIN/../fleet.conf for the sandboxed bin/
[ "$(bash "$P" agent)" = codex ] || fail "G: a global-layer FLEET_AGENT=codex must show (no overlay)"
out=$(bash "$T") || fail "G: toggle over a global codex exited non-zero" "$out"
[ "$(agent_line)" = 'FLEET_AGENT="claude"' ] || fail "G: the flip lands in the FLEET overlay (global untouched)" "$(cat "$CONF" 2>/dev/null)"
grep -qx 'FLEET_AGENT="codex"' "$WORK/fleet.conf" || fail "G: the global fleet.conf must not be rewritten"
[ "$(bash "$P" agent)" = claude ] || fail "G: the overlay must now win over the global layer"
rm -f "$WORK/fleet.conf"
ok "G global layer read; ⌃v writes the fleet overlay, which wins"

# --- H. wiring: the dash launches, ticks, flips and restores through the helpers -------
DASH="$BIN/tmux-dashboard.sh"
# the key is NOT a literal (issue #556): $DASH_KEY_AGENT from dash-keymap.sh, whose
# default is ctrl-v — asserted through the resolver, so this can't drift back to ⌃a.
grep -Eq -- '--bind "\$DASH_KEY_AGENT:transform\(bash \$BIN/dash-agent-toggle\.sh\)"' "$DASH" \
  || fail "H: tmux-dashboard.sh must bind \$DASH_KEY_AGENT to transform(bash \$BIN/dash-agent-toggle.sh)"
grep -q -- '--bind "ctrl-a:' "$DASH" && fail "H: ctrl-a is the operator's tmux prefix — never a dash bind (#556)"
[ "$(bash "$KM" key agent)" = ctrl-v ] || fail "H: the agent flip must resolve to ctrl-v under the pinned C-b prefix"
grep -Eq '^AGENT_PROMPT="\$BIN/dash-agent-prompt\.sh"' "$DASH" || fail "H: tmux-dashboard.sh must name the helper as AGENT_PROMPT"
grep -Eq -- '--prompt="\$PROMPT_NOW" --ghost="\$GHOST_NOW"' "$DASH" || fail "H: --prompt/--ghost must come from the helper, not literals"
grep -Eq 'PROMPT_NOW=\$\(bash "\$AGENT_PROMPT" prompt' "$DASH" || fail "H: PROMPT_NOW must be derived from the helper"
grep -Eq 'GHOST_NOW=\$\(bash "\$AGENT_PROMPT" ghost' "$DASH" || fail "H: GHOST_NOW must be derived from the helper"
grep -Eq '^\s*export DASH_GLYPH_AGENT\b' "$DASH" || fail "H: tmux-dashboard.sh must export DASH_GLYPH_AGENT so the ghost names the key it actually bound (#559)"
grep -Eq 'codex: prefix|claude: prefix|prefix for a one-off' "$DASH" "$PROMPT" "$TOGGLE" "$BIN/dash-enter.sh" "$BIN/fleet-keys.sh" \
  && fail "H: a codex:/claude: prefix hint survives somewhere (#559 removed the prefix)" "$(grep -nE 'codex: prefix|claude: prefix|prefix for a one-off' "$DASH" "$PROMPT" "$TOGGLE" "$BIN/dash-enter.sh" "$BIN/fleet-keys.sh")"
grep -Eq -- '--bind "load:reload-sync\(sleep \$REFRESH; sh \$WAIT; bash \$ROWS\)\+transform\(bash \$AGENT_PROMPT actions\)"' "$DASH" || fail "H: the load tick must re-derive the label (after the popup-waited reload, #308)"
grep -Eq -- '--bind "\$DASH_KEY_RELOAD:reload\(bash \$ROWS\)\+transform\(bash \$AGENT_PROMPT actions\)"' "$DASH" || fail "H: ⌃r (via \$DASH_KEY_RELOAD) must re-derive the label"
for f in dash-enter.sh dash-esc.sh; do
  grep -q 'dash-agent-prompt.sh" prompt' "$BIN/$f" || fail "H: $f must restore the prompt through dash-agent-prompt.sh"
  grep -q 'change-prompt(▸ )' "$BIN/$f" && fail "H: $f still restores a literal '▸ ' prompt (drops the agent label)"
done
grep -q 'key "$(dg agent)"' "$BIN/fleet-keys.sh" || fail "H: fleet-keys.sh dashboard sheet must document the flip via dg agent"
sheet=$(NO_COLOR=1 bash "$BIN/fleet-keys.sh" --plain --context dash)   # capture first: grep -q + pipefail would SIGPIPE the sheet
printf '%s\n' "$sheet" | grep -q '^  ⌃v  *flip this fleet' || fail "H: the rendered sheet must show ⌃v for the flip" "$sheet"
ok "H dash wiring: \$DASH_KEY_AGENT (ctrl-v) bind, helper-derived --prompt/--ghost, DASH_GLYPH_AGENT exported, load/⌃r re-derive, enter/esc restore, ? sheet, no prefix hint"

# --- I. shellcheck (when present) -------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  sc="$(shellcheck -x "$PROMPT" "$TOGGLE" 2>&1)" || fail "I: helpers not shellcheck-clean" "$sc"
  ok "I dash-agent-prompt.sh / dash-agent-toggle.sh are shellcheck-clean"
fi

# --- J. LIVE: real fzf on a private socket, the dash's own ⌃v bind ----------------------
if [ -n "$REAL_TMUX" ] && command -v fzf >/dev/null 2>&1; then
  rm -f "$CONF" "$CONF.bak"
  LIVE_PATH="${PATH#"$WORK/fakebin:"}"   # the pane talks to the REAL tmux on the private socket
  "$REAL_TMUX" -S "$LIVE_SOCK" new-session -d -x 70 -y 6 -s testsess \
    "export PATH='$LIVE_PATH' TMPDIR='$WORK' FLEET_CONF_DIR='$WORK/conf' FLEET_SKIP_GLOBAL_CONF=1 FLEET_SESSION=testsess; \
     fzf --prompt=\"\$(bash '$P' prompt)\" --ghost=\"\$(bash '$P' ghost)\" --disabled --info=hidden --no-separator \
         --bind 'ctrl-v:transform(bash $T)' </dev/null; sleep 30" 2>/dev/null \
    || fail "J: could not start the private tmux server"
  n=0; until "$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess 2>/dev/null | grep -Fq 'claude ▸'; do
    n=$((n+1)); [ "$n" -gt 50 ] && fail "J: fzf never drew the 'claude ▸' prompt" "$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess 2>&1)"
    sleep 0.1
  done
  pane=$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess)
  case "$pane" in *'切换 agent: ⌃v'*) ;; *) fail "J: the ghost must name the resolved toggle key (⌃v under the pinned C-b prefix)" "$pane" ;; esac
  case "$pane" in *'codex:'*|*'claude:'*) fail "J: the ghost must not advertise a codex:/claude: prefix (#559)" "$pane" ;; esac
  "$REAL_TMUX" -S "$LIVE_SOCK" send-keys -t testsess C-v
  n=0; until "$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess 2>/dev/null | grep -Fq "${IN}codex"; do
    n=$((n+1)); [ "$n" -gt 50 ] && fail "J: after ⌃v the pane must show codex in the IN colour" "$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess | cat -v)"
    sleep 0.1
  done
  pane=$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess)
  case "$pane" in *'切换 agent: ⌃v'*) ;; *) fail "J: after ⌃v the ghost must still name the toggle key (one ghost, both agents)" "$(printf '%s' "$pane" | cat -v)" ;; esac
  case "$pane" in *'codex:'*|*'claude:'*) fail "J: after ⌃v the ghost must still carry no prefix hint (#559)" "$(printf '%s' "$pane" | cat -v)" ;; esac
  [ "$(agent_line)" = 'FLEET_AGENT="codex"' ] || fail "J: the live ⌃v must have written FLEET_AGENT=\"codex\"" "$(cat "$CONF" 2>/dev/null)"
  "$REAL_TMUX" -S "$LIVE_SOCK" kill-server 2>/dev/null
  ok "J live fzf: ⌃v recolours the prompt, ghost names the key, persists the conf"

  # --- K. LIVE: the server's prefix IS ⌃v → the bind resolved in the pane is ⌥v -------
  # The #556 failure end to end: the pane's own `tmux show -gv prefix` (via $TMUX on
  # the private socket) says C-v, so dash-keymap.sh hands fzf alt-v. ⌥v must flip;
  # a bare ⌃v must NOT — tmux eats it as the prefix before fzf ever sees it.
  rm -f "$CONF" "$CONF.bak"
  "$REAL_TMUX" -S "$LIVE_SOCK" new-session -d -x 70 -y 6 -s testsess "sleep 60" 2>/dev/null \
    || fail "K: could not start the private tmux server"
  "$REAL_TMUX" -S "$LIVE_SOCK" set -g prefix C-v
  "$REAL_TMUX" -S "$LIVE_SOCK" respawn-pane -k -t testsess \
    "unset FLEET_TMUX_PREFIX FLEET_TMUX_PREFIX2; export PATH='$LIVE_PATH' TMPDIR='$WORK' FLEET_CONF_DIR='$WORK/conf' FLEET_SKIP_GLOBAL_CONF=1 FLEET_SESSION=testsess; \
     k=\$(bash '$KM' key agent); echo \"\$k\" > '$WORK/k.resolved'; \
     fzf --prompt=\"\$(bash '$P' prompt)\" --ghost=\"\$(bash '$P' ghost)\" --disabled --info=hidden --no-separator \
         --bind \"\${k}:transform(bash $T)\" </dev/null; sleep 30" \
    || fail "K: could not respawn the pane with the resolved bind"
  n=0; until "$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess 2>/dev/null | grep -Fq 'claude ▸'; do
    n=$((n+1)); [ "$n" -gt 50 ] && fail "K: fzf never drew the 'claude ▸' prompt" "$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess 2>&1)"
    sleep 0.1
  done
  [ "$(cat "$WORK/k.resolved" 2>/dev/null)" = alt-v ] || fail "K: inside a pane whose server prefix is C-v the flip must resolve to alt-v" "$(cat "$WORK/k.resolved" 2>/dev/null)"
  pane=$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess)
  case "$pane" in *'切换 agent: ⌥v'*) ;; *) fail "K: the ghost drawn in a C-v-prefix pane must name ⌥v — the key the bind holds (#559)" "$(printf '%s' "$pane" | cat -v)" ;; esac
  "$REAL_TMUX" -S "$LIVE_SOCK" send-keys -t testsess M-v
  n=0; until "$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess 2>/dev/null | grep -Fq "${IN}codex"; do
    n=$((n+1)); [ "$n" -gt 50 ] && fail "K: ⌥v must flip the prompt to codex" "$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess | cat -v)"
    sleep 0.1
  done
  [ "$(agent_line)" = 'FLEET_AGENT="codex"' ] || fail "K: the live ⌥v must have written FLEET_AGENT=\"codex\"" "$(cat "$CONF" 2>/dev/null)"
  "$REAL_TMUX" -S "$LIVE_SOCK" send-keys -t testsess C-v      # the prefix: tmux keeps it
  sleep 0.7
  [ "$(agent_line)" = 'FLEET_AGENT="codex"' ] || fail "K: a bare ⌃v (the prefix) must NOT reach fzf — conf flipped" "$(cat "$CONF" 2>/dev/null)"
  "$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess | grep -Fq "${IN}codex" || fail "K: after a bare ⌃v the prompt must still read codex" "$("$REAL_TMUX" -S "$LIVE_SOCK" capture-pane -p -e -t testsess | cat -v)"
  "$REAL_TMUX" -S "$LIVE_SOCK" kill-server 2>/dev/null
  ok "K live fzf under prefix C-v: bind + ghost resolve to ⌥v, ⌥v flips, a bare ⌃v is eaten by tmux"
else
  printf 'skip J/K live fzf tails (tmux or fzf not installed)\n'
fi

printf 'dash-agent-toggle-selftest: %d checks passed\n' "$pass"
exit 0
