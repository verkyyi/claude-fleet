#!/bin/bash
# fleet-feedback.sh — one sentence from a session becomes a feedback number
# (issue #3358, EPIC #3354 C4). The fleet-feedback plugin's /fleet-feedback runs
# it; a person may run it by hand too (bash-guard's _DIRECT_TOOLS does not take it).
#
#   fleet-feedback.sh preview [--attach] <text | ->   what WOULD go out — nothing is sent,
#                                                     no token is read
#   fleet-feedback.sh send    [--attach] <text | ->   send it; prints the 反馈号 F…
#   fleet-feedback.sh outbox                          send what was kept while the hub was
#                                                     away (the diskguard tick runs it)
#   fleet-feedback.sh status                          hub · token · plugin · outbox, one line each
#
# `-` (or no text) reads the sentence from stdin — the command body hands it over
# a quoted heredoc, so no quote the person typed can break the shell line.
#
# What goes out (POST /v1/node/feedback, multipart — docs/dev/FLEET-HUB.md «Feedback»):
#   text    the sentence, through conf/secret-shapes.list (bin/fleet_redact.py)
#   ctx     fleet_version (@agent_ver, else the install's version) · agent (claude |
#           codex) · machine_kind (managed-mac | managed-linux | own: fleet_node_manages)
#           · worker_id (fleet_worker_id) · cc_session (the Claude session this runs
#           under) · window (its name)
#   attach  only with --attach (asked every time): the rows of conf/debug-collect.list
#           written in the last FLEET_FEEDBACK_LOG_MINS (30) minutes, their last N lines,
#           and this window's screen (`capture-pane -p`), each through the same table
# Then EVERYTHING that would go out is scanned once more (fleet_redact.py --check):
# one hit ⇒ nothing is sent, exit 3, the part named — the same rule as the
# diagnosis bundle (bin/fleet-doctor-bundle.sh). The hub checks again (422).
#
# The node token is read ONLY inside the subshell that runs curl (_fleet_hub_env,
# issue #1491) — never exported to this script, let alone the session.
# Hub unreachable (or 5xx) ⇒ the redacted feedback is kept in
# $FLEET_CONF_DIR/feedback-outbox/<id>/ (0700) for FLEET_FEEDBACK_OUTBOX_DAYS (3);
# `outbox` sends each one once — the entry is taken out of the box before it is
# posted, so two ticks never send it twice — and tells the session that wrote it
# its F number (fleet-peer-send.sh wid:<worker_id>).
#
# Exit: 0 sent (outbox / status: done) · 1 anything else (said in one line) ·
#       2 没开: usage, no hub or node token here, or the hub has no feedback desk ·
#       3 遮不干净 — refused, nothing sent · 4 限频 (the hub's sentence, nothing kept) ·
#       5 kept in the outbox, sent later.
# Log: $FLEET_CONF_DIR/logs/feedback.log — time · result · F number · sizes; never the words.
# Seams (tests): FLEET_HUB_CURL (curl), FLEET_FEEDBACK_MACHINE_KIND, FLEET_FEEDBACK_SCREEN_CMD
#   (prints the screen), FLEET_FEEDBACK_PEER_SEND (fleet-peer-send.sh), FLEET_FEEDBACK_SHAPES
#   (the shapes table), FLEET_FEEDBACK_COLLECT (the collect list), FLEET_FEEDBACK_PLUGIN_SETTINGS.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
# shellcheck source=/dev/null
[ -f "$BIN/fleet-daemon-lib.sh" ] && . "$BIN/fleet-daemon-lib.sh" 2>/dev/null

CONF="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
OUTBOX="$CONF/feedback-outbox"
LOG="$CONF/logs/feedback.log"
SHAPES="${FLEET_FEEDBACK_SHAPES:-$BIN/../conf/secret-shapes.list}"
COLLECT="${FLEET_FEEDBACK_COLLECT:-$BIN/../conf/debug-collect.list}"
LOG_MINS="${FLEET_FEEDBACK_LOG_MINS:-30}"
KEEP_DAYS="${FLEET_FEEDBACK_OUTBOX_DAYS:-3}"
CURL="${FLEET_HUB_CURL:-curl}"
PLUGIN="fleet-feedback@claude-fleet"

usage() { sed -n '2,16p' "$0" >&2; exit 2; }
logline() {
  mkdir -p "${LOG%/*}" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}

STAGE=''
cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT

# --- context ------------------------------------------------------------------------
kind_word() {
  case "$1" in
    managed-mac) printf '托管 Mac 机器' ;; managed-linux) printf '托管 Linux 机器' ;; *) printf '自己的电脑' ;;
  esac
}
machine_kind() {
  if [ -n "${FLEET_FEEDBACK_MACHINE_KIND:-}" ]; then printf '%s' "$FLEET_FEEDBACK_MACHINE_KIND"; return; fi
  if type fleet_node_manages >/dev/null 2>&1 && fleet_node_manages; then
    case "$(uname -s)" in Darwin) printf 'managed-mac' ;; *) printf 'managed-linux' ;; esac
  else
    printf 'own'
  fi
}
install_ver() {
  local r b
  r=$(cd "$BIN/.." 2>/dev/null && pwd -P) || r=''
  b=${r##*/}
  if printf '%s' "$b" | grep -Eqx '[0-9a-f]{7,40}'; then printf '%s' "$b" | cut -c1-12; return; fi
  git -C "$BIN/.." rev-parse --short=12 HEAD 2>/dev/null || true
}
# the Claude session this runs under: the first ancestor with a registry record
cc_session() {
  local p="$PPID" i=0 s
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$i" -lt 12 ]; do
    if [ -f "${FLEET_CC_SESSIONS_DIR:-$HOME/.claude/sessions}/$p.json" ] && type fleet_cc_session_id >/dev/null 2>&1; then
      s=$(fleet_cc_session_id "$p" 2>/dev/null) && [ -n "$s" ] && { printf '%s' "$s"; return; }
    fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i + 1))
  done
}

CTX_VER='' CTX_AGENT='' CTX_KIND='' CTX_WID='' CTX_CCS='' CTX_WIN='' CTX_WINID='' CTX_SESS=''
ctx_collect() {
  local a=''
  if type fleet_pane_fmt >/dev/null 2>&1 && [ -n "${TMUX_PANE:-}" ]; then
    CTX_SESS=$(fleet_pane_fmt "$FLEET_SESSION_FMT") || CTX_SESS=''
    CTX_WINID=$(fleet_pane_fmt '#{window_id}') || CTX_WINID=''
    CTX_WIN=$(fleet_pane_fmt '#{window_name}') || CTX_WIN=''
    CTX_VER=$(fleet_pane_fmt '#{@agent_ver}') || CTX_VER=''
    a=$(fleet_pane_fmt '#{@cc_agent}') || a=''
    if [ -n "$CTX_SESS" ] && [ -n "$CTX_WINID" ]; then
      CTX_WID=$(fleet_worker_id "$CTX_SESS" "$CTX_WINID" 2>/dev/null) || CTX_WID=''
    fi
  fi
  [ -n "$CTX_VER" ] || CTX_VER=$(install_ver)
  case "$a" in codex*) CTX_AGENT=codex ;; *) CTX_AGENT=claude ;; esac
  [ -n "${CODEX_THREAD_ID:-}${CODEX_SESSION_ID:-}" ] && [ -z "$a" ] && CTX_AGENT=codex
  CTX_KIND=$(machine_kind)
  CTX_CCS=$(cc_session)
  [ -n "$CTX_CCS" ] || CTX_CCS="${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}"
  return 0
}
ctx_json() {
  python3 - "$CTX_VER" "$CTX_AGENT" "$CTX_KIND" "$CTX_WID" "$CTX_CCS" "$CTX_WIN" <<'PY'
import json, sys
keys = ("fleet_version", "agent", "machine_kind", "worker_id", "cc_session", "window")
print(json.dumps({k: v for k, v in zip(keys, sys.argv[1:]) if v}, ensure_ascii=False))
PY
}

# --- redaction ----------------------------------------------------------------------
redact() {  # redact <in> <out> <stats>
  python3 "$BIN/fleet_redact.py" --table "$SHAPES" --stats "$3" < "$1" > "$2"
}
# stats files → "N<TAB>name name …"
stats_sum() {
  [ "$#" -gt 0 ] || { printf '0\t'; return 0; }
  cat "$@" 2>/dev/null | awk -F'\t' 'NF == 2 { n += $2; if (!(($1) in s)) { s[$1] = 1; o = o (o ? " " : "") $1 } }
    END { printf "%d\t%s", n, o }'
}

# collect <text file> <attach yes|no> — fills $STAGE: text, ctx.json, attach/*,
# and the stats; sets RED_TEXT / RED_ATT ("N<TAB>names") and ATT_LOGS / ATT_SCREEN.
RED_TEXT='' RED_ATT='' ATT_LOGS='' ATT_SCREEN=0
collect() {
  local src="$1" want="$2" bp s n f exp b
  [ -f "$SHAPES" ] || { printf 'fleet-feedback：找不到遮密钥的形状表（%s），不发。\n' "$SHAPES" >&2; exit 1; }
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fleet-feedback.XXXXXX") || exit 1
  chmod 700 "$STAGE"
  mkdir -p "$STAGE/attach" "$STAGE/raw" "$STAGE/st"
  redact "$src" "$STAGE/text" "$STAGE/st/text" || { printf 'fleet-feedback：遮密钥失败，不发。\n' >&2; exit 1; }
  # the sentence ends without the newline the redactor writes back
  printf '%s' "$(cat "$STAGE/text")" > "$STAGE/text.1" && mv -f "$STAGE/text.1" "$STAGE/text"
  RED_TEXT=$(stats_sum "$STAGE/st/text")
  ctx_collect
  ctx_json > "$STAGE/ctx.json"
  [ "$want" = yes ] || return 0
  # logs: the collect list's rows touched in the last LOG_MINS minutes
  if [ -f "$COLLECT" ]; then
    while IFS=$'\t' read -r bp s n; do
      case "$bp" in ''|'#'*) continue ;; esac
      # shellcheck disable=SC2088  # the list's literal ~/ prefix, matched, never expanded
      case "$s" in
        '~/'*)            exp="$HOME/${s#\~/}" ;;
        '$SHELL_CACHE/'*) exp="${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}/${s#\$SHELL_CACHE/}" ;;
        '$CONF_DIR/'*)    exp="$CONF/${s#\$CONF_DIR/}" ;;
        *)                exp="$s" ;;
      esac
      [ -f "$exp" ] || continue
      [ -n "$(find "$exp" -mmin "-$LOG_MINS" 2>/dev/null)" ] || continue
      b="log-$(printf '%s' "${bp##*/}" | tr -c 'A-Za-z0-9._-' '_')"
      tail -n "${n:-200}" "$exp" > "$STAGE/raw/$b" 2>/dev/null || continue
      redact "$STAGE/raw/$b" "$STAGE/attach/$b" "$STAGE/st/$b" || { printf 'fleet-feedback：遮密钥失败（%s），不发。\n' "$bp" >&2; exit 1; }
      ATT_LOGS="$ATT_LOGS${ATT_LOGS:+、}${bp##*/}"
    done < "$COLLECT"
  fi
  # this window's screen
  if [ -n "${FLEET_FEEDBACK_SCREEN_CMD:-}" ]; then
    sh -c "$FLEET_FEEDBACK_SCREEN_CMD" > "$STAGE/raw/screen.txt" 2>/dev/null || :
  elif [ -n "${TMUX_PANE:-}" ]; then
    tmux capture-pane -p -t "$TMUX_PANE" > "$STAGE/raw/screen.txt" 2>/dev/null || :
  fi
  if [ -s "$STAGE/raw/screen.txt" ]; then
    redact "$STAGE/raw/screen.txt" "$STAGE/attach/screen.txt" "$STAGE/st/screen" || { printf 'fleet-feedback：遮密钥失败（屏幕），不发。\n' >&2; exit 1; }
    ATT_SCREEN=$(wc -l < "$STAGE/attach/screen.txt" | tr -d ' ')
  fi
  rm -rf "$STAGE/raw"
  set --
  for f in "$STAGE"/st/*; do [ -f "$f" ] && [ "${f##*/}" != text ] && set -- "$@" "$f"; done
  RED_ATT=$(stats_sum ${@+"$@"})
  return 0
}

# recheck — the whole outgoing set scanned again; a hit ⇒ exit 3, the part named
recheck() {
  local hits f part
  set -- "$STAGE/text" "$STAGE/ctx.json"
  for f in "$STAGE"/attach/*; do [ -f "$f" ] && set -- "$@" "$f"; done
  hits=$(python3 "$BIN/fleet_redact.py" --table "$SHAPES" --check "$@" 2>/dev/null) && return 0
  [ -n "$hits" ] || { printf 'fleet-feedback：查不了还有没有密钥，不发。\n' >&2; exit 1; }
  part=$(printf '%s\n' "$hits" | head -n 1 | cut -f1)
  case "$part" in
    */text) part='原话' ;; */ctx.json) part='自动带上的信息' ;; */screen.txt) part='屏幕' ;; *) part="日志 ${part##*/}" ;;
  esac
  printf '%s里还有像密码或令牌的东西（%s），遮不干净 — 没发，什么都没留下。改一下再发。\n' \
    "$part" "$(printf '%s\n' "$hits" | head -n 1 | cut -f2)"
  logline "refused-unclean	$part"
  exit 3
}

read_text() {  # read_text <arg…> → $STAGE-independent temp file in $TXT
  TXT=$(mktemp "${TMPDIR:-/tmp}/fleet-feedback-text.XXXXXX") || exit 1
  if [ "$#" -eq 0 ] || [ "$*" = - ]; then cat > "$TXT"; else printf '%s' "$*" > "$TXT"; fi
  if ! grep -q '[^[:space:]]' "$TXT"; then
    rm -f "$TXT"; printf '反馈是空的：/fleet-feedback 后面写一句话再发。\n' >&2; exit 2
  fi
}

# --- the hub ------------------------------------------------------------------------
hub_ready() {  # the token is looked at inside a subshell only — never kept here
  ( type _fleet_hub_env >/dev/null 2>&1 && _fleet_hub_env
    [ -n "${CCQUOTA_HUB_URL:-}" ] || CCQUOTA_HUB_URL=$( . "$BIN/fleet-hub-url.sh" --lib 2>/dev/null && fleet_hub_url 2>/dev/null)
    [ -n "${CCQUOTA_TOKEN:-}" ] && [ -n "${CCQUOTA_HUB_URL:-}" ] )
}

# post <dir> → "<http code>\n<json>" on stdout, curl's rc as the return
post() {
  local d="$1" f
  set -- -F "text=<$d/text" -F "ctx=<$d/ctx.json;type=application/json"
  for f in "$d"/attach/*; do [ -f "$f" ] && set -- "$@" -F "attach=@$f;filename=${f##*/}"; done
  ( type _fleet_hub_env >/dev/null 2>&1 && _fleet_hub_env
    [ -n "${CCQUOTA_HUB_URL:-}" ] || CCQUOTA_HUB_URL=$( . "$BIN/fleet-hub-url.sh" --lib 2>/dev/null && fleet_hub_url 2>/dev/null)
    "$CURL" -sS --connect-timeout "${FLEET_FEEDBACK_CONNECT_SECS:-3}" --max-time "${FLEET_HUB_TIMEOUT:-30}" \
      -o - -w '\n%{http_code}' -H "Authorization: Bearer ${CCQUOTA_TOKEN:-}" \
      "$@" "${CCQUOTA_HUB_URL%/}/v1/node/feedback" 2>/dev/null )
}

json_field() {  # json_field <json> <key>
  printf '%s' "$1" | python3 -c 'import json, sys
try: v = json.load(sys.stdin).get(sys.argv[1])
except Exception: v = None
print("" if v is None else v)' "$2" 2>/dev/null
}

# answer <code> <json> <attach yes|no> → the sentence on stdout, the class as rc
# (it runs in $(…): nothing it sets reaches the caller):
# 0 sent · 2 off · 3 secret · 4 limited · 5 retry later · 1 refused for good
answer() {
  local code="$1" json="$2" att="$3" id msg note
  msg=$(json_field "$json" message)
  case "$code" in
    200)
      id=$(json_field "$json" id); note=$(json_field "$json" note)
      [ -n "$id" ] || { printf '入口回的话看不懂（没有反馈号），过一会儿再发。\n'; return 5; }
      printf '已收到，反馈号 %s。处理完会在这里告诉你。' "$id"
      [ "$att" = yes ] && printf '（日志和屏幕只给管理员看，7 天后删）'
      printf '\n'; [ -n "$note" ] && printf '%s\n' "$note"
      return 0 ;;
    429) printf '%s\n（这句话没发出去，也没存。）\n' "${msg:-发得太快了，过一会儿再发。}"; return 4 ;;
    422) printf '%s\n' "${msg:-入口查出里面有像密码或令牌的东西，没收。遮掉再发。}"; return 3 ;;
    404|405) printf '入口还没开反馈这项（%s），这句话没发。\n' "$code"; return 2 ;;
    401) printf '入口不认这台机器的节点令牌（401），这句话没发；请找管理员。\n'; return 1 ;;
    403|400|413) printf '%s\n' "${msg:-入口没收这条反馈（HTTP ${code}）。}"; return 1 ;;
    *) return 5 ;;
  esac
}

# --- outbox -------------------------------------------------------------------------
keep() {  # keep the staged feedback (already redacted and checked) for later
  local id
  id="$(date +%s)-$$-$RANDOM"
  mkdir -p "$OUTBOX" && chmod 700 "$OUTBOX" 2>/dev/null
  mkdir "$OUTBOX/.$id" 2>/dev/null || return 1
  cp -R "$STAGE/text" "$STAGE/ctx.json" "$STAGE/attach" "$OUTBOX/.$id/" 2>/dev/null || { rm -rf "$OUTBOX/.$id"; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$CTX_WID" "$CTX_SESS" "$CTX_WINID" "$1" > "$OUTBOX/.$id/origin"
  mv "$OUTBOX/.$id" "$OUTBOX/$id"   # whole or not at all: a tick never reads a half entry
}

tell() {  # tell <origin file> <sentence>
  local wid _rest
  IFS=$'\t' read -r wid _rest < "$1" 2>/dev/null || return 0
  [ -n "$wid" ] || return 0
  "${FLEET_FEEDBACK_PEER_SEND:-$BIN/fleet-peer-send.sh}" "wid:$wid" "fleet：$2" >/dev/null 2>&1 || true
}

flush() {
  local e name age now taken resp rc code json att sent=0 kept=0
  [ -d "$OUTBOX" ] || exit 0
  mkdir "$OUTBOX/.lock" 2>/dev/null || {
    # a lock older than ten minutes is a killed tick's
    [ -n "$(find "$OUTBOX/.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] && rm -rf "$OUTBOX/.lock" && mkdir "$OUTBOX/.lock" 2>/dev/null || exit 0
  }
  trap 'rm -rf "$OUTBOX/.lock"; cleanup' EXIT
  now=$(date +%s)
  for e in "$OUTBOX"/*; do
    [ -d "$e" ] || continue
    name=${e##*/}
    age=$(( now - ${name%%-*} ))
    att=no; [ -n "$(ls "$e/attach" 2>/dev/null)" ] && att=yes
    if [ "$age" -gt $(( KEEP_DAYS * 86400 )) ]; then
      tell "$e/origin" "你 ${KEEP_DAYS} 天前存着的反馈一直没连上入口，已经丢掉了；还想说就再发一次。"
      rm -rf "$e"; logline "outbox-expired	$name"; continue
    fi
    # taken out of the box BEFORE it is posted: a second tick never sends it again
    taken="$OUTBOX/.sending-$name"
    mv "$e" "$taken" 2>/dev/null || continue
    hub_ready || { mv "$taken" "$e"; kept=$((kept + 1)); continue; }
    resp=$(post "$taken"); rc=$?
    code=$(printf '%s\n' "$resp" | tail -n 1); json=$(printf '%s\n' "$resp" | sed '$d')
    [ "$rc" -eq 0 ] || code=000
    ANSWER_ID=$(json_field "$json" id)
    msg=$(answer "$code" "$json" "$att"); rc=$?
    case "$rc" in
      0) tell "$taken/origin" "你之前存着的反馈已经发出：$msg"
         rm -rf "$taken"; sent=$((sent + 1)); logline "outbox-sent	$ANSWER_ID	$name" ;;
      5|4|2) mv "$taken" "$e"; kept=$((kept + 1)); logline "outbox-kept	$code	$name" ;;
      *) tell "$taken/origin" "你之前存着的反馈入口没收：$msg"
         rm -rf "$taken"; logline "outbox-refused	$code	$name" ;;
    esac
  done
  [ "$sent$kept" = 00 ] || printf 'outbox: sent %s, kept %s\n' "$sent" "$kept"
  exit 0
}

# --- commands -----------------------------------------------------------------------
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
ATTACH=no
while [ "$#" -gt 0 ]; do
  case "$1" in --attach) ATTACH=yes; shift ;; --) shift; break ;; -h|--help) usage ;; *) break ;; esac
done

case "$cmd" in
  preview)
    read_text "$@"
    collect "$TXT" yes; rm -f "$TXT"
    recheck
    n=${RED_TEXT%%	*}; names=${RED_TEXT#*	}
    printf '将发出（还没发）\n'
    printf '  原话：「%s」\n' "$(cat "$STAGE/text")"
    [ "$n" -gt 0 ] && printf '  已遮掉原话里 %s 处像密码或令牌的东西（%s）\n' "$n" "$names"
    printf '  自动带上：版本 %s · %s · %s · 这个会话%s\n' "${CTX_VER:-未知}" "$(kind_word "$CTX_KIND")" \
      "$( [ "$CTX_AGENT" = codex ] && echo Codex || echo Claude)" "${CTX_WIN:+（${CTX_WIN}）}"
    printf '  公开到 GitHub 的只有原话、版本和机器类型；你是谁、哪台机器、哪个会话只有管理员在入口能看到。\n'
    printf '可以附上（只给管理员看，7 天后删，密钥先遮掉）：\n'
    if [ -n "$ATT_LOGS" ] || [ "$ATT_SCREEN" -gt 0 ]; then
      [ -n "$ATT_LOGS" ] && printf '  最近 %s 分钟的日志：%s\n' "$LOG_MINS" "$ATT_LOGS"
      [ "$ATT_SCREEN" -gt 0 ] && printf '  当前屏幕：%s 行\n' "$ATT_SCREEN"
      n=${RED_ATT%%	*}; names=${RED_ATT#*	}
      [ "$n" -gt 0 ] && printf '  已遮掉 %s 处像密码或令牌的东西（%s）\n' "$n" "$names"
    else
      printf '  （这里没有最近的日志，也读不到屏幕 — 附上也只发原话）\n'
    fi
    exit 0 ;;
  send)
    read_text "$@"
    collect "$TXT" "$ATTACH"; rm -f "$TXT"
    recheck
    if ! hub_ready; then
      printf '这台电脑没接入口（没有入口地址或节点令牌），反馈发不出去。\n'
      logline "off	no-hub"; exit 2
    fi
    resp=$(post "$STAGE"); rc=$?
    code=$(printf '%s\n' "$resp" | tail -n 1); json=$(printf '%s\n' "$resp" | sed '$d')
    [ "$rc" -eq 0 ] || code=000
    ANSWER_ID=$(json_field "$json" id)
    msg=$(answer "$code" "$json" "$ATTACH"); rc=$?
    case "$rc" in
      0) printf '%s\n' "$msg"; logline "sent	$ANSWER_ID	attach=$ATTACH"; exit 0 ;;
      5) if keep "$ATTACH"; then
           printf '入口暂时连不上（%s），先存在这台机器上，连上后自动发出（最多存 %s 天）。会话里会再告诉你反馈号。\n' \
             "$( [ "$code" = 000 ] && echo 连不上 || echo "HTTP $code")" "$KEEP_DAYS"
           logline "kept	$code"; exit 5
         fi
         printf '入口暂时连不上，本机也存不下（%s），这句话没发；过一会儿再发。\n' "$OUTBOX"; exit 1 ;;
      *) printf '%s\n' "$msg"; logline "refused	$code"; exit "$rc" ;;
    esac ;;
  outbox) flush ;;
  status)
    if hub_ready; then echo 'hub     有入口地址和节点令牌'; else echo 'hub     没有（这台电脑发不了反馈）'; fi
    f="${FLEET_FEEDBACK_PLUGIN_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
    if [ -f "$f" ] && python3 -c 'import json, sys
sys.exit(0 if json.load(open(sys.argv[1])).get("enabledPlugins", {}).get(sys.argv[2]) is True else 1)' "$f" "$PLUGIN" 2>/dev/null
    then echo 'plugin  开（/fleet-feedback 可用）'; else echo 'plugin  没开'; fi
    n=0; for e in "$OUTBOX"/*; do [ -d "$e" ] && n=$((n + 1)); done
    echo "outbox  $n 条待补发"
    exit 0 ;;
  *) usage ;;
esac
