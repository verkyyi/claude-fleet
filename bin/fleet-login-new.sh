#!/bin/bash
# fleet-login-new.sh <login> --full-name <name> [--pubkey <file>] [--share-pool]
#                    [--pool-src <dir>] [--password-file <file>] [--no-daemons]
#                    [--machine <name>] [--no-welcome] [--lang zh|en] [--apply]
#   — open a new person's OS login on a shared machine in ONE command
#     (issue #1164, EPIC #1163; no GUI sign-in needed since #1192, EPIC #1190;
#     writes the person's welcome letter since #1195, EPIC #1212).
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
#      (a relative path is resolved against where you typed it — see below).
#      No --pubkey (issue #1195): a TEMPORARY ed25519 pair is generated into
#      ~/<login>-onboard/id_ed25519{,.pub} (dir 700, key 600, comment
#      `<login>-onboard-temp`), its public half is what is installed, and its
#      private half goes into the welcome letter of step 9 — so the person can
#      connect before they ever sent you a key, and swaps it for their own on
#      first login (the letter says how). --no-welcome without --pubkey is an
#      error: nothing would carry the key.
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
#      The clone sits in the login's home, which macOS creates 700 — the admin
#      cannot read it (issue #1213: the first real run listed "0 background
#      services … nothing to install" and exited 0). So the templates and the
#      clone's apply script are read AS THE LOGIN (`sudo -u <login> -H cat`)
#      into this run's temp dir and rendered from there; the step prints
#      `installed N/N`, and 0 templates is a FAILURE (exit 1) that names the
#      dir and who read it, never a quiet success.
#   9. the welcome letter (issue #1195; `--no-welcome` skips it) →
#      ~/<login>-onboard/welcome.txt in YOUR home, mode 600: how to connect
#      (`ssh -p <port> <login>@<host>` — host and port from FLEET_SSH_PUBLIC_HOST /
#      FLEET_SSH_PUBLIC_PORT, the machine's public entry, read the way every knob
#      is: env → the install's fleet.conf → ~/.config/claude-fleet/fleet.settings,
#      via fleet-hook-conf.sh; unset ⇒ `<HOST>` placeholder + a WARN, port ⇒ 22),
#      the temporary private key inline when step 4 generated one (an attachment
#      does not leave this machine's mail; a file the admin reads does), an
#      ssh-config snippet, the swap-the-key steps, what the guide and `cf` do,
#      and what is still theirs (Codex device code, `gh auth login`). NEVER the
#      password. `--lang zh` (default) or `en`. You send it; the script only
#      writes it — and never prints the key to the terminal.
#
# and then prints what only a human can do (the Codex device code, the person's
# own `gh auth login`, the ccquota enrollment) — and where the password and the
# letter went.
#
# DEFAULT IS A DRY RUN: it prints every command it would run and runs none.
# --apply runs them, stopping at the first failure. Run it as the admin login,
# NOT under sudo — it sudo's each step itself, and your $HOME is where the pool
# comes from (and where the password file lands). Run it from ANY directory
# (issue #1216): the steps run from `/`, because a `sudo -u <login>` inherits
# the cwd and the new login cannot stand in your 0700 home — from
# ~/projects/… step 7's clone died on `Unable to read current working
# directory` (#1210 ④; sync-logins had the same in #1162). --pubkey /
# --pool-src / --password-file are made absolute first, so a relative
# `--pubkey alice.pub` (docs/SHARED-MACHINE.md's example) is still found.
#
# Only ever ADDS: it refuses (exit 3) when the login or its home already exists,
# never overwrites, and writes nothing in the new home outside `.ssh/`,
# `.config/claude-fleet/accounts/` (plus owning the `.config` dirs it creates),
# `.zshrc` and `.claude/fleet/`. In YOUR home it writes only ~/<login>-onboard/
# (password.txt, the temporary key pair, welcome.txt — all yours only).
#
# Exit: 0 ok · 1 a step failed under --apply · 2 bad arguments · 3 the login
#       (or its home) already exists
#
# Conf: FLEET_SSH_PUBLIC_HOST / FLEET_SSH_PUBLIC_PORT (global; fleet.conf.example)
#      — the public SSH entry the welcome letter names.
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

LOGIN='' FULL='' PUBKEY='' SHARE=0 APPLY=0 MACHINE=mini POOL_SRC='' PWFILE='' DAEMONS=1 WELCOME=1 WLANG=zh
while [ $# -gt 0 ]; do
  case "$1" in
    --full-name) [ $# -ge 2 ] || usage; FULL=$2; shift 2 ;;
    --pubkey)    [ $# -ge 2 ] || usage; PUBKEY=$2; shift 2 ;;
    --pool-src)  [ $# -ge 2 ] || usage; POOL_SRC=$2; shift 2 ;;
    --machine)   [ $# -ge 2 ] || usage; MACHINE=$2; shift 2 ;;
    --password-file) [ $# -ge 2 ] || usage; PWFILE=$2; shift 2 ;;
    --lang)      [ $# -ge 2 ] || usage; WLANG=$2; shift 2 ;;
    --share-pool) SHARE=1; shift ;;
    --no-daemons) DAEMONS=0; shift ;;
    --welcome)   WELCOME=1; shift ;;
    --no-welcome) WELCOME=0; shift ;;
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
case "$WLANG" in zh|en) ;; *) die2 "--lang: zh or en (got '$WLANG')" ;; esac
# No --pubkey ⇒ a temporary pair, carried by the welcome letter (issue #1195).
TMPKEY=0
if [ -z "$PUBKEY" ]; then
  [ "$WELCOME" = 1 ] || die2 "--pubkey <file> is required with --no-welcome (no letter would carry a temporary key)"
  TMPKEY=1
else
  [ -r "$PUBKEY" ] || die2 "--pubkey: cannot read '$PUBKEY'"
fi
[ "$EUID" != 0 ] || die2 "run this as the admin login, not under sudo — it sudo's each step itself"

if [ "$TMPKEY" = 1 ]; then
  KEYS=1
else
  KEYS=$(grep -Ec '^(ssh-|ecdsa-|sk-)' "$PUBKEY" 2>/dev/null) || KEYS=0
  if [ "$KEYS" -eq 0 ] && [ "$APPLY" = 1 ]; then
    die2 "--pubkey '$PUBKEY' holds no public key line (ssh-… / ecdsa-… / sk-…)"
  fi
fi

BIN="$(cd "$(dirname "$0")" && pwd)"
GITURL="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}/$FLEET_REPO_SELF.git"

# Every path this script was handed, made absolute against the directory the
# admin typed it in — then run from / (issue #1216). Every `sudo -u <login>`
# below inherits the cwd, and the new login cannot stand in the admin's 0700
# home: from ~/projects/… step 7's clone died on `fatal: Unable to read current
# working directory: Permission denied` (#1210 ④) and only a `cd /` rerun went
# through — the same family as sync-logins' #1162. Resolved BEFORE the cd, so a
# relative `--pubkey alice.pub` (the docs' example) is still found; shown
# absolute in the transcript, so the plan reads the same from anywhere.
abs_dir()  { case "$1" in /*) printf '%s\n' "$1" ;; *) ( cd -- "$1" 2>/dev/null && pwd -P ) || printf '%s/%s\n' "$PWD" "$1" ;; esac; }
abs_file() { case "$1" in /*) printf '%s\n' "$1" ;; */*) printf '%s/%s\n' "$(abs_dir "${1%/*}")" "${1##*/}" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
[ -z "$PUBKEY" ] || PUBKEY=$(abs_file "$PUBKEY")
[ -z "$POOL_SRC" ] || POOL_SRC=$(abs_dir "$POOL_SRC")
[ -z "$PWFILE" ] || PWFILE=$(abs_file "$PWFILE")
HOMES=$(abs_dir "${FLEET_LOGIN_HOMES:-/Users}")
H="$HOMES/$LOGIN"
DDIR=$(abs_dir "${FLEET_INSTALL_DAEMON_DIR:-/Library/LaunchDaemons}")
# Everything this run leaves in the ADMIN's home: one dir, theirs only (700).
ONBOARD="$HOME/$LOGIN-onboard"
KEYFILE="$ONBOARD/id_ed25519"; [ "$TMPKEY" = 0 ] || PUBKEY="$KEYFILE.pub"
WELCOME_FILE="$ONBOARD/welcome.txt"
cd / || die2 'cannot cd / (every step runs from there; issue #1216)'

# The machine's public SSH entry, for the letter (issue #1195): the env is the
# floor, the install's fleet.conf and the login's fleet.settings override it —
# fleet-hook-conf.sh is the one resolution path (issue #561), so what the config
# modal shows is what the letter says. Unset host ⇒ a placeholder + a WARN (the
# letter still has everything else); unset port ⇒ 22, ssh's own default.
SSH_HOST=${FLEET_SSH_PUBLIC_HOST:-} SSH_PORT=${FLEET_SSH_PUBLIC_PORT:-}
if [ -f "$BIN/fleet-hook-conf.sh" ]; then
  _conf=$(bash "$BIN/fleet-hook-conf.sh" FLEET_SSH_PUBLIC_HOST FLEET_SSH_PUBLIC_PORT 2>/dev/null) || _conf=''
  _v=$(printf '%s\n' "$_conf" | sed -n 1p); [ -z "$_v" ] || SSH_HOST=$_v
  _v=$(printf '%s\n' "$_conf" | sed -n 2p); [ -z "$_v" ] || SSH_PORT=$_v
  unset _conf _v
fi
[ -n "$SSH_PORT" ] || SSH_PORT=22
printf '%s' "$SSH_PORT" | grep -Eq '^[0-9]{1,5}$' || die2 "FLEET_SSH_PUBLIC_PORT: not a port number: '$SSH_PORT'"
HOST_SHOWN=${SSH_HOST:-'<HOST>'}

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
  PWFILE="$ONBOARD/password.txt"; PWGEN=1
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
  if [ "$TMPKEY" = 1 ] && ! command -v ssh-keygen >/dev/null 2>&1; then
    printf '%s: ssh-keygen not found — cannot generate the temporary key (pass --pubkey <file>); nothing was changed\n' "$PROG" >&2; exit 1
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
say "  login=$LOGIN  full-name=$FULL  home=$H  share-pool=$([ "$SHARE" = 1 ] && echo yes || echo no)  daemons=$([ "$DAEMONS" = 1 ] && echo system || echo 'no (gui, after a GUI sign-in)')  key=$([ "$TMPKEY" = 1 ] && echo 'temporary (generated)' || echo "$PUBKEY")  welcome=$([ "$WELCOME" = 1 ] && echo "$WLANG" || echo no)"
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

if [ "$TMPKEY" = 1 ]; then
  # A temporary pair (issue #1195): generated HERE, in the admin's onboard dir,
  # never printed — its private half is for the welcome letter (step 9) only.
  # A stale pair from an earlier failed run of this same login is worthless
  # (the login did not exist — we refused above if it did), so it is replaced;
  # ssh-keygen would otherwise stop to ask "Overwrite?" on a non-tty and hang.
  step "install the public key (no --pubkey: a temporary ed25519 pair → $KEYFILE, mode 600 — public half installed now, private half goes in the welcome letter)"
  if [ "$APPLY" = 1 ]; then
    ( umask 077 && mkdir -p "$ONBOARD" && rm -f "$KEYFILE" "$KEYFILE.pub" \
      && ssh-keygen -q -t ed25519 -N '' -C "$LOGIN-onboard-temp" -f "$KEYFILE" ) || fail
    say "  (generated $KEYFILE + .pub)"
  else
    say "  (would run: ssh-keygen -q -t ed25519 -N '' -C $LOGIN-onboard-temp -f $KEYFILE)"
  fi
else
  step "install the public key ($KEYS key line(s) from $PUBKEY)"
fi
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
  # Under --apply the clone exists — inside the login's home, which macOS made
  # 700, so the admin's own process can neither list nor read it (issue #1213;
  # #1210 ①). Everything in it is read AS THE LOGIN: `sudo -u <login> -H ls`
  # for the unit list, `sudo -u <login> -H cat` for each template and for the
  # clone's own fleet-install-apply.sh, each copied into this run's temp dir
  # (the admin's; stdout is ours). The render then runs here, as the admin,
  # with the clone's script when that version knows --render-system (the same
  # render the login's own first-login apply will compare against), else with
  # this install's — and root installs + bootstraps the result. A dry run has
  # no clone yet — it previews the unit list from this install's templates.
  STAGE="$TMPD/stage"; mkdir -p "$STAGE/launchd" "$STAGE/bin" "$TMPD/plists"
  unit_names() { sed -n 's/^com\.claude-fleet\.\(.*\)\.plist\.tmpl$/\1/p' | sort; }
  if [ "$APPLY" = 1 ]; then
    TMPL_DIR="$ROOT/launchd"
    UNITS=$(sudo -u "$LOGIN" -H ls -1 "$TMPL_DIR" 2>"$TMPD/ls.err" | unit_names)
  else
    TMPL_DIR="$BIN/../launchd"
    UNITS=$(ls -1 "$TMPL_DIR" 2>/dev/null | unit_names)
  fi
  NU=$(printf '%s\n' "$UNITS" | sed '/^$/d' | wc -l | tr -d ' ')
  step "install $LOGIN's $NU background services as system LaunchDaemons (com.claude-fleet.$LOGIN.*, UserName $LOGIN — no GUI sign-in needed)"
  if [ "$APPLY" = 1 ]; then
    show sudo -u "$LOGIN" -H ls -1 "$TMPL_DIR"
    if [ "$NU" = 0 ]; then
      err=$(sed 's/^/: /' "$TMPD/ls.err" | head -n 1)
      printf '%s: no launchd/com.claude-fleet.*.plist.tmpl in %s (read as %s)%s — 0 background services to install: the clone at stable carries no daemon templates\n' \
        "$PROG" "$TMPL_DIR" "$LOGIN" "$err" >&2
      fail
    fi
    say "  (the clone is in $LOGIN's 700 home: $NU templates + bin/fleet-install-apply.sh read as $LOGIN, rendered here as the admin)"
    # shellcheck disable=SC2024  # the point: the login reads, the redirect is ours (admin-owned temp)
    for u in $UNITS; do
      t="launchd/com.claude-fleet.$u.plist.tmpl"
      sudo -u "$LOGIN" -H cat "$ROOT/$t" > "$STAGE/$t" \
        || { printf '%s: cannot read %s as %s\n' "$PROG" "$ROOT/$t" "$LOGIN" >&2; fail; }
    done
    APPLY_SH="$STAGE/bin/fleet-install-apply.sh"
    # shellcheck disable=SC2024  # same: read as the login, written here
    sudo -u "$LOGIN" -H cat "$ROOT/bin/fleet-install-apply.sh" > "$APPLY_SH" 2>/dev/null \
      && grep -q -- '--render-system' "$APPLY_SH" || APPLY_SH="$BIN/fleet-install-apply.sh"
  elif [ "$NU" = 0 ]; then
    say "  WARN: no launchd/*.plist.tmpl in $TMPL_DIR — nothing to preview here; --apply reads the clone's (as $LOGIN) and fails on 0"
  fi
  NI=0
  for u in $UNITS; do
    label="com.claude-fleet.$LOGIN.$u"; dst="$DDIR/$label.plist"; src="$TMPD/plists/$label.plist"
    if [ "$APPLY" = 1 ]; then
      FLEET_INSTALL_LOGIN="$LOGIN" FLEET_INSTALL_HOME="$H" bash "$APPLY_SH" --render-system "$u" --root "$STAGE" > "$src" \
        || { printf '%s: render %s failed (%s --render-system)\n' "$PROG" "$u" "$APPLY_SH" >&2; fail; }
    fi
    run_shown "sudo install -m 644 <$label.plist, rendered from launchd/com.claude-fleet.$u.plist.tmpl> $(printf %q "$dst")" \
      -- sudo install -m 644 "$src" "$dst"
    run sudo launchctl bootstrap system "$dst"
    NI=$((NI + 1))
  done
  [ "$APPLY" = 1 ] && say "  installed $NI/$NU"
fi

# 9. the welcome letter (issue #1195) — everything the person needs to connect,
# in the admin's onboard dir, 600. The private key is read from the file step 4
# wrote and goes ONLY into this file: never into the transcript, never the
# password. `<HOST>` stays a visible placeholder when the public entry is unset
# — the admin gets a WARN here, the reader gets a line saying who to ask.
ADMIN=${USER:-}; [ -n "$ADMIN" ] || ADMIN=$(id -un 2>/dev/null || true)
KEY_ALIAS="$MACHINE-$LOGIN"
welcome_zh() {
  local date; date=$(date -u +%Y-%m-%d)
  cat <<EOF
你好，${FULL}：

你在 $MACHINE 上的账号开好了，登录名 ${LOGIN}。这封信由 fleet-login-new.sh 自动生成
（${date}，开号人 ${ADMIN:-未知}），照着做就能连上。

1. 怎么连

   ssh -p $SSH_PORT $LOGIN@$HOST_SHOWN

   第一次 ssh 登录会自动装好 claude-fleet 和 Claude Code，把你的 fleet 拉起来，然后
   直接进去——要几分钟，别中断；向导会先开口。
EOF
  [ -n "$SSH_HOST" ] || cat <<EOF
   （开号人还没配这台机器的公网入口：把上面的 <HOST> 换成开号人告诉你的主机名，
   端口也以开号人说的为准。）
EOF
  if [ "$TMPKEY" = 1 ]; then
    cat <<EOF

2. 钥匙（临时的，只用来第一次登录）

   把下面 BEGIN 到 END 之间的内容（含这两行）原样存成你电脑上的文件
   ~/.ssh/${KEY_ALIAS}，然后：
   chmod 600 ~/.ssh/$KEY_ALIAS

EOF
    cat "$KEYFILE"
    cat <<EOF

   它对应的公钥已经装进你在 $MACHINE 上的 ~/.ssh/authorized_keys：
   $(cat "$KEYFILE.pub")
EOF
  else
    cat <<EOF

2. 钥匙

   用你给开号人的那把钥匙登录——它的公钥已经装进你在 $MACHINE 上的
   ~/.ssh/authorized_keys：
$(sed 's/^/   /' "$PUBKEY")
   下面 ssh config 里的 IdentityFile 填这把钥匙的私钥路径。
EOF
  fi
  cat <<EOF

3. ssh config 片段

   加到你电脑的 ~/.ssh/config，以后 ssh $MACHINE 就够了：

Host $MACHINE
  HostName $HOST_SHOWN
  Port $SSH_PORT
  User $LOGIN
  IdentityFile ~/.ssh/$( [ "$TMPKEY" = 1 ] && printf '%s' "$KEY_ALIAS" || printf '%s' '<你的私钥>' )
  IdentitiesOnly yes

4. 换成你自己的钥匙（登上以后尽快）

EOF
  if [ "$TMPKEY" = 1 ]; then
    cat <<EOF
   临时钥匙经过了这封信，登上之后换掉它：
   a. 在你电脑上生成一把新钥匙（已有就跳过）：
      ssh-keygen -t ed25519 -f ~/.ssh/$KEY_ALIAS-own
   b. 把新公钥装上去（这一步还用临时钥匙）：
      ssh-copy-id -i ~/.ssh/$KEY_ALIAS-own.pub -o IdentityFile=~/.ssh/$KEY_ALIAS -p $SSH_PORT $LOGIN@$HOST_SHOWN
   c. 用新钥匙登一次，确认能进：
      ssh -i ~/.ssh/$KEY_ALIAS-own -p $SSH_PORT $LOGIN@$HOST_SHOWN
   d. 登进 $MACHINE 后删掉临时钥匙那一行：
      grep -v ' $LOGIN-onboard-temp\$' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   e. 把 ssh config 里的 IdentityFile 改成 ~/.ssh/$KEY_ALIAS-own；电脑上的 ~/.ssh/$KEY_ALIAS 可以删了。
EOF
  else
    cat <<EOF
   你用的是自己的钥匙，不用换。以后要再加一把：登进 $MACHINE 后把新公钥追加到
   ~/.ssh/authorized_keys 就行。
EOF
  fi
  cat <<EOF

5. 向导与 cf

   - 每次 ssh 登录都直接进你的 fleet；断开后再 ssh 就回来了。
   - 向导（一个 Claude 会话）会带你走一遍：加自己的仓库 → 提第一个 issue → 看 worker 跑 → 合并 PR。
   - 向导窗口关了、或想再开：cf --guide
   - 在 shell 里：cf 回到 fleet；cf owner/repo 把一个仓库加进来。
   - 想离开但不关会话：按 tmux 的 prefix 键（默认 Ctrl-b）再按 d；下次 ssh 回来接着用。

6. 还要你自己做的

   - Codex：ccquota codex login personal --device-auth（按提示批准设备码）
   - GitHub：gh auth login（用你自己的账号）

这封信里没有密码：登录只用钥匙。连不上、要重设密码，找开号人${ADMIN:+ $ADMIN}。
EOF
}
welcome_en() {
  local date; date=$(date -u +%Y-%m-%d)
  cat <<EOF
Hi $FULL,

Your login on $MACHINE is ready: user name $LOGIN. This letter was generated by
fleet-login-new.sh ($date, by ${ADMIN:-unknown}); follow it and you are in.

1. How to connect

   ssh -p $SSH_PORT $LOGIN@$HOST_SHOWN

   Your first ssh login installs claude-fleet and Claude Code, brings your fleet up
   and drops you into it — a few minutes, don't interrupt; the guide speaks first.
EOF
  [ -n "$SSH_HOST" ] || cat <<EOF
   (The public entry of this machine is not configured yet: replace <HOST> above
   with the host name the admin gives you, and take the port from them too.)
EOF
  if [ "$TMPKEY" = 1 ]; then
    cat <<EOF

2. Key (temporary — for the first login only)

   Save everything from the BEGIN line to the END line (both included) verbatim
   as ~/.ssh/$KEY_ALIAS on your own computer, then:
   chmod 600 ~/.ssh/$KEY_ALIAS

EOF
    cat "$KEYFILE"
    cat <<EOF

   Its public half is already in your ~/.ssh/authorized_keys on $MACHINE:
   $(cat "$KEYFILE.pub")
EOF
  else
    cat <<EOF

2. Key

   Log in with the key you gave the admin — its public half is already in your
   ~/.ssh/authorized_keys on $MACHINE:
$(sed 's/^/   /' "$PUBKEY")
   Put that key's private path in the IdentityFile line below.
EOF
  fi
  cat <<EOF

3. ssh config snippet

   Add this to ~/.ssh/config on your computer; from then on \`ssh $MACHINE\` is enough:

Host $MACHINE
  HostName $HOST_SHOWN
  Port $SSH_PORT
  User $LOGIN
  IdentityFile ~/.ssh/$( [ "$TMPKEY" = 1 ] && printf '%s' "$KEY_ALIAS" || printf '%s' '<your-private-key>' )
  IdentitiesOnly yes

4. Swap in your own key (soon after your first login)

EOF
  if [ "$TMPKEY" = 1 ]; then
    cat <<EOF
   The temporary key travelled in this letter, so replace it once you are in:
   a. Make a new key on your computer (skip if you have one):
      ssh-keygen -t ed25519 -f ~/.ssh/$KEY_ALIAS-own
   b. Install its public half (this step still uses the temporary key):
      ssh-copy-id -i ~/.ssh/$KEY_ALIAS-own.pub -o IdentityFile=~/.ssh/$KEY_ALIAS -p $SSH_PORT $LOGIN@$HOST_SHOWN
   c. Log in once with the new key to make sure it works:
      ssh -i ~/.ssh/$KEY_ALIAS-own -p $SSH_PORT $LOGIN@$HOST_SHOWN
   d. On $MACHINE, drop the temporary key's line:
      grep -v ' $LOGIN-onboard-temp\$' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   e. Point IdentityFile in your ssh config at ~/.ssh/$KEY_ALIAS-own; ~/.ssh/$KEY_ALIAS on your computer can go.
EOF
  else
    cat <<EOF
   You are on your own key already — nothing to swap. To add another one later,
   append its public half to ~/.ssh/authorized_keys on $MACHINE.
EOF
  fi
  cat <<EOF

5. The guide and cf

   - Every ssh login lands you straight in your fleet; disconnect and ssh again to return.
   - The guide (a Claude session) walks you through: add your own repo → file your first issue → watch the worker → merge the PR.
   - Guide window closed, or want it back: cf --guide
   - In a shell: cf returns to the fleet; cf owner/repo adds a repo to it.
   - To leave without closing anything: the tmux prefix (Ctrl-b by default), then d; your next ssh picks up where you left.

6. Still yours to do

   - Codex: ccquota codex login personal --device-auth   (approve the device code)
   - GitHub: gh auth login   (your own account)

There is no password in this letter: you log in with the key. Can't get in, or need
a password reset — ask the admin${ADMIN:+ ($ADMIN)}.
EOF
}
welcome_text() { if [ "$WLANG" = en ]; then welcome_en; else welcome_zh; fi; }

if [ "$WELCOME" = 1 ]; then
  step "write the welcome letter ($WLANG) → $WELCOME_FILE (mode 600, yours only: host $HOST_SHOWN, port $SSH_PORT, $([ "$TMPKEY" = 1 ] && echo 'the temporary private key inline' || echo "their own key's public line"), never the password)"
  [ -n "$SSH_HOST" ] || say "  WARN: FLEET_SSH_PUBLIC_HOST is unset — the letter says <HOST>; set it (and FLEET_SSH_PUBLIC_PORT, now $SSH_PORT) in ~/.config/claude-fleet/fleet.settings (prefix+c), then re-run or edit the letter"
  if [ "$APPLY" = 1 ]; then
    ( umask 077 && mkdir -p "$ONBOARD" && welcome_text > "$WELCOME_FILE" ) || fail
    say "  (wrote $WELCOME_FILE)"
  else
    say "  (would write it — a dry run writes nothing)"
  fi
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
if [ "$WELCOME" = 1 ]; then
  say "  welcome letter: $WELCOME_FILE (mode 600, yours only) — send it to $LOGIN yourself: how to connect$([ "$TMPKEY" = 1 ] && echo ', the temporary private key' || echo ''), the ssh config, the key swap, the guide; never the password"
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
