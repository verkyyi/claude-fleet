#!/bin/bash
# fleet-sidebar-remote.sh <action> <session> <wid:worker_id> [client]
# The row menu's actions on a row that lives on ANOTHER machine (issue #1487,
# EPIC #1479 C8). A local row's items run this machine's scripts on its window;
# a remote row has no window here, so every one of these is a hub WRITE through
# bin/fleet-hub-write.sh — the one write client — journalled on the hub and on
# the node, and this script only owns the asking and the telling:
#
#   stop     worker_stop    — graceful /exit there; toasts the outcome
#   resume   worker_resume  — reopen a stopped one (a live row refuses, and says so)
#   reap     worker_reap    — the confirmed reap (the menu's confirm-before ran
#                             first, as for a local row); toasts the result token
#   message  worker_message — INSIDE a popup (dash-popup.sh): asks for the text,
#                             sends it, shows the outcome. The text never passes
#                             through a tmux command string, so it needs no quoting.
#   answer   worker_answer  — INSIDE a popup: a permission prompt (`⊘`, needs=perm)
#                             asks 批准 / 拒绝 → yes / no; a question (`?`,
#                             needs=ask) asks for the option number(s); then sends
#                             and waits for the node's verdict, refusal verbatim.
#
# The row's machine, name and what it needs come from the sidebar's own cache
# ($FLEET_C/global/remote_<sess>, fleet-hub-sessions.sh) — never the network.
# THE HUB SILENT (issue #1483, EPIC #1479 C4): with global/hub_ok older than
# FLEET_HUB_SESSIONS_STALE (fleet_status_hub_lost — the one rule the sidebar's
# rows and the bar read too) nothing is sent: a write now would only time out,
# so the toast — or the popup, for the two that take input — says 「入口失联
# Nm，稍后再试」 and that is all; the next round that stands lifts it. Enter on
# the row (the ⇄ proxy window) is a direct ssh, not a hub write: untouched.
# Nothing here runs on a local row (an `@` id exits 0 at once), and nothing runs
# in a one-machine fleet: the menu offers these items on `wid:` rows only.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-ui-lang.sh"

action="${1:-}"; sess="${2:-}"; wid="${3:-}"; client="${4:-}"
case "$wid" in wid:*/*) ;; *) exit 0 ;; esac
[ -n "$sess" ] && [ -n "$action" ] || exit 0
fleet_load_conf "$sess" 2>/dev/null
worker_id="${wid#wid:}"

# the row, off the cache: node (col 2), name (8), needs (10)
row=$(LC_ALL=C awk -F $'\037' -v w="$wid" '$1 == w { print $2 "\037" $8 "\037" $10; exit }' \
      "$FLEET_C/global/remote_$sess" 2>/dev/null)
node="${row%%$'\037'*}"; rest="${row#*$'\037'}"
name="${rest%%$'\037'*}"; needs="${rest#*$'\037'}"
[ -n "$node" ] || node='?'
[ -n "$name" ] || name="${worker_id##*/}"

toast() { tmux display-message ${client:+-c "$client"} "$1" 2>/dev/null || :; }
WRITE="$BIN/fleet-hub-write.sh"

# outcome <record-json> → one line for a human, in the UI language
outcome() {
  printf '%s' "$1" | FR_LANG="$(fleet_ui_lang)" FR_WHAT="$2" python3 -c '
import json, os, sys
zh = os.environ["FR_LANG"] == "zh"
what = os.environ["FR_WHAT"]
try:
    o = json.load(sys.stdin)
except ValueError:
    print(("%s：没发出去" if zh else "%s: not sent") % what); sys.exit(0)
if "error" in o and not o.get("operation_id"):
    e = o["error"] if isinstance(o["error"], dict) else {"message": str(o["error"])}
    print(("%s：入口拒绝 — %s%s" if zh else "%s: the hub refused — %s%s")
          % (what, (e.get("code", "") + ": ") if e.get("code") else "", e.get("message", "")))
    sys.exit(0)
st = o.get("status", "?")
res = o.get("result") if isinstance(o.get("result"), dict) else {}
err = res.get("error") if isinstance(res.get("error"), dict) else None
if st == "succeeded":
    how = res.get("how") or res.get("delivery") or ""
    print(("%s：已完成%s" if zh else "%s: done%s") % (what, (" · " + str(how)) if how else ""))
elif st == "failed":
    print(("%s：被拒绝 — %s: %s" if zh else "%s: refused — %s: %s")
          % (what, (err or {}).get("code", "?"), (err or {}).get("message", "")))
elif st in ("accepted", "running", "pending"):
    print(("%s：入口已受理，那台机器处理中" if zh else "%s: accepted — the machine is on it") % what)
else:
    print(("%s：未确认（%s）— %s" if zh else "%s: unconfirmed (%s) — %s")
          % (what, st, (err or {}).get("message", "op=" + str(o.get("operation_id", "?")))))
'
}

label() {  # the action's human name for the toast / popup title
  case "$(fleet_ui_lang):$1" in
    zh:stop) printf '停 %s（在 %s）' "$name" "$node" ;;      en:stop) printf 'stop %s (on %s)' "$name" "$node" ;;
    zh:resume) printf '继续 %s（在 %s）' "$name" "$node" ;;  en:resume) printf 'resume %s (on %s)' "$name" "$node" ;;
    zh:reap) printf '回收 %s（在 %s）' "$name" "$node" ;;    en:reap) printf 'reap %s (on %s)' "$name" "$node" ;;
    zh:message) printf '发给 %s（在 %s）' "$name" "$node" ;; en:message) printf 'message %s (on %s)' "$name" "$node" ;;
    zh:answer) printf '答 %s（在 %s）' "$name" "$node" ;;    en:answer) printf 'answer %s (on %s)' "$name" "$node" ;;
  esac
}
# write <tool> <json> [wait] → the record on stdout (fleet-hub-write's), rc its rc
write() { bash "$WRITE" "$1" "$2" --wait "${3:-30}" --quiet 2>/dev/null; }
json_wid() { python3 -c 'import json,sys; d={"worker_id": sys.argv[1]}
if len(sys.argv) > 3 and sys.argv[2]: d[sys.argv[2]] = sys.argv[3]
print(json.dumps(d, ensure_ascii=False))' "$worker_id" "${1:-}" "${2:-}"; }

pause() { printf '\n%s' "$(fleet_ui_t remote_press_any)" >&2; read -r -n 1 -s _ 2>/dev/null || read -r _ 2>/dev/null || true; }

# 入口失联 (#1483): refuse before asking anything, send nothing, say why.
FLEET_STATUS_G="$FLEET_C/global"; . "$BIN/fleet-status-lib.sh"
fleet_status_remote_head "$sess"; fleet_status_hub_ok "$FSR_TS"
if fleet_status_hub_lost "$(date +%s)"; then
  fleet_status_age "$FSH_AGE"
  case "$action" in
    message|answer) printf '%s\n%s\n' "$(label "$action")" "$(fleet_ui_t remote_hub_lost_fmt "$FSA")" >&2; pause ;;
    stop|resume|reap) toast "fleet: $(fleet_ui_t remote_hub_lost_fmt "$FSA")" ;;
  esac
  exit 0
fi

case "$action" in
  stop|resume|reap)
    tool=worker_$action; wait=30; [ "$action" = reap ] && wait=90
    rec=$(write "$tool" "$(json_wid)" "$wait")
    toast "fleet: $(outcome "$rec" "$(label "$action")")"
    ;;
  message)
    # inside the popup: the text from the keyboard, straight into the JSON
    printf '%s\n' "$(label message)" >&2
    printf '%s\n' "$(fleet_ui_t remote_message_hint)" >&2
    IFS= read -r -e text 2>/dev/null || text=''
    [ -n "${text// /}" ] || exit 0
    rec=$(write worker_message "$(json_wid text "$text")" 30)
    printf '\n%s\n' "$(outcome "$rec" "$(label message)")" >&2
    pause
    ;;
  answer)
    printf '%s\n' "$(label answer)" >&2
    ans=''
    case "$needs" in
      perm)
        printf '%s\n' "$(fleet_ui_t remote_perm_prompt)" >&2
        read -r -n 1 -s k 2>/dev/null || k=''
        case "$k" in y|Y) ans=yes ;; n|N) ans=no ;; *) exit 0 ;; esac ;;
      *)
        # a question (needs=ask), or an unknown red row: the option number(s),
        # or y / n when it turns out to be a permission prompt after all
        printf '%s\n' "$(fleet_ui_t remote_pick_prompt)" >&2
        IFS= read -r -e ans 2>/dev/null || ans=''
        case "$ans" in y|Y|yes) ans=yes ;; n|N|no) ans=no ;; esac ;;
    esac
    [ -n "$ans" ] || exit 0
    printf '%s\n' "$(fleet_ui_t remote_sending)" >&2
    rec=$(write worker_answer "$(json_wid answer "$ans")" 90)
    printf '\n%s\n' "$(outcome "$rec" "$(label answer)")" >&2
    pause
    ;;
  *) exit 0 ;;
esac
exit 0
