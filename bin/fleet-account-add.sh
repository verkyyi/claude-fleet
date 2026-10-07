#!/bin/bash
# fleet-account-add.sh — `fleet account add`: sign a NEW subscription in and hand
# it to the hub, in one command (issue #2084).
#
#   fleet account add --provider claude|codex --label <name> [--principal <id>]
#                     [--account-uuid <uuid>|none] [--device-auth|--browser] [--dry-run]
#
# The subscriptions page's 「加订阅」 used to give two commands and a file to
# write by hand — `claude setup-token`, save the token as
# ~/.config/claude-fleet/accounts/<label>, `fleet-creds-import.sh <label>`; or
# `CODEX_HOME=~/.codex-accounts/<label> codex login`, `fleet-creds-import.sh
# --codex <label>` — and the local copy it left behind was easy to forget. This
# does all four steps:
#
#   1 登录 sign in    claude: `claude setup-token`, then the token it prints is
#                     pasted (hidden). codex: `codex login` into a fresh
#                     CODEX_HOME (`--device-auth` — a link + code for any device —
#                     by default over ssh, the browser flow otherwise).
#   2 存放 hold       into a private 0700 temp dir, 0600 files — never the
#                     accounts dir, never ~/.codex-accounts.
#   3 导入 import     bin/fleet-creds-import.sh against that dir, unchanged (the
#                     same request, the same checks, the same output).
#   4 删除 remove     the temp dir, on every exit. The hub holds the account
#                     from here; a node that leases it gets its own copy.
#
# The page's wait is unchanged: it polls the credential audit for this provider
# + label's `put`, which step 3 writes.
#
# Needs, checked BEFORE anyone signs in: the hub's URL (CCQUOTA_HUB_URL, else
# FLEET_HUB_URL, fleet.conf, node.env) and the operator's viewer token
# (CCQUOTA_VIEWER_TOKEN or ~/.ccquota/viewer-token) — the import route is
# operator-only. A token is never printed, logged or put on a command line.
#
# Seams: FLEET_ACCOUNT_ADD_CLAUDE_BIN (claude), FLEET_ACCOUNT_ADD_CODEX_BIN (codex).
# Exit 0 = in the hub · 1 = the sign-in or the import failed · 2 = usage / not ready.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
: "${FLEET_CONF_DIR:=$HOME/.config/claude-fleet}"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
say() { printf '%s\n' "$*"; }
die() { printf 'fleet account add · %s\n' "$1" >&2; exit "${2:-2}"; }

PROV='' LABEL='' PRINCIPAL='' AUUID='' DEVICE='' DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)     [ -n "${2:-}" ] || usage; PROV="$2"; shift 2 ;;
    --provider=*)   PROV="${1#*=}"; shift ;;
    --label)        [ -n "${2:-}" ] || usage; LABEL="$2"; shift 2 ;;
    --label=*)      LABEL="${1#*=}"; shift ;;
    --principal)    [ -n "${2:-}" ] || usage; PRINCIPAL="$2"; shift 2 ;;
    --account-uuid) [ -n "${2:-}" ] || usage; AUUID="$2"; shift 2 ;;
    --device-auth)  DEVICE=1; shift ;;
    --browser)      DEVICE=0; shift ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help)      sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              printf 'fleet account add · 不认识 unknown: %s\n' "$1" >&2; usage ;;
  esac
done
case "$PROV" in
  claude|codex) ;;
  '') die '要 --provider claude|codex · --provider is required' ;;
  *)  die "不认识的 provider「${PROV}」· --provider is claude or codex" ;;
esac
[ -n "$LABEL" ] || die '要 --label <名字> · --label is required'
# The vault's label rule (fleet_creds.go validAccountLabel; the page's LABEL_RE),
# minus what fleet-creds-import.sh never reads as a label.
if ! [[ "$LABEL" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$ ]] || [[ "$LABEL" == *.conf ]]; then
  die "名字「${LABEL}」不合规：字母、数字、. _ -，最长 64，不以 . 开头 · not a valid label"
fi
if [ "$PROV" = codex ] && [ "$LABEL" = default ]; then
  die 'Codex 的 default 是这台机器自己的 ~/.codex，换个名字；导入它用 fleet-creds-import.sh --codex · `default` is this machine'"'"'s own ~/.codex — pick another label'
fi
[ "$PROV" = claude ] || [ -z "$AUUID" ] || die '--account-uuid 只用于 claude · --account-uuid applies to claude only'
[ -n "$DEVICE" ] || { if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then DEVICE=1; else DEVICE=0; fi; }

# --- ready? (before anyone signs in) ------------------------------------------
_env_val() {  # <file> <key> → the value its last `KEY=` line sets, quotes stripped
  [ -r "$1" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=//p" "$1" | tail -n 1 | sed 's/[[:space:]]#.*$//; s/^["'"'"']//; s/["'"'"']$//'
}
HUB="${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}"
[ -n "$HUB" ] || HUB=$(_env_val "$FLEET_CONF_DIR/fleet.conf" FLEET_HUB_URL)
[ -n "$HUB" ] || HUB=$(_env_val "$FLEET_CONF_DIR/node.env" CCQUOTA_HUB_URL)
[ -n "$HUB" ] || die '找不到入口地址（CCQUOTA_HUB_URL / fleet.conf 的 FLEET_HUB_URL）· no hub URL here — run this on a fleet machine'
if [ "$DRY" = 0 ] && [ -z "${CCQUOTA_VIEWER_TOKEN:-}" ] && [ ! -s "$HOME/.ccquota/viewer-token" ]; then
  die '这台机器没有管理员令牌（CCQUOTA_VIEWER_TOKEN 或 ~/.ccquota/viewer-token），导入只有管理员能做 · no viewer token here — the import is operator-only'
fi
IMPORT="$BIN/fleet-creds-import.sh"
[ -f "$IMPORT" ] || die "缺 $IMPORT · fleet-creds-import.sh is missing"

# --- the private hold: 0700, gone on every exit ---------------------------------
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-account-add.XXXXXX")" || die '建不了临时目录 · cannot make a temp dir' 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

fail() { say ''; say "✖ $1"; say '  本机没有留下任何副本 · nothing was kept on this machine'; exit 1; }

say "fleet account add · $PROV · $LABEL → $HUB"
say ''
if [ "$PROV" = claude ]; then
  mkdir -p "$WORK/accounts"
  say '1/3 登录 · sign in — the browser opens; when it prints a token (sk-ant-oat01-…), copy it'
  "${FLEET_ACCOUNT_ADD_CLAUDE_BIN:-claude}" setup-token || fail '登录没有完成 · the sign-in did not complete'
  printf '\n粘贴令牌（不显示）· paste the token (hidden): ' >&2
  tok=''
  IFS= read -rs tok || tok=''
  printf '\n' >&2
  tok=$(printf '%s' "$tok" | tr -d '[:space:]')
  case "$tok" in sk-ant-oat01-*) ;; *) tok=''; fail '这不是 setup-token（sk-ant-oat01-…）· that is not a setup token' ;; esac
  case "$tok" in *[!A-Za-z0-9_-]*) tok=''; fail '令牌里有多余字符 · the token has stray characters' ;; esac
  printf '%s\n' "$tok" > "$WORK/accounts/$LABEL"; tok=''
  say ''
  say '2/3 导入 · hand it to the hub'
  args=()
  [ -z "$PRINCIPAL" ] || args+=(--principal "$PRINCIPAL")
  [ -z "$AUUID" ] || args+=(--account-uuid "$AUUID")
  [ "$DRY" = 0 ] || args+=(--dry-run)
  FLEET_ACCOUNTS_DIR="$WORK/accounts" CCQUOTA_HUB_URL="$HUB" \
    bash "$IMPORT" ${args[@]+"${args[@]}"} "$LABEL"; rc=$?
else
  home="$WORK/codex/$LABEL"; mkdir -p "$home"
  if [ "$DEVICE" = 1 ]; then
    say '1/3 登录 · sign in — open the link below on any device and enter the code'
    CODEX_HOME="$home" "${FLEET_ACCOUNT_ADD_CODEX_BIN:-codex}" login --device-auth || fail '登录没有完成 · the sign-in did not complete'
  else
    say '1/3 登录 · sign in — the browser opens (over ssh: --device-auth)'
    CODEX_HOME="$home" "${FLEET_ACCOUNT_ADD_CODEX_BIN:-codex}" login || fail '登录没有完成 · the sign-in did not complete'
  fi
  [ -s "$home/auth.json" ] || fail '登录后没有 auth.json · the sign-in left no auth.json'
  say ''
  say '2/3 导入 · hand it to the hub'
  args=(--codex)
  [ -z "$PRINCIPAL" ] || args+=(--principal "$PRINCIPAL")
  [ "$DRY" = 0 ] || args+=(--dry-run)
  # the import's `ccquota codex list` lookup would resolve a registered name to
  # some OTHER home; this account lives only in $home, so it is off here, as is
  # the «stop refreshing it on this machine» reminder — nothing here holds it.
  CCQUOTA_FLEET_CODEX_HOMES="$WORK/codex" FLEET_QUOTA_BIN="$WORK/no-ccquota" FLEET_CREDS_IMPORT_NO_HOLDER=1 \
    CCQUOTA_HUB_URL="$HUB" bash "$IMPORT" ${args[@]+"${args[@]}"} "$LABEL"; rc=$?
fi
[ "$rc" -eq 0 ] || fail "导入失败（exit ${rc}，原因见上）· the import failed"
rm -rf "$WORK"
say ''
say '3/3 删除本地副本 · the local copy is removed'
if [ "$DRY" = 1 ]; then
  say "✓ dry-run：登录成功，没有发送 · signed in, nothing sent"
else
  say "✓ $PROV/$LABEL 已交给入口，订阅页会自己往下走 · in the hub — the subscriptions page moves on by itself"
fi
exit 0
