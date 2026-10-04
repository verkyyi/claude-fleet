#!/bin/sh
# fleet-lang.sh — the ONE source of the fleet's LANGUAGE-PRESERVATION rules
# (issue #620).
#
# THE BUG: a session held entirely in Chinese (or any non-English language) snaps
# back to English the moment fleet automation touches it. Not a UI-translation
# problem — the fleet INJECTS English text at the tail of a conversation (a
# migrate/restore resume nudge, the auto-handoff directive, a quota notice, a
# child report), so the MOST RECENT instruction the model sees is English and it
# follows it. The transcript above is still Chinese; only the last turn moved.
#
# THE FIX IS NOT TRANSLATION. Shipping a nudge per language is the wrong shape:
# the wording is still evolving (#524, #567, #572, #574 all rewrote one), so every
# language added is another copy to keep in step, and every rewrite silently
# strands the translations. ONE English sentence — "keep speaking whatever you
# were already speaking" — covers every language at once and cannot go stale.
#
# The precedent is already in the repo: conf/codex-preamble.md tells a Codex
# worker to "Reply in the language the issue is written in." That rule was never
# given to the Claude path, which is half of this issue.
#
# THREE rules, because the injection points differ in ONE respect — whether the
# model can SEE the prior conversation:
#
#   RESUME  the session continues with its transcript intact (claude --resume
#           after a migrate/restore, an in-place /model switch, the auto-handoff
#           directive). The evidence of the language is right there above; the
#           rule only has to stop the English tail from overriding it.
#   SEED    a NEW session with no prior turns (a freshly spawned worker). Nothing
#           to continue, so the language is inferred from the work itself — the
#           issue text. This is conf/codex-preamble.md's rule, given to Claude.
#   NOTICE  an out-of-band message pushed INTO a live session (a quota warning, a
#           child's outcome report). These need no translation at all: they only
#           have to declare that they are NOT a language switch.
#
# POSIX sh on purpose, and assignments only: bin/set-claude-state.sh is `sh`-wired
# and cannot source the bash-only fleet-lib.sh, so both shells share this file
# verbatim. bin/fleet-lib.sh sources it, so every bash consumer already has the
# rules by sourcing the lib as usual.
#
# Also runnable, for a consumer that cannot source at all:
#   fleet-lang.sh resume|seed|notice     → prints that rule on one line
#
# Keep every rule free of single quotes and backticks: these strings are embedded
# single-quoted into launch command lines (bin/fleet-migrate.sh, bin/fleet-restore.sh)
# and into a JSON hook decision (bin/set-claude-state.sh). The apostrophe in the
# NOTICE rule is the one exception and it rides only over fleet_peer_send, which
# does no quoting at all.

# Continuing session, transcript visible.
FLEET_LANG_RULE_RESUME='Continue replying in the language this session was using before this interruption.'
# Fresh session, no transcript — take the language from the work.
FLEET_LANG_RULE_SEED='Reply in the language the issue is written in.'
# Out-of-band notice pushed into a live session: not a language switch.
FLEET_LANG_RULE_NOTICE="This notice is in English; keep replying in your session's language."

# Direct run → print one rule. SOURCED → define only, silently.
# The $0 guard is load-bearing, not ceremony: a sourced file inherits the CALLER's
# positional parameters, so a bare `case "$1"` here would fire on any script that
# happens to be invoked as `… seed` (or `-h`) and sources fleet-lib.sh. $0 is the
# outer script when sourced and this file only when executed.
case "${0##*/}" in
  fleet-lang.sh)
    case "${1:-}" in
      resume) printf '%s\n' "$FLEET_LANG_RULE_RESUME" ;;
      seed)   printf '%s\n' "$FLEET_LANG_RULE_SEED" ;;
      notice) printf '%s\n' "$FLEET_LANG_RULE_NOTICE" ;;
      *)      printf 'fleet-lang.sh resume|seed|notice — print one language-preservation rule\n' ;;
    esac
    ;;
esac
