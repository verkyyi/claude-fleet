#!/bin/bash
# fleet-session-name-selftest.sh — fleet-session-wrap.sh → fleet-claude.sh:
# new, restore and fork launches keep the window's display name (T1334 / D7QD).
# Fake native binaries record NUL-delimited argv; no real agent or tmux server.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_sandbox "${TMPDIR:-/tmp}/fleet-session-name.XXXXXX"
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/home"
for f in fleet-session-wrap.sh fleet-claude.sh fleet-lib.sh; do
  ln -s "$BIN/$f" "$WORK/bin/$f"
done
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf"
export NAME_TEST_DIR="$WORK" PATH="$WORK/fakebin:$PATH"
export TMUX=test-socket TMUX_PANE=%42
cat > "$WORK/fakebin/tmux" <<'SH'
#!/bin/sh
if [ "$1" = display-message ]; then
  case "$*" in
    *'#{window_name}'*) cat "$NAME_TEST_DIR/name" ;;
    *'#{@wrap_quiet}'*) printf 1 ;;
  esac
fi
exit 0
SH
cat > "$WORK/fakebin/claude" <<'SH'
#!/bin/sh
printf '%s\0' "$@" > "$NAME_TEST_DIR/argv"
printf claude > "$NAME_TEST_DIR/provider"
SH
cat > "$WORK/bin/fleet-codex.sh" <<'SH'
#!/bin/sh
printf '%s\0' "$@" > "$NAME_TEST_DIR/argv"
printf codex > "$NAME_TEST_DIR/provider"
SH
chmod +x "$WORK/fakebin/claude" "$WORK/fakebin/tmux" "$WORK/bin/fleet-codex.sh"
# Keep the real launcher and its dispatch/config resolution; no fleet accounts.
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-account.sh"
chmod +x "$WORK/bin/fleet-account.sh"
printf 'FLEET_MODEL=opus\n' > "$WORK/fleet.conf"

run() {
  rm -f "$WORK/argv" "$WORK/provider"
  bash "$WORK/bin/fleet-session-wrap.sh" "$@" >"$WORK/launch.log" 2>&1 \
    || st_fail "launch failed: $(cat "$WORK/launch.log")"
}
check() {  # <provider> <expected name, empty = absent> <original argv...>
  python3 - "$WORK" "$@" <<'PY' || st_fail 'native argv differs'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
provider, name, *original = sys.argv[2:]
assert (root / 'provider').read_text() == provider
args = (root / 'argv').read_bytes().split(b'\0')[:-1]
args = [a.decode() for a in args]
names = []
for i, arg in enumerate(args):
    if arg == '--':
        break
    if arg in ('--name', '-n'):
        names.append(args[i + 1])
    elif arg.startswith('--name='):
        names.append(arg.partition('=')[2])
assert names == ([name] if name else []), (names, args)
if original:
    assert args[-len(original):] == original, (original, args)
PY
}

name='修复 "引号" · 空格 '\''单引号'\'' $(echo untouched) `literal`'
printf '%s' "$name" > "$WORK/name"
run --session-id new-id 'first prompt'
check claude "$name" --session-id new-id 'first prompt'
run --resume old-id 'resume prompt'
check claude "$name" --resume old-id 'resume prompt'
run --resume old-id --fork-session 'fork prompt'
check claude "$name" --resume old-id --fork-session 'fork prompt'
for flag in --name -n; do
  run "$flag" 'caller name' --resume old-id
  check claude 'caller name' "$flag" 'caller name' --resume old-id
done
run '--name=caller name' --resume old-id
check claude 'caller name' '--name=caller name' --resume old-id
run -- 'prompt mentioning --name'
check claude "$name" -- 'prompt mentioning --name'
for name in '' resume-placeholder; do
  printf '%s' "$name" > "$WORK/name"
  run --resume old-id
  check claude '' --resume old-id
done
printf 'Named window' > "$WORK/name"
(export TMUX_PANE=''; run --resume old-id; check claude '' --resume old-id) || exit 1
run --agent codex resume codex-id
check codex '' resume codex-id
printf 'FLEET_AGENT=codex\nFLEET_MODEL=opus\n' > "$WORK/fleet.conf"
run 'new codex prompt'
check codex '' 'new codex prompt'
# A saved Claude transcript stays Claude even if the fleet default is now Codex.
run --resume old-id
check claude 'Named window' --resume old-id
st_ok 'new / restore / fork names survive argv; caller wins; Codex and missing names stay untouched'
