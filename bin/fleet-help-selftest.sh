#!/bin/sh
# fleet-help-selftest.sh — the fleet-help skill's index points at sections that
# still exist (issue #3216).
#
# skills/fleet-help/SKILL.md answers «how do I …» by reading the doc section its
# index names — `docs/<file>.md` § 「<anchor>」 — and links the hub's pages as
# `<入口>/<path>`. A renamed heading or a moved page would leave it pointing at
# nothing, and the skill would start answering from memory. So:
#   A  the checker on fixtures: an anchor that is a heading's start or a bold
#      lead passes; a missing anchor, a missing doc and a page the hub does not
#      serve are each red, naming what is gone
#   B  the real skill: every § 「…」 resolves (docs/dev/CLIENT.md, MULTI-MACHINE-OPS.md,
#      MANAGED-NODE.md, STATE.md …), every <入口>/… page is a route in
#      tokenledger/internal/api (server.go, roles.go, or an old address app_mount.go's
#      consolePages moves on), and the
#      index is not empty
#   C  the skill ships: it is in the Agent package (conf/agent-bundle.manifest's
#      skills/ — 承载's, #4826), and docs/dev/CLIENT.md carries the 常见问题
#      section it answers from
#   D  current thin-client intents and FAQ coverage survive a retirement: a
#      shorter index or an unrelated heading sharing a prefix must not hide it
# Exit 0 = pass.
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$BIN/.." && pwd)
SKILL="$ROOT/skills/fleet-help/SKILL.md"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-help selftest: python3 absent — SKIP'; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-help.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# check <skill> <root>: one line per broken reference, exit 1 if any; prints
# `refs=<n> pages=<m>` on success.
cat > "$WORK/check.py" <<'PY'
import glob, os, re, sys

skill, root = sys.argv[1], sys.argv[2]
text = open(skill, encoding="utf-8").read()
refs = re.findall(r"`(docs/[A-Za-z0-9_./-]+\.md)` § 「([^」]+)」", text)
pages = sorted(set(re.findall(r"`<入口>(/[A-Za-z0-9_/-]+)`", text)))
bad = []


def anchored(doc, anchor):
    for line in open(doc, encoding="utf-8"):
        s = line.strip()
        h = re.match(r"#+\s+(.*)", s)
        if h and h.group(1).startswith(anchor):
            return True
        for b in re.findall(r"\*\*(.+?)\*\*", s):
            if b.startswith(anchor):
                return True
    return False


for doc, anchor in refs:
    p = os.path.join(root, doc)
    if not os.path.isfile(p):
        bad.append("missing doc: %s (§ 「%s」)" % (doc, anchor))
    elif not anchored(p, anchor):
        bad.append("missing section: %s § 「%s」" % (doc, anchor))

src = ""
for f in glob.glob(os.path.join(root, "tokenledger/internal/api/*.go")):
    if not f.endswith("_test.go"):
        src += open(f, encoding="utf-8").read()
for page in pages:
    if '"%s"' % page not in src:
        bad.append("page not served by the hub: <入口>%s" % page)

if not refs:
    bad.append("no § references at all — the index is gone")
for b in bad:
    print(b)
if bad:
    sys.exit(1)
print("refs=%d pages=%d" % (len(refs), len(pages)))
PY
check() { python3 "$WORK/check.py" "$@"; }

# --- A: the checker on fixtures -------------------------------------------------
F="$WORK/fx"
mkdir -p "$F/docs" "$F/tokenledger/internal/api"
cat > "$F/docs/A.md" <<'EOF'
# A
## The keys — every one
**手机：Termius 四样** (EPIC #1).
EOF
printf 'package api\nconst p = "/quota"\n' > "$F/tokenledger/internal/api/server.go"
printf 'package api\nconst q = "/usage"\n' > "$F/tokenledger/internal/api/server_test.go"
cat > "$F/good.md" <<'EOF'
| x | `docs/A.md` § 「The keys」 · `docs/A.md` § 「手机：Termius 四样」 |
see `<入口>/quota`
EOF
out=$(check "$F/good.md" "$F") || fail "A: a heading start and a bold lead should pass" "$out"
[ "$out" = "refs=2 pages=1" ] || fail "A: counts" "$out"
printf '`docs/A.md` § 「Gone」\n' > "$F/b1.md"
out=$(check "$F/b1.md" "$F") && fail "A: a missing section should be red" "$out"
case "$out" in *"missing section: docs/A.md § 「Gone」"*) ;; *) fail "A: names the section" "$out" ;; esac
printf '`docs/B.md` § 「The keys」\n' > "$F/b2.md"
out=$(check "$F/b2.md" "$F") && fail "A: a missing doc should be red" "$out"
case "$out" in *"missing doc: docs/B.md"*) ;; *) fail "A: names the doc" "$out" ;; esac
printf '`docs/A.md` § 「The keys」 `<入口>/usage`\n' > "$F/b3.md"
out=$(check "$F/b3.md" "$F") && fail "A: a page only a _test.go names should be red" "$out"
case "$out" in *"<入口>/usage"*) ;; *) fail "A: names the page" "$out" ;; esac
printf 'nothing here\n' > "$F/b4.md"
check "$F/b4.md" "$F" >/dev/null && fail "A: an empty index should be red"
ok "A the checker: heading / bold lead pass; a missing section, doc, page or index is red"

# --- B: the real skill ----------------------------------------------------------
[ -f "$SKILL" ] || fail "B: $SKILL missing"
out=$(check "$SKILL" "$ROOT") || fail "B: skills/fleet-help/SKILL.md points at something gone — fix the index or the doc" "$out"
ok "B the real index resolves ($out)"
for pg in /fleet/keys /quota /usage /connect; do
  grep -q "\`<入口>$pg\`" "$SKILL" || fail "B: the skill no longer links $pg"
done
ok "B the four hub pages are linked"

# --- C: it ships ----------------------------------------------------------------
# the Agent package (skills/ included) is 承载's since #4826: it ships there
python3 "$ROOT/bin/fleet-agent-bundle.py" files --root "$ROOT" | grep -qx 'skills/fleet-help/SKILL.md' \
  || fail "C: skills/fleet-help/SKILL.md is not in the Agent package (conf/agent-bundle.manifest)"
grep -q '^## 常见问题' "$ROOT/docs/dev/CLIENT.md" || fail "C: docs/dev/CLIENT.md lost its 常见问题 section"
ok "C in the Agent package; docs/dev/CLIENT.md has its 常见问题"

# --- D: current help coverage (issue #4449) --------------------------------------
# B intentionally accepts heading prefixes. Before #4449, the retired "The keys"
# and "A new session" still passed by matching the phone keys and CLI headings.
# Keep their actual intents, and the broken panel/task/shell intents, on the
# current user's guide; deleting those rows must not make B green either.
python3 - "$SKILL" <<'PY' || fail "D: current client help coverage"
import sys

text = open(sys.argv[1], encoding="utf-8").read()
index = text.split("## 2.", 1)[1].split("## 3.", 1)[0]
rows = [line.split("|", 2)[1:] for line in index.splitlines() if line.startswith("|")]
usage = "docs/public/zh/member/usage.md"
client = "docs/dev/CLIENT.md"
required = [
    ("⌘P:", usage, "一个键：总面板"),
    ("⌘P:", usage, "一个会话能做的事"),
    ("client keys", client, "One key + the panel"),
    ("a new session", usage, "开一个会话"),
    ("a new session", client, "A new session in one command"),
    ("hand a task", usage, "开一个会话"),
    ("a session's state", usage, "会话的状态"),
    ("session's shell", usage, "一个会话能做的事"),
    ("phone's keys", client, "The keys: one, to open the panel"),
    ("cannot connect", client, "连不上"),
    ("Chinese shows", client, "中文乱码"),
    ("list stopped updating", client, "列表停住"),
    ("leaving, quitting", client, "会话结束了"),
    ("quota and usage", client, "额度和用量在哪看"),
]
for intent, doc, section in required:
    matches = [body for label, body in rows if intent in label]
    ref = "`%s` § 「%s」" % (doc, section)
    if len(matches) != 1 or ref not in matches[0]:
        sys.exit("missing current help for %s: %s" % (intent, ref))
# Every reference still goes through B's real file/section checker above.
print("current client intents and all five FAQ answers retained")
PY
ok "D thin-client panel / keys / new session / task / state / shell and FAQ coverage"

echo "fleet-help selftest: $pass passed"
