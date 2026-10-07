#!/usr/bin/env bash
# fleet-proxy-quota.sh — the credential proxy's quota readings onto their windows
# (issue #1978, EPIC #1967 R3).
#
# With FLEET_CRED_PROXY=1 every request of every session — Claude or Codex —
# passes bin/fleet-cred-proxy.py, and every answer carries the account's
# rate-limit windows. The proxy keeps each session's newest reading (ctl
# `quota`); this hands each one to the measurement bus's one writer,
# `conf/statusline.sh --from proxy`, on the window whose @cred_sid it is — so a
# Codex window, which never had a status line, gets its @rl* too, and every
# session's numbers come from one place on one scale.
#
#   fleet-proxy-quota.sh push [--socket LABEL]…
#        every live fleet socket (fleet_sockets), or just the ones named.
#        A window is stamped when the proxy holds a reading for its session
#        that is newer than the window's @rl_ts — or about as new (60 s) and
#        the window's stamp is another feeder's. Prints one line per stamp.
#        The percents go over as the proxy has them (decimals); statusline.sh
#        floors them, as it does the mod's.
#        Exit 0 always: no proxy, no reading, no window = nothing to do.
#
# Who runs it: the proxy itself, at most once per FLEET_CRED_QUOTA_PUSH_SECS
# after a fresh reading (not separated — fleet-cred-proxy.sh sets
# FLEET_CRED_QUOTA_PUSH), and the quota watch's tick before it reads the stamps
# (always — the only road when the proxy runs as another uid, issue #1971).
#
# A central-route session's requests carry the hub's pass, so the proxy files
# them under h-<hash>; fleet-session-cred.sh records that name as `qsid` beside
# the session (a hash, never the pass), and this follows it.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
SL="$BIN/../conf/statusline.sh"

cmd="${1:-}"; [ $# -gt 0 ] && shift
socks=()
while [ $# -gt 0 ]; do
  case "$1" in
    --socket) socks+=("${2:-}"); shift 2 ;;
    *) echo "fleet-proxy-quota: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  push) ;;
  -h|--help|'')
    sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    [ -n "$cmd" ]; exit $? ;;
  *) echo "fleet-proxy-quota: unknown command $cmd (see --help)" >&2; exit 2 ;;
esac

[ -f "$SL" ] || exit 0
q=$(bash "$BIN/fleet-cred-proxy.sh" quota 2>/dev/null) || exit 0
case "$q" in ''|'{}') exit 0 ;; esac

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" >/dev/null 2>&1 || exit 0
if [ ${#socks[@]} -eq 0 ]; then
  while IFS= read -r s; do [ -n "$s" ] && socks+=("$s"); done <<EOF
$(fleet_sockets)
EOF
fi

for s in ${socks[@]+"${socks[@]}"}; do
  spath=$(tmux -L "$s" display-message -p '#{socket_path}' 2>/dev/null) || continue
  [ -n "$spath" ] || continue
  rows=$(fleet_lw '#{window_id} #{?@cred_sid,#{@cred_sid},-} #{?@rl_src,#{@rl_src},-} #{?@rl_ts,#{@rl_ts},-}' tmux -L "$s")
  [ -n "$rows" ] || continue
  # one python pass: which windows get which reading (no credential anywhere in it)
  todo=$(FPQ_QUOTA="$q" FPQ_SESS="$CONF/cred-proxy/sessions" python3 -I -c '
import json, os, re, sys
q = json.loads(os.environ["FPQ_QUOTA"] or "{}")
sd = os.environ["FPQ_SESS"]
def qsid(sid):
    try:
        for line in open(os.path.join(sd, sid)):
            if line.startswith("qsid="):
                return line[5:].strip()
    except OSError:
        pass
    return ""
for line in sys.stdin:
    f = line.split()
    if len(f) != 4 or not f[0].startswith("@") or not re.match(r"^[A-Za-z0-9._-]+$", f[1]):
        continue
    wid, sid, src, ts = f
    r = q.get(sid) or q.get(qsid(sid))
    if not r or not isinstance(r.get("ts"), int):
        continue
    have = int(ts) if ts.isdigit() else 0
    if not (r["ts"] > have or (src != "proxy" and r["ts"] >= have - 60)):
        continue
    kv = ["rl5h=%s" % r["rl5h"], "rl7d=%s" % r["rl7d"],
          "rl_reset5=%s" % r["rl_reset5"], "rl_reset7=%s" % r["rl_reset7"], "ts=%d" % r["ts"]]
    if all(re.match(r"^[a-z_0-9]+=(-|[0-9]+(\.[0-9]+)?)$", x) for x in kv):
        print(wid, sid, r.get("provider", "-"), " ".join(kv))
' <<< "$rows")
  [ -n "$todo" ] || continue
  while read -r wid sid prov kvs; do
    # shellcheck disable=SC2086  # kvs: key=value words, digits and - only (checked above)
    TMUX="$spath,0,0" TMUX_PANE="$wid" bash "$SL" --from proxy $kvs
    printf 'stamped %s %s %s (%s) %s\n' "$s" "$wid" "$sid" "$prov" "$kvs"
  done <<< "$todo"
done
exit 0
