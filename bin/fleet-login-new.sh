#!/bin/bash
# fleet-login-new.sh <login> --full-name <name> --pubkey <file> [--share-pool]
#                    [--pool-src <dir>] [--password-file <file>] [--no-daemons]
#                    [--machine <name>] [--apply]
#   — open a new person's OS login on a shared machine in ONE command
#     (issue #1164, EPIC #1163; no GUI sign-in needed since #1192, EPIC #1190).
#
# docs/SHARED-MACHINE.md steps 1–2b used to be ~7 hand-typed admin commands
# spread over two docs; a missed chown or group membership meant the person
# could not log in, or could not use the pool, and the admin had to go hunting.
# This script is those steps, in order:
#
#   1. sudo sysadminctl -addUser <login> -fullName <name> -password <pw>
#      <pw> is --password-file's first line, or (default) a random one this
#      script writes to ~/<login>-onboard/password.txt (mode 600, yours only) —
#      never a terminal prompt (`-password -` hung every remote/scripted run,
#      #1183 ①), and never printed: the person signs in with their key.
#   2. sudo createhomedir -c -u <login>          (the home, so step 4 has a place)
#   3. sudo dseditgroup … com.apple.access_ssh   (only when that group exists —
#                                     without it Remote Login admits every user)
#   4. ~/.ssh/authorized_keys ← --pubkey, .ssh 700 / key file 600, owned by <login>
#   5. --share-pool: every Claude pool token + its <label>.conf from --pool-src
#      (default: YOUR accounts dir) → ~<login>/.config/claude-fleet/accounts,
#      dir 700 / files 600, owned by <login> — SHARED-MACHINE step 2b. Never
#      ~/.codex/auth.json: Codex rotates its refresh token, so the new login gets
#      its own device-code session instead (printed as a manual step).
#   6. ~<login>/.zshrc ← the ~/.local/bin PATH line (Claude Code's native install
#      dir, issue #1191; skipped when the file has one) and, after it, the
#      claude-fleet block (fleet-login-bootstrap.sh --print-zshrc, issue #1165),
#      owned by <login>: its first interactive login clones claude-fleet at
#      `stable`, installs it and Claude Code, and brings its fleet up on the
#      starter repo — nobody installs anything by hand.
#   7. ~<login>/.claude/fleet ← claude-fleet cloned at `stable`, AS <login>
#      (sudo -u), so the daemons of step 8 have their scripts from the moment
#      they load, and the first-login bootstrap finds its install already there.
#   8. the login's background services, as an admin: every launchd/*.plist.tmpl
#      of that clone rendered in SYSTEM shape (fleet-install-apply.sh
#      --render-system: Label com.claude-fleet.<login>.<unit>, UserName <login>,
#      __HOME__ = its home) → /Library/LaunchDaemons + `launchctl bootstrap
#      system`. That is the shape every guest login on a shared mini runs
#      (EPIC #1190 convention 2); it needs no gui/<uid> domain, so nobody has to
#      sit at the console and sign in once (#1183 ②). The bootstrap then finds
#      each unit "already current" and passes as a non-admin. `--no-daemons`
#      skips this step for someone who WILL sign in at the GUI: their first
#      graphical login installs gui LaunchAgents the historic way.
#
# and then prints what only a human can do (the Codex device code, the person's
# own `gh auth login`, the ccquota enrollment) — and where the password went.
#
# DEFAULT IS A DRY RUN: it prints every command it would run and runs none.
# --apply runs them, stopping at the first failure. Run it as the admin login,
# NOT under sudo — it sudo's each step itself, and your $HOME is where the pool
# comes from (and where the password file lands).
#
# Only ever ADDS: it refuses (exit 3) when the login or its home already exists,
# never overwrites, and writes nothing in the new home outside `.ssh/`,
# `.config/claude-fleet/accounts/` (plus owning the `.config` dirs it creates),
# `.zshrc` and `.claude/fleet/`.
#
# Exit: 0 ok · 1 a step failed under --apply · 2 bad arguments · 3 the login
#       (or its home) already exists
#
# Env (tests): FLEET_LOGIN_HOMES (default /Users) — the homes root ·
#      FLEET_INSTALL_DAEMON_DIR (/Library/LaunchDaemons) · FLEET_BOOTSTRAP_GIT_BASE
#      (https://github.com) · FLEET_INSTALL_BREW_PREFIX (as fleet-install-apply.sh).
set -u

PROG=fleet-login-new
FLEET_REPO_SELF=verkyyi/claude-fleet
usage() {
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

LOGIN='' FULL='' PUBKEY='' SHARE=0 APPLY=0 MACHINE=mini POOL_SRC='' PWFILE='' DAEMONS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --full-name) [ $# -ge 2 ] || usage; FULL=$2; shift 2 ;;
    --pubkey)    [ $# -ge 2 ] || usage; PUBKEY=$2; shift 2 ;;
    --pool-src)  [ $# -ge 2 ] || usage; POOL_SRC=$2; shift 2 ;;
    --machine)   [ $# -ge 2 ] || usage; MACHINE=$2; shift 2 ;;
    --password-file) [ $# -ge 2 ] || usage; PWFILE=$2; shift 2 ;;
    --share-pool) SHARE=1; shift ;;
    --no-daemons) DAEMONS=0; shift ;;
    --apply)     APPLY=1; shift ;;
    -h|--help)   sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*)          die2 "unknown option: $1" ;;
    *)           [ -z "$LOGIN" ] || die2 "one login at a time (got '$LOGIN' and '$1')"
                 LOGIN=$1; shift ;;
  esac
done

[ -n "$LOGIN" ] || usage
printf '%s' "$LOGIN" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' \
  || die2 "bad login name '$LOGIN' (lowercase letters, digits, _ and -; at most 32)"
[ -n "$FULL" ] || die2 "--full-name is required"
[ -n "$PUBKEY" ] || die2 "--pubkey <file> is required"
[ -r "$PUBKEY" ] || die2 "--pubkey: cannot read '$PUBKEY'"
[ "$EUID" != 0 ] || die2 "run this as the admin login, not under sudo — it sudo's each step itself"

KEYS=$(grep -Ec '^(ssh-|ecdsa-|sk-)' "$PUBKEY" 2>/dev/null) || KEYS=0
if [ "$KEYS" -eq 0 ] && [ "$APPLY" = 1 ]; then
  die2 "--pubkey '$PUBKEY' holds no public key line (ssh-… / ecdsa-… / sk-…)"
fi

HOMES=${FLEET_LOGIN_HOMES:-/Users}
H="$HOMES/$LOGIN"
DDIR="${FLEET_INSTALL_DAEMON_DIR:-/Library/LaunchDaemons}"
GITURL="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}/$FLEET_REPO_SELF.git"
BIN="$(cd "$(dirname "$0")" && pwd)"

# The password (#1192): a file, never a prompt and never argv on the screen.
# --password-file's first line, or a random one written to the admin's own
# ~/<login>-onboard/password.txt under --apply. The person signs in with their
# key; the file is for the admin (and a password reset), so it stays 600.
PW='' PWGEN=0
if [ -n "$PWFILE" ]; then
  [ -r "$PWFILE" ] || die2 "--password-file: cannot read '$PWFILE'"
  PW=$(head -n 1 "$PWFILE")
  [ -n "$PW" ] || die2 "--password-file: '$PWFILE' is empty"
else
  PWFILE="$HOME/$LOGIN-onboard/password.txt"; PWGEN=1
fi
gen_password() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

# The pool: every regular file but dotfiles and editor backups — i.e. each
# <label> token AND its <label>.conf (fleet-account.sh's acct_labels, .conf kept).
POOL=()
if [ "$SHARE" = 1 ]; then
  [ -n "$POOL_SRC" ] || POOL_SRC="${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/accounts}"
  [ -d "$POOL_SRC" ] || die2 "--share-pool: no pool at '$POOL_SRC' (--pool-src <dir>)"
  for f in "$POOL_SRC"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in .*|*~) continue ;; esac
    POOL+=("$f")
  done
  [ "${#POOL[@]}" -gt 0 ] || die2 "--share-pool: '$POOL_SRC' holds no tokens"
fi

# Refuse, never overwrite (exit 3) — checked in both modes, so a dry run that
# looks clean is one --apply will actually carry out.
if id "$LOGIN" >/dev/null 2>&1; then
  printf '%s: login %s already exists — refusing (this script only adds)\n' "$PROG" "$LOGIN" >&2
  exit 3
fi
if [ -e "$H" ]; then
  printf '%s: %s already exists (no such login) — refusing to write into it\n' "$PROG" "$H" >&2
  exit 3
fi

if [ "$APPLY" = 1 ]; then
  for t in sudo sysadminctl createhomedir git; do
    command -v "$t" >/dev/null 2>&1 || { printf '%s: %s not found — nothing was changed\n' "$PROG" "$t" >&2; exit 1; }
  done
  if [ "$DAEMONS" = 1 ] && ! command -v plutil >/dev/null 2>&1; then
    printf '%s: plutil not found — cannot render LaunchDaemons (--no-daemons to skip step 8); nothing was changed\n' "$PROG" >&2; exit 1
  fi
fi

SSH_GROUP=com.apple.access_ssh
HAVE_SSH_GROUP=0
dscl . -read "/Groups/$SSH_GROUP" >/dev/null 2>&1 && HAVE_SSH_GROUP=1

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fleet-login-new.XXXXXX") || { printf '%s: mktemp failed\n' "$PROG" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

N=0
say() { printf '%s\n' "$*"; }
show() { local q; q=$(printf '%q ' "$@"); printf '  $ %s\n' "${q% }"; }
fail() { printf '%s: FAILED at step %s — stopped; nothing after it ran\n' "$PROG" "$N" >&2; exit 1; }
# run <argv…>: print, and under --apply execute.
run() { show "$@"; [ "$APPLY" = 1 ] || return 0; "$@" || fail; }
# run_shown <line> -- <argv…>: print <line> as the command instead of argv (a
# secret in argv, or a file that exists only under --apply, stays out of the
# transcript); under --apply execute argv.
run_shown() { local line=$1; shift; [ "${1:-}" != -- ] || shift; printf '  $ %s\n' "$line"; [ "$APPLY" = 1 ] || return 0; "$@" || fail; }
# append <src> <dst>: sudo tee -a <dst> < <src>
append() {
  local q; q=$(printf "%q " sudo tee -a "$2")
  printf "  \$ %s < %s\n" "${q% }" "$(printf %q "$1")"
  [ "$APPLY" = 1 ] || return 0
  # shellcheck disable=SC2024  # the key is read as the admin on purpose; only the write needs root
  sudo tee -a "$2" < "$1" >/dev/null || fail
}
step() { N=$((N + 1)); say ""; say "[$N] $*"; }

if [ "$APPLY" = 1 ]; then
  say "fleet-login-new: creating login '$LOGIN' ($FULL) — running each step:"
else
  say "fleet-login-new: DRY RUN — nothing below is executed. Re-run with --apply to do it."
fi
say "  login=$LOGIN  full-name=$FULL  home=$H  share-pool=$([ "$SHARE" = 1 ] && echo yes || echo no)  daemons=$([ "$DAEMONS" = 1 ] && echo system || echo 'no (gui, after a GUI sign-in)')"
[ "$KEYS" -gt 0 ] || say "  WARN: --pubkey '$PUBKEY' holds no public key line; --apply will refuse it"

if [ "$PWGEN" = 1 ]; then
  step "create the OS login (password: random, written to $PWFILE — mode 600, never printed)"
  if [ "$APPLY" = 1 ]; then
    PW=$(gen_password)
    [ "${#PW}" -ge 16 ] || { printf '%s: could not generate a password\n' "$PROG" >&2; fail; }
    ( umask 077 && mkdir -p "$(dirname "$PWFILE")" && printf '%s\n' "$PW" > "$PWFILE" ) || fail
    say "  (wrote $PWFILE)"
  else
    say "  (would write a random password to $PWFILE, mode 600)"
  fi
else
  step "create the OS login (password: the first line of $PWFILE — never printed)"
fi
run_shown "sudo sysadminctl -addUser $(printf %q "$LOGIN") -fullName $(printf %q "$FULL") -password <redacted: $PWFILE>" \
  -- sudo sysadminctl -addUser "$LOGIN" -fullName "$FULL" -password "$PW"
step "create its home directory"
run sudo createhomedir -c -u "$LOGIN"

step "allow SSH (Remote Login)"
if [ "$HAVE_SSH_GROUP" = 1 ]; then
  run sudo dseditgroup -o edit -a "$LOGIN" -t user "$SSH_GROUP"
else
  say "  (skipped: no $SSH_GROUP group — Remote Login is open to all users)"
fi

step "install the public key ($KEYS key line(s) from $PUBKEY)"
run sudo mkdir -p "$H/.ssh"
append "$PUBKEY" "$H/.ssh/authorized_keys"
run sudo chown -R "$LOGIN:staff" "$H/.ssh"
run sudo chmod 700 "$H/.ssh"
run sudo chmod 600 "$H/.ssh/authorized_keys"

if [ "$SHARE" = 1 ]; then
  D="$H/.config/claude-fleet/accounts"
  step "join the shared Claude pool (${#POOL[@]} files from $POOL_SRC — SHARED-MACHINE 2b)"
  DST=()
  for f in ${POOL[@]+"${POOL[@]}"}; do DST+=("$D/${f##*/}"); done
  run sudo mkdir -p "$D"
  run sudo cp -p ${POOL[@]+"${POOL[@]}"} "$D/"
  run sudo chown "$LOGIN:staff" "$H/.config" "$H/.config/claude-fleet"
  run sudo chown -R "$LOGIN:staff" "$D"
  run sudo chmod 700 "$D"
  run sudo chmod 600 ${DST[@]+"${DST[@]}"}
fi

step "set up claude-fleet on first login (~/.zshrc — ~/.local/bin PATH line + fleet-login-bootstrap.sh)"
ZRC="$TMPD/zshrc"
BS="$BIN/fleet-login-bootstrap.sh"
# The PATH line first (issue #1191) — unless the file already carries one — then
# the block: the block's bootstrap call must already see ~/.local/bin.
{ grep -qF '.local/bin' "$H/.zshrc" 2>/dev/null || bash "$BS" --print-path-line; bash "$BS" --print-zshrc; } > "$ZRC" \
  || { printf '%s: fleet-login-bootstrap.sh --print-zshrc failed\n' "$PROG" >&2; exit 1; }
append "$ZRC" "$H/.zshrc"
run sudo chown "$LOGIN:staff" "$H/.zshrc"
run sudo chmod 644 "$H/.zshrc"

# 7. the clone, as the login — its daemons (8) reference ~<login>/.claude/fleet/bin
ROOT="$H/.claude/fleet"
step "install claude-fleet for $LOGIN (clone at stable → $ROOT, as $LOGIN — the services below run its scripts)"
run sudo -u "$LOGIN" -H mkdir -p "$H/.claude"
run sudo -u "$LOGIN" -H git -c advice.detachedHead=false clone -q -b stable "$GITURL" "$ROOT"
run sudo -u "$LOGIN" -H mkdir -p "$ROOT/logs"

# 8. the background services, system shape, as the admin
if [ "$DAEMONS" = 1 ]; then
  # Under --apply the clone exists: render ITS templates with ITS apply script
  # when that version knows --render-system (the same render the login's own
  # first-login apply will compare against), else with this install's. A dry run
  # has no clone yet — it previews the unit list from this install's templates.
  if [ "$APPLY" = 1 ]; then
    TMPL_DIR="$ROOT/launchd"; APPLY_SH="$ROOT/bin/fleet-install-apply.sh"
    grep -q -- '--render-system' "$APPLY_SH" 2>/dev/null || APPLY_SH="$BIN/fleet-install-apply.sh"
  else
    TMPL_DIR="$BIN/../launchd"; APPLY_SH="$BIN/fleet-install-apply.sh"
  fi
  UNITS=$(ls "$TMPL_DIR"/com.claude-fleet.*.plist.tmpl 2>/dev/null | sed 's#.*/com\.claude-fleet\.\(.*\)\.plist\.tmpl$#\1#' | sort)
  NU=$(printf '%s\n' "$UNITS" | sed '/^$/d' | wc -l | tr -d ' ')
  step "install $LOGIN's $NU background services as system LaunchDaemons (com.claude-fleet.$LOGIN.*, UserName $LOGIN — no GUI sign-in needed)"
  if [ "$NU" = 0 ]; then
    say "  (no launchd/*.plist.tmpl in $TMPL_DIR — nothing to install)"
  fi
  mkdir -p "$TMPD/plists"
  for u in $UNITS; do
    label="com.claude-fleet.$LOGIN.$u"; dst="$DDIR/$label.plist"; src="$TMPD/plists/$label.plist"
    if [ "$APPLY" = 1 ]; then
      FLEET_INSTALL_LOGIN="$LOGIN" FLEET_INSTALL_HOME="$H" bash "$APPLY_SH" --render-system "$u" --root "$ROOT" > "$src" \
        || { printf '%s: render %s failed (%s --render-system)\n' "$PROG" "$u" "$APPLY_SH" >&2; fail; }
    fi
    run_shown "sudo install -m 644 <$label.plist, rendered from launchd/com.claude-fleet.$u.plist.tmpl> $(printf %q "$dst")" \
      -- sudo install -m 644 "$src" "$dst"
    run sudo launchctl bootstrap system "$dst"
  done
fi

say ""
if [ "$APPLY" = 1 ]; then
  say "done: login '$LOGIN' created. Left for a human:"
else
  say "after --apply, left for a human:"
fi
if [ "$PWGEN" = 1 ]; then
  say "  password: $PWFILE (mode 600, yours only — the person signs in with their key; not printed here, never sent)"
else
  say "  password: the first line of $PWFILE (--password-file) — not printed here, never sent"
fi
i=0
if [ "$DAEMONS" = 0 ]; then
  i=$((i + 1))
  say "  $i. sign in as $LOGIN ONCE in the GUI (console or Screen Sharing) — creates the"
  say "     login Keychain and the gui/<uid> launchd domain its LaunchAgents load into"
fi
i=$((i + 1)); say "  $i. as $LOGIN: ccquota codex login personal --device-auth   — approve the device code"
say "     (never copy ~/.codex/auth.json between logins)"
i=$((i + 1)); say "  $i. as $LOGIN: gh auth login   — their own GitHub identity"
i=$((i + 1)); say "  $i. on the hub: ccquota enroll --name $MACHINE-$LOGIN   — give $LOGIN the token privately"
say "     (then docs/SHARED-MACHINE.md step 4: the ccquota agent)"
if [ "$DAEMONS" = 1 ]; then
  say "  claude-fleet + Claude Code install themselves on $LOGIN's first SSH login — no GUI sign-in, no step here"
else
  say "  claude-fleet + Claude Code install themselves on $LOGIN's first terminal login after step 1 — no step here"
fi
exit 0
