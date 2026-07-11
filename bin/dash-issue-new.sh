#!/bin/bash
# dash-issue-new.sh [confirm] [--spawn] — file a NEW GitHub issue from a popup.
#
# Two callers share this one script (issue #205):
#   • backlog ⌃n (capture-only): file the issue, drop it in the backlog, done.
#     `enter` on the row later spawns the worker (or autofill picks it up).
#   • prefix+n (quick-dispatch, --spawn): file the issue AND immediately spawn
#     its bound worker window (dash-issue-session.sh) — one keystroke → one line
#     → issue filed + worker running, zero LLM tokens in the dispatch path.
#
# Called with no args it opens a small popup that reads a title (required) and an
# optional body; the popup re-invokes it with `confirm` (carrying --spawn when
# set), which runs `gh issue create` against this fleet's repo, optimistically
# drops the new row into the issues cache (so the panel's reload shows it at
# once), and kicks a background refetch to make it authoritative. In --spawn mode
# it then spawns the worker; a session-cap refusal surfaces visibly and the issue
# is still filed (files-without-spawning — the backlog item is never lost).
# Empty title aborts quietly; a gh failure surfaces and doesn't wedge the modal.
#
# Args (order-independent): `confirm` = phase 2 (running inside the popup);
# `--spawn` = quick-dispatch mode (spawn the worker after create).
mode=""; spawn=0
for _a in "$@"; do
  case "$_a" in
    confirm) mode=confirm ;;
    --spawn) spawn=1 ;;
  esac
done
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

FLEET_SESSION=$(fleet_current_session); export FLEET_SESSION
# Overlay this fleet's per-session conf so a per-fleet FLEET_AUTO_TRIAGE=1 (and
# FLEET_AUTO_TRIAGE_MODEL) is honored — the auto-triage knob is opt-in per fleet,
# like FLEET_AUTOFILL. Sourced in BOTH phases (this runs before the phase split),
# so phase 2 inside the popup sees it too. Repo resolution below still wins via CF_REPO.
fleet_load_conf "$FLEET_SESSION"
# repo: CF_REPO (passed through the popup) wins; else the fleet's cached repo,
# else the global FLEET_REPO — matching the backlog panel's resolution.
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -n "${CF_REPO:-}" ] && REPO="$CF_REPO"
[ -z "$REPO" ] && { tmux display-message "backlog: no repo resolved — cannot create issue"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot create issue"; exit 1; }

# phase 1: pop the input dialog that re-invokes us in `confirm` mode. Carry
# --spawn through so quick-dispatch (prefix+n) reaches phase 2 as a spawn. A taller
# popup when auto-triage is on leaves room to echo the triaged title/labels.
if [ "$mode" != confirm ]; then
  spawn_arg=""; [ "$spawn" = 1 ] && spawn_arg=" --spawn"
  ph=12; [ "${FLEET_AUTO_TRIAGE:-0}" = 1 ] && ph=16
  tmux display-popup -w 76 -h "$ph" -E "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm$spawn_arg"
  exit 0
fi

# phase 2: running inside the popup — read a title (required) then an optional
# body, then file the issue. Title-only is the fast path (empty body is fine).
[ "$spawn" = 1 ] && verb="New issue + worker" || verb="New issue"
printf '\n  %s in \033[1m%s\033[0m\n  (empty title = cancel)\n\n  title ▸ ' "$verb" "$REPO"
IFS= read -r title
[ -z "$title" ] && exit 0
printf '  body  ▸ (optional, enter to skip) '
IFS= read -r body

# --- optional inline auto-triage (issue #235) ---------------------------------
# When FLEET_AUTO_TRIAGE=1 (and claude + the helper are present), expand the one
# line into a triaged issue: a refined title, an elaborated body, a component
# MILESTONE, a type LABEL, and a priority:pN tier — all validated against the
# repo's real sets by fleet-triage.sh, so the `gh issue create` below can't fail
# on an invented name. OFF by default (this whole block is skipped) → capture
# stays the raw, fast, zero-token path. Any triage hiccup silently falls back to
# the raw title/body the user typed (the issue is never lost).
labels="" milestone=""
if [ "${FLEET_AUTO_TRIAGE:-0}" = 1 ] && command -v claude >/dev/null 2>&1 && [ -x "$BIN/fleet-triage.sh" ]; then
  printf '\n  \033[2mauto-triage…\033[0m'
  # FLEET_AUTO_TRIAGE_MODEL is a shell var from the sourced conf (not exported), so
  # pass it EXPLICITLY to the child — only if set, so an unset value keeps
  # fleet-triage.sh's own haiku default rather than forcing --model "".
  tri_model=()
  [ -n "${FLEET_AUTO_TRIAGE_MODEL:-}" ] && tri_model=(--model "$FLEET_AUTO_TRIAGE_MODEL")
  if tri=$("$BIN/fleet-triage.sh" --repo "$REPO" --line "$title" --body "$body" "${tri_model[@]}" 2>/dev/null) && [ -n "$tri" ]; then
    # Parse fleet-triage.sh's stdout contract in pure bash (BSD sed doesn't grok
    # \t in a pattern): header lines "KEY<TAB>value", then everything after the
    # @@FLEET_TRIAGE_BODY@@ sentinel is the body.
    t_title="" t_body="" in_body=0; TAB=$'\t'
    while IFS= read -r ln; do
      if [ "$in_body" = 1 ]; then t_body+="$ln"$'\n'; continue; fi
      case "$ln" in
        '@@FLEET_TRIAGE_BODY@@') in_body=1 ;;
        "TITLE${TAB}"*)     t_title="${ln#TITLE"${TAB}"}" ;;
        "MILESTONE${TAB}"*) milestone="${ln#MILESTONE"${TAB}"}" ;;
        "LABELS${TAB}"*)    labels="${ln#LABELS"${TAB}"}" ;;
      esac
    done <<TRI
$tri
TRI
    t_body="${t_body%$'\n'}"                        # drop the trailing newline
    [ -n "$t_title" ] && title="$t_title"
    [ -n "$t_body" ]  && body="$t_body"
    printf ' \033[32m✓\033[0m\n  \033[1m%s\033[0m\n' "$title"
    [ -n "$milestone" ] && printf '  \033[2mmilestone:\033[0m %s\n' "$milestone"
    [ -n "$labels" ]    && printf '  \033[2mlabels:\033[0m %s\n' "$labels"
  else
    printf ' \033[33mskipped\033[0m (unavailable) — filing as typed\n'
  fi
fi

# Build the create args: optional --milestone / repeated --label (both already
# validated by triage to exist in the repo, so create never fails on them).
create_args=(--repo "$REPO" --title "$title" --body "$body")
[ -n "$milestone" ] && create_args+=(--milestone "$milestone")
if [ -n "$labels" ]; then
  _oldifs="$IFS"; IFS=','
  for L in $labels; do [ -n "$L" ] && create_args+=(--label "$L"); done
  IFS="$_oldifs"
fi

if url=$(gh issue create "${create_args[@]}" 2>/dev/null); then
  num="${url##*/}"; num="${num//[^0-9]/}"          # trailing #num from the issue URL
  # Optimistically insert the new row into THIS fleet's issues cache so the modal's
  # reload shows it at once (mirrors dash-issue-close.sh's optimistic drop). A
  # brand-new issue has no milestone + no assignee, matching the collector's row
  # format: "<milestone>\t#<num>\t<assignee>\t<title>". fleet_cache returns the
  # exact file the reload reads, so we never touch the .ts (no flat-cache flash).
  src=$(fleet_cache issues "$FLEET_SESSION")
  [ -n "$num" ] && [ -n "$src" ] && \
    printf '%s\t#%s\t%s\t%s\n' "${milestone:-· no milestone}" "$num" '·' "$title" >> "$src"
  # kick a background refetch to make the cache authoritative (ordering, dedup);
  # GH_TTL=0 forces the fetch regardless of cache age.
  ( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )
  if [ "$spawn" = 1 ] && [ -n "$num" ]; then
    # Quick-dispatch (prefix+n): spawn the bound worker now. dash-issue-session.sh
    # is the shared spawn choke point — it enforces the global + per-fleet session
    # caps and the already-spawned dedup. Pass the title as --title so the window
    # is named after the WORK without depending on the just-written optimistic cache
    # row surviving the background collector refetch (issue #216). It exits non-zero
    # on a cap refusal (already surfaced via its own display-message). If it
    # refuses, the issue is STILL filed — announce filed-without-spawning in the
    # popup so the item is visibly not lost (acceptance (c)); it sits in the backlog
    # for a later spawn.
    if bash "$BIN/dash-issue-session.sh" "$num" --title "$title"; then
      tmux display-message "filed + spawned #$num in $REPO ✓"
    else
      printf '\n  \033[33mfiled #%s ✓ — but NOT spawned\033[0m (session cap reached).\n  It is in the backlog; enter on its row spawns it later.\n  press any key ' "$num"; read -rsn1 _
    fi
  else
    tmux display-message "filed new issue #$num in $REPO ✓"
  fi
else
  printf '\n  \033[31mfailed to create issue in %s\033[0m — press any key ' "$REPO"; read -rsn1 _
fi
