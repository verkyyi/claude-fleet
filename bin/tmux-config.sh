#!/bin/bash
# tmux-config.sh — prefix+c CONFIG MODAL: view + edit this fleet's config across
# both layers (per-fleet overlay ▸ global ▸ default), mirroring the prefix+j dash
# and prefix+b backlog fzf popups (issues #83, #89).
#
# Rows are DECLARATIVELY driven by the @label/@group/@tier/@scope/@edit/@unit
# tags in fleet.conf.example (parsed via fleet-config-lib.sh) — there is no
# hardcoded key list here. Each key shows its FRIENDLY LABEL, effective value,
# and TWO markers: the allowed write scope (🔒 identity view-only · 🌐 global-only
# · 🎚 per-fleet overridable) and the layer the effective value came from (green
# ▸ per-fleet · blue · global · dim default). Rows are grouped common-first;
# Advanced / Global-only-advanced / Identity sit behind Tab-expandable headers.
# `?` reveals the raw FLEET_* key inline; ⌃s toggles which layer a per-fleet edit
# WRITES to; enter edits the highlighted key (bin/dash-config-edit.sh validates +
# writes by @edit type, backing up first, and refuses identity keys).
#
# Dispatch (re-invoked by the fzf binds):
#   tmux-config.sh                 → the fzf loop (run under `tmux display-popup -E`)
#   tmux-config.sh rows            → emit the fzf rows (FIELD1<US>colored display)
#   tmux-config.sh preview KEY     → the detail/preview pane for one key
#   tmux-config.sh toggle-scope    → flip the write scope, then reload
#   tmux-config.sh toggle-raw      → flip raw-key visibility, then reload
#   tmux-config.sh toggle-bucket F → expand/collapse a section header row
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SELF="$BIN/$(basename "$0")"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-config-lib.sh"

SESSION=$(fleet_current_session)
# Outside a fleet (no session ⇒ no per-fleet conf) only the global layer is
# writable — pin the write scope there so an edit can't dead-end.
[ -n "$SESSION" ] || fcfg_wscope_set "" global

US="$FCFG_US"

# Shared palette (Tokyo Night) — one definition for rows + preview so the
# per-layer colors can never drift between the two panes.
CFG_R=$'\033[0m'; CFG_B=$'\033[1m'
CFG_KEY=$'\033[38;2;125;207;255m'     # cyan   — label / key name
CFG_TX=$'\033[38;2;169;177;214m'      # text   — value
CFG_FLEET=$'\033[38;2;158;206;106m'   # green  — per-fleet overlay wins
CFG_GLOBAL=$'\033[38;2;122;162;247m'  # blue   — inherited from global
CFG_DIM=$'\033[38;2;86;95;137m'       # dim    — unset → code default

# ---- UI state (raw-key + section-expand toggles, persisted per session) ------
CFG_STATE_DIR="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}"
raw_file()   { printf '%s/config_raw_%s' "$CFG_STATE_DIR" "${SESSION:-_}"; }
raw_on()     { [ -f "$(raw_file)" ]; }
raw_toggle() { local f; f=$(raw_file); if [ -f "$f" ]; then rm -f "$f"; else mkdir -p "$CFG_STATE_DIR" 2>/dev/null; : > "$f"; fi; }
exp_file()   { printf '%s/config_exp_%s' "$CFG_STATE_DIR" "${SESSION:-_}"; }
exp_has()    { grep -qxF "$1" "$(exp_file)" 2>/dev/null; }
exp_toggle() {
  local b="$1" f tmp; f=$(exp_file); mkdir -p "$CFG_STATE_DIR" 2>/dev/null
  if grep -qxF "$b" "$f" 2>/dev/null; then
    tmp="$f.tmp.$$"; grep -vxF "$b" "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f"
  else
    printf '%s\n' "$b" >> "$f"
  fi
}

# ---- one key row: FIELD1=KEY, FIELD2=colored "scope label value source" ------
render_row() {
  local key="$1" ev val src col srcmark scope smark label unit lf vf sf raw
  scope=$(fcfg_scope "$key")
  case "$scope" in
    identity) smark='🔒' ;;
    global)   smark='🌐' ;;
    *)        smark='🎚' ;;
  esac
  ev=$(fcfg_effective "$key" "$SESSION"); val=${ev%"$US"*}; src=${ev##*"$US"}
  case "$src" in
    fleet)  col="$CFG_FLEET";  srcmark='▸ per-fleet' ;;
    global) col="$CFG_GLOBAL"; srcmark='· global' ;;
    *)      col="$CFG_DIM";    srcmark='  default' ;;
  esac
  if [ -n "$val" ]; then
    unit=$(fcfg_unit "$key"); [ -n "$unit" ] && val="$val $unit"
  else
    val='(empty)'
  fi
  label=$(fcfg_label "$key")
  lf=$(printf '%-30s' "$(printf '%.30s' "$label")")
  vf=$(printf '%-22s' "$(printf '%.20s' "$val")")
  sf=$(printf '%-11s' "$srcmark")
  raw=''; raw_on && raw="  $CFG_DIM$key$CFG_R"
  printf '%s%s%s %s%s%s %s%s%s %s%s%s%s\n' \
    "$key" "$US" \
    "$smark" \
    "$CFG_KEY" "$lf" "$CFG_R" \
    "$CFG_TX" "$vf" "$CFG_R" \
    "$col" "$sf" "$CFG_R" "$raw"
}

# ---- non-key rows (field1 is a sentinel the binds recognize) -----------------
emit_context() {
  local repo ws
  repo=$(fcfg_effective FLEET_REPO "$SESSION"); repo=${repo%"$US"*}
  ws=$(fcfg_wscope "$SESSION" | tr '[:lower:]' '[:upper:]')
  printf '@@NOOP@@%s%sfleet%s %s%s%s   %sedits ▸ %s · ? raw keys · tab expand%s\n' \
    "$US" "$CFG_B" "$CFG_R" "$CFG_KEY" "${repo:-<unset>}" "$CFG_R" "$CFG_DIM" "$ws" "$CFG_R"
}
emit_subheader() { printf '@@NOOP@@%s%s── %s ─%s\n' "$US" "$CFG_DIM" "$1" "$CFG_R"; }
emit_spacer()    { printf '@@NOOP@@%s\n' "$US"; }
emit_toggle() {
  local bid="$1" name="$2" n="$3" arrow
  if exp_has "$bid"; then arrow='▾'; else arrow='▸'; fi
  printf '@@TOGGLE@@%s%s%s%s %s %s(%s)%s\n' "$bid" "$US" "$CFG_B" "$arrow" "$name" "$CFG_DIM" "$n" "$CFG_R"
}
emit_bucket() {
  local bid="$1" name="$2" keys="$3" n key
  n=$(printf '%s' "$keys" | grep -c .)
  [ "$n" -gt 0 ] || return 0
  emit_toggle "$bid" "$name" "$n"
  exp_has "$bid" || return 0
  printf '%s' "$keys" | while IFS= read -r key; do [ -n "$key" ] && render_row "$key"; done
}

# ---- rows: context header · common (grouped) · collapsible buckets ----------
emit_rows() {
  local key tier scope g groups
  local common_keys='' adv_keys='' gadv_keys='' id_keys=''
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    scope=$(fcfg_scope "$key"); tier=$(fcfg_tier "$key")
    if [ "$scope" = identity ]; then                       id_keys="$id_keys$key
"
    elif [ "$tier" = advanced ] && [ "$scope" = global ]; then gadv_keys="$gadv_keys$key
"
    elif [ "$tier" = advanced ]; then                          adv_keys="$adv_keys$key
"
    else                                                       common_keys="$common_keys$key
"
    fi
  done < <(fcfg_keys)

  emit_context

  # common section, grouped by @group in first-appearance order
  groups=$(printf '%s' "$common_keys" | while IFS= read -r key; do [ -n "$key" ] && printf '%s\n' "$(fcfg_group "$key")"; done | awk 'NF && !seen[$0]++')
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    emit_subheader "$g"
    printf '%s' "$common_keys" | while IFS= read -r key; do
      [ -n "$key" ] || continue
      [ "$(fcfg_group "$key")" = "$g" ] && render_row "$key"
    done
  done <<EOF
$groups
EOF

  emit_spacer
  emit_bucket advanced   "⚙ Advanced"               "$adv_keys"
  emit_bucket global-adv "🌐 Global-only · advanced" "$gadv_keys"
  emit_bucket identity   "🔒 Identity · view-only"   "$id_keys"
}

# ---- preview: the detail pane for one key -----------------------------------
emit_preview() {
  local key="${1:-}" B="$CFG_B" R="$CFG_R" DIM="$CFG_DIM" GN="$CFG_FLEET"
  case "$key" in
    FLEET_[A-Z0-9_]*) : ;;
    @@TOGGLE@@*) printf '  %ssection%s\n\n  enter / tab expands or collapses this section.\n' "$DIM" "$R"; return ;;
    *)           printf '  %s(select a key)%s\n' "$DIM" "$R"; return ;;
  esac
  local edit label unit dv ev val src scope fconf gconf fv gv ws tgt
  edit=$(fcfg_edit "$key"); label=$(fcfg_label "$key"); unit=$(fcfg_unit "$key")
  scope=$(fcfg_scope "$key"); dv=$(fcfg_default "$key")
  fconf=$(fcfg_fleet_conf "$SESSION"); gconf=$(fcfg_global_conf)
  ev=$(fcfg_effective "$key" "$SESSION"); val=${ev%"$FCFG_US"*}; src=${ev##*"$FCFG_US"}
  printf '%s%s%s   %s[%s%s]%s\n  %s%s%s\n\n' \
    "$B" "$label" "$R" "$DIM" "$edit" "${unit:+ · $unit}" "$R" "$DIM" "$key" "$R"
  fcfg_full "$key" | sed 's/^/  /'
  printf '\n  %s────────%s\n' "$DIM" "$R"
  case "$scope" in
    identity) printf '  %s🔒 identity%s — view-only; set in fleet.conf and re-provision.\n' "$B" "$R" ;;
    global)   printf '  %s🌐 global-only%s — writes fleet.conf; applies to ALL fleets.\n' "$B" "$R" ;;
    *)        printf '  %s🎚 per-fleet%s — g writes the global default, f this fleet'\''s overlay.\n' "$B" "$R" ;;
  esac
  printf '  %seffective%s : %s%s%s   %s(%s)%s\n' "$B" "$R" "$GN" "${val:-<empty>}" "$R" "$DIM" "$src" "$R"
  printf '  %sdefault%s   : %s\n' "$DIM" "$R" "${dv:-<empty>}"
  if fv=$(fcfg_file_value "$fconf" "$key"); then printf '  per-fleet : %s\n' "$fv"
  else printf '  %sper-fleet : (unset)%s\n' "$DIM" "$R"; fi
  if gv=$(fcfg_file_value "$gconf" "$key"); then printf '  global    : %s\n' "$gv"
  else printf '  %sglobal    : (unset)%s\n' "$DIM" "$R"; fi
  if [ "$scope" = identity ]; then
    printf '\n  %senter is disabled for identity keys%s\n' "$DIM" "$R"
  elif [ "$scope" = global ]; then
    printf '\n  %s✎ enter writes the GLOBAL layer%s\n  %s%s%s\n' "$B" "$R" "$DIM" "$gconf" "$R"
  else
    ws=$(fcfg_wscope "$SESSION"); tgt=$(fcfg_target_conf "$SESSION" "$ws")
    printf '\n  %s✎ enter edits the %s layer%s\n  %s%s%s\n' \
      "$B" "$(printf '%s' "$ws" | tr '[:lower:]' '[:upper:]')" "$R" \
      "$DIM" "${tgt:-<not in a fleet — global only>}" "$R"
  fi
}

case "${1:-loop}" in
  rows)         emit_rows; exit 0 ;;
  preview)      emit_preview "${2:-}"; exit 0 ;;
  toggle-scope) fcfg_wscope_toggle "$SESSION"
                tmux display-message "config: per-fleet edits now write to the $(fcfg_wscope "$SESSION" | tr '[:lower:]' '[:upper:]') layer" 2>/dev/null || true
                exit 0 ;;
  toggle-raw)   raw_toggle; exit 0 ;;
  toggle-bucket) case "${2:-}" in @@TOGGLE@@*) exp_toggle "${2#@@TOGGLE@@}" ;; esac
                exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf required for the prefix+c config modal"; sleep 3; exit 1; }
[ -f "$(fcfg_example)" ] || { echo "fleet.conf.example not found — cannot build the config modal"; sleep 3; exit 1; }

# ⌃s toggles write scope; to re-render the border-label with the new scope we
# drop a restart sentinel and abort fzf — the outer loop relaunches. esc leaves
# no sentinel, so it exits. enter/tab/? reload in place (the modal stays open).
RESTART="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/config_restart_${SESSION:-_}.$$"
run_fzf() {
  rm -f "$RESTART"
  local scope; scope=$(fcfg_wscope "$SESSION" | tr '[:lower:]' '[:upper:]')
  bash "$SELF" rows | fzf --ansi --delimiter="$FCFG_US" --with-nth=2 --nth=2 \
    --no-sort --layout=reverse-list --info=hidden --border=rounded \
    --border-label=" fleet config · per-fleet edits write to the $scope layer " --border-label-pos=3 \
    --prompt='filter ▸ ' \
    --header='enter=edit/expand · tab=expand section · ⌃s=write-scope (global⇄per-fleet) · ?=raw keys · ⌃r=refresh · esc' \
    --preview "bash $SELF preview {1}" \
    --preview-window='right,54%,wrap,border-left' \
    --bind "ctrl-r:reload(bash $SELF rows)" \
    --bind "ctrl-p:toggle-preview" \
    --bind "ctrl-s:execute-silent(bash $SELF toggle-scope; : > '$RESTART')+abort" \
    --bind "?:execute-silent(bash $SELF toggle-raw)+reload(bash $SELF rows)" \
    --bind "tab:execute-silent(bash $SELF toggle-bucket {1})+reload(bash $SELF rows)" \
    --bind "enter:execute(bash $BIN/dash-config-edit.sh {1})+execute-silent(bash $SELF toggle-bucket {1})+reload(bash $SELF rows)+refresh-preview" \
    >/dev/null 2>&1
}
while :; do
  run_fzf || true
  [ -f "$RESTART" ] || break
done
rm -f "$RESTART"
exit 0
