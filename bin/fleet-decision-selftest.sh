#!/bin/bash
# fleet-decision-selftest.sh — the decision format (issue #2669, EPIC #2668 C1):
# bin/fleet_decision.py is the one reader / writer; docs/DECISIONS.md the spec.
#
#   A  an ask with a suggestion → one row: item · suggest · default · due · src · kind
#   B  `due --apply` past the deadline → ONE --to-worker answer on the worker's
#      issue + ONE 「默认拍板」 on its parent; a second pass posts nothing
#   C  a never row (declared, or caught by a keyword — one per class) is not due,
#      and apply refuses it even when handed it directly
#   D  an old ask (no field, no marker) still reads as a row that waits: 「等你」
#   E  the deadline: 4h default, a duration, a night ask / a night deadline → 09:00
#   F  a human reply / a direct-route 「决定」 answers a row; a worker's own note does not
#   G  render --demo: the table + the fleet:decision marker
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
PY="$BIN/fleet_decision.py"
[ -f "$PY" ] || { echo "selftest: fleet_decision.py missing" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-decision.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
export FLEET_UI_LANG=zh FLEET_DECISION_TZ=Asia/Shanghai FLEET_CONF_DIR="$WORK/conf"
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
d() { python3 "$PY" "$@"; }

# A fake GitHub: one JSON file of comments per issue, posts appended to it.
mkdir -p "$WORK/gh"
cat > "$WORK/comments" <<'SH'
#!/bin/sh
f="$GHDIR/$(printf '%s' "$1" | tr / _)#$2.json"; [ -f "$f" ] && cat "$f" || echo '[]'
SH
cat > "$WORK/post" <<'SH'
#!/bin/sh
f="$GHDIR/$(printf '%s' "$1" | tr / _)#$2.json"; body=$(cat)
printf '%s\t%s#%s\n' "$3" "$1" "$2" >> "$GHDIR/posts"
python3 - "$f" "$1" "$2" "$body" <<'P'
import json, os, sys
f, repo, n, body = sys.argv[1:]
c = json.load(open(f)) if os.path.exists(f) else []
c.append({"body": body + "\n\n<!-- fleet:from role=steward -->", "createdAt": "2026-10-09T12:00:00Z",
          "url": "https://github.com/%s/issues/%s#issuecomment-%d" % (repo, n, 900 + len(c))})
json.dump(c, open(f, "w"), ensure_ascii=False)
P
echo "https://github.com/$1/issues/$2#issuecomment-new"
SH
cat > "$WORK/parent" <<'SH'
#!/bin/sh
[ "$2" = 501 ] || [ "$2" = 502 ] && echo "acme/app#500"
exit 0
SH
chmod +x "$WORK/comments" "$WORK/post" "$WORK/parent"
export GHDIR="$WORK/gh" FLEET_DECISION_COMMENTS_CMD="$WORK/comments" FLEET_DECISION_POST_CMD="$WORK/post" \
       FLEET_DECISION_PARENT_CMD="$WORK/parent"
# seed <issue> <body> — the worker's own ⛔ comment, as fleet-comment.sh posts it
seed() {
  python3 - "$GHDIR/acme_app#$1.json" "$1" "$2" <<'P'
import json, os, sys
f, n, body = sys.argv[1:]
c = json.load(open(f)) if os.path.exists(f) else []
c.append({"body": body + "\n\n<!-- fleet:from role=worker issue=%s -->\n<!-- fleet:no-relay -->" % n,
          "createdAt": "2026-10-09T02:00:00Z",
          "url": "https://github.com/acme/app/issues/%s#issuecomment-%d" % (n, 100 + len(c))})
json.dump(c, open(f, "w"), ensure_ascii=False)
P
}
NOW=2026-10-09T10:00:00+08:00

# --- A ---------------------------------------------------------------------------
seed 501 "$(d ask-body --question '试水名单先发 20 家还是 50 家？' --suggest '20 家' --now "$NOW")"
d parse --repo acme/app --issue 501 > "$WORK/a" || fail "A: parse failed"
python3 - "$WORK/a" <<'P' || fail "A: the row is wrong" "$(cat "$WORK/a")"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert len(rows) == 1, rows
r = rows[0]
assert (r["item"], r["suggest"], r["default"], r["kind"], r["state"]) == \
       ("试水名单先发 20 家还是 50 家？", "20 家", "20 家", "normal", "open"), r
assert r["due"] == "2026-10-09T14:00:00+08:00", r
assert r["src"] == "gh:acme/app#501" and r["url"].endswith("#issuecomment-100"), r
P
ok "A an ask with a suggestion → one row (default = the suggestion, due 4h, src gh:acme/app#501 + its URL)"

# --- B ---------------------------------------------------------------------------
seed 502 "$(d ask-body --question '要不要开一台云机器跑抓取？' --suggest '不开' --class normal --now "$NOW")"
d due --repo acme/app --issue 501 --issue 502 --now 2026-10-09T13:59:00+08:00 > "$WORK/b0"
[ ! -s "$WORK/b0" ] || fail "B: a row was due before its deadline" "$(cat "$WORK/b0")"
d due --repo acme/app --issue 501 --issue 502 --now 2026-10-09T14:01:00+08:00 --apply > "$WORK/b1" \
  || fail "B: apply failed" "$(cat "$WORK/b1")"
[ "$(cat "$GHDIR/posts")" = "$(printf 'to-worker\tacme/app#501\nnote\tacme/app#500')" ] \
  || fail "B: want one to-worker answer on #501 and one note on the parent #500" "$(cat "$GHDIR/posts")"
grep -q 'fleet:answer row=.* by=default' "$GHDIR/acme_app#501.json" || fail "B: the answer carries no fleet:answer marker"
grep -q 'fleet:default-decided row=' "$GHDIR/acme_app#500.json" || fail "B: the parent record carries no marker"
grep -q '默认拍板' "$GHDIR/acme_app#500.json" || fail "B: the parent record does not say 默认拍板"
d due --repo acme/app --issue 501 --issue 502 --now 2026-10-10T14:01:00+08:00 --apply > "$WORK/b2"
[ "$(wc -l < "$GHDIR/posts" | tr -d ' ')" = 2 ] || fail "B: a second pass posted again" "$(cat "$GHDIR/posts")"
d parse --repo acme/app --issue 501 | grep -q '"state": "defaulted"' || fail "B: the answered row does not read defaulted"
ok "B past the deadline: one --to-worker answer + one 默认拍板 on the parent; a second pass posts nothing"

# --- C ---------------------------------------------------------------------------
grep -q 'acme/app#502' "$GHDIR/posts" && fail "C: a money question (declared normal) was defaulted"
for q in 'rule|改一下 CLAUDE.md 里的约定吗？' 'money|这个月预算加 200 刀付费吗？' 'publish|合并后 move stable 吗？'; do
  k=$(d ask-body --question "${q#*|}" --suggest 是 --class normal --now "$NOW" | sed -n 's/.* kind=\([^ ]*\) .*/\1/p')
  [ "$k" = "never%3A${q%%|*}" ] || fail "C: '${q#*|}' read kind=$k, want never:${q%%|*}"
done
k=$(d ask-body --question '换个名字？' --suggest 好 --class never:publish --now "$NOW" | sed -n 's/.* kind=\([^ ]*\) .*/\1/p')
[ "$k" = "never%3Apublish" ] || fail "C: a declared never:publish read $k"
d ask-body --question '要不要开一台云机器？' --suggest 开 --now "$NOW" | grep -q '截止' && fail "C: a never question still names a deadline it will not keep"
python3 - "$PY" <<'P' || fail "C: apply defaulted a never row handed to it directly"
import importlib.util, sys
s = importlib.util.spec_from_file_location("fd", sys.argv[1]); fd = importlib.util.module_from_spec(s); s.loader.exec_module(fd)
r = fd.apply_due({"id": "x", "kind": "never:money", "default": "开", "src": "gh:acme/app#502", "due": "2026-10-09T00:00:00+08:00"})
assert r == {"id": "x", "skipped": "never"}, r
P
ok "C never rows (declared, or a keyword — rule · money · publish) are never due, and apply refuses one"

# --- D ---------------------------------------------------------------------------
seed 503 '⛔ blocked: which repo owns this?'
d parse --repo acme/app --issue 503 > "$WORK/d"
python3 - "$WORK/d" <<'P' || fail "D: an old ask is not a waiting row" "$(cat "$WORK/d")"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert len(r) == 1 and r[0]["default"] == "" and r[0]["state"] == "open" and r[0]["id"].startswith("legacy-"), r
P
d due --repo acme/app --issue 503 --now 2027-01-01T00:00:00+08:00 | grep -q . && fail "D: an old ask came due"
d render --rows "$WORK/d" | grep -q '| 等你 |' || fail "D: an old ask's row does not read 等你" "$(d render --rows "$WORK/d")"
ok "D an old ask (no field, no marker) reads as a row 「等你」 and never comes due"

# --- E ---------------------------------------------------------------------------
python3 - "$PY" <<'P' || fail "E: the deadline rule"
import importlib.util, sys
s = importlib.util.spec_from_file_location("fd", sys.argv[1]); fd = importlib.util.module_from_spec(s); s.loader.exec_module(fd)
t = fd.parse_time
for asked, given, want in (("2026-10-09T10:00:00+08:00", None, "2026-10-09T14:00:00+08:00"),
                           ("2026-10-09T10:00:00+08:00", "90m", "2026-10-09T11:30:00+08:00"),
                           ("2026-10-09T20:00:00+08:00", None, "2026-10-10T09:00:00+08:00"),
                           ("2026-10-09T23:30:00+08:00", "30m", "2026-10-10T09:00:00+08:00"),
                           ("2026-10-09T02:00:00+08:00", None, "2026-10-09T09:00:00+08:00"),
                           ("2026-10-09T10:00:00+08:00", "2026-10-09T12:00:00+08:00", "2026-10-09T12:00:00+08:00")):
    got = fd.iso(fd.due_at(t(asked), given))
    assert got == want, (asked, given, got, want)
P
ok "E deadline: 4h default · a duration · an explicit time · a night ask or a night deadline → 09:00"

# --- F ---------------------------------------------------------------------------
python3 - "$PY" <<'P' || fail "F: who answers a row"
import importlib.util, sys
s = importlib.util.spec_from_file_location("fd", sys.argv[1]); fd = importlib.util.module_from_spec(s); s.loader.exec_module(fd)
ask, _ = fd.ask_body("q?", "yes", now="2026-10-09T10:00:00+08:00")
fleet = "\n<!-- fleet:from role=worker -->"
def state(*later):
    cs = [{"body": ask + fleet, "url": "https://github.com/a/b/issues/1#c1"}] + [{"body": b} for b in later]
    return fd.parse_comments(cs)[0]["state"]
assert state() == "open"
assert state("note: still working" + fleet) == "open"            # the worker's own note
assert state("no, 50") == "answered"                               # a person on GitHub
assert state("决定（直达）：50 家" + fleet) == "answered"           # the direct route
P
ok "F a person's reply or a direct-route 决定 answers a row; the worker's own note does not"

# --- G ---------------------------------------------------------------------------
d render --demo > "$WORK/g"
grep -q '^| # | 事项 | 建议 | 不答按 | 截止 | 来源 |$' "$WORK/g" || fail "G: no header" "$(cat "$WORK/g")"
grep -q '永不默认：花钱' "$WORK/g" && grep -q '永不默认：对外发布' "$WORK/g" || fail "G: never rows not marked" "$(cat "$WORK/g")"
grep -q '^<!-- fleet:decision v=1 id=demo -->$' "$WORK/g" || fail "G: no fleet:decision marker"
ok "G render --demo: the table, never rows marked, the fleet:decision marker"

printf 'fleet-decision-selftest: %d passed\n' "$pass"
