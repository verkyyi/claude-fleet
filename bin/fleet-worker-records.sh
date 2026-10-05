#!/bin/bash
# fleet-worker-records.sh — hand a reaped worker's evidence and history row to
# the hub, and read back what workers on the owner's OTHER machines left
# (issue #1609, EPIC #1645 C9).
#
#   fleet-worker-records.sh push  --session S --repo R --key K [--win W] [--evidence-only]
#   fleet-worker-records.sh fetch --session S --repo R (--epic E | --issue M | --history) [--dir D]
#
# WHY. A member the hub placed on m4 captured its 改动前 / 改动后 THERE
# (fleet-evidence.sh writes under m4's $FLEET_CONF_DIR) and was reaped THERE
# (its /fleet-history row is m4's ledger). The machine that ran the EPIC read
# 无证据 for six of twelve members and had one history row of seven. Now the
# reaping machine uploads what the worker left — every evidence file, its
# ledger row — to the hub, keyed by the worker_id (issue #1646); the other
# machine's `fleet-evidence.sh list/export` and `fleet-history.sh list` read it
# back. The hub keeps it 30 days and shows it only to the same owner's nodes.
#
# push   (fleet_reap_record runs it on every reap, fleet-report-parent.sh at a
#        ship report, --evidence-only: its row is not written yet) — the files
#        of `fleet-evidence.sh list --issue M` and the row of `fleet-history.sh row K`. Text first; an image over
#        FLEET_WORKER_RECORDS_IMG_MAX bytes (default 600 KiB) is shrunk with
#        `sips` (1600 px JPEG); a file still over 2 MiB is left out (stderr says
#        so) — text is cut to 2 MiB instead. Idempotent: the hub keys a record on
#        worker_id + name, so the ship report and the reap replace, never double.
# fetch  prints one TSV line per record from ANOTHER fleet (this fleet's own
#        uploads are skipped — the local copy is the truth here):
#          evidence <issue> <stage> <ts> <path> <note> <node>   (file written to <path>)
#          history  <issue|key> <node> <ledger row…>
#        Files land under --dir (default $FLEET_CONF_DIR/fleets/<S>/remote/<repo-slug>/<issue>/).
#
# Exit: 0 ok · 1 the hub refused or did not answer (stderr says which) · 2 usage
#       · 3 not applicable — not a hub node (no node token: node.env, #1491), the
#       hub predates #1609 (404), FLEET_WORKER_RECORDS=0, or nothing to push.
#       Exit 3 prints nothing on stdout: a one-machine fleet reads exactly what it
#       always read.
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport; FLEET_HUB_TIMEOUT
# the per-call bound (default 10 s; fetch 5 s).
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-worker-records: %s\n' "$2" >&2; exit "$1"; }

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in push|fetch) ;; *) die 2 'usage: fleet-worker-records.sh push|fetch --session S --repo R …' ;; esac
sess='' repo='' key='' win='' epic='' issue='' hist=0 dir='' nohist=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session) sess="${2:-}"; shift 2 ;;
    --repo)    repo="${2:-}"; shift 2 ;;
    --key)     key="${2:-}"; shift 2 ;;
    --win)     win="${2:-}"; shift 2 ;;
    --epic)    epic="${2//[^0-9]/}"; shift 2 ;;
    --issue)   issue="${2//[^0-9]/}"; shift 2 ;;
    --history) hist=1; shift ;;
    --evidence-only) nohist=1; shift ;;
    --dir)     dir="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument $1" ;;
  esac
done
[ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
[ -n "$sess" ] && [ -n "$repo" ] || die 2 'needs --session and --repo'

[ "${FLEET_WORKER_RECORDS:-1}" != 0 ] || exit 3
_fleet_hub_creds_missing >/dev/null && exit 3
CURL=${FLEET_HUB_CURL:-curl}
U=$(fleet_uuid "$sess") || U=''

# hub_call <method> <url-suffix> [<body-file>] → the JSON on stdout; exits with
# this script's code on a non-200.
hub_call() {
  local resp rc code json
  if [ -n "${3:-}" ]; then
    resp=$(_fleet_hub_env
      "$CURL" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -o - -w '\n%{http_code}' \
        -H "Authorization: Bearer $CCQUOTA_TOKEN" -H 'Content-Type: application/json' \
        -X "$1" --data-binary "@$3" "${CCQUOTA_HUB_URL%/}$2" 2>/dev/null); rc=$?
  else
    resp=$(_fleet_hub_env
      "$CURL" -sS --max-time "${FLEET_HUB_TIMEOUT:-5}" -o - -w '\n%{http_code}' \
        -H "Authorization: Bearer $CCQUOTA_TOKEN" -X "$1" "${CCQUOTA_HUB_URL%/}$2" 2>/dev/null); rc=$?
  fi
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable (curl exit $rc)"
  code=$(printf '%s\n' "$resp" | tail -n 1)
  json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200) printf '%s\n' "$json" ;;
    404|405) die 3 'the hub keeps no worker records (it predates #1609)' ;;
    401) case "$json" in *'viewer token'*) die 3 'the hub keeps no worker records (it predates #1609)' ;; esac
         die 1 'the hub does not know this machine'"'"'s node token (401)' ;;
    *) die 1 "the hub refused (HTTP $code): $(printf '%s' "$json" | head -c 300)" ;;
  esac
}

if [ "$cmd" = push ]; then
  [ -n "$key" ] || die 2 'push needs --key <N|scratch-N>'
  [ -n "$U" ] || die 3 "fleet $sess has no fleet UUID on this machine — nothing to key a record on"
  hkey=''
  case "$key" in
    *[!0-9]*) case "$key" in scratch-[1-9]*) hkey=$key ;; *) die 2 "not a key: $key" ;; esac ;;
    *) issue=$key; hkey="issue-$key" ;;
  esac
  wid='' owid=''
  if [ -n "$win" ]; then
    wid=$(fleet_worker_id "$sess" "$win" 2>/dev/null) || wid=''
    owid=$(_fleet_tmux "$sess" show-options -wqv -t "$win" @origin_wid 2>/dev/null) || owid=''
  fi
  [ -n "$wid" ] || wid="$U/$hkey"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fleet-wr.XXXXXX") || die 1 'mktemp failed'
  trap 'rm -rf "$tmp"' EXIT
  : > "$tmp/ev"
  if [ -n "$issue" ]; then
    bash "$BIN/fleet-evidence.sh" list --session "$sess" --repo "$repo" --issue "$issue" > "$tmp/ev" 2>/dev/null || :
  fi
  : > "$tmp/row"
  [ "$nohist" = 1 ] || bash "$BIN/fleet-history.sh" row --repo "$repo" "$key" > "$tmp/row" 2>/dev/null || :
  python3 - "$tmp" "$wid" "$owid" "$repo" "${issue:-0}" "$hkey" "${FLEET_WORKER_RECORDS_IMG_MAX:-614400}" <<'PY' > "$tmp/body.json" || exit 3
import base64, json, os, re, shutil, subprocess, sys
tmp, wid, owid, repo, issue, key, imgmax = sys.argv[1:8]
imgmax, cap = int(imgmax), 2 << 20
epic, recs = 0, []
def safe(n):
    n = re.sub(r'[^A-Za-z0-9._+=@,-]', '_', n).lstrip('._') or 'capture'
    return n[:200]
for line in open(os.path.join(tmp, 'ev'), encoding='utf-8', errors='replace'):
    line = line.rstrip('\n')
    if line.startswith('#'):
        m = re.search(r'epic (\d+)', line)
        if m: epic = int(m.group(1))
        continue
    f = line.split('\t')
    if len(f) < 5 or f[1] == 'none' or not f[3] or not os.path.isfile(f[3]):
        continue
    m = re.search(r'/epic/(\d+)/evidence/', f[3])
    if m: epic = int(m.group(1))
    path, name = f[3], os.path.basename(f[3])
    data = open(path, 'rb').read()
    ext = name.rsplit('.', 1)[-1].lower() if '.' in name else ''
    if ext in ('png', 'jpg', 'jpeg', 'gif', 'heic', 'tiff', 'bmp', 'webp') and len(data) > imgmax and shutil.which('sips'):
        out = os.path.join(tmp, 'shrunk.jpg')
        if subprocess.run(['sips', '-Z', '1600', '-s', 'format', 'jpeg', '-s', 'formatOptions', '70', path, '--out', out],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0 and os.path.isfile(out):
            data = open(out, 'rb').read(); os.remove(out)
            if ext not in ('jpg', 'jpeg'): name += '.jpg'
    if len(data) > cap:
        try:
            data.decode('utf-8')
            data = data[:cap - 64] + b'\n... [cut at 2 MiB for the hub]\n'
        except UnicodeDecodeError:
            sys.stderr.write('fleet-worker-records: %s is over 2 MiB even shrunk — left on this machine\n' % path)
            continue
    recs.append({'kind': 'evidence', 'name': safe(name), 'stage': f[1], 'ts': f[2],
                 'note': f[4] if len(f) > 4 else '', 'content': base64.b64encode(data).decode()})
row = open(os.path.join(tmp, 'row'), 'rb').read().strip(b'\n')
if row:
    st = row.split(b'\t')[9].decode('utf-8', 'replace') if row.count(b'\t') >= 9 else 'landed'
    recs.append({'kind': 'history', 'name': 'ledger', 'stage': st or 'landed',
                 'content': base64.b64encode(row + b'\n').decode()})
if not recs:
    sys.exit(1)
body = {'worker_id': wid, 'repo': repo, 'issue': int(issue), 'key': key, 'epic': epic, 'records': recs}
if owid: body['origin_wid'] = owid
json.dump(body, sys.stdout)
PY
  out=$(hub_call POST /v1/node/worker-records "$tmp/body.json") || exit $?
  n=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stored",0))' 2>/dev/null)
  printf 'pushed %s record(s) for %s as %s\n' "${n:-?}" "$hkey" "$wid"
  exit 0
fi

# ---- fetch -------------------------------------------------------------------
q="repo=$repo"
if [ -n "$epic" ]; then q="$q&epic=$epic"
elif [ -n "$issue" ]; then q="$q&issue=$issue"
elif [ "$hist" = 1 ]; then q="$q&kind=history"
else die 2 'fetch needs --epic, --issue or --history'; fi
[ "$hist" = 1 ] && [ -n "$epic$issue" ] && q="$q&kind=history"
[ -n "$dir" ] || dir="$FLEET_CONF_DIR/fleets/$sess/remote/$(fleet_slug "$repo")"
json=$(hub_call GET "/v1/node/worker-records?$q") || exit $?
printf '%s' "$json" | python3 -c '
import base64, json, os, sys
own, root = sys.argv[1], sys.argv[2]
def one(s): return str(s or "").replace("\t", " ").replace("\n", " ")
for r in json.load(sys.stdin).get("records") or []:
    if own and r.get("fleet_id") == own:
        continue
    node, data = one(r.get("node")) or "?", base64.b64decode(r.get("content") or "")
    tag = str(r.get("issue") or "") or one(r.get("key"))
    if r.get("kind") == "history":
        row = data.decode("utf-8", "replace").strip("\n")
        if row: print("history\t%s\t%s\t%s" % (tag, node, row))
        continue
    if not r.get("issue"): continue
    d = os.path.join(root, str(r["issue"]))
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, os.path.basename(r["name"]))
    with open(p, "wb") as f: f.write(data)
    print("evidence\t%s\t%s\t%s\t%s\t%s\t%s" % (r["issue"], one(r.get("stage")), one(r.get("ts")), p, one(r.get("note")), node))
' "$U" "$dir"
