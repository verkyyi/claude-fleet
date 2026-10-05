#!/bin/sh
# fleet-hub-image.sh [--dir <checkout>] [--remote <name>] [--branch <trunk>]
#                    [--hub <url>] [--timeout <s>]
#   — which commit the hub (入口) image was built from, and how far it is from
#   `refs/tags/stable` (issue #1696).
#
# The hub image is deployed by hand (docs/FLEET-HUB.md), and the only place its
# commit was written down was the image TAG (`prod-<sha>`), readable only with
# cluster access — so "is the hub serving the client stable says it should?"
# had no answer without kubectl, and #1692 guessed it wrong. The hub now serves
# its build stamp on GET /version (public, like /healthz); this reads it and
# compares the commit with the stable tag, the same way `fleet-stable.sh show`
# compares stable with trunk: `git ls-remote` for the tag, `rev-list --count`.
#
# The hub URL: --hub, else CCQUOTA_HUB_URL / FLEET_HUB_URL, else the last such
# line of $FLEET_CONF_DIR/fleet.conf, else hub.json's `url`. No credential is
# read or sent.
#
# Prints line-anchored `key: value` lines (fleet-doctor parses them):
#   hub:     <url>|none          image:   <version stamp>|?
#   commit:  <sha>|?             stable:  <sha>|none|?
#   behind:  <n>|?               ahead:   <n>|?
#   verdict: CURRENT|BEHIND|AHEAD|DIVERGED|NOHUB|UNREACHABLE|UNSTAMPED|UNKNOWN
#   note:    <why, for anything but CURRENT>
#   BEHIND   the image lacks N commits stable has (the hub serves an older client)
#   AHEAD    the image is newer than stable (deployed from trunk) — not a fault
#   UNSTAMPED the hub answers but names no commit: built before #1696 (no
#            /version) or without a sha in VERSION (`docker`, `dev`)
#   UNKNOWN  the commits could not be compared (tag unreadable, commit not on
#            the remote's trunk) — unknown, NEVER 0
#
# Exit: 0 verdict printed (any) · 1 NOHUB · 2 usage
set -u

BIN_DIR=$(cd "$(dirname "$0")" && pwd)
dir="$(cd "$BIN_DIR/.." && pwd)"
remote=origin branch=master hub="" timeout=5
TAG=stable

die() { printf 'fleet-hub-image: %s\n' "$*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)     shift; dir="${1:-}" ;;
    --remote)  shift; remote="${1:-}" ;;
    --branch)  shift; branch="${1:-}" ;;
    --hub)     shift; hub="${1:-}" ;;
    --timeout) shift; timeout="${1:-5}" ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown argument $1" ;;
  esac
  shift
done
case "$timeout" in ''|*[!0-9]*|0) timeout=5 ;; esac

conf_dir="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
hub_url() {
  u="${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}"
  if [ -z "$u" ] && [ -f "$conf_dir/fleet.conf" ]; then
    u=$(grep -E '^[[:space:]]*(export[[:space:]]+)?(CCQUOTA_HUB_URL|FLEET_HUB_URL)=' "$conf_dir/fleet.conf" \
        | ( unset CCQUOTA_HUB_URL FLEET_HUB_URL
            while IFS= read -r l; do eval "$l" >/dev/null 2>&1; done
            printf '%s' "${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}" ))
  fi
  if [ -z "$u" ] && [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" ]; then
    u=$(sed -n 's/.*"url" *: *"\([^"]*\)".*/\1/p' "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" | head -n1)
  fi
  printf '%s' "${u%/}"
}

out() { printf '%-8s %s\n' "$1:" "$2"; }

[ -n "$hub" ] || hub=$(hub_url)
hub="${hub%/}"
if [ -z "$hub" ]; then
  out hub none; out verdict NOHUB; out note "no hub URL (FLEET_HUB_URL / CCQUOTA_HUB_URL / hub.json) — nothing to compare"
  exit 1
fi
out hub "$hub"

body=$(curl -fsS --max-time "$timeout" "$hub/version" 2>/dev/null) || body=""
image=$(printf '%s' "$body" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' | head -n1)
commit=$(printf '%s' "$body" | sed -n 's/.*"commit" *: *"\([0-9a-f]*\)".*/\1/p' | head -n1)
if [ -z "$image" ]; then
  # Did the hub answer at all? An image built before #1696 has no /version.
  if curl -fsS --max-time "$timeout" -o /dev/null "$hub/healthz" 2>/dev/null; then
    out image '?'; out commit '?'; out verdict UNSTAMPED
    out note "the hub has no /version — its image predates #1696; redeploy it to see its commit"
  else
    out image '?'; out commit '?'; out verdict UNREACHABLE
    out note "could not reach $hub/version — the image's commit is unknown, NOT current"
  fi
  exit 0
fi
out image "$image"
if [ -z "$commit" ]; then
  out commit '?'; out verdict UNSTAMPED
  out note "the image's stamp ($image) names no commit — build it with VERSION=prod-\$(git rev-parse --short HEAD)"
  exit 0
fi
out commit "$commit"

unknown() { out behind '?'; out verdict UNKNOWN; out note "$1 — distance unknown, NOT 0"; exit 0; }
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { out stable '?'; unknown "$dir is not a git checkout"; }
g() { git -C "$dir" -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=15" "$@"; }

ls=$(g ls-remote "$remote" "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null) || { out stable '?'; unknown "could not read refs/tags/$TAG from $remote"; }
st=$(printf '%s\n' "$ls" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')
[ -n "$st" ] || st=$(printf '%s\n' "$ls" | awk 'NF {print $1; exit}')
if [ -z "$st" ]; then
  out stable none; out behind '?'; out verdict UNKNOWN
  out note "no refs/tags/$TAG on $remote — nothing to compare the image with"
  exit 0
fi

# Both commits must be local: fetch trunk once (stable and every deployed image
# come from it), then the tag's own commit if it is still missing.
have() { git -C "$dir" cat-file -e "$1^{commit}" 2>/dev/null; }
if ! have "$commit" || ! have "$st"; then
  g fetch --no-tags -q "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null
  have "$st" || g fetch --no-tags -q "$remote" "$st" 2>/dev/null
fi
out stable "$(git -C "$dir" rev-parse --short "$st" 2>/dev/null || printf '%.7s' "$st")"
have "$st" || unknown "could not fetch the stable commit"
full=$(git -C "$dir" rev-parse -q --verify "$commit^{commit}" 2>/dev/null) || unknown "commit $commit is not on $remote/$branch (or is ambiguous)"

behind=$(git -C "$dir" rev-list --count "$full..$st")
ahead=$(git -C "$dir" rev-list --count "$st..$full")
out behind "$behind"; out ahead "$ahead"
if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
  out verdict CURRENT
elif [ "$ahead" -eq 0 ]; then
  out verdict BEHIND
  out note "the hub serves the client from $commit, $behind commit(s) older than stable — redeploy the hub image at stable"
elif [ "$behind" -eq 0 ]; then
  out verdict AHEAD
  out note "the hub image is $ahead commit(s) newer than stable"
else
  out verdict DIVERGED
  out note "the hub image and stable have diverged ($ahead only in the image, $behind only in stable)"
fi
exit 0
