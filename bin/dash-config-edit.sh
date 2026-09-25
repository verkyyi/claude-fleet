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
[ -f "$BIN/fleet-ui-lang.sh" ] && . "$BIN/fleet-ui-lang.sh"

SESSION=$(fleet_current_session)
[ -n "$SESSION" ] && fleet_load_conf "$SESSION" 2>/dev/null || true
KSCOPE=$(fcfg_scope "$KEY")     # identity | global | fleet (from the @scope tag)
EDIT=$(fcfg_edit "$KEY")        # no | bool | int | enum | path | str | regex

edit_t() {
  if _fcfg_ui_is_zh; then
    case "$1" in
      identity_msg_fmt) printf '%s 是 identity key - 请在 fleet.conf 中设置并重新 provision。' "${2:-}" ;;
      identity_status_fmt) printf 'config: %s 是 identity key - 请在 fleet.conf 中设置并重新 provision' "${2:-}" ;;
      no_target) printf '没有可写入的 conf - 未做修改。' ;;
      no_target_status_fmt) printf 'config: 没有可写入 %s 的 conf - 未做修改' "${2:-}" ;;
      writing_to_fmt) printf '写入到 %s 层' "${2:-}" ;;
      effective_now) printf '当前生效' ;;
      in_this_layer) printf '当前层' ;;
      unset_here) printf '当前层未设置' ;;
      empty) printf '空' ;;
      defer_default) printf '取消设置（使用默认值）' ;;
      custom_model) printf '输入完整 claude-* id' ;;
      full_model_prompt) printf '完整模型 id  （空 = 取消 · - = 设为空） ▸ ' ;;
      choose_prompt) printf '选择 ▸ ' ;;
      choose_header_fmt) printf '当前生效: %s (%s)   ·   enter=选择 · esc=取消' "${2:-}" "${3:-}" ;;
      pick_label_fmt) printf ' 选择 %s → %s 层 ' "${2:-}" "${3:-}" ;;
      valid_bool) printf '  合法输入   : 0 或 1\n' ;;
      valid_int) printf '  合法输入   : 非负整数\n' ;;
      valid_enum) printf '  合法输入   : documented values 之一（看配置预览）· - = 设为空，使用默认值\n' ;;
      valid_regex) printf '  合法输入   : 合法 extended regex（不能含双引号、反引号或 $(...)）· - = 设为空\n' ;;
      valid_path) printf '  合法输入   : 路径（$HOME/${VAR} 可以；不能含双引号、反引号或 $(...)）· - = 设为空\n' ;;
      valid_text) printf '  合法输入   : 文本（不能含双引号、反引号或 $(...)）· - = 设为空\n' ;;
      new_value_prompt) printf '\n  新值  （空 = 取消 · - = 设为空） ▸ ' ;;
      rejected_fmt) printf '\n  \033[31m✗ 已拒绝:\033[0m %s\n  （未写入 - 按任意键）' "${2:-}" ;;
      write_failed_fmt) printf '\n  \033[31m✗ 写入失败\033[0m - %s 不可写（磁盘满或只读？）\n  （未修改 - 按任意键）' "${2:-}" ;;
      write_failed_status_fmt) printf 'config: 写入 %s 失败 - 未修改' "${2:-}" ;;
      created_fmt) printf '\n  \033[32m✓ 已创建\033[0m %s 并设置 \033[1m%s = %s\033[0m\n  %s\n' "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
      created_status_fmt) printf 'config: 已创建 %s 并设置 %s=%s' "${2:-}" "${3:-}" "${4:-}" ;;
      wrote_fmt) printf '\n  \033[32m✓ 已写入\033[0m \033[1m%s = %s\033[0m 到 %s 层（备份: %s.bak）\n  %s\n' "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" ;;
      wrote_status_fmt) printf 'config: 已设置 %s=%s（%s）- 备份 %s.bak' "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
      *) printf '%s' "$1" ;;
    esac
  else
    case "$1" in
      identity_msg_fmt) printf '%s is an identity key — set it in fleet.conf and re-provision.' "${2:-}" ;;
      identity_status_fmt) printf 'config: %s is an identity key — set it in fleet.conf and re-provision' "${2:-}" ;;
      no_target) printf 'no conf to write to — nothing changed.' ;;
      no_target_status_fmt) printf 'config: no conf to write %s to — nothing changed' "${2:-}" ;;
      writing_to_fmt) printf 'writing to the \033[1m%s\033[0m layer' "${2:-}" ;;
      effective_now) printf 'effective now' ;;
      in_this_layer) printf 'in this layer' ;;
      unset_here) printf 'unset here' ;;
      empty) printf 'empty' ;;
      defer_default) printf 'unset (defer to the default)' ;;
      custom_model) printf 'type a full claude-* id' ;;
      full_model_prompt) printf 'full model id  (empty = cancel · - = set empty) ▸ ' ;;
      choose_prompt) printf 'choose ▸ ' ;;
      choose_header_fmt) printf 'effective now: %s (%s)   ·   enter=choose · esc=cancel' "${2:-}" "${3:-}" ;;
      pick_label_fmt) printf ' pick %s → %s layer ' "${2:-}" "${3:-}" ;;
      valid_bool) printf '  valid input   : 0 or 1\n' ;;
      valid_int) printf '  valid input   : a non-negative integer\n' ;;
      valid_enum) printf '  valid input   : one of the documented values (see the config preview) · - (set empty, defer to default)\n' ;;
      valid_regex) printf '  valid input   : a valid extended regex (no double-quotes, backticks, or $(…)) · - = set empty\n' ;;
      valid_path) printf '  valid input   : a path ($HOME/${VAR} ok; no double-quotes, backticks, or $(…)) · - = set empty\n' ;;
      valid_text) printf '  valid input   : free text (no double-quotes, backticks, or $(…)) · - = set empty\n' ;;
      new_value_prompt) printf '\n  new value  (empty = cancel · - = set empty) ▸ ' ;;
      rejected_fmt) printf '\n  \033[31m✗ rejected:\033[0m %s\n  (nothing written — press any key)' "${2:-}" ;;
      write_failed_fmt) printf '\n  \033[31m✗ write failed\033[0m — %s is not writable (full/read-only volume?)\n  (nothing changed — press any key)' "${2:-}" ;;
      write_failed_status_fmt) printf 'config: write to %s FAILED — nothing changed' "${2:-}" ;;
      created_fmt) printf '\n  \033[32m✓ created\033[0m %s and set \033[1m%s = %s\033[0m\n  %s\n' "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
      created_status_fmt) printf 'config: created %s and set %s=%s' "${2:-}" "${3:-}" "${4:-}" ;;
      wrote_fmt) printf '\n  \033[32m✓ wrote\033[0m \033[1m%s = %s\033[0m to the %s layer (backup: %s.bak)\n  %s\n' "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" ;;
      wrote_status_fmt) printf 'config: set %s=%s (%s) — backup %s.bak' "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
      *) printf '%s' "$1" ;;
    esac
  fi
}

edit_scope_label() {
  if _fcfg_ui_is_zh; then
    case "$1" in
      FLEET) printf '当前 fleet' ;;
      REPO\ *) printf '仓库 %s' "${1#REPO }" ;;
      *) printf '%s' "$1" ;;
    esac
  else
    printf '%s' "$1"
  fi
}

edit_src_label() {
  if _fcfg_ui_is_zh; then
    case "$1" in
      repo) printf '仓库' ;;
      fleet) printf '当前 fleet' ;;
      global) printf '全局' ;;
      legacy) printf '旧配置' ;;
      default) printf '默认' ;;
      *) printf '%s' "$1" ;;
    esac
  else
    printf '%s' "$1"
  fi
}

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
  tmux display-message "$(edit_t identity_status_fmt "$KEY")" 2>/dev/null || true
  refuse "$(edit_t identity_msg_fmt "$KEY")"
  exit 0
fi
SCOPE=$(fcfg_key_wscope "$SESSION" "$KEY" "$KSCOPE")
REPO=''
case "$SCOPE" in repo:*) REPO=$(fcfg_scope_repo "$SESSION" "$SCOPE") ;; esac
TARGET=$(fcfg_target_conf "$SESSION" "$SCOPE")

if [ -z "$TARGET" ]; then   # defensive: a repo scope that stopped resolving mid-edit
  tmux display-message "$(edit_t no_target_status_fmt "$KEY")" 2>/dev/null || true
  refuse "$(edit_t no_target)"
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
scope_label=$(edit_scope_label "$scope_up")
effsrc_label=$(edit_src_label "$effsrc")

printf '\n  \033[1m%s\033[0m  [%s]   →  %s\n' "$(fcfg_label "$KEY")" "$EDIT" "$(edit_t writing_to_fmt "$scope_label")"
printf '  \033[38;2;86;95;137m%s  ·  %s\033[0m\n' "$KEY" "$(fcfg_short "$KEY")"
printf '\n  %s : %s  (%s)\n' "$(edit_t effective_now)" "${effval:-<$(edit_t empty)>}" "$effsrc_label"
printf '  %s : %s\n' "$(edit_t in_this_layer)" "${cur:-<$(edit_t unset_here)>}"
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
    printf '%s%s\033[36m%-9s\033[0m  \033[38;2;86;95;137m— %s\033[0m\n' ':defer:' "$US" "($(edit_t empty))" "$(edit_t defer_default)"
    [ "$is_model" = yes ] && \
      printf '%s%s\033[36m%-9s\033[0m  \033[38;2;86;95;137m— %s\033[0m\n' ':custom:' "$US" 'custom…' "$(edit_t custom_model)"
  )
  sel=$(printf '%s\n' "$rows" | fzf --ansi --delimiter="$US" --with-nth=2 \
          --no-sort --layout=reverse-list --info=hidden --border=rounded \
          --border-label="$(edit_t pick_label_fmt "$(fcfg_label "$KEY")" "$scope_label")" --border-label-pos=3 \
          --prompt="$(edit_t choose_prompt)" \
          --header="$(edit_t choose_header_fmt "${effval:-<$(edit_t empty)>}" "$effsrc_label")") \
        || exit 0                                # esc / no selection = cancel
  tok=${sel%%"$US"*}
  case "$tok" in
    ':defer:')  val='' ;;
    ':custom:')
      printf '\n  '
      edit_t full_model_prompt
      IFS= read -r val
      [ -n "$val" ] || exit 0
      [ "$val" = '-' ] && val='' ;;
    '')  exit 0 ;;                               # defensive: empty selection = cancel
    *)   val="$tok" ;;
  esac
else
  case "$EDIT" in
    bool)  edit_t valid_bool ;;
    int)   edit_t valid_int ;;
    enum)  edit_t valid_enum ;;
    regex) edit_t valid_regex ;;
    path)  edit_t valid_path ;;
    *)     edit_t valid_text ;;
  esac
  # Bare empty input cancels (the standard for these popups); a lone '-' is the
  # explicit "set this key empty" sentinel — enums/strings document empty as a
  # real, meaningful value ("defer to the default"), which bare-empty can't express.
  edit_t new_value_prompt
  IFS= read -r val
  [ -n "$val" ] || exit 0
  [ "$val" = '-' ] && val=''
fi

if ! reason=$(fcfg_validate "$EDIT" "$val" "$KEY"); then
  edit_t rejected_fmt "$reason"
  read -rsn1 _ || true
  exit 0
fi

if [ -n "$REPO" ]; then
  wstatus=$(fcfg_repo_write "$SESSION" "${SCOPE#repo:}" "$KEY" "$val" "$EDIT"); wrc=$?
else
  wstatus=$(fcfg_write "$TARGET" "$KEY" "$val" "$EDIT"); wrc=$?
fi
if [ "$wrc" -ne 0 ]; then
  edit_t write_failed_fmt "$TARGET"
  read -rsn1 _ || true
  tmux display-message "$(edit_t write_failed_status_fmt "${TARGET##*/}")" 2>/dev/null || true
  exit 0
fi
show=${val:-($(edit_t empty))}
if [ "$wstatus" = created ]; then
  edit_t created_fmt "$TARGET" "$KEY" "$show" "$TARGET"
  tmux display-message "$(edit_t created_status_fmt "${TARGET##*/}" "$KEY" "$show")" 2>/dev/null || true
else
  edit_t wrote_fmt "$KEY" "$show" "$scope_label" "${TARGET##*/}" "$TARGET"
  tmux display-message "$(edit_t wrote_status_fmt "$KEY" "$show" "$scope_label" "${TARGET##*/}")" 2>/dev/null || true
fi
sleep 0.8
exit 0
