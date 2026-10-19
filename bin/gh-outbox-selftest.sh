#!/bin/bash
# gh-outbox-selftest.sh — a GitHub ticket write made while GitHub does not answer is
# kept and made later, in order, never twice (issue #4844, EPIC #4839 C5).
#
# A stand-in GitHub (a fake `gh` holding one repo's issues in a JSON file) is cut
# off — every call a connection error — while a session writes to its ticket:
# claim · 3 comments · evidence · a closing note + close · a sub-ticket hung on it.
# Then:
#   A  nothing reached GitHub, every write said 「已记下」 and exited 0, and the
#      outbox ($FLEET_CONF_DIR/gh-outbox) holds them, 0600, no token in them
#   B  a new GitHub ticket is refused: exit 6 and the one sentence
#   C  GitHub back: the issue-bridge tick drains it — the stand-in received exactly
#      those writes, in the order they were made
#   D  the same outbox replayed a second time adds nothing
#   E  a claim whose session no longer holds the issue (its lease moved on) is
#      dropped, never made
#   F  GitHub answering: the door writes at once, byte for byte, nothing kept
#   G  a replay that meets GitHub down again stops and keeps the rest; one that
#      fails otherwise holds back only that ticket's later writes, and after 24 h
#      it moves to stuck/ (the doctor's WARN)
#
# Drives: bin/fleet_gh_outbox.py, bin/fleet-ticket.sh, bin/fleet-comment.sh,
# bin/fleet-evidence.sh, bin/fleet-issue-file.sh, bin/fleet-issue-bridge.sh,
# bin/fleet-gh-lib.sh, bin/fleet_gh.py, bin/fleet-gh.sh, bin/fleet-doctor.sh.
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted condition
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/gh-outbox-st.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [ -n "${3:-}" ] && printf '  %s\n' "$3"; fi; }

REPO=octo/outbox
mkdir -p "$T/stub" "$T/home" "$T/conf" "$T/tmp"
STATE="$T/gh-state.json"
cat > "$STATE" <<'JSON'
{"mode": "down", "me": "me", "next": 100,
 "issues": {"7": {"assignees": [], "state": "OPEN", "labels": [], "comments": [], "title": "seven"},
            "8": {"assignees": [], "state": "OPEN", "labels": [], "comments": [], "title": "eight"},
            "9": {"assignees": [], "state": "OPEN", "labels": [], "comments": [], "title": "nine"}},
 "parent": {}, "events": [], "calls": 0}
JSON

# The stand-in: a connection error for every call while mode=down; else enough of
# gh's issue / api surface for the door, answered from and written to STATE.
cat > "$T/stub/gh" <<'PY'
#!/usr/bin/env python3
import json, os, re, sys
S = os.environ["GHOB_STATE"]
st = json.load(open(S))
a = sys.argv[1:]
st["calls"] += 1
def save(): json.dump(st, open(S, "w"))
def out(x): sys.stdout.write(x if x.endswith("\n") else x + "\n")
if a[:2] in (["auth", "token"], ["--version"]):
    out("gho_fake"); sys.exit(0)
if st["mode"] == "down":
    save()
    sys.stderr.write('error connecting to api.github.com\n'); sys.exit(1)
def opt(name):
    for i, x in enumerate(a):
        if x == name and i + 1 < len(a): return a[i + 1]
        if x.startswith(name + "="): return x.split("=", 1)[1]
    return None
def jq():
    return opt("--jq") or opt("-q")
def ev(e): st["events"].append(e)
REPO = os.environ["GHOB_REPO"]
if a[:2] == ["api", "zen"]: save(); out("zen"); sys.exit(0)
if a[0] == "api":
    path = next((x for x in a[1:] if x.startswith("repos/") or x in ("user", "rate_limit")), "")
    method = opt("--method") or opt("-X") or "GET"
    if path == "user": save(); out(st["me"]); sys.exit(0)
    if path == "rate_limit": save(); out("5000"); sys.exit(0)
    m = re.match(r"repos/[^/]+/[^/]+/issues/(\d+)(/[a-z_]+)?(\?.*)?$", path)
    if not m: sys.stderr.write("fake gh: no such api %s\n" % path); sys.exit(1)
    n, sub = m.group(1), (m.group(2) or "")
    iss = st["issues"].get(n)
    if iss is None: sys.stderr.write("HTTP 404\n"); sys.exit(1)
    if sub == "" and method == "GET": save(); out(str(1000 + int(n))); sys.exit(0)
    if sub == "" and method == "PATCH":
        if iss["state"] != "CLOSED": iss["state"] = "CLOSED"; ev("close %s" % n)
        save(); out("https://github.com/%s/issues/%s" % (REPO, n)); sys.exit(0)
    if sub == "/comments" and method == "GET":
        save(); out("\n".join(c for c in iss["comments"])); sys.exit(0)
    if sub == "/comments":
        f = opt("-F")[len("body=@"):]
        body = open(f).read(); iss["comments"].append(body); ev("comment %s %s" % (n, body.splitlines()[0]))
        save(); out("https://github.com/%s/issues/%s#c%d" % (REPO, n, len(iss["comments"]))); sys.exit(0)
    if sub == "/parent":
        p = st["parent"].get(n)
        if not p: save(); sys.stderr.write("HTTP 404\n"); sys.exit(1)
        save(); out("%s\t%s" % (REPO, p)); sys.exit(0)
    if sub == "/sub_issues" and method == "POST":
        child = str(int(opt("-F").split("=", 1)[1]) - 1000)
        if st["parent"].get(child) == n:
            save(); sys.stderr.write("HTTP 422: already a sub-issue\n"); sys.exit(1)
        st["parent"][child] = n; ev("link %s<-%s" % (n, child)); save(); sys.exit(0)
    sys.stderr.write("fake gh: no such api %s %s\n" % (method, path)); sys.exit(1)
if a[0] == "issue":
    verb, n = a[1], (a[2] if len(a) > 2 else "")
    if verb == "create":
        st["next"] += 1; k = str(st["next"])
        st["issues"][k] = {"assignees": [], "state": "OPEN", "labels": [], "comments": [], "title": opt("--title")}
        ev("create %s" % k); save(); out("https://github.com/%s/issues/%s" % (REPO, k)); sys.exit(0)
    iss = st["issues"].get(n)
    if iss is None: sys.stderr.write("issue not found\n"); sys.exit(1)
    if verb == "view":
        f = (opt("--json") or "number,title,state").split(",")
        full = {"number": int(n), "title": iss["title"], "state": iss["state"], "url": "https://github.com/%s/issues/%s" % (REPO, n),
                "body": "", "assignees": [{"login": x} for x in iss["assignees"]],
                "labels": [{"name": x} for x in iss["labels"]], "comments": [{"body": c} for c in iss["comments"]]}
        o = {k: full.get(k) for k in f}
        q = jq()
        save()
        if q == ".labels[].name": out("\n".join(iss["labels"])) if iss["labels"] else None
        elif q and "join" in q: out(",".join(iss["labels"]))
        else: out(json.dumps(o))
        sys.exit(0)
    if verb == "edit":
        if opt("--add-assignee") and st["me"] not in iss["assignees"]: iss["assignees"].append(st["me"]); ev("claim %s" % n)
        if opt("--remove-assignee") and st["me"] in iss["assignees"]: iss["assignees"].remove(st["me"]); ev("release %s" % n)
        for l in (opt("--add-label") or "").split(","):
            if l and l not in iss["labels"]: iss["labels"].append(l); ev("label %s +%s" % (n, l))
        for l in (opt("--remove-label") or "").split(","):
            if l and l in iss["labels"]: iss["labels"].remove(l); ev("label %s -%s" % (n, l))
        save(); sys.exit(0)
    if verb == "comment":
        body = opt("--body"); iss["comments"].append(body); ev("comment %s %s" % (n, body.splitlines()[0]))
        save(); out("https://github.com/%s/issues/%s#c%d" % (REPO, n, len(iss["comments"]))); sys.exit(0)
    if verb in ("close", "reopen"):
        want = "CLOSED" if verb == "close" else "OPEN"
        if iss["state"] != want: iss["state"] = want; ev("%s %s" % (verb, n))
        save(); sys.exit(0)
sys.stderr.write("fake gh: unhandled %s\n" % a); save(); sys.exit(1)
PY
chmod +x "$T/stub/gh"
# A tmux that is not there: no server, no pane (the door reads no binding).
printf '#!/bin/sh\nexit 1\n' > "$T/stub/tmux"; chmod +x "$T/stub/tmux"

export HOME="$T/home" FLEET_CONF_DIR="$T/conf" TMPDIR="$T/tmp" FLEET_SKIP_GLOBAL_CONF=1
export PATH="$T/stub:$PATH" GHOB_STATE="$STATE" GHOB_REPO="$REPO" GH_TOKEN=gho_fake_never_written
export FLEET_GH_WRITE_GAP=0 FLEET_GH_TIMEOUT=5 FLEET_REPO="$REPO" CF_REPO="$REPO" CCQUOTA_FLEET=0
unset TMUX TMUX_PANE FLEET_GH_FAKE_DOWN FLEET_GH_FAKE_LIMIT FLEET_STATE_DIR FLEET_GH_OUTBOX_DIR
mkdir -p "$FLEET_CONF_DIR/global" "$FLEET_CONF_DIR/fleets/st/repos" "$T/main"
# the evidence store's fleet: its one repo in the repos/ layout (#1937, #4806)
: > "$FLEET_CONF_DIR/fleets/st/conf"
printf 'FLEET_REPO=%s\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=master\nFLEET_FORGE=github\n' "$REPO" "$T/main" \
  > "$FLEET_CONF_DIR/fleets/st/repos/octo-outbox.conf"
printf 'octo-outbox\n' > "$FLEET_CONF_DIR/fleets/st/repos/.order"
OB="$FLEET_CONF_DIR/gh-outbox"
st() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$STATE" "$1"; }
mode() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["mode"]=sys.argv[2]; json.dump(d,open(sys.argv[1],"w"))' "$STATE" "$1"; }
nq() { find "$OB" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }
ID="gh:$REPO#7"

# ---- while GitHub does not answer ----------------------------------------------
rcs=''; errs="$T/errs"; : > "$errs"
w() { local r; "$@" >>"$T/out" 2>>"$errs"; r=$?; rcs="$rcs $r"; }
w bash "$BIN/fleet-ticket.sh" claim "$ID"
w bash "$BIN/fleet-comment.sh" 7 --repo "$REPO" --note --body "one: progress"
w bash "$BIN/fleet-comment.sh" 7 --repo "$REPO" --note --body "two: more progress"
w bash "$BIN/fleet-comment.sh" 7 --repo "$REPO" --note --body "three: nearly there"
printf 'evidence: before\n' > "$T/ev.txt"
w bash "$BIN/fleet-evidence.sh" before --repo "$REPO" --issue 7 --epic none --session st --note "evidence: before" --post "$T/ev.txt"
w bash "$BIN/fleet-comment.sh" 7 --repo "$REPO" --note --close --body "wrap: done"
w bash "$BIN/fleet-ticket.sh" link "$ID" "gh:$REPO#8"
check "A every write exits 0 (got:$rcs)" '[ "$rcs" = " 0 0 0 0 0 0 0" ]' "$(tail -n 5 "$errs")"
check "A nothing reached GitHub" '[ "$(st "len(d[\"events\"])")" = 0 ]'
check "A each write said 已记下" '[ "$(grep -c "已记下" "$errs")" = 8 ]' "$(cat "$errs")"
check "A the outbox holds the 8 writes" '[ "$(nq)" = 8 ]'
perm=$(stat -c %a "$OB" 2>/dev/null || stat -f %Lp "$OB" 2>/dev/null)
fperm=$(f=$(find "$OB" -maxdepth 1 -name '*.json' | head -1); stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)
check "A outbox dir 0700, entries 0600 (got $perm/$fperm)" '[ "$perm" = 700 ] && [ "$fperm" = 600 ]'
check "A no token in an entry" '! grep -rq "gho_fake" "$OB"'
check "A an entry carries v · opid · repo · verb · args · session · ts" \
  'python3 -c "import json,sys,glob; e=json.load(open(sorted(glob.glob(sys.argv[1]+\"/*.json\"))[0])); sys.exit(0 if {\"v\",\"opid\",\"repo\",\"verb\",\"args\",\"session\",\"ts\"} <= set(e) else 1)" "$OB"'
check "A the gh-down marker is open" '[ -f "$FLEET_CONF_DIR/global/gh-down" ]'
line=$(python3 "$BIN/fleet_gh_outbox.py" line)
check "A the doctor's words: 待补 8 条 ($line)" 'case "$line" in "待补 8 条"*) true ;; *) false ;; esac'

# ---- B: a new ticket is refused ------------------------------------------------
nerr=$(bash "$BIN/fleet-issue-file.sh" --repo "$REPO" --title "drill: new" --body "x" 2>&1 >/dev/null); nrc=$?
check "B a new GitHub ticket: exit 6 (got $nrc)" '[ "$nrc" = 6 ]' "$nerr"
check "B …and the one sentence" 'printf "%s" "$nerr" | grep -q "GitHub 不通.*新单没开.*入口单"' "$nerr"
check "B …nothing kept for it" '[ "$(nq)" = 8 ]'

# ---- E's setup: a claim whose session's lease has moved on ---------------------
python3 "$BIN/fleet_gh_outbox.py" put --repo "$REPO" --verb claim --session gone-session -- "gh:$REPO#9" >/dev/null
export FLEET_GH_OUTBOX_OWNER_CMD='[ "$1" != gone-session ]'
cp -R "$OB" "$T/outbox-copy"

# ---- C: GitHub answers again, the bridge's tick drains it ------------------------
mode up
export FLEET_GH_DOWN_PROBE_SECS=0
bash "$BIN/fleet-issue-bridge.sh" --poll >"$T/bridge.out" 2>&1
want='claim 7|comment 7 one: progress|comment 7 two: more progress|comment 7 three: nearly there|comment 7 📎 上线证据 · #7|comment 7 wrap: done|close 7|link 7<-8'
got=$(st '"|".join(d["events"])')
check "C GitHub received exactly those writes, in order" '[ "$got" = "$want" ]' "got: $got"
check "C the outbox is empty" '[ "$(nq)" = 0 ]' "$(cat "$T/bridge.out")"
check "C the gh-down marker closed (the probe answered)" '[ ! -f "$FLEET_CONF_DIR/global/gh-down" ]'
check "C each comment carries its op id" '[ "$(st "sum(\"fleet:op id=\" in c for c in d[\"issues\"][\"7\"][\"comments\"])")" = 5 ]'
check "E the moved claim was dropped" '! st "d[\"issues\"][\"9\"][\"assignees\"]" | grep -q me'
check "E …and said so in the log" 'grep -q "dropped .*verb=claim.*#9" "$FLEET_CONF_DIR/logs/gh-outbox.log"'

# ---- D: the same outbox replayed again -----------------------------------------
cp "$T/outbox-copy"/*.json "$OB"/
python3 "$BIN/fleet_gh_outbox.py" drain 2>/dev/null
got2=$(st '"|".join(d["events"])')
check "D a second replay adds nothing" '[ "$got2" = "$want" ]' "got: $got2"
check "D …and empties the outbox" '[ "$(nq)" = 0 ]'

# ---- F: GitHub answering — written at once, nothing kept -------------------------
o=$(bash "$BIN/fleet-comment.sh" 8 --repo "$REPO" --note --body "live: hello" 2>/dev/null); frc=$?
check "F a live comment: its URL, exit 0, nothing kept" \
  '[ "$frc" = 0 ] && case "$o" in https://github.com/*) true ;; *) false ;; esac && [ "$(nq)" = 0 ]' "rc=$frc out=$o"
check "F …with no op id (byte for byte as before)" '! st "d[\"issues\"][\"8\"][\"comments\"][-1]" | grep -q "fleet:op"'

# ---- G: down again mid-drain, a failing write, stuck after 24 h -----------------
mode down
bash "$BIN/fleet-ticket.sh" post "gh:$REPO#8" --body "g1" 2>/dev/null
bash "$BIN/fleet-ticket.sh" post "gh:$REPO#404" --body "g-missing" 2>/dev/null   # never answers 200
bash "$BIN/fleet-ticket.sh" close "gh:$REPO#404" 2>/dev/null
bash "$BIN/fleet-ticket.sh" post "gh:$REPO#9" --body "g2" 2>/dev/null
check "G four writes kept" '[ "$(nq)" = 4 ]'
python3 "$BIN/fleet_gh_outbox.py" drain 2>/dev/null
check "G still down: the drain made nothing, kept all four" '[ "$(nq)" = 4 ]'
mode up; rm -f "$FLEET_CONF_DIR/global/gh-down"
python3 "$BIN/fleet_gh_outbox.py" drain 2>/dev/null
ev=$(st '"|".join(d["events"][-2:])')
check "G #404's failure held back only #404 (g1, g2 made)" \
  '[ "$ev" = "comment 8 g1|comment 9 g2" ] && [ "$(nq)" = 2 ]' "events: $ev · left $(nq)"
check "G …its close never overtook its comment" '! st "d[\"events\"]" | grep -q "close 404"'
FLEET_GH_OUTBOX_STUCK_SECS=0 python3 "$BIN/fleet_gh_outbox.py" drain 2>/dev/null
check "G failing past the limit ⇒ gh-outbox/stuck/" \
  '[ "$(find "$OB/stuck" -name "*.json" | wc -l | tr -d " ")" -ge 1 ]'
dline=$(python3 "$BIN/fleet_gh_outbox.py" line)
check "G the doctor's words name it ($dline)" 'printf "%s" "$dline" | grep -q "补不上"'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
