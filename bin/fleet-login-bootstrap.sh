#!/bin/bash
# fleet-login-bootstrap.sh — a new login sets claude-fleet up for itself, once
# (issue #1165, EPIC #1163 C2). Run AS the new login — by fleet-login-new.sh
# right after it opens the login (issue #2702: no ~/.zshrc block runs it on a
# first SSH login any more — a fleet machine is no one's client).
#
# Steps, each skipped when already done (a failed run is re-run by hand and only
# fills in what is missing):
#
#   install   ~/.claude/fleet — bin/fleet-login-install.sh, the ONE install road
#             of a login's first minute (issue #2775, EPIC #2770 C5): this
#             machine's runtime when it is managed (a tree of links into
#             <root>/current — no fetch), else the hub's signed stable (one local
#             commit on master), else — a developer's machine with neither — a
#             clone of stable on a `master` branch. Never the old bootstrap
#             mirror, never GitHub while a runtime or a hub has the version. The
#             line names the source: runtime · hub · git (or present: made
#             already, by fleet-login-new.sh's step 7).
#   claude    Claude Code, when no `claude` is on PATH (issue #1191): the admin's
#             own binary from this machine's cache (fleet-bootstrap-cache.sh
#             claude, issue #2297) when there is one, else the official
#             native installer (`curl -fsSL https://claude.ai/install.sh | bash`
#             → ~/.local/bin/claude), run as this login; FLEET_CLAUDE_INSTALL_CMD
#             overrides the command (a test seam). ~/.local/bin goes on THIS run's
#             PATH first, so the tmux server fleet-up starts below inherits it.
#   tmux      reapply-tmux-attention.sh (one idempotent source-file line).
#   apply     bin/fleet-install-apply.sh --from <empty tree> --to HEAD (a tree
#             linked to the runtime: --tree-from <an empty dir> --tree-to it): every
#             hook, command, skill and LaunchAgent (install-sync included) is an
#             "addition", so the one apply path installs all of it. Where this
#             login's daemons can go decides HOW it runs, never whether (issue
#             #1214): on macOS a login whose daemons fleet-login-new.sh --apply
#             already installed as system LaunchDaemons
#             (/Library/LaunchDaemons/com.claude-fleet.<login>.*, issue #1192)
#             applies at once and finds them current — no GUI session needed; a
#             login with a gui/<uid> launchd domain (it has signed in at the
#             console) gets gui LaunchAgents loaded into it; a login with NEITHER
#             — SSH-only, and the admin's step 8 installed nothing (#1210 ①②) —
#             still gets every hook, command, skill and setting (apply
#             --no-daemons), and its daemons are one `daemons: WARN` line naming
#             who installs them, never a failed step. `global/bootstrap.applied`
#             records the sha once it passed, so it never runs twice.
#   zshrc     the ~/.local/bin PATH line (--print-path-line) in ~/.zshrc, unless
#             the file has one — and nothing else (issue #2702: no banner, no
#             client on login, no cw.zsh; a block an older login still carries is
#             fleet-node-shell-retire.sh's to take out).
#   onboard   seed Claude's first-run theme + onboarding state, and append only
#             the wizard's commands to ~/.claude/settings.json permissions.allow.
#   fleet     fleet-up.sh <FLEET_SEED_REPO> --seed --no-attach, when this login
#             has no fleet yet: the starter repo, which only looks (issue #1167).
#             When the starter is claude-fleet itself (the default) its checkout
#             is made from the install just put here — a local clone of it, or of
#             the runtime's tree as one commit — with origin pointed at GitHub for
#             later work but not fetched (issue #2775); any other starter is the
#             person's own repo, cloned over https, so no `gh auth` is needed.
#   doctor    fleet-doctor.sh, output passed through — a report, never a gate.
#
# Every step is timed: one `timing:` line at the end, and the same in
# `$FLEET_CONF_DIR/global/bootstrap.timing` — `<UTC> source=<s> total=<n>s
# install=<n>s claude=… doctor=<n>s` (install's source and seconds from
# global/bootstrap.install when fleet-login-new.sh made it — the 60-second
# measure of issue #2268 starts at its step 7).
#
# Done ⇔ every step before doctor passed → `$FLEET_CONF_DIR/global/bootstrapped`
# — the commands and skills are in and the fleet is up; missing daemons are a
# WARN, not a step (the doctor's `onboard` row keeps naming them, and the WARN
# says who installs them). With that marker it exits 0 at once. A login that
# already HAS a fleet this script did not start (no `global/bootstrap.started`)
# is left alone: exit 0, nothing written.
#
# Not here: ccquota enroll (a hub admin's job), `gh auth login`, the Codex device
# code — fleet-login-new.sh prints those for a human.
#
# Usage:
#   fleet-login-bootstrap.sh              # set this login up (idempotent)
#   fleet-login-bootstrap.sh --print-path-line    # the ~/.local/bin PATH line
#
# Env: FLEET_SEED_REPO (verkyyi/claude-fleet) · FLEET_INSTALL_ROOT
#      (~/.claude/fleet) · FLEET_CONF_DIR (~/.config/claude-fleet) ·
#      FLEET_NODE_ROOT · FLEET_HUB_URL · FLEET_DIST_SOURCE · FLEET_BOOTSTRAP_GIT_BASE
#      (fleet-login-install.sh's) ·
#      FLEET_CLAUDE_INSTALL_CMD (the claude installer — test seam) ·
#      FLEET_INSTALL_PLATFORM / FLEET_INSTALL_LAUNCHCTL / FLEET_INSTALL_DAEMON_DIR /
#      FLEET_INSTALL_LOGIN (as fleet-install-apply.sh)
# Exit: 0 bootstrapped (now or before) or left alone · 1 a step failed (the
#       lines say which; re-run it) · 2 usage
set -uo pipefail

PROG=fleet-login-bootstrap
FLEET_REPO_SELF=verkyyi/claude-fleet
SEED="${FLEET_SEED_REPO:-verkyyi/claude-fleet}"
ROOT="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}"
GITBASE="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}"  # dist-ok: the starter's origin URL, written, never fetched here; another starter is the person's repo

# One line, idempotent (sourced again in every tmux pane's shell), POSIX so it
# reads the same in a .bashrc: Claude Code's native install dir, first on PATH.
print_path_line() {
  printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac  # claude-fleet: Claude Code lives in ~/.local/bin (issue #1191)'
}

case "${1:-}" in
  '') ;;
  --print-path-line) print_path_line; exit 0 ;;
  -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf '%s: unknown arg %s\n' "$PROG" "$1" >&2; exit 2 ;;
esac

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"
G="$FLEET_CONF_DIR/global"
CACHE_SH="$BIN/fleet-bootstrap-cache.sh"
DONE="$G/bootstrapped" STARTED="$G/bootstrap.started" APPLIED="$G/bootstrap.applied"

say() { printf '%s: %s\n' "$PROG" "$*"; }
FAILS=0
fail() { FAILS=$((FAILS + 1)); say "$1: FAIL $2"; }
# Each step timed (issue #2775): milliseconds where python3 is (every machine
# this runs on), whole seconds otherwise; `<step>=<s.t>s` collected in TIMES.
ms() { PYTHONDONTWRITEBYTECODE=1 python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo $(( $(date +%s) * 1000 )); }
secs() { printf '%d.%ds' $(( $1 / 1000 )) $(( $1 % 1000 / 100 )); }
TIMES='' T_ALL=0 _t0=0
step_begin() { _t0=$(ms); }
step_end() { TIMES="$TIMES $1=$(secs $(( $(ms) - _t0 )))"; }

[ -f "$DONE" ] && { say "already bootstrapped ($(cat "$DONE" 2>/dev/null)) — nothing to do"; exit 0; }
if [ ! -f "$STARTED" ] && [ -n "$(fleet_each_conf)" ]; then
  say "this login already has a fleet — set up by hand, leaving it alone"
  exit 0
fi
mkdir -p "$G" && { [ -f "$STARTED" ] || date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STARTED"; } \
  || { say "cannot write $G"; exit 1; }
T_ALL=$(ms)   # after the two ways out above, which write nothing — not even a python cache

# --- install ------------------------------------------------------------------
# One road for a login's first install (issue #2775): fleet-login-install.sh —
# the runtime, else the hub, else a clone. Its line: `<source> <sha> <what>`.
step_begin
SRC='' ISHA=''
ierr="$G/.install.err.$$"
if line=$(bash "$BIN/fleet-login-install.sh" "$ROOT" 2>"$ierr" </dev/null); then
  sed 's/^/    /' "$ierr"
  read -r SRC ISHA what <<EOF
$line
EOF
  if [ "$SRC" = present ]; then say "install: ok — $ROOT is there already ($what, ${ISHA:0:7})"
  else say "install: ok — from the $SRC: $what → $ROOT"; fi
else
  sed 's/^/    /' "$ierr"
  fail install "fleet-login-install.sh made no $ROOT (the lines above say why)"
fi
rm -f "$ierr"
step_end install
LINKED=''
[ -d "$ROOT/.git" ] || LINKED=$(cd "$ROOT" 2>/dev/null && pwd -P)
[ "$FAILS" = 0 ] || { say "stopped — nothing else can run without the install"; exit 1; }
mkdir -p "$ROOT/logs"

# --- claude -------------------------------------------------------------------
# Claude Code is a per-login native install (~/.local/bin/claude) that nothing
# system-wide provides, and the guide window dies at spawn without it (#1183).
# ~/.local/bin goes on THIS run's PATH first: the check below, the fleet-up further
# down (whose tmux server keeps this PATH for life) and the doctor all see it.
PATH=$(fleet_local_bin_path); export PATH
step_begin
if cbin=$(command -v claude 2>/dev/null) && [ -n "$cbin" ]; then
  say "claude: ok — $cbin"
else
  cmd="${FLEET_CLAUDE_INSTALL_CMD:-curl -fsSL https://claude.ai/install.sh | bash}"
  # the admin's own Claude Code, cached on this machine, before claude.ai (issue #2297)
  if out=$(bash "$CACHE_SH" claude </dev/null 2>&1); then cmd="$CACHE_SH claude"; rc=0
  else out=$(bash -c "$cmd" </dev/null 2>&1); rc=$?
  fi
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" = 0 ] && cbin=$(command -v claude 2>/dev/null) && [ -n "$cbin" ]; then
    say "claude: ok — installed $cbin"
  else
    fail claude "no claude on PATH after \`$cmd\` (rc=$rc — offline?)"
  fi
fi
step_end claude

# --- tmux ---------------------------------------------------------------------
step_begin
if grep -q '^[[:space:]]*[^#[:space:]].*tmux-attention\.conf' "$HOME/.tmux.conf" 2>/dev/null; then
  say "tmux: ok — ~/.tmux.conf already sources the fleet conf"
elif sh "$ROOT/bin/reapply-tmux-attention.sh" >/dev/null 2>&1; then
  say "tmux: ok — ~/.tmux.conf sources the fleet conf"
else
  fail tmux "reapply-tmux-attention.sh failed"
fi
step_end tmux

# --- apply --------------------------------------------------------------------
step_begin
if [ -n "$LINKED" ]; then head=$ISHA; else head=$(git -C "$ROOT" rev-parse HEAD); fi
platform="${FLEET_INSTALL_PLATFORM:-}"
[ -n "$platform" ] || { [ "$(uname -s)" = Darwin ] && platform=launchd; }
# Where this login's daemons can go decides HOW apply runs, never WHETHER (issue
# #1214). System-shape daemons the admin installed (fleet-login-new.sh --apply,
# issue #1192): apply keeps that shape, loads nothing into gui/<uid>, and finds
# every unit current. A gui/<uid> launchd domain (a console sign-in happened):
# apply loads gui LaunchAgents into it. NEITHER, on launchd — an SSH-only login
# whose admin-side step 8 installed nothing (#1210 ①②): the tools still install
# (apply --no-daemons) and the daemons are the WARN below. Until #1214 that case
# was `apply: FAIL no GUI session`, so no command or skill landed and the guide's
# first words were «Unknown command: /fleet-onboard».
login="${FLEET_INSTALL_LOGIN:-${USER:-$(id -un)}}"
sysd=0
# the shape rule is fleet-daemon-lib.sh's (issue #1495) — the one apply keeps by
# shellcheck source=/dev/null
. "$BIN/fleet-daemon-lib.sh"
[ "$(fleet_daemon_shape "$login")" = system ] && sysd=1
nodaemons=''
if [ "$platform" = launchd ] && [ "$sysd" = 0 ] && ! "${FLEET_INSTALL_LAUNCHCTL:-launchctl}" print "gui/$(id -u)" >/dev/null 2>&1; then
  nodaemons=1
fi
if [ -f "$APPLIED" ]; then
  say "apply: ok — applied before ($(cat "$APPLIED"))"
else
  [ "$sysd" = 1 ] && say "apply: system LaunchDaemons com.claude-fleet.$login.* are installed — no GUI sign-in needed"
  if [ -n "$LINKED" ]; then
    # a tree linked to the runtime has no git (issue #2774): --tree-from an empty
    # directory, every file of the version is an addition — the same apply
    empty="$G/.empty-tree"; rm -rf "$empty"; mkdir -p "$empty" || empty=''
    set -- --tree-from "$empty" --tree-to "$LINKED" --root "$ROOT" --from none --to "$head"
  else
    # The empty tree as a commit: --from it, every file of HEAD is an addition.
    empty=$(GIT_AUTHOR_NAME=fleet GIT_AUTHOR_EMAIL=fleet@localhost \
            GIT_COMMITTER_NAME=fleet GIT_COMMITTER_EMAIL=fleet@localhost \
            git -C "$ROOT" commit-tree "$(git -C "$ROOT" hash-object -t tree -w /dev/null)" -m 'empty (fleet-login-bootstrap)' 2>/dev/null)
    set -- --from "$empty" --to "$head"
  fi
  if [ -z "$empty" ]; then
    fail apply "could not make the empty tree to apply from in $ROOT"
  elif out=$(bash "$ROOT/bin/fleet-install-apply.sh" "$@" ${nodaemons:+--no-daemons} 2>&1); then
    printf '%s\n' "$out" | sed 's/^/    /'
    printf '%s\n' "$head" > "$APPLIED"
    if [ -n "$nodaemons" ]; then
      say "apply: ok — installed at ${head:0:7} (hooks, commands, skills, settings — the daemons are the line below)"
    else
      say "apply: ok — installed at ${head:0:7}"
    fi
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    fail apply "fleet-install-apply.sh did not pass (lines above)"
  fi
  [ -z "$LINKED" ] || rm -rf "$G/.empty-tree"
fi
step_end apply
# The daemons, when apply could not place them: a WARN that names who installs
# them, never a failed step — the commands and the guide work without them, and
# a step that fails here is what kept every tool out (#1210 ②).
if [ -n "$nodaemons" ]; then
  t='~'   # the two markers, ~-relative, for the human reading the line
  say "daemons: WARN — not installed: no system LaunchDaemons com.claude-fleet.$login.* and no GUI session for $login (no gui/$(id -u) launchd domain). The commands and the guide work without them; the background services (dash refresh, cleanup, dispatch, install-sync, …) do not run until an admin installs them for $login — \`~/.claude/fleet/bin/fleet-login-new.sh $login --daemons-only --apply\` (docs/SHARED-MACHINE.md «Add the daemons to an existing login») — or you sign in once at the console (or Screen Sharing), then \`rm -f ${APPLIED/#$HOME/$t} ${DONE/#$HOME/$t}\` and log in again"
fi

# --- zshrc --------------------------------------------------------------------
# The ~/.local/bin PATH line only (issues #1191, #2702); a PATH line of the
# login's own is kept, never doubled.
step_begin
zrc="$HOME/.zshrc"
if grep -qF '.local/bin' "$zrc" 2>/dev/null; then
  say "zshrc: ok — ~/.zshrc already puts ~/.local/bin on PATH"
elif { [ ! -s "$zrc" ] || printf '\n'; print_path_line; } >> "$zrc"; then
  say "zshrc: ok — added the ~/.local/bin PATH line to ~/.zshrc"
else
  fail zshrc "could not write ~/.zshrc"
fi
step_end zshrc

# --- onboarding defaults ------------------------------------------------------
step_begin
if out=$(python3 "$ROOT/bin/fleet-onboard-defaults.py" "$HOME" 2>&1); then
  say "$out"
else
  fail onboard "$out"
fi
step_end onboard

# --- fleet --------------------------------------------------------------------
step_begin
if lf=$(fleet_login_fleet) && [ -n "$lf" ]; then
  say "fleet: ok — '$lf' is configured"
else
  seed_dir="$HOME/projects/${SEED##*/}"
  if [ ! -e "$seed_dir" ]; then
    mkdir -p "$(dirname "$seed_dir")"
    if [ "$SEED" = "$FLEET_REPO_SELF" ]; then
      # The starter is claude-fleet itself (the default): its checkout comes from
      # the install just put here, never a second download (issue #2775) — a
      # local clone of a checkout, or the runtime's tree as one commit; origin
      # names GitHub for the work done there later, but nothing fetches it now.
      if [ -z "$LINKED" ]; then
        git clone -q "$ROOT" "$seed_dir" 2>/dev/null </dev/null \
          && git -C "$seed_dir" remote set-url origin "$GITBASE/$SEED.git" \
          || { rm -rf "$seed_dir"; fail fleet "could not clone the starter from $ROOT"; }
      else
        # the runtime's own release dir, so the files are files, not links into it
        rel=$(sed -n 's/.*"root": *"\([^"]*\)".*/\1/p' "$LINKED/.fleet-linked" 2>/dev/null)
        if [ -n "$rel" ] && [ -d "$rel/$ISHA" ] && git init -q "$seed_dir" 2>/dev/null \
           && ( cd "$rel/$ISHA" && GIT_DIR="$seed_dir/.git" GIT_WORK_TREE="$rel/$ISHA" \
                git -c "safe.directory=$rel/$ISHA" -c core.autocrlf=false add -A -f -- . ':(exclude).release' ':(exclude)tools' ) >/dev/null 2>&1 </dev/null \
           && GIT_AUTHOR_NAME=fleet-release GIT_AUTHOR_EMAIL=fleet-release@localhost \
              GIT_COMMITTER_NAME=fleet-release GIT_COMMITTER_EMAIL=fleet-release@localhost \
              git -C "$seed_dir" commit -q --no-verify -m "fleet-release: $ISHA (this machine's runtime)" >/dev/null 2>&1 </dev/null \
           && git -C "$seed_dir" checkout -q -B master 2>/dev/null \
           && git -C "$seed_dir" checkout -q -- . 2>/dev/null \
           && git -C "$seed_dir" remote add origin "$GITBASE/$SEED.git"; then
          :
        else
          rm -rf "$seed_dir"; fail fleet "could not make the starter's checkout from the runtime (${rel:-?}/$ISHA)"
        fi
      fi
    else
      git clone -q "$GITBASE/$SEED.git" "$seed_dir" 2>/dev/null \
        || fail fleet "git clone $GITBASE/$SEED.git failed"
    fi
  fi
  if [ -d "$seed_dir/.git" ]; then
    if out=$(bash "$ROOT/bin/fleet-up.sh" "$SEED" "$seed_dir" --seed --no-attach </dev/null 2>&1); then
      printf '%s\n' "$out" | sed 's/^/    /'
      say "fleet: ok — up on the starter repo $SEED (looks only; add your own with fleet-up.sh <owner/repo>)"
    else
      printf '%s\n' "$out" | sed 's/^/    /'
      fail fleet "fleet-up.sh $SEED failed"
    fi
  fi
fi
step_end fleet

# --- done? --------------------------------------------------------------------
if [ "$FAILS" = 0 ]; then
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$DONE"
  say "bootstrapped — marked $DONE"
fi

# --- doctor (a report, not a gate) ---------------------------------------------
step_begin
say "doctor:"
bash "$ROOT/bin/fleet-doctor.sh" 2>&1 | sed 's/^/    /'
step_end doctor

# --- timing (issue #2775) -------------------------------------------------------
# install's source and seconds: the made install's record when fleet-login-new.sh
# made it before this run (step 7 — where the 60-second measure starts)
irec=$(cat "$G/bootstrap.install" 2>/dev/null)
isrc=$(printf '%s' "$irec" | awk '{print $1}'); isecs=$(printf '%s' "$irec" | awk '{print $3}')
case "$isecs" in ''|*[!0-9]*) isecs=0 ;; esac
[ "$SRC" = present ] || isecs=0
tot=$(( $(ms) - T_ALL + isecs * 1000 ))
[ "$SRC" = present ] && TIMES=$(printf '%s' "$TIMES" | sed "s/ install=[^ ]*/ install=${isecs}.0s/")
tline="$(date -u '+%Y-%m-%dT%H:%M:%SZ') source=${isrc:-${SRC:-unknown}} total=$(secs "$tot")$TIMES"
printf '%s\n' "$tline" > "$G/bootstrap.timing" 2>/dev/null
say "timing: $tline"

[ "$FAILS" = 0 ] || { say "$FAILS step(s) failed — re-run: $ROOT/bin/fleet-login-bootstrap.sh"; exit 1; }
exit 0
