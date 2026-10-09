#!/bin/bash
# fleet-quick-dispatch-selftest.sh — ⌘T 派一件事 (issue #2753): bin/fleet-quick-dispatch.py.
#
#   A. the payload: the writing area's own (fleet-compose.py payload) for one
#      line — title, repo, agent codex only when asked, `via: dispatch`
#   B. the repo a ↵ goes to untouched: the last one used (compose-state.json,
#      shared with the writing area) while the hub still names it, else the first
#   C. no list on screen: --send runs from here (FLEET_DISPATCH_SEND_CMD), and
#      the last repo is remembered
#   D. a list on screen (an isolated tmux server): the payload waits in
#      compose-send.json and the list gets `compose` on its @sidebar_do — the
#      writing area's own road, nothing else
#   E. fleet-compose.py --send says the issue a `new` filed (`filed: #N` on
#      stderr) so the list can say 「已建 #N 并开工」; stdout stays the place's line
#   F. the key: ⌘T / prefix t open it (conf/tmux-shell.conf, dash-keymap.sh), the
#      bar says 「⌘T 派单」, ⌘P's first line is 「⚡ 派一件事…」 (fleet-quickopen.py)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
CHECKS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (no '$3')" "$2" ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fdisp.XXXXXX") || fail "mktemp"
REAL_TMUX=$(command -v tmux || true)
cleanup() {
  [ -n "$REAL_TMUX" ] && TMUX_TMPDIR="$WORK/tt" "$REAL_TMUX" kill-server 2>/dev/null   # this test's own server
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
# never the server this test runs in: no $TMUX, a private TMUX_TMPDIR
unset TMUX TMUX_PANE
mkdir -p "$WORK/tt" "$WORK/state" "$WORK/g"
export TMUX_TMPDIR="$WORK/tt" FLEET_SWITCH_STATE="$WORK/state" FLEET_STATUS_G="$WORK/g" FLEET_UI_LANG=zh \
  FLEET_COMPOSE_LOG="$WORK/compose.ndjson"
printf 'acme/app\nacme/web\n' > "$WORK/g/hub_repos"
D() { python3 "$BIN/fleet-quick-dispatch.py" "$@"; }
J() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get(sys.argv[1]))' "$1"; }

# --- A. the payload --------------------------------------------------------------
p=$(D payload --title '  修 登录 bug  ' --repo acme/web) || fail "A: payload exited non-zero"
eq 'A: the title, one line, trimmed' '修 登录 bug' "$(printf '%s' "$p" | J title)"
eq 'A: the repo named' 'acme/web' "$(printf '%s' "$p" | J repo)"
eq 'A: no Codex asked → the fleet default (null)' 'None' "$(printf '%s' "$p" | J agent)"
eq 'A: the node is the hub'"'"'s pick (null)' 'None' "$(printf '%s' "$p" | J node)"
eq 'A: via dispatch' 'dispatch' "$(printf '%s' "$p" | J via)"
eq 'A: --codex → agent codex' 'codex' "$(D payload --title x --repo acme/web --codex | J agent)"
D payload --title '   ' --repo acme/web >/dev/null 2>&1 && fail "A: an empty title made a payload"
CHECKS=$((CHECKS + 1))

# --- B. the default repo -----------------------------------------------------------
rm -f "$WORK/state/compose-state.json"
eq 'B: nothing used yet → the first the hub names' 'acme/app' "$(D payload --title x | J repo)"
printf '{"repo": "acme/web"}\n' > "$WORK/state/compose-state.json"
eq 'B: the last one used' 'acme/web' "$(D payload --title x | J repo)"
printf '{"repo": "acme/gone"}\n' > "$WORK/state/compose-state.json"
eq 'B: a last one no longer hosted → the first' 'acme/app' "$(D payload --title x | J repo)"

# --- C. no list: --send here --------------------------------------------------------
cat > "$WORK/send.sh" <<EOF
#!/bin/bash
cp "\$1" "$WORK/sent.json"
printf 'REMOTE m5 start done U/f1\n'
EOF
chmod +x "$WORK/send.sh"
out=$(FLEET_DISPATCH_SEND_CMD="$WORK/send.sh" D send --title '看日志' --repo acme/web --codex) \
  || fail "C: send with no list exited non-zero" "$out"
has 'C: said how it ended' "$out" 'm5'
eq 'C: the payload went out with its agent' 'codex' "$(J agent < "$WORK/sent.json")"
eq 'C: the last repo is remembered (compose-state.json)' 'acme/web' "$(J repo < "$WORK/state/compose-state.json")"
printf '#!/bin/sh\nprintf "没有机器有空\\n" >&2; exit 4\n' > "$WORK/nope.sh"; chmod +x "$WORK/nope.sh"
out=$(FLEET_DISPATCH_SEND_CMD="$WORK/nope.sh" D send --title '看日志' --repo acme/web 2>&1) \
  && fail "C: a refused send exited 0" "$out"
has 'C: a refusal says why' "$out" '没有机器有空'
CHECKS=$((CHECKS + 1)); [ -f "$WORK/state/compose-failed.json" ] || fail "C: a refused payload was not kept (compose-failed.json)"

# --- D. a list on screen: the writing area's own road -------------------------------
if [ -n "$REAL_TMUX" ]; then
  "$REAL_TMUX" -f /dev/null new-session -d -s c -x 120 -y 30 || fail "D: tmux did not start"
  lp=$("$REAL_TMUX" display-message -p -t c '#{pane_id}')
  "$REAL_TMUX" set-option -p -t "$lp" @sidebar 1
  out=$(D send --title '派一件事' --repo acme/app) || fail "D: send to the list exited non-zero" "$out"
  has 'D: 「已发出：…」' "$out" '派一件事'
  eq 'D: the list got `compose` on its queue' 'compose ' "$("$REAL_TMUX" show-options -pqv -t "$lp" @sidebar_do)"
  eq 'D: the payload waits in compose-send.json' 'dispatch' "$(J via < "$WORK/state/compose-send.json")"
  eq 'D: …for the repo picked' 'acme/app' "$(J repo < "$WORK/state/compose-send.json")"
fi

# --- E. --send says the number filed ------------------------------------------------
QB="$WORK/q-bin"; mkdir -p "$QB"
for f in "$BIN"/*; do ln -sf "$f" "$QB/"; done
rm -f "$QB/fleet-client-place.sh"
cat > "$QB/fleet-client-place.sh" <<'EOF'
#!/bin/bash
printf '{"key": "acme-web:issue-42", "filed": "https://github.com/acme/web/issues/42"}' > "$FLEET_PLACE_RESULT"
printf 'REMOTE m5 start done U/f42\t\n'
EOF
chmod +x "$QB/fleet-client-place.sh"
printf '{"title":"看日志","body":"看日志","repo":"acme/web","via":"dispatch"}\n' > "$WORK/e.json"
python3 "$QB/fleet-compose.py" --send "$WORK/e.json" >"$WORK/e.out" 2>"$WORK/e.err" || fail "E: --send exited non-zero" "$(cat "$WORK/e.err")"
has 'E: stderr says the issue filed' "$(cat "$WORK/e.err")" 'filed: #42'
eq 'E: stdout stays the place'"'"'s one line' 'REMOTE m5 start done U/f42' "$(tr -d '\t' < "$WORK/e.out")"
# the list's word for it (fleet-sidebar.py compose_told)
has 'E: the list says 「已建 #N 并开工」 for a ⌘T send' "$(sed -n '/^def compose_told/,/^def placed/p' "$BIN/fleet-sidebar.py")" 'sidebar_dispatch_done_fmt'
eq 'E: the words' '已建 #42 并开工' "$(sh "$BIN/fleet-ui-lang.sh" t sidebar_dispatch_done_fmt 42)"

# --- F. the key, the bar, ⌘P ---------------------------------------------------------
CONF="$ROOT/conf/tmux-shell.conf"
eq 'F: the switch table row' 'dispatch ⌘T 0x74-0x100000 932 t' "$(bash "$BIN/dash-keymap.sh" --panel switch list | awk '$1 == "dispatch"')"
has 'F: ⌘T opens fleet-quick-dispatch.py through the popup door' "$(grep -E '^bind -n User932 ' "$CONF")" 'dash-popup.sh'
has 'F: …the dispatch popup' "$(grep -E '^bind -n User932 ' "$CONF")" 'fleet-quick-dispatch.py'
eq 'F: prefix t is the same body' "$(grep -E '^bind -n User932 ' "$CONF" | sed 's/^bind -n User932 //')" "$(grep -E '^bind t ' "$CONF" | sed 's/^bind t //')"
has 'F: the bar says ⌘T 派单' "$(grep -F '@fleet_hint_session ' "$CONF")" '⌘T#{E:@fleet_hint_k0} 派单'
first=$(python3 - "$BIN" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("q", os.path.join(sys.argv[1], "fleet-quickopen.py"))
q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
print(q.top_lines("", "multi")[0][1][0])
PY
)
eq 'F: ⌘P'"'"'s first line is 派一件事' 'dispatch' "$first"

printf 'fleet-quick-dispatch-selftest: %d checks passed\n' "$CHECKS"
