#!/bin/bash
# fleet-up.sh [<owner/repo>] [<checkout-dir>] [--name <session>] [--base <branch>]
#
# Bring up a new FLEET: a tmux session pinned to one GitHub repo, with a local
# checkout (reused if it exists, cloned if it doesn't). With no <owner/repo>,
# infers it from the current checkout: run it from inside a git worktree and it
# uses that repo's 'origin' and that worktree as the checkout dir. Writes the per-fleet conf
# ($FLEET_CONF_DIR/<session>.conf) the rest of the tooling reads, builds the
# 'plan' hub (a dash+hub split — the embedded dash self-marks @dash=1 and is
# reached via prefix+g; there is no standalone 'dash' window), and kicks the
# collector so the dash has data immediately. See docs/ARCHITECTURE.md.
#
# A fleet ≡ a tmux session ≡ one repo. Run once per repo you want to work.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

die() { echo "fleet-up: $*" >&2; exit 1; }
usage() { echo "usage: fleet-up.sh [<owner/repo>] [<checkout-dir>] [--name <session>] [--base <branch>]" >&2; }
need_arg() { [ "$1" -ge 2 ] || { usage; die "$2 needs an argument"; }; }   # $1=$#, $2=flag

REPO=""; DIR=""; NAME=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) need_arg "$#" --name; NAME="$2"; shift 2;;
    --base) need_arg "$#" --base; BASE="$2"; shift 2;;
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
if [ -z "$REPO" ]; then
  top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) \
    || die "no <owner/repo> given and $PWD is not a git checkout"
  REPO=$(git -C "$top" remote get-url origin 2>/dev/null) \
    || die "$top has no 'origin' remote — pass <owner/repo> explicitly"
  DIR="${DIR:-$top}"
  echo "fleet-up: inferred $(fleet_norm_repo "$REPO") from $top"
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
# Standard session name: 'fleet-<repo-basename>' so every fleet groups together
# and its session visibly names its repo. --name overrides verbatim.
NAME="${NAME:-fleet-$(basename "$REPO")}"
NAME=$(printf '%s' "$NAME" | tr '.: ' '-')        # tmux session names: no . : space
DIR="${DIR:-$HOME/projects/$(basename "$REPO")}"

# Each fleet gets its OWN tmux server on a named socket (== the session name), so
# one fleet's crash / stray kill-server can't take down the others (issue #159).
# SOCK is that socket label; every tmux call below names it explicitly because
# fleet-up runs from a plain shell (no inherited $TMUX for THIS fleet's server).
SOCK=$(fleet_socket "$NAME")
tmux -L "$SOCK" has-session -t "$NAME" 2>/dev/null && die "a tmux session '$NAME' already exists (one fleet per repo)"

# --- checkout: reuse if it's already that repo, else clone ---
if [ -d "$DIR/.git" ]; then
  have=$(fleet_norm_repo "$(git -C "$DIR" remote get-url origin 2>/dev/null)")
  [ "$have" = "$REPO" ] || die "$DIR is a checkout of '$have', not '$REPO'"
  echo "fleet-up: reusing existing checkout $DIR"
elif [ -e "$DIR" ]; then
  die "$DIR exists but is not a git checkout"
else
  echo "fleet-up: cloning $REPO → $DIR"
  mkdir -p "$(dirname "$DIR")"
  if command -v gh >/dev/null 2>&1; then gh repo clone "$REPO" "$DIR" || die "clone failed";
  else git clone "https://github.com/$REPO.git" "$DIR" || die "clone failed"; fi
fi

# --- base branch: the repo's TRUNK, not "whatever branch we're standing on" ---
# Order + the full why: fleet_resolve_base_branch() in fleet-lib.sh (issue #603).
# Picking this wrong is the fleet's most expensive silent failure — every worker
# works perfectly onto a branch nobody ships from — so the ONLY answer we accept
# quietly is the repo's authoritative GitHub default. Everything else speaks up.
IFS=$'\t' read -r BASE BASE_SRC BASE_DEFAULT \
  < <(fleet_resolve_base_branch "$REPO" "$DIR" "$BASE")

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

# --- project trust (issue #563) ---
# Claude Code asks "trust this folder?" once per project root and a worktree
# resolves to its MAIN checkout — so an untrusted $DIR means every worker this
# fleet spawns parks on that dialog with nobody to answer it. The launcher
# pre-trusts at spawn, but a live install predating #563 (or FLEET_PRETRUST=0) does
# not: say it loudly here, at the one moment the operator is watching, with the fix.
if [ -f "$BIN/fleet-trust.sh" ]; then
  case "$(sh "$BIN/fleet-trust.sh" check "$DIR" 2>/dev/null)" in
    untrusted)
      echo "fleet-up: WARNING — $DIR is not trusted in $(sh "$BIN/fleet-trust.sh" file):" >&2
      echo "          workers spawned by a pre-#563 launcher hang at Claude Code's \"trust this folder?\" dialog." >&2
      echo "          fix now:  sh $BIN/fleet-trust.sh grant --main '$DIR'" >&2 ;;
  esac
fi

# --- create the session + the HUB ---
# 'work' is the plain work shell; the 'plan' hub (the dash, and ONLY the dash —
# a fresh fleet no longer comes up with a hub Claude session) is built by
# hub-session.sh, scoped to THIS fleet's session + checkout so F9 toggles this
# fleet's own hub.
workwin=$(tmux -L "$SOCK" new-session -d -P -F '#{window_id}' -s "$NAME" -c "$DIR" -n work) \
  || die "tmux new-session failed for '$NAME'"
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

# --- land the caller on the new fleet ---
# Each fleet is its OWN tmux server now, so switch-client (same-server only) can't
# reach it. If we're already attached to ANOTHER fleet, detach this client and
# re-attach to the new socket in one motion (-E runs post-detach; tmux ≥ 3.2).
# Outside tmux, just attach the new socket.
if [ -n "${TMUX:-}" ]; then
  tmux detach-client -E "exec tmux -L '$SOCK' attach -t '$NAME'" 2>/dev/null \
    || echo "          attach:  tmux -L $SOCK attach -t $NAME"
else
  tmux -L "$SOCK" attach -t "$NAME" || echo "          attach:  tmux -L $SOCK attach -t $NAME"
fi
