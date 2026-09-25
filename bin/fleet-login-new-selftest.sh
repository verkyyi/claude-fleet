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
#                 the ADMIN's home, passed to sysadminctl as argv, never printed;
#                 --password-file <f> uses f's first line and writes nothing
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
#                 fleet.settings), the swap-the-key steps, cf --guide, the human
#                 steps — never the password, never the key on the terminal;
#                 --pubkey + --lang en → their own key's public line, no private
#                 block, English; host unset → `<HOST>` in the letter + a WARN;
#                 --no-welcome without --pubkey / a bad --lang / a bad port → 2;
#                 --no-welcome writes no letter; a dry run plans both, writes none
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
S="$BIN/fleet-login-new.sh"
[ -f "$S" ] || { printf 'selftest: %s not found\n' "$S" >&2; exit 2; }
BASH_BIN=/bin/bash; [ -x "$BASH_BIN" ] || BASH_BIN=bash

WORK="$(mktemp -d "${TMPDIR:-/tmp}/login-new-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM HUP

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
cat > "$WORK/shim/dscl" <<EOF
#!/bin/sh
echo "dscl \$*" >> "$LOG"
[ "\${FAKE_SSH_GROUP:-1}" = 1 ]
EOF
cat > "$WORK/shim/id" <<'EOF'
#!/bin/sh
for u in ${FAKE_EXISTING:-}; do [ "$1" = "$u" ] && { echo "uid=501($u)"; exit 0; }; done
exit 1
EOF
chmod +x "$WORK/shim/"*
export PATH="$WORK/shim:$PATH"
export FLEET_LOGIN_HOMES="$WORK/homes"
mkdir -p "$FLEET_LOGIN_HOMES"
# the admin's HOME (the password file lands there) + the daemons dir (#1192)
export HOME="$WORK/admin" FLEET_INSTALL_DAEMON_DIR="$WORK/LaunchDaemons" FLEET_INSTALL_BREW_PREFIX=/opt/homebrew
mkdir -p "$HOME" "$FLEET_INSTALL_DAEMON_DIR" "$CALLER"
# the fixture GitHub: the real launchd/ templates + fleet-install-apply.sh, at stable
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
FX="$WORK/fx"; mkdir -p "$FX/bin" "$FX/launchd"
cp "$BIN/fleet-install-apply.sh" "$FX/bin/"
cp "$BIN/../launchd/"com.claude-fleet.*.plist.tmpl "$FX/launchd/" 2>/dev/null
NTMPL=$(ls "$FX/launchd" | wc -l | tr -d ' ')
[ "$NTMPL" -gt 0 ] || fail "no launchd/*.plist.tmpl beside bin/ — the fixture needs the real templates"
git init -q -b master "$FX" && git -C "$FX" add -A && git -C "$FX" commit -qm stable && git -C "$FX" tag stable
GB="$WORK/gh"; mkdir -p "$GB/verkyyi"; git clone -q --bare "$FX" "$GB/verkyyi/claude-fleet.git"
export FLEET_BOOTSTRAP_GIT_BASE="$GB"
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
run() { : > "$LOG"; OUT=$("$BASH_BIN" "$S" "$@" 2>&1); RC=$?; CALLS=$(cat "$LOG"); }
mutations() { printf '%s\n' "$CALLS" | grep -v '^dscl ' | grep -c . ; }

# --- A. dry run -------------------------------------------------------------
run victor --full-name 'Victor V' --pubkey "$KEY" --share-pool --pool-src "$POOL"
eq "A dry run exit" 0 "$RC"
contains "A banner" "$OUT" "DRY RUN"
contains "A addUser" "$OUT" "sudo sysadminctl -addUser victor -fullName Victor\\ V -password <redacted: $HOME/victor-onboard/password.txt>"
not_contains "A never prompts (#1192)" "$OUT" "-password -"
contains "A would write the password" "$OUT" "would write a random password to $HOME/victor-onboard/password.txt"
[ -e "$HOME/victor-onboard" ] && fail "A dry run wrote the password file"
contains "A home" "$OUT" 'sudo createhomedir -c -u victor'
contains "A ssh group" "$OUT" 'sudo dseditgroup -o edit -a victor -t user com.apple.access_ssh'
contains "A key" "$OUT" "sudo tee -a $FLEET_LOGIN_HOMES/victor/.ssh/authorized_keys < $KEY"
contains "A key chmod" "$OUT" "sudo chmod 600 $FLEET_LOGIN_HOMES/victor/.ssh/authorized_keys"
contains "A pool cp" "$OUT" "sudo cp -p $POOL/alpha $POOL/alpha.conf $POOL/beta $POOL/beta.conf $FLEET_LOGIN_HOMES/victor/.config/claude-fleet/accounts/"
contains "A pool chown" "$OUT" "sudo chown -R victor:staff $FLEET_LOGIN_HOMES/victor/.config/claude-fleet/accounts"
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
contains "B2 addUser argv carries it" "$CALLS" "sysadminctl -addUser victor -fullName Victor V -password $PW"
not_contains "B2 never printed" "$OUT" "$PW"
contains "B2 redacted on screen" "$OUT" "-password <redacted: $PWF>"
contains "B2 path at the end" "$OUT" "password: $PWF (mode 600"
contains "B ssh group argv" "$CALLS" "dseditgroup -o edit -a victor -t user com.apple.access_ssh"
eq "B key content" "$(cat "$KEY")" "$(cat "$H/.ssh/authorized_keys")"
eq "B .ssh mode" 700 "$(mode "$H/.ssh")"
eq "B key mode" 600 "$(mode "$H/.ssh/authorized_keys")"
contains "B .ssh chown" "$CALLS" "chown -R victor:staff $H/.ssh"
D="$H/.config/claude-fleet/accounts"
eq "B pool set" "alpha alpha.conf beta beta.conf" "$(ls -A "$D" | tr '\n' ' ' | sed 's/ $//')"
eq "B pool token" "tok-beta" "$(cat "$D/beta")"
eq "B pool dir mode" 700 "$(mode "$D")"
for f in alpha alpha.conf beta beta.conf; do eq "B pool $f mode" 600 "$(mode "$D/$f")"; done
contains "B pool chown" "$CALLS" "chown -R victor:staff $D"
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
  eq "B3 $NTMPL templates + the apply script read as the login" "$((NTMPL + 1))" "$(grep -c '^sudo cat$' "$LOG")"
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
: > "$LOG"; OUT=$("$BASH_BIN" "$S" pam --full-name P --pubkey "$KEY" --password-file "$WORK/pw.txt" --apply --no-daemons 2>&1); RC=$?
CALLS=$(cat "$LOG"); unlock_homes
eq "B2 --password-file exit" 0 "$RC"
contains "B2 --password-file argv" "$CALLS" "sysadminctl -addUser pam -fullName P -password hunter2-from-file"
not_contains "B2 --password-file never printed" "$OUT" "hunter2-from-file"
contains "B2 --password-file redacted" "$OUT" "-password <redacted: $WORK/pw.txt>"
[ -e "$HOME/pam-onboard/password.txt" ] && fail "B2 --password-file still generated one"
contains "B2 --password-file at the end" "$OUT" "password: the first line of $WORK/pw.txt (--password-file)"

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
[ -e "$FLEET_LOGIN_HOMES/dora/.config" ] && fail "D wrote .config without --share-pool"

# --- E. usage ---------------------------------------------------------------
: > "$WORK/empty.pub"
mkdir -p "$WORK/nopool"
for args in "Bad!Name --full-name X --pubkey $KEY" \
            "eve --pubkey $KEY" \
            "eve --full-name X --pubkey $WORK/missing.pub" \
            "eve --full-name X --pubkey $WORK/empty.pub --apply" \
            "eve --full-name X --pubkey $KEY --share-pool --pool-src $WORK/nopool" \
            "eve --full-name X --pubkey $KEY --share-pool --pool-src $WORK/absent" \
            "eve --full-name X --pubkey $KEY --bogus" \
            "eve --full-name X --pubkey $KEY --password-file $WORK/missing.txt" \
            "eve --full-name X --pubkey $KEY --password-file $WORK/empty.pub" \
            "eve eve2 --full-name X --pubkey $KEY" \
            ""; do
  # shellcheck disable=SC2086  # deliberate word-split of the case's argv
  run $args
  eq "E exit 2 [$args]" 2 "$RC"
  eq "E nothing run [$args]" 0 "$(mutations)"
  not_contains "E bash32 [$args]" "$OUT" "unbound variable"
done
[ -e "$FLEET_LOGIN_HOMES/eve" ] && fail "E created a home on a usage error"
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
hrun() { : > "$LOG"; OUT=$(cd "$CALLER" && "$BASH_BIN" "$S" "$@" 2>&1); RC=$?; CALLS=$(cat "$LOG"); unlock_homes; }
hrun hal --full-name 'Hal H' --pubkey hal.pub --share-pool --pool-src ./pool --password-file pw.txt --apply $DAEMONS
eq "H apply from the closed cwd: exit 0" 0 "$RC"
not_contains "H no getcwd death" "$OUT" "Unable to read current working directory"
not_contains "H no failed step" "$OUT" "FAILED at step"
HH="$FLEET_LOGIN_HOMES/hal"
contains "H the clone ran as the login" "$CALLS" "sudo git"
eq "H clone at stable" "$(git -C "$FX" rev-parse stable)" "$(git -C "$HH/.claude/fleet" rev-parse HEAD 2>/dev/null)"
eq "H relative --pubkey found" "$(cat "$KEY")" "$(cat "$HH/.ssh/authorized_keys")"
eq "H relative --pool-src found" "alpha alpha.conf beta beta.conf" "$(ls -A "$HH/.config/claude-fleet/accounts" | tr '\n' ' ' | sed 's/ $//')"
contains "H relative --password-file found" "$CALLS" "sysadminctl -addUser hal -fullName Hal H -password pw-from-cwd"
contains "H transcript: key path absolute" "$OUT" "sudo tee -a $HH/.ssh/authorized_keys < $CALLER/hal.pub"
contains "H transcript: pool path absolute" "$OUT" "sudo cp -p $CALLER/pool/alpha $CALLER/pool/alpha.conf $CALLER/pool/beta $CALLER/pool/beta.conf $HH/.config/claude-fleet/accounts/"
contains "H transcript: password path absolute" "$OUT" "-password <redacted: $CALLER/pw.txt>"
[ -e "$HOME/hal-onboard/password.txt" ] && fail "H --password-file still generated one"
# a dry run from there: the same absolute paths on screen, nothing executed
hrun ian --full-name I --pubkey hal.pub --share-pool --pool-src pool
eq "H dry run exit" 0 "$RC"
contains "H dry run: key path absolute" "$OUT" "sudo tee -a $FLEET_LOGIN_HOMES/ian/.ssh/authorized_keys < $CALLER/hal.pub"
contains "H dry run: pool path absolute" "$OUT" "sudo cp -p $CALLER/pool/alpha "
eq "H dry run nothing executed" 0 "$(mutations)"
[ -e "$FLEET_LOGIN_HOMES/ian" ] && fail "H dry run created a home"
# a relative path that does not exist is still the usual exit 2, from there too
hrun jo --full-name J --pubkey nope.pub
eq "H missing relative key → 2" 2 "$RC"
not_contains "H bash32" "$OUT" "unbound variable"
# --- I. 0 templates (#1213) -----------------------------------------------------
# a stable whose clone carries no launchd/*.plist.tmpl: --apply FAILS at step 8,
# names the dir it read (as the login) — never "nothing to install" + exit 0
FX2="$WORK/fx2"; mkdir -p "$FX2/bin"; cp "$BIN/fleet-install-apply.sh" "$FX2/bin/"
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
# FLEET_SSH_PUBLIC_HOST/PORT, the swap-the-key steps, the guide + cf, the human
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
  eq "J only .claude + .ssh + .zshrc in the login's home" ".claude .ssh .zshrc" "$(ls -A "$KH" | tr '\n' ' ' | sed 's/ $//')"
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
  contains "J letter: guide" "$W" "cf --guide"
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
echo "fleet-login-new-selftest PASS ($CHECKS checks, $("$BASH_BIN" -c 'echo $BASH_VERSION'))"
