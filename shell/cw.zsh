# cw.zsh — worktree-per-session helpers. Source from ~/.zshrc:
#   source ~/.claude/fleet/shell/cw.zsh
#
# cw <branch> [window-name]  — create a worktree + tmux window running claude
# cwrm <branch>              — remove a worktree + its branch
# cwclean [--prune]          — audit worktrees; --prune removes merged+clean+idle ones
# cf [<owner/repo>] [dir]    — bring up a fleet (no args = infer from this checkout)

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
