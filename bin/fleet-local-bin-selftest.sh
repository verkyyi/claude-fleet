#!/bin/bash
# fleet-local-bin-selftest.sh — ~/.local/bin is on the PATH a fleet's tmux server
# runs under (issue #1191), in a sandbox login (its own HOME, FLEET_CONF_DIR,
# install root and tmux sockets — fleet-seed-selftest.sh's sandbox):
#   1. fleet_local_bin_path: prepends $HOME/.local/bin when absent; a PATH that has
#      it (front, middle, end) comes back byte for byte; no substring match.
#   2. fleet-up from a PATH WITHOUT ~/.local/bin: the server's global PATH
#      (`show-environment -g PATH`) starts with $HOME/.local/bin, and a window
#      spawned SERVER-SIDE afterwards (a bind's run-shell → new-window, the
#      respawn path) runs under it — and fleet-up's own output is the four lines
#      it has always printed, byte for byte. (A window spawned by a CLIENT gets
#      that client's PATH — tmux 3.6 — which the zshrc line and the daemon plists
#      carry; one assertion pins that rule so the split stays visible.)
#   3. fleet-up from a PATH WITH ~/.local/bin: the server's PATH is the caller's,
#      byte for byte (no prepend, no duplicate); the same four lines.
#   4. a server already running from a PATH without the dir (an older fleet-up, a
#      daemon's PATH): `fleet-up` on the live fleet says "already up" as before,
#      and the server's PATH now starts with $HOME/.local/bin, the rest untouched;
#      a second run changes nothing more.
# Hub, collector, disk gate and trust check are stubbed in a sandbox bin/; tmux: a
# PATH shim maps every `-L <label>` to a private socket under $SOCKD.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-local-bin-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/shim" "$WORK/root/bin" "$WORK/home" "$WORK/tmp"
# Sockets in a SHORT dir: a unix socket path is capped at ~104 bytes.
SOCKD="$(mktemp -d /tmp/f1191.XXXXXX)" || exit 2
cat > "$WORK/shim/tmux" <<EOS
#!/bin/bash
if [ "\${1:-}" = -L ]; then s="$SOCKD/\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
exec "$REAL_TMUX" -S "$SOCKD/none" "\$@"
EOS
printf '#!/bin/sh\nexit 1\n' > "$WORK/shim/gh"
chmod +x "$WORK/shim/tmux" "$WORK/shim/gh"

cleanup() {
  local s; for s in "$SOCKD"/*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  rm -rf "$WORK" "$SOCKD"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp" FLEET_C="$WORK/cache"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION FLEET_SKIP_GLOBAL_CONF
unset _FLEET_GLOBAL_CONF_SOURCED FLEET_GLOBAL_MAX_SESSIONS FLEET_SEED FLEET_AUTOFILL FLEET_ISSUE_BRIDGE
export FLEET_ONBOARD=0     # no first-fleet guide here (#1169)

# The two PATHs under test: the shim first, then the runner's PATH with every
# `*/.local/bin` dropped (WITHOUT), and the same with the sandbox HOME's own
# ~/.local/bin at the END (WITH — present, but not first, so a prepend would show).
_p=''; _ifs=$IFS; IFS=:; for _d in $PATH; do case "$_d" in */.local/bin) ;; *) _p="$_p${_p:+:}$_d" ;; esac; done; IFS=$_ifs
WITHOUT="$WORK/shim:$_p"
WITH="$WITHOUT:$HOME/.local/bin"
export PATH="$WITHOUT"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ;; *) fail "$1: [$3] not in: $2" ;; esac; }
leg()  { if [ "$FAILS" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; _legf=$FAILS; }

# ---- sandbox install root: the real scripts, hub/collector/gates stubbed ----
SB="$WORK/root/bin"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
rm -f "$SB/hub-session.sh" "$SB/tmux-dash-collect.sh" "$SB/fleet-diskguard.sh" "$SB/fleet-trust.sh"
cat > "$SB/hub-session.sh" <<'EOS'
#!/bin/bash
tmux -L "$HUB_SESSION" new-window -d -t "$HUB_SESSION:" -n plan -c "$HUB_CWD" 'sleep 3600'
EOS
printf '#!/bin/sh\nexit 0\n' > "$SB/tmux-dash-collect.sh"
printf '#!/bin/sh\nexit 0\n' > "$SB/fleet-diskguard.sh"
printf '#!/bin/sh\necho trusted\n' > "$SB/fleet-trust.sh"
chmod +x "$SB"/hub-session.sh "$SB"/tmux-dash-collect.sh "$SB"/fleet-diskguard.sh "$SB"/fleet-trust.sh
UP="$SB/fleet-up.sh"

git init -q "$WORK/src/a" && git -C "$WORK/src/a" remote add origin "https://github.com/o/a.git"
up()      { bash "$UP" "$@" --base master </dev/null 2>&1; }
lib()     { bash -c ". '$SB/fleet-lib.sh'; $1"; }
down()    { "$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null; }
srvpath() { tmux -L fleet show-environment -g PATH 2>/dev/null | sed 's/^PATH=//'; }
# the PATH a window spawned NOW runs under. Server-side (winpath): a run-shell job
# — a dash bind's footing — issues the new-window, so the pane's PATH is the
# server's global environment, not this test's. Client-side (clientpath): this
# test is the client, and tmux hands the pane the client's PATH.
cat > "$WORK/spawn.sh" <<EOS
#!/bin/sh
tmux -L fleet new-window -d -t fleet: "printf '%s' \"\\\$PATH\" > '$WORK/win.path'"
EOS
chmod +x "$WORK/spawn.sh"
_wait() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$WORK/win.path" ] && break; sleep 0.2; done; cat "$WORK/win.path" 2>/dev/null; }
winpath()    { rm -f "$WORK/win.path"; tmux -L fleet run-shell -t fleet: "$WORK/spawn.sh"; _wait; }
clientpath() { rm -f "$WORK/win.path"; "$WORK/spawn.sh"; _wait; }
# fleet-up's output on this sandbox, as it has always been (the byte-for-byte leg)
want=$(printf '%s\n' \
  "fleet-up: reusing existing checkout $WORK/src/a" \
  "fleet-up: wrote $FLEET_CONF_DIR/fleets/fleet/conf" \
  "fleet-up: fleet 'fleet' is up (repo=o/a base=master [flag])" \
  "fleet-up: not attaching (--no-attach) — later: cf")

# ---- 1. the helper ----
eq "1 prepends" "$(HOME=/h PATH=/usr/bin:/bin lib fleet_local_bin_path)" "/h/.local/bin:/usr/bin:/bin"
eq "1 front: unchanged" "$(HOME=/h PATH=/h/.local/bin:/usr/bin:/bin lib fleet_local_bin_path)" "/h/.local/bin:/usr/bin:/bin"
eq "1 middle: unchanged" "$(HOME=/h PATH=/usr/bin:/h/.local/bin:/bin lib fleet_local_bin_path)" "/usr/bin:/h/.local/bin:/bin"
eq "1 end: unchanged" "$(HOME=/h PATH=/usr/bin:/bin:/h/.local/bin lib fleet_local_bin_path)" "/usr/bin:/bin:/h/.local/bin"
eq "1 no substring match" "$(HOME=/h PATH=/h/.local/binx:/usr/bin:/bin lib fleet_local_bin_path)" "/h/.local/bin:/h/.local/binx:/usr/bin:/bin"
leg "1 fleet_local_bin_path: prepend once, never twice"

# ---- 2. fleet-up from a PATH without ~/.local/bin ----
out=$(up o/a "$WORK/src/a" --no-attach); eq "2 rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-up o/a --no-attach (PATH without ~/.local/bin)\n%s\n' "$out"
eq "2 output byte for byte" "$out" "$want"
eq "2 server PATH" "$(srvpath)" "$HOME/.local/bin:$WITHOUT"
eq "2 a window spawned server-side sees it" "$(winpath)" "$HOME/.local/bin:$WITHOUT"
eq "2 a window spawned by a client gets the client's PATH" "$(PATH="$WITH" clientpath)" "$WITH"
down
leg "2 fleet-up puts ~/.local/bin first on the server's PATH"

# ---- 3. fleet-up from a PATH that has it: the caller's PATH, byte for byte ----
rm -rf "$FLEET_CONF_DIR"
out=$(PATH="$WITH" up o/a "$WORK/src/a" --no-attach); eq "3 rc" "$?" 0
eq "3 output byte for byte" "$out" "$want"
eq "3 server PATH = the caller's" "$(srvpath)" "$WITH"
eq "3 once" "$(srvpath | tr ':' '\n' | grep -cx "$HOME/.local/bin")" 1
down
leg "3 a PATH that has it is left byte for byte alone"

# ---- 4. a server already running without it: stamped, the rest untouched ----
tmux -L fleet new-session -d -s fleet -n plan 'sleep 3600'    # an older server, this fleet's conf from leg 3
eq "4 before: no ~/.local/bin" "$(srvpath)" "$WITHOUT"
out=$(up o/a "$WORK/src/a" --no-attach); eq "4 rc" "$?" 0
has "4 already up, as before" "$out" "fleet-up: fleet 'fleet' is already up"
eq "4 server PATH stamped" "$(srvpath)" "$HOME/.local/bin:$WITHOUT"
eq "4 a window spawned server-side sees it" "$(winpath)" "$HOME/.local/bin:$WITHOUT"
out=$(up o/a "$WORK/src/a" --no-attach); eq "4 again rc" "$?" 0
eq "4 again: unchanged" "$(srvpath)" "$HOME/.local/bin:$WITHOUT"
down
leg "4 a live server started without it is stamped once"

[ "$FAILS" = 0 ] || { printf 'selftest FAIL: %d assertion(s)\n' "$FAILS" >&2; exit 1; }
printf 'selftest PASS: ~/.local/bin rides every fleet server PATH (issue #1191) — bash %s\n' "$(bash -c 'echo $BASH_VERSION')"
