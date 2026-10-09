#!/bin/bash
# fleet-login-new-selftest.sh — bin/fleet-login-new.sh against a fake homes root,
# fully hermetic (issue #1164): no real account, no real sudo. sudo, sysadminctl,
# createhomedir, dseditgroup, dscl, id, chown and launchctl are PATH shims that
# log what they were asked (sudo -u <login> -H runs the command as us, HOME
# untouched); mkdir / tee / cp / chmod / install / git run for real inside the
# sandbox, against a local fixture "GitHub" (FLEET_BOOTSTRAP_GIT_BASE) holding
# the real launchd/ templates + fleet-install-apply.sh, tagged stable.
#
# The home is UNREADABLE to the admin (issue #1213): macOS creates it 700, so
# the admin's own process cannot list or read the clone inside it — only root
# (`sudo …`) and the login (`sudo -u <login>`) can. The createhomedir shim
# makes the fake home mode 000 and the sudo shim unlocks it around each call
# it runs, so a bare read of the home by the script fails here exactly as it
# does on the real machine (#1210 ①: step 8 listed 0 templates and exited 0).
#
# What it pins:
#   A. dry run    lists every command (addUser, home, ssh group, key, pool, clone,
#                 the daemons), runs NONE of them, creates nothing — not even the
#                 password file — exit 0; addUser is never `-password -` (#1192)
#   B. --apply    call order addUser → createhomedir → dseditgroup → key → pool;
#                 .ssh 700 + authorized_keys 600 holding the key; chown to the
#                 login; the pool copy = exactly the source's tokens + .conf
#                 (no dotfiles, no editor backups), dir 700, files 600; ~/.zshrc =
#                 the ~/.local/bin PATH line (#1191) then the bootstrap block
#                 (#1165) — the line once and first — 644, owned by the login
#   B2. password  (#1192) a random one → ~/<login>-onboard/password.txt (600) in
#                 the ADMIN's home, never printed; --password-file <f> uses f's
#                 first line and writes nothing. (#2396) It is on NO shim's argv:
#                 addUser goes shell-less with no -password, the password reaches
#                 `dscl .` on stdin (`passwd /Users/<login> <pw>`), the shell
#                 comes back after; a DS error on that stdin → FAILED; a
#                 --password-file line with a space / quote / backslash → exit 2
#   B3. daemons   (#1192) the clone at stable as the login (~<login>/.claude/fleet
#                 + logs/); every launchd template rendered in system shape —
#                 Label com.claude-fleet.<login>.<unit>, UserName <login>, __HOME__
#                 = its home — installed 644 under FLEET_INSTALL_DAEMON_DIR and
#                 `launchctl bootstrap system`'d, 14 of them from the real repo
#                 — read AS THE LOGIN out of its 700 home (#1213), `installed
#                 N/N` printed, the home still unreadable to the admin at the
#                 end; --no-daemons skips that step and prints the GUI sign-in
#                 step
#   C. exists     a known login → exit 3 in both modes, nothing run; an existing
#                 home dir alone → exit 3
#   D. no group   no com.apple.access_ssh → step skipped, dseditgroup never run
#   E. usage      bad name / no --full-name / unreadable key / --apply with an
#                 empty key / --share-pool with no pool → exit 2, nothing run
#   F. failure    a failing step under --apply stops there (exit 1)
#   G. bash 3.2   no `unbound variable` on any path (runs under /bin/bash, 3.2 on
#                 macOS), with and without --share-pool
#   H. cwd        (#1216) run from the admin's own 0700 home — the sudo shim
#                 refuses any `sudo -u` from under it the way git died on getcwd
#                 (#1210 ④) — with a RELATIVE --pubkey / --pool-src /
#                 --password-file: --apply goes through, every relative path is
#                 found, the transcript shows them absolute; a dry run likewise
#   I. 0 units    (#1213) a stable with no launchd/*.plist.tmpl → --apply fails
#                 at step 8 (exit 1) naming the dir + the login it read as,
#                 nothing installed, nothing bootstrapped — never "nothing to
#                 install" + exit 0; a dry run from an install without launchd/
#                 warns and exits 0
#   J. welcome    (#1195) no --pubkey → a temporary ed25519 pair in the admin's
#                 ~/<login>-onboard/ (700; key 600), its public half installed,
#                 its private half in welcome.txt (600) with the ssh line + config
#                 snippet from FLEET_SSH_PUBLIC_HOST/PORT (env, or the login's
#                 fleet.settings), the swap-the-key steps, fleet guide (no cf, #1711), the human
#                 steps — never the password, never the key on the terminal;
#                 --pubkey + --lang en → their own key's public line, no private
#                 block, English; host unset → `<HOST>` in the letter + a WARN;
#                 --no-welcome without --pubkey / a bad --lang / a bad port → 2;
#                 --no-welcome writes no letter; a dry run plans both, writes none
#   K. daemons-only (#1223) an existing login + its clone, no daemons → `--daemons-only
#                 --apply` = N install + N bootstrap system calls, steps 1–7 zero,
#                 `installed N/N`; a rerun leaves every unit alone; one missing
#                 unit → only it; no clone → exit 1 naming it; no such login / no
#                 home → exit 4, nothing run; another step's option → exit 2
#   L. cache      (#2297) FLEET_BOOTSTRAP_CACHE on, GitHub unreachable: --apply
#                 refreshes the cache as root (stable + the admin's claude), clones
#                 the login's install from it (safe.directory, --no-local), points
#                 origin back at GitHub — exit 0, HEAD at stable; a dry run shows
#                 the refresh + the cached clone and says what happens with none
#   N. full name  (#2210) a full name another login carries → `<name> (<login>)`
#                 passed to sysadminctl, a note on stderr; that one taken too →
#                 exit 3, nothing run; sysadminctl "succeeding" without making
#                 the login → FAILED at step 1, step 2 never run
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
S="$BIN/fleet-login-new.sh"
[ -f "$S" ] || { printf 'selftest: %s not found\n' "$S" >&2; exit 2; }
BASH_BIN=/bin/bash; [ -x "$BASH_BIN" ] || BASH_BIN=bash

WORK="$(mktemp -d "${TMPDIR:-/tmp}/login-new-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
LPID='' FPID='' HPID='' SRUN=''
trap 'kill $LPID $FPID $HPID 2>/dev/null; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK" ${SRUN:+"$SRUN"}' EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:
$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]:
$2";; esac; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- shims ------------------------------------------------------------------
LOG="$WORK/calls.log"
DLOG="$WORK/dscl-stdin.log"   # what interactive `dscl .` read on stdin (#2396)
mkdir -p "$WORK/shim"
# the admin's own home is 0700: from under CALLER (their repo checkout, where
# docs/SHARED-MACHINE.md's example is typed) "the login" cannot stand — a
# `sudo -u` run from there dies the way git did on getcwd (issue #1216)
CALLER="$WORK/admin/projects/claude-fleet"
# root and the login can read the home; the admin's bare process cannot (#1213):
# unlock every fake home around the command, relock after — never exec.
cat > "$WORK/shim/sudo" <<EOF
#!/bin/sh
# sudo -u <login> -H <cmd…>: as "the login" = us (the sandbox home is ours)
if [ "\$1" = -u ]; then
  case "\$PWD/" in "$CALLER/"*) echo "fatal: Unable to read current working directory: Permission denied" >&2; exit 128 ;; esac
  shift 2; [ "\$1" = -H ] && shift
fi
echo "sudo \$1" >> "$LOG"
for h in "\$FLEET_LOGIN_HOMES"/*; do [ -d "\$h" ] && chmod 700 "\$h"; done
"\$@"; rc=\$?
for h in "\$FLEET_LOGIN_HOMES"/*; do [ -d "\$h" ] && chmod 000 "\$h"; done
exit \$rc
EOF
for t in sysadminctl dseditgroup chown launchctl; do
  cat > "$WORK/shim/$t" <<EOF
#!/bin/sh
echo "$t \$*" >> "$LOG"
[ -n "\${FAKE_FAIL:-}" ] && [ "\$FAKE_FAIL" = "$t" ] && exit 1
exit 0
EOF
done
cat > "$WORK/shim/createhomedir" <<EOF
#!/bin/sh
echo "createhomedir \$*" >> "$LOG"
mkdir -p "\$FLEET_LOGIN_HOMES/\$3" && chmod 000 "\$FLEET_LOGIN_HOMES/\$3"
EOF
# `dscl . -list /Users RealName` answers FAKE_REALNAMES ("<login>=<full name>;…",
# issue #2210); every other read answers the ssh group's presence
cat > "$WORK/shim/dscl" <<EOF
#!/bin/sh
echo "dscl \$*" >> "$LOG"
# interactive \`dscl .\` (issue #2396): its commands come on stdin, kept apart
# from the argv log; FAKE_DSCL_ERR plays a DS error, which dscl answers with exit 0
if [ \$# -eq 1 ]; then
  cat >> "$DLOG"
  [ -n "\${FAKE_DSCL_ERR:-}" ] && echo "passwd: DS Error: -14165 (eDSAuthPasswordQualityCheckFailed)"
  echo Goodbye; exit 0
fi
[ "\$2" = -create ] && exit 0
if [ "\$2" = -list ] && [ "\$4" = RealName ]; then
  printf '%s' "\${FAKE_REALNAMES:-}" | tr ';' '\n' | sed 's/=/ /'; exit 0
fi
[ "\${FAKE_SSH_GROUP:-1}" = 1 ]
EOF
# a login exists when FAKE_EXISTING names it, or this run's sysadminctl made it
# (the shim logs it; FAKE_NOCREATE plays macOS refusing with exit 0 — #2210)
cat > "$WORK/shim/id" <<EOF
#!/bin/sh
for u in \${FAKE_EXISTING:-}; do [ "\$1" = "\$u" ] && { echo "uid=501(\$u)"; exit 0; }; done
[ -z "\${FAKE_NOCREATE:-}" ] && grep -q "^sysadminctl -addUser \$1 " "$LOG" 2>/dev/null && { echo "uid=502(\$1)"; exit 0; }
exit 1
EOF
chmod +x "$WORK/shim/"*
export PATH="$WORK/shim:$PATH"
export FLEET_LOGIN_HOMES="$WORK/homes"
mkdir -p "$FLEET_LOGIN_HOMES"
# step 7b (issue #2294) runs the real fleet-credsep.sh install through the sudo
# shim: every root path under the sandbox (its FLEET_CREDSEP_* seams), the role
# account played by us, each new login a FLEET_CREDSEP_PW row (its home under
# FLEET_LOGIN_HOMES), no launchctl, no wait for a proxy nobody starts here
# (the run dir holds the proxy's ctl.sock: a short /tmp path, AF_UNIX caps it at 104 bytes)
SRUN=$(mktemp -d /tmp/lns.XXXXXX) || exit 2
ME=$(/usr/bin/id -un)
export FLEET_CREDSEP_ROOT_BASE="$WORK/credsep/db" FLEET_CREDSEP_RUN_BASE="$SRUN" \
       FLEET_CREDSEP_LOG_BASE="$WORK/credsep/log" FLEET_CREDSEP_LIB="$WORK/credsep/lib" \
       FLEET_CREDSEP_DAEMON_DIR="$WORK/credsep/daemons" FLEET_CREDSEP_ROLE="$ME" \
       FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' \
       FLEET_CREDSEP_PW="$WORK/credsep/pw" FLEET_LOGIN_CREDSEP_WAIT=0
unset FLEET_CRED_SEPARATE FLEET_CRED_PROXY
mkdir -p "$WORK/credsep/daemons"
for l in victor victor2 pam dora eve fay gus hal ian jo kai kim lee lou max ned nohome oda oli pat pia quin uma vee wen lena 24haowan; do
  printf '%s:%s:%s:%s\n' "$l" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" "$FLEET_LOGIN_HOMES/$l"
done > "$FLEET_CREDSEP_PW"
# the admin's HOME (the password file lands there) + the daemons dir (#1192)
export HOME="$WORK/admin" FLEET_INSTALL_DAEMON_DIR="$WORK/LaunchDaemons" FLEET_INSTALL_BREW_PREFIX=/opt/homebrew
mkdir -p "$HOME" "$FLEET_INSTALL_DAEMON_DIR" "$CALLER"
# the fixture GitHub: the real launchd/ templates + fleet-install-apply.sh, at stable
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
FX="$WORK/fx"; mkdir -p "$FX/bin" "$FX/launchd"
cp "$BIN/fleet-install-apply.sh" "$BIN/fleet-daemon-lib.sh" "$FX/bin/"   # apply sources the lib beside it (#1495)
# 7b's verdict is read AS the login with its own clone's credsep (issue #2294)
cp "$BIN/fleet-credsep.sh" "$BIN/fleet-credsep.py" "$BIN/fleet-credsep-launch.py" "$BIN/fleet-cred-proxy.py" \
   "$BIN/fleet-cred-proxy.sh" "$FX/bin/"
# leg O (issue #2652): the login's own join + bring-up, as stubs that log what
# they were handed — the real ones are fleet-node-join / -bootstrap selftests'
cat > "$FX/bin/fleet-node-join.sh" <<'NJ'
#!/bin/bash
# stub: the pass must be ours to read, the token in it; node.env + runner, nothing started
printf '%s\n' "$*" >> "${FLEET_SELFTEST_NJ_LOG:-/dev/null}"
j=''; while [ $# -gt 0 ]; do [ "$1" = --joined ] && j=$2; shift; done
tok=$(sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' "$j") || exit 1
[ -n "$tok" ] || { echo "stub node-join: no token in $j"; exit 1; }
mkdir -p "$FLEET_CONF_DIR" "$HOME/.ccquota" && printf 'CCQUOTA_TOKEN=%s\n' "$tok" > "$FLEET_CONF_DIR/node.env" && chmod 600 "$FLEET_CONF_DIR/node.env"
printf '#!/bin/sh\n' > "$HOME/.ccquota/run-agent.sh"
echo "service: skipped (--service none)"
NJ
cat > "$FX/bin/fleet-login-bootstrap.sh" <<'BS'
#!/bin/bash
echo "as=$HOME conf=$FLEET_CONF_DIR" >> "${FLEET_SELFTEST_BS_LOG:-/dev/null}"
echo "fleet-login-bootstrap: fleet: ok — up on the starter repo"
exit "${FLEET_SELFTEST_BS_RC:-0}"
BS
chmod +x "$FX/bin/fleet-node-join.sh" "$FX/bin/fleet-login-bootstrap.sh"
cp "$BIN/../launchd/"com.claude-fleet.*.plist.tmpl "$FX/launchd/" 2>/dev/null
NTMPL=$(ls "$FX/launchd" | wc -l | tr -d ' ')
[ "$NTMPL" -gt 0 ] || fail "no launchd/*.plist.tmpl beside bin/ — the fixture needs the real templates"
git init -q -b master "$FX" && git -C "$FX" add -A && git -C "$FX" commit -qm stable && git -C "$FX" tag stable
GB="$WORK/gh"; mkdir -p "$GB/verkyyi"; git clone -q --bare "$FX" "$GB/verkyyi/claude-fleet.git"
export FLEET_BOOTSTRAP_GIT_BASE="$GB"
# no machine cache unless leg L builds one (issue #2297) — the operator's may be real
export FLEET_BOOTSTRAP_CACHE=off
# no plutil (Linux CI): the daemons step cannot render — run those legs with --no-daemons
DAEMONS=''; command -v plutil >/dev/null 2>&1 || DAEMONS=--no-daemons

# --- inputs -----------------------------------------------------------------
KEY="$WORK/victor.pub"; echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE victor@laptop' > "$KEY"
POOL="$WORK/pool"; mkdir -p "$POOL"
for l in alpha beta; do echo "tok-$l" > "$POOL/$l"; echo "CCQUOTA_ACCOUNT=$l" > "$POOL/$l.conf"; done
echo junk > "$POOL/.DS_Store"; echo old > "$POOL/alpha~"; mkdir "$POOL/subdir"
chmod 600 "$POOL"/*

# the lock (#1213): a home the script made must still be unreadable to us when
# it returns — the sudo shim relocked after its last call — and a bare read of
# a file inside it fails; the assertions below then need it open.
# LOCK_BITES=0: running as root, where mode 000 stops nothing (not a fleet box).
LOCK_BITES=1; mkdir -p "$WORK/probe/x"; chmod 000 "$WORK/probe"
ls "$WORK/probe" >/dev/null 2>&1 && LOCK_BITES=0
chmod 700 "$WORK/probe"
locked() { # $1 home: still mode 000 (0), or open / missing (1)
  [ -d "$1" ] && [ "$(mode "$1")" = 0 ]
}
unlock_homes() { for h in "$FLEET_LOGIN_HOMES"/*; do [ -d "$h" ] && chmod 700 "$h"; done; return 0; }
run() { : > "$LOG"; : > "$DLOG"; OUT=$("$BASH_BIN" "$S" "$@" 2>&1); RC=$?; CALLS=$(cat "$LOG"); }
mutations() { printf '%s\n' "$CALLS" | grep -v '^dscl ' | grep -c . ; }

# --- A. dry run -------------------------------------------------------------
run victor --full-name 'Victor V' --pubkey "$KEY" --share-pool --pool-src "$POOL"
eq "A dry run exit" 0 "$RC"
contains "A banner" "$OUT" "DRY RUN"
contains "A addUser" "$OUT" "sudo sysadminctl -addUser victor -fullName Victor\\ V -shell /usr/bin/false"
not_contains "A addUser has no password argv (#2396)" "$OUT" "-password"
contains "A password on dscl's stdin" "$OUT" "sudo dscl .   < passwd /Users/victor <redacted: $HOME/victor-onboard/password.txt>"
contains "A the shell back" "$OUT" "sudo dscl . -create /Users/victor UserShell /bin/zsh"
not_contains "A never prompts (#1192)" "$OUT" "-password -"
contains "A would write the password" "$OUT" "would write a random password to $HOME/victor-onboard/password.txt"
[ -e "$HOME/victor-onboard" ] && fail "A dry run wrote the password file"
contains "A home" "$OUT" 'sudo createhomedir -c -u victor'
contains "A home 700 right after (#2414)" "$OUT" "sudo createhomedir -c -u victor
  \$ sudo chmod 700 $FLEET_LOGIN_HOMES/victor
"
contains "A ssh group" "$OUT" 'sudo dseditgroup -o edit -a victor -t user com.apple.access_ssh'
contains "A key" "$OUT" "sudo tee -a $FLEET_LOGIN_HOMES/victor/.ssh/authorized_keys < $KEY"
contains "A key chmod" "$OUT" "sudo chmod 600 $FLEET_LOGIN_HOMES/victor/.ssh/authorized_keys"
# separated (the default, issue #2294): the pool goes into the store, never the login's dir
not_contains "A no pool cp into the login" "$OUT" "sudo cp -p $POOL/alpha"
contains "A pool into the store" "$OUT" "the tokens go into victor's credential store in step 7b"
contains "A conf switches" "$OUT" "sudo install -m 600 <fleet.conf: [common] export FLEET_CRED_PROXY=1, export FLEET_CRED_SEPARATE=1> $FLEET_LOGIN_HOMES/victor/.config/claude-fleet/fleet.conf"
contains "A credsep install" "$OUT" "sudo bash $BIN/fleet-credsep.sh install --login victor --fresh --install-dir $FLEET_LOGIN_HOMES/victor/.claude/fleet --pool-src $POOL"
if [ -z "$DAEMONS" ]; then case "$OUT" in *"--fresh"*"[8] install victor"*) ;; *) fail "A 7b is not before the daemons (8)" ;; esac; fi
# --no-credsep: the old layout, every token copied into the login
run victor --full-name 'Victor V' --pubkey "$KEY" --share-pool --pool-src "$POOL" --no-credsep
contains "A pool cp" "$OUT" "sudo cp -p $POOL/alpha $POOL/alpha.conf $POOL/beta $POOL/beta.conf $FLEET_LOGIN_HOMES/victor/.config/claude-fleet/accounts/"
contains "A pool chown" "$OUT" "sudo chown -R victor:staff $FLEET_LOGIN_HOMES/victor/.config/claude-fleet/accounts"
not_contains "A --no-credsep no 7b" "$OUT" "fleet-credsep.sh install"
contains "A --no-credsep says off" "$OUT" "credsep: off"
run victor --full-name 'Victor V' --pubkey "$KEY" --share-pool --pool-src "$POOL"
not_contains "A no dotfile" "$OUT" ".DS_Store"
not_contains "A no backup" "$OUT" "alpha~"
not_contains "A no GUI step (#1192)" "$OUT" "ONCE in the GUI"
contains "A manual codex" "$OUT" "1. as victor: ccquota codex login personal --device-auth"
contains "A manual gh" "$OUT" "2. as victor: gh auth login"
contains "A manual enroll" "$OUT" "3. on the hub: ccquota enroll --name mini-victor"
contains "A zshrc" "$OUT" "sudo chown victor:staff $FLEET_LOGIN_HOMES/victor/.zshrc"
contains "A installs itself" "$OUT" "claude-fleet + Claude Code install themselves"
contains "A clone as the login" "$OUT" "sudo -u victor -H git -c advice.detachedHead=false clone -q -b stable $GB/verkyyi/claude-fleet.git $FLEET_LOGIN_HOMES/victor/.claude/fleet"
contains "A daemons step" "$OUT" "[8] install victor's $NTMPL background services as system LaunchDaemons (com.claude-fleet.victor.*, UserName victor — no GUI sign-in needed)"
contains "A daemon install" "$OUT" "sudo install -m 644 <com.claude-fleet.victor.spinner.plist, rendered from launchd/com.claude-fleet.spinner.plist.tmpl> $FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.victor.spinner.plist"
contains "A daemon bootstrap" "$OUT" "sudo launchctl bootstrap system $FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.victor.spinner.plist"
contains "A password path at the end" "$OUT" "password: $HOME/victor-onboard/password.txt (mode 600"
contains "A finishes itself" "$OUT" "claude-fleet + Claude Code install themselves on victor's first SSH login"
eq "A nothing executed" 0 "$(mutations)"
eq "A nothing created" "" "$(ls "$FLEET_LOGIN_HOMES")"
eq "A no daemon written" "" "$(ls "$FLEET_INSTALL_DAEMON_DIR")"
# --no-daemons: step 8 gone, the GUI sign-in is back as a human step
run victor --full-name 'Victor V' --pubkey "$KEY" --no-daemons
eq "A --no-daemons exit" 0 "$RC"
not_contains "A --no-daemons no step 8" "$OUT" "system LaunchDaemons"
contains "A --no-daemons GUI step" "$OUT" "1. sign in as victor ONCE in the GUI"
contains "A --no-daemons codex is 2" "$OUT" "2. as victor: ccquota codex login"
contains "A --no-daemons installs itself" "$OUT" "claude-fleet + Claude Code install themselves on victor's first terminal login after step 1"

# --- B. apply ---------------------------------------------------------------
run victor --full-name 'Victor V' --pubkey "$KEY" --share-pool --pool-src "$POOL" --machine box --apply $DAEMONS
BOUT=$OUT
eq "B apply exit" 0 "$RC"
H="$FLEET_LOGIN_HOMES/victor"
# the home was never opened to the admin's own process (#1213): still 000, and a
# bare read of the clone inside it fails — the script got everything via sudo
locked "$H" || fail "B home is readable to the admin after the run (mode $(mode "$H")) — the sudo shim did not relock it"
if [ "$LOCK_BITES" = 1 ]; then
  ls "$H/.claude/fleet/launchd" >/dev/null 2>&1 && fail "B the admin can list the clone's launchd/ in a locked home — the lock model is broken"
fi
unlock_homes
ORDER=$(printf '%s\n' "$CALLS" | grep -Ev '^(sudo|dscl) ' | awk '{print $1}' | uniq | tr '\n' ' ')
eq "B call order" "sysadminctl createhomedir dseditgroup chown$([ -z "$DAEMONS" ] && echo " launchctl") " "$ORDER"
# B2. the password (#1192): generated into the admin's home, 600, on argv, never in the output
PWF="$HOME/victor-onboard/password.txt"
[ -f "$PWF" ] || fail "B2 no password file at $PWF"
PW=$(cat "$PWF")
eq "B2 password length" 24 "${#PW}"
eq "B2 password file mode" 600 "$(mode "$PWF")"
eq "B2 onboard dir mode" 700 "$(mode "$HOME/victor-onboard")"
# no argv any shim saw carries it (#2396) — addUser, dscl, sudo, chown, …
contains "B2 addUser shell-less, no password" "$CALLS" "sysadminctl -addUser victor -fullName Victor V -shell /usr/bin/false"
not_contains "B2 no argv carries it" "$CALLS" "$PW"
not_contains "B2 no -password argv at all" "$CALLS" "-password"
eq "B2 dscl stdin carries it" "passwd /Users/victor $PW" "$(cat "$DLOG")"
ORD2=$(printf '%s\n' "$CALLS" | grep -E '^(sysadminctl -addUser|dscl \.$|dscl \. -create /Users/victor UserShell /bin/zsh$|createhomedir)' | awk '{print $1 $2 $3}' | tr '\n' ' ')
eq "B2 addUser → passwd → shell → home" "sysadminctl-addUservictor dscl. dscl.-create createhomedir-c-u " "$ORD2"
not_contains "B2 never printed" "$OUT" "$PW"
contains "B2 redacted on screen" "$OUT" "<redacted: $PWF>"
contains "B2 path at the end" "$OUT" "password: $PWF (mode 600"
contains "B ssh group argv" "$CALLS" "dseditgroup -o edit -a victor -t user com.apple.access_ssh"
eq "B key content" "$(cat "$KEY")" "$(cat "$H/.ssh/authorized_keys")"
eq "B .ssh mode" 700 "$(mode "$H/.ssh")"
eq "B key mode" 600 "$(mode "$H/.ssh/authorized_keys")"
contains "B .ssh chown" "$CALLS" "chown -R victor:staff $H/.ssh"
D="$H/.config/claude-fleet/accounts"
eq "B pool set" "alpha alpha.conf beta beta.conf" "$(ls -A "$D" | tr '\n' ' ' | sed 's/ $//')"
eq "B pool: the login holds the marker" "store:beta" "$(cat "$D/beta")"
eq "B pool: the .conf travels" "CCQUOTA_ACCOUNT=beta" "$(cat "$D/beta.conf")"
eq "B pool: the token is in the store" "tok-beta" "$(cat "$FLEET_CREDSEP_ROOT_BASE/victor/accounts/beta" 2>/dev/null)"
eq "B pool: store token mode" 600 "$(mode "$FLEET_CREDSEP_ROOT_BASE/victor/accounts/beta")"
eq "B pool dir mode" 700 "$(mode "$D")"
for f in alpha alpha.conf beta beta.conf; do eq "B pool $f mode" 600 "$(mode "$D/$f")"; done
contains "B config chown" "$CALLS" "chown victor:staff $H/.config $H/.config/claude-fleet"
contains "B machine" "$OUT" "ccquota enroll --name box-victor"
eq "B only .claude + .config + .ssh + .zshrc written" ".claude .config .ssh .zshrc" "$(ls -A "$H" | tr '\n' ' ' | sed 's/ $//')"
# B3. the clone (#1192): at stable, as the login, logs/ ready for the daemons' StandardErrorPath
eq "B3 clone at stable" "$(git -C "$FX" rev-parse stable)" "$(git -C "$H/.claude/fleet" rev-parse HEAD 2>/dev/null)"
[ -d "$H/.claude/fleet/logs" ] || fail "B3 no logs/ in the clone"
eq "B3 only the clone under .claude" "fleet" "$(ls -A "$H/.claude" | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$DAEMONS" ]; then
  # B3. the daemons: every template, system shape, installed + bootstrapped
  eq "B3 $NTMPL plists installed" "$NTMPL" "$(ls "$FLEET_INSTALL_DAEMON_DIR"/com.claude-fleet.victor.*.plist | wc -l | tr -d ' ')"
  eq "B3 $NTMPL bootstraps" "$NTMPL" "$(grep -c '^launchctl bootstrap system ' "$LOG")"
  for f in "$FLEET_INSTALL_DAEMON_DIR"/com.claude-fleet.victor.*.plist; do
    u=${f##*/com.claude-fleet.victor.}; u=${u%.plist}
    eq "B3 $u Label" "com.claude-fleet.victor.$u" "$(plutil -extract Label raw -o - "$f")"
    eq "B3 $u UserName" victor "$(plutil -extract UserName raw -o - "$f")"
    eq "B3 $u mode" 644 "$(mode "$f")"
    contains "B3 $u runs the login's clone" "$(plutil -extract ProgramArguments.2 raw -o - "$f")" "$H/.claude/fleet/"
    ok_bs=$(grep -c "^launchctl bootstrap system $f$" "$LOG"); eq "B3 $u bootstrapped once" 1 "$ok_bs"
  done
  # #1213: the templates were listed + read AS THE LOGIN (the admin cannot read a
  # 700 home), rendered here, and the count printed matches what was installed
  contains "B3 templates listed as the login" "$OUT" "sudo -u victor -H ls -1 $H/.claude/fleet/launchd"
  contains "B3 read as the login" "$OUT" "read as victor"
  eq "B3 $NTMPL templates + the apply script + its fleet-daemon-lib.sh read as the login (#1495)" "$((NTMPL + 2))" "$(grep -c '^sudo cat$' "$LOG")"
  contains "B3 installed N/N" "$OUT" "installed $NTMPL/$NTMPL"
  not_contains "B3 never 'nothing to install'" "$OUT" "nothing to install"
  # the login's own first-login apply must find them current: same render, from its clone
  same=$(FLEET_INSTALL_LOGIN=victor FLEET_INSTALL_HOME="$H" bash "$H/.claude/fleet/bin/fleet-install-apply.sh" --render-system spinner --root "$H/.claude/fleet" | plutil -convert xml1 -o - -)
  eq "B3 render matches the bootstrap's" "$same" "$(plutil -convert xml1 -o - "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.victor.spinner.plist")"
  not_contains "B3 no GUI step" "$OUT" "ONCE in the GUI"
fi
# the first-login file (issues #1165, #1191): the ~/.local/bin PATH line, then the
# block — exactly what the bootstrap prints, in that order, owned by the login
BS="$BIN/fleet-login-bootstrap.sh"
eq "B zshrc = PATH line + bootstrap block" "$(bash "$BS" --print-path-line; bash "$BS" --print-zshrc)" "$(cat "$H/.zshrc")"
eq "B PATH line once" 1 "$(grep -c '\.local/bin' "$H/.zshrc")"
eq "B PATH line first, block second" "1 2" "$(grep -n -e '\.local/bin' -e '>>> claude-fleet' "$H/.zshrc" | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"
eq "B zshrc mode" 644 "$(mode "$H/.zshrc")"
contains "B zshrc chown" "$CALLS" "chown victor:staff $H/.zshrc"
# B2. --password-file: its first line, nothing generated
printf 'hunter2-from-file\nsecond line ignored\n' > "$WORK/pw.txt"
: > "$LOG"; : > "$DLOG"; OUT=$("$BASH_BIN" "$S" pam --full-name P --pubkey "$KEY" --password-file "$WORK/pw.txt" --apply --no-daemons 2>&1); RC=$?
CALLS=$(cat "$LOG"); unlock_homes
eq "B2 --password-file exit" 0 "$RC"
not_contains "B2 --password-file on no argv" "$CALLS" "hunter2-from-file"
eq "B2 --password-file on dscl's stdin" "passwd /Users/pam hunter2-from-file" "$(cat "$DLOG")"
not_contains "B2 --password-file never printed" "$OUT" "hunter2-from-file"
contains "B2 --password-file redacted" "$OUT" "<redacted: $WORK/pw.txt>"
[ -e "$HOME/pam-onboard/password.txt" ] && fail "B2 --password-file still generated one"
contains "B2 --password-file at the end" "$OUT" "password: the first line of $WORK/pw.txt (--password-file)"

# --- M. separated from the first moment (issue #2294, EPIC #2293 C1) ---------
# victor, opened in B: nothing a session of his could read holds a credential —
# no .credentials.json / auth.json / node.env, no pool token anywhere in his
# home; status is `separated`; and a session of his reaches the subscription
# through the proxy (the store's token on the way out).
unlock_homes
CD="$H/.config/claude-fleet"
eq "M no credential file in the home" "" "$(cd "$H" && find . \( -name .credentials.json -o -name auth.json -o -name node.env \) -print)"
eq "M no pool token in the home" "" "$(grep -rl 'tok-alpha\|tok-beta' "$H" 2>/dev/null)"
contains "M fleet.conf: the proxy" "$(cat "$CD/fleet.conf")" "export FLEET_CRED_PROXY=1"
contains "M fleet.conf: separated" "$(cat "$CD/fleet.conf")" "export FLEET_CRED_SEPARATE=1"
eq "M fleet.conf mode" 600 "$(mode "$CD/fleet.conf")"
contains "M nothing to move: a fresh login" "$BOUT" "credentials: 0 moved"
contains "M pool into the store" "$BOUT" "pool: 2 account(s) from $POOL"
st=$(FLEET_CONF_DIR="$CD" bash "$H/.claude/fleet/bin/fleet-credsep.sh" status 2>&1)
contains "M status separated (as the login, its own clone)" "$st" "separated · $FLEET_CREDSEP_ROOT_BASE/victor"
contains "M the hub reads the verdict last" "$(printf '%s\n' "$BOUT" | tail -n 1)" "credsep: pending"
# the login's account judge reads a pool label as usable (the picker names it,
# and the proxy then mints for it) — a `hub:` marker with no lease file would not
eq "M the account judge: beta usable" "beta	valid" "$(FLEET_CONF_DIR="$CD" FLEET_STATE_DIR="$WORK/acct-state" python3 "$BIN/.fleet-account.py" claude-login beta 2>&1)"
# the proxy, as launchd would start it (root's code copy), against a fake far end
cat > "$WORK/fake.py" <<'PY2'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
W = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        with open(W + "/fake.log", "a") as f:
            f.write("%s %s auth=%s\n" % (self.command, self.path, self.headers.get("authorization", "")))
        b = json.dumps({"ok": True}).encode()
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = any
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(W + "/fake.port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY2
python3 "$WORK/fake.py" "$WORK" & FPID=$!
for _ in $(seq 1 300); do [ -s "$WORK/fake.port" ] && break; sleep 0.1; done
FP=$(cat "$WORK/fake.port" 2>/dev/null)
# the upstream comes from root's settings only (issue #2290), which install wrote
[ -f "$FLEET_CREDSEP_LIB/victor.conf" ] || fail "M install wrote no root settings $FLEET_CREDSEP_LIB/victor.conf"
printf 'FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:%s\n' "$FP" >> "$FLEET_CREDSEP_LIB/victor.conf"
HOME="$WORK/admin" python3 -I "$FLEET_CREDSEP_LIB/fleet-credsep-launch.py" proxy victor 2>"$WORK/launch.err" & LPID=$!
for _ in $(seq 1 300); do [ -s "$FLEET_CREDSEP_RUN_BASE/victor/port" ] && [ -S "$FLEET_CREDSEP_RUN_BASE/victor/ctl.sock" ] && break; sleep 0.1; done
PORT=$(cat "$FLEET_CREDSEP_RUN_BASE/victor/port" 2>/dev/null)
[ -n "$PORT" ] || fail "M the proxy did not start: $(cat "$WORK/launch.err" | tr "\n" " ")"
tok=$(FLEET_CONF_DIR="$CD" bash "$H/.claude/fleet/bin/fleet-cred-proxy.sh" mint --account beta --sid s1 2>&1)
case "$tok" in fcp1.*) ;; *) fail "M mint: $tok" ;; esac
code=$(curl -s --max-time 60 -o "$WORK/l.body" -w '%{http_code}' -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/v1/messages")
eq "M a session's request is answered through the proxy" 200 "$code"
contains "M ... carrying the store's token, which the login never held" "$(cat "$WORK/fake.log" 2>/dev/null)" "POST /v1/messages auth=Bearer tok-beta"
kill "$LPID" "$FPID" 2>/dev/null; wait "$LPID" "$FPID" 2>/dev/null; LPID='' FPID=''
# a pool token put back at the login's path is a leak the doctor names (the
# store made unreadable the way the role account's 0700 makes it — here the
# role account is us)
R="$FLEET_CREDSEP_ROOT_BASE/victor"
cp "$R/accounts/beta" "$CD/accounts/beta.tmp" && mv "$CD/accounts/beta.tmp" "$CD/accounts/beta"
chmod 000 "$R"
ck=$(FLEET_CONF_DIR="$CD" bash "$H/.claude/fleet/bin/fleet-credsep.sh" check 2>&1)
chmod 700 "$R"
contains "M check WARNs on a pool token back at the login's path" "$ck" "credentials are back at login paths: $CD/accounts/beta"
printf 'store:beta\n' > "$CD/accounts/beta"
# --no-credsep: the old layout, and the hub reads `credsep: off`
: > "$LOG"; OUT=$("$BASH_BIN" "$S" uma --full-name N --pubkey "$KEY" --share-pool --pool-src "$POOL" --no-credsep --apply --no-daemons 2>&1); RC=$?
unlock_homes
eq "M --no-credsep exit" 0 "$RC"
eq "M --no-credsep: the token in the login (the old way)" "tok-beta" "$(cat "$FLEET_LOGIN_HOMES/uma/.config/claude-fleet/accounts/beta" 2>/dev/null)"
[ -e "$FLEET_CREDSEP_ROOT_BASE/uma" ] && fail "M --no-credsep made a store"
contains "M --no-credsep last line" "$(printf '%s\n' "$OUT" | tail -n 1)" "credsep: off"
# 7b refused (a login that is not fresh, a store that cannot be made) → the run fails, never hands it out
: > "$LOG"; OUT=$(FLEET_CREDSEP_ROOT_BASE=/dev/null/nope "$BASH_BIN" "$S" vee --full-name V --pubkey "$KEY" --apply --no-daemons 2>&1); RC=$?
unlock_homes
eq "M 7b failing → exit 1" 1 "$RC"
contains "M 7b failing stops at it" "$OUT" "FAILED at step"
not_contains "M 7b failing: never 'separated'" "$OUT" "credsep: separated"

# --- C. already exists -------------------------------------------------------
run victor --full-name V --pubkey "$KEY"
eq "C home exists → 3" 3 "$RC"
eq "C home exists nothing run" 0 "$(mutations)"
for m in "" --apply; do
  : > "$LOG"; OUT=$(FAKE_EXISTING='root victor2' "$BASH_BIN" "$S" victor2 --full-name V --pubkey "$KEY" $m 2>&1); RC=$?
  CALLS=$(cat "$LOG"); unlock_homes
  eq "C login exists → 3 ($m)" 3 "$RC"
  contains "C says exists ($m)" "$OUT" "already exists"
  eq "C nothing run ($m)" 0 "$(mutations)"
done
[ -e "$FLEET_LOGIN_HOMES/victor2" ] && fail "C created a home for an existing login"

# --- D. no ssh access group --------------------------------------------------
: > "$LOG"; OUT=$(FAKE_SSH_GROUP=0 "$BASH_BIN" "$S" dora --full-name D --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?
CALLS=$(cat "$LOG"); unlock_homes
eq "D exit" 0 "$RC"
contains "D skipped" "$OUT" "skipped: no com.apple.access_ssh"
not_contains "D no dseditgroup" "$CALLS" "dseditgroup"
eq "D key mode" 600 "$(mode "$FLEET_LOGIN_HOMES/dora/.ssh/authorized_keys")"
[ -e "$FLEET_LOGIN_HOMES/dora/.config/claude-fleet/accounts" ] && fail "D wrote accounts/ without --share-pool"

# --- E. usage ---------------------------------------------------------------
: > "$WORK/empty.pub"
printf 'two words\n' > "$WORK/pw-space.txt"; printf 'qu"ote\n' > "$WORK/pw-quote.txt"; printf 'back\\slash\n' > "$WORK/pw-bslash.txt"
mkdir -p "$WORK/nopool"
for args in "Bad!Name --full-name X --pubkey $KEY" \
            "2468 --full-name X --pubkey $KEY" \
            "eve --pubkey $KEY" \
            "eve --full-name X --pubkey $WORK/missing.pub" \
            "eve --full-name X --pubkey $WORK/empty.pub --apply" \
            "eve --full-name X --pubkey $KEY --share-pool --pool-src $WORK/nopool" \
            "eve --full-name X --pubkey $KEY --share-pool --pool-src $WORK/absent" \
            "eve --full-name X --pubkey $KEY --bogus" \
            "eve --full-name X --pubkey $KEY --password-file $WORK/missing.txt" \
            "eve --full-name X --pubkey $KEY --password-file $WORK/empty.pub" \
            "eve --full-name X --pubkey $KEY --password-file $WORK/pw-space.txt --apply" \
            "eve --full-name X --pubkey $KEY --password-file $WORK/pw-quote.txt --apply" \
            "eve --full-name X --pubkey $KEY --password-file $WORK/pw-bslash.txt --apply" \
            "eve eve2 --full-name X --pubkey $KEY" \
            ""; do
  # shellcheck disable=SC2086  # deliberate word-split of the case's argv
  run $args
  eq "E exit 2 [$args]" 2 "$RC"
  eq "E nothing run [$args]" 0 "$(mutations)"
  not_contains "E bash32 [$args]" "$OUT" "unbound variable"
done
[ -e "$FLEET_LOGIN_HOMES/eve" ] && fail "E created a home on a usage error"
# a digit-leading login is a login (macOS allows it — issue #2105, `24haowan`)
run 24haowan --full-name X --pubkey "$KEY"
eq "E digit-leading dry run exit" 0 "$RC"
contains "E digit-leading addUser" "$OUT" "sysadminctl -addUser 24haowan"
# an empty key is fine for a PREVIEW (the evidence run uses /dev/null) — it warns
run eve --full-name X --pubkey /dev/null
eq "E empty key dry run exit" 0 "$RC"
contains "E empty key warns" "$OUT" "WARN"

# --- F. a failing step stops the run ------------------------------------------
: > "$LOG"; OUT=$(FAKE_FAIL=dseditgroup "$BASH_BIN" "$S" fay --full-name F --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?
unlock_homes
eq "F exit 1" 1 "$RC"
contains "F says where" "$OUT" "FAILED at step 3"
[ -e "$FLEET_LOGIN_HOMES/fay/.ssh" ] && fail "F kept going after a failed step"

# --- G. bash 3.2 --------------------------------------------------------------
not_contains "G bash32 failed step" "$OUT" "unbound variable"
run gus --full-name G --pubkey "$KEY"
not_contains "G bash32 no pool" "$OUT" "unbound variable"
eq "G no pool exit" 0 "$RC"

# --- H. a cwd the login cannot read (issue #1216) ------------------------------
# docs/SHARED-MACHINE.md's example, typed where the admin actually is: inside
# their own 0700 home, with a relative `--pubkey alice.pub`. Every `sudo -u`
# inherits that cwd, and step 7's clone died on getcwd (#1210 ④, the same
# family as sync-logins' #1162). The script runs them from / — and resolves
# every relative path argument first, so they are still found.
cp "$KEY" "$CALLER/hal.pub"; mkdir -p "$CALLER/pool"; cp -p "$POOL"/alpha "$POOL"/alpha.conf "$POOL"/beta "$POOL"/beta.conf "$CALLER/pool/"; printf 'pw-from-cwd\n' > "$CALLER/pw.txt"
( cd "$CALLER" && "$WORK/shim/sudo" -u hal -H git --version >/dev/null 2>&1 ) && fail "H the shim does not refuse a -u run from the closed cwd"
( cd "$CALLER" && "$WORK/shim/sudo" tee /dev/null </dev/null >/dev/null 2>&1 ) || fail "H the shim refuses a root (no -u) run from the closed cwd"
hrun() { : > "$LOG"; : > "$DLOG"; OUT=$(cd "$CALLER" && "$BASH_BIN" "$S" "$@" 2>&1); RC=$?; CALLS=$(cat "$LOG"); unlock_homes; }
hrun hal --full-name 'Hal H' --pubkey hal.pub --share-pool --pool-src ./pool --password-file pw.txt --apply $DAEMONS
eq "H apply from the closed cwd: exit 0" 0 "$RC"
not_contains "H no getcwd death" "$OUT" "Unable to read current working directory"
not_contains "H no failed step" "$OUT" "FAILED at step"
HH="$FLEET_LOGIN_HOMES/hal"
contains "H the clone ran as the login" "$CALLS" "sudo git"
eq "H clone at stable" "$(git -C "$FX" rev-parse stable)" "$(git -C "$HH/.claude/fleet" rev-parse HEAD 2>/dev/null)"
eq "H relative --pubkey found" "$(cat "$KEY")" "$(cat "$HH/.ssh/authorized_keys")"
eq "H relative --pool-src found" "alpha alpha.conf beta beta.conf" "$(ls -A "$HH/.config/claude-fleet/accounts" | tr '\n' ' ' | sed 's/ $//')"
eq "H relative --password-file found" "passwd /Users/hal pw-from-cwd" "$(cat "$DLOG")"
contains "H transcript: key path absolute" "$OUT" "sudo tee -a $HH/.ssh/authorized_keys < $CALLER/hal.pub"
contains "H transcript: pool path absolute" "$OUT" "--pool-src $CALLER/pool"
contains "H transcript: password path absolute" "$OUT" "<redacted: $CALLER/pw.txt>"
[ -e "$HOME/hal-onboard/password.txt" ] && fail "H --password-file still generated one"
# a dry run from there: the same absolute paths on screen, nothing executed
hrun ian --full-name I --pubkey hal.pub --share-pool --pool-src pool
eq "H dry run exit" 0 "$RC"
contains "H dry run: key path absolute" "$OUT" "sudo tee -a $FLEET_LOGIN_HOMES/ian/.ssh/authorized_keys < $CALLER/hal.pub"
contains "H dry run: pool path absolute" "$OUT" "--pool-src $CALLER/pool"
eq "H dry run nothing executed" 0 "$(mutations)"
[ -e "$FLEET_LOGIN_HOMES/ian" ] && fail "H dry run created a home"
# a relative path that does not exist is still the usual exit 2, from there too
hrun jo --full-name J --pubkey nope.pub
eq "H missing relative key → 2" 2 "$RC"
not_contains "H bash32" "$OUT" "unbound variable"
# --- I. 0 templates (#1213) -----------------------------------------------------
# a stable whose clone carries no launchd/*.plist.tmpl: --apply FAILS at step 8,
# names the dir it read (as the login) — never "nothing to install" + exit 0
FX2="$WORK/fx2"; mkdir -p "$FX2/bin"; cp "$BIN/fleet-install-apply.sh" "$BIN/fleet-daemon-lib.sh" "$FX2/bin/"
git init -q -b master "$FX2" && git -C "$FX2" add -A && git -C "$FX2" commit -qm stable && git -C "$FX2" tag stable
GB2="$WORK/gh2"; mkdir -p "$GB2/verkyyi"; git clone -q --bare "$FX2" "$GB2/verkyyi/claude-fleet.git"
if [ -z "$DAEMONS" ]; then
  : > "$LOG"; OUT=$(FLEET_BOOTSTRAP_GIT_BASE="$GB2" "$BASH_BIN" "$S" kim --full-name K --pubkey "$KEY" --share-pool --pool-src "$POOL" --apply 2>&1); RC=$?
  CALLS=$(cat "$LOG"); unlock_homes
  eq "I 0 templates → exit 1" 1 "$RC"
  contains "I fails at step 8" "$OUT" "FAILED at step 8"
  contains "I names the dir + who read it" "$OUT" "no launchd/com.claude-fleet.*.plist.tmpl in $FLEET_LOGIN_HOMES/kim/.claude/fleet/launchd (read as kim)"
  contains "I says 0" "$OUT" "0 background services"
  not_contains "I never 'nothing to install'" "$OUT" "nothing to install"
  for f in "$FLEET_INSTALL_DAEMON_DIR"/com.claude-fleet.kim.*; do [ -e "$f" ] && fail "I installed $f with 0 templates"; done
  not_contains "I nothing bootstrapped" "$CALLS" "launchctl bootstrap"
  eq "I clone happened first" "$(git -C "$FX2" rev-parse stable)" "$(git -C "$FLEET_LOGIN_HOMES/kim/.claude/fleet" rev-parse HEAD 2>/dev/null)"
fi
# a dry run has no clone: it previews from THIS install's launchd/ — none there
# is a WARN, not a failure (--apply reads the clone's)
NL="$WORK/nolaunchd/bin"; mkdir -p "$NL"; ln -s "$BIN"/* "$NL/"
: > "$LOG"; OUT=$("$BASH_BIN" "$NL/fleet-login-new.sh" lou --full-name L --pubkey "$KEY" 2>&1); RC=$?
CALLS=$(cat "$LOG")
eq "I dry run without launchd/ exits 0" 0 "$RC"
contains "I dry run warns" "$OUT" "WARN: no launchd/*.plist.tmpl in $NL/../launchd"
contains "I dry run says 0" "$OUT" "[7] install lou's 0 background services"
not_contains "I dry run never 'nothing to install'" "$OUT" "nothing to install"
eq "I dry run nothing executed" 0 "$(mutations)"
[ -e "$FLEET_LOGIN_HOMES/lou" ] && fail "I dry run created a home"

# --- J. the welcome letter + the temporary key (issue #1195) --------------------
# No --pubkey: a temporary ed25519 pair in the ADMIN's onboard dir (700), its
# public half installed as the login's authorized_keys, its private half INSIDE
# ~/<login>-onboard/welcome.txt (600) — with the ssh line + config snippet from
# FLEET_SSH_PUBLIC_HOST/PORT, the swap-the-key steps, the guide + fleet (no cf, #1711), the human
# steps; NEVER the password, and the private key never on the terminal.
if command -v ssh-keygen >/dev/null 2>&1; then
  : > "$LOG"; OUT=$(FLEET_SSH_PUBLIC_HOST=ssh.example.test FLEET_SSH_PUBLIC_PORT=22022 "$BASH_BIN" "$S" wen --full-name 'Wen W' --machine box --apply --no-daemons 2>&1); RC=$?
  CALLS=$(cat "$LOG"); unlock_homes
  eq "J apply with no --pubkey: exit 0" 0 "$RC"
  not_contains "J no failed step" "$OUT" "FAILED at step"
  not_contains "J bash32" "$OUT" "unbound variable"
  OB="$HOME/wen-onboard"; KF="$OB/id_ed25519"; WF="$OB/welcome.txt"; KH="$FLEET_LOGIN_HOMES/wen"
  [ -f "$KF" ] && [ -f "$KF.pub" ] || fail "J no temporary key pair at $KF"
  eq "J onboard dir mode" 700 "$(mode "$OB")"
  eq "J private key mode" 600 "$(mode "$KF")"
  eq "J welcome mode" 600 "$(mode "$WF")"
  eq "J password file beside it" 600 "$(mode "$OB/password.txt")"
  eq "J the onboard dir holds exactly the four" "id_ed25519 id_ed25519.pub password.txt welcome.txt" "$(ls -A "$OB" | tr '\n' ' ' | sed 's/ $//')"
  eq "J the pub half is the installed key" "$(cat "$KF.pub")" "$(cat "$KH/.ssh/authorized_keys")"
  eq "J key mode" 600 "$(mode "$KH/.ssh/authorized_keys")"
  contains "J key comment (greppable for the swap)" "$(cat "$KF.pub")" " wen-onboard-temp"
  eq "J private key parses back to the public line" "$(ssh-keygen -y -f "$KF" | cut -d' ' -f1,2)" "$(cut -d' ' -f1,2 "$KF.pub")"
  eq "J only .claude + .config (7b: fleet.conf + credsep.json) + .ssh + .zshrc in the login's home" ".claude .config .ssh .zshrc" "$(ls -A "$KH" | tr '\n' ' ' | sed 's/ $//')"
  contains "J transcript: the temp pub is what tee'd" "$OUT" "sudo tee -a $KH/.ssh/authorized_keys < $KF.pub"
  contains "J transcript: key=temporary" "$OUT" "key=temporary (generated)  welcome=zh"
  contains "J transcript: step 9" "$OUT" "write the welcome letter (zh) → $WF (mode 600"
  contains "J transcript: the letter at the end" "$OUT" "welcome letter: $WF (mode 600, yours only)"
  PRIV=$(cat "$KF")
  not_contains "J private key never on the terminal" "$OUT" "PRIVATE KEY"
  not_contains "J private key body never on the terminal" "$OUT" "$(printf '%s\n' "$PRIV" | sed -n 2p)"
  W=$(cat "$WF")
  contains "J letter: ssh line = host + port" "$W" "ssh -p 22022 wen@ssh.example.test"
  contains "J letter: the private key, verbatim" "$W" "$PRIV"
  contains "J letter: the public line" "$W" "$(cat "$KF.pub")"
  contains "J letter: where to save the key" "$W" "chmod 600 ~/.ssh/box-wen"
  contains "J letter: config Host" "$W" "Host box"
  contains "J letter: config HostName" "$W" "HostName ssh.example.test"
  contains "J letter: config Port" "$W" "Port 22022"
  contains "J letter: config User" "$W" "User wen"
  contains "J letter: config IdentityFile" "$W" "IdentityFile ~/.ssh/box-wen"
  contains "J letter: swap — ssh-copy-id the new key over the temp one" "$W" "ssh-copy-id -i ~/.ssh/box-wen-own.pub -o IdentityFile=~/.ssh/box-wen -p 22022 wen@ssh.example.test"
  contains "J letter: swap — drop the temp line" "$W" "grep -v ' wen-onboard-temp\$' ~/.ssh/authorized_keys"
  contains "J letter: guide" "$W" "fleet guide"
  contains "J letter: ssh opens the client (#1711)" "$W" "ssh box 后自动打开 fleet"
  # no `cf` word anywhere outside the key material (base64 can spell one)
  not_contains "J letter: no cf left (#1711)" "$(printf '%s\n' "$W" | sed '/BEGIN/,/END/d' | grep -v 'ssh-ed25519\|ssh-rsa' | grep -w cf)" cf
  contains "J letter: codex step" "$W" "ccquota codex login personal --device-auth"
  contains "J letter: gh step" "$W" "gh auth login"
  contains "J letter: Chinese by default" "$W" "怎么连"
  contains "J letter: names the admin" "$W" "开号人 ${USER:-未知}"
  not_contains "J letter: no placeholder when configured" "$W" "<HOST>"
  PWK=$(cat "$OB/password.txt")
  not_contains "J letter: never the password" "$W" "$PWK"
  not_contains "J letter: never even the password path" "$W" "password.txt"
  # the swap step's grep really drops that line and only that line
  printf '%s\nssh-ed25519 AAAAOWN wen@own\n' "$(cat "$KF.pub")" > "$WORK/ak"
  eq "J swap grep keeps the own key only" "ssh-ed25519 AAAAOWN wen@own" "$(grep -v ' wen-onboard-temp$' "$WORK/ak")"
  # J2. --pubkey + --lang en: their own key, no private key block, English
  : > "$LOG"; OUT=$(FLEET_SSH_PUBLIC_HOST=ssh.example.test FLEET_SSH_PUBLIC_PORT=22022 "$BASH_BIN" "$S" lee --full-name 'Lee L' --pubkey "$KEY" --lang en --apply --no-daemons 2>&1); RC=$?
  unlock_homes
  eq "J2 --pubkey --lang en exit" 0 "$RC"
  [ -e "$HOME/lee-onboard/id_ed25519" ] && fail "J2 generated a temporary key although --pubkey was given"
  eq "J2 onboard dir: password + letter only" "password.txt welcome.txt" "$(ls -A "$HOME/lee-onboard" | tr '\n' ' ' | sed 's/ $//')"
  W=$(cat "$HOME/lee-onboard/welcome.txt")
  contains "J2 English" "$W" "How to connect"
  not_contains "J2 not Chinese" "$W" "怎么连"
  not_contains "J2 no private key" "$W" "PRIVATE KEY"
  contains "J2 their own public line" "$W" "$(cat "$KEY")"
  contains "J2 nothing to swap" "$W" "nothing to swap"
  not_contains "J2 no temp-line removal" "$W" "onboard-temp"
  contains "J2 ssh line" "$W" "ssh -p 22022 lee@ssh.example.test"
  contains "J2 IdentityFile is theirs to fill" "$W" "IdentityFile ~/.ssh/<your-private-key>"
  contains "J2 transcript: key=<file>" "$OUT" "key=$KEY  welcome=en"
  # J3. host unset: a visible placeholder in the letter + a WARN on the terminal; port 22
  : > "$LOG"; OUT=$(env -u FLEET_SSH_PUBLIC_HOST -u FLEET_SSH_PUBLIC_PORT "$BASH_BIN" "$S" max --full-name M --pubkey "$KEY" --apply --no-daemons 2>&1); RC=$?
  unlock_homes
  eq "J3 host unset: exit 0" 0 "$RC"
  contains "J3 WARN names the key" "$OUT" "WARN: FLEET_SSH_PUBLIC_HOST is unset"
  W=$(cat "$HOME/max-onboard/welcome.txt")
  contains "J3 placeholder + default port" "$W" "ssh -p 22 max@<HOST>"
  contains "J3 tells the reader whom to ask" "$W" "开号人还没配"
  # J4. the keys come from the login's fleet.settings (the one resolution path, #561)
  mkdir -p "$HOME/.config/claude-fleet"
  printf 'FLEET_SSH_PUBLIC_HOST=mini.example.test\nFLEET_SSH_PUBLIC_PORT=2222\n' > "$HOME/.config/claude-fleet/fleet.settings"
  : > "$LOG"; OUT=$(env -u FLEET_SKIP_GLOBAL_CONF -u FLEET_SSH_PUBLIC_HOST -u FLEET_SSH_PUBLIC_PORT FLEET_CONF_DIR="$HOME/.config/claude-fleet" "$BASH_BIN" "$S" ned --full-name N --pubkey "$KEY" --apply --no-daemons 2>&1); RC=$?
  unlock_homes; rm -f "$HOME/.config/claude-fleet/fleet.settings"
  eq "J4 from fleet.settings: exit 0" 0 "$RC"
  not_contains "J4 no WARN" "$OUT" "WARN: FLEET_SSH_PUBLIC_HOST"
  contains "J4 letter reads fleet.settings" "$(cat "$HOME/ned-onboard/welcome.txt")" "ssh -p 2222 ned@mini.example.test"
  # a bad port is a usage error before anything runs
  : > "$LOG"; OUT=$(FLEET_SSH_PUBLIC_PORT=abc "$BASH_BIN" "$S" oda --full-name O --pubkey "$KEY" 2>&1); RC=$?; CALLS=$(cat "$LOG")
  eq "J4 bad port → 2" 2 "$RC"
  contains "J4 bad port named" "$OUT" "FLEET_SSH_PUBLIC_PORT: not a port number: 'abc'"
  eq "J4 bad port: nothing run" 0 "$(mutations)"
else
  echo "selftest: ssh-keygen not installed — SKIP leg J (temporary key + welcome letter)" >&2
fi
# J5. usage: --no-welcome needs --pubkey (nothing would carry a temp key); --lang is zh|en
run oli --full-name O --no-welcome
eq "J5 --no-welcome without --pubkey → 2" 2 "$RC"
contains "J5 says why" "$OUT" "--pubkey <file> is required with --no-welcome"
run oli --full-name O --pubkey "$KEY" --lang fr
eq "J5 --lang fr → 2" 2 "$RC"
contains "J5 --lang names the choices" "$OUT" "--lang: zh or en (got 'fr')"
eq "J5 nothing run" 0 "$(mutations)"
[ -e "$HOME/oli-onboard" ] && fail "J5 a usage error created the onboard dir"
# --no-welcome with a key: no step 9, no letter, everything else as before
: > "$LOG"; OUT=$("$BASH_BIN" "$S" pat --full-name P --pubkey "$KEY" --no-welcome --apply --no-daemons 2>&1); RC=$?
unlock_homes
eq "J5 --no-welcome --apply exit" 0 "$RC"
not_contains "J5 --no-welcome: no letter step" "$OUT" "welcome letter"
contains "J5 --no-welcome: banner" "$OUT" "welcome=no"
[ -e "$HOME/pat-onboard/welcome.txt" ] && fail "J5 --no-welcome still wrote the letter"
eq "J5 --no-welcome: password only" "password.txt" "$(ls -A "$HOME/pat-onboard" | tr '\n' ' ' | sed 's/ $//')"
# J6. a dry run without --pubkey plans the key + the letter and creates nothing
run quin --full-name Q
eq "J6 dry run exit" 0 "$RC"
contains "J6 plans the keygen" "$OUT" "would run: ssh-keygen -q -t ed25519 -N '' -C quin-onboard-temp -f $HOME/quin-onboard/id_ed25519"
contains "J6 plans the key install from the temp pub" "$OUT" "sudo tee -a $FLEET_LOGIN_HOMES/quin/.ssh/authorized_keys < $HOME/quin-onboard/id_ed25519.pub"
contains "J6 plans the letter" "$OUT" "would write it — a dry run writes nothing"
not_contains "J6 no empty-key warning for a planned key" "$OUT" "holds no public key line"
eq "J6 nothing executed" 0 "$(mutations)"
[ -e "$HOME/quin-onboard" ] && fail "J6 dry run created the onboard dir"
[ -e "$FLEET_LOGIN_HOMES/quin" ] && fail "J6 dry run created a home"
not_contains "J6 bash32" "$OUT" "unbound variable"
# --- K. --daemons-only (issue #1223) ------------------------------------------
# an existing login with its home + its own clone (first login already ran),
# but nothing under the daemons dir: step 8 alone, nothing else
KH="$FLEET_LOGIN_HOMES/kai"; mkdir -p "$KH/.claude"
git clone -q -b stable "$GB/verkyyi/claude-fleet.git" "$KH/.claude/fleet"
chmod 000 "$KH"
konly() { : > "$LOG"; OUT=$(FAKE_EXISTING='kai nohome' "$BASH_BIN" "$S" "$@" 2>&1); RC=$?; CALLS=$(cat "$LOG"); unlock_homes; }
steps_1to7() { printf '%s\n' "$CALLS" | grep -Ec '^(sysadminctl|createhomedir|dseditgroup|chown|sudo (tee|mkdir|cp|chmod|git|ssh-keygen))( |$)'; }
konly kai --daemons-only
eq "K dry run exit" 0 "$RC"
contains "K dry run banner" "$OUT" "DRY RUN"
contains "K step is 8" "$OUT" "[8] install kai's $NTMPL background services as system LaunchDaemons"
not_contains "K no step 1" "$OUT" "[1]"
not_contains "K no addUser" "$OUT" "sysadminctl"
not_contains "K no letter" "$OUT" "welcome letter"
eq "K dry run nothing executed" 0 "$(mutations)"
for f in "$FLEET_INSTALL_DAEMON_DIR"/com.claude-fleet.kai.*; do [ -e "$f" ] && fail "K dry run wrote $f"; done
if [ -z "$DAEMONS" ]; then
  konly kai --daemons-only --apply
  eq "K apply exit" 0 "$RC"
  eq "K $NTMPL installs" "$NTMPL" "$(grep -c '^sudo install$' "$LOG")"
  eq "K $NTMPL bootstraps" "$NTMPL" "$(grep -c '^launchctl bootstrap system ' "$LOG")"
  eq "K steps 1–7: zero calls" 0 "$(steps_1to7)"
  contains "K installed N/N" "$OUT" "installed $NTMPL/$NTMPL"
  contains "K read as the login" "$OUT" "sudo -u kai -H ls -1 $KH/.claude/fleet/launchd"
  eq "K $NTMPL plists" "$NTMPL" "$(ls "$FLEET_INSTALL_DAEMON_DIR"/com.claude-fleet.kai.*.plist | wc -l | tr -d ' ')"
  eq "K Label" com.claude-fleet.kai.spinner "$(plutil -extract Label raw -o - "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.kai.spinner.plist")"
  [ -e "$HOME/kai-onboard" ] && fail "K wrote an onboard dir"
  # again: everything already in place → left alone, nothing bootstrapped twice
  konly kai --daemons-only --apply
  eq "K rerun exit" 0 "$RC"
  eq "K rerun no bootstrap" 0 "$(grep -c '^launchctl ' "$LOG")"
  contains "K rerun installed N/N" "$OUT" "installed $NTMPL/$NTMPL ($NTMPL already in place)"
  # one unit missing → only that one
  rm -f "$FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.kai.spinner.plist"
  konly kai --daemons-only --apply
  eq "K fill one: exit" 0 "$RC"
  eq "K fill one: one bootstrap" "launchctl bootstrap system $FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.kai.spinner.plist" "$(grep '^launchctl ' "$LOG")"
  # a login with no clone yet: fails at step 8 naming what is missing
  LH="$FLEET_LOGIN_HOMES/nohome"; mkdir -p "$LH"; chmod 000 "$LH"
  konly nohome --daemons-only --apply
  eq "K no clone → 1" 1 "$RC"
  contains "K no clone says why" "$OUT" "--daemons-only needs nohome's own clone"
  eq "K no clone nothing bootstrapped" 0 "$(grep -c '^launchctl ' "$LOG")"
  rm -rf "$LH"
fi
# refusals: no such login, a login with no home → 4, nothing run
for m in "" --apply; do
  konly ghost --daemons-only $m
  eq "K no login → 4 ($m)" 4 "$RC"
  contains "K no login says so ($m)" "$OUT" "--daemons-only: no login ghost"
  eq "K no login nothing run ($m)" 0 "$(mutations)"
  konly nohome --daemons-only $m
  eq "K no home → 4 ($m)" 4 "$RC"
  contains "K no home says so ($m)" "$OUT" "has no home at $FLEET_LOGIN_HOMES/nohome"
  eq "K no home nothing run ($m)" 0 "$(mutations)"
done
# the options of other steps are refused, not silently dropped
for args in "kai --daemons-only --no-daemons" "kai --daemons-only --share-pool --pool-src $POOL" \
            "kai --daemons-only --pubkey $KEY" "kai --daemons-only --password-file $WORK/pw.txt"; do
  # shellcheck disable=SC2086
  konly $args
  eq "K usage → 2 ($args)" 2 "$RC"
  eq "K usage nothing run ($args)" 0 "$(mutations)"
done
not_contains "K bash32" "$OUT" "unbound variable"
# --- L. the machine's cache (#2297): no github.com for the clone -------------
CC="$WORK/cache"; mkdir -p "$WORK/l-bin"
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$WORK/l-bin/claude"; chmod +x "$WORK/l-bin/claude"
export FLEET_BOOTSTRAP_CACHE="$CC" FLEET_BOOTSTRAP_CACHE_SRC="$FX" FLEET_BOOTSTRAP_GIT_BASE="$WORK/abroad-unreachable"
PATH="$WORK/l-bin:$PATH" run lena --full-name 'Lena L' --pubkey "$KEY" --no-daemons
eq "L dry run exit" 0 "$RC"
contains "L dry: refresh" "$OUT" "sudo env FLEET_BOOTSTRAP_CACHE=$CC bash $BIN/fleet-bootstrap-cache.sh refresh --from $FX --claude $WORK/l-bin/claude"
contains "L dry: cached clone" "$OUT" "sudo -u lena -H git -c safe.directory=$CC/claude-fleet.git -c advice.detachedHead=false clone -q --no-local -b stable $CC/claude-fleet.git $FLEET_LOGIN_HOMES/lena/.claude/fleet"
contains "L dry: the fallback named" "$OUT" "nothing cached at $CC at --apply time"
[ -e "$CC" ] && fail "L dry run made the cache"
PATH="$WORK/l-bin:$PATH" run lena --full-name 'Lena L' --pubkey "$KEY" --no-daemons --apply
eq "L apply exit" 0 "$RC"
unlock_homes
LH="$FLEET_LOGIN_HOMES/lena"
eq "L clone at stable" "$(git -C "$FX" rev-parse stable)" "$(git -C "$LH/.claude/fleet" rev-parse HEAD 2>/dev/null)"
eq "L origin = GitHub" "$WORK/abroad-unreachable/verkyyi/claude-fleet.git" "$(git -C "$LH/.claude/fleet" remote get-url origin)"
eq "L claude cached" 9.9.9 "$(cat "$CC/claude/current")"
not_contains "L no fallback" "$OUT" "the cached clone failed"
not_contains "L bash32" "$OUT" "unbound variable"
export FLEET_BOOTSTRAP_CACHE=off FLEET_BOOTSTRAP_GIT_BASE="$GB"; unset FLEET_BOOTSTRAP_CACHE_SRC
# --- N. a full name already taken (issue #2210) --------------------------------
: > "$LOG"; OUT=$(FAKE_REALNAMES='verkyyi=verkyyi;root=System Administrator' "$BASH_BIN" "$S" pia --full-name verkyyi --pubkey "$KEY" $DAEMONS 2>&1); RC=$?; CALLS=$(cat "$LOG")
eq "N dry exit" 0 "$RC"
contains "N note" "$OUT" "full name verkyyi is already login verkyyi's — using verkyyi (pia)"
contains "N alt name" "$OUT" "-fullName verkyyi\\ \\(pia\\)"
: > "$LOG"; OUT=$(FAKE_REALNAMES='verkyyi=verkyyi;x=verkyyi (pia)' "$BASH_BIN" "$S" pia --full-name verkyyi --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?; CALLS=$(cat "$LOG")
eq "N both taken exit" 3 "$RC"
eq "N both taken: nothing run" 0 "$(mutations)"
: > "$LOG"; OUT=$(FAKE_NOCREATE=1 "$BASH_BIN" "$S" pia --full-name Pia --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?; CALLS=$(cat "$LOG")
unlock_homes
eq "N no login exit" 1 "$RC"
contains "N no login named" "$OUT" "sysadminctl did not create login pia"
contains "N stops at 1" "$OUT" "FAILED at step 1"
not_contains "N no home" "$CALLS" "createhomedir"

# --- B2. a DS error setting the password (issue #2396) --------------------------
# interactive dscl exits 0 on it: its words decide — FAILED at step 1, shell-less,
# never the password on screen, nothing after it run
: > "$LOG"; : > "$DLOG"; OUT=$(FAKE_DSCL_ERR=1 "$BASH_BIN" "$S" pia --full-name Pia --pubkey "$KEY" --password-file "$WORK/pw.txt" --apply $DAEMONS 2>&1); RC=$?; CALLS=$(cat "$LOG")
unlock_homes
eq "B2 DS error exit" 1 "$RC"
contains "B2 DS error named" "$OUT" "could not set the password of pia"
contains "B2 DS error stops at 1" "$OUT" "FAILED at step 1"
not_contains "B2 DS error: password never shown" "$OUT" "hunter2-from-file"
not_contains "B2 DS error: shell not given back" "$CALLS" "UserShell"
not_contains "B2 DS error: no home" "$CALLS" "createhomedir"
# --- O. a login the hub opens joins as its own node, its fleet up (issue #2652) ----
# The admin agent hands the create's join code in the environment: the script
# redeems it itself (the code in a file, never an argv), the login runs
# fleet-node-join.sh --joined as itself, the agent's LaunchDaemon definition is
# dropped for 7b, and fleet-login-bootstrap.sh runs as the login after step 8.
cat > "$WORK/hub.py" <<'PY3'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
W = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        open(W + "/hub.log", "a").write("%s %s %s\n" % (self.path, b.get("code"), b.get("os_user")))
        ok = b.get("code") == "fj_abcdefghijklmnopqrstuvwxyz"
        out = json.dumps({"token": "ntok-secret", "endpoint_id": "ep_1", "label": "m-oli"} if ok else {"error": "no"}).encode()
        self.send_response(200 if ok else 401); self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(W + "/hub.port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY3
python3 "$WORK/hub.py" "$WORK" & HPID=$!
for _ in $(seq 1 300); do [ -s "$WORK/hub.port" ] && break; sleep 0.1; done
HUBU="http://127.0.0.1:$(cat "$WORK/hub.port" 2>/dev/null)"
export FLEET_SELFTEST_NJ_LOG="$WORK/nj.log" FLEET_SELFTEST_BS_LOG="$WORK/bs.log"
JC=fj_abcdefghijklmnopqrstuvwxyz
: > "$LOG"; OUT=$(FLEET_LOGIN_JOIN_CODE=$JC FLEET_LOGIN_HUB=$HUBU "$BASH_BIN" "$S" oli --full-name Oli --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?; CALLS=$(cat "$LOG")
unlock_homes
OH="$FLEET_LOGIN_HOMES/oli"
eq "O exit" 0 "$RC"
contains "O the code redeemed for the login" "$(cat "$WORK/hub.log" 2>/dev/null)" "/v1/node/join $JC oli"
not_contains "O the code never on a shim's argv" "$CALLS" "$JC"
not_contains "O the code never in the output" "$OUT" "$JC"
not_contains "O the node token never in the output" "$OUT" "ntok-secret"
contains "O node-join as the login, --joined, nothing started" "$(cat "$WORK/nj.log" 2>/dev/null)" "--no-fleet --service none --compute 1"
[ -e "$OH/.fleet-join-pass.json" ] && fail "O the node pass was left in the home"
contains "O the agent's definition for 7b" "$(cat "$FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.oli.plist" 2>/dev/null)" "<string>$OH/.ccquota/run-agent.sh</string>"
contains "O ... runs as the login" "$(cat "$FLEET_INSTALL_DAEMON_DIR/com.ccquota.agent.oli.plist" 2>/dev/null)" "<key>UserName</key><string>oli</string>"
[ -L "$OH/.config/claude-fleet/node.env" ] || fail "O 7b did not move node.env into the store (still $(ls -l "$OH/.config/claude-fleet/node.env" 2>&1))"
eq "O 7b: the token in the store" "CCQUOTA_TOKEN=ntok-secret" "$(cat "$FLEET_CREDSEP_ROOT_BASE/oli/node.env" 2>/dev/null)"
contains "O the fleet brought up as the login, after 8 (its conf; the sudo shim keeps HOME)" "$(cat "$WORK/bs.log" 2>/dev/null)" "conf=$OH/.config/claude-fleet"
contains "O the hub's detail says so" "$(printf '%s\n' "$OUT" | tail -n 3)" "fleet: up"
contains "O ... and that it joined" "$(printf '%s\n' "$OUT" | tail -n 3)" "node: joined $HUBU"
contains "O credsep stays last" "$(printf '%s\n' "$OUT" | tail -n 1)" "credsep:"
# a code the hub refuses: the login still opens, the line says why
: > "$WORK/bs.log"; : > "$LOG"; OUT=$(FLEET_LOGIN_JOIN_CODE=fj_zzzzzzzzzzzzzzzzzzzzzzzzzz FLEET_LOGIN_HUB=$HUBU "$BASH_BIN" "$S" oda --full-name Oda --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?
unlock_homes
eq "O refused code: still opened" 0 "$RC"
contains "O refused code: named" "$OUT" "node: WARN — the hub did not take the join code (HTTP 401)"
# no join code: neither step, byte for byte as before
: > "$WORK/nj.log"; : > "$WORK/bs.log"; : > "$LOG"; OUT=$("$BASH_BIN" "$S" lou --full-name Lou --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?
unlock_homes
eq "O no code: exit" 0 "$RC"
eq "O no code: no node-join" "" "$(cat "$WORK/nj.log")"
eq "O no code: no bring-up" "" "$(cat "$WORK/bs.log")"
not_contains "O no code: no node line" "$OUT" "node:"
# a malformed code is refused before anything runs
: > "$LOG"; OUT=$(FLEET_LOGIN_JOIN_CODE='fj_x;rm' FLEET_LOGIN_HUB=$HUBU "$BASH_BIN" "$S" kai --full-name Kai --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?; CALLS=$(cat "$LOG")
eq "O malformed code: usage" 2 "$RC"
not_contains "O malformed code: nothing ran" "$CALLS" "addUser"
kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; HPID=''
echo "fleet-login-new-selftest PASS ($CHECKS checks, $("$BASH_BIN" -c 'echo $BASH_VERSION'))"
