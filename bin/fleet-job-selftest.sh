#!/bin/bash
# fleet-job-selftest.sh — `fleet job` (bin/fleet-job.sh + bin/fleet_job.py) and
# what runs inside the Job (bin/fleet-job-runner.sh), issue #3552 (EPIC #3500
# C7). No network, no cluster: the hub is FLEET_HUB_CURL, a stub that serves the
# runner's REAL log back in small chunks; the git mirror is a local repo.
#
#   A  the runner: the commit fetched from the mirror, the command run in it, its
#      $FLEET_JOB_OUT packed into one marked block, `exit N` last, its own exit N;
#      a commit the mirror lacks → exit 90.
#   B  run: POST /v1/node/jobs with repo · HEAD · kind · cmd, the token on curl's
#      -K stdin (never argv); the log printed without the block, the block
#      unpacked into .fleet-job/<job>/ (git-excluded), the Job's exit returned —
#      the block split across the hub's chunks.
#   C  no node token → exit 3, nothing sent; an unpushed HEAD → exit 2, nothing
#      sent; a bad --kind → exit 2.
#   D  status / logs: the state; the log from the start without waiting.
#   E  an outputs tar reaching out of its directory is never written outside it.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
FAIL=0 CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$1"; }

st_sandbox "${TMPDIR:-/tmp}/fjob.XXXXXX"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 CCQUOTA_NODE_KEY=off FLEET_JOB_POLL=0
mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE CCQUOTA_TOKEN CCQUOTA_HUB_URL
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# the repo on "GitHub" (also the mirror) and the session's clone of it
gitq init -q "$WORK/origin"
( cd "$WORK/origin" && echo one > a.txt && gitq add a.txt && gitq commit -qm one )
gitq clone -q "$WORK/origin" "$WORK/wt" 2>/dev/null
REF=$(git -C "$WORK/wt" rev-parse HEAD)

# --- A: the runner ---------------------------------------------------------
LOG="$WORK/job.log"
FLEET_JOB_WORK="$WORK/w1" FLEET_JOB_MIRROR="$WORK/origin" FLEET_JOB_REF="$REF" FLEET_JOB_REPO=o/r \
  FLEET_JOB_KIND=test FLEET_JOB_CMD='cat a.txt; mkdir -p "$FLEET_JOB_OUT/d"; echo built > "$FLEET_JOB_OUT/d/r.txt"; exit 3' \
  sh "$BIN/fleet-job-runner.sh" > "$LOG" 2>&1; rc=$?
if [ "$rc" = 3 ] && grep -qx one "$LOG" && grep -q '^::fleet-job:: artifacts [0-9]' "$LOG" \
   && grep -qx '::fleet-job:: artifacts-end' "$LOG" && [ "$(tail -n 1 "$LOG")" = '::fleet-job:: exit 3' ]; then
  ok "A runner: fetched, ran in the checkout, outputs in one block, exit 3 last and as its own"
else
  st_miss "A runner: rc=$rc"; cat "$LOG"
fi
FLEET_JOB_WORK="$WORK/w2" FLEET_JOB_MIRROR="$WORK/origin" FLEET_JOB_REF="$(printf 'f%.0s' $(seq 1 40))" \
  FLEET_JOB_CMD=true sh "$BIN/fleet-job-runner.sh" > "$WORK/miss.log" 2>&1; rc=$?
if [ "$rc" = 90 ] && grep -q 'not on the mirror' "$WORK/miss.log"; then
  ok "A runner: a commit the mirror lacks → exit 90, said"
else
  st_miss "A runner on a missing commit: rc=$rc"; cat "$WORK/miss.log"
fi

# --- the hub ---------------------------------------------------------------
# POST → the Job's name; GET ?offset=N → $SERVE from N, CHUNK bytes at a time,
# state succeeded once all of it was served.
cat > "$WORK/curl" <<'EOF'
#!/bin/bash
cfg=$(cat); body='' method=GET url=''
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case ${args[$i]} in
    --data-binary) body=${args[$((i + 1))]} ;;
    -X) method=${args[$((i + 1))]} ;;
  esac
  url=${args[$i]}; i=$((i + 1))
done
{ printf 'argv: %s\n' "$*"; printf 'stdin: %s\n' "$cfg"; printf 'body: %s %s %s\n' "$method" "$url" "$body"; } >> "$CURL_LOG"
if [ "$method" = POST ]; then
  printf '{"job":"job-0123456789ab","cluster":"c1","kind":"test"}\n200'; exit 0
fi
case $url in *'?offset='*) off=${url##*=} ;; *) off=0 ;; esac
python3 - "$SERVE" "$off" "${CHUNK:-64}" <<'PY'
import json, sys
data = open(sys.argv[1]).read()
off, n = int(sys.argv[2]), int(sys.argv[3])
chunk = data[off:off + n]
state = 'succeeded' if off + len(chunk) >= len(data) else 'running'
print(json.dumps({'job': 'job-0123456789ab', 'state': state, 'log': chunk, 'offset': off + len(chunk)}))
sys.stdout.write('200')
PY
EOF
chmod +x "$WORK/curl"
export FLEET_HUB_CURL="$WORK/curl" CURL_LOG="$WORK/curl.log" SERVE="$LOG"
: > "$CURL_LOG"

# --- C: refusals before anything is sent ------------------------------------
( cd "$WORK/wt" && "$BIN/fleet-job.sh" run --repo o/r -- make test ) > "$WORK/c.out" 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -s "$CURL_LOG" ] && ok "C no node token → exit 3, nothing sent" || { st_miss "C no token: rc=$rc"; cat "$WORK/c.out"; }
printf 'CCQUOTA_TOKEN=tok-secret-1\nCCQUOTA_HUB_URL=https://hub.example\n' > "$FLEET_CONF_DIR/node.env"
( cd "$WORK/wt" && "$BIN/fleet-job.sh" run --kind root --repo o/r -- make test ) > "$WORK/c.out" 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -s "$CURL_LOG" ] && ok "C a bad --kind → exit 2, nothing sent" || { st_miss "C bad kind: rc=$rc"; cat "$WORK/c.out"; }
( cd "$WORK/wt" && echo two > b.txt && gitq add b.txt && gitq commit -qm two \
  && "$BIN/fleet-job.sh" run --repo o/r -- make test ) > "$WORK/c.out" 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$CURL_LOG" ] && grep -q 'push it first' "$WORK/c.out"; then
  ok "C an unpushed HEAD → exit 2 (push it first), nothing sent"
else
  st_miss "C unpushed: rc=$rc"; cat "$WORK/c.out"
fi
git -C "$WORK/wt" reset -q --hard "$REF"

# --- B: run, follow, unpack -------------------------------------------------
( cd "$WORK/wt" && CHUNK=50 "$BIN/fleet-job.sh" run --kind untrusted --repo o/r -- 'make test' ) \
  > "$WORK/b.out" 2> "$WORK/b.err"; rc=$?
post=$(grep '^body: POST' "$CURL_LOG")
if [ "$rc" = 3 ] && printf '%s' "$post" | grep -q '"kind": "untrusted"' && printf '%s' "$post" | grep -q "\"ref\": \"$REF\"" \
   && printf '%s' "$post" | grep -q '/v1/node/jobs ' && printf '%s' "$post" | grep -q '"cmd": "make test"'; then
  ok "B run: POST /v1/node/jobs with repo · HEAD · kind · cmd; the Job's exit 3 returned"
else
  st_miss "B run: rc=$rc post=$post"; cat "$WORK/b.out" "$WORK/b.err"
fi
if grep -q 'tok-secret-1' "$CURL_LOG" && ! grep '^argv:' "$CURL_LOG" | grep -q 'tok-secret-1'; then
  ok "B the token rides curl's -K stdin, never its argv"
else
  st_miss "B the token's road"; grep '^argv:' "$CURL_LOG" | head -3
fi
if grep -qx one "$WORK/b.out" && grep -qx '::fleet-job:: exit 3' "$WORK/b.out" \
   && ! grep -q 'artifacts\|^H4sI' "$WORK/b.out" \
   && [ "$(cat "$WORK/wt/.fleet-job/job-0123456789ab/d/r.txt" 2>/dev/null)" = built ]; then
  ok "B the log printed without the block; the block (split over 50-byte chunks) unpacked into .fleet-job/<job>/"
else
  st_miss "B output"; cat "$WORK/b.out"; find "$WORK/wt/.fleet-job" 2>/dev/null
fi
if grep -qx '.fleet-job/' "$WORK/wt/.git/info/exclude" && [ -z "$(git -C "$WORK/wt" status --porcelain)" ]; then
  ok "B .fleet-job/ is excluded: the worktree stays clean"
else
  st_miss "B exclude"; git -C "$WORK/wt" status --porcelain
fi

# --- D: status / logs -------------------------------------------------------
st=$(cd "$WORK/wt" && CHUNK=100000 "$BIN/fleet-job.sh" status job-0123456789ab 2>/dev/null)
[ "$st" = 'job-0123456789ab succeeded' ] && ok "D status: the state" || st_miss "D status: $st"
rm -rf "$WORK/wt/.fleet-job"
( cd "$WORK/wt" && CHUNK=40 "$BIN/fleet-job.sh" logs job-0123456789ab ) > "$WORK/d.out" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -qx one "$WORK/d.out" && [ -f "$WORK/wt/.fleet-job/job-0123456789ab/d/r.txt" ]; then
  ok "D logs: the whole log from the start, the outputs with it"
else
  st_miss "D logs: rc=$rc"; cat "$WORK/d.out"
fi

# --- E: a hostile outputs tar ------------------------------------------------
python3 - "$WORK/evil.log" <<'PY'
import base64, io, sys, tarfile
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w:gz') as t:
    for name, data in (('../escaped.txt', b'x'), ('ok.txt', b'y')):
        info = tarfile.TarInfo(name); info.size = len(data); t.addfile(info, io.BytesIO(data))
    link = tarfile.TarInfo('lnk'); link.type = tarfile.SYMTYPE; link.linkname = '/etc/passwd'; t.addfile(link)
b = base64.b64encode(buf.getvalue()).decode()
open(sys.argv[1], 'w').write('::fleet-job:: artifacts %d\n%s\n::fleet-job:: artifacts-end\n::fleet-job:: exit 0\n' % (len(buf.getvalue()), b))
PY
( cd "$WORK/wt" && SERVE="$WORK/evil.log" CHUNK=100000 "$BIN/fleet-job.sh" logs job-0123456789ab ) > /dev/null 2>&1
if [ ! -e "$WORK/wt/.fleet-job/escaped.txt" ] && [ ! -e "$WORK/wt/.fleet-job/job-0123456789ab/lnk" ] \
   && [ -f "$WORK/wt/.fleet-job/job-0123456789ab/ok.txt" ]; then
  ok "E outputs: a path out of the directory and a symlink are dropped, a plain file kept"
else
  st_miss "E hostile tar"; find "$WORK/wt/.fleet-job"
fi

printf '\n%d checks, %d failed\n' "$CHECKS" "$FAIL"
st_done
