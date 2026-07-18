#!/bin/bash
# tmux-config-selftest.sh — hermetic smoke test for bin/fleet-config-lib.sh (the
# prefix+c config modal, issues #83 + #89). No tmux, no fzf, no network.
#
# Asserts the modal's core contract against the REAL fleet.conf.example (so it
# also guards that the example stays parseable + fully annotated) plus TEMP
# global/per-fleet confs:
#   • KEY LIST      every FLEET_* key in the example is discovered.
#   • TAGS          @label/@group/@tier/@scope/@edit/@unit parse per key, and
#                   EVERY key carries a full tag line (no un-annotated drift).
#   • TYPING        @edit maps to the coarse validation class (int→num, etc.).
#   • DEFAULTS      parsed from the example (commented + uncommented lines).
#   • LAYERING      effective value + winning layer = per-fleet ▸ global ▸ default.
#   • VALIDATION    bad values by type are rejected; good ones pass; identity
#                   (@edit=no) always refuses; regex validity is enforced; a
#                   value that would break `source`-ing is refused.
#   • WRITE         create-on-first-write, in-place upsert (no dup lines), backup
#                   on update, prefix-safe keys, int bare / str quoted, and the
#                   written conf sources back to the value.
#   • WRITE-SCOPE   the g/f write-scope toggle persists + flips.
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
         FLEET_CLEANUP FLEET_CLEANUP_MAX_PER_TICK FLEET_NOTIFY_CMD \
         FLEET_DISK_FLOOR_GB FLEET_SPAWN_FOCUS FLEET_GH_TTL FLEET_CONF_DIR; do
  printf '%s\n' "$keys" | grep -qxF "$k" || fail "key list missing $k"
  ok
done

# --- TAGS: every key is fully annotated -------------------------------------
# No un-annotated drift: each key must carry a @label, a @scope in the allowed
# set, and an @edit in the allowed set.
while IFS= read -r k; do
  [ -n "$k" ] || continue
  [ -n "$(fcfg_tag "$k" label)" ] || fail "$k has no @label"
  case "$(fcfg_scope "$k")" in identity|global|fleet) : ;; *) fail "$k @scope invalid: $(fcfg_scope "$k")" ;; esac
  case "$(fcfg_edit  "$k")" in no|bool|int|enum|path|str|regex) : ;; *) fail "$k @edit invalid: $(fcfg_edit "$k")" ;; esac
  case "$(fcfg_tier  "$k")" in common|advanced) : ;; *) fail "$k @tier invalid: $(fcfg_tier "$k")" ;; esac
  ok
done <<EOF
$keys
EOF

# spot-check specific tag values (the declarative contract from the issue)
eq 'label FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_label FLEET_GLOBAL_MAX_SESSIONS)" 'Max sessions — all fleets'
eq 'group FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_group FLEET_GLOBAL_MAX_SESSIONS)" caps
eq 'tier  FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_tier  FLEET_GLOBAL_MAX_SESSIONS)" common
eq 'scope FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_scope FLEET_GLOBAL_MAX_SESSIONS)" global
eq 'edit  FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_edit  FLEET_GLOBAL_MAX_SESSIONS)" int
eq 'unit  FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_unit  FLEET_GLOBAL_MAX_SESSIONS)" sessions
eq 'scope FLEET_REPO (identity)'     "$(fcfg_scope FLEET_REPO)"                identity
eq 'edit  FLEET_REPO (identity)'     "$(fcfg_edit  FLEET_REPO)"                no
eq 'scope FLEET_MAX_SESSIONS'        "$(fcfg_scope FLEET_MAX_SESSIONS)"        fleet
eq 'edit  FLEET_PROTECTED_RE'        "$(fcfg_edit  FLEET_PROTECTED_RE)"        regex
eq 'edit  FLEET_NOTIFY_CMD'          "$(fcfg_edit  FLEET_NOTIFY_CMD)"          path
eq 'label FLEET_REPO fallback-free'  "$(fcfg_label FLEET_REPO)"                'GitHub repo'
# a key not in the example → sensible fallbacks (never crashes)
eq 'label fallback'  "$(fcfg_label FLEET_DOES_NOT_EXIST)" FLEET_DOES_NOT_EXIST
eq 'scope fallback'  "$(fcfg_scope FLEET_DOES_NOT_EXIST)" fleet
eq 'tier fallback'   "$(fcfg_tier  FLEET_DOES_NOT_EXIST)" common

# --- TABLE: fcfg_table agrees with the per-key accessors (no drift) ----------
# The single-pass batch parser must produce, for every key, exactly what the
# individual accessors return — otherwise the fast modal path diverges from the
# preview/edit path.
while IFS="$FCFG_US" read -r k label group tier scope edit unit def; do
  [ -n "$k" ] || continue
  eq "table label $k" "$label" "$(fcfg_label "$k")"
  eq "table group $k" "$group" "$(fcfg_group "$k")"
  eq "table tier  $k" "$tier"  "$(fcfg_tier  "$k")"
  eq "table scope $k" "$scope" "$(fcfg_scope "$k")"
  eq "table edit  $k" "$edit"  "$(fcfg_edit  "$k")"
  eq "table unit  $k" "$unit"  "$(fcfg_unit  "$k")"
  eq "table def   $k" "$def"   "$(fcfg_default "$k")"
done <<EOF
$(fcfg_table)
EOF
# the global daemon settings must be @scope=global (a per-fleet override is a
# silent no-op — the modal must not show a `fleet` per-fleet tag for them).
eq 'scope FLEET_GH_TTL'              "$(fcfg_scope FLEET_GH_TTL)"              global
eq 'scope FLEET_ISSUE_TTL'           "$(fcfg_scope FLEET_ISSUE_TTL)"           global
eq 'scope FLEET_PR_REFRESH_INTERVAL' "$(fcfg_scope FLEET_PR_REFRESH_INTERVAL)" global
# issue #237: the notifier (read only by the collector + diskguard daemons) and the
# status-bar container (read only by tmux-status.sh, global env) are now global-only.
eq 'scope FLEET_NOTIFY_CMD'          "$(fcfg_scope FLEET_NOTIFY_CMD)"          global
eq 'scope FLEET_STATUS_CONTAINER'    "$(fcfg_scope FLEET_STATUS_CONTAINER)"    global

# DRIFT GUARD (issue #237): fleet_load_conf strips exactly fleet-lib's
# $_FLEET_GLOBAL_ONLY from the per-fleet overlay, so that list MUST equal the set of
# keys the example tags @scope=global. If the two drift, a global-only key silently
# becomes per-fleet-overridable again (or a per-fleet key gets wrongly stripped).
# Extract the list from fleet-lib in a SUBSHELL so its unconditional FLEET_C reset
# can't clobber this test's isolated cache dir.
example_global=$(printf '%s\n' "$keys" | while IFS= read -r gk; do
  [ -n "$gk" ] || continue
  [ "$(fcfg_scope "$gk")" = global ] && printf '%s\n' "$gk"
done | sort | tr '\n' ' ')
lib_global=$( . "$BIN/fleet-lib.sh" >/dev/null 2>&1; printf '%s' "$_FLEET_GLOBAL_ONLY" | tr ' ' '\n' | sort | tr '\n' ' ' )
eq 'global-only list == example @scope=global set' "$example_global" "$lib_global"

# --- TYPING (fcfg_type derives from @edit) ----------------------------------
eq 'type FLEET_CLEANUP'       "$(fcfg_type FLEET_CLEANUP)"       bool
eq 'type FLEET_SPAWN_FOCUS'    "$(fcfg_type FLEET_SPAWN_FOCUS)"    bool
eq 'type FLEET_MODEL'          "$(fcfg_type FLEET_MODEL)"          enum
eq 'type FLEET_SUBAGENT_MODEL' "$(fcfg_type FLEET_SUBAGENT_MODEL)" enum
eq 'type FLEET_MERGE_METHOD'   "$(fcfg_type FLEET_MERGE_METHOD)"   enum
eq 'type FLEET_STEWARD_MODEL'  "$(fcfg_type FLEET_STEWARD_MODEL)"  enum
eq 'type FLEET_STEWARD_LITE'   "$(fcfg_type FLEET_STEWARD_LITE)"   bool
eq 'type FLEET_STEWARD_MCP'    "$(fcfg_type FLEET_STEWARD_MCP)"    bool
eq 'type FLEET_CTX_WINDOW'     "$(fcfg_type FLEET_CTX_WINDOW)"     num
eq 'type FLEET_MAX_SESSIONS'   "$(fcfg_type FLEET_MAX_SESSIONS)"   num
eq 'type FLEET_ISSUE_TTL'      "$(fcfg_type FLEET_ISSUE_TTL)"      num
eq 'type FLEET_REPO (no→str)'  "$(fcfg_type FLEET_REPO)"           str
eq 'type FLEET_NOTIFY_CMD'     "$(fcfg_type FLEET_NOTIFY_CMD)"     str
eq 'type FLEET_PROTECTED_RE'   "$(fcfg_type FLEET_PROTECTED_RE)"   str

# --- DEFAULTS ---------------------------------------------------------------
eq 'default FLEET_CTX_WINDOW'          "$(fcfg_default FLEET_CTX_WINDOW)"          200000
eq 'default FLEET_GLOBAL_MAX_SESSIONS' "$(fcfg_default FLEET_GLOBAL_MAX_SESSIONS)" 8
eq 'default FLEET_CLEANUP'            "$(fcfg_default FLEET_CLEANUP)"            1
eq 'default FLEET_MODEL'               "$(fcfg_default FLEET_MODEL)"               opus
eq 'default FLEET_DISK_FLOOR_GB'       "$(fcfg_default FLEET_DISK_FLOOR_GB)"       12
eq 'default FLEET_GH_TTL'              "$(fcfg_default FLEET_GH_TTL)"              90
[ -n "$(fcfg_short FLEET_REPO)" ] || fail 'short help for FLEET_REPO is empty'; ok
# short help must NOT leak the tag line
case "$(fcfg_short FLEET_REPO)" in *@label=*) fail 'short help leaked the tag line' ;; esac; ok
case "$(fcfg_full  FLEET_REPO)" in *@label=*) fail 'full help leaked the tag line' ;; esac; ok

# --- LAYERING ---------------------------------------------------------------
: > "$FCFG_GLOBAL_CONF"; : > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(default) val' "${ev%"$FCFG_US"*}" 200000
eq 'effective(default) src' "${ev##*"$FCFG_US"}" default
printf 'FLEET_CTX_WINDOW=300000\n' > "$FCFG_GLOBAL_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(global) val' "${ev%"$FCFG_US"*}" 300000
eq 'effective(global) src' "${ev##*"$FCFG_US"}" global
printf 'FLEET_CTX_WINDOW=1000000\n' > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(fleet) val' "${ev%"$FCFG_US"*}" 1000000
eq 'effective(fleet) src' "${ev##*"$FCFG_US"}" fleet
printf '#FLEET_MODEL=sonnet\n' > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_MODEL s1)
eq 'commented != set' "${ev##*"$FCFG_US"}" default

# --- VALIDATION -------------------------------------------------------------
fcfg_validate int  42        FLEET_X >/dev/null || fail 'int 42 should pass'; ok
fcfg_validate int  0         FLEET_X >/dev/null || fail 'int 0 should pass';  ok
fcfg_validate int  abc       FLEET_X >/dev/null && fail 'int abc should fail'; ok
fcfg_validate int  -1        FLEET_X >/dev/null && fail 'int -1 should fail';  ok
fcfg_validate num  7         FLEET_X >/dev/null || fail 'num alias should pass'; ok
fcfg_validate no   whatever  FLEET_REPO >/dev/null && fail 'edit=no should always refuse'; ok
fcfg_validate bool 1         FLEET_X >/dev/null || fail 'bool 1 should pass'; ok
fcfg_validate bool 2         FLEET_X >/dev/null && fail 'bool 2 should fail'; ok
fcfg_validate bool auto      FLEET_X >/dev/null && fail 'bool auto is not a valid bool (SELF_LAND retired #277)'; ok
fcfg_validate enum opus      FLEET_MODEL >/dev/null || fail 'enum opus should pass'; ok
fcfg_validate enum ''        FLEET_MODEL >/dev/null || fail 'enum empty should pass'; ok
fcfg_validate enum claude-x  FLEET_MODEL >/dev/null || fail 'enum claude-x should pass'; ok
fcfg_validate enum gpt4      FLEET_MODEL >/dev/null && fail 'enum gpt4 should fail'; ok
fcfg_validate enum inherit   FLEET_MODEL >/dev/null && fail 'inherit invalid for FLEET_MODEL'; ok
fcfg_validate enum inherit   FLEET_SUBAGENT_MODEL >/dev/null || fail 'inherit valid for subagent'; ok
# FLEET_STEWARD_MODEL is a plain model enum (issue #284) — aliases + claude-* + empty,
# but NOT "inherit" (that's a subagent-only shape).
fcfg_validate enum sonnet    FLEET_STEWARD_MODEL >/dev/null || fail 'enum sonnet valid for steward model'; ok
fcfg_validate enum ''        FLEET_STEWARD_MODEL >/dev/null || fail 'empty valid for steward model'; ok
fcfg_validate enum inherit   FLEET_STEWARD_MODEL >/dev/null && fail 'inherit invalid for steward model'; ok
fcfg_validate bool 1         FLEET_STEWARD_LITE  >/dev/null || fail 'bool 1 valid for steward lite'; ok
fcfg_validate bool 2         FLEET_STEWARD_LITE  >/dev/null && fail 'bool 2 invalid for steward lite'; ok
# FLEET_HANDOFF_DEST is an enum over its OWN set (comment|file|empty), issue #275.
fcfg_validate enum comment   FLEET_HANDOFF_DEST >/dev/null || fail 'comment valid for FLEET_HANDOFF_DEST'; ok
fcfg_validate enum file      FLEET_HANDOFF_DEST >/dev/null || fail 'file valid for FLEET_HANDOFF_DEST'; ok
fcfg_validate enum ''        FLEET_HANDOFF_DEST >/dev/null || fail 'empty valid for FLEET_HANDOFF_DEST'; ok
fcfg_validate enum opus      FLEET_HANDOFF_DEST >/dev/null && fail 'model alias invalid for FLEET_HANDOFF_DEST'; ok
# FLEET_MERGE_METHOD is an enum over its OWN set (squash|merge|rebase|empty), issue #283.
fcfg_validate enum squash    FLEET_MERGE_METHOD >/dev/null || fail 'squash valid for FLEET_MERGE_METHOD'; ok
fcfg_validate enum merge     FLEET_MERGE_METHOD >/dev/null || fail 'merge valid for FLEET_MERGE_METHOD'; ok
fcfg_validate enum rebase    FLEET_MERGE_METHOD >/dev/null || fail 'rebase valid for FLEET_MERGE_METHOD'; ok
fcfg_validate enum ''        FLEET_MERGE_METHOD >/dev/null || fail 'empty valid for FLEET_MERGE_METHOD'; ok
fcfg_validate enum opus      FLEET_MERGE_METHOD >/dev/null && fail 'model alias invalid for FLEET_MERGE_METHOD'; ok
fcfg_validate enum fast      FLEET_MERGE_METHOD >/dev/null && fail 'garbage invalid for FLEET_MERGE_METHOD'; ok
fcfg_validate enum comment   FLEET_MODEL >/dev/null && fail 'comment invalid for FLEET_MODEL'; ok
fcfg_validate regex '^(a|b)$' FLEET_PROTECTED_RE >/dev/null || fail 'valid regex should pass'; ok
fcfg_validate regex '^(a'    FLEET_PROTECTED_RE >/dev/null && fail 'invalid regex should fail'; ok
fcfg_validate regex 'a`b'    FLEET_PROTECTED_RE >/dev/null && fail 'regex with backtick should fail'; ok
fcfg_validate path '$HOME/x'   FLEET_NOTIFY_CMD >/dev/null || fail 'path $HOME/x should pass'; ok
fcfg_validate str  '$HOME/x'   FLEET_NOTIFY_CMD >/dev/null || fail 'str $HOME/x should pass'; ok
fcfg_validate str  '${HOME}/x' FLEET_NOTIFY_CMD >/dev/null || fail 'str ${HOME} param-expansion should pass'; ok
fcfg_validate str  'a"b'       FLEET_NOTIFY_CMD >/dev/null && fail 'str with quote should fail'; ok
fcfg_validate str  'a`b'       FLEET_NOTIFY_CMD >/dev/null && fail 'str with backtick should fail'; ok
fcfg_validate str  '$(reboot)' FLEET_NOTIFY_CMD >/dev/null && fail 'str with $(…) command sub should fail'; ok
fcfg_validate str  'a\'        FLEET_NOTIFY_CMD >/dev/null && fail 'str trailing backslash should fail'; ok

# --- MODEL-ALIAS SOURCE OF TRUTH (issue #415) -------------------------------
# `fable` is now a first-class alias on every model key — it used to be rejected
# (the immediate bug): the validator and the picker each hardcoded a stale list.
fcfg_validate enum fable FLEET_MODEL          >/dev/null || fail 'fable valid for FLEET_MODEL'; ok
fcfg_validate enum fable FLEET_SUBAGENT_MODEL >/dev/null || fail 'fable valid for FLEET_SUBAGENT_MODEL'; ok
fcfg_validate enum fable FLEET_STEWARD_MODEL  >/dev/null || fail 'fable valid for FLEET_STEWARD_MODEL'; ok

# fcfg_is_model_key partitions the enum keys the model picker/validator apply to.
fcfg_is_model_key FLEET_MODEL          || fail 'FLEET_MODEL is a model key'; ok
fcfg_is_model_key FLEET_STEWARD_MODEL  || fail 'FLEET_STEWARD_MODEL is a model key'; ok
fcfg_is_model_key FLEET_HANDOFF_DEST   && fail 'FLEET_HANDOFF_DEST is not a model key'; ok

# fcfg_model_aliases is the ONE list, and it is key-aware: every model key offers
# fable; only the subagent key offers `inherit`.
ma_model=$(fcfg_model_aliases FLEET_MODEL          | cut -d"$FCFG_US" -f1 | tr '\n' ' ')
ma_sub=$(  fcfg_model_aliases FLEET_SUBAGENT_MODEL | cut -d"$FCFG_US" -f1 | tr '\n' ' ')
case " $ma_model " in *' fable '*)   ok ;; *) fail "fcfg_model_aliases missing fable: $ma_model" ;; esac
case " $ma_model " in *' inherit '*) fail "FLEET_MODEL must NOT offer inherit: $ma_model" ;; *) ok ;; esac
case " $ma_sub "   in *' inherit '*) ok ;; *) fail "FLEET_SUBAGENT_MODEL must offer inherit: $ma_sub" ;; esac

# PICKER ⇔ VALIDATOR: every token the picker can offer for an enum key (from
# fcfg_enum_options, what dash-config-edit reads) must also validate for that key.
# Ties the offered set to the accepted set for EVERY enum key so they can't drift.
for k in FLEET_MODEL FLEET_SUBAGENT_MODEL FLEET_STEWARD_MODEL FLEET_HANDOFF_DEST FLEET_MERGE_METHOD; do
  while IFS="$FCFG_US" read -r tok _ann; do
    [ -n "$tok" ] || continue
    fcfg_validate enum "$tok" "$k" >/dev/null || fail "picker offers '$tok' for $k but the validator rejects it"
    ok
  done <<EOF
$(fcfg_enum_options "$k")
EOF
done

# No SECOND hardcoded alias list — the tier aliases live only in fcfg_model_aliases
# (one token per printf line), never as a `sonnet|haiku` / `sonnet | haiku` pipe
# list in the lib or the editor (the "exactly ONE place" acceptance, issue #415).
for f in "$LIB" "$BIN/dash-config-edit.sh"; do
  grep -nE 'sonnet[[:space:]]*\|[[:space:]]*haiku' "$f" >/dev/null 2>&1 \
    && fail "stale hardcoded alias list in ${f##*/} — drive it from fcfg_model_aliases"
  ok
done

# --- WRITE ------------------------------------------------------------------
NEW="$WORK/new.conf"
st=$(fcfg_write "$NEW" FLEET_MAX_SESSIONS 3 int)
eq 'write create status' "$st" created
[ -f "$NEW" ] || fail 'write did not create the file'; ok
v=$( . "$NEW"; printf '%s' "${FLEET_MAX_SESSIONS:-}" ); eq 'sourced after create' "$v" 3
grep -qxF 'FLEET_MAX_SESSIONS=3' "$NEW" || fail 'int should write bare (no quotes)'; ok
st=$(fcfg_write "$NEW" FLEET_MAX_SESSIONS 5 int)
eq 'write update status' "$st" updated
[ -f "$NEW.bak" ] || fail 'update did not back up'; ok
n=$(grep -cE '^FLEET_MAX_SESSIONS=' "$NEW"); eq 'no duplicate line' "$n" 1
v=$( . "$NEW"; printf '%s' "${FLEET_MAX_SESSIONS:-}" ); eq 'sourced after update' "$v" 5
# prefix-safe: FLEET_CLEANUP must not clobber FLEET_CLEANUP_MAX_PER_TICK
fcfg_write "$NEW" FLEET_CLEANUP 1 bool >/dev/null
fcfg_write "$NEW" FLEET_CLEANUP_MAX_PER_TICK 2 int >/dev/null
v=$( . "$NEW"; printf '%s' "${FLEET_CLEANUP:-}" );              eq 'prefix key A' "$v" 1
v=$( . "$NEW"; printf '%s' "${FLEET_CLEANUP_MAX_PER_TICK:-}" ); eq 'prefix key B' "$v" 2
n=$(grep -cE '^FLEET_CLEANUP=' "$NEW"); eq 'CLEANUP single line' "$n" 1
# string value with $-expansion + slashes survives verbatim in the file
fcfg_write "$NEW" FLEET_NOTIFY_CMD '$HOME/bin/notify.sh' path >/dev/null
grep -qF 'FLEET_NOTIFY_CMD="$HOME/bin/notify.sh"' "$NEW" || fail 'path write mangled the value'; ok
# regex value round-trips as a quoted string and sources cleanly
fcfg_write "$NEW" FLEET_PROTECTED_RE '^(master|main)$' regex >/dev/null
grep -qF 'FLEET_PROTECTED_RE="^(master|main)$"' "$NEW" || fail 'regex write mangled the value'; ok
( set -e; . "$NEW" ) || fail 'written conf does not source cleanly'; ok
# an empty value (the '-' clear sentinel) writes KEY="" and sources back to empty
fcfg_write "$NEW" FLEET_MODEL '' enum >/dev/null
grep -qxF 'FLEET_MODEL=""' "$NEW" || fail 'empty enum should write KEY=""'; ok
v=$( . "$NEW"; printf '%s' "${FLEET_MODEL-unset}" ); eq 'empty enum sources to empty' "$v" ''

# --- WRITE-SCOPE toggle (the g/f layer selector) ----------------------------
eq 'default write-scope' "$(fcfg_wscope s1)" fleet
fcfg_wscope_toggle s1
eq 'toggled write-scope' "$(fcfg_wscope s1)" global
fcfg_wscope_set s1 fleet
eq 'set write-scope back' "$(fcfg_wscope s1)" fleet

# WRITE FAILURE must be reported (not a false success). A read-only dir makes the
# tmp-write/rename fail; fcfg_write must return non-zero and leave no orphan tmp.
# (root ignores mode bits — skip there so a root CI runner doesn't spuriously fail.)
if [ "$(id -u)" != 0 ]; then
  RO="$WORK/ro"; mkdir -p "$RO"; chmod 500 "$RO"
  if fcfg_write "$RO/x.conf" FLEET_MAX_SESSIONS 9 int >/dev/null 2>&1; then
    chmod 700 "$RO"; fail 'write to a read-only dir should return non-zero'
  fi
  ok
  [ -z "$(find "$RO" -name 'x.conf.tmp.*' 2>/dev/null)" ] || { chmod 700 "$RO"; fail 'failed write left an orphan tmp file'; }
  ok
  chmod 700 "$RO"
fi

printf 'selftest PASS: %d assertions (keys · tags · typing · defaults · layering · validation · write · write-scope)\n' "$pass"
exit 0
