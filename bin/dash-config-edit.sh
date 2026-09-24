#!/bin/bash
# dash-config-edit.sh <KEY> — edit one FLEET_* key from the prefix+c config modal
# (bin/tmux-config.sh). Runs INLINE in the modal's display-popup pty, in the gap
# between fzf runs (the modal `abort`s fzf, runs us, then relaunches) — NOT in a
# nested popup-inside-a-popup, which never opened reliably (issue #122). Shows
# context, reads one line, validates by @edit type, and writes to the routed conf.
#
# Scope routing (issues #89, #1102) — fcfg_key_wscope, from the modal's ⌃s toggle
# (THIS FLEET ⇄ a hosted REPO) and the key's @scope tag:
#   identity → REFUSED (view-only; set in fleet.conf and re-provision).
#   a per-repo key (fcfg_repo_keys) under a repo scope → that repo's overlay
#              (fleets/<sess>/repos/<slug>.conf; a one-repo fleet's is its conf).
#   anything else → THIS FLEET: a global-only key writes the login's
#              fleet.settings (fleet_load_conf strips it from a fleet conf), every
#              other key the fleet conf. Never refused for being in the "wrong"
#              layer, and never the install's fleet.conf — that is read-only legacy.
# Every write backs the file up first.
set -uo pipefail
KEY="${1:-}"
case "$KEY" in FLEET_[A-Z0-9_]*) : ;; *) exit 0 ;; esac   # ignore blank/junk/header rows
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-config-lib.sh"

SESSION=$(fleet_current_session)
KSCOPE=$(fcfg_scope "$KEY")     # identity | global | fleet (from the @scope tag)
EDIT=$(fcfg_edit "$KEY")        # no | bool | int | enum | path | str | regex

# We run inside the modal's popup pty (fzf aborted just before us), so clear the
# stale fzf frame up front and surface everything — refusals included — right here
# on a clean screen. A tmux display-message alone would be hidden behind the popup.
printf '\033[H\033[2J'
refuse() { printf '\n  \033[33m%s\033[0m\n' "$1"; sleep 1.4; }

# --- scope routing ----------------------------------------------------------
# Identity / view-only keys are refused here (the modal routes every FLEET_* key
# through us so the refusal is *visible* in the popup, not just on the hidden
# status line).
if [ "$KSCOPE" = identity ] || [ "$EDIT" = no ]; then
  tmux display-message "config: $KEY is an identity key — set it in fleet.conf and re-provision" 2>/dev/null || true
  refuse "$KEY is an identity key — set it in fleet.conf and re-provision."
  exit 0
fi
SCOPE=$(fcfg_key_wscope "$SESSION" "$KEY" "$KSCOPE")
REPO=''
case "$SCOPE" in repo:*) REPO=$(fcfg_scope_repo "$SESSION" "$SCOPE") ;; esac
TARGET=$(fcfg_target_conf "$SESSION" "$SCOPE")

if [ -z "$TARGET" ]; then   # defensive: a repo scope that stopped resolving mid-edit
  tmux display-message "config: no conf to write $KEY to — nothing changed" 2>/dev/null || true
  refuse "no conf to write $KEY to — nothing changed."
  exit 0
fi

# Show context, read one line, validate, write.
cur=$(fcfg_file_value "$TARGET" "$KEY" || true)
if [ -n "$REPO" ]; then
  ev=$(fcfg_repo_effective "$KEY" "$SESSION" "$REPO"); scope_up="REPO $REPO"
else
  ev=$(fcfg_effective "$KEY" "$SESSION" "$KSCOPE"); scope_up=FLEET
fi
effval=${ev%"$FCFG_US"*}; effsrc=${ev##*"$FCFG_US"}

printf '\n  \033[1m%s\033[0m  [%s]   →  writing to the \033[1m%s\033[0m layer\n' "$(fcfg_label "$KEY")" "$EDIT" "$scope_up"
printf '  \033[38;2;86;95;137m%s  ·  %s\033[0m\n' "$KEY" "$(fcfg_short "$KEY")"
printf '\n  effective now : %s  (%s)\n' "${effval:-<empty>}" "$effsrc"
printf '  in this layer : %s\n' "${cur:-<unset here>}"
# An @edit=enum key is a CHOICE, not free text (issue #415): pick it from an fzf
# menu instead of typing an alias you have to remember. The options come from the
# ONE source of truth in fleet-config-lib (fcfg_enum_options → fcfg_model_aliases
# for the model keys), the SAME data the validator accepts, so the offered set and
# the accepted set can't drift — and `fable` is finally offered. The picker runs
# full-screen in THIS popup pty (like the outer modal's own fzf), not a nested
# popup; on exit fzf restores the context above. Falls back to the free-text read
# if fzf is somehow absent (dash-config-edit run outside the fzf-gated modal).
if [ "$EDIT" = enum ] && command -v fzf >/dev/null 2>&1; then
  US="$FCFG_US"
  is_model=no; fcfg_is_model_key "$KEY" && is_model=yes
  # Field1 = the literal token (or a :sentinel:); field2 = the annotated display
  # (fzf shows + searches only field2). `:defer:` writes empty; `:custom:` (model
  # keys only) drops to the free-text read so any full claude-* id still works.
  rows=$(
    fcfg_enum_options "$KEY" | while IFS="$US" read -r tok ann; do
      printf '%s%s\033[1m%-9s\033[0m  \033[38;2;86;95;137m— %s\033[0m\n' "$tok" "$US" "$tok" "$ann"
    done
    printf '%s%s\033[36m%-9s\033[0m  \033[38;2;86;95;137m— unset (defer to the default)\033[0m\n' ':defer:' "$US" '(empty)'
    [ "$is_model" = yes ] && \
      printf '%s%s\033[36m%-9s\033[0m  \033[38;2;86;95;137m— type a full claude-* id\033[0m\n' ':custom:' "$US" 'custom…'
  )
  sel=$(printf '%s\n' "$rows" | fzf --ansi --delimiter="$US" --with-nth=2 \
          --no-sort --layout=reverse-list --info=hidden --border=rounded \
          --border-label=" pick $(fcfg_label "$KEY") → $scope_up layer " --border-label-pos=3 \
          --prompt='choose ▸ ' \
          --header="effective now: ${effval:-<empty>} ($effsrc)   ·   enter=choose · esc=cancel") \
        || exit 0                                # esc / no selection = cancel
  tok=${sel%%"$US"*}
  case "$tok" in
    ':defer:')  val='' ;;
    ':custom:')
      printf '\n  full model id  (empty = cancel · - = set empty) ▸ '
      IFS= read -r val
      [ -n "$val" ] || exit 0
      [ "$val" = '-' ] && val='' ;;
    '')  exit 0 ;;                               # defensive: empty selection = cancel
    *)   val="$tok" ;;
  esac
else
  case "$EDIT" in
    bool)  printf '  valid input   : 0 or 1\n' ;;
    int)   printf '  valid input   : a non-negative integer\n' ;;
    enum)  printf "  valid input   : one of the documented values (see the config preview) · - (set empty, defer to default)\n" ;;
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
fi

if ! reason=$(fcfg_validate "$EDIT" "$val" "$KEY"); then
  printf '\n  \033[31m✗ rejected:\033[0m %s\n  (nothing written — press any key)' "$reason"
  read -rsn1 _ || true
  exit 0
fi

if [ -n "$REPO" ]; then
  wstatus=$(fcfg_repo_write "$SESSION" "${SCOPE#repo:}" "$KEY" "$val" "$EDIT"); wrc=$?
else
  wstatus=$(fcfg_write "$TARGET" "$KEY" "$val" "$EDIT"); wrc=$?
fi
if [ "$wrc" -ne 0 ]; then
  printf '\n  \033[31m✗ write failed\033[0m — %s is not writable (full/read-only volume?)\n  (nothing changed — press any key)' "$TARGET"
  read -rsn1 _ || true
  tmux display-message "config: write to ${TARGET##*/} FAILED — nothing changed" 2>/dev/null || true
  exit 0
fi
show=${val:-(empty)}
if [ "$wstatus" = created ]; then
  printf '\n  \033[32m✓ created\033[0m %s and set \033[1m%s = %s\033[0m\n  %s\n' "$TARGET" "$KEY" "$show" "$TARGET"
  tmux display-message "config: created ${TARGET##*/} and set $KEY=$show" 2>/dev/null || true
else
  printf '\n  \033[32m✓ wrote\033[0m \033[1m%s = %s\033[0m to the %s layer (backup: %s.bak)\n  %s\n' "$KEY" "$show" "$scope_up" "${TARGET##*/}" "$TARGET"
  tmux display-message "config: set $KEY=$show ($scope_up) — backup ${TARGET##*/}.bak" 2>/dev/null || true
fi
sleep 0.8
exit 0
