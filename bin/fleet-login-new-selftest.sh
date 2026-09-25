#!/bin/bash
# fleet-login-new-selftest.sh — bin/fleet-login-new.sh against a fake homes root,
# fully hermetic (issue #1164): no real account, no real sudo. sudo, sysadminctl,
# createhomedir, dseditgroup, dscl, id and chown are PATH shims that log what they
# were asked; mkdir / tee / cp / chmod run for real inside the sandbox.
#
# What it pins:
#   A. dry run    lists every command (addUser, home, ssh group, key, pool), runs
#                 NONE of them, creates nothing, exit 0
#   B. --apply    call order addUser → createhomedir → dseditgroup → key → pool;
#                 .ssh 700 + authorized_keys 600 holding the key; chown to the
#                 login; the pool copy = exactly the source's tokens + .conf
#                 (no dotfiles, no editor backups), dir 700, files 600
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
echo "sudo \$1" >> "$LOG"
exec "\$@"
EOF
for t in sysadminctl dseditgroup chown; do
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
contains "A addUser" "$OUT" 'sudo sysadminctl -addUser victor -fullName Victor\ V -password -'
contains "A home" "$OUT" 'sudo createhomedir -c -u victor'
contains "A ssh group" "$OUT" 'sudo dseditgroup -o edit -a victor -t user com.apple.access_ssh'
contains "A key" "$OUT" "sudo tee -a $FLEET_LOGIN_HOMES/victor/.ssh/authorized_keys < $KEY"
contains "A key chmod" "$OUT" "sudo chmod 600 $FLEET_LOGIN_HOMES/victor/.ssh/authorized_keys"
contains "A pool cp" "$OUT" "sudo cp -p $POOL/alpha $POOL/alpha.conf $POOL/beta $POOL/beta.conf $FLEET_LOGIN_HOMES/victor/.config/claude-fleet/accounts/"
contains "A pool chown" "$OUT" "sudo chown -R victor:staff $FLEET_LOGIN_HOMES/victor/.config/claude-fleet/accounts"
not_contains "A no dotfile" "$OUT" ".DS_Store"
not_contains "A no backup" "$OUT" "alpha~"
contains "A manual gui" "$OUT" "GUI"
contains "A manual codex" "$OUT" "ccquota codex login personal --device-auth"
contains "A manual gh" "$OUT" "gh auth login"
contains "A manual enroll" "$OUT" "ccquota enroll --name mini-victor"
eq "A nothing executed" 0 "$(mutations)"
eq "A nothing created" "" "$(ls "$FLEET_LOGIN_HOMES")"

# --- B. apply ---------------------------------------------------------------
run victor --full-name 'Victor V' --pubkey "$KEY" --share-pool --pool-src "$POOL" --machine box --apply
eq "B apply exit" 0 "$RC"
H="$FLEET_LOGIN_HOMES/victor"
ORDER=$(printf '%s\n' "$CALLS" | grep -Ev '^(sudo|dscl) ' | awk '{print $1}' | uniq | tr '\n' ' ')
eq "B call order" "sysadminctl createhomedir dseditgroup chown " "$ORDER"
contains "B addUser argv" "$CALLS" "sysadminctl -addUser victor -fullName Victor V -password -"
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
eq "B only .ssh + .config written" ".config .ssh" "$(ls -A "$H" | tr '\n' ' ' | sed 's/ $//')"

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
: > "$LOG"; OUT=$(FAKE_SSH_GROUP=0 "$BASH_BIN" "$S" dora --full-name D --pubkey "$KEY" --apply 2>&1); RC=$?
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
: > "$LOG"; OUT=$(FAKE_FAIL=dseditgroup "$BASH_BIN" "$S" fay --full-name F --pubkey "$KEY" --apply 2>&1); RC=$?
eq "F exit 1" 1 "$RC"
contains "F says where" "$OUT" "FAILED at step 3"
[ -e "$FLEET_LOGIN_HOMES/fay/.ssh" ] && fail "F kept going after a failed step"

# --- G. bash 3.2 --------------------------------------------------------------
not_contains "G bash32 failed step" "$OUT" "unbound variable"
run gus --full-name G --pubkey "$KEY"
not_contains "G bash32 no pool" "$OUT" "unbound variable"
eq "G no pool exit" 0 "$RC"

echo "fleet-login-new-selftest PASS ($CHECKS checks, $("$BASH_BIN" -c 'echo $BASH_VERSION'))"
