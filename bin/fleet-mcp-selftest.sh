#!/bin/sh
# fleet-mcp-selftest.sh — the fleet tool service's contract (issue #1807, EPIC #1813 C5).
#
# bin/fleet-mcp.py is the ONE stdio MCP server Claude and Codex sessions both mount
# (docs/FLEET-MCP.md). Driven against fake scripts in a sandbox bin/:
#   A  initialize + tools/list: server `fleet`, exactly the twenty-four tools, every
#      schema closed (additionalProperties false)
#   B  refusals: an unknown argument, a wrong type, a missing argument, an
#      out-of-range timeout, a malformed repo, a repo this fleet does not host,
#      an unknown tool — each answered isError with the reason, and NOTHING ran
#   C  each tool runs its script once, with exactly its argv; the script's exit
#      code, stdout and stderr come back as they came (a non-zero exit is data)
#   D  degenerate (EPIC #1813 rule 1): no hub at all — every hub variable unset —
#      and every tool is still listed and still runs
#   E  the legacy fleet-peer shim still serves list_agents / send_message
#   F  `--mount codex` derives Codex's -c value from conf/mcp-worker.json, with
#      the env Codex withholds and a per-call timeout an await fits in
#   G  报问记合 (issue #1808) refusals: each new tool's bad enum, bad combination,
#      wrong type — answered isError with the reason, and NOTHING ran
#   H  report · ask · comment · evidence · handoff · pr_verdict · pr_merge each run
#      their script with exactly the documented argv, a body / doc on STDIN, and the
#      exit code passes through; ask posts `⛔ blocked:` THEN stamps the window red
#   I  script ≡ tool: the same inputs through the REAL fleet-comment.sh (by hand vs
#      the comment tool) post the byte-identical comment, the REAL
#      fleet-report-parent.sh --dry-run prints the same, and every new tool's argv +
#      stdin is what the hand-typed contract command (commands/fleet-claim.md) runs
#   J  the worker credential (issue #1809): minted for the pane's session, a valid
#      one runs the tool and the call log names its worker_id; expired, forged,
#      tampered, another session's pane, another fleet, revoked → refused, nothing
#      ran; the same session in a new window (a migration) still holds; renewal
#      keeps the nonce; no credential runs as before and logs `via=marker`; and the
#      credential appears in no file, log, reply or tmux option the run left behind
#   K  the hub route (issue #1810): with the hub on for the fleet and a node token,
#      a credentialed spawn / await / send hands its script $FLEET_WORKER_ASSERT,
#      HMAC'd with HashToken(node token), naming the session; no hub, no token or no
#      credential → none, and with no hub not one network request (a sitecustomize
#      traps every Python socket; curl and ccquota are tripwires); the real
#      fleet_hub_put carries it as the relay's `worker`, and without it the outbox
#      file is byte for byte as before
#   L  the rest of a worker skill (issue #1811): brief · file_issue · gh · context ·
#      transfer · where · show · open · handoff arm — refusals run nothing, each runs
#      its script with exactly the documented argv, and handoff arm returns at once
#      with the cycle helper DETACHED (it outlives the call)
#   M  a new version, taken between calls (issue #1898): the install is a link to a
#      version dir; switched while a call is in flight, that call finishes on the old
#      code, then the server os.execv's the new file (same pid, the connection never
#      drops), sends notifications/tools/list_changed, and tools/list carries the new
#      tool; the queued request is served by the new version, the credential still
#      holds (via=cred), nothing of the handover leaks to a script or $TMPDIR; a new
#      version that fails its --probe is refused and the old one keeps serving; a
#      quiet client is reloaded on the poll; FLEET_MCP_RELOAD=0 never reloads
#   N  the mod's fallback road (issue #2057): `--spec status spawn await` prints
#      exactly the tools/list entries; `--call <tool> <json>` is one tools/call
#      from a command line — the same argv to the script, the byte-identical text
#      on stdout, exit 0 answered (the script's exit is in the text) / 1 refused
#      (the reason on stdout, nothing ran) / 2 usage; the call log says road=call
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
SUT="$BIN/fleet-mcp.py"
[ -f "$SUT" ] || { echo "selftest: fleet-mcp.py missing" >&2; exit 2; }
[ -f "$BIN/fleet-peer-mcp.py" ] || { echo "selftest: fleet-peer-mcp.py missing" >&2; exit 2; }
[ -f "$BIN/../conf/mcp-worker.json" ] || { echo "selftest: conf/mcp-worker.json missing" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-mcp.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/conf"
cp "$SUT" "$WORK/bin/fleet-mcp.py"
cp "$BIN/fleet-peer-mcp.py" "$WORK/bin/fleet-peer-mcp.py"
cp "$BIN/../conf/mcp-worker.json" "$WORK/conf/mcp-worker.json"
LOG="$WORK/runs"; : > "$LOG"

cat > "$WORK/bin/fleet-lib.sh" <<'SH'
fleet_origin_key() { printf 'issue-1807'; }
fleet_origin_win() { printf '@77'; }
fleet_win_for_key() { [ "$1" = issue-77 ] && printf '@77'; }
SH
# Every fake script logs its argv, one line per run, to $LOG.
fake() { # fake <name> <body>
  { printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\n' "$1" "$LOG"; printf '%s\n' "$2"; } > "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}
fake fleet-repo.sh 'printf "fleet tf hosts:\n  acme/app                 main=/x/app  base=main  [conf]\n  acme/lib                 main=/x/lib  base=main  [repos/acme-lib.conf]\n"'
fake fleet-children.sh 'if [ "${1:-}" = --json ]; then printf "%s\n" "{\"children\":[{\"child\":\"issue-99\",\"outcome\":\"merged\"}]}"; else printf "issue-99  merged  PR #5\n1/1 ✓\n"; fi'
fake dash-issue-session.sh 'echo "spawned issue-$1"; echo "cap note" >&2; exit 2'
fake fleet-await.sh 'echo "MERGED #$1 pr=42"; exit 0'
fake fleet-peer-send.sh 'text=$(cat); printf "sent -> %s (%s)\n" "$1" "$text"'
# 报问记合 (issue #1808): a script that may take stdin logs it as `<<<body>` after its argv.
fakein() { # fakein <name> <body>
  fake "$1" "case \" \$* \" in *' - '*) printf '<<<%s>\\n' \"\$(cat)\" >> \"$LOG\" ;; esac
$2"
}
fake fleet-report-parent.sh 'echo "queued → parent issue-77"; exit 3'
fakein fleet-comment.sh 'echo "https://github.com/acme/app/issues/$1#c1"'
fake set-claude-state.sh 'exit 0'
fakein fleet-evidence.sh 'echo "/ev/$1"'
fakein fleet-handoff-file.sh 'echo "/h/$1"; [ "$1" = check ] && exit 3; exit 0'
fake fleet-pr-verdict.sh 'echo PENDING; exit 1'
fake fleet-pr-merge.sh 'echo MERGED'
# the rest of a worker skill (issue #1811)
fake fleet-claim-brief.sh 'echo "===== fleet ====="'
fake fleet-compact-resume.sh 'echo map'
fake fleet-issue-file.sh 'echo "https://github.com/acme/app/issues/900"'
fake fleet-gh.sh 'echo "{}"'
fake fleet-context.sh 'echo "ctx 41% OK"'
fake fleet-transfer.sh 'echo /req/1'
fake fleet-client-where.sh 'echo "m5 iTerm2"; exit 3'
fake fleet-show.sh 'echo "SENT a.png"'
fake fleet-open.sh 'echo sent:iterm2'
fake fleet-handoff-cycle.sh "sleep 2; echo cycle-done >> '$LOG.cycle'"
printf 'import sys\nopen("%s", "a").write("fleet-loop.py " + " ".join(sys.argv[1:]) + "\\n")\n' "$LOG" > "$WORK/bin/fleet-loop.py"

cat > "$WORK/tmux" <<'SH'
#!/bin/sh
if [ "$1" = display-message ]; then
  case "$*" in
    *session_name*) printf 'tf\n' ;;
    *'window #{window_name}'*) printf 'window issue-1807 · issue=1807 repo=acme/app state=working lifecycle= origin=issue-77\n' ;;
    *'#{@origin}'*) printf 'issue-77\n' ;;
    *'#{@issue}'*) printf '1807\n' ;;
  esac
  exit 0
fi
if [ "$1" = list-windows ]; then
  printf '@1\ttf\tissue-1807\t1807\tcodex\tworking\t\tissue-77\t\t\t/tmp/repo-issue-1807\t/tmp/repo-issue-1807\n'
  printf '@2\ttf\tissue-77\t77\t\tidle\t\t\t\t\t/tmp/repo-issue-77\t/tmp/repo-issue-77\n'
  printf '@3\ttf\tissue-99\t99\t\tidle\t\tissue-1807\t\t\t/tmp/repo-issue-99\t/tmp/repo-issue-99\n'
  printf '@4\ttf\thome\t\t\tidle\t\t\t\t\t/tmp\t/tmp\n'
  exit 0
fi
exit 1
SH
chmod +x "$WORK/tmux"

# serve <out> [extra server args] < requests — one stdio session, no hub anywhere.
serve() {
  out=$1; shift
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u CCQUOTA_HUB_URL -u CCQUOTA_URL -u FLEET_WORKER_CRED \
    PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 python3 "$WORK/bin/fleet-mcp.py" "$@" > "$out"
}
call() { # call <id> <tool> <json args>
  printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"
}

# --- A: the tool list ---------------------------------------------------------
serve "$WORK/a" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
python3 - "$WORK/a" <<'PY' || fail "A: initialize / tools/list" "$(cat "$WORK/a")"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, rows                       # the notification got no answer
assert rows[0]["result"]["serverInfo"]["name"] == "fleet", rows[0]
assert rows[0]["result"]["protocolVersion"] == "2025-06-18", rows[0]
tools = {t["name"]: t for t in rows[1]["result"]["tools"]}
assert set(tools) == {"status", "children", "repos", "agents", "spawn", "await", "send",
                      "report", "ask", "comment", "evidence", "handoff", "pr_verdict", "pr_merge",
                      "brief", "file_issue", "gh", "context", "transfer", "where", "whats_new", "show", "open",
                      "set_reap"}, sorted(tools)
for t in tools.values():
    assert t["inputSchema"]["additionalProperties"] is False, t
    assert t["description"], t
assert tools["spawn"]["inputSchema"]["required"] == ["issue"]
assert tools["send"]["inputSchema"]["required"] == ["to", "text"]
assert tools["comment"]["inputSchema"]["required"] == ["issue", "body"]
assert tools["ask"]["inputSchema"]["required"] == ["question"]
for n in ("report", "evidence", "handoff"):
    assert len(tools[n]["inputSchema"]["required"]) == 1, n
for n in ("pr_verdict", "pr_merge"):
    assert tools[n]["inputSchema"]["required"] == ["pr"], n
PY
ok "A server \`fleet\`, the twenty-four tools, every schema closed"

# --- B: refusals — nothing runs -----------------------------------------------
: > "$LOG"
{
  call 10 spawn '{"issue":5,"force":true}'
  call 11 spawn '{"issue":"5"}'
  call 12 spawn '{}'
  call 13 await '{"issue":5,"timeout":9999}'
  call 14 spawn '{"issue":5,"repo":"--force"}'
  call 15 spawn '{"issue":5,"repo":"other/repo"}'
  call 16 await '{"issue":5,"repo":"other/repo"}'
  call 17 status '{"issue":5}'
  call 18 send '{"to":"rm -rf","text":"x"}'
  call 19 nope '{}'
  call 20 spawn '{"issue":true}'
} | serve "$WORK/b"
python3 - "$WORK/b" <<'PY' || fail "B: a bad call was not refused with its reason" "$(cat "$WORK/b")"
import json, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
want = {10: 'unknown argument "force"', 11: "must be an integer", 12: 'missing required argument "issue"',
        13: "≤ 570", 14: "owner/name", 15: "not hosted by this fleet", 16: "acme/app, acme/lib",
        17: "takes no arguments", 18: "issue:<N>, scratch-<N>, orchestrator or parent", 19: "unknown tool",
        20: "must be an integer"}
for i, why in want.items():
    res = rows[i]["result"]
    assert res.get("isError") is True, (i, res)
    text = res["content"][0]["text"]
    assert why in text and "Nothing ran." in text, (i, text)
PY
# The repo check READS fleet-repo.sh list; nothing else may have run.
ran=$(grep -v '^fleet-repo.sh list$' "$LOG")
[ -z "$ran" ] || fail "B: a refused call ran a script" "$ran"
ok "B unknown arg · wrong type · missing · out of range · bad/unhosted repo · unknown tool: refused, nothing ran"

# --- C: each tool runs its script once ----------------------------------------
: > "$LOG"
{
  call 30 status '{}'
  call 31 children '{}'
  call 32 repos '{}'
  call 33 agents '{}'
  call 34 spawn '{"issue":12,"repo":"acme/lib"}'
  call 35 await '{"issue":12,"timeout":60}'
  call 36 send '{"to":"issue:99","text":"hello child"}'
  call 37 send '{"to":"parent","text":"hello parent"}'
} | serve "$WORK/c"
python3 - "$WORK/c" <<'PY' || fail "C: a tool's result is wrong" "$(cat "$WORK/c")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
for i, r in rows.items():
    assert not r.get("isError"), (i, r)
st = rows[30]["structuredContent"]
assert st["window"].startswith("window issue-1807 · issue=1807"), st
assert st["children"]["exit"] == 0 and "1/1" in st["children"]["stdout"], st
assert st["repos"] == ["acme/app", "acme/lib"], st
assert "acme/lib" in rows[30]["content"][0]["text"]
ch = rows[31]["structuredContent"]
assert ch["exit"] == 0 and json.loads(ch["stdout"])["children"][0]["child"] == "issue-99", ch
assert rows[32]["structuredContent"]["repos"] == ["acme/app", "acme/lib"]
agents = rows[33]["structuredContent"]["agents"]
assert {a["key"] for a in agents} == {"issue-1807", "issue-77", "issue-99"}, agents
assert next(a for a in agents if a["key"] == "issue-1807")["is_self"]
assert next(a for a in agents if a["key"] == "issue-77")["is_parent"]
assert next(a for a in agents if a["key"] == "issue-99")["is_child"]
sp = rows[34]["structuredContent"]
assert (sp["command"], sp["exit"]) == ("dash-issue-session.sh", 2), sp           # exit code passes through
assert sp["stdout"] == "spawned issue-12\n" and sp["stderr"] == "cap note\n", sp
assert rows[34]["content"][0]["text"].startswith("exit 2 · dash-issue-session.sh"), rows[34]
aw = rows[35]["structuredContent"]
assert (aw["exit"], aw["stdout"]) == (0, "MERGED #12 pr=42\n"), aw
assert rows[36]["structuredContent"]["receipt"] == "sent -> issue:99 (hello child)", rows[36]
assert rows[37]["structuredContent"]["receipt"] == "sent -> @77 (hello parent)", rows[37]
PY
grep -qx 'dash-issue-session.sh 12 --repo acme/lib' "$LOG" || fail "C: spawn ran the wrong argv" "$(cat "$LOG")"
grep -qx 'fleet-await.sh 12 --timeout 60' "$LOG" || fail "C: await ran the wrong argv" "$(cat "$LOG")"
grep -qx 'fleet-children.sh --json' "$LOG" || fail "C: children did not run fleet-children.sh --json" "$(cat "$LOG")"
grep -qx 'fleet-peer-send.sh issue:99 -' "$LOG" && grep -qx 'fleet-peer-send.sh @77 -' "$LOG" \
  || fail "C: send ran the wrong argv" "$(cat "$LOG")"
[ "$(grep -c '^dash-issue-session.sh' "$LOG")" = 1 ] && [ "$(grep -c '^fleet-await.sh' "$LOG")" = 1 ] \
  || fail "C: a write tool ran more than once" "$(cat "$LOG")"
ok "C status · children · repos · agents · spawn · await · send each ran its script once; exit code + output pass through"

# --- D: degenerate — no hub, every tool available -----------------------------
: > "$LOG"
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
  call 40 spawn '{"issue":3}'
  call 41 await '{"issue":3}'
} | serve "$WORK/d"
python3 - "$WORK/d" <<'PY' || fail "D: with no hub a tool was missing or failed" "$(cat "$WORK/d")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert len(rows[1]["tools"]) == 24, rows[1]
assert rows[40]["structuredContent"]["exit"] == 2 and not rows[40].get("isError"), rows[40]
assert rows[41]["structuredContent"]["exit"] == 0, rows[41]
PY
grep -qx 'fleet-await.sh 3 --timeout 540' "$LOG" || fail "D: await's default timeout is not 540" "$(cat "$LOG")"
ok "D no hub configured: all twenty-four tools listed, spawn/await run locally (await default 540s)"

# --- E: the legacy fleet-peer shim --------------------------------------------
env -u FLEET_WORKER_CRED PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 python3 "$WORK/bin/fleet-peer-mcp.py" > "$WORK/e" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_message","arguments":{"to":"issue:99","text":"hi"}}}
EOF
python3 - "$WORK/e" <<'PY' || fail "E: the fleet-peer shim broke" "$(cat "$WORK/e")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert rows[1]["serverInfo"]["name"] == "fleet-peer"
assert {t["name"] for t in rows[2]["tools"]} == {"list_agents", "send_message"}
assert rows[3]["structuredContent"]["delivered"] is True
PY
ok "E fleet-peer-mcp.py still serves list_agents / send_message (one version)"

# --- F: the Codex mount, from the one definition ------------------------------
m=$(python3 "$WORK/bin/fleet-mcp.py" --mount codex) || fail "F: --mount codex failed"
case "$m" in
  'mcp_servers.fleet={command="bash",args=["-c",'*'fleet-mcp.py'*'],env_vars=["TMUX","TMUX_PANE",'*'"FLEET_WORKER_CRED","FLEET_MCP_BIN"],tool_timeout_sec=600}') : ;;
  *) fail "F: the Codex mount value is wrong" "$m" ;;
esac
python3 - "$WORK/conf/mcp-worker.json" <<'PY' || fail "F: conf/mcp-worker.json is not the one fleet server"
import json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"mcpServers"} and set(d["mcpServers"]) == {"fleet"}, d
assert "fleet-mcp.py" in " ".join(d["mcpServers"]["fleet"]["args"])
PY
ok "F conf/mcp-worker.json = server \`fleet\` only; --mount codex derives the -c value from it"

# --- G: 报问记合 refusals — nothing runs (issue #1808) -------------------------
: > "$LOG"
{
  call 50 report '{"state":"shipped"}'
  call 51 report '{"state":"merged","pr":"12"}'
  call 52 report '{"state":"merged","dry_run":"yes"}'
  call 53 report '{"state":"merged","win":"@3"}'
  call 54 ask '{}'
  call 55 ask '{"question":"may I?","kind":"later"}'
  call 56 comment '{"issue":5}'
  call 57 comment '{"issue":5,"body":"x","mode":"relay"}'
  call 58 comment '{"issue":5,"body":"x","repo":"other/repo"}'
  call 59 evidence '{"action":"live","text":"x"}'
  call 60 evidence '{"action":"before"}'
  call 61 evidence '{"action":"after","file":"a.png","text":"x"}'
  call 62 evidence '{"action":"post","file":"a.png"}'
  call 63 evidence '{"action":"before","text":"x","mv":true}'
  call 64 handoff '{"action":"check"}'
  call 65 handoff '{"action":"find","slug":"x"}'
  call 66 handoff '{"action":"remove"}'
  call 67 pr_verdict '{"pr":12,"timeout":60}'
  call 68 pr_verdict '{"pr":12,"wait":true,"timeout":9999}'
  call 69 pr_merge '{"pr":12,"method":"rebase"}'
  call 70 pr_merge '{"pr":0}'
  call 71 comment '{"issue":5,"body":"   "}'
} | serve "$WORK/g"
python3 - "$WORK/g" <<'PY' || fail "G: a bad 报问记合 call was not refused with its reason" "$(cat "$WORK/g")"
import json, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
want = {50: "merged · blocked · failed · stopped · waiting", 51: "must be an integer", 52: "true or false",
        53: 'unknown argument "win"', 54: 'missing required argument "question"', 55: "question · permission",
        56: 'missing required argument "body"', 57: "note · to-worker", 58: "not hosted by this fleet",
        59: "line · before · after · post", 60: "exactly one of file, text, pane (got none)",
        61: "exactly one of file, text, pane (got file, text)", 62: "post takes no file",
        63: "mv applies to a file only", 64: "check needs doc", 65: "slug applies to path only",
        66: "path · find · repo · check", 67: "apply with wait only", 68: "≤ 570",
        69: 'unknown argument "method"', 70: "≥ 1", 71: "non-empty string"}
for i, why in want.items():
    res = rows[i]["result"]
    assert res.get("isError") is True, (i, res)
    text = res["content"][0]["text"]
    assert why in text and "Nothing ran." in text, (i, text)
PY
ran=$(grep -v '^fleet-repo.sh list$' "$LOG")
[ -z "$ran" ] || fail "G: a refused 报问记合 call ran a script" "$ran"
ok "G report · ask · comment · evidence · handoff · pr_verdict · pr_merge: bad enum / combination / type refused, nothing ran"

# --- H: each new tool runs its script, argv exact, text on stdin --------------
: > "$LOG"
{
  call 80 report '{"state":"merged","pr":42,"summary":"landed it"}'
  call 81 ask '{"question":"which repo owns this?"}'
  call 82 ask '{"question":"push to prod?","kind":"permission","issue":77}'
  call 83 comment '{"issue":1808,"body":"line one\nline \"two\" $HOME `x`"}'
  call 84 comment '{"issue":5,"body":"go","mode":"to-worker","close":true,"repo":"acme/lib"}'
  call 85 evidence '{"action":"line"}'
  call 86 evidence '{"action":"before","text":"7 tools","name":"tools.txt","note":"before"}'
  call 87 evidence '{"action":"after","file":".playwright-mcp/a.png","mv":true,"note":"after"}'
  call 88 evidence '{"action":"after","pane":"%3","name":"dash.txt"}'
  call 89 evidence '{"action":"post"}'
  call 90 handoff '{"action":"path","slug":"c6"}'
  call 91 handoff '{"action":"check","doc":"# handoff\nRepo: acme/app","issue":1808}'
  call 92 pr_verdict '{"pr":42}'
  call 93 pr_verdict '{"pr":42,"repo":"acme/app","wait":true,"until_merged":true,"timeout":30}'
  call 94 pr_merge '{"pr":42}'
  call 95 report '{"state":"blocked","summary":"need a token","dry_run":true}'
} | serve "$WORK/h"
python3 - "$WORK/h" <<'PY' || fail "H: a 报问记合 tool's result is wrong" "$(cat "$WORK/h")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
for i, r in rows.items():
    assert not r.get("isError"), (i, r)
def sc(i): return rows[i]["structuredContent"]
assert (sc(80)["command"], sc(80)["exit"]) == ("fleet-report-parent.sh", 3), sc(80)     # queued is data
assert rows[80]["content"][0]["text"].startswith("exit 3 · fleet-report-parent.sh\nqueued"), rows[80]
a = sc(81)
assert (a["command"], a["exit"], a["issue"]) == ("fleet-comment.sh", 0, 1807), a          # the pane's @issue
assert a["body"] == "⛔ blocked: which repo owns this?", a
assert (a["state"]["command"], a["state"]["exit"]) == ("set-claude-state.sh", 0), a
assert "set-claude-state.sh" in rows[81]["content"][0]["text"], rows[81]
assert sc(82)["issue"] == 77 and sc(82)["body"] == "⛔ blocked — needs authorization: push to prod?", sc(82)
assert sc(83)["stdout"].startswith("https://github.com/acme/app/issues/1808"), sc(83)
assert sc(91)["exit"] == 3, sc(91)                                                     # check findings = data
assert (sc(92)["exit"], sc(92)["stdout"]) == (1, "PENDING\n"), sc(92)
assert sc(94)["stdout"] == "MERGED\n", sc(94)
PY
cat > "$WORK/h.want" <<'EOF'
fleet-report-parent.sh --state merged --pr 42 --summary landed it
fleet-comment.sh 1807 --note --body-file -
<<<⛔ blocked: which repo owns this?>
set-claude-state.sh blocked
fleet-comment.sh 77 --note --body-file -
<<<⛔ blocked — needs authorization: push to prod?>
set-claude-state.sh blocked
fleet-comment.sh 1808 --note --body-file -
<<<line one
line "two" $HOME `x`>
fleet-repo.sh list
fleet-comment.sh 5 --to-worker --close --repo acme/lib --body-file -
<<<go>
fleet-evidence.sh line
fleet-evidence.sh before --note before --name tools.txt -
<<<7 tools>
fleet-evidence.sh after --note after --mv .playwright-mcp/a.png
fleet-evidence.sh after --name dash.txt --pane %3
fleet-evidence.sh post
fleet-handoff-file.sh path --slug c6
fleet-handoff-file.sh check - --issue 1808
<<<# handoff
Repo: acme/app>
fleet-pr-verdict.sh 42
fleet-repo.sh list
fleet-pr-verdict.sh 42 --repo acme/app --wait --timeout 30 --until-merged
fleet-pr-merge.sh 42
fleet-report-parent.sh --state blocked --summary need a token --dry-run
EOF
diff "$WORK/h.want" "$LOG" > "$WORK/h.diff" || fail "H: a 报问记合 tool ran the wrong argv / stdin" "$(cat "$WORK/h.diff")"
ok "H report · ask · comment · evidence · handoff · pr_verdict · pr_merge: exact argv, text on stdin, exit passes through"

# --- I: script ≡ tool, through the REAL scripts --------------------------------
# A second sandbox with the real fleet-comment.sh / fleet-report-parent.sh and
# their libraries; only gh is fake (it records what would be posted).
R="$WORK/real"; mkdir -p "$R/bin" "$R/conf" "$R/gh"
for f in fleet-mcp.py fleet-comment.sh fleet-report-parent.sh fleet-lib.sh fleet-gh-lib.sh; do
  cp "$BIN/$f" "$R/bin/$f"
done
for f in "$BIN"/fleet-*lib.sh; do cp "$f" "$R/bin/" 2>/dev/null; done
printf '#!/bin/sh\nprintf "fleet tf hosts:\\n  acme/app   main=/x  base=main  [conf]\\n"\n' > "$R/bin/fleet-repo.sh"
cat > "$R/gh/gh" <<SH
#!/bin/sh
{ printf 'ARGV'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\\n'; } >> "\$GH_LOG"
echo "https://github.com/acme/app/issues/5#issuecomment-1"
SH
chmod +x "$R/bin/"* "$R/gh/gh"
real() { # real <log> <cmd…> — no tmux, no hub, a sandbox conf; gh records
  log=$1; shift
  env -u TMUX -u TMUX_PANE -u CCQUOTA_FLEET -u FLEET_HUB_URL -u FLEET_REPO -u CF_REPO \
    FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$R/conf" GH_LOG="$log" PATH="$R/gh:$PATH" "$@"
}
body='a note — with "quotes", $VARS, `ticks` and
a second line'
real "$R/by-hand" bash "$R/bin/fleet-comment.sh" 5 --note --repo acme/app --body "$body" >/dev/null 2>"$R/by-hand.err" \
  || fail "I: the real fleet-comment.sh failed by hand" "$(cat "$R/by-hand.err")"
req=$(python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"comment","arguments":{"issue":5,"body":sys.argv[1],"repo":"acme/app"}}}))' "$body")
printf '%s\n' "$req" | real "$R/by-tool" python3 "$R/bin/fleet-mcp.py" > "$R/tool.out"
[ -s "$R/by-hand" ] || fail "I: the hand-typed comment posted nothing" "$(cat "$R/by-hand.err")"
cmp -s "$R/by-hand" "$R/by-tool" || fail "I: the comment tool posted a different comment than the script by hand" \
  "$(diff "$R/by-hand" "$R/by-tool"; cat "$R/tool.out")"
grep -q 'fleet:no-relay' "$R/by-tool" || fail "I: the tool's comment lost the no-relay marker" "$(cat "$R/by-tool")"
# The report: a child window with a parent, on an ISOLATED tmux server (-S, never
# the live one) — the dry run resolves the parent and prints the exact envelope.
SOCK="$WORK/s"
tmux -S "$SOCK" -f /dev/null new-session -d -s tf -n issue-77 -c "$WORK" \
  && tmux -S "$SOCK" new-window -t tf -n issue-1808 -c "$WORK" \
  || fail "I: could not start the isolated tmux server"
trap 'tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
tmux -S "$SOCK" set-window-option -t tf:issue-77 @issue 77
tmux -S "$SOCK" set-window-option -t tf:issue-1808 @issue 1808
tmux -S "$SOCK" set-window-option -t tf:issue-1808 @origin issue-77
CP=$(tmux -S "$SOCK" display-message -p -t tf:issue-1808 '#{pane_id}')
# real() unsets TMUX for the comment leg; this leg puts the isolated pane back.
hand=$(real /dev/null sh -c 'TMUX=$0 TMUX_PANE=$1; export TMUX TMUX_PANE; shift 2; exec "$@"' \
  "$SOCK,1,0" "$CP" bash "$R/bin/fleet-report-parent.sh" --state blocked --summary 'need a token' --dry-run 2>&1; echo "rc=$?")
case "$hand" in *'[child-report] issue #1808'*'summary: need a token'*) : ;;
  *) fail "I: the real report dry run did not resolve the parent" "$hand" ;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report","arguments":{"state":"blocked","summary":"need a token","dry_run":true}}}' \
  | real /dev/null sh -c 'TMUX=$0 TMUX_PANE=$1; export TMUX TMUX_PANE; shift 2; exec "$@"' \
      "$SOCK,1,0" "$CP" python3 "$R/bin/fleet-mcp.py" > "$R/report.out"
tool=$(python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read())["result"]["structuredContent"]; print(d["stdout"]+d["stderr"]+"rc=%d" % d["exit"])' "$R/report.out")
[ "$hand" = "$tool" ] || fail "I: report --dry-run differs between the script and the tool" "by hand: $hand
by tool: $tool"
ok "I the same inputs: real fleet-comment.sh posts the byte-identical comment by hand and by tool; real report --dry-run (isolated tmux, parent resolved) prints the same envelope"
# --- J: the worker credential (issue #1809) -----------------------------------
G="$WORK/cred"; mkdir -p "$G/conf" "$G/sbin"
cat >> "$WORK/bin/fleet-lib.sh" <<'SH'
fleet_uuid() { printf '11111111-2222-4333-8444-555555555555'; }
fleet_window_fid() { tmux set-window-option -t "$2" @fleet_id 99999999-0000-4000-8000-000000000000; printf '99999999-0000-4000-8000-000000000000'; }
SH
# A tmux whose pane options come from the environment: FAKE_FID is the window's
# @fleet_id; every set-* is recorded, so the leak check reads what tmux was told.
cat > "$G/sbin/tmux" <<SH
#!/bin/sh
case "\$1" in
  set-option|set-window-option|set-environment) printf '%s\n' "\$*" >> "$G/tmux-sets"; exit 0 ;;
  display-message) ;;
  *) exec "$WORK/tmux" "\$@" ;;
esac
for fmt in "\$@"; do :; done
case "\$fmt" in
  '#{@fleet_id}') printf '%s\n' "\${FAKE_FID:-}" ;;
  '#{window_id}') printf '@1\n' ;;
  '#{?@fleet_id,'*) printf '%s\n' "\${FAKE_FID:-issue-1809}" ;;
  '#{@repo}'*) printf 'acme/app\t1809\tissue-77\n' ;;
  *) exec "$WORK/tmux" "\$@" ;;
esac
SH
chmod +x "$G/sbin/tmux"
FID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
gsrv() { # gsrv <out> — one stdio session as a pane of fleet `tf`, credential from $CRED
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u FLEET_WORKER_CRED PATH="$G/sbin:$PATH" TMUX="${GTMUX:-1}" \
    TMUX_PANE="${GPANE:-%1}" FLEET_CONF_DIR="$G/conf" FLEET_MCP_LOG="$G/calls.log" FAKE_FID="${PANE_FID-$FID}" \
    ${CRED:+FLEET_WORKER_CRED="$CRED"} python3 "$WORK/bin/fleet-mcp.py" > "$1"
}
gcred() { # gcred <action> — fleet-mcp.py --cred <action> as the pane, credential from $CRED
  env -u FLEET_WORKER_CRED PATH="$G/sbin:$PATH" TMUX=1 TMUX_PANE=%1 FLEET_CONF_DIR="$G/conf" FAKE_FID="$FID" \
    FLEET_CRED_FID_WAIT=0 ${CRED:+FLEET_WORKER_CRED="$CRED"} python3 "$WORK/bin/fleet-mcp.py" --cred "$1"
}
# py <code> [args] — run python with fleet-mcp.py imported as m (FLEET_CONF_DIR = the sandbox's)
py() {
  code=$1; shift
  env FLEET_CONF_DIR="$G/conf" python3 -c "import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('m', '$WORK/bin/fleet-mcp.py'); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
$code" "$@"
}
# verdict <file> <id> → ok | refused:<text>
verdict() {
  python3 -c 'import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get("id") == int(sys.argv[2]):
        res = r["result"]
        print("refused:" + res["content"][0]["text"] if res.get("isError") else "ok")' "$1" "$2"
}

CRED=$(CRED='' gcred mint) || fail "J: --cred mint failed"
case "$CRED" in fwc1.*.*) : ;; *) fail "J: the minted credential has the wrong form" ;; esac
mode=$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$G/conf/worker-cred/key")
[ "$mode" = 600 ] || fail "J: the login key is $mode, not 0600"
claims=$(gcred check) || fail "J: a fresh credential does not verify"
python3 -c 'import json, sys
c = json.loads(sys.argv[1])
assert c["fid"] == sys.argv[2] and c["fleet"] == "tf", c
assert c["worker_id"] == "11111111-2222-4333-8444-555555555555/" + sys.argv[2], c
assert (c["repo"], c["issue"], c["origin"], c["key"]) == ("acme/app", "1809", "issue-77", "issue-1807"), c
assert c["exp"] - c["iat"] == 24 * 3600 and len(c["nonce"]) >= 16, c' "$claims" "$FID" \
  || fail "J: the claims are wrong" "$claims"
ok "J mint: the pane's session (fid, fleet, worker_id, repo/issue/origin), 24h, key 0600"

# A valid credential runs the tool; the log names the session.
: > "$LOG"; : > "$G/calls.log"
call 70 spawn '{"issue":5}' | gsrv "$G/ok"
[ "$(verdict "$G/ok" 70)" = ok ] || fail "J: a valid credential was refused" "$(cat "$G/ok")"
grep -q '^dash-issue-session.sh 5$' "$LOG" || fail "J: the spawn did not run" "$(cat "$LOG")"
grep -q "tool=spawn via=cred who=11111111-2222-4333-8444-555555555555/$FID verdict=exit=2" "$G/calls.log" \
  || fail "J: the call log does not name the session" "$(cat "$G/calls.log")"
call 71 status '{}' | gsrv "$G/st"
grep -q "identity: 11111111-2222-4333-8444-555555555555/$FID (credential" "$G/st" \
  || fail "J: status does not show the identity" "$(cat "$G/st")"
ok "J a valid credential runs the tool; the call log and status name the worker_id"

# A migrated session: another pane, a new window carrying the same @fleet_id.
: > "$LOG"
call 72 spawn '{"issue":6}' | GPANE=%9 gsrv "$G/mig"
[ "$(verdict "$G/mig" 72)" = ok ] || fail "J: the same session in a new window was refused" "$(cat "$G/mig")"
grep -q '^dash-issue-session.sh 6$' "$LOG" || fail "J: the migrated session's spawn did not run" "$(cat "$LOG")"
ok "J the same session (same @fleet_id) in a new window — a migration — still holds"

# Refusals: each answered with why, logged via=badcred, nothing ran.
refused() { # refused <label> <expected text> — reads $G/r
  v=$(verdict "$G/r" 80)
  case "$v" in refused:*"$2"*"Nothing ran."*) : ;; *) fail "J: $1 was not refused" "$v" ;; esac
  [ ! -s "$LOG" ] || fail "J: $1 ran a script" "$(cat "$LOG")"
  grep -q "tool=spawn via=badcred .*verdict=refused" "$G/calls.log" || fail "J: $1 not logged" "$(cat "$G/calls.log")"
  ok "J refused: $1"
  : > "$LOG"; : > "$G/calls.log"
}
: > "$LOG"; : > "$G/calls.log"
EXPIRED=$(py 'c = m.cred_verify(sys.argv[1]); c["exp"] = 1000; print(m.cred_sign(c, m.cred_key()))' "$CRED")
call 80 spawn '{"issue":5}' | CRED=$EXPIRED gsrv "$G/r"; refused "an expired credential" "expired"
FORGED=$(env FLEET_CONF_DIR="$G/other" python3 -c "import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('m', '$WORK/bin/fleet-mcp.py'); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.cred_sign(json.loads(sys.argv[1]), m.cred_key(create=True)))" "$claims")
call 80 spawn '{"issue":5}' | CRED=$FORGED gsrv "$G/r"; refused "a forged credential (another login's key)" "signature"
call 80 spawn '{"issue":5}' | CRED="${CRED%??}xx" gsrv "$G/r"; refused "a tampered signature" "signature"
call 80 spawn '{"issue":5}' | PANE_FID=dddddddd-0000-4000-8000-000000000000 gsrv "$G/r"
refused "another session's pane (a spawn as someone else's parent)" "is not the credential's session"
call 80 spawn '{"issue":5}' | GTMUX=/tmp/tmux-501/other,1,0 gsrv "$G/r"; refused "another fleet" "credential is for fleet tf"

# Renewal keeps the session and the nonce, with a fresh 24h.
py 'old = m.cred_verify(sys.argv[1])
m.HELD["cred"] = m.cred_sign(dict(old, iat=old["iat"] - 7200, exp=old["exp"] - 7200), m.cred_key())
m.cred_renew()
new = m.cred_verify(m.HELD["cred"])
assert new["nonce"] == old["nonce"] and new["fid"] == old["fid"] and new["exp"] >= old["exp"], (old, new)' "$CRED" \
  || fail "J: renewal is wrong"
ok "J renewal: same session and nonce, a fresh 24h"

# Revoked (the session exited): refused from then on.
gcred revoke || fail "J: --cred revoke failed"
call 80 spawn '{"issue":5}' | gsrv "$G/r"; refused "a revoked credential (its session exited)" "revoked"
gcred check >/dev/null 2>&1 && fail "J: --cred check passed a revoked credential"

# No credential: as before, by the window's options — and the log says so.
call 81 spawn '{"issue":5}' | CRED='' PANE_FID='' gsrv "$G/n"
[ "$(verdict "$G/n" 81)" = ok ] || fail "J: a call without a credential was refused" "$(cat "$G/n")"
grep -q 'tool=spawn via=marker who=issue-1809 verdict=exit=2' "$G/calls.log" \
  || fail "J: a call without a credential is not logged as via=marker" "$(cat "$G/calls.log")"
ok "J no credential: runs as before, logged via=marker"

# The credential is in no file the run left behind — the call log, the key dir,
# the revoked list, every tmux option set, every reply.
for c in "$CRED" "$EXPIRED"; do
  hits=$(grep -rlF "${c##*.}" "$WORK" 2>/dev/null)
  [ -z "$hits" ] || fail "J: the credential leaked into a file" "$hits"
done
ok "J the credential appears in no file, log, reply or tmux option"

# --- K: the hub route — a worker assertion (issue #1810) ----------------------
# A session's spawn / await / send hand their script $FLEET_WORKER_ASSERT only when
# the hub is on for this fleet AND the call's credential held; it verifies against
# HashToken(node token) and names the session. With no hub configured: no
# assertion, and not one network request — from the server or anything it ran.
K="$WORK/hub"; mkdir -p "$K/py"
cat >> "$WORK/bin/fleet-lib.sh" <<'SH'
fleet_hub_on() { [ "${CCQUOTA_FLEET:-0}" = 1 ]; }
_fleet_node_env_val() { [ -r "$FLEET_CONF_DIR/node.env" ] || return 1; sed -n "s/^$1=//p" "$FLEET_CONF_DIR/node.env" | head -n 1; }
SH
# The scripts record whether they were handed an assertion (its value to a file).
for sc in dash-issue-session.sh fleet-await.sh fleet-peer-send.sh; do
  printf '#!/bin/sh\n[ "%s" = fleet-peer-send.sh ] && cat >/dev/null\nprintf "%%s %%s\\n" "%s" "${FLEET_WORKER_ASSERT:-none}" >> "%s"\necho done\n' \
    "$sc" "$sc" "$K/asserts" > "$WORK/bin/$sc"
  chmod +x "$WORK/bin/$sc"
done
# Any network a Python process opens (the server, or a script it runs) is logged.
cat > "$K/py/sitecustomize.py" <<PY2
import socket
_log = "$K/net"
def _deny(*a, **k):
    open(_log, "a").write("network: %r\\n" % (a[:2],))
    raise OSError("no network in this selftest")
socket.socket.connect = _deny
socket.create_connection = _deny
socket.getaddrinfo = _deny
PY2
printf '#!/bin/sh\necho "$0 $*" >> "%s"\nexit 1\n' "$K/net" > "$G/sbin/curl"
cp "$G/sbin/curl" "$G/sbin/ccquota"; chmod +x "$G/sbin/curl" "$G/sbin/ccquota"
ksrv() { # ksrv <out> [CCQUOTA_FLEET value] — gsrv, with the hub variable chosen
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u CCQUOTA_TOKEN -u FLEET_WORKER_CRED -u FLEET_WORKER_ASSERT \
    ${2:+CCQUOTA_FLEET="$2"} PYTHONPATH="$K/py" PATH="$G/sbin:$PATH" TMUX=1 TMUX_PANE=%1 \
    FLEET_CONF_DIR="$G/conf" FLEET_MCP_LOG="$G/calls.log" FAKE_FID="$FID" \
    ${CRED:+FLEET_WORKER_CRED="$CRED"} python3 "$WORK/bin/fleet-mcp.py" > "$1"
}
kcalls() {
  call 90 spawn '{"issue":5}'; call 91 await '{"issue":5,"timeout":5}'; call 92 send '{"to":"issue:77","text":"hi"}'
}
CRED=$(CRED='' gcred mint) || fail "K: --cred mint failed"
rm -f "$G/conf/node.env"; : > "$K/asserts"; : > "$K/net"; : > "$G/calls.log"
kcalls | ksrv "$K/d"
[ "$(grep -c ' none$' "$K/asserts")" = 3 ] || fail "K: with no hub a script was handed an assertion" "$(cat "$K/asserts")"
[ ! -s "$K/net" ] || fail "K: with no hub something opened the network" "$(cat "$K/net")"
grep -q 'hub=' "$G/calls.log" && fail "K: with no hub the call log says an assertion went out" "$(cat "$G/calls.log")"
ok "K no hub: spawn/await/send run with no assertion and not one network request (server, scripts, curl, ccquota)"

# The fleet runs with the hub but this node has no token: still nothing.
: > "$K/asserts"
kcalls | ksrv "$K/t" 1
[ "$(grep -c ' none$' "$K/asserts")" = 3 ] || fail "K: no node token, yet an assertion" "$(cat "$K/asserts")"
ok "K hub on, no node token: no assertion"

# Hub on + node token: each of the three gets one, signed for THIS node, naming the session.
printf 'CCQUOTA_TOKEN=ccq_selftest\nCCQUOTA_HUB_URL=http://127.0.0.1:9\n' > "$G/conf/node.env"
: > "$K/asserts"; : > "$K/net"; : > "$G/calls.log"
kcalls | ksrv "$K/h" 1
python3 - "$K/asserts" "$FID" <<'PY2' || fail "K: the assertion is wrong" "$(cat "$K/asserts")"
import base64, hashlib, hmac, json, sys, time
rows = [l.split(" ", 1) for l in open(sys.argv[1]).read().splitlines()]
assert [r[0] for r in rows] == ["dash-issue-session.sh", "fleet-await.sh", "fleet-peer-send.sh"], rows
key = hashlib.sha256(b"ccq_selftest").hexdigest().encode()
for script, a in rows:
    head, sig = a.rsplit(".", 1)
    assert head.startswith("fwa1."), a
    want = base64.urlsafe_b64encode(hmac.new(key, head.encode(), hashlib.sha256).digest()).decode().rstrip("=")
    assert hmac.compare_digest(want, sig), "signature does not verify with HashToken(node token)"
    c = json.loads(base64.urlsafe_b64decode(head.split(".")[1] + "=" * 4))
    assert c["worker_id"] == "11111111-2222-4333-8444-555555555555/" + sys.argv[2], c
    assert (c["fid"], c["key"], c["repo"], c["issue"], c["origin"]) == (sys.argv[2], "issue-1807", "acme/app", "1809", "issue-77"), c
    ttl = c["exp"] - c["iat"]
    assert ttl == (24 * 3600 if script == "fleet-peer-send.sh" else 600), (script, ttl)
    assert abs(c["iat"] - time.time()) < 60, c
PY2
[ ! -s "$K/net" ] || fail "K: the server itself opened the network" "$(cat "$K/net")"
[ "$(grep -c 'via=cred .* hub=asserted' "$G/calls.log")" = 3 ] || fail "K: the call log does not say an assertion went out" "$(cat "$G/calls.log")"
ok "K hub on: spawn/await/send each handed an assertion — HMAC(HashToken(node token)), the session's worker_id/key/repo/issue/origin, 10 min (a message: 24h)"

# No credential (or one that does not hold): never an assertion, even with the hub on.
: > "$K/asserts"
kcalls | CRED='' ksrv "$K/n" 1
[ "$(grep -c ' none$' "$K/asserts")" = 3 ] || fail "K: a call with no credential was handed an assertion" "$(cat "$K/asserts")"
ok "K hub on, no credential: no assertion (the node speaks for itself, as before)"

# The real fleet_hub_put carries it as the relay's `worker`; absent = byte for byte as before.
put() {
  FLEET_CONF_DIR="$K/conf" CCQUOTA_FLEET=1 bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1
    f=$(fleet_hub_put message 11111111-2222-4333-8444-555555555555/issue-1 \
          11111111-2222-4333-8444-666666666666/issue-2 s1 "{\"text\":\"hi\"}") && cat "$f" && rm -f "$f"' put "$BIN"
}
plain=$(unset FLEET_WORKER_ASSERT; put)
[ "$plain" = '{"id":"11111111-2222-4333-8444-555555555555/issue-1#s1","kind":"message","from":"11111111-2222-4333-8444-555555555555/issue-1","to":"11111111-2222-4333-8444-666666666666/issue-2","payload":{"text":"hi"}}' ] \
  || fail "K: fleet_hub_put with no assertion is not byte for byte as before" "$plain"
signed=$(FLEET_WORKER_ASSERT=fwa1.e30.c2ln put)
python3 -c 'import json, sys; r = json.loads(sys.argv[1]); assert r["worker"] == "fwa1.e30.c2ln" and r["payload"] == {"text": "hi"}, r' "$signed" \
  || fail "K: fleet_hub_put does not carry the assertion" "$signed"
ok "K fleet_hub_put: the relay carries it as \`worker\`; with none, the file is byte for byte as before"
# --- L: the rest of a worker skill (issue #1811) --------------------------------
: > "$LOG"
{
  call 100 brief '{"kind":"resume","issue":5}'
  call 101 file_issue '{"title":"x","spawn":true,"bind":true}'
  call 102 gh '{"kind":"pull","number":5}'
  call 103 gh '{"kind":"pr","number":5,"max_age":-1}'
  call 104 transfer '{"action":"arm","to":"codex"}'
  call 105 transfer '{"action":"check","to":"codex","handoff":"/n.md"}'
  call 106 transfer '{"action":"arm","to":"gemini","handoff":"/n.md"}'
  call 107 handoff '{"action":"arm"}'
  call 108 handoff '{"action":"arm","doc":"/d.md","issue":5}'
  call 109 handoff '{"action":"arm","doc":"/d.md","slug":"x"}'
  call 110 handoff '{"action":"path","repo":"acme/app"}'
  call 111 file_issue '{"title":"x","repo":"acme/zzz"}'
  call 112 show '{"inline":true}'
  call 113 open '{"target":""}'
} | serve "$WORK/j1"
python3 - "$WORK/j1" <<'PY' || fail "L: a C9 refusal is wrong" "$(cat "$WORK/j1")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
want = {100: "resume takes no issue", 101: "spawn and bind are exclusive", 102: "must be one of",
        103: "must be ≥ 0", 104: "arm needs handoff", 105: "check takes no handoff", 106: "must be one of",
        107: "exactly one of doc", 108: "exactly one of doc", 109: "arm takes no slug",
        110: "repo applies to arm only", 111: "not hosted by this fleet", 112: 'missing required argument "file"',
        113: "non-empty string"}
for i, w in want.items():
    r = rows[i]
    assert r.get("isError"), (i, r)
    t = r["content"][0]["text"]
    assert w in t and t.endswith("Nothing ran."), (i, t)
PY
grep -v '^fleet-repo.sh list$' "$LOG" > "$WORK/j1.ran"
[ -s "$WORK/j1.ran" ] && fail "L: a refused C9 call ran a script" "$(cat "$WORK/j1.ran")"
: > "$LOG"; rm -f "$LOG.cycle"
{
  call 120 brief '{}'
  call 121 brief '{"issue":5,"repo":"acme/lib","no_comments":true}'
  call 122 brief '{"kind":"resume"}'
  call 123 file_issue '{"title":"follow-up","body":"why now","labels":"bug, area:dash","priority":"p2","parent":1811,"spawn":true}'
  call 124 file_issue '{"title":"scratch req","bind":true,"repo":"acme/lib"}'
  call 1241 file_issue '{"title":"master red","breakage":true,"spawn":true}'
  call 1242 file_issue '{"title":"same red","breakage_key":"aaaa111-0123456789ab"}'
  call 1243 file_issue '{"title":"master red, other bug","breakage":false}'
  call 125 gh '{"kind":"issue","number":5,"fields":"title,state"}'
  call 126 gh '{"kind":"pr","number":42,"fields":"state,mergeStateStatus","max_age":0}'
  call 127 gh '{"kind":"checks","number":42,"repo":"acme/app"}'
  call 128 context '{}'
  call 129 context '{"json":true}'
  call 130 transfer '{"action":"check","to":"codex"}'
  call 131 transfer '{"action":"arm","to":"claude","handoff":"/n.md","loop":"/l.json"}'
  call 132 transfer '{"action":"export_loop","transcript":"/t.jsonl","output":"/l.json"}'
  call 133 where '{"json":true}'
  call 134 show '{"file":"a.png"}'
  call 135 show '{"file":"-x.png","inline":true}'
  call 136 open '{"target":":5173/"}'
  call 137 handoff '{"action":"arm","doc":"/d.md"}'
} | serve "$WORK/j2"
python3 - "$WORK/j2" <<'PY' || fail "L: a C9 tool's result is wrong" "$(cat "$WORK/j2")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
for i, r in rows.items():
    assert not r.get("isError"), (i, r)
def sc(i): return rows[i]["structuredContent"]
assert (sc(133)["command"], sc(133)["exit"]) == ("fleet-client-where.sh", 3), sc(133)   # nobody connected = data
assert sc(137)["command"] == "fleet-handoff-cycle.sh" and sc(137)["exit"] == 0 and sc(137)["pid"] > 0, sc(137)
assert "end the turn" in sc(137)["stdout"], sc(137)
PY
# The detached helper was still running when the tool answered, and finishes on its own.
[ -f "$LOG.cycle" ] && fail "L: handoff arm waited for the cycle helper instead of detaching it"
i=0; while [ ! -f "$LOG.cycle" ] && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$LOG.cycle" ] || fail "L: the detached cycle helper never finished" "$(cat "$LOG")"
cat > "$WORK/j.want" <<'WANT'
fleet-claim-brief.sh
fleet-repo.sh list
fleet-claim-brief.sh --issue 5 --repo acme/lib --no-comments
fleet-compact-resume.sh --brief
fleet-issue-file.sh --title follow-up --body why now --label bug --label area:dash --priority p2 --parent 1811 --spawn
fleet-repo.sh list
fleet-issue-file.sh --title scratch req --repo acme/lib --bind
fleet-issue-file.sh --title master red --spawn --breakage
fleet-issue-file.sh --title same red --breakage-key aaaa111-0123456789ab
fleet-issue-file.sh --title master red, other bug --no-breakage
fleet-gh.sh issue view 5 --json title,state
fleet-gh.sh pr view 42 --json state,mergeStateStatus --max-age 0
fleet-repo.sh list
fleet-gh.sh pr checks 42 --repo acme/app
fleet-context.sh
fleet-context.sh --json
fleet-transfer.sh --session tf --window %1 --to codex --dry-run
fleet-transfer.sh --session tf --window %1 --to claude --handoff /n.md --loop /l.json --after-turn
fleet-loop.py from-claude --transcript /t.jsonl --output /l.json
fleet-client-where.sh --json
fleet-show.sh -- a.png
fleet-show.sh --inline -- -x.png
fleet-open.sh -- :5173/
fleet-handoff-cycle.sh --pane %1 --doc /d.md
WANT
sed 's/ $//' "$LOG" > "$WORK/j.got"   # a no-argument run logs "<name> "
diff "$WORK/j.want" "$WORK/j.got" > "$WORK/j.diff" || fail "L: a C9 tool ran the wrong argv" "$(cat "$WORK/j.diff")"
ok "L brief · file_issue · gh · context · transfer · where · show · open · handoff arm: refusals run nothing, exact argv, arm detaches"

# --- M: a new version, taken between calls (issue #1898) --------------------------
M="$WORK/reload"; mkdir -p "$M/tmp"
mkver() { # mkver <name> <children-script body> [python appended to fleet-mcp.py]
  mkdir -p "$M/$1/logs"; cp -R "$WORK/bin" "$M/$1/bin"
  printf '#!/bin/sh\n%s\n' "$2" > "$M/$1/bin/fleet-children.sh"; chmod +x "$M/$1/bin/fleet-children.sh"
  [ -n "${3:-}" ] && python3 - "$M/$1/bin/fleet-mcp.py" "$3" <<'PYX'
import sys
p, extra = sys.argv[1], sys.argv[2]
s = open(p).read()
anchor = "\n# The pre-#1807 fleet-peer server"
assert anchor in s
open(p, "w").write(s.replace(anchor, "\n" + extra + "\n" + anchor, 1))
PYX
  return 0
}
mkver v1 'sleep 2; echo v1-children'
mkver v2 'echo "v2-children exec=${FLEET_MCP_EXEC:-none}"' 'TOOLS["zz_new"] = (tool_context, dict(TOOLS["context"][1]))'
mkver v3 'echo v3-children' 'this is not python ('
mkver v4 'echo v4-children' 'TOOLS["zz_quiet"] = (tool_context, dict(TOOLS["context"][1]))'
ln -s "$M/v1" "$M/home"
CRED=$(CRED='' gcred mint) || fail "M: --cred mint failed"
cat > "$M/drive.py" <<'PYX'
import json, os, queue, subprocess, sys, threading, time
M, cmd = sys.argv[1], sys.argv[2:]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
inbox = queue.Queue()
threading.Thread(target=lambda: [inbox.put(json.loads(l)) for l in proc.stdout], daemon=True).start()
def send(obj):
    proc.stdin.write((json.dumps(obj) + "\n").encode()); proc.stdin.flush()
def req(i, method, params=None):
    send({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}})
def call(i, name):
    req(i, "tools/call", {"name": name, "arguments": {}})
def get(timeout=15):
    try:
        return inbox.get(timeout=timeout)
    except queue.Empty:
        sys.exit("M: no message within %ss (server pid %d alive=%s)" % (timeout, proc.pid, proc.poll() is None))
def text(msg):
    return msg["result"]["content"][0]["text"]
def names(msg):
    return sorted(t["name"] for t in msg["result"]["tools"])
def switch(to):
    tmp = M + "/home.tmp"; os.symlink(M + "/" + to, tmp); os.replace(tmp, M + "/home")
def check(cond, why):
    if not cond:
        sys.exit("M: " + why)
mode = os.environ.get("DRIVE", "main")
req(1, "initialize", {"protocolVersion": "2025-06-18"})
init = get()
check(init["result"]["capabilities"]["tools"].get("listChanged") is True, "initialize does not declare tools.listChanged: %s" % init)
req(2, "tools/list"); first = names(get())
check("zz_new" not in first and "children" in first, "v1 lists %s" % first)
if mode == "off":
    switch("v2"); call(3, "children"); m = get()
    check(m.get("id") == 3 and "v1-children" in text(m), "with FLEET_MCP_RELOAD=0 the call left v1: %s" % m)
    req(4, "tools/list"); m = get(); check(names(m) == first, "with FLEET_MCP_RELOAD=0 the list changed: %s" % names(m))
    print("off-ok"); sys.exit(0)
# a call in flight when the link moves: it finishes on v1, the next request execs v2
call(3, "children"); time.sleep(0.6); switch("v2"); call(4, "children")
m = get(); check(m.get("id") == 3 and "v1-children" in text(m), "the in-flight call was not finished by v1: %s" % m)
m = get(); check(m.get("method") == "notifications/tools/list_changed", "no list_changed after the switch: %s" % m)
m = get(); check(m.get("id") == 4 and "v2-children exec=none" in text(m), "the queued call was not served by v2 (or the handover leaked): %s" % m)
req(5, "tools/list"); m = get(); check("zz_new" in names(m), "v2's new tool is not listed: %s" % names(m))
call(6, "zz_new"); m = get(); check(m.get("id") == 6 and not m["result"].get("isError"), "the new tool does not run: %s" % m)
check(proc.poll() is None, "the server process ended")
# a broken new version: refused, v2 keeps serving, no list_changed
switch("v3"); call(7, "children"); m = get()
check(m.get("id") == 7 and "v2-children" in text(m), "a broken version was not refused: %s" % m)
# a quiet client: the poll takes the new version with nothing asked
switch("v4"); m = get(10)
check(m.get("method") == "notifications/tools/list_changed", "a quiet server did not reload on the poll: %s" % m)
req(8, "tools/list"); m = get(); check("zz_quiet" in names(m) and "zz_new" not in names(m), "v4's list is wrong: %s" % names(m))
call(9, "children"); m = get(); check("v4-children" in text(m), "v4 does not serve: %s" % m)
print("pid=%d" % proc.pid)
proc.stdin.close(); proc.wait(10)
PYX
mrun() { # mrun <log> — the driver, as a credentialed pane of fleet `tf`
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u FLEET_WORKER_CRED PATH="$G/sbin:$PATH" TMUX=1 TMUX_PANE=%1 \
    FLEET_CONF_DIR="$G/conf" FLEET_MCP_LOG="$1" FAKE_FID="$FID" FLEET_WORKER_CRED="$CRED" TMPDIR="$M/tmp" \
    FLEET_MCP_RELOAD_POLL_S=0.3 python3 "$M/drive.py" "$M" python3 "$M/home/bin/fleet-mcp.py" 2>&1
}
out=$(mrun "$M/calls.log") || fail "M: the reload session failed" "$out
$(cat "$M/calls.log" 2>/dev/null)"
pid=${out#pid=}
grep -q "tool=(reload) via=- who=pid$pid verdict=exec " "$M/calls.log" \
  && grep -q "tool=(reload) via=- who=pid$pid verdict=resumed " "$M/calls.log" \
  || fail "M: the exec + resume are not logged under the server's one pid ($pid)" "$(cat "$M/calls.log")"
grep -q "verdict=refused why=\"new version failed its probe" "$M/calls.log" \
  || fail "M: the broken version's refusal is not logged" "$(cat "$M/calls.log")"
[ "$(grep -c 'tool=children via=cred .*verdict=exit=0' "$M/calls.log")" = 4 ] && grep -q 'tool=zz_new via=cred .*verdict=exit=0' "$M/calls.log" \
  || fail "M: the credential did not hold across the exec" "$(cat "$M/calls.log")"
[ -z "$(ls -A "$M/tmp")" ] || fail "M: the carry file was left behind" "$(ls -la "$M/tmp")"
grep -rqF "$CRED" "$M/calls.log" "$M/tmp" && fail "M: the credential leaked into the call log"
rm -f "$M/home"; ln -s "$M/v1" "$M/home"
out=$(DRIVE=off FLEET_MCP_RELOAD=0 mrun "$M/off.log") && [ "$out" = off-ok ] || fail "M: FLEET_MCP_RELOAD=0 still reloaded" "$out"
grep -q 'tool=(reload)' "$M/off.log" && fail "M: FLEET_MCP_RELOAD=0 logged a reload" "$(cat "$M/off.log")"
ok "M a new version between calls: in-flight call finishes on the old, exec keeps pid + connection + credential, list_changed, new tool listed; broken version refused; quiet poll; off switch"

# --- N: the mod's fallback road — --spec and --call (issue #2057) ------------------
# A session launched before the service was mounted (--plugin-dir only) still carries
# the mod's fleet_status / fleet_spawn / fleet_await; the mod registers them from
# --spec and forwards every call to --call. Same identity, check, script, log.
# (K replaced spawn / await with its assertion tripwires: the plain fakes again.)
fake dash-issue-session.sh 'echo "spawned issue-$1"; echo "cap note" >&2; exit 2'
fake fleet-await.sh 'echo "MERGED #$1 pr=42"; exit 0'
cli() { # cli <out> <args…> — one command line in the sandbox (no hub, no credential)
  out=$1; shift
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u CCQUOTA_HUB_URL -u CCQUOTA_URL -u FLEET_WORKER_CRED \
    PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 FLEET_MCP_LOG="$WORK/n.log" python3 "$WORK/bin/fleet-mcp.py" "$@" > "$out" 2> "$out.err"
}
cli "$WORK/n.spec" --spec status spawn await; rc=$?
[ "$rc" = 0 ] || fail "N: --spec status spawn await exited $rc" "$(cat "$WORK/n.spec.err")"
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | serve "$WORK/n.list"
python3 - "$WORK/n.spec" "$WORK/n.list" <<'PY2' || fail "N: --spec is not the tools/list entry, byte for byte" "$(cat "$WORK/n.spec")"
import json, sys
spec = json.load(open(sys.argv[1]))
listed = {t["name"]: t for t in json.loads(open(sys.argv[2]).readline())["result"]["tools"]}
assert [s["name"] for s in spec] == ["status", "spawn", "await"], spec
for s in spec:
    assert s == listed[s["name"]], (s, listed[s["name"]])
    assert s["inputSchema"]["additionalProperties"] is False, s
PY2
cli "$WORK/n.bad" --spec status nope; rc=$?
[ "$rc" = 2 ] && grep -q 'unknown tool nope' "$WORK/n.bad.err" || fail "N: --spec of an unknown tool: exit $rc, want 2 naming it" "$(cat "$WORK/n.bad.err")"
cli "$WORK/n.bad" --spec; rc=$?
[ "$rc" = 2 ] || fail "N: a bare --spec exited $rc, want 2"
ok "N --spec status spawn await = the tools/list entries byte for byte, closed schemas; an unknown name exits 2"

# --call spawn: the script ran once with exactly the MCP argv; the text is the MCP
# text; exit 0 even though the script exited 2 (that exit is IN the text).
: > "$LOG"; : > "$WORK/n.log"
cli "$WORK/n.spawn" --call spawn '{"issue":12,"repo":"acme/lib"}'; rc=$?
[ "$rc" = 0 ] || fail "N: --call spawn exited $rc (the script's exit belongs in the text)" "$(cat "$WORK/n.spawn" "$WORK/n.spawn.err")"
grep -qx 'dash-issue-session.sh 12 --repo acme/lib' "$LOG" || fail "N: --call spawn ran the wrong argv" "$(cat "$LOG"; echo ---; cat "$WORK/n.spawn" "$WORK/n.spawn.err")"
[ "$(grep -c '^dash-issue-session.sh' "$LOG")" = 1 ] || fail "N: --call spawn ran the script more than once" "$(cat "$LOG")"
call 40 spawn '{"issue":12,"repo":"acme/lib"}' | serve "$WORK/n.mcp"
python3 - "$WORK/n.spawn" "$WORK/n.mcp" <<'PY2' || fail "N: --call's text differs from the tools/call text" "$(cat "$WORK/n.spawn" "$WORK/n.mcp")"
import json, sys
cli = open(sys.argv[1]).read()
mcp = json.loads(open(sys.argv[2]).readline())["result"]["content"][0]["text"]
assert cli == mcp + "\n", (cli, mcp)
assert cli.startswith("exit 2 · dash-issue-session.sh\nspawned issue-12\n[stderr]\ncap note"), cli
PY2
cli "$WORK/n.aw" --call await '{"issue":12}'; rc=$?
[ "$rc" = 0 ] && grep -qx 'fleet-await.sh 12 --timeout 540' "$LOG" || fail "N: --call await did not run fleet-await.sh 12 --timeout 540 (exit $rc)" "$(cat "$LOG")"
cli "$WORK/n.st" --call status '{}'; rc=$?
[ "$rc" = 0 ] && grep -q '^window: window issue-1807 · issue=1807' "$WORK/n.st" && grep -q 'acme/lib' "$WORK/n.st" \
  || fail "N: --call status did not print the status text (exit $rc)" "$(cat "$WORK/n.st" "$WORK/n.st.err")"
cli "$WORK/n.st0" --call status; rc=$?
[ "$rc" = 0 ] || fail "N: --call status with no arguments exited $rc"
grep -q 'tool=spawn via=marker who=- verdict=exit=2 road=call' "$WORK/n.log" || fail "N: the call log does not say road=call" "$(cat "$WORK/n.log")"
ok "N --call spawn/await/status: the script's exact argv once, the byte-identical tools/call text, exit 0 with the script's exit in the text; log road=call"

# Refusals: exit 1, the reason on stdout as the model reads it, nothing ran. Usage: exit 2.
: > "$LOG"
cli "$WORK/n.r1" --call spawn '{"issue":"12"}'; rc=$?
[ "$rc" = 1 ] && grep -q 'fleet.spawn: "issue" must be an integer' "$WORK/n.r1" || fail "N: a wrong type: exit $rc, want 1 with the reason" "$(cat "$WORK/n.r1" "$WORK/n.r1.err")"
cli "$WORK/n.r2" --call spawn '{"issue":12,"repo":"other/repo"}'; rc=$?
[ "$rc" = 1 ] && grep -q 'not hosted by this fleet' "$WORK/n.r2" || fail "N: an unhosted repo: exit $rc, want 1 with the reason" "$(cat "$WORK/n.r2")"
cli "$WORK/n.r3" --call spawn '{"issue":12,"force":true}'; rc=$?
[ "$rc" = 1 ] && grep -q 'unknown argument "force"' "$WORK/n.r3" || fail "N: an unknown argument: exit $rc, want 1" "$(cat "$WORK/n.r3")"
cli "$WORK/n.r4" --call nope '{}'; rc=$?
[ "$rc" = 1 ] && grep -q 'unknown tool' "$WORK/n.r4" || fail "N: an unknown tool: exit $rc, want 1" "$(cat "$WORK/n.r4")"
grep -q '^dash-issue-session.sh\|^fleet-await.sh' "$LOG" && fail "N: a refused --call ran a script" "$(cat "$LOG")"
cli "$WORK/n.u1" --call spawn 'not json'; rc=$?
[ "$rc" = 2 ] && grep -q 'not JSON' "$WORK/n.u1.err" || fail "N: non-JSON arguments: exit $rc, want 2" "$(cat "$WORK/n.u1.err")"
cli "$WORK/n.u2" --call spawn '[1]'; rc=$?
[ "$rc" = 2 ] || fail "N: a JSON list as arguments exited $rc, want 2"
cli "$WORK/n.u3" --call; rc=$?
[ "$rc" = 2 ] || fail "N: a bare --call exited $rc, want 2"
cli "$WORK/n.u4" --call spawn '{}' extra; rc=$?
[ "$rc" = 2 ] || fail "N: --call with a fourth word exited $rc, want 2"
ok "N --call refusals (type · unhosted repo · unknown argument · unknown tool): exit 1, the reason on stdout, nothing ran; non-JSON / a list / no tool / an extra word: exit 2"

# --- O: ask carries the decision format (issue #2669) -------------------------
# With bin/fleet_decision.py beside it: a field ⇒ 建议 / 不答按 / 截止 + the
# fleet:ask marker; no field + FLEET_STEWARD=0 ⇒ today's body byte for byte; no
# field + the steward on ⇒ the marker, a row that waits (「等你」).
cp "$BIN/fleet_decision.py" "$BIN/fleet-ui-lang.sh" "$WORK/bin/"
: > "$LOG"
{
  call 120 ask '{"question":"which repo owns this?"}'
  call 121 ask '{"question":"20 or 50?","suggest":"20","due":"90m"}'
} | FLEET_STEWARD=0 FLEET_UI_LANG=zh serve "$WORK/o"
{ call 122 ask '{"question":"which repo owns this?"}'; } | FLEET_STEWARD=1 FLEET_UI_LANG=zh serve "$WORK/o2"
python3 - "$WORK/o" "$WORK/o2" <<'PY' || fail "O: ask with the decision format" "$(cat "$WORK/o" "$WORK/o2")"
import json, sys
rows = {}
for f in sys.argv[1:]:
    rows.update({r["id"]: r["result"]["structuredContent"] for r in (json.loads(l) for l in open(f) if l.strip())})
assert rows[120]["body"] == "⛔ blocked: which repo owns this?", rows[120]
b = rows[121]["body"]
assert b.startswith("⛔ blocked: 20 or 50?\n\n- 建议：20\n- 不答按：20\n- 截止：") and "<!-- fleet:ask v=1 id=" in b, b
assert " kind=normal " in b and " suggest=20 " in b, b
b = rows[122]["body"]
assert b.startswith("⛔ blocked: which repo owns this?\n\n- 不答按：等你\n\n<!-- fleet:ask v=1 "), b
PY
rm -f "$WORK/bin/fleet_decision.py" "$WORK/bin/fleet-ui-lang.sh"
ok "O ask: a field ⇒ 建议/不答按/截止 + fleet:ask marker; steward off + no field ⇒ today's body; steward on ⇒ 等你 row"

printf 'fleet-mcp-selftest: %d passed\n' "$pass"
