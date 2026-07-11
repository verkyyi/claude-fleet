#!/bin/bash
# fleet-triage.sh --repo <owner/name> --line "<one line>" [--body "<text>"]
#              [--model <model>] — the INLINE auto-triage pass (issue #235).
#
# The LLM half of the "one line → issue" capture: given a single line of intent
# (and an optional rough body), it makes ONE `claude -p` call and returns a
# triaged issue — a refined title, an elaborated body, a component MILESTONE, a
# type LABEL, and a PRIORITY tier — grounded in THIS repo's REAL milestones and
# labels. Called by bin/dash-issue-new.sh when a fleet opts in with
# FLEET_AUTO_TRIAGE=1; it is a no-op path otherwise (capture stays raw + fast).
#
# It rolls the four automations the issue asks for into one cheap call:
#   • auto-elaborate — expand the one-liner into a fuller title + body.
#   • auto-classify  — pick a component (milestone) + type label.
#   • auto-triage    — the umbrella: label/route a fresh issue.
#   • auto-priority  — assign a priority:p{0,1,2} tier (the same label the
#                      autofill dispatcher already ranks by — bin/fleet-dispatch.sh).
#
# ROBUSTNESS RAIL: the model can hallucinate a milestone or label that does not
# exist. Every suggestion is validated against the repo's ACTUAL sets before it
# leaves this script, so the caller's `gh issue create --milestone/--label` can
# never fail on a bad name — an unknown suggestion is silently dropped, never
# invented. Priority/control labels (steward-control, blocked, scout, duplicate…)
# are stripped from the classify output too, so triage can only ever ADD a type
# label + one priority tier, never mislabel an issue into the control plane.
#
# COST: one `claude -p` call per capture — small, and only when a human filed an
# issue via the fast path with FLEET_AUTO_TRIAGE=1. Self-disables (exit 3) if
# `claude` is not on PATH so the caller falls back to a raw create.
#
# Output contract (stdout) — the caller (dash-issue-new.sh) parses these:
#   TITLE<TAB><refined title>
#   MILESTONE<TAB><validated milestone title, or empty>
#   LABELS<TAB><validated comma-joined labels incl the priority tier, or empty>
#   @@FLEET_TRIAGE_BODY@@
#   <elaborated body, to EOF>
#
# Exit: 0 = a triage block was emitted · 2 = usage/arg error · 3 = triage
# unavailable/failed (no claude, empty model output) — caller should fall back to
# the raw title/body it already has. On 3 nothing authoritative is printed.
#
# Test seam (bin/fleet-triage-selftest.sh runs fully hermetic): inject the valid
# sets via TRIAGE_MILESTONES / TRIAGE_LABELS (newline-separated) to skip the gh
# fetch, and put a canned `claude` on PATH to skip the real model call.
set -uo pipefail

REPO="" LINE="" BODY="" MODEL="${FLEET_AUTO_TRIAGE_MODEL:-haiku}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)  REPO="${2:-}"; shift 2 ;;
    --line)  LINE="${2:-}"; shift 2 ;;
    --body)  BODY="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'fleet-triage: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { printf 'fleet-triage: --repo required\n' >&2; exit 2; }
[ -n "$LINE" ] || { printf 'fleet-triage: --line required\n' >&2; exit 2; }
command -v claude >/dev/null 2>&1 || exit 3   # no model → caller does a raw create

BODY_SENTINEL='@@FLEET_TRIAGE_BODY@@'

# --- the repo's REAL milestones + labels (the validation whitelist) ------------
# Injected sets (tests, or a caller with a warm cache) win; else fetch via gh.
# gh api is used over `gh label/milestone list` for stable --jq across gh versions.
MILESTONES="${TRIAGE_MILESTONES:-}"
LABELS_ALL="${TRIAGE_LABELS:-}"
if [ -z "$MILESTONES" ] && command -v gh >/dev/null 2>&1; then
  MILESTONES=$(gh api "repos/$REPO/milestones" --jq '.[].title' 2>/dev/null)
fi
if [ -z "$LABELS_ALL" ] && command -v gh >/dev/null 2>&1; then
  LABELS_ALL=$(gh api "repos/$REPO/labels" --paginate --jq '.[].name' 2>/dev/null)
fi

# Control/meta labels triage must NEVER auto-apply: the priority tier is chosen
# separately (PRIORITY field), and steward-control/blocked/scout route an issue
# out of the normal worker flow — a misfire there is worse than no label. So the
# classify whitelist is (all labels) − (these). Matched case-insensitively.
is_control_label() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    priority:p0|priority:p1|priority:p2|steward-control|blocked|scout|duplicate|wontfix|invalid) return 0 ;;
    *) return 1 ;;
  esac
}
# type/component labels offered to the model (control labels filtered out)
TYPE_LABELS=""
while IFS= read -r l; do
  [ -z "$l" ] && continue
  is_control_label "$l" || TYPE_LABELS+="${TYPE_LABELS:+$'\n'}$l"
done <<EOF
$LABELS_ALL
EOF

# comma/newline list → prompt-friendly bullet block ("- x") for the model
bullets() { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d;s/^/- /'; }

# --- the prompt ----------------------------------------------------------------
ms_block=$(bullets "$MILESTONES"); [ -n "$ms_block" ] || ms_block="(none defined)"
lb_block=$(bullets "$TYPE_LABELS"); [ -n "$lb_block" ] || lb_block="(none defined)"
read -r -d '' PROMPT <<EOF || true
You are the triage bot for the GitHub repo "$REPO". Turn a one-line issue idea
into a well-formed issue. Reply in EXACTLY this format and nothing else:

TITLE: <one concise, specific, imperative title — no trailing period>
MILESTONE: <choose EXACTLY ONE milestone title from the list below that best fits the component/area, or "none">
LABELS: <zero or more type labels from the list below, comma-separated, or "none">
PRIORITY: <p0, p1, p2, or none — p0=urgent/blocking, p1=important, p2=nice-to-have; "none" if unclear>
BODY:
<2 to 5 sentences elaborating what the issue is, why it matters, and a hint at scope. Plain prose, no headings.>

Rules:
- MILESTONE and LABELS MUST be chosen ONLY from the exact lists below (verbatim), or "none". Do not invent new ones.
- Prefer "none" over a wrong guess. Do not add a priority label in LABELS — use the PRIORITY field.

Available milestones (components/areas):
$ms_block

Available type labels:
$lb_block

The one-line idea:
$LINE
EOF
[ -n "$BODY" ] && PROMPT+=$'\n\nRough notes from the author (fold into the body):\n'"$BODY"

RAW=$(printf '%s' "$PROMPT" | claude -p --model "$MODEL" 2>/dev/null)
[ -n "$RAW" ] || exit 3   # empty model output → caller falls back to raw create

# --- parse + validate the model output -----------------------------------------
# Pull each header field's value (first match wins; tolerant of leading spaces and
# a "**TITLE:**"-style markdown wrap the model might add). BODY = everything after
# the first line whose content is "BODY:". Keys are matched CASE-SENSITIVELY
# (uppercase, as the prompt dictates) — the GNU `sed //I` and `awk IGNORECASE`
# extensions are avoided so this runs on BSD/macOS sed+awk as well as Linux.
field() { printf '%s\n' "$RAW" | sed -n "s/^[[:space:]*]*$1:[[:space:]]*//p" | head -n1; }
T_TITLE=$(field TITLE)
T_MS=$(field MILESTONE)
T_LABELS=$(field LABELS)
T_PRIO=$(field PRIORITY)
# BODY = lines after the "BODY:" sentinel, with leading/trailing blank lines (and a
# stray markdown "**" fence) trimmed but internal structure preserved.
T_BODY=$(printf '%s\n' "$RAW" | sed -n '/^[[:space:]*]*BODY:[[:space:]]*$/,$p' | sed '1d' \
  | awk '{ l[NR]=$0 }
         END { f=0; for(i=1;i<=NR;i++) if(l[i] ~ /[^[:space:]*]/){f=i;break}
               t=0; for(i=NR;i>=1;i--) if(l[i] ~ /[^[:space:]*]/){t=i;break}
               if(f) for(i=f;i<=t;i++) print l[i] }')

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\*\{1,2\}//' -e 's/\*\{1,2\}$//'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
T_TITLE=$(trim "$T_TITLE"); T_MS=$(trim "$T_MS"); T_PRIO=$(trim "$T_PRIO")

# TITLE: fall back to the raw line if the model gave nothing usable.
[ -n "$T_TITLE" ] || T_TITLE="$LINE"

# MILESTONE: keep only if it matches a real milestone (case-insensitively → the
# repo's canonical spelling). tolower() is portable awk; IGNORECASE is not.
val_ms=""
if [ -n "$T_MS" ] && [ "$(lower "$T_MS")" != none ]; then
  val_ms=$(printf '%s\n' "$MILESTONES" | awk -v w="$T_MS" '
    { if (tolower($0)==tolower(w)){print $0; exit} }')
fi

# LABELS: keep only real, non-control type labels (case-insensitive → canonical),
# deduped, order-preserving.
val_labels=""
add_label() { # $1 = candidate — validate against TYPE_LABELS, append canonical
  local cand canon; cand=$(trim "$1"); [ -z "$cand" ] && return
  [ "$(lower "$cand")" = none ] && return
  is_control_label "$cand" && return
  canon=$(printf '%s\n' "$TYPE_LABELS" | awk -v w="$cand" '
    { if (tolower($0)==tolower(w)){print $0; exit} }')
  [ -z "$canon" ] && return
  case ",$val_labels," in *",$canon,"*) return ;; esac   # dedup
  val_labels+="${val_labels:+,}$canon"
}
_oldifs="$IFS"; IFS=','
for c in $T_LABELS; do add_label "$c"; done
IFS="$_oldifs"

# PRIORITY: p0|p1|p2 → the priority:pN label, but only if that label exists in the
# repo (it does in a fleet repo, but validate so we never emit a non-existent one).
case "$(lower "$T_PRIO")" in
  p0|p1|p2)
    ptier="priority:$(lower "$T_PRIO")"
    if printf '%s\n' "$LABELS_ALL" | grep -qxiF "$ptier"; then
      case ",$val_labels," in *",$ptier,"*) : ;; *) val_labels+="${val_labels:+,}$ptier" ;; esac
    fi ;;
esac

# --- emit the contract ---------------------------------------------------------
printf 'TITLE\t%s\n' "$T_TITLE"
printf 'MILESTONE\t%s\n' "$val_ms"
printf 'LABELS\t%s\n' "$val_labels"
printf '%s\n' "$BODY_SENTINEL"
[ -n "$T_BODY" ] && printf '%s\n' "$T_BODY" || printf '%s\n' "$BODY"
exit 0
