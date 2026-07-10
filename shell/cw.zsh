# cw.zsh — worktree-per-session helpers. Source from ~/.zshrc:
#   source ~/.claude/fleet/shell/cw.zsh
#
# cw <branch> [window-name]  — create a worktree + tmux window running claude
# cwrm <branch>              — remove a worktree + its branch
# cwclean [--prune]          — audit worktrees; --prune removes merged+clean+idle ones
# cf [<owner/repo>] [dir]    — bring up a fleet (no args = infer from this checkout)
#
# It also installs a tmux() destroy-guard (issue #158) — see the bottom of the
# file — so an accidental `tmux kill-server` from a bypass-perms worker can't
# take down every fleet sharing the default socket.

# cf — shorthand for fleet-up.sh. With no args, run it from inside a checkout
# and it infers the repo from origin. Any fleet-up flags pass straight through.
cf() {
  local bin="${${(%):-%x}:h:h}/bin"   # this file lives at <fleet>/shell/cw.zsh
  [ -x "$bin/fleet-up.sh" ] || { echo "cf: $bin/fleet-up.sh not found"; return 1; }
  "$bin/fleet-up.sh" "$@"
}

cw() {
  local repo root branch name dir bin
  bin="${${(%):-%x}:h:h}/bin"          # this file lives at <fleet>/shell/cw.zsh
  local launch=claude                  # route through the account launcher if present
  [ -x "$bin/fleet-claude.sh" ] && launch="$bin/fleet-claude.sh"
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "cw: not in a git repo"; return 1; }
  repo=$(basename "$root")
  branch="$1"; [ -z "$branch" ] && { echo "usage: cw <branch> [window-name]"; return 1; }
  name="${2:-$branch}"
  dir="$root/../${repo}-${branch//\//-}"
  # refresh the base branch so the new worktree starts from up-to-date code
  if git -C "$root" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    echo "cw: pulling $(git -C "$root" branch --show-current)..."
    git -C "$root" pull --ff-only || echo "cw: pull failed, continuing from local HEAD"
  fi
  git worktree add "$dir" -b "$branch" 2>/dev/null || git worktree add "$dir" "$branch" || return 1
  if [ -n "$TMUX" ]; then
    # reuse the current window: rename it, move into the worktree, run claude
    tmux rename-window "$name"
    cd "$dir" && "$launch"
  else
    # not in tmux: ensure the global session exists and drop a named window into it
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main
    tmux new-window -t main: -n "$name" -c "$dir" "$launch"
    tmux attach -t main
  fi
}

cwrm() {
  local repo root branch dir
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "cwrm: not in a git repo"; return 1; }
  repo=$(basename "$root")
  branch="$1"; [ -z "$branch" ] && { echo "usage: cwrm <branch>"; return 1; }
  dir="$root/../${repo}-${branch//\//-}"
  git worktree remove "$dir" && echo "removed $dir"
  # refresh the base branch; if $branch was merged remotely this lets -d succeed
  if git -C "$root" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    echo "cwrm: pulling $(git -C "$root" branch --show-current)..."
    git -C "$root" pull --ff-only || echo "cwrm: pull failed, continuing"
  fi
  git branch -d "$branch" 2>/dev/null && echo "deleted branch $branch" \
    || echo "branch $branch not deleted (unmerged? use: git branch -D $branch)"
}

cwclean() {
  local prune=0; [[ "$1" == "--prune" || "$1" == "-y" ]] && prune=1
  local root main base master live dir head branch
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "cwclean: not in a git repo"; return 1; }
  main=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  base=$(git -C "$main" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  base="${base:-main}"
  echo "cwclean: fetching origin/$base…"
  git -C "$main" fetch -q origin "$base" 2>/dev/null
  master=$(git -C "$main" rev-parse --verify -q "origin/$base" 2>/dev/null || git -C "$main" rev-parse --verify -q "$base")
  [[ -z "$master" ]] && { echo "cwclean: cannot resolve $base"; return 1; }
  live=$(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null)

  local -a prunable prunebranch
  printf '%-52s %-34s %-8s %-6s %s\n' WORKTREE BRANCH MERGED DIRTY LIVE
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "HEAD "*)     head="${line#HEAD }" ;;
      "branch "*)   branch="${line#branch refs/heads/}" ;;
      "")
        [[ -z "$dir" ]] && continue
        # skip main worktree, current worktree, detached HEAD, and the base itself
        if [[ "$dir" == "$main" || "$dir" == "$root" || -z "$branch" || "$branch" == "$base" ]]; then
          dir=""; head=""; branch=""; continue
        fi
        local merged=no dirty=no islive=no
        if git -C "$main" merge-base --is-ancestor "$head" "$master" 2>/dev/null; then merged=yes
        elif git -C "$main" diff --quiet "$master" "$head" 2>/dev/null; then merged=squash; fi
        [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] && dirty=yes
        echo "$live" | grep -qx "$dir" && islive=yes
        printf '%-52s %-34s %-8s %-6s %s\n' "${dir##*/}" "$branch" "$merged" "$dirty" "$islive"
        if [[ "$merged" != "no" && "$dirty" == "no" && "$islive" == "no" ]]; then
          prunable+=("$dir"); prunebranch+=("$branch")
        fi
        dir=""; head=""; branch="" ;;
    esac
  done < <(git -C "$main" worktree list --porcelain; echo "")

  local n=${#prunable[@]}
  if (( n == 0 )); then echo "\ncwclean: nothing safe to prune."; return 0; fi
  echo "\ncwclean: $n worktree(s) safe to prune (merged + clean + no live session):"
  local i; for i in {1..$n}; do echo "  - ${prunable[$i]##*/}  [${prunebranch[$i]}]"; done
  if (( ! prune )); then echo "\nRe-run 'cwclean --prune' to remove them."; return 0; fi
  read "REPLY?Remove these $n worktree(s) and delete their branches? [y/N] "
  [[ "$REPLY" == [yY] ]] || { echo "aborted."; return 0; }
  for i in {1..$n}; do
    git -C "$main" worktree remove "${prunable[$i]}" && echo "removed ${prunable[$i]##*/}"
    git -C "$main" branch -D "${prunebranch[$i]}" 2>/dev/null && echo "  deleted branch ${prunebranch[$i]}"
  done
}

# tmux() destroy-guard — issue #158.
#
# Every fleet runs its workers with --dangerously-skip-permissions on the SHARED
# `default` tmux socket. One stray `tmux kill-server` (or a kill-session /
# kill-window aimed at a sibling window) therefore takes down EVERY fleet on the
# machine at once. This wrapper blocks the common *accidental* forms. It is an
# accident rail, NOT a security boundary — bypass-perms can always `pkill tmux`
# or signal the pid directly; nothing at the shell level can stop arbitrary code.
# It only closes the everyday footguns, which is where the real crashes came from.
#
#   • kill-server                    → always refused.
#   • kill-session / kill-window     → refused unless the target is THIS worker's
#                                      own window (self-teardown is allowed).
#   • anything on an isolated server (a global -L/-S is present) → allowed: that
#                                      is exactly the safe testing convention.
#   • FLEET_ALLOW_TMUX_DESTROY=1     → guard disabled entirely (maintenance, and
#                                      what the fleet's own scripts set if needed).
#
# Fleet scripts (fleet-down.sh, fleet-restore.sh, the selftests) are unaffected:
# a shell function is not inherited by the bash processes they run in, so they
# always reach the real tmux binary.
tmux() {
  emulate -L zsh
  # Escape hatch first — never stand between a deliberate operator and tmux.
  [[ "${FLEET_ALLOW_TMUX_DESTROY:-}" == 1 ]] && { command tmux "$@"; return; }

  local -a A=( "$@" )
  # Walk the GLOBAL options to find the subcommand; note an isolated socket
  # (-L name / -S path), which means "not the shared default server" → allowed.
  local sub="" isolated=0 i=1
  while (( i <= ${#A} )); do
    case "${A[i]}" in
      -L|-S)     isolated=1; (( i++ )) ;;   # socket value is the next token
      -L*|-S*)   isolated=1 ;;              # glued form: -Lname / -S/path/sock
      -f|-c|-T)  (( i++ )) ;;               # global opts that consume a value
      -*)        ;;                          # a boolean global flag
      *)         sub="${A[i]}"; break ;;    # the subcommand
    esac
    (( i++ ))
  done

  local dest=""
  case "$sub" in
    kill-ser*) dest=server ;;   # kill-server (prefixes: tmux accepts abbreviations)
    kill-ses*) dest=session ;;  # kill-session
    kill-w*)   dest=window ;;   # kill-window
  esac
  # Isolated server, or a subcommand we don't guard → straight through.
  if (( isolated )) || [[ -z "$dest" ]]; then command tmux "$@"; return; fi

  local hint="test on an isolated socket (tmux -L scratch …) or set FLEET_ALLOW_TMUX_DESTROY=1 to override"

  # This worker's own window — a globally-unique id like @4. Prefer the caller's
  # own pane ($TMUX_PANE) over the active pane, so the check is about THIS shell.
  local ownwin
  ownwin="$(command tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)"
  [[ -z "$ownwin" ]] && ownwin="$(command tmux display-message -p '#{window_id}' 2>/dev/null)"

  # Parse the subcommand's target (-t) and the "all but current" flag (-a).
  local target="" allbut=0 j=$(( i + 1 ))
  while (( j <= ${#A} )); do
    case "${A[j]}" in
      -t)   target="${A[j+1]}"; (( j++ )) ;;
      -t*)  target="${A[j]#-t}" ;;
      -a)   allbut=1 ;;
    esac
    (( j++ ))
  done

  # kill-server, or a `-a` (all-but-current) sweep, always hits siblings.
  if [[ "$dest" == server ]] || (( allbut )); then
    print -ru2 -- "tmux: refusing '$sub' on the shared fleet server — it can take down every fleet. $hint"
    return 1
  fi

  if [[ "$dest" == window ]]; then
    local tw
    if [[ -z "$target" ]]; then tw="$ownwin"   # default target = the current window
    else tw="$(command tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null)"; fi
    if [[ -n "$ownwin" && "$tw" == "$ownwin" ]]; then command tmux "$@"; return; fi
    print -ru2 -- "tmux: refusing to kill-window '${target:-current}' — not this worker's own window. $hint"
    return 1
  fi

  # dest == session: only self-teardown is OK, i.e. the target session holds just
  # this one window. Anything larger would take sibling workers (or the hub) down.
  local sess
  if [[ -n "$target" ]]; then sess="$target"
  else sess="$(command tmux display-message -p -t "${TMUX_PANE:-}" '#{session_id}' 2>/dev/null)"; fi
  local -a wins
  wins=( ${(f)"$(command tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null)"} )
  if [[ -n "$ownwin" && ${#wins} -eq 1 && "${wins[1]}" == "$ownwin" ]]; then command tmux "$@"; return; fi
  print -ru2 -- "tmux: refusing kill-session '${target:-current}' — it would kill sibling fleet windows. $hint"
  return 1
}
