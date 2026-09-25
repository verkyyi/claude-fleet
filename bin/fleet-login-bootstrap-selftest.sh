#!/bin/bash
# fleet-login-bootstrap-selftest.sh — a new login sets itself up (issue #1165),
# in a fake HOME against a local fixture "GitHub" (FLEET_BOOTSTRAP_GIT_BASE):
#   A. first run: install cloned at `stable` (not master's tip) and on a master
#      branch; apply --from an EMPTY-tree commit --to HEAD; tmux line; the zshrc
#      block once; fleet-up <seed> <checkout> --seed --no-attach, the seed checkout
#      cloned first; doctor output passed through; `global/bootstrapped` written.
#   B. second run: exit 0, nothing called, not one file in HOME changed.
#   C. a HOME that already has a fleet (set up by hand): exit 0, nothing called,
#      not one file changed — not even the zshrc it lacks.
#   D. a failed apply: exit 1, no marker, the other steps still done; the next run
#      re-applies only (fleet-up not called again, the zshrc block still once).
#   E. launchd with no GUI session yet: apply is not attempted, says why, exit 1.
#   F. --print-zshrc parses as zsh; its guard names the marker the script writes.
# Every step past the clone is a stub in the fixture repo's bin/ that logs its
# argv — the real scripts have their own selftests.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
BASH_BIN=/bin/bash; [ -x "$BASH_BIN" ] || BASH_BIN=bash

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-login-bootstrap-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ;; *) fail "$1: [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1: [$3] unexpectedly in: $2" ;; esac; }
leg()  { if [ "$FAILS" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; _legf=$FAILS; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset TMUX TMUX_PANE FLEET_INSTALL_ROOT FLEET_SEED_REPO FLEET_INSTALL_LAUNCHCTL
CALLS="$WORK/calls"; export CALLS

# ---- the fixture GitHub: verkyyi/claude-fleet with stubs, stable one behind master ----
FX="$WORK/fx"; mkdir -p "$FX/bin" "$FX/shell"
stub() { # stub <name> <body…> — logs "<name> <argv>" to $CALLS, then runs <body>
  local n="$1"; shift
  { printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "$CALLS"\n' "$n"; printf '%s\n' "$@"; } > "$FX/bin/$n"
  chmod +x "$FX/bin/$n"
}
stub fleet-install-apply.sh 'echo "apply: stub"; exit "${APPLY_RC:-0}"'
stub reapply-tmux-attention.sh 'echo "source-file ~/.claude/fleet/conf/tmux-attention.conf" >> "$HOME/.tmux.conf"'
stub fleet-up.sh 'mkdir -p "$FLEET_CONF_DIR/fleets/fleet" && printf "FLEET_REPO=\"%s\"\n" "$1" > "$FLEET_CONF_DIR/fleets/fleet/conf"; echo "fleet-up: stub up"'
stub fleet-doctor.sh 'echo "PASS doctor-stub all green"'
echo '# stub' > "$FX/shell/fleet-login.zsh"
git init -q -b master "$FX" && git -C "$FX" add -A && git -C "$FX" commit -qm stable-one
git -C "$FX" tag stable
STABLE=$(git -C "$FX" rev-parse HEAD)
echo later > "$FX/later" && git -C "$FX" add later && git -C "$FX" commit -qm master-tip
GB="$WORK/gh"; mkdir -p "$GB/verkyyi"
git clone -q --bare "$FX" "$GB/verkyyi/claude-fleet.git"
export FLEET_BOOTSTRAP_GIT_BASE="$GB" FLEET_INSTALL_PLATFORM=none

newhome() { # newhome <dir> — a fresh login: HOME + its conf dir
  export HOME="$1" FLEET_CONF_DIR="$1/.config/claude-fleet"
  mkdir -p "$HOME"; : > "$CALLS"
}
boot() { "$BASH_BIN" "$BIN/fleet-login-bootstrap.sh" "$@" </dev/null 2>&1; }
# every path + content hash + mtime under HOME (git internals included)
snap() { ( cd "$HOME" || exit 1; find . -print | sort
           { find . -type f -exec stat -c '%n %Y %s' {} + 2>/dev/null || find . -type f -exec stat -f '%N %m %z' {} +; } | sort
           find . -type f -exec cksum {} + | sort ); }

# ---- A. first run ----
newhome "$WORK/a"
out=$(boot); rc=$?
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '%s\n' "$out"
eq "A rc" "$rc" 0
R="$HOME/.claude/fleet"
eq "A install at stable, not master's tip" "$(git -C "$R" rev-parse HEAD)" "$STABLE"
eq "A install on master" "$(git -C "$R" symbolic-ref --short HEAD 2>/dev/null)" master
eq "A master tracks origin/master" "$(git -C "$R" rev-parse --abbrev-ref 'master@{upstream}' 2>/dev/null)" origin/master
ap=$(grep '^fleet-install-apply.sh ' "$CALLS")
from=$(printf '%s' "$ap" | sed -n 's/.*--from \([0-9a-f]*\) .*/\1/p')
eq "A apply --to HEAD" "${ap##*--to }" "$STABLE"
eq "A apply --from the empty tree" "$(git -C "$R" rev-parse "$from^{tree}" 2>/dev/null)" 4b825dc642cb6eb9a060e54bf8d69288fbee4904
eq "A applied stamp" "$(cat "$FLEET_CONF_DIR/global/bootstrap.applied" 2>/dev/null)" "$STABLE"
eq "A tmux line once" "$(grep -c tmux-attention.conf "$HOME/.tmux.conf")" 1
eq "A zshrc = the block" "$(cat "$HOME/.zshrc")" "$(boot --print-zshrc)"
eq "A fleet-up quiet + no attach" "$(grep '^fleet-up.sh ' "$CALLS")" \
  "fleet-up.sh verkyyi/claude-fleet $HOME/projects/claude-fleet --seed --no-attach"
eq "A seed checkout cloned" "$(git -C "$HOME/projects/claude-fleet" rev-parse --is-inside-work-tree 2>/dev/null)" true
has "A doctor passed through" "$out" "    PASS doctor-stub all green"
[ -s "$FLEET_CONF_DIR/global/bootstrapped" ] || fail "A: no global/bootstrapped"
leg "A first run installs everything, fleet-up --seed --no-attach"

# ---- B. second run: zero changes ----
before=$(snap); : > "$CALLS"
out=$(boot); eq "B rc" "$?" 0
has "B says done" "$out" "already bootstrapped"
eq "B nothing called" "$(cat "$CALLS")" ""
eq "B HOME byte-identical" "$(snap)" "$before"
leg "B second run changes nothing"

# ---- C. a HOME with a hand-made fleet ----
newhome "$WORK/c"
mkdir -p "$FLEET_CONF_DIR/fleets/mine" && echo 'FLEET_REPO="me/mine"' > "$FLEET_CONF_DIR/fleets/mine/conf"
echo '# mine' > "$HOME/.zshrc"
before=$(snap)
out=$(boot); eq "C rc" "$?" 0
has "C says so" "$out" "already has a fleet"
eq "C nothing called" "$(cat "$CALLS")" ""
eq "C HOME byte-identical" "$(snap)" "$before"
[ -e "$HOME/.claude" ] && fail "C: cloned into a hand-made login"
leg "C an existing fleet is left alone"

# ---- D. apply fails, the next run fills in only that ----
newhome "$WORK/d"
out=$(APPLY_RC=1 boot); eq "D rc" "$?" 1
has "D names the step" "$out" "apply: FAIL"
[ -e "$FLEET_CONF_DIR/global/bootstrapped" ] && fail "D: marked done after a failed apply"
[ -e "$FLEET_CONF_DIR/global/bootstrap.applied" ] && fail "D: apply stamped after failing"
eq "D fleet still up" "$(grep -c '^fleet-up.sh ' "$CALLS")" 1
eq "D zshrc block still written" "$(grep -c '>>> claude-fleet' "$HOME/.zshrc")" 1
: > "$CALLS"
out=$(boot); eq "D re-run rc" "$?" 0
eq "D re-run: apply + doctor only" "$(awk '{print $1}' "$CALLS" | tr '\n' ' ')" "fleet-install-apply.sh fleet-doctor.sh "
eq "D zshrc block still once" "$(grep -c '>>> claude-fleet' "$HOME/.zshrc")" 1
eq "D tmux line still once" "$(grep -c tmux-attention.conf "$HOME/.tmux.conf")" 1
[ -s "$FLEET_CONF_DIR/global/bootstrapped" ] || fail "D: re-run did not mark done"
leg "D a failed step is retried alone"

# ---- E. macOS before the first GUI sign-in ----
newhome "$WORK/e"
out=$(FLEET_INSTALL_PLATFORM=launchd FLEET_INSTALL_LAUNCHCTL=false boot); eq "E rc" "$?" 1
has "E says why" "$out" "no GUI session"
grep -q '^fleet-install-apply.sh ' "$CALLS" && fail "E: apply ran with no gui domain"
[ -e "$FLEET_CONF_DIR/global/bootstrapped" ] && fail "E: marked done"
leg "E no GUI session → apply waits"

# ---- F. the zshrc block ----
z=$(boot --print-zshrc)
if command -v zsh >/dev/null 2>&1; then
  printf '%s\n' "$z" | zsh -n || fail "F: block does not parse as zsh"
fi
has "F guard = the marker" "$z" '[[ ! -f ~/.config/claude-fleet/global/bootstrapped ]]'
has "F clones stable" "$z" "clone -q -b stable https://github.com/verkyyi/claude-fleet.git"
has "F sources fleet-login.zsh" "$z" 'source ~/.claude/fleet/shell/fleet-login.zsh'
out=$(boot --bogus); eq "F bad arg rc" "$?" 2
leg "F --print-zshrc"

[ "$FAILS" = 0 ] || { printf 'selftest FAIL: %s failure(s)\n' "$FAILS"; exit 1; }
printf 'selftest PASS: a new login sets itself up once, and only once (issue #1165) — bash %s\n' "$("$BASH_BIN" -c 'echo $BASH_VERSION')"
