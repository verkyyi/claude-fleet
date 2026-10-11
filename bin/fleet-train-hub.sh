#!/bin/bash
# fleet-train-hub.sh <train_sha> [--dir <checkout>] [--hub <url>] [--timeout <s>]
#   — does this release train deploy the hub (入口), or is the hub already
#   TRAIN_SHA's? (issue #3142, EPIC #3139 C3)
#
# One train ships one commit: the hub image, the publish and stable all name
# TRAIN_SHA. Rebuilding and rolling the hub costs a train 10–15 minutes, so it is
# done only when the hub would differ (EPIC #3139 发起人拍板 9):
#   * the Go source the hub's ccquota is built from — the same digest
#     `fleet-stable.sh move`'s gate 8 and the hub's own publish check compare
#     (bin/fleet-src-digest.py: tokenledger/ less tests and docs), or
#   * deploy/k8s/ (the manifests the deploy applies)
# changed between the commit the hub runs (its GET /version `prod-<sha>`) and
# TRAIN_SHA. A hub whose commit cannot be read or is not in the checkout is
# deployed (unknown is never "the same"). When it is skipped, gate 8 of the
# train's move still holds the hub's ccquota to TRAIN_SHA's source.
#
# RELEASE_TRAIN_HUB=off (a repo variable the workflow passes in): the train never
# deploys — hub-deploy.yml by hand is then the only road (its push trigger retired
# with #3143) — and gate 8 still checks.
#
# Prints, and appends to $GITHUB_OUTPUT when set:
#   deploy   true | false
#   live     the commit the hub runs (full sha), or empty when unknown
#   why      one line
# Exit: 0 decided · 2 usage / TRAIN_SHA not in the checkout
set -u
BIN_DIR=$(cd "$(dirname "$0")" && pwd)
dir=. hub="" timeout=15 train=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)     shift; dir="${1:-}" ;;
    --hub)     shift; hub="${1:-}" ;;
    --timeout) shift; timeout="${1:-15}" ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        printf 'fleet-train-hub: unknown argument %s\n' "$1" >&2; exit 2 ;;
    *)         [ -z "$train" ] || { printf 'fleet-train-hub: one sha only\n' >&2; exit 2; }; train="$1" ;;
  esac
  shift
done
case "$timeout" in ''|*[!0-9]*|0) timeout=15 ;; esac
[ -n "$hub" ] || hub="${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}"
hub="${hub%/}"
[ -n "$train" ] || { printf 'fleet-train-hub: usage: fleet-train-hub.sh <train_sha> [--dir d] [--hub url]\n' >&2; exit 2; }
train=$(git -C "$dir" rev-parse -q --verify "$train^{commit}") \
  || { printf 'fleet-train-hub: %s is not a commit in %s\n' "$train" "$dir" >&2; exit 2; }

say() {   # say <deploy> <live> <why>
  printf 'deploy=%s\nlive=%s\nwhy=%s\n' "$1" "$2" "$3"
  [ -z "${GITHUB_OUTPUT:-}" ] || printf 'deploy=%s\nlive=%s\nwhy=%s\n' "$1" "$2" "$3" >> "$GITHUB_OUTPUT"
  exit 0
}

[ "${RELEASE_TRAIN_HUB:-}" != off ] || say false "" "RELEASE_TRAIN_HUB=off — the train deploys no hub (hub-deploy.yml by hand: Actions → Run workflow); the move's ccquota gate still checks it"
[ -n "$hub" ] || say true "" "no hub address — deploying"

ver=$(curl -fsS -m "$timeout" "$hub/version" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("version") or "")
except Exception: pass' 2>/dev/null)
case "$ver" in
  (prod-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) short=${ver#prod-} ;;
  (*) say true "" "the hub's /version names no prod-<sha> build (${ver:-unreadable}) — deploying" ;;
esac
live=$(git -C "$dir" rev-parse -q --verify "$short^{commit}" 2>/dev/null) || {
  git -C "$dir" fetch -q --no-tags origin "+refs/heads/master:refs/remotes/origin/master" >/dev/null 2>&1 </dev/null
  live=$(git -C "$dir" rev-parse -q --verify "$short^{commit}" 2>/dev/null)
} || say true "" "the hub runs $ver, a commit this checkout does not have — deploying"

[ "$live" != "$train" ] || say false "$live" "the hub already runs $(printf '%.7s' "$train")"
src_live=$(python3 "$BIN_DIR/fleet-src-digest.py" "$dir" "$live" 2>/dev/null) || src_live="?live"
src_train=$(python3 "$BIN_DIR/fleet-src-digest.py" "$dir" "$train" 2>/dev/null) || src_train="?train"
if [ "$src_live" != "$src_train" ]; then
  say true "$live" "the Go source changed since the hub's $ver — deploying $(printf '%.7s' "$train")"
fi
if ! git -C "$dir" diff --quiet "$live" "$train" -- deploy/k8s 2>/dev/null; then
  say true "$live" "deploy/k8s/ changed since the hub's $ver — deploying $(printf '%.7s' "$train")"
fi
say false "$live" "the hub's $ver already is $(printf '%.7s' "$train")'s Go source and deploy/k8s/ — no new image"
