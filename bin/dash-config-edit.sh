#!/bin/bash
# dash-config-edit.sh <KEY> [confirm] — edit one FLEET_* key from the prefix+c
# config modal (bin/tmux-config.sh). Mirrors dash-issue-comment.sh's two-phase
# popup: phase 1 opens a small input popup; phase 2 (inside it) shows context,
# reads one line, validates by @edit type, and writes to the routed conf.
#
# Scope routing (issue #89), from the key's @scope tag:
#   identity → REFUSED (view-only; set in fleet.conf and re-provision).
#   global   → always writes the global fleet.conf (the g/f write-scope toggle
#              is ignored — a global-only key can't land in a per-fleet overlay).
#   fleet    → follows the modal's write-scope toggle (global fleet.conf ⇄ the
#              per-fleet <session>.conf), backing up first.
set -uo pipefail
KEY="${1:-}"; MODE="${2:-}"
case "$KEY" in FLEET_[A-Z0-9_]*) : ;; *) exit 0 ;; esac   # ignore blank/junk/header rows
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-config-lib.sh"

SESSION=$(fleet_current_session)
KSCOPE=$(fcfg_scope "$KEY")     # identity | global | fleet (from the @scope tag)
EDIT=$(fcfg_edit "$KEY")        # no | bool | int | enum | path | str | regex

# --- scope routing ----------------------------------------------------------
# Identity keys are view-only — refuse before opening any popup.
if [ "$KSCOPE" = identity ] || [ "$EDIT" = no ]; then
  tmux display-message "config: $KEY is an identity key — set it in fleet.conf and re-provision" 2>/dev/null || true
  exit 0
fi
# Global-only keys always write the global conf; per-fleet keys follow the toggle.
if [ "$KSCOPE" = global ]; then
  SCOPE=global
else
  SCOPE=$(fcfg_wscope "$SESSION")
fi
TARGET=$(fcfg_target_conf "$SESSION" "$SCOPE")

if [ -z "$TARGET" ]; then
  tmux display-message "config: no per-fleet conf here (not in a fleet) — press ⌃s to write GLOBAL" 2>/dev/null || true
  exit 0
fi

# phase 1: pop the input dialog, which re-invokes us in confirm mode.
if [ "$MODE" != confirm ]; then
  tmux display-popup -w 88 -h 18 -E "bash '$BIN/dash-config-edit.sh' '$KEY' confirm"
  exit 0
fi

# phase 2: inside the popup — show context, read one line, validate, write.
cur=$(fcfg_file_value "$TARGET" "$KEY" || true)
ev=$(fcfg_effective "$KEY" "$SESSION"); effval=${ev%"$FCFG_US"*}; effsrc=${ev##*"$FCFG_US"}
scope_up=$(printf '%s' "$SCOPE" | tr '[:lower:]' '[:upper:]')

printf '\n  \033[1m%s\033[0m  [%s]   →  writing to the \033[1m%s\033[0m layer\n' "$(fcfg_label "$KEY")" "$EDIT" "$scope_up"
printf '  \033[38;2;86;95;137m%s  ·  %s\033[0m\n' "$KEY" "$(fcfg_short "$KEY")"
printf '\n  effective now : %s  (%s)\n' "${effval:-<empty>}" "$effsrc"
printf '  in this layer : %s\n' "${cur:-<unset here>}"
case "$EDIT" in
  bool)  printf '  valid input   : 0 or 1\n' ;;
  int)   printf '  valid input   : a non-negative integer\n' ;;
  enum)  printf "  valid input   : opus | sonnet | haiku | opusplan | default | claude-* | - (set empty, defer to default)\n" ;;
  regex) printf "  valid input   : a valid extended regex (no double-quotes, backticks, or \$(…)) · - = set empty\n" ;;
  path)  printf "  valid input   : a path (\$HOME/\${VAR} ok; no double-quotes, backticks, or \$(…)) · - = set empty\n" ;;
  *)     printf "  valid input   : free text (no double-quotes, backticks, or \$(…)) · - = set empty\n" ;;
esac
# Bare empty input cancels (the standard for these popups); a lone '-' is the
# explicit "set this key empty" sentinel — enums/strings document empty as a
# real, meaningful value ("defer to the default"), which bare-empty can't express.
printf '\n  new value  (empty = cancel · - = set empty) ▸ '
IFS= read -r val
[ -n "$val" ] || exit 0
[ "$val" = '-' ] && val=''

if ! reason=$(fcfg_validate "$EDIT" "$val" "$KEY"); then
  printf '\n  \033[31m✗ rejected:\033[0m %s\n  (nothing written — press any key)' "$reason"
  read -rsn1 _ || true
  exit 0
fi

if ! status=$(fcfg_write "$TARGET" "$KEY" "$val" "$EDIT"); then
  printf '\n  \033[31m✗ write failed\033[0m — %s is not writable (full/read-only volume?)\n  (nothing changed — press any key)' "$TARGET"
  read -rsn1 _ || true
  tmux display-message "config: write to ${TARGET##*/} FAILED — nothing changed" 2>/dev/null || true
  exit 0
fi
show=${val:-(empty)}
if [ "$status" = created ]; then
  printf '\n  \033[32m✓ created\033[0m %s and set \033[1m%s = %s\033[0m\n  %s\n' "$TARGET" "$KEY" "$show" "$TARGET"
  tmux display-message "config: created ${TARGET##*/} and set $KEY=$show" 2>/dev/null || true
else
  printf '\n  \033[32m✓ wrote\033[0m \033[1m%s = %s\033[0m to the %s layer (backup: %s.bak)\n  %s\n' "$KEY" "$show" "$SCOPE" "${TARGET##*/}" "$TARGET"
  tmux display-message "config: set $KEY=$show ($SCOPE) — backup ${TARGET##*/}.bak" 2>/dev/null || true
fi
sleep 0.8
exit 0
