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
#   E. (#1214) launchd with neither a GUI session nor this login's system
#      LaunchDaemons — #1210 ①②: apply still runs, with --no-daemons, so every
#      hook, command and skill lands; bootstrap.applied + bootstrapped written,
#      exit 0; the `apply: ok` line names what went in and ONE `daemons: WARN`
#      line follows it naming the admin's onboarding command and the console
#      sign-in path. Another login's LaunchDaemons do not count (same WARN). With
#      a gui domain: apply runs without the flag and no WARN (the historic gui
#      path); on a platform without launchd: neither the flag nor the WARN.
#   E2. (#1192) the same, but this login's system LaunchDaemons are installed
#      (FLEET_INSTALL_DAEMON_DIR/com.claude-fleet.<login>.*.plist): apply runs in
#      full, says no GUI sign-in is needed, bootstrap.applied written, exit 0 —
#      no --no-daemons, no WARN line: the pre-#1214 output, unchanged.
#   F. --print-zshrc parses as zsh; its guard names the marker the script writes;
#      --print-path-line is one zsh line that puts ~/.local/bin on PATH once.
#   G. claude (issue #1191): one on PATH → no install; none → the install command
#      once (FLEET_CLAUDE_INSTALL_CMD), before fleet-up, which then runs with
#      ~/.local/bin first on PATH; a failed install → exit 1, retried alone.
#   H. the ~/.local/bin PATH line: before the block, once — put first in an older
#      zshrc that has the block without it; a login's own line is kept, not doubled.
#   I. first-run Claude UI state and wizard permissions: seed missing keys, keep
#      existing values/rules, and cover every shell command in the wizard.
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
unset TMUX TMUX_PANE FLEET_INSTALL_ROOT FLEET_SEED_REPO FLEET_INSTALL_LAUNCHCTL FLEET_CLAUDE_INSTALL_CMD
CALLS="$WORK/calls"; export CALLS
# No `claude` anywhere on PATH — the runner's own ~/.local/bin included — so the
# fixture login looks like one that has none (issue #1191); the "installer" is a
# stub that logs its call and drops a fake claude where the real one does.
_p=''; _ifs=$IFS; IFS=:; for _d in $PATH; do [ -x "$_d/claude" ] || _p="$_p${_p:+:}$_d"; done; IFS=$_ifs
export PATH="$_p"
cat > "$WORK/claude-install" <<'STUB'
#!/bin/bash
echo "claude-install $*" >> "$CALLS"
[ -n "${CLAUDE_INSTALL_RC:-}" ] && exit "$CLAUDE_INSTALL_RC"
mkdir -p "$HOME/.local/bin" && printf '#!/bin/sh\necho claude-stub\n' > "$HOME/.local/bin/claude" && chmod +x "$HOME/.local/bin/claude"
echo "installer: stub"
STUB
chmod +x "$WORK/claude-install"
export FLEET_CLAUDE_INSTALL_CMD="$WORK/claude-install"
UPPATH="$WORK/up.path"; export UPPATH        # the PATH fleet-up was run with

# ---- the fixture GitHub: verkyyi/claude-fleet with stubs, stable one behind master ----
FX="$WORK/fx"; mkdir -p "$FX/bin" "$FX/shell"
cp "$BIN/fleet-onboard-defaults.py" "$FX/bin/fleet-onboard-defaults.py"
stub() { # stub <name> <body…> — logs "<name> <argv>" to $CALLS, then runs <body>
  local n="$1"; shift
  { printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "$CALLS"\n' "$n"; printf '%s\n' "$@"; } > "$FX/bin/$n"
  chmod +x "$FX/bin/$n"
}
stub fleet-install-apply.sh 'echo "apply: stub"; exit "${APPLY_RC:-0}"'
stub reapply-tmux-attention.sh 'echo "source-file ~/.claude/fleet/conf/tmux-attention.conf" >> "$HOME/.tmux.conf"'
stub fleet-up.sh 'printf "%s\n" "$PATH" > "$UPPATH"; mkdir -p "$FLEET_CONF_DIR/fleets/fleet" && printf "FLEET_REPO=\"%s\"\n" "$1" > "$FLEET_CONF_DIR/fleets/fleet/conf"; echo "fleet-up: stub up"'
stub fleet-doctor.sh 'echo "PASS doctor-stub all green"'
echo '# stub' > "$FX/shell/fleet-login.zsh"
git init -q -b master "$FX" && git -C "$FX" add -A && git -C "$FX" commit -qm stable-one
git -C "$FX" tag stable
STABLE=$(git -C "$FX" rev-parse HEAD)
echo later > "$FX/later" && git -C "$FX" add later && git -C "$FX" commit -qm master-tip
GB="$WORK/gh"; mkdir -p "$GB/verkyyi"
git clone -q --bare "$FX" "$GB/verkyyi/claude-fleet.git"
export FLEET_BOOTSTRAP_GIT_BASE="$GB" FLEET_INSTALL_PLATFORM=none
# no system daemons for this login unless a leg installs some (the operator's
# /Library/LaunchDaemons may hold com.claude-fleet.<login>.* for real)
export FLEET_INSTALL_DAEMON_DIR="$WORK/LaunchDaemons" FLEET_INSTALL_LOGIN=tester
mkdir -p "$FLEET_INSTALL_DAEMON_DIR"

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
hasnt "A no launchd: apply without --no-daemons" "$ap" "--no-daemons"
hasnt "A no launchd: no daemons WARN" "$out" "daemons: WARN"
eq "A apply --from the empty tree" "$(git -C "$R" rev-parse "$from^{tree}" 2>/dev/null)" 4b825dc642cb6eb9a060e54bf8d69288fbee4904
eq "A applied stamp" "$(cat "$FLEET_CONF_DIR/global/bootstrap.applied" 2>/dev/null)" "$STABLE"
eq "A tmux line once" "$(grep -c tmux-attention.conf "$HOME/.tmux.conf")" 1
eq "A zshrc = the PATH line, then the block" "$(cat "$HOME/.zshrc")" "$(boot --print-path-line; boot --print-zshrc)"
eq "A PATH line once" "$(grep -c '\.local/bin' "$HOME/.zshrc")" 1
eq "A PATH line first, block second" "$(grep -n -e '\.local/bin' -e '>>> claude-fleet' "$HOME/.zshrc" | cut -d: -f1 | tr '\n' ' ')" "1 2 "
# claude (issue #1191): installed once, before fleet-up, which runs with ~/.local/bin first
eq "A claude installed once" "$(grep -c '^claude-install' "$CALLS")" 1
has "A claude ok line" "$out" "claude: ok — installed $HOME/.local/bin/claude"
[ -x "$HOME/.local/bin/claude" ] || fail "A: no ~/.local/bin/claude after the install"
eq "A claude before fleet-up" "$(awk '{print $1}' "$CALLS" | grep -Ex 'claude-install|fleet-up\.sh' | tr '\n' ' ')" "claude-install fleet-up.sh "
case "$(cat "$UPPATH")" in "$HOME/.local/bin:"*) ;; *) fail "A: fleet-up ran without ~/.local/bin first on PATH: $(cat "$UPPATH")" ;; esac
eq "A fleet-up quiet + no attach" "$(grep '^fleet-up.sh ' "$CALLS")" \
  "fleet-up.sh verkyyi/claude-fleet $HOME/projects/claude-fleet --seed --no-attach"
eq "A seed checkout cloned" "$(git -C "$HOME/projects/claude-fleet" rev-parse --is-inside-work-tree 2>/dev/null)" true
has "A doctor passed through" "$out" "    PASS doctor-stub all green"
[ -s "$FLEET_CONF_DIR/global/bootstrapped" ] || fail "A: no global/bootstrapped"
python3 - "$HOME" <<'PY' || fail 'A first-run Claude defaults absent'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
state = json.loads((home / '.claude.json').read_text())
settings = json.loads((home / '.claude/settings.json').read_text())
assert state['hasCompletedOnboarding'] is True
assert state['theme'] == 'dark'
assert settings['permissions']['allow']
PY
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

# ---- E. macOS, neither a GUI session nor system LaunchDaemons (#1214, #1210 ①②) ----
newhome "$WORK/e"
out=$(FLEET_INSTALL_PLATFORM=launchd FLEET_INSTALL_LAUNCHCTL=false boot); eq "E rc" "$?" 0
ap=$(grep '^fleet-install-apply.sh ' "$CALLS")
[ -n "$ap" ] || fail "E: apply did not run without a gui domain — the tools never land"
has "E apply --no-daemons" "$ap" " --no-daemons"
eq "E apply --to HEAD" "$(printf '%s' "$ap" | sed -n 's/.*--to \([0-9a-f]*\).*/\1/p')" "$STABLE"
has "E apply ok names the tools" "$out" "apply: ok — installed at ${STABLE:0:7} (hooks, commands, skills, settings"
has "E daemons WARN" "$out" "daemons: WARN — not installed: no system LaunchDaemons com.claude-fleet.tester.* and no GUI session for tester"
has "E WARN names the admin's command" "$out" "fleet-login-new.sh"
has "E WARN names the doc" "$out" "docs/SHARED-MACHINE.md"
has "E WARN names the console path" "$out" "sign in once at the console"
has "E WARN names the re-apply, ~-relative" "$out" "rm -f ~/.config/claude-fleet/global/bootstrap.applied ~/.config/claude-fleet/global/bootstrapped"
hasnt "E no FAIL" "$out" "FAIL"
eq "E one daemons line" "$(printf '%s\n' "$out" | grep -c '^fleet-login-bootstrap: daemons: WARN')" 1
eq "E apply line, then daemons line, then zshrc" \
  "$(printf '%s\n' "$out" | grep -oE '^fleet-login-bootstrap: (apply: ok|daemons: WARN|zshrc: ok)' | sed 's/^fleet-login-bootstrap: //' | tr '\n' '|')" "apply: ok|daemons: WARN|zshrc: ok|"
eq "E applied stamp" "$(cat "$FLEET_CONF_DIR/global/bootstrap.applied" 2>/dev/null)" "$STABLE"
[ -s "$FLEET_CONF_DIR/global/bootstrapped" ] || fail "E: not marked done — the tools are in and the fleet is up"
eq "E fleet up" "$(grep -c '^fleet-up.sh ' "$CALLS")" 1
# the second login: nothing to do, the WARN is not a retry loop
: > "$CALLS"
out=$(FLEET_INSTALL_PLATFORM=launchd FLEET_INSTALL_LAUNCHCTL=false boot); eq "E re-run rc" "$?" 0
has "E re-run says done" "$out" "already bootstrapped"
eq "E re-run nothing called" "$(cat "$CALLS")" ""
# the printed re-apply: after a console sign-in (a gui domain now), the two
# markers removed and one more login — apply runs again, this time with daemons
rm -f "$FLEET_CONF_DIR/global/bootstrap.applied" "$FLEET_CONF_DIR/global/bootstrapped"
out=$(FLEET_INSTALL_PLATFORM=launchd FLEET_INSTALL_LAUNCHCTL=true boot); eq "E re-apply rc" "$?" 0
eq "E re-apply: apply + doctor only" "$(awk '{print $1}' "$CALLS" | tr '\n' ' ')" "fleet-install-apply.sh fleet-doctor.sh "
hasnt "E re-apply: with daemons" "$(grep '^fleet-install-apply.sh ' "$CALLS")" "--no-daemons"
hasnt "E re-apply: no WARN" "$out" "daemons: WARN"
[ -s "$FLEET_CONF_DIR/global/bootstrapped" ] || fail "E: re-apply did not mark done"
# a gui domain from the start: the historic gui path — no flag, no WARN, plain apply line
newhome "$WORK/e-gui"
out=$(FLEET_INSTALL_PLATFORM=launchd FLEET_INSTALL_LAUNCHCTL=true boot); eq "E gui rc" "$?" 0
hasnt "E gui: apply without --no-daemons" "$(grep '^fleet-install-apply.sh ' "$CALLS")" "--no-daemons"
hasnt "E gui: no WARN" "$out" "daemons: WARN"
has "E gui: plain apply line" "$out" "apply: ok — installed at ${STABLE:0:7}"
hasnt "E gui: no tools parenthesis" "$out" "(hooks, commands"
leg "E no GUI session, no system daemons → the tools install, the daemons are a WARN"

# ---- E2. system-shape daemons installed by the admin (#1192): no GUI needed ----
newhome "$WORK/e2"
mkdir -p "$WORK/sysd" && : > "$WORK/sysd/com.claude-fleet.tester.spinner.plist"
out=$(FLEET_INSTALL_PLATFORM=launchd FLEET_INSTALL_LAUNCHCTL=false FLEET_INSTALL_DAEMON_DIR="$WORK/sysd" boot); eq "E2 rc" "$?" 0
has "E2 says why" "$out" "apply: system LaunchDaemons com.claude-fleet.tester.* are installed — no GUI sign-in needed"
hasnt "E2 no GUI complaint" "$out" "no GUI session"
hasnt "E2 no daemons WARN (#1214 leaves this path as it was)" "$out" "daemons: WARN"
hasnt "E2 apply in full, no --no-daemons" "$(grep '^fleet-install-apply.sh ' "$CALLS")" "--no-daemons"
has "E2 plain apply line" "$out" "apply: ok — installed at ${STABLE:0:7}
"
grep -q '^fleet-install-apply.sh ' "$CALLS" || fail "E2: apply did not run"
eq "E2 applied stamp" "$(cat "$FLEET_CONF_DIR/global/bootstrap.applied" 2>/dev/null)" "$STABLE"
[ -s "$FLEET_CONF_DIR/global/bootstrapped" ] || fail "E2: not marked done"
# another login's daemons do not count: the tools install, this login's daemons are the WARN
newhome "$WORK/e3"
mkdir -p "$WORK/sysd3" && : > "$WORK/sysd3/com.claude-fleet.someoneelse.spinner.plist"
out=$(FLEET_INSTALL_PLATFORM=launchd FLEET_INSTALL_LAUNCHCTL=false FLEET_INSTALL_DAEMON_DIR="$WORK/sysd3" boot); eq "E2 other login rc" "$?" 0
has "E2 other login: --no-daemons" "$(grep '^fleet-install-apply.sh ' "$CALLS")" " --no-daemons"
has "E2 other login: the WARN" "$out" "daemons: WARN — not installed: no system LaunchDaemons com.claude-fleet.tester.*"
hasnt "E2 other login: not the admin's line" "$out" "are installed — no GUI sign-in needed"
leg "E2 system LaunchDaemons installed → apply runs in full without a GUI session"

# ---- F. the zshrc block ----
z=$(boot --print-zshrc)
if command -v zsh >/dev/null 2>&1; then
  printf '%s\n' "$z" | zsh -n || fail "F: block does not parse as zsh"
fi
has "F guard = the marker" "$z" '[[ ! -f ~/.config/claude-fleet/global/bootstrapped ]]'
has "F clones stable" "$z" "clone -q -b stable https://github.com/verkyyi/claude-fleet.git"
has "F sources fleet-login.zsh" "$z" 'source ~/.claude/fleet/shell/fleet-login.zsh'
pl=$(boot --print-path-line)
eq "F path line is one line" "$(printf '%s\n' "$pl" | wc -l | tr -d ' ')" 1
has "F path line exports the dir" "$pl" 'export PATH="$HOME/.local/bin:$PATH"'
if command -v zsh >/dev/null 2>&1; then
  printf '%s\n' "$pl" | zsh -n || fail "F: path line does not parse as zsh"
  n=$(HOME=/h PATH=/usr/bin:/bin zsh -f -c "$pl
$pl
print -r -- \"\$PATH\"" 2>/dev/null | tr ':' '\n' | grep -cx /h/.local/bin)
  eq "F path line: sourced twice, on PATH once (zsh)" "$n" 1
fi
n=$(HOME=/h PATH=/usr/bin:/bin "$BASH_BIN" -c "$pl
$pl
printf '%s' \"\$PATH\"" 2>/dev/null | tr ':' '\n' | grep -cx /h/.local/bin)
eq "F path line: sourced twice, on PATH once (bash)" "$n" 1
out=$(boot --bogus); eq "F bad arg rc" "$?" 2
leg "F --print-zshrc / --print-path-line"

# ---- G. claude: on PATH → nothing; a failed install → retried alone (#1191) ----
newhome "$WORK/g"
mkdir -p "$WORK/g-bin"; printf '#!/bin/sh\necho elsewhere\n' > "$WORK/g-bin/claude"; chmod +x "$WORK/g-bin/claude"
out=$(PATH="$WORK/g-bin:$PATH" boot); eq "G rc" "$?" 0
has "G found, left alone" "$out" "claude: ok — $WORK/g-bin/claude"
grep -q '^claude-install' "$CALLS" && fail "G: installed over a claude already on PATH"
[ -e "$HOME/.local/bin/claude" ] && fail "G: a second claude dropped in ~/.local/bin"
newhome "$WORK/g2"
out=$(CLAUDE_INSTALL_RC=7 boot); eq "G2 rc" "$?" 1
has "G2 names the step" "$out" "claude: FAIL"
has "G2 names the command" "$out" "$WORK/claude-install"
[ -e "$FLEET_CONF_DIR/global/bootstrapped" ] && fail "G2: marked done without claude"
eq "G2 the rest still ran" "$(grep -c '^fleet-up.sh ' "$CALLS")" 1
: > "$CALLS"
out=$(boot); eq "G2 re-run rc" "$?" 0
eq "G2 re-run: claude + doctor only" "$(awk '{print $1}' "$CALLS" | tr '\n' ' ')" "claude-install fleet-doctor.sh "
has "G2 re-run installed" "$out" "claude: ok — installed $HOME/.local/bin/claude"
[ -s "$FLEET_CONF_DIR/global/bootstrapped" ] || fail "G2: re-run did not mark done"
leg "G claude: on PATH → nothing; failed install → retried alone"

# ---- H. the PATH line: before the block, once (#1191) ----
newhome "$WORK/h"
{ echo '# mine'; boot --print-zshrc; } > "$HOME/.zshrc"        # an older login: the block, no PATH line
out=$(boot); eq "H rc" "$?" 0
has "H says so" "$out" "PATH line before the claude-fleet block"
eq "H line put first" "$(head -1 "$HOME/.zshrc")" "$(boot --print-path-line)"
eq "H PATH line once" "$(grep -c '\.local/bin' "$HOME/.zshrc")" 1
eq "H block once" "$(grep -c '>>> claude-fleet' "$HOME/.zshrc")" 1
eq "H the rest intact" "$(tail -n +2 "$HOME/.zshrc")" "$(echo '# mine'; boot --print-zshrc)"
newhome "$WORK/h2"
echo 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zshrc"   # a line of the login's own
out=$(boot); eq "H2 rc" "$?" 0
has "H2 block only" "$out" "zshrc: ok — added the claude-fleet block to ~/.zshrc"
eq "H2 PATH line once" "$(grep -c '\.local/bin' "$HOME/.zshrc")" 1
eq "H2 = own line, blank, block" "$(cat "$HOME/.zshrc")" "$(printf 'export PATH="$HOME/.local/bin:$PATH"\n\n'; boot --print-zshrc)"
leg "H the PATH line goes before the block, once"

# ---- I. preserve existing values; all wizard shell lines have a rule ----
newhome "$WORK/i"
mkdir -p "$HOME/.claude"
printf '{"hasCompletedOnboarding":false,"theme":"light","mine":7}\n' > "$HOME/.claude.json"
printf '{"permissions":{"allow":["Bash(my-command)"]},"mine":8}\n' > "$HOME/.claude/settings.json"
out=$(boot); eq "I rc" "$?" 0
python3 - "$HOME" "$BIN/../commands/fleet-onboard.md" "$BIN/fleet-onboard-defaults.py" <<'PY' || fail 'I values/rules or wizard coverage'
import fnmatch, importlib.util, json, pathlib, re, sys
home, md, module = map(pathlib.Path, sys.argv[1:])
state = json.loads((home / '.claude.json').read_text())
settings = json.loads((home / '.claude/settings.json').read_text())
assert state['hasCompletedOnboarding'] is False and state['theme'] == 'light' and state['mine'] == 7
assert settings['mine'] == 8
allow = settings['permissions']['allow']
assert allow[0] == 'Bash(my-command)' and len(allow) == len(set(allow))
spec = importlib.util.spec_from_file_location('defaults', module)
defaults = importlib.util.module_from_spec(spec)
spec.loader.exec_module(defaults)
assert all(rule in allow for rule in defaults.ALLOW)
commands = []
in_shell = False
for line in md.read_text().splitlines():
    stripped = line.strip()
    if stripped.startswith('```'):
        in_shell = stripped == '```sh'
        continue
    if in_shell:
        command = stripped.split('  #', 1)[0].strip()
        if command and not command.startswith('#'):
            commands.append(command)
    # Some one-line calls are printed inline in prose rather than a shell fence.
    for command in re.findall(r'`([^`]+)`', line):
        if command.startswith(('~/.claude/fleet/bin/', 'gh repo ', 'gh pr ')):
            commands.append(command)
assert len(commands) >= 20, f'only {len(commands)} wizard commands extracted'
for command in commands:
    if not any(fnmatch.fnmatchcase(command, rule[5:-1]) for rule in allow if rule.startswith('Bash(')):
        raise AssertionError(f'no allow rule for wizard command: {command}')
print(f'PASS wizard allow rules cover {len(commands)} shell lines from fleet-onboard.md')
PY
leg "I Claude first-run state preserves values; wizard commands are allowed"

[ "$FAILS" = 0 ] || { printf 'selftest FAIL: %s failure(s)\n' "$FAILS"; exit 1; }
printf 'selftest PASS: a new login sets itself up once, and only once — Claude Code included, the tools even without daemons (issues #1165, #1191, #1214) — bash %s\n' "$("$BASH_BIN" -c 'echo $BASH_VERSION')"
