#!/bin/bash
# tmux-config.sh — prefix+c CONFIG MODAL: view + edit this fleet's config across
# both layers (per-fleet overlay ▸ global ▸ default), mirroring the prefix+G dash
# and prefix+b backlog fzf popups (issues #83, #89).
#
# Rows are DECLARATIVELY driven by the @label/@group/@tier/@scope/@edit/@unit
# tags in fleet.conf.example (parsed via fleet-config-lib.sh) — there is no
# hardcoded key list here. Each key shows its FRIENDLY LABEL, effective value,
# and TWO text tags: the allowed write scope (dim `locked` identity view-only ·
# blue `global`-only · green `fleet` per-fleet overridable) and the layer the
# effective value came from (green ▸ per-fleet · blue · global · dim default).
# Scope is carried by color + a short aligned word, not by emoji. Rows are
# grouped common-first;
# Advanced / Global-only-advanced / Identity sit behind Tab-expandable headers.
# `?` reveals the raw FLEET_* key inline; ⌃s toggles which layer a per-fleet edit
# WRITES to; enter on an editable key edits it, on a section header expands it.
#
# enter mirrors the ⌃s abort→act→relaunch pattern rather than nesting a popup:
# a `transform` bind (emit_enter_action) branches on the row type — a section
# header toggles in place, an editable FLEET_* key is stashed in a sentinel and
# fzf `abort`s so the outer loop runs bin/dash-config-edit.sh in the GAP between
# fzf runs (no popup-inside-a-popup, the #122 bug) then relaunches the modal,
# and an identity/view-only key refuses on the status line (modal stays open).
#
# Dispatch (re-invoked by the fzf binds):
#   tmux-config.sh                 → the fzf loop (run under `tmux display-popup -E`)
#   tmux-config.sh rows            → emit the fzf rows (FIELD1<US>colored display)
#   tmux-config.sh preview KEY     → the detail/preview pane for one key
#   tmux-config.sh enter-action K S Q QRY → emit the fzf action(s) for enter on K
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
CFG_STATE_DIR="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/global"
raw_file()   { printf '%s/config_raw_%s' "$CFG_STATE_DIR" "${SESSION:-_}"; }
raw_on()     { [ -f "$(raw_file)" ]; }
raw_toggle() { local f; f=$(raw_file); if [ -f "$f" ]; then rm -f "$f"; else mkdir -p "$CFG_STATE_DIR" 2>/dev/null; : > "$f"; fi; }
exp_file()   { printf '%s/config_exp_%s' "$CFG_STATE_DIR" "${SESSION:-_}"; }
exp_has()    { grep -qxF "$1" "$(exp_file)" 2>/dev/null; }
exp_toggle() {
  local b="$1" f tmp; f=$(exp_file); mkdir -p "$CFG_STATE_DIR" 2>/dev/null
  if grep -qxF "$b" "$f" 2>/dev/null; then
    # grep -v exits 1 when it filters out the ONLY line (empty output) — that is
    # success here, not failure, so don't gate the mv on its status or collapsing
    # the last-open section would silently no-op.
    tmp="$f.tmp.$$"; { grep -vxF "$b" "$f" 2>/dev/null || true; } > "$tmp" && mv "$tmp" "$f"
  else
    printf '%s\n' "$b" >> "$f"
  fi
}

# ---- one key row from pre-parsed fields (label/scope/unit/default) -----------
# FIELD1=KEY (binds — {1} in the fzf actions) · FIELD2=colored "label value scope
# source" (both the display AND the search scope — fzf searches the --with-nth=2
# field) · FIELD3=KEY (legacy; kept so {1}/parsing stay stable). fzf is run with
# --with-nth=2 and NO --nth: modern fzf (≥~0.38) interprets --nth relative to the
# --with-nth output, so the old `--nth=2,3` referenced fields that no longer exist
# and silently matched NOTHING (every filter came up empty). Searching the visible
# field2 works on every fzf version; the raw FLEET_* key is still searchable via
# the `?` raw-key toggle, which appends it to field2. RCONF_F/RCONF_G are set once
# by emit_rows so the effective-value lookup only greps the two (small) confs.
# Layout: label · value · scope-tag · source-layer, each in a fixed-width column
# so the eye scans straight down. Scope is a short word (locked/global/fleet)
# colored by CFG_* — color carries the emphasis emoji used to. The tag + markers
# are pure ASCII, so `printf %-Ns` byte-padding == cell-width here: alignment holds
# with no wcwidth pass needed (unlike the old 2-cell emoji that broke column math).
render_row() {
  local key="$1" label="$2" scope="$3" unit="$4" def="$5"
  local stag scol col src srcmark val v lf vf tf sf raw disp
  case "$scope" in
    identity) stag='locked'; scol="$CFG_DIM"    ;;
    global)   stag='global'; scol="$CFG_GLOBAL" ;;
    *)        stag='fleet';  scol="$CFG_FLEET"  ;;
  esac
  if   v=$(fcfg_file_value "$RCONF_F" "$key"); then val="$v"; src=fleet
  elif v=$(fcfg_file_value "$RCONF_G" "$key"); then val="$v"; src=global
  else val="$def"; src=default
  fi
  case "$src" in
    fleet)  col="$CFG_FLEET";  srcmark='▸ per-fleet' ;;
    global) col="$CFG_GLOBAL"; srcmark='· global' ;;
    *)      col="$CFG_DIM";    srcmark='  default' ;;
  esac
  if [ -n "$val" ]; then [ -n "$unit" ] && val="$val $unit"; else val='(empty)'; fi
  lf=$(printf '%-30s' "$(printf '%.30s' "$label")")
  vf=$(printf '%-22s' "$(printf '%.20s' "$val")")
  tf=$(printf '%-6s' "$stag")
  sf=$(printf '%-11s' "$srcmark")
  raw=''; raw_on && raw="  $CFG_DIM$key$CFG_R"
  disp="$CFG_KEY$lf$CFG_R $CFG_TX$vf$CFG_R $scol$tf$CFG_R $col$sf$CFG_R$raw"
  printf '%s%s%s%s%s\n' "$key" "$US" "$disp" "$US" "$key"
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
  local bid="$1" name="$2" t="$3" n key label group tier scope edit unit def
  n=$(printf '%s' "$t" | grep -c .)
  [ "$n" -gt 0 ] || return 0
  emit_toggle "$bid" "$name" "$n"
  exp_has "$bid" || return 0
  printf '%s' "$t" | while IFS="$US" read -r key label group tier scope edit unit def; do
    [ -n "$key" ] && render_row "$key" "$label" "$scope" "$unit" "$def"
  done
}

# ---- rows: context header · common (grouped) · collapsible buckets ----------
# One awk pass (fcfg_table) parses the example into label/group/tier/scope/edit/
# unit/default records; everything below works from those in-memory records, so
# a render no longer re-parses the file per key.
emit_rows() {
  local key label group tier scope edit unit def og
  local common_t='' adv_t='' gadv_t='' id_t='' order='' line
  RCONF_F=$(fcfg_fleet_conf "$SESSION"); RCONF_G=$(fcfg_global_conf)
  while IFS="$US" read -r key label group tier scope edit unit def; do
    [ -n "$key" ] || continue
    line="$key$US$label$US$group$US$tier$US$scope$US$edit$US$unit$US$def"
    if [ "$scope" = identity ]; then                            id_t="$id_t$line
"
    elif [ "$tier" = advanced ] && [ "$scope" = global ]; then  gadv_t="$gadv_t$line
"
    elif [ "$tier" = advanced ]; then                           adv_t="$adv_t$line
"
    else
      common_t="$common_t$line
"
      case "$US$order$US" in *"$US$group$US"*) : ;; *) order="${order:+$order$US}$group" ;; esac
    fi
  done <<EOF
$(fcfg_table)
EOF

  emit_context

  # common section, grouped by @group in first-appearance order
  local oIFS="$IFS"; IFS="$US"; set -- $order; IFS="$oIFS"
  for og in "$@"; do
    emit_subheader "$og"
    printf '%s' "$common_t" | while IFS="$US" read -r key label group tier scope edit unit def; do
      [ -n "$key" ] || continue
      [ "$group" = "$og" ] && render_row "$key" "$label" "$scope" "$unit" "$def"
    done
  done

  emit_spacer
  emit_bucket advanced   "ADVANCED"               "$adv_t"
  emit_bucket global-adv "GLOBAL-ONLY · ADVANCED"  "$gadv_t"
  emit_bucket identity   "IDENTITY (locked)"       "$id_t"
}

# ---- preview: the detail pane for one key -----------------------------------
emit_preview() {
  local key="${1:-}" B="$CFG_B" R="$CFG_R" DIM="$CFG_DIM" GN="$CFG_FLEET" BL="$CFG_GLOBAL"
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
    identity) printf '  %slocked%s — identity, view-only; set in fleet.conf and re-provision.\n' "$DIM" "$R" ;;
    global)   printf '  %s%sglobal%s — global-only; writes fleet.conf; applies to ALL fleets.\n' "$B" "$BL" "$R" ;;
    *)        printf '  %s%sfleet%s — per-fleet; g writes the global default, f this fleet'\''s overlay.\n' "$B" "$GN" "$R" ;;
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
    printf '\n  %senter writes the GLOBAL layer%s\n  %s%s%s\n' "$B" "$R" "$DIM" "$gconf" "$R"
  else
    ws=$(fcfg_wscope "$SESSION"); tgt=$(fcfg_target_conf "$SESSION" "$ws")
    printf '\n  %senter edits the %s layer%s\n  %s%s%s\n' \
      "$B" "$(printf '%s' "$ws" | tr '[:lower:]' '[:upper:]')" "$R" \
      "$DIM" "${tgt:-<not in a fleet — global only>}" "$R"
  fi
}

# ---- enter dispatch: emit the fzf action(s) for the enter key ---------------
# Called from the `enter:transform(...)` bind with the current FIELD1 ($key), the
# edit-sentinel + saved-query paths ($sentinel/$qfile, baked into the bind so the
# parent loop and this child agree), and the live filter query ($q).
# Mirrors dash-enter.sh: does the side-effect here, prints fzf actions to stdout.
#   @@TOGGLE@@ header → expand/collapse in place (reload).
#   FLEET_* key       → stash key (+ current filter query) and `abort`; the outer
#                       loop runs dash-config-edit.sh in the gap, then relaunches
#                       with the query restored. Identity/view-only keys route the
#                       same way — dash-config-edit.sh refuses them *visibly* in the
#                       popup (a status-line message would be hidden behind it), so
#                       don't special-case them here.
#   @@NOOP@@ / blank  → nothing.
# The `abort` is gated on the sentinel write SUCCEEDING: on a full/read-only volume
# an unguarded abort would drop fzf with no sentinel and no restart, silently
# closing the whole modal instead of editing. On failure we keep the modal open
# and report on the status line.
emit_enter_action() {
  local key="${1:-}" sentinel="${2:-}" qfile="${3:-}" q="${4:-}"
  case "$key" in
    @@TOGGLE@@*)
      exp_toggle "${key#@@TOGGLE@@}"
      printf 'reload(bash %s rows)' "$SELF" ;;
    FLEET_[A-Z0-9_]*)
      if [ -n "$sentinel" ] && printf '%s' "$key" > "$sentinel" 2>/dev/null; then
        [ -n "$qfile" ] && printf '%s' "$q" > "$qfile" 2>/dev/null
        printf 'abort'
      else
        tmux display-message "config: could not stage an edit for $key (full/read-only volume?)" 2>/dev/null || true
      fi ;;
    *) : ;;
  esac
}

case "${1:-loop}" in
  rows)         emit_rows; exit 0 ;;
  preview)      emit_preview "${2:-}"; exit 0 ;;
  enter-action) emit_enter_action "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit 0 ;;
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
# enter on a key stashes it here + aborts fzf; the loop reads it and runs the edit
# in the gap, then relaunches with the filter query restored (config_query_*).
# Baked into the enter bind so the transform child writes the SAME paths the parent
# loop reads (like $RESTART). mkdir the dir up front so the writes can't fail for a
# missing parent (see the guarded abort in emit_enter_action).
CGLOB="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/global"
RESTART="$CGLOB/config_restart_${SESSION:-_}.$$"
EDITKEY="$CGLOB/config_edit_${SESSION:-_}.$$"
QUERYF="$CGLOB/config_query_${SESSION:-_}.$$"
mkdir -p "$CGLOB" 2>/dev/null || true
run_fzf() {
  # Restore the filter query the edit path stashed (empty on a fresh open / ⌃s),
  # then clear the one-shot sentinels for this run.
  local savedq=''; [ -f "$QUERYF" ] && savedq=$(cat "$QUERYF" 2>/dev/null)
  rm -f "$RESTART" "$EDITKEY" "$QUERYF"
  local scope; scope=$(fcfg_wscope "$SESSION" | tr '[:lower:]' '[:upper:]')
  bash "$SELF" rows | fzf --ansi --delimiter="$FCFG_US" --with-nth=2 \
    --no-sort --layout=reverse-list --info=hidden --border=rounded \
    --query="$savedq" \
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
    --bind "enter:transform(bash $SELF enter-action {1} '$EDITKEY' '$QUERYF' {q})" \
    >/dev/null 2>&1
}
while :; do
  run_fzf || true
  # A key stashed itself + aborted fzf: run the edit here, in the gap between fzf
  # runs (a plain interactive prompt in this same display-popup pty — NOT a nested
  # popup), then relaunch the modal so it reflects the new value (query restored).
  if [ -f "$EDITKEY" ]; then
    ekey=$(cat "$EDITKEY" 2>/dev/null); rm -f "$EDITKEY"
    [ -n "$ekey" ] && bash "$BIN/dash-config-edit.sh" "$ekey"
    continue
  fi
  [ -f "$RESTART" ] || break
done
rm -f "$RESTART" "$EDITKEY" "$QUERYF"
exit 0
