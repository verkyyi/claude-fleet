#!/bin/bash
# fleet-feedback-selftest.sh — bin/fleet-feedback.sh, the session half of
# /fleet-feedback (issue #3358, EPIC #3354 C4), against a fake hub (a curl shim)
# and an isolated tmux server (the window's name, its screen).
#
#   A  preview sends nothing: no curl, no outbox; it names what is public
#   B  a sample of conf/secret-shapes.list in the words, a log and the screen: the
#      preview says each was masked, and the bytes that go out hold none of them
#   C  the answers: 200 → 反馈号 F12 (0) · 429 → the hub's sentence, nothing kept (4) ·
#      422 → refused (3) · 404 → 没开 (2) · no token → 没开 (2) · unreachable → kept (5)
#   D  the outbox: one kept feedback is sent once and only once, its session told the
#      F number; an entry older than the keep is dropped
#   E  遮不干净: a secret in what is sent along (the window's name) ⇒ exit 3, no curl
#   F  the node token never reaches anything the script starts but curl
#   G  zsh (#1633) and bash 3.2 (#703) run it
#   H  wiring: the diskguard tick runs the outbox; the plugin's command calls the script
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
FB="$BIN/fleet-feedback.sh"
CHECKS=0
ok() { CHECKS=$((CHECKS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; exit 1; }
has() { case "$2" in *"$1"*) ok ;; *) fail "$3" "$2" ;; esac; }
hasnt() { case "$2" in *"$1"*) fail "$3" "$2" ;; *) ok ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbst.XXXXXX")
SOCK="fbst-$$"
REAL_TMUX=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -) command -v tmux || true)
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$TMPDIR" "$XDG_CACHE_HOME/claude-fleet/shell/logs"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL TMUX TMUX_PANE
export FLEET_FEEDBACK_MACHINE_KIND=managed-linux
TOKEN="nodetok-FAKE-$$"
printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=%s\n' "$TOKEN" > "$FLEET_CONF_DIR/node.env"

# the fake hub: answers $WORK/code + $WORK/body; records argv, every -F part's bytes,
# and whether its own environment carried the token
cat > "$WORK/curl" <<SH
#!/bin/bash
echo call >> "$WORK/calls"
: > "$WORK/sent"
prev=''
for a in "\$@"; do
  if [ "\$prev" = -F ]; then
    v=\${a#*=}; v=\${v%%;*}
    case "\$v" in '<'*|'@'*) cat "\${v#?}" >> "$WORK/sent" ;; *) printf '%s' "\$v" >> "$WORK/sent" ;; esac
    printf '\n' >> "$WORK/sent"
  fi
  [ "\$prev" = -H ] && printf '%s\n' "\$a" >> "$WORK/headers"
  prev=\$a
done
printf '%s' "\${@: -1}" > "$WORK/url"
code=\$(cat "$WORK/code")
[ "\$code" = 000 ] && exit 7
cat "$WORK/body"; printf '\n%s' "\$code"
SH
cat > "$WORK/peer-send" <<SH
#!/bin/bash
printf '%s|%s\n' "\$1" "\$2" >> "$WORK/told"
env | grep -c CCQUOTA_TOKEN >> "$WORK/peer-env" || true
SH
chmod +x "$WORK/curl" "$WORK/peer-send"
export FLEET_HUB_CURL="$WORK/curl" FLEET_FEEDBACK_PEER_SEND="$WORK/peer-send"
hub() { printf '%s' "$1" > "$WORK/code"; printf '%s' "$2" > "$WORK/body"; rm -f "$WORK/calls" "$WORK/sent"; }
calls() { [ -f "$WORK/calls" ] && wc -l < "$WORK/calls" | tr -d ' ' || echo 0; }
outbox_n() { local n=0 e; for e in "$FLEET_CONF_DIR/feedback-outbox"/*; do [ -d "$e" ] && n=$((n + 1)); done; echo "$n"; }

# samples off the ONE table (a row each: words · log · screen)
S_TEXT="ghp_FAKEtext$$aaaaaaaaaaaa"
S_LOG="sk-ant-api03-FAKElog$$bbbbbbbb"
S_SCREEN="glpat-FAKEscreen$$cccccccc"
for s in github anthropic gitlab; do grep -q "^$s	" "$ROOT/conf/secret-shapes.list" || fail "the shapes table lost its $s row"; done; ok
printf 'connect m5 relay %s\n' "$S_LOG" > "$XDG_CACHE_HOME/claude-fleet/shell/logs/connect.log"
printf 'old place line\n' > "$XDG_CACHE_HOME/claude-fleet/shell/logs/place.log"
touch -t 202001010000 "$XDG_CACHE_HOME/claude-fleet/shell/logs/place.log"   # older than 30 minutes
export FLEET_FEEDBACK_SCREEN_CMD="printf 'prompt> export X=%s\n' '$S_SCREEN'"
WORDS="⌘P 要等 5 秒 \"引号\" '单引号' \$HOME 令牌 $S_TEXT"

# ---- A: preview sends nothing ----------------------------------------------------------
hub 200 '{"id":"F12","state":"received"}'
out=$(printf '%s\n' "$WORDS" | bash "$FB" preview -); rc=$?
[ "$rc" = 0 ] || fail "A preview rc $rc" "$out"; ok
[ "$(calls)" = 0 ] || fail "A preview called the hub"; ok
[ "$(outbox_n)" = 0 ] || fail "A preview kept something"; ok
has '将发出（还没发）' "$out" "A preview heading"
has '公开到 GitHub 的只有原话、版本和机器类型' "$out" "A preview should say what is public"
has '托管 Linux 机器' "$out" "A machine kind"
has "\$HOME" "$out" "A the words must reach the preview untouched by a shell"

# ---- B: masked in the preview, gone from the bytes ---------------------------------------
for s in "$S_TEXT" "$S_LOG" "$S_SCREEN"; do hasnt "$s" "$out" "B preview shows a secret"; done
has '已遮掉原话里 1 处' "$out" "B the words' mask should be named"
has 'connect.log' "$out" "B a fresh log should be offered"
hasnt 'place.log' "$out" "B a log older than 30 minutes is not offered"
has '已遮掉 2 处像密码或令牌的东西（anthropic gitlab）' "$out" "B the attachments' masks should be named"
out=$(printf '%s\n' "$WORDS" | bash "$FB" send --attach -); rc=$?
[ "$rc" = 0 ] || fail "B send rc $rc" "$out"; ok
has '已收到，反馈号 F12。处理完会在这里告诉你。（日志和屏幕只给管理员看，7 天后删）' "$out" "B the answer"
sent=$(cat "$WORK/sent")
for s in "$S_TEXT" "$S_LOG" "$S_SCREEN"; do hasnt "$s" "$sent" "B a secret went out"; done
has '<redacted:github>' "$sent" "B the words went out masked"
has '<redacted:gitlab>' "$sent" "B the screen went out masked"
has '"machine_kind": "managed-linux"' "$sent" "B ctx carries the machine kind"
has '"agent": "claude"' "$sent" "B ctx carries the agent"
[ "$(cat "$WORK/url")" = https://hub.example/v1/node/feedback ] || fail "B posted to $(cat "$WORK/url")"; ok

# ---- C: each answer its sentence ----------------------------------------------------------
hub 429 '{"error":"rate_limited","message":"两条反馈要隔 30 秒 — 12 秒后再发。","retry_after":12}'
out=$(bash "$FB" send "再说一句"); rc=$?
[ "$rc" = 4 ] || fail "C 429 rc $rc" "$out"; ok
has '12 秒后再发' "$out" "C 429 the hub's sentence"; has '也没存' "$out" "C 429 nothing kept"
[ "$(outbox_n)" = 0 ] || fail "C 429 kept something"; ok
hub 422 '{"error":"secret","message":"原话里有像 github 的东西（密码或令牌）— 这条反馈入口没收"}'
out=$(bash "$FB" send "x"); rc=$?
[ "$rc" = 3 ] || fail "C 422 rc $rc" "$out"; ok
has '入口没收' "$out" "C 422 sentence"
hub 404 'not found'
out=$(bash "$FB" send "x"); rc=$?
[ "$rc" = 2 ] || fail "C 404 rc $rc" "$out"; ok
has '入口还没开反馈' "$out" "C 404 sentence"
mv "$FLEET_CONF_DIR/node.env" "$WORK/node.env.off"
hub 200 '{"id":"F99"}'
out=$(bash "$FB" send "x"); rc=$?
[ "$rc" = 2 ] && [ "$(calls)" = 0 ] || fail "C no token rc $rc (calls $(calls))" "$out"; ok
has '没接入口' "$out" "C no token sentence"
mv "$WORK/node.env.off" "$FLEET_CONF_DIR/node.env"
out=$(bash "$FB" send "" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "C empty words rc $rc" "$out"; ok

# ---- D: unreachable → kept → sent once -----------------------------------------------------
hub 000 ''
out=$(bash "$FB" send --attach "入口挂了 $S_TEXT"); rc=$?
[ "$rc" = 5 ] || fail "D unreachable rc $rc" "$out"; ok
has '先存在这台机器上' "$out" "D kept sentence"
[ "$(outbox_n)" = 1 ] || fail "D outbox should hold 1, holds $(outbox_n)"; ok
grep -rqF -e "$S_TEXT" -e "$S_LOG" -e "$S_SCREEN" "$FLEET_CONF_DIR/feedback-outbox" && fail "D the outbox holds a secret"; ok
[ "$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$FLEET_CONF_DIR/feedback-outbox")" = 700 ] \
  || fail "D the outbox is not 0700"; ok
e=$(ls "$FLEET_CONF_DIR/feedback-outbox"); printf 'wid-1\tfleet\t@3\tyes\n' > "$FLEET_CONF_DIR/feedback-outbox/$e/origin"
out=$(bash "$FB" outbox); rc=$?    # still away: kept
[ "$rc" = 0 ] && [ "$(outbox_n)" = 1 ] || fail "D a failed retry should keep it" "$out"; ok
hub 200 '{"id":"F13","state":"received"}'
bash "$FB" outbox >/dev/null
[ "$(calls)" = 1 ] && [ "$(outbox_n)" = 0 ] || fail "D outbox should send once (calls $(calls), left $(outbox_n))"; ok
has 'wid:wid-1|fleet：你之前存着的反馈已经发出：已收到，反馈号 F13' "$(cat "$WORK/told" 2>/dev/null)" "D the session is told its F number"
bash "$FB" outbox >/dev/null
[ "$(calls)" = 1 ] || fail "D a second outbox sent it again"; ok
[ "$(wc -l < "$WORK/told" | tr -d ' ')" = 1 ] || fail "D told twice"; ok
# an entry past the keep is dropped, its session told
mkdir -p "$FLEET_CONF_DIR/feedback-outbox/100-1-1/attach"
printf 'old' > "$FLEET_CONF_DIR/feedback-outbox/100-1-1/text"; echo '{}' > "$FLEET_CONF_DIR/feedback-outbox/100-1-1/ctx.json"
printf 'wid-2\tfleet\t@4\tno\n' > "$FLEET_CONF_DIR/feedback-outbox/100-1-1/origin"
hub 200 '{"id":"F14"}'
bash "$FB" outbox >/dev/null
[ "$(calls)" = 0 ] && [ "$(outbox_n)" = 0 ] || fail "D an expired entry should be dropped unsent"; ok
has 'wid:wid-2|fleet：你 3 天前存着的反馈' "$(cat "$WORK/told")" "D the expired entry's session is told"
# a held lock: the tick leaves the box alone
hub 000 ''; bash "$FB" send "y" >/dev/null; hub 200 '{"id":"F15"}'
mkdir "$FLEET_CONF_DIR/feedback-outbox/.lock"
bash "$FB" outbox >/dev/null
[ "$(calls)" = 0 ] || fail "D a held lock should keep a second tick out"; ok
rmdir "$FLEET_CONF_DIR/feedback-outbox/.lock"; bash "$FB" outbox >/dev/null
[ "$(outbox_n)" = 0 ] || fail "D the outbox did not drain after the lock went"; ok

# ---- E/F: a real (isolated) tmux window ------------------------------------------------
if [ -n "$REAL_TMUX" ]; then
  "$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s fbst -n "win-$S_TEXT" -x 120 -y 30 'sleep 600' || fail "E tmux"
  sp=$("$REAL_TMUX" -L "$SOCK" display-message -p '#{socket_path}')
  pane=$("$REAL_TMUX" -L "$SOCK" display-message -p -t fbst '#{pane_id}')
  mkdir -p "$WORK/tbin"; printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$WORK/tbin/tmux"; chmod +x "$WORK/tbin/tmux"
  hub 200 '{"id":"F16"}'
  out=$(PATH="$WORK/tbin:$PATH" TMUX="$sp,1,0" TMUX_PANE="$pane" bash "$FB" send "x"); rc=$?
  [ "$rc" = 3 ] && [ "$(calls)" = 0 ] || fail "E a secret in the window name should refuse (rc $rc, calls $(calls))" "$out"; ok
  has '自动带上的信息里还有像密码或令牌的东西' "$out" "E names the part"
  "$REAL_TMUX" -L "$SOCK" rename-window -t fbst "scratch-3"
  unset FLEET_FEEDBACK_SCREEN_CMD
  "$REAL_TMUX" -L "$SOCK" set-option -w -t fbst @cc_agent codex
  out=$(PATH="$WORK/tbin:$PATH" TMUX="$sp,1,0" TMUX_PANE="$pane" bash "$FB" preview "x"); rc=$?
  [ "$rc" = 0 ] || fail "E preview in a window rc $rc" "$out"; ok
  has '这个会话（scratch-3）' "$out" "E the window name"; has 'Codex' "$out" "E the agent off @cc_agent"
  has '当前屏幕' "$out" "E the pane's screen is offered"
  ok
fi
# F: the token reached curl's header and nothing else the script started
grep -q "Bearer $TOKEN" "$WORK/headers" || fail "F curl never got the token"; ok
grep -qv '^0$' "$WORK/peer-env" && fail "F the token reached fleet-peer-send"; ok
grep -q 'export CCQUOTA_TOKEN\|export.*CCQUOTA' "$FB" && ! grep -q '_fleet_hub_env' "$FB" && fail "F the script exports the token itself"; ok
grep -rqF "$TOKEN" "$FLEET_CONF_DIR/logs" 2>/dev/null && fail "F the token is in the log"; ok

# ---- G: zsh and bash 3.2 -----------------------------------------------------------------
hub 200 '{"id":"F17"}'
if command -v zsh >/dev/null 2>&1; then
  out=$(zsh -c '"$1" send "zsh 下发一句" ; echo "rc=$?"' _ "$FB"); has 'rc=0' "$out" "G zsh"
  has '反馈号 F17' "$out" "G zsh answer"
fi
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]'; then
  out=$(/bin/bash "$FB" send --attach "bash 3.2"; echo "rc=$?"); has 'rc=0' "$out" "G bash 3.2"
  out=$(/bin/bash "$FB" preview "bash 3.2"; echo "rc=$?"); has 'rc=0' "$out" "G bash 3.2 preview"
fi

# ---- H: wiring -----------------------------------------------------------------------------
grep -q 'fleet-feedback.sh" outbox' "$BIN/fleet-diskguard.sh" && grep -q '^    feedback_watch ' "$BIN/fleet-diskguard.sh" \
  || fail "H the diskguard tick does not run the outbox"; ok
C="$ROOT/plugins/fleet-feedback/commands/fleet-feedback.md"
# shellcheck disable=SC2088  # the command body's literal path
grep -q '~/.claude/fleet/bin/fleet-feedback.sh preview' "$C" && grep -q '~/.claude/fleet/bin/fleet-feedback.sh send' "$C" \
  && grep -q 'AskUserQuestion' "$C" && grep -q '1 附上' "$C" || fail "H the command body lost a step"; ok
grep -q '"fleet-feedback"' "$BIN/../.claude-plugin/marketplace.json" || fail "H not in the marketplace"; ok
grep -q 'fleet-feedback' "$BIN/../hooks/bash-guard.py" && fail "H bash-guard's _DIRECT_TOOLS must not take it (a person runs it)"; ok

echo "fleet-feedback-selftest: PASS ($CHECKS checks)"
