#!/bin/bash
# fleet-up.sh [<owner/repo>] [<checkout-dir>] [--name <session>] [--base <branch>] [--seed] [--no-repo] [--no-attach]
# fleet-up.sh --undo [<session>]
#
# ONE FLEET PER LOGIN (issue #979). A login runs exactly one fleet holding all its
# repos, so this brings up THE fleet — or, when the login already has one, adds the
# repo to it (fleet-repo.sh add), then lands you on it. Creating a SECOND fleet is refused: a second fleet
# means a second login. A brand-new fleet is named "fleet"; an existing fleet keeps
# its name (fleet-claude-fleet stays fleet-claude-fleet).
#
# Bringing a fleet up: a tmux session, its conf (fleets/<session>/conf — the
# fleet's settings, no repo) and the hub. A repo — named, or inferred from the
# current checkout (its 'origin', that worktree as the checkout dir) — is added
# exactly as `fleet-repo.sh add` adds one (fleet_repo_register: reuse or clone the
# checkout, resolve the base branch, write repos/<slug>.conf): there is no first
# repo put any other way (issue #1937). With no repo (outside a checkout, or
# --no-repo) the fleet comes up with what it hosts — a brand-new one with none, its
# hub in $HOME; new sessions are then no-repo sessions until one is added. The
# collector is kicked so the sidebar has data at once. See docs/ARCHITECTURE.md.
#
# A fleet ≡ a tmux session ≡ one login. Run it for every repo you want to work:
# the first brings the fleet up, each further one adds its repo.
#
# --seed (issue #1167): this repo is only the login's STARTER — the fleet comes up
# on it so it works at once, but it never takes work: its overlay also gets
# FLEET_SEED=1 + FLEET_AUTOFILL=0 + FLEET_ISSUE_BRIDGE=0, so the dispatcher never
# auto-spawns from its backlog and the issue-bridge never relays its comments (see
# fleet_repo_is_seed). It marks the fleet's ONLY repo — a --seed for a repo added
# beside others is refused.
#
# --no-attach (issue #1165): bring the fleet up and stop — no attach, no client
# switch. For a script that sets a login up (fleet-login-bootstrap.sh) and must
# carry on past this line; the login's next `fleet` opens the client.
#
# --undo (issue #1846): take back the last `fleet down` — every session it closed
# comes back on its own conversation (fleet-restore.sh --undo, from the
# restore.map.down-<time> fleet-down.sh kept). Nothing else on this line applies.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

die() { echo "fleet-up: $*" >&2; exit 1; }
usage() { echo "usage: fleet-up.sh [<owner/repo>] [<checkout-dir>] [--name <session>] [--base <branch>] [--seed] [--no-repo] [--no-attach] | --undo [<session>]" >&2; }
need_arg() { [ "$1" -ge 2 ] || { usage; die "$2 needs an argument"; }; }   # $1=$#, $2=flag

REPO=""; DIR=""; NAME=""; BASE=""; SEED=0; NOATTACH=0; NOREPO=0
if [ "${1:-}" = --undo ]; then
  shift
  exec bash "$BIN/fleet-restore.sh" --undo "${1:-}"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --name) need_arg "$#" --name; NAME="$2"; shift 2;;
    --base) need_arg "$#" --base; BASE="$2"; shift 2;;
    --seed) SEED=1; shift;;
    --no-attach) NOATTACH=1; shift;;
    --no-repo) NOREPO=1; shift;;
    -h|--help) usage; exit 0;;
    -*) usage; die "unknown flag $1";;
    *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$DIR" ]; then DIR="$1"; else die "extra arg $1"; fi; shift;;
  esac
done
command -v tmux >/dev/null 2>&1 || die "tmux not found"
command -v git  >/dev/null 2>&1 || die "git not found"

# Disk-pressure circuit-breaker: never bring a fleet up into a nearly-full volume.
# A fleet whose first writes ENOSPC takes the SHARED tmux server — and every other
# fleet on it — down with it. --gate exits 3 when free < FLEET_DISK_FLOOR_GB.
if [ -x "$BIN/fleet-diskguard.sh" ]; then
  bash "$BIN/fleet-diskguard.sh" --gate \
    || die "disk too low to spawn a fleet safely — free space first (see: fleet-diskguard.sh --free)"
fi

# No <owner/repo> given: infer it from the current checkout ($PWD in a git
# worktree), and default the checkout dir to that worktree so we reuse it.
# Outside any checkout — or with --no-repo — no repo is added (issue #1937): the
# login's fleet comes up with the repos it has, and a brand-new one with none
# (`cf` still means "take me to my fleet", issue #979).
if [ -z "$REPO" ] && [ "$NOREPO" = 0 ]; then
  if top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
    REPO=$(git -C "$top" remote get-url origin 2>/dev/null) \
      || die "$top has no 'origin' remote — pass <owner/repo> explicitly, or --no-repo"
    DIR="${DIR:-$top}"
    echo "fleet-up: inferred $(fleet_norm_repo "$REPO") from $top"
  fi
fi
[ "$NOREPO" = 1 ] && { REPO=""; DIR=""; }

if [ -n "$REPO" ]; then
  REPO=$(fleet_norm_repo "$REPO")
  # Shape-check owner/repo before it reaches `gh repo clone`/`git clone`: exactly
  # one slash, both halves non-empty, and only chars GitHub allows (no spaces or
  # shell metacharacters). Catches typos and non-GitHub URLs up front.
  case "$REPO" in
    *[!A-Za-z0-9_./-]* | */*/* | /* | */) die "invalid repo '$REPO' — expected owner/repo";;
    ?*/?*) : ;;
    *) die "invalid repo '$REPO' — expected owner/repo";;
  esac
fi

# --- which fleet: the login's one (issue #979) ---
# The session name no longer derives from a repo. With a fleet configured, THAT is
# the fleet; with none, a new one is called "fleet". Two or more configured is an
# estate from before the fold: use the one already hosting this repo, else the one
# that is up, else refuse — never guess. --name names the fleet explicitly (restore
# passes it), and a --name that is not the login's fleet would be a second one.
if [ -n "$NAME" ]; then
  NAME=$(printf '%s' "$NAME" | tr '.: ' '-')      # tmux session names: no . : space
  LOGIN=$(fleet_login_fleet); lrc=$?
  if [ ! -f "$(fleet_conf_file "$NAME")" ] && [ "$lrc" -ne 1 ]; then
    [ "$lrc" -eq 0 ] || LOGIN="$(fleet_each_conf | cut -f1 | tr '\n' ' ')"
    die "refusing a second fleet '$NAME' — this login already has '${LOGIN% }'. One fleet per login: \`fleet-up ${REPO:-<owner/repo>}\` adds the repo to it; a second fleet needs a second login."
  fi
else
  NAME=$(fleet_login_fleet); lrc=$?
  if [ "$lrc" -eq 1 ]; then
    NAME=fleet
  elif [ "$lrc" -eq 2 ]; then
    NAME=""
    if [ -n "$REPO" ]; then
      while IFS=$'\t' read -r s _; do
        [ -n "$s" ] && fleet_repo_hosted "$s" "$REPO" && { NAME="$s"; break; }
      done < <(fleet_each_conf)
    fi
    if [ -z "$NAME" ]; then
      live=$(fleet_sockets)
      case "$live" in
        *$'\n'*|'') die "this login has several fleets ($(fleet_each_conf | cut -f1 | tr '\n' ' ')) and none hosts ${REPO:-the repo you named} — fold them into one (fleet-repo.sh fold <from> --into <fleet>), or pass --name <fleet>" ;;
        *) NAME="$live" ;;
      esac
    fi
  fi
fi

# Each fleet gets its OWN tmux server on a named socket (== the session name), so
# one fleet's crash / stray kill-server can't take down the others (issue #159).
# SOCK is that socket label; every tmux call below names it explicitly because
# fleet-up runs from a plain shell (no inherited $TMUX for THIS fleet's server).
SOCK=$(fleet_socket "$NAME")
# A socket left by a dying server drops every client — has-session and
# new-session below would both fail with `server exited unexpectedly` (issue
# #1729). Clear it first, and say so: this fleet's server just died.
fleet_socket_heal "$SOCK" >&2 || true
LIVE=0; tmux -L "$SOCK" has-session -t "$NAME" 2>/dev/null && LIVE=1

# Every repo is put one way (issue #1937): repos/<slug>.conf, the first one too.
# An old-layout conf still naming its first repo moves it there before anything
# else reads it (fleet_conf_repo_migrate — identity frozen first, both files kept
# as .bak), so the repo named here is either hosted already or added below,
# through the one implementation fleet-repo.sh add uses (fleet_repo_register).
migrate_conf_repo() {
  local out
  out=$(fleet_conf_repo_migrate "$NAME") \
    || die "could not move the repo out of $(fleet_conf_file "$NAME") into repos/ — nothing changed (rc $?)"
  [ -n "$out" ] && echo "fleet-up: $out — out of the fleet conf into repos/ (kept as .bak)"
  return 0
}
[ -f "$(fleet_conf_file "$NAME")" ] && migrate_conf_repo

ADD_REPO=""; ADD_DIR=""; ADD_BASE=""
if [ -n "$REPO" ]; then
  if fleet_repo_hosted "$NAME" "$REPO"; then
    echo "fleet-up: fleet '$NAME' already hosts $REPO"
    [ -n "$DIR" ] && [ "$DIR" != "$(fleet_repo_conf_get "$NAME" "$REPO" FLEET_MAIN)" ] \
      && echo "fleet-up: '$NAME' already hosts $REPO at $(fleet_repo_conf_get "$NAME" "$REPO" FLEET_MAIN) — keeping it (fleet-repo.sh remove + add to move it)"
  else
    ADD_REPO="$REPO"; ADD_DIR="$DIR"; ADD_BASE="$BASE"
  fi
fi
# --seed marks the login's starter (issue #1167): the fleet's only repo, never one
# added beside others.
if [ "$SEED" = 1 ]; then
  [ -n "$REPO" ] || die "--seed needs the starter's <owner/repo>"
  [ -z "$(fleet_repos "$NAME" | grep -vxF "$REPO")" ] \
    || die "--seed marks a fleet's only repo — '$NAME' already hosts $(fleet_repos "$NAME" | grep -vxF "$REPO" | tr '\n' ' ')so $REPO would only be added; drop --seed"
fi

# add_repo — the repo named here, when the fleet does not host it yet.
add_repo() {
  [ -n "$ADD_REPO" ] || return 0
  # fleet_repo_register (issue #1104): its token on stdout is for scripts — here
  # the human lines on stderr already say what happened.
  local seedarg=''; [ "$SEED" = 1 ] && seedarg=--seed
  fleet_repo_register "$NAME" "$ADD_REPO" ${ADD_DIR:+"$ADD_DIR"} ${ADD_BASE:+--base "$ADD_BASE"} \
      ${seedarg:+"$seedarg"} >/dev/null \
    || die "could not add $ADD_REPO to fleet '$NAME'"
  echo "fleet-up: added $ADD_REPO to fleet '$NAME'"
  ADD_REPO=""
}
# mark_seed — --seed on a repo the fleet already hosts (its only one): in its overlay.
mark_seed() {
  local f kv
  [ "$SEED" = 1 ] && [ -z "$ADD_REPO" ] || return 0
  f=$(fleet_repo_conf_file "$NAME" "$REPO")
  [ -f "$f" ] || return 0
  for kv in FLEET_SEED=1 FLEET_AUTOFILL=0 FLEET_ISSUE_BRIDGE=0; do
    fleet_conf_set "$f" "${kv%%=*}" "${kv#*=}" || die "failed to write ${kv%%=*} to $f"
  done
  echo "fleet-up: $REPO is this fleet's seed repo — no autofill, no issue-bridge (FLEET_SEED=1)"
}

if [ "$LIVE" = 1 ]; then
  echo "fleet-up: fleet '$NAME' is already up"
  mark_seed
else
# --- write the per-fleet conf ---
# PRESERVE any custom FLEET_* keys already in the conf (issue #170): a crash + `cf`
# restore re-runs fleet-up, and a truncating rewrite would silently drop the
# operator's FLEET_ISSUE_BRIDGE / FLEET_CLEANUP / FLEET_MAX_SESSIONS / … Only the
# header is refreshed — the conf holds the fleet's settings, no repo (#1937).
# Atomic write.
# One directory per fleet (issue #181): the conf lives at fleets/<sess>/conf. If an
# un-migrated legacy flat <sess>.conf exists, adopt it into the per-fleet dir FIRST
# so fleet_write_conf preserves its custom FLEET_* keys (issue #170) at the new path.
CONF="$(fleet_state_dir "$NAME")/conf"
legacy="$FLEET_CONF_DIR/$NAME.conf"
fleet_conf_reserved "$NAME" && legacy=''   # fleet.conf is the machine's, never fleet `fleet`'s (#1887)
# A fleet this login has never had (no conf, not even a legacy one): the one
# moment the onboarding guide may open (issue #1169, below).
NEWFLEET=0; [ ! -f "$CONF" ] && [ ! -f "$legacy" ] && NEWFLEET=1
if [ ! -f "$CONF" ] && [ -f "$legacy" ]; then
  { mv "$legacy" "$CONF" 2>/dev/null || cp "$legacy" "$CONF"; }
  migrate_conf_repo
  if [ -n "$ADD_REPO" ] && fleet_repo_hosted "$NAME" "$ADD_REPO"; then ADD_REPO=""; fi
fi
fleet_write_conf "$CONF" "$NAME" "" "" "" "$(date '+%Y-%m-%d %H:%M:%S')" \
  || die "failed to write $CONF"
echo "fleet-up: wrote $CONF"
# The repo goes in before the session exists, so the hub's first paint has it;
# register does the checkout (reuse or clone), the base branch (#603), the trust
# warning (#563), and wakes the daemons.
add_repo
mark_seed

# Where the hub opens: $HOME (or HUB_CWD), however many repos the fleet hosts —
# a fleet has no main checkout (#795, #1937, #1941).
HUB_DIR="${HUB_CWD:-$HOME}"

# --- create the session + the HUB ---
# 'work' is the plain work shell; the 'plan' hub (the dash, and ONLY the dash —
# a fresh fleet no longer comes up with a hub Claude session) is built by
# hub-session.sh, scoped to THIS fleet's session so F9 toggles this
# fleet's own hub.
# The server inherits THIS process's PATH for its whole life, and every window it
# spawns server-side (a bind, a hook) runs under it; the hub + guide spawned right
# below get it as this client's — so ~/.local/bin (Claude Code's native install)
# goes on it BEFORE the fork, or a login whose PATH lacked the dir never finds
# claude on a respawn (issue #1191, #1183; fleet_local_bin_path in fleet-lib.sh).
PATH=$(fleet_local_bin_path); PATH=$(fleet_path_fill); export PATH
# The server starts from conf/tmux-fleet-server.conf, never bare: the fleet layer
# loads first and the person's ~/.tmux.conf after it with -q, so an error in theirs
# no longer drops the reaper hooks and the rename guard (issue #1845).
workwin=$(fleet_server_new_session "$SOCK" -d -P -F '#{window_id}' -s "$NAME" -c "$HUB_DIR" -n work) \
  || die "tmux new-session failed for '$NAME'$(fleet_wedged_note)"
# A fresh server recycles pane ids: drop the last server's unrun mod commands
# before any pane exists to take them (issue #1538).
fleet_mod_inbox_reset "$SOCK"
# A session is on its way: wake the idle-gated daemons so the dash is fresh on
# their very next tick, not up to FLEET_DAEMON_IDLE_AFTER later (issue #1077).
[ -f "$BIN/fleet-daemon-lib.sh" ] && ( . "$BIN/fleet-daemon-lib.sh" && fleet_daemon_wake "$BIN/.." ) 2>/dev/null || true
# hub-session.sh builds the hub against this fleet's socket. It resolves the
# same SOCK from the session name, so it needs no explicit socket argument.
HUB_SESSION="$NAME" HUB_CWD="$HUB_DIR" bash "$BIN/hub-session.sh"
# The 'plan' hub is the whole fleet UI — retire the throwaway 'work' shell so the
# session starts with ONLY the hub (hub-session.sh already selected it). tmux
# needs an initial window to create the session; we drop it once the hub exists.
tmux -L "$SOCK" kill-window -t "$workwin" 2>/dev/null || true
# The fleet's one orchestrating session (issue #1957): opened beside home, in
# $HOME (FLEET_ORCHESTRATOR=0 turns it off); the tick's home_watch keeps it there.
bash "$BIN/fleet-orchestrator.sh" ensure "$NAME" >/dev/null 2>&1 || true

# --- first fleet on this login: open the guide, pinned (issue #1169) ---
# A newcomer does not know /fleet-onboard exists, so their first fleet comes up
# with it already running, pinned to the top of the session list. Only a fleet
# created just now asks — restoring or re-attaching an existing one never opens
# it here. The pending marker lets the collector retry ONLY a first fleet that
# tried to open a guide; old fleets without an onboarded marker are unaffected.
# «Stayed running» is not enough (issue #1215): onboarded is written only once the
# guide has SPOKEN — fleet-onboard.sh brief left global/guide.spoke — and is still
# up. A claude that only printed `Unknown command` is left for the collector,
# which confirms a late speaker or reopens a silent one (fleet_guide_tick).
ONBOARDED="$FLEET_CONF_DIR/global/onboarded"
if [ "$NEWFLEET" = 1 ] && [ "${FLEET_ONBOARD:-1}" != 0 ] && [ ! -e "$ONBOARDED" ]; then
  mkdir -p "${ONBOARDED%/*}"
  : > "$FLEET_CONF_DIR/global/onboard.pending"
  date +%s > "$FLEET_CONF_DIR/global/onboard.retry"
  if fleet_guide_open "$NAME" >/dev/null 2>&1 && fleet_guide_wait "$NAME" "${FLEET_GUIDE_WAIT_SECS:-30}"; then
    date '+%Y-%m-%d %H:%M:%S' > "$ONBOARDED"
    rm -f "$FLEET_CONF_DIR/global/onboard.pending"
    echo "fleet-up: opened the onboarding guide (/fleet-onboard), pinned to the top"
  else
    echo "fleet-up: onboarding guide has not spoken yet — collector will confirm it, or retry" >&2
  fi
fi

# --- populate caches now so the dash isn't empty on first paint ---
( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )

_rl=$(fleet_repos "$NAME" | tr '\n' ' '); _rl=${_rl% }
echo "fleet-up: fleet '$NAME' is up ($(fleet_repos "$NAME" | grep -c .) repo(s): ${_rl:-none — fleet-repo.sh add <owner/repo>})"
fi
# A server already running — an older fleet-up, or one a daemon started from its
# own PATH — gets ~/.local/bin stamped onto its global environment, so the next
# window it spawns server-side finds claude too (issue #1191). A no-op when there.
fleet_server_local_bin "$SOCK"
# ...and this login's TMPDIR, so a server a `sudo -u` half started reads the
# daemons' dash cache, not a shared /tmp one (issue #2442). A no-op when there.
fleet_server_tmpdir "$SOCK"
# The server outlives its last window (issue #1784): an exit that closes the last
# session must not take every view of this machine down with it.
fleet_server_resident "$SOCK" "$NAME"
rm -f "$FLEET_CONF_DIR/fleets/$NAME/restore.down" 2>/dev/null   # up again: --auto may restore it (#1784)

# --- a repo the fleet does not host yet (a fleet that was already up): add it ---
add_repo
# Whose fleet this is (issue #1099): the footer and the hub's border title draw
# the login name from the server-level @login, stamped once here instead of a
# `#(id -un)` fork every status-interval (#888). tmux's own #{user} would do it,
# but only from 3.3 — the conf falls back to it when @login is unset.
tmux -L "$SOCK" set -g @login "$(id -un)" 2>/dev/null || true
# The retired repo filter (issue #1034): the dash always shows `all`, so a
# `current-repo` file left by the old footer picker is dead state — drop it.
rm -f "$FLEET_CONF_DIR/fleets/$NAME/current-repo" 2>/dev/null

# --- land the caller on the new fleet ---
# Each fleet is its OWN tmux server now, so switch-client (same-server only) can't
# reach it. If we're already attached to ANOTHER fleet, detach this client and
# re-attach to the new socket in one motion (-E runs post-detach; tmux ≥ 3.2).
# Outside tmux, just attach the new socket.
# Already inside this fleet: nothing to switch.
_here=${TMUX:-}; _here=${_here%%,*}; _here=${_here##*/}
if [ "$NOATTACH" = 1 ]; then
  echo "fleet-up: not attaching (--no-attach) — later: fleet"
elif [ -n "${TMUX:-}" ] && [ "$_here" = "$SOCK" ]; then
  :
elif [ -n "${TMUX:-}" ]; then
  tmux detach-client -E "exec tmux -L '$SOCK' attach -t '$NAME'" 2>/dev/null \
    || echo "          attach:  tmux -L $SOCK attach -t $NAME"
else
  tmux -L "$SOCK" attach -t "$NAME" || echo "          attach:  tmux -L $SOCK attach -t $NAME"
fi
