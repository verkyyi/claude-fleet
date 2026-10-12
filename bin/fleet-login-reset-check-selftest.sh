#!/bin/bash
# fleet-login-reset-check-selftest.sh — bin/fleet-login-reset-check.py in a
# sandbox (issue #3507, EPIC #3500 C11; BREAK-IT `spare-reuse-leaks`).
#
# For each platform (darwin, linux — the same file, --platform picks the table):
#   A  a home that is only its skeleton, nothing else anywhere → reset: clean, 0
#   B  one thing planted per category → reset: dirty <every category>, 1; the
#      checker's --list must equal the list below, so a category the table loses
#      (or gains with no plant here) is red
#   C  each category cleared in turn → exactly that one leaves the verdict
#   D  the second roads of a category: a LaunchDaemon whose UserName is the
#      login, a linger file, an archived home under the archive dir (not a leak)
#   E  --since: only what predates the wash counts (files by ctime, a process
#      by its start); an unreadable crontab is dirty, never clean
# ps and crontab are PATH shims; every system path sits under --root.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CHECK="$BIN/fleet-login-reset-check.py"
W=$(mktemp -d "${TMPDIR:-/tmp}/reset-check.XXXXXX")
trap 'rm -rf "$W"' EXIT
FAILS=0
fail() { FAILS=$((FAILS + 1)); printf 'selftest FAIL %s\n' "$1"; }
ok() { printf 'ok   %s\n' "$1"; }
L=fleetu7
U=$(id -u)

EXPECT_darwin='home keychain git-cred ssh authorized-keys fleet-conf credsep entry-keys task-state onboard crontab launchd processes tmux outside-files'
EXPECT_linux='home git-cred ssh authorized-keys fleet-conf credsep entry-keys task-state onboard crontab systemd-user processes tmux outside-files'

mkdir -p "$W/shim"
cat > "$W/shim/ps" <<'SH'
#!/bin/sh
cat "$RC_PS" 2>/dev/null; exit 0
SH
cat > "$W/shim/crontab" <<'SH'
#!/bin/sh
if [ -f "$RC_CRON_ERR" ]; then cat "$RC_CRON_ERR" >&2; exit 1; fi
if [ -s "$RC_CRON" ]; then cat "$RC_CRON"; exit 0; fi
echo "crontab: no crontab for $4" >&2; exit 1
SH
chmod +x "$W/shim/ps" "$W/shim/crontab"

setup() {   # setup <platform> → a fresh sandbox $S with a skeleton-only home
  P=$1 S="$W/$1"
  rm -rf "$S"; mkdir -p "$S/sys"
  if [ "$P" = darwin ]; then
    HR="$S/sys/Users" SK="$S/sys/System/Library/User Template/Non_localized" TT="$S/sys/private/tmp"
    OUT1="$S/sys/Users/Shared" ADMIN="$S/sys/Users/admin"
  else
    HR="$S/sys/home" SK="$S/sys/etc/skel" TT="$S/sys/tmp"
    OUT1="$S/sys/var/tmp" ADMIN="$S/sys/home/admin"
  fi
  H="$HR/$L"
  mkdir -p "$SK/Library/Preferences" "$SK/Desktop" "$TT" "$OUT1" "$ADMIN" "$S/sys/var/tmp" "$S/sys/dev/shm" \
    "$S/sys/var/db/fleet-node/logins" "$S/sys/var/db/fleet-cred" "$S/sys/Library/LaunchDaemons" \
    "$S/sys/var/lib/systemd/linger" "$S/sys/Users/Shared/offboarded"
  printf 'x\n' > "$SK/.profile"; printf 'x\n' > "$SK/Library/Preferences/.keep"
  cp -R "$SK" "$H"
  : > "$S/ps"; : > "$S/cron"; rm -f "$S/cron.err"
}
run() {   # run [args…] → $OUT (stdout), $ERR, $RC
  OUT=$(RC_PS="$S/ps" RC_CRON="$S/cron" RC_CRON_ERR="$S/cron.err" PATH="$W/shim:$PATH" \
        python3 "$CHECK" "$L" --platform "$P" --root "$S/sys" --home "$H" --uid "$U" "$@" 2>"$S/err")
  RC=$?; ERR=$(cat "$S/err")
}
verdict() { printf '%s\n' "$OUT" | tail -n 1; }
want() {  # want <label> <expected last line> <expected rc>
  if [ "$(verdict)" = "$2" ] && [ "$RC" = "$3" ]; then ok "$1"
  else fail "$1: wanted '$2' rc $3, got '$(verdict)' rc $RC; stderr: $(printf '%s' "$ERR" | head -n 3)"; fi
}
csv() { printf '%s\n' "$@" | tr ' ' '\n' | grep . | paste -sd, -; }

plant() {   # plant <category>
  case "$1" in
    home) printf 'notes\n' > "$H/notes.txt" ;;
    keychain) mkdir -p "$H/Library/Keychains"; : > "$H/Library/Keychains/login.keychain-db" ;;
    git-cred) printf 'https://u:t@github.com\n' > "$H/.git-credentials" ;;
    ssh) mkdir -p "$H/.ssh"; : > "$H/.ssh/id_ed25519" ;;
    authorized-keys) mkdir -p "$H/.ssh"; printf 'ssh-ed25519 AAAA prev\n' > "$H/.ssh/authorized_keys" ;;
    fleet-conf) mkdir -p "$H/.config/claude-fleet"; : > "$H/.config/claude-fleet/fleet.conf" ;;
    credsep) mkdir -p "$S/sys/var/db/fleet-cred/$L/accounts"; : > "$S/sys/var/db/fleet-cred/$L/accounts/a.json" ;;
    entry-keys) mkdir -p "$S/sys/var/db/fleet-node/entry/keys"; printf 'ssh-ed25519 AAAA prev\n' > "$S/sys/var/db/fleet-node/entry/keys/$L" ;;
    task-state) mkdir -p "$S/sys/var/db/fleet-node/logins/$L/services"; : > "$S/sys/var/db/fleet-node/logins/$L/services/x.json" ;;
    onboard) mkdir -p "$ADMIN/$L-onboard"; : > "$ADMIN/$L-onboard/password.txt" ;;
    crontab) printf '# a comment\n* * * * * echo hi\n' > "$S/cron" ;;
    launchd) mkdir -p "$H/Library/LaunchAgents"; : > "$H/Library/LaunchAgents/com.prev.agent.plist" ;;
    systemd-user) mkdir -p "$H/.config/systemd/user"; : > "$H/.config/systemd/user/prev.service" ;;
    processes) printf '%s 4242 01:02:03 /usr/bin/sleep\n1 1 9-00:00:00 launchd\n' "$U" > "$S/ps" ;;
    tmux) mkdir -p "$TT/tmux-$U"; : > "$TT/tmux-$U/default" ;;
    outside-files) printf 'x\n' > "$OUT1/leftover.txt" ;;
    *) fail "the selftest has no plant for category '$1' — add one"; return 1 ;;
  esac
}
unplant() {
  case "$1" in
    home) rm -f "$H/notes.txt" ;;
    keychain) rm -rf "$H/Library/Keychains" ;;
    git-cred) rm -f "$H/.git-credentials" ;;
    ssh) rm -f "$H/.ssh/id_ed25519" ;;
    authorized-keys) rm -f "$H/.ssh/authorized_keys" ;;
    fleet-conf) rm -rf "$H/.config/claude-fleet" ;;
    credsep) rm -rf "$S/sys/var/db/fleet-cred/$L" ;;
    entry-keys) rm -f "$S/sys/var/db/fleet-node/entry/keys/$L" ;;
    task-state) rm -rf "$S/sys/var/db/fleet-node/logins/$L" ;;
    onboard) rm -rf "$ADMIN/$L-onboard" ;;
    crontab) : > "$S/cron" ;;
    launchd) rm -rf "$H/Library/LaunchAgents" ;;
    systemd-user) rm -rf "$H/.config/systemd/user" ;;
    processes) : > "$S/ps" ;;
    tmux) rm -rf "$TT/tmux-$U" ;;
    outside-files) rm -f "$OUT1/leftover.txt" ;;
  esac
}

NCAT=''
for P in darwin linux; do
  case "$P" in darwin) EXP=$EXPECT_darwin ;; *) EXP=$EXPECT_linux ;; esac
  # The table and this list in lockstep: a category the checker loses or gains is red.
  got=$(python3 "$CHECK" --list --platform "$P" | cut -f1 | paste -sd' ' -)
  [ "$got" = "$EXP" ] && ok "$P: --list is the expected table ($(printf '%s\n' $EXP | grep -c .) categories)" \
    || fail "$P: --list is '$got', the selftest expects '$EXP'"

  setup "$P"
  run; want "$P A: skeleton-only home → clean" 'reset: clean' 0

  for c in $EXP; do plant "$c"; done
  # the onboarding kit inside the login's OWN home is home's, never onboard's
  run; want "$P B: one plant per category → every category" "reset: dirty $(csv "$EXP")" 1
  NCAT="${NCAT:+$NCAT · }$P $(printf '%s\n' $EXP | grep -c .)"

  for c in $EXP; do
    unplant "$c"
    run; want "$P C: cleared $c → only $c leaves" "reset: dirty $(csv "$(printf '%s\n' $EXP | grep -vx -- "$c")")" 1
    plant "$c"
  done

  # D: the other roads in
  setup "$P"
  printf 'x\n' > "$S/sys/Users/Shared/offboarded/$L.tar.gz"
  run
  if [ "$P" = darwin ]; then
    want "$P D: an archived home under the archive dir is not a leak" 'reset: clean' 0
    cat > "$S/sys/Library/LaunchDaemons/com.example.thing.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.example.thing</string><key>UserName</key><string>$L</string></dict></plist>
EOF
    : > "$S/sys/Library/LaunchDaemons/com.ccquota.agent.$L.plist"
    run; want "$P D: a LaunchDaemon running as the login → launchd" 'reset: dirty launchd' 1
    case "$ERR" in *com.example.thing.plist*com.ccquota.agent.$L.plist*|*com.ccquota.agent.$L.plist*com.example.thing.plist*) ok "$P D: both daemons named" ;;
      *) fail "$P D: the launchd detail misses a daemon: $ERR" ;; esac
  else
    : > "$S/sys/var/lib/systemd/linger/$L"
    run; want "$P D: a linger file → systemd-user" 'reset: dirty systemd-user' 1
  fi

  # E: --since (ctime / process start) and fail-closed
  setup "$P"
  rm -rf "$H"; mkdir -p "$H"
  printf 'old\n' > "$H/old.txt"       # the one thing the wash will miss
  printf '%s 1 03:00:00 /bin/old\n' "$U" > "$S/ps"
  sleep 1.2; T=$(python3 -c 'import time; print(time.time())'); sleep 0.2
  cp -R "$SK/." "$H/"                  # the wash: the skeleton made again around it
  mkdir -p "$H/.ssh" "$H/.config/claude-fleet"
  : > "$H/.ssh/id_new"; : > "$H/.config/claude-fleet/fleet.conf"
  run --since "$T"; want "$P E: --since: the old file + the old process count, the new install does not" 'reset: dirty home,processes' 1
  rm -f "$H/old.txt"; printf '%s 1 00:00 /bin/new\n' "$U" > "$S/ps"
  run --since "$T"; want "$P E: --since: only new things → clean" 'reset: clean' 0
  run; want "$P E: no --since: the same new install is a leak" 'reset: dirty ssh,fleet-conf,processes' 1
  rm -rf "$H/.ssh" "$H/.config"; : > "$S/ps"
  printf 'crontab: permission denied\n' > "$S/cron.err"
  run; want "$P E: an unreadable crontab is dirty, not clean" 'reset: dirty crontab' 1
  case "$ERR" in *'cannot read'*) ok "$P E: says it could not read" ;; *) fail "$P E: no 'cannot read' in: $ERR" ;; esac
  rm -f "$S/cron.err"
  run --json
  case "$OUT" in *'"verdict": "clean"'*) ok "$P E: --json clean" ;; *) fail "$P E: --json: $OUT" ;; esac
done

OUT=$(python3 "$CHECK" no-such-login-$$ 2>&1); RC=$?
[ "$RC" = 2 ] && ok 'no such login → exit 2' || fail "no such login: rc $RC: $OUT"

printf 'categories: %s\n' "$NCAT"
if [ "$FAILS" -gt 0 ]; then printf 'fleet-login-reset-check selftest: %d FAILED\n' "$FAILS"; exit 1; fi
printf 'fleet-login-reset-check selftest: OK\n'
