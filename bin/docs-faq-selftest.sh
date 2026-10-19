#!/bin/bash
# docs-faq-selftest.sh — the FAQ's one source and the troubleshooting page's row
# coverage (issue #3582, EPIC #3569 C12).
#
#   A  every row `fleet doctor` / `fleet doctor --machine` can print (read off
#      bin/fleet-doctor.sh + bin/fleet-node-update.py by bin/fleet-doctor-rows.py)
#      has its `#### `<row>`` section on docs/public/zh/troubleshooting.md, none a
#      skeleton, none for a row the doctor no longer prints — and on its English
#      twin docs/public/en/troubleshooting.md the same (issue #3592)
#   B  in a sandbox doctor: a new row reds page-check and page-skeleton prints its
#      section; a 「待写」 skeleton reds; a section for a gone row reds
#   C  bin/docs-faq.py check passes for zh and en; both mark the same number of
#      site questions
#   D  the docs build's faq.json is docs-faq.py json word for word, and the built
#      faq page carries every site question + answer word for word (check-html);
#      a page with one answer changed is refused
#   E  docs-faq.py check refuses a site answer of two paragraphs and a question
#      with no answer
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROWS="$ROOT/bin/fleet-doctor-rows.py"
FAQ="$ROOT/bin/docs-faq.py"
PAGE="$ROOT/docs/public/zh/troubleshooting.md"
PAGE_EN="$ROOT/docs/public/en/troubleshooting.md"
T="$(mktemp -d "${TMPDIR:-/tmp}/docs-faq-st.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# A
if out="$(python3 "$ROWS" page-check "$PAGE" --root "$ROOT" 2>&1)"; then
  ok "A troubleshooting covers all $(python3 "$ROWS" names --root "$ROOT" | wc -l | tr -d ' ') doctor rows"
else
  bad "A troubleshooting page vs the doctor's rows:"; printf '%s\n' "$out" | sed 's/^/     /'
fi
if out="$(python3 "$ROWS" page-check "$PAGE_EN" --root "$ROOT" 2>&1)"; then
  ok "A the English troubleshooting page covers them too"
else
  bad "A en/troubleshooting.md vs the doctor's rows (translate the zh sections):"; printf '%s\n' "$out" | sed 's/^/     /'
fi

# B — a sandbox doctor with three rows
mkdir -p "$T/r/bin"
printf 'pass alpha "x"\nwarn beta "y"\n' > "$T/r/bin/fleet-doctor.sh"
printf 'rows.append(("PASS", "gamma", "z"))\n' > "$T/r/bin/fleet-node-update.py"
sec() { printf '#### `%s`\n\n来自 x。\n\n- **是什么**：%s\n- **WARN / FAIL 怎么办**：y\n\n' "$1" "$2"; }
{ echo "# t"; sec alpha a; sec beta b; } > "$T/p1.md"
out="$(python3 "$ROWS" page-check "$T/p1.md" --root "$T/r")"
case "$out" in *"missing section \`gamma\`"*) ok "B a new row reds page-check" ;; *) bad "B new row not caught: $out" ;; esac
python3 "$ROWS" page-skeleton "$T/p1.md" --root "$T/r" | grep -q '^#### `gamma`$' && ok "B page-skeleton prints the new row's section" \
  || bad "B page-skeleton did not print gamma"
{ echo "# t"; sec alpha a; sec beta '（待写）'; sec gamma c; sec delta d; } > "$T/p2.md"
out="$(python3 "$ROWS" page-check "$T/p2.md" --root "$T/r")"; rc=$?
case "$out" in *"\`beta\` is still a skeleton"*"\`delta\` is on the page but"*) [ $rc = 1 ] && ok "B skeleton + gone row red" || bad "B rc $rc" ;;
  *) bad "B skeleton / gone row not caught: $out" ;; esac
# a row only the client-only doctor in bin/fleet prints (issue #4908) is a row too
printf '%s\n' "    printf '  %-4s  %-8s %s\\n' \"\${r%%x}\" epsilon \"\${r#*x}\"" > "$T/r/bin/fleet"
out="$(python3 "$ROWS" page-check "$T/p1.md" --root "$T/r")"
case "$out" in *"missing section \`epsilon\` (client)"*) ok "B a client-only row reds page-check" ;; *) bad "B client row not caught: $out" ;; esac
{ echo "# t"; sec alpha a; sec beta b; sec gamma c; sec epsilon e; } > "$T/p3.md"
python3 "$ROWS" page-check "$T/p3.md" --root "$T/r" >/dev/null && ok "B its section is accepted" || bad "B client section refused"

# C
for l in zh en; do
  out="$(python3 "$FAQ" check --lang $l 2>&1)" && ok "C $l/faq.md checks" || bad "C $l/faq.md: $out"
done
nz=$(python3 "$FAQ" json --lang zh --site | grep -c '"site": true')
ne=$(python3 "$FAQ" json --lang en --site | grep -c '"site": true')
[ "$nz" = "$ne" ] && [ "$nz" -gt 0 ] && ok "C zh and en mark $nz site questions each" || bad "C site questions zh $nz, en $ne"

# D
if "$ROOT/bin/docs-build.sh" --out "$T/out" >/dev/null 2>"$T/build.err"; then
  for l in zh en; do
    python3 "$FAQ" json --lang $l > "$T/want.$l.json"
    cmp -s "$T/want.$l.json" "$T/out/$l/faq.json" && ok "D $l/faq.json = docs-faq.py json" || bad "D $l/faq.json differs"
    out="$(python3 "$FAQ" check-html "$T/out/$l/faq.html" --lang $l)" && ok "D built $l/faq.html carries every site Q+A word for word" \
      || bad "D $l/faq.html: $out"
  done
  a1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["items"][0]["a"])' "$T/want.zh.json")
  python3 - "$T/out/zh/faq.html" "$a1" > "$T/bent.html" <<'PY'
import sys
print(open(sys.argv[1], encoding='utf-8').read().replace(sys.argv[2], sys.argv[2][:-2] + '。'))
PY
  python3 "$FAQ" check-html "$T/bent.html" --lang zh >/dev/null && bad "D a changed answer passed check-html" || ok "D a changed answer is refused"
else
  bad "D docs-build failed: $(cat "$T/build.err")"
fi

# E
mkdir -p "$T/e/zh"
printf '# f\n\n## g\n\n### one?\n<!-- faq: site -->\nfirst.\n\nsecond.\n\n### two?\n\n' > "$T/e/zh/faq.md"
out="$(python3 "$FAQ" check --src "$T/e")"; rc=$?
case "$out" in *"more than one paragraph: one?"*"no answer: two?"*) [ $rc = 1 ] && ok "E two-paragraph site answer + empty answer refused" || bad "E rc $rc" ;;
  *) bad "E not refused: $out" ;; esac

[ "$fail" = 0 ] && echo "PASS docs-faq-selftest" || { echo "FAIL docs-faq-selftest"; exit 1; }
