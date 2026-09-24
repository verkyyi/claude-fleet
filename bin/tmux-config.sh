#!/bin/bash
# tmux-config.sh — prefix+c CONFIG MODAL: view + edit this fleet's config
# (this fleet ▸ legacy install fleet.conf ▸ default), mirroring the prefix+g dash
# and prefix+b backlog fzf popups (issues #83, #89).
#
# Rows are DECLARATIVELY driven by the @label/@group/@tier/@scope/@edit/@unit
# tags in fleet.conf.example (parsed via fleet-config-lib.sh) — there is no
# hardcoded key list here. Each key shows its FRIENDLY LABEL, effective value,
# and TWO text tags: what it is (dim `locked` identity view-only · magenta `repo`
# settable per repo · blank otherwise) and the layer the effective value came
# from (magenta ▸ repo · green ▸ fleet · blue · legacy · dim default). Scope is
# carried by color + a short aligned word, not by emoji. Rows are grouped
# common-first; Advanced / Identity sit behind Tab-expandable headers;
# the INTERNAL header (issue #1101) is the "show all" switch — collapsed, it hides
# the @tier=internal pacing/budget/timeout knobs fcfg_table leaves out by default.
# `?` reveals the raw FLEET_* key inline; ⌃s toggles the write scope; enter on an
# editable key edits it, on a section header expands it.
#
# Two write scopes, never a third (issue #1102): THIS FLEET ⇄ a hosted REPO. One
# login runs one fleet (#977), so the old fleet⇄global split was one layer seen
# twice; the @scope=global tag still decides the FILE (fleet.settings vs the fleet
# conf — fcfg_key_wscope) but is no longer a scope you pick or a reason to refuse.
# The install's fleet.conf is read (`· legacy`) and never written.
#
# Repo scope (issue #802): ⌃s steps through `repo:<slug>` — one per hosted repo,
# one for a one-repo fleet too. There the per-repo keys (model, agent, MCP
# servers, deploy, setup…; fcfg_repo_keys) show the value THAT repo's windows read,
# with a magenta `▸ repo` source when its own overlay sets it, and enter writes the
# repo's overlay; every other key still edits this fleet. In a one-repo fleet the
# repo layer IS the fleet conf, and in the fleet scope every row renders exactly
# as before a repo was ever added.
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

US="$FCFG_US"

# Shared palette (Tokyo Night) — one definition for rows + preview so the
# per-layer colors can never drift between the two panes.
CFG_R=$'\033[0m'; CFG_B=$'\033[1m'
CFG_KEY=$'\033[38;2;125;207;255m'     # cyan   — label / key name
CFG_TX=$'\033[38;2;169;177;214m'      # text   — value
CFG_FLEET=$'\033[38;2;158;206;106m'   # green  — this fleet sets it
CFG_LEGACY=$'\033[38;2;122;162;247m'  # blue   — the install's read-only fleet.conf
CFG_DIM=$'\033[38;2;86;95;137m'       # dim    — unset → code default
CFG_REPO=$'\033[38;2;187;154;247m'    # magenta — the repo's own overlay wins

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
# the `?` raw-key toggle, which appends it to field2. RCONF_F/RCONF_S/RCONF_I are
# set once by emit_rows so the effective-value lookup only greps the (small) confs
# — the same ladder as fcfg_effective, minus a tag lookup per row.
# Layout: label · value · scope-tag · source-layer, each in a fixed-width column
# so the eye scans straight down. Scope is a short word (locked/repo/blank)
# colored by CFG_* — color carries the emphasis emoji used to. The tag + markers
# are pure ASCII, so `printf %-Ns` byte-padding == cell-width here: alignment holds
# with no wcwidth pass needed (unlike the old 2-cell emoji that broke column math).
render_row() {
  local key="$1" label="$2" scope="$3" unit="$4" def="$5"
  local stag scol col src srcmark val v lf vf tf sf raw disp isrepo=''
  case "$RKEYS" in *" $key "*) isrepo=1 ;; esac
  case "$scope" in
    identity) stag='locked'; scol="$CFG_DIM" ;;
    *)        stag=${isrepo:+repo}; scol="$CFG_REPO" ;;
  esac
  if [ -n "$RREPO" ] && [ -n "$isrepo" ]; then
    v=$(fcfg_repo_effective "$key" "$SESSION" "$RREPO"); val=${v%"$US"*}; src=${v##*"$US"}
  elif [ "$scope" != global ] && v=$(fcfg_file_value "$RCONF_F" "$key"); then val="$v"; src=fleet
  elif v=$(fcfg_file_value "$RCONF_S" "$key"); then val="$v"; src=fleet
  elif v=$(fcfg_file_value "$RCONF_I" "$key"); then val="$v"; src=legacy
  else val="$def"; src=default
  fi
  case "$src" in
    repo)   col="$CFG_REPO";   srcmark='▸ repo' ;;
    fleet)  col="$CFG_FLEET";  srcmark='▸ fleet' ;;
    legacy) col="$CFG_LEGACY"; srcmark='· legacy' ;;
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
  if [ -n "$RREPO" ]; then repo=$RREPO
  else repo=$(fcfg_effective FLEET_REPO "$SESSION"); repo=${repo%"$US"*}; fi
  ws=$(fcfg_wscope_label "$SESSION")
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
  local common_t='' adv_t='' id_t='' int_t='' order='' line
  RCONF_F=$(fcfg_fleet_conf "$SESSION"); RCONF_S=$(fcfg_settings_conf); RCONF_I=$(fcfg_install_conf)
  RKEYS=" $(fcfg_repo_keys | tr '\n' ' ') "   # per-repo keys, once — not a fork per row
  # Repo scope: the per-repo rows resolve for THIS repo (empty = this fleet).
  RREPO=$(fcfg_scope_repo "$SESSION" "$(fcfg_wscope "$SESSION")" || true)
  while IFS="$US" read -r key label group tier scope edit unit def; do
    [ -n "$key" ] || continue
    line="$key$US$label$US$group$US$tier$US$scope$US$edit$US$unit$US$def"
    if [ "$tier" = internal ]; then                             int_t="$int_t$line
"
    elif [ "$scope" = identity ]; then                          id_t="$id_t$line
"
    elif [ "$tier" = advanced ]; then                           adv_t="$adv_t$line
"
    else
      common_t="$common_t$line
"
      case "$US$order$US" in *"$US$group$US"*) : ;; *) order="${order:+$order$US}$group" ;; esac
    fi
  done <<EOF
$(fcfg_table --all)
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
  emit_bucket identity   "IDENTITY (locked)"       "$id_t"
  emit_bucket internal   "INTERNAL · show all (pacing, budgets, timeouts)" "$int_t"
}

# ---- preview: the detail pane for one key -----------------------------------
emit_preview() {
  local key="${1:-}" B="$CFG_B" R="$CFG_R" DIM="$CFG_DIM" GN="$CFG_FLEET"
  case "$key" in
    FLEET_[A-Z0-9_]*) : ;;
    @@TOGGLE@@*) printf '  %ssection%s\n\n  enter / tab expands or collapses this section.\n' "$DIM" "$R"; return ;;
    *)           printf '  %s(select a key)%s\n' "$DIM" "$R"; return ;;
  esac
  local edit label unit dv ev val src scope fv iv kws tgt repo row r rv
  edit=$(fcfg_edit "$key"); label=$(fcfg_label "$key"); unit=$(fcfg_unit "$key")
  scope=$(fcfg_scope "$key"); dv=$(fcfg_default "$key")
  kws=$(fcfg_key_wscope "$SESSION" "$key" "$scope"); repo=''
  case "$kws" in repo:*) repo=$(fcfg_scope_repo "$SESSION" "$kws") ;; esac
  if [ -n "$repo" ]; then ev=$(fcfg_repo_effective "$key" "$SESSION" "$repo")
  else ev=$(fcfg_effective "$key" "$SESSION" "$scope"); fi
  val=${ev%"$FCFG_US"*}; src=${ev##*"$FCFG_US"}
  printf '%s%s%s   %s[%s%s]%s\n  %s%s%s\n\n' \
    "$B" "$label" "$R" "$DIM" "$edit" "${unit:+ · $unit}" "$R" "$DIM" "$key" "$R"
  fcfg_full "$key" | sed 's/^/  /'
  printf '\n  %s────────%s\n' "$DIM" "$R"
  if [ "$scope" = identity ]; then
    printf '  %slocked%s — identity, view-only; set in fleet.conf and re-provision.\n' "$DIM" "$R"
  elif fcfg_is_repo_key "$key"; then
    printf '  %s%srepo%s — this fleet, or ⌃s to set it for one repo only.\n' "$B" "$CFG_REPO" "$R"
  else
    printf '  %s%sfleet%s — a setting of this fleet.\n' "$B" "$GN" "$R"
  fi
  printf '  %seffective%s : %s%s%s   %s(%s%s)%s\n' "$B" "$R" "$GN" "${val:-<empty>}" "$R" "$DIM" "$src" "${repo:+ · $repo}" "$R"
  printf '  %sdefault%s   : %s\n' "$DIM" "$R" "${dv:-<empty>}"
  fv=$(fcfg_effective "$key" "$SESSION" "$scope")
  if [ "${fv##*"$FCFG_US"}" = fleet ]; then printf '  this fleet: %s\n' "${fv%"$FCFG_US"*}"
  else printf '  %sthis fleet: (unset)%s\n' "$DIM" "$R"; fi
  # The install's fleet.conf: shown only when it still carries the key (read-only).
  if iv=$(fcfg_file_value "$(fcfg_install_conf)" "$key"); then
    printf '  %slegacy    : %s  (install fleet.conf, read-only)%s\n' "$DIM" "$iv" "$R"
  fi
  # A per-repo key in a multi-repo fleet: what EACH hosted repo reads.
  if fcfg_is_repo_key "$key" && fleet_has_repo_overlays "$SESSION"; then
    printf '\n  %sper repo%s\n' "$B" "$R"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      r=${row#*"$FCFG_US"}; rv=$(fcfg_repo_effective "$key" "$SESSION" "$r")
      printf '  %-28s %s  %s(%s)%s\n' "$r" "${rv%"$FCFG_US"*}" "$DIM" "${rv##*"$FCFG_US"}" "$R"
    done <<EOF
$(fcfg_repo_scopes "$SESSION")
EOF
  fi
  if [ "$scope" = identity ]; then
    printf '\n  %senter is disabled for identity keys%s\n' "$DIM" "$R"
  else
    tgt=$(fcfg_target_conf "$SESSION" "$kws")
    printf '\n  %senter edits %s%s\n  %s%s%s\n' \
      "$B" "$(if [ -n "$repo" ]; then printf 'REPO %s' "$repo"; else printf 'THIS FLEET'; fi)" "$R" "$DIM" "$tgt" "$R"
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
                tmux display-message "config: edits now write to $(fcfg_wscope_label "$SESSION")" 2>/dev/null || true
                exit 0 ;;
  toggle-raw)   raw_toggle; exit 0 ;;
  toggle-bucket) case "${2:-}" in @@TOGGLE@@*) exp_toggle "${2#@@TOGGLE@@}" ;; esac
                exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf required for the prefix+c config modal"; sleep 3; exit 1; }
[ -f "$(fcfg_example)" ] || { echo "fleet.conf.example not found — cannot build the config modal"; sleep 3; exit 1; }
eval "$(bash "$BIN/dash-keymap.sh" --panel config env)"

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
  local scope; scope=$(fcfg_wscope_label "$SESSION")
  # The header carries a tappable `[✕ close]` button chip; the click-header bind
  # below aborts (→ closes this popup) when ✕/close is tapped — an iPad/Termius
  # dismiss that doesn't need Escape (issue #346). Bracketed as a button (issue
  # #381), so a tap lands on `[✕` or `close]` — the case globs *✕*|*close*.
  bash "$SELF" rows | fzf --ansi --delimiter="$FCFG_US" --with-nth=2 \
    --no-sort --layout=reverse-list --info=hidden --border=rounded \
    --query="$savedq" \
    --border-label=" fleet config · edits write to $scope " --border-label-pos=3 \
    --prompt='filter ▸ ' \
    --header="enter=edit/expand · tab=expand section · space=detail · $DASH_GLYPH_SCOPE=write-scope (fleet⇄repo) · ?=raw keys · $DASH_GLYPH_RELOAD=refresh · esc · [✕ close]" \
    --preview "bash $SELF preview {1}" \
    --preview-window='right,54%,wrap,border-left,hidden' \
    --bind "$DASH_KEY_RELOAD:reload(bash $SELF rows)" \
    --bind "space:toggle-preview" \
    --bind "$DASH_KEY_PREVIEW:toggle-preview" \
    --bind "$DASH_KEY_SCOPE:execute-silent(bash $SELF toggle-scope; : > '$RESTART')+abort" \
    --bind "?:execute-silent(bash $SELF toggle-raw)+reload(bash $SELF rows)" \
    --bind "tab:execute-silent(bash $SELF toggle-bucket {1})+reload(bash $SELF rows)" \
    --bind "enter:transform(bash $SELF enter-action {1} '$EDITKEY' '$QUERYF' {q})" \
    --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac' \
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
