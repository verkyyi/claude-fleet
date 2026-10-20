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
#   • NON-IMAGE    --inline on a PDF sends it as a download (inline=0), stderr says so
#   • D-KEY        FLEET_SHOW_KEYS=d → the image again as inline=0 after the inline=1
#   • RECEIPT      (issue #3541) one result line per file — saved:<path> · failed:<why>
#                  · unconfirmed — on every road:
#        ITERM     the Custom= kind=file request goes right before the download and
#                  fleet-open.sh --ack answers it: saved:<path> rc 0 · failed:<why>
#                  rc 4 · a v2 script's «unknown kind» → unconfirmed · no answer →
#                  unconfirmed · no secret → nothing asked, unconfirmed at once
#        THIN      a thin 看台 with caps=show gets OSC 7502 show; the REAL thin loop
#                  (fleet-thin.py show_req) fetches it through --fetch, saves it in
#                  its downloads and answers: saved:<path>, bytes identical, a name
#                  taken → «name (1).ext»; --fetch serves an id once; a fetch that
#                  fails → failed rc 4; no answer → unconfirmed; a row with no caps
#                  → the terminal road as before
#        CLIENT    the lease's result naming a path → saved; the local opener →
#                  saved:<the file here>
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
st_sandbox "${TMPDIR:-/tmp}/fshow-selftest.XXXXXX"
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
# nobody's client, no fleet-open secret: the terminal road, nothing asked (#3541)
export FLEET_CONF_DIR="$WORK/conf" FLEET_OPEN_SECRET_FILE="$WORK/no.secret" FLEET_OPEN_WHERE_CMD="$WORK/bin/where"
mkdir -p "$FLEET_CONF_DIR"
printf '#!/bin/sh\ncat "%s/where.json" 2>/dev/null || echo "{}"\n' "$WORK" > "$WORK/bin/where"; chmod +x "$WORK/bin/where"
OUT="$WORK/out"; export FLEET_SHOW_OUT="$OUT"
SHOW="$BIN/fleet-show.sh"

st_tally
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
res=$("$SHOW" "$F" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ "$res" = unconfirmed ] && grep -q '^fleet-show: pic one.png → iTerm2（/dev/ttyNEW iTerm2' "$WORK/err" \
  && grep -q '没有 fleet-open 密钥' "$WORK/err" && st_ok "no secret: unconfirmed at once, rc 0, stderr names the road" || st_miss "result ($rc): $res / $(cat "$WORK/err")"
[ "$(cat "$STATE/locked")" = /dev/ttyNEW ] && st_ok "PICK newest client (iTerm2)" || st_miss "PICK locked $(cat "$STATE/locked")"
meta=$(decode "$OUT")
[ "$meta" = "pic one.png 0 200001 MultipartFile" ] && st_ok "header: $meta" || st_miss "header: $meta"
cmp -s "$OUT.bin" "$F" && st_ok "ROUNDTRIP bytes identical" || st_miss "ROUNDTRIP bytes differ"
raw=$(python3 -c 'import base64,re,sys; print(repr(base64.b64decode(re.search(rb"name=([^;]*);", open(sys.argv[1],"rb").read()).group(1))))' "$OUT")
[ "$raw" = "b'pic one.png'" ] && st_ok "NAME has no trailing newline" || st_miss "NAME decoded to $raw"
[ ! -f "$STATE/lockcmd" ] && st_ok "RESTORE unset lock-command stays unset" || st_miss "RESTORE left $(cat "$STATE/lockcmd")"
ls -d "$WORK"/fleet-show.* >/dev/null 2>&1 && st_miss "job/lock dir leaked" || st_ok "no job/lock dir left"

# ---- RESTORE(session value) + INLINE + SINGLE ------------------------------------
printf '%s' 'lock -np' > "$STATE/lockcmd"; rm -f "$OUT"
FLEET_SHOW_HOLD_SECS=1 "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
[ "$(cat "$STATE/lockcmd")" = 'lock -np' ] && st_ok "RESTORE session value kept" || st_miss "RESTORE got $(cat "$STATE/lockcmd")"
[ "$(inl "$OUT" | cut -d' ' -f2)" = 1 ] && st_ok "INLINE inline=1" || st_miss "INLINE: $(inl "$OUT")"
rm -f "$OUT"; "$SHOW" --single "$F" >/dev/null 2>&1
meta=$(decode "$OUT"); case "$meta" in *' File') cmp -s "$OUT.bin" "$F" && st_ok "SINGLE File= roundtrip" || st_miss "SINGLE bytes" ;; *) st_miss "SINGLE: $meta" ;; esac

# ---- DEGRADE --------------------------------------------------------------------
deg() {  # <label> <expect-rc> <cmd…>
  local label=$1 want=$2; shift 2
  rm -f "$OUT"; local out; out=$("$@" 2>/dev/null); local rc=$?
  if [ "$rc" = "$want" ] && { [ "$want" = 1 ] || { printf '%s' "$out" | grep -q "^PATH /" && printf '%s' "$out" | grep -q '^failed:.'; }; } && [ ! -s "$OUT" ]; then
    st_ok "DEGRADE $label → rc $rc"
  else st_miss "DEGRADE $label → rc $rc out=$out"; fi
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
  && st_ok "DEGRADE names the active client + its termtype" || st_miss "DEGRADE why: $why"
clients '100|/dev/ttyOLD|iTerm2 3.6.10' '300|/dev/ttyBLANK|'
deg 'active client with empty termtype' 2 "$SHOW" "$F"
clients '300|/dev/ttyNEW|xterm-256color'
rm -f "$OUT"; "$SHOW" --client /dev/ttyNEW "$F" >/dev/null 2>&1 && cmp -s "$F" "$(decode "$OUT" >/dev/null; echo "$OUT.bin")" \
  && st_ok "--client names a non-iTerm2 client outright" || st_miss "--client outright"

# ---- CENTER / NON-IMAGE / D-KEY (--inline, #1371) --------------------------------
clients '300|/dev/ttyNEW|iTerm2 3.6.10|141,29,24,64'
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "7;29 1 ;width=84;height=16;preserveAspectRatio=1" ] && st_ok "CENTER landscape 2000x1000 → $got" || st_miss "CENTER landscape: $got"
grep -q 'wide.png · 5.7 KB · 2000×1000' "$OUT" && st_ok "CENTER title row: name · size · pixels" || st_miss "CENTER title row missing"
grep -q '任意键返回 tmux · d 同时下载到 ~/Downloads · [0-9]*s 后自动返回 tmux' "$OUT" \
  && st_ok "CENTER footer hint + countdown" || st_miss "CENTER footer missing"
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/tall.jpg" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "3;60 1 ;width=23;height=25;preserveAspectRatio=1" ] && st_ok "CENTER portrait JPEG 1000x3000 → $got" || st_miss "CENTER portrait: $got"
clients '300|/dev/ttyNEW|iTerm2 3.6.10|141,29,0,0'
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "3;1 1 -" ] && st_ok "CENTER no cell size → top-left, own size" || st_miss "CENTER fallback: $got"
clients '300|/dev/ttyNEW|iTerm2 3.6.10'
rm -f "$OUT"; FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT")
[ "$got" = "3;1 1 -" ] && st_ok "CENTER no geometry field (old tmux) → top-left" || st_miss "CENTER no-geom: $got"

clients '300|/dev/ttyNEW|iTerm2 3.6.10|141,29,24,64'
rm -f "$OUT"; res=$(FLEET_SHOW_KEYS=x "$SHOW" --inline "$WORK/doc.pdf" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(inl "$OUT")" = "- 0 -" ] && printf '%s' "$res" | grep -q '^fleet-show: doc.pdf .*不是 iTerm2 能画的图' \
  && st_ok "NON-IMAGE pdf --inline → download + said so" || st_miss "NON-IMAGE ($rc): $(inl "$OUT") / $res"

rm -f "$OUT"; FLEET_SHOW_KEYS=d "$SHOW" --inline "$WORK/wide.png" >/dev/null 2>&1
got=$(inl "$OUT" | cut -d' ' -f2 | tr '\n' ' ')
[ "$got" = "1 0 " ] && grep -q '已发出下载' "$OUT" && st_ok "D-KEY d → inline=1 then inline=0 download" || st_miss "D-KEY: $got"

rm -f "$OUT"; res=$(FLEET_SHOW_KEYS=dx "$SHOW" --inline "$WORK/wide.png" "$WORK/tall.jpg" 2>&1)
got=$(inl "$OUT" | cut -d' ' -f2 | tr '\n' ' ')
[ "$got" = "1 0 1 " ] && printf '%s' "$res" | grep -q '^fleet-show: wide.png → 你按了 d' \
  && [ "$(printf '%s\n' "$res" | grep -c '^unconfirmed$')" = 2 ] \
  && grep -q '\[1/2\] wide.png' "$OUT" && st_ok "D-KEY on screen 1 of 2 reported, then screen 2" || st_miss "D-KEY multi: $got / $res"

# ---- RECEIPT · ITERM (issue #3541) ------------------------------------------------
# The laptop's fleet_open.py, played: wait for the Custom= request in the stream, check
# it is kind=file for this file and comes BEFORE its MultipartFile, answer it.
cat > "$WORK/iterm_peer.py" <<'PY'
import base64, json, os, re, subprocess, sys, time
out, state, why, secret = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
end = time.time() + 15
while time.time() < end:
    s = open(out, "rb").read() if os.path.exists(out) else b""
    m = re.search(rb"\x1b\]1337;Custom=id=([^:]*):([^\a]*)\a", s)
    if m and b"FileEnd" in s:
        assert m.group(1).decode() == secret, "secret"
        assert m.start() < s.find(b"MultipartFile="), "request after the file"
        d = json.loads(base64.b64decode(m.group(2)))
        assert d["kind"] == "file" and d["name"] == "pic one.png" and d["size"] == 200001 and d["v"] == 1, d
        if state != "none":
            subprocess.call(["bash", sys.argv[5], "--ack", d["id"], state, why])
        print("seen")
        sys.exit(0)
    time.sleep(0.05)
sys.exit(1)
PY
printf 'sekrit-0123\n' > "$WORK/open.secret"
clients '300|/dev/ttyNEW|iTerm2 3.6.10'
iterm() {  # <state ok|fail|none> <why> → "rc|stdout"; the peer's verdict in $WORK/peer
  rm -f "$OUT"
  ( python3 "$WORK/iterm_peer.py" "$OUT" "$1" "$2" sekrit-0123 "$BIN/fleet-open.sh" > "$WORK/peer" 2>&1 & )
  local out rc; out=$(FLEET_OPEN_SECRET_FILE="$WORK/open.secret" FLEET_SHOW_ACK_WAIT=3 "$SHOW" "$F" 2>"$WORK/err"); rc=$?
  sleep 0.2; printf '%s|%s' "$rc" "$out"
}
got=$(iterm ok "/Users/p/Downloads/pic one.png")
[ "$got" = "0|saved:/Users/p/Downloads/pic one.png" ] && grep -qx seen "$WORK/peer" \
  && st_ok "ITERM saved:<path> from fleet_open.py's answer (request before the file, keyed)" || st_miss "ITERM saved: $got / $(cat "$WORK/peer" "$WORK/err")"
got=$(iterm fail "it never landed in the laptop's downloads folder")
[ "$got" = "4|failed:it never landed in the laptop's downloads folder" ] && st_ok "ITERM failed:<why> rc 4" || st_miss "ITERM failed: $got"
got=$(iterm fail "the laptop refused it: unknown kind='file'")
[ "$got" = "0|unconfirmed" ] && grep -q '旧版' "$WORK/err" && st_ok "ITERM a v2 script's refusal → unconfirmed, says so" || st_miss "ITERM v2: $got / $(cat "$WORK/err")"
t0=$(date +%s); got=$(iterm none ""); t1=$(date +%s)
[ "$got" = "0|unconfirmed" ] && [ $(( t1 - t0 )) -ge 3 ] && grep -q '没等到那边的回执' "$WORK/err" \
  && st_ok "ITERM no answer → unconfirmed after the wait" || st_miss "ITERM none: $got ($(( t1 - t0 ))s) / $(cat "$WORK/err")"
[ -n "$(find "$FLEET_CONF_DIR/open-acks" -type f 2>/dev/null)" ] && st_miss "ITERM receipts left behind" || st_ok "ITERM no receipt left behind"

# ---- RECEIPT · THIN (issue #3541) -------------------------------------------------
# The REAL loop's show_req, fed the 7502 off the 看台's tty through its own parser;
# its fetch is this machine's `fleet-show.sh --fetch`, its receipt `fleet-open.sh --ack`.
cat > "$WORK/thin_peer.py" <<'PY'
import importlib.util, os, sys, threading, time
out, token, binp = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fleet_thin", os.path.join(binp, "fleet-thin.py"))
ft = importlib.util.module_from_spec(spec); spec.loader.exec_module(ft)
t = object.__new__(ft.Thin)
t.base, t.home, t.said, t.said_lock = {"argv": []}, "mini", [], threading.Lock()
end = time.time() + 15
while time.time() < end:
    data = open(out, "rb").read() if os.path.exists(out) else b""
    if data:
        _, events, _ = ft.Osc7502(token).feed(data)
        shows = [kv for kind, kv in events if kind == "show"]
        if shows:
            for kv in shows:
                t.show_req(kv)
            print("\n".join(t.said))
            sys.exit(0)
    time.sleep(0.05)
sys.exit(1)
PY
VIEWS="$FLEET_CONF_DIR/remote-views"; mkdir -p "$VIEWS"
DEV=$(printf '{"device":"Pat Mac"}' | base64 | tr -d '\n')
row() {  # <caps column or empty>
  printf '/dev/ttyNEW\tfleet-x\tthin\t1\t1\tcur=x\troute=lan\tdevice=%s\ttoken=tok-1\tfuid=u\tnode=mini%s\n' "$DEV" "$1" > "$VIEWS/v1"
}
printf '{"source":"hub","state":"active","via":"thin"}\n' > "$WORK/where.json"
DL="$WORK/dl"; mkdir -p "$DL"
TOUT="$WORK/thin.out"
thin() {  # <file…> → "rc|stdout" (FETCH= the loop's fetch command)
  rm -f "$OUT" "$TOUT"
  ( env FLEET_THIN_DOWNLOADS="$DL" FLEET_THIN_LOG="$WORK/thin.log" FLEET_THIN_FETCH_CMD="${FETCH:-bash $SHOW --fetch}" \
        FLEET_THIN_ACK_CMD="bash $BIN/fleet-open.sh" python3 "$WORK/thin_peer.py" "$TOUT" tok-1 "$BIN" > "$WORK/peer" 2>&1 & )
  local out rc; out=$(env FLEET_THIN_SHOW_OUT="$TOUT" FLEET_SHOW_ACK_WAIT=5 "$SHOW" "$@" 2>"$WORK/err"); rc=$?
  sleep 0.3; printf '%s|%s' "$rc" "$out"
}
row "	caps=show"
got=$(thin "$F")
[ "$got" = "0|saved:$DL/pic one.png" ] && cmp -s "$DL/pic one.png" "$F" && [ ! -s "$OUT" ] \
  && st_ok "THIN saved:<path> in the loop's downloads, bytes identical, no terminal escape" || st_miss "THIN saved: $got / $(cat "$WORK/peer" "$WORK/err")"
grep -q 'fleet · .* 发来 pic one.png，存在 ' "$WORK/peer" && st_ok "THIN the loop says where it saved it" || st_miss "THIN say: $(cat "$WORK/peer")"
grep -q 'Pat Mac' "$WORK/err" && st_ok "THIN stderr names the device" || st_miss "THIN device: $(cat "$WORK/err")"
got=$(thin "$F")
[ "$got" = "0|saved:$DL/pic one (1).png" ] && st_ok "THIN a taken name → «pic one (1).png»" || st_miss "THIN taken: $got"
[ -n "$(find "$FLEET_CONF_DIR/show-files" -type f 2>/dev/null)" ] && st_miss "THIN a fetched id left registered" || st_ok "THIN --fetch serves an id once"
bash "$SHOW" --fetch 00ff >/dev/null 2>&1; [ $? = 3 ] && st_ok "THIN --fetch of an unknown id → rc 3" || st_miss "THIN --fetch unknown"
bash "$SHOW" --fetch '../x' >/dev/null 2>&1; [ $? = 1 ] && st_ok "THIN --fetch refuses a non-hex id" || st_miss "THIN --fetch non-hex"
got=$(FETCH=false thin "$F")
case "$got" in "4|failed:fetch failed (rc 1)"*) st_ok "THIN a fetch that fails → failed:<why> rc 4" ;; *) st_miss "THIN fetch fail: $got" ;; esac
rm -f "$OUT" "$TOUT"; got=$(FLEET_THIN_SHOW_OUT="$TOUT" FLEET_SHOW_ACK_WAIT=1 "$SHOW" "$F" 2>"$WORK/err"); rc=$?
[ "$rc|$got" = "0|unconfirmed" ] && grep -q 'show;token=tok-1;' "$TOUT" && st_ok "THIN no answer → unconfirmed" || st_miss "THIN none: $rc|$got"
row ""
rm -f "$OUT" "$TOUT"; got=$(FLEET_THIN_SHOW_OUT="$TOUT" "$SHOW" "$F" 2>/dev/null)
[ "$got" = unconfirmed ] && [ ! -s "$TOUT" ] && [ -s "$OUT" ] && st_ok "THIN a row with no caps (older loop) → the terminal road" || st_miss "THIN no caps: $got"
rm -f "$VIEWS/v1"

# ---- RECEIPT · CLIENT lease + local opener (issue #3541) ---------------------------
printf '{"source":"hub","state":"active","via":"ssh"}\n' > "$WORK/where.json"
cat > "$WORK/bin/actions" <<'SH'
print('{"state":"done","result":"saved:/Users/p/Downloads/x.png","client":{"device":"Pat Mac"}}')
SH
got=$(FLEET_SHOW_ACTIONS_BIN="$WORK/bin/actions" "$SHOW" "$F" 2>/dev/null); rc=$?
[ "$rc|$got" = "0|saved:/Users/p/Downloads/x.png" ] && st_ok "CLIENT the lease's result → saved:<path>" || st_miss "CLIENT: $rc|$got"
printf '{"source":"local","state":"active","via":"local"}\n' > "$WORK/where.json"
got=$(FLEET_SHOW_LOCAL_CMD=true "$SHOW" "$F" 2>/dev/null); rc=$?
[ "$rc|$got" = "0|saved:$(cd "$WORK" && pwd -P)/pic one.png" ] && st_ok "CLIENT the local opener → saved:<the file here>" || st_miss "LOCAL: $rc|$got"
rm -f "$WORK/where.json"

st_done
