#!/bin/bash
# refocus-hook.sh — re-state a worker's task charter right after a context
# compaction (issue #1266, EPIC #1262 C6). Wired to the Claude Code `SessionStart`
# hook with matcher `compact`.
#
# THE GAP. A worker learns what it is for exactly once: the /fleet-claim seed
# prints the brief (which issue, which repo, which branch, one-issue-one-PR, how
# to land). A long worker gets auto-compacted, and the summary that replaces its
# history is free to drop that opening brief — after which the session drifts
# out of scope, or forgets to ship the fleet's way (PR → verdict → merge →
# report-parent). SessionStart(source=compact) fires on the SAME pane right after
# the summary lands, so this hook hands the charter back as
# `hookSpecificOutput.additionalContext`, which Claude Code adds to the very next
# turn's context.
#
# WHAT IT EMITS. A ≤1.5 KB block that opens `[fleet charter] #<N>` (so a human,
# a selftest or a later hook — R1 reuses this one — can spot it): the issue +
# repo + title, worktree + branch + base, the PR the dash's prmap knows for that
# branch, who spawned it, and the rails. For the full thread it points at
# bin/fleet-claim-brief.sh — the one preamble read — rather than inlining it: the
# brief is many KB and costs a gh round-trip, and a SessionStart hook must stay
# small and offline. So this hook makes ZERO gh calls: tmux options, git, and
# the dash's on-disk caches (prmap for the PR, issues for the title).
#
# WHO GETS IT. Only a WORKER (fleet_seat, with the same issue-<N> worktree
# fallback fleet-claim-brief.sh uses) gets the charter. A scratch session (@raw=1)
# gets its recovery map back instead, and only after a FLEET compaction (#1318) or
# a native one bin/precompact-hook.sh saved a map for (#1321).
# The hub has neither ⇒ zero output, as does a pane outside tmux, a headless `claude -p` child
# (CLAUDE_CODE_ENTRYPOINT ≠ cli, same discriminator as set-claude-state.sh), and
# a multi-repo window whose repo is unknown (skipped, never guessed — CLAUDE.md).
# Belt and braces on the source: the settings matcher already restricts it to
# `compact`, and the script re-checks the payload so a matcher a host ignores
# (or a hand run) never injects on startup/resume/clear.
#
# Kill switch: FLEET_REFOCUS=0 in fleet.conf / the fleet overlay. Test seam: FLEET_REFOCUS_SOURCE overrides the
# stdin source. Always exits 0 (SessionStart can't block, and a broken hook must
# never cost the session its turn).
set -u
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) : ;; *) exit 0 ;; esac

if [ -n "${FLEET_REFOCUS_SOURCE:-}" ]; then
  src="$FLEET_REFOCUS_SOURCE"
elif [ ! -t 0 ]; then
  src=$(cat 2>/dev/null \
    | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
else
  src=""
fi
[ "$src" = compact ] || exit 0

# In-place compaction (issue #1269): when the fleet itself typed this /compact
# (bin/fleet-compact-send.sh stamped @compact_stage=compacting), this is step 3 —
# mark it restored and ask the worker to check the recovery map it wrote in step 1.
# Read before any early exit below, so the stage completes even with refocus off.
# Each completed compaction also bumps @compact_count (issue #1316): the Stop hook
# hands the session off instead once it reaches FLEET_COMPACT_MAX, and the fresh
# session's SessionStart (handoff-latch-reset-hook.sh) zeroes it.
compact_check=''
cstate=$(tmux display-message -p -t "$TMUX_PANE" '#{@compact_stage}|#{@compact_count}' 2>/dev/null)
if [ "${cstate%%|*}" = compacting ]; then
  tmux set-window-option -t "$TMUX_PANE" @compact_stage restored 2>/dev/null
  ccount=${cstate#*|}
  case "$ccount" in ''|*[!0-9]*) ccount=0 ;; esac
  tmux set-window-option -t "$TMUX_PANE" @compact_count $(( ccount + 1 )) 2>/dev/null
  compact_check=1
fi
# A native compaction the fleet saw coming (issue #1321): bin/precompact-hook.sh
# wrote the recovery map itself just before Claude Code's own compaction and
# stamped @compact_native. Read back here like a fleet map (not for a fleet
# compaction, which has its own), and consumed: one compaction, one read-back.
# A stamp older than an hour is stale — the compaction it announced never came.
native=''
nts=$(tmux display-message -p -t "$TMUX_PANE" '#{@compact_native}' 2>/dev/null)
case "$nts" in ''|*[!0-9]*) : ;; *)
  tmux set-window-option -u -t "$TMUX_PANE" @compact_native 2>/dev/null
  [ -z "$compact_check" ] && [ $(( $(date +%s) - nts )) -le 3600 ] && native=1 ;;
esac
# The context-ladder ledger (issue #1320): every compaction this pane comes back
# from — ours (`fleet`, the count just bumped) or Claude Code's own (`auto`, which
# used to leave no trace outside the transcript).
[ -f "$(dirname "$0")/fleet-ladder-log.sh" ] && sh "$(dirname "$0")/fleet-ladder-log.sh" restored \
  --reason "$([ -n "$compact_check" ] && echo fleet || echo auto)" </dev/null >/dev/null 2>&1

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || exit 0

issue=$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}|#{@raw}' 2>/dev/null)
raw="${issue#*|}"
issue="${issue%%|*}"
issue="${issue//[^0-9]/}"

# A SCRATCH window (@raw=1, no @issue — issue #1318) has no charter to re-state: it
# was never spawned for one issue. What it does have, after a fleet compaction, is
# the recovery map it wrote at the prep step (fleet_recovery_map_path: its worktree's
# git dir, else the fleet's conf dir) — so restate THAT, inline (the summary may have
# dropped it), with the same "check first" line. An auto compaction (not ours) and a
# missing map stay silent, as scratch always was. Same ≤ 1.5 KB contract.
if [ -z "$issue" ] && [ "$raw" = 1 ]; then
  [ -n "$compact_check$native" ] || exit 0
  sess=$(fleet_current_session)
  [ -n "$sess" ] && fleet_load_conf "$sess" 2>/dev/null
  [ "${FLEET_REFOCUS:-1}" = 0 ] && exit 0
  map=$(fleet_recovery_map_path "$TMUX_PANE" "$(pwd -P 2>/dev/null)")
  [ -n "$map" ] && [ -f "$map" ] || exit 0
  REFOCUS_MAP="$map" REFOCUS_NATIVE="$native" python3 - <<'PY' 2>/dev/null
import json, os
path = os.environ["REFOCUS_MAP"]
who = ("Claude Code auto-compacted you; the fleet saved this map just before"
       if os.environ.get("REFOCUS_NATIVE") else
       "The fleet compacted you in place to avoid a handoff")
try:
    body = open(path, encoding="utf-8", errors="replace").read().strip()
except OSError:
    raise SystemExit(0)
head = "\n".join([
    "[fleet recovery map] scratch",
    "%s. CHECK FIRST: compare this "
    "recovery map (%s) with `git status`, `git log -3` and any PR it names; fix any "
    "drift, then resume its next step." % (who, path),
    "--- map ---",
])
ctx = head + "\n" + body
b = ctx.encode("utf-8")
if len(b) > 1536:                     # the contract: ≤ 1.5 KB — the file holds the rest
    ctx = b[:1533].decode("utf-8", "ignore") + "…"
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": ctx}},
                 ensure_ascii=False))
PY
  exit 0
fi
[ -n "$issue" ] || exit 0                       # hub / unbound ⇒ silent
cwd=$(pwd -P 2>/dev/null)
seat=$(fleet_seat)
if [ "$seat" != worker ]; then
  case "$cwd" in */*issue-[0-9]*) seat=worker ;; esac
fi
[ "$seat" = worker ] || exit 0

sess=$(fleet_current_session)
[ -n "$sess" ] || exit 0
fleet_load_conf "$sess" 2>/dev/null
repo=$(fleet_window_repo "$sess" "$TMUX_PANE")
[ -n "$repo" ] || exit 0                        # unknown repo ⇒ skip, never guess
fleet_load_repo_conf "$sess" "$repo" 2>/dev/null
[ "${FLEET_REFOCUS:-1}" = 0 ] && exit 0          # the conf (global, fleet, repo overlay) can switch it off
base="${FLEET_BASE_BRANCH:-master}"
main="${FLEET_MAIN:-?}"
merge=$(fleet_merge_method 2>/dev/null); merge="${merge:-squash}"

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
branch="${branch:-issue-$issue}"

slug=$(fleet_slug "$repo")
# The dash's caches, read-only and best-effort: a cold cache just means "unknown".
pr='none yet'
prmap="$FLEET_C/fleets/$slug/prmap"
if [ -f "$prmap" ]; then
  row=$(LC_ALL=C awk -F'\t' -v b="$branch" '$1 == b { print; exit }' "$prmap" 2>/dev/null)
  if [ -n "$row" ]; then
    pr=$(printf '%s\n' "$row" | LC_ALL=C awk -F'\t' '{ s = $2 " " $3; if ($4 != "" && $4 != "·") s = s " ci" $4; print s }')
  fi
fi
title=''
issues="$FLEET_C/fleets/$slug/issues"
[ -f "$issues" ] && title=$(LC_ALL=C awk -F'\t' -v n="#$issue" '$2 == n { print $4; exit }' "$issues" 2>/dev/null)

origin=$(tmux display-message -p -t "$TMUX_PANE" '#{@origin}' 2>/dev/null)
origin=$(printf '%s' "$origin" | tr -cd 'A-Za-z0-9._:-')
case "$origin" in
  *issue-*|*scratch-*) origin_line="spawned by $origin — when you finish, report the outcome: fleet-report-parent.sh --state merged|blocked --pr <PR> --summary '…'" ;;
  *)                   origin_line="no live parent (fleet-report-parent.sh still runs on ship; it exits 0 silently)" ;;
esac

map=''
if [ -n "$compact_check$native" ]; then
  map=$(fleet_recovery_map_path "$TMUX_PANE" "$cwd")
  [ -n "$map" ] && [ -f "$map" ] || map=''
fi

REFOCUS_ISSUE="$issue" REFOCUS_REPO="$repo" REFOCUS_TITLE="$title" \
REFOCUS_CWD="$cwd" REFOCUS_BRANCH="$branch" REFOCUS_BASE="$base" \
REFOCUS_MAIN="$main" REFOCUS_MERGE="$merge" REFOCUS_PR="$pr" \
REFOCUS_ORIGIN="$origin_line" REFOCUS_CHECK="$compact_check" REFOCUS_MAP="$map" \
REFOCUS_NATIVE="$native" \
python3 - <<'PY' 2>/dev/null
import json, os
e = os.environ.get
title = (e("REFOCUS_TITLE") or "").strip()
if len(title) > 80:
    title = title[:79] + "…"
n, repo = e("REFOCUS_ISSUE"), e("REFOCUS_REPO")
lines = [
    "[fleet charter] #%s · %s%s" % (n, repo, (" — " + title) if title else ""),
    "Your context was just compacted; this restates the task you were spawned for.",
]
if e("REFOCUS_CHECK"):
    lines.append("- The fleet compacted you in place to avoid a handoff. CHECK FIRST: compare your "
                 "recovery map (%s) with `git status`, `git log -3` and the PR; fix any drift, "
                 "then resume its next step." % (e("REFOCUS_MAP") or "in the summary above"))
elif e("REFOCUS_NATIVE") and e("REFOCUS_MAP"):
    lines.append("- Claude Code auto-compacted you; the fleet saved a recovery map just before "
                 "(%s: git state, PR, latest issue comment, your last prompts). CHECK FIRST: read it, "
                 "compare with `git status` and the PR, then resume." % e("REFOCUS_MAP"))
lines += [
    "- worktree %s · branch %s → base %s · PR: %s"
        % (e("REFOCUS_CWD"), e("REFOCUS_BRANCH"), e("REFOCUS_BASE"), e("REFOCUS_PR")),
    "- One issue, one worktree, one PR: work ONLY on #%s here. Adjacent work → "
    "fleet-issue-file.sh --parent %s [--spawn], never in this worktree." % (n, n),
    "- Base checkout %s is read-only; talk on the issue via fleet-comment.sh." % e("REFOCUS_MAIN"),
    "- Done = verify → push → PR with `Closes #%s` → fleet-pr-verdict.sh <PR> "
    "(--wait in background) → on READY `gh pr merge --%s --delete-branch` → "
    "confirm MERGED → report → stop. Never /fleet-sync-install." % (n, e("REFOCUS_MERGE")),
    "- Blocked → `⛔ blocked:` comment + set-claude-state.sh blocked, report, stop.",
    "- %s" % e("REFOCUS_ORIGIN"),
    "- Full brief (issue thread + charter): ~/.claude/fleet/bin/fleet-claim-brief.sh",
]
ctx = "\n".join(lines)
b = ctx.encode("utf-8")
if len(b) > 1536:                     # the contract: ≤ 1.5 KB, whatever the paths
    ctx = b[:1533].decode("utf-8", "ignore") + "…"
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": ctx}},
                 ensure_ascii=False))
PY
exit 0
