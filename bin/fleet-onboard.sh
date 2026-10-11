#!/bin/bash
# fleet-onboard.sh — the onboarding wizard's memory + one-call brief (issue #1168,
# EPIC #1163 C5). The wizard itself is commands/fleet-onboard.md; this is the
# part of it that has to survive the conversation.
#
#   fleet-onboard.sh brief [--session <sess>] [--dev] [--no-gh]  # everything step 0 needs
#   fleet-onboard.sh look  [--mark]                       # the session the newcomer started
#   fleet-onboard.sh get   [<key>]                        # the saved progress
#   fleet-onboard.sh set   <key>=<value>…                 # record progress (merges)
#   fleet-onboard.sh reset                                # start over
#   fleet-onboard.sh path                                 # where it lives
#
# WHY A FILE. A newcomer does not finish in one sitting: they close the laptop
# while the worker runs, or the window is reaped, or they call the wizard back a
# day later (R1 #1171). The wizard must pick up at the step it left — never
# re-ask which repo, never re-file the issue it already filed. So progress lives
# on disk, not in the transcript: $FLEET_CONF_DIR/global/onboard.state. Global,
# not per-fleet, because a login has exactly ONE fleet (EPIC #977) and the
# newcomer is the login, not a session name.
#
# FORMAT. `key=value` lines, one per key, rewritten atomically (tmp + mv) with a
# fresh `updated=<epoch>`. Values are one line: a newline or CR in a value is
# folded to a space, so no value can forge a second key. Unknown keys are kept —
# a later wizard version may add some.
#
# STEPS, in order (`step=` holds the one the wizard is ON, i.e. not finished).
# The default walk is for someone who never wrote code (issue #3332, EPIC #3178
# C20): one key, one thing done, two or three minutes — no repo, no issue, no PR.
#   key     say hello, teach the one key (⌘P · phone ⌃Space) → `look --mark`
#   try     they write one thing on ⌘P's ⚡ row and press ↵   → records task= once seen
#   see     they watch that session work and finish
#   done    finished — calling the wizard back offers one more, or the developer walk
# The developer walk is optional, entered only when they ask for it (path=dev):
#   repo    pick / add their own repo (GitHub login lives here, nowhere else)
#   issue   the same ⚡ row, its 仓库 cell set to that repo → the hub files it
#   watch   the session works, opens a PR               → records pr= once one opens
#   merge   look at the merged PR together
# `set step=<x>` refuses anything else (exit 2), so a typo can't strand the resume.
# An older walk's saved `handoff` (the step #3332 retired) resumes as `done`.
#
# THE LANGUAGE (issue #3329). `brief` prints `lang=` — the saved one, else
# fleet_ui_lang (the person's hub choice, the 看台's @view_lang, the locale) —
# and the walk's fixed lines as `say.<name>:` in that language, from
# fleet-ui-lang.sh's onboard_* keys (the one table; both languages there).
#
# LOOK. The session the newcomer starts from ⌘P is an ordinary window the guide
# did not open, so the guide cannot be told about it; it looks instead. `look
# --mark` remembers every window there is (global/onboard.seen, @fleet_id per
# line) right before they press the key; a later `look` prints each worker
# window that is not on that list, one `new<TAB>state<TAB>task<TAB>issue<TAB>
# repo<TAB>words` row (`none` when there is none yet). Every scan is fleet_lw.
#
# THE SPOKE MARKER (issue #1215). The first `brief` that runs inside a fleet also
# writes $FLEET_CONF_DIR/global/guide.spoke — the wizard has genuinely reached
# its step 0 on this login. fleet-lib's fleet_guide_alive requires it: a guide
# window whose claude came up but only printed `Unknown command: /fleet-onboard`
# (#1210 ③) is running and has NOT spoken, so fleet-up / the collector never
# record `onboarded` over it and the collector reopens it instead. Written here
# ONLY, read everywhere else; `reset` forgets the progress, not that it spoke.
#
# THE STARTER REPO. A newcomer's fleet is started on claude-fleet itself
# (`fleet-up.sh --seed`, C4 #1167), marked by FLEET_SEED=1 in the fleet conf and
# read ONLY through fleet_repo_is_seed — it marks the conf's OWN repo, never an
# overlay. `brief` tags it `[seed]` so the wizard can say plainly
# «this is the tool itself, not your repo» and never offer it as a place to work.
# Once another repo is hosted the tag also names the way out — `fleet-repo.sh
# remove <seed>` (issue #1172), which the wizard offers right after the add.
#
# Exit: 0 ok · 1 no such key (get) / write failed · 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-ui-lang.sh"

STEPS="key try see done repo issue watch merge"

usage() { sed -n '5,9p' "$0" | sed 's/^# //' >&2; exit 2; }

state_file() { printf '%s/global/onboard.state' "$FLEET_CONF_DIR"; }
spoke_file() { printf '%s/global/guide.spoke' "$FLEET_CONF_DIR"; }
seen_file()  { printf '%s/global/onboard.seen' "$FLEET_CONF_DIR"; }

# the walk's fixed lines, in the order the skill says them (fleet-ui-lang.sh onboard_*)
SAY="hello key try sent done more dev"

# The wizard reached step 0: record it once (the first time it spoke stays).
# Best effort — a brief that could not leave the marker is still a brief.
mark_spoke() {
  local f; f=$(spoke_file)
  [ -e "$f" ] && return 0
  mkdir -p "${f%/*}" 2>/dev/null && date '+%Y-%m-%d %H:%M:%S' > "$f" 2>/dev/null
  return 0
}

# Print the saved state (nothing when there is none).
state_dump() {
  local f; f=$(state_file)
  [ -r "$f" ] && grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f"
  return 0
}

state_get() {
  state_dump | awk -v k="$1" 'index($0, k"=")==1 { v=substr($0, length(k)+2); found=1 } END { if (found) print v; exit !found }'
}

valid_step() {
  case " $STEPS " in *" $1 "*) return 0 ;; esac
  return 1
}

# set k=v… — merge into the existing state, atomically.
state_set() {
  local f dir tmp kv k
  f=$(state_file); dir=${f%/*}
  [ $# -gt 0 ] || usage
  for kv in "$@"; do
    case "$kv" in
      [A-Za-z_]*=*) ;;
      *) echo "fleet-onboard: not key=value: $kv" >&2; exit 2 ;;
    esac
    k=${kv%%=*}
    case "$k" in *[!A-Za-z0-9_]*) echo "fleet-onboard: bad key: $k" >&2; exit 2 ;; esac
    if [ "$k" = step ] && ! valid_step "${kv#*=}"; then
      echo "fleet-onboard: unknown step '${kv#*=}' (one of: $STEPS)" >&2; exit 2
    fi
  done
  mkdir -p "$dir" 2>/dev/null || { echo "fleet-onboard: cannot create $dir" >&2; exit 1; }
  tmp=$(mktemp "$dir/.onboard.state.XXXXXX") || { echo "fleet-onboard: cannot write $dir" >&2; exit 1; }
  # Old lines, then the new ones, then the stamp; the LAST value of a key wins
  # and each key keeps the position it first appeared at.
  {
    state_dump
    for kv in "$@"; do
      printf '%s=%s\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | tr '\r\n' '  ')"
    done
    printf 'updated=%s\n' "$(date +%s)"
  } | awk '{ k=substr($0, 1, index($0,"=")-1); if (k == "updated") { u = $0; next }; if (!(k in v)) o[n++]=k; v[k]=$0 }
           END { for (i=0; i<n; i++) print v[o[i]]; print u }' > "$tmp"
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" || { rm -f "$tmp"; echo "fleet-onboard: write failed: $f" >&2; exit 1; }
}

brief() {
  local sess="" gh="" dev=0 conf r tag me="" step seat lang n
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) shift; sess="${1:-}" ;;
      --dev)     dev=1 ;;
      --no-gh)   gh=0 ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$sess" ] || sess=$(fleet_current_session)
  if [ -z "$sess" ] || ! conf=$(fleet_conf_file "$sess") || [ ! -f "$conf" ]; then
    echo "fleet-onboard: not inside a fleet (session='${sess:-}')" >&2
    exit 3
  fi
  fleet_load_conf "$sess"
  seat=$(fleet_seat)
  mark_spoke
  [ "$(state_get path 2>/dev/null)" = dev ] && dev=1
  [ -n "$gh" ] || gh=$dev

  # One language for the whole walk: what they chose here, else what the fleet
  # draws for this person (fleet_ui_lang).
  lang=$(state_get lang 2>/dev/null)
  case "$lang" in zh|en) ;; *) lang=$(fleet_ui_lang) ;; esac

  echo "===== fleet ====="
  echo "session=$sess seat=${seat:-none} lang=$lang path=$([ "$dev" = 1 ] && echo dev || echo plain)"
  echo "===== say ($lang) ====="
  for n in $SAY; do
    printf 'say.%s: %s\n' "$n" "$(_FLEET_UI_L=$lang fleet_ui_t "onboard_$n")"
  done

  # The plain walk never names a repo, GitHub or an issue (issue #3320 gaps 1, 6):
  # the repos and the GitHub login are the developer walk's only.
  if [ "$dev" = 1 ]; then
    echo "===== developer walk ====="
    if [ "$gh" = 1 ]; then
      me=$(gh api user --jq .login 2>/dev/null)
      echo "gh=${me:-NOT-LOGGED-IN}"
    fi
    echo "repos:"
    local nrepos; nrepos=$(fleet_repos "$sess" | grep -c .)
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      tag=""
      if fleet_repo_is_seed "$sess" "$r"; then
        tag="  [seed] 起步仓库 = 工具本身，不是新人的仓库 · 不提、不让人处理"
        [ "$nrepos" -gt 1 ] && tag="$tag · 人要拿掉才: fleet-repo.sh remove $r"
      fi
      [ -n "$me" ] && [ -z "$tag" ] && [ "${r%%/*}" = "$me" ] && tag="  [mine]"
      echo "  $r$tag"
    done <<EOF
$(fleet_repos "$sess")
EOF
  fi

  echo "===== progress ($(state_file)) ====="
  if [ -s "$(state_file)" ]; then
    state_dump
    step=$(state_get step 2>/dev/null)
    valid_step "${step:-key}" || step="done"   # an older walk's handoff (#3332)
    echo "resume: ${step:-key}"
  else
    echo "(none — a fresh start)"
    echo "resume: key"
  fi
}

# look [--mark] — see the session the newcomer started from ⌘P (header: LOOK).
look() {
  local mark=0 f rows fid name role st task issue repo words found=0
  case "${1:-}" in --mark) mark=1 ;; '') ;; *) usage ;; esac
  f=$(seen_file)
  rows=$(fleet_lw '#{@fleet_id}|#{window_name}|#{@fleet_role}|#{@claude_state}|#{@task}|#{@issue}|#{@repo}|#{@task_line}') || {
    echo "fleet-onboard: cannot read the windows (no fleet server here?)" >&2; exit 1; }
  if [ "$mark" = 1 ]; then
    mkdir -p "${f%/*}" 2>/dev/null
    printf '%s\n' "$rows" | awk -F'|' '$1 != "" { print $1 }' > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || {
      rm -f "$f.tmp.$$"; echo "fleet-onboard: cannot write $f" >&2; exit 1; }
    echo "marked: $(grep -c . "$f" 2>/dev/null || echo 0) windows"
    return 0
  fi
  [ -f "$f" ] || { echo "fleet-onboard: nothing marked yet — run look --mark before they press the key" >&2; exit 1; }
  while IFS='|' read -r fid name role st task issue repo words; do
    [ -n "$fid" ] || continue
    case "${role:-worker}" in worker) ;; *) continue ;; esac
    grep -qxF "$fid" "$f" && continue
    printf 'new\t%s\t%s\t%s\t%s\t%s\n' "${st:-starting}" "${task:--}" "${issue:+#$issue}" "${repo:--}" "${words:-$name}"
    found=1
  done <<EOF
$rows
EOF
  [ "$found" = 1 ] || echo none
}

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
case "$cmd" in
  brief) brief "$@" ;;
  look)  look "$@" ;;
  get)
    if [ $# -eq 0 ]; then state_dump
    else state_get "$1" || exit 1
    fi ;;
  set)   state_set "$@" ;;
  reset) rm -f "$(state_file)" ;;
  path)  state_file; echo ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
