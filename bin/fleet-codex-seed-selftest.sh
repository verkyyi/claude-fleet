#!/bin/bash
# fleet-codex-seed-selftest.sh — the Codex seed is SUBMITTED (issue #2430).
# bin/fleet-codex-seed.py against a fake Codex TUI on an isolated tmux socket:
#   A. a seed left in the composer (`› <seed>`) gets ONE Enter and goes in;
#   B. a seed Codex submitted itself (empty composer) gets no key at all;
#   C. a window that says working is never typed into;
#   D. a multi-line seed and a resume launch carry nothing to confirm;
#   E. fleet-codex-runtime.py consults it (for_launch beside the monitor).
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'SKIP no python3'; exit 0; }
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) continue ;; esac; REAL_TMUX=$t; break; done
[ -n "$REAL_TMUX" ] || { echo 'SKIP no tmux'; exit 0; }
WORK=$(mktemp -d /tmp/fcseed.XXXXXX) || exit 2
SOCK="fcseed$$"
cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
ok() { printf 'ok   %s\n' "$1"; }
mkdir -p "$WORK/b"; ln -s "$REAL_TMUX" "$WORK/b/tmux"
export PATH="$WORK/b:$PATH" FLEET_CONF_DIR="$WORK/conf"
# A fake Codex composer: `› <prefill>` with the cursor at its end; a lone CR
# submits (the turn is logged, the box empties).
cat > "$WORK/fake" <<'PY'
#!/usr/bin/env python3
import json, os, sys, tty
tty.setraw(0)
log = os.environ["FAKE_TURNS"]
buf = os.environ.get("FAKE_PREFILL", "")
def draw():
    shown = buf if buf else ""
    sys.stdout.write('\x1b[2J\x1b[H  OpenAI Codex\r\n\r\n› ' + shown + '\r\n\r\n  gpt high · ~' + '\x1b[3;%dH' % (3 + len(shown.encode('utf-16-le')) // 2))
    sys.stdout.flush()
draw()
while True:
    b = os.read(0, 4096)
    if not b:
        break
    for c in b:
        if c == 13:
            with open(log, 'a') as f:
                f.write(json.dumps({"turn": buf}) + '\n')
            buf = ''
    draw()
PY
chmod +x "$WORK/fake"
nt() { "$REAL_TMUX" -L "$SOCK" "$@"; }
nt -f /dev/null new-session -d -s s -x 100 -y 20 'sleep 600'
pane_for() {   # <name> <prefill> → pane id
  nt new-window -d -P -F '#{pane_id}' -t s: -n "$1" \
    "FAKE_TURNS='$WORK/$1.turns' FAKE_PREFILL='$2' exec python3 '$WORK/fake'"
}
run() {   # <pane> <seed>
  printf '%s' "$2" > "$WORK/seed"
  FLEET_CODEX_SEED_TICK=0.2 python3 "$BIN/fleet-codex-seed.py" --socket "$SOCK" --pane "$1" --seed-file "$WORK/seed" --secs "${3:-4}"
}
turns() { [ -f "$WORK/$1.turns" ] && grep -c . "$WORK/$1.turns" || echo 0; }

# A — left in the box: one Enter, the turn goes in
p=$(pane_for a 'hello OK'); sleep 0.5
out=$(run "$p" 'hello OK')
[ "$(turns a)" = 1 ] && grep -q '"hello OK"' "$WORK/a.turns" \
  || fail 'A: a seed left in the composer was not submitted' "$out / $(cat "$WORK/a.turns" 2>/dev/null)"
case "$out" in enters=1*) ;; *) fail "A: want exactly one Enter, got $out" ;; esac
ok 'A: seed left in the composer → one Enter, submitted'

# B — already submitted (empty box): no key
p=$(pane_for b ''); sleep 0.5
out=$(run "$p" 'hello OK' 1.5)
[ "$(turns b)" = 0 ] || fail 'B: an empty composer was typed into' "$out"
ok 'B: empty composer → nothing sent'

# C — the window says working: never typed into
p=$(pane_for c 'hello OK'); sleep 0.5
nt set-option -w -t "$p" @claude_state working
out=$(run "$p" 'hello OK')
[ "$(turns c)" = 0 ] || fail 'C: a working window was typed into' "$out"
ok 'C: working window → nothing sent'

# D — nothing to confirm: a multi-line seed, a resume, an option last
d=$(python3 - "$BIN/fleet-codex-seed.py" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1])
print(repr(m["seed_of"](["--remote", "unix://x", "-c", "a=b", "hello"])),
      repr(m["seed_of"](["resume", "abc"])), repr(m["seed_of"](["-c", "a=b"])),
      m["SeedConfirm"]("%1", "line one\nline two").done)
PY
)
[ "$d" = "'hello' '' '' True" ] || fail "D: seed_of / multi-line: $d"
ok 'D: seed_of picks the last word; resume / option / multi-line carry none'

# E — the runtime consults it
grep -q 'fleet-codex-seed.py' "$BIN/fleet-codex-runtime.py" && grep -q 'seeder.tick()' "$BIN/fleet-codex-runtime.py" \
  || fail 'E: fleet-codex-runtime.py no longer runs the seed confirm'
ok 'E: fleet-codex-runtime.py runs it beside the monitor'
echo 'PASS fleet-codex-seed-selftest'
