#!/bin/bash
# fleet-repo.sh — the repos a fleet hosts (issue #788).
#
#   fleet-repo.sh list   [--session <sess>]
#   fleet-repo.sh add    [--session <sess>] <owner/repo> [<checkout-dir>] [--base <branch>]
#   fleet-repo.sh remove [--session <sess>] <owner/repo> [--force]
#
# A fleet hosts its conf's own FLEET_REPO plus one overlay per further repo at
# $FLEET_CONF_DIR/fleets/<sess>/repos/<slug>.conf (see fleet_repos in fleet-lib.sh).
# All hosted repos are equal; the conf's repo is simply the first one.
#
# `add` reuses the checkout if it already is that repo, else clones it — the same
# rule as fleet-up.sh — resolves the base branch the same way (#603), and writes the
# overlay. It REFUSES unless FLEET_MULTIREPO=1 (env, global fleet.conf or this
# fleet's conf): a second repo stays switched off for real fleets until the batch's
# end-to-end check (#795) lifts the gate.
#
# `remove` deletes an overlay. The conf's own repo lives in the fleet conf and is not
# removable here. A repo that still has live windows (@repo) is refused without
# --force: those sessions would lose their repo's MAIN/base mid-flight.
#
# --session defaults to the fleet this pane runs in. Exit 0 ok, 1 refused/failed,
# 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

die()   { echo "fleet-repo: $*" >&2; exit 1; }
usage() { sed -n '4,6p' "$0" | sed 's/^# //' >&2; exit 2; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
SESS=""; REPO=""; DIR=""; BASE=""; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ $# -ge 2 ] || usage; SESS="$2"; shift 2 ;;
    --base)    [ $# -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage ;;
    -*)        echo "fleet-repo: unknown flag $1" >&2; usage ;;
    *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$DIR" ]; then DIR="$1"; else die "extra arg $1"; fi; shift ;;
  esac
done
[ -n "$SESS" ] || { [ -n "${TMUX:-}" ] && SESS=$(fleet_current_session); }
[ -n "$SESS" ] || die "no fleet — pass --session <sess>"
CONF=$(fleet_conf_file "$SESS")
[ -f "$CONF" ] || die "'$SESS' is not a fleet (no conf at $CONF)"

norm_repo_arg() {
  REPO=$(fleet_norm_repo "$REPO")
  case "$REPO" in
    *[!A-Za-z0-9_./-]* | */*/* | /* | */) die "invalid repo '$REPO' — expected owner/repo" ;;
    ?*/?*) : ;;
    *) die "invalid repo '$REPO' — expected owner/repo" ;;
  esac
}

case "$cmd" in
  list)
    [ -z "$REPO" ] || usage
    confrepo=$( unset FLEET_REPO; . "$CONF" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    confrepo=$(fleet_norm_repo "$confrepo")
    printf 'fleet %s hosts:\n' "$SESS"
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      row=$( fleet_load_repo_conf "$SESS" "$r" >/dev/null 2>&1
             printf '%s\t%s' "${FLEET_MAIN:-?}" "${FLEET_BASE_BRANCH:-?}" )
      if [ "$r" = "$confrepo" ]; then src=conf; else src=repos/$(fleet_slug "$r").conf; fi
      printf '  %-36s main=%s  base=%s  [%s]\n' "$r" "${row%%$'\t'*}" "${row#*$'\t'}" "$src"
    done <<EOF
$(fleet_repos "$SESS")
EOF
    printf 'current: %s\n' "$(fleet_current_repo "$SESS")"
    ;;

  add)
    [ -n "$REPO" ] || usage
    norm_repo_arg
    # The gate reads what a spawn would: env ▸ global fleet.conf ▸ this fleet's conf.
    gate=$( fleet_load_conf "$SESS" >/dev/null 2>&1; printf '%s' "${FLEET_MULTIREPO:-0}" )
    [ "$gate" = 1 ] || die "refused: hosting a second repo is switched off (set FLEET_MULTIREPO=1 to enable — #788/#795)"
    fleet_repo_hosted "$SESS" "$REPO" && die "$SESS already hosts $REPO"
    DIR="${DIR:-$HOME/projects/$(basename "$REPO")}"
    # --- checkout: reuse if it's already that repo, else clone (as fleet-up.sh) ---
    if [ -d "$DIR/.git" ]; then
      have=$(fleet_norm_repo "$(git -C "$DIR" remote get-url origin 2>/dev/null)")
      [ "$have" = "$REPO" ] || die "$DIR is a checkout of '$have', not '$REPO'"
      echo "fleet-repo: reusing existing checkout $DIR"
    elif [ -e "$DIR" ]; then
      die "$DIR exists but is not a git checkout"
    else
      echo "fleet-repo: cloning $REPO → $DIR"
      mkdir -p "$(dirname "$DIR")"
      if command -v gh >/dev/null 2>&1; then gh repo clone "$REPO" "$DIR" || die "clone failed"
      else git clone "https://github.com/$REPO.git" "$DIR" || die "clone failed"; fi
    fi
    DIR=$(cd "$DIR" && pwd)
    IFS=$'\t' read -r BASE BASE_SRC BASE_DEFAULT \
      < <(fleet_resolve_base_branch "$REPO" "$DIR" "$BASE")
    case "$BASE_SRC" in
      default) : ;;
      flag) if [ -n "$BASE_DEFAULT" ] && [ "$BASE" != "$BASE_DEFAULT" ]; then
              echo "fleet-repo: WARNING — --base '$BASE' is NOT $REPO's default branch ('$BASE_DEFAULT')." >&2
            fi ;;
      *) echo "fleet-repo: WARNING — could not read $REPO's default branch from GitHub; using '$BASE' ($BASE_SRC) — verify it is the trunk." >&2 ;;
    esac
    f=$(fleet_repo_conf_file "$SESS" "$REPO")
    mkdir -p "$(dirname "$f")" || die "cannot create $(dirname "$f")"
    {
      printf "# claude-fleet: repo '%s' hosted by fleet '%s' — written by fleet-repo.sh %s\n" \
        "$REPO" "$SESS" "$(date '+%Y-%m-%d %H:%M:%S')"
      printf '# Overlays the fleet conf for this repo'\''s windows. Optional overrides:\n'
      printf '# FLEET_MODEL, FLEET_AGENT, FLEET_MCP_CONFIG, FLEET_DEPLOY_*.\n'
      printf 'FLEET_REPO="%s"\n' "$REPO"
      printf 'FLEET_MAIN="%s"\n' "$DIR"
      printf 'FLEET_BASE_BRANCH="%s"\n' "$BASE"
    } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; die "failed to write $f"; }
    echo "fleet-repo: $SESS now hosts $REPO (main=$DIR base=$BASE) — $f"
    fleet_repo_label_sync "$SESS"      # the footer grows `· all` (issue #793)
    ;;

  remove)
    [ -n "$REPO" ] || usage
    norm_repo_arg
    f=$(fleet_repo_conf_file "$SESS" "$REPO")
    if [ ! -f "$f" ]; then
      fleet_repo_hosted "$SESS" "$REPO" \
        && die "$REPO is the fleet conf's own repo ($CONF) — not removable here"
      die "$SESS does not host $REPO"
    fi
    if [ "$FORCE" != 1 ]; then
      live=$(_fleet_tmux "$SESS" list-windows -t "$SESS" -F '#{window_name} #{@repo}' 2>/dev/null \
             | awk -v r="$REPO" '$2 == r { print $1 }' | tr '\n' ' ')
      [ -z "$live" ] || die "refused: live windows still belong to $REPO: $live(--force to remove anyway)"
    fi
    rm -f "$f" || die "cannot remove $f"
    if fleet_repo_hosted "$SESS" "$REPO"; then
      echo "fleet-repo: removed $REPO's overlay — it stays hosted through $CONF"
    else
      echo "fleet-repo: $SESS no longer hosts $REPO"
    fi
    fleet_repo_label_sync "$SESS"      # back to the bare fleet name at one repo (#793)
    ;;

  *) usage ;;
esac
