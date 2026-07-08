#!/bin/bash
# dash-issue-close.sh <issue-number> [confirm] — close a GitHub issue straight
# from the backlog panel (triage without leaving tmux). Called with just the
# number it opens a small y/n confirm popup; the popup re-invokes it with
# `confirm`, which runs `gh issue close`, optimistically drops the row from the
# fleet's issues cache (so the panel repaints without it at once), and kicks a
# background refetch to make it authoritative. Closed by mistake? `gh issue
# reopen <N>` or the web — closing is reversible.
num="${1//[^0-9]/}"; [ -z "$num" ] && exit 0
mode="${2:-}"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"

FLEET_SESSION=$(fleet_current_session); export FLEET_SESSION
# repo: CF_REPO (passed through the confirm popup) wins; else the fleet's cached
# repo, else the global FLEET_REPO — matching the backlog panel's resolution.
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -n "${CF_REPO:-}" ] && REPO="$CF_REPO"
[ -z "$REPO" ] && { tmux display-message "backlog: no repo resolved — cannot close #$num"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot close #$num"; exit 1; }

# phase 1: pop a confirm dialog that re-invokes us in `confirm` mode.
if [ "$mode" != confirm ]; then
  tmux display-popup -w 64 -h 8 -E "CF_REPO='$REPO' bash '$BIN/dash-issue-close.sh' '$num' confirm"
  exit 0
fi

# phase 2: running inside the popup — ask, then close.
printf '\n  Close issue \033[1m#%s\033[0m in %s?\n\n  [y] close    [n] cancel ' "$num" "$REPO"
read -rsn1 ans; echo
case "$ans" in y|Y) ;; *) exit 0;; esac

if gh issue close "$num" --repo "$REPO" >/dev/null 2>&1; then
  src=$(fleet_cache issues "$FLEET_SESSION")
  if [ -f "$src" ]; then
    tmp="$src.$$"; grep -v $'\t#'"$num"$'\t' "$src" > "$tmp" 2>/dev/null; mv -f "$tmp" "$src"
  fi
  rm -f "$C/issue_$(fleet_slug "$REPO")_${num}" "$C/issue_$(fleet_slug "$REPO")_${num}.ts"
  rm -f "$C/issues_$(fleet_slug "$REPO").ts" "$C/issues.ts"   # force the next fetch
  ( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )
  tmux display-message "issue #$num closed ✓"
else
  printf '\n  \033[31mfailed to close #%s\033[0m — press any key ' "$num"; read -rsn1 _
fi
