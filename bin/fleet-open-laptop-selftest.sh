#!/bin/bash
# fleet-open-laptop-selftest.sh — the LAPTOP half of fleet-open (issue #1380):
# extras/iterm2/fleet_open.py, extras/iterm2/install.sh, and fleet-doctor's
# `laptop` row. No iTerm2, no network, no real ssh.
#
#   1. `python3 -m unittest` over extras/iterm2/test_*.py (parse, allow-list,
#      host, port choice, ssh/osascript argv) — fleet_open.py imports without
#      the iterm2 module;
#   2. install.sh in a sandbox HOME with PATH shims for `ssh` (-G reads the
#      sandbox ~/.ssh/config; `cat` serves the mini's secret + script) and
#      `defaults` (iTerm2 version + EnableAPIServer):
#      a. --dry-run on a fresh laptop writes NOTHING and lists every step;
#      b. install: script == source, secret 0600, host, default allow-list, the
#         three ssh keys added under the existing Host block, a dated backup;
#      c. a second run (and a second --dry-run) changes nothing: `changes: 0`,
#         every file byte-identical;
#      d. a Host block that already has ControlMaster gets only the other two;
#         no Host block at all → one appended; an existing allow-list is kept;
#      e. API off → a WARN, exit 0, and `defaults write` never runs;
#      f. iTerm2 3.4 → refused (exit 1);
#      g. `bash -s -- --mini …` with no fleet_open.py beside it fetches the
#         script from the mini;
#      h. --uninstall removes script/secret/host, keeps log + allow; again = 0;
#   3. fleet-doctor's laptop row: unset → no row; installed same version → PASS;
#      older → WARN; missing → WARN; unreachable → INFO `?`, never WARN/FAIL.
# Runs install.sh under /bin/bash when that is 3.x (the macOS floor, #703).
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
EX="$ROOT/extras/iterm2"
for f in "$EX/fleet_open.py" "$EX/install.sh" "$EX/test_fleet_open.py" "$BIN/fleet-doctor.sh"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
command -v python3 >/dev/null || { printf 'selftest: python3 missing\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-open-laptop-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- out ---\n%s\n' "$(cat "$WORK/out" 2>/dev/null)" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }

# --- 1. unit tests ----------------------------------------------------------
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$EX" -p 'test_*.py' >"$WORK/out" 2>&1 \
  || fail "python unittest failed"
grep -q '^OK' "$WORK/out" || fail "unittest did not report OK"
ok

# --- 2. install.sh ----------------------------------------------------------
SH=bash
case "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" in 3) SH=/bin/bash ;; esac

mkdir -p "$WORK/shim" "$WORK/mini/.claude/fleet/extras/iterm2" "$WORK/mini/.config/claude-fleet" "$WORK/iTerm.app/Contents"
cp "$EX/fleet_open.py" "$WORK/mini/.claude/fleet/extras/iterm2/"
printf 's3cr3t-token\n' > "$WORK/mini/.config/claude-fleet/open.secret"

# ssh shim: `-G <alias>` derives the three keys from $HOME/.ssh/config (what we
# edit); otherwise run the remote command with ~ = the fake mini's home, or — for
# the doctor's laptop probe — with HOME = $SHIM_LAPTOP_HOME.
cat > "$WORK/shim/ssh" <<'EOF'
#!/bin/bash
if [ "$1" = -G ]; then
  c="$HOME/.ssh/config"
  grep -qi '^[[:space:]]*ControlMaster[[:space:]]' "$c" 2>/dev/null && echo 'controlmaster auto' || echo 'controlmaster false'
  grep -qi '^[[:space:]]*ControlPath[[:space:]]' "$c" 2>/dev/null && echo 'controlpath /x/cm-abc' || echo 'controlpath none'
  grep -qi '^[[:space:]]*ControlPersist[[:space:]]' "$c" 2>/dev/null && echo 'controlpersist 600'
  exit 0
fi
[ "${SHIM_SSH_DOWN:-0}" = 1 ] && exit 255
while [ $# -gt 1 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) shift; break ;; esac; done
if [ -n "${SHIM_LAPTOP_HOME:-}" ]; then HOME="$SHIM_LAPTOP_HOME" sh -c "$1"; exit; fi
cmd="${1//\~/$SHIM_MINI_HOME}"
sh -c "$cmd"
EOF
cat > "$WORK/shim/defaults" <<'EOF'
#!/bin/sh
case "$1" in write) echo "defaults $*" >> "$SHIM_LOG"; exit 0 ;; esac
case "$3" in
  CFBundleShortVersionString) echo "${SHIM_ITERM_VER:-3.5.4}" ;;
  EnableAPIServer) [ "${SHIM_API:-1}" = x ] && exit 1; echo "${SHIM_API:-1}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/shim/ssh" "$WORK/shim/defaults"

H="$WORK/home"
fresh_home() {
  rm -rf "$H"; mkdir -p "$H/.ssh" "$H/Library/Application Support/iTerm2/iterm2env-3.12"
  printf 'Host *\n  ServerAliveInterval 30\n\nHost macmini\n  HostName mini.local\n  User op\n' > "$H/.ssh/config"
}
inst() {   # inst [install.sh args…] → $WORK/out, exit code in $RC
  env HOME="$H" PATH="$WORK/shim:$PATH" FLEET_OPEN_ITERM_APP="$WORK/iTerm.app" \
    SHIM_MINI_HOME="$WORK/mini" SHIM_LOG="$WORK/defaults.log" \
    "$SH" "$EX/install.sh" "$@" >"$WORK/out" 2>&1
  RC=$?
  grep -q 'unbound variable' "$WORK/out" && fail "install.sh died on an unbound variable"
  return 0
}
snap() { (cd "$H" && find . -type f ! -name 'iterm2env*' -exec cksum {} \; | sort) ; }
AL="$H/Library/Application Support/iTerm2/Scripts/AutoLaunch/fleet_open.py"
C="$H/.config/fleet-open"

# a. dry run on a fresh laptop
fresh_home; before="$(snap)"
inst --mini macmini --dry-run
[ "$RC" = 0 ] || fail "dry-run exit $RC"
[ "$(snap)" = "$before" ] || fail "dry-run changed files"
[ -e "$C" ] && fail "dry-run created $C"
for w in 'would  install fleet_open.py v' 'would  install secret' 'would  install host alias' \
         'would  install default allow-list' 'would  add ControlMaster ControlPath ControlPersist to Host macmini'; do
  grep -qF "$w" "$WORK/out" || fail "dry-run lacks: $w"
done
grep -q '^changes: [1-9]' "$WORK/out" || fail "dry-run did not count its changes"
ok

# b. install
inst --mini macmini
[ "$RC" = 0 ] || fail "install exit $RC"
cmp -s "$AL" "$EX/fleet_open.py" || fail "AutoLaunch script differs from the source"
[ "$(cat "$C/secret")" = s3cr3t-token ] || fail "secret content"
[ "$(stat -f %Lp "$C/secret" 2>/dev/null || stat -c %a "$C/secret")" = 600 ] || fail "secret not 0600"
[ "$(cat "$C/host")" = macmini ] || fail "host file"
grep -qx 'github.com' "$C/allow" && grep -qx 'claude.ai' "$C/allow" || fail "default allow-list"
ls "$H/.ssh/config.bak-"* >/dev/null 2>&1 || fail "no ssh config backup"
awk '/^Host macmini/{f=1;next} /^Host /{f=0} f' "$H/.ssh/config" > "$WORK/blk"
for k in 'ControlMaster auto' 'ControlPath ~/.ssh/cm-%C' 'ControlPersist 10m' 'HostName mini.local'; do
  grep -qF "$k" "$WORK/blk" || fail "Host macmini block lacks: $k"
done
[ "$(grep -c '^Host ' "$H/.ssh/config")" = 2 ] || fail "a Host block was added/lost"
grep -q '^changes: [1-9]' "$WORK/out" || fail "install reported no changes"
ok

# c. idempotent
before="$(snap)"
inst --mini macmini
[ "$RC" = 0 ] && grep -q '^changes: 0' "$WORK/out" || fail "second install not a no-op"
[ "$(snap)" = "$before" ] || fail "second install changed files"
inst --dry-run       # alias now comes from ~/.config/fleet-open/host
[ "$RC" = 0 ] && grep -q '^changes: 0' "$WORK/out" || fail "dry-run on an installed laptop not a no-op"
grep -q 'would' "$WORK/out" && fail "dry-run on an installed laptop would change something"
set -- "$H/.ssh/config.bak-"*; [ "$#" = 1 ] || fail "backup multiplied"
ok

# d. partial ssh config, no Host block, kept allow-list
fresh_home
printf 'Host macmini\n  ControlMaster auto\n' > "$H/.ssh/config"
mkdir -p "$C"; printf 'example.org\n' > "$C/allow"
inst --mini macmini
[ "$RC" = 0 ] || fail "partial install exit $RC"
[ "$(grep -c ControlMaster "$H/.ssh/config")" = 1 ] || fail "ControlMaster duplicated"
grep -q 'add ControlPath ControlPersist to Host macmini' "$WORK/out" || fail "should add only the two missing keys"
[ "$(cat "$C/allow")" = example.org ] || fail "existing allow-list overwritten"
fresh_home; printf 'Host other\n  User x\n' > "$H/.ssh/config"
inst --mini macmini
grep -q '^Host macmini$' "$H/.ssh/config" && grep -q '^Host other$' "$H/.ssh/config" || fail "Host block not appended"
inst --mini macmini; grep -q '^changes: 0' "$WORK/out" || fail "appended block not idempotent"
fresh_home; rm -f "$H/.ssh/config"
inst --mini macmini
[ "$RC" = 0 ] && grep -q '^Host macmini$' "$H/.ssh/config" || fail "no ~/.ssh/config: not created"
ok

# e. API off → warn, never flipped
fresh_home; rm -f "$WORK/defaults.log"
SHIM_API=0 inst --mini macmini
[ "$RC" = 0 ] || fail "API-off install should still exit 0"
grep -q 'WARN.*Python API is OFF' "$WORK/out" || fail "no API-off warning"
[ -e "$WORK/defaults.log" ] && fail "install.sh ran defaults write"
SHIM_API=x inst --mini macmini; grep -q 'Python API is OFF' "$WORK/out" || fail "unset key not read as off"
ok

# f. old iTerm2
fresh_home
SHIM_ITERM_VER=3.4.19 inst --mini macmini
[ "$RC" = 1 ] && grep -q 'too old' "$WORK/out" || fail "iTerm2 3.4 not refused (rc=$RC)"
[ -e "$AL" ] && fail "installed despite old iTerm2"
SHIM_ITERM_VER=3.10.0 inst --mini macmini
[ "$RC" = 0 ] || fail "3.10 compared as older than 3.5"
ok

# g. remote: script piped on stdin, fetched back from the mini
fresh_home
(cd "$WORK" && env HOME="$H" PATH="$WORK/shim:$PATH" FLEET_OPEN_ITERM_APP="$WORK/iTerm.app" \
  SHIM_MINI_HOME="$WORK/mini" "$SH" -s -- --mini macmini < "$EX/install.sh" >"$WORK/out" 2>&1) \
  || fail "bash -s install failed"
grep -q 'script source: macmini:' "$WORK/out" || fail "bash -s did not fetch the script from the mini"
cmp -s "$AL" "$EX/fleet_open.py" || fail "fetched script differs"
ok

# h. uninstall
printf 'x\n' > "$C/log"
inst --uninstall
[ "$RC" = 0 ] || fail "uninstall exit $RC"
[ -e "$AL" ] || [ -e "$C/secret" ] || [ -e "$C/host" ] && fail "uninstall left files"
[ -f "$C/log" ] && [ -f "$C/allow" ] || fail "uninstall removed log/allow"
inst --uninstall; grep -q '^changes: 0' "$WORK/out" || fail "second uninstall not a no-op"
ok

# --- 3. fleet-doctor laptop row --------------------------------------------
LH="$WORK/laptop"; mkdir -p "$LH/Library/Application Support/iTerm2/Scripts/AutoLaunch"
LAL="$LH/Library/Application Support/iTerm2/Scripts/AutoLaunch/fleet_open.py"
doc() {
  env HOME="$WORK/dochome" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/shim:$PATH" \
    SHIM_LAPTOP_HOME="$LH" "$@" sh "$BIN/fleet-doctor.sh" >"$WORK/out" 2>&1
  grep -q 'unbound variable' "$WORK/out" && fail "doctor died on an unbound variable"
  grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+laptop[[:space:]]' "$WORK/out"
}
mkdir -p "$WORK/dochome" "$WORK/conf"
[ -z "$(doc env)" ] || fail "laptop row printed with FLEET_OPEN_LAPTOP unset"
v="$(sed -n 's/^FLEET_OPEN_VERSION = "\([0-9]*\)".*/\1/p' "$EX/fleet_open.py")"
cp "$EX/fleet_open.py" "$LAL"
doc env FLEET_OPEN_LAPTOP=macbook | grep -q "PASS.*laptop.*v$v installed on macbook" || fail "same version not PASS"
sed 's/^FLEET_OPEN_VERSION = .*/FLEET_OPEN_VERSION = "0"/' "$EX/fleet_open.py" > "$LAL"
doc env FLEET_OPEN_LAPTOP=macbook | grep -q "WARN.*laptop.*v0 on macbook, this checkout has v$v" || fail "old version not WARN"
rm -f "$LAL"
doc env FLEET_OPEN_LAPTOP=macbook | grep -q 'WARN.*laptop.*not installed on macbook' || fail "missing not WARN"
r="$(doc env FLEET_OPEN_LAPTOP=macbook SHIM_SSH_DOWN=1)"
printf '%s\n' "$r" | grep -q 'INFO.*laptop.*? macbook unreachable' || fail "unreachable not INFO ?"
ok

printf 'fleet-open-laptop-selftest: %d checks passed\n' "$CHECKS"
