#!/bin/bash
# fleet-show-selftest.sh — bin/fleet-show.sh + bin/fleet-show-send.py (issue #1367).
#
# A fake `tmux` on PATH plays the server: it answers display-message/list-clients,
# keeps the session's lock-command in a file, and on `lock-client` RUNS that
# command the way a real client would. FLEET_SHOW_OUT points the sender at a file
# instead of /dev/tty, so the escape stream it would put on the operator's
# terminal is decoded back here and compared byte for byte.
#   • ROUNDTRIP    multipart stream decodes to the exact file bytes, name, inline=0
#   • PICK         newest-activity client whose termtype matches iTerm2 wins; a
#                  newer non-iTerm2 client is skipped
#   • RESTORE      lock-command unset before → unset after; a session value → kept
#   • INLINE       --inline sets inline=1 · --single uses the one-shot File= form
#   • DEGRADE      FLEET_SHOW=0 / no iTerm2 client / over the cap / no tmux → PATH,
#                  exit 2 · missing file → exit 1 · --client not of this session
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'selftest: python3 missing — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fshow-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
mkdir -p "$WORK/bin"
STATE="$WORK/state"; mkdir -p "$STATE"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
S="$STATE"
case "\$1" in
  display-message) echo fleet-x ;;
  list-clients) cat "\$S/clients" ;;
  show-options)
    [ -f "\$S/lockcmd" ] || exit 0
    case "\$2" in -qv) cat "\$S/lockcmd" ;; *) printf 'lock-command %s\n' "\$(cat "\$S/lockcmd")" ;; esac ;;
  set-option)
    if [ "\$2" = -u ]; then rm -f "\$S/lockcmd"; else printf '%s' "\$5" > "\$S/lockcmd"; fi ;;
  lock-client)
    echo "\$3" > "\$S/locked"; sh -c "\$(cat "\$S/lockcmd")" </dev/null ;;
esac
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH" TMUX="/x/sock,1,0" TMUX_PANE="%1"
OUT="$WORK/out"; export FLEET_SHOW_OUT="$OUT"
SHOW="$BIN/fleet-show.sh"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
TAB=$(printf '\t')
clients() { printf '%s\n' "$@" | tr '|' "$TAB" > "$STATE/clients"; }

decode() {  # <stream> → prints "name inline size" and writes the payload to <stream>.bin
  python3 - "$1" <<'PY'
import base64, re, sys
s = open(sys.argv[1], 'rb').read()
m = re.search(rb'\x1b\]1337;(MultipartFile|File)=name=([^;]*);size=(\d+);inline=(\d)', s)
if m.group(1) == b'File':
    data = base64.b64decode(re.search(rb':([^\a]*)\a', s[m.end():]).group(1))
else:
    assert s.endswith(b'\x1b]1337;FileEnd\x07'), 'no FileEnd'
    data = base64.b64decode(b''.join(re.findall(rb'\x1b\]1337;FilePart=([^\a]*)\a', s)))
open(sys.argv[1] + '.bin', 'wb').write(data)
print(base64.b64decode(m.group(2)).decode(), m.group(4).decode(), m.group(3).decode(), m.group(1).decode())
PY
}

head -c 200001 /dev/urandom > "$WORK/pic one.png"
F="$WORK/pic one.png"

# ---- ROUNDTRIP + PICK + RESTORE(unset) -------------------------------------------
clients '100|/dev/ttyOLD|iTerm2 3.6.10' '300|/dev/ttyNEW|xterm-256color' '200|/dev/ttyMID|iTerm2 3.6.10'
rm -f "$OUT" "$STATE/lockcmd"
res=$("$SHOW" "$F" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$res" | grep -q '^SENT pic one.png (200001 bytes) → /dev/ttyMID \[iTerm2' \
  && ok "SENT line, rc 0" || bad "SENT ($rc): $res"
[ "$(cat "$STATE/locked")" = /dev/ttyMID ] && ok "PICK newest iTerm2 client" || bad "PICK locked $(cat "$STATE/locked")"
meta=$(decode "$OUT")
[ "$meta" = "pic one.png 0 200001 MultipartFile" ] && ok "header: $meta" || bad "header: $meta"
cmp -s "$OUT.bin" "$F" && ok "ROUNDTRIP bytes identical" || bad "ROUNDTRIP bytes differ"
[ ! -f "$STATE/lockcmd" ] && ok "RESTORE unset lock-command stays unset" || bad "RESTORE left $(cat "$STATE/lockcmd")"
ls -d "$WORK"/fleet-show.* >/dev/null 2>&1 && bad "job/lock dir leaked" || ok "no job/lock dir left"

# ---- RESTORE(session value) + INLINE + SINGLE ------------------------------------
printf '%s' 'lock -np' > "$STATE/lockcmd"; rm -f "$OUT"
FLEET_SHOW_HOLD_SECS=1 "$SHOW" --inline "$F" >/dev/null 2>&1
[ "$(cat "$STATE/lockcmd")" = 'lock -np' ] && ok "RESTORE session value kept" || bad "RESTORE got $(cat "$STATE/lockcmd")"
[ "$(decode "$OUT" | cut -d' ' -f3)" = 1 ] && ok "INLINE inline=1" || bad "INLINE: $(decode "$OUT")"
rm -f "$OUT"; "$SHOW" --single "$F" >/dev/null 2>&1
meta=$(decode "$OUT"); case "$meta" in *' File') cmp -s "$OUT.bin" "$F" && ok "SINGLE File= roundtrip" || bad "SINGLE bytes" ;; *) bad "SINGLE: $meta" ;; esac

# ---- DEGRADE --------------------------------------------------------------------
deg() {  # <label> <expect-rc> <cmd…>
  local label=$1 want=$2; shift 2
  rm -f "$OUT"; local out; out=$("$@" 2>/dev/null); local rc=$?
  if [ "$rc" = "$want" ] && { [ "$want" = 1 ] || printf '%s' "$out" | grep -q "^PATH /"; } && [ ! -s "$OUT" ]; then
    ok "DEGRADE $label → rc $rc"
  else bad "DEGRADE $label → rc $rc out=$out"; fi
}
deg 'FLEET_SHOW=0' 2 env FLEET_SHOW=0 "$SHOW" "$F"
deg 'over the cap' 2 env FLEET_SHOW_MAX_BYTES=10 "$SHOW" "$F"
deg 'no tmux' 2 env -u TMUX "$SHOW" "$F"
deg 'missing file' 1 "$SHOW" "$WORK/nope.png"
deg '--client not ours' 2 "$SHOW" --client /dev/ttyELSE "$F"
clients '300|/dev/ttyNEW|xterm-256color'
deg 'no iTerm2 client' 2 "$SHOW" "$F"
clients '300|/dev/ttyNEW|xterm-256color'
rm -f "$OUT"; "$SHOW" --client /dev/ttyNEW "$F" >/dev/null 2>&1 && cmp -s "$F" "$(decode "$OUT" >/dev/null; echo "$OUT.bin")" \
  && ok "--client names a non-iTerm2 client outright" || bad "--client outright"

[ "$fail" = 0 ] && echo "fleet-show-selftest: PASS" || echo "fleet-show-selftest: FAIL"
exit "$fail"
