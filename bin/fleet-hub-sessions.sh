#!/bin/bash
# fleet-hub-sessions.sh — the sidebar's view of YOUR sessions on the other machines
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
#   --loop      --refresh every FLEET_HUB_SESSIONS_WATCHED_EVERY (2s) while a client
#               is attached to any fleet session on this machine — someone is
#               looking — else every FLEET_HUB_SESSIONS_EVERY (10s), for
#               FLEET_HUB_SESSIONS_LOOP_SECS (70s), then exit. One at a time (pid
#               file). The 2 s is half of the 「3 秒内看到」 budget (issue #1481);
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
#               off; nobody looking, it is never sent (the 10 s cadence as before).
#   --ensure    start a detached --loop unless one is alive (one per cache: the
#               loop holds global/hubsess.lock — issue #2630; never via nohup). The collector runs this
#               every tick (60s), so the 10s cadence needs no daemon of its own and a
#               loop can never outlive the collector by more than one round. The loop
#               gets its own session (setsid), or launchd kills it with the tick
#               (issue #1596) and the cache stops whenever no sidebar is drawing.
#   --status    `loop <pid>|none · cache <age>s|none` for fleet-doctor; rc 1 = no
#               loop or a cache older than FLEET_HUB_SESSIONS_STATUS_STALE (60s).
#   --identity  WHO this login asks the hub as (issue #1475), one line, no network:
#               `cert <cert path> <valid until>` / `token <where it came from>` /
#               `none <why>` — exit 0 for the first two, 1 for none. fleet-doctor
#               reads it; so does a person wondering why the sidebar shows no m4.
#
# OFF unless CCQUOTA_FLEET=1: every mode is then a silent no-op that writes nothing,
# and the dash never looks for the cache — a one-machine fleet is byte for byte
# what it was (CLAUDE.md «Degenerate case is sacred»).
#
# CLIENT MODE (issue #1484, EPIC #1479 C5 — the shell on a person's own computer):
# FLEET_HUB_SESSIONS_CLIENT=<name> makes this loop serve ONE pseudo-fleet named
# <name> that has no conf, no control database and no windows of its own: the
# fleet list is that one name, every session the hub shows is another machine's
# (`local`=0 — this computer is a node at most by coincidence, and the shell
# reaches even its own sessions through a nested attach, #1485), `#me` is empty,
# the C1 locator cache is not written, and `watched` asks the shell's own tmux
# server (`-L <name>`). The rows, the header lines, hub_ok, hub_nodes and
# hub_limits are written exactly as for a fleet, under the $TMPDIR the shell
# gives it — so tmux-dashboard-rows.sh, fleet-status-lib.sh and tmux-status.sh
# read them unchanged. Unset (every node, every fleet) nothing here differs.
#
# Who asks (issue #1475), in this order — the first that exists is used:
#   1. FLEET_HUB_SESSIONS_CMD: a seam; it prints the fleet_sessions JSON itself.
#   1b. on a NODE (not the shell), this login's node token — node.env's
#      CCQUOTA_TOKEN, as a bearer on curl's stdin config, never its argv (issue
#      #2630): the hub reads it as the login's owner, the scope a certificate
#      gets, and it never expires — the collector's loop no longer goes dark when
#      a certificate lapses or no viewer token exists. A hub older than that door
#      answers 401: noted for FLEET_HUB_SESSIONS_NODE_REFUSED_TTL (600s) and the
#      round falls through to 2. FLEET_HUB_SESSIONS_NODE_TOKEN=0 skips it.
#   2. YOUR connection certificate — ~/.ssh/fleet-cert + fleet-cert-cert.pub, the
#      pair `fleet login` wrote (FLEET_CERT names another key), while it is valid:
#      a POST {cert, sig, ts} with `ssh-keygen -Y sign -n fleet-sessions@claude-fleet`
#      over "fleet-sessions <ts>", the protocol of #1414's /v1/fleet/routes. The hub
#      answers with exactly the machines your ACTIVE accounts are on — no token, so
#      a colleague's sidebar fills in right after `fleet login`. A certificate the
#      hub refuses (401: revoked, a clock too far off) falls through to 3.
#   3. the viewer token — CCQUOTA_VIEWER_TOKEN, else ~/.ccquota/viewer-token (the
#      operator's; it sees every login on every machine).
#   4. neither: nothing is fetched, one stderr note, no remote row anywhere, and
#      fleet-doctor's `hub` line WARNs.
# The hub's URL: CCQUOTA_HUB_URL, else FLEET_HUB_URL, else the `url` in
# ~/.config/claude-fleet/hub.json (what `fleet login` remembered).
#
# Which rows: every session whose login is yours (os_user = `id -un`, or
# FLEET_HUB_SESSIONS_USER; `*` = every login the hub shows you — what the shell
# takes when the hub answered over your certificate, already cut to your logins,
# issue #2388) and that has a
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
# (`macmini=m5 mini2=m4`).
#
# Cache (US-separated — \x1f, as the dash's own WFMT: a TAB is IFS whitespace,
# so `read` would collapse the empty fields). Header lines first:
#   #ts<US><epoch>                                when this cache was written
#   #me<US><label>                                this machine's label (#1475)
#   #node<US><label><US>online|lost<US><n><US><last-seen epoch><US>via   one per OTHER
#       machine the hub shows you (#1475): the sidebar's status line — n is your
#       sessions there, last-seen the hub's newest observation of it. From the
#       hub's `nodes` list; derived from the sessions on a hub older than #1475.
# then one row per session:
#   wid:<worker_id>  node  online|lost  issue  repo  state  agent  name  origin  needs  local  wid  via  busy  born  cfg  [title]
#   [reap epic backfill]  [ctx_left ctx_band ctx_ts model effort]  [test]
# Fields 21-25 (issue #2431) are the session's measurement bus (the node's
# inventory columns 24-28): % of the context LEFT, its band, the reading's epoch,
# the model and its effort — `fleet ls` prints them; all five or none (a node
# older than it sends none), so a `read` naming `backfill` last must name one more.
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
# answer — or `node` — the machine itself, over the shell's direct connection
# while the hub is silent (below). A reader that dims rows for the hub's silence
# spares a `node` line: that machine answered. `busy` (#1607, rows only) is the
# node's word for a window whose turn is over but whose work is not — `looping`
# (a /loop round still held) or `bg` (a Bash-tool job still running) — empty
# otherwise; fleet-epic-backstop.sh reads it so a member mid-acceptance on
# another machine is never merged under it. A `read` naming `via` last must name
# one more. `born` (#1750, rows only) is the session's birth, epoch seconds (the
# node's @born, else window_created; empty from a node older than it) — the order
# tmux-dashboard-rows.sh draws every machine's rows in. A `read` naming `busy`
# last must name it too. `cfg` (#1783, rows only) is `stale` / `renew` (#1895) / `ok` — the session's
# configuration against the one a fresh session gets on ITS machine now, judged
# there (fleet-control-read.sh); empty when unknown or from an older node. A
# `read` naming `born` last must name it too. `title` (#1921, rows only) is the
# session's issue title off its node's own issue cache (fleet-control-read.sh) —
# what a sidebar row and a session's top bar (#1904) show instead of the window
# name's slug. APPENDED only when there is one, so a row without (a scratch, an
# older node) is byte for byte what it was; a `read` naming `cfg` last must name
# it too.
#
# THE HUB SILENT, IN THE SHELL (issue #1488, EPIC #1479 R3) — client mode only.
# The shell has no fleet of its own, so when the hub goes quiet its list has
# nothing to fall back on but the cache (#1483). It does hold connections, though:
# every proxy window's pane is a ControlMaster ssh into a machine (`@remote_ctl`,
# fleet-remote-view.sh `run`). Once hub_ok is older than FLEET_HUB_SESSIONS_STALE
# (the rows read 失联), each round that the hub fails asks every machine whose
# connection answers `-O check` for its own sessions over it —
# `fleet-remote-view.sh sessions`, the hub's fleet_sessions shape — merges the
# answers into one document and feeds it through the SAME mapping as the hub's
# (map_write), marked via=node; the machines that did not answer keep their last
# lines, via=hub, so they read 失联 as before. hub_ok is NOT touched — the hub IS
# silent and the bar keeps saying so — and the ETag is dropped, so the hub's next
# answer is a full body that takes the cache back; nothing to switch. A node (no
# FLEET_HUB_SESSIONS_CLIENT) never does this: its own rows come from its own tmux
# (#1483) and it holds no connection to anyone. FLEET_HUB_NODE_TIMEOUT (8s) bounds
# each ask.
#
# NO HUB AT ALL, IN THE SHELL (issue #1712, EPIC #1710 C2) — client mode only.
# A computer with no hub address still opens the same client (fleet-shell.sh
# sets FLEET_HUB_SESSIONS_LOCAL=1 when no address is configured anywhere): every
# round asks THIS machine for its sessions — `fleet-remote-view.sh sessions`, the
# very answer a machine gives over the shell's connection above, run here from
# the node's own bin/ (FLEET_REMOTE_BIN, relative to $HOME as on any machine) —
# and feeds it through the same mapping, via=node: the machine answered for
# itself, so no row reads 失联 for a hub that does not exist. Nothing goes on
# the network, the summaries (hub_nodes / hub_limits) are not asked for, and
# hub_ok records the last round that stood (--status reads it). Unset, or with a
# hub address, nothing here differs.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

G="$FLEET_C/global"
EVERY="${FLEET_HUB_SESSIONS_EVERY:-10}"; case "$EVERY" in ''|*[!0-9]*|0) EVERY=10 ;; esac
WATCHED_EVERY="${FLEET_HUB_SESSIONS_WATCHED_EVERY:-2}"; case "$WATCHED_EVERY" in ''|*[!0-9]*|0) WATCHED_EVERY=2 ;; esac
ETAGF="$G/hubsess.etag"      # the validator of the cache on disk (issue #1481)
# …and what MAPPED that cache (issue #2397): the ETag vouches for the hub's answer,
# not for the rows this code kept of it. Its second line is this stamp — the code
# that maps (by content, as it loaded), the rows-user knob, client or node — and a
# validator under any other stamp is never sent: cj's client, updated to the code
# that keeps his node login's rows (#2390), kept asking with the ETag the old code
# had stored beside an empty cache, and every 304 kept the list empty.
MAPCODE=$(cat "$BIN/fleet-hub-sessions.sh" "$BIN/fleet-lib.sh" 2>/dev/null | cksum | awk '{ print $1 "-" $2 }')
ETAG_STAMP=''  # this round's stamp (fetch sets it; curl_sessions writes it)
LOOP_SECS="${FLEET_HUB_SESSIONS_LOOP_SECS:-70}"; case "$LOOP_SECS" in ''|*[!0-9]*) LOOP_SECS=70 ;; esac
LP_WAIT="${FLEET_HUB_SESSIONS_WAIT:-25}"; case "$LP_WAIT" in ''|*[!0-9]*|0) LP_WAIT=25 ;; esac
[ "$LP_WAIT" -le 25 ] || LP_WAIT=25
WAIT=''      # the long poll's wait for THIS round (issue #1526); set by loop only
LP_SENT=0    # 1 = this round's ask carried a validator AND a wait
LAST_FETCH=1 # this round's fetch rc (0 = 200, 3 = 304)
SCOPED=0     # 1 = this round's answer came over YOUR certificate (issue #2388)
PIDF="$G/hubsess.pid"
SESSIONS_NS='fleet-sessions@claude-fleet'
SUMMARY_NS='fleet-summary@claude-fleet'   # the status bar's two summaries (#1502)

# The fleets this loop serves: the shell's one pseudo-fleet in client mode
# (issue #1484), else every fleet configured on this machine whose hub switch is
# on (issue #1539: per fleet — a fleet conf's own CCQUOTA_FLEET line wins over the
# environment, so one fleet can stay local beside a hub one; no such line
# anywhere ⇒ the environment decides for all, as before).
CLIENT="${FLEET_HUB_SESSIONS_CLIENT:-}"
case "$CLIENT" in *[!A-Za-z0-9._-]*) CLIENT='' ;; esac
LOCAL=0      # the shell with no hub at all (#1712): this machine answers for itself
[ -n "$CLIENT" ] && [ "${FLEET_HUB_SESSIONS_LOCAL:-0}" = 1 ] && LOCAL=1
hub_on() { if [ -n "$CLIENT" ]; then [ "${CCQUOTA_FLEET:-0}" = 1 ]; else fleet_hub_any; fi; }
local_fleets() {
  if [ -n "$CLIENT" ]; then printf '%s\t-\n' "$CLIENT"; return; fi
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

# node_token → rc 0 with this login's node token in $NTOK (issue #2630): node mode
# only (the shell is a person's computer, never a node), node.env readable here
# (a separated login's broker credential is not an endpoint token), and not
# refused by this hub within NODE_REFUSED_TTL. It never enters the environment.
NTOK=''; AUTH_TOK=''
NODE_REFUSED_TTL="${FLEET_HUB_SESSIONS_NODE_REFUSED_TTL:-600}"
case "$NODE_REFUSED_TTL" in ''|*[!0-9]*) NODE_REFUSED_TTL=600 ;; esac
node_token() {
  local t
  NTOK=''
  [ -z "$CLIENT" ] && [ "${FLEET_HUB_SESSIONS_NODE_TOKEN:-1}" != 0 ] || return 1
  [ -r "$(fleet_node_env_file)" ] || return 1
  { read -r t < "$G/hubsess.nodetok.refused"; } 2>/dev/null || t=''
  case "$t" in ''|*[!0-9]*) ;; *) [ $(( $(date +%s) - t )) -ge "$NODE_REFUSED_TTL" ] || return 1 ;; esac
  NTOK=$(_fleet_node_env_val CCQUOTA_TOKEN 2>/dev/null)
  [ -n "$NTOK" ]
}

# identity → one line: cert … / token … / none …; rc 0 / 0 / 1.
identity() {
  local st src
  if [ -n "${FLEET_HUB_SESSIONS_CMD:-}" ]; then printf 'cmd FLEET_HUB_SESSIONS_CMD\n'; return 0; fi
  if node_token; then printf 'node %s\n' "$(fleet_node_env_file)"; return 0; fi
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
         if [ -n "$etag" ]; then printf '%s\n%s\n' "$etag" "$ETAG_STAMP" > "$ETAGF.new" && mv -f "$ETAGF.new" "$ETAGF"
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
  ETAG_STAMP="map $MAPCODE $ETAG_STAMP ${CLIENT:-node} ${FLEET_HUB_SESSIONS_USER:-}"
  if [ -s "$ETAGF" ] && { read -r etag; IFS= read -r stamp || stamp=''; } < "$ETAGF" && [ -n "$etag" ]; then
    [ "$stamp" = "$ETAG_STAMP" ] || etag=''
    while IFS=$'\t' read -r sess _c; do
      [ -z "$sess" ] || [ -s "$G/remote_$sess" ] || { etag=''; break; }
    done < "$lf"
  fi
  # the long poll (issue #1526): only with a validator to hold against
  q=''; LP_SENT=0; SCOPED=0
  if [ -n "$WAIT" ] && [ -n "$etag" ]; then LP_SENT=1; q="?wait=$WAIT"; fi
  if [ -n "$NTOK" ]; then
    AUTH_TOK=$NTOK
    curl_sessions "$out" "$etag" "$url/v1/fleet/fleet_sessions$q"; rc=$?; AUTH_TOK=''
    [ "$rc" = 4 ] || return "$rc"
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
      [ "$rc" = 4 ] || { SCOPED=1; return "$rc"; }
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
  printf 'fleet-hub-sessions: %s — the sidebar shows no other machine\n' "$(identity | sed 's/^none //')" >&2
  return 1
}

# local_fetch <out> — no hub (#1712): THIS machine's sessions, hub-shaped, from
# the node's own bin/ (FLEET_REMOTE_BIN, relative to $HOME — the path a machine
# is asked by over ssh), outside any tmux client. rc 1 when it does not answer.
local_fetch() {
  local rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
  case "$rbin" in /*) ;; *) rbin="$HOME/$rbin" ;; esac
  [ -f "$rbin/fleet-remote-view.sh" ] || {
    printf 'fleet-hub-sessions: no hub, and no fleet installed here (%s) — nothing to list\n' "$rbin" >&2; return 1; }
  ( unset TMUX TMUX_PANE; cd "$HOME" 2>/dev/null || :; bash "$rbin/fleet-remote-view.sh" sessions ) </dev/null >"$1" 2>/dev/null
}

# hub_ok <epoch> — the ONE word on 「入口通不通」 (issue #1483, EPIC #1479 C4):
# written on every round whose answer stood (a 200 taken in refresh, a 304
# restamped below), never on a failed one — so its age IS the hub's silence.
# fleet_status_hub_ok / fleet_status_hub_lost (fleet-status-lib.sh) are the
# readers; a cache from before this file is judged by its own #ts there.
hub_ok() {
  printf '%s\n' "$1" > "$G/hub_ok.new" 2>/dev/null && mv -f "$G/hub_ok.new" "$G/hub_ok"
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
  printf '%s\t%s\t%s\n' "$why" "$since" "$detail" > "$G/hub_why.new" 2>/dev/null && mv -f "$G/hub_why.new" "$G/hub_why"
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
  [ -z "$CLIENT" ] && [ -f "$FLEET_CONF_DIR/control/hub-workers.tsv" ] && touch "$FLEET_CONF_DIR/control/hub-workers.tsv" 2>/dev/null
  hub_ok "$now"
  return 0
}

# rows_user — whose sessions this round's answer is cut to: FLEET_HUB_SESSIONS_USER,
# else `*` for the shell when the hub answered over the person's certificate (issue
# #2388: the hub already scoped it to their logins, and the login on a node is not
# the name of the computer they sit at — cj's sidebar matched `id -un` against it
# and dropped every session, the one just opened included), else `id -un`.
rows_user() {
  if [ -n "${FLEET_HUB_SESSIONS_USER:-}" ]; then printf '%s' "$FLEET_HUB_SESSIONS_USER"
  elif [ -n "$CLIENT" ] && [ "$SCOPED" = 1 ]; then printf '*'
  else id -un 2>/dev/null; fi
}

refresh() {
  hub_on || return 0
  local json sess _c u lf mf repos m rc now ok
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
  while IFS=$'\t' read -r sess _c; do
    [ -n "$sess" ] || continue
    if [ -n "$CLIENT" ]; then
      # the shell's pseudo-fleet (#1484): no UUID, no repos, no windows to map
      printf '%s\t\t0\t\n' "$sess"; continue
    fi
    u=$(fleet_uuid "$sess" 2>/dev/null) || u=''
    repos=$(fleet_repos "$sess" 2>/dev/null | tr '\n' ' ')
    m=1   # every key carries its repo (issue #1939) — the bit stays for an older reader
    printf '%s\t%s\t%s\t%s\n' "$sess" "$u" "$m" "$repos"
    bash "$BIN/fleet-control-read.sh" workers "$sess" 2>/dev/null \
      | while IFS= read -r line; do [ -n "$line" ] && printf '%s\t%s\n' "$sess" "$line"; done >> "$mf"
  done > "$lf" <<EOF
$(local_fleets)
EOF
  if [ "$LOCAL" = 1 ]; then
    # no hub (#1712): this machine's own answer, mapped as a machine's (via=node;
    # every login it lists is this one — `*`, as over a connection)
    rc=1; now=$(date +%s)
    local_fetch "$json" && [ -s "$json" ] && map_write "$json" "$lf" "$mf" "$now" node '*' && rc=0
    [ "$rc" = 0 ] && hub_ok "$now"
    LAST_FETCH=$rc
    rm -f "$json" "$lf" "$mf"
    return "$rc"
  fi
  fetch "$json" "$lf"; rc=$?; LAST_FETCH=$rc
  if [ "$rc" = 3 ]; then
    restamp "$lf"; rm -f "$json" "$lf" "$mf"; return 0
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
    # the shell (#1488): past the stale bound, every machine it is connected to
    # answers for itself over that connection — client mode only
    rc=1
    if [ -n "$CLIENT" ] && hub_lost_now; then node_refresh "$json" "$lf" "$mf" && rc=0; fi
    rm -f "$json" "$lf" "$mf"
    return "$rc"
  fi
  now=$(date +%s)
  map_write "$json" "$lf" "$mf" "$now" hub "$(rows_user)"; rc=$?
  rm -f "$json" "$lf" "$mf"
  # A cache that failed to write is not vouched for: the next fetch takes the body.
  # One that stood is the hub answering: hub_ok (#1483).
  if [ "$rc" = 0 ]; then hub_ok "$now"; else rm -f "$ETAGF"; fi
  return "$rc"
}

# map_write <json> <local-fleets> <window-map> <now> <via> <user> — the ONE mapping
# from a fleet_sessions document to the caches: the hub's answer (via=hub), and in
# client mode with the hub silent the machines' own answers over the shell's
# connections (via=node, #1488 — then <user> is `*`: a login you are ssh'd into is
# yours, and the lines of the machines that did not answer are carried over from
# the cache on disk, via=hub, so they read 失联 as before).
map_write() {
  local json="$1" lf="$2" mf="$3" now="$4" via="$5" user="$6"
  python3 - "$json" "$lf" "$G" "$FLEET_C" "$FLEET_CONF_DIR/control/hub-workers.tsv" \
    "$user" "$(hostname 2>/dev/null)" \
    "${FLEET_NODE_ALIASES:-}" "$now" "$mf" "$BIN" "$CLIENT" "$via" <<'PY'
import json, os, re, sys, tempfile, time
from datetime import datetime, timezone
jpath, lpath, gdir, cdir, wpath, user, host, aliases, now, mpath, bindir, client, via = sys.argv[1:14]
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
# Client mode (#1484): this computer is nobody's `#me` — every row is a machine
# the shell reaches over ssh, this host included when it happens to be a node.
me = "" if client else short(host)
local = []
for line in open(lpath, encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 4 and p[0]:
        local.append(dict(sess=p[0], uuid=p[1], multi=p[2] == "1", repos=p[3].split()))
local_uuids = {f["uuid"] for f in local if f["uuid"]}
clean = lambda v: re.sub(r"[\t\n\r\x1f]", " ", str(v if v is not None else ""))

# This machine's live windows (issue #1480): (fleet, key) → window id, keyed by
# the hub's own rule (fleet_hub_common.worker_key, what the node agent reports),
# so a local row's worker_id maps to the window that holds it right now.
sys.path.insert(0, bindir)
try:
    from fleet_hub_common import worker_key
except Exception:
    worker_key = None
windows = {}
one_repo = {f["sess"]: f["repos"] for f in local}
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
                # compat-1v: 下一批删
                # …and by the bare key a one-repo fleet's worker_id wore before
                # issue #1939 (the one repo's alias, read for one version)
                if ":" in k and len(one_repo.get(p[0]) or []) == 1:
                    windows.setdefault((p[0], k.split(":", 1)[1]), p[1])
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

# The C1 locator cache: worker_id → machine, for every routable session — a
# node's; the shell (client mode) has no control adapter to serve.
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
if not client:
    write(wpath, "".join("%s\t%s\n" % (w, label(s.get("machine_name")))
                         for s in sessions if s.get("worker_id")
                         for w in (s["worker_id"], ident_wid(s)) if w))

is_local = lambda s: not client and (s.get("fleet_id") in local_uuids or short(s.get("machine_name")) == me)
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
    rows.append(dict(wid=wid, node=label(host) if here else label(s.get("machine_name")),
                     av="online" if here else ("lost" if s.get("availability") == "lost" else "online"),
                     issue=w.get("issue") or "", repo=w.get("repo") or "",
                     state=w.get("lifecycle") if w.get("lifecycle") not in (None, "", "awake") else (w.get("state") or ""),
                     agent=w.get("agent") or "", name=w.get("name") or w.get("key") or wid.split("/", 1)[1],
                     owid=by_ident.get(w.get("origin_wid") or "", w.get("origin_wid") or ""), needs=w.get("needs") or "", busy=w.get("busy") or "", born=born_of(w), cfg=w.get("cfg") if w.get("cfg") in ("stale", "renew", "ok") else "", title=w.get("title") if isinstance(w.get("title"), str) else "", detail=w.get("detail") if isinstance(w.get("detail"), str) else "", role="orchestrator" if w.get("role") == "orchestrator" else "", queue=str(w["orch_queue"]) if type(w.get("orch_queue")) is int and w["orch_queue"] >= 0 else "", epic=w.get("epic") if isinstance(w.get("epic"), str) and re.fullmatch(r"(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[1-9][0-9]{0,9}(?::[0-9]{1,4}/[0-9]{1,4})?", w.get("epic")) else "", reap=w.get("reap") if isinstance(w.get("reap"), str) and re.fullmatch(r"[A-Za-z0-9:.+-]{1,48}", w.get("reap")) else "", backfill="failed" if w.get("backfill") == "failed" else "", test=w.get("test") is True, ctx=ctx_of(w), ask=ask_of(w, w.get("lifecycle") if w.get("lifecycle") not in (None, "", "awake") else (w.get("state") or "")), stale=stale_of(w), seen=epoch(s.get("observed_at")), seenf=fepoch(s.get("observed_at")),
                     local=here["sess"] if here else None,
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
    if r["local"]:
        continue                                     # this machine is `#me`, never a #node
    cur = nodes.setdefault(r["node"], dict(av="lost", n=0, seen=0))
    cur["n"] += 1
    if not data.get("nodes"):
        if r["av"] in ("online", "maintenance") and cur["av"] == "lost":
            cur["av"] = r["av"]
        cur["seen"] = max(cur["seen"], r["seen"])
head = ["#ts\x1f%s\n" % now, "#me\x1f%s\n" % ("" if client else clean(label(host)))]
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

def e2e_log(path, rows):
    """The end-to-end log (issue #1631): for each row whose state or needs moved
    since the cache on disk, one line in global/hub_e2e.log —
    `<received ms> <observed ms> <lag ms> <worker_id> <state>|<needs>` — the
    node's observation of the change (the hub's observed_at) to this shell
    holding it. `--e2e` reads the median off the last 50. Kept to 500 lines."""
    old = {}
    try:
        for line in open(path, encoding="utf-8"):
            p = line.rstrip("\n").split("\x1f")
            if p[0].startswith("wid:") and len(p) >= 10:
                old[p[0][4:]] = (p[5], p[9])
    except OSError:
        return                                       # a first cache: nothing moved
    recv = time.time()
    new = []
    for r in rows:
        prev = old.get(r["wid"])
        if prev is None or prev == (clean(r["state"]), clean(r["needs"])) or not r["seenf"]:
            continue
        new.append("%d %d %d %s %s|%s\n" % (recv * 1000, r["seenf"] * 1000, (recv - r["seenf"]) * 1000,
                                            r["wid"], clean(r["state"]) or "-", clean(r["needs"]) or "-"))
    if not new:
        return
    lp = os.path.join(gdir, "hub_e2e.log")
    try:
        with open(lp, encoding="utf-8") as f:
            keep = f.readlines()[-(500 - len(new)):] if len(new) < 500 else []
    except OSError:
        keep = []
    write(lp, "".join(keep + new[-500:]))

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
                                              + ((r["title"],) if r["title"] or r["reap"] or r["epic"] or r["backfill"] or r["ctx"] or r["test"] or r["ask"] else ())
                                              + ((r["reap"],) if r["reap"] or r["epic"] or r["backfill"] or r["ctx"] or r["test"] or r["ask"] else ())
                                              + ((r["epic"],) if r["epic"] or r["backfill"] or r["ctx"] or r["test"] or r["ask"] else ())
                                              + ((r["backfill"],) if r["backfill"] or r["ctx"] or r["test"] or r["ask"] else ())
                                              # 21-25 (#2431): ctx_left · ctx_band · ctx_ts · model ·
                                              # effort — all five, only when the node measured any
                                              + (r["ctx"] or (("",) * 5 if r["test"] or r["ask"] else ()))
                                              # 26 (#2505): `1` on a test identity's session
                                              + (("1" if r["test"] else "",) if r["test"] or r["ask"] else ())
                                              # 27-28 (#2538): what a needs session asks — its
                                              # kind (permission · question · auth) and its words
                                              + (r["ask"] or ())) + "\n")
    path = os.path.join(gdir, "remote_" + f["sess"])
    if via == "node" and not (client and os.environ.get("FLEET_HUB_SESSIONS_LOCAL") == "1"):
        # The machines that did not answer over a connection keep their last
        # lines (#1488) — header lines before any row, as every reader expects —
        # marked via=hub: not heard this round, so the hub's silence dims them.
        # With no hub at all (#1712) this machine is the whole list: an earlier
        # hub round's other machines are not carried.
        fresh = set(nodes)
        keep_nodes, keep_rows = [], []
        try:
            for line in open(path, encoding="utf-8"):
                p = line.rstrip("\n").split("\x1f")
                if p[0] == "#node" and len(p) >= 5 and p[1] and p[1] not in fresh:
                    keep_nodes.append("\x1f".join(p[:5] + ["hub"]) + "\n")
                elif p[0].startswith("wid:") and len(p) >= 12 and p[1] not in fresh:
                    keep_rows.append("\x1f".join(p[:12] + ["hub"] + p[13:14]) + "\n")
        except OSError:
            pass
        out = out[:len(head)] + keep_nodes + out[len(head):] + keep_rows
    unk = {lb for lb, n in nodes.items() if n.get("unk")}
    if via == "hub" and unk:
        # A machine whose fleet the hub could not read this beat (`sessions`
        # null, #1465) is "could not read", never "no windows" (#1795): its
        # rows the answer lacks keep their last lines. A hub that blanked them
        # dropped every row of that machine for the seconds a node's read
        # timed out — the sidebar collapsed to the one row it stood on.
        have = {r["wid"] for r in rows}
        try:
            for line in open(path, encoding="utf-8"):
                p = line.rstrip("\n").split("\x1f")
                if p[0].startswith("wid:") and len(p) >= 2 and p[1] in unk and p[0][4:] not in have:
                    out.append(line if line.endswith("\n") else line + "\n")
        except OSError:
            pass
    if client and via == "hub":
        e2e_log(path, rows)
    write(path, "".join(out))
    # Who is waiting on you, and what they ask (issue #1951): `needs_<sess>` beside
    # the cache, one line per session in `needs` (or `failed`) —
    # `<worker_id> US <#issue|name> US <needs|failed> US <machine> US <question>` —
    # which fleet-alerts.sh turns into the client's needs rows (the bar's
    # 「! n 等你」, the notification). The question is the node's
    # @claude_needs_detail, carried as the worker's `detail`.
    need = []
    for r in rows:
        if r["local"] and r["local"] != f["sess"]:
            continue
        st = clean(r["state"])
        if st not in ("needs", "failed"):
            continue
        subj = "#" + str(r["issue"]) if r["issue"] else r["name"]
        need.append("\x1f".join(clean(v) for v in (r["wid"], subj, clean(r["needs"]) if st == "needs" else "failed",
                                                   r["node"], r["detail"][:120])) + "\n")
    write(os.path.join(gdir, "needs_" + f["sess"]), "".join(need))
    # The orchestrating session (issue #1957): `orch_<sess>` beside the cache, ONE
    # line — `<worker_id> US <machine> US <online|lost> US <state> US <needs> US
    # <question>[ US <queue>]`. The person has one (issue #2117: the hub names the machine that
    # holds it, fleet-orchestrator.sh closes the others); should two still answer
    # — a machine that has not asked yet, an old hub — the line is the online one
    # on the home machine (`fleet connect`'s last pick), then online, then by
    # machine, and `orch_multi_<sess>` names them all for the doctor's WARN. Every
    # orchestrator's row stays in the cache (fleet-remote-view.sh open finds it
    # there), the rows skip every one of them (tmux-dashboard-rows.sh reads the
    # worker_ids from `orch_all_<sess>`), and 「新任务」 wears the line's state
    # (fleet-sidebar.py), the writing area its busy line (fleet-compose.py).
    home = ""
    try:
        cp = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"),
                          "claude-fleet", "connect.json")
        with open(cp, encoding="utf-8") as cf:
            home = str((json.load(cf) or {}).get("last") or "")
    except (OSError, ValueError, AttributeError):
        home = ""
    def first_label(n):
        return (n or "").split(".")[0].lower()
    orch = sorted((r for r in rows if r["role"] == "orchestrator" and not (r["local"] and r["local"] != f["sess"])),
                  key=lambda r: (r["av"] != "online", not home or first_label(r["node"]) != first_label(home), r["node"]))
    # A 7th column (issue #2617, EPIC #2615 C2): `<queue>`, what waits behind its
    # running turn (the worker's orch_queue, the node inventory's `orchq=`) — only
    # when the node counted one (0 included), so an orchestrator that cannot count
    # (Codex, no mod, an older node) writes the six columns byte for byte as before.
    line = lambda r: "\x1f".join(clean(v) for v in (r["wid"], r["node"], r["av"], r["state"], r["needs"],
                                                      r["detail"][:120]) + ((r["queue"],) if r["queue"] else ())) + "\n"
    write(os.path.join(gdir, "orch_" + f["sess"]), "".join(line(r) for r in orch[:1]))
    write(os.path.join(gdir, "orch_all_" + f["sess"]), "".join(line(r) for r in orch))
    write(os.path.join(gdir, "orch_multi_" + f["sess"]),
          "".join(clean(r["node"]) + "\x1f" + clean(r["av"]) + "\n" for r in orch) if len(orch) > 1 else "")
    # The batches nobody drives (issue #1916): `epicstale_<sess>` beside the cache,
    # one line per (machine, EPIC) — `<owner/name>#<N> US <machine> US <online|lost>
    # US <age s> US <title> US <local 1|0>` — off any row of that machine (every
    # row carries its login's list). The sidebar draws each as a grey 「#N 没人在跑」
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
PY
}

# --- the hub silent: the rows over the shell's own connections (issue #1488) -------
# hub_lost_now — 失联 by the ONE word (fleet-status-lib.sh, as the rows and the bar
# read it): hub_ok older than FLEET_HUB_SESSIONS_STALE, or never written.
hub_lost_now() {
  # shellcheck disable=SC2034  # FLEET_STATUS_G is read by the lib sourced on the next line
  FLEET_STATUS_G="$G"; . "$BIN/fleet-status-lib.sh"
  fleet_status_hub_ok 0; fleet_status_hub_lost "$(date +%s)"
}
# node_ssh_host <label> — its ssh host (FLEET_REMOTE_SSH, as fleet-remote-view.sh)
node_ssh_host() {
  local h
  h=$(printf '%s\n' ${FLEET_REMOTE_SSH:-} | awk -F= -v n="$1" '$1 == n { print $2; exit }')
  printf '%s' "${h:-$1}"
}
# node_sources → `<label>\t<host>\t<ctl>` per machine the shell holds a LIVE
# connection to: a proxy window's `@remote_ctl` whose master answers `-O check`
# (fleet-shell.sh's ssh mode makes that a yes for a host that is this computer),
# then the shell's warm masters (`$TMPDIR/warm/<label>.sock`, issue #1631) for a
# machine no window is on.
node_sources() {
  local remote ctl node host out
  # the stage's windows (issue #1759: the shell's proxies live on `<client>-stage`),
  # and a shell's own, started before it
  out=$( { tmux -L "$CLIENT-stage" list-windows -t "=$CLIENT-stage" -F "#{@remote}"$'\t'"#{@remote_ctl}" 2>/dev/null
           tmux -L "$CLIENT" list-windows -t "=$CLIENT" -F "#{@remote}"$'\t'"#{@remote_ctl}" 2>/dev/null; } \
  | while IFS=$'\t' read -r remote ctl; do
      node=${remote%%:*}
      case "$node" in (''|-|*[!A-Za-z0-9._-]*) continue ;; esac
      [ -n "$ctl" ] && [ -S "$ctl" ] || continue
      host=$(node_ssh_host "$node")
      ${FLEET_REMOTE_SSH_CMD:-ssh} -S "$ctl" -O check "$host" >/dev/null 2>&1 || continue
      printf '%s\t%s\t%s\n' "$node" "$host" "$ctl"
    done | awk -F '\t' '!seen[$1]++')   # one connection per machine, the stage's first
  [ -n "$out" ] && printf '%s\n' "$out"
  for ctl in "${TMPDIR:-/tmp}"/warm/*.sock; do
    [ -S "$ctl" ] || continue
    node=${ctl##*/}; node=${node%.sock}
    case "$node" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    printf '%s\n' "$out" | cut -f1 | grep -qxF "$node" && continue
    host=$(node_ssh_host "$node")
    ${FLEET_REMOTE_SSH_CMD:-ssh} -S "$ctl" -O check "$host" >/dev/null 2>&1 || continue
    printf '%s\t%s\t%s\n' "$node" "$host" "$ctl"
  done
  return 0
}
# node_refresh <json> <local-fleets> <window-map> → rc 0 = a cache written off the
# connections (<json> is reused for the merged document). Each machine is asked
# once, bounded by FLEET_HUB_NODE_TIMEOUT; one that fails keeps its last lines.
node_refresh() {
  local json="$1" lf="$2" mf="$3" src srcf asked now rc
  src=$(node_sources); [ -n "$src" ] || return 1
  # the sources go by file: the script itself is python's stdin (the heredoc)
  srcf=$(mktemp "$G/hubsess.src.XXXXXX") || return 1
  printf '%s\n' "$src" > "$srcf"
  asked=$(python3 - "$json" "$srcf" "${FLEET_REMOTE_SSH_CMD:-ssh}" \
            "${FLEET_REMOTE_BIN:-.claude/fleet/bin}" "${FLEET_HUB_NODE_TIMEOUT:-8}" <<'PY'
import json, shlex, subprocess, sys
from datetime import datetime, timezone
out, srcpath, ssh, rbin, tmo = sys.argv[1:6]
try:
    tmo = float(tmo)
except ValueError:
    tmo = 8.0
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
sessions, nodes, asked = [], [], []
for line in open(srcpath, encoding="utf-8"):
    node, host, ctl = (line.rstrip("\n").split("\t") + ["", "", ""])[:3]
    if not node or not ctl:
        continue
    try:
        r = subprocess.run(shlex.split(ssh) + ["-S", ctl, host, "bash %s/fleet-remote-view.sh sessions" % rbin],
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=tmo)
        d = json.loads(r.stdout.decode("utf-8", "replace"))
        rows = d["sessions"]
        assert isinstance(rows, list)
    except Exception:
        sys.stderr.write("fleet-hub-sessions: %s did not answer over its connection — its last rows stand\n" % node)
        continue
    n = 0
    for s in rows:
        if isinstance(s, dict) and s.get("worker_id"):
            s["machine_name"] = node          # the shell's label for it, whatever it calls itself
            sessions.append(s)
            n += 1
    nodes.append({"machine_name": node, "availability": "online", "sessions": n, "observed_at": now})
    asked.append(node)
if not asked:
    sys.exit(1)
with open(out, "w", encoding="utf-8") as f:
    json.dump({"sessions": sessions, "nodes": nodes}, f)
print(" ".join(asked))
PY
); rc=$?
  rm -f "$srcf"
  [ "$rc" = 0 ] && [ -s "$json" ] || return 1
  now=$(date +%s)
  map_write "$json" "$lf" "$mf" "$now" node '*' || return 1
  # the hub's next answer must be a full body: the cache is no longer its last one
  rm -f "$ETAGF"
  printf 'fleet-hub-sessions: hub silent — the rows of %s come over the direct connection (via=node) until it answers\n' "$asked" >&2
  return 0
}

# watched — is anyone looking? A client attached to any fleet session on this
# machine: the dash, a shell, another machine's proxy window. Then the loop runs
# at WATCHED_EVERY; with nobody attached there is no one to show a change to
# sooner, and the hub is asked every EVERY as before.
watched() {
  local sess _c
  while IFS=$'\t' read -r sess _c; do
    [ -n "$sess" ] || continue
    [ -n "$(tmux -L "$sess" list-clients 2>/dev/null)" ] && return 0
  done <<EOF
$(local_fleets)
EOF
  return 1
}

# --- The status bar's two summaries (issue #1482, EPIC #1479 C3) ---------------
# Written on the same round as the sessions, read by bin/fleet-status-lib.sh (the
# bar, C4's 入口 chip, C5's shell) — never fetched on a render path.
#   $G/hub_nodes   #ts<US><epoch>, then one line per machine the hub shows:
#     node<US>online|lost<US>load1<US>ncpu<US>mem_pct<US>sessions<US>fleet_version<US>age<US>mem_used_mb<US>mem_total_mb<US>ver_state<US>place<US>hostname
#     (sessions `?` when the hub could not read a fleet there — #1465; place is
#     `coord` / `maint` / '' — what the sidebar's 「开在哪」 greys, issue #1778)
#     (/v1/nodes `machines`: one load per machine; fleet_version is its newest
#     login's; age is seconds since its last heartbeat when written; ver_state
#     is that version's word against the stable mark — issue #644, below)
#   $G/hub_repos   #ts<US><epoch>, then one owner/name per line: the repos those
#     machines' fleets host (`repos`, issue #1927) — the sidebar's candidates
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
         curl -K - -sS -m 8 -o "$SUMJ" -w '%{http_code}' "$url/v1/fleet/summary" 2>/dev/null)
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
  [ "$LOCAL" = 1 ] && return 0     # no hub (#1712): nothing to summarize
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
# sidebar's repo candidates while its list has no heading yet. A hub older
# than `repos` sends no key: then no file, and the sidebar says what it did.
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
# `account` {state opening|failed|none, eta_s, machine, ask}. The sidebar
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
  local end every t0
  # ONE loop per cache, by a lock its holder keeps for life (issue #2630): the
  # pid file alone let two shells' --ensure race past each other (two loops on
  # one cache for hours). Not holding it yet ⇒ re-exec under the lock; someone
  # else holds it ⇒ exit 0.
  local guard="${FLEET_HUBSESS_GUARD:-}"
  if [ -z "${FLEET_HUBSESS_LOCKED:-}" ]; then
    exec python3 -c "$LOCK_PY" "$LOCKF" 0 bash "$BIN/fleet-hub-sessions.sh" --loop
  fi
  unset FLEET_HUBSESS_LOCKED FLEET_HUBSESS_GUARD
  printf '%s\n' "$$" > "$PIDF"
  end=$(( $(date +%s) + LOOP_SECS ))
  while :; do
    # the lock's holder is gone (SIGKILLed): the lock went with it — stop
    if [ -n "$guard" ] && ! kill -0 "$guard" 2>/dev/null; then break; fi
    every=$EVERY; WAIT=''
    if watched; then
      every=$WATCHED_EVERY
      [ "${FLEET_HUB_SESSIONS_LONGPOLL:-1}" = 0 ] || WAIT=$LP_WAIT
    fi
    t0=$(date +%s); LP_SENT=0; LAST_FETCH=1
    # A client in standby (issue #1715: another client holds the person's
    # lease) asks the hub nothing; Enter on its standby screen resumes it.
    if [ -n "${FLEET_HUB_SESSIONS_CLIENT:-}" ] && [ -f "${TMPDIR:-/tmp}/client.standby" ]; then
      [ $(( $(date +%s) + EVERY )) -le "$end" ] || break
      sleep "$EVERY"; continue
    fi
    refresh_all 2>/dev/null
    # A long-polled answer paces itself (issue #1526): a 200 (a change) or a
    # 304 the hub held is asked again at once; an immediate 304 or a failure —
    # an older hub that ignores `wait`, or none — keeps the 2 s cadence.
    if [ "$LP_SENT" = 1 ] && { [ "$LAST_FETCH" = 0 ] || [ $(( $(date +%s) - t0 )) -ge "$WATCHED_EVERY" ]; }; then
      every=0
    fi
    [ $(( $(date +%s) + every )) -le "$end" ] || break
    [ "$every" = 0 ] || sleep "$every"
  done
  read -r p < "$PIDF" 2>/dev/null && [ "$p" = "$$" ] && rm -f "$PIDF"
  return 0
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
# the sidebar, remote_<sess> stopped for 10 hours. setsid(2) takes it out of
# that group; systemd's collect unit says KillMode=process for the same reason.
ensure() {
  hub_on || return 0
  [ -z "$(loop_pid)" ] || return 0
  mkdir -p "$G" 2>/dev/null || return 0
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

# e2e [N] — the end-to-end readout (issue #1631): over the last N (50) lines of
# global/hub_e2e.log, `n <count> · median <ms> · max <ms>` — a state change on a
# node to this shell holding it. rc 1 = no line yet.
e2e() {
  local n="$1"
  case "$n" in ''|*[!0-9]*) n=50 ;; esac
  [ -s "$G/hub_e2e.log" ] || { printf 'n 0 · no change logged yet (%s)\n' "$G/hub_e2e.log"; return 1; }
  tail -n "$n" "$G/hub_e2e.log" | awk '{ print $3 }' | sort -n | awk '
    { v[NR] = $1 } END { if (NR == 0) exit 1
      m = (NR % 2) ? v[(NR + 1) / 2] : int((v[NR / 2] + v[NR / 2 + 1]) / 2)
      printf "n %d · median %dms · max %dms\n", NR, m, v[NR] }'
}

cert_paths   # CERT_KEY / CERT_PUB for every mode (cert_state runs in a subshell)
case "${1:-}" in
  --refresh)  refresh_all ;;
  --loop)     loop ;;
  --ensure)   ensure ;;
  --status)   status ;;
  --identity) identity ;;
  --e2e)      e2e "${2:-50}" ;;
  *) printf 'usage: fleet-hub-sessions.sh --refresh | --loop | --ensure | --status | --identity | --e2e [N]\n' >&2; exit 2 ;;
esac
