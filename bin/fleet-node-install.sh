#!/bin/bash
# fleet-node-install.sh — make this Mac a MANAGED machine in one command, and
# repair one by running the same command again (issue #2330, EPIC #2329 C1).
#
#   sudo fleet node install --join <码> [--hub <url>]
#   curl -fsSL <url of this script> | sudo bash -s -- --hub <url> --join <码>
#
# The code comes from the hub's 「机器」 page (「添加机器」, a 托管 code: trusted,
# role managed, one hour — docs/MANAGED-NODE.md §2), which prints the second
# line. Every step looks first and acts only on what is missing; a step that
# fails stops the run, says why and prints the rerun line, and leaves nothing
# half written (each file lands by one rename, a step that cannot finish puts
# back what it replaced). Exit 0 = converged.
#
# Steps, in order (one line each: `✓ <step> …` · `跳过 <step>：…` · `✗ <step>：…`):
#   检查      root · macOS · /usr/bin/python3 (Xcode command line tools) · curl
#   加入      the join code → this MACHINE's node token, kept in
#             <state>/machine.env (root 600) with the hub's address. A rerun
#             whose token the hub still accepts needs no code (C2, §1).
#   发布公钥  the hub's release signing key, pinned once in <state>/release.pub
#             (--release-key <file> pins a given one); the updater checks every
#             release against it (C7)
#   期望状态  GET /v1/node/desired → <state>/expected.json, the first copy of
#             「应有的样子」 (C2, §3); an empty `accounts` is left out (= not stated)
#   ccquota   the hub's build for this platform (/v1/node/dist, SHA-256 checked)
#             into <state>/bin/ccquota — only to fetch the first release; once
#             `current` exists its own bin/ccquota is used
#   运行时    the root runtime <root>/<sha> + `current`, every pinned tool with it:
#             one tick of the machine's updater (bin/fleet-node-update.py, C6) on
#             the release expected.json names, else the hub's stable (--target
#             <sha> overrides). Piped from curl, the updater is taken from the
#             signed release itself.
#   角色用户  the credential role account (_fleetcred) — fleet-credsep.py role
#   ssh CA    the hub's SSH user CA at /etc/ssh/fleet_user_ca.pub + the
#             sshd_config.d drop-in, exactly as the admin agent writes them;
#             `sshd -t` and `sshd -T` must agree or both go back (no hub CA ⇒ 跳过)
#   守护      <state>/logins, then the machine daemon's LaunchDaemon
#             (fleet-node-supervisor.py install, from `current` — C3)
#
# On a managed machine the old roads (`fleet host on`, `fleet node join`) say to
# use this command instead, and still work for one version.
#
# Usage: fleet-node-install.sh [--join <fj_code>] [--hub <url>] [--target <sha>]
#                              [--release-key <file>]
# Env (sandbox seams, docs/BREAK-IT.md `node-install-half`): FLEET_NODE_STATE
#   (/var/db/fleet-node) · FLEET_NODE_ROOT (/Library/Application Support/claude-fleet) ·
#   FLEET_NODE_LOG · FLEET_NODE_DAEMON_DIR · FLEET_NODE_LAUNCHCTL · FLEET_NODE_TEST=1
#   (no root needed) · FLEET_NODE_INSTALL_CURL (curl) · FLEET_NODE_INSTALL_OS /
#   _ARCH (uname) · FLEET_NODE_PYTHON (/usr/bin/python3) · FLEET_NODE_SSH_DIR
#   (/etc/ssh) · FLEET_NODE_SSHD (/usr/sbin/sshd; '' = no check) · FLEET_CREDSEP_ROLE
# Exit: 0 converged · 1 a step failed (the line says which; rerun the same command) · 2 usage
set -uo pipefail

PROG=fleet-node-install
CODE="" HUB="" TARGET="" RKEY=""
usage() {
  if [ -f "$0" ]; then sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  else echo "usage: fleet-node-install.sh --join <fj_code> --hub <url> [--target <sha>] [--release-key <file>]"; fi
}
while [ $# -gt 0 ]; do
  case "$1" in
    --join) CODE="${2:-}"; shift ;;
    --join=*) CODE="${1#--join=}" ;;
    --hub) HUB="${2:-}"; shift ;;
    --hub=*) HUB="${1#--hub=}" ;;
    --target) TARGET="${2:-}"; shift ;;
    --release-key) RKEY="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "$PROG: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$CODE" ] && ! printf '%s' "$CODE" | grep -Eq '^fj_[a-z2-7]{26}$'; then
  echo "$PROG: --join does not look like a join code (fj_ + 26 characters)" >&2; exit 2
fi
case "$TARGET" in ''|[0-9a-f]*) ;; *) echo "$PROG: --target: a commit sha" >&2; exit 2 ;; esac
if [ -n "$RKEY" ] && [ ! -r "$RKEY" ]; then echo "$PROG: --release-key $RKEY is not readable" >&2; exit 2; fi

here=""
[ -f "$0" ] && here="$(cd "$(dirname "$0")" && pwd -P)"
STATE="${FLEET_NODE_STATE:-/var/db/fleet-node}"
ROOT="${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}"
CUR="$ROOT/current"
ENVF="$STATE/machine.env"
PUB="$STATE/release.pub"
EXP="$STATE/expected.json"
CURL="${FLEET_NODE_INSTALL_CURL:-curl}"
PY="${FLEET_NODE_PYTHON:-/usr/bin/python3}"
SSHDIR="${FLEET_NODE_SSH_DIR:-/etc/ssh}"
SSHD="${FLEET_NODE_SSHD-/usr/sbin/sshd}"
ROLE="${FLEET_CREDSEP_ROLE:-_fleetcred}"
OS="${FLEET_NODE_INSTALL_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
ARCH="${FLEET_NODE_INSTALL_ARCH:-$(uname -m)}"
case "$ARCH" in x86_64|amd64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; esac
# every child (the updater, the daemon's install) sees the same paths
export FLEET_NODE_STATE="$STATE" FLEET_NODE_ROOT="$ROOT" FLEET_NODE_RUNTIME="$CUR"

# the line a failure ends with: the same command, the code elided (共同约定 8)
RERUN="sudo fleet node install --join <码>${HUB:+ --hub $HUB}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-install.XXXXXX")" || { echo "$PROG: no temp dir" >&2; exit 1; }
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

ok()   { printf '✓ %s %s\n' "$1" "$2"; }
skip() { printf '跳过 %s：%s\n' "$1" "$2"; }
fail() { printf '✗ %s：%s\n  重跑：%s\n' "$1" "$2" "$RERUN"; exit 1; }

# put <src> <dst> <mode> — <dst> by one rename, never half written
put() {
  local tmp="$2.tmp-install.$$"
  cp "$1" "$tmp" 2>/dev/null && chmod "$3" "$tmp" && mv -f "$tmp" "$2" && return 0
  rm -f "$tmp"; return 1
}

# req <GET|POST> <path> <out> [body file] [token] → prints the HTTP code (000 = no answer)
req() {
  local a=(-sS --max-time 60 -o "$3" -w '%{http_code}')
  [ -n "${5:-}" ] && a+=(-H "Authorization: Bearer $5")
  [ "$1" = POST ] && a+=(-X POST -H 'Content-Type: application/json' --data-binary "@$4")
  "$CURL" "${a[@]}" "$HUB$2" 2>/dev/null || true
}

envval() { [ -r "$ENVF" ] && sed -n "s/^$1=//p" "$ENVF" | head -n 1; }

# ---------------------------------------------------------------- 检查 ----------
if [ "$(id -u)" != 0 ] && [ "${FLEET_NODE_TEST:-}" != 1 ]; then
  fail 检查 "要以 root 运行（它写 /Library、/var/db 和 /etc/ssh）：sudo fleet node install --join <码>"
fi
[ "$OS" = darwin ] || fail 检查 "托管机器只做 macOS（这台是 ${OS}）"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 \
  || fail 检查 "$PY 不能用 — 先装 Xcode 命令行工具：xcode-select --install"
command -v "$CURL" >/dev/null 2>&1 || fail 检查 "没有 curl"
[ -n "$HUB" ] || HUB="$(envval CCQUOTA_HUB_URL)"
HUB="${HUB%/}"
case "$HUB" in
  http://*|https://*) ;;
  '') fail 检查 "不知道入口地址：加 --hub <url>（入口「添加机器」给的那一行里有）" ;;
  *) fail 检查 "--hub 要是 http(s) 地址：$HUB" ;;
esac
RERUN="sudo fleet node install --join <码> --hub $HUB"
mkdir -p "$STATE" && chmod 755 "$STATE" || fail 检查 "建不了 $STATE"
ok 检查 "root · macOS $ARCH · $("$PY" -c 'import platform; print("python " + platform.python_version())')"

# ---------------------------------------------------------------- 加入 ----------
TOKEN="$(envval CCQUOTA_TOKEN)"
joined=""
if [ -n "$TOKEN" ] && [ "$(envval CCQUOTA_HUB_URL)" = "$HUB" ] \
   && [ "$(req GET /v1/node/self "$WORK/self" "" "$TOKEN")" = 200 ]; then
  skip 加入 "这台机器已加入 ${HUB}（入口仍认 $ENVF 里的令牌）"
else
  if [ -z "$CODE" ]; then
    if [ -n "$TOKEN" ]; then fail 加入 "入口不再认 $ENVF 里的令牌 — 在入口「机器」页点「添加机器」拿一个新码，加 --join <码> 重跑"
    else fail 加入 "要一个加入码：在入口「机器」页点「添加机器」，加 --join <码> 重跑"; fi
  fi
  host="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname)"
  "$PY" -c 'import json,sys; json.dump({"code": sys.argv[1], "hostname": sys.argv[2], "os_user": "root"}, open(sys.argv[3], "w"))' \
    "$CODE" "$host" "$WORK/join.req" || fail 加入 "写不了请求"
  code=$(req POST /v1/node/join "$WORK/join" "$WORK/join.req")
  rm -f "$WORK/join.req"
  case "$code" in
    200) ;;
    401) fail 加入 "入口不认这个加入码（错了、过期了，或已用过）— 回入口「机器」页再点一次「添加机器」" ;;
    000) fail 加入 "连不上 $HUB" ;;
    *) fail 加入 "入口答 HTTP ${code}：$(head -c 200 "$WORK/join" 2>/dev/null)" ;;
  esac
  TOKEN="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token") or "")' "$WORK/join" 2>/dev/null)"
  epid="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("endpoint_id") or "")' "$WORK/join" 2>/dev/null)"
  rm -f "$WORK/join"
  [ -n "$TOKEN" ] || fail 加入 "入口的回答里没有令牌"
  # machine.env: the two lines this step owns, every other line kept
  { [ -r "$ENVF" ] && grep -Ev '^(CCQUOTA_HUB_URL|CCQUOTA_TOKEN)=' "$ENVF"
    printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=%s\n' "$HUB" "$TOKEN"; } > "$WORK/machine.env"
  put "$WORK/machine.env" "$ENVF" 600 || { rm -f "$WORK/machine.env"; fail 加入 "写不了 ${ENVF}（入口那边已登记 ${epid:-这台}，重跑需要新码）"; }
  rm -f "$WORK/machine.env"
  joined=1
  ok 加入 "${epid:-?} · 可信与角色记在入口发的身份上（令牌在 ${ENVF}，root 600）"
fi

# ---------------------------------------------------------------- 发布公钥 ------
if [ -n "$RKEY" ]; then
  grep -Eq '^ed25519 [A-Za-z0-9+/=]{40,}$' "$RKEY" || fail 发布公钥 "$RKEY 不是一把 ed25519 发布公钥"
  if cmp -s "$RKEY" "$PUB"; then skip 发布公钥 "已钉住 $PUB"
  else put "$RKEY" "$PUB" 644 || fail 发布公钥 "写不了 $PUB"; ok 发布公钥 "钉住 $RKEY → $PUB"; fi
elif [ -s "$PUB" ]; then
  skip 发布公钥 "已钉住 ${PUB}（换钥匙：--release-key <文件>）"
else
  code=$(req GET /v1/fleet/release/key "$WORK/key")
  case "$code" in
    200) ;;
    404) fail 发布公钥 "入口没有发布签名（入口未配 CCQUOTA_FLEET_RELEASE_KEY）" ;;
    000) fail 发布公钥 "连不上 $HUB" ;;
    *) fail 发布公钥 "入口答 HTTP $code" ;;
  esac
  tr -d '\r' < "$WORK/key" | sed -n '1p' > "$WORK/key.1"
  grep -Eq '^ed25519 [A-Za-z0-9+/=]{40,}$' "$WORK/key.1" || fail 发布公钥 "入口给的不是一把 ed25519 公钥"
  put "$WORK/key.1" "$PUB" 644 || fail 发布公钥 "写不了 $PUB"
  ok 发布公钥 "钉住 $(cut -c1-24 "$PUB")… → $PUB"
fi

# ---------------------------------------------------------------- 期望状态 ------
code=$(req GET /v1/node/desired "$WORK/desired" "" "$TOKEN")
case "$code" in
  200)
    "$PY" - "$WORK/desired" "$WORK/expected.json" <<'PY' || fail 期望状态 "入口给的期望状态读不懂"
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict):
    raise SystemExit(1)
# an empty list states nothing: written, it would pause every account (C3)
if not d.get("accounts"):
    d.pop("accounts", None)
with open(sys.argv[2], "w") as f:
    json.dump(d, f, indent=1, sort_keys=True)
    f.write("\n")
PY
    if cmp -s "$WORK/expected.json" "$EXP"; then
      skip 期望状态 "$EXP 与入口一致（版本 $("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", 0))' "$EXP")）"
    else
      put "$WORK/expected.json" "$EXP" 644 || fail 期望状态 "写不了 $EXP"
      ok 期望状态 "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("版本 %s · 发布版 %s · 账号 %s" % (d.get("version", 0), (d.get("release") or "随 stable")[:12], ", ".join(d.get("accounts") or []) or "未定"))' "$EXP") → $EXP"
    fi ;;
  404) skip 期望状态 "入口还没有期望状态（旧入口）" ;;
  401|403) fail 期望状态 "入口不认这台机器的令牌（HTTP ${code}）" ;;
  000) fail 期望状态 "连不上 $HUB" ;;
  *) fail 期望状态 "入口答 HTTP $code" ;;
esac

# ---------------------------------------------------------------- ccquota -------
CCQ="$STATE/bin/ccquota"
if [ -x "$CUR/bin/ccquota" ]; then
  CCQ="$CUR/bin/ccquota"
  skip ccquota "用运行时里的 $CCQ"
elif [ -x "$CCQ" ]; then
  skip ccquota "已有 $CCQ"
else
  code=$("$CURL" -sS --max-time 300 -D "$WORK/dist.h" -o "$WORK/ccquota" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$HUB/v1/node/dist/$OS-$ARCH" 2>/dev/null) || code=000
  [ "$code" = 200 ] || fail ccquota "入口没给 ccquota-$OS-${ARCH}（HTTP ${code}）"
  want="$(tr -d '\r' < "$WORK/dist.h" | sed -n 's/^[Xx]-[Cc]cquota-[Ss]ha256: *//p' | head -n 1)"
  got="$(shasum -a 256 "$WORK/ccquota" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || fail ccquota "下载的 ccquota 校验和不对（要 ${want:-?}，得 ${got}）"
  mkdir -p "$STATE/bin" && chmod 755 "$STATE/bin" || fail ccquota "建不了 $STATE/bin"
  put "$WORK/ccquota" "$CCQ" 755 || fail ccquota "写不了 $CCQ"
  ok ccquota "ccquota-$OS-${ARCH}（sha256 ${got:0:12}…）→ $CCQ"
fi

# ---------------------------------------------------------------- 运行时 --------
cur_sha() { basename "$(readlink "$CUR" 2>/dev/null)"; }
staged() { [ -L "$CUR" ] && [ -f "$CUR/.release/staged.json" ] && [ -f "$CUR/bin/fleet-node-supervisor.py" ]; }
if staged && [ -z "$TARGET" ]; then
  skip 运行时 "current = $(cur_sha | cut -c1-12)（之后由守护的更新器跟发布版走）"
else
  upd=""
  if [ -n "$here" ] && [ -f "$here/fleet-node-update.py" ] && [ -f "$here/fleet-node-supervisor.py" ]; then
    upd="$here/fleet-node-update.py"
  elif staged; then
    upd="$CUR/bin/fleet-node-update.py"
  else
    # piped from curl: the updater comes out of the signed release itself
    "$CCQ" release fetch --hub "$HUB" --pubkey "$PUB" "${TARGET:-stable}" "$WORK/tree" >"$WORK/fetch.out" 2>&1 \
      || fail 运行时 "取不到发布版：$(tail -n 1 "$WORK/fetch.out")"
    upd="$WORK/tree/bin/fleet-node-update.py"
    [ -f "$upd" ] || fail 运行时 "发布版里没有 bin/fleet-node-update.py（stable 早于整机更新器）"
  fi
  # the installer's tick never waits out an earlier failure's backoff
  env FLEET_NODE_CCQUOTA="$CCQ" FLEET_NODE_UPDATE_RETRY=0 ${TARGET:+"FLEET_NODE_UPDATE_TARGET=$TARGET"} \
    "$PY" -I "$upd" tick >"$WORK/tick.out" 2>&1
  # a switch ends at phase `switched` (the daemon verifies it next); anything else says result + reason
  res="$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%s\t%s" % ("switched" if d.get("phase") == "switched" else d.get("result", ""), d.get("reason", "")))' "$STATE/update.json" 2>/dev/null)"
  case "${res%%	*}" in
    switched|committed) ok 运行时 "current = $(cur_sha | cut -c1-12) · $("$PY" -I "$upd" versions 2>/dev/null | sed 's/^version *//')" ;;
    current) ok 运行时 "current = $(cur_sha | cut -c1-12)（已是这一版）" ;;
    *) fail 运行时 "更新器：${res:-$(tail -n 1 "$WORK/tick.out")}" ;;
  esac
  staged || fail 运行时 "更新器跑完了，$CUR 却不是一个装齐的发布版"
fi

# ---------------------------------------------------------------- 角色用户 ------
if id -u "$ROLE" >/dev/null 2>&1; then
  skip 角色用户 "$ROLE 已在（uid $(id -u "$ROLE")）"
else
  [ -f "$CUR/bin/fleet-credsep.py" ] || fail 角色用户 "运行时里没有 bin/fleet-credsep.py"
  out="$("$PY" -I "$CUR/bin/fleet-credsep.py" role 2>&1)" || fail 角色用户 "$(printf '%s' "$out" | tail -n 1)"
  id -u "$ROLE" >/dev/null 2>&1 || fail 角色用户 "建完仍找不到 $ROLE"
  ok 角色用户 "${ROLE}（uid $(id -u "$ROLE")）"
fi

# ---------------------------------------------------------------- ssh CA --------
KEYP="$SSHDIR/fleet_user_ca.pub"
CONFP="$SSHDIR/sshd_config.d/100-fleet-user-ca.conf"
code=$(req GET /v1/fleet/ssh-ca.pub "$WORK/ca")
case "$code" in
  200)
    tr -d '\r' < "$WORK/ca" | sed -n '1p' > "$WORK/ca.1"
    grep -Eq '^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+ [A-Za-z0-9+/=]+' "$WORK/ca.1" || fail "ssh CA" "入口给的不是一把 ssh 公钥"
    # the admin agent's drop-in, byte for byte (internal/agent/node_sshca.go sshCAConf)
    printf '# Managed by ccquota (claude-fleet#1412): trust the fleet hub'"'"'s SSH user CA.\n# Existing keys are untouched; this only ADDS certificate logins.\nTrustedUserCAKeys %s\n' "$KEYP" > "$WORK/ca.conf"
    if cmp -s "$WORK/ca.1" "$KEYP" && cmp -s "$WORK/ca.conf" "$CONFP"; then
      skip "ssh CA" "sshd 已信入口的 CA（${KEYP}）"
    else
      mkdir -p "$SSHDIR/sshd_config.d" || fail "ssh CA" "建不了 $SSHDIR/sshd_config.d"
      for f in "$KEYP" "$CONFP"; do [ -e "$f" ] && cp -p "$f" "$WORK/back.$(basename "$f")"; done
      # back to how it was: what was there returns, what was not goes
      undo() {
        local f; for f in "$KEYP" "$CONFP"; do
          if [ -e "$WORK/back.$(basename "$f")" ]; then mv -f "$WORK/back.$(basename "$f")" "$f"; else rm -f "$f"; fi
        done
      }
      put "$WORK/ca.1" "$KEYP" 644 && put "$WORK/ca.conf" "$CONFP" 644 || { undo; fail "ssh CA" "写不了 $SSHDIR"; }
      if [ -n "$SSHD" ]; then
        if ! out="$("$SSHD" -t 2>&1)"; then undo; fail "ssh CA" "sshd -t 不过，已退回：$(printf '%s' "$out" | head -n 1)"; fi
        eff="$("$SSHD" -T 2>/dev/null | awk 'tolower($1) == "trustedusercakeys" { print $2; exit }')"
        if [ "$eff" != "$KEYP" ]; then
          undo
          fail "ssh CA" "sshd 用的 TrustedUserCAKeys 是「${eff:-无}」不是 ${KEYP}（sshd_config 没 Include sshd_config.d，或别处先设了），已退回"
        fi
      fi
      ok "ssh CA" "$KEYP + ${CONFP}（下一次 ssh 连接生效，sshd 不重启）"
    fi ;;
  404) skip "ssh CA" "入口不签 ssh 证书" ;;
  000) fail "ssh CA" "连不上 $HUB" ;;
  *) fail "ssh CA" "入口答 HTTP $code" ;;
esac

# ---------------------------------------------------------------- 守护 ----------
mkdir -p "$STATE/logins" && chmod 700 "$STATE/logins" || fail 守护 "建不了 $STATE/logins"
SUP="$CUR/bin/fleet-node-supervisor.py"
if "$PY" -I "$SUP" install --check >/dev/null 2>&1; then
  skip 守护 "com.claude-fleet.node 已装好、在跑"
else
  out="$("$PY" -I "$SUP" install 2>&1)" || fail 守护 "$(printf '%s' "$out" | tail -n 1)"
  ok 守护 "$(printf '%s' "$out" | tail -n 1)"
fi

if [ -n "$joined" ]; then
  echo "已收敛：这台是托管机器。账号由守护接管：sudo $CUR/bin/fleet-node-supervisor.py account adopt <账号>"
else
  echo "已收敛"
fi
exit 0
