#!/bin/bash
# fleet-open-selftest.sh — bin/fleet-open.sh + bin/fleet-open-addr.py (issue #1379).
#
# The same fake `tmux` as fleet-show-selftest plays the server (list-clients from a
# file, lock-command kept in a file, `lock-client` RUNS it), a fake `tailscale`
# answers `status --json` / `serve status --json`, FLEET_SHOW_OUT points the sender
# at a file, and FLEET_OPEN_URL_BIN swaps open-url.sh for a recorder — so nothing
# here can reach the operator's real terminal, tunnel or browser.
#   • REWRITE   :port/path · localhost / 127.0.0.1 / [::1] URL · this machine's
#               tailnet name (via `tailscale serve`'s proxy, longest mount + its
#               path; via doc-preview's https.port → server.port; neither → url)
#               · an external URL → {"kind":"url"} · a bad port / junk → exit 1
#   • BYTES     the escape on the client is EXACTLY
#               ESC ] 1337 ; Custom=id=<secret>:<base64 JSON> BEL, the JSON equals
#               --print's minus ts, and stdout is the one line `sent:iterm2`
#   • SECRET    made on first run at ~/.config/claude-fleet/open.secret, mode 0600,
#               64 hex; a loose existing one is chmod'ed to 0600 and kept; the
#               secret never appears on stdout/stderr or in the lock-command
#   • CHANNEL   the newest client is picked · lock-command restored (unset stays
#               unset) · no job/lock dir left
#   • FALLBACK  active client not iTerm2 / FLEET_OPEN=0 / no tmux → open-url.sh gets
#               the fallback URL, nothing written to the client, stdout is its
#               token (`fallback:copied` / `sent:tunnel`) · a loopback page names the
#               `ssh -L` it needs
#   • OPEN-URL  OPEN_URL_REPORT=1: a live tunnel port → `sent:tunnel`, the listener
#               got the URL
#   • FILE      a file → fleet-show (MultipartFile on the client), `sent:iterm2`
#   • RECORD    open.last holds the last result + kind, never the URL
#   • DOCTOR    fleet-doctor's `open` line: no secret → INFO; secret 0600 + last
#               result → PASS naming it; a loose secret → WARN
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'selftest: python3 missing — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fopen-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
LPID=""
trap '[ -n "$LPID" ] && kill "$LPID" 2>/dev/null; rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" HOME="$WORK/home"
mkdir -p "$WORK/bin" "$HOME"
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
    if [ "\$2" = -u ]; then rm -f "\$S/lockcmd"; else printf '%s' "\$5" > "\$S/lockcmd"; printf '%s\n' "\$5" >> "\$S/lockcmds"; fi ;;
  lock-client)
    echo "\$3" > "\$S/locked"; sh -c "\$(cat "\$S/lockcmd")" </dev/null ;;
esac
EOF
cat > "$WORK/bin/tailscale" <<EOF
#!/bin/sh
case "\$1" in
  status) echo '{"Self":{"DNSName":"box.tail0.ts.net.","TailscaleIPs":["100.64.0.7"]}}' ;;
  serve)  cat "$STATE/serve.json" 2>/dev/null || echo '{}' ;;
esac
EOF
cat > "$WORK/bin/open-url" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > "$STATE/openurl.argv"
echo "\${FAKE_OPENURL_SAYS:-fallback:copied}"
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/tailscale" "$WORK/bin/open-url"
export PATH="$WORK/bin:$PATH" TMUX="/x/sock,1,0" TMUX_PANE="%1"
export FLEET_OPEN_URL_BIN="$WORK/bin/open-url" FLEET_OPEN_DOCPREV_ROOT="$WORK/docprev"
OUT="$WORK/out"; export FLEET_SHOW_OUT="$OUT"
OPEN="$BIN/fleet-open.sh"
SECRET="$HOME/.config/claude-fleet/open.secret"

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
TAB=$(printf '\t')
clients() { printf '%s\n' "$@" | tr '|' "$TAB" > "$STATE/clients"; }
nots() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.pop("ts",None); print(json.dumps(d,sort_keys=True,separators=(",",":")))' "$1"; }
pr() { nots "$("$OPEN" --print "$1" 2>/dev/null)"; }
want() { nots "$1"; }

# ---- REWRITE ----------------------------------------------------------------------
chk() {  # <label> <address> <expected JSON without ts>
  local got; got=$(pr "$2")
  [ "$got" = "$(want "$3")" ] && ok "REWRITE $1" || bad "REWRITE $1: $2 → $got"
}
chk ':port/path'      ':8765/d/x/'                 '{"v":1,"kind":"forward","rport":8765,"path":"/d/x/","scheme":"http","host":""}'
chk ':port bare'      ':3000'                      '{"v":1,"kind":"forward","rport":3000,"path":"/","scheme":"http","host":""}'
chk 'localhost URL'   'http://localhost:5173/a?b=1#c' '{"v":1,"kind":"forward","rport":5173,"path":"/a?b=1#c","scheme":"http","host":""}'
chk '127.0.0.1 https' 'https://127.0.0.1/x'        '{"v":1,"kind":"forward","rport":443,"path":"/x","scheme":"https","host":""}'
chk '[::1] no scheme' '[::1]:8080/'                '{"v":1,"kind":"forward","rport":8080,"path":"/","scheme":"http","host":""}'
chk 'host:port no scheme' 'localhost:9000/p'      '{"v":1,"kind":"forward","rport":9000,"path":"/p","scheme":"http","host":""}'
cat > "$STATE/serve.json" <<'J'
{"Web":{"box.tail0.ts.net:8446":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}},
        "box.tail0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"},"/api":{"Proxy":"http://localhost:7000/v1"}}},
        "box.tail0.ts.net:10000":{"Handlers":{"/":{"Proxy":"https://example.com"}}}}}
J
chk 'tailnet via serve' 'https://box.tail0.ts.net:8446/d/abc/' '{"v":1,"kind":"forward","rport":8765,"path":"/d/abc/","scheme":"http","host":""}'
chk 'tailnet longest mount' 'https://box.tail0.ts.net/api/users?x=1' '{"v":1,"kind":"forward","rport":7000,"path":"/v1/users?x=1","scheme":"http","host":""}'
chk 'tailnet short name' 'https://box/z'          '{"v":1,"kind":"forward","rport":9000,"path":"/z","scheme":"http","host":""}'
chk 'tailnet IP'      'https://100.64.0.7:8446/'  '{"v":1,"kind":"forward","rport":8765,"path":"/","scheme":"http","host":""}'
chk 'tailnet, proxy not loopback → url' 'https://box.tail0.ts.net:10000/' '{"v":1,"kind":"url","url":"https://box.tail0.ts.net:10000/","host":""}'
echo '{}' > "$STATE/serve.json"; mkdir -p "$WORK/docprev"
echo https > "$WORK/docprev/mode"; echo 8447 > "$WORK/docprev/https.port"; echo 8800 > "$WORK/docprev/server.port"
chk 'tailnet via doc-preview record' 'https://box.tail0.ts.net:8447/d/q/' '{"v":1,"kind":"forward","rport":8800,"path":"/d/q/","scheme":"http","host":""}'
chk 'tailnet, nothing serves it → url' 'https://box.tail0.ts.net:9999/' '{"v":1,"kind":"url","url":"https://box.tail0.ts.net:9999/","host":""}'
chk 'external URL'    'https://github.com/o/r/pull/1' '{"v":1,"kind":"url","url":"https://github.com/o/r/pull/1","host":""}'
chk 'external, no scheme' 'github.com/o/r'       '{"v":1,"kind":"url","url":"https://github.com/o/r","host":""}'
chk 'mailto'          'mailto:a@b.c'              '{"v":1,"kind":"url","url":"mailto:a@b.c","host":""}'
got=$(FLEET_OPEN_SSH_HOST=macmini pr ':1/')
[ "$got" = "$(want '{"v":1,"kind":"forward","rport":1,"path":"/","scheme":"http","host":"macmini"}')" ] \
  && ok "REWRITE host = FLEET_OPEN_SSH_HOST" || bad "REWRITE host hint: $got"
"$OPEN" --print ':99999' >/dev/null 2>&1; [ $? = 1 ] && ok "REWRITE port out of range → exit 1" || bad "REWRITE bad port rc"
"$OPEN" --print 'two words' >/dev/null 2>&1; [ $? = 1 ] && ok "REWRITE junk → exit 1" || bad "REWRITE junk rc"
ts=$("$OPEN" --print ':1' | python3 -c 'import json,sys; print(json.load(sys.stdin)["ts"])')
[ $(( $(date +%s) - ts )) -lt 60 ] 2>/dev/null && ok "REWRITE ts is now" || bad "REWRITE ts=$ts"
[ ! -e "$SECRET" ] && ok "--print sends nothing, makes no secret" || bad "--print made a secret"

# ---- BYTES + SECRET + CHANNEL -----------------------------------------------------
clients '100|/dev/ttyOLD|iTerm2 3.6.10' '300|/dev/ttyNEW|iTerm2 3.6.10' '200|/dev/ttyMID|xterm-256color'
rm -f "$OUT" "$STATE/lockcmd" "$STATE/lockcmds"
res=$("$OPEN" ':8765/d/x/' 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ "$res" = sent:iterm2 ] && ok "stdout is one line sent:iterm2" || bad "result ($rc): $res / $(cat "$WORK/err")"
[ "$(cat "$STATE/locked")" = /dev/ttyNEW ] && ok "CHANNEL newest iTerm2 client" || bad "CHANNEL locked $(cat "$STATE/locked")"
[ -f "$SECRET" ] && ok "SECRET created at ~/.config/claude-fleet/open.secret" || bad "SECRET missing"
perm=$(stat -c '%a' "$SECRET" 2>/dev/null || stat -f '%Lp' "$SECRET" 2>/dev/null)
[ "$perm" = 600 ] && ok "SECRET mode 0600" || bad "SECRET mode $perm"
sec=$(cat "$SECRET")
printf '%s' "$sec" | grep -Eq '^[0-9a-f]{64}$' && ok "SECRET 64 hex" || bad "SECRET shape"
verdict=$(python3 - "$OUT" "$sec" "$(pr ':8765/d/x/')" <<'PY'
import base64, json, re, sys
s = open(sys.argv[1], 'rb').read()
m = re.fullmatch(rb'\x1b\]1337;Custom=id=([0-9a-f]+):([A-Za-z0-9+/=]+)\x07', s)
if not m: print('shape', repr(s[:80])); sys.exit()
if m.group(1).decode() != sys.argv[2]: print('id'); sys.exit()
d = json.loads(base64.b64decode(m.group(2)))
d.pop('ts')
print('ok' if json.dumps(d, sort_keys=True, separators=(',', ':')) == sys.argv[3] else 'json ' + json.dumps(d))
PY
)
[ "$verdict" = ok ] && ok "BYTES ESC]1337;Custom=id=<secret>:<b64 JSON>BEL, nothing else" || bad "BYTES: $verdict"
grep -qF "$sec" "$WORK/err" && bad "SECRET leaked to stderr" || ok "SECRET not on stderr"
grep -qF "$sec" "$STATE/lockcmds" && bad "SECRET in the lock-command" || ok "SECRET not in the lock-command"
[ ! -f "$STATE/lockcmd" ] && ok "CHANNEL lock-command restored (unset)" || bad "CHANNEL left $(cat "$STATE/lockcmd")"
ls -d "$WORK"/fleet-show.* >/dev/null 2>&1 && bad "job/lock dir leaked" || ok "no job/lock dir left"
[ "$(cut -f2,3 "$HOME/.config/claude-fleet/open.last")" = "sent:iterm2${TAB}forward" ] \
  && ok "RECORD open.last = sent:iterm2 forward" || bad "RECORD: $(cat "$HOME/.config/claude-fleet/open.last")"
grep -q 8765 "$HOME/.config/claude-fleet/open.last" && bad "RECORD holds the address" || ok "RECORD holds no address"

chmod 644 "$SECRET"; rm -f "$OUT"
"$OPEN" 'https://github.com/x' >/dev/null 2>&1
perm=$(stat -c '%a' "$SECRET" 2>/dev/null || stat -f '%Lp' "$SECRET" 2>/dev/null)
[ "$perm" = 600 ] && [ "$(cat "$SECRET")" = "$sec" ] && ok "SECRET loose → 0600, same secret" || bad "SECRET re-perm: $perm"
grep -q 'Custom=id=' "$OUT" && ok "url kind sent too" || bad "url kind not sent"

# ---- FALLBACK ---------------------------------------------------------------------
fb() {  # <label> <expect stdout> <expect open-url arg> <cmd…>
  local label=$1 want=$2 arg=$3; shift 3
  rm -f "$OUT" "$STATE/openurl.argv"
  local res; res=$("$@" 2>"$WORK/err"); local rc=$?
  if [ "$rc" = 0 ] && [ "$res" = "$want" ] && [ ! -s "$OUT" ] && [ "$(cat "$STATE/openurl.argv" 2>/dev/null)" = "$arg" ]; then
    ok "FALLBACK $label → $res"
  else bad "FALLBACK $label → rc $rc res=$res arg=$(cat "$STATE/openurl.argv" 2>/dev/null) out=$(wc -c < "$OUT" 2>/dev/null)"; fi
}
clients '100|/dev/ttyOLD|iTerm2 3.6.10' '300|/dev/ttyPHONE|xterm-256color'
fb 'active client not iTerm2' fallback:copied 'http://127.0.0.1:8765/d/x/' "$OPEN" ':8765/d/x/'
grep -q 'ssh -L 8765:127.0.0.1:8765' "$WORK/err" && ok "FALLBACK names the ssh -L a loopback page needs" || bad "FALLBACK hint: $(cat "$WORK/err")"
grep -q 'ttyPHONE 是 xterm-256color' "$WORK/err" && ok "FALLBACK says why (fleet-show's words)" || bad "FALLBACK why"
fb 'tunnel took it' sent:tunnel 'https://github.com/x' env FAKE_OPENURL_SAYS=sent:tunnel "$OPEN" 'https://github.com/x'
echo '{"Web":{"box.tail0.ts.net:8446":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}' > "$STATE/serve.json"
fb 'tailnet page keeps its tailnet URL' fallback:copied 'https://box.tail0.ts.net:8446/d/a/' "$OPEN" 'https://box.tail0.ts.net:8446/d/a/'
clients '300|/dev/ttyNEW|iTerm2 3.6.10'
fb 'FLEET_OPEN=0' fallback:copied 'https://github.com/x' env FLEET_OPEN=0 "$OPEN" 'https://github.com/x'
fb 'no tmux' fallback:copied 'https://github.com/x' env -u TMUX "$OPEN" 'https://github.com/x'
[ "$(cut -f2 "$HOME/.config/claude-fleet/open.last")" = fallback:copied ] && ok "RECORD fallback:copied" || bad "RECORD fallback"

# ---- OPEN-URL's report (the real script, a tunnel listener we own) ------------------
LPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); s.settimeout(20)
open(sys.argv[3],"w").close()
c,_=s.accept(); open(sys.argv[2],"wb").write(c.recv(4096))' "$LPORT" "$STATE/tunnel.got" "$STATE/tunnel.up" &
LPID=$!
for _ in $(seq 1 50); do [ -f "$STATE/tunnel.up" ] && break; sleep 0.1; done
res=$(OPEN_URL_REPORT=1 URL_OPENER_PORT="$LPORT" sh "$BIN/open-url.sh" 'https://example.com/z' 2>/dev/null)
wait "$LPID" 2>/dev/null; LPID=""
[ "$res" = sent:tunnel ] && grep -q 'https://example.com/z' "$STATE/tunnel.got" 2>/dev/null \
  && ok "OPEN-URL OPEN_URL_REPORT=1 → sent:tunnel, listener got the URL" || bad "OPEN-URL: $res / $(cat "$STATE/tunnel.got" 2>/dev/null)"
res=$(URL_OPENER_PORT="$LPORT" sh "$BIN/open-url.sh" '' 2>/dev/null)
[ -z "$res" ] && ok "OPEN-URL no URL → silent (unchanged)" || bad "OPEN-URL empty: $res"

# ---- FILE → fleet-show -------------------------------------------------------------
clients '300|/dev/ttyNEW|iTerm2 3.6.10'
printf 'hello' > "$WORK/note.txt"; rm -f "$OUT"
res=$("$OPEN" "$WORK/note.txt" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$res" = sent:iterm2 ] && grep -q 'MultipartFile=' "$OUT" && ok "FILE → fleet-show download, sent:iterm2" || bad "FILE ($rc): $res"
clients '300|/dev/ttyNEW|xterm-256color'
res=$("$OPEN" "$WORK/note.txt" 2>/dev/null); rc=$?
[ "$rc" = 2 ] && printf '%s' "$res" | grep -q "^PATH $WORK/note.txt" && [ "$(printf '%s\n' "$res" | tail -n 1)" = fallback:path ] \
  && ok "FILE not iTerm2 → PATH + fallback:path, exit 2" || bad "FILE fallback ($rc): $res"

# ---- DOCTOR's open line ---------------------------------------------------------------
doctor_open() {
  FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" sh "$BIN/fleet-doctor.sh" 2>/dev/null \
    | grep -aE '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+open ' | head -1
}
mkdir -p "$WORK/conf"
l=$(doctor_open)
case "$l" in *PASS*fallback:path*) ok "DOCTOR PASS names the last result" ;; *) bad "DOCTOR pass: $l" ;; esac
chmod 644 "$SECRET"
case "$(doctor_open)" in *WARN*0600*) ok "DOCTOR loose secret → WARN" ;; *) bad "DOCTOR loose: $(doctor_open)" ;; esac
rm -f "$SECRET" "$HOME/.config/claude-fleet/open.last"
case "$(doctor_open)" in *INFO*first*) ok "DOCTOR no secret → INFO" ;; *) bad "DOCTOR none: $(doctor_open)" ;; esac

[ "$fail" = 0 ] && echo "fleet-open-selftest: PASS" || echo "fleet-open-selftest: FAIL"
exit "$fail"
