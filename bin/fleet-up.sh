#!/bin/bash
# fleet-up.sh [<owner/repo>] [<checkout-dir>] [--name <session>] [--base <branch>] [--seed]
#
# ONE FLEET PER LOGIN (issue #979). A login runs exactly one fleet holding all its
# repos, so this brings up THE fleet — or, when the login already has one, adds the
# repo to it (fleet-repo.sh add), then lands you on it. Creating a SECOND fleet is refused: a second fleet
# means a second login. A brand-new fleet is named "fleet"; an existing fleet keeps
# its name (fleet-claude-fleet stays fleet-claude-fleet).
#
# Bringing a fleet up: a tmux session with its first repo's local checkout (reused
# if it exists, cloned if it doesn't). With no <owner/repo>,
# infers it from the current checkout: run it from inside a git worktree and it
# uses that repo's 'origin' and that worktree as the checkout dir. Writes the per-fleet conf
# ($FLEET_CONF_DIR/<session>.conf) the rest of the tooling reads, builds the
# 'plan' hub (a dash+hub split — the embedded dash self-marks @dash=1 and is
# reached via prefix+g; there is no standalone 'dash' window), and kicks the
# collector so the dash has data immediately. See docs/ARCHITECTURE.md.
#
# A fleet ≡ a tmux session ≡ one login. Run it for every repo you want to work:
# the first brings the fleet up, each further one adds its repo.
#
# --seed (issue #1167): this repo is only the login's STARTER — the fleet comes up
# on it so it works at once, but it never takes work: the conf also gets
# FLEET_SEED=1 + FLEET_AUTOFILL=0 + FLEET_ISSUE_BRIDGE=0, so the dispatcher never
# auto-spawns from its backlog and the issue-bridge never relays its comments (see
# fleet_repo_is_seed). It marks the fleet conf's OWN repo only — a --seed for a repo
# the fleet would merely ADD is refused. Without --seed the conf is byte-identical.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

die() { echo "fleet-up: $*" >&2; exit 1; }
usage() { echo "usage: fleet-up.sh [<owner/repo>] [<checkout-dir>] [--name <session>] [--base <branch>] [--seed]" >&2; }
need_arg() { [ "$1" -ge 2 ] || { usage; die "$2 needs an argument"; }; }   # $1=$#, $2=flag

REPO=""; DIR=""; NAME=""; BASE=""; FROM_CONF=0; SEED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) need_arg "$#" --name; NAME="$2"; shift 2;;
    --base) need_arg "$#" --base; BASE="$2"; shift 2;;
    --seed) SEED=1; shift;;
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
# Outside any checkout, `cf` still means "take me to my fleet" (issue #979): with
# the login's fleet configured, bring THAT fleet up on its own repo.
if [ -z "$REPO" ]; then
  if top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
    REPO=$(git -C "$top" remote get-url origin 2>/dev/null) \
      || die "$top has no 'origin' remote — pass <owner/repo> explicitly"
    DIR="${DIR:-$top}"
    echo "fleet-up: inferred $(fleet_norm_repo "$REPO") from $top"
  elif lf=$(fleet_login_fleet) && [ -n "$lf" ]; then
    REPO=$( . "$(fleet_conf_file "$lf")" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$REPO" ] || die "fleet '$lf' has no FLEET_REPO in $(fleet_conf_file "$lf")"
    NAME="${NAME:-$lf}"; FROM_CONF=1
  else
    die "no <owner/repo> given and $PWD is not a git checkout"
  fi
fi

REPO=$(fleet_norm_repo "$REPO")
# Shape-check owner/repo before it reaches `gh repo clone`/`git clone`: exactly
# one slash, both halves non-empty, and only chars GitHub allows (no spaces or
# shell metacharacters). Catches typos and non-GitHub URLs up front.
case "$REPO" in
  *[!A-Za-z0-9_./-]* | */*/* | /* | */) die "invalid repo '$REPO' — expected owner/repo";;
  ?*/?*) : ;;
  *) die "invalid repo '$REPO' — expected owner/repo";;
esac
DIR_ARG="$DIR"
DIR="${DIR:-$HOME/projects/$(basename "$REPO")}"

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
    die "refusing a second fleet '$NAME' — this login already has '${LOGIN% }'. One fleet per login: \`fleet-up $REPO\` adds the repo to it; a second fleet needs a second login."
  fi
else
  NAME=$(fleet_login_fleet); lrc=$?
  if [ "$lrc" -eq 1 ]; then
    NAME=fleet
  elif [ "$lrc" -eq 2 ]; then
    NAME=""
    while IFS=$'\t' read -r s _; do
      [ -n "$s" ] && fleet_repo_hosted "$s" "$REPO" && { NAME="$s"; break; }
    done < <(fleet_each_conf)
    if [ -z "$NAME" ]; then
      live=$(fleet_sockets)
      case "$live" in
        *$'\n'*|'') die "this login has several fleets ($(fleet_each_conf | cut -f1 | tr '\n' ' ')) and none hosts $REPO — fold them into one (fleet-repo.sh fold <from> --into <fleet>), or pass --name <fleet>" ;;
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
LIVE=0; tmux -L "$SOCK" has-session -t "$NAME" 2>/dev/null && LIVE=1

# The fleet already exists (configured) and this is not its conf's own repo: bring
# the fleet up on its OWN repo (when it is down), then add this one. The fleet
# conf's FLEET_REPO/MAIN/BASE_BRANCH stay the fleet's — rewriting them to the new
# repo would re-home every window it already has.
ADD_REPO=""; ADD_DIR=""; ADD_BASE=""; KEEP_BASE=0
CONF_R=$(fleet_conf_file "$NAME")
if [ -f "$CONF_R" ]; then
  own_repo=$(fleet_norm_repo "$( . "$CONF_R" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )")
  own_main=$( . "$CONF_R" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
  own_base=$( . "$CONF_R" >/dev/null 2>&1; printf '%s' "${FLEET_BASE_BRANCH:-}" )
  if [ -n "$own_repo" ] && [ "$own_repo" != "$REPO" ]; then
    ADD_REPO="$REPO"; ADD_DIR="$DIR_ARG"; ADD_BASE="$BASE"
    REPO="$own_repo"; DIR="${own_main:-$HOME/projects/$(basename "$own_repo")}"
    BASE="${own_base:-}"; [ -n "$BASE" ] && KEEP_BASE=1
  elif [ -z "$DIR_ARG" ] && [ -n "${own_main:-}" ]; then
    DIR="$own_main"                                # its own repo: its own checkout
    # Named by nothing but the conf (cf from outside a checkout): keep its base too.
    if [ "$FROM_CONF" = 1 ] && [ -z "$BASE" ] && [ -n "${own_base:-}" ]; then
      BASE="$own_base"; KEEP_BASE=1
    fi
  fi
fi
# --seed marks the fleet conf's own repo, never one it would add (issue #1167).
[ "$SEED" = 1 ] && [ -n "$ADD_REPO" ] \
  && die "--seed marks a fleet's OWN repo — '$NAME' is on $REPO, so $ADD_REPO would only be added; drop --seed"

# The seed repo only looks (issue #1167): mark it in the conf the moment the conf
# exists — before the hub, so no daemon tick ever reads it unmarked.
seed_conf() {
  local conf kv; conf="$(fleet_state_dir "$NAME")/conf"
  for kv in FLEET_SEED=1 FLEET_AUTOFILL=0 FLEET_ISSUE_BRIDGE=0; do
    fleet_conf_set "$conf" "${kv%%=*}" "${kv#*=}" || die "failed to write ${kv%%=*} to $conf"
  done
  echo "fleet-up: $REPO is this fleet's seed repo — no autofill, no issue-bridge (FLEET_SEED=1)"
}

if [ "$LIVE" = 1 ]; then
  echo "fleet-up: fleet '$NAME' is already up"
  [ "$SEED" = 1 ] && seed_conf
else
# --- checkout: reuse if it's already that repo, else clone ---
# The one clone-or-reuse, shared with fleet-repo.sh add (fleet-lib.sh, issue #1104).
fleet_repo_checkout "$REPO" "$DIR" fleet-up || exit 1

# --- base branch: the repo's TRUNK, not "whatever branch we're standing on" ---
# Order + the full why: fleet_resolve_base_branch() in fleet-lib.sh (issue #603).
# Picking this wrong is the fleet's most expensive silent failure — every worker
# works perfectly onto a branch nobody ships from — so the ONLY answer we accept
# quietly is the repo's authoritative GitHub default. Everything else speaks up.
# Bringing an existing fleet up only to add ANOTHER repo: its conf already names
# its base — use it as is, never re-resolve (or prompt) about a repo you didn't name.
if [ "$KEEP_BASE" = 1 ]; then
  BASE_SRC=default; BASE_DEFAULT="$BASE"
else
  IFS=$'\t' read -r BASE BASE_SRC BASE_DEFAULT \
    < <(fleet_resolve_base_branch "$REPO" "$DIR" "$BASE")
fi

case "$BASE_SRC" in
  default) : ;;   # authoritative — nothing to say
  flag)
    # An explicit --base that disagrees with the repo's default is either a
    # deliberate choice or the bug. We cannot tell them apart, so make the
    # operator own it out loud. fleet-restore.sh re-runs us with --base taken
    # from the existing conf, so a base that was wrong ONCE arrives here on
    # every restore — this is where it finally gets said.
    if [ -n "$BASE_DEFAULT" ] && [ "$BASE" != "$BASE_DEFAULT" ]; then
      echo "fleet-up: WARNING — --base '$BASE' is NOT $REPO's default branch ('$BASE_DEFAULT')." >&2
      echo "          Every worker in this fleet will branch from and open PRs against '$BASE'." >&2
      echo "          If that is not your trunk, the whole fleet's work lands where nobody ships from." >&2
      # Prompt only with a human on both ends: fleet-restore.sh runs us with
      # stdout in a log file, and a prompt there would hang the restore forever.
      if [ -t 0 ] && [ -t 1 ]; then
        printf '          use base branch '"'"'%s'"'"' anyway? [y/N] ' "$BASE" >&2
        read -r ans
        case "$ans" in
          [yY]|[yY][eE][sS]) ;;
          *) die "aborted — re-run with --base '$BASE_DEFAULT' (or no --base at all)";;
        esac
      else
        echo "          (not a tty — proceeding; check it with: fleet-doctor.sh)" >&2
      fi
    fi ;;
  *)
    # gh could not tell us the default branch, so whatever we picked is a guess.
    echo "fleet-up: WARNING — could not read $REPO's default branch from GitHub (gh missing, unauthed, or offline)." >&2
    echo "          falling back to '$BASE' (source: $BASE_SRC) — VERIFY it is this repo's trunk." >&2
    echo "          if it is not:  fleet-up.sh ... --base <trunk>   (or fix the conf and re-run fleet-doctor.sh)" >&2 ;;
esac

# --- write the per-fleet conf ---
# PRESERVE any custom FLEET_* keys already in the conf (issue #170): a crash + `cf`
# restore re-runs fleet-up, and a truncating rewrite would silently drop the
# operator's FLEET_ISSUE_BRIDGE / FLEET_CLEANUP / FLEET_MAX_SESSIONS / … Only the
# derived three (repo/main/base) are refreshed; the rest survive. Atomic write.
# One directory per fleet (issue #181): the conf lives at fleets/<sess>/conf. If an
# un-migrated legacy flat <sess>.conf exists, adopt it into the per-fleet dir FIRST
# so fleet_write_conf preserves its custom FLEET_* keys (issue #170) at the new path.
CONF="$(fleet_state_dir "$NAME")/conf"
legacy="$FLEET_CONF_DIR/$NAME.conf"
[ ! -f "$CONF" ] && [ -f "$legacy" ] && { mv "$legacy" "$CONF" 2>/dev/null || cp "$legacy" "$CONF"; }
fleet_write_conf "$CONF" "$NAME" "$REPO" "$DIR" "$BASE" "$(date '+%Y-%m-%d %H:%M:%S')" \
  || die "failed to write $CONF"
echo "fleet-up: wrote $CONF"
[ "$SEED" = 1 ] && seed_conf

# --- project trust (issue #563) ---
# Claude Code asks "trust this folder?" once per project root and a worktree
# resolves to its MAIN checkout — so an untrusted $DIR means every worker this
# fleet spawns parks on that dialog with nobody to answer it. The launcher
# pre-trusts at spawn, but a live install predating #563 (or FLEET_PRETRUST=0) does
# not: say it loudly here, at the one moment the operator is watching, with the fix.
# Shared with every repo added later (fleet_repo_trust_warn, issue #1104).
fleet_repo_trust_warn "$DIR" fleet-up

# --- create the session + the HUB ---
# 'work' is the plain work shell; the 'plan' hub (the dash, and ONLY the dash —
# a fresh fleet no longer comes up with a hub Claude session) is built by
# hub-session.sh, scoped to THIS fleet's session + checkout so F9 toggles this
# fleet's own hub.
workwin=$(tmux -L "$SOCK" new-session -d -P -F '#{window_id}' -s "$NAME" -c "$DIR" -n work) \
  || die "tmux new-session failed for '$NAME'"
# A session is on its way: wake the idle-gated daemons so the dash is fresh on
# their very next tick, not up to FLEET_DAEMON_IDLE_AFTER later (issue #1077).
[ -f "$BIN/fleet-daemon-lib.sh" ] && ( . "$BIN/fleet-daemon-lib.sh" && fleet_daemon_wake "$BIN/.." ) 2>/dev/null || true
# hub-session.sh builds the hub against this fleet's socket. It resolves the
# same SOCK from the session name, so it needs no explicit socket argument.
HUB_SESSION="$NAME" HUB_CWD="$DIR" bash "$BIN/hub-session.sh"
# The 'plan' hub is the whole fleet UI — retire the throwaway 'work' shell so the
# session starts with ONLY the hub (hub-session.sh already selected it). tmux
# needs an initial window to create the session; we drop it once the hub exists.
tmux -L "$SOCK" kill-window -t "$workwin" 2>/dev/null || true

# --- populate caches now so the dash isn't empty on first paint ---
( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )

echo "fleet-up: fleet '$NAME' is up (repo=$REPO base=$BASE [$BASE_SRC])"
fi

# --- a repo the fleet does not host yet: add it ---
if [ -n "$ADD_REPO" ]; then
  if fleet_repo_hosted "$NAME" "$ADD_REPO"; then
    echo "fleet-up: fleet '$NAME' already hosts $ADD_REPO"
  else
    # fleet_repo_register (issue #1104): its token on stdout is for scripts — here
    # the human lines on stderr already say what happened.
    fleet_repo_register "$NAME" "$ADD_REPO" ${ADD_DIR:+"$ADD_DIR"} ${ADD_BASE:+--base "$ADD_BASE"} >/dev/null \
      || die "could not add $ADD_REPO to fleet '$NAME'"
    echo "fleet-up: added $ADD_REPO to fleet '$NAME'"
  fi
fi
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
if [ -n "${TMUX:-}" ] && [ "$_here" = "$SOCK" ]; then
  :
elif [ -n "${TMUX:-}" ]; then
  tmux detach-client -E "exec tmux -L '$SOCK' attach -t '$NAME'" 2>/dev/null \
    || echo "          attach:  tmux -L $SOCK attach -t $NAME"
else
  tmux -L "$SOCK" attach -t "$NAME" || echo "          attach:  tmux -L $SOCK attach -t $NAME"
fi
