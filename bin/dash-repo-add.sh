#!/bin/bash
# dash-repo-add.sh [--session <sess>] [<owner/name>] — add a repo to this fleet from
# the UI (issue #1103, EPIC #1096 C7).
#
# Two entries, one script (EPIC #894 convention 1): the hub dash's ⌃z (`repo-add`
# in bin/dash-keymap.sh) and the task sidebar's row menu `g` (fleet-sidebar-menu.sh)
# both run it inside bin/dash-popup.sh. It asks ONE thing — the repo as owner/name
# (a GitHub URL or git@ form is normalised) — checks the shape, and hands it to
# `fleet-repo.sh add --session <sess> <owner/name>`: fleet_repo_register (issue
# #1104), the same implementation fleet-up.sh gives the first repo, so the checkout
# is $HOME/projects/<name> (reused when it already is that repo, cloned when
# missing — the clone streams its progress into the popup and can take a while),
# the base branch is resolved, the overlay is written, and the follow-through
# (trust warning, daemon wake, collector kick) runs. Nothing to restart: the dash
# re-reads fleet_repos every frame, so the new repo's heading is on the next one.
#
# The verdict is fleet-repo.sh's stdout token, said in the operator's words and
# held on screen until dismissed — ↵ / esc / a tap on [✕ close] (iPad first,
# issue #346). A wrong shape re-asks instead of failing; esc anywhere cancels.
#
# With <owner/name> on the command line nothing is asked and nothing waits — the
# scriptable form (tests, a one-liner, and what a Claude session runs when told
# 「把 xxx 仓库拉下来」 — skills/fleet-add-repo, issue #3375). ⌘P's 「添加仓库…」 opens
# the interactive form (fleet-quickopen.py's `repo-add`).
#
# Every sentence is fleet-ui-lang.sh's (repo_add_*, zh/en — issue #3375); a token is
# never shown bare. failed:clone is read off the clone's own output into one of
# 拉不到 GitHub（网络） · GitHub 上找不到 · 没登录 (clone_reason). Two seams print
# without adding anything: `--shape <text>` (the owner/name it normalises to, rc 1
# when none) and `--explain <token> <owner/name> [<clone output file>]` (the
# sentence that token gets) — the selftest's, and anyone's who wants the words.
#
# --session names the fleet; default $FLEET_SESSION (both popup openers export
# it), else the pane's own fleet; a name that is no fleet falls to the login's one
# fleet when it has exactly one.
#
# stdout is ONE result token — the set fleet-repo.sh add prints (added:<slug> ·
# refused:hosted · refused:origin-mismatch · refused:not-a-checkout ·
# refused:invalid-repo · failed:clone · failed:write) plus three of its own:
# `cancelled` (the prompt was dismissed), `refused:no-fleet` and `failed:no-result`
# (fleet-repo.sh printed no token). Exit 0 = added, 1 = refused/failed, 2 = usage,
# 130 = cancelled. Every human line is on stderr — inside the popup that IS the
# screen, so the operator sees the clone progress and the verdict either way.
set -uo pipefail
# fzf owns the input line (UTF-8/IME/paste-aware echo, instant esc — issue #429);
# force a UTF-8 locale so the CJK verdict lines are whole characters everywhere.
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

. "$BIN/fleet-ui-lang.sh"
t() { fleet_ui_t "$@"; }

# shape <text> → the normalised owner/name on stdout; rc 1 when it is not one. The
# same rule fleet_repo_register applies, checked here first so a typo re-asks in
# the popup instead of burning a fleet-repo.sh run on it. A pasted link may carry
# a tail (/tree/main, ?tab=…, #readme) — only owner/name is kept.
shape() {
  local r; r=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$r" in
    http://*|https://*|ssh://*|github.com/*|www.github.com/*)
      r="${r#*://}"; r="${r%%[?#]*}"
      r=$(printf '%s' "$r" | awk -F/ '{ print $2 "/" $3 }') ;;
  esac
  r=$(fleet_norm_repo "$r")
  case "$r" in
    *[!A-Za-z0-9_./-]* | */*/* | /* | */) return 1 ;;
    ?*/?*) printf '%s' "$r"; return 0 ;;
  esac
  return 1
}

# clone_reason <file> → net | notfound | auth | "" — why a clone failed, read off
# what gh / git said. Not-found first: gh's 「Could not resolve to a Repository」
# must not read as DNS's 「Could not resolve host」.
clone_reason() {
  local f="${1:-}" low
  [ -n "$f" ] && [ -f "$f" ] || return 0
  low=$(tr '[:upper:]' '[:lower:]' < "$f")
  case "$low" in
    *"could not resolve to a repository"*|*"repository not found"*|*"returned error: 404"*|*"http 404"*|*"not found (http"*)
      echo notfound ;;
    *"gh auth login"*|*"authentication failed"*|*"permission denied (publickey)"*|*"could not read username"*|*"bad credentials"*|*"http 401"*|*"returned error: 403"*)
      echo auth ;;
    *"could not resolve host"*|*"resolve host"*|*"failed to connect"*|*"timed out"*|*"connection refused"*|*"network is unreachable"*|*"no route to host"*|*"connection reset"*|*"error connecting to"*|*"dial tcp"*|*"tls handshake"*|*"ssl"*|*"name resolution"*|*"no such host"*|*"unable to access"*)
      echo net ;;
  esac
}

# verdict <token> <owner/name> <dir> [<clone output file>] → the sentence (stdout)
verdict() {
  local tok="$1" repo="$2" dir="$3" f="${4:-}"
  case "$tok" in
    added:*)                 t repo_add_added_fmt "$repo" "$dir" ;;
    refused:hosted)          t repo_add_hosted_fmt "$repo" "$dir" ;;
    refused:origin-mismatch) t repo_add_mismatch_fmt "$dir" "$repo" ;;
    refused:not-a-checkout)  t repo_add_notcheckout_fmt "$dir" ;;
    refused:invalid-repo)    t repo_add_invalid_fmt "$repo" ;;
    refused:no-fleet)        t repo_add_nofleet ;;
    failed:clone)
      case "$(clone_reason "$f")" in
        net)      t repo_add_net ;;
        notfound) t repo_add_notfound_fmt "$repo" ;;
        auth)     t repo_add_auth ;;
        *)        t repo_add_clone ;;
      esac ;;
    failed:write)            t repo_add_write ;;
    failed:no-result|'')     t repo_add_noresult ;;
    *)                       t repo_add_other ;;
  esac
}

case "${1:-}" in
  --shape)   [ $# -eq 2 ] || exit 2; shape "$2"; rc=$?; [ "$rc" = 0 ] && echo; exit "$rc" ;;
  --explain) [ $# -ge 3 ] && [ $# -le 4 ] || exit 2
             verdict "$2" "$3" "$HOME/projects/$(basename "$3")" "${4:-}"; echo; exit 0 ;;
esac

SESS=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)   [ $# -ge 2 ] || { echo "dash-repo-add: --session needs a value" >&2; exit 2; }
                 SESS="$2"; shift 2 ;;
    --session=*) SESS="${1#--session=}"; shift ;;
    -h|--help)   sed -n '2,3p' "$0" | sed 's/^# //' >&2; exit 2 ;;
    -*)          echo "dash-repo-add: unknown flag $1" >&2; exit 2 ;;
    *)           [ -z "$REPO" ] || { echo "dash-repo-add: extra arg $1" >&2; exit 2; }
                 REPO="$1"; shift ;;
  esac
done
[ -n "$SESS" ] || SESS="${FLEET_SESSION:-}"
[ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null)
# Not a fleet (⌘P on a shell session of this machine, issue #3375) but the login
# has exactly one — one fleet per login — that one is meant.
if [ -z "$SESS" ] || [ ! -f "$(fleet_conf_file "$SESS")" ]; then
  only=$(fleet_each_conf 2>/dev/null | cut -f1)
  case "$only" in ?*) [ "$(printf '%s\n' "$only" | grep -c .)" = 1 ] && SESS="$only" ;; esac
fi
if [ -z "$SESS" ] || [ ! -f "$(fleet_conf_file "$SESS")" ]; then
  echo "dash-repo-add: not inside a fleet — pass --session <sess>" >&2
  t repo_add_nofleet >&2; echo >&2
  echo "refused:no-fleet"; exit 1
fi

INTERACTIVE=0
if [ -z "$REPO" ]; then
  if ! [ -t 0 ] && ! [ -t 1 ]; then
    echo "dash-repo-add: no repo given and no terminal to ask on — dash-repo-add.sh <owner/name>" >&2; exit 2
  fi
  command -v fzf >/dev/null 2>&1 \
    || { echo "dash-repo-add: fzf not found — from a shell: bin/fleet-repo.sh add <owner/name>" >&2; exit 2; }
  INTERACTIVE=1
fi

# `[✕ close]` header token + click-header bind: an iPad/Termius tap-to-dismiss
# where Escape is a reach (issue #346); bracketed as a button (issue #381), so the
# clicked word is `[✕` or `close]` and the case globs fire on either half.
# shellcheck disable=SC2016  # fzf expands $FZF_CLICK_HEADER_WORD itself
CLOSE_BIND='click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac'

if [ "$INTERACTIVE" = 1 ]; then
  hosted=$(fleet_repos "$SESS" | paste -sd ' ' - | sed 's/ / · /g')
  # fzf as a pure text input (issue #429): empty candidate list (< /dev/null),
  # --print-query echoes the typed line as the first output line. Exit 130 = Esc /
  # Ctrl-C / the ✕ tap → cancel; 0/1 = accepted (1 = Enter with no match, the
  # normal case here). fzf reads keys from /dev/tty, so it works inside
  # a fleet popup.
  note=""
  while :; do
    hdr=$(t repo_add_header_fmt "$SESS")
    hdr="$hdr"$'\n'"$(t repo_add_hosted_list_fmt "${hosted:-$(t repo_add_none)}")"
    [ -n "$note" ] && hdr="$hdr"$'\n'"$note"
    raw=$(fzf --print-query --no-multi --layout=reverse --no-info --no-separator \
              --height=100% --border=none --prompt='owner/name ▸ ' --header="$hdr" \
              --bind "$CLOSE_BIND" < /dev/null 2>/dev/null); rc=$?
    [ "$rc" -eq 130 ] && { echo cancelled; exit 130; }
    raw=${raw%%$'\n'*}
    raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$raw" ] || { echo cancelled; exit 130; }
    if REPO=$(shape "$raw"); then break; fi
    note=$(t repo_add_retry_fmt "$raw")
  done
else
  raw="$REPO"
  REPO=$(shape "$raw") || {
    echo "dash-repo-add: '$raw' is not owner/name" >&2
    verdict refused:invalid-repo "$raw" "" >&2; echo >&2
    echo "refused:invalid-repo"; exit 1; }
fi

name=$(basename "$REPO"); dir="$HOME/projects/$name"
tokf=$(mktemp "${TMPDIR:-/tmp}/dash-repo-add.XXXXXX") || exit 2
errf=$(mktemp "${TMPDIR:-/tmp}/dash-repo-add.XXXXXX") || { rm -f "$tokf"; exit 2; }
trap 'rm -f "$tokf" "$errf"' EXIT
{
  echo "→ fleet-repo.sh add --session $SESS $REPO"
  echo "  $(t repo_add_running_fmt "$dir")"
  echo
} >&2
# stdout (the token) to a file; stderr (the clone's progress, the human lines)
# streams to the screen AND to a file, for the verdict screen's tail. A pipeline,
# not a process substitution, so the tee is done before the file is read.
bash "$BIN/fleet-repo.sh" add --session "$SESS" "$REPO" 2>&1 >"$tokf" | tee "$errf" >&2
token=$(grep -E '^(added|refused|failed):' "$tokf" | tail -n 1)

case "$token" in
  added:*) rc=0 ;;
  refused:*|failed:*) rc=1 ;;
  *) token="failed:no-result"; rc=1 ;;
esac
# refused:hosted: say where the code already is — the repo's own checkout
[ "$token" = refused:hosted ] && {
  have=$(bash "$BIN/fleet-repo.sh" get --session "$SESS" FLEET_MAIN "$REPO" 2>/dev/null)
  [ -n "$have" ] && dir="$have"; }
v=$(verdict "$token" "$REPO" "$dir" "$errf")
printf '\n%s\n' "$v" >&2
printf '%s\n' "$token"

# Hold the verdict on screen until dismissed (the popup closes with us). A list,
# not a `read -rsn1`: ↵ / esc / a double-tap on a row / a tap on [✕ close] all
# close it, which is what an iPad has. The last lines fleet-repo.sh said come
# along (a clone's \r progress unfolded), so a failure's reason is on screen.
if [ "$INTERACTIVE" = 1 ]; then
  rows="$v"$'\n'"$(tr '\r' '\n' < "$errf" | grep -v '^[[:space:]]*$' | tail -n 8 | sed 's/^/    /')"
  printf '%s\n' "$rows" | fzf --no-sort --layout=reverse-list --info=hidden --no-separator \
      --border=none --height=100% --no-input \
      --header="$(t repo_add_close)" --bind "$CLOSE_BIND" >/dev/null 2>&1 || :
fi
exit "$rc"
