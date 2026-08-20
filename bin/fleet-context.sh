#!/bin/bash
# fleet-context.sh [--json] [-q] — how full is THIS Claude session's context? (issue #464)
#
# Claude Code shows the context meter to the HUMAN (the /context command, the
# statusline bar) but gives the model no way to ask "how full am I?" about
# itself. A worker is nonetheless told to `/fleet-handoff` *before* it runs out
# (the standing charter in commands/fleet-claim.md), and the auto-handoff nudge
# (issue #330) only fires at a clean Stop — so mid-task, a worker deciding
# whether to start one more expensive sweep is flying blind. This is the read
# that closes that gap: ONE command, run from inside the pane, printing what
# this session has spent and whether to hand off.
#
# Two independent sources, best-effort, whichever is available:
#   @ctx_pct     Claude Code's OWN percentage, stamped onto the pane's window by
#                conf/statusline.sh on every render (issue #330's measurement
#                bus). Authoritative — it accounts for the autocompact reserve —
#                but only present once a statusline has rendered in this pane.
#   transcript   the session's own ~/.claude/projects/<enc-cwd>/<sid>.jsonl. The
#                LAST main-thread assistant record's usage block sums to the live
#                context (input + cache_creation + cache_read + output); that is
#                exactly what the next request re-sends. Always available, and it
#                also yields turn count, session output tokens and the pre-compact
#                peak — but its percentage is DERIVED against FLEET_CONTEXT_LIMIT,
#                so it reads a little LOWER than Claude Code's own number.
# Sidechain (subagent) records are excluded: a fanned-out Explore agent's context
# is not this session's. A `/clear` or an autocompact simply moves the last
# record, so the live figure follows it down with no special case.
#
# Verdicts (the `verdict:` line, one token):
#   OK        plenty of headroom            → carry on
#   WATCH     getting full                  → finish the current thread, then hand off
#   HANDOFF   at/over the threshold         → run /fleet-handoff now
#   UNKNOWN   nothing measurable yet        → no statusline stamp, no usage record
# Bands: with FLEET_AUTO_HANDOFF_PCT set (issue #330), HANDOFF is that threshold
# and WATCH the 15 points below it — so this read agrees with the nudge that will
# fire anyway. With it OFF, the fallback bands are the statusline's own colours
# (conf/statusline.sh: yellow at 50%, red at 80%).
#
# Exit codes (so a caller can branch without parsing): 0 OK · 1 any other verdict
# · 2 error (no transcript AND no stamp, no jq). Mirrors bin/fleet-pr-verdict.sh.
#
# Read-only: it reads a transcript and two tmux options, and writes nothing.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"

PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

as_json=0 quiet=0 sid="" tpath="" pane="${TMUX_PANE:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)       as_json=1 ;;
    -q|--quiet)   quiet=1 ;;
    --session)    shift; sid="${1:-}" ;;
    --transcript) shift; tpath="${1:-}" ;;
    --pane)       shift; pane="${1:-}" ;;
    -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)          printf 'fleet-context: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)            printf 'fleet-context: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# --- the context window denominator ------------------------------------------
# Only ever used for the DERIVED percentage (the @ctx_pct stamp needs no
# denominator). Default 200k = the standard window; a fleet running a long-context
# model sets FLEET_CONTEXT_LIMIT to match.
LIMIT="${FLEET_CONTEXT_LIMIT:-200000}"
case "$LIMIT" in ''|*[!0-9]*) LIMIT=200000 ;; esac
[ "$LIMIT" -gt 0 ] || LIMIT=200000

# --- resolve the transcript ---------------------------------------------------
# 1) an explicit --transcript wins (the selftest's path, and a hand inspection).
# 2) a known session id globs across ALL project dirs — exact and cwd-independent,
#    so a `cd` inside the pane can't misresolve it.
# 3) otherwise fall back to the newest *.jsonl in this cwd's project dir (older
#    CLIs that don't export the id). Claude Code encodes a cwd into its project
#    dir by replacing every non-alphanumeric byte with '-' (see fleet_transcript_dir).
[ -z "$sid" ] && sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$tpath" ] && [ -n "$sid" ]; then
  for f in "$PROJECTS"/*/"$sid".jsonl; do [ -f "$f" ] && { tpath="$f"; break; }; done
fi
if [ -z "$tpath" ]; then
  dir=$(fleet_transcript_dir "${CLAUDE_PROJECT_DIR:-$(pwd -P)}" 2>/dev/null)
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    tpath=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -n1)
  fi
fi

# --- read the pane's statusline stamp ----------------------------------------
stamp=""
if [ -n "${TMUX:-}" ] && [ -n "$pane" ]; then
  stamp=$(tmux display-message -p -t "$pane" '#{@ctx_pct}' 2>/dev/null)
fi
case "$stamp" in ''|*[!0-9]*) stamp="" ;; esac
armed=""
if [ -n "${TMUX:-}" ] && [ -n "$pane" ]; then
  armed=$(tmux display-message -p -t "$pane" '#{@handoff_armed}' 2>/dev/null)
fi
[ "$armed" = "1" ] || armed=""

# --- fold the transcript ------------------------------------------------------
# ONE pass: every main-thread assistant usage block as a TSV row, then awk takes
# the LAST row (the live context), the row count (turns), the output-token sum
# (session spend) and the max (the pre-compact peak). `fromjson?` skips a torn
# final line — the file is being appended to while we read it.
live=0 turns=0 out_total=0 peak=0
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    [ -n "$stamp" ] || { printf 'fleet-context: jq not on PATH and no @ctx_pct stamp — nothing to read\n' >&2; exit 2; }
  else
    read -r live turns out_total peak <<EOF
$(jq -Rr 'fromjson? // empty
          | select(.type == "assistant" and (.isSidechain != true))
          | .message.usage // empty
          | select(.cache_read_input_tokens != null)
          | [ ((.input_tokens // 0) + (.cache_creation_input_tokens // 0)
               + (.cache_read_input_tokens // 0) + (.output_tokens // 0)),
              (.output_tokens // 0) ] | @tsv' "$tpath" 2>/dev/null \
      | awk -F'\t' '{ n++; last=$1; out+=$2; if ($1>mx) mx=$1 }
                    END { printf "%d %d %d %d\n", last+0, n+0, out+0, mx+0 }')
EOF
  fi
fi
case "$live"      in ''|*[!0-9]*) live=0 ;; esac
case "$turns"     in ''|*[!0-9]*) turns=0 ;; esac
case "$out_total" in ''|*[!0-9]*) out_total=0 ;; esac
case "$peak"      in ''|*[!0-9]*) peak=0 ;; esac

# --- resolve ONE percentage + say which source it came from -------------------
derived=-1
[ "$live" -gt 0 ] && derived=$(( (live * 100 + LIMIT / 2) / LIMIT ))
if [ -n "$stamp" ]; then pct="$stamp"; src="statusline"
elif [ "$derived" -ge 0 ];  then pct="$derived"; src="transcript"
else pct=-1; src="none"
fi

# --- verdict ------------------------------------------------------------------
thr="${FLEET_AUTO_HANDOFF_PCT:-0}"
case "$thr" in ''|*[!0-9]*) thr=0 ;; esac
if [ "$thr" -gt 0 ]; then
  hand="$thr"; warn=$(( thr - 15 )); [ "$warn" -lt 1 ] && warn=1
else
  hand=80; warn=50                       # conf/statusline.sh's own red/yellow bands
fi
if   [ "$pct" -lt 0 ];        then verdict="UNKNOWN"; why="no @ctx_pct stamp and no usage record yet"
elif [ "$pct" -ge "$hand" ];  then verdict="HANDOFF"; why="at/over ${hand}% — run /fleet-handoff now, before the window forces a compaction"
elif [ "$pct" -ge "$warn" ];  then verdict="WATCH";   why="past ${warn}% — finish this thread, then /fleet-handoff rather than starting a broad sweep"
else                               verdict="OK";      why="under ${warn}% — carry on"
fi

if [ "$quiet" = "1" ]; then
  printf '%s\n' "$verdict"
  [ "$verdict" = "OK" ] && exit 0 || exit 1
fi

# --- render -------------------------------------------------------------------
_k() { awk -v n="${1:-0}" 'BEGIN {
  if (n < 1000)              printf "%d", n
  else if (n % 1000 == 0)    printf "%dk", n/1000
  else                       printf "%.1fk", n/1000
}'; }

if [ "$as_json" = "1" ]; then
  printf '{"verdict":"%s","pct":%s,"source":"%s","live_tokens":%s,"limit":%s,' \
    "$verdict" "$pct" "$src" "$live" "$LIMIT"
  printf '"derived_pct":%s,"stamp_pct":%s,"turns":%s,"output_tokens":%s,"peak_tokens":%s,' \
    "$derived" "${stamp:--1}" "$turns" "$out_total" "$peak"
  printf '"warn_pct":%s,"handoff_pct":%s,"auto_handoff_pct":%s,"armed":%s,"transcript":"%s"}\n' \
    "$warn" "$hand" "$thr" "$([ -n "$armed" ] && echo true || echo false)" "${tpath//\"/}"
  [ "$verdict" = "OK" ] && exit 0 || exit 1
fi

if [ "$pct" -ge 0 ]; then
  if [ "$live" -gt 0 ]; then
    printf 'context   %s%%  (%s / %s tokens)   src=%s\n' \
      "$pct" "$(_k "$live")" "$(_k "$LIMIT")" "$src"
  else
    printf 'context   %s%%   src=%s\n' "$pct" "$src"
  fi
  # Both readings, when both exist — they legitimately differ (Claude Code's own
  # number counts the autocompact reserve), and seeing both beats trusting one.
  if [ -n "$stamp" ] && [ "$derived" -ge 0 ] && [ "$stamp" != "$derived" ]; then
    printf 'cross     statusline %s%% vs transcript-derived %s%% (the stamp counts the autocompact reserve)\n' \
      "$stamp" "$derived"
  fi
else
  printf 'context   unknown — no statusline stamp on this pane and no usage record in the transcript\n'
fi
if [ "$turns" -gt 0 ]; then
  printf 'session   %s assistant turns · %s output tokens' "$turns" "$(_k "$out_total")"
  # A live figure well under the peak means a /clear or an autocompact already
  # dropped this session's context — worth saying, since the number looks "fresh"
  # while the work behind it is not.
  if [ "$peak" -gt 0 ] && [ "$live" -gt 0 ] && [ "$peak" -gt $(( live + live / 5 )) ]; then
    printf ' · peak %s (already compacted/cleared)' "$(_k "$peak")"
  fi
  printf '\n'
fi
if [ "$thr" -gt 0 ]; then
  printf 'handoff   auto-handoff at %s%%%s · watch from %s%%\n' \
    "$thr" "$([ -n "$armed" ] && echo ' (already armed)')" "$warn"
else
  printf 'handoff   auto-handoff OFF (FLEET_AUTO_HANDOFF_PCT=0) · bands %s%%/%s%%\n' "$warn" "$hand"
fi
printf 'verdict:  %s — %s\n' "$verdict" "$why"

[ "$verdict" = "OK" ] && exit 0 || exit 1
