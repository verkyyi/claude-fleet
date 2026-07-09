#!/bin/bash
# tmux-config-selftest.sh — hermetic smoke test for bin/fleet-config-lib.sh (the
# prefix+c config modal, issue #83). No tmux, no fzf, no network.
#
# Asserts the modal's core contract against the REAL fleet.conf.example (so it
# also guards that the example stays parseable) plus TEMP global/per-fleet confs:
#   • KEY LIST      every FLEET_* key in the example is discovered.
#   • TYPING        booleans/enums/numerics/strings classify correctly.
#   • DEFAULTS      parsed from the example (commented + uncommented lines).
#   • LAYERING      effective value + winning layer = per-fleet ▸ global ▸ default.
#   • VALIDATION    bad values by type are rejected; good ones pass; a value that
#                   would break `source`-ing (double-quote/backtick/trailing \) is
#                   refused.
#   • WRITE         create-on-first-write, in-place upsert (no dup lines), backup
#                   on update, prefix-safe keys, and the written conf sources back
#                   to the value.
#
# Exit 0 = pass. Non-zero = fail (prints which assertion).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-config-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcfg-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# Isolate every writable path into $WORK; parse the REAL example.
export FCFG_GLOBAL_CONF="$WORK/fleet.conf"
export FCFG_FLEET_CONF="$WORK/s1.conf"
export FLEET_C="$WORK/cache"
mkdir -p "$FLEET_C"
# shellcheck source=/dev/null
. "$LIB"

pass=0
ok()   { pass=$((pass+1)); }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq()   { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; ok; }

# --- KEY LIST ---------------------------------------------------------------
keys=$(fcfg_keys)
for k in FLEET_REPO FLEET_CTX_WINDOW FLEET_MODEL FLEET_GLOBAL_MAX_SESSIONS \
         FLEET_AUTOFILL FLEET_AUTOFILL_MAX_PER_TICK FLEET_NOTIFY_CMD \
         FLEET_DISK_FLOOR_GB FLEET_SPAWN_FOCUS; do
  printf '%s\n' "$keys" | grep -qxF "$k" || fail "key list missing $k"
  ok
done

# --- TYPING -----------------------------------------------------------------
eq 'type FLEET_AUTOFILL'       "$(fcfg_type FLEET_AUTOFILL)"       bool
eq 'type FLEET_SPAWN_FOCUS'    "$(fcfg_type FLEET_SPAWN_FOCUS)"    bool
eq 'type FLEET_MODEL'          "$(fcfg_type FLEET_MODEL)"          enum
eq 'type FLEET_SUBAGENT_MODEL' "$(fcfg_type FLEET_SUBAGENT_MODEL)" enum
eq 'type FLEET_CTX_WINDOW'     "$(fcfg_type FLEET_CTX_WINDOW)"     num
eq 'type FLEET_MAX_SESSIONS'   "$(fcfg_type FLEET_MAX_SESSIONS)"   num
eq 'type FLEET_ISSUE_TTL'      "$(fcfg_type FLEET_ISSUE_TTL)"      num
eq 'type FLEET_REPO'           "$(fcfg_type FLEET_REPO)"           str
eq 'type FLEET_NOTIFY_CMD'     "$(fcfg_type FLEET_NOTIFY_CMD)"     str

# --- DEFAULTS ---------------------------------------------------------------
eq 'default FLEET_CTX_WINDOW'          "$(fcfg_default FLEET_CTX_WINDOW)"          200000
eq 'default FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_default FLEET_GLOBAL_MAX_SESSIONS)" 8
eq 'default FLEET_AUTOFILL'            "$(fcfg_default FLEET_AUTOFILL)"            0
eq 'default FLEET_MODEL'               "$(fcfg_default FLEET_MODEL)"               opus
eq 'default FLEET_DISK_FLOOR_GB'       "$(fcfg_default FLEET_DISK_FLOOR_GB)"       12
[ -n "$(fcfg_short FLEET_REPO)" ] || fail 'short help for FLEET_REPO is empty'; ok

# --- LAYERING ---------------------------------------------------------------
# no confs → default
: > "$FCFG_GLOBAL_CONF"; : > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(default) val' "${ev%"$FCFG_US"*}" 200000
eq 'effective(default) src' "${ev##*"$FCFG_US"}" default
# global set → global wins over default
printf 'FLEET_CTX_WINDOW=300000\n' > "$FCFG_GLOBAL_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(global) val' "${ev%"$FCFG_US"*}" 300000
eq 'effective(global) src' "${ev##*"$FCFG_US"}" global
# per-fleet set → overlay wins over global
printf 'FLEET_CTX_WINDOW=1000000\n' > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(fleet) val' "${ev%"$FCFG_US"*}" 1000000
eq 'effective(fleet) src' "${ev##*"$FCFG_US"}" fleet
# a COMMENTED assignment does NOT count as set
printf '#FLEET_MODEL=sonnet\n' > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_MODEL s1)
eq 'commented != set' "${ev##*"$FCFG_US"}" default

# --- VALIDATION -------------------------------------------------------------
fcfg_validate num  42        FLEET_X >/dev/null || fail 'num 42 should pass'; ok
fcfg_validate num  0         FLEET_X >/dev/null || fail 'num 0 should pass';  ok
fcfg_validate num  abc       FLEET_X >/dev/null && fail 'num abc should fail'; ok
fcfg_validate num  -1        FLEET_X >/dev/null && fail 'num -1 should fail';  ok
fcfg_validate num  ''        FLEET_X >/dev/null && fail 'num empty should fail'; ok
fcfg_validate bool 1         FLEET_X >/dev/null || fail 'bool 1 should pass'; ok
fcfg_validate bool 2         FLEET_X >/dev/null && fail 'bool 2 should fail'; ok
fcfg_validate enum opus      FLEET_MODEL >/dev/null || fail 'enum opus should pass'; ok
fcfg_validate enum ''        FLEET_MODEL >/dev/null || fail 'enum empty should pass'; ok
fcfg_validate enum claude-x  FLEET_MODEL >/dev/null || fail 'enum claude-x should pass'; ok
fcfg_validate enum gpt4      FLEET_MODEL >/dev/null && fail 'enum gpt4 should fail'; ok
fcfg_validate enum inherit   FLEET_MODEL >/dev/null && fail 'inherit invalid for FLEET_MODEL'; ok
fcfg_validate enum inherit   FLEET_SUBAGENT_MODEL >/dev/null || fail 'inherit valid for subagent'; ok
fcfg_validate str  '$HOME/x'   FLEET_NOTIFY_CMD >/dev/null || fail 'str $HOME/x should pass'; ok
fcfg_validate str  '${HOME}/x' FLEET_NOTIFY_CMD >/dev/null || fail 'str ${HOME} param-expansion should pass'; ok
fcfg_validate str  'a"b'       FLEET_NOTIFY_CMD >/dev/null && fail 'str with quote should fail'; ok
fcfg_validate str  'a`b'       FLEET_NOTIFY_CMD >/dev/null && fail 'str with backtick should fail'; ok
fcfg_validate str  '$(reboot)' FLEET_NOTIFY_CMD >/dev/null && fail 'str with $(…) command sub should fail'; ok
fcfg_validate str  'a\'        FLEET_NOTIFY_CMD >/dev/null && fail 'str trailing backslash should fail'; ok

# --- WRITE ------------------------------------------------------------------
NEW="$WORK/new.conf"
st=$(fcfg_write "$NEW" FLEET_MAX_SESSIONS 3 num)
eq 'write create status' "$st" created
[ -f "$NEW" ] || fail 'write did not create the file'; ok
v=$( . "$NEW"; printf '%s' "${FLEET_MAX_SESSIONS:-}" ); eq 'sourced after create' "$v" 3
# update in place → backup + single line
st=$(fcfg_write "$NEW" FLEET_MAX_SESSIONS 5 num)
eq 'write update status' "$st" updated
[ -f "$NEW.bak" ] || fail 'update did not back up'; ok
n=$(grep -cE '^FLEET_MAX_SESSIONS=' "$NEW"); eq 'no duplicate line' "$n" 1
v=$( . "$NEW"; printf '%s' "${FLEET_MAX_SESSIONS:-}" ); eq 'sourced after update' "$v" 5
# prefix-safe: FLEET_AUTOFILL must not clobber FLEET_AUTOFILL_MAX_PER_TICK
fcfg_write "$NEW" FLEET_AUTOFILL 1 bool >/dev/null
fcfg_write "$NEW" FLEET_AUTOFILL_MAX_PER_TICK 2 num >/dev/null
v=$( . "$NEW"; printf '%s' "${FLEET_AUTOFILL:-}" );              eq 'prefix key A' "$v" 1
v=$( . "$NEW"; printf '%s' "${FLEET_AUTOFILL_MAX_PER_TICK:-}" ); eq 'prefix key B' "$v" 2
n=$(grep -cE '^FLEET_AUTOFILL=' "$NEW"); eq 'AUTOFILL single line' "$n" 1
# string value with $-expansion + slashes survives verbatim in the file
fcfg_write "$NEW" FLEET_NOTIFY_CMD '$HOME/bin/notify.sh' str >/dev/null
grep -qF 'FLEET_NOTIFY_CMD="$HOME/bin/notify.sh"' "$NEW" || fail 'string write mangled the value'; ok
# and the whole conf still sources cleanly (the invariant that matters)
( set -e; . "$NEW" ) || fail 'written conf does not source cleanly'; ok
# an empty value (the '-' clear sentinel in the modal) writes KEY="" and sources
# back to empty — the documented "defer to default" path for enums.
fcfg_write "$NEW" FLEET_MODEL '' enum >/dev/null
grep -qxF 'FLEET_MODEL=""' "$NEW" || fail 'empty enum should write KEY=""'; ok
v=$( . "$NEW"; printf '%s' "${FLEET_MODEL-unset}" ); eq 'empty enum sources to empty' "$v" ''

# WRITE FAILURE must be reported (not a false success). A read-only dir makes the
# tmp-write/rename fail; fcfg_write must return non-zero and leave no orphan tmp.
# (root ignores mode bits — skip there so a root CI runner doesn't spuriously fail.)
if [ "$(id -u)" != 0 ]; then
  RO="$WORK/ro"; mkdir -p "$RO"; chmod 500 "$RO"
  if fcfg_write "$RO/x.conf" FLEET_MAX_SESSIONS 9 num >/dev/null 2>&1; then
    chmod 700 "$RO"; fail 'write to a read-only dir should return non-zero'
  fi
  ok
  [ -z "$(find "$RO" -name 'x.conf.tmp.*' 2>/dev/null)" ] || { chmod 700 "$RO"; fail 'failed write left an orphan tmp file'; }
  ok
  chmod 700 "$RO"
fi

printf 'selftest PASS: %d assertions (keys · typing · defaults · layering · validation · write)\n' "$pass"
exit 0
