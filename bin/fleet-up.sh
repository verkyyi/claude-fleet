#!/bin/bash
# fleet-up.sh [<owner/repo>] [<checkout-dir>] [--name <session>] [--base <branch>]
#
# Bring up a new FLEET: a tmux session pinned to one GitHub repo, with a local
# checkout (reused if it exists, cloned if it doesn't). With no <owner/repo>,
# infers it from the current checkout: run it from inside a git worktree and it
# uses that repo's 'origin' and that worktree as the checkout dir. Writes the per-fleet conf
# ($FLEET_CONF_DIR/<session>.conf) the rest of the tooling reads, builds the
# 'plan' hub (a dash+steward split — the embedded dash self-marks @dash=1 and is
# reached via prefix+G; there is no standalone 'dash' window), and kicks the
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

tmux has-session -t "$NAME" 2>/dev/null && die "a tmux session '$NAME' already exists (one fleet per repo)"

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

# --- base branch: flag > gh default > origin/HEAD > main ---
if [ -z "$BASE" ] && command -v gh >/dev/null 2>&1; then
  BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
fi
[ -z "$BASE" ] && BASE=$(git -C "$DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -z "$BASE" ] && BASE=main

# --- write the per-fleet conf ---
# PRESERVE any custom FLEET_* keys already in the conf (issue #170): a crash + `cf`
# restore re-runs fleet-up, and a truncating rewrite would silently drop the
# operator's FLEET_ISSUE_BRIDGE / FLEET_SELF_LAND / FLEET_AUTOFILL / … Only the
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

# --- create the session + the steward HUB ---
# 'work' is the plain work shell; the 'plan' hub (dash on top + a persistent
# steward Claude session below) is built by steward-session.sh, scoped to THIS
# fleet's session + checkout so prefix+g toggles this fleet's own steward.
workwin=$(tmux new-session -d -P -F '#{window_id}' -s "$NAME" -c "$DIR" -n work) \
  || die "tmux new-session failed for '$NAME'"
STEWARD_SESSION="$NAME" STEWARD_CWD="$DIR" bash "$BIN/steward-session.sh"
# The 'plan' hub is the whole fleet UI — retire the throwaway 'work' shell so the
# session starts with ONLY the hub (steward-session.sh already selected it). tmux
# needs an initial window to create the session; we drop it once the hub exists.
tmux kill-window -t "$workwin" 2>/dev/null || true

# --- populate caches now so the dash isn't empty on first paint ---
( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )

echo "fleet-up: fleet '$NAME' is up (repo=$REPO base=$BASE)"

# --- land the caller on the new fleet: switch if already in tmux, else attach ---
if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$NAME" || echo "          attach:  tmux switch-client -t $NAME"
else
  tmux attach -t "$NAME" || echo "          attach:  tmux attach -t $NAME"
fi
