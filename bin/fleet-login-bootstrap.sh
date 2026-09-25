#!/bin/bash
# fleet-login-bootstrap.sh — a new login sets claude-fleet up for itself, once
# (issue #1165, EPIC #1163 C2). Run AS the new login — by the one-time block
# fleet-login-new.sh writes into its ~/.zshrc, on its first interactive login.
#
# Steps, each skipped when already done (a failed run is re-run on the next login
# and only fills in what is missing):
#
#   install   ~/.claude/fleet — cloned at refs/tags/stable (the hook's clone, or
#             this script's own), on a `master` branch so install-sync can
#             fast-forward it from there.
#   claude    Claude Code, when no `claude` is on PATH (issue #1191): the official
#             native installer (`curl -fsSL https://claude.ai/install.sh | bash`
#             → ~/.local/bin/claude), run as this login; FLEET_CLAUDE_INSTALL_CMD
#             overrides the command (a test seam). ~/.local/bin goes on THIS run's
#             PATH first, so the tmux server fleet-up starts below inherits it.
#   tmux      reapply-tmux-attention.sh (one idempotent source-file line).
#   apply     bin/fleet-install-apply.sh --from <empty tree> --to HEAD: every
#             hook, command, skill and LaunchAgent (install-sync included) is an
#             "addition", so the one apply path installs all of it. On macOS it
#             waits for the login's first GUI sign-in (no gui/<uid> launchd domain
#             before it — agents cannot load); `global/bootstrap.applied` records
#             the sha once it passed, so it never runs twice.
#   zshrc     the claude-fleet block (--print-zshrc) appended to ~/.zshrc unless
#             it already sources shell/fleet-login.zsh — with the ~/.local/bin
#             PATH line (--print-path-line) BEFORE it, unless the file has one.
#   fleet     fleet-up.sh <FLEET_SEED_REPO> --seed --no-attach, when this login
#             has no fleet yet: the starter repo, which only looks (issue #1167).
#             Its checkout is cloned over https first, so no `gh auth` is needed.
#   doctor    fleet-doctor.sh, output passed through — a report, never a gate.
#
# Done ⇔ every step before doctor passed → `$FLEET_CONF_DIR/global/bootstrapped`.
# With that marker it exits 0 at once. A login that already HAS a fleet this
# script did not start (no `global/bootstrap.started`) is left alone: exit 0,
# nothing written.
#
# Not here: ccquota enroll (a hub admin's job), `gh auth login`, the Codex device
# code — fleet-login-new.sh prints those for a human.
#
# Usage:
#   fleet-login-bootstrap.sh              # set this login up (idempotent)
#   fleet-login-bootstrap.sh --print-zshrc        # the one-time block
#   fleet-login-bootstrap.sh --print-path-line    # the ~/.local/bin PATH line
#
# Env: FLEET_SEED_REPO (verkyyi/claude-fleet) · FLEET_INSTALL_ROOT
#      (~/.claude/fleet) · FLEET_CONF_DIR (~/.config/claude-fleet) ·
#      FLEET_BOOTSTRAP_GIT_BASE (https://github.com — test seam) ·
#      FLEET_CLAUDE_INSTALL_CMD (the claude installer — test seam) ·
#      FLEET_INSTALL_PLATFORM / FLEET_INSTALL_LAUNCHCTL (as fleet-install-apply.sh)
# Exit: 0 bootstrapped (now or before) or left alone · 1 a step failed (the
#       lines say which; the next login retries) · 2 usage
set -uo pipefail

PROG=fleet-login-bootstrap
FLEET_REPO_SELF=verkyyi/claude-fleet
SEED="${FLEET_SEED_REPO:-verkyyi/claude-fleet}"
ROOT="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}"
GITBASE="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}"

print_zshrc() {
  cat <<'ZSH'
# >>> claude-fleet (bin/fleet-login-bootstrap.sh, issue #1165) >>>
# First interactive login(s): install claude-fleet and bring the fleet up — until
# it has succeeded once (~/.config/claude-fleet/global/bootstrapped).
if [[ -o interactive ]] && [[ -z "$TMUX" ]] && [[ ! -f ~/.config/claude-fleet/global/bootstrapped ]]; then
  [[ -d ~/.claude/fleet/.git ]] || git clone -q -b stable https://github.com/verkyyi/claude-fleet.git ~/.claude/fleet
  [[ -x ~/.claude/fleet/bin/fleet-login-bootstrap.sh ]] && ~/.claude/fleet/bin/fleet-login-bootstrap.sh
fi
[[ -r ~/.claude/fleet/shell/cw.zsh ]] && source ~/.claude/fleet/shell/cw.zsh
# banner, then an SSH login goes straight into the fleet (issue #1166)
[[ -r ~/.claude/fleet/shell/fleet-login.zsh ]] && source ~/.claude/fleet/shell/fleet-login.zsh
# <<< claude-fleet <<<
ZSH
}
# One line, idempotent (sourced again in every tmux pane's shell), POSIX so it
# reads the same in a .bashrc: Claude Code's native install dir, first on PATH.
print_path_line() {
  printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac  # claude-fleet: Claude Code lives in ~/.local/bin (issue #1191)'
}

case "${1:-}" in
  '') ;;
  --print-zshrc) print_zshrc; exit 0 ;;
  --print-path-line) print_path_line; exit 0 ;;
  -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf '%s: unknown arg %s\n' "$PROG" "$1" >&2; exit 2 ;;
esac

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"
G="$FLEET_CONF_DIR/global"
DONE="$G/bootstrapped" STARTED="$G/bootstrap.started" APPLIED="$G/bootstrap.applied"

say() { printf '%s: %s\n' "$PROG" "$*"; }
FAILS=0
fail() { FAILS=$((FAILS + 1)); say "$1: FAIL $2"; }

[ -f "$DONE" ] && { say "already bootstrapped ($(cat "$DONE" 2>/dev/null)) — nothing to do"; exit 0; }
if [ ! -f "$STARTED" ] && [ -n "$(fleet_each_conf)" ]; then
  say "this login already has a fleet — set up by hand, leaving it alone"
  exit 0
fi
mkdir -p "$G" && { [ -f "$STARTED" ] || date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STARTED"; } \
  || { say "cannot write $G"; exit 1; }

# --- install ------------------------------------------------------------------
if [ -d "$ROOT/.git" ]; then
  say "install: ok — $ROOT is a checkout"
elif [ -e "$ROOT" ]; then
  fail install "$ROOT exists but is not a git checkout — move it aside and log in again"
else
  mkdir -p "$(dirname "$ROOT")"
  if git clone -q -b stable "$GITBASE/$FLEET_REPO_SELF.git" "$ROOT" 2>/dev/null; then
    say "install: cloned $FLEET_REPO_SELF at stable → $ROOT"
  else
    fail install "git clone $GITBASE/$FLEET_REPO_SELF.git failed (offline?)"
  fi
fi
# `clone -b stable` leaves HEAD detached at the tag: name it master (tracking
# origin/master) so install-sync's `merge --ff-only stable` moves a branch.
if [ -d "$ROOT/.git" ] && ! git -C "$ROOT" symbolic-ref -q HEAD >/dev/null; then
  if git -C "$ROOT" checkout -q -B master 2>/dev/null; then
    git -C "$ROOT" branch -q --set-upstream-to=origin/master master 2>/dev/null || true
    say "install: on master at $(git -C "$ROOT" rev-parse --short HEAD)"
  else
    fail install "could not put $ROOT on a master branch"
  fi
fi
[ "$FAILS" = 0 ] || { say "stopped — nothing else can run without the install"; exit 1; }
mkdir -p "$ROOT/logs"

# --- claude -------------------------------------------------------------------
# Claude Code is a per-login native install (~/.local/bin/claude) that nothing
# system-wide provides, and the guide window dies at spawn without it (#1183).
# ~/.local/bin goes on THIS run's PATH first: the check below, the fleet-up further
# down (whose tmux server keeps this PATH for life) and the doctor all see it.
PATH=$(fleet_local_bin_path); export PATH
if cbin=$(command -v claude 2>/dev/null) && [ -n "$cbin" ]; then
  say "claude: ok — $cbin"
else
  cmd="${FLEET_CLAUDE_INSTALL_CMD:-curl -fsSL https://claude.ai/install.sh | bash}"
  out=$(bash -c "$cmd" </dev/null 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" = 0 ] && cbin=$(command -v claude 2>/dev/null) && [ -n "$cbin" ]; then
    say "claude: ok — installed $cbin"
  else
    fail claude "no claude on PATH after \`$cmd\` (rc=$rc — offline?)"
  fi
fi

# --- tmux ---------------------------------------------------------------------
if grep -q 'tmux-attention.conf' "$HOME/.tmux.conf" 2>/dev/null; then
  say "tmux: ok — ~/.tmux.conf already sources the fleet conf"
elif sh "$ROOT/bin/reapply-tmux-attention.sh" >/dev/null 2>&1; then
  say "tmux: ok — ~/.tmux.conf sources the fleet conf"
else
  fail tmux "reapply-tmux-attention.sh failed"
fi

# --- apply --------------------------------------------------------------------
head=$(git -C "$ROOT" rev-parse HEAD)
platform="${FLEET_INSTALL_PLATFORM:-}"
[ -n "$platform" ] || { [ "$(uname -s)" = Darwin ] && platform=launchd; }
if [ -f "$APPLIED" ]; then
  say "apply: ok — applied before ($(cat "$APPLIED"))"
elif [ "$platform" = launchd ] && ! "${FLEET_INSTALL_LAUNCHCTL:-launchctl}" print "gui/$(id -u)" >/dev/null 2>&1; then
  fail apply "no GUI session for $(id -un) yet — sign in once at the console (or Screen Sharing), then log in again"
else
  # The empty tree as a commit: --from it, every file of HEAD is an addition.
  empty=$(GIT_AUTHOR_NAME=fleet GIT_AUTHOR_EMAIL=fleet@localhost \
          GIT_COMMITTER_NAME=fleet GIT_COMMITTER_EMAIL=fleet@localhost \
          git -C "$ROOT" commit-tree "$(git -C "$ROOT" hash-object -t tree -w /dev/null)" -m 'empty (fleet-login-bootstrap)' 2>/dev/null)
  if [ -z "$empty" ]; then
    fail apply "could not make the empty-tree commit in $ROOT"
  elif out=$(bash "$ROOT/bin/fleet-install-apply.sh" --from "$empty" --to "$head" 2>&1); then
    printf '%s\n' "$out" | sed 's/^/    /'
    printf '%s\n' "$head" > "$APPLIED"
    say "apply: ok — installed at ${head:0:7}"
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    fail apply "fleet-install-apply.sh did not pass (lines above)"
  fi
fi

# --- zshrc --------------------------------------------------------------------
# The PATH line goes BEFORE the block (issue #1191): the block's bootstrap call,
# and the fleet-up it runs, must already see ~/.local/bin. A file that has the
# block but no PATH line (a login opened before #1191) gets the line at the top;
# a PATH line of the login's own is kept, never doubled.
zrc="$HOME/.zshrc"
has_block=0; grep -q 'fleet-login\.zsh' "$zrc" 2>/dev/null && has_block=1
has_path=0;  grep -qF '.local/bin' "$zrc" 2>/dev/null && has_path=1
if [ "$has_block" = 1 ] && [ "$has_path" = 1 ]; then
  say "zshrc: ok — ~/.zshrc already sources fleet-login.zsh"
elif [ "$has_block" = 1 ]; then
  if { print_path_line; cat "$zrc"; } > "$zrc.tmp.$$" && cat "$zrc.tmp.$$" > "$zrc"; then
    rm -f "$zrc.tmp.$$"
    say "zshrc: ok — put the ~/.local/bin PATH line before the claude-fleet block in ~/.zshrc"
  else
    rm -f "$zrc.tmp.$$"
    fail zshrc "could not write ~/.zshrc"
  fi
elif { [ ! -s "$zrc" ] || printf '\n'; [ "$has_path" = 1 ] || print_path_line; print_zshrc; } >> "$zrc"; then
  if [ "$has_path" = 1 ]; then
    say "zshrc: ok — added the claude-fleet block to ~/.zshrc"
  else
    say "zshrc: ok — added the ~/.local/bin PATH line + the claude-fleet block to ~/.zshrc"
  fi
else
  fail zshrc "could not write ~/.zshrc"
fi

# --- fleet --------------------------------------------------------------------
if lf=$(fleet_login_fleet) && [ -n "$lf" ]; then
  say "fleet: ok — '$lf' is configured"
else
  seed_dir="$HOME/projects/${SEED##*/}"
  if [ ! -e "$seed_dir" ]; then
    mkdir -p "$(dirname "$seed_dir")"
    git clone -q "$GITBASE/$SEED.git" "$seed_dir" 2>/dev/null \
      || fail fleet "git clone $GITBASE/$SEED.git failed"
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

# --- done? --------------------------------------------------------------------
if [ "$FAILS" = 0 ]; then
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$DONE"
  say "bootstrapped — marked $DONE"
fi

# --- doctor (a report, not a gate) ---------------------------------------------
say "doctor:"
bash "$ROOT/bin/fleet-doctor.sh" 2>&1 | sed 's/^/    /'

[ "$FAILS" = 0 ] || { say "$FAILS step(s) failed — fixed on the next login, or re-run: $ROOT/bin/fleet-login-bootstrap.sh"; exit 1; }
exit 0
