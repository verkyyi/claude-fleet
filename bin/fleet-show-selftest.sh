#!/bin/bash
# fleet-show-selftest.sh — bin/fleet-show.sh + bin/fleet-show-send.py (issue #1367).
#
# A fake `tmux` on PATH plays the server: it answers display-message/list-clients,
# keeps the session's lock-command in a file, and on `lock-client` RUNS that
# command the way a real client would. FLEET_SHOW_OUT points the sender at a file
# instead of /dev/tty, so the escape stream it would put on the operator's
# terminal is decoded back here and compared byte for byte.
#   • ROUNDTRIP    multipart stream decodes to the exact file bytes, name, inline=0
#   • NAME         name= is the bare basename — no trailing newline (a `basename |
#                  base64` encodes one, and iTerm2 shows it as a `?` on the file)
#   • PICK         the newest-activity client wins and must BE iTerm2 (#1371): a
#                  newer non-iTerm2 client degrades instead of falling back to a
#                  stale iTerm2 one · an empty termtype degrades
#   • RESTORE      lock-command unset before → unset after; a session value → kept
#   • INLINE       --inline sets inline=1 · --single uses the one-shot File= form
#   • DEGRADE      FLEET_SHOW=0 / no iTerm2 client / over the cap / no tmux → PATH,
#                  exit 2 · missing file → exit 1 · --client not of this session
#   • CENTER       (#1371) --inline on a 141x29 client, 24x64 px cells: a landscape
#                  PNG and a portrait JPEG land at the computed CUP with
#                  width=/height= cells + preserveAspectRatio=1 · unknown client
#                  size → top-left, no width= · title row + countdown footer
#   • NON-IMAGE    --inline on a PDF sends it as a download (inline=0), SENT says so
#   • D-KEY        FLEET_SHOW_KEYS=d → the image again as inline=0 after the inline=1
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

# --inline fixtures: a 2000x1000 PNG, a 1000x3000 JPEG, a PDF (headers real, bodies random)
python3 - "$WORK" <<'PY'
import os, struct, sys, zlib
w = sys.argv[1]
ihdr = struct.pack(">IIBBBBB", 2000, 1000, 8, 2, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr + struct.pack(">I", zlib.crc32(b"IHDR" + ihdr))
open(w + "/wide.png", "wb").write(png + os.urandom(5800))
app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x00" * 9
sof = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, 3000, 1000, 3) + b"\x00" * 9
open(w + "/tall.jpg", "wb").write(b"\xff\xd8" + app0 + sof + os.urandom(3000))
open(w + "/doc.pdf", "wb").write(b"%PDF-1.4\n" + os.urandom(500))
PY
inl() {  # <stream> → one line per file escape: "<CUP before it> <inline> <extra args>"
  python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1], 'rb').read()
for m in re.finditer(rb'(?:\x1b\[(\d+);(\d+)H)?\x1b\]1337;MultipartFile=name=[^;]*;size=\d+;inline=(\d)([^\a]*)\a', s):
    cup = f"{m.group(1).decode()};{m.group(2).decode()}" if m.group(1) else "-"
    print(cup, m.group(3).decode(), m.group(4).decode() or "-")
PY
}

# ---- ROUNDTRIP + PICK + RESTORE(unset) -------------------------------------------
clients '100|/dev/ttyOLD|iTerm2 3.6.10' '300|/dev/ttyNEW|iTerm2 3.6.10' '200|/dev/ttyMID|xterm-256color'
rm -f "$OUT" "$STATE/lockcmd"
res=$("$SHOW" "$F" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$res" | grep -q '^SENT pic one.png (200001 bytes) → /dev/ttyNEW \[iTerm2' \
  && ok "SENT line, rc 0" || bad "SENT ($rc): $res"
[ "$(cat "$STATE/locked")" = /dev/ttyNEW ] && ok "PICK newest client (iTerm2)" || bad "PICK locked $(cat "$STATE/locked")"
meta=$(decode "$OUT")
[ "$meta" = "pic one.png 0 200001 MultipartFile" ] && ok "header: $meta" || bad "header: $meta"
cmp -s "$OUT.bin" "$F" && ok "ROUNDTRIP bytes identical" || bad "ROUNDTRIP bytes differ"
raw=$(python3 -c 'import base64,re,sys; print(repr(base64.b64decode(re.search(rb"name=([^;]*);", open(sys.argv[1],"rb").read()).group(1))))' "$OUT")
[ "$raw" = "b'pic one.png'" ] && ok "NAME has no trailing newline" || bad "NAME decoded to $raw"
[ ! -f "$STATE/lockcmd" ] && ok "RESTORE unset lock-command stays unset" || bad "RESTORE left $(cat "$STATE/lockcmd")"
ls -d "$WORK"/fleet-show.* >/dev/null 2>&1 && bad "job/lock dir leaked" || ok "no job/lock dir left"

# ---- RESTORE(session value) + INLINE + SINGLE ------------------------------------
printf '%s' 'lock -np' > "$STATE/lockcmd"; rm -f "$OUT"
FLEET_SHOW_HOLD_SECS=1 "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
[ "$(cat "$STATE/lockcmd")" = 'lock -np' ] && ok "RESTORE session value kept" || bad "RESTORE got $(cat "$STATE/lockcmd")"
[ "$(inl "$OUT" | cut -d' ' -f2)" = 1 ] && ok "INLINE inline=1" || bad "INLINE: $(inl "$OUT")"
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
clients '100|/dev/ttyOLD|iTerm2 3.6.10' '300|/dev/ttyPHONE|xterm-256color'
deg 'active client not iTerm2 (stale iTerm2 attached)' 2 "$SHOW" "$F"
why=$("$SHOW" "$F" 2>&1 >/dev/null)
printf '%s' "$why" | grep -q '当前活跃 client /dev/ttyPHONE 是 xterm-256color，不是 iTerm2' \
  && ok "DEGRADE names the active client + its termtype" || bad "DEGRADE why: $why"
clients '100|/dev/ttyOLD|iTerm2 3.6.10' '300|/dev/ttyBLANK|'
deg 'active client with empty termtype' 2 "$SHOW" "$F"
clients '300|/dev/ttyNEW|xterm-256color'
rm -f "$OUT"; "$SHOW" --client /dev/ttyNEW "$F" >/dev/null 2>&1 && cmp -s "$F" "$(decode "$OUT" >/dev/null; echo "$OUT.bin")" \
  && ok "--client names a non-iTerm2 client outright" || bad "--client outright"

# ---- CENTER / NON-IMAGE / D-KEY (--inline, #1371) --------------------------------
clients '300|/dev/ttyNEW|iTerm2 3.6.10|141,29,24,64'
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "7;29 1 ;width=84;height=16;preserveAspectRatio=1" ] && ok "CENTER landscape 2000x1000 → $got" || bad "CENTER landscape: $got"
grep -q 'wide.png · 5.7 KB · 2000×1000' "$OUT" && ok "CENTER title row: name · size · pixels" || bad "CENTER title row missing"
grep -q '任意键返回 tmux · d 同时下载到 ~/Downloads · [0-9]*s 后自动返回 tmux' "$OUT" \
  && ok "CENTER footer hint + countdown" || bad "CENTER footer missing"
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/tall.jpg" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "3;60 1 ;width=23;height=25;preserveAspectRatio=1" ] && ok "CENTER portrait JPEG 1000x3000 → $got" || bad "CENTER portrait: $got"
clients '300|/dev/ttyNEW|iTerm2 3.6.10|141,29,0,0'
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "3;1 1 -" ] && ok "CENTER no cell size → top-left, own size" || bad "CENTER fallback: $got"
clients '300|/dev/ttyNEW|iTerm2 3.6.10'
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "3;1 1 -" ] && ok "CENTER no geometry field (old tmux) → top-left" || bad "CENTER no-geom: $got"

clients '300|/dev/ttyNEW|iTerm2 3.6.10|141,29,24,64'
rm -f "$OUT"; res=$(FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/doc.pdf" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(inl "$OUT")" = "- 0 -" ] && printf '%s' "$res" | grep -q '^SENT doc.pdf .*not an image' \
  && ok "NON-IMAGE pdf --inline → download + said so" || bad "NON-IMAGE ($rc): $(inl "$OUT") / $res"

rm -f "$OUT"; FLEET_SHOW_KEYS=d "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT" | cut -d' ' -f2 | tr '\n' ' ')
[ "$got" = "1 0 " ] && grep -q '已发出下载' "$OUT" && ok "D-KEY d → inline=1 then inline=0 download" || bad "D-KEY: $got"

rm -f "$OUT"; res=$(FLEET_SHOW_KEYS=dx "$SHOW" --inline "$WORK/wide.png" "$WORK/tall.jpg" 2>&1)
got=$(inl "$OUT" | cut -d' ' -f2 | tr '\n' ' ')
[ "$got" = "1 0 1 " ] && printf '%s' "$res" | grep -q '^SENT wide.png → the operator pressed d' \
  && grep -q '\[1/2\] wide.png' "$OUT" && ok "D-KEY on screen 1 of 2 reported, then screen 2" || bad "D-KEY multi: $got / $res"

[ "$fail" = 0 ] && echo "fleet-show-selftest: PASS" || echo "fleet-show-selftest: FAIL"
exit "$fail"
