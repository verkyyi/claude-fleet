#!/bin/bash
# tmux-config-selftest.sh — hermetic smoke test for bin/fleet-config-lib.sh (the
# prefix+c config modal, issues #83 + #89). No tmux, no fzf, no network.
#
# Asserts the modal's core contract against the REAL fleet.conf.example (so it
# also guards that the example stays parseable + fully annotated) plus TEMP
# install/login/per-fleet confs:
#   • KEY LIST      every FLEET_* key in the example is discovered.
#   • TAGS          @label/@group/@tier/@scope/@edit/@unit parse per key, and
#                   EVERY key carries a full tag line (no un-annotated drift).
#   • TYPING        @edit maps to the coarse validation class (int→num, etc.).
#   • DEFAULTS      parsed from the example (commented + uncommented lines).
#   • LAYERING      effective value + winning layer = this fleet (fleet conf ▸
#                   fleet.settings) ▸ legacy install fleet.conf ▸ default; a
#                   global-only key skips the fleet conf (fleet_load_conf strips it).
#   • VALIDATION    bad values by type are rejected; good ones pass; identity
#                   (@edit=no) always refuses; regex validity is enforced; a
#                   value that would break `source`-ing is refused.
#   • WRITE         create-on-first-write, in-place upsert (no dup lines), backup
#                   on update, prefix-safe keys, int bare / str quoted, and the
#                   written conf sources back to the value.
#   • WRITE-SCOPE   (issue #1102) the ⌃s toggle is fleet ⇄ repo:<slug> only —
#                   no global scope; a key's write lands by fcfg_key_wscope
#                   (global-only → fleet.settings, else the fleet conf, per-repo
#                   under a repo scope → the repo), never the install fleet.conf.
#   • REPO SCOPE    (issue #802) every hosted repo is a repo:<slug> scope — a
#                   one-repo fleet's too, whose repo layer IS its fleet conf (no
#                   repos/ is ever created); per-repo keys resolve + write per repo;
#                   the modal's rows show the repo's value; the editor writes a
#                   non-repo key under a repo scope to the fleet instead of refusing,
#                   and a global-only key to fleet.settings, which fleet-lib reads.
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
export FCFG_SETTINGS_CONF="$WORK/fleet.settings"
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
  case "$(fcfg_tier  "$k")" in common|advanced|internal) : ;; *) fail "$k @tier invalid: $(fcfg_tier "$k")" ;; esac
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
$(fcfg_table --all)
EOF

# --- INTERNAL TIER (issue #1101) ----------------------------------------------
# The default table is the settings you might change: @tier=internal rows (pacing,
# budgets, timeouts) are left out, and the panel face stays ≤ 120 rows so the list
# cannot quietly grow back. `--all` / FLEET_CONFIG_SHOW_INTERNAL=1 is every key;
# an internal key still resolves its default (callers' ${FLEET_X:-d} untouched).
n_def=$(fcfg_table | grep -c .); n_all=$(fcfg_table --all | grep -c .)
[ "$n_def" -le 120 ] || fail "default fcfg_table has $n_def rows — the panel face is capped at 120"; ok
eq 'fcfg_table --all = every key' "$n_all" "$(printf '%s\n' "$keys" | grep -c .)"
eq 'FLEET_CONFIG_SHOW_INTERNAL=1 = --all' "$(FLEET_CONFIG_SHOW_INTERNAL=1 fcfg_table | grep -c .)" "$n_all"
fcfg_table | cut -d"$FCFG_US" -f4 | grep -qx internal && fail 'default fcfg_table lists an internal row'; ok
eq 'tier FLEET_COLLECT_GIT_BUDGET' "$(fcfg_tier FLEET_COLLECT_GIT_BUDGET)" internal
eq 'internal default still resolves' "$(fcfg_default FLEET_COLLECT_GIT_BUDGET)" 30
fcfg_table | cut -d"$FCFG_US" -f1 | grep -qx FLEET_COLLECT_GIT_BUDGET && fail 'internal key in the default view'; ok
# The two settings the charter pins must stay on the face.
for k in FLEET_MAX_SESSIONS FLEET_GLOBAL_MAX_SESSIONS FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH; do
  fcfg_table | cut -d"$FCFG_US" -f1 | grep -qx "$k" || fail "$k must stay in the default view"; ok
done
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
eq 'type FLEET_AGENT'          "$(fcfg_type FLEET_AGENT)"          enum
eq 'type FLEET_CHILD_REPORT'   "$(fcfg_type FLEET_CHILD_REPORT)"   enum   # not bool (issue #968)
eq 'type FLEET_CODEX_MODEL'    "$(fcfg_type FLEET_CODEX_MODEL)"    str
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
eq 'default FLEET_CHILD_REPORT'        "$(fcfg_default FLEET_CHILD_REPORT)"        immediate
[ -n "$(fcfg_short FLEET_REPO)" ] || fail 'short help for FLEET_REPO is empty'; ok
# short help must NOT leak the tag line
case "$(fcfg_short FLEET_REPO)" in *@label=*) fail 'short help leaked the tag line' ;; esac; ok
case "$(fcfg_full  FLEET_REPO)" in *@label=*) fail 'full help leaked the tag line' ;; esac; ok

# --- LAYERING ---------------------------------------------------------------
: > "$FCFG_GLOBAL_CONF"; : > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(default) val' "${ev%"$FCFG_US"*}" 200000
eq 'effective(default) src' "${ev##*"$FCFG_US"}" default
# The install's fleet.conf is still READ — an old install loads unchanged — and
# shows as the read-only legacy layer.
printf 'FLEET_CTX_WINDOW=300000\n' > "$FCFG_GLOBAL_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(legacy) val' "${ev%"$FCFG_US"*}" 300000
eq 'effective(legacy) src' "${ev##*"$FCFG_US"}" legacy
# The login's fleet.settings wins over it, and is "this fleet" to the user.
printf 'FLEET_CTX_WINDOW=400000\n' > "$FCFG_SETTINGS_CONF"
ev=$(fcfg_effective FLEET_CTX_WINDOW s1)
eq 'effective(settings) val' "${ev%"$FCFG_US"*}" 400000
eq 'effective(settings) src' "${ev##*"$FCFG_US"}" fleet
rm -f "$FCFG_SETTINGS_CONF"
# A global-only key in a fleet conf is stripped at load, so it is never "in effect".
printf 'FLEET_GH_TTL=5\n' > "$FCFG_FLEET_CONF"
ev=$(fcfg_effective FLEET_GH_TTL s1)
eq 'global-only skips fleet conf' "$ev" "90${FCFG_US}default"
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
# FLEET_AGENT is an enum over its OWN set (claude|codex|empty), issue #547.
fcfg_validate enum claude    FLEET_AGENT >/dev/null || fail 'claude valid for FLEET_AGENT'; ok
fcfg_validate enum codex     FLEET_AGENT >/dev/null || fail 'codex valid for FLEET_AGENT'; ok
fcfg_validate enum ''        FLEET_AGENT >/dev/null || fail 'empty valid for FLEET_AGENT'; ok
fcfg_validate enum opus      FLEET_AGENT >/dev/null && fail 'model alias invalid for FLEET_AGENT'; ok
fcfg_validate enum gemini    FLEET_AGENT >/dev/null && fail 'unknown agent invalid for FLEET_AGENT'; ok
# FLEET_CHILD_REPORT is an enum over its OWN set (immediate|batch|0|empty), issue
# #968 — it was tagged @edit=bool, so the modal could only toggle 0/1 and `batch`
# (issue #939) had to be hand-written. The legacy `1` still validates.
fcfg_validate enum immediate FLEET_CHILD_REPORT >/dev/null || fail 'immediate valid for FLEET_CHILD_REPORT'; ok
fcfg_validate enum batch     FLEET_CHILD_REPORT >/dev/null || fail 'batch valid for FLEET_CHILD_REPORT'; ok
fcfg_validate enum 0         FLEET_CHILD_REPORT >/dev/null || fail '0 valid for FLEET_CHILD_REPORT'; ok
fcfg_validate enum 1         FLEET_CHILD_REPORT >/dev/null || fail 'legacy 1 valid for FLEET_CHILD_REPORT'; ok
fcfg_validate enum ''        FLEET_CHILD_REPORT >/dev/null || fail 'empty valid for FLEET_CHILD_REPORT'; ok
fcfg_validate enum on        FLEET_CHILD_REPORT >/dev/null && fail 'on invalid for FLEET_CHILD_REPORT'; ok
fcfg_validate enum opus      FLEET_CHILD_REPORT >/dev/null && fail 'model alias invalid for FLEET_CHILD_REPORT'; ok
cr_opts=$(fcfg_enum_options FLEET_CHILD_REPORT | cut -d"$FCFG_US" -f1 | paste -sd' ' -)
eq 'picker offers immediate/batch/0 for FLEET_CHILD_REPORT' "$cr_opts" 'immediate batch 0'
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

# fcfg_is_model_key partitions the enum keys the model picker/validator apply to.
fcfg_is_model_key FLEET_MODEL          || fail 'FLEET_MODEL is a model key'; ok
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
for k in FLEET_MODEL FLEET_SUBAGENT_MODEL FLEET_HANDOFF_DEST FLEET_MERGE_METHOD FLEET_AGENT FLEET_SLEEP FLEET_SLEEP_WAKE FLEET_CHILD_REPORT; do
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

# --- WRITE-SCOPE toggle (fleet ⇄ repo, issue #1102) --------------------------
eq 'default write-scope' "$(fcfg_wscope s1)" fleet
# No fleet-lib in scope here ⇒ no repo scopes ⇒ ⌃s has nowhere else to go —
# and in particular never to a global scope.
fcfg_wscope_toggle s1
eq 'toggle without repos stays fleet' "$(fcfg_wscope s1)" fleet
# A `global` persisted by an older modal reads back as fleet.
fcfg_wscope_set s1 global
eq 'stale global scope → fleet' "$(fcfg_wscope s1)" fleet
fcfg_wscope_set s1 fleet
eq 'scope label' "$(fcfg_wscope_label s1)" FLEET
# Where an edit lands: global-only → the login's fleet.settings, identity → none,
# everything else → the fleet conf. Never the install's (legacy) fleet.conf.
eq 'key wscope global-only' "$(fcfg_key_wscope s1 FLEET_GLOBAL_MAX_SESSIONS)" global
eq 'key wscope per-fleet'   "$(fcfg_key_wscope s1 FLEET_MAX_SESSIONS)" fleet
fcfg_key_wscope s1 FLEET_REPO >/dev/null && fail 'identity key has a write scope'; ok
eq 'global target = fleet.settings' "$(fcfg_target_conf s1 global)" "$FCFG_SETTINGS_CONF"
eq 'fleet target = fleet conf'      "$(fcfg_target_conf s1 fleet)"  "$FCFG_FLEET_CONF"
eq 'no-session target = settings'   "$(FCFG_FLEET_CONF='' fcfg_target_conf '' fleet)" "$FCFG_SETTINGS_CONF"

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

# --- REPO SCOPE (issue #802) -------------------------------------------------
# A real fleet-lib over a temp FLEET_CONF_DIR: fleet s2 hosts o/a (its conf) and,
# once an overlay exists, o/b. FCFG_FLEET_CONF is dropped so the lib resolves the
# fleet conf the way the modal does.
unset FCFG_FLEET_CONF
export FLEET_CONF_DIR="$WORK/confdir"
mkdir -p "$FLEET_CONF_DIR/fleets/s2"
F2="$FLEET_CONF_DIR/fleets/s2/conf"
printf 'FLEET_REPO="o/a"\nFLEET_MODEL="sonnet"\nFLEET_DEPLOY_CHECK="actions"\n' > "$F2"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# One-repo fleet (no repos/ overlay): one repo scope, for its one repo, so ⌃s is
# fleet ⇄ repo:o-a — and that repo layer IS the fleet conf: an edit there writes
# F2 and never creates repos/, so the degenerate fleet stays a degenerate fleet.
eq 'one-repo: one repo scope' "$(fcfg_repo_scopes s2 | cut -d"$FCFG_US" -f1)" repo:o-a
fcfg_wscope_toggle s2; eq 'one-repo toggle → repo' "$(fcfg_wscope s2)" repo:o-a
eq 'one-repo scope label' "$(fcfg_wscope_label s2)" 'REPO o/a'
eq 'one-repo repo target = fleet conf' "$(fcfg_target_conf s2 repo:o-a)" "$F2"
eq 'one-repo per-repo key → repo'      "$(fcfg_key_wscope s2 FLEET_MODEL)" repo:o-a
eq 'one-repo non-repo key → fleet'     "$(fcfg_key_wscope s2 FLEET_MAX_SESSIONS)" fleet
eq 'one-repo global-only key → global' "$(fcfg_key_wscope s2 FLEET_GLOBAL_MAX_SESSIONS)" global
cp "$F2" "$WORK/F2.keep"
eq 'one-repo repo write' "$(fcfg_repo_write s2 o-a FLEET_AGENT codex enum)" updated
eq 'one-repo write lands in fleet conf' "$(fcfg_file_value "$F2" FLEET_AGENT)" codex
[ -e "$FLEET_CONF_DIR/fleets/s2/repos" ] && fail 'one-repo repo write created repos/'; ok
mv "$WORK/F2.keep" "$F2"; rm -f "$F2.bak"
fcfg_wscope_toggle s2; eq 'one-repo toggle → fleet' "$(fcfg_wscope s2)" fleet

# Shim tmux so the modal resolves session s2 with no server.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\ncase "$1" in display-message) echo s2 ;; esac\nexit 0\n' > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
rows() { PATH="$SHIM:$PATH" bash "$BIN/tmux-config.sh" rows | sed 's/\x1b\[[0-9;]*m//g'; }
ROWS1=$(rows)
# The INTERNAL header is the modal's "show all" switch (issue #1101): collapsed,
# no internal key is a row; expanded, every one is.
printf '%s\n' "$ROWS1" | grep -q '^@@TOGGLE@@internal.*INTERNAL' || fail 'modal lacks the INTERNAL (show all) header'; ok
printf '%s\n' "$ROWS1" | grep -q '^FLEET_COLLECT_GIT_BUDGET' && fail 'collapsed modal lists an internal key'; ok
PATH="$SHIM:$PATH" bash "$BIN/tmux-config.sh" toggle-bucket @@TOGGLE@@internal
R=$(rows)
eq 'expanded INTERNAL lists every internal key' \
  "$(printf '%s\n' "$R" | grep -cE '^FLEET_[A-Z0-9_]+'"$FCFG_US")" \
  "$(fcfg_table --all | cut -d"$FCFG_US" -f1,4 | grep -c "${FCFG_US}internal$" | awk -v n="$(printf '%s\n' "$ROWS1" | grep -cE '^FLEET_[A-Z0-9_]+'"$FCFG_US")" '{print $1+n}')"
PATH="$SHIM:$PATH" bash "$BIN/tmux-config.sh" toggle-bucket @@TOGGLE@@internal
eq 'collapsing INTERNAL restores the rows' "$(rows)" "$ROWS1"

mkdir -p "$FLEET_CONF_DIR/fleets/s2/repos"
printf 'FLEET_REPO="o/b"\nFLEET_MAIN="/tmp/b"\nFLEET_MODEL="opus"\n' > "$FLEET_CONF_DIR/fleets/s2/repos/o-b.conf"
eq 'repo scopes' "$(fcfg_repo_scopes s2 | cut -d"$FCFG_US" -f1 | paste -sd' ' -)" 'repo:o-a repo:o-b'
eq 'scope → repo' "$(fcfg_scope_repo s2 repo:o-b)" o/b
fcfg_scope_repo s2 repo:nope >/dev/null && fail 'unhosted scope resolved'; ok
# The cycle: fleet → repo:o-a → repo:o-b → fleet — no global stop (issue #1102).
fcfg_wscope_toggle s2; eq 'cycle 1' "$(fcfg_wscope s2)" repo:o-a
fcfg_wscope_toggle s2; eq 'cycle 2' "$(fcfg_wscope s2)" repo:o-b
eq 'scope label' "$(fcfg_wscope_label s2)" 'REPO o/b'
fcfg_wscope_toggle s2; eq 'cycle 3' "$(fcfg_wscope s2)" fleet
fcfg_wscope_set s2 repo:gone; eq 'stale repo scope → fleet' "$(fcfg_wscope s2)" fleet

# Keys + targets.
for k in FLEET_MODEL FLEET_AGENT FLEET_MCP_CONFIG FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK FLEET_WORKTREE_SETUP; do
  fcfg_is_repo_key "$k" || fail "$k should be a per-repo key"; ok
done
fcfg_is_repo_key FLEET_MAX_SESSIONS && fail 'FLEET_MAX_SESSIONS is not per-repo'; ok
eq 'repo target' "$(fcfg_target_conf s2 repo:o-b)" "$FLEET_CONF_DIR/fleets/s2/repos/o-b.conf"
eq 'unhosted repo target is empty' "$(fcfg_target_conf s2 repo:gone)" ''

# Effective value per repo: own overlay ▸ fleet conf ▸ … — and a deploy key does
# NOT leak from the conf repo into another repo (fleet-lib unsets it).
eq 'o/b model (own overlay)' "$(fcfg_repo_effective FLEET_MODEL s2 o/b)" "opus${FCFG_US}repo"
eq 'o/a model (fleet conf)'  "$(fcfg_repo_effective FLEET_MODEL s2 o/a)" "sonnet${FCFG_US}fleet"
eq 'o/a deploy (fleet conf)' "$(fcfg_repo_effective FLEET_DEPLOY_CHECK s2 o/a)" "actions${FCFG_US}fleet"
eq 'o/b deploy (no leak)'    "$(fcfg_repo_effective FLEET_DEPLOY_CHECK s2 o/b)" "${FCFG_US}default"
# …and it agrees with what a reader loading the repo conf actually sees.
eq 'o/b model = fleet_repo_conf_get' "$(fleet_repo_conf_get s2 o/b FLEET_MODEL)" opus
eq 'o/b deploy = fleet_repo_conf_get' "$(fleet_repo_conf_get s2 o/b FLEET_DEPLOY_CHECK)" ''

# Write: into o/b's overlay; the conf repo's first write CREATES its overlay,
# seeded with FLEET_REPO so fleet_repos still lists it once.
eq 'repo write updates' "$(fcfg_repo_write s2 o-b FLEET_AGENT codex enum)" updated
eq 'o/b agent after write' "$(fleet_repo_conf_get s2 o/b FLEET_AGENT)" codex
eq 'fleet conf untouched' "$(fcfg_file_value "$F2" FLEET_AGENT || echo unset)" unset
eq 'conf-repo write creates' "$(fcfg_repo_write s2 o-a FLEET_MODEL haiku enum)" created
eq 'conf-repo overlay seeded' "$(fcfg_file_value "$FLEET_CONF_DIR/fleets/s2/repos/o-a.conf" FLEET_REPO)" o/a
eq 'o/a model after write' "$(fleet_repo_conf_get s2 o/a FLEET_MODEL)" haiku
eq 'o/b model unaffected'  "$(fleet_repo_conf_get s2 o/b FLEET_MODEL)" opus
eq 'repos listed once' "$(fleet_repos s2 | paste -sd' ' -)" 'o/a o/b'
fcfg_repo_write s2 gone FLEET_MODEL opus enum >/dev/null 2>&1 && fail 'write to an unhosted repo succeeded'; ok

# The modal's rows in repo scope show the repo's own value, marked `▸ repo`.
fcfg_wscope_set s2 repo:o-b
R=$(rows)
printf '%s\n' "$R" | grep '^FLEET_AGENT' | grep -q 'codex.*▸ repo' || fail "repo-scope row lacks o/b's agent: $(printf '%s\n' "$R" | grep '^FLEET_AGENT')"; ok
printf '%s\n' "$R" | grep '^@@NOOP@@' | head -1 | grep -q 'o/b.*REPO o/b' || fail 'context row does not name the repo scope'; ok
PATH="$SHIM:$PATH" bash "$BIN/tmux-config.sh" preview FLEET_MODEL | sed 's/\x1b\[[0-9;]*m//g' > "$WORK/pv"
grep -q 'per repo' "$WORK/pv" && grep -qE 'o/a +haiku' "$WORK/pv" && grep -qE 'o/b +opus' "$WORK/pv" \
  || fail "preview lacks the per-repo values: $(cat "$WORK/pv")"; ok
# The EDITOR end to end (issue #1102): under a repo scope, a key that is not
# per-repo is WRITTEN to this fleet — never refused for the "wrong layer" — and a
# global-only key lands in the login's fleet.settings, which fleet_load_conf's
# caller (fleet-lib) then reads. The install's fleet.conf is read, never written.
edit() { printf '%s\n' "$2" | PATH="$SHIM:$PATH" bash "$BIN/dash-config-edit.sh" "$1" >/dev/null 2>&1; }
unset FCFG_SETTINGS_CONF
printf 'FLEET_GLOBAL_MAX_SESSIONS=5\nFLEET_MAX_SESSIONS=4\n' > "$FCFG_GLOBAL_CONF"
cp "$FCFG_GLOBAL_CONF" "$WORK/install.keep"
fcfg_wscope_set s2 repo:o-b
edit FLEET_MAX_SESSIONS 6
eq 'repo scope: non-repo key → fleet conf' "$(fcfg_file_value "$F2" FLEET_MAX_SESSIONS)" 6
eq 'repo scope: o/b overlay untouched' "$(fcfg_file_value "$FLEET_CONF_DIR/fleets/s2/repos/o-b.conf" FLEET_MAX_SESSIONS || echo unset)" unset
edit FLEET_GLOBAL_MAX_SESSIONS 9
eq 'global-only → fleet.settings' "$(fcfg_file_value "$FLEET_CONF_DIR/fleet.settings" FLEET_GLOBAL_MAX_SESSIONS)" 9
eq 'global-only not in fleet conf' "$(fcfg_file_value "$F2" FLEET_GLOBAL_MAX_SESSIONS || echo unset)" unset
eq 'install fleet.conf never written' "$(cat "$FCFG_GLOBAL_CONF")" "$(cat "$WORK/install.keep")"
edit FLEET_DEPLOY_REF origin/prod
eq 'repo scope: per-repo key → o/b overlay' "$(fcfg_file_value "$FLEET_CONF_DIR/fleets/s2/repos/o-b.conf" FLEET_DEPLOY_REF)" origin/prod
# The enum PICKER end to end (issue #968): FLEET_CHILD_REPORT is chosen from the
# fzf menu, not toggled as a bool. A stand-in fzf hands back the row whose token
# is $FCFG_TEST_PICK, so this drives the editor's real enum branch (rows → fzf →
# token → validate → write), and the write is the quoted enum form the digest
# reads: FLEET_CHILD_REPORT="batch".
PICK="$WORK/pick"; mkdir -p "$PICK"
cat > "$PICK/fzf" <<'EOF'
#!/bin/sh
awk -v want="$FCFG_TEST_PICK" 'BEGIN{FS="\037"} $1==want{print; exit}'
EOF
chmod +x "$PICK/fzf"
pick() { FCFG_TEST_PICK="$2" PATH="$PICK:$SHIM:$PATH" bash "$BIN/dash-config-edit.sh" "$1" </dev/null >/dev/null 2>&1; }
pick FLEET_CHILD_REPORT batch
grep -qxF 'FLEET_CHILD_REPORT="batch"' "$F2" || fail "picking batch did not write FLEET_CHILD_REPORT=\"batch\" to the fleet conf: $(grep FLEET_CHILD_REPORT "$F2" || echo '<no line>')"; ok
eq 'picked batch → fleet conf (not the o/b overlay)' "$(fcfg_file_value "$FLEET_CONF_DIR/fleets/s2/repos/o-b.conf" FLEET_CHILD_REPORT || echo unset)" unset
pick FLEET_CHILD_REPORT 0
grep -qxF 'FLEET_CHILD_REPORT="0"' "$F2" || fail "picking 0 did not write FLEET_CHILD_REPORT=\"0\": $(grep FLEET_CHILD_REPORT "$F2" || echo '<no line>')"; ok
v=$( . "$F2"; . "$BIN/fleet-children-lib.sh"; children_report_mode ); eq 'picked 0 reads back as off' "$v" 0
pick FLEET_CHILD_REPORT immediate
v=$( . "$F2"; . "$BIN/fleet-children-lib.sh"; children_report_mode ); eq 'picked immediate reads back' "$v" immediate
# What the fleet actually loads: settings beat the legacy install value; the
# legacy per-fleet key still comes through where nothing overrides it.
v=$( unset _FLEET_GLOBAL_CONF_SOURCED FLEET_SKIP_GLOBAL_CONF FLEET_GLOBAL_MAX_SESSIONS
     . "$BIN/fleet-lib.sh"; . "$FCFG_GLOBAL_CONF"; . "$FLEET_CONF_DIR/fleet.settings"
     fleet_load_conf s2; printf '%s %s' "$FLEET_GLOBAL_MAX_SESSIONS" "$FLEET_MAX_SESSIONS" )
eq 'loaded: settings global-only + fleet key' "$v" '9 6'
v=$( unset _FLEET_GLOBAL_CONF_SOURCED FLEET_SKIP_GLOBAL_CONF FLEET_GLOBAL_MAX_SESSIONS
     . "$BIN/fleet-lib.sh"; printf '%s' "${FLEET_GLOBAL_MAX_SESSIONS:-}" )
eq 'fleet-lib reads fleet.settings' "$v" 9
ev=$(fcfg_effective FLEET_GLOBAL_MAX_SESSIONS s2)
eq 'modal agrees' "$ev" "9${FCFG_US}fleet"
rm -f "$FLEET_CONF_DIR/fleet.settings" "$FLEET_CONF_DIR/fleet.settings.bak" "$F2.bak"
: > "$FCFG_GLOBAL_CONF"
printf 'FLEET_REPO="o/a"\nFLEET_MODEL="sonnet"\nFLEET_DEPLOY_CHECK="actions"\n' > "$F2"
fcfg_wscope_set s2 fleet

# Degenerate rows: drop the overlays and the rows are byte-identical to before.
rm -rf "$FLEET_CONF_DIR/fleets/s2/repos"
eq 'one-repo rows unchanged' "$(rows)" "$ROWS1"

printf 'selftest PASS: %d assertions (keys · tags · typing · defaults · layering · validation · write · write-scope · repo-scope)\n' "$pass"
exit 0
