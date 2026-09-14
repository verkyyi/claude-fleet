#!/bin/bash
# fleet-lang-selftest.sh — the guard on issue #620: every place the fleet INJECTS
# English text into a live session must carry a language-preservation rule.
#
# WHY A TEST AT ALL. The bug it closes is invisible from the code: nothing breaks,
# no error is logged, a Chinese session simply starts answering in English after a
# migrate / quota warning / auto-handoff, and the operator is left to notice. The
# fix is one sentence appended to each injected string — and a sentence at the end
# of a long string is EXACTLY the thing a later rewrite drops without noticing.
# Every one of these strings has already been rewritten at least once (#524, #551,
# #567, #572, #574), so "someone will reword this again" is a certainty, not a
# hypothetical. This test is what makes that reword fail loudly.
#
# It checks three things:
#   1. the canonical rules themselves (bin/fleet-lang.sh) — wording pinned, and the
#      sourced-vs-executed contract that keeps them from printing into a caller;
#   2. the REAL resolved text, wherever the owning script is source-safe
#      (fleet-migrate.sh, fleet-model-switch.sh) — the strongest form of the check;
#   3. a STRUCTURAL check everywhere else: the rule variable must appear ON the
#      line that builds the injected string. A reword that keeps the line but drops
#      the rule fails here; so does deleting the line.
#
# Pure text + one sourced script. No tmux, no network, no gh, no temp state.
# Exit 0 = pass; non-zero = fail (prints the failing assertion).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# ===== 1. the canonical rules ===================================================
# Pinned verbatim: a reword is fine, but it must be a deliberate edit here too —
# these exact sentences are what the injection-point checks below look for, and
# what the conf docs quote for an operator writing a custom nudge.
WANT_RESUME='Continue replying in the language this session was using before this interruption.'
WANT_SEED='Reply in the language the issue is written in.'
WANT_NOTICE="This notice is in English; keep replying in your session's language."

# shellcheck source=/dev/null
. "$BIN/fleet-lang.sh"
[ "${FLEET_LANG_RULE_RESUME:-}" = "$WANT_RESUME" ] || fail "RESUME rule changed" "${FLEET_LANG_RULE_RESUME:-<unset>}"
[ "${FLEET_LANG_RULE_SEED:-}"   = "$WANT_SEED" ]   || fail "SEED rule changed"   "${FLEET_LANG_RULE_SEED:-<unset>}"
[ "${FLEET_LANG_RULE_NOTICE:-}" = "$WANT_NOTICE" ] || fail "NOTICE rule changed" "${FLEET_LANG_RULE_NOTICE:-<unset>}"
ok "the three canonical rules are defined, with the pinned wording"

# Every rule is embedded single-quoted into a launch command line
# (fleet-migrate.sh / fleet-restore.sh) or into a JSON hook decision
# (set-claude-state.sh), and fleet-migrate.sh STRIPS single quotes and backticks
# from a nudge — a rule carrying either would arrive mangled or break the line.
# NOTICE is exempt: it rides only over fleet_peer_send, which quotes nothing.
v=''
for r in RESUME SEED; do
  eval "v=\$FLEET_LANG_RULE_$r"
  case "$v" in
    *\'*|*\`*|*\"*|*\\*) fail "the $r rule must carry no quote/backtick/backslash (it is embedded in a command line and in JSON)" "$v" ;;
  esac
done
ok "the embedded rules stay free of quotes, backticks and backslashes"

# Executed → prints one rule. This is the escape hatch for a consumer that cannot
# source (another language, an awk/python hop).
[ "$(sh "$BIN/fleet-lang.sh" resume)" = "$WANT_RESUME" ] || fail "fleet-lang.sh resume must print the resume rule"
[ "$(sh "$BIN/fleet-lang.sh" seed)"   = "$WANT_SEED" ]   || fail "fleet-lang.sh seed must print the seed rule"
[ "$(sh "$BIN/fleet-lang.sh" notice)" = "$WANT_NOTICE" ] || fail "fleet-lang.sh notice must print the notice rule"
ok "executed directly, fleet-lang.sh prints the rule it is asked for"

# SOURCED → defines only, silently. A sourced file inherits the CALLER's positional
# parameters, so without the $0 guard any script invoked as `… seed` that sources
# fleet-lib.sh would print a stray rule into its own stdout — which for a producer
# whose stdout IS the dash would corrupt the render.
out=$(sh -c '. "$1/fleet-lang.sh"; :' fakecaller.sh "$BIN" seed 2>&1)
[ -z "$out" ] || fail "sourcing fleet-lang.sh must print NOTHING even when the caller's \$1 is a rule name" "$out"
ok "sourced, fleet-lang.sh is silent regardless of the caller's positional args"

# fleet-lib.sh is the choke point ~every bash consumer already sources, so it must
# carry the rules through without each script hunting for the file itself.
out=$(FLEET_SKIP_GLOBAL_CONF=1 bash -c '. "$1/fleet-lib.sh"; printf "%s" "${FLEET_LANG_RULE_SEED:-}"' _ "$BIN")
[ "$out" = "$WANT_SEED" ] || fail "sourcing fleet-lib.sh must expose the language rules" "$out"
ok "fleet-lib.sh re-exports the rules to every bash consumer that sources it"

# ===== 2. REAL resolved text — the source-safe scripts ==========================
# fleet-migrate.sh defines-only when sourced (a direct run dispatches), so the
# built-ins can be read exactly as a migrate would use them.
# Sourced in a subshell (nothing leaks into this one) whose $0 is ANOTHER path in
# bin/: the script's own `dirname $0` then still finds its siblings, while
# `BASH_SOURCE[0] != $0` keeps it on the define-only branch instead of dispatching.
probe() { FLEET_SKIP_GLOBAL_CONF=1 bash -c '. "$1" >/dev/null 2>&1; eval "$2"' \
            "$BIN/.lang-probe" "$1" "$2"; }

out=$(probe "$BIN/fleet-migrate.sh" 'printf "%s\n%s\n" "$NUDGE_BUILTIN" "$NUDGE_MODEL_BUILTIN"')
case "$out" in *"$WANT_RESUME"*) : ;; *) fail "fleet-migrate.sh built-in nudges must end with the resume rule" "$out" ;; esac
[ "$(printf '%s' "$out" | grep -c -- "$WANT_RESUME")" = 2 ] \
  || fail "BOTH migrate nudges (account cap AND model cap) must carry the rule" "$out"
case "$out" in *__MODEL__*) : ;; *) fail "the model-cap nudge must still carry its __MODEL__ placeholder" "$out" ;; esac
ok "fleet-migrate.sh: both resume nudges carry the rule (real resolved text)"

# The conf keys (issue #620) must OVERRIDE, and an unset/empty key must fall back
# to the built-in — that is the "默认值不变" half of the issue.
grep -q 'NUDGE_DEFAULT="${FLEET_MIGRATE_NUDGE:-\$NUDGE_BUILTIN}"' "$BIN/fleet-migrate.sh" \
  || fail "FLEET_MIGRATE_NUDGE must override the built-in, with the built-in as its default"
grep -q 'NUDGE_MODEL_DEFAULT="${FLEET_MIGRATE_NUDGE_MODEL:-\$NUDGE_MODEL_BUILTIN}"' "$BIN/fleet-migrate.sh" \
  || fail "FLEET_MIGRATE_NUDGE_MODEL must override the built-in, with the built-in as its default"
ok "fleet-migrate.sh: the two nudges are conf keys that default to the built-ins"

# Both keys must be REGISTERED in fleet.conf.example — that is what makes them
# visible in the prefix+c config modal instead of a knob only the source reveals.
for k in FLEET_MIGRATE_NUDGE FLEET_MIGRATE_NUDGE_MODEL; do
  grep -qE "^#?[[:space:]]*$k=" "$ROOT/fleet.conf.example" \
    || fail "$k must be documented in fleet.conf.example (the config modal reads it from there)"
done
ok "both migrate-nudge keys are registered in fleet.conf.example"

# fleet-model-switch.sh pins its pure helpers the same way.
out=$(probe "$BIN/fleet-model-switch.sh" 'printf "%s" "$NUDGE_DEFAULT"')
case "$out" in *"$WANT_RESUME"*) : ;; *) fail "fleet-model-switch.sh's in-place /model nudge must carry the resume rule" "$out" ;; esac
ok "fleet-model-switch.sh: the in-place /model nudge carries the rule (real resolved text)"

# ===== 3. STRUCTURAL — the rule must sit ON the injected string's line ==========
# carries <file> <rule-var> <anchor-regex> <what>
#   The anchor identifies the line that BUILDS the injected text. Requiring both on
#   one line is what catches the realistic regression: someone rewrites the wording
#   in place and the trailing rule goes with it.
carries() {
  local f="$1" var="$2" anchor="$3" what="$4" line
  line=$(grep -nE "$anchor" "$ROOT/$f" | head -1) \
    || fail "$f: could not find the $what line (anchor: $anchor) — did it move?"
  [ -n "$line" ] || fail "$f: could not find the $what line (anchor: $anchor) — did it move?"
  case "$line" in
    *"\${$var"*) ok "$f: the $what carries \$$var" ;;
    *) fail "$f: the $what no longer carries \$$var — a non-English session will be flipped to English by it (issue #620)" "$line" ;;
  esac
}

carries bin/fleet-restore.sh      FLEET_LANG_RULE_RESUME 'nudge="The tmux server crashed' \
        'crash-restore resume nudge'
carries bin/set-claude-state.sh   FLEET_LANG_RULE_RESUME '"decision":"block"' \
        'auto-handoff Stop-hook directive'
carries bin/fleet-quotawatch.sh   FLEET_LANG_RULE_NOTICE 'qmsg="\[fleet quota watch\]' \
        'quota-watch warning pushed into a live session'
carries bin/fleet-report-parent.sh FLEET_LANG_RULE_NOTICE '^msg=.*no reply needed' \
        'child-report envelope'
# The brief's language section is a heading + the rule beneath it, so the check is
# a small window rather than one line: the heading must exist AND the rule must be
# printed under it. (fleet-claim-brief-selftest.sh pins the REAL rendered output;
# this is the cheap structural half.)
blk=$(grep -A3 '===== language' "$ROOT/bin/fleet-claim-brief.sh" | head -4)
case "$blk" in
  *'$FLEET_LANG_RULE_SEED'*) ok "bin/fleet-claim-brief.sh: the worker seed language section prints \$FLEET_LANG_RULE_SEED" ;;
  *) fail "bin/fleet-claim-brief.sh: the language section must print \$FLEET_LANG_RULE_SEED — without it the Claude seed path has no equivalent of conf/codex-preamble.md's rule (issue #620)" "$blk" ;;
esac

# The seed rule must reach BOTH agents. Codex has had it since #547 via its
# preamble; the Claude path gets it from the brief above. Losing either half is
# the asymmetry issue #620 was filed about.
grep -qF "$WANT_SEED" "$ROOT/conf/codex-preamble.md" \
  || fail "conf/codex-preamble.md must keep the seed rule — it is the Codex path's copy (and the precedent #620 cites)"
ok "conf/codex-preamble.md keeps the seed rule for the Codex path"

# The handoff doc is the ONLY thing a pickup session can read — it has no
# transcript — so the language has to be WRITTEN DOWN or it is simply lost. The
# doc's shape is owned by the base skill (commands/fleet-handoff.md deliberately
# does not restate its skeleton), so the field is pinned there and the fleet skill
# only has to point at it.
grep -q '^Language:' "$ROOT/skills/handoff/SKILL.md" \
  || fail "skills/handoff/SKILL.md's doc skeleton must carry a Language: line — a pickup session has no transcript to infer the language from (issue #620)"
grep -q 'Language:' "$ROOT/commands/fleet-handoff.md" \
  || fail "commands/fleet-handoff.md must point the handoff at the doc's Language: line"
grep -q 'the language the doc records' "$ROOT/commands/fleet-handoff.md" \
  || fail "commands/fleet-handoff.md pickup must resume in the language the doc records"
ok "the handoff doc carries the session language across the pickup boundary"

printf '\nfleet-lang selftest: OK (%d checks)\n' "$pass"
