#!/bin/bash
# fleet-hub-sessions.sh — a machine's view of YOUR sessions on the other machines
# (issue #1423, EPIC #1419 C4; identity + machine lines issue #1475).
#
# The cross-machine hub (`ccquota hub` with CCQUOTA_FLEET=1, tokenledger #1409)
# answers `fleet_sessions`: every window of every fleet it can see, with its
# worker_id and machine. This script is the ONE thing that asks it, and it never
# runs on the render path: it writes a local cache per fleet, and
# tmux-dashboard-rows.sh only reads that file — the dash repaints 4×/s and must
# never wait on a network (EPIC #1419 rule 4).
#
#   --refresh   one fetch → $FLEET_C/global/remote_<sess> for every fleet on this
#               machine, plus the C1 locator cache control/hub-workers.tsv. A failed
#               fetch leaves the last cache in place: its rows go on rendering, and
#               once global/hub_ok — the epoch of the last round that stood (a
#               200 taken, a 304 restamped), written here and nowhere else — is
#               older than FLEET_HUB_SESSIONS_STALE they read 失联 (issue #1483,
#               EPIC #1479 C4: the rows, the bar and the remote-row actions all
#               read that one file through fleet_status_hub_lost, none probes
#               the hub; the next round that stands flips them back, nothing to
#               restart). A cache from before hub_ok is judged by its own #ts.
#               The same round writes the status bar's two summaries (issue
#               #1482): global/hub_nodes (/v1/nodes) and global/hub_limits
#               (/v1/limits) — or both from POST /v1/fleet/summary when the
#               identity is a connection certificate (issue #1502) — on their own cadence, FLEET_HUB_SUMMARY_EVERY
#               (10s), see refresh_summaries below.
#   --loop      --refresh every FLEET_HUB_SESSIONS_WATCHED_EVERY (2s) while the
#               shared watcher predicate holds AND a real list read was within
#               30s; otherwise wait on fleet-state-changed or a 60s fallback, until
#               FLEET_HUB_SESSIONS_LOOP_SECS (70s) past the newest of
#               global/hubsess.want (an --ensure) and global/hubsess.view (a real
#               list read), then exit. One at a time (the lock, below). The 2 s is half of the 「3 秒内看到」 budget (issue #1481);
#               the other half is the node reporting a change at once
#               (fleet_hub_nudge). The fetch is cheap enough to ask that often
#               because it is conditional: the hub answers fleet_sessions with an
#               ETag (its newest heartbeat + row count), the loop sends it back as
#               If-None-Match, and a 304 carries no body — the rows stand and only
#               the cache's #ts line is re-stamped so they never read 失联 while
#               the hub is answering. A hub without ETags (older) is fetched in
#               full every time, as before.
#               LONG POLL (issue #1526): while someone is looking and a validator
#               is held, the ask also says `wait` (FLEET_HUB_SESSIONS_WAIT, 25s —
#               under an ingress's 60 s idle timeout; curl gives up 5 s after it):
#               the hub holds the 304 and answers the moment a heartbeat moves the
#               validator, so a change lands in ~the node's beat, not up to 2 s
#               later. An answer that was held, or a 200, is asked again at once;
#               an immediate 304 or a failure (an older hub ignores `wait`) falls
#               back to the 2 s cadence. FLEET_HUB_SESSIONS_LONGPOLL=0 turns it
#               off; without a recent list request, it is never sent.
#   --ensure    start a detached --loop unless one is alive (one per cache: the
#               loop holds global/hubsess.lock — issue #2630; never via nohup). The collector runs this
#               every tick (60s), so the fallback needs no daemon of its own and a
#               loop can never outlive the collector by more than one round. Each call
#               stamps global/hubsess.want, and a running loop goes on to LOOP_SECS
#               past the newest stamp (issue #3079) — one loop for as long as the
#               collector lives, no gap between the old loop's end and the next tick. The loop
#               gets its own session (setsid), or launchd kills it with the tick
#               (issue #1596) and the cache stops whenever no command panel is drawing.
#               A VIEWER keeps it too: the loop's end is LOOP_SECS past the newer
#               of hubsess.want and hubsess.view's mtime (fleet_view.py
#               hub_view_request touches it on every real list read). On a node at
#               load 27-43 the collector's ticks overran and each one deferred
#               this --ensure, so the loop ended while the view stamp was 2 s old
#               and ⌘P's other machines stood still for ~3 minutes. Bounded both
#               ways: a stamp older than LOOP_SECS extends nothing, nor does one
#               in the future (it would keep the loop for ever). The collector
#               runs --ensure in its tick's fixed head now (tmux-dash-collect.sh),
#               so an overrun never skips it, and ⌘P's resident panel runs it when
#               the cache is stale and no loop holds the lock (fleet-panel-server.py).
#               An --ensure that STARTS a loop says so in the log, with who asked
#               (FLEET_HUBSESS_BY): the gap between two such lines is the dark time.
#   log         one line per loop start and exit (why: lifetime · guard gone ·
#               replaced by other code · TERM) and per round (200 / 304 / fail,
#               its ms, watched or not) in $FLEET_CONF_DIR/logs/hubsess.log,
#               rotated to .1 at 1 MB — no token, no URL. The 3-minute freeze
#               above could not be reconstructed without it.
#   --status    `loop <pid>|none · cache <age>s|none` for fleet-doctor; rc 1 = no
#               loop or a cache older than FLEET_HUB_SESSIONS_STATUS_STALE (60s).
#   --identity  WHO this login asks the hub as (issue #1475), one line, no network:
#               `cert <cert path> <valid until>` / `token <where it came from>` /
#               `none <why>` — exit 0 for the first two, 1 for none. fleet-doctor
#               reads it; so does a person wondering why the command panel shows no mac-a.
#
# OFF unless CCQUOTA_FLEET=1: every mode is then a silent no-op that writes nothing,
# and the dash never looks for the cache — a one-machine fleet is byte for byte
# what it was (CLAUDE.md «Degenerate case is sacred»).
#
# Who asks (issue #1475), in this order — the first that exists is used:
#   1. FLEET_HUB_SESSIONS_CMD: a seam; it prints the fleet_sessions JSON itself.
#   1b. this login's node token — node.env's
#      CCQUOTA_TOKEN at its hub, or a separated login's credential-proxy broker
#      pair (fleet_node_pair, issue #3106) — as a bearer on curl's stdin config,
#      never its argv (issue #2630): the hub reads it as the login's owner, the scope a certificate
#      gets, and it never expires — the collector's loop no longer goes dark when
#      a certificate lapses or no viewer token exists. A hub older than that door
#      answers 401: noted for FLEET_HUB_SESSIONS_NODE_REFUSED_TTL (600s) and the
#      round falls through to 2. FLEET_HUB_SESSIONS_NODE_TOKEN=0 skips it.
#   2. YOUR connection certificate — ~/.ssh/fleet-cert + fleet-cert-cert.pub, the
#      pair `fleet login` wrote (FLEET_CERT names another key), while it is valid:
#      a POST {cert, sig, ts} with `ssh-keygen -Y sign -n fleet-sessions@claude-fleet`
#      over "fleet-sessions <ts>", the protocol of #1414's /v1/fleet/routes. The hub
#      answers with exactly the machines your ACTIVE accounts are on — no token. A certificate the
#      hub refuses (401: revoked, a clock too far off) falls through to 3.
#   3. the viewer token — CCQUOTA_VIEWER_TOKEN, else ~/.ccquota/viewer-token (the
#      operator's; it sees every login on every machine).
#   4. neither: nothing is fetched, one stderr note, no remote row anywhere, and
#      fleet-doctor's `hub` line WARNs.
# The hub's URL: CCQUOTA_HUB_URL, else FLEET_HUB_URL, else the `url` in
# ~/.config/claude-fleet/hub.json (what `fleet login` remembered).
#
# Which rows: every session whose login is yours (os_user = `id -un`, or
# FLEET_HUB_SESSIONS_USER; `*` = every login the hub shows you — what a node takes
# when the hub answered over its node token, already cut to your logins, issue
# #3001) and that has a
# worker_id — a row the hub could not identify is not addressable, so it is not
# shown. The other machines' rows go into EVERY fleet's cache here; this machine's
# own (issue #1480, EPIC #1479 C1: by fleet UUID, else by hostname + fleet name)
# go into THEIR fleet's cache only, marked `local`=1 and carrying the window id
# they live in right now — mapped once per refresh from the control adapter's
# inventory (`fleet-control-read.sh workers`, the hub's own key rule), never from
# the hub's observation — so a dash that takes its whole list from the hub
# (FLEET_SIDEBAR_SOURCE=hub) can still paint and enter them as local windows. A
# dash on the default source ignores them: nothing it draws changes. The machine
# label is the hostname's first label, renamed through FLEET_NODE_ALIASES
# (`mac-c=mac-b mac-d=mac-a`).
#
# Cache (US-separated — \x1f, as the dash's own WFMT: a TAB is IFS whitespace,
# so `read` would collapse the empty fields). Header lines first:
#   #ts<US><epoch>                                when this cache was written
#   #me<US><label>                                this machine's label (#1475)
#   #node<US><label><US>online|lost<US><n><US><last-seen epoch><US>via   one per OTHER
#       machine the hub shows you (#1475): the command panel's status line — n is your
#       sessions there, last-seen the hub's newest observation of it. From the
#       hub's `nodes` list; derived from the sessions on a hub older than #1475.
# then one row per session:
#   wid:<worker_id>  node  online|lost  issue  repo  state  agent  name  origin  needs  local  wid  via  busy  born  cfg  [title]
#   [reap epic backfill]  [ctx_left ctx_band ctx_ts model effort]  [test]  [akind atext]  [tokens]  [pin]
# Fields 21-25 (issue #2431) are the session's measurement bus (the node's
# inventory columns 24-28): % of the context LEFT, its band, the reading's epoch,
# the model and its effort — `fleet ls` prints them; all five or none (a node
# older than it sends none), so a `read` naming `backfill` last must name one more.
# Fields 27-28 (issue #2538) are what a needs session asks (kind, words); field
# 29 (issue #3377) is the session's pool tokens since this UTC midnight, the
# hub's tokens_today — appended only when there are any, the empty ones before
# it kept, so a reader naming the ask pair last must name one more. Field 30
# (issue #3517) is `1` on a pinned session (the node's `pin=`), the same way.
# Field 26 (issue #2505) is `1` on a session the TEST identity's client placed
# (the node's inventory column 30, @test_identity): the list hides it unless
# FLEET_ROWS_TEST=1 (`fleet ls`); absent on every other row.
# `origin` is already in the viewing fleet's terms: a parent in THIS fleet is its
# bare key (`issue-1419`, exactly what a local @origin holds), a parent elsewhere is
# its full worker_id; no @origin_wid ⇒ the issue's sub-issue parent (the collector's
# parents cache), when that repo is hosted here. `needs` (#1475) is the window's
# @claude_needs — ask / perm / blocked / … — so the row draws the same red `?`.
# `local` (#1480) is 1 for a row of THIS fleet on THIS machine, 0 for another
# machine's; `wid` is a local row's live tmux window id (`@12`; empty when no window
# holds that worker right now), empty on another machine's row. Both are APPENDED,
# so a reader of the ten older fields is unchanged — but a `read` that names `needs`
# last must now name these two too, or they arrive glued to it. `via` (#1488) is
# appended after them, on the rows and the #node lines alike: `hub` — the hub's
# answer — or `node` — the machine itself (the old client's direct connection
# while the hub was silent, issue #1488; that client went with #3008). A reader
# that dims rows for the hub's silence spares a `node` line: that machine answered. `busy` (#1607, rows only) is the
# node's word for a window whose turn is over but whose work is not — `looping`
# (a /loop round still held) or `bg` (a Bash-tool job still running) — empty
# otherwise. A `read` naming `via` last must name
# one more. `born` (#1750, rows only) is the session's birth, epoch seconds (the
# node's @born, else window_created; empty from a node older than it) — the order
# tmux-dashboard-rows.sh draws every machine's rows in. A `read` naming `busy`
# last must name it too. `cfg` (#1783, rows only) is `stale` / `renew` (#1895) / `ok` — the session's
# configuration against the one a fresh session gets on ITS machine now, judged
# there (fleet-control-read.sh); empty when unknown or from an older node. A
# `read` naming `born` last must name it too. `title` (#1921, rows only) is the
# session's issue title off its node's own issue cache (fleet-control-read.sh) —
# what a command panel row and a session's top bar (#1904) show instead of the window
# name's slug. APPENDED only when there is one, so a row without (a scratch, an
# older node) is byte for byte what it was; a `read` naming `cfg` last must name
# it too.
#
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

G="$FLEET_C/global"
EVERY="${FLEET_HUB_SESSIONS_EVERY:-10}"; case "$EVERY" in ''|*[!0-9]*|0) EVERY=10 ;; esac
WATCHED_EVERY="${FLEET_HUB_SESSIONS_WATCHED_EVERY:-2}"; case "$WATCHED_EVERY" in ''|*[!0-9]*|0) WATCHED_EVERY=2 ;; esac
# No real list request: events wake the loop; 60s is only discovery/fallback.
# Preserve explicit interval overrides (including existing accelerated fixtures).
IDLE_EVERY="${FLEET_HUB_SESSIONS_IDLE_EVERY:-${FLEET_HUB_SESSIONS_EVERY:+$EVERY}}"
case "$IDLE_EVERY" in ''|*[!0-9]*|0) IDLE_EVERY=60 ;; esac
ETAGF="$G/hubsess.etag"      # the validator of the cache on disk (issue #1481)
# …and what MAPPED that cache (issue #2397): the ETag vouches for the hub's answer,
# not for the rows this code kept of it. Its second line is this stamp — the code
# that maps (by content, as it loaded), the rows-user knob — and a
# validator under any other stamp is never sent: cj's client, updated to the code
# that keeps his node login's rows (#2390), kept asking with the ETag the old code
# had stored beside an empty cache, and every 304 kept the list empty.
MAPCODE=$(cat "$BIN/fleet-hub-sessions.sh" "$BIN/fleet-lib.sh" "$BIN/fleet-client-core.sh" "$BIN/fleet-render-watch.py" 2>/dev/null | cksum | awk '{ print $1 "-" $2 }')
ETAG_STAMP=''  # this round's stamp (fetch sets it; curl_sessions writes it)
LOOP_SECS="${FLEET_HUB_SESSIONS_LOOP_SECS:-70}"; case "$LOOP_SECS" in ''|*[!0-9]*) LOOP_SECS=70 ;; esac
LP_WAIT="${FLEET_HUB_SESSIONS_WAIT:-25}"; case "$LP_WAIT" in ''|*[!0-9]*|0) LP_WAIT=25 ;; esac
[ "$LP_WAIT" -le 25 ] || LP_WAIT=25
WAIT=''      # the long poll's wait for THIS round (issue #1526); set by loop only
NAP_SOCKS=() # this login's fleet sockets, as watched() last listed them (issue #4261)
NAP_PID=''
FOLLOWUP=0
LP_SENT=0    # 1 = this round's ask carried a validator AND a wait
LAST_FETCH=1 # this round's fetch rc (0 = 200, 3 = 304)
NSCOPED=0    # 1 = …over this login's node token: cut to its person's logins (issue #3001)
PIDF="$G/hubsess.pid"
# Every --ensure stamps its epoch here, and a running loop keeps going until
# LOOP_SECS past the newest stamp (issue #3079): with a 70 s loop and a 60 s
# collector tick, the tick's --ensure used to find the loop still alive, start
# nothing, and leave remote_<sess> unrefreshed for up to a minute once it ended.
WANTF="$G/hubsess.want"
# …and so does a viewer (the 3-minute freeze above): fleet_view.py
# hub_view_request touches this on every real list read. Its MTIME is the stamp.
VIEWF="$G/hubsess.view"
# An --ensure that replaces a loop of other code writes the loop's pid here before
# its TERM, so the loop's exit line says `replaced`, not `term`.
REPLF="$G/hubsess.replace"

# The loop's own record (the 3-minute freeze could not be reconstructed without
# one): one line per start, exit and round, in the login's logs — the install is
# read-only (issue #4668). Rotated to .1 at FLEET_HUB_SESSIONS_LOG_MAX bytes (1 MB),
# checked at the start and every 64 lines, so a round costs one `date` and no `wc`.
# Words only: never a token, a header or a URL.
HLOG="$FLEET_CONF_DIR/logs/hubsess.log"
HLOG_MAX="${FLEET_HUB_SESSIONS_LOG_MAX:-1048576}"; case "$HLOG_MAX" in ''|*[!0-9]*|0) HLOG_MAX=1048576 ;; esac
HLOG_N=0
hlog() {
  local sz
  if [ $(( HLOG_N % 64 )) = 0 ]; then
    mkdir -p "${HLOG%/*}" 2>/dev/null || return 0
    sz=$( { wc -c < "$HLOG"; } 2>/dev/null | tr -d ' ')
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    [ "$sz" -lt "$HLOG_MAX" ] || mv -f "$HLOG" "$HLOG.1" 2>/dev/null
  fi
  HLOG_N=$(( HLOG_N + 1 ))
  { printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$$" "$*" >> "$HLOG"; } 2>/dev/null
  return 0
}
# ms_now → MS: milliseconds, from bash 5's EPOCHREALTIME (no fork); bash 3.2 has
# none, and gets the second ×1000 — a round's duration to the second there.
MS=0
ROUNDS_N=0; EXIT_WHY=''; LOOP_T0=''
ms_now() {
  local t="${EPOCHREALTIME:-}"
  if [ -n "$t" ]; then t=${t/[.,]/}; MS=$(( t / 1000 )); else MS=$(( $(date +%s) * 1000 )); fi
}
# mtime_of <file> → its mtime in epoch seconds on stdout, 0 when it is absent.
# GNU stat FIRST: `stat -f %m` on GNU means "filesystem status" and exits 0.
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# The code the running loop loaded (its MAPCODE), written at its start: an
# --ensure of other code replaces the loop (issue #3164). The loop is kept alive
# by every --ensure, so before this a version switch never reached it — mac-c's
# loop ran the code from before #3107's broker for hours after the switch and
# kept the two-hour-old list on screen.
LOOPCODEF="$G/hubsess.loopcode"
SESSIONS_NS='fleet-sessions@claude-fleet'
SUMMARY_NS='fleet-summary@claude-fleet'   # the status bar's two summaries (#1502)

# The fleets this loop serves: every fleet configured on this machine whose hub
# switch is on (issue #1539: per fleet — a fleet conf's own CCQUOTA_FLEET line
# wins over the environment, so one fleet can stay local beside a hub one; no such
# line anywhere ⇒ the environment decides for all, as before). The old client's
# one pseudo-fleet (FLEET_HUB_SESSIONS_CLIENT, issue #1484) went with that client
# (#3008).
hub_on() { fleet_hub_any; }
local_fleets() {
  local s c
  while IFS=$'\t' read -r s c; do
    [ -n "$s" ] && fleet_hub_on "$s" && printf '%s\t%s\n' "$s" "$c"
  done <<EOF
$(fleet_each_conf)
EOF
}

# hub_url → the hub's URL on stdout, rc 1 when none is configured anywhere.
hub_url() {
  local u="${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}"
  if [ -z "$u" ]; then
    u=$(python3 - "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" <<'PY' 2>/dev/null
import json, sys
try:
    print(str(json.load(open(sys.argv[1])).get("url") or ""))
except Exception:
    pass
PY
)
  fi
  [ -n "$u" ] || return 1
  printf '%s\n' "${u%/}"
}

# cert_paths → sets CERT_KEY / CERT_PUB (the `fleet login` pair, or FLEET_CERT's).
cert_paths() {
  CERT_KEY="${FLEET_CERT:-$HOME/.ssh/fleet-cert}"
  CERT_PUB="$CERT_KEY-cert.pub"
}

# cert_state → `ok <valid-until>` / `expired <valid-until>` / `missing` on stdout.
# Local only: ssh-keygen -L's `Valid:` line against this clock.
cert_state() {
  cert_paths
  [ -f "$CERT_KEY" ] && [ -f "$CERT_PUB" ] || { printf 'missing\n'; return 0; }
  command -v ssh-keygen >/dev/null 2>&1 || { printf 'missing\n'; return 0; }
  ssh-keygen -L -f "$CERT_PUB" 2>/dev/null | python3 -c '
import sys, time
state, until = "ok", "forever"
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("Valid:"):
        continue
    w = line.split()
    if "forever" in line or len(w) < 5:
        break
    try:
        start = time.mktime(time.strptime(w[2], "%Y-%m-%dT%H:%M:%S"))
        end = time.mktime(time.strptime(w[4], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        break
    until = w[4]
    now = time.time()
    if now < start - 300 or now > end:
        state = "expired"
    break
print(state, until)
' 2>/dev/null || printf 'missing\n'
}

# token_source → `env` / `file` on stdout and the token in $TOK; rc 1 when none.
token_source() {
  TOK="${CCQUOTA_VIEWER_TOKEN:-}"
  if [ -n "$TOK" ]; then printf 'env\n'; return 0; fi
  [ -r "$HOME/.ccquota/viewer-token" ] && read -r TOK < "$HOME/.ccquota/viewer-token" || TOK=''
  [ -n "$TOK" ] || return 1
  printf 'file\n'
}

# node_token → rc 0 with this login's node token in $NTOK and the address it is
# good at in $NURL (issue #2630; #3106): node mode only (the shell is a person's
# computer, never a node), node.env's token at its hub — or, separated, the
# credential proxy's broker pair (fleet_node_pair; re-minted past NODE_PAIR_TTL,
# its fcpn1. lives 600 s) — and not refused by this hub within NODE_REFUSED_TTL.
# It never enters the environment.
NTOK=''; NURL=''; NPAIR=''; NTOK_AT=0; AUTH_TOK=''
NODE_PAIR_TTL=300
NODE_REFUSED_TTL="${FLEET_HUB_SESSIONS_NODE_REFUSED_TTL:-600}"
case "$NODE_REFUSED_TTL" in ''|*[!0-9]*) NODE_REFUSED_TTL=600 ;; esac
node_token() {
  local t
  NTOK=''
  [ "${FLEET_HUB_SESSIONS_NODE_TOKEN:-1}" != 0 ] || return 1
  [ -r "$(fleet_node_env_file)" ] || _fleet_node_separated || return 1
  { read -r t < "$G/hubsess.nodetok.refused"; } 2>/dev/null || t=''
  case "$t" in ''|*[!0-9]*) ;; *) [ $(( $(date +%s) - t )) -ge "$NODE_REFUSED_TTL" ] || return 1 ;; esac
  if [ -n "$NPAIR" ] && [ $(( $(date +%s) - NTOK_AT )) -lt "$NODE_PAIR_TTL" ]; then :
  else NPAIR=$(fleet_node_pair "$(hub_url 2>/dev/null)") || NPAIR=''; NTOK_AT=$(date +%s); fi
  case "$NPAIR" in *"	"*) ;; *) NPAIR=''; return 1 ;; esac
  NURL=${NPAIR%%	*}; NTOK=${NPAIR#*	}
  [ -n "$NTOK" ] && [ -n "$NURL" ]
}

# identity → one line: cert … / token … / none …; rc 0 / 0 / 1.
identity() {
  local st src
  if [ -n "${FLEET_HUB_SESSIONS_CMD:-}" ]; then printf 'cmd FLEET_HUB_SESSIONS_CMD\n'; return 0; fi
  if node_token; then
    if [ -r "$(fleet_node_env_file)" ]; then printf 'node %s\n' "$(fleet_node_env_file)"
    else printf 'node the credential proxy broker (separated)\n'; fi
    return 0
  fi
  st=$(cert_state)
  case "$st" in
    ok\ *) printf 'cert %s %s\n' "$CERT_PUB" "${st#ok }"; return 0 ;;
  esac
  if src=$(token_source); then
    case "$src" in env) printf 'token CCQUOTA_VIEWER_TOKEN\n' ;; *) printf 'token ~/.ccquota/viewer-token\n' ;; esac
    return 0
  fi
  case "$st" in
    expired\ *) printf 'none certificate expired %s (run `fleet login` again) and no viewer token\n' "${st#expired }" ;;
    *)          printf 'none no connection certificate (%s — run `fleet login`) and no viewer token\n' "${CERT_PUB:-~/.ssh/fleet-cert-cert.pub}" ;;
  esac
  return 1
}

# curl_sessions <out> <etag> <curl args…> — one fleet_sessions request into
# <out>, with the validator (issue #1481) when we hold one. rc 0 = 200 (the
# ETag the body came with is kept in $ETAGF; none ⇒ an older hub, dropped);
# 3 = 304, nothing changed since <etag> (the <out> file is empty); 4 = 401/403,
# the credential was refused; 1 = anything else.
curl_sessions() {
  local out="$1" etag="$2" hdr code max=8; shift 2
  hdr=$(mktemp "$G/hubsess.hdr.XXXXXX") || return 1
  [ "$LP_SENT" = 1 ] && max=$(( WAIT + 5 ))
  set -- -sS -m "$max" -o "$out" -D "$hdr" -w '%{http_code}' "$@"
  [ -n "$etag" ] && set -- "$@" -H "If-None-Match: $etag"
  if [ -n "$AUTH_TOK" ]; then
    # the bearer rides curl's config on stdin (a builtin printf): never an argv
    # another login's `ps` can read (issue #2630)
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_TOK" | curl -K - "$@" 2>/dev/null)
  else
    code=$(curl "$@" 2>/dev/null)
  fi
  case "$code" in
    200) etag=$(awk 'tolower($1) == "etag:" { sub(/\r$/, "", $2); print $2; exit }' "$hdr" 2>/dev/null)
         rm -f "$hdr"
         if [ -n "$etag" ]; then printf '%s\n%s\n' "$etag" "$ETAG_STAMP" > "$ETAGF.new.$$" && mv -f "$ETAGF.new.$$" "$ETAGF"
         else rm -f "$ETAGF"; fi
         return 0 ;;
    304)     rm -f "$hdr"; return 3 ;;
    401|403) rm -f "$hdr"; REFUSED_CODE=$code; principal_note "$out"; return 4 ;;
    *)       rm -f "$hdr"; return 1 ;;
  esac
}

# principal_note <body> — a 401 that is the certificate's principals not being
# the login the hub checks (issue #2457, after #2437) is said in the person's
# words, once per refusal, instead of reading as 「入口连不上」 further down.
# The wording is fleet-connect.py's (principal_hint), never a second copy.
PRINCIPAL_SAID=''
principal_note() {
  local hint
  [ -s "$1" ] && [ -f "$BIN/fleet-connect.py" ] || return 0
  hint=$(python3 "$BIN/fleet-connect.py" --principal-hint < "$1" 2>/dev/null) || return 0
  [ -n "$hint" ] || return 0
  PRINCIPAL_SAID=1
  printf 'fleet-hub-sessions: %s\n' "$hint" >&2
}

# fetch_cert <url> <out> <etag> → the JSON into <out>; rc as curl_sessions
# (4 = the hub refused the certificate: fall back).
fetch_cert() {
  local url="$1" out="$2" etag="$3" ts sig cert body
  ts=$(date +%s)
  sig=$(printf 'fleet-sessions %s' "$ts" | ssh-keygen -Y sign -f "$CERT_KEY" -n "$SESSIONS_NS" 2>/dev/null) || return 1
  cert=$(head -n1 "$CERT_PUB" 2>/dev/null) || return 1
  body=$(python3 -c 'import json, sys
b = {"cert": sys.argv[1], "sig": sys.argv[2], "ts": int(sys.argv[3])}
if sys.argv[4]: b["wait"] = int(sys.argv[4])
print(json.dumps(b))' \
         "$cert" "$sig" "$ts" "$([ "$LP_SENT" = 1 ] && printf '%s' "$WAIT")") || return 1
  curl_sessions "$out" "$etag" -X POST -H 'Content-Type: application/json' --data-binary "$body" "$url/v1/fleet/fleet_sessions"
}

# fetch <out> <local-fleets> → the fleet_sessions JSON into <out>. rc 0 = a fresh
# body; 3 = 304, nothing changed since the ETag on disk (the <out> file is empty);
# 1 = no answer. The validator goes out only while every cache it vouches for is
# on disk — a fleet created since, or a wiped $FLEET_C, needs the body.
fetch() {
  local out="$1" lf="$2" url st rc etag='' stamp sess _c q
  PRINCIPAL_SAID=''; REFUSED_CODE=''
  if [ -n "${FLEET_HUB_SESSIONS_CMD:-}" ]; then
    bash -c "$FLEET_HUB_SESSIONS_CMD" </dev/null >"$out" 2>/dev/null; return
  fi
  url=$(hub_url) || { printf 'fleet-hub-sessions: no hub URL (CCQUOTA_HUB_URL / FLEET_HUB_URL / hub.json) — no other machine to show\n' >&2; return 1; }
  command -v curl >/dev/null 2>&1 || return 1
  st=$(cert_state)
  case "$st" in ok\ *) ETAG_STAMP=cert ;; *) ETAG_STAMP=token ;; esac
  node_token && ETAG_STAMP=node
  ETAG_STAMP="map $MAPCODE $ETAG_STAMP node ${FLEET_HUB_SESSIONS_USER:-}"
  if [ -s "$G/hubsess.body" ] && [ -s "$ETAGF" ] && { read -r etag; IFS= read -r stamp || stamp=''; } < "$ETAGF" && [ -n "$etag" ]; then
    [ "$stamp" = "$ETAG_STAMP" ] || etag=''
    while IFS=$'\t' read -r sess _c; do
      [ -z "$sess" ] || [ -s "$G/remote_$sess" ] || { etag=''; break; }
    done < "$lf"
  fi
  # the long poll (issue #1526): only with a validator to hold against
  q=''; LP_SENT=0; NSCOPED=0
  if [ -n "$WAIT" ] && [ -n "$etag" ]; then LP_SENT=1; q="?wait=$WAIT"; fi
  if [ -n "$NTOK" ]; then
    AUTH_TOK=$NTOK
    curl_sessions "$out" "$etag" "$NURL/v1/fleet/fleet_sessions$q"; rc=$?; AUTH_TOK=''
    # The hub answers a node token with its login's PERSON's rows — every login
    # of theirs, on every machine (FleetScope, issue #3001); a login no person
    # holds is refused below and reads as before.
    [ "$rc" = 4 ] || { NSCOPED=1; return "$rc"; }
    # A hub older than the node-token door (#2630) says 401: remember it for
    # NODE_REFUSED_TTL, so the 2 s cadence does not ask twice a round.
    date +%s > "$G/hubsess.nodetok.refused" 2>/dev/null
    printf 'fleet-hub-sessions: the hub refused this login'"'"'s node token — trying the certificate / viewer token\n' >&2
    etag=''; q=''; LP_SENT=0
    case "$st" in ok\ *) ETAG_STAMP=${ETAG_STAMP/ node / cert } ;; *) ETAG_STAMP=${ETAG_STAMP/ node / token } ;; esac
  fi
  case "$st" in
    ok\ *)
      fetch_cert "$url" "$out" "$etag"; rc=$?
      # A certificate is always a person, never the operator: the hub has already
      # cut the answer to the (machine, login) pairs of their accounts (FleetScope)
      [ "$rc" = 4 ] || return "$rc"
      if [ -n "$PRINCIPAL_SAID" ]; then printf 'fleet-hub-sessions: trying the viewer token\n' >&2
      else printf 'fleet-hub-sessions: the hub refused the connection certificate %s — trying the viewer token\n' "$CERT_PUB" >&2; fi
      # the token's answer is another identity's: no validator, its own stamp
      etag=''; q=''; LP_SENT=0; ETAG_STAMP=${ETAG_STAMP/ cert / token } ;;
  esac
  if token_source >/dev/null; then
    AUTH_TOK=$TOK
    curl_sessions "$out" "$etag" "$url/v1/fleet/fleet_sessions$q"; rc=$?; AUTH_TOK=''
    [ "$rc" = 4 ] && rc=1
    return "$rc"
  fi
  printf 'fleet-hub-sessions: %s — the command panel (⌘P) shows no other machine\n' "$(identity | sed 's/^none //')" >&2
  return 1
}

# hub_ok <epoch> — the ONE word on 「入口通不通」 (issue #1483, EPIC #1479 C4):
# written on every round whose answer stood (a 200 taken in refresh, a 304
# restamped below), never on a failed one — so its age IS the hub's silence.
# fleet_status_hub_ok / fleet_status_hub_lost (fleet-status-lib.sh) are the
# readers; a cache from before this file is judged by its own #ts there.
#
# A one-shot --refresh may run beside the loop (⌘P's hub_fresh no longer kills one
# at its wait, so it can still be running when the loop starts): every write here
# is a temp of its own + one rename — mktemp / mkstemp for the caches and the body,
# `.new.<pid>` for hub_ok, hub_why and the ETag — so two writers never share a
# half-written file. The worst a race leaves is one round's older body under a
# newer ETag, which the hub's next heartbeat (a new validator ⇒ a 200) replaces.
hub_ok() {
  printf '%s\n' "$1" > "$G/hub_ok.new.$$" 2>/dev/null && mv -f "$G/hub_ok.new.$$" "$G/hub_ok"
  rm -f "$G/hub_why"
  fleet_hub_auth_note hub-sessions ok
  return 0
}

# hub_why <refused|unreachable> <detail> — WHY the hub's last round did not stand
# (issue #2465), beside hub_ok: `<why><TAB><since epoch><TAB><detail>`. refused =
# it answered 401/403 (the credential is the thing to fix); unreachable = no
# answer at all. The since is kept while the reason does not change, so a reader
# can say how long it has refused; hub_ok removes the file. The rows keep their
# 失联 rule (#1483) — this only names the cause.
REFUSED_CODE=''
hub_why() {
  local why="$1" detail="${2:-}" since='' w s _d
  { IFS=$'\t' read -r w s _d < "$G/hub_why"; } 2>/dev/null && [ "$w" = "$why" ] && since=$s
  case "$since" in ''|*[!0-9]*) since=$(date +%s) ;; esac
  printf '%s\t%s\t%s\n' "$why" "$since" "$detail" > "$G/hub_why.new.$$" 2>/dev/null && mv -f "$G/hub_why.new.$$" "$G/hub_why"
  [ "$why" = refused ] && fleet_hub_auth_note hub-sessions fail "$detail"
  return 0
}

# restamp <local-fleets> — a 304's only writes: the #ts line of every fleet's cache
# (the rows and the #me/#node header lines are unchanged, the hub is answering),
# hub_ok, plus the C1 locator cache's mtime, which _fleet_hub_node trusts by age.
restamp() {
  local lf="$1" now sess _c f tmp
  now=$(date +%s)
  while IFS=$'\t' read -r sess _c; do
    [ -n "$sess" ] || continue
    f="$G/remote_$sess"; [ -s "$f" ] || continue
    tmp=$(mktemp "$G/.hubsess.XXXXXX") || continue
    if { printf '#ts\037%s\n' "$now"; tail -n +2 "$f"; } > "$tmp" 2>/dev/null; then mv -f "$tmp" "$f"; else rm -f "$tmp"; fi
  done < "$lf"
  [ -f "$FLEET_CONF_DIR/control/hub-workers.tsv" ] && touch "$FLEET_CONF_DIR/control/hub-workers.tsv" 2>/dev/null
  hub_ok "$now"
  return 0
}

# rows_user — whose sessions this round's answer is cut to: FLEET_HUB_SESSIONS_USER,
# else `*` when the answer came over this login's node token (issue #3001: the hub
# cut it to this login's person — their other logins' sessions, here and on every
# machine, are theirs too), else `id -un`.
rows_user() {
  if [ -n "${FLEET_HUB_SESSIONS_USER:-}" ]; then printf '%s' "$FLEET_HUB_SESSIONS_USER"
  elif [ "$NSCOPED" = 1 ]; then printf '*'
  else id -un 2>/dev/null; fi
}

# inv_cached <sess> <now> <mf> — the fleet's kept line on stdout and its kept
# window rows appended to <mf>, rc 0; rc 1 (nothing written) when there is none,
# it is older than the TTL, or hub-nudge moved since the round that read it
# (issue #3544). The kept file carries that round's START mtime (inv_keep), so a
# nudge that landed while the inventory was being read is never masked.
INV_TTL="${FLEET_HUB_SESSIONS_INV_TTL:-15}"; case "$INV_TTL" in ''|*[!0-9]*) INV_TTL=15 ;; esac
INV_ON=0     # set by loop() only: a one-shot --refresh always reads afresh
inv_cached() {
  local f="$G/hubsess.inv.$1" n="$FLEET_CONF_DIR/global/hub-nudge" at line row
  [ "$INV_ON" = 1 ] && [ "$INV_TTL" -gt 0 ] && [ -f "$n" ] && [ "$f" -nt "$n" ] || return 1
  {
    IFS= read -r at && IFS= read -r line || return 1
    case "$at" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( $2 - at )) -ge 0 ] && [ $(( $2 - at )) -lt "$INV_TTL" ] || return 1
    printf '%s\n' "$line"
    while IFS= read -r row; do printf '%s\n' "$row"; done >> "$3"
  } < "$f"
}
# inv_keep <sess> <now> <line> <rows> — keep this round's read for inv_cached,
# only when hub-nudge is strictly older than the round's start (same second on a
# filesystem test that reads seconds = not kept: read again next round).
inv_keep() {
  local f="$G/hubsess.inv.$1" n="$FLEET_CONF_DIR/global/hub-nudge" st="$G/hubsess.inv.start"
  [ "$INV_ON" = 1 ] || return 0
  [ "$INV_TTL" -gt 0 ] && [ -f "$n" ] && [ "$st" -nt "$n" ] || { rm -f "$f" 2>/dev/null; return 0; }
  { printf '%s\n%s\n' "$2" "$3"; [ -z "$4" ] || printf '%s\n' "$4"; } > "$f.new" 2>/dev/null \
    && touch -r "$st" "$f.new" 2>/dev/null && mv -f "$f.new" "$f" 2>/dev/null
  return 0
}

refresh() {
  hub_on || return 0
  local json sess _c u lf mf repos m rc now ok inv_line inv_rows
  mkdir -p "$G" 2>/dev/null || return 1
  json=$(mktemp "$G/hubsess.json.XXXXXX") || return 1
  lf=$(mktemp "$G/hubsess.local.XXXXXX") || { rm -f "$json"; return 1; }
  mf=$(mktemp "$G/hubsess.map.XXXXXX") || { rm -f "$json" "$lf"; return 1; }
  # This machine's fleets: name, UUID (may be empty), multi-repo bit, hosted repos —
  # and (issue #1480) each one's live window inventory, through the SAME adapter
  # the node agent reports to the hub with, so a local row's worker_id is derived
  # by one rule on both sides and maps back to the window that holds it NOW.
  # Built BEFORE the fetch (issue #1481): `fetch` reads the fleet list to decide
  # whether every cache the hub's answer would replace exists, which is what
  # makes a 304 safe to take.
  : > "$mf"
  if [ "$INV_ON" = 1 ]; then now=$(date +%s); : > "$G/hubsess.inv.start" 2>/dev/null; fi
  while IFS=$'\t' read -r sess _c; do
    [ -n "$sess" ] || continue
    # The fleet's line + its window inventory, kept between a loop's rounds (issue
    # #3544): a watched loop asks every 2 s and the inventory is ~25 processes a round,
    # but it only changes on a spawn, a close or a state change — each of which
    # touches hub-nudge. So the last one is reused while it is younger than
    # FLEET_HUB_SESSIONS_INV_TTL (15 s, the agent's own `workers` cache) AND
    # strictly newer than hub-nudge; a one-shot --refresh, no nudge file (no hub
    # nudges here) or 0 ⇒ read every round, byte for byte as before.
    inv_cached "$sess" "${now:-0}" "$mf" && continue
    u=$(fleet_uuid "$sess" 2>/dev/null) || u=''
    repos=$(fleet_repos "$sess" 2>/dev/null | tr '\n' ' ')
    m=1   # every key carries its repo (issue #1939) — the bit stays for an older reader
    inv_line=$(printf '%s\t%s\t%s\t%s' "$sess" "$u" "$m" "$repos")
    inv_rows=$(bash "$BIN/fleet-control-read.sh" workers "$sess" 2>/dev/null \
      | while IFS= read -r line; do [ -n "$line" ] && printf '%s\t%s\n' "$sess" "$line"; done)
    printf '%s\n' "$inv_line"
    [ -z "$inv_rows" ] || printf '%s\n' "$inv_rows" >> "$mf"
    inv_keep "$sess" "${now:-0}" "$inv_line" "$inv_rows"
  done > "$lf" <<EOF
$(local_fleets)
EOF
  fetch "$json" "$lf"; rc=$?; LAST_FETCH=$rc
  if [ "$rc" = 3 ]; then
    # The validator only covers the hub body, not local windows/parent files.
    # Remap that retained body when those inputs changed, even on a 304.
    if [ -s "$G/hubsess.body" ]; then
      cp "$G/hubsess.body" "$json"; rc=0
    else
      restamp "$lf"; rm -f "$json" "$lf" "$mf"; return 0
    fi
  fi
  if [ "$rc" != 0 ] || [ ! -s "$json" ]; then
    # one line, with how long the hub has been silent (hub_ok is left as it was);
    # a principal mismatch was already said in its own words — not 「unreachable」
    ok=''; { read -r ok _c < "$G/hub_ok"; } 2>/dev/null || ok=''
    [ -n "$PRINCIPAL_SAID" ] && ok=principal
    if [ -n "$REFUSED_CODE" ]; then hub_why refused "HTTP $REFUSED_CODE${PRINCIPAL_SAID:+ (certificate principals)}"
    else hub_why unreachable "no answer"; fi
    case "$ok" in
      principal) printf 'fleet-hub-sessions: the hub answered but refused this certificate (above) — keeping the last cache\n' >&2 ;;
      ''|*[!0-9]*) printf 'fleet-hub-sessions: hub unreachable — keeping the last cache (its rows read 失联 once hub_ok is older than %ss)\n' "${FLEET_HUB_SESSIONS_STALE:-60}" >&2 ;;
      *) printf 'fleet-hub-sessions: hub unreachable for %ss — keeping the last cache (its rows read 失联 past %ss; the next answer flips them back)\n' "$(( $(date +%s) - ok ))" "${FLEET_HUB_SESSIONS_STALE:-60}" >&2 ;;
    esac
    rm -f "$json" "$lf" "$mf"
    return 1
  fi
  now=$(date +%s)
  map_write "$json" "$lf" "$mf" "$now" hub "$(rows_user)"; rc=$?
  if [ "$rc" = 0 ]; then mv -f "$json" "$G/hubsess.body"; fi
  rm -f "$json" "$lf" "$mf"
  # A cache that failed to write is not vouched for: the next fetch takes the body.
  # One that stood is the hub answering: hub_ok (#1483).
  if [ "$rc" = 0 ]; then hub_ok "$now"; else rm -f "$ETAGF"; fi
  return "$rc"
}

# map_write <json> <local-fleets> <window-map> <now> <via> <user> — the ONE mapping
# from a fleet_sessions document (the hub's answer, via=hub) to the caches.
map_write() {
  local json="$1" lf="$2" mf="$3" now="$4" via="$5" user="$6"
  python3 - "$json" "$lf" "$G" "$FLEET_C" "$FLEET_CONF_DIR/control/hub-workers.tsv" \
    "$user" "$(hostname 2>/dev/null)" \
    "${FLEET_NODE_ALIASES:-}" "$now" "$mf" "$BIN" "$via" "$(id -un 2>/dev/null)" "$MAPCODE" <<'PY'
import hashlib, json, os, re, sys, tempfile, time
from pathlib import Path
from datetime import datetime, timezone
jpath, lpath, gdir, cdir, wpath, user, host, aliases, now, mpath, bindir, via, login = sys.argv[1:14]
sys.path.insert(0, bindir)
import fleet_iso  # the one ISO reader (issue #2024)
try:
    data = json.load(open(jpath, encoding="utf-8"))
    sessions = data["sessions"]
    assert isinstance(sessions, list)
except Exception:
    sys.stderr.write("fleet-hub-sessions: the hub's answer is not a fleet_sessions list — keeping the last cache\n")
    sys.exit(1)
alias = dict(a.split("=", 1) for a in aliases.split() if "=" in a)
short = lambda h: (h or "").split(".", 1)[0]
label = lambda h: alias.get(h) or alias.get(short(h)) or short(h) or "?"
me = short(host)
local = []
for line in open(lpath, encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 4 and p[0]:
        local.append(dict(sess=p[0], uuid=p[1], multi=p[2] == "1", repos=p[3].split()))
local_uuids = {f["uuid"] for f in local if f["uuid"]}
clean = lambda v: re.sub(r"[\t\n\r\x1f]", " ", str(v if v is not None else ""))

# The hub response plus local mapping inputs, not the clock, determine the
# rows. Verify retained outputs too: deletion/corruption forces a real rebuild.
def notify_rows(rows):
    if os.path.exists(os.path.join(os.path.dirname(os.path.dirname(wpath)), "thin-lease.json")):
        try:
            import fleet_notify
            os.environ["FLEET_CONF_DIR"] = os.path.dirname(os.path.dirname(wpath))
            fleet_notify.beat(rows, gdir, "", sender=[sys.executable, os.path.join(bindir, "fleet_thin_lease.py"), "notify"])
        except Exception as e:
            sys.stderr.write("fleet-hub-sessions: notify: %s\n" % e)

memo_path = Path(gdir) / "hubsess.map.json"
def digest_file(path, rows=False):
    try:
        raw = Path(path).read_bytes()
        if rows and raw.startswith(b"#ts\x1f"):
            raw = raw.partition(b"\n")[2]
        return hashlib.sha256(raw).hexdigest()
    except OSError:
        return None

parent_paths = sorted({str(Path(cdir) / "fleets" / re.sub(r"[^A-Za-z0-9._-]", "", r.replace("/", "-")) / "parents")
                       for f in local for r in f["repos"]})
inputs = [sys.argv[14], user, host, aliases, via, login,
          digest_file(jpath), digest_file(lpath), digest_file(mpath),
          [(p, digest_file(p)) for p in parent_paths]]
key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
outputs = [wpath, str(Path(gdir) / "fleet_logins"), str(Path(gdir) / "wid_ids")] + [str(Path(gdir) / (pre + f["sess"]))
           for f in local for pre in ("remote_", "epicstale_", "orphanrep_", "notices_")]
def output_digests():
    return {p: digest_file(p, rows=Path(p).name.startswith("remote_")) for p in outputs}
try:
    memo = json.loads(memo_path.read_text())
    if memo["key"] == key and memo["outputs"] == output_digests():
        for f in local:
            path = Path(gdir) / ("remote_" + f["sess"])
            raw = path.read_text()
            fd, tmp = tempfile.mkstemp(dir=gdir, prefix=".hubsess.")
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                out.write("#ts\x1f%s\n" % now + raw.partition("\n")[2])
            os.replace(tmp, path)
        os.utime(wpath, None)
        notify_rows(memo["rows"])
        sys.exit(0)
except (OSError, ValueError, KeyError, TypeError):
    pass

# This machine's live windows (issue #1480): (fleet, key) → window id, keyed by
# the hub's own rule (fleet_hub_common.worker_key, what the node agent reports),
# so a local row's worker_id maps to the window that holds it right now.
sys.path.insert(0, bindir)
try:
    from fleet_hub_common import worker_key
except Exception:
    worker_key = None
windows = {}
if worker_key is not None:
    try:
        for line in open(mpath, encoding="utf-8"):
            p = line.rstrip("\n").split("\t")
            if len(p) < 5 or not re.fullmatch(r"@[0-9]+", p[1]):
                continue
            issue = int(p[2]) if p[2].isdigit() and int(p[2]) > 0 else None
            k = worker_key(issue, p[3] == "1", p[4], p[9] if len(p) > 9 else "")
            if k:
                windows[(p[0], k)] = p[1]
    except OSError:
        pass
slug = lambda r: re.sub(r"[^A-Za-z0-9._-]", "", (r or "").replace("/", "-"))

def epoch(iso):
    """A hub timestamp (RFC 3339, any precision) → epoch seconds, 0 when unreadable."""
    return fleet_iso.epoch(iso, utc=True)

def fepoch(iso):
    """As epoch(), to the millisecond (the end-to-end log, issue #1631)."""
    return fleet_iso.fepoch(iso, 0.0, utc=True)

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".hubsess.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)

# The C1 locator cache: worker_id → machine, for every routable session.
# A session's lifelong identity (issue #1646): the worker's `identity` (its
# @fleet_id) answers as `<fleet UUID>/<identity>` too — the locator finds the
# session by the worker_id its children hold, and an identity-form @origin_wid
# reads back as the key-form worker_id the rows below are keyed by.
IDRE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
def ident_wid(s):
    i, wid = (s.get("worker") or {}).get("identity"), s.get("worker_id") or ""
    return wid.split("/", 1)[0] + "/" + i if isinstance(i, str) and IDRE.fullmatch(i) and "/" in wid else None
by_ident = {}
for s in sessions:
    iw = ident_wid(s)
    if iw:
        by_ident[iw] = s["worker_id"]
write(wpath, "".join("%s\t%s\n" % (w, label(s.get("machine_name")))
                     for s in sessions if s.get("worker_id")
                     for w in (s["worker_id"], ident_wid(s)) if w))
# …and each key-form worker_id's ID (EPIC T644 C7): a row is keyed by its key, its
# short code / EPIC parent / result are its ID's — the view reads them off the ID
# cache by this pair (`<worker_id>\t<ID>`, login-wide), so another machine's
# session shows the same code whichever machine is home.
write(os.path.join(gdir, "wid_ids"), "".join("%s\t%s\n" % (s["worker_id"], (s.get("worker") or {})["identity"])
                                              for s in sessions if s.get("worker_id") and ident_wid(s)))

# Another login's session on this machine (issue #3001: a node's answer may carry
# every login of its person) is never this login's local row — its fleet may well
# share this one's name. A row with no os_user (an older hub) reads as before.
other_login = lambda s: isinstance(s.get("os_user"), str) and s["os_user"] != login
is_local = lambda s: not other_login(s) and (s.get("fleet_id") in local_uuids or short(s.get("machine_name")) == me)
def local_fleet(s):
    """The fleet HERE a local session belongs to: by UUID; else, for a session the
    hub places on THIS host, by fleet name — a machine with no control database
    has no UUID to match, and a UUID minted under another conf (the node agent's
    environment is not a pane's) must not lose this machine its own rows. None:
    not attributable — no row."""
    for f in local:
        if f["uuid"] and s.get("fleet_id") == f["uuid"]:
            return f
    if short(s.get("machine_name")) == me:
        for f in local:
            if s.get("fleet_name") == f["sess"]:
                return f
    return None
def born_of(w):
    """A session's birth, epoch seconds (issue #1750) — the node's `born`, or ""."""
    b = w.get("born")
    return str(b) if isinstance(b, int) and not isinstance(b, bool) and b > 0 else ""

def stale_of(w):
    """The node's batches nobody drives (issue #1916): the worker's `epic_stale`
    — the same list on every row of that login — as (ref, age, title) kept valid."""
    out = []
    for e in (w.get("epic_stale") if isinstance(w.get("epic_stale"), list) else [])[:20]:
        if not isinstance(e, dict) or not isinstance(e.get("epic"), str) or type(e.get("age")) is not int:
            continue
        if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]{0,9}", e["epic"]) and e["age"] >= 0:
            out.append((e["epic"], e["age"], e.get("title") if isinstance(e.get("title"), str) else ""))
    return out


def notices_of(w):
    """The login's read mark and messages not seen yet (T701): the worker's
    `notices` — the same on every row of that login — as (mark, [(id, ts, level,
    kind, sub, wid, text)]) kept valid; (0, []) when none."""
    n = w.get("notices") if isinstance(w.get("notices"), dict) else {}
    mark = n.get("mark") if type(n.get("mark")) is int else 0
    out = []
    for e in (n.get("rows") if isinstance(n.get("rows"), list) else [])[:10]:
        if not isinstance(e, dict) or not isinstance(e.get("id"), str) or type(e.get("ts")) is not int:
            continue
        if not re.fullmatch(r"[0-9a-f]{12}", e["id"]):
            continue
        out.append((e["id"], e["ts"]) + tuple(e.get(k) if isinstance(e.get(k), str) else ""
                                              for k in ("level", "kind", "sub", "wid", "text")))
    return mark, out


def orphans_of(w):
    """The login's unread results of sessions whose spawner was gone (issue
    #3369): the worker's `orphan_reports` — the same list on every row of that
    login — as (id, ts, repo, child, state, pr, summary) kept valid."""
    out = []
    for e in (w.get("orphan_reports") if isinstance(w.get("orphan_reports"), list) else [])[:10]:
        if not isinstance(e, dict) or not isinstance(e.get("id"), str) or type(e.get("ts")) is not int:
            continue
        if not re.fullmatch(r"[0-9a-f]{12}", e["id"]):
            continue
        out.append((e["id"], e["ts"]) + tuple(e.get(k) if isinstance(e.get(k), str) else ""
                                              for k in ("repo", "child", "state", "pr", "summary")))
    return out


rows = []

def ctx_of(w):
    """The measurement bus off a worker (issue #2431, columns 24-28 of the node's
    inventory): (ctx_left, ctx_band, ctx_ts, model, effort) as cache text, each
    validated; None when the node sent none (an older node: `fleet ls` says —)."""
    lf, bd, ts, md, ef = (w.get(k) for k in ("ctx_left", "ctx_band", "ctx_ts", "model", "effort"))
    out = (str(lf) if isinstance(lf, int) and not isinstance(lf, bool) and 0 <= lf <= 100 else "",
           bd if bd in ("ok", "watch", "handoff") else "",
           str(ts) if isinstance(ts, int) and not isinstance(ts, bool) and ts > 0 else "",
           md if isinstance(md, str) and re.fullmatch(r"[A-Za-z0-9 ._()+-]{1,64}", md) else "",
           ef if isinstance(ef, str) and re.fullmatch(r"[a-z]{1,16}", ef) else "")
    return out if any(out) else None

ASK_KIND = {"perm": "permission", "ask": "question", "auth": "auth"}

def tok_of(s):
    """The session's pool tokens today (issue #3377): the hub's tokens_today on
    its fleet_sessions row, as cache text — '' when none is recorded (the client
    then shows nothing, never 0) or from a hub older than it."""
    n = s.get("tokens_today")
    return str(n) if isinstance(n, int) and not isinstance(n, bool) and n > 0 else ""


def ask_of(w, state):
    """「在问你」带原话 (issue #2538): (kind, words) of a session that waits on
    you — the agent's own report (status_kind / status_msg, the node's column
    29), else its needs subtype and detail; None when it is not asking or said
    nothing. The words are kept to 200 characters, the current question only."""
    if state != "needs":
        return None
    k, m = w.get("status_kind"), w.get("status_msg")
    k = k if isinstance(k, str) and re.fullmatch(r"[A-Za-z0-9_.+-]{1,32}", k) else ASK_KIND.get(w.get("needs") or "", "")
    m = m if isinstance(m, str) and m.strip() else (w.get("detail") if isinstance(w.get("detail"), str) else "")
    m = re.sub(r"[\x00-\x1f\x7f]+", " ", m).strip()[:200]
    return (k, m) if k or m else None

OFF_WORD = "已停用（管理员限制）"   # the hub's MachineDisabledWord (issue #3824)

for s in sessions:
    w = s.get("worker") or {}
    wid = s.get("worker_id")
    if not wid or "/" not in wid:
        continue
    if user != "*" and s.get("os_user") != user:
        continue                                     # someone else's login
    here = None
    if is_local(s):
        # this machine (issue #1480): a row of ITS fleet's cache, marked local, with
        # the window that holds it now; the dash on the default source skips it
        here = local_fleet(s)
        if here is None:
            continue
    # a machine the person's allowlist leaves out (issue #3824, availability
    # "disabled"): never a row to enter — it dims as a lost one does, and its
    # title says why
    off = s.get("availability") == "disabled" and not here
    if off:
        w = dict(w, title=OFF_WORD, status_kind="", status_msg="", detail="")
    rows.append(dict(wid=wid, node=label(host) if here else label(s.get("machine_name")),
                     av="online" if here else ("lost" if s.get("availability") == "lost" or off else "online"),
                     issue=w.get("issue") or "", repo=w.get("repo") or "",
                     state=w.get("lifecycle") if w.get("lifecycle") not in (None, "", "awake") else (w.get("state") or ""),
                     agent=w.get("agent") or "", name=w.get("name") or w.get("key") or wid.split("/", 1)[1],
                     owid=by_ident.get(w.get("origin_wid") or "", w.get("origin_wid") or ""), needs=w.get("needs") or "", busy=w.get("busy") or "", born=born_of(w), cfg=w.get("cfg") if w.get("cfg") in ("stale", "renew", "ok") else "", title=w.get("title") if isinstance(w.get("title"), str) else "", detail=w.get("detail") if isinstance(w.get("detail"), str) else "", epic=w.get("epic") if isinstance(w.get("epic"), str) and re.fullmatch(r"(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#(?:[1-9][0-9]{0,9}|T[1-9][0-9]{0,9}|[A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z]{3,25})(?::[0-9]{1,4}/[0-9]{1,4})?", w.get("epic")) else "", reap=w.get("reap") if isinstance(w.get("reap"), str) and re.fullmatch(r"[A-Za-z0-9:.+-]{1,48}", w.get("reap")) else "", backfill="failed" if w.get("backfill") == "failed" else "", test=w.get("test") is True, ctx=ctx_of(w), ask=ask_of(w, w.get("lifecycle") if w.get("lifecycle") not in (None, "", "awake") else (w.get("state") or "")), stale=stale_of(w), orphans=orphans_of(w), notices=notices_of(w), seen=epoch(s.get("observed_at")), seenf=fepoch(s.get("observed_at")),
                     tok=tok_of(s), pin=w.get("pin") is True, local=here["sess"] if here else None,
                     lwid=windows.get((here["sess"], wid.split("/", 1)[1]), "") if here else ""))

# The other machines (issue #1475): the hub's `nodes` list when it has one
# (availability + its newest observation, every visible machine, sessions or
# not), else what the sessions say. Session counts are always THIS cache's rows
# — yours — never the hub's count of every login.
nodes = {}
for n in (data.get("nodes") or []) if isinstance(data.get("nodes"), list) else []:
    if not isinstance(n, dict) or not n.get("machine_name") or short(n.get("machine_name")) == me:
        continue
    lb = label(n.get("machine_name"))
    cur = nodes.setdefault(lb, dict(av="lost", n=0, seen=0))
    # null sessions: a fleet of yours there could not be read (#1465) — its rows
    # are missing, so the count is `?`, never the rows this cache happens to hold
    if "sessions" in n and n["sessions"] is None:
        cur["unk"] = True
    # heard beats lost; `maintenance` (#1427) is heard too — the operator's
    # flag over an online machine, never a third kind of silence
    if n.get("availability") in ("online", "maintenance") and cur["av"] == "lost":
        cur["av"] = n.get("availability")
    cur["seen"] = max(cur["seen"], epoch(n.get("observed_at")))
for r in rows:
    if r["local"] or (me and r["node"] == label(host)):
        continue                                     # this machine is `#me`, never a #node (another login's row here too, #3001)
    cur = nodes.setdefault(r["node"], dict(av="lost", n=0, seen=0))
    cur["n"] += 1
    if not data.get("nodes"):
        if r["av"] in ("online", "maintenance") and cur["av"] == "lost":
            cur["av"] = r["av"]
        cur["seen"] = max(cur["seen"], r["seen"])
head = ["#ts\x1f%s\n" % now, "#me\x1f%s\n" % clean(label(host))]
for lb in sorted(nodes):
    n = nodes[lb]
    head.append("\x1f".join(("#node", clean(lb), n["av"], "?" if n.get("unk") else str(n["n"]), str(n["seen"]), via)) + "\n")

# Which login each fleet runs under (issue #2430): one person may hold two logins
# on one machine, and a row opens over ssh AS ITS fleet's login. Every session's
# fleet_id + os_user goes into the client's fleet → login map (fleet_fleet_login
# in fleet-lib.sh owns the format: `<fleet UUID>\t<login>`, the last line wins),
# rewritten whole so it never grows past the fleets the hub shows.
def write_logins():
    mp = os.path.join(gdir, "fleet_logins")
    seen = {}
    try:
        for line in open(mp, encoding="utf-8"):
            u, _, lg = line.rstrip("\n").partition("\t")
            if u and lg:
                seen[u] = lg
    except OSError:
        pass
    new = dict(seen)
    for s in sessions:
        u, lg = s.get("fleet_id"), s.get("os_user")
        if isinstance(u, str) and isinstance(lg, str) and re.fullmatch(r"[0-9A-Za-z-]{1,64}", u) \
                and re.fullmatch(r"[a-z_][a-z0-9_.-]{0,31}", lg):
            new[u] = lg
    if new != seen:
        write(mp, "".join("%s\t%s\n" % kv for kv in sorted(new.items())))
write_logins()

by_issue = {(r["repo"], str(r["issue"])): r["wid"] for r in rows if r["issue"]}
parents = {}
def parent_of(repo, issue):
    if repo not in parents:
        parents[repo] = {}
        try:
            for line in open(os.path.join(cdir, "fleets", slug(repo), "parents"), encoding="utf-8"):
                c, _, p = line.rstrip("\n").partition("\t")
                if c and p:
                    parents[repo][c] = p
        except OSError:
            pass
    return parents[repo].get(str(issue))

for f in local:
    out = list(head)
    for r in rows:
        if r["local"] and r["local"] != f["sess"]:
            continue                                 # a local row: its own fleet's cache only
        origin = ""
        ou, _, ok = r["owid"].partition("/")
        if ok:
            origin = ok if f["uuid"] and ou == f["uuid"] else r["owid"]
        elif r["issue"] and r["repo"] in f["repos"]:
            p = parent_of(r["repo"], r["issue"])
            if p:
                # the parent's row, when the hub lists one: a parent in THIS fleet
                # (a local row since #1480) is its bare key, as a local @origin is
                pu, _, pk = (by_issue.get((r["repo"], p)) or "").partition("/")
                if pk:
                    origin = pk if f["uuid"] and pu == f["uuid"] else pu + "/" + pk
                else:
                    origin = slug(r["repo"]) + ":issue-" + p     # every key carries its repo (#1939, #1941)
        out.append("\x1f".join(clean(v) for v in ("wid:" + r["wid"], r["node"], r["av"], r["issue"], r["repo"],
                                               r["state"], r["agent"], r["name"], origin, r["needs"],
                                               "1" if r["local"] else "0", r["lwid"], via, r["busy"], r["born"], r["cfg"])
                                              # 17 title, 18 reap (#1902), 19 epic (#1958), 20 backfill
                                              # (#2235): each only when there is one, the empty ones
                                              # before it kept
                                              + ((r["title"],) if r["title"] or r["reap"] or r["epic"] or r["backfill"] or r["ctx"] or r["test"] or r["ask"] or r["tok"] or r["pin"] else ())
                                              + ((r["reap"],) if r["reap"] or r["epic"] or r["backfill"] or r["ctx"] or r["test"] or r["ask"] or r["tok"] or r["pin"] else ())
                                              + ((r["epic"],) if r["epic"] or r["backfill"] or r["ctx"] or r["test"] or r["ask"] or r["tok"] or r["pin"] else ())
                                              + ((r["backfill"],) if r["backfill"] or r["ctx"] or r["test"] or r["ask"] or r["tok"] or r["pin"] else ())
                                              # 21-25 (#2431): ctx_left · ctx_band · ctx_ts · model ·
                                              # effort — all five, only when the node measured any
                                              + (r["ctx"] or (("",) * 5 if r["test"] or r["ask"] or r["tok"] or r["pin"] else ()))
                                              # 26 (#2505): `1` on a test identity's session
                                              + (("1" if r["test"] else "",) if r["test"] or r["ask"] or r["tok"] or r["pin"] else ())
                                              # 27-28 (#2538): what a needs session asks — its
                                              # kind (permission · question · auth) and its words
                                              + (r["ask"] or (("", "") if r["tok"] or r["pin"] else ()))
                                              # 29 (#3377): the session's pool tokens today,
                                              # only when the hub recorded any
                                              + ((r["tok"],) if r["tok"] or r["pin"] else ())
                                              # 30 (#3517): `1` on a pinned session
                                              + (("1",) if r["pin"] else ())) + "\n")
    path = os.path.join(gdir, "remote_" + f["sess"])
    unk = {lb for lb, n in nodes.items() if n.get("unk")}
    if via == "hub" and unk:
        # A machine whose fleet the hub could not read this beat (`sessions`
        # null, #1465) is "could not read", never "no windows" (#1795): its
        # rows the answer lacks keep their last lines. A hub that blanked them
        # dropped every row of that machine for the seconds a node's read
        # timed out — the command panel collapsed to the one row it stood on.
        have = {r["wid"] for r in rows}
        try:
            for line in open(path, encoding="utf-8"):
                p = line.rstrip("\n").split("\x1f")
                if p[0].startswith("wid:") and len(p) >= 2 and p[1] in unk and p[0][4:] not in have:
                    out.append(line if line.endswith("\n") else line + "\n")
        except OSError:
            pass
    write(path, "".join(out))
    # The batches nobody drives (issue #1916): `epicstale_<sess>` beside the cache,
    # one line per (machine, EPIC) — `<owner/name>#<N> US <machine> US <online|lost>
    # US <age s> US <title> US <local 1|0>` — off any row of that machine (every
    # row carries its login's list). The command panel draws each as a grey 「#N 没人在跑」
    # row; THIS machine's (local 1) it reads off its own marks instead.
    seen_st, st_lines = set(), []
    for r in rows:
        if r["local"] and r["local"] != f["sess"]:
            continue
        for ref, age, title in r["stale"]:
            if (r["node"], ref) in seen_st:
                continue
            seen_st.add((r["node"], ref))
            st_lines.append("\x1f".join(clean(v) for v in (ref, r["node"], r["av"], age, title[:200],
                                                         "1" if r["local"] else "0")) + "\n")
    write(os.path.join(gdir, "epicstale_" + f["sess"]), "".join(st_lines))
    # The results nobody took (issue #3369): `orphanrep_<sess>`, one line per
    # (machine, report) — `<id> US <machine> US <online|lost> US <ts> US <repo> US
    # <child> US <state> US <pr> US <summary> US <local 1|0>` — off any row of that
    # machine (every row carries its login's list). The command panel draws each as a
    # 「结果给你」 row; THIS machine's (local 1) it reads off its own file instead.
    seen_or, or_lines = set(), []
    for r in rows:
        if r["local"] and r["local"] != f["sess"]:
            continue
        for rid, ts, orepo, child, state, pr, summ in r["orphans"]:
            if (r["node"], rid) in seen_or:
                continue
            seen_or.add((r["node"], rid))
            or_lines.append("\x1f".join(clean(v) for v in (rid, r["node"], r["av"], ts, orepo, child, state, pr,
                                                         summ[:300], "1" if r["local"] else "0")) + "\n")
    write(os.path.join(gdir, "orphanrep_" + f["sess"]), "".join(or_lines))
    # The messages not seen yet (T701): `notices_<sess>`, one line per (machine,
    # message) — `<id> US <machine> US <its read mark> US <ts> US <level> US <kind>
    # US <sub> US <wid> US <text> US <local 1|0>` — off any row of that machine.
    # bin/fleet_notice.py reads the other machines' (local 0) beside its own book,
    # and takes the latest read mark of all: another home sees the same messages.
    seen_nt, nt_lines = set(), []
    for r in rows:
        if r["local"] and r["local"] != f["sess"]:
            continue
        mark, nts = r.get("notices") or (0, [])
        for rid, ts, lvl, kind, sub, wid, text in nts:
            if (r["node"], rid) in seen_nt:
                continue
            seen_nt.add((r["node"], rid))
            nt_lines.append("\x1f".join(clean(v) for v in (rid, r["node"], mark, ts, lvl, kind, sub, wid, text[:200],
                                                         "1" if r["local"] else "0")) + "\n")
        if not nts and mark and (r["node"], "mark") not in seen_nt:
            # a machine with nothing unseen still says how far it has read
            seen_nt.add((r["node"], "mark"))
            nt_lines.append("\x1f".join(clean(v) for v in ("-", r["node"], mark, "", "", "", "", "", "",
                                                         "1" if r["local"] else "0")) + "\n")
    write(os.path.join(gdir, "notices_" + f["sess"]), "".join(nt_lines))
# A session needs you (issue #2759, EPIC #2756 C3), decided here on every round
# that brought rows (bin/fleet_notify.py is the one rule; it can never cost the
# cache above) — on a thin client's home (issue #3005, EPIC #2999 C8): every row
# of this machine's caches, told to the terminal of the 看台 here that holds the
# person's lease (fleet_thin_lease.py keeps it). Only once a thin 看台 has had a
# lease here — never one, no book, nothing.
notify_rows(rows)
write(str(memo_path), json.dumps(dict(key=key, outputs=output_digests(), rows=rows)))
PY
}

# The shared watcher predicate, qualified by an actual list read in the last 30s.
# An attached terminal/online lease is not itself an open list (#4357).
watched() {
  local sess _c sockpath
  NAP_SOCKS=()
  while IFS=$'\t' read -r sess _c; do
    [ -n "$sess" ] || continue
    sockpath=$(tmux -L "$sess" display-message -p '#{socket_path}' 2>/dev/null) || continue
    [ -z "$sockpath" ] || NAP_SOCKS+=("$sockpath")
  done <<EOF
$(local_fleets)
EOF
  python3 "$BIN/fleet-render-watch.py" --view-active "$G/hubsess.view" 1 ${NAP_SOCKS[@]+"${NAP_SOCKS[@]}"}
}

# --- The status bar's two summaries (issue #1482, EPIC #1479 C3) ---------------
# Written on the same round as the sessions, read by bin/fleet-status-lib.sh (the
# bar, C4's 入口 chip, C5's shell) — never fetched on a render path.
#   $G/hub_nodes   #ts<US><epoch>, then one line per machine the hub shows:
#     node<US>online|lost<US>load1<US>ncpu<US>mem_pct<US>sessions<US>fleet_version<US>age<US>mem_used_mb<US>mem_total_mb<US>ver_state<US>place<US>hostname
#     (sessions `?` when the hub could not read a fleet there — #1465; place is
#     `coord` / `maint` / '' — what the command panel's 「开在哪」 greys, issue #1778)
#     (/v1/nodes `machines`: one load per machine; fleet_version is its newest
#     login's; age is seconds since its last heartbeat when written; ver_state
#     is that version's word against the stable mark — issue #644, below)
#   $G/hub_repos   #ts<US><epoch>, then one owner/name per line: the repos those
#     machines' fleets host (`repos`, issue #1927) — the command panel's candidates
#     for a first session while its list has no repo heading; a person with no
#     active login yet gets a `#account<US>state<US>eta_s<US>machine<US>ask<US>epoch`
#     line after #ts (issue #2069: opening | failed | none)
#   $G/hub_limits  #ts<US><epoch>, then one line per subscription with a reading:
#     label<US>pct5h<US>pctweek<US>account_uuid<US>hub_label
#     (/v1/limits?account=all; `label` is this login's accounts/<label>.conf name
#     whose CCQUOTA_ACCOUNT is that uuid — a window's @cc_account — else the
#     hub's label; a subscription without a utilization, e.g. codex, is skipped)
# Identity follows #1475's ladder (seam, certificate, viewer token). A valid
# certificate asks the hub's certificate door, POST /v1/fleet/summary (#1502):
# ONE signed request whose body carries both `machines` and `per_account`,
# narrowed by the hub to this person's machines and subscriptions — so a
# colleague who only ran `fleet login` gets a machine cell and an account chip
# too. Only when the hub REFUSES it (401/403, or 404 on a hub not yet redeployed)
# does the round fall back to the two viewer routes with the token; a network
# failure is no answer, never a token spend. No identity means no fetch — then
# nothing is written and the bar shows `?` / no account chip; a failed fetch
# keeps the last file. Seams: FLEET_HUB_NODES_CMD / FLEET_HUB_LIMITS_CMD
# print the JSON; a run driven by FLEET_HUB_SESSIONS_CMD never goes to the network
# for these either (a selftest must not reach a real hub through hub.json).
SUMJ=''; SUMRC=''   # the certificate answer of THIS round (refresh_summaries resets both)
# fetch_summary_cert <url> → rc 0 with the body in $SUMJ; 4 = refused; 1 = no answer.
# Asked once per round: fetch_nodes and fetch_limits read the same body.
fetch_summary_cert() {
  local url="$1" ts sig cert body code
  if [ -n "$SUMRC" ]; then return "$SUMRC"; fi
  SUMRC=1
  ts=$(date +%s)
  sig=$(printf 'fleet-summary %s' "$ts" | ssh-keygen -Y sign -f "$CERT_KEY" -n "$SUMMARY_NS" 2>/dev/null) || return 1
  cert=$(head -n1 "$CERT_PUB" 2>/dev/null) || return 1
  body=$(python3 -c 'import json, sys; print(json.dumps({"cert": sys.argv[1], "sig": sys.argv[2], "ts": int(sys.argv[3])}))' \
         "$cert" "$sig" "$ts") || return 1
  SUMJ=$(mktemp "$G/hubsummary.json.XXXXXX") || return 1
  code=$(curl -sS -m 8 -o "$SUMJ" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
         --data-binary "$body" "$url/v1/fleet/summary" 2>/dev/null)
  case "$code" in
    200)         SUMRC=0 ;;
    401|403|404) SUMRC=4
                 printf 'fleet-hub-sessions: the hub refused the connection certificate %s for the summaries (HTTP %s) — trying the viewer token\n' "$CERT_PUB" "$code" >&2 ;;
  esac
  return "$SUMRC"
}
# fetch_summary_node <url> → as fetch_summary_cert, over this login's node token
# (issue #2630): a GET of the same door, narrowed by the hub to the token's owner.
fetch_summary_node() {
  local url="$1" code
  if [ -n "$SUMRC" ]; then return "$SUMRC"; fi
  SUMRC=1
  SUMJ=$(mktemp "$G/hubsummary.json.XXXXXX") || return 1
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$NTOK" |
         curl -K - -sS -m 8 -o "$SUMJ" -w '%{http_code}' "${NURL:-$url}/v1/fleet/summary" 2>/dev/null)
  case "$code" in
    200)         SUMRC=0 ;;
    401|403|404) SUMRC=4; date +%s > "$G/hubsess.nodetok.refused" 2>/dev/null ;;
  esac
  return "$SUMRC"
}
fetch_viewer() {   # fetch_viewer <path> → the JSON on stdout; rc 1 when no answer
  local url
  [ -z "${FLEET_HUB_SESSIONS_CMD:-}" ] || return 1
  url=$(hub_url) || return 1
  command -v curl >/dev/null 2>&1 || return 1
  if node_token; then
    fetch_summary_node "$url"
    case $? in
      0) cat "$SUMJ"; return 0 ;;
      4) rm -f "$SUMJ"; SUMJ=''; SUMRC='' ;;   # refused: the certificate / token, as before
      *) return 1 ;;
    esac
  fi
  case "$(cert_state)" in
    ok\ *)
      fetch_summary_cert "$url"
      case $? in
        0) cat "$SUMJ"; return 0 ;;
        4) ;;                       # refused: the token, if this login has one
        *) return 1 ;;
      esac ;;
  esac
  token_source >/dev/null || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$TOK" | curl -K - -fsS -m 8 "$url$1" 2>/dev/null
}
fetch_nodes() {
  if [ -n "${FLEET_HUB_NODES_CMD:-}" ]; then bash -c "$FLEET_HUB_NODES_CMD" </dev/null 2>/dev/null; return; fi
  fetch_viewer /v1/nodes
}
fetch_limits() {
  if [ -n "${FLEET_HUB_LIMITS_CMD:-}" ]; then bash -c "$FLEET_HUB_LIMITS_CMD" </dev/null 2>/dev/null; return; fi
  fetch_viewer '/v1/limits?account=all'
}
# Their own cadence (FLEET_HUB_SUMMARY_EVERY, 10s; 0 = every round): the loop
# asks fleet_sessions every 2s while someone is looking (#1481, a conditional GET),
# but these two are full answers — a stamp of the last attempt, hit or miss, holds
# them to the old pace.
SUMMARY_EVERY="${FLEET_HUB_SUMMARY_EVERY:-10}"; case "$SUMMARY_EVERY" in ''|*[!0-9]*) SUMMARY_EVERY=10 ;; esac
SUMF="$G/hubsum.ts"
refresh_summaries() {
  hub_on || return 0
  local nj lj now last=''
  mkdir -p "$G" 2>/dev/null || return 1
  now=$(date +%s)
  { read -r last < "$SUMF"; } 2>/dev/null || last=''    # braced: a missing file is silent (#1483 fix in passing)
  case "$last" in ''|*[!0-9]*) ;; *) [ $(( now - last )) -lt "$SUMMARY_EVERY" ] && return 0 ;; esac
  printf '%s\n' "$now" > "$SUMF"
  SUMJ=''; SUMRC=''
  nj=$(mktemp "$G/hubnodes.json.XXXXXX") || return 1
  if fetch_nodes >"$nj" && [ -s "$nj" ]; then
    python3 - "$nj" "$G/hub_nodes" "${FLEET_NODE_ALIASES:-}" "$now" "${FLEET_LIVE_DIR:-$HOME/.claude/fleet}" "$BIN" <<'PY' || printf 'fleet-hub-sessions: /v1/nodes did not answer a machine list — keeping the last hub_nodes\n' >&2
import json, os, re, subprocess, sys, tempfile
from datetime import datetime, timezone
jpath, out, aliases, now, live, bindir = sys.argv[1:7]
sys.path.insert(0, bindir)
import fleet_iso  # the one ISO reader (issue #2024)
now = int(now)
data = json.load(open(jpath, encoding="utf-8"))
machines = data.get("machines")
if not isinstance(machines, list):
    sys.exit(1)
alias = dict(a.split("=", 1) for a in aliases.split() if "=" in a)
short = lambda h: (h or "").split(".", 1)[0]
label = lambda h: alias.get(h) or alias.get(short(h)) or short(h) or "?"
clean = lambda v: re.sub(r"[\t\n\r\x1f]", " ", str(v if v is not None else ""))
def epoch(iso):
    return fleet_iso.epoch(iso, utc=True)
version = {}
for n in data.get("nodes") or []:
    if not isinstance(n, dict) or not n.get("hostname") or not n.get("fleet_version"):
        continue
    t = epoch(n.get("last_heartbeat"))
    if t >= version.get(n["hostname"], (0, ""))[0]:
        version[n["hostname"]] = (t, n["fleet_version"])
# /v1/fleet/summary (the node-token / certificate door) has no `nodes`: the
# machine itself carries its newest login's version there (issue #2692).
for m in machines:
    if isinstance(m, dict) and m.get("hostname") and m.get("fleet_version") and m["hostname"] not in version:
        version[m["hostname"]] = (epoch(m.get("last_heartbeat")), m["fleet_version"])
# 旧 (issue #644, EPIC #1524 R4): a machine's fleet_version is the short sha of
# its live install's HEAD (fleet-install-version.sh, carried on its node's
# heartbeat). It is judged HERE, once per round, against the stable mark this
# login's install-sync daemon keeps fetched as the live install's local
# refs/tags/stable (fleet-install-sync.sh) — local git only, never the network —
# so the bar and the doctor read one word, as builtins. The 11th field:
#   ok         at stable          old:<n>   n commits behind stable → the bar's 旧
#   ahead:<n>  n commits past it  off       not on stable's line (a branch)
#   ?          a version this checkout cannot resolve (never fetched here)
#   ''         no version reported, no live checkout, or no local stable tag:
#              UNKNOWN — drawn as nothing, never as current (the #635 rule)
def git(*args):
    try:
        r = subprocess.run(["git", "-C", live] + list(args), capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return r.returncode, r.stdout.strip()
stable = None
if live and os.path.isdir(live):
    rc, got = git("rev-parse", "-q", "--verify", "refs/tags/stable^{commit}")
    if rc == 0 and got:
        stable = got
memo = {}
def vstate(ver):
    if not ver or stable is None:
        return ""
    if ver not in memo:
        if not re.fullmatch(r"[0-9a-fA-F]{4,40}", ver):
            s = "?"
        else:
            rc, full = git("rev-parse", "-q", "--verify", ver + "^{commit}")
            if rc != 0 or not full:
                s = "?"
            elif full == stable:
                s = "ok"
            elif git("merge-base", "--is-ancestor", full, stable)[0] == 0:
                s = "old:" + (git("rev-list", "--count", full + ".." + stable)[1] or "?")
            elif git("merge-base", "--is-ancestor", stable, full)[0] == 0:
                s = "ahead:" + (git("rev-list", "--count", stable + ".." + full)[1] or "?")
            else:
                s = "off"
        memo[ver] = s
    return memo[ver]
lines = ["#ts\x1f%d\n" % now]
for m in machines:
    if not isinstance(m, dict) or not m.get("hostname"):
        continue
    h = m["hostname"]
    try:
        total = int(m.get("mem_total_bytes") or 0); free = int(m.get("mem_free_bytes") or 0)
        load1 = float(m.get("load1") or 0); ncpu = int(m.get("ncpu") or 0)
        # null = a fleet there could not be read (#1465): unknown, never 0
        sess = "?" if "sessions" in m and m["sessions"] is None else int(m.get("sessions") or 0)
    except (TypeError, ValueError):
        continue
    used = max(total - free, 0)
    hb = epoch(m.get("last_heartbeat"))
    ver = version.get(h, (0, ""))[1]
    # 12th: what may be placed there (issue #1778) — `coord` when every login
    # only coordinates (#1719), `maint` while flagged 维护中 (#1427), else '';
    # 13th: the hostname, which the hub resolves whatever this login calls it.
    word = "coord" if m.get("compute_off") else "maint" if m.get("status") == "maintenance" else ""
    lines.append("\x1f".join(clean(v) for v in (
        label(h), "online" if m.get("status") == "online" else "lost", "%.2f" % load1, ncpu,
        used * 100 // total if total else "", sess, ver,
        max(now - hb, 0) if hb else "", used // 1048576, total // 1048576, vstate(ver), word, h)) + "\n")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".hubnodes.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("".join(lines))
os.replace(tmp, out)
# hub_services (issue #2526): each machine's login-level register as the hub
# hands it to this person (`machines[].services`, their own logins only) and
# the open service_failed alerts a summary answer carries — one JSON for
# `fleet ls --services`, the doctor's services row and the alert bar. A
# machine with nothing registered is simply not listed.
svc = {"ts": now, "machines": [], "alerts": [a for a in (data.get("alerts") or [])
                                             if isinstance(a, dict) and a.get("kind") == "service_failed"]}
for m in machines:
    if isinstance(m, dict) and m.get("hostname") and isinstance(m.get("services"), list) and m["services"]:
        svc["machines"].append({"hostname": m["hostname"], "label": label(m["hostname"]),
                                "status": m.get("status") or "", "services_at": m.get("services_at"),
                                "services": [x for x in m["services"] if isinstance(x, dict)]})
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".hubservices.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(svc, f, ensure_ascii=False)
os.replace(tmp, os.path.join(os.path.dirname(out), "hub_services"))
# hub_repos (issue #1927): every repo a fleet on these machines hosts, the
# command panel's repo candidates while its list has no heading yet. A hub older
# than `repos` sends no key: then no file, and the command panel says what it did.
hub_repos = os.path.join(os.path.dirname(out), "hub_repos")
if machines and not any(isinstance(m, dict) and "repos" in m for m in machines):
    try:
        os.unlink(hub_repos)
    except OSError:
        pass
    sys.exit(0)
repos = sorted({r for m in machines if isinstance(m, dict) for r in (m.get("repos") or [])
                if isinstance(r, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", r)})
# #account (issue #2069): a person with no active login yet — the hub's
# `account` {state opening|failed|none, eta_s, machine, ask}. The command panel
# reads it beside an empty repo list: 正在为你开机器 / 该找谁. No key (a login
# they already hold, or an older hub) = no line.
acct = data.get("account") if isinstance(data.get("account"), dict) else None
aline = ""
if acct and acct.get("state") in ("opening", "failed", "none"):
    eta = acct.get("eta_s")
    aline = "#account\x1f" + "\x1f".join(clean(v) for v in (
        acct["state"], eta if isinstance(eta, int) else "", acct.get("machine") or "",
        acct.get("ask") or "", now)) + "\n"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".hubrepos.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("#ts\x1f%d\n" % now + aline + "".join(r + "\n" for r in repos))
os.replace(tmp, hub_repos)
PY
  fi
  rm -f "$nj"
  lj=$(mktemp "$G/hublimits.json.XXXXXX") || return 1
  if fetch_limits >"$lj" && [ -s "$lj" ]; then
    python3 - "$lj" "$G/hub_limits" "${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}" "$now" <<'PY' || printf 'fleet-hub-sessions: /v1/limits did not answer a per_account list — keeping the last hub_limits\n' >&2
import glob, json, os, re, sys, tempfile
jpath, out, accdir, now = sys.argv[1:5]
data = json.load(open(jpath, encoding="utf-8"))
per = data.get("per_account")
if not isinstance(per, list):
    sys.exit(1)
clean = lambda v: re.sub(r"[\t\n\r\x1f]", " ", str(v if v is not None else ""))
local = {}   # account uuid → this login's label (accounts/<label>.conf, CCQUOTA_ACCOUNT=…)
for conf in sorted(glob.glob(os.path.join(accdir, "*.conf"))):
    try:
        for line in open(conf, encoding="utf-8"):
            m = re.match(r'\s*(?:export\s+)?CCQUOTA_ACCOUNT=["\']?([^"\'\s#]+)', line)
            if m:
                local[m.group(1)] = os.path.basename(conf)[:-5]
    except OSError:
        pass
def pct(w):
    try:
        return "" if w is None or w.get("utilization") is None else str(int(float(w["utilization"]) + 0.5))
    except (TypeError, ValueError, AttributeError):
        return ""
lines = ["#ts\x1f%d\n" % int(now)]
for a in per:
    if not isinstance(a, dict):
        continue
    lim = a.get("limits") or {}
    if not isinstance(lim, dict) or not lim.get("available"):
        continue
    p5, pw = pct(lim.get("five_hour")), pct(lim.get("seven_day"))
    if p5 == "" and pw == "":
        continue
    uuid = a.get("account_uuid") or ""
    lines.append("\x1f".join(clean(v) for v in (local.get(uuid) or a.get("label") or uuid, p5, pw, uuid, a.get("label") or "")) + "\n")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".hublimits.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("".join(lines))
os.replace(tmp, out)
PY
  fi
  rm -f "$lj"
  [ -z "$SUMJ" ] || rm -f "$SUMJ"
  return 0
}
# One round: the sessions (its rc), then the two summaries.
refresh_all() { local rc; refresh; rc=$?; refresh_summaries; return "$rc"; }

loop() {
  hub_on || return 0
  mkdir -p "$G" 2>/dev/null || return 1
  local end every t0 want view left first=1 nowt ms0 rcw wseen
  # ONE loop per cache, by a lock its holder keeps for life (issue #2630): the
  # pid file alone let two shells' --ensure race past each other (two loops on
  # one cache for hours). Not holding it yet ⇒ re-exec under the lock; someone
  # else holds it ⇒ exit 0.
  local guard="${FLEET_HUBSESS_GUARD:-}"
  if [ -z "${FLEET_HUBSESS_LOCKED:-}" ]; then
    exec python3 -c "$LOCK_PY" "$LOCKF" 0 bash "$BIN/fleet-hub-sessions.sh" --loop
  fi
  unset FLEET_HUBSESS_LOCKED FLEET_HUBSESS_GUARD
  INV_ON=1
  printf '%s\n' "$$" > "$PIDF"
  EXIT_WHY=''; LOOP_T0=$(date +%s)
  trap 'loop_cleanup' EXIT
  trap 'loop_term' TERM INT
  hlog "start life=${LOOP_SECS}s code=${MAPCODE%%-*}"
  printf '%s\n' "$MAPCODE" > "$LOOPCODEF.new" 2>/dev/null && mv -f "$LOOPCODEF.new" "$LOOPCODEF"
  # a round SIGKILLed mid-write (a --refresh cut at its timeout, a killed loop)
  # leaves its mktemp files behind — no trap runs (task EQBE): one sweep per loop
  # life of the ones older than an hour; the live names (hubsess.map.json, …)
  # never match the six-letter suffix
  find "$G" -maxdepth 1 -type f \( -name 'hubsess.hdr.??????' -o -name 'hubsess.json.??????' \
       -o -name 'hubsess.local.??????' -o -name 'hubsess.map.??????' -o -name 'hub*.json.??????' \
       -o -name '.hubsess.??????' -o -name 'hub_ok.new.*' -o -name 'hub_why.new.*' \
       -o -name 'hubsess.etag.new.*' \) -mmin +60 -delete 2>/dev/null || :
  end=$(( $(date +%s) + LOOP_SECS ))
  while :; do
    # the lock's holder is gone (SIGKILLed): the lock went with it — stop
    if [ -n "$guard" ] && ! kill -0 "$guard" 2>/dev/null; then EXIT_WHY='guard gone'; break; fi
    # --ensure extends our life, and so does a viewer reading the list (the
    # 3-minute freeze: the collector's ticks overran, no --ensure came for longer
    # than LOOP_SECS, and the loop ended under a ⌘P read 2 s before). A long
    # fallback must be cut at the lifetime boundary, not make the loop exit a
    # whole minute before that boundary. Bounded: a view stamp older than
    # LOOP_SECS extends nothing, nor does one in the future.
    { read -r want < "$WANTF"; } 2>/dev/null || want=0
    case "$want" in ''|*[!0-9]*) want=0 ;; esac
    nowt=$(date +%s)
    view=$(mtime_of "$VIEWF"); case "$view" in ''|*[!0-9]*) view=0 ;; esac
    [ "$view" -le $(( nowt + 1 )) ] || view=0   # a future stamp would live for ever
    [ "$view" -le "$want" ] || want=$view
    [ $(( want + LOOP_SECS )) -gt "$end" ] && end=$(( want + LOOP_SECS ))
    [ "$first" = 1 ] || [ "$nowt" -lt "$end" ] || { EXIT_WHY=lifetime; break; }
    first=0
    every=$EVERY; WAIT=''; wseen=no
    if watched; then
      every=$WATCHED_EVERY; wseen=yes
      [ "${FLEET_HUB_SESSIONS_LONGPOLL:-1}" = 0 ] || WAIT=$LP_WAIT
    else
      every=$IDLE_EVERY
    fi
    : > "$G/hubsess.round.start"
    t0=$(date +%s); LP_SENT=0; LAST_FETCH=1
    ms_now; ms0=$MS
    refresh_all 2>/dev/null; rcw=$?
    ms_now; ROUNDS_N=$(( ROUNDS_N + 1 ))
    if [ "$rcw" != 0 ]; then rcw=fail; elif [ "$LAST_FETCH" = 3 ]; then rcw=304; else rcw=200; fi
    hlog "round rc=$rcw ms=$(( MS - ms0 )) watched=$wseen"
    # The node's nudge and the hub's publication are asynchronous. One bounded
    # follow-up after a local event catches a heartbeat racing the first fetch;
    # it does not keep an unseen list on a timer thereafter.
    if [ "$FOLLOWUP" = 1 ]; then every=1; FOLLOWUP=0; fi
    # A thin client's 看台 here (issue #3005): its lease is this machine's to keep.
    thin_lease_beat
    # A long-polled answer paces itself (issue #1526): a 200 (a change) or a
    # 304 the hub held is asked again at once; an immediate 304 or a failure —
    # an older hub that ignores `wait`, or none — keeps the 2 s cadence.
    if [ "$LP_SENT" = 1 ] && { [ "$LAST_FETCH" = 0 ] || [ $(( $(date +%s) - t0 )) -ge "$WATCHED_EVERY" ]; }; then
      every=0
    fi
    left=$(( end - $(date +%s) ))
    [ "$left" -gt 0 ] || { EXIT_WHY=lifetime; break; }
    [ "$every" -le "$left" ] || every=$left
    [ "$every" = 0 ] || idle_nap "$every"
  done
  return 0
}

# loop_term — TERM / INT: an --ensure of other code says so first (REPLF holds our
# pid), anything else is a plain TERM. The EXIT trap writes the line.
loop_term() {
  local p=''
  { read -r p < "$REPLF"; } 2>/dev/null || p=''
  if [ "$p" = "$$" ]; then EXIT_WHY='replaced by other code'; rm -f "$REPLF"; else EXIT_WHY=term; fi
  exit 0
}

loop_cleanup() {
  local p wt vw nowt
  nowt=$(date +%s)
  { read -r wt < "$WANTF"; } 2>/dev/null || wt=''
  case "$wt" in ''|*[!0-9]*) wt=never ;; *) wt="$(( nowt - wt ))s" ;; esac
  vw=$(mtime_of "$VIEWF"); case "$vw" in ''|*[!0-9]*|0) vw=never ;; *) vw="$(( nowt - vw ))s" ;; esac
  hlog "exit reason=${EXIT_WHY:-lifetime} up=$(( nowt - ${LOOP_T0:-$nowt} ))s rounds=${ROUNDS_N:-0} want_age=$wt view_age=$vw"
  if [ -n "$NAP_PID" ]; then
    kill "$NAP_PID" 2>/dev/null || :
    wait "$NAP_PID" 2>/dev/null || :
  fi
  rm -f "$G/hubsess.wake.$$"
  { read -r p < "$PIDF"; } 2>/dev/null && [ "$p" = "$$" ] && rm -f "$PIDF"
  return 0
}

# Wait on the same broadcast as the spinner. No two-second socket polling.
# Thin-client lease renewal is maintenance (15s), independent of row refresh;
# servicing it must not turn an online lease back into an open list.
idle_nap() {
  local until=$(( SECONDS + $1 )) left cap reason
  while [ "$SECONDS" -lt "$until" ]; do
    left=$(( until - SECONDS )); cap=$left
    if [ -f "$FLEET_CONF_DIR/thin-lease.json" ] && [ "$cap" -gt 15 ]; then cap=15; fi
    python3 "$BIN/fleet-render-watch.py" --events-only --max-frames "$cap" \
      --since "$G/hubsess.round.start" --changed "$G/hubsess.view" \
      --changed "$FLEET_CONF_DIR/global/hub-nudge" 1 ${NAP_SOCKS[@]+"${NAP_SOCKS[@]}"} > "$G/hubsess.wake.$$" &
    NAP_PID=$!
    wait "$NAP_PID"; NAP_PID=''
    read -r reason < "$G/hubsess.wake.$$" || reason=timeout
    case "$reason" in event|changed) FOLLOWUP=1; return 0 ;; esac
    [ "$cap" = "$left" ] || thin_lease_beat
  done
}

# thin_lease_beat — the person's client lease for each thin 看台 with a client
# attached here (fleet_thin_lease.py beat, issue #3005, EPIC #2999 C8): a node
# only, and only while a thin row is registered or its book is still open.
thin_lease_beat() {
  [ -f "$FLEET_CONF_DIR/thin-lease.json" ] \
    || awk -F '\t' '$3 == "thin" { f = 1; exit } END { exit !f }' "$FLEET_CONF_DIR"/remote-views/* 2>/dev/null \
    || return 0
  FLEET_CONF_DIR="$FLEET_CONF_DIR" python3 "$BIN/fleet_thin_lease.py" beat >/dev/null 2>&1 || :
}

# The lock (issue #2630): $G/hubsess.lock, an flock held by a small python
# parent (LOCK_PY) for exactly as long as the loop it runs: it takes the lock or
# exits 0 (another loop has it), starts the loop as its child — in a process
# group of the loop's own, the lock's descriptor NOT inherited, so a curl or a
# sleep the loop leaves behind can never keep it — writes the loop's pid in it,
# forwards TERM/INT, and exits with it. A SIGKILLed loop frees the lock at once;
# a SIGKILLed parent is noticed by the loop at its next round (FLEET_HUBSESS_GUARD).
# With 1 as its 2nd argument it first leaves the caller's session (setsid) and
# ignores SIGHUP — what `nohup` was for, minus nohup: macOS's nohup detaches from
# the console through launchd and exits when it cannot, which is EVERY time under
# a LaunchDaemon, so the collector's --ensure never started a loop (`loop none`
# for 5 hours). A lock file it cannot open is no reason to stay dark: the loop
# runs unlocked.
LOCKF="$G/hubsess.lock"
LOCK_PY='import fcntl, os, signal, subprocess, sys
lock, detach, argv = sys.argv[1], sys.argv[2] == "1", sys.argv[3:]
if detach:
    try:
        os.setsid()
    except OSError:
        pass
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
try:
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o644)
except OSError:
    fd = -1
if fd >= 0:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)
os.environ["FLEET_HUBSESS_LOCKED"] = "1"
os.environ["FLEET_HUBSESS_GUARD"] = str(os.getpid())
child = subprocess.Popen(argv, preexec_fn=os.setpgrp)
if fd >= 0:
    os.ftruncate(fd, 0)
    os.write(fd, ("%d\n" % child.pid).encode())
def forward(sig, _frame):
    try:
        child.send_signal(sig)
    except OSError:
        pass
for sig in (signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, forward)
rc = child.wait()
sys.exit(rc if rc >= 0 else 128 - rc)'

# lock_holder → the pid holding $LOCKF on stdout, nothing when it is free (or
# there is no lock file). The test lock is dropped at once.
lock_holder() {
  [ -f "$LOCKF" ] || return 0
  python3 -c 'import fcntl, os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY)
except OSError:
    sys.exit(0)
try:
    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
except OSError:
    print((os.read(fd, 32).decode(errors="replace").split() or [""])[0])
' "$LOCKF" 2>/dev/null
}

# loop_pid → the live loop's pid on stdout, nothing when none: the lock's holder
# (issue #2630), else — a loop of a version before the lock — the pid file. A pid
# alone is not proof (issue #1596): a recycled pid answers `kill -0`, and then no
# tick would ever start the loop again — so the pid must still BE a --loop of ours.
loop_pid() {
  local p cmd
  p=$(lock_holder)
  [ -n "$p" ] || { read -r p < "$PIDF"; } 2>/dev/null || return 0
  case "$p" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$p" 2>/dev/null || return 0
  cmd=$(ps -o command= -p "$p" 2>/dev/null) || return 0
  case "$cmd" in *fleet-hub-sessions.sh*--loop*) printf '%s\n' "$p" ;; esac
}

# The loop runs in a SESSION OF ITS OWN (issue #1596). The collector calling
# --ensure is a launchd job, and when a job's tick exits launchd kills every
# process left in its process group (no AbandonProcessGroup) — the `nohup … &`
# loop died ~1 s after each start, so with no client attached to start it from
# the command panel, remote_<sess> stopped for 10 hours. setsid(2) takes it out of
# that group; systemd's collect unit says KillMode=process for the same reason.
ensure() {
  hub_on || return 0
  mkdir -p "$G" 2>/dev/null || return 0
  date +%s > "$WANTF" 2>/dev/null
  local p code=''
  p=$(loop_pid)
  if [ -n "$p" ]; then
    # a loop of other code — an older version still running after a switch, or
    # one from before this stamp (no file) — gives way to this one (issue #3164)
    { read -r code < "$LOOPCODEF"; } 2>/dev/null || code=''
    [ "$code" = "$MAPCODE" ] && return 0
    printf '%s\n' "$p" > "$REPLF" 2>/dev/null
    hlog "ensure: loop $p runs other code — replacing it"
    kill -TERM "$p" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -n "$(loop_pid)" ] || break
      sleep 0.2
    done
    [ -z "$(loop_pid)" ] || return 0
  fi
  # one line per loop it starts (never per call: the collector and every stale
  # ⌘P call this) — the gap between two such lines is how long no loop ran
  hlog "ensure: no loop — starting one (by ${FLEET_HUBSESS_BY:-?})"
  ( cd / && exec python3 -c "$LOCK_PY" "$LOCKF" 1 bash "$BIN/fleet-hub-sessions.sh" --loop </dev/null >/dev/null 2>&1 & )
  return 0
}

# --status → one line for fleet-doctor: `loop <pid>|none · cache <age>s|none`,
# where cache = the age of hub_ok (the last round that stood). rc 0 = a loop is
# alive and the cache is younger than FLEET_HUB_SESSIONS_STATUS_STALE (60s);
# rc 1 otherwise. No network.
status() {
  hub_on || { printf 'off\n'; return 0; }
  local p ts age='' stale="${FLEET_HUB_SESSIONS_STATUS_STALE:-60}" rc=0
  case "$stale" in ''|*[!0-9]*) stale=60 ;; esac
  p=$(loop_pid)
  { read -r ts < "$G/hub_ok"; } 2>/dev/null || ts=''
  case "$ts" in ''|*[!0-9]*) ts='' ;; *) age="$(( $(date +%s) - ts ))s" ;; esac
  [ -n "$p" ] || rc=1
  { [ -n "$age" ] && [ "${age%s}" -le "$stale" ]; } || rc=1
  printf 'loop %s · cache %s\n' "${p:-none}" "${age:-none}"
  return "$rc"
}

cert_paths   # CERT_KEY / CERT_PUB for every mode (cert_state runs in a subshell)
case "${1:-}" in
  --refresh)  refresh_all ;;
  --loop)     loop ;;
  --ensure)   ensure ;;
  --status)   status ;;
  --identity) identity ;;
  *) printf 'usage: fleet-hub-sessions.sh --refresh | --loop | --ensure | --status | --identity\n' >&2; exit 2 ;;
esac
