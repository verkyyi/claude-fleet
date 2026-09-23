#!/bin/bash
# fleet-children-lib.sh — the child-report LEDGER's write half (issue #937).
# Source it (after fleet-lib.sh); it defines:
#
#   children_dir <sess>                  → $FLEET_STATE/children for that fleet
#                                          (fleet_state_dir <sess>/children)
#   children_file <parent-key> <sess>    → that parent's <parent-key>.ndjson
#   children_append <parent-key> <json> [<sess>]
#                                        → append one event, deduped + seq'd
#   report_tier <STATE> [summary] [verdict] [child @claude_state]
#                                        → loud | quiet | silent (issue #938)
#   children_report_mode [value]         → immediate | batch | 0 — the
#                                          FLEET_CHILD_REPORT switch, normalised
#
# <json> carries {child, state, pr, verdict, summary, title, tier}; seq and ts are
# stamped here, under a lock, so two children reporting at once never share a seq.
# state ∈ MERGED BLOCKED FAILED STOPPED REAPED WAITING IDLE. A write whose
# (child, state, pr) equals that child's LATEST event is a no-op — the reaper's
# backstop repeating the ship path's report adds nothing.
#
# The ledger is keyed by the PARENT'S KEY (fleet_origin_canon's `issue-N` /
# `scratch-N` / `<slug>:issue-N`), never a window id: the key is what @origin
# already carries, and it survives a migrate/restore that mints a new window id.
# Readers: bin/fleet-children.sh (the query command). Format + this function are a
# stable interface (EPIC #935: C4/C5/C6/R1) — add fields, never rename.
#
# NEVER fails its caller: it runs on a child's SHIP path and in a Stop hook.
# Prints nothing on stdout (a Stop hook's stdout is its JSON response); returns 0
# on success or a dup, 1 when it could not write.

_CHILDREN_BIN="${_CHILDREN_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

children_dir() {
  local sess="${1:-}"
  [ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
  [ -n "$sess" ] || return 1
  printf '%s/children' "$(fleet_state_dir "$sess")"
}

# The key doubles as a file name: keep the key charset only (`:` survives — it is
# the multi-repo separator), so no key can climb out of the ledger dir.
children_file() {
  local key d
  key=$(printf '%s' "${1:-}" | LC_ALL=C tr -cd 'A-Za-z0-9._:-')
  case "$key" in ''|.*) return 1 ;; esac
  d=$(children_dir "${2:-}") || return 1
  printf '%s/%s.ndjson' "$d" "$key"
}

children_append() {
  local f
  f=$(children_file "${1:-}" "${3:-}") || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  printf '%s' "${2:-}" | python3 "$_CHILDREN_BIN/fleet-children.py" append --file "$f" >/dev/null 2>&1
}

# report_tier — how loudly a child report may interrupt its parent (issue #938).
# The ONE place the bands are decided: fleet-report-parent.sh stamps it into the
# ledger and gates delivery on it, and the batch digest (C5 #939) and the blocking
# wait (R1 #812) read the same answer rather than re-deriving it.
#   loud    someone must act: BLOCKED; FAILED that is not being fixed; REAPED with
#           unlanded work (unmerged/dirty); a true STOPPED (no bg job, no open PR,
#           done — unshipped work nobody is carrying); any child whose own
#           @claude_state is `needs`.
#   quiet   an outcome worth knowing, nothing to do: MERGED; FAILED while the child
#           says it is fixing it (fleet-claim's `RED: … fixing it`); any other reap.
#   silent  a turn boundary, not an outcome: WAITING (bg job / open PR — #864's
#           busy verdict) and IDLE (the gate could not be read). Ledger only.
# An unknown state is loud: a band this function does not know must fail toward
# delivery, never toward a swallowed report.
report_tier() {
  local st sum="${2:-}" v="${3:-}" cs="${4:-}"
  st=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
  case "$cs" in needs*) printf 'loud\n'; return 0 ;; esac
  case "$st" in
    WAITING|IDLE) printf 'silent\n' ;;
    MERGED)       printf 'quiet\n' ;;
    FAILED)
      case "$(printf '%s' "$sum" | tr '[:upper:]' '[:lower:]')" in
        *fixing*|*正在修*) printf 'quiet\n' ;;
        *)                 printf 'loud\n' ;;
      esac ;;
    REAPED)
      case "$v" in unmerged|dirty) printf 'loud\n' ;; *) printf 'quiet\n' ;; esac ;;
    *)            printf 'loud\n' ;;   # BLOCKED, STOPPED, anything new
  esac
}

# children_report_mode — FLEET_CHILD_REPORT (or $1) as one of immediate|batch|0.
# The legacy `1` (and unset, and anything unrecognised) is `immediate`: the switch
# fails toward the historic per-report delivery, never toward silence.
children_report_mode() {
  case "${1-${FLEET_CHILD_REPORT:-}}" in
    0|no|off|false) printf '0\n' ;;
    batch)          printf 'batch\n' ;;
    *)              printf 'immediate\n' ;;
  esac
}
