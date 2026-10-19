# selftest-repo-fixture.sh — sourced by selftests (issue #4806): put a repo into a
# sandbox fleet the way fleet_repo_register leaves it — an overlay at
# <conf-dir>/fleets/<sess>/repos/<slug>.conf, listed in repos/.order. The fleet
# conf names no repo (issue #1937); one that does is not read.
#
#   fx_repo <conf-dir> <sess> <owner/name> [KEY=VALUE ...]
#
# Each KEY=VALUE becomes one line of the overlay, KEY="VALUE" (pass the value
# already expanded: FLEET_MAIN="$dir"). Re-adding a repo
# rewrites its overlay and keeps its place in .order. POSIX sh, no fleet-lib.

fx_repo() {
  _fx_d="$1/fleets/$2/repos"; _fx_r=$3; shift 3
  _fx_s=$(printf '%s' "$_fx_r" | tr '/' '-')
  mkdir -p "$_fx_d" || return 1
  { printf 'FLEET_REPO="%s"\n' "$_fx_r"
    for _fx_kv in "$@"; do printf '%s="%s"\n' "${_fx_kv%%=*}" "${_fx_kv#*=}"; done
  } > "$_fx_d/$_fx_s.conf" || return 1
  grep -qxF -- "$_fx_s" "$_fx_d/.order" 2>/dev/null || printf '%s\n' "$_fx_s" >> "$_fx_d/.order"
}
