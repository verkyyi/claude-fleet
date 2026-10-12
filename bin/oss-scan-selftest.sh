#!/bin/bash
# oss-scan-selftest.sh — bin/oss-scan.sh, the internal-name inventory (issue
# #3571, EPIC #3569 C1), on throwaway git repos with a stub gitleaks.
#
#   A  a fake private address in a sandbox repo is reported with its rule id, rc 1
#   B  a kept word (the repo's own name, a placeholder) is no hit; a clean repo rc 0
#   C  conf/oss-scan.allow drops a file:rule; --all shows it as class allow
#   D  the class: a test / a doc / a comment → placeholder, running code → config
#   E  --summary's file count == --files' lines; --inventory has one row a file
#   F  every rule of the real conf/oss-scan.rules compiles in git grep -E and awk
#   G  --history: a stub gitleaks with no finding → rc 0 · "0 处未确认"; one → rc 1
#   H  the repo's .gitleaks.toml confirms each finding by commit + path + rule
#   I  --gate (issue #3572, C2): a PR adding a private address line → red, naming
#      file:line + rule; the same line ending `# oss-ok: <理由>` → green (and counted)
#   J  --gate's baseline: a rule's tree count above conf/oss-scan.baseline → red even
#      with nothing new in the diff; below → green + 「请把 … 调低」; a moved file → green
#   K  --commits <range> hands gitleaks `--log-opts <range>`, rc 1 on a finding
#   L  the real conf/oss-scan.baseline names every rule of conf/oss-scan.rules
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
SCAN="$BIN/oss-scan.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oss-scan-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

T=$(printf '\t')
# a rule table of our own: the machine word is built so this file never holds it
M="lab""host9"
cat > "$WORK/rules" <<EOF
private-ipv4${T}(^|[^0-9.])(10\.[0-9]+|192\.168)\.[0-9]+\.[0-9]+${T}test rule
machine${T}(^|[^A-Za-z0-9_-])(${M})([^A-Za-z0-9_-]|$)${T}test rule
ts-net${T}[A-Za-z0-9][A-Za-z0-9.-]*\.ts\.net${T}test rule
#@keep${T}example.ts.net
EOF
: > "$WORK/allow"

mkrepo() {
    rm -rf "$WORK/repo"; mkdir -p "$WORK/repo"
    git -C "$WORK/repo" init -q
    git -C "$WORK/repo" config user.email t@t; git -C "$WORK/repo" config user.name t
}
commit() { git -C "$WORK/repo" add -A && git -C "$WORK/repo" commit -qm x; }
scan() { "$SCAN" --root "$WORK/repo" --rules "$WORK/rules" --allow "$WORK/allow" "$@"; }

# ---- A ----
mkrepo
mkdir -p "$WORK/repo/lib"
printf 'x = 1\nHOST = "10.1.2.3"\n' > "$WORK/repo/lib/net.py"
commit
out=$(scan); rc=$?
if [ "$rc" = 1 ] && [ "$out" = "lib/net.py:2:private-ipv4:config" ]; then ok A
else bad "A rc=$rc out=$out"; fi

# ---- B ----
mkrepo
printf 'see http://example.ts.net/ and 1.10.0.1.2 is a version\n' > "$WORK/repo/README.md"
commit
out=$(scan); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok B; else bad "B rc=$rc out=$out"; fi

# ---- C ----
mkrepo
printf 'ip 192.168.0.9\n' > "$WORK/repo/notes.md"
commit
printf 'notes.md%sprivate-ipv4%sa reason\n' "$T" "$T" > "$WORK/allow"
out=$(scan); rc=$?
all=$(scan --all)
if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$all" = "notes.md:1:private-ipv4:allow" ]; then ok C
else bad "C rc=$rc out=$out all=$all"; fi
: > "$WORK/allow"

# ---- D ----
mkrepo
mkdir -p "$WORK/repo/bin" "$WORK/repo/docs"
printf '#!/bin/sh\n# runs on %s\nssh %s true\n' "$M" "$M" > "$WORK/repo/bin/run.sh"
printf 'ssh %s true\n' "$M" > "$WORK/repo/bin/run-selftest.sh"
printf 'ssh %s.tail.%s\n' "$M" ts.net > "$WORK/repo/docs/x.md"
commit
out=$(scan | sort)
want=$(printf '%s\n' \
    "bin/run-selftest.sh:1:machine:placeholder" \
    "bin/run.sh:2:machine:placeholder" \
    "bin/run.sh:3:machine:config" \
    "docs/x.md:1:machine:placeholder" \
    "docs/x.md:1:ts-net:placeholder" | sort)
if [ "$out" = "$want" ]; then ok D; else bad "D got:
$out"; fi

# ---- E ----
n=$(scan --summary | sed -n 's/^tree: \([0-9]*\) .*/\1/p')
f=$(scan --files | wc -l | tr -d ' ')
rows=$(scan --inventory | grep -c '^| `')
if [ "$n" = 3 ] && [ "$f" = 3 ] && [ "$rows" = 3 ]; then ok E; else bad "E summary=$n files=$f rows=$rows"; fi

# ---- F ----
bad_rules=""
while IFS="$T" read -r id ere _; do
    case "$id" in ''|'#'*) continue ;; esac
    git -C "$WORK/repo" grep -qE -e "$ere" -- . >/dev/null 2>&1; [ $? -le 1 ] || bad_rules="$bad_rules $id(git)"
    echo x | awk -v e="$ere" '{ if (match($0, e)) {} }' 2>/dev/null || bad_rules="$bad_rules $id(awk)"
    case "$ere" in *'\b'*|*'\d'*|*'\s'*|*'\w'*|*'{'*) bad_rules="$bad_rules $id(syntax)" ;; esac
done < "$BIN/../conf/oss-scan.rules"
nrules=$(grep -c "^[a-z0-9-]*$T" "$BIN/../conf/oss-scan.rules")
if [ -z "$bad_rules" ] && [ "$nrules" -ge 9 ]; then ok F; else bad "F rules=$nrules bad:$bad_rules"; fi

# ---- G ----
mkdir -p "$WORK/stub"
cat > "$WORK/stub/gitleaks" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && out=$2; shift; done
if [ -n "${STUB_FINDING:-}" ]; then
  printf '[{"RuleID":"aws-access-token","Commit":"0123456789abcdef","File":"a.sh","StartLine":3}]' > "$out"
else printf '[]' > "$out"; fi
EOF
chmod +x "$WORK/stub/gitleaks"
s0=$(PATH="$WORK/stub:$PATH" "$SCAN" --root "$WORK/repo" --history --summary); r0=$?
s1=$(STUB_FINDING=1 PATH="$WORK/stub:$PATH" "$SCAN" --root "$WORK/repo" --history); r1=$?
if [ "$r0" = 0 ] && printf '%s' "$s0" | grep -q '^history: 0 处未确认' \
   && [ "$r1" = 1 ] && [ "$s1" = "01234567:a.sh:3:aws-access-token" ]; then ok G
else bad "G r0=$r0 s0=$s0 r1=$r1 s1=$s1"; fi

# ---- H ----
python3 - "$BIN/../.gitleaks.toml" <<'PY' && ok H || bad H
import re, sys
t = open(sys.argv[1]).read()
blocks = t.split("\n[[allowlists]]\n")[1:]
assert "useDefault = true" in t, "default rules off"
assert len(blocks) >= 28, len(blocks)
for b in blocks:
    assert 'condition = "AND"' in b, b
    assert len(re.findall(r'"[0-9a-f]{40}"', b)) == 1, b
    assert re.search(r"paths = \['''\^[^']+\$'''\]", b), b
    assert re.search(r'targetRules = \["[a-z-]+"\]', b), b
    assert "regexes" not in b and "stopwords" not in b, b
PY

# ---- I ----
# A sandbox repo: master holds one allowed-free hit (the baseline), a branch adds.
gate() { "$SCAN" --root "$WORK/repo" --rules "$WORK/rules" --allow "$WORK/allow" --baseline-file "$WORK/base" --gate master; }
mkrepo
git -C "$WORK/repo" symbolic-ref HEAD refs/heads/master
mkdir -p "$WORK/repo/lib"
printf 'OLD = "192.168.7.7"\n' > "$WORK/repo/lib/old.py"
printf 'x = 1\n' > "$WORK/repo/lib/net.py"
commit
"$SCAN" --root "$WORK/repo" --rules "$WORK/rules" --allow "$WORK/allow" --baseline > "$WORK/base"
git -C "$WORK/repo" checkout -qb pr
printf 'x = 1\nHOST = "10.9.8.7"\n' > "$WORK/repo/lib/net.py"
commit
out=$(gate); rc=$?
red_ok=0
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qx 'lib/net.py:2 private-ipv4 — 改成配置项或换成占位，见 docs/dev/OSS-INVENTORY.md' \
    && ! printf '%s\n' "$out" | grep -q 'lib/old.py' && red_ok=1
printf 'x = 1\nHOST = "10.9.8.7"  # oss-ok: 试验网段，文档示例\n' > "$WORK/repo/lib/net.py"
commit
out2=$(gate); rc2=$?
if [ "$red_ok" = 1 ] && [ "$rc2" = 0 ] && printf '%s\n' "$out2" | grep -q '绿.*豁免 1 处' \
   && "$SCAN" --root "$WORK/repo" --rules "$WORK/rules" --allow "$WORK/allow" --summary | grep -q '豁免: *1 处'; then ok I
else bad "I rc=$rc out=$out | rc2=$rc2 out2=$out2"; fi

# ---- J ----
# the baseline says 0 for private-ipv4 while master already holds one: red, though
# the PR's diff adds nothing
git -C "$WORK/repo" checkout -q master
git -C "$WORK/repo" checkout -qb pr2
printf 'y = 2\n' >> "$WORK/repo/lib/net.py"; commit
sed "s/^private-ipv4${T}.*/private-ipv4${T}0/" "$WORK/base" > "$WORK/base.0"; cp "$WORK/base" "$WORK/base.1"
cp "$WORK/base.0" "$WORK/base"; o1=$(gate); r1=$?
# a PR that removes the old hit: green, and asks for the baseline to go down
cp "$WORK/base.1" "$WORK/base"; git -C "$WORK/repo" rm -q lib/old.py; commit
o2=$(gate); r2=$?
# a PR that only moves a file holding a hit: rename detection keeps it green
git -C "$WORK/repo" checkout -q master; git -C "$WORK/repo" checkout -qb pr3
mkdir -p "$WORK/repo/legacy"; git -C "$WORK/repo" mv lib/old.py legacy/old.py; commit
o3=$(gate); r3=$?
if [ "$r1" = 1 ] && printf '%s' "$o1" | grep -q '基线只许降.*private-ipv4 0 → 1' \
   && [ "$r2" = 0 ] && printf '%s' "$o2" | grep -q '降了：private-ipv4 1 → 0' \
   && [ "$r3" = 0 ]; then ok J
else bad "J r1=$r1 o1=$o1 | r2=$r2 o2=$o2 | r3=$r3 o3=$o3"; fi

# ---- K ----
cat > "$WORK/stub/gitleaks" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$STUB_ARGS"
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && out=$2; shift; done
printf '[{"RuleID":"github-pat","Commit":"fedcba9876543210","File":"b.sh","StartLine":1}]' > "$out"
EOF
chmod +x "$WORK/stub/gitleaks"
s1=$(STUB_ARGS="$WORK/args" PATH="$WORK/stub:$PATH" "$SCAN" --root "$WORK/repo" --commits master..pr3); r1=$?
if [ "$r1" = 1 ] && [ "$s1" = "fedcba98:b.sh:1:github-pat" ] && grep -q -- '--log-opts master..pr3' "$WORK/args"; then ok K
else bad "K r1=$r1 s1=$s1 args=$(cat "$WORK/args" 2>/dev/null)"; fi

# ---- L ----
miss=""
while IFS="$T" read -r id ere _; do
    case "$id" in ''|'#'*) continue ;; esac
    grep -q "^${id}${T}[0-9][0-9]*\$" "$BIN/../conf/oss-scan.baseline" || miss="$miss $id"
done < "$BIN/../conf/oss-scan.rules"
if [ -z "$miss" ]; then ok L; else bad "L conf/oss-scan.baseline lacks:$miss"; fi

[ "$fails" = 0 ] && echo "oss-scan-selftest: all passed" || { echo "oss-scan-selftest: $fails failed"; exit 1; }
