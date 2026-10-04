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
#               (/v1/limits) — on their own cadence, FLEET_HUB_SUMMARY_EVERY
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
#   --ensure    start a detached --loop unless one is alive. The collector runs this
#               every tick (60s), so the 10s cadence needs no daemon of its own and a
#               loop can never outlive the collector by more than one round.
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
# FLEET_HUB_SESSIONS_USER; `*` = every login the hub shows you) and that has a
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
#   #node<US><label><US>online|lost<US><n><US><last-seen epoch>   one per OTHER
#       machine the hub shows you (#1475): the sidebar's status line — n is your
#       sessions there, last-seen the hub's newest observation of it. From the
#       hub's `nodes` list; derived from the sessions on a hub older than #1475.
# then one row per session:
#   wid:<worker_id>  node  online|lost  issue  repo  state  agent  name  origin  needs  local  wid
# `origin` is already in the viewing fleet's terms: a parent in THIS fleet is its
# bare key (`issue-1419`, exactly what a local @origin holds), a parent elsewhere is
# its full worker_id; no @origin_wid ⇒ the issue's sub-issue parent (the collector's
# parents cache), when that repo is hosted here. `needs` (#1475) is the window's
# @claude_needs — ask / perm / blocked / … — so the row draws the same red `?`.
# `local` (#1480) is 1 for a row of THIS fleet on THIS machine, 0 for another
# machine's; `wid` is a local row's live tmux window id (`@12`; empty when no window
# holds that worker right now), empty on another machine's row. Both are APPENDED,
# so a reader of the ten older fields is unchanged — but a `read` that names `needs`
# last must now name these two too, or they arrive glued to it.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

G="$FLEET_C/global"
EVERY="${FLEET_HUB_SESSIONS_EVERY:-10}"; case "$EVERY" in ''|*[!0-9]*|0) EVERY=10 ;; esac
WATCHED_EVERY="${FLEET_HUB_SESSIONS_WATCHED_EVERY:-2}"; case "$WATCHED_EVERY" in ''|*[!0-9]*|0) WATCHED_EVERY=2 ;; esac
ETAGF="$G/hubsess.etag"      # the validator of the cache on disk (issue #1481)
LOOP_SECS="${FLEET_HUB_SESSIONS_LOOP_SECS:-70}"; case "$LOOP_SECS" in ''|*[!0-9]*) LOOP_SECS=70 ;; esac
PIDF="$G/hubsess.pid"
SESSIONS_NS='fleet-sessions@claude-fleet'

hub_on() { [ "${CCQUOTA_FLEET:-0}" = 1 ]; }
# The fleets this loop serves: the shell's one pseudo-fleet in client mode
# (issue #1484), else every fleet configured on this machine.
CLIENT="${FLEET_HUB_SESSIONS_CLIENT:-}"
case "$CLIENT" in *[!A-Za-z0-9._-]*) CLIENT='' ;; esac
local_fleets() {
  if [ -n "$CLIENT" ]; then printf '%s\t-\n' "$CLIENT"; else fleet_each_conf; fi
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

# identity → one line: cert … / token … / none …; rc 0 / 0 / 1.
identity() {
  local st src
  if [ -n "${FLEET_HUB_SESSIONS_CMD:-}" ]; then printf 'cmd FLEET_HUB_SESSIONS_CMD\n'; return 0; fi
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
  local out="$1" etag="$2" hdr code; shift 2
  hdr=$(mktemp "$G/hubsess.hdr.XXXXXX") || return 1
  set -- -sS -m 8 -o "$out" -D "$hdr" -w '%{http_code}' "$@"
  [ -n "$etag" ] && set -- "$@" -H "If-None-Match: $etag"
  code=$(curl "$@" 2>/dev/null)
  case "$code" in
    200) etag=$(awk 'tolower($1) == "etag:" { sub(/\r$/, "", $2); print $2; exit }' "$hdr" 2>/dev/null)
         rm -f "$hdr"
         if [ -n "$etag" ]; then printf '%s\n' "$etag" > "$ETAGF.new" && mv -f "$ETAGF.new" "$ETAGF"
         else rm -f "$ETAGF"; fi
         return 0 ;;
    304)     rm -f "$hdr"; return 3 ;;
    401|403) rm -f "$hdr"; return 4 ;;
    *)       rm -f "$hdr"; return 1 ;;
  esac
}

# fetch_cert <url> <out> <etag> → the JSON into <out>; rc as curl_sessions
# (4 = the hub refused the certificate: fall back).
fetch_cert() {
  local url="$1" out="$2" etag="$3" ts sig cert body
  ts=$(date +%s)
  sig=$(printf 'fleet-sessions %s' "$ts" | ssh-keygen -Y sign -f "$CERT_KEY" -n "$SESSIONS_NS" 2>/dev/null) || return 1
  cert=$(head -n1 "$CERT_PUB" 2>/dev/null) || return 1
  body=$(python3 -c 'import json, sys; print(json.dumps({"cert": sys.argv[1], "sig": sys.argv[2], "ts": int(sys.argv[3])}))' \
         "$cert" "$sig" "$ts") || return 1
  curl_sessions "$out" "$etag" -X POST -H 'Content-Type: application/json' --data-binary "$body" "$url/v1/fleet/fleet_sessions"
}

# fetch <out> <local-fleets> → the fleet_sessions JSON into <out>. rc 0 = a fresh
# body; 3 = 304, nothing changed since the ETag on disk (the <out> file is empty);
# 1 = no answer. The validator goes out only while every cache it vouches for is
# on disk — a fleet created since, or a wiped $FLEET_C, needs the body.
fetch() {
  local out="$1" lf="$2" url st rc etag='' sess _c
  if [ -n "${FLEET_HUB_SESSIONS_CMD:-}" ]; then
    bash -c "$FLEET_HUB_SESSIONS_CMD" </dev/null >"$out" 2>/dev/null; return
  fi
  url=$(hub_url) || { printf 'fleet-hub-sessions: no hub URL (CCQUOTA_HUB_URL / FLEET_HUB_URL / hub.json) — no other machine to show\n' >&2; return 1; }
  command -v curl >/dev/null 2>&1 || return 1
  if [ -s "$ETAGF" ] && read -r etag < "$ETAGF" && [ -n "$etag" ]; then
    while IFS=$'\t' read -r sess _c; do
      [ -z "$sess" ] || [ -s "$G/remote_$sess" ] || { etag=''; break; }
    done < "$lf"
  fi
  st=$(cert_state)
  case "$st" in
    ok\ *)
      fetch_cert "$url" "$out" "$etag"; rc=$?
      [ "$rc" = 4 ] || return "$rc"
      printf 'fleet-hub-sessions: the hub refused the connection certificate %s — trying the viewer token\n' "$CERT_PUB" >&2 ;;
  esac
  if token_source >/dev/null; then
    curl_sessions "$out" "$etag" -H "Authorization: Bearer $TOK" "$url/v1/fleet/fleet_sessions"; rc=$?
    [ "$rc" = 4 ] && rc=1
    return "$rc"
  fi
  printf 'fleet-hub-sessions: %s — the sidebar shows no other machine\n' "$(identity | sed 's/^none //')" >&2
  return 1
}

# hub_ok <epoch> — the ONE word on 「入口通不通」 (issue #1483, EPIC #1479 C4):
# written on every round whose answer stood (a 200 taken in refresh, a 304
# restamped below), never on a failed one — so its age IS the hub's silence.
# fleet_status_hub_ok / fleet_status_hub_lost (fleet-status-lib.sh) are the
# readers; a cache from before this file is judged by its own #ts there.
hub_ok() {
  printf '%s\n' "$1" > "$G/hub_ok.new" 2>/dev/null && mv -f "$G/hub_ok.new" "$G/hub_ok"
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
    if fleet_multirepo "$sess" 2>/dev/null; then m=1; else m=0; fi
    printf '%s\t%s\t%s\t%s\n' "$sess" "$u" "$m" "$repos"
    bash "$BIN/fleet-control-read.sh" workers "$sess" 2>/dev/null \
      | while IFS= read -r line; do [ -n "$line" ] && printf '%s\t%s\n' "$sess" "$line"; done >> "$mf"
  done > "$lf" <<EOF
$(local_fleets)
EOF
  fetch "$json" "$lf"; rc=$?
  if [ "$rc" = 3 ]; then
    restamp "$lf"; rm -f "$json" "$lf" "$mf"; return 0
  fi
  if [ "$rc" != 0 ] || [ ! -s "$json" ]; then
    rm -f "$json" "$lf" "$mf"
    # one line, with how long the hub has been silent (hub_ok is left as it was)
    ok=''; { read -r ok _c < "$G/hub_ok"; } 2>/dev/null || ok=''
    case "$ok" in
      ''|*[!0-9]*) printf 'fleet-hub-sessions: hub unreachable — keeping the last cache (its rows read 失联 once hub_ok is older than %ss)\n' "${FLEET_HUB_SESSIONS_STALE:-60}" >&2 ;;
      *) printf 'fleet-hub-sessions: hub unreachable for %ss — keeping the last cache (its rows read 失联 past %ss; the next answer flips them back)\n' "$(( $(date +%s) - ok ))" "${FLEET_HUB_SESSIONS_STALE:-60}" >&2 ;;
    esac
    return 1
  fi
  now=$(date +%s)
  python3 - "$json" "$lf" "$G" "$FLEET_C" "$FLEET_CONF_DIR/control/hub-workers.tsv" \
    "${FLEET_HUB_SESSIONS_USER:-$(id -un 2>/dev/null)}" "$(hostname 2>/dev/null)" \
    "${FLEET_NODE_ALIASES:-}" "$now" "$mf" "$BIN" "$CLIENT" <<'PY'
import json, os, re, sys, tempfile
from datetime import datetime, timezone
jpath, lpath, gdir, cdir, wpath, user, host, aliases, now, mpath, bindir, client = sys.argv[1:13]
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
    try:
        s = str(iso or "")
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        s = re.sub(r"(\.\d{6})\d+", r"\1", s)
        d = datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return int(d.timestamp())
    except Exception:
        return 0

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".hubsess.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)

# The C1 locator cache: worker_id → machine, for every routable session — a
# node's; the shell (client mode) has no control adapter to serve.
if not client:
    write(wpath, "".join("%s\t%s\n" % (s["worker_id"], label(s.get("machine_name")))
                         for s in sessions if s.get("worker_id")))

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
rows = []
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
                     owid=w.get("origin_wid") or "", needs=w.get("needs") or "", seen=epoch(s.get("observed_at")),
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
    head.append("\x1f".join(("#node", clean(lb), n["av"], str(n["n"]), str(n["seen"]))) + "\n")

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
                    origin = (slug(r["repo"]) + ":" if f["multi"] else "") + "issue-" + p
        out.append("\x1f".join(clean(v) for v in ("wid:" + r["wid"], r["node"], r["av"], r["issue"], r["repo"],
                                               r["state"], r["agent"], r["name"], origin, r["needs"],
                                               "1" if r["local"] else "0", r["lwid"])) + "\n")
    write(os.path.join(gdir, "remote_" + f["sess"]), "".join(out))
PY
  rc=$?
  rm -f "$json" "$lf" "$mf"
  # A cache that failed to write is not vouched for: the next fetch takes the body.
  # One that stood is the hub answering: hub_ok (#1483).
  if [ "$rc" = 0 ]; then hub_ok "$now"; else rm -f "$ETAGF"; fi
  return "$rc"
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
#     node<US>online|lost<US>load1<US>ncpu<US>mem_pct<US>sessions<US>fleet_version<US>age<US>mem_used_mb<US>mem_total_mb
#     (/v1/nodes `machines`: one load per machine; fleet_version is its newest
#     login's; age is seconds since its last heartbeat when written)
#   $G/hub_limits  #ts<US><epoch>, then one line per subscription with a reading:
#     label<US>pct5h<US>pctweek<US>account_uuid<US>hub_label
#     (/v1/limits?account=all; `label` is this login's accounts/<label>.conf name
#     whose CCQUOTA_ACCOUNT is that uuid — a window's @cc_account — else the
#     hub's label; a subscription without a utilization, e.g. codex, is skipped)
# Both routes are viewer routes, asked only when this login's identity (#1475's
# ladder: seam, certificate, viewer token) IS the viewer token: a certificate
# opens neither and a certificate round never spends the token, no identity
# means no fetch — then nothing is written and the bar shows `?` / no account
# chip (a cert door for them: #1502); a failed fetch keeps the last file. Seams: FLEET_HUB_NODES_CMD / FLEET_HUB_LIMITS_CMD
# print the JSON; a run driven by FLEET_HUB_SESSIONS_CMD never goes to the network
# for these either (a selftest must not reach a real hub through hub.json).
fetch_viewer() {   # fetch_viewer <path> → the JSON on stdout; rc 1 when no answer
  local url
  [ -z "${FLEET_HUB_SESSIONS_CMD:-}" ] || return 1
  url=$(hub_url) || return 1
  command -v curl >/dev/null 2>&1 || return 1
  # #1475's ladder, not a fallback: the login's identity is the certificate when
  # it has a valid one, and a certificate round never spends the viewer token —
  # so only a token identity asks these two routes (a cert door: #1502).
  case "$(cert_state)" in ok\ *) return 1 ;; esac
  token_source >/dev/null || return 1
  curl -fsS -m 8 -H "Authorization: Bearer $TOK" "$url$1" 2>/dev/null
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
  nj=$(mktemp "$G/hubnodes.json.XXXXXX") || return 1
  if fetch_nodes >"$nj" && [ -s "$nj" ]; then
    python3 - "$nj" "$G/hub_nodes" "${FLEET_NODE_ALIASES:-}" "$now" <<'PY' || printf 'fleet-hub-sessions: /v1/nodes did not answer a machine list — keeping the last hub_nodes\n' >&2
import json, os, re, sys, tempfile
from datetime import datetime, timezone
jpath, out, aliases, now = sys.argv[1:5]
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
    try:
        s = str(iso or "")
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        s = re.sub(r"(\.\d{6})\d+", r"\1", s)
        d = datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return int(d.timestamp())
    except Exception:
        return 0
version = {}
for n in data.get("nodes") or []:
    if not isinstance(n, dict) or not n.get("hostname") or not n.get("fleet_version"):
        continue
    t = epoch(n.get("last_heartbeat"))
    if t >= version.get(n["hostname"], (0, ""))[0]:
        version[n["hostname"]] = (t, n["fleet_version"])
lines = ["#ts\x1f%d\n" % now]
for m in machines:
    if not isinstance(m, dict) or not m.get("hostname"):
        continue
    h = m["hostname"]
    try:
        total = int(m.get("mem_total_bytes") or 0); free = int(m.get("mem_free_bytes") or 0)
        load1 = float(m.get("load1") or 0); ncpu = int(m.get("ncpu") or 0); sess = int(m.get("sessions") or 0)
    except (TypeError, ValueError):
        continue
    used = max(total - free, 0)
    hb = epoch(m.get("last_heartbeat"))
    lines.append("\x1f".join(clean(v) for v in (
        label(h), "online" if m.get("status") == "online" else "lost", "%.2f" % load1, ncpu,
        used * 100 // total if total else "", sess, version.get(h, (0, ""))[1],
        max(now - hb, 0) if hb else "", used // 1048576, total // 1048576)) + "\n")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".hubnodes.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("".join(lines))
os.replace(tmp, out)
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
  return 0
}
# One round: the sessions (its rc), then the two summaries.
refresh_all() { local rc; refresh; rc=$?; refresh_summaries; return "$rc"; }

loop() {
  hub_on || return 0
  mkdir -p "$G" 2>/dev/null || return 1
  local p end every
  read -r p < "$PIDF" 2>/dev/null || p=''
  if [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
  printf '%s\n' "$$" > "$PIDF"
  end=$(( $(date +%s) + LOOP_SECS ))
  while :; do
    refresh_all 2>/dev/null
    every=$EVERY; watched && every=$WATCHED_EVERY
    [ $(( $(date +%s) + every )) -le "$end" ] || break
    sleep "$every"
  done
  read -r p < "$PIDF" 2>/dev/null && [ "$p" = "$$" ] && rm -f "$PIDF"
  return 0
}

ensure() {
  hub_on || return 0
  local p
  read -r p < "$PIDF" 2>/dev/null || p=''
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
  ( cd / && nohup bash "$BIN/fleet-hub-sessions.sh" --loop </dev/null >/dev/null 2>&1 & )
  return 0
}

cert_paths   # CERT_KEY / CERT_PUB for every mode (cert_state runs in a subshell)
case "${1:-}" in
  --refresh)  refresh_all ;;
  --loop)     loop ;;
  --ensure)   ensure ;;
  --identity) identity ;;
  *) printf 'usage: fleet-hub-sessions.sh --refresh | --loop | --ensure | --identity\n' >&2; exit 2 ;;
esac
