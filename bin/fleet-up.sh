#!/bin/bash
# fleet-up.sh <owner/repo> [<checkout-dir>] [--name <session>] [--base <branch>]
#
# Bring up a new FLEET: a tmux session pinned to one GitHub repo, with a local
# checkout (reused if it exists, cloned if it doesn't). Writes the per-fleet conf
# ($FLEET_CONF_DIR/<session>.conf) the rest of the tooling reads, opens the
# standard windows (work shell + dash), and kicks the collector so the dash has
# data immediately. See docs/ARCHITECTURE.md.
#
# A fleet ≡ a tmux session ≡ one repo. Run once per repo you want to work.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

die() { echo "fleet-up: $*" >&2; exit 1; }

REPO=""; DIR=""; NAME=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    -*) die "unknown flag $1";;
    *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$DIR" ]; then DIR="$1"; else die "extra arg $1"; fi; shift;;
  esac
done
[ -n "$REPO" ] || die "usage: fleet-up.sh <owner/repo> [<dir>] [--name <session>] [--base <branch>]"
command -v tmux >/dev/null 2>&1 || die "tmux not found"
command -v git  >/dev/null 2>&1 || die "git not found"

REPO=$(fleet_norm_repo "$REPO")
NAME="${NAME:-$(basename "$REPO")}"
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
mkdir -p "$FLEET_CONF_DIR"
CONF="$FLEET_CONF_DIR/$NAME.conf"
cat > "$CONF" <<EOF
# claude-fleet: fleet '$NAME' — written by fleet-up.sh $(date '+%Y-%m-%d %H:%M:%S')
# Overlays the global fleet.conf for this fleet's tmux session. Add any other
# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.
FLEET_REPO="$REPO"
FLEET_MAIN="$DIR"
FLEET_BASE_BRANCH="$BASE"
EOF
echo "fleet-up: wrote $CONF"

# --- create the session + standard windows ---
tmux new-session -d -s "$NAME" -c "$DIR" -n work || die "tmux new-session failed for '$NAME'"
tmux new-window  -t "$NAME:" -c "$DIR" -n dash "bash '$BIN/tmux-dashboard.sh'"
if [ -n "${FLEET_STEWARD_CMD:-}" ]; then
  tmux new-window -t "$NAME:" -c "$DIR" -n steward "$FLEET_STEWARD_CMD"
fi
tmux select-window -t "$NAME:work"

# --- populate caches now so the dash isn't empty on first paint ---
( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )

echo "fleet-up: fleet '$NAME' is up (repo=$REPO base=$BASE)"
echo "          attach:  tmux attach -t $NAME"
