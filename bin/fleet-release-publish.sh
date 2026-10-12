#!/bin/bash
# fleet-release-publish.sh <sha> [--hub <url>] [--dir <checkout>] [--train <json file>] [--dry-run]
#   — hand the hub a stable it then serves to every machine (issue #2772,
#   EPIC #2770 C2). Run by CI: the release train's `release` job (before its
#   move, issue #3142), and stable-publish.yml (dispatch only — the repair road,
#   and the one `fleet-stable.sh move` by hand dispatches). The hub never looks on GitHub
#   for a new stable once one publish has landed.
#
# What it sends (POST <hub>/v1/fleet/release/publish, multipart):
#   sha      the commit
#   prev     the hub's own stable, read from <hub>/v1/fleet/release/stable
#            ("" when the hub has none yet)
#   commits  `git rev-list --first-parent <prev>..<sha> | git cat-file --batch`
#   tree     `git archive --format=tar <sha> | gzip -n` — the whole commit
#   run      this run's URL, for the hub's log and fleet_audit
#   train    with --train <file> (issue #3142): the release train's ledger — what
#            it carried, its stages, its macOS queue (#3140's JSON). Bookkeeping
#            only: a hub without the ledger ignores the part, and a hub with it
#            never refuses a publish over it.
#   signer   with FLEET_RELEASE_SIGN_KEY in the environment (issue #3559): the
#            train's public key. A hub that holds no signing key builds the
#            release UNSIGNED for it and answers 202 with the manifest's bytes;
#            this script checks them against the checkout
#            (fleet-release-sign.py check — every file, the chain, the place on
#            the chain), signs them (Ed25519 + SSHSIG) and POSTs the two
#            signatures; only then is it stable. The key comes from the
#            release-sign environment's secret and is only ever read from the
#            environment — never an argv, a file or a log line.
# The hub hashes the archive into a git tree and the commit objects into their
# shas, so it needs no trust in this script — only in who runs it:
#
# WHO: the workflow's GitHub Actions OIDC token (permissions: id-token: write),
# audience FLEET_PUBLISH_AUDIENCE (default ccquota-fleet-release) — the hub checks
# repository, ref and workflow. Without one (not in Actions), FLEET_PUBLISH_TOKEN
# — the hub's publish-only fallback bearer — from the environment. Neither is
# ever printed or written to a file.
#
# Re-runnable: the same sha again answers 200 `already`. A hub that moved on
# meanwhile answers 409 and says its stable; run it again.
#
# Exit 0 published / already · 1 the hub refused (its answer printed) ·
#      2 usage / git / no identity · 3 the hub could not be reached
set -uo pipefail

sha="" hub="${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}" dir="" dry=0 train=""
die() { printf 'fleet-release-publish: %s\n' "$*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hub) shift; hub="${1:-}" ;;
    --dir) shift; dir="${1:-}" ;;
    --train) shift; train="${1:-}" ;;
    --dry-run|-n) dry=1 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$sha" ] || die "one sha only"; sha="$1" ;;
  esac
  shift
done
here="$(cd "$(dirname "$0")" && pwd)"
[ -n "$dir" ] || dir="$(cd "$here/.." && pwd)"
[ -z "$train" ] || [ -s "$train" ] || die "--train $train is not a file"
[ -n "$hub" ] || die "no hub — pass --hub <url> or set FLEET_HUB_URL"
hub="${hub%/}"
sha=$(git -C "$dir" rev-parse -q --verify "${sha:-HEAD}^{commit}") || die "unknown commit ${sha:-HEAD} in $dir"

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet-publish.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT

# the hub's stable: the chain is cut from there
code=$(curl -sS -m 30 -o "$work/stable.json" -w '%{http_code}' "$hub/v1/fleet/release/stable") ||
  { printf 'fleet-release-publish: %s cannot be reached\n' "$hub" >&2; exit 3; }
prev=""
case "$code" in
  200) prev=$(sed -n 's/^ *"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' "$work/stable.json" | head -1) ;;
  404) ;; # releases on, nothing stable yet — or releases off, and the POST says so
  *) printf 'fleet-release-publish: GET %s/v1/fleet/release/stable answered %s\n' "$hub" "$code" >&2; exit 3 ;;
esac

if [ -n "$prev" ] && [ "$prev" != "$sha" ]; then
  git -C "$dir" cat-file -e "$prev^{commit}" 2>/dev/null ||
    git -C "$dir" fetch -q origin "$prev" 2>/dev/null ||
    die "the hub's stable ${prev:0:7} is not in $dir (a shallow checkout? fetch-depth: 0)"
  git -C "$dir" merge-base --is-ancestor "$prev" "$sha" ||
    printf 'fleet-release-publish: %s does not descend from the hub'"'"'s stable %s — the hub will refuse it (409)\n' "${sha:0:7}" "${prev:0:7}" >&2
  git -C "$dir" rev-list --first-parent "$prev..$sha" > "$work/list" || die "git rev-list failed"
elif [ -z "$prev" ]; then
  printf '%s\n' "$sha" > "$work/list"
else
  : > "$work/list" # the hub already has it: an empty chain, answered `already`
fi
if [ -s "$work/list" ]; then
  git -C "$dir" cat-file --batch < "$work/list" > "$work/commits" || die "git cat-file failed"
else
  : > "$work/commits"
fi
git -C "$dir" archive --format=tar "$sha" | gzip -n > "$work/tree.tar.gz" || die "git archive failed"
n=$(grep -c . "$work/list")
size=$(wc -c < "$work/tree.tar.gz" | tr -d ' ')
from="${prev:0:7}"; [ -n "$from" ] || from=none
printf 'publish: %s → %s  (%s commit(s), tree %s bytes) to %s\n' "$from" "${sha:0:7}" "$n" "$size" "$hub"
if [ "$dry" -eq 1 ]; then
  printf 'dry-run: would POST %s/v1/fleet/release/publish\n' "$hub"
  exit 0
fi

# who: the run's OIDC token, else the fallback bearer — kept in a curl config
# file (0600, removed on exit), never on an argv
umask 077
tok=""
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  printf 'header = "Authorization: bearer %s"\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" > "$work/oidc.cfg"
  tok=$(curl -sS -m 30 -K "$work/oidc.cfg" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${FLEET_PUBLISH_AUDIENCE:-ccquota-fleet-release}" |
    sed -n 's/.*"value": *"\([^"]*\)".*/\1/p') || tok=""
  [ -n "$tok" ] || die "no OIDC token from the Actions runtime (permissions: id-token: write?)"
elif [ -n "${FLEET_PUBLISH_TOKEN:-}" ]; then
  tok="$FLEET_PUBLISH_TOKEN"
else
  die "no identity: not a GitHub Actions run with id-token: write, and no FLEET_PUBLISH_TOKEN"
fi
printf 'header = "Authorization: Bearer %s"\n' "$tok" > "$work/auth.cfg"
tok=""

run=""
[ -z "${GITHUB_RUN_ID:-}" ] || run="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID" # dist-ok: the run's link, for the hub's log
set -- -F "sha=$sha" -F "prev=$prev" -F "run=$run"
[ -z "$train" ] || set -- "$@" -F "train=@$train;type=application/json"
signer=""
if [ -n "${FLEET_RELEASE_SIGN_KEY:-}" ]; then
  signer=$(python3 "$here/fleet-release-sign.py" pub env:FLEET_RELEASE_SIGN_KEY) ||
    die "FLEET_RELEASE_SIGN_KEY is not a base64 ed25519 seed"
  printf 'signer: %s (the release-sign key)\n' "$signer"
  set -- "$@" -F "signer=$signer"
fi
code=$(curl -sS -m 900 -K "$work/auth.cfg" -o "$work/answer" -w '%{http_code}' "$@" \
  -F "commits=@$work/commits;type=application/octet-stream" \
  -F "tree=@$work/tree.tar.gz;type=application/gzip" \
  "$hub/v1/fleet/release/publish") || { printf 'fleet-release-publish: POST to %s failed\n' "$hub" >&2; exit 3; }
answer=$(cat "$work/answer" 2>/dev/null)
if [ "$code" = 200 ]; then
  [ -z "$signer" ] || printf 'note: the hub still signs with its own key — the release-sign key was offered, not used\n'
  printf 'published: %s\n' "$answer"
  exit 0
fi
if [ "$code" = 202 ]; then
  # the hub built it unsigned: look, then sign (issue #3559)
  python3 -c 'import base64, json, sys; sys.stdout.buffer.write(base64.b64decode(json.load(open(sys.argv[1]))["manifest"]))' \
    "$work/answer" > "$work/manifest.json" || { printf 'fleet-release-publish: the hub answered 202 without a manifest: %s\n' "$answer" >&2; exit 1; }
  python3 "$here/fleet-release-sign.py" check --key env:FLEET_RELEASE_SIGN_KEY --dir "$dir" --sha "$sha" --prev "$prev" "$work/manifest.json" ||
    { printf 'fleet-release-publish: NOT signed — the hub built something else than this commit\n' >&2; exit 1; }
  python3 "$here/fleet-release-sign.py" manifest --key env:FLEET_RELEASE_SIGN_KEY "$work/manifest.json" > "$work/sigs" ||
    { printf 'fleet-release-publish: signing failed\n' >&2; exit 1; }
  code=$(curl -sS -m 120 -K "$work/auth.cfg" -o "$work/answer" -w '%{http_code}' -F "sha=$sha" \
    -F "sig=$(sed -n 1p "$work/sigs")" -F "sshsig=$(sed -n 2p "$work/sigs")" \
    "$hub/v1/fleet/release/publish") || { printf 'fleet-release-publish: POST of the signature to %s failed\n' "$hub" >&2; exit 3; }
  answer=$(cat "$work/answer" 2>/dev/null)
  if [ "$code" = 200 ]; then
    printf 'published (signed by the train): %s\n' "$answer"
    exit 0
  fi
fi
if [ "$code" = 428 ]; then
  printf 'fleet-release-publish: the hub holds no signing key and waits for the train'"'"'s — this run has no FLEET_RELEASE_SIGN_KEY (the release-sign environment): %s\n' "$answer" >&2
  exit 1
fi
printf 'fleet-release-publish: the hub answered %s: %s\n' "$code" "$answer" >&2
case "$code" in 5??) exit 3 ;; esac
exit 1
