#!/bin/bash
# Prepare a build context from a signed release; tokens never enter the image.
# Usage: prepare-image.sh <hub>[ <hub>…] <release.pub> <40-character sha> <new-context-dir> [linux-amd64]
#
# <hub> is one hub URL, or several in one argument separated by spaces: asked in
# order, the next one when a fetch fails. Each answers the same signed release —
# ccquota verifies every byte against <release.pub>, so which hub carried it
# never matters — and a half-fetched artifact resumes on the next one
# (<context>/runtime.dl, by sha256).
#
# Bounded (issue: the train's `node image` sat 40 minutes on a hub serving
# 50 KB/s, silent): FLEET_IMAGE_FETCH_SECS=<n> gives up after n seconds in all,
# and a hub that carries less than FLEET_IMAGE_FETCH_FLOOR bytes/s (default
# 204800) for FLEET_IMAGE_FETCH_FLOOR_SECS (default 60) is dropped for the next
# one, naming its rate. train-build.sh sets them; unset (a build by hand on a
# slow link) = no bound beyond ccquota's own 30 s stall, as before. GNU
# `timeout`, when the machine has it, backs the bound up. A ccquota that knows
# `--progress` prints a line per artifact and every 5 s.
#
# The context must hold every artifact image-stage.py's `stage` takes — each
# tool and its helpers (#3017: codex-code-mode-host). `need` is that one list;
# it is checked here, so a context that would fail inside `docker build` fails
# now. A ccquota older than #3017 drops helpers from `--pinned`
# (issue #3554): then the release is fetched again whole and checked again.
# CCQUOTA names the ccquota to run (default: the one on PATH).
#
# Then, on any machine (Apple Silicon included — the classic builder takes a
# cached arm64 base for --platform linux/amd64, which Rosetta cannot run):
#   docker buildx build --platform linux/amd64 --load -t <image>:<sha> <context-dir>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HUB=${1:-} KEY=${2:-} SHA=${3:-} DEST=${4:-} PLATFORM=${5:-linux-amd64}
HUBS=''
for h in $HUB; do
  h=${h%/}
  case "$h" in http://*|https://*) ;; *) HUBS=''; break ;; esac
  case " $HUBS " in *" $h "*) ;; *) HUBS="$HUBS${HUBS:+ }$h" ;; esac
done
if [ -z "$HUBS" ] || [ ! -f "$KEY" ] || [ -z "$DEST" ] || [ -e "$DEST" ] \
    || ! printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo 'usage: prepare-image.sh <hub>[ <hub>…] <release.pub> <sha> <new-context-dir> [linux-amd64]' >&2
  exit 2
fi
case "$PLATFORM" in
  linux-amd64|linux-arm64) ARCH=${PLATFORM#linux-} ;;
  *) echo "prepare-image.sh: the image is linux-amd64 or linux-arm64, not $PLATFORM" >&2; exit 2 ;;
esac
CCQ=${CCQUOTA:-ccquota}
FETCH_SECS=${FLEET_IMAGE_FETCH_SECS:-}
FLOOR=${FLEET_IMAGE_FETCH_FLOOR:-204800}
FLOOR_SECS=${FLEET_IMAGE_FETCH_FLOOR_SECS:-60}
TICK=${FLEET_IMAGE_FETCH_TICK:-5}
DEADLINE=''
[ -z "$FETCH_SECS" ] || DEADLINE=$(( $(date +%s) + FETCH_SECS ))
TO=''; [ -z "$DEADLINE" ] || TO=$(command -v timeout || command -v gtimeout || true)
PROGRESS=()
"$CCQ" release fetch -h 2>&1 </dev/null | grep -q -- '-progress' && PROGRESS=(--progress -)

say() { printf 'prepare-image.sh: %s\n' "$*" >&2; }
fail() {   # the one red line; on GitHub's runner an annotation naming the hub and its rate
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::error::prepare-image.sh: %s\n' "$*" >&2; else say "$*"; fi
}
mbps() {   # mbps <bytes> <seconds>
  awk -v b="$1" -v s="$2" 'BEGIN { if (s < 1) s = 1; r = b / s
    if (r >= 1048576) printf "%.2f MB/s", r / 1048576; else printf "%.0f KB/s", r / 1024 }'
}
bytes() { du -sk "$1" 2>/dev/null | awk '{ print $1 * 1024; f = 1 } END { if (!f) print 0 }'; }

# attempt <hub> <dest> <ccquota release fetch flags…>: one hub, watched — the
# bytes landing in <dest>.dl every FLOOR_SECS, and the deadline. WHY says how it ended.
attempt() {
  local hub=$1 dest=$2 pid rc t0 now b ws_t='' ws_b=0 log
  shift 2
  WHY=''
  log="$dest.log"; : > "$log"
  local to=(); [ -z "$TO" ] || to=("$TO" -k 10 $(( DEADLINE - $(date +%s) + 15 )))
  t0=$(date +%s)
  ${to[@]+"${to[@]}"} "$CCQ" release fetch --hub "$hub" --pubkey "$KEY" "$@" ${PROGRESS[@]+"${PROGRESS[@]}"} \
    "$SHA" "$dest" > >(tee -a "$log" >&2) 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$TICK"
    kill -0 "$pid" 2>/dev/null || break
    [ -n "$DEADLINE" ] || continue
    now=$(date +%s)
    if [ "$now" -ge "$DEADLINE" ]; then
      b=$(bytes "$dest.dl")
      WHY="still fetching at the ${FETCH_SECS}s bound ($(mbps "$((b - ws_b))" "$((now - ${ws_t:-$t0}))") over the last $((now - ${ws_t:-$t0}))s)"
      kill "$pid" 2>/dev/null; break
    fi
    [ -d "$dest.dl" ] || continue          # manifest + tree: in memory, under the deadline only
    b=$(bytes "$dest.dl")
    if [ -z "$ws_t" ]; then ws_t=$now ws_b=$b; continue; fi
    if [ $((b - ws_b)) -ge $((FLOOR * FLOOR_SECS)) ]; then ws_t=$now ws_b=$b; continue; fi
    if [ $((now - ws_t)) -ge "$FLOOR_SECS" ]; then
      WHY="too slow: $(mbps "$((b - ws_b))" "$((now - ws_t))") for $((now - ws_t))s, under the floor of $(mbps "$FLOOR" 1)"
      kill "$pid" 2>/dev/null; break
    fi
  done
  wait "$pid"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$WHY" ]; then
    say "release $SHA from $hub in $(( $(date +%s) - t0 ))s"
    return 0
  fi
  [ -n "$WHY" ] || WHY="ccquota exit $rc: $(grep -v '^ ' "$log" | tail -n 1)"
  [ "$rc" != 124 ] || WHY="timed out at the ${FETCH_SECS}s bound"
  return 1
}

# fetch <dest> <flags…>: every hub in turn until one delivers
fetch() {
  local dest=$1 hub tried=''
  shift
  for hub in $HUBS; do
    if [ -n "$DEADLINE" ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
      tried="$tried${tried:+; }$hub: not asked — the ${FETCH_SECS}s bound was spent"; continue
    fi
    rm -rf "$dest" "$dest.partial"     # what a stopped try left; $dest.dl stays (resumed)
    attempt "$hub" "$dest" "$@" && { rm -f "$dest.log"; return 0; }
    say "$hub: $WHY"
    tried="$tried${tried:+; }$hub: $WHY"
  done
  rm -f "$dest.log"
  fail "no hub delivered release $SHA — $tried"
  return 1
}

# missing <runtime-dir>: the artifacts stage wants that the context lacks
missing() {
  local n
  python3 -I "$HERE/image-stage.py" need "$1" "$ARCH" | while IFS= read -r n; do
    [ -f "$1/.release/artifacts/$n" ] || printf '%s\n' "$n"
  done
}

mkdir -m 700 "$DEST" || exit 1
fetch "$DEST/runtime" --artifacts --pinned --platform "$PLATFORM" || exit 1
lack=$(missing "$DEST/runtime") || exit 1
if [ -n "$lack" ]; then
  printf 'prepare-image.sh: %s --pinned left out: %s — fetching the whole release instead\n' \
    "$("$CCQ" version 2>/dev/null | head -n 1)" "$(printf '%s' "$lack" | tr '\n' ' ')" >&2
  rm -rf "$DEST/runtime" || exit 1
  fetch "$DEST/runtime" --artifacts || exit 1
  lack=$(missing "$DEST/runtime") || exit 1
  if [ -n "$lack" ]; then
    printf 'prepare-image.sh: release %s carries no %s — the image cannot be built from it\n' \
      "$SHA" "$(printf '%s' "$lack" | tr '\n' ' ')" >&2
    exit 1
  fi
  # only what the image takes stays: the other platforms' artifacts go
  keep=$(python3 -I "$HERE/image-stage.py" need "$DEST/runtime" "$ARCH")
  for f in "$DEST/runtime/.release/artifacts"/*; do
    [ -e "$f" ] || continue
    printf '%s\n' "$keep" | grep -qxF "$(basename "$f")" || rm -f "$f"
  done
fi
rm -rf "$DEST/runtime.dl" "$DEST/runtime.partial"   # a resumed try's leftovers never enter the context
cp "$KEY" "$DEST/release.pub" || exit 1
cp "$HERE/Dockerfile" "$HERE/image-stage.py" "$DEST/" || exit 1
cp -R "$HERE/devnet" "$DEST/devnet" || exit 1
echo "Verified build context: $DEST ($PLATFORM, $SHA)"
echo "Build: docker buildx build --platform linux/$ARCH --load -t <image>:$SHA $DEST"
