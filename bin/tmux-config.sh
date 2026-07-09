#!/bin/bash
# tmux-config.sh — prefix+c CONFIG MODAL: view + edit this fleet's config across
# both layers (per-fleet overlay ▸ global ▸ default), mirroring the prefix+j dash
# and prefix+b backlog fzf popups (issue #83).
#
# Each row is one FLEET_* key with its EFFECTIVE value and the LAYER that set it
# (green ▸ per-fleet overlay · blue global · dim default). ⌃s toggles which layer
# an edit WRITES to (global fleet.conf ⇄ per-fleet <session>.conf); enter edits
# the highlighted key at that scope (bin/dash-config-edit.sh validates + writes,
# backing up first). The key list + per-key help come from fleet.conf.example.
#
# Dispatch (re-invoked by the fzf binds):
#   tmux-config.sh              → the fzf loop (run under `tmux display-popup -E`)
#   tmux-config.sh rows         → emit the fzf rows (KEY<US>colored display)
#   tmux-config.sh preview KEY  → the detail/preview pane for one key
#   tmux-config.sh toggle-scope → flip the write scope, then reload
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SELF="$BIN/$(basename "$0")"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-config-lib.sh"

SESSION=$(fleet_current_session)
# Outside a fleet (no session ⇒ no per-fleet conf) only the global layer is
# writable — pin the scope there so an edit can't dead-end.
[ -n "$SESSION" ] || fcfg_scope_set "" global

# Shared palette (Tokyo Night) — one definition for rows + preview so the
# per-layer colors can never drift between the two panes.
CFG_R=$'\033[0m'; CFG_B=$'\033[1m'
CFG_KEY=$'\033[38;2;125;207;255m'     # cyan   — key name
CFG_TX=$'\033[38;2;169;177;214m'      # text   — value
CFG_FLEET=$'\033[38;2;158;206;106m'   # green  — per-fleet overlay wins
CFG_GLOBAL=$'\033[38;2;122;162;247m'  # blue   — inherited from global
CFG_DIM=$'\033[38;2;86;95;137m'       # dim    — unset → code default

# ---- rows: one line per key (field1=KEY, field2=colored display) ------------
emit_rows() {
  local key ev val src col mark kf vf US="$FCFG_US"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ev=$(fcfg_effective "$key" "$SESSION"); val=${ev%"$US"*}; src=${ev##*"$US"}
    case "$src" in
      fleet)  col="$CFG_FLEET";  mark='▸ per-fleet' ;;
      global) col="$CFG_GLOBAL"; mark='· global' ;;
      *)      col="$CFG_DIM";    mark='  default' ;;
    esac
    [ -n "$val" ] || val='(empty)'
    kf=$(printf '%-27s' "$key")
    vf=$(printf '%-42s' "$(printf '%.40s' "$val")")
    printf '%s%s%s%s%s %s%s%s %s%s%s\n' \
      "$key" "$US" "$CFG_KEY" "$kf" "$CFG_R" "$CFG_TX" "$vf" "$CFG_R" "$col" "$mark" "$CFG_R"
  done < <(fcfg_keys)
}

# ---- preview: the detail pane for one key -----------------------------------
emit_preview() {
  local key="${1:-}" B="$CFG_B" R="$CFG_R" DIM="$CFG_DIM" GN="$CFG_FLEET"
  [ -n "$key" ] || { printf '  (select a key)\n'; return; }
  local type dv ev val src scope tgt fconf gconf fv gv
  type=$(fcfg_type "$key")
  dv=$(fcfg_default "$key")
  fconf=$(fcfg_fleet_conf "$SESSION"); gconf=$(fcfg_global_conf)
  ev=$(fcfg_effective "$key" "$SESSION"); val=${ev%"$FCFG_US"*}; src=${ev##*"$FCFG_US"}
  printf '%s%s%s   %s[%s]%s\n\n' "$B" "$key" "$R" "$DIM" "$type" "$R"
  fcfg_full "$key" | sed 's/^/  /'
  printf '\n  %s────────%s\n' "$DIM" "$R"
  printf '  %seffective%s : %s%s%s   %s(%s)%s\n' "$B" "$R" "$GN" "${val:-<empty>}" "$R" "$DIM" "$src" "$R"
  printf '  %sdefault%s   : %s\n' "$DIM" "$R" "${dv:-<empty>}"
  if fv=$(fcfg_file_value "$fconf" "$key"); then printf '  per-fleet : %s\n' "$fv"
  else printf '  %sper-fleet : (unset)%s\n' "$DIM" "$R"; fi
  if gv=$(fcfg_file_value "$gconf" "$key"); then printf '  global    : %s\n' "$gv"
  else printf '  %sglobal    : (unset)%s\n' "$DIM" "$R"; fi
  scope=$(fcfg_scope "$SESSION"); tgt=$(fcfg_target_conf "$SESSION" "$scope")
  printf '\n  %s✎ enter edits the %s layer%s\n  %s%s%s\n' \
    "$B" "$(printf '%s' "$scope" | tr '[:lower:]' '[:upper:]')" "$R" \
    "$DIM" "${tgt:-<not in a fleet — global only>}" "$R"
}

case "${1:-loop}" in
  rows)         emit_rows; exit 0 ;;
  preview)      emit_preview "${2:-}"; exit 0 ;;
  toggle-scope) fcfg_scope_toggle "$SESSION"
                tmux display-message "config: edits now write to the $(fcfg_scope "$SESSION" | tr '[:lower:]' '[:upper:]') layer" 2>/dev/null || true
                exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf required for the prefix+c config modal"; sleep 3; exit 1; }
[ -f "$(fcfg_example)" ] || { echo "fleet.conf.example not found — cannot build the config modal"; sleep 3; exit 1; }

# ⌃s toggles scope; to re-render the border-label + preview with the new scope we
# drop a restart sentinel and abort fzf — the outer loop relaunches. esc leaves
# no sentinel, so it exits. enter edits in place and reload-refreshes (stays open).
RESTART="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/config_restart_${SESSION:-_}.$$"
run_fzf() {
  rm -f "$RESTART"
  local scope; scope=$(fcfg_scope "$SESSION" | tr '[:lower:]' '[:upper:]')
  bash "$SELF" rows | fzf --ansi --delimiter="$FCFG_US" --with-nth=2 --nth=2 \
    --no-sort --layout=reverse-list --info=hidden --border=rounded \
    --border-label=" fleet config · edits write to the $scope layer " --border-label-pos=3 \
    --prompt='filter ▸ ' \
    --header='enter=edit · ⌃s=toggle scope (global⇄per-fleet) · ⌃p=preview · ⌃r=refresh · esc' \
    --preview "bash $SELF preview {1}" \
    --preview-window='right,54%,wrap,border-left' \
    --bind "ctrl-r:reload(bash $SELF rows)" \
    --bind "ctrl-p:toggle-preview" \
    --bind "ctrl-s:execute-silent(bash $SELF toggle-scope; : > '$RESTART')+abort" \
    --bind "enter:execute(bash $BIN/dash-config-edit.sh {1})+reload(bash $SELF rows)+refresh-preview" \
    >/dev/null 2>&1
}
while :; do
  run_fzf || true
  [ -f "$RESTART" ] || break
done
rm -f "$RESTART"
exit 0
