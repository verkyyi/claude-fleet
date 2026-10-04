#!/bin/bash
# fleet-hub-node-env-selftest.sh — `bin/fleet-hub-node.sh env [--write]` (issue
# #1491): this login's node token file, $FLEET_CONF_DIR/node.env, filled once from
# the ccquota agent's launchd plist for a login whose agent predates
# fleet-node-join.sh (its token lives only in the plist's EnvironmentVariables, so
# every `ccquota lease|place|move` from its fleet panes exited 1 「no hub
# configured」). Hermetic: HOME, FLEET_CONF_DIR and the daemon dir are a sandbox,
# `sudo` is a shim that opens a closed dir for the one command and closes it again.
#
#   A. report    no node.env → `env` exits 1, says missing + the fix
#   B. write     a gui LaunchAgent plist → `--write` exits 0, node.env is 0600, the
#                CCQUOTA_* strings copied (hub URL + token first, the rest sorted),
#                a non-CCQUOTA key and a non-string value left out; NO output line
#                ever carries the token's value
#   C. rerun     `--write` again → already present, file untouched; `--force` after
#                the plist changed → rewritten
#   D. daemon    no LaunchAgent; the system LaunchDaemon's dir is closed to this
#                login → read through `sudo -n` (test -r, then cat), written
#   E. none      no plist anywhere → exit 1, the line names both places it looked
#   F. --plist   an explicit file → written; one without CCQUOTA_TOKEN → exit 3,
#                nothing written
#   G. perms     a 0644 node.env → `env` says group/other-readable, chmod 600
#   H. no token  node.env without a CCQUOTA_TOKEN= line → `env` exits 1 and says
#                so; `--write` (no --force needed) rewrites it
#   I. usage     an unknown flag → exit 2; `paths` still answers
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
HN="$BIN/fleet-hub-node.sh"
[ -f "$HN" ] || { printf 'selftest: %s not found\n' "$HN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-node-env-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
DD="$WORK/daemons"
cleanup() { chmod 755 "$DD" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }
contains() { case "$2" in *"$3"*) ok ;; *) fail "$1 — output lacks [$3]" "$2" ;; esac; }
not_contains() { case "$2" in *"$3"*) fail "$1 — output carries [$3]" "$2" ;; *) ok ;; esac; }
eq() { [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; ok; }

mkdir -p "$WORK/home/Library/LaunchAgents" "$WORK/conf" "$DD" "$WORK/shim"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK"
export FLEET_HUB_NODE_SUDO='' FLEET_HUB_NODE_DAEMON_DIR="$DD"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL
NE="$WORK/conf/node.env"
AGENT="$WORK/home/Library/LaunchAgents/com.ccquota.agent.plist"
DAEMON="$DD/com.ccquota.agent.$(id -un).plist"
TOKEN='fn_SECRET_1234567890abcdef'

# plist <label> <token> [<extra dict rows>] → an XML plist the way the hand-written
# ones look (docs/SHARED-MACHINE.md step 4): EnvironmentVariables with the hub
# settings, plus HOME (not CCQUOTA_*) and an integer (not a string).
plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>/x/ccquota</string><string>agent</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CCQUOTA_TOKEN</key><string>$2</string>
    <key>CCQUOTA_HUB_URL</key><string>https://hub.test</string>
    <key>CCQUOTA_FLEET</key><string>1</string>
    <key>CCQUOTA_FLEET_ADMIN</key><string>1</string>
    <key>CCQUOTA_FLEET_NODE_ROUTES</key><string>a,b</string>
    <key>CCQUOTA_INT</key><integer>7</integer>
    <key>HOME</key><string>/Users/x</string>
    ${3:-}
  </dict>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
}
run() { OUT=$(bash "$HN" env "$@" 2>&1); RC=$?; }
mode() { ls -ld "$1" | cut -c1-10; }

# --- A. report: missing -------------------------------------------------------
run
eq "A: missing → exit 1" 1 "$RC"
contains "A: says missing" "$OUT" "node.env: missing ($NE)"
contains "A: carries the fix" "$OUT" 'fleet-hub-node.sh env --write'

# --- B. write from the gui LaunchAgent ------------------------------------------
plist com.ccquota.agent "$TOKEN" > "$AGENT"; chmod 600 "$AGENT"
run --write
eq "B: --write → exit 0" 0 "$RC"
contains "B: says written, names the source" "$OUT" "node.env: written from $AGENT"
contains "B: lists the keys, hub URL + token first, rest sorted" "$OUT" "keys: CCQUOTA_HUB_URL CCQUOTA_TOKEN CCQUOTA_FLEET CCQUOTA_FLEET_ADMIN CCQUOTA_FLEET_NODE_ROUTES ("
not_contains "B: the token's VALUE is never printed" "$OUT" "$TOKEN"
[ -f "$NE" ] || fail "B: node.env written"
eq "B: 0600" "-rw-------" "$(mode "$NE")"
eq "B: contents" "CCQUOTA_HUB_URL=https://hub.test
CCQUOTA_TOKEN=$TOKEN
CCQUOTA_FLEET=1
CCQUOTA_FLEET_ADMIN=1
CCQUOTA_FLEET_NODE_ROUTES=a,b" "$(grep -v '^#' "$NE")"
contains "B: a header comment names the source" "$(head -1 "$NE")" "# claude-fleet fleet-hub-node env --write (issue #1491) from $AGENT"
not_contains "B: HOME is not a CCQUOTA_* key" "$(cat "$NE")" "HOME="
not_contains "B: an integer value is not copied" "$(cat "$NE")" "CCQUOTA_INT"
[ -e "$NE.tmp" ] && fail "B: the temp file is gone"
ok
run
eq "B: report → exit 0" 0 "$RC"
contains "B: report says present, 0600" "$OUT" "node.env: present ($NE, 0600)"
# fleet-lib's reader sees the same token (what fleet_hub_* will export per call)
got=$(cd "$WORK" && bash -c '. "$1/fleet-lib.sh"; _fleet_node_env_val CCQUOTA_TOKEN' _ "$BIN")
eq "B: fleet-lib reads the token back" "$TOKEN" "$got"

# --- C. rerun / --force ----------------------------------------------------------
sum1=$(cksum < "$NE")
plist com.ccquota.agent "fn_NEWER_token" > "$AGENT"
run --write
eq "C: rerun → exit 0" 0 "$RC"
contains "C: says already present" "$OUT" "node.env: already present ($NE) — --force rewrites it"
eq "C: file untouched" "$sum1" "$(cksum < "$NE")"
run --write --force
eq "C: --force → exit 0" 0 "$RC"
contains "C: --force rewrote it" "$OUT" "node.env: written from $AGENT"
eq "C: the new token is in" "CCQUOTA_TOKEN=fn_NEWER_token" "$(grep '^CCQUOTA_TOKEN=' "$NE")"
eq "C: still 0600" "-rw-------" "$(mode "$NE")"

# --- D. the system LaunchDaemon in a closed dir, through sudo -n ------------------
rm -f "$NE" "$AGENT"
plist "com.ccquota.agent.$(id -un)" "$TOKEN" > "$DAEMON"
chmod 000 "$DD"
[ -r "$DAEMON" ] && fail "D: setup — the daemon dir must be closed to this login"
cat > "$WORK/shim/sudo" <<EOF
#!/bin/sh
# fake passwordless sudo: log, drop -n, open the dir for the one command, close it
echo "\$*" >> "$WORK/sudo.log"
[ "\$1" = -n ] && shift
chmod 755 "$DD"; "\$@"; rc=\$?; chmod 000 "$DD"; exit \$rc
EOF
chmod +x "$WORK/shim/sudo"
run --write
chmod 755 "$DD"
eq "D: no sudo → exit 1 (cannot see the daemon's plist)" 1 "$RC"
contains "D: no sudo → names both places" "$OUT" "looked for $AGENT $DAEMON"
chmod 000 "$DD"
FLEET_HUB_NODE_SUDO="$WORK/shim/sudo -n" run --write
chmod 755 "$DD"
eq "D: with sudo → exit 0" 0 "$RC"
contains "D: written from the daemon's plist" "$OUT" "node.env: written from $DAEMON"
contains "D: sudo probed readability" "$(cat "$WORK/sudo.log")" "-n test -r $DAEMON"
contains "D: sudo read the bytes" "$(cat "$WORK/sudo.log")" "-n cat $DAEMON"
eq "D: 0600" "-rw-------" "$(mode "$NE")"
eq "D: the token is in" "CCQUOTA_TOKEN=$TOKEN" "$(grep '^CCQUOTA_TOKEN=' "$NE")"
not_contains "D: the token's VALUE is never printed" "$OUT" "$TOKEN"

# --- E. no plist anywhere --------------------------------------------------------
rm -f "$NE" "$DAEMON"
run --write
eq "E: nothing to fill from → exit 1" 1 "$RC"
contains "E: says missing and where it looked" "$OUT" "node.env: missing ($NE) and no agent service definition to fill it from — looked for $AGENT $DAEMON"
contains "E: points at --plist / re-join" "$OUT" "pass --plist <file>, or re-join with fleet-node-join.sh"
[ -e "$NE" ] && fail "E: nothing written"
ok

# --- F. --plist <file>; one without a token ----------------------------------------
plist com.x "$TOKEN" > "$WORK/other.plist"
run --write --plist "$WORK/other.plist"
eq "F: explicit plist → exit 0" 0 "$RC"
contains "F: written from it" "$OUT" "node.env: written from $WORK/other.plist"
rm -f "$NE"
plist com.x "" > "$WORK/notoken.plist"
run --write --plist "$WORK/notoken.plist"
eq "F: no token in the plist → exit 3" 3 "$RC"
contains "F: says so" "$OUT" "$WORK/notoken.plist carries no CCQUOTA_TOKEN in EnvironmentVariables — nothing written"
[ -e "$NE" ] && fail "F: nothing written for a token-less plist"
ok
printf 'not a plist\n' > "$WORK/junk.plist"
run --write --plist "$WORK/junk.plist"
eq "F: not a plist → exit 1" 1 "$RC"
contains "F: says it cannot read it" "$OUT" "cannot read $WORK/junk.plist"

# --- G. perms --------------------------------------------------------------------
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=%s\n' "$TOKEN" > "$NE"; chmod 644 "$NE"
run
eq "G: readable node.env → exit 0 (present, flagged)" 0 "$RC"
contains "G: flags the mode" "$OUT" "node.env: present but group/other-readable (-rw-r--r--) — chmod 600 $NE"
chmod 600 "$NE"

# --- H. node.env without a token line --------------------------------------------
printf 'CCQUOTA_HUB_URL=https://hub.test\n' > "$NE"; chmod 600 "$NE"
run
eq "H: no token line → exit 1" 1 "$RC"
contains "H: says so" "$OUT" "node.env: present but has no CCQUOTA_TOKEN= line ($NE)"
plist com.ccquota.agent "$TOKEN" > "$AGENT"; chmod 600 "$AGENT"
run --write
eq "H: --write fills it without --force" 0 "$RC"
contains "H: written" "$OUT" "node.env: written from $AGENT"
eq "H: the token is in" "CCQUOTA_TOKEN=$TOKEN" "$(grep '^CCQUOTA_TOKEN=' "$NE")"

# --- I. usage --------------------------------------------------------------------
run --bogus
eq "I: unknown flag → exit 2" 2 "$RC"
contains "I: usage line" "$OUT" "usage: fleet-hub-node.sh env [--write [--force]] [--plist <file>]"
OUT=$(bash "$HN" paths 2>&1); RC=$?
eq "I: paths still answers" 0 "$RC"
contains "I: paths prints the outbox" "$OUT" "outbox"

printf 'fleet-hub-node-env-selftest OK (%s checks)\n' "$CHECKS"
