#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code status line — reads JSON from stdin, outputs a single coloured line.
#
# Fields used (from documented Claude Code schema):
#   .workspace.current_dir  — current working directory
#   .cwd                    — fallback CWD
#   .model.display_name     — human-readable model name
#   .context_window.used_percentage  — % of context window consumed (null before first message)
#
# Git commands use --no-optional-locks to avoid touching lock files.
# Requires: jq  (silently exits if absent)

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)

# ── ANSI colour constants ────────────────────────────────────────────────────
RESET=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
MAGENTA=$'\033[35m'

SEP="${DIM} │ ${RESET}"   # dim vertical bar as segment separator

SEGMENTS=()

# ── 1. Context usage % ───────────────────────────────────────────────────────
# .context_window.used_percentage is pre-calculated (0-100); null before first message.
CTX_PCT=$(jq -r '.context_window.used_percentage // ""' <<< "$INPUT")

if [[ -n "$CTX_PCT" ]]; then
  CTX_INT=$(printf '%.0f' "$CTX_PCT")
  if   (( CTX_INT >= 80 )); then CTX_COLOR="$RED"
  elif (( CTX_INT >= 50 )); then CTX_COLOR="$YELLOW"
  else                            CTX_COLOR="$GREEN"
  fi
  # Build a mini bar (10 chars wide)
  FILLED=$(( CTX_INT / 10 ))
  BAR=""
  for (( i=0; i<10; i++ )); do
    if (( i < FILLED )); then BAR="${BAR}█"; else BAR="${BAR}░"; fi
  done
  SEGMENTS+=("${CTX_COLOR}${BAR} ${CTX_INT}%${RESET}")
fi

# ── 2. Current working directory ─────────────────────────────────────────────
CWD_RAW=$(jq -r '.workspace.current_dir // .cwd // ""' <<< "$INPUT")

if [[ -n "$CWD_RAW" ]]; then
  # Replace $HOME prefix with ~
  CWD_DISPLAY="${CWD_RAW/#$HOME/~}"

  # Shorten very deep paths: keep last two components, prefix with …
  # Count slash depth below $HOME
  STRIPPED="${CWD_RAW/#$HOME/}"
  DEPTH=$(awk -F'/' '{print NF-1}' <<< "$STRIPPED")
  if (( DEPTH > 3 )); then
    PARENT=$(basename "$(dirname "$CWD_RAW")")
    BASE=$(basename "$CWD_RAW")
    CWD_DISPLAY="…/${PARENT}/${BASE}"
  fi

  SEGMENTS+=("${BOLD}${CYAN}${CWD_DISPLAY}${RESET}")
fi

# ── 3. Git branch + dirty indicator ──────────────────────────────────────────
if [[ -n "$CWD_RAW" ]] && command -v git &>/dev/null; then
  GIT_BRANCH=$(git -C "$CWD_RAW" --no-optional-locks \
                 rev-parse --abbrev-ref HEAD 2>/dev/null || true)

  if [[ -n "$GIT_BRANCH" && "$GIT_BRANCH" != "HEAD" ]]; then
    GIT_DIRTY=""
    git -C "$CWD_RAW" --no-optional-locks diff --quiet          2>/dev/null || GIT_DIRTY="*"
    git -C "$CWD_RAW" --no-optional-locks diff --cached --quiet 2>/dev/null || GIT_DIRTY="*"

    if [[ -n "$GIT_DIRTY" ]]; then
      SEGMENTS+=("${YELLOW}${GIT_BRANCH}${GIT_DIRTY}${RESET}")
    else
      SEGMENTS+=("${GREEN}${GIT_BRANCH}${RESET}")
    fi
  fi
fi

# ── 4. Model display name ─────────────────────────────────────────────────────
MODEL=$(jq -r '.model.display_name // ""' <<< "$INPUT")
if [[ -n "$MODEL" ]]; then
  SEGMENTS+=("${MAGENTA}${MODEL}${RESET}")
fi

# ── Join segments with separator and print ────────────────────────────────────
RESULT=""
for SEG in "${SEGMENTS[@]}"; do
  if [[ -n "$RESULT" ]]; then
    RESULT="${RESULT}${SEP}${SEG}"
  else
    RESULT="$SEG"
  fi
done

printf '%s\n' "$RESULT"
