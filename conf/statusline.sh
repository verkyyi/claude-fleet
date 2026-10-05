#!/usr/bin/env bash
# conf/statusline.sh — Claude Code's status line, run as the fleet's MEASUREMENT BUS.
#
# Claude Code runs this command on every status-line redraw with a JSON on stdin
# (schema: https://code.claude.com/docs/en/statusline). Since issue #1452 it PRINTS
# NOTHING — the bottom status line is gone; the operator reads the context %, the
# model and the effort level on the pane's TOP border instead (the right-aligned
# segment of pane-border-format in conf/tmux-attention.conf). The command stays
# wired in settings.json because this stdin JSON is the only place the fleet learns
# these numbers. Each render stamps them onto this pane's WINDOW as tmux options —
# the same state bus as @claude_state / @issue:
#
#   .context_window.used_percentage      → @ctx_pct    rounded % (issue #330: the
#                                           auto-handoff nudge, bin/fleet-context.sh)
#   .context_window.context_window_size  → @ctx_limit  the window SIZE — the only
#                                           place the fleet can learn it (#477)
#   those two + the fleet's handoff lines → @ctx_band   ok | watch | handoff — the
#                                           header's colour (#1452). Same bands as
#                                           fleet-context.sh: with
#                                           FLEET_AUTO_HANDOFF_PCT (or _TOKENS,
#                                           converted against @ctx_limit the way
#                                           set-claude-state.sh does, #1317) the
#                                           handoff line is red and 15 points below
#                                           it is yellow (unset ⇒ 80, #1571); with
#                                           it 0 and no _TOKENS, 80 / 50.
#   .model.display_name                  → @model      e.g. "Opus 5.5" (#1452)
#   .effort.level                        → @effort     low … max — present only
#                                           when the model has an effort level;
#                                           UNSET otherwise, so a model switch
#                                           cannot leave a stale one (#1452)
#   .rate_limits.five_hour / .seven_day  → @rl5h @rl7d @rl_reset @rl_ts (#1267: the
#                                           quota watch merges them per @cc_account;
#                                           both windows or nothing)
#   (mod feed only, issue #1459)         → @ctx_src mod  beside @ctx_pct, and
#                                           @rl_src mod beside the @rl* set — who
#                                           fed the bus (bin/fleet-statusline.sh)
#
# Cost per render: one jq pass, one tmux read, and at most ONE tmux write chain —
# a stamp is written only when its value CHANGED since the last render, so an idle
# pane costs tmux nothing. The @rl_* set is the one exception: its @rl_ts IS the
# freshness the quota watch reads, so it is re-stamped on every render that has
# both windows (and it unsets @rl_src: the fleet mod stamps the same set with
# @rl_src=mod, issue #1338).
#
# TWO FEEDERS, ONE WRITER (issue #1459). The same script is also what the fleet
# mod (mod/fleet/hooks/usage.ts) runs to stamp the SAME options from inside the
# session — off `session.measure` (context + rate limits, after every turn),
# `turn.step` (model + effort, per model request) and a model poll — so a login
# that removes `statusLine` from settings.json (`bin/fleet-statusline.sh off`,
# which also gives the pane its bottom row back) loses nothing: the field names,
# the rounding and the @ctx_band lines are this one file's, whoever feeds it.
#
#   statusline.sh                              Claude Code: the JSON on stdin
#   statusline.sh --from mod key=value …       the mod: the same fields as argv —
#       ctx_pct ctx_limit model effort rl5h rl7d rl_reset5 rl_reset7; a key
#       absent = not in this reading (left alone), exactly as an absent JSON
#       path is. No stdin, no jq. Two extra stamps say who fed the bus:
#       @ctx_src mod (beside @ctx_pct) and @rl_src mod (where the Claude path
#       UNSETS @rl_src). The Claude path never touches @ctx_src, so once the mod
#       has stamped a window it stays marked — `fleet-statusline.sh status`
#       counts those marks before the operator turns the statusLine off.
#
# While both feed the same window the newest write wins; they agree on every
# value by construction, so the only visible seam is the model's spelling (the
# mod derives the display name from the model id — mod/fleet/hooks/usage.ts).
#
# Outside tmux there is no bus: nothing is stamped and nothing is printed. The
# old visible line's cwd + git-branch segments went with it (#1452 — the window
# name and the task bar show both), so this never runs git.
# Requires: jq on the Claude path (silently exits if absent); none on the mod's.

FROM=''
if [[ "${1:-}" == --from ]]; then FROM="${2:-}"; shift 2; fi

US=$'\x1f'   # field separator — never whitespace, so `read` keeps EMPTY fields

if [[ "$FROM" == mod ]]; then
  # ── the mod's reading: key=value argv, no stdin ─────────────────────────────
  [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] || exit 0
  CTX_PCT='' CTX_SIZE='' MODEL='' EFFORT='' RL5='-' RL7='-' RLR5='-' RLR7='-'
  for kv in "$@"; do
    case "$kv" in
      ctx_pct=*)   CTX_PCT=${kv#*=} ;;
      ctx_limit=*) CTX_SIZE=${kv#*=} ;;
      model=*)     MODEL=${kv#*=} ;;
      effort=*)    EFFORT=${kv#*=} ;;
      rl5h=*)      RL5=${kv#*=} ;;
      rl7d=*)      RL7=${kv#*=} ;;
      rl_reset5=*) RLR5=${kv#*=} ;;
      rl_reset7=*) RLR7=${kv#*=} ;;
    esac
  done
  # The jq path floors a decimal %; floor the mod's the same way.
  [[ "$RL5" =~ ^[0-9]+\.[0-9]+$ ]] && RL5=${RL5%%.*}
  [[ "$RL7" =~ ^[0-9]+\.[0-9]+$ ]] && RL7=${RL7%%.*}
else
  # ── Claude Code's render: the status-line JSON on stdin ─────────────────────
  command -v jq >/dev/null 2>&1 || exit 0
  INPUT=$(cat)
  [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] || exit 0

  # One jq pass over the whole payload. `(path)? // null` swallows a
  # wrongly-typed parent ({"rate_limits":"weird"}, {"effort":"x"}) and still
  # yields one element per field, so the join stays aligned. Rate-limit fields:
  # numbers floor to an integer, anything else is `-` (both % must be numbers,
  # or nothing is stamped — the watch reads a half stamp as none).
  FIELDS=$(jq -r '
    def str: if . == null then "" else tostring end;
    def num: if type == "number" then (floor | tostring) else "-" end;
    [ ((.context_window.used_percentage)?        // null | str),
      ((.context_window.context_window_size)?    // null | str),
      ((.model.display_name)?                    // null | str),
      ((.effort.level)?                          // null | str),
      ((.rate_limits.five_hour.used_percentage)? // null | num),
      ((.rate_limits.seven_day.used_percentage)? // null | num),
      ((.rate_limits.five_hour.resets_at)?       // null | num),
      ((.rate_limits.seven_day.resets_at)?       // null | num) ]
    | join("\u001f")' <<< "$INPUT" 2>/dev/null) || exit 0
  IFS=$US read -r CTX_PCT CTX_SIZE MODEL EFFORT RL5 RL7 RLR5 RLR7 <<< "$FIELDS"
fi

# ── what this render wants on the bus ───────────────────────────────────────
# '' = leave the option as it is (no reading this render); the band / effort
# rules below are the only places '' means UNSET.
want_pct='' want_limit='' want_band=''
if [[ "$CTX_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  want_pct=$(printf '%.0f' "$CTX_PCT")
  [[ "$CTX_SIZE" =~ ^[0-9]+(\.[0-9]+)?$ ]] && want_limit=${CTX_SIZE%%.*}

  # The handoff lines, read the CHEAP way — never by sourcing fleet-lib (≈200 ms
  # through fleet-hook-conf.sh; this is the per-render hot path). Precedence is
  # what a sourcing script sees (issue #561): the environment is the floor, the
  # install's fleet.conf overrides it, then $FLEET_CONF_DIR/fleet.settings (the
  # order fleet-lib sources them), then THIS fleet's overlay — fleets/<sess>/conf,
  # legacy <sess>.conf — where the socket label is the fleet (issue #159). File
  # tests and one awk; the last assignment wins, quotes and a trailing comment
  # are stripped. statusline-selftest.sh pins the layering.
  SL_PCT="${FLEET_AUTO_HANDOFF_PCT:-}" SL_TOK="${FLEET_AUTO_HANDOFF_TOKENS:-}"
  SL_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
  SL_HERE="${BASH_SOURCE[0]%/*}"
  [[ "$SL_HERE" == "${BASH_SOURCE[0]}" ]] && SL_HERE=.
  SL_SOCK="${TMUX%%,*}"; SL_SOCK="${SL_SOCK##*/}"
  SL_FILES=()
  [[ -f "$SL_HERE/../fleet.conf" ]] && SL_FILES+=("$SL_HERE/../fleet.conf")
  [[ -f "$SL_CONF_DIR/fleet.settings" ]] && SL_FILES+=("$SL_CONF_DIR/fleet.settings")
  [[ -f "$SL_CONF_DIR/fleet.conf" ]] && SL_FILES+=("$SL_CONF_DIR/fleet.conf")   # the one file (#1623)
  if [[ -n "$SL_SOCK" ]]; then
    if   [[ -f "$SL_CONF_DIR/fleets/$SL_SOCK/conf" ]]; then SL_FILES+=("$SL_CONF_DIR/fleets/$SL_SOCK/conf")
    elif [[ -f "$SL_CONF_DIR/$SL_SOCK.conf" ]];        then SL_FILES+=("$SL_CONF_DIR/$SL_SOCK.conf")
    fi
  fi
  if [[ ${#SL_FILES[@]} -gt 0 ]]; then
    SL_KV=$(awk '/^[[:space:]]*(export[[:space:]]+)?FLEET_AUTO_HANDOFF_(PCT|TOKENS)=/ {
                   k = $0; sub(/^[[:space:]]*(export[[:space:]]+)?/, "", k); sub(/=.*$/, "", k)
                   v = $0; sub(/^[^=]*=/, "", v); sub(/[[:space:]]+#.*$/, "", v); gsub(/["\047[:space:]]/, "", v)
                   val[k] = v }
                 END { print val["FLEET_AUTO_HANDOFF_PCT"]; print val["FLEET_AUTO_HANDOFF_TOKENS"] }' \
            ${SL_FILES[@]+"${SL_FILES[@]}"} 2>/dev/null)
    SL_V=${SL_KV%%$'\n'*}; [[ -n "$SL_V" ]] && SL_PCT=$SL_V
    SL_V=${SL_KV#*$'\n'};  [[ "$SL_V" != "$SL_KV" && -n "$SL_V" ]] && SL_TOK=$SL_V
  fi
  [[ -z "$SL_PCT" ]] && SL_PCT=80                 # the hook's unset ⇒ 80 (issue #1571)
  [[ "$SL_PCT" =~ ^[0-9]+$ ]] || SL_PCT=0
  [[ "$SL_TOK" =~ ^[0-9]+$ ]] || SL_TOK=0
  # A line set in TOKENS wins over the % key, converted against this window's
  # size — rounded up, clamped to 100, exactly as set-claude-state.sh does
  # (#1317); no readable size ⇒ the % key.
  hand=$SL_PCT
  if (( SL_TOK > 0 )) && [[ -n "$want_limit" ]] && (( want_limit > 0 )); then
    hand=$(( (SL_TOK * 100 + want_limit - 1) / want_limit )); (( hand > 100 )) && hand=100
  fi
  if (( hand > 0 )); then warn=$(( hand - 15 )); (( warn < 1 )) && warn=1
  else hand=80; warn=50; fi                      # fleet-context.sh's own fallback bands
  if   (( want_pct >= hand )); then want_band=handoff
  elif (( want_pct >= warn )); then want_band=watch
  else                              want_band=ok; fi
fi

# ── one read of what is on the bus now; queue only what differs ─────────────
CUR=$(tmux display-message -p -t "$TMUX_PANE" \
        "#{@ctx_pct}${US}#{@ctx_limit}${US}#{@ctx_band}${US}#{@model}${US}#{@effort}${US}#{@ctx_src}" 2>/dev/null)
IFS=$US read -r cur_pct cur_limit cur_band cur_model cur_effort cur_src <<< "$CUR"

ARGS=()
# stamp <option> <want> <have> — queue a set (want='' ⇒ an unset) when they differ.
stamp() {
  [[ "$2" == "$3" ]] && return 0
  [[ ${#ARGS[@]} -gt 0 ]] && ARGS+=(\;)
  if [[ -n "$2" ]]; then ARGS+=(set-window-option -t "$TMUX_PANE" "$1" "$2")
  else                   ARGS+=(set-window-option -u -t "$TMUX_PANE" "$1"); fi
}
if [[ -n "$want_pct" ]]; then
  stamp @ctx_pct  "$want_pct"  "$cur_pct"
  [[ -n "$want_limit" ]] && stamp @ctx_limit "$want_limit" "$cur_limit"
  stamp @ctx_band "$want_band" "$cur_band"
  [[ "$FROM" == mod ]] && stamp @ctx_src mod "$cur_src"   # the Claude path never touches it
fi
if [[ -n "$MODEL" ]]; then
  stamp @model  "$MODEL"  "$cur_model"
  stamp @effort "$EFFORT" "$cur_effort"      # '' ⇒ unset: this model has no effort level
fi
if [[ "$RL5" =~ ^[0-9]+$ && "$RL7" =~ ^[0-9]+$ ]]; then
  [[ ${#ARGS[@]} -gt 0 ]] && ARGS+=(\;)
  ARGS+=(set-window-option -t "$TMUX_PANE" @rl5h "$RL5" \; \
         set-window-option -t "$TMUX_PANE" @rl7d "$RL7" \; \
         set-window-option -t "$TMUX_PANE" @rl_reset "$RLR5 $RLR7" \; \
         set-window-option -t "$TMUX_PANE" @rl_ts "$(date +%s)" \;)
  if [[ "$FROM" == mod ]]; then ARGS+=(set-window-option -t "$TMUX_PANE" @rl_src mod)
  else                          ARGS+=(set-window-option -u -t "$TMUX_PANE" @rl_src); fi
fi
[[ ${#ARGS[@]} -gt 0 ]] && tmux ${ARGS[@]+"${ARGS[@]}"} 2>/dev/null
exit 0
