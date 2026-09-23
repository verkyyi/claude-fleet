#!/bin/bash
# fleet-repo.sh — the repos a fleet hosts (issue #788).
#
#   fleet-repo.sh list   [--session <sess>]
#   fleet-repo.sh add    [--session <sess>] <owner/repo> [<checkout-dir>] [--base <branch>]
#   fleet-repo.sh remove [--session <sess>] <owner/repo> [--force]
#   fleet-repo.sh get    [--session <sess>] <KEY> [<owner/repo> | --window <w> | --worktree <dir>] [--tsv]
#   fleet-repo.sh fold   <from-session> --into <session> [--dry-run] [--wait]
#
# A fleet hosts its conf's own FLEET_REPO plus one overlay per further repo at
# $FLEET_CONF_DIR/fleets/<sess>/repos/<slug>.conf (see fleet_repos in fleet-lib.sh).
# All hosted repos are equal; the conf's repo is simply the first one.
#
# `add` reuses the checkout if it already is that repo, else clones it — the same
# rule as fleet-up.sh — resolves the base branch the same way (#603), and writes the
# overlay. (It used to refuse without FLEET_MULTIREPO=1; the two-repo end-to-end
# check, bin/multirepo-e2e-selftest.sh, lifted that gate in #795.)
#
# `remove` deletes an overlay. The conf's own repo lives in the fleet conf and is not
# removable here. A repo that still has live windows (@repo) is refused without
# --force: those sessions would lose their repo's MAIN/base mid-flight.
#
# `get` prints one setting AS A REPO SEES IT (issue #978): the repo's overlay value,
# else the fleet conf's — fleet_repo_conf_get. The repo is the one named, or the
# window's (fleet_window_repo), or the one whose base registers <dir>
# (fleet_worktree_repo), or — with none of those — this pane's window. A repo that
# cannot be resolved reads the fleet value (the documented fallback, never a
# guess at a repo). `--tsv` prints `<repo>\t<conf file holding it>\t<value>`: the
# out-of-process readers (the sleep/failover MCP contract) use it to name the file
# a fix belongs in.
#
# `fold` moves a one-repo fleet into another (issue #796): see fold_main below.
#
# --session defaults to the fleet this pane runs in. Exit 0 ok, 1 refused/failed,
# 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

die()   { echo "fleet-repo: $*" >&2; exit 1; }
usage() { sed -n '4,8p' "$0" | sed 's/^# //' >&2; exit 2; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
SESS=""; REPO=""; DIR=""; BASE=""; FORCE=0; KEY=""; WIN=""; WT=""; TSV=0
INTO=""; DRY=0; WAIT=0
if [ "$cmd" = get ]; then KEY="${1:-}"; [ -n "$KEY" ] || usage; shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ $# -ge 2 ] || usage; SESS="$2"; shift 2 ;;
    --base)    [ $# -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --window)  [ $# -ge 2 ] || usage; WIN="$2"; shift 2 ;;
    --worktree) [ $# -ge 2 ] || usage; WT="$2"; shift 2 ;;
    --tsv)     TSV=1; shift ;;
    --force)   FORCE=1; shift ;;
    --into)    [ $# -ge 2 ] || usage; INTO="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --wait)    WAIT=1; shift ;;
    -h|--help) usage ;;
    -*)        echo "fleet-repo: unknown flag $1" >&2; usage ;;
    *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$DIR" ]; then DIR="$1"; else die "extra arg $1"; fi; shift ;;
  esac
done
if [ "$cmd" = fold ]; then
  { [ -n "$REPO" ] && [ -n "$INTO" ] && [ -z "$DIR" ]; } || usage
  SESS="$INTO"
fi
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

# ---- fold (issue #796) --------------------------------------------------------
# fleet-repo.sh fold <from> --into <sess> [--dry-run] [--wait] — move the one-repo
# fleet <from> into <sess>, then retire <from>. What the hand fold of tokenledger
# did in five steps (recorded on #796), as one plan + execute pair:
#   1. <from>'s repo becomes an overlay of <sess> — `add`, reusing <from>'s checkout
#      and base — and every per-repo key <from>'s conf sets to a value <sess> does
#      not already have is carried into it (model, agent, MCP, deploy, #978's
#      setup/switches). A differing key with NO per-repo form is not carried: it is
#      WARNED, because only <sess>'s fleet conf could hold it.
#   2. each worker window (issue-N / scratch-N) takes the cross-fleet move path:
#      fleet-worker-stop.sh (a graceful /exit — its ledger row keeps it resumable),
#      then dash-restore-session.sh --repo into <sess> (same transcript, same
#      worktree, @repo stamped). A hibernating worker is woken first. A busy one
#      (working / needs) is left where it is — or, with --wait, moved the moment it
#      goes idle (at most FLEET_FOLD_WAIT s, default 7200). Panels and warm-pool
#      windows are not moved: they retire with the server, and <sess>'s own pool
#      refills for the repo (#797).
#   3. only when nothing is left behind: fleet-down <from> (never --purge), and its
#      conf dir is ARCHIVED, never deleted, to
#      $FLEET_CONF_DIR/archive/<from>-folded-into-<sess without fleet->-<YYYYMMDD>.
# --dry-run prints the plan and stops; a real run prints the SAME plan, then acts.
# Re-running after a partial fold is safe: an already-hosted repo is left as is.
_FOLD_CARRY="FLEET_MODEL FLEET_AGENT FLEET_MCP_CONFIG FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK FLEET_REPO_SHORT $_FLEET_REPO_OVERRIDABLE"

# Always the fleet's OWN socket by label — a fold talks to two fleets, so the
# pane's $TMUX (one of them, or neither) is never the right answer for both.
ftm()      { local s="$1"; shift; tmux -L "$(fleet_socket "$s")" "$@"; }
fold_opt() { ftm "$1" display-message -p -t "$2" "$3" 2>/dev/null; }
# fold_val <sess> <KEY> — KEY as that fleet's conf leaves it (subshelled).
fold_val() { ( fleet_load_repo_conf "$1" '' >/dev/null 2>&1; eval "printf '%s' \"\${$2-}\"" ); }
# fold_q <value> — shell-quoted for an overlay line: "…" when that is literal, else %q.
fold_q() {
  case "$1" in *[\"\$\`\\]*) printf '%q' "$1" ;; *) printf '"%s"' "$1" ;; esac
}
# fold_sets <conf> → the FLEET_* keys the file assigns, one per line.
fold_sets() {
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?(FLEET_[A-Za-z0-9_]+)=.*/\2/p' "$1" | sort -u
}
# fold_key <sess> <wid> → issue-N / scratch-N, as fleet-worker-stop.sh resolves it.
fold_key() {
  local iss wt
  iss=$(fold_opt "$1" "$2" '#{@issue}'); iss="${iss//[^0-9]/}"
  [ -n "$iss" ] && { printf 'issue-%s' "$iss"; return 0; }
  [ "$(fold_opt "$1" "$2" '#{@raw}')" = 1 ] || return 0
  wt=$(fold_opt "$1" "$2" '#{@worktree}'); [ -n "$wt" ] || wt=$(fold_opt "$1" "$2" '#{pane_current_path}')
  fleet_scratch_key "$wt"
}
# fold_classify <from> <wid> → "<action>\t<key>\t<name>\t<why>", action one of
# move · wake · busy · panel · pool · left.
fold_classify() {
  local name key st
  name=$(fold_opt "$1" "$2" '#{window_name}')
  case "$name" in dash|plan|backlog) printf 'panel\t-\t%s\tretires with the server\n' "$name"; return 0 ;; esac
  if [ "$(fold_opt "$1" "$2" '#{@pool}')" = 1 ]; then
    printf 'pool\t-\t%s\tretires with the server; the target refills its pool\n' "$name"; return 0
  fi
  key=$(fold_key "$1" "$2")
  if [ -z "$key" ]; then
    printf 'left\t-\t%s\tno issue-N / scratch-N binding — not resumable; close or move it by hand\n' "$name"
    return 0
  fi
  if [ -n "$(fold_opt "$1" "$2" '#{@worker_lifecycle}')" ]; then
    printf 'wake\t%s\t%s\thibernating — woken, then moved\n' "$key" "$name"; return 0
  fi
  st=$(fold_opt "$1" "$2" '#{@claude_state}')
  # needs/blocked is the worker's own "stuck, turn over" red (#704) — idle, so it
  # moves; any other needs is a prompt waiting mid-turn.
  [ "$st" = needs ] && [ "$(fold_opt "$1" "$2" '#{@claude_needs}')" = blocked ] && st=needs/blocked
  case "$st" in
    needs/blocked)   printf 'move\t%s\t%s\t%s\n' "$key" "$name" "$st" ;;
    working*|needs*) printf 'busy\t%s\t%s\t%s\n' "$key" "$name" "$st" ;;
    *)               printf 'move\t%s\t%s\t%s\n' "$key" "$name" "${st:-idle}" ;;
  esac
}
# fold_found <sess> <key> <repo> — 0 iff a window of <sess> holds <key> for <repo>.
fold_found() {
  local w
  for w in $(ftm "$1" list-windows -t "=$1" -F '#{window_id}' 2>/dev/null); do
    [ "$(fold_key "$1" "$w")" = "$2" ] || continue
    [ "$(fleet_norm_repo "$(fold_opt "$1" "$w" '#{@repo}')")" = "$3" ] && return 0
  done
  return 1
}
# fold_move <wid> <key> <wake:0|1> — one worker across; prints the outcome. rc 0 moved.
fold_move() {
  local out landed
  if [ "$3" = 1 ]; then
    bash "$BIN/fleet-sleep.sh" wake "$FROM" "$1" >/dev/null 2>&1 \
      || { echo "    $2: wake failed — left in $FROM (fleet-sleep.sh why $FROM $1)"; return 1; }
  fi
  out=$(bash "$BIN/fleet-worker-stop.sh" "$FROM" "$2" 2>/dev/null)
  case "$out" in
    stopped:*) : ;;
    *) echo "    $2: stop ${out:-failed} — left in $FROM"; return 1 ;;
  esac
  case "$2" in scratch-*) landed="landed:scratch:$2" ;; *) landed="landed:issue:${2#issue-}" ;; esac
  bash "$BIN/dash-restore-session.sh" "$landed" "$SESS" --repo "$SRC_REPO" >/dev/null 2>&1
  if fold_found "$SESS" "$2" "$SRC_REPO"; then echo "    $2: moved ($out) → $SESS"; return 0; fi
  echo "    $2: stopped ($out) but not resumed in $SESS — its ledger row is kept: /fleet-history resume there"
  return 1
}
# fold_count <tsv> <action...> → how many plan rows carry one of the actions.
fold_count() {
  local t="$1"; shift
  printf '%s' "$t" | awk -F'\t' -v a=" $* " 'NF && index(a, " " $2 " ")' | grep -c .
}

fold_main() {
  FROM="$REPO"
  [ "$FROM" != "$SESS" ] || die "cannot fold $SESS into itself"
  local fconf; fconf=$(fleet_conf_file "$FROM")
  [ -f "$fconf" ] || die "'$FROM' is not a fleet (no conf at $fconf)"
  if [ -n "${TMUX:-}" ] && [ "$(fleet_current_session)" = "$FROM" ]; then
    die "run fold from outside $FROM — its own server is torn down at the end"
  fi
  local nrepos; nrepos=$(fleet_repos "$FROM" | grep -c .)
  [ "$nrepos" = 1 ] || die "$FROM hosts $nrepos repos — fold takes a one-repo fleet"
  SRC_REPO=$(fleet_repos "$FROM")
  local row src_main src_base
  row=$( fleet_load_repo_conf "$FROM" "$SRC_REPO" >/dev/null 2>&1
         printf '%s\t%s' "${FLEET_MAIN:-}" "${FLEET_BASE_BRANCH:-}" )
  src_main=${row%%$'\t'*}; src_base=${row#*$'\t'}
  [ -d "$src_main/.git" ] || die "$FROM's checkout ($src_main) is not a git checkout"
  local hosted=0; fleet_repo_hosted "$SESS" "$SRC_REPO" && hosted=1

  # ---- plan: one pass that both --dry-run and the real run print ----
  local k sv tv carry='' warns='' skip
  skip=" FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH $_FLEET_GLOBAL_ONLY "
  for k in $(fold_sets "$fconf"); do
    sv=$(fold_val "$FROM" "$k"); tv=$(fold_val "$SESS" "$k")
    [ "$sv" = "$tv" ] && continue
    case " $_FOLD_CARRY " in
      *" $k "*) carry="$carry$k=$(fold_q "$sv")"$'\n' ;;
      *) case "$skip" in *" $k "*) continue ;; esac
         warns="$warns$k: $FROM=\"$sv\" $SESS=\"$tv\""$'\n' ;;
    esac
  done
  local plan='' w
  for w in $(ftm "$FROM" list-windows -t "=$FROM" -F '#{window_id}' 2>/dev/null); do
    plan="$plan$w"$'\t'"$(fold_classify "$FROM" "$w")"$'\n'
  done
  local busy_act='left'; [ "$WAIT" = 1 ] && busy_act='wait'
  echo "fold $FROM → $SESS ($SRC_REPO)"
  if [ "$hosted" = 1 ]; then
    echo "  repo:    $SESS already hosts $SRC_REPO — its overlay is left as is"
  else
    echo "  repo:    add $SRC_REPO main=$src_main base=$src_base"
    [ -n "$carry" ] && printf '%s' "$carry" | sed 's/^/  carry:   /'
  fi
  [ -n "$warns" ] && printf '%s' "$warns" \
    | sed 's/^/  WARN:    fleet-level key, no per-repo form — not carried: /'
  local wid act key name why
  while IFS=$'\t' read -r wid act key name why; do
    [ -n "$wid" ] || continue
    [ "$act" = busy ] && act="$busy_act"
    printf '  %-8s %-11s %s — %s\n' "$act" "$key" "$name" "$why"
  done <<PLAN
$plan
PLAN
  local stuck; stuck=$(fold_count "$plan" left busy)
  [ "$WAIT" = 1 ] && stuck=$(fold_count "$plan" left)
  if [ "$stuck" -gt 0 ]; then
    echo "  retire:  NO — $stuck window(s) stay in $FROM; re-run fold (or --wait) once they are done"
  else
    echo "  retire:  fleet-down $FROM; archive its conf → archive/$FROM-folded-into-${SESS#fleet-}-<date>"
  fi
  [ "$DRY" = 1 ] && return 0

  # ---- execute ----
  if [ "$(fold_count "$plan" move wake busy)" -gt 0 ] && ! ftm "$SESS" has-session -t "=$SESS" 2>/dev/null; then
    die "$SESS is not running — fleet-up it first (the sessions resume into it)"
  fi
  if [ "$hosted" = 0 ]; then
    bash "$0" add --session "$SESS" "$SRC_REPO" "$src_main" --base "$src_base" || die "add failed"
    if [ -n "$carry" ]; then
      local f; f=$(fleet_repo_conf_file "$SESS" "$SRC_REPO")
      { printf '# carried from fleet %s by fold (issue #796)\n' "$FROM"; printf '%s' "$carry"; } >> "$f" \
        || die "cannot write $f"
    fi
  fi
  local failed=0 pending=''
  while IFS=$'\t' read -r wid act key name why; do
    case "$act" in
      move) fold_move "$wid" "$key" 0 || failed=$((failed + 1)) ;;
      wake) fold_move "$wid" "$key" 1 || failed=$((failed + 1)) ;;
      busy) pending="$pending$wid"$'\t'"$key"$'\n' ;;
    esac
  done <<PLAN
$plan
PLAN
  # --wait: each busy worker is moved as soon as it goes idle.
  if [ "$WAIT" = 1 ] && [ -n "$pending" ]; then
    local deadline next line
    deadline=$(( $(date +%s) + ${FLEET_FOLD_WAIT:-7200} ))
    while [ -n "$pending" ] && [ "$(date +%s)" -lt "$deadline" ]; do
      next=''
      while IFS=$'\t' read -r wid key; do
        [ -n "$wid" ] || continue
        if [ "$(fold_key "$FROM" "$wid")" != "$key" ]; then
          echo "    $key: gone from $FROM — nothing to move"; continue
        fi
        line=$(fold_classify "$FROM" "$wid")
        case "${line%%$'\t'*}" in
          move) fold_move "$wid" "$key" 0 || failed=$((failed + 1)) ;;
          wake) fold_move "$wid" "$key" 1 || failed=$((failed + 1)) ;;
          *)    next="$next$wid"$'\t'"$key"$'\n' ;;
        esac
      done <<PEND
$pending
PEND
      pending="$next"
      [ -n "$pending" ] && sleep "${FLEET_FOLD_POLL:-15}"
    done
  fi
  local left; left=$(( $(fold_count "$plan" left) + failed + $(printf '%s' "$pending" | grep -c .) ))
  if [ "$left" -gt 0 ]; then
    echo "fold: $FROM NOT retired — $left session(s) still there; re-run fold once they are done"
    return 1
  fi

  # ---- retire: the server goes, the conf is archived (never deleted) ----
  bash "$BIN/fleet-down.sh" "$FROM" || die "fleet-down $FROM failed"
  local adir dest
  adir="$FLEET_CONF_DIR/archive"; dest="$adir/$FROM-folded-into-${SESS#fleet-}-$(date +%Y%m%d)"
  [ -e "$dest" ] && dest="$dest-$(date +%H%M%S)"
  mkdir -p "$adir" || die "cannot create $adir"
  if [ -d "$FLEET_CONF_DIR/fleets/$FROM" ]; then
    mv "$FLEET_CONF_DIR/fleets/$FROM" "$dest" || die "cannot archive $FLEET_CONF_DIR/fleets/$FROM"
  else   # a legacy flat <sess>.conf
    { mkdir -p "$dest" && mv "$fconf" "$dest/conf"; } || die "cannot archive $fconf"
  fi
  echo "fold: $FROM retired — its conf is archived at $dest"
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

  get)
    case "$KEY" in [A-Z_]*) ;; *) usage ;; esac
    case "$KEY" in *[!A-Za-z0-9_]*) usage ;; esac
    if [ -n "$REPO" ]; then
      norm_repo_arg
      fleet_repo_hosted "$SESS" "$REPO" || die "$SESS does not host $REPO"
    elif [ -n "$WIN" ]; then
      REPO=$(fleet_window_repo "$SESS" "$WIN")
    elif [ -n "$WT" ]; then
      REPO=$(fleet_worktree_repo "$SESS" "$WT"); REPO=${REPO%%$'\t'*}
    elif [ -n "${TMUX_PANE:-}" ] \
         && [ "$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" = "$SESS" ]; then
      REPO=$(fleet_window_repo "$SESS" "$TMUX_PANE")
    fi
    if [ -n "$REPO" ]; then
      val=$(fleet_repo_conf_get "$SESS" "$REPO" "$KEY"); src=$(fleet_repo_conf_file_for "$SESS" "$REPO")
    else   # unresolved: the fleet value, from the fleet conf alone
      val=$( fleet_load_repo_conf "$SESS" '' >/dev/null 2>&1; eval "printf '%s' \"\${$KEY:-}\"" ); src=$CONF
    fi
    if [ "$TSV" = 1 ]; then printf '%s\t%s\t%s\n' "$REPO" "$src" "$val"; else printf '%s\n' "$val"; fi
    ;;

  fold) fold_main ;;

  *) usage ;;
esac
