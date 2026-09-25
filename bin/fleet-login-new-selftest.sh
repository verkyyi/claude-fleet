#!/bin/bash
# fleet-login-new-selftest.sh — bin/fleet-login-new.sh against a fake homes root,
# fully hermetic (issue #1164): no real account, no real sudo. sudo, sysadminctl,
# createhomedir, dseditgroup, dscl, id, chown and launchctl are PATH shims that
# log what they were asked (sudo -u <login> -H runs the command as us, HOME
# untouched); mkdir / tee / cp / chmod / install / git run for real inside the
# sandbox, against a local fixture "GitHub" (FLEET_BOOTSTRAP_GIT_BASE) holding
# the real launchd/ templates + fleet-install-apply.sh, tagged stable.
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
#                 `launchctl bootstrap system`'d, 14 of them from the real repo;
#                 --no-daemons skips that step and prints the GUI sign-in step
#   C. exists     a known login → exit 3 in both modes, nothing run; an existing
#                 home dir alone → exit 3
#   D. no group   no com.apple.access_ssh → step skipped, dseditgroup never run
#   E. usage      bad name / no --full-name / unreadable key / --apply with an
#                 empty key / --share-pool with no pool → exit 2, nothing run
#   F. failure    a failing step under --apply stops there (exit 1)
#   G. bash 3.2   no `unbound variable` on any path (runs under /bin/bash, 3.2 on
#                 macOS), with and without --share-pool
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
S="$BIN/fleet-login-new.sh"
[ -f "$S" ] || { printf 'selftest: %s not found\n' "$S" >&2; exit 2; }
BASH_BIN=/bin/bash; [ -x "$BASH_BIN" ] || BASH_BIN=bash

WORK="$(mktemp -d "${TMPDIR:-/tmp}/login-new-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

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
cat > "$WORK/shim/sudo" <<EOF
#!/bin/sh
# sudo -u <login> -H <cmd…>: as "the login" = us (the sandbox home is ours)
if [ "\$1" = -u ]; then shift 2; [ "\$1" = -H ] && shift; fi
echo "sudo \$1" >> "$LOG"
exec "\$@"
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
mkdir -p "\$FLEET_LOGIN_HOMES/\$3"
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
mkdir -p "$HOME" "$FLEET_INSTALL_DAEMON_DIR"
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
CALLS=$(cat "$LOG")
eq "B2 --password-file exit" 0 "$RC"
contains "B2 --password-file argv" "$CALLS" "sysadminctl -addUser pam -fullName P -password hunter2-from-file"
not_contains "B2 --password-file never printed" "$OUT" "hunter2-from-file"
contains "B2 --password-file redacted" "$OUT" "-password <redacted: $WORK/pw.txt>"
[ -e "$HOME/pam-onboard" ] && fail "B2 --password-file still generated one"
contains "B2 --password-file at the end" "$OUT" "password: the first line of $WORK/pw.txt (--password-file)"

# --- C. already exists -------------------------------------------------------
run victor --full-name V --pubkey "$KEY"
eq "C home exists → 3" 3 "$RC"
eq "C home exists nothing run" 0 "$(mutations)"
for m in "" --apply; do
  : > "$LOG"; OUT=$(FAKE_EXISTING='root victor2' "$BASH_BIN" "$S" victor2 --full-name V --pubkey "$KEY" $m 2>&1); RC=$?
  CALLS=$(cat "$LOG")
  eq "C login exists → 3 ($m)" 3 "$RC"
  contains "C says exists ($m)" "$OUT" "already exists"
  eq "C nothing run ($m)" 0 "$(mutations)"
done
[ -e "$FLEET_LOGIN_HOMES/victor2" ] && fail "C created a home for an existing login"

# --- D. no ssh access group --------------------------------------------------
: > "$LOG"; OUT=$(FAKE_SSH_GROUP=0 "$BASH_BIN" "$S" dora --full-name D --pubkey "$KEY" --apply $DAEMONS 2>&1); RC=$?
CALLS=$(cat "$LOG")
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
eq "F exit 1" 1 "$RC"
contains "F says where" "$OUT" "FAILED at step 3"
[ -e "$FLEET_LOGIN_HOMES/fay/.ssh" ] && fail "F kept going after a failed step"

# --- G. bash 3.2 --------------------------------------------------------------
not_contains "G bash32 failed step" "$OUT" "unbound variable"
run gus --full-name G --pubkey "$KEY"
not_contains "G bash32 no pool" "$OUT" "unbound variable"
eq "G no pool exit" 0 "$RC"

echo "fleet-login-new-selftest PASS ($CHECKS checks, $("$BASH_BIN" -c 'echo $BASH_VERSION'))"
