#!/bin/bash
# install-apply-selftest.sh — bin/fleet-install-apply.sh against a throwaway
# install + fake HOME, fully hermetic (issue #1119).
#
# A local git repo stands in for ~/.claude/fleet; launchctl / systemctl / claude
# are shims that log what they were asked; the helpers apply delegates to
# (migrate-layout, hooks-merge, ui-refresh, sleep repark) are stubs that log
# their argv. No real daemon, no real ~/.claude, no network.
#
# What it pins:
#   A. script only      a bin/ script change reloads nothing
#   B. plist changed    an installed unit is re-rendered + bootout/bootstrap'd;
#                       a changed unit this login never installed is left alone
#   C. added / retired  a new template is installed + bootstrapped; a deleted
#                       one is booted out + its plist removed
#   D. spinner          a changed spinner script kickstarts the KeepAlive unit
#   E. commands (#858)  README.md (quotes the marker) and _template.md (placeholder
#                       owner) are NOT installed; real commands are; a retired one
#                       is removed; a personal one is untouched; a README.md an
#                       old sync left behind is removed
#   F. skills           a changed skill dir is mirrored whole; a divergent
#                       personal skill is warned + left alone; a retired one goes
#   G. hooks / ui       hooks-merge runs only when the table changed; the conf
#                       reload gets --from's conf as its before-file
#   H. dry-run          prints the plan, changes nothing, calls no launchctl
#   I. failure          a failed bootstrap -> PARTIAL, exit 1
#   J. systemd          modified -> daemon-reload + restart; added -> enable --now;
#                       retired -> disable --now + removed
#   K. usage            --to must be HEAD, both revs required, from==to no-ops
#   L. the skill        /fleet-sync-install calls apply (ff -> apply -> report)
#                       rather than carrying its own copy of the steps
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
AP="$BIN/fleet-install-apply.sh"
[ -f "$AP" ] || { printf 'selftest: %s not found\n' "$AP" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo 'install-apply-selftest SKIP (no git)'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-apply-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
ok() { CHECKS=$((CHECKS + 1)); eval "$2" || fail "$1 — [$2] is false — output:
$OUT"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:
$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]:
$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"

# --- fake HOME + shims ------------------------------------------------------------
H="$WORK/home" R="$WORK/home/.claude/fleet" LOG="$WORK/calls.log"
mkdir -p "$H/.claude/commands" "$H/.claude/skills" "$H/Library/LaunchAgents" "$WORK/shim" "$H/.config/systemd/user"
: > "$LOG"
for t in launchctl systemctl claude; do
  cat > "$WORK/shim/$t" <<EOF
#!/bin/sh
echo "$t \$*" >> "$LOG"
case "\$*" in *"\${FAIL_ON:-@@none@@}"*) exit 1 ;; esac
exit 0
EOF
  chmod +x "$WORK/shim/$t"
done
export HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" FLEET_INSTALL_ROOT="$R"
export FLEET_LAUNCHD_AGENTS_DIR="$H/Library/LaunchAgents" FLEET_INSTALL_DAEMON_DIR="$WORK/LaunchDaemons"
export FLEET_SYSTEMD_USER_DIR="$H/.config/systemd/user" FLEET_INSTALL_PLATFORM=launchd
export FLEET_INSTALL_LAUNCHCTL="$WORK/shim/launchctl" FLEET_INSTALL_SYSTEMCTL="$WORK/shim/systemctl"
export FLEET_INSTALL_CLAUDE="$WORK/shim/claude" FLEET_INSTALL_BREW_PREFIX=/opt/homebrew FLEET_INSTALL_SUDO=''
export FLEET_INSTALL_LOGIN=tester

# --- the install: a git repo with stub helpers ---------------------------------
mkdir -p "$R/bin" "$R/launchd" "$R/systemd" "$R/commands" "$R/skills/sk" "$R/hooks" "$R/conf"
git init -q -b master "$R"
stub() { # $1 name — logs its argv, prints a last line
  cat > "$R/bin/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "$LOG"
case "\$*" in *--conf*) set -- \$*; while [ "\$1" != --conf ]; do shift; done; cp "\$2" "$WORK/seen-before.conf" ;; esac
echo "$1 done"
EOF
}
stub fleet-migrate-layout.sh; stub fleet-hooks-merge.py; stub fleet-ui-refresh.sh
cat > "$R/bin/fleet-hooks-merge.py" <<EOF
import sys
open("$LOG","a").write("fleet-hooks-merge.py " + " ".join(sys.argv[1:]) + "\n")
print("appended PreToolUse Bash guard.sh")
EOF
cat > "$R/bin/fleet-lib.sh" <<'EOF'
fleet_sockets() { printf '%s\n' ${STUB_SOCKS:-}; }
EOF
cat > "$R/bin/fleet-sleep.sh" <<EOF
#!/bin/bash
echo "fleet-sleep.sh \$*" >> "$LOG"
echo '{"reparked":"/x"}'
EOF
echo 'echo collect' > "$R/bin/tmux-dash-collect.sh"
echo 'echo spin' > "$R/bin/tmux-spinner.sh"
tmpl() { # $1 unit $2 interval
  cat > "$R/launchd/com.claude-fleet.$1.plist.tmpl" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.claude-fleet.$1</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>__HOME__/.claude/fleet/bin/$1.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>__BREW_PREFIX__/bin:/usr/bin</string></dict>
  <key>StartInterval</key><integer>$2</integer>
</dict></plist>
EOF
}
tmpl collect 60; tmpl spinner 0; tmpl webhook 0; tmpl oldie 30
printf '[Service]\nExecStart=__HOME__/.claude/fleet/bin/collect.sh\n' > "$R/systemd/claude-fleet-collect.service"
printf '[Timer]\nOnUnitActiveSec=60\n' > "$R/systemd/claude-fleet-collect.timer"
printf '[Service]\nExecStart=__HOME__/x\n' > "$R/systemd/claude-fleet-oldie.service"
printf '[Timer]\nOnUnitActiveSec=30\n' > "$R/systemd/claude-fleet-oldie.timer"
cat > "$R/commands/fleet-claim.md" <<'EOF'
# /fleet-claim

<!-- fleet skill · owner: worker -->
v1
EOF
cat > "$R/commands/fleet-old.md" <<'EOF'
# /fleet-old

<!-- fleet skill · owner: hub -->
EOF
cat > "$R/commands/README.md" <<'EOF'
# Fleet commands

| Marker | `<!-- fleet skill · owner: … -->` |

```
<!-- fleet skill · owner: worker|hub|either -->
```
EOF
cat > "$R/commands/_template.md" <<'EOF'
# /fleet-<name>

<!-- fleet skill · owner: worker|hub|either -->
EOF
printf '# sk\n\n<!-- fleet skill -->\nv1\n' > "$R/skills/sk/SKILL.md"
printf '#!/bin/sh\necho v1\n' > "$R/skills/sk/run.sh"; chmod +x "$R/skills/sk/run.sh"
echo '{"hooks":{}}' > "$R/hooks/settings-hooks.json"
printf 'bind a run x\nbind b run y\n' > "$R/conf/tmux-attention.conf"
chmod +x "$R"/bin/*.sh
git -C "$R" add -A && git -C "$R" commit -qm v0
C0=$(git -C "$R" rev-parse HEAD)

# this login's installed state at C0: collect + spinner + oldie agents, commands,
# a personal command, the skill, and a README.md an older sync installed (#858)
render() { sed -e "s|__HOME__|$H|g" -e 's|__BREW_PREFIX__|/opt/homebrew|g' "$1"; }
for u in collect spinner oldie; do render "$R/launchd/com.claude-fleet.$u.plist.tmpl" > "$H/Library/LaunchAgents/com.claude-fleet.$u.plist"; done
cp "$R/commands/fleet-claim.md" "$R/commands/fleet-old.md" "$R/commands/README.md" "$H/.claude/commands/"
echo 'mine' > "$H/.claude/commands/personal.md"
mkdir -p "$H/.claude/skills/sk" && cp -p "$R/skills/sk/"* "$H/.claude/skills/sk/"

commit() { git -C "$R" add -A && git -C "$R" commit -qm "$1" && git -C "$R" rev-parse HEAD; }
run_ap() { : > "$LOG"; OUT=$(bash "$AP" "$@" 2>&1); RC=$?; }

# --- A. script only ---------------------------------------------------------------
echo 'echo collect v2' > "$R/bin/tmux-dash-collect.sh"
C1=$(commit 'script only')
run_ap --from "$C0" --to "$C1"
eq 'A exit' 0 "$RC"
contains 'A says no reload' "$OUT" 'daemons: ok — no daemon change, no reload needed'
ok 'A no launchctl' "! grep -q '^launchctl' '$LOG'"
ok 'A layout migrated' "grep -q '^fleet-migrate-layout.sh' '$LOG'"
ok 'A hooks untouched' "! grep -q 'fleet-hooks-merge' '$LOG'"
contains 'A final line' "$OUT" 'apply: ok'
contains 'A stale #858 README removed on any run' "$OUT" 'commands: removed README.md'
ok 'A stale README gone' "[ ! -f '$H/.claude/commands/README.md' ]"

# --- H. dry-run on a plist change (before B applies it) ---------------------------
sed -i.bak 's/<integer>60</<integer>90</' "$R/launchd/com.claude-fleet.collect.plist.tmpl" && rm -f "$R/launchd/"*.bak
sed -i.bak 's/<integer>0</<integer>5</' "$R/launchd/com.claude-fleet.webhook.plist.tmpl" && rm -f "$R/launchd/"*.bak
C2=$(commit 'plist changed')
snap=$(cat "$H/Library/LaunchAgents/com.claude-fleet.collect.plist")
run_ap --from "$C1" --to "$C2" --dry-run
eq 'H exit' 0 "$RC"
contains 'H plans reload' "$OUT" 'daemons: would reload collect'
eq 'H plist untouched' "$snap" "$(cat "$H/Library/LaunchAgents/com.claude-fleet.collect.plist")"
ok 'H no launchctl' "! grep -q '^launchctl' '$LOG'"
ok 'H migrate dry' "grep -q '^fleet-migrate-layout.sh --dry-run' '$LOG'"

# --- B. plist changed -------------------------------------------------------------
run_ap --from "$C1" --to "$C2"
eq 'B exit' 0 "$RC"
contains 'B reloaded' "$OUT" 'daemons: reloaded collect'
ok 'B bootout' "grep -qx 'launchctl bootout gui/$(id -u)/com.claude-fleet.collect' '$LOG'"
ok 'B bootstrap' "grep -qx 'launchctl bootstrap gui/$(id -u) $H/Library/LaunchAgents/com.claude-fleet.collect.plist' '$LOG'"
ok 'B plist rendered' "grep -q '<integer>90<' '$H/Library/LaunchAgents/com.claude-fleet.collect.plist' && grep -q '/opt/homebrew/bin' '$H/Library/LaunchAgents/com.claude-fleet.collect.plist' && ! grep -q __HOME__ '$H/Library/LaunchAgents/com.claude-fleet.collect.plist'"
contains 'B webhook not installed' "$OUT" 'daemons: skip webhook — changed, not installed on this login'
ok 'B webhook not loaded' "! grep -q webhook '$LOG' && [ ! -f '$H/Library/LaunchAgents/com.claude-fleet.webhook.plist' ]"
run_ap --from "$C1" --to "$C2"
contains 'B re-run is a no-op' "$OUT" 'daemons: ok collect — installed plist already current'
ok 'B re-run no launchctl' "! grep -q '^launchctl' '$LOG'"

# --- C. added / retired -----------------------------------------------------------
tmpl fresh 120; git -C "$R" rm -q "$R/launchd/com.claude-fleet.oldie.plist.tmpl"
C3=$(commit 'add fresh, retire oldie')
run_ap --from "$C2" --to "$C3"
eq 'C exit' 0 "$RC"
contains 'C added' "$OUT" 'daemons: added fresh'
ok 'C fresh bootstrapped' "grep -qx 'launchctl bootstrap gui/$(id -u) $H/Library/LaunchAgents/com.claude-fleet.fresh.plist' '$LOG' && [ -f '$H/Library/LaunchAgents/com.claude-fleet.fresh.plist' ]"
ok 'C fresh not booted out first' "! grep -q 'bootout gui/$(id -u)/com.claude-fleet.fresh' '$LOG'"
contains 'C retired' "$OUT" 'daemons: retired oldie'
ok 'C oldie out' "grep -qx 'launchctl bootout gui/$(id -u)/com.claude-fleet.oldie' '$LOG' && [ ! -f '$H/Library/LaunchAgents/com.claude-fleet.oldie.plist' ]"

# --- D. spinner script ----------------------------------------------------------
echo 'echo spin v2' > "$R/bin/tmux-spinner.sh"
C4=$(commit 'spinner script')
run_ap --from "$C3" --to "$C4"
contains 'D kicked' "$OUT" 'daemons: kicked spinner'
ok 'D kickstart -k' "grep -qx 'launchctl kickstart -k gui/$(id -u)/com.claude-fleet.spinner' '$LOG'"

# --- E. commands (#858) -----------------------------------------------------------
sed -i.bak 's/^v1$/v2/' "$R/commands/fleet-claim.md"; rm -f "$R/commands/"*.bak
printf '\nmore docs\n' >> "$R/commands/README.md"
printf '\nmore\n' >> "$R/commands/_template.md"
printf '# /fleet-new\n\n<!-- fleet skill · owner: either -->\n' > "$R/commands/fleet-new.md"
git -C "$R" rm -q "$R/commands/fleet-old.md"
C5=$(commit 'commands')
run_ap --from "$C4" --to "$C5"
eq 'E exit' 0 "$RC"
ok 'E claim updated' "grep -qx v2 '$H/.claude/commands/fleet-claim.md'"
ok 'E new installed' "[ -f '$H/.claude/commands/fleet-new.md' ]"
ok 'E README not installed' "[ ! -f '$H/.claude/commands/README.md' ]"
ok 'E _template not installed' "[ ! -f '$H/.claude/commands/_template.md' ]"
ok 'E retired removed' "[ ! -f '$H/.claude/commands/fleet-old.md' ]"
ok 'E personal untouched' "grep -qx mine '$H/.claude/commands/personal.md'"
contains 'E summary' "$OUT" 'commands: installed 2 · removed 1'
bash "$AP" --is-command "$R/commands/fleet-new.md"; eq 'E gate accepts a command' 0 $?
bash "$AP" --is-command "$R/commands/README.md"; eq 'E gate rejects README' 1 $?
bash "$AP" --is-command "$R/commands/_template.md"; eq 'E gate rejects the placeholder' 1 $?
# the real repo's docs, when this runs from a checkout that has them
if [ -f "$BIN/../commands/README.md" ]; then
  bash "$AP" --is-command "$BIN/../commands/README.md"; eq 'E repo README rejected' 1 $?
  bash "$AP" --is-command "$BIN/../commands/fleet-claim.md"; eq 'E repo fleet-claim accepted' 0 $?
fi

# --- F. skills --------------------------------------------------------------------
printf '#!/bin/sh\necho v2\n' > "$R/skills/sk/run.sh"
mkdir -p "$R/skills/mine"; printf '# mine\n\n<!-- fleet skill -->\nrepo\n' > "$R/skills/mine/SKILL.md"
mkdir -p "$H/.claude/skills/mine"; printf '# mine\nmy own edits\n' > "$H/.claude/skills/mine/SKILL.md"
C6=$(commit 'skills')
run_ap --from "$C5" --to "$C6"
ok 'F dir mirrored (script + exec bit)' "grep -q v2 '$H/.claude/skills/sk/run.sh' && [ -x '$H/.claude/skills/sk/run.sh' ]"
contains 'F personal warned' "$OUT" 'skills: WARN mine is a personal skill'
ok 'F personal untouched' "grep -q 'my own edits' '$H/.claude/skills/mine/SKILL.md'"
git -C "$R" rm -rq "$R/skills/sk"
C7=$(commit 'retire sk')
run_ap --from "$C6" --to "$C7"
ok 'F retired removed' "[ ! -d '$H/.claude/skills/sk' ]"

# --- G. hooks / ui ------------------------------------------------------------------
echo '{"hooks":{"x":1}}' > "$R/hooks/settings-hooks.json"
printf 'bind a run x\n' > "$R/conf/tmux-attention.conf"
C8=$(commit 'hooks + conf')
run_ap --from "$C7" --to "$C8"
eq 'G exit' 0 "$RC"
ok 'G hooks merged' "grep -q '^fleet-hooks-merge.py merge --source $R/hooks/settings-hooks.json --settings $H/.claude/settings.json' '$LOG'"
contains 'G hooks relayed' "$OUT" 'hooks: re-merged — 1 change(s)'
ok 'G ui conf reload' "grep -q '^fleet-ui-refresh.sh --all --conf' '$LOG'"
eq 'G before-conf is --from' "$(printf 'bind a run x\nbind b run y')" "$(cat "$WORK/seen-before.conf")"
STUB_SOCKS='f1 f2' run_ap --from "$C7" --to "$C8"
contains 'G repark per fleet' "$OUT" 'repark: ok — 2 page(s) re-parked on 2 live fleet(s)'

# --- I. failure -----------------------------------------------------------------------
sed -i.bak 's/<integer>90</<integer>45</' "$R/launchd/com.claude-fleet.collect.plist.tmpl" && rm -f "$R/launchd/"*.bak
C9=$(commit 'plist again')
FAIL_ON=bootstrap run_ap --from "$C8" --to "$C9"
eq 'I exit 1' 1 "$RC"
contains 'I FAIL line' "$OUT" 'daemons: FAIL bootstrap'
contains 'I PARTIAL' "$OUT" 'apply: PARTIAL'

# --- J. systemd ---------------------------------------------------------------------
for f in collect.service collect.timer oldie.service oldie.timer; do
  sed "s|__HOME__|$H|g" "$R/systemd/claude-fleet-$f" > "$H/.config/systemd/user/claude-fleet-$f"
done
S0=$(git -C "$R" rev-parse HEAD)
printf '[Timer]\nOnUnitActiveSec=90\n' > "$R/systemd/claude-fleet-collect.timer"
printf '[Service]\nExecStart=__HOME__/n\n' > "$R/systemd/claude-fleet-newu.service"
printf '[Timer]\nOnUnitActiveSec=5\n' > "$R/systemd/claude-fleet-newu.timer"
git -C "$R" rm -q "$R/systemd/claude-fleet-oldie.service" "$R/systemd/claude-fleet-oldie.timer"
S1=$(commit 'systemd')
FLEET_INSTALL_PLATFORM=systemd run_ap --from "$S0" --to "$S1"
eq 'J exit' 0 "$RC"
ok 'J daemon-reload' "grep -qx 'systemctl --user daemon-reload' '$LOG'"
ok 'J restart collect' "grep -qx 'systemctl --user restart claude-fleet-collect.timer' '$LOG'"
ok 'J enable newu' "grep -qx 'systemctl --user enable --now claude-fleet-newu.timer' '$LOG' && grep -q '$H/n' '$H/.config/systemd/user/claude-fleet-newu.service'"
ok 'J disable oldie' "grep -qx 'systemctl --user disable --now claude-fleet-oldie.timer' '$LOG' && [ ! -f '$H/.config/systemd/user/claude-fleet-oldie.timer' ]"

# --- M. system LaunchDaemon shape (a guest login: UserName, per-login label) ------
if command -v plutil >/dev/null 2>&1; then
  mkdir -p "$WORK/LaunchDaemons" "$WORK/noagents"
  M0=$(git -C "$R" rev-parse HEAD)
  render "$R/launchd/com.claude-fleet.collect.plist.tmpl" > "$WORK/LaunchDaemons/com.claude-fleet.tester.collect.plist"
  sed -i.bak 's/<integer>45</<integer>75</' "$R/launchd/com.claude-fleet.collect.plist.tmpl" && rm -f "$R/launchd/"*.bak
  M1=$(commit 'plist for system shape')
  D="$WORK/LaunchDaemons/com.claude-fleet.tester.collect.plist"
  snap=$(cat "$D")
  FLEET_INSTALL_SUDO=false FLEET_LAUNCHD_AGENTS_DIR="$WORK/noagents" run_ap --from "$M0" --to "$M1"
  eq 'M no sudo -> exit 1' 1 "$RC"
  contains 'M prints runnable admin commands' "$OUT" "run as an admin: sudo install -m 644 $R/logs/install-apply-pending/com.claude-fleet.tester.collect.plist $D"
  ok 'M pending plist kept' "[ -f '$R/logs/install-apply-pending/com.claude-fleet.tester.collect.plist' ]"
  eq 'M no sudo -> unchanged' "$snap" "$(cat "$D")"
  ok 'M no sudo -> no launchctl' "! grep -q '^launchctl' '$LOG'"
  FLEET_LAUNCHD_AGENTS_DIR="$WORK/noagents" run_ap --from "$M0" --to "$M1"
  eq 'M exit' 0 "$RC"
  eq 'M label' com.claude-fleet.tester.collect "$(plutil -extract Label raw -o - "$D")"
  eq 'M UserName' tester "$(plutil -extract UserName raw -o - "$D")"
  eq 'M argv wrapped' /bin/sh "$(plutil -extract ProgramArguments.0 raw -o - "$D")"
  contains 'M argv keeps the script' "$(plutil -extract ProgramArguments.2 raw -o - "$D")" "exec '/bin/bash' '$H/.claude/fleet/bin/collect.sh'"
  eq 'M interval' 75 "$(plutil -extract StartInterval raw -o - "$D")"
  ok 'M system reload' "grep -qx 'launchctl bootout system/com.claude-fleet.tester.collect' '$LOG' && grep -qx 'launchctl bootstrap system $D' '$LOG'"
  FLEET_LAUNCHD_AGENTS_DIR="$WORK/noagents" run_ap --from "$M0" --to "$M1"
  contains 'M re-run is a no-op' "$OUT" 'daemons: ok collect — installed plist already current'
fi

# --- K. usage -------------------------------------------------------------------------
run_ap --from "$C0" --to "$C1"; eq 'K --to not HEAD' 2 "$RC"
run_ap --to HEAD; eq 'K --from required' 2 "$RC"
run_ap --from nosuchrev --to HEAD; eq 'K unknown rev' 2 "$RC"
run_ap --from HEAD --to HEAD
eq 'K from==to exit' 0 "$RC"
contains 'K from==to no-op' "$OUT" 'nothing to apply'
ok 'K from==to touched nothing' "[ ! -s '$LOG' ]"

# --- L. /fleet-sync-install calls apply -----------------------------------------
SKILL="$BIN/../commands/fleet-sync-install.md"
if [ -f "$SKILL" ]; then
  s=$(cat "$SKILL")
  contains 'L skill calls apply' "$s" 'fleet-install-apply.sh --from "$before" --to "$after"'
  not_contains 'L no hand-copied command pass' "$s" 'cp -p "$src"/*'
  not_contains 'L no hand-rolled bootstrap' "$s" 'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-fleet.<x>.plist'
fi

printf 'install-apply-selftest: PASS (%d checks)\n' "$CHECKS"
