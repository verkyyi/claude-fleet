#!/bin/bash
# One-login readiness summary for fleet-doctor.sh. Read-only; prints either
# "ready: ..." or a comma-separated list of missing steps.
set -u
bin=$(cd "$(dirname "$0")" && pwd)
conf_dir=${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}
accounts=${FLEET_ACCOUNTS_DIR:-$HOME/.config/claude-fleet/accounts}
missing=''
add() { missing="${missing:+$missing, }$1"; }

command -v claude >/dev/null 2>&1 || add 'Claude CLI'

tokens=0
bad_tokens=0
for f in "$accounts"/*; do
  [ -f "$f" ] || continue
  case "${f##*/}" in .*|*~|*.conf) continue ;; esac
  tokens=$((tokens + 1))
  [ -s "$f" ] && [ -n "$(find "$f" -type f -perm 600 2>/dev/null)" ] || bad_tokens=1
done
[ "$tokens" -gt 0 ] && [ "$bad_tokens" = 0 ] || add 'Claude accounts (nonempty 600 token files)'

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  add 'GitHub login (gh auth login)'
fi

# `ccquota codex list` has a LOGIN column; a listed but expired profile does
# not make Codex usable. The header and any invalid profile are ignored.
codex_rows=''
if ! command -v ccquota >/dev/null 2>&1 ||
   ! codex_rows=$(ccquota codex list 2>/dev/null) ||
   ! printf '%s\n' "$codex_rows" | awk 'NR > 1 && $5 == "valid" { ok=1 } END { exit !ok }'; then
  add 'Codex LOGIN valid (ccquota codex login)'
fi

keys="$HOME/.ssh/authorized_keys"
if [ ! -s "$keys" ]; then
  add 'SSH authorized_keys'
elif awk '($1 ~ /^(ssh-|ecdsa-|sk-)/) {
  for (i=3; i<=NF; i++) if (tolower($i) ~ /(^|[^a-z])temp(orary)?([^a-z]|$)/ || $i ~ /临时/) found=1
} END { exit !found }' "$keys"; then
  add 'replace temporary SSH key'
fi

# New guest logins use system LaunchDaemons with a login-qualified label;
# console logins use gui LaunchAgents. Every shipped unit must be loaded.
if command -v launchctl >/dev/null 2>&1; then
  uid=$(id -u)
  login=$(id -un)
  for tmpl in "$bin"/../launchd/com.claude-fleet.*.plist.tmpl; do
    [ -f "$tmpl" ] || continue
    unit=${tmpl##*/com.claude-fleet.}; unit=${unit%.plist.tmpl}
    launchctl print "gui/$uid/com.claude-fleet.$unit" >/dev/null 2>&1 ||
      launchctl print "system/com.claude-fleet.$login.$unit" >/dev/null 2>&1 ||
      { add "daemon $unit"; }
  done
elif command -v systemctl >/dev/null 2>&1; then
  systemctl --user is-active claude-fleet-collect.timer >/dev/null 2>&1 || add 'daemon collect'
else
  add 'fleet daemons (no service manager)'
fi

if [ ! -e "$conf_dir/global/onboarded" ]; then
  # fleet_guide_alive distinguishes an agent from a guide window left at a
  # bare shell. The marker also counts: it survives the guide being closed.
  # shellcheck source=/dev/null
  . "$bin/fleet-lib.sh"
  guide=0
  while IFS=$'\t' read -r sess _; do
    [ -n "$sess" ] || continue
    if fleet_guide_alive "$sess"; then guide=1; break; fi
  done < <(fleet_each_conf)
  [ "$guide" = 1 ] || add 'onboarding guide'
fi

if [ -n "$missing" ]; then printf 'needs: %s\n' "$missing"; exit 1; fi
printf 'ready: Claude, accounts, GitHub, Codex, SSH, daemons, guide\n'
