#!/bin/bash
# fleet-hub-sessions.sh — the sidebar's view of YOUR sessions on the other machines
# (issue #1423, EPIC #1419 C4).
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
#               once it is older than FLEET_HUB_SESSIONS_STALE they read 失联.
#   --loop      --refresh every FLEET_HUB_SESSIONS_EVERY (10s) for
#               FLEET_HUB_SESSIONS_LOOP_SECS (70s), then exit. One at a time (pid file).
#   --ensure    start a detached --loop unless one is alive. The collector runs this
#               every tick (60s), so the 10s cadence needs no daemon of its own and a
#               loop can never outlive the collector by more than one round.
#
# OFF unless CCQUOTA_FLEET=1: every mode is then a silent no-op that writes nothing,
# and the dash never looks for the cache — a one-machine fleet is byte for byte
# what it was (CLAUDE.md «Degenerate case is sacred»).
#
# Where the answer comes from: FLEET_HUB_SESSIONS_CMD (prints the fleet_sessions
# JSON on stdout) when set, else GET $CCQUOTA_HUB_URL/v1/fleet/fleet_sessions with
# the viewer token (CCQUOTA_VIEWER_TOKEN, else ~/.ccquota/viewer-token) as the bearer. Neither ⇒ nothing to read, one stderr note.
#
# Which rows: a session whose fleet is NOT one of this machine's (by fleet UUID,
# and by hostname as a backstop), whose login is yours (os_user = `id -un`, or
# FLEET_HUB_SESSIONS_USER; `*` = every login the hub shows you), and that has a
# worker_id — a row the hub could not identify is not addressable, so it is not
# shown. The machine label is the hostname's first label, renamed through
# FLEET_NODE_ALIASES (`macmini=m5 mini2=m4`).
#
# Cache row (US-separated — \x1f, as the dash's own WFMT: a TAB is IFS whitespace,
# so `read` would collapse the empty fields — after one `#ts<US><epoch>` line):
#   wid:<worker_id>  node  online|lost  issue  repo  state  agent  name  origin
# `origin` is already in the viewing fleet's terms: a parent in THIS fleet is its
# bare key (`issue-1419`, exactly what a local @origin holds), a parent elsewhere is
# its full worker_id; no @origin_wid ⇒ the issue's sub-issue parent (the collector's
# parents cache), when that repo is hosted here.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

G="$FLEET_C/global"
EVERY="${FLEET_HUB_SESSIONS_EVERY:-10}"; case "$EVERY" in ''|*[!0-9]*|0) EVERY=10 ;; esac
LOOP_SECS="${FLEET_HUB_SESSIONS_LOOP_SECS:-70}"; case "$LOOP_SECS" in ''|*[!0-9]*) LOOP_SECS=70 ;; esac
PIDF="$G/hubsess.pid"

hub_on() { [ "${CCQUOTA_FLEET:-0}" = 1 ]; }

# fetch → the fleet_sessions JSON on stdout, rc 1 when there is no answer.
fetch() {
  if [ -n "${FLEET_HUB_SESSIONS_CMD:-}" ]; then
    bash -c "$FLEET_HUB_SESSIONS_CMD" </dev/null 2>/dev/null; return
  fi
  [ -n "${CCQUOTA_HUB_URL:-}" ] || { printf 'fleet-hub-sessions: no CCQUOTA_HUB_URL (and no FLEET_HUB_SESSIONS_CMD) — no other machine to show\n' >&2; return 1; }
  command -v curl >/dev/null 2>&1 || return 1
  # The viewer token where ccquota itself finds it: the env, else ~/.ccquota/viewer-token.
  local tok="${CCQUOTA_VIEWER_TOKEN:-}"
  [ -n "$tok" ] || { [ -r "$HOME/.ccquota/viewer-token" ] && read -r tok < "$HOME/.ccquota/viewer-token"; } || tok=''
  if [ -n "$tok" ]; then
    curl -fsS -m 8 -H "Authorization: Bearer $tok" "${CCQUOTA_HUB_URL%/}/v1/fleet/fleet_sessions" 2>/dev/null
  else
    curl -fsS -m 8 "${CCQUOTA_HUB_URL%/}/v1/fleet/fleet_sessions" 2>/dev/null
  fi
}

refresh() {
  hub_on || return 0
  local json sess _c u lf repos m
  mkdir -p "$G" 2>/dev/null || return 1
  json=$(mktemp "$G/hubsess.json.XXXXXX") || return 1
  lf=$(mktemp "$G/hubsess.local.XXXXXX") || { rm -f "$json"; return 1; }
  if ! fetch >"$json" || [ ! -s "$json" ]; then
    rm -f "$json" "$lf"
    printf 'fleet-hub-sessions: hub unreachable — keeping the last cache (its rows read 失联 once stale)\n' >&2
    return 1
  fi
  # This machine's fleets: name, UUID (may be empty), multi-repo bit, hosted repos.
  while IFS=$'\t' read -r sess _c; do
    [ -n "$sess" ] || continue
    u=$(fleet_uuid "$sess" 2>/dev/null) || u=''
    repos=$(fleet_repos "$sess" 2>/dev/null | tr '\n' ' ')
    if fleet_multirepo "$sess" 2>/dev/null; then m=1; else m=0; fi
    printf '%s\t%s\t%s\t%s\n' "$sess" "$u" "$m" "$repos"
  done > "$lf" <<EOF
$(fleet_each_conf)
EOF
  python3 - "$json" "$lf" "$G" "$FLEET_C" "$FLEET_CONF_DIR/control/hub-workers.tsv" \
    "${FLEET_HUB_SESSIONS_USER:-$(id -un 2>/dev/null)}" "$(hostname 2>/dev/null)" \
    "${FLEET_NODE_ALIASES:-}" "$(date +%s)" <<'PY'
import json, os, re, sys, tempfile
jpath, lpath, gdir, cdir, wpath, user, host, aliases, now = sys.argv[1:10]
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
slug = lambda r: re.sub(r"[^A-Za-z0-9._-]", "", (r or "").replace("/", "-"))

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".hubsess.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)

# The C1 locator cache: worker_id → machine, for every routable session.
write(wpath, "".join("%s\t%s\n" % (s["worker_id"], label(s.get("machine_name")))
                     for s in sessions if s.get("worker_id")))

rows = []
for s in sessions:
    w = s.get("worker") or {}
    wid = s.get("worker_id")
    if not wid or "/" not in wid:
        continue
    if s.get("fleet_id") in local_uuids or short(s.get("machine_name")) == me:
        continue                                     # this machine: the dash has it live
    if user != "*" and s.get("os_user") != user:
        continue                                     # someone else's login
    rows.append(dict(wid=wid, node=label(s.get("machine_name")),
                     av="lost" if s.get("availability") == "lost" else "online",
                     issue=w.get("issue") or "", repo=w.get("repo") or "",
                     state=w.get("lifecycle") if w.get("lifecycle") not in (None, "", "awake") else (w.get("state") or ""),
                     agent=w.get("agent") or "", name=w.get("name") or w.get("key") or wid.split("/", 1)[1],
                     owid=w.get("origin_wid") or ""))
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
    out = ["#ts\x1f%s\n" % now]
    for r in rows:
        origin = ""
        ou, _, ok = r["owid"].partition("/")
        if ok:
            origin = ok if f["uuid"] and ou == f["uuid"] else r["owid"]
        elif r["issue"] and r["repo"] in f["repos"]:
            p = parent_of(r["repo"], r["issue"])
            if p:
                origin = by_issue.get((r["repo"], p)) or ((slug(r["repo"]) + ":" if f["multi"] else "") + "issue-" + p)
        out.append("\x1f".join(clean(v) for v in ("wid:" + r["wid"], r["node"], r["av"], r["issue"], r["repo"],
                                               r["state"], r["agent"], r["name"], origin)) + "\n")
    write(os.path.join(gdir, "remote_" + f["sess"]), "".join(out))
PY
  local rc=$?
  rm -f "$json" "$lf"
  return "$rc"
}

loop() {
  hub_on || return 0
  mkdir -p "$G" 2>/dev/null || return 1
  local p end
  read -r p < "$PIDF" 2>/dev/null || p=''
  if [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
  printf '%s\n' "$$" > "$PIDF"
  end=$(( $(date +%s) + LOOP_SECS ))
  while :; do
    refresh 2>/dev/null
    [ $(( $(date +%s) + EVERY )) -le "$end" ] || break
    sleep "$EVERY"
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

case "${1:-}" in
  --refresh) refresh ;;
  --loop)    loop ;;
  --ensure)  ensure ;;
  *) printf 'usage: fleet-hub-sessions.sh --refresh | --loop | --ensure\n' >&2; exit 2 ;;
esac
