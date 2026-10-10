#!/bin/bash
# fleet-login-new.sh <login> --full-name <name> [--pubkey <file>] [--share-pool]
#                    [--pool-src <dir>] [--password-file <file>] [--no-daemons]
#                    [--machine <name>] [--no-welcome] [--lang zh|en] [--no-credsep]
#                    [--apply]
# fleet-login-new.sh <login> --daemons-only [--apply]
#   — open a new person's OS login on a shared machine in ONE command
#     (issue #1164, EPIC #1163; no GUI sign-in needed since #1192, EPIC #1190;
#     writes the person's welcome letter since #1195, EPIC #1212).
#
# docs/SHARED-MACHINE.md steps 1–2b used to be ~7 hand-typed admin commands
# spread over two docs; a missed chown or group membership meant the person
# could not log in, or could not use the pool, and the admin had to go hunting.
# This script is those steps, in order:
#
#   1. sudo sysadminctl -addUser <login> -fullName <name> -shell /usr/bin/false
#      then `sudo dscl .` reading `passwd /Users/<login> <pw>` on its STDIN, then
#      the shell back to /bin/zsh. <pw> never enters any argv (issue #2396: the
#      old `-password <pw>` sat in `ps` for the ~5 minutes sysadminctl ran, to
#      every login on the machine — and still runs, every time on macmini:
#      the whole create, home + install + daemons, is 13 min and more, #2908);
#      the login is shell-less while it still has
#      no password, so a blank-password `su` reaches nothing. <pw> is
#      --password-file's first line, or (default) a random one this script
#      writes to ~/<login>-onboard/password.txt (mode 600, yours only) — never a
#      terminal prompt (`-password -` hung every remote/scripted run, #1183 ①),
#      and never printed: the person signs in with their key.
#   2. sudo createhomedir -c -u <login>          (the home, so step 4 has a place)
#      + sudo chmod 700 <home>   (never the macOS default: 0750 staff lets every
#                                 other login list it — issue #2414)
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
#      (default: YOUR accounts dir). Separated (the default, step 7b): the tokens
#      go into the login's credential STORE, never its dir — it gets only the
#      label markers (`store:<label>`) + the .conf files. --no-credsep: the old
#      layout, every token copied into ~<login>/.config/claude-fleet/accounts
#      (dir 700 / files 600, owned by <login>, readable by its every session) —
#      SHARED-MACHINE step 2b. Never ~/.codex/auth.json: Codex rotates its
#      refresh token, so the new login gets its own device-code session instead
#      (printed as a manual step).
#   6. ~<login>/.zshrc ← the ~/.local/bin PATH line (Claude Code's native install
#      dir, issue #1191; skipped when the file has one), owned by <login> — and
#      nothing else (issue #2702): no login banner, no client opened on an SSH
#      login, no cw.zsh. A fleet machine is no one's client; the person runs
#      `fleet` on their own device. Step 8b sets the login up instead.
#   7. ~<login>/.claude/fleet, AS <login> (sudo -u), so the daemons of step 8
#      have their scripts from the moment they load, and the first-login
#      bootstrap finds its install already there — bin/fleet-login-install.sh,
#      the ONE install road of a login's first minute (issue #2775, EPIC #2770
#      C5), staged where the login can read it: this machine's runtime when it
#      is managed (a tree of links into <root>/current, no fetch), else the
#      hub's signed stable (FLEET_LOGIN_HUB, else this install's FLEET_HUB_URL),
#      else a clone of stable from GitHub (a developer's machine). Root first
#      refreshes the machine's Claude Code cache (fleet-bootstrap-cache.sh, issue
#      #2297) so the login's first-run Claude install reaches no claude.ai; its
#      claude-fleet mirror is retired (#2775).
#   7b. its subscription out of its reach (issue #2294, EPIC #2293 C1) — after
#      the clone, BEFORE its background services and its first session (先代理、
#      后搬凭据、再开会话): ~<login>/.config/claude-fleet/fleet.conf gets
#      FLEET_CRED_PROXY=1 + FLEET_CRED_SEPARATE=1 in [common] (owned by <login>,
#      600), then, as root, `fleet-credsep.sh install --login <login> --fresh
#      --install-dir ~<login>/.claude/fleet [--pool-src <pool>]`: the role
#      account's store /var/db/fleet-cred/<login>/ (0700 _fleetcred), the proxy
#      run as _fleetcred, the pool (step 5) inside the store. Its preflight is
#      "nothing runs as this login yet". From then on the login needs no sudo:
#      its sessions reach the subscription only through the proxy. The run ends
#      with ONE line the hub reads — `credsep: separated` (status separated AND
#      check OK, the one judgement, EPIC #2293 convention 1), `credsep: pending
#      — <why>` (separated, but check not OK yet: the proxy still starting) — and
#      a status that is not separated FAILS the run (exit 1). --no-credsep skips
#      7b (and prints `credsep: off`): the old layout, for a machine whose fleet
#      predates credsep.
#   8. on a MANAGED machine (step 7 linked the install to <root>/current):
#      `sudo python3 <root>/current/bin/fleet-node-supervisor.py account adopt
#      <login>` instead — the machine daemon runs a managed login's account tasks
#      itself and moves its install with every switch of the runtime (issue
#      #2775; an unadopted login linked to the runtime would never move, and
#      install-sync cannot follow a tree with no git). --no-daemons leaves it
#      unadopted, with a WARN naming the command.
#      Elsewhere:
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
#   7a. (a login the HUB opens — FLEET_LOGIN_JOIN_CODE + FLEET_LOGIN_HUB in the
#      environment, set by the admin agent from the create op, issue #2652) the
#      login joins the hub as its OWN node: this script redeems the one-time
#      code (POST <hub>/v1/node/join, the code in a file — never an argv), and
#      the login runs `fleet-node-join.sh --joined <pass> --service none
#      --no-fleet --compute 1` as itself (node.env + ccquota + its runner,
#      nothing started); the admin drops its LaunchDaemon definition
#      (com.ccquota.agent.<login>, not loaded) — so 7b moves the token into the
#      store and starts the agent through its launcher (--no-credsep: loaded
#      here). Without it the hub never sees this login's fleet: a heartbeat
#      covers only the login that sends it. A step that fails is a WARN.
#   8b. (every login, issue #2702 — before it, only the ones the hub opened)
#      the fleet comes up AS the login, right away — fleet-login-bootstrap.sh:
#      clone, Claude Code, apply, the starter fleet. No ~/.zshrc block runs it on
#      a first SSH login any more, and the person's first session needs a fleet
#      there (a WARN on failure that names the command to re-run).
#   9. the welcome letter (issue #1195; `--no-welcome` skips it) →
#      ~/<login>-onboard/welcome.txt in YOUR home, mode 600: how to connect
#      (`ssh -p <port> <login>@<host>` — host and port from FLEET_SSH_PUBLIC_HOST /
#      FLEET_SSH_PUBLIC_PORT, the machine's public entry, read the way every knob
#      is: env → the install's fleet.conf → ~/.config/claude-fleet/fleet.settings,
#      via fleet-hook-conf.sh; unset ⇒ `<HOST>` placeholder + a WARN, port ⇒ 22),
#      the temporary private key inline when step 4 generated one (an attachment
#      does not leave this machine's mail; a file the admin reads does), an
#      ssh-config snippet, the swap-the-key steps, what the guide and `fleet` do,
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
# --daemons-only (issue #1223): step 8 ALONE, for a login that already exists
# but has no com.claude-fleet.<login>.* under /Library/LaunchDaemons — the
# bootstrap's `daemons: WARN` names this command. Steps 1–7 and 9 are skipped
# (their options are refused), the login AND its home must exist (else exit 4),
# the templates are read from the login's own clone as the login exactly as in
# a full run (#1213), a unit whose plist is already in place is left alone, and
# it still prints `installed N/N`. A dry run previews from this install.

# Only ever ADDS: it refuses (exit 3) when the login or its home already exists,
# never overwrites, and writes nothing in the new home outside `.ssh/`,
# `.config/claude-fleet/accounts/` (plus owning the `.config` dirs it creates),
# `.config/claude-fleet/{fleet.conf,credsep.json}` (7b), `.zshrc` and
# `.claude/fleet/`. In YOUR home it writes only ~/<login>-onboard/
# (password.txt, the temporary key pair, welcome.txt — all yours only).
#
# Exit: 0 ok · 1 a step failed under --apply · 2 bad arguments · 3 the login
#       (or its home) already exists · 4 --daemons-only: no such login (or
#       no home)
#
# Env: FLEET_LOGIN_OP_ID — the admin agent's op_id (issue #2928): written to
#      ~/<login>-onboard/op before step 1, its result appended on success, so
#      the same op arriving twice is answered from it (the agent reads it).
#
# Conf: FLEET_SSH_PUBLIC_HOST / FLEET_SSH_PUBLIC_PORT (global; fleet.conf.example)
#      — the public SSH entry the welcome letter names.
# Env: FLEET_LOGIN_CREDSEP_WAIT (15) — seconds 7b waits for `check` to pass
#      (the proxy starting) before it reports `pending`.
# Env (tests): FLEET_LOGIN_HOMES (default /Users) — the homes root ·
#      FLEET_INSTALL_DAEMON_DIR (/Library/LaunchDaemons) · FLEET_BOOTSTRAP_GIT_BASE
#      (https://github.com) · FLEET_INSTALL_BREW_PREFIX (as fleet-install-apply.sh) ·
#      FLEET_BOOTSTRAP_CACHE (fleet-bootstrap-cache.sh's; `off` = no cache) ·
#      FLEET_NODE_ROOT (the machine runtime, fleet-login-install.sh's) ·
#      FLEET_HUB_URL / FLEET_DIST_SOURCE (passed to the login's install).
set -u

PROG=fleet-login-new
usage() {
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

LOGIN='' FULL='' PUBKEY='' SHARE=0 APPLY=0 MACHINE=mini POOL_SRC='' PWFILE='' DAEMONS=1 WELCOME=1 WLANG=zh DONLY=0 CREDSEP=1
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
    --no-credsep) CREDSEP=0; shift ;;
    --daemons-only) DONLY=1; shift ;;
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
# A leading digit is allowed (macOS permits it; `24haowan` opened on a second
# machine, issue #2105) — an all-digit name is not: it reads as a uid.
printf '%s' "$LOGIN" | grep -Eq '^[a-z0-9_][a-z0-9_-]{0,31}$' \
  && printf '%s' "$LOGIN" | grep -q '[a-z_-]' \
  || die2 "bad login name '$LOGIN' (lowercase letters, digits, _ and -, not all digits; at most 32)"
# A login the hub opens (issue #2652): its join code + the hub, from the admin
# agent's environment — never an argv. Checked before anything is looked at.
JCODE=${FLEET_LOGIN_JOIN_CODE:-} JHUB=${FLEET_LOGIN_HUB:-}
unset FLEET_LOGIN_JOIN_CODE
OPENED=0
if [ -n "$JCODE" ] && [ -n "$JHUB" ]; then
  printf '%s' "$JCODE" | grep -Eq '^fj_[a-z2-7]{26}$' || die2 'FLEET_LOGIN_JOIN_CODE is not a join code (fj_…)'
  JHUB=${JHUB%/}; OPENED=1
fi
# The op that runs this (issue #2928): the admin agent's op_id, from its
# environment. Under --apply it is written to ~/<login>-onboard/op before step 1
# (op= · pid= · started=) and, when the run ends well, its result lines after
# (done= · line=…): the agent reads that file when the SAME op reaches it again
# with the login already there — finished = its result, never 「already exists」;
# still running = waited for; neither = rolled back. Hex, at most 64.
OPID=${FLEET_LOGIN_OP_ID:-}
unset FLEET_LOGIN_OP_ID
[ -z "$OPID" ] || printf '%s' "$OPID" | grep -Eq '^[0-9a-f]{1,64}$' || die2 'FLEET_LOGIN_OP_ID is not an op id (hex)'
if [ "$DONLY" = 1 ]; then
  # --daemons-only (issue #1223): step 8 for a login that already exists — the
  # options of steps 1–7 and 9 have nothing to act on, so they are refused, not
  # silently dropped (--full-name is accepted and unused: a caller may pass the
  # create argv it already has).
  [ "$DAEMONS" = 1 ] || die2 "--daemons-only and --no-daemons contradict each other"
  [ "$SHARE" = 0 ] || die2 "--daemons-only installs the background services only; --share-pool is step 5 (docs/SHARED-MACHINE.md 2b for an existing login)"
  [ -z "$PUBKEY" ] || die2 "--daemons-only installs the background services only; --pubkey is step 4"
  [ -z "$PWFILE" ] || die2 "--daemons-only installs the background services only; --password-file is step 1"
  WELCOME=0 CREDSEP=0
else
  [ -n "$FULL" ] || die2 "--full-name is required"
fi
case "$WLANG" in zh|en) ;; *) die2 "--lang: zh or en (got '$WLANG')" ;; esac
# No --pubkey ⇒ a temporary pair, carried by the welcome letter (issue #1195).
TMPKEY=0
if [ "$DONLY" = 1 ]; then
  :
elif [ -z "$PUBKEY" ]; then
  [ "$WELCOME" = 1 ] || die2 "--pubkey <file> is required with --no-welcome (no letter would carry a temporary key)"
  TMPKEY=1
else
  [ -r "$PUBKEY" ] || die2 "--pubkey: cannot read '$PUBKEY'"
fi
[ "$EUID" != 0 ] || die2 "run this as the admin login, not under sudo — it sudo's each step itself"

if [ "$TMPKEY" = 1 ] || [ "$DONLY" = 1 ]; then
  KEYS=1
else
  KEYS=$(grep -Ec '^(ssh-|ecdsa-|sk-)' "$PUBKEY" 2>/dev/null) || KEYS=0
  if [ "$KEYS" -eq 0 ] && [ "$APPLY" = 1 ]; then
    die2 "--pubkey '$PUBKEY' holds no public key line (ssh-… / ecdsa-… / sk-…)"
  fi
fi

BIN="$(cd "$(dirname "$0")" && pwd)"
# the launchd label rule for a login's system daemons (issue #1495) — the lib's, not a copy
# shellcheck source=/dev/null
. "$BIN/fleet-daemon-lib.sh"
# the machine's Claude Code cache a new login installs from (issue #2297)
CACHE_SH="$BIN/fleet-bootstrap-cache.sh"
CDIR=$(bash "$CACHE_SH" dir)
# A managed machine (issue #2775): the runtime's release, which step 7 links the
# login's install to and step 8 hands to the machine daemon (account adopt)
NROOT="${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}"; NROOT=${NROOT%/}
MSHA=$(readlink "$NROOT/current" 2>/dev/null); MSHA=${MSHA%/}; MSHA=${MSHA##*/}
case "$MSHA" in *[!0-9a-f]*) MSHA='' ;; esac
[ "${#MSHA}" = 40 ] && [ -d "$NROOT/$MSHA/bin" ] || MSHA=''
# the hub the login's install asks for a signed stable: the hub opening this
# login (7a), else this install's own
HUBU=${FLEET_LOGIN_HUB:-${FLEET_HUB_URL:-}}
if [ -z "$HUBU" ] && [ -z "${FLEET_HUB_URL+set}" ] && [ -f "$BIN/fleet-hook-conf.sh" ]; then
  HUBU=$(bash "$BIN/fleet-hook-conf.sh" FLEET_HUB_URL 2>/dev/null | sed -n 1p) || HUBU=''
fi

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
if [ "$DONLY" = 1 ]; then
  :
elif [ -n "$PWFILE" ]; then
  [ -r "$PWFILE" ] || die2 "--password-file: cannot read '$PWFILE'"
  PW=$(head -n 1 "$PWFILE")
  [ -n "$PW" ] || die2 "--password-file: '$PWFILE' is empty"
  # it travels as one word of an interactive dscl line (issue #2396), whose
  # parser has no reliable escape for these — refuse rather than mangle
  case "$PW" in *[[:space:]\"\'\\]*|*[![:print:]]*)
    die2 "--password-file: '$PWFILE' holds a space, quote, backslash or control character — use printable ASCII without them" ;;
  esac
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
# looks clean is one --apply will actually carry out. --daemons-only is the
# mirror image (issue #1223): it needs the login AND its home, else exit 4.
if [ "$DONLY" = 1 ]; then
  if ! id "$LOGIN" >/dev/null 2>&1; then
    printf '%s: --daemons-only: no login %s — refusing (open it first: fleet-login-new.sh %s --full-name <name> --apply)\n' "$PROG" "$LOGIN" "$LOGIN" >&2
    exit 4
  fi
  if [ ! -d "$H" ]; then
    printf '%s: --daemons-only: login %s has no home at %s — refusing\n' "$PROG" "$LOGIN" "$H" >&2
    exit 4
  fi
elif id "$LOGIN" >/dev/null 2>&1; then
  printf '%s: login %s already exists — refusing (this script only adds)\n' "$PROG" "$LOGIN" >&2
  exit 3
elif [ -e "$H" ]; then
  printf '%s: %s already exists (no such login) — refusing to write into it\n' "$PROG" "$H" >&2
  exit 3
fi

# A full name another login already carries (issue #2210): sysadminctl refuses
# it — "User with full name '…' already exists" — and still exits 0, so step 1
# "passed" and step 3 died on a login that was never made. The same person's
# second login (the hub's relogin) hits it every time: take `<name> (<login>)`.
realname_owner() { # $1 name → the login whose short or full name it is (none: empty)
  dscl . -list /Users RealName 2>/dev/null | awk -v n="$1" '
    { u = $1; r = $0; sub(/^[^ \t]+[ \t]*/, "", r)
      if (u == n || r == n) { print u; exit } }'
}
if [ "$DONLY" = 0 ]; then
  _own=$(realname_owner "$FULL")
  if [ -n "$_own" ]; then
    _alt="$FULL ($LOGIN)"
    [ -z "$(realname_owner "$_alt")" ] || {
      printf '%s: full name %s is login %s'"'"'s, and %s is taken too — refusing (pass another --full-name)\n' \
        "$PROG" "$FULL" "$_own" "$_alt" >&2
      exit 3
    }
    printf '%s: full name %s is already login %s'"'"'s — using %s\n' "$PROG" "$FULL" "$_own" "$_alt" >&2
    FULL=$_alt
  fi
  unset _own _alt
fi

if [ "$APPLY" = 1 ]; then
  if [ "$DONLY" = 1 ]; then NEED='sudo'; else NEED='sudo sysadminctl createhomedir git'; fi
  for t in $NEED; do
    command -v "$t" >/dev/null 2>&1 || { printf '%s: %s not found — nothing was changed\n' "$PROG" "$t" >&2; exit 1; }
  done
  # a managed machine adopts the login at step 8 instead (issue #2775): no plist to render
  if [ "$DAEMONS" = 1 ] && [ -z "$MSHA" ] && ! command -v plutil >/dev/null 2>&1; then
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

# ---- a login the hub opens (issue #2652): its own node, its fleet up --------
# FLEET_LOGIN_JOIN_CODE / FLEET_LOGIN_HUB come from the admin agent (the create
# op's join code), never an argv. Unset ⇒ both steps skip, byte for byte.
NODE_LINE='' FLEET_LINE=''
warn_step() { say "  WARN: $1"; NODE_LINE=${NODE_LINE:-"node: WARN — $1"}; }
node_join_step() {
  [ "$OPENED" = 1 ] || return 0
  N0=$N; N="${N}a"; say ""; say "[$N] join $JHUB as $LOGIN's own node (the hub opened this login: its fleet is seen only through its own agent)"
  local pass="$H/.fleet-join-pass.json" plist="$DDIR/com.ccquota.agent.$LOGIN.plist"
  show curl -sS -X POST --data @'<join code, from the environment, never shown>' "$JHUB/v1/node/join"
  show sudo -u "$LOGIN" -H env FLEET_CONF_DIR="$H/.config/claude-fleet" bash "$ROOT/bin/fleet-node-join.sh" \
    --hub "$JHUB" --joined "$pass" --no-admin --no-deps --no-fleet --service none --compute 1
  show sudo install -m 644 '<com.ccquota.agent.'"$LOGIN"'.plist>' "$plist"
  if [ "$APPLY" != 1 ]; then N=$N0; return 0; fi
  local body="$TMPD/join.body" got="$TMPD/join.json" code
  ( umask 077; printf '{"code":"%s","hostname":"%s","os_user":"%s"}' "$JCODE" "$(hostname -s 2>/dev/null)" "$LOGIN" > "$body" )
  code=$(curl -sS --max-time 30 -o "$got" -w '%{http_code}' -H 'Content-Type: application/json' \
    -X POST --data @"$body" "$JHUB/v1/node/join" 2>/dev/null) || code=000
  rm -f "$body"
  if [ "$code" != 200 ]; then warn_step "the hub did not take the join code (HTTP $code) — the login is open, but not on the hub"; N=$N0; return 0; fi
  # the pass holds the node token: the login's own, 600, gone once read
  if ! { sudo install -m 600 "$got" "$pass" && sudo chown "$LOGIN:staff" "$pass"; }; then
    rm -f "$got"; warn_step "cannot hand $LOGIN its node pass"; N=$N0; return 0
  fi
  rm -f "$got"
  local out rc
  out=$(sudo -u "$LOGIN" -H env FLEET_CONF_DIR="$H/.config/claude-fleet" PATH="$H/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$ROOT/bin/fleet-node-join.sh" --hub "$JHUB" --joined "$pass" --no-admin --no-deps --no-fleet --service none --compute 1 2>&1); rc=$?
  sudo rm -f "$pass"
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" != 0 ]; then warn_step "fleet-node-join.sh exited $rc as $LOGIN"; N=$N0; return 0; fi
  # the agent's definition, not loaded: 7b turns it into the launcher's and
  # starts it; with --no-credsep it is loaded here as it is
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n<!-- fleet-login-new.sh (issue #2652) -->\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>com.ccquota.agent.%s</string>\n  <key>UserName</key><string>%s</string>\n' "$LOGIN" "$LOGIN"
    printf '  <key>ProgramArguments</key>\n  <array><string>%s/.ccquota/run-agent.sh</string></array>\n' "$H"
    printf '  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n'
    printf '  <key>StandardErrorPath</key><string>%s/.ccquota/agent.log</string>\n  <key>StandardOutPath</key><string>%s/.ccquota/agent.log</string>\n' "$H" "$H"
    printf '</dict>\n</plist>\n'; } > "$TMPD/agent.plist"
  if ! sudo install -m 644 "$TMPD/agent.plist" "$plist"; then warn_step "cannot write $plist"; N=$N0; return 0; fi
  if [ "$CREDSEP" = 0 ]; then
    sudo launchctl bootstrap system "$plist" || { warn_step "launchctl bootstrap system $plist"; N=$N0; return 0; }
    NODE_LINE="node: joined $JHUB — its agent runs (com.ccquota.agent.$LOGIN)"
  else
    NODE_LINE="node: joined $JHUB — its agent starts through the credential launcher (next step)"
  fi
  say "  $NODE_LINE"
  N=$N0
}
fleet_up_step() {
  say ""; say "[${N}b] bring $LOGIN's fleet up now, as $LOGIN (fleet-login-bootstrap.sh — no login shell sets it up, issue #2702)"
  show sudo -u "$LOGIN" -H env FLEET_CONF_DIR="$CD" bash "$ROOT/bin/fleet-login-bootstrap.sh"
  [ "$APPLY" = 1 ] || return 0
  local out rc
  out=$(sudo -u "$LOGIN" -H env FLEET_CONF_DIR="$CD" PATH="$H/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$ROOT/bin/fleet-login-bootstrap.sh" </dev/null 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" = 0 ]; then FLEET_LINE='fleet: up (fleet-login-bootstrap.sh)'
  else FLEET_LINE="fleet: WARN — fleet-login-bootstrap.sh exited $rc; re-run: sudo -u $LOGIN -H bash $ROOT/bin/fleet-login-bootstrap.sh"; fi
  say "  $FLEET_LINE"
}

if [ "$DONLY" = 1 ]; then
  if [ "$APPLY" = 1 ]; then
    say "fleet-login-new: installing the background services of existing login '$LOGIN' (step 8 only) — running it:"
  else
    say "fleet-login-new: DRY RUN — nothing below is executed. Re-run with --apply to do it."
  fi
  say "  login=$LOGIN  home=$H  daemons-only=yes (steps 1–7 and 9 skipped)"
  N=7
elif [ "$APPLY" = 1 ]; then
  say "fleet-login-new: creating login '$LOGIN' ($FULL) — running each step:"
else
  say "fleet-login-new: DRY RUN — nothing below is executed. Re-run with --apply to do it."
fi
[ "$DONLY" = 1 ] || say "  login=$LOGIN  full-name=$FULL  home=$H  share-pool=$([ "$SHARE" = 1 ] && echo yes || echo no)  daemons=$([ "$DAEMONS" = 1 ] && echo system || echo 'no (gui, after a GUI sign-in)')  key=$([ "$TMPKEY" = 1 ] && echo 'temporary (generated)' || echo "$PUBKEY")  welcome=$([ "$WELCOME" = 1 ] && echo "$WLANG" || echo no)"
[ "$KEYS" -gt 0 ] || say "  WARN: --pubkey '$PUBKEY' holds no public key line; --apply will refuse it"

# Steps 1–7 open the login; --daemons-only (issue #1223) skips straight to 8.
ROOT="$H/.claude/fleet"
OPMARK="$ONBOARD/op"
if [ "$DONLY" = 0 ] && [ "$APPLY" = 1 ] && [ -n "$OPID" ]; then
  # before anything is made: a login this op makes is known as this op's, even
  # when the run is cut off half way (issue #2928)
  ( umask 077 && mkdir -p "$ONBOARD" \
    && printf 'op=%s\npid=%s\nstarted=%s\n' "$OPID" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OPMARK" ) \
    || { printf '%s: cannot write %s — nothing was changed\n' "$PROG" "$OPMARK" >&2; exit 1; }
fi
if [ "$DONLY" = 0 ]; then
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
  # No password on any argv (issue #2396): `ps` shows every process's argv to
  # every login, and addUser runs for minutes. Created shell-less, the password
  # goes in on dscl's stdin, then the shell is given back.
  run sudo sysadminctl -addUser "$LOGIN" -fullName "$FULL" -shell /usr/bin/false
  # sysadminctl's exit says nothing about whether the login exists (#2210)
  if [ "$APPLY" = 1 ] && ! id "$LOGIN" >/dev/null 2>&1; then
    printf '%s: sysadminctl did not create login %s (see its message above)\n' "$PROG" "$LOGIN" >&2
    fail
  fi
  printf '  $ sudo dscl .   < passwd /Users/%s <redacted: %s>   (on stdin, never argv)\n' "$LOGIN" "$PWFILE"
  if [ "$APPLY" = 1 ]; then
    # interactive dscl: one command per stdin line, the password one plain word
    # (checked above). It exits 0 on a DS error, so its words are the verdict;
    # they never echo the password, redacted anyway.
    DSOUT=$(printf 'passwd /Users/%s %s\n' "$LOGIN" "$PW" | sudo dscl . 2>&1) \
      && ! printf '%s' "$DSOUT" | grep -qi 'error' \
      || { printf '%s: could not set the password of %s: %s\n' "$PROG" "$LOGIN" "${DSOUT//"$PW"/<redacted>}" >&2; fail; }
  fi
  run sudo dscl . -create "/Users/$LOGIN" UserShell /bin/zsh
  step "create its home directory (mode 700 — every login is in staff)"
  run sudo createhomedir -c -u "$LOGIN"
  # macOS's default home is 0750 <login>:staff on some machines (m4, issue
  # #2414) and every login is in staff, so any other login could list ~/.claude,
  # ~/.claude/projects, ~/.codex. Never rely on the default: 700, the mode only
  # — the ACL (`everyone deny delete`) is left as macOS made it.
  run sudo chmod 700 "$H"

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

  if [ "$SHARE" = 1 ] && [ "$CREDSEP" = 1 ]; then
    step "join the shared Claude pool (${#POOL[@]} files from $POOL_SRC)"
    say "  (separated: the tokens go into $LOGIN's credential store in step 7b — never into $H; it gets the label markers only)"
  elif [ "$SHARE" = 1 ]; then
    D="$H/.config/claude-fleet/accounts"
    step "join the shared Claude pool (${#POOL[@]} files from $POOL_SRC — SHARED-MACHINE 2b; --no-credsep: readable by $LOGIN's sessions)"
    DST=()
    for f in ${POOL[@]+"${POOL[@]}"}; do DST+=("$D/${f##*/}"); done
    run sudo mkdir -p "$D"
    run sudo cp -p ${POOL[@]+"${POOL[@]}"} "$D/"
    run sudo chown "$LOGIN:staff" "$H/.config" "$H/.config/claude-fleet"
    run sudo chown -R "$LOGIN:staff" "$D"
    run sudo chmod 700 "$D"
    run sudo chmod 600 ${DST[@]+"${DST[@]}"}
  fi

  step "$LOGIN's .zshrc — the ~/.local/bin PATH line only (no banner, no client on login: issue #2702)"
  ZRC="$TMPD/zshrc"
  BS="$BIN/fleet-login-bootstrap.sh"
  # The PATH line (issue #1191) — unless the file already carries one
  { grep -qF '.local/bin' "$H/.zshrc" 2>/dev/null || bash "$BS" --print-path-line; } > "$ZRC" \
    || { printf '%s: fleet-login-bootstrap.sh --print-path-line failed\n' "$PROG" >&2; exit 1; }
  append "$ZRC" "$H/.zshrc"
  run sudo chown "$LOGIN:staff" "$H/.zshrc"
  run sudo chmod 644 "$H/.zshrc"

  # 7. the install, as the login — its daemons (8) reference ~<login>/.claude/fleet/bin
  if [ -n "$MSHA" ]; then
    step "install claude-fleet for $LOGIN ($ROOT → this machine's runtime $NROOT/$(printf '%.7s' "$MSHA"), as $LOGIN — the services below run its scripts)"
  else
    step "install claude-fleet for $LOGIN (the hub's signed stable, else a clone of stable → $ROOT, as $LOGIN — the services below run its scripts)"
  fi
  run sudo -u "$LOGIN" -H mkdir -p "$H/.claude"
  # The machine's Claude Code cache first (issue #2297): the admin's own binary,
  # copied by root where every login can read it, so the login's first-run Claude
  # install reaches no claude.ai. A note, never a failure.
  if [ "$CDIR" != off ]; then
    CL=$(command -v claude 2>/dev/null) || CL=''
    [ -n "$CL" ] || { [ -x "$HOME/.local/bin/claude" ] && CL="$HOME/.local/bin/claude"; }
    show sudo env FLEET_BOOTSTRAP_CACHE="$CDIR" bash "$CACHE_SH" refresh ${CL:+--claude "$CL"}
    if [ "$APPLY" = 1 ]; then
      sudo env FLEET_BOOTSTRAP_CACHE="$CDIR" bash "$CACHE_SH" refresh ${CL:+--claude "$CL"} 2>&1 | sed 's/^/    /'
    fi
  fi
  # fleet-login-install.sh (issue #2775), staged world-readable: this install
  # lives in the admin's home, which the login cannot read (#1213)
  ISTG="$BIN"
  if [ "$APPLY" = 1 ]; then
    ISTG=$(mktemp -d "${TMPDIR:-/tmp}/fleet-login-install.XXXXXX") && chmod 755 "$ISTG" \
      && cp "$BIN/fleet-login-install.sh" "$BIN/fleet-release-lib.sh" "$BIN/fleet-daemon-lib.sh" \
            "$BIN/fleet-node-update.py" "$BIN/fleet-node-supervisor.py" "$ISTG/" \
      && chmod 644 "$ISTG"/* \
      || { printf '%s: cannot stage fleet-login-install.sh for %s\n' "$PROG" "$LOGIN" >&2; fail; }
  fi
  INS=(sudo -u "$LOGIN" -H env HOME="$H" FLEET_CONF_DIR="$H/.config/claude-fleet" FLEET_NODE_ROOT="$NROOT")
  [ -z "$HUBU" ] || INS+=(FLEET_HUB_URL="$HUBU")
  [ -z "${FLEET_DIST_SOURCE:-}" ] || INS+=(FLEET_DIST_SOURCE="$FLEET_DIST_SOURCE")
  [ -z "${FLEET_BOOTSTRAP_GIT_BASE:-}" ] || INS+=(FLEET_BOOTSTRAP_GIT_BASE="$FLEET_BOOTSTRAP_GIT_BASE")
  INS+=(bash "$ISTG/fleet-login-install.sh" "$ROOT")
  show "${INS[@]}"
  if [ "$APPLY" = 1 ]; then
    if iline=$("${INS[@]}"); then
      rm -rf "$ISTG"
      say "  install: ${iline%% *} — ${iline#* * }"
    else
      rm -rf "$ISTG"; fail
    fi
  fi
  run sudo -u "$LOGIN" -H mkdir -p "$ROOT/logs"

  # 7a. a login the hub opens joins it as its own node (issue #2652) — before
  # 7b, so the token and the agent are separated with everything else
  node_join_step
  # 7b. the subscription out of the login's reach (issue #2294) — before its
  # services (8) and its first session: the proxy first, then the credentials
  CD="$H/.config/claude-fleet"
  if [ "$CREDSEP" = 1 ]; then
    N0=$N; N="${N}b"; say ""; say "[$N] keep the subscription out of $LOGIN's reach (credsep, before any service or session: FLEET_CRED_PROXY=1 + FLEET_CRED_SEPARATE=1, store ${FLEET_CREDSEP_ROOT_BASE:-/var/db/fleet-cred}/$LOGIN$([ "$SHARE" = 1 ] && echo ', the pool inside it'))"
    FC="$TMPD/fleet.conf"
    {
      printf "# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.\n"
      printf '# Credentials never live here: node.env, hub.json (its token), secrets.env and\n'
      printf '# ~/.ssh/fleet-cert are separate, each 0600. Written by fleet-login-new.sh when\n'
      printf '# this login was opened: separated from its first session on (issue #2294).\n'
      printf '\n# ---- [common] ----\n'
      printf 'export FLEET_CRED_PROXY=1\n'
      printf 'export FLEET_CRED_SEPARATE=1\n'
      printf '%s\n' '_fcs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/secrets.env"; [ -f "$_fcs" ] && . "$_fcs"; unset _fcs'
      printf '\n# ---- [client] — only the shell (FLEET_SHELL=1) reads this section ----\n'
      printf '%s\n:\n%s\n' 'if [ "${FLEET_SHELL:-0}" = 1 ]; then' 'fi  # ---- [client] end ----'
      printf '\n# ---- [node] — the shell (FLEET_SHELL=1) does not read this section ----\n'
      printf '%s\n:\n%s\n' 'if [ "${FLEET_SHELL:-0}" != 1 ]; then' 'fi  # ---- [node] end ----'
    } > "$FC"
    run sudo mkdir -p "$CD"
    run sudo chown "$LOGIN:staff" "$H/.config" "$CD"
    run sudo chmod 700 "$CD"
    run_shown "sudo install -m 600 <fleet.conf: [common] export FLEET_CRED_PROXY=1, export FLEET_CRED_SEPARATE=1> $(printf %q "$CD/fleet.conf")" \
      -- sudo install -m 600 "$FC" "$CD/fleet.conf"
    run sudo chown "$LOGIN:staff" "$CD/fleet.conf"
    CS=(sudo bash "$BIN/fleet-credsep.sh" install --login "$LOGIN" --fresh --install-dir "$ROOT")
    [ "$SHARE" = 1 ] && CS+=(--pool-src "$POOL_SRC")
    run "${CS[@]}"
    N=$N0
  fi
fi

# 8. on a managed machine: the machine daemon takes the login (issue #2775) —
# account adopt, which runs its account tasks as it and moves its linked install
# with every switch of the runtime. No per-login LaunchDaemon is rendered.
ADOPTED=0
if [ -n "$MSHA" ] && [ "$DAEMONS" = 1 ]; then
  SUP="$NROOT/current/bin/fleet-node-supervisor.py"
  step "hand $LOGIN to this machine's daemon (account adopt: it runs $LOGIN's background services itself and moves its install with the runtime — no per-login LaunchDaemon)"
  run sudo python3 "$SUP" account adopt "$LOGIN"
  ADOPTED=1
elif [ -n "$MSHA" ]; then
  say ""
  say "  WARN: --no-daemons on a managed machine: $LOGIN's install is linked to the runtime but not adopted — it does not move with the machine until an admin runs: sudo python3 '$NROOT/current/bin/fleet-node-supervisor.py' account adopt $LOGIN"
fi

# 8. the background services, system shape, as the admin
if [ "$DAEMONS" = 1 ] && [ "$ADOPTED" = 0 ]; then
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
      [ "$DONLY" = 0 ] || printf '%s: --daemons-only needs %s'"'"'s own clone at %s — its first login installs it (fleet-login-bootstrap.sh), then re-run this\n' "$PROG" "$LOGIN" "$ROOT" >&2
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
    # The apply script sources fleet-daemon-lib.sh beside itself (the one label /
    # shape rule, #1495), so the clone's lib is staged with it; a clone whose
    # script or lib cannot be read falls back to this install's pair.
    # shellcheck disable=SC2024  # same: read as the login, written here
    sudo -u "$LOGIN" -H cat "$ROOT/bin/fleet-install-apply.sh" > "$APPLY_SH" 2>/dev/null \
      && grep -q -- '--render-system' "$APPLY_SH" \
      && sudo -u "$LOGIN" -H cat "$ROOT/bin/fleet-daemon-lib.sh" > "$STAGE/bin/fleet-daemon-lib.sh" 2>/dev/null \
      || APPLY_SH="$BIN/fleet-install-apply.sh"
  elif [ "$NU" = 0 ]; then
    say "  WARN: no launchd/*.plist.tmpl in $TMPL_DIR — nothing to preview here; --apply reads the clone's (as $LOGIN) and fails on 0"
  fi
  NI=0 NK=0
  for u in $UNITS; do
    label=$(fleet_daemon_label "$u" system "$LOGIN"); dst="$DDIR/$label.plist"; src="$TMPD/plists/$label.plist"
    # --daemons-only fills what is missing (issue #1223): a unit already in
    # place is left alone — a second `launchctl bootstrap` of a loaded label
    # fails, and replacing a live one is the login's own apply's job.
    if [ "$DONLY" = 1 ] && [ -e "$dst" ]; then
      say "  (already in place: $dst — left alone)"
      NK=$((NK + 1)); continue
    fi
    if [ "$APPLY" = 1 ]; then
      FLEET_INSTALL_LOGIN="$LOGIN" FLEET_INSTALL_HOME="$H" bash "$APPLY_SH" --render-system "$u" --root "$STAGE" > "$src" \
        || { printf '%s: render %s failed (%s --render-system)\n' "$PROG" "$u" "$APPLY_SH" >&2; fail; }
    fi
    run_shown "sudo install -m 644 <$label.plist, rendered from launchd/com.claude-fleet.$u.plist.tmpl> $(printf %q "$dst")" \
      -- sudo install -m 644 "$src" "$dst"
    run sudo launchctl bootstrap system "$dst"
    NI=$((NI + 1))
  done
  [ "$APPLY" = 1 ] && say "  installed $((NI + NK))/$NU$([ "$NK" = 0 ] || echo " ($NK already in place)")"
fi

# The verdict of 7b — the ONE judgement (EPIC #2293 convention 1): status
# `separated` AND check OK, read AS the login with its own scripts. Status not
# separated = 7b did not take: the run fails (the hub must not hand this login
# out). Check not OK yet = the proxy still coming up: waited for, then `pending`.
CREDSEP_LINE=''
if [ "$DONLY" = 0 ] && [ "$CREDSEP" = 0 ]; then
  CREDSEP_LINE='credsep: off (--no-credsep — the old layout: the subscription is readable by this login'"'"'s sessions)'
elif [ "$DONLY" = 0 ] && [ "$APPLY" = 1 ]; then
  say ""; say "[check] $LOGIN is separated (fleet-credsep.sh status + check, as $LOGIN — the step 7b verdict)"
  AS=(sudo -u "$LOGIN" -H env FLEET_CONF_DIR="$CD" bash "$ROOT/bin/fleet-credsep.sh")
  show "${AS[@]}" status
  st=$("${AS[@]}" status 2>&1)
  say "  $st"
  case "$st" in
    separated*) ;;
    *) printf '%s: %s is NOT separated after step 7b (%s) — stopped: do not hand this login out\n' "$PROG" "$LOGIN" "$st" >&2
       say "credsep: not separated"; exit 1 ;;
  esac
  wait=${FLEET_LOGIN_CREDSEP_WAIT:-15}; t=0
  while :; do
    ck=$("${AS[@]}" check 2>&1); rc=$?
    [ "$rc" = 0 ] && break
    [ "$t" -ge "$wait" ] && break
    sleep 1; t=$((t + 1))
  done
  show "${AS[@]}" check
  say "  $ck"
  if [ "$rc" = 0 ]; then CREDSEP_LINE='credsep: separated'
  else CREDSEP_LINE="credsep: pending — $ck"; fi
elif [ "$DONLY" = 0 ]; then
  CREDSEP_LINE='credsep: (after --apply) separated before its first session'
fi

[ "$DONLY" = 1 ] || fleet_up_step

if [ "$DONLY" = 1 ]; then
  say ""
  if [ "$APPLY" = 1 ]; then
    say "done: $LOGIN's background services are in place — check with: sudo launchctl list | grep -c com.claude-fleet.$LOGIN."
  else
    say "after --apply: $LOGIN's background services run its own ~/.claude/fleet; nothing on its side needs re-running"
  fi
  exit 0
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

   开号时已经替你装好 claude-fleet 和 Claude Code、把你的 fleet 拉起来了。ssh 上来是
   一个普通 shell——这台是托管机器，不在这里开 fleet 客户端（第 5 条）。
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

5. 向导与 fleet

   - fleet 在你自己的电脑上用：装一次客户端（curl -fsSL <入口>/install | sh，入口地址问开号人），
     然后敲 fleet——左边是你的会话，右边接到 $MACHINE 上的那一个。
   - 向导（一个 Claude 会话）会带你走一遍：加自己的仓库 → 提第一个 issue → 看 worker 跑 → 合并 PR。
   - 向导窗口关了、或想再开：在 $MACHINE 的 shell 里 fleet guide
   - 在 $MACHINE 的 shell 里：fleet repo add owner/repo 把一个仓库加进来。
   - 想离开但不关会话：按 tmux 的 prefix 键（默认 Ctrl-b）再按 d；下次敲 fleet 接着用。

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

   claude-fleet and Claude Code are already installed and your fleet is up. An ssh
   login there is a plain shell — this is a managed machine, the fleet client runs
   on your own computer (section 5).
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

5. The guide and fleet

   - fleet runs on your own computer: install the client once (curl -fsSL <hub>/install | sh — ask the admin for the hub address),
     then type fleet — your sessions on the left, the one on $MACHINE on the right.
   - The guide (a Claude session) walks you through: add your own repo → file your first issue → watch the worker → merge the PR.
   - Guide window closed, or want it back: fleet guide, in a shell on $MACHINE
   - In a shell on $MACHINE: fleet repo add owner/repo adds a repo to it.
   - To leave without closing anything: the tmux prefix (Ctrl-b by default), then d; type fleet again to pick up where you left.

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
  say "  claude-fleet + Claude Code were installed for $LOGIN above (step 8b) — no GUI sign-in, no step here"
else
  say "  claude-fleet + Claude Code were installed for $LOGIN above (step 8b); its daemons wait for step 1"
fi
# the hub's detail is the output's tail: a login it opened says whether it is
# on the hub with its fleet up (issue #2652); credsep stays the last line
[ -z "$NODE_LINE" ] || say "$NODE_LINE"
[ -z "$FLEET_LINE" ] || say "$FLEET_LINE"
# last, so the hub's detail (the output's tail) always carries it
say "$CREDSEP_LINE"
if [ "$APPLY" = 1 ] && [ -n "$OPID" ]; then
  # this op's result, for the same op arriving again (issue #2928): the lines
  # the hub reads off the output's tail, credsep last
  { printf 'done=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for l in "$NODE_LINE" "$FLEET_LINE" "$CREDSEP_LINE"; do [ -z "$l" ] || printf 'line=%s\n' "$l"; done
  } >> "$OPMARK" 2>/dev/null || say "  WARN: cannot record the result in $OPMARK"
fi
exit 0
