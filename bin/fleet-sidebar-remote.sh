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
#                             first, as for a local row) through fleet_hub_reap;
#                             toasts the node's dash-reap token as a local reap does
#   message  worker_message — the text from $FLEET_SIDEBAR_TEXT (the sidebar's
#                             input line asked for it, issue #1620), sent, the
#                             outcome toasted. The text never passes through a
#                             tmux command string, so it needs no quoting.
#                             Without it (a terminal): asks for the text, sends
#                             it, shows the outcome.
#   switch   worker_switch  — 换到可用订阅 (issue #2102): the node closes the
#                             session and resumes the same conversation on the
#                             fleet's active subscription (dash-migrate.sh `to`,
#                             whose dry-run refuses the same / a benched target);
#                             toasts the outcome — a refusal says why
#   rename   worker_rename  — 改名… (issue #2358): the new name from
#                             $FLEET_SIDEBAR_TEXT (the sidebar's input line,
#                             pre-filled with the old one), sent; the node renames
#                             the window holding the worker's @fleet_id — the
#                             display name only, never the key. The outcome
#                             toasted; a refusal (machine lost, no grant, the
#                             session gone) says why. Without the text: asked.
#   reappol  worker_reap_policy — 改回收方式… (issue #2368): the policy from
#                             $FLEET_SIDEBAR_TEXT (a pick of the row menu's
#                             second menu, fleet-reap-policy.sh menu on a `wid:`
#                             row; `fleet reap`), else asked. Checked here with
#                             fleet_reap_policy.py first — a typo never goes out,
#                             and an `at:HH:MM` is resolved on THIS computer's
#                             clock, the person's — then sent; the node stamps
#                             @reap_policy through fleet-reap-policy.sh set. The
#                             outcome toasted; a refusal says why.
#   answer   worker_answer  — the same: $FLEET_SIDEBAR_TEXT, or asked — a
#                             permission prompt (`⊘`, needs=perm) takes y / n →
#                             yes / no; a question (`?`, needs=ask) the option
#                             number(s); then sends and waits for the node's
#                             verdict, refusal verbatim.
#
# The row's machine, name and what it needs come from the sidebar's own cache
# ($FLEET_C/global/remote_<sess>, fleet-hub-sessions.sh) — never the network.
# THE HUB SILENT (issue #1483, EPIC #1479 C4): with global/hub_ok older than
# FLEET_HUB_SESSIONS_STALE (fleet_status_hub_lost — the one rule the sidebar's
# rows and the bar read too) nothing is sent: a write now would only time out,
# so the toast — or the popup, for the two that take input — says 「入口失联
# Nm，稍后再试」 and that is all; the next round that stands lifts it. Enter on
# the row (the proxy window) is a direct ssh, not a hub write: untouched.
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
  case "$1" in
    stop|resume|reap|message|answer|switch|rename|reappol) fleet_ui_t "remote_label_${1}_fmt" "$name" "$node" ;;
  esac
}
# write <tool> <json> [wait] → the record on stdout (fleet-hub-write's), rc its rc
write() { bash "$WRITE" "$1" "$2" --wait "${3:-30}" --quiet 2>/dev/null; }
json_wid() { python3 -c 'import json,sys; d={"worker_id": sys.argv[1]}
if len(sys.argv) > 3 and sys.argv[2]: d[sys.argv[2]] = sys.argv[3]
print(json.dumps(d, ensure_ascii=False))' "$worker_id" "${1:-}" "${2:-}"; }

pause() { printf '\n%s' "$(fleet_ui_t remote_press_any)" >&2; read -r -n 1 -s _ 2>/dev/null || read -r _ 2>/dev/null || true; }
# The sidebar's input line already asked (issue #1620): no terminal here, so the
# outcome is a toast, never a «press any key».
LINE=''; [ -n "${FLEET_SIDEBAR_TEXT+x}" ] && LINE=1
tell() {   # <outcome> — shown where the asking happened
  if [ -n "$LINE" ]; then toast "fleet: $1"
  else printf '\n%s\n' "$1" >&2; pause; fi
}

# 入口失联 (#1483): refuse before asking anything, send nothing, say why.
# shellcheck disable=SC2034  # FLEET_STATUS_G is read by the lib sourced on the same line
FLEET_STATUS_G="$FLEET_C/global"; . "$BIN/fleet-status-lib.sh"
fleet_status_remote_head "$sess"; fleet_status_hub_ok "$FSR_TS"
if fleet_status_hub_lost "$(date +%s)"; then
  fleet_status_age "$FSH_AGE"
  case "$action" in
    message|answer|rename|reappol)
      if [ -n "$LINE" ]; then toast "fleet: $(fleet_ui_t remote_hub_lost_fmt "$FSA")"
      else printf '%s\n%s\n' "$(label "$action")" "$(fleet_ui_t remote_hub_lost_fmt "$FSA")" >&2; pause; fi ;;
    stop|resume|reap|switch) toast "fleet: $(fleet_ui_t remote_hub_lost_fmt "$FSA")" ;;
  esac
  exit 0
fi

case "$action" in
  reap)
    # fleet_hub_reap (issue #1589): the node's own dash-reap token, reason and
    # exit — so the toast is the one a local row's reap shows, plus the machine.
    out=$(fleet_hub_reap "$worker_id" 90 2>/dev/null); token=$(printf '%s\n' "$out" | tail -1)
    case "$token" in
      reaped:full) msg=$(fleet_ui_t reap_done) ;;
      reaped:keep) msg=$(fleet_ui_t reap_kept) ;;
      skip:live)   msg=$(fleet_ui_t reap_live) ;;
      skip:*)      msg=$(fleet_ui_t reap_skip_fmt "${token#skip:}") ;;
      refused:*|failed:*) msg=$(fleet_ui_t reap_refused_fmt "$token") ;;
      *)           msg=$(fleet_ui_t reap_none) ;;
    esac
    toast "$msg · $(label reap)"
    ;;
  stop|resume|switch)
    tool=worker_$action
    rec=$(write "$tool" "$(json_wid)" 30)
    toast "fleet: $(outcome "$rec" "$(label "$action")")"
    ;;
  message)
    # the text from the sidebar's line, else the keyboard — straight into the JSON
    if [ -n "$LINE" ]; then text=$FLEET_SIDEBAR_TEXT
    else
      printf '%s\n' "$(label message)" >&2
      printf '%s\n' "$(fleet_ui_t remote_message_hint)" >&2
      IFS= read -r -e text 2>/dev/null || text=''
    fi
    [ -n "${text// /}" ] || exit 0
    rec=$(write worker_message "$(json_wid text "$text")" 30)
    tell "$(outcome "$rec" "$(label message)")"
    ;;
  rename)
    # the new name from the sidebar's line (pre-filled with the old one), else
    # the keyboard; unchanged or blank = nothing to do
    if [ -n "$LINE" ]; then nm=$FLEET_SIDEBAR_TEXT
    else
      printf '%s\n' "$(label rename)" >&2
      IFS= read -r -e nm 2>/dev/null || nm=''
    fi
    [ -n "${nm// /}" ] && [ "$nm" != "$name" ] || exit 0
    rec=$(write worker_rename "$(json_wid name "$nm")" 30)
    tell "$(outcome "$rec" "$(label rename)")"
    ;;
  reappol)
    if [ -n "$LINE" ]; then pol=$FLEET_SIDEBAR_TEXT
    else
      printf '%s\n%s\n' "$(label reappol)" "$(fleet_ui_t remote_reappol_hint)" >&2
      IFS= read -r -e pol 2>/dev/null || pol=''
    fi
    pol=${pol// /}
    [ -n "$pol" ] || exit 0
    canon=$(python3 "$BIN/fleet_reap_policy.py" norm "$pol" 2>/dev/null) || canon=''
    if [ -z "$canon" ]; then
      tell "$(fleet_ui_t remote_reappol_bad_fmt "$(label reappol)" "$pol")"; exit 0
    fi
    rec=$(write worker_reap_policy "$(json_wid policy "$canon")" 30)
    tell "$(outcome "$rec" "$(label reappol)")"
    ;;
  answer)
    ans=''
    if [ -n "$LINE" ]; then
      ans=$FLEET_SIDEBAR_TEXT
      case "$ans" in y|Y|yes) ans=yes ;; n|N|no) ans=no ;; esac
      case "$needs:$ans" in perm:yes|perm:no|perm:) ;; perm:*) ans='' ;; esac
    else
    printf '%s\n' "$(label answer)" >&2
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
    fi
    [ -n "$ans" ] || exit 0
    [ -n "$LINE" ] || printf '%s\n' "$(fleet_ui_t remote_sending)" >&2
    rec=$(write worker_answer "$(json_wid answer "$ans")" 90)
    tell "$(outcome "$rec" "$(label answer)")"
    ;;
  *) exit 0 ;;
esac
exit 0
