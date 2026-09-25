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
[ -f "$BIN/fleet-ui-lang.sh" ] && . "$BIN/fleet-ui-lang.sh"

SESSION=$(fleet_current_session)
[ -n "$SESSION" ] && fleet_load_conf "$SESSION" 2>/dev/null || true

US="$FCFG_US"

cfg_t() {
  if _fcfg_ui_is_zh; then
    case "$1" in
      locked) printf '锁定' ;;
      repo) printf '仓库' ;;
      fleet) printf '当前 fleet' ;;
      legacy) printf '旧配置' ;;
      default) printf '默认' ;;
      empty) printf '空' ;;
      unset) printf '未设置' ;;
      edits) printf '写入' ;;
      raw_keys) printf '原始 key' ;;
      expand) printf '展开' ;;
      search_all) printf '搜索=全部' ;;
      skills_hint) printf '$fleet-config' ;;
      section) printf '分组' ;;
      section_help) printf 'enter / tab 展开或折叠这个分组。' ;;
      select_key) printf '选择一个配置项' ;;
      advanced) printf '高级' ;;
      identity_locked) printf '身份（锁定）' ;;
      internal) printf '内部 · 显示全部（节奏、预算、超时）' ;;
      fleet_config) printf 'fleet 配置' ;;
      filter) printf '过滤' ;;
      write_scope) printf '写入范围' ;;
      refresh) printf '刷新' ;;
      close) printf '关闭' ;;
      header) printf '↵编辑  输入搜索全部  Space详情  %s范围  ?key  %s刷新  Esc关闭' "$DASH_GLYPH_SCOPE" "$DASH_GLYPH_RELOAD" ;;
      border_fmt) printf ' fleet 配置 · 写入到 %s ' "${2:-}" ;;
      no_fzf) printf 'prefix+c 配置面板需要 fzf' ;;
      no_example) printf '找不到 fleet.conf.example，无法生成配置面板' ;;
      scope_msg_fmt) printf 'config: 现在写入到 %s' "${2:-}" ;;
      stage_fail_fmt) printf 'config: 无法暂存编辑 %s（磁盘满或只读？）' "${2:-}" ;;
      pick_fmt) printf ' 选择 %s → %s 层 ' "${2:-}" "${3:-}" ;;
      choose) printf '选择' ;;
      choose_prompt) printf '选择 ▸ ' ;;
      effective_now) printf '当前生效' ;;
      enter_choose) printf 'enter=选择 · esc=取消' ;;
      locked_preview) printf '身份配置，只读；需要修改 fleet.conf 后重新 provision。' ;;
      repo_preview) printf '可写当前 fleet；也可用 ⌃s 切到单仓库覆盖。' ;;
      fleet_preview) printf '写入当前 fleet 配置。' ;;
      effective) printf '生效值' ;;
      description) printf '说明' ;;
      current_values) printf '当前值' ;;
      write_target) printf '写入目标' ;;
      type_label) printf '类型' ;;
      unit_label) printf '单位' ;;
      original_help) printf '原始说明' ;;
      no_cn_help) printf '这个长尾配置还没有中文说明。下面是原始说明：' ;;
      install_readonly) printf '安装层 fleet.conf，只读' ;;
      this_fleet) printf '当前 fleet' ;;
      this_layer) printf '当前层' ;;
      per_repo) printf '每个仓库' ;;
      enter_disabled) printf 'identity key 禁止 enter 编辑' ;;
      enter_edits_fmt) printf 'enter 编辑 %s' "${2:-}" ;;
      this_fleet_caps) printf '当前 fleet' ;;
      *) printf '%s' "$1" ;;
    esac
  else
    case "$1" in
      locked) printf 'locked' ;;
      repo) printf 'repo' ;;
      fleet) printf 'fleet' ;;
      legacy) printf 'legacy' ;;
      default) printf 'default' ;;
      empty) printf 'empty' ;;
      unset) printf 'unset' ;;
      edits) printf 'edits' ;;
      raw_keys) printf 'raw keys' ;;
      expand) printf 'expand' ;;
      search_all) printf 'search=all' ;;
      skills_hint) printf 'agents can use $fleet-config' ;;
      section) printf 'section' ;;
      section_help) printf 'enter / tab expands or collapses this section.' ;;
      select_key) printf 'select a key' ;;
      advanced) printf 'ADVANCED' ;;
      identity_locked) printf 'IDENTITY (locked)' ;;
      internal) printf 'INTERNAL · show all (pacing, budgets, timeouts)' ;;
      fleet_config) printf 'fleet config' ;;
      filter) printf 'filter' ;;
      write_scope) printf 'write-scope' ;;
      refresh) printf 'refresh' ;;
      close) printf 'close' ;;
      header) printf 'enter edit  type searches all  Space detail  %s scope  ? key  %s reload  Esc close' "$DASH_GLYPH_SCOPE" "$DASH_GLYPH_RELOAD" ;;
      border_fmt) printf ' fleet config · edits write to %s ' "${2:-}" ;;
      no_fzf) printf 'fzf required for the prefix+c config modal' ;;
      no_example) printf 'fleet.conf.example not found — cannot build the config modal' ;;
      scope_msg_fmt) printf 'config: edits now write to %s' "${2:-}" ;;
      stage_fail_fmt) printf 'config: could not stage an edit for %s (full/read-only volume?)' "${2:-}" ;;
      pick_fmt) printf ' pick %s → %s layer ' "${2:-}" "${3:-}" ;;
      choose) printf 'choose' ;;
      choose_prompt) printf 'choose ▸ ' ;;
      effective_now) printf 'effective now' ;;
      enter_choose) printf 'enter=choose · esc=cancel' ;;
      locked_preview) printf 'Identity setting, view-only; set it in fleet.conf and re-provision.' ;;
      repo_preview) printf 'Writes to this fleet, or use ⌃s to set one repo only.' ;;
      fleet_preview) printf 'Writes to this fleet config.' ;;
      effective) printf 'effective' ;;
      description) printf 'Description' ;;
      current_values) printf 'Current Values' ;;
      write_target) printf 'Write Target' ;;
      type_label) printf 'type' ;;
      unit_label) printf 'unit' ;;
      original_help) printf 'Original Help' ;;
      no_cn_help) printf 'No localized summary yet. Original help:' ;;
      install_readonly) printf 'install fleet.conf, read-only' ;;
      this_fleet) printf 'this fleet' ;;
      this_layer) printf 'this layer' ;;
      per_repo) printf 'per repo' ;;
      enter_disabled) printf 'enter is disabled for identity keys' ;;
      enter_edits_fmt) printf 'enter edits %s' "${2:-}" ;;
      this_fleet_caps) printf 'THIS FLEET' ;;
      *) printf '%s' "$1" ;;
    esac
  fi
}

cfg_is_essential() {
  case "$1" in
    FLEET_UI_LANG|FLEET_SIDEBAR|FLEET_SIDEBAR_WIDTH|FLEET_CLOSE_LANDS_NEXT|FLEET_HOME_SIDEBAR_FIRST|\
    FLEET_AGENT|FLEET_MODEL|FLEET_CODEX_MODEL|FLEET_WORKER_PROMPT|FLEET_SCRATCH_POOL|\
    FLEET_MAX_SESSIONS|FLEET_GLOBAL_MAX_SESSIONS|FLEET_AUTOFILL|FLEET_QUOTA_GATE|FLEET_QUOTA_CEILING|\
    FLEET_ISSUE_BRIDGE|FLEET_CLEANUP|FLEET_SLEEP|FLEET_NOTIFY_CMD)
      return 0 ;;
    *) return 1 ;;
  esac
}

cfg_essential_group() {
  if _fcfg_ui_is_zh; then
    case "$1" in
      FLEET_UI_LANG|FLEET_SIDEBAR|FLEET_SIDEBAR_WIDTH|FLEET_CLOSE_LANDS_NEXT|FLEET_HOME_SIDEBAR_FIRST) printf '界面' ;;
      FLEET_AGENT|FLEET_MODEL|FLEET_CODEX_MODEL|FLEET_WORKER_PROMPT|FLEET_SCRATCH_POOL) printf '启动' ;;
      FLEET_MAX_SESSIONS|FLEET_GLOBAL_MAX_SESSIONS|FLEET_AUTOFILL|FLEET_QUOTA_GATE|FLEET_QUOTA_CEILING) printf '容量' ;;
      *) printf '自动化' ;;
    esac
  else
    case "$1" in
      FLEET_UI_LANG|FLEET_SIDEBAR|FLEET_SIDEBAR_WIDTH|FLEET_CLOSE_LANDS_NEXT|FLEET_HOME_SIDEBAR_FIRST) printf 'Interface' ;;
      FLEET_AGENT|FLEET_MODEL|FLEET_CODEX_MODEL|FLEET_WORKER_PROMPT|FLEET_SCRATCH_POOL) printf 'Launch' ;;
      FLEET_MAX_SESSIONS|FLEET_GLOBAL_MAX_SESSIONS|FLEET_AUTOFILL|FLEET_QUOTA_GATE|FLEET_QUOTA_CEILING) printf 'Capacity' ;;
      *) printf 'Automation' ;;
    esac
  fi
}

cfg_essential_order() {
  case "$1" in
    FLEET_UI_LANG) printf '010' ;;
    FLEET_SIDEBAR) printf '011' ;;
    FLEET_SIDEBAR_WIDTH) printf '012' ;;
    FLEET_CLOSE_LANDS_NEXT) printf '013' ;;
    FLEET_HOME_SIDEBAR_FIRST) printf '014' ;;
    FLEET_AGENT) printf '020' ;;
    FLEET_MODEL) printf '021' ;;
    FLEET_SUBAGENT_MODEL) printf '022' ;;
    FLEET_CODEX_MODEL) printf '023' ;;
    FLEET_CODEX_SUBAGENT_MODEL) printf '024' ;;
    FLEET_WORKER_PROMPT) printf '025' ;;
    FLEET_SPAWN_FOCUS) printf '026' ;;
    FLEET_SCRATCH_POOL) printf '027' ;;
    FLEET_PRESPAWN_DEDUP) printf '028' ;;
    FLEET_MERGE_METHOD) printf '029' ;;
    FLEET_MAX_SESSIONS) printf '030' ;;
    FLEET_GLOBAL_MAX_SESSIONS) printf '031' ;;
    FLEET_AUTOFILL) printf '032' ;;
    FLEET_QUOTA_GATE) printf '033' ;;
    FLEET_QUOTA_CEILING) printf '034' ;;
    FLEET_ISSUE_BRIDGE) printf '040' ;;
    FLEET_CLEANUP) printf '041' ;;
    FLEET_SLEEP) printf '042' ;;
    FLEET_NOTIFY_CMD) printf '043' ;;
    FLEET_GH_TTL) printf '044' ;;
    FLEET_PR_REFRESH_INTERVAL) printf '045' ;;
    *) printf '999' ;;
  esac
}

cfg_desc() {
  local key="$1"
  if _fcfg_ui_is_zh; then
    case "$key" in
      FLEET_UI_LANG) cat <<'EOF'
控制 tmux 内所有 fleet UI 文案的语言。`zh` 强制中文，`en` 强制英文，`auto` 跟随当前登录环境；在 C/未设置 locale 下保持中文。
EOF
        ;;
      FLEET_SIDEBAR) cat <<'EOF'
控制 worker 窗口左侧任务栏是否启用。开启后可以用任务栏切换任务、输入新会话名、打开行菜单和快捷键。
EOF
        ;;
      FLEET_SIDEBAR_WIDTH) cat <<'EOF'
左侧任务栏宽度，单位是列。屏幕太窄时任务栏会自动隐藏；增大宽度可以显示更完整的中文任务名。
EOF
        ;;
      FLEET_CLOSE_LANDS_NEXT) cat <<'EOF'
关闭当前任务窗口后，优先落到相邻任务，而不是回 hub。适合连续处理多个 worker 的工作流。
EOF
        ;;
      FLEET_HOME_SIDEBAR_FIRST) cat <<'EOF'
按 ⌂/F9 时先聚焦任务栏，再按一次回 hub。关闭后，⌂/F9 会更直接地回 hub。
EOF
        ;;
      FLEET_AGENT) cat <<'EOF'
新 worker 默认使用的 agent CLI。可在 `claude` 和 `codex` 之间切换；已有窗口不受影响。
EOF
        ;;
      FLEET_MODEL) cat <<'EOF'
Claude worker 的默认模型。可用别名如 `opus`、`sonnet`、`haiku`、`fable`，也可由 repo overlay 覆盖。
EOF
        ;;
      FLEET_CODEX_MODEL) cat <<'EOF'
Codex worker 的默认模型。留空时使用 Codex CLI 自己的默认值；只影响之后启动的新 Codex 会话。
EOF
        ;;
      FLEET_WORKER_PROMPT) cat <<'EOF'
新 worker 启动时预填的初始提示词。适合放团队约定、验证要求或默认执行方式。
EOF
        ;;
      FLEET_SCRATCH_POOL) cat <<'EOF'
预热 scratch 会话数量。大于 0 会提前准备空闲 scratch，换取更快启动；也会占用会话容量。
EOF
        ;;
      FLEET_MAX_SESSIONS) cat <<'EOF'
当前 fleet 允许同时运行的最大会话数。超过后新任务会等待空位或被自动化流程延后。
EOF
        ;;
      FLEET_GLOBAL_MAX_SESSIONS) cat <<'EOF'
这个登录下所有 fleets 合计的最大会话数。用于保护账号、机器资源和 Claude/Codex 配额。
EOF
        ;;
      FLEET_AUTOFILL) cat <<'EOF'
根据 backlog 中带标签的 issue 自动填充空闲 worker。适合批量推进任务；关闭后只手动启动。
EOF
        ;;
      FLEET_QUOTA_GATE) cat <<'EOF'
接近配额上限时停止自动填充或新启动，避免把账号推到硬限制。通常和配额上限百分比一起使用。
EOF
        ;;
      FLEET_QUOTA_CEILING) cat <<'EOF'
配额保护阈值百分比。达到这个百分比后，quota gate 会阻止进一步自动启动。
EOF
        ;;
      FLEET_ISSUE_BRIDGE) cat <<'EOF'
把 GitHub issue 评论转发给对应 worker，让外部评论能进入正在运行的任务窗口。
EOF
        ;;
      FLEET_CLEANUP) cat <<'EOF'
启用清理守护进程。任务 merge/close 后自动回收窗口、worktree 和相关状态。
EOF
        ;;
      FLEET_SLEEP) cat <<'EOF'
worker 空闲后的休眠策略。`on` 会休眠空闲 worker，`observe` 只报告候选，`off` 关闭自动休眠。
EOF
        ;;
      FLEET_NOTIFY_CMD) cat <<'EOF'
通知命令路径。fleet 在需要你处理、升级提醒或关键状态变化时调用它。
EOF
        ;;
      *) return 1 ;;
    esac
  else
    fcfg_full "$key"
  fi
}

cfg_wscope_label() {
  local l
  l=$(fcfg_wscope_label "$SESSION")
  if _fcfg_ui_is_zh; then
    case "$l" in
      FLEET) printf '当前 fleet' ;;
      REPO\ *) printf '仓库 %s' "${l#REPO }" ;;
      *) printf '%s' "$l" ;;
    esac
  else
    printf '%s' "$l"
  fi
}

cfg_src_label() {
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
  local stag scol col src srcmark srcplain val v lf vf tf sf raw disp isrepo=''
  case "$RKEYS" in *" $key "*) isrepo=1 ;; esac
  case "$scope" in
    identity) stag=$(cfg_t locked); scol="$CFG_DIM" ;;
    *)        stag=${isrepo:+$(cfg_t repo)}; scol="$CFG_REPO" ;;
  esac
  if [ -n "$RREPO" ] && [ -n "$isrepo" ]; then
    v=$(fcfg_repo_effective "$key" "$SESSION" "$RREPO"); val=${v%"$US"*}; src=${v##*"$US"}
  elif [ "$scope" != global ] && v=$(fcfg_file_value "$RCONF_F" "$key"); then val="$v"; src=fleet
  elif v=$(fcfg_file_value "$RCONF_S" "$key"); then val="$v"; src=fleet
  elif v=$(fcfg_file_value "$RCONF_I" "$key"); then val="$v"; src=legacy
  else val="$def"; src=default
  fi
  case "$src" in
    repo)   col="$CFG_REPO";   srcplain="$(cfg_t repo)";   srcmark="▸ $srcplain" ;;
    fleet)  col="$CFG_FLEET";  srcplain="$(cfg_t fleet)";  srcmark="▸ $srcplain" ;;
    legacy) col="$CFG_LEGACY"; srcplain="$(cfg_t legacy)"; srcmark="· $srcplain" ;;
    *)      col="$CFG_DIM";    srcplain="$(cfg_t default)"; srcmark="  $srcplain" ;;
  esac
  if [ -n "$val" ]; then [ -n "$unit" ] && val="$val $unit"; else val="($(cfg_t empty))"; fi
  if _fcfg_ui_is_zh; then
    raw=''; raw_on && raw="  $CFG_DIM$key$CFG_R"
    lf="$label"
    vf="$val"
    if [ ${#vf} -gt 32 ]; then vf="${vf:0:32}..."; fi
    [ -n "$stag" ] || stag='-'
    disp="${CFG_KEY}${lf}${CFG_R}	${CFG_TX}${vf}${CFG_R}	${scol}${stag}${CFG_R}	${col}${srcplain}${CFG_R}${raw}"
    printf '%s%s%s%s%s\n' "$key" "$US" "$disp" "$US" "$key"
    return
  else
    lf=$(printf '%-30s' "$(printf '%.30s' "$label")")
    vf=$(printf '%-22s' "$(printf '%.20s' "$val")")
  fi
  tf=$(printf '%-6s' "$stag")
  sf=$(printf '%-13s' "$srcmark")
  raw=''; raw_on && raw="  $CFG_DIM$key$CFG_R"
  disp="$CFG_KEY$lf$CFG_R $CFG_TX$vf$CFG_R $scol$tf$CFG_R $col$sf$CFG_R$raw"
  printf '%s%s%s%s%s\n' "$key" "$US" "$disp" "$US" "$key"
}

# ---- non-key rows (field1 is a sentinel the binds recognize) -----------------
emit_context() {
  local repo ws mode="${1:-essential}"
  if [ -n "$RREPO" ]; then repo=$RREPO
  else repo=$(fcfg_effective FLEET_REPO "$SESSION"); repo=${repo%"$US"*}; fi
  ws=$(cfg_wscope_label)
  printf '@@NOOP@@%s%sfleet%s %s%s%s   %s%s ▸ %s · ? %s · %s · %s%s\n' \
    "$US" "$CFG_B" "$CFG_R" "$CFG_KEY" "${repo:-<$(cfg_t unset)>}" "$CFG_R" "$CFG_DIM" \
    "$(cfg_t edits)" "$ws" "$(cfg_t raw_keys)" "$(cfg_t search_all)" "$(cfg_t skills_hint)" "$CFG_R"
  [ "$mode" = search ] && printf '@@NOOP@@%s%s%s%s\n' "$US" "$CFG_DIM" "$(cfg_t search_all)" "$CFG_R"
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
  local query="${1:-}" search=0 key label group tier scope edit unit def og
  local common_t='' adv_t='' id_t='' int_t='' order='' line essential_ordered='' sortline
  [ -n "$query" ] && search=1
  RCONF_F=$(fcfg_fleet_conf "$SESSION"); RCONF_S=$(fcfg_settings_conf); RCONF_I=$(fcfg_install_conf)
  RKEYS=" $(fcfg_repo_keys | tr '\n' ' ') "   # per-repo keys, once — not a fork per row
  # Repo scope: the per-repo rows resolve for THIS repo (empty = this fleet).
  RREPO=$(fcfg_scope_repo "$SESSION" "$(fcfg_wscope "$SESSION")" || true)
  while IFS="$US" read -r key label group tier scope edit unit def; do
    [ -n "$key" ] || continue
    label=$(fcfg_label_i18n "$key" "$label")
    group=$(fcfg_group_i18n "$group")
    [ "$search" = 0 ] && ! cfg_is_essential "$key" && continue
    [ "$search" = 0 ] && group=$(cfg_essential_group "$key")
    line="$key$US$label$US$group$US$tier$US$scope$US$edit$US$unit$US$def"
    if [ "$search" = 0 ]; then
      sortline="$(cfg_essential_order "$key")$US$line"
      essential_ordered="$essential_ordered$sortline
"
    elif [ "$tier" = internal ]; then                           int_t="$int_t$line
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

  if [ "$search" = 0 ]; then
    while IFS="$US" read -r _ord key label group tier scope edit unit def; do
      [ -n "$key" ] || continue
      line="$key$US$label$US$group$US$tier$US$scope$US$edit$US$unit$US$def"
      common_t="$common_t$line
"
      case "$US$order$US" in *"$US$group$US"*) : ;; *) order="${order:+$order$US}$group" ;; esac
    done <<EOF
$(printf '%s' "$essential_ordered" | sort -t"$US" -k1,1)
EOF
  fi

  if [ "$search" = 1 ]; then emit_context search; else emit_context essential; fi

  # common section, grouped by @group in first-appearance order
  local oIFS="$IFS"; IFS="$US"; set -- $order; IFS="$oIFS"
  for og in "$@"; do
    emit_subheader "$og"
    printf '%s' "$common_t" | while IFS="$US" read -r key label group tier scope edit unit def; do
      [ -n "$key" ] || continue
      [ "$group" = "$og" ] && render_row "$key" "$label" "$scope" "$unit" "$def"
    done
  done

  if [ "$search" = 1 ]; then
    emit_spacer
    emit_bucket advanced   "$(cfg_t advanced)"         "$adv_t"
    emit_bucket identity   "$(cfg_t identity_locked)"  "$id_t"
    emit_bucket internal   "$(cfg_t internal)"         "$int_t"
  fi
}

# ---- preview: the detail pane for one key -----------------------------------
emit_preview() {
  local key="${1:-}" B="$CFG_B" R="$CFG_R" DIM="$CFG_DIM" GN="$CFG_FLEET"
  case "$key" in
    FLEET_[A-Z0-9_]*) : ;;
    @@TOGGLE@@*) printf '  %s%s%s\n\n  %s\n' "$DIM" "$(cfg_t section)" "$R" "$(cfg_t section_help)"; return ;;
    *)           printf '  %s(%s)%s\n' "$DIM" "$(cfg_t select_key)" "$R"; return ;;
  esac
  local edit label unit dv ev val src scope fv iv kws tgt repo row r rv desc
  edit=$(fcfg_edit "$key"); label=$(fcfg_label "$key"); unit=$(fcfg_unit "$key")
  scope=$(fcfg_scope "$key"); dv=$(fcfg_default "$key")
  kws=$(fcfg_key_wscope "$SESSION" "$key" "$scope"); repo=''
  case "$kws" in repo:*) repo=$(fcfg_scope_repo "$SESSION" "$kws") ;; esac
  if [ -n "$repo" ]; then ev=$(fcfg_repo_effective "$key" "$SESSION" "$repo")
  else ev=$(fcfg_effective "$key" "$SESSION" "$scope"); fi
  val=${ev%"$FCFG_US"*}; src=${ev##*"$FCFG_US"}
  printf '%s%s%s\n' "$B" "$label" "$R"
  printf '  %s%s%s\n' "$DIM" "$key" "$R"
  printf '  %s%s%s: %s%s%s' "$DIM" "$(cfg_t type_label)" "$R" "$B" "$edit" "$R"
  [ -n "$unit" ] && printf '   %s%s%s: %s' "$DIM" "$(cfg_t unit_label)" "$R" "$unit"
  printf '\n\n'

  printf '%s%s%s\n' "$B" "$(cfg_t description)" "$R"
  if desc=$(cfg_desc "$key"); then
    printf '%s\n' "$desc" | sed 's/^/  /'
  else
    printf '  %s%s%s\n' "$DIM" "$(cfg_t no_cn_help)" "$R"
    printf '%s\n' "$(fcfg_full "$key")" | sed 's/^/  /'
  fi

  printf '\n%s%s%s\n' "$B" "$(cfg_t current_values)" "$R"
  printf '  %s%s%s : %s%s%s   %s(%s%s)%s\n' "$DIM" "$(cfg_t effective)" "$R" "$GN" "${val:-<$(cfg_t empty)>}" "$R" "$DIM" "$(cfg_src_label "$src")" "${repo:+ · $repo}" "$R"
  printf '  %s%s%s   : %s\n' "$DIM" "$(cfg_t default)" "$R" "${dv:-<$(cfg_t empty)>}"
  fv=$(fcfg_effective "$key" "$SESSION" "$scope")
  if [ "${fv##*"$FCFG_US"}" = fleet ]; then printf '  %s%s%s : %s\n' "$DIM" "$(cfg_t this_layer)" "$R" "${fv%"$FCFG_US"*}"
  else printf '  %s%s%s : (%s)\n' "$DIM" "$(cfg_t this_layer)" "$R" "$(cfg_t unset)"; fi
  if iv=$(fcfg_file_value "$(fcfg_install_conf)" "$key"); then
    printf '  %s%s%s : %s  %s(%s)%s\n' "$DIM" "$(cfg_t legacy)" "$R" "$iv" "$DIM" "$(cfg_t install_readonly)" "$R"
  fi

  printf '\n%s%s%s\n' "$B" "$(cfg_t write_target)" "$R"
  if [ "$scope" = identity ]; then
    printf '  %s%s%s\n' "$DIM" "$(cfg_t locked_preview)" "$R"
  elif fcfg_is_repo_key "$key"; then
    printf '  %s%s%s%s\n' "$B" "$CFG_REPO" "$(cfg_t repo_preview)" "$R"
  else
    printf '  %s%s%s%s\n' "$B" "$GN" "$(cfg_t fleet_preview)" "$R"
  fi
  # A per-repo key in a multi-repo fleet: what EACH hosted repo reads.
  if fcfg_is_repo_key "$key" && fleet_has_repo_overlays "$SESSION"; then
    printf '\n  %s%s%s\n' "$B" "$(cfg_t per_repo)" "$R"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      r=${row#*"$FCFG_US"}; rv=$(fcfg_repo_effective "$key" "$SESSION" "$r")
      printf '  %-28s %s  %s(%s)%s\n' "$r" "${rv%"$FCFG_US"*}" "$DIM" "$(cfg_src_label "${rv##*"$FCFG_US"}")" "$R"
    done <<EOF
$(fcfg_repo_scopes "$SESSION")
EOF
  fi
  if [ "$scope" = identity ]; then
    printf '\n  %s%s%s\n' "$DIM" "$(cfg_t enter_disabled)" "$R"
  else
    tgt=$(fcfg_target_conf "$SESSION" "$kws")
    printf '\n  %s%s%s\n  %s%s%s\n' \
      "$B" "$(cfg_t enter_edits_fmt "$(if [ -n "$repo" ]; then printf 'REPO %s' "$repo"; else cfg_t this_fleet_caps; fi)")" "$R" "$DIM" "$tgt" "$R"
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
      printf 'reload(bash %s rows %q)' "$SELF" "$q" ;;
    FLEET_[A-Z0-9_]*)
      if [ -n "$sentinel" ] && printf '%s' "$key" > "$sentinel" 2>/dev/null; then
        [ -n "$qfile" ] && printf '%s' "$q" > "$qfile" 2>/dev/null
        printf 'abort'
      else
        tmux display-message "$(cfg_t stage_fail_fmt "$key")" 2>/dev/null || true
      fi ;;
    *) : ;;
  esac
}

case "${1:-loop}" in
  rows)         emit_rows "${2:-}"; exit 0 ;;
  preview)      emit_preview "${2:-}"; exit 0 ;;
  enter-action) emit_enter_action "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit 0 ;;
  toggle-scope) fcfg_wscope_toggle "$SESSION"
                tmux display-message "$(cfg_t scope_msg_fmt "$(cfg_wscope_label)")" 2>/dev/null || true
                exit 0 ;;
  toggle-raw)   raw_toggle; exit 0 ;;
  toggle-bucket) case "${2:-}" in @@TOGGLE@@*) exp_toggle "${2#@@TOGGLE@@}" ;; esac
                exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { cfg_t no_fzf; echo; sleep 3; exit 1; }
[ -f "$(fcfg_example)" ] || { cfg_t no_example; echo; sleep 3; exit 1; }
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
  local scope; scope=$(cfg_wscope_label)
  # The header carries a tappable `[✕ close]` button chip; the click-header bind
  # below aborts (→ closes this popup) when ✕/close is tapped — an iPad/Termius
  # dismiss that doesn't need Escape (issue #346). Bracketed as a button (issue
  # #381), so a tap lands on `[✕` or `close]` — the case globs *✕*|*close*.
  bash "$SELF" rows "$savedq" | fzf --ansi --delimiter="$FCFG_US" --with-nth=2 \
    --no-sort --layout=reverse-list --info=hidden --border=rounded --tabstop=24 \
    --query="$savedq" \
    --border-label="$(cfg_t border_fmt "$scope")" --border-label-pos=3 \
    --prompt="$(cfg_t filter) ▸ " \
    --header="$(cfg_t header)" \
    --preview "bash $SELF preview {1}" \
    --preview-window='right,54%,wrap,border-left,hidden' \
    --bind "change:reload(bash $SELF rows {q})" \
    --bind "$DASH_KEY_RELOAD:reload(bash $SELF rows {q})" \
    --bind "space:toggle-preview" \
    --bind "$DASH_KEY_PREVIEW:toggle-preview" \
    --bind "$DASH_KEY_SCOPE:execute-silent(bash $SELF toggle-scope; : > '$RESTART')+abort" \
    --bind "?:execute-silent(bash $SELF toggle-raw)+reload(bash $SELF rows {q})" \
    --bind "tab:execute-silent(bash $SELF toggle-bucket {1})+reload(bash $SELF rows {q})" \
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
