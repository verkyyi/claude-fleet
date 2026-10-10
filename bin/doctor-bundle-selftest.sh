#!/usr/bin/env bash
# doctor-bundle-selftest.sh — `fleet doctor --bundle` (issue #2890, EPIC #2889 C1).
#
#   A  conf/secret-shapes.list passes its own rules (fleet_redact.py --lint, the
#      awk copy loads it) and every row is exercised by the corpus below
#   B  bin/fleet_redact.py and bin/fleet-redact.awk write the same bytes, the same
#      --stats and the same --check for the same input
#   C  the node layout: fleet-doctor.sh --bundle in a sandbox HOME planted with ten
#      kinds of fake credential → every file there, manifest.json the contract,
#      each sha256 right, 0 hits, nothing off conf/debug-collect.list read
#   D  the client-only layout: bin/fleet doctor --bundle with no fleet-doctor.sh
#   E  a credential that survives redaction → exit 3, the file named, no bundle
#   F  a rerun replaces its own bundle; a directory that is not one is refused
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/dbundle.XXXXXX")" || exit 2
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
SHAPES="$ROOT/conf/secret-shapes.list"
awkr() { LC_ALL=C awk -v table="$SHAPES" -f "$BIN/fleet-redact.awk" "$@"; }

# the corpus: every kind 共同约定第 1 条 names, the neighbours that must survive,
# a non-ASCII line and a last line with no newline
cat > "$T/corpus" <<'EOF'
plain: desk-session-handoff-notes-and-more task-runner HostKeyAlias=fleet-m5 ConnectTimeout=15
GH ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 and github_pat_11ABCDEFGHIJKLMNOPQRST_xyz
key sk-ant-api03-abcdefghijklmnop more sk-proj-abcdefghijklmnopqrstuvwx
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
-----END OPENSSH PRIVATE KEY----- tail
x -----BEGIN RSA PRIVATE KEY-----abc-----END RSA PRIVATE KEY----- y
> Authorization: Bearer abcdefghijklmnopqrstuvwxyz
curl -H "bearer abcdefghijklmnopqrstuvwxyz0123"
< set-cookie: sid=abc; Path=/
GET https://hub.example/v1/x?a=1&token=deadbeef&sig=zz#frag
export FLEET_HUB_TOKEN="abc def" CCQUOTA_FLEET_DEBUG_KEY=s3cret DB_PASSWORD='p w' OTHER=1
  "token": "hub-secret-value", "url": "https://x"
fleet-debug ticket fdt.abc.def · Authorization: FleetDebug fdt.x
jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig_abc-123 end
AKIAABCDEFGHIJKLMNOP xoxb-1234567890-abc AIzaSyA1234567890abcdefghijklmnopqrstu glpat-abcdefghijklmnopqrstu
üñï ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123ü
-----BEGIN EC PRIVATE KEY-----
unterminated body
EOF
printf 'no newline ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123' >> "$T/corpus"

# --- A ---------------------------------------------------------------------------
if python3 "$BIN/fleet_redact.py" --lint; then ok "A the table passes fleet_redact.py --lint"; else bad "A the table fails its lint"; fi
if printf '' | awkr >/dev/null; then ok "A the awk copy loads the table"; else bad "A the awk copy cannot load the table"; fi
printf 'bad\tvalue\tx^y\n' > "$T/bad.list"
python3 "$BIN/fleet_redact.py" --table "$T/bad.list" --lint 2>/dev/null
[ $? = 2 ] && ok "A a row with ^ is refused (exit 2)" || bad "A a row with ^ was accepted"
python3 "$BIN/fleet_redact.py" --stats "$T/st" < "$T/corpus" > /dev/null
miss=''
while IFS="$(printf '\t')" read -r nm _; do
  case $nm in ''|'#'*) continue ;; esac
  grep -q "^$nm	" "$T/st" || miss="$miss $nm"
done < "$SHAPES"
[ -z "$miss" ] && ok "A every row of the table hits the corpus" || bad "A rows the corpus never exercises:$miss"

# --- B ---------------------------------------------------------------------------
python3 "$BIN/fleet_redact.py" --stats "$T/p.st" < "$T/corpus" > "$T/p.out"
awkr -v stats="$T/a.st" < "$T/corpus" > "$T/a.out"
if cmp -s "$T/p.out" "$T/a.out" && cmp -s "$T/p.st" "$T/a.st"; then ok "B python and awk: the same bytes and the same counts"
else bad "B python and awk differ:"; diff "$T/p.out" "$T/a.out" | head -n 10; diff "$T/p.st" "$T/a.st"; fi
for w in desk-session-handoff-notes-and-more task-runner HostKeyAlias=fleet-m5 OTHER=1 '"url": "https://x"' ' tail' ' y'; do
  grep -qF -e "$w" "$T/p.out" || bad "B over-redacted: [$w] is gone"
done
grep -q 'unterminated' "$T/p.out" && bad "B an unterminated key block leaked" || ok "B an unterminated key block is dropped to the end"
(cd "$T" && python3 "$BIN/fleet_redact.py" --check p.out corpus > p.chk; echo "rc=$?" >> p.chk)
(cd "$T" && awkr -v mode=check p.out corpus > a.chk; echo "rc=$?" >> a.chk)
if cmp -s "$T/p.chk" "$T/a.chk" && grep -q '^rc=1' "$T/p.chk" && ! grep -q '^p.out' "$T/p.chk"; then
  ok "B --check: both copies find the corpus, neither finds its redaction"
else bad "B --check differs or is wrong"; diff "$T/p.chk" "$T/a.chk"; cat "$T/p.chk"; fi

# --- sandbox: ten kinds planted in the whitelisted logs, three files off the list ----
mkhome() {  # mkhome <dir>
  local h="$1/home" lg="$1/home/.cache/claude-fleet/shell/logs"
  mkdir -p "$lg" "$h/.ssh" "$1/conf"
  cp "$T/corpus" "$lg/connect.log"
  printf 'place m5 → refused sk-ant-api03-placeplaceplace\n' > "$lg/place.log"
  printf 'keeper renew ok\n' > "$lg/keeper.log"
  printf 'NOTLISTED_cert\n' > "$h/.ssh/fleet-cert"
  printf '{"token": "NOTLISTED_hubjson"}\n' > "$1/conf/hub.json"
  printf 'FLEET_HUB_TOKEN=NOTLISTED_secrets\n' > "$1/conf/secrets.env"
}
run() {  # run <sandbox> <redactor> <cmd…>
  local sb="$1" r="$2"; shift 2
  ( unset FLEET_HUB_URL https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy
    export HOME="$sb/home" FLEET_CONF_DIR="$sb/conf" TMPDIR="$T" FLEET_BUNDLE_NET=0 \
           HTTPS_PROXY='http://bob:hunter2pw@proxy.corp:8080' NO_PROXY=localhost
    [ "$r" = auto ] || export FLEET_REDACT="$r"
    "$@" )
}
PLANTED='ghp_ABCDEFGHIJ github_pat_11ABC sk-ant-api03 sk-proj- b3BlbnNzaC1 abcdefghijklmnopqrstuvwxyz deadbeef s3cret hub-secret-value fdt.abc eyJhbGci AKIAABCD xoxb- AIzaSy glpat- hunter2pw NOTLISTED_'
leaks() {  # leaks <bundle dir> → the planted words still in it
  local w out=''
  for w in $PLANTED; do grep -rqF -e "$w" "$1" && out="$out $w"; done
  printf '%s' "$out"
}

# --- C: the node layout -------------------------------------------------------------
mkhome "$T/c"
for r in python awk; do
  run "$T/c" "$r" env FLEET_BUNDLE_DOCTOR_CMD="printf '  PASS  tls      ok\n  FAIL  cert     GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123\n    second line\n'; exit 1" \
    sh "$BIN/fleet-doctor.sh" --bundle "$T/c/b-$r" > "$T/c/out-$r" 2>&1
  rc=$?
  [ "$rc" = 0 ] && ok "C[$r] fleet-doctor.sh --bundle → 0 though the doctor FAILed" || { bad "C[$r] exit $rc"; cat "$T/c/out-$r"; continue; }
  b="$T/c/b-$r"
  for f in doctor.txt doctor.json system.txt tools.txt route.txt ssh-v.txt logs/connect.log logs/place.log logs/keeper.log manifest.json; do
    [ -f "$b/$f" ] || bad "C[$r] no $f"
  done
  l=$(leaks "$b"); [ -z "$l" ] && ok "C[$r] none of the planted credentials is in the bundle" || bad "C[$r] left in the bundle:$l"
  [ "$(cd "$b" && find . -type f | sed 's#^\./##' | sort | while IFS= read -r f; do python3 "$BIN/fleet_redact.py" --check "$f"; done)" = '' ] \
    && ok "C[$r] the whole bundle scans clean" || bad "C[$r] the table still finds something in the bundle"
  grep -q 'HTTPS_PROXY  已设置 proxy.corp:8080' "$b/route.txt" && ok "C[$r] a proxy is told by host:port only" || bad "C[$r] route.txt: $(grep PROXY "$b/route.txt" | head -n 2)"
  [ ! -e "$b/logs/login.log" ] && ok "C[$r] a missing source is not invented" || bad "C[$r] logs/login.log appeared"
  python3 - "$b" "$r" <<'PY' && ok "C[$r] manifest.json: the contract, every sha256 right, missing listed" || bad "C[$r] manifest.json is wrong"
import hashlib, json, os, sys
b, r = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(b, "manifest.json")))
assert m["v"] == 1 and m["collected_at"].endswith("Z") and m["client_version"] and m["redactor"] == r, m
assert m["doctor_rc"] == 1
paths = {f["path"] for f in m["files"]}
assert {"doctor.txt", "system.txt", "tools.txt", "route.txt", "ssh-v.txt", "logs/connect.log", "doctor.json"} <= paths, paths
for f in m["files"]:
    assert hashlib.sha256(open(os.path.join(b, f["path"]), "rb").read()).hexdigest() == f["sha256"], f
assert [x["path"] for x in m["missing"]] == ["logs/login.log"], m["missing"]
rd = m["redactions"]
assert rd["total"] == sum(f["redactions"] for f in m["files"]) == sum(rd["by_shape"].values()) > 10, rd
j = json.load(open(os.path.join(b, "doctor.json")))
assert j["rc"] == 1 and j["fails"] == 1 and j["rows"][1]["row"] == "cert" and "second line" in j["rows"][1]["msg"], j
PY
  grep -q '去掉了 [0-9]* 处密码或令牌' "$T/c/out-$r" && grep -q '没有的：logs/login.log' "$T/c/out-$r" \
    && ok "C[$r] it says what it took and how many it removed" || { bad "C[$r] the summary"; cat "$T/c/out-$r"; }
done
cmp -s "$T/c/b-python/logs/connect.log" "$T/c/b-awk/logs/connect.log" && cmp -s "$T/c/b-python/doctor.txt" "$T/c/b-awk/doctor.txt" \
  && ok "C the two redactors' bundles agree file for file" || bad "C python and awk bundles differ"

# --- D: the client-only layout ---------------------------------------------------------
mkhome "$T/d"; mkdir -p "$T/d/root/bin" "$T/d/root/conf"
for f in fleet fleet-doctor-bundle.sh fleet_redact.py fleet-redact.awk; do cp "$BIN/$f" "$T/d/root/bin/"; done
cp "$ROOT/conf/secret-shapes.list" "$ROOT/conf/debug-collect.list" "$T/d/root/conf/"
printf '#!/bin/sh\n[ "$1" = doctor ] && printf "PASS\\tclient stub ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123\\n"\n' > "$T/d/root/bin/fleet-client-update.sh"
chmod +x "$T/d/root/bin/"*
run "$T/d" auto sh "$T/d/root/bin/fleet" doctor --bundle "$T/d/b" > "$T/d/out" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q 'PASS  fleet    client stub <redacted:github-token>' "$T/d/b/doctor.txt" \
   && grep -q '"source": "fleet doctor (client)"' "$T/d/b/manifest.json" && [ -z "$(leaks "$T/d/b")" ]; then
  ok "D bin/fleet doctor --bundle with only the client: the client's doctor, redacted"
else bad "D client-only (exit $rc)"; cat "$T/d/out"; cat "$T/d/b/doctor.txt" 2>/dev/null; fi

# --- E: something survives → exit 3, no bundle --------------------------------------------
mkhome "$T/e"; mkdir -p "$T/e/root/bin" "$T/e/root/conf"
for f in fleet-doctor.sh fleet-doctor-bundle.sh fleet-redact.awk; do cp "$BIN/$f" "$T/e/root/bin/"; done
cp "$ROOT/conf/secret-shapes.list" "$ROOT/conf/debug-collect.list" "$T/e/root/conf/"
cat > "$T/e/root/bin/fleet_redact.py" <<EOF
import sys
if "--check" in sys.argv:
    sys.argv[0] = "$BIN/fleet_redact.py"; exec(open("$BIN/fleet_redact.py").read())
sys.stdout.buffer.write(sys.stdin.buffer.read())
EOF
run "$T/e" python env FLEET_BUNDLE_DOCTOR_CMD='echo doctor' sh "$T/e/root/bin/fleet-doctor.sh" --bundle "$T/e/b" > "$T/e/out" 2>&1
rc=$?
if [ "$rc" = 3 ] && [ ! -e "$T/e/b" ] && grep -q 'logs/connect.log' "$T/e/out" && ! find "$T/e" -maxdepth 1 -name 'b.tmp*' | grep -q .; then
  ok "E a credential past redaction: exit 3, logs/connect.log named, nothing written"
else bad "E (exit $rc)"; cat "$T/e/out"; ls "$T/e"; fi

# --- F: rerun, and a directory that is not a bundle ---------------------------------------
run "$T/c" python env FLEET_BUNDLE_DOCTOR_CMD='echo again' sh "$BIN/fleet-doctor.sh" --bundle "$T/c/b-python" >/dev/null 2>&1 \
  && grep -qx again "$T/c/b-python/doctor.txt" && ok "F a rerun replaces its own bundle" || bad "F the rerun"
mkdir -p "$T/f/mine"; echo keep > "$T/f/mine/notes.txt"
run "$T/c" python env FLEET_BUNDLE_DOCTOR_CMD='echo x' sh "$BIN/fleet-doctor.sh" --bundle "$T/f/mine" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && [ "$(cat "$T/f/mine/notes.txt")" = keep ] && ok "F someone else's directory is refused (exit 2), untouched" || bad "F (exit $rc)"

if [ "$fails" -gt 0 ]; then printf 'doctor-bundle selftest: %d FAILED\n' "$fails" >&2; exit 1; fi
echo "doctor-bundle selftest: OK"
