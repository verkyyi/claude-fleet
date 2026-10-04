#!/bin/bash
# fleet-statusline-selftest.sh — bin/fleet-statusline.sh, the statusLine switch (issue #1459).
#
# The one thing the switch must never do is leave a blind spot: remove the
# statusLine while a Claude window has no mod to report its context % and model.
# Hermetic — a sandbox install (this script + the lib symlinked into a temp bin/,
# a conf/statusline.sh beside it), a temp CLAUDE_CONFIG_DIR with its own
# settings.json, a temp FLEET_CONF_DIR with two fleets, and a fake `tmux` on PATH
# whose `has-session` answers from a marker file and whose `list-windows` prints
# canned rows per socket label. No real tmux server, no real settings.
#
#   A  status: none / fleet / personal classified; a census over BOTH live fleets
#      (panels, codex and unstamped windows skipped); the blind reasons named
#      (no mod · stale beat · old mod < 0.2.0); --porcelain's one summary line
#   B  on: none → the key is added pointing at THIS install's conf/statusline.sh,
#      a .bak.<epoch> written, every other key byte-identical; on again → no write
#   C  off refuses while a window is blind: exit 1, the window named, settings
#      untouched, no backup; refuses a personal status line (exit 1) on BOTH
#      on and off; refuses under FLEET_MOD=0
#   D  off with every window fed: the key removed, a backup written, the rest of
#      the file byte-identical; off again → "already off", no write; --dry-run
#      changes nothing; --force takes the blind spot; zero Claude windows pass
#   E  unreadable settings.json → exit 2, nothing written
#
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/fleet-statusline.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SUT" "$LIB" "$BIN/../conf/statusline.sh"; do
  [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: SKIP — python3 not on PATH\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-statusline.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"   # as the switch spells its own root (a TMPDIR with a trailing / would leave //)
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# --- the sandbox install ------------------------------------------------------
mkdir -p "$WORK/inst/bin" "$WORK/inst/conf" "$WORK/cc" "$WORK/cfg/fleets/fleet-a" "$WORK/cfg/fleets/fleet-b" "$WORK/live" "$WORK/rows" "$WORK/fakebin"
ln -s "$SUT" "$WORK/inst/bin/fleet-statusline.sh"
ln -s "$LIB" "$WORK/inst/bin/fleet-lib.sh"
: > "$WORK/inst/conf/statusline.sh"
OURS="$WORK/inst/conf/statusline.sh"
printf 'FLEET_REPO=a/a\n' > "$WORK/cfg/fleets/fleet-a/conf"
printf 'FLEET_REPO=b/b\n' > "$WORK/cfg/fleets/fleet-b/conf"
SETTINGS="$WORK/cc/settings.json"

# fake tmux: `tmux -L <label> has-session …` → 0 iff $WORK/live/<label> exists;
# `tmux -L <label> list-windows …` → the canned rows for that label.
cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/sh
label=''
if [ "\${1:-}" = -L ]; then label="\$2"; shift 2; fi
case "\${1:-}" in
  has-session)  [ -f "$WORK/live/\$label" ] ;;
  list-windows) cat "$WORK/rows/\$label" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/fakebin/tmux"

NOW=$(date +%s)
TAB=$(printf '\t')
US=$(printf '\037')
# row <id> <name> <agent> <mark> <alive> <ver> <pct> <src> — the -F columns the switch
# asks for, US-separated (empty fields must survive the read; a tab collapses them)
row() { printf "%s${US}%s${US}%s${US}%s${US}%s${US}%s${US}%s${US}%s\n" "$@"; }

# run <args…> → stdout+stderr, rc appended as "rc=N"
run() {
  # shellcheck disable=SC2046  # word-split on purpose: one variable name per word
  ( unset $(env | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p') TMUX TMUX_PANE
    export PATH="$WORK/fakebin:$PATH" CLAUDE_CONFIG_DIR="$WORK/cc" FLEET_CONF_DIR="$WORK/cfg" HOME="$WORK/home" ${EXTRA_ENV:-}
    bash "$WORK/inst/bin/fleet-statusline.sh" "$@" 2>&1; printf 'rc=%s\n' "$?" )
}
has() { case "$2" in *"$3"*) : ;; *) fail "$1" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1" "$2" ;; esac; }
others() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s.pop("statusLine",None); print(json.dumps(s,sort_keys=True))' "$1"; }

# --- A: status + census ---------------------------------------------------------
printf '{\n  "model": "opus",\n  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x"}]}]},\n  "statusLine": {"type": "command", "command": "/Users/op/.claude/fleet/conf/statusline.sh"},\n  "permissions": {"allow": ["Bash(ls:*)"]}\n}\n' > "$SETTINGS"
: > "$WORK/live/fleet-a"; : > "$WORK/live/fleet-b"
{ row @1 dash '' '' '' '' '' ''                                   # panel: skipped
  row @2 hub '' opus "$NOW" 0.2.0 12 mod                         # fed + stamped
  row @3 issue-1 '' opus "$((NOW-5))" 0.2.0 40 ''                # fed, not yet stamped
  row @4 issue-2 codex gpt-6 '' '' 33 ''                        # codex: skipped
  row @5 issue-3 '' 'done' '' '' 20 ''                            # no mod
  row @6 issue-4 '' working "$((NOW-300))" 0.2.0 20 mod          # stale beat
  row @7 scratch-1 '' opus "$NOW" 0.1.0 8 ''                     # old mod
  row @8 shell '' '' '' '' '' ''                                 # unstamped: skipped
} > "$WORK/rows/fleet-a"
{ row @1 issue-9 '' fable "$NOW" 0.2.0 55 mod
  row @2 plan '' '' '' '' '' ''
} > "$WORK/rows/fleet-b"
out=$(run status)
has "A: fleet classified" "$out" 'statusLine: fleet — /Users/op/.claude/fleet/conf/statusline.sh'
has "A: census counts both fleets" "$out" 'windows: 6 claude · 3 fed by the mod (v0.2.0+, beat fresh) · 3 stamped @ctx_src=mod · 3 not fed'
has "A: no-mod window named" "$out" '! fleet-a:issue-3 — no mod'
has "A: stale beat named" "$out" '! fleet-a:issue-4 — stale beat (300s)'
has "A: old mod named" "$out" '! fleet-a:scratch-1 — old mod v0.1.0 (< v0.2.0'
has "A: verdict not yet" "$out" 'verdict: not yet — 3 window(s) would lose'
has "A: status exits 0" "$out" 'rc=0'
out=$(run status --porcelain)
[ "$(printf '%s\n' "$out" | head -1)" = "wired=fleet${TAB}windows=6${TAB}fed=3${TAB}blind=3${TAB}stamped=3${TAB}mod=on" ] || fail "A: porcelain summary line" "$out"
has "A: porcelain blind rows" "$out" "blind${TAB}fleet-a${TAB}issue-3${TAB}no mod"
ok "A status: wired kind, census over two fleets, blind reasons, porcelain"

# --- B: on --------------------------------------------------------------------
printf '{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}}\n' > "$SETTINGS"
before=$(others "$SETTINGS")
out=$(run status); has "B: none classified" "$out" 'statusLine: none —'
out=$(run on)
has "B: on adds" "$out" "added statusLine in $SETTINGS"
has "B: on backs up" "$out" 'backup  '"$SETTINGS"'.bak.'
has "B: rc 0" "$out" 'rc=0'
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$SETTINGS")" = "$OURS" ] || fail "B: the key must point at THIS install's conf/statusline.sh" "$(cat "$SETTINGS")"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["type"])' "$SETTINGS")" = command ] || fail "B: type command" "$(cat "$SETTINGS")"
[ "$(others "$SETTINGS")" = "$before" ] || fail "B: every other key must survive byte for byte" "$(cat "$SETTINGS")"
ls "$SETTINGS".bak.* >/dev/null 2>&1 || fail "B: a .bak.<epoch> must exist"
nbak=$(ls "$SETTINGS".bak.* | wc -l | tr -d ' ')
out=$(run on)
has "B: on again is a no-op" "$out" 'already on'
[ "$(ls "$SETTINGS".bak.* | wc -l | tr -d ' ')" = "$nbak" ] || fail "B: a no-op must not write a backup"
ok "B on: key added at this install's path, backup, other keys intact, idempotent"

# --- C: refusals ------------------------------------------------------------------
snap=$(cat "$SETTINGS")
out=$(run off)
has "C: off refused with blind windows" "$out" 'REFUSED — 3 of 6 Claude window(s) are not fed'
has "C: names them" "$out" '! fleet-a:issue-3 — no mod'
has "C: says how" "$out" 'cycle them first'
has "C: rc 1" "$out" 'rc=1'
[ "$(cat "$SETTINGS")" = "$snap" ] || fail "C: a refused off must not touch settings.json"
[ "$(ls "$SETTINGS".bak.* | wc -l | tr -d ' ')" = "$nbak" ] || fail "C: a refused off must not write a backup"
out=$(EXTRA_ENV='FLEET_MOD=0' run off)
has "C: FLEET_MOD=0 refused" "$out" 'REFUSED — FLEET_MOD=0'
has "C: rc 1" "$out" 'rc=1'
out=$(EXTRA_ENV='FLEET_MOD=0' run status)
has "C: FLEET_MOD=0 verdict" "$out" 'verdict: FLEET_MOD=0 — no second reporter'
printf '{"statusLine": {"type": "command", "command": "/Users/op/bin/my-line.sh"}, "model": "opus"}\n' > "$SETTINGS"
snap=$(cat "$SETTINGS")
out=$(run off); has "C: personal off refused" "$out" 'REFUSED — settings.json wires a personal status line (/Users/op/bin/my-line.sh)'; has "C: rc 1" "$out" 'rc=1'
out=$(run on);  has "C: personal on refused" "$out" 'REFUSED — settings.json wires a personal status line'; has "C: rc 1" "$out" 'rc=1'
out=$(run status); has "C: personal classified" "$out" 'statusLine: personal — /Users/op/bin/my-line.sh'
[ "$(cat "$SETTINGS")" = "$snap" ] || fail "C: a personal status line must never be rewritten"
ok "C refusals: blind windows, FLEET_MOD=0, a personal status line — exit 1, file untouched"

# --- D: off ---------------------------------------------------------------------
printf '{\n  "model": "opus",\n  "statusLine": {\n    "type": "command",\n    "command": "%s"\n  },\n  "permissions": {"allow": ["Bash(ls:*)"]}\n}\n' "$OURS" > "$SETTINGS"
before=$(others "$SETTINGS")
{ row @2 hub '' opus "$NOW" 0.2.0 12 mod
  row @3 issue-1 '' opus "$((NOW-5))" 0.2.0 40 mod
  row @4 issue-2 codex gpt-6 '' '' 33 ''
} > "$WORK/rows/fleet-a"
{ row @1 issue-9 '' fable "$((NOW-30))" 0.3.1 55 mod; } > "$WORK/rows/fleet-b"
out=$(run status); has "D: verdict ready" "$out" 'verdict: ready — `fleet-statusline.sh off`'
has "D: census 3/3" "$out" 'windows: 3 claude · 3 fed by the mod'
nbak=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
out=$(run off --dry-run)
has "D: dry-run says would" "$out" "would remove statusLine in $SETTINGS"
has "D: rc 0" "$out" 'rc=0'
grep -q '"statusLine"' "$SETTINGS" || fail "D: --dry-run must not remove the key"
[ "$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')" = "$nbak" ] || fail "D: --dry-run must not write a backup"
out=$(run off)
has "D: removed" "$out" "removed statusLine in $SETTINGS"
has "D: summary" "$out" 'statusLine off: 3/3 windows fed by the mod. New sessions have their bottom row back'
has "D: rc 0" "$out" 'rc=0'
grep -q '"statusLine"' "$SETTINGS" && fail "D: the key must be gone" "$(cat "$SETTINGS")"
[ "$(others "$SETTINGS")" = "$before" ] || fail "D: every other key must survive byte for byte" "$(cat "$SETTINGS")"
[ "$(ls "$SETTINGS".bak.* | wc -l | tr -d ' ')" = "$((nbak+1))" ] || fail "D: exactly one new backup"
nbak=$((nbak+1))
out=$(run off); has "D: off again" "$out" 'already off'; has "D: rc 0" "$out" 'rc=0'
[ "$(ls "$SETTINGS".bak.* | wc -l | tr -d ' ')" = "$nbak" ] || fail "D: a no-op must not write a backup"
# --force takes a blind window knowingly
printf '{"statusLine": {"type": "command", "command": "%s"}}\n' "$OURS" > "$SETTINGS"
{ row @2 hub '' opus "$NOW" 0.2.0 12 mod; row @5 issue-3 '' 'done' '' '' 20 ''; } > "$WORK/rows/fleet-a"
out=$(run off); has "D: refused without --force" "$out" 'rc=1'
out=$(run off --force)
has "D: --force removes" "$out" "removed statusLine in $SETTINGS"
has "D: --force says blind" "$out" '(1 blind, --force)'
# zero Claude windows (no live fleet) → the gate passes trivially
printf '{"statusLine": {"type": "command", "command": "%s"}}\n' "$OURS" > "$SETTINGS"
rm -f "$WORK/live/fleet-a" "$WORK/live/fleet-b"
out=$(run status); has "D: no live fleet → 0 windows" "$out" 'windows: 0 claude · 0 fed'
out=$(run off); has "D: no windows → off allowed" "$out" "removed statusLine in $SETTINGS"
ok "D off: removed with a backup, other keys intact; idempotent; --dry-run inert; --force; no windows passes"

# --- E: unreadable settings -----------------------------------------------------
printf '{not json\n' > "$SETTINGS"
snap=$(cat "$SETTINGS")
out=$(run off); has "E: unreadable → exit 2" "$out" 'rc=2'; has "E: says so" "$out" 'cannot read'
out=$(run on);  has "E: unreadable → exit 2" "$out" 'rc=2'
[ "$(cat "$SETTINGS")" = "$snap" ] || fail "E: an unreadable file must not be rewritten"
rm -f "$SETTINGS"
: > "$WORK/live/fleet-a"
out=$(run status); has "E: no settings.json → none" "$out" 'statusLine: none'
ok "E unreadable settings.json: exit 2, nothing written; a missing file reads as none"

printf 'fleet-statusline-selftest: %d passed\n' "$pass"
