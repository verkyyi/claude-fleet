#!/bin/bash
# clipboard-osc52-selftest.sh — text selected in another machine's session reaches
# the person's own clipboard (issue #1766).
#
# The chain on the person's screen: their terminal ← the shell's tmux
# (conf/tmux-shell.conf) ← its right pane, a nested client of the STAGE
# (conf/tmux-shell-stage.conf) ← the stage's pane, the machine's fleet session
# (conf/tmux-attention.conf). A selection is copied by the INNERMOST tmux, which
# writes it as OSC 52 to its terminal — a pane of the next server out. tmux's
# default `set-clipboard external` drops an OSC 52 a pane sends, so every hop
# outward must say `on`, or the copy dies there.
#
#   A. lint   each of the three confs sets `set-clipboard on`; the hub's client
#             manifest is current — the hub packs these very files at build
#             time (fleet-client-mirror.sh --check, #1803).
#   B. chain  three tmux servers on isolated sockets, each given the
#             set-clipboard value its conf sets, nested shell → stage → node, a
#             python pty as the outer terminal. In the node, copy-mode selects a
#             line and copies it (what a mouse drag ends in): the pty receives
#             `\e]52;c;<base64>`, and the decoded text is exactly the selection.
#   C. why    the same chain with the shell at `external` (the value before
#             #1766): the pty receives no OSC 52 — the failure this fixes.
#   D. doctor `fleet doctor` on a client (fleet-agent-bundle.py doctor) prints a
#             `clipboard` row: PASS when iTerm2's AllowClipboardAccess is on, WARN
#             (with where to turn it on) when off or unset, nothing without iTerm2.
#   E. Ms     (issue #2758) the shell and the stage give every terminal `Ms` (their
#             terminal-overrides[92] row): an outer terminal tmux has no clipboard
#             feature for (TERM=screen-256color — a phone's, say) still receives
#             the copy; without the row it receives nothing (the row is what does it).
#   F. drag   a real mouse drag, typed into the outer terminal as SGR mouse
#             reports, crosses shell → stage → node, ends the node's copy-mode
#             selection (tmux's stock MouseDragEnd1Pane → copy-pipe-and-cancel)
#             and the terminal receives that text as OSC 52.
#   G. shell  the shell conf binds the drag's release, y and ↵ to
#             copy-pipe-and-cancel in both copy-mode tables (a copy made in its
#             own copy-mode leaves the same way); the node conf binds none
#             (fleet-keys-selftest.sh leg 8 — the node only opens capabilities).
#   J. hint   a terminal that may not take a copy (Termius, macOS Terminal, one
#             the client cannot name) reads how to copy on its own bar for a
#             moment: status-left shows @fleet_clip_hint_text to the ttys in
#             @fleet_clip_hint — never a display-message, which would keep a
#             popup (the standby screen, ⌘P) from drawing while it shows.
#   I. own    the program in the node's pane copies by itself (Claude Code's own
#             copy): an OSC 52 it writes — raw, or as tmux passthrough (the node
#             conf's allow-passthrough) — reaches the outer terminal too.
#   H. iTerm2 fleet-iterm-profile.py write turns AllowClipboardAccess on once (it is
#             app-wide: iTerm2 has no per-profile key) and records that it did; a
#             person who turns it off afterwards keeps it off; FLEET_ITERM_KEYS=0
#             touches nothing.
#
# Prints what the terminal received, decoded — the issue's 上线证据.
# tmux / python3 absent → SKIP (exit 0). CLIP_KEEP=1 keeps the work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BIN/.." && pwd)"
TMUX_BIN=$(command -v tmux) || { printf 'clipboard-osc52 selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'clipboard-osc52 selftest: python3 absent — SKIP\n'; exit 0; }
unset TMUX TMUX_PANE

FAIL=0; CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); printf 'ok:   %s\n' "$1"; }
bad() { CHECKS=$((CHECKS + 1)); FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# --- A. the confs ------------------------------------------------------------
clipval() {  # <conf> → the value its `set -g set-clipboard` line sets (last wins)
  awk '$1=="set" && $2=="-g" && $3=="set-clipboard" {v=$4} END {print v}' "$1"
}
SHELL_V=$(clipval "$REPO/conf/tmux-shell.conf")
STAGE_V=$(clipval "$REPO/conf/tmux-shell-stage.conf")
NODE_V=$(clipval "$REPO/conf/tmux-attention.conf")
NODE_PT=$(awk '$1=="set" && $2=="-g" && $3=="allow-passthrough" {v=$4} END {print v}' "$REPO/conf/tmux-attention.conf")
[ "$SHELL_V" = on ] && ok "A conf/tmux-shell.conf: set-clipboard on" || bad "A conf/tmux-shell.conf: set-clipboard '${SHELL_V}', want on"
[ "$STAGE_V" = on ] && ok "A conf/tmux-shell-stage.conf: set-clipboard on" || bad "A conf/tmux-shell-stage.conf: set-clipboard '${STAGE_V}', want on"
[ "$NODE_V" = on ] && ok "A conf/tmux-attention.conf: set-clipboard on" || bad "A conf/tmux-attention.conf: set-clipboard '${NODE_V}', want on"
# the hub serves these very files (one copy, packed at build time — #1803)
if [ -d "$REPO/tokenledger/internal/api/fleetclient" ]; then
  if out=$(bash "$BIN/fleet-client-mirror.sh" --check 2>&1); then ok "A fleet-client-mirror.sh --check"
  else bad "A fleet-client-mirror.sh --check: $out"; fi
fi

# --- D. the client doctor's `clipboard` row (fleet-agent-bundle.py) ------------
# iTerm2 must accept the OSC 52 too; `fleet doctor` on a client says so, never fixes it.
drow() { FLEET_ITERM_CLIPBOARD="$1" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("b", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); print(m.iterm_clipboard())' "$BIN/fleet-agent-bundle.py" 2>&1; }
case "$(drow 1)" in *PASS*clipboard*) ok "D doctor: iTerm2 AllowClipboardAccess=1 → PASS clipboard" ;; *) bad "D doctor on: $(drow 1)" ;; esac
case "$(drow 0)" in *WARN*clipboard*"may access clipboard"*) ok "D doctor: AllowClipboardAccess=0 → WARN with where to turn it on" ;; *) bad "D doctor off: $(drow 0)" ;; esac
case "$(drow '')" in *WARN*clipboard*) ok "D doctor: AllowClipboardAccess unset (iTerm2 default off) → WARN" ;; *) bad "D doctor unset: $(drow '')" ;; esac
[ "$(drow none)" = None ] && ok "D doctor: no iTerm2 → no row" || bad "D doctor no iTerm2: $(drow none)"

# --- E (lint half). the Ms row in the shell and the stage ----------------------
msrow() {  # <conf> → the value its terminal-overrides[92] line sets
  awk '$1=="set" && $2=="-s" && $3=="terminal-overrides[92]" {v=$4} END {print v}' "$1" | tr -d "'"
}
MS_SHELL=$(msrow "$REPO/conf/tmux-shell.conf")
MS_STAGE=$(msrow "$REPO/conf/tmux-shell-stage.conf")
case "$MS_SHELL" in '*:Ms=\E]52;%p1%s;%p2%s\007') ok "E conf/tmux-shell.conf: every terminal has Ms" ;; *) bad "E conf/tmux-shell.conf Ms row: '$MS_SHELL'" ;; esac
case "$MS_STAGE" in '*:Ms=\E]52;%p1%s;%p2%s\007') ok "E conf/tmux-shell-stage.conf: every terminal has Ms" ;; *) bad "E conf/tmux-shell-stage.conf Ms row: '$MS_STAGE'" ;; esac
grep -q 'terminal-overrides.*Ms=' "$REPO/conf/tmux-attention.conf" \
  && bad "E conf/tmux-attention.conf grew an Ms row (the node's terminal is the stage — its own conf says it)" \
  || ok "E the node conf adds no Ms row"

# --- G. the shell's copy-mode binds; none on the node --------------------------
for tbl in copy-mode copy-mode-vi; do
  for k in MouseDragEnd1Pane y Enter; do
    if awk -v t="$tbl" -v k="$k" '$1=="bind" && $2=="-T" && $3==t && $4==k && /copy-pipe-and-cancel/ {f=1} END {exit !f}' "$REPO/conf/tmux-shell.conf"; then
      ok "G shell: $tbl $k → copy-pipe-and-cancel"
    else bad "G shell: no '$tbl $k → copy-pipe-and-cancel' bind"; fi
  done
done
grep -Eq '^[[:space:]]*bind(-key)?[[:space:]]+-T[[:space:]]+copy-mode' "$REPO/conf/tmux-attention.conf" \
  && bad "G the node conf binds a copy-mode key (it may only open capabilities)" || ok "G the node conf binds no copy-mode key"

# --- J. the hint for a terminal that may not take a copy (fleet-shell.sh clip_hint)
grep -q '^set -g status-left .*#{m:\*|#{client_tty}|\*,#{@fleet_clip_hint}}' "$REPO/conf/tmux-shell.conf" \
  && ok "J the bar shows @fleet_clip_hint_text to the ttys in @fleet_clip_hint" || bad "J status-left does not read @fleet_clip_hint"
body=$(sed -n '/^clip_hint()/,/^}/p' "$BIN/fleet-shell.sh")
case "$body" in
  *display-message*) bad "J clip_hint uses display-message (a message keeps a popup from drawing)" ;;
  *@fleet_clip_hint*) ok "J clip_hint writes the bar's option, never a message" ;;
  *) bad "J clip_hint not found in fleet-shell.sh" ;;
esac
[ "$(sh "$BIN/fleet-ui-lang.sh" t clip_hint)" != clip_hint ] && ok "J the words come from fleet-ui-lang.sh (clip_hint)" || bad "J fleet-ui-lang.sh has no clip_hint"

# --- H. the iTerm2 permission ---------------------------------------------------
HW="$(mktemp -d /tmp/cliph.XXXXXX)" || exit 2
iprof() {  # <prefs plist state: unset|0|1> [env…] → AllowClipboardAccess after a write, + mark
  python3 - "$HW/p.plist" "$1" <<'PYH'
import plistlib, sys
d = {"New Bookmarks": []}
if sys.argv[2] != "unset": d["AllowClipboardAccess"] = sys.argv[2] == "1"
plistlib.dump(d, open(sys.argv[1], "wb"))
PYH
}
iread() { python3 -c 'import plistlib,sys; v=plistlib.load(open(sys.argv[1],"rb")).get("AllowClipboardAccess"); print("unset" if v is None else int(v))' "$HW/p.plist"; }
irun() { env FLEET_ITERM_DIR="$HW/dp" FLEET_ITERM_PREFS="$HW/p.plist" FLEET_ITERM_CLIP_MARK="$HW/mark" ITERM_PROFILE='' "$@" \
  python3 "$BIN/fleet-iterm-profile.py" write >/dev/null 2>&1; }
rm -f "$HW/mark"; iprof unset; irun
[ "$(iread)" = 1 ] && [ -f "$HW/mark" ] && ok "H unset → fleet turns it on, and marks that it did" || bad "H unset: AllowClipboardAccess=$(iread) mark=$([ -f "$HW/mark" ] && echo y || echo n)"
rm -f "$HW/mark"; iprof 0; irun
[ "$(iread)" = 1 ] && ok "H off, never turned on by fleet → on" || bad "H off before fleet: $(iread)"
iprof 0; irun
[ "$(iread)" = 0 ] && ok "H turned off by the person after fleet turned it on → stays off" || bad "H re-enabled after the person turned it off: $(iread)"
rm -f "$HW/mark"; iprof 1; irun
[ "$(iread)" = 1 ] && [ -f "$HW/mark" ] && ok "H already on → left on, marked" || bad "H already on: $(iread)"
rm -f "$HW/mark"; iprof unset; irun FLEET_ITERM_KEYS=0
[ "$(iread)" = unset ] && [ ! -f "$HW/mark" ] && ok "H FLEET_ITERM_KEYS=0 → nothing written" || bad "H FLEET_ITERM_KEYS=0 wrote: $(iread)"
rm -rf "$HW"

# --- B/C. the chain ----------------------------------------------------------
# Sockets under a SHORT dir: a long $TMPDIR overflows AF_UNIX's 104 bytes.
WORK="$(mktemp -d /tmp/clip.XXXXXX)" || exit 2
cleanup() {
  for s in shell stage node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  [ -n "${CLIP_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }; rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
PAYLOAD='hello-1766 选中的字 ✓'

# The pty: attaches to the shell server, then runs the copy in the node, and
# reports every OSC 52 the terminal received (decoded) as JSON lines.
cat > "$WORK/term.py" <<'PY'
import base64, fcntl, json, os, pty, re, select, struct, subprocess, sys, termios, time
tmux, work, payload, term, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = term
    os.execvp(tmux, [tmux, "-S", work + "/shell", "attach", "-t", "shell"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
buf = b""
def pump(secs):
    global buf
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return
            if not d: return
            buf += d
def T(sock, *a):
    return subprocess.run([tmux, "-S", work + "/" + sock, *a], capture_output=True, text=True).stdout
# Wait until every hop has a client: shell (us), stage (in shell's pane), node (in stage's).
for _ in range(100):
    pump(0.1)
    if T("stage", "list-clients").strip() and T("node", "list-clients").strip() \
       and payload in T("node", "capture-pane", "-p"):
        break
pump(0.5)
buf = b""
if mode == "drag":
    # A person's drag: SGR mouse reports typed into the outer terminal — press on
    # the payload's first cell, move along row 1, release just past its last.
    width = sum(2 if ord(ch) > 0x2e80 else 1 for ch in payload)
    os.write(fd, b"\x1b[<0;1;1M")
    pump(0.3)
    for x in range(2, width + 2):
        os.write(fd, b"\x1b[<32;%d;1M" % x)
        pump(0.03)
    pump(0.3)
    os.write(fd, b"\x1b[<0;%d;1m" % (width + 1))
    pump(2.0)
elif mode in ("pane", "pane-pt"):
    # The program in the node's pane copies by itself (Claude Code's own copy):
    # it writes OSC 52 to its terminal — raw, or wrapped as tmux passthrough.
    b64 = base64.b64encode(payload.encode()).decode()
    seq = "\\033]52;c;%s\\007" % b64
    if mode == "pane-pt":
        seq = "\\033Ptmux;\\033\\033]52;c;%s\\007\\033\\\\" % b64
    T("node", "respawn-pane", "-k", "-t", "node", "printf '%s'; exec sleep 600" % seq)
    pump(2.0)
else:
    # Select the payload line in copy-mode and copy it — where a mouse drag ends.
    T("node", "copy-mode", "-t", "node")
    T("node", "send", "-t", "node", "-X", "search-backward", "hello-1766")
    T("node", "send", "-t", "node", "-X", "begin-selection")
    T("node", "send", "-t", "node", "-X", "end-of-line")
    T("node", "send", "-t", "node", "-X", "copy-selection-and-cancel")
    pump(2.0)
out = []
for m in re.finditer(rb"\x1b\]52;([a-z]*);([A-Za-z0-9+/=]*)(?:\x07|\x1b\\)", buf):
    out.append({"sel": m.group(1).decode(), "text": base64.b64decode(m.group(2)).decode("utf-8", "replace")})
print(json.dumps({"osc52": out, "buffer": T("node", "show-buffer")}, ensure_ascii=False))
os.kill(pid, 9)
PY

chain() {  # <shell value> [outer TERM] [copy|drag] [ms|noms] → the pty's JSON
  local s
  for s in shell stage node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  local conf="$WORK/base.conf"
  printf 'set -g default-terminal "tmux-256color"\nset -g status off\nset -g escape-time 0\nset -g mode-keys emacs\nset -g mouse on\n' > "$conf"
  "$TMUX_BIN" -S "$WORK/node" -f "$conf" new-session -d -s node -x 96 -y 24 \
    "printf '%s\n' '$PAYLOAD'; exec sleep 600"
  "$TMUX_BIN" -S "$WORK/node" set -g set-clipboard "$NODE_V"
  "$TMUX_BIN" -S "$WORK/node" set -g allow-passthrough "$NODE_PT"
  "$TMUX_BIN" -S "$WORK/stage" -f "$conf" new-session -d -s stage -x 98 -y 26 \
    "TMUX= exec $TMUX_BIN -S $WORK/node attach -t node"
  "$TMUX_BIN" -S "$WORK/stage" set -g set-clipboard "$STAGE_V"
  "$TMUX_BIN" -S "$WORK/shell" -f "$conf" new-session -d -s shell -x 100 -y 28 \
    "TMUX= exec $TMUX_BIN -S $WORK/stage attach -t stage"
  "$TMUX_BIN" -S "$WORK/shell" set -g set-clipboard "$1"
  if [ "${4:-ms}" = ms ]; then  # the shell's and the stage's own Ms rows (E)
    "$TMUX_BIN" -S "$WORK/stage" set -s 'terminal-overrides[92]' "$MS_STAGE"
    "$TMUX_BIN" -S "$WORK/shell" set -s 'terminal-overrides[92]' "$MS_SHELL"
  fi
  python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" "$PAYLOAD" "${2:-xterm-256color}" "${3:-copy}"
}

field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

J=$(chain "$SHELL_V")
printf 'B shell=%s stage=%s node=%s → terminal received: %s\n' "$SHELL_V" "$STAGE_V" "$NODE_V" "$J"
n=$(field "$J" 'len(d["osc52"])')
got=$(field "$J" 'd["osc52"][-1]["text"] if d["osc52"] else ""')
buf=$(field "$J" 'd["buffer"]')
[ "$buf" = "$PAYLOAD" ] && ok "B the node copied the selection: '$buf'" || bad "B node buffer '$buf', want '$PAYLOAD'"
[ "${n:-0}" -ge 1 ] && ok "B the outer terminal received OSC 52 ($n)" || bad "B the outer terminal received no OSC 52"
[ "$got" = "$PAYLOAD" ] && ok "B OSC 52 decodes to the selection: '$got'" || bad "B OSC 52 decoded '$got', want '$PAYLOAD'"

J=$(chain external)
printf 'C shell=external (before #1766) → terminal received: %s\n' "$J"
n=$(field "$J" 'len(d["osc52"])')
[ "${n:-1}" = 0 ] && ok "C shell at external: no OSC 52 reaches the terminal (the bug)" \
  || bad "C shell at external still passed OSC 52 ($n) — the chain test is not measuring the shell's setting"

# --- E. an outer terminal tmux knows no clipboard for -------------------------
J=$(chain "$SHELL_V" screen-256color copy ms)
printf 'E outer TERM=screen-256color, the Ms rows → terminal received: %s\n' "$J"
got=$(field "$J" 'd["osc52"][-1]["text"] if d["osc52"] else ""')
[ "$got" = "$PAYLOAD" ] && ok "E TERM=screen-256color: the copy arrives through the Ms row" || bad "E TERM=screen-256color with the Ms rows: got '$got'"
J=$(chain "$SHELL_V" screen-256color copy noms)
printf 'E outer TERM=screen-256color, no Ms rows (before #2758) → terminal received: %s\n' "$J"
n=$(field "$J" 'len(d["osc52"])')
[ "${n:-1}" = 0 ] && ok "E without the Ms rows the same terminal receives nothing (the row is what does it)" \
  || bad "E without the Ms rows OSC 52 still arrived ($n) — leg E is not measuring the row"

# --- F. a real drag ------------------------------------------------------------
J=$(chain "$SHELL_V" xterm-256color drag ms)
printf 'F a mouse drag over the line → terminal received: %s\n' "$J"
got=$(field "$J" 'd["osc52"][-1]["text"] if d["osc52"] else ""')
[ "$got" = "$PAYLOAD" ] && ok "F drag → release: the selection reaches the terminal as OSC 52: '$got'" \
  || bad "F drag: OSC 52 decoded '$got', want '$PAYLOAD'"

# --- I. the program's own copy -------------------------------------------------
for m in pane pane-pt; do
  J=$(chain "$SHELL_V" xterm-256color "$m" ms)
  printf 'I the node pane writes OSC 52 itself (%s) → terminal received: %s\n' "$m" "$J"
  got=$(field "$J" 'd["osc52"][-1]["text"] if d["osc52"] else ""')
  [ "$got" = "$PAYLOAD" ] && ok "I a program's own copy ($m) crosses the three hops: '$got'" \
    || bad "I $m: OSC 52 decoded '$got', want '$PAYLOAD'"
done

printf 'clipboard-osc52 selftest: %d check(s), %d failure(s)\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
