#!/bin/sh
# fleet-mcp-selftest.sh — the fleet tool service's contract (issue #1807, EPIC #1813 C5).
#
# bin/fleet-mcp.py is the ONE stdio MCP server Claude and Codex sessions both mount
# (docs/dev/FLEET-MCP.md). Driven against fake scripts in a sandbox bin/:
#   A  initialize + tools/list: server `fleet`, exactly the seventeen core tools
#      (the dispatch group is `fleet-orch`'s — Q), every schema closed
#      (additionalProperties false)
#   B  refusals: an unknown argument, a wrong type, a missing argument, an
#      out-of-range timeout, a malformed repo, a repo this fleet does not host,
#      an unknown tool — each answered isError with the reason, and NOTHING ran
#   C  each tool runs its script once, with exactly its argv; the script's exit
#      code, stdout and stderr come back as they came (a non-zero exit is data)
#   D  degenerate (EPIC #1813 rule 1): no hub at all — every hub variable unset —
#      and every core tool is still listed, spawn / await still run
#   F  `--mount codex` derives Codex's -c value from conf/mcp-worker.json, with
#      the env Codex withholds and a per-call timeout an await fits in
#   G  报问记合 (issue #1808) refusals: each new tool's bad enum, bad combination,
#      wrong type — answered isError with the reason, and NOTHING ran
#   H  report · ask · handoff · pr_verdict · pr_merge each run their script with
#      exactly the documented argv, a body / doc on STDIN, and the exit code passes
#      through; ask writes no comment (issue #4898), it stamps the window red
#   I  script ≡ tool: the same inputs through the REAL fleet-report-parent.sh
#      --dry-run print the same envelope by hand and by tool
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
#   L  the rest of a worker skill (issue #1811): brief · context ·
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
#   P  spawn from any seat — a worker's too — runs dash-issue-session.sh (issue
#      #4591 lifted #2960's seat gate)
#   N  the mod's fallback road (issue #2057): `--spec status spawn await` prints
#      exactly the tools/list entries; `--call <tool> <json>` is one tools/call
#      from a command line — the same argv to the script, the byte-identical text
#      on stdout, exit 0 answered (the script's exit is in the text) / 1 refused
#      (the reason on stdout, nothing ran) / 2 usage; the call log says road=call
#   S  a fleet of two repos (issue #4761): send narrows issue:<N> by `repo`, by a
#      `<slug>:issue-<N>` key, else by the caller window's own repo; fid:<uuid> / a bare
#      @fleet_id goes as wid:<uuid>; spawn / await with no repo take the caller's;
#      a caller with no repo, or a one-repo fleet, hands the script no --repo
#   R2 one code (EPIC T644 C3): task answers the task's code as id; await task / id
#      take it (fleet-await.sh --task); a local ID's code stays the ID road
#   Q  two groups (issue #3113, EPIC #3111 C2): `--group orch` is the server
#      `fleet-orch` listing exactly spawn · await · children · answer_dialog · send · task · clear (T592)
#      `--list` prints each server's list; `fleet` still answers a dispatch-group
#      call (an old session's, road=legacy in the call log); a server that took over
#      from a pre-group version keeps listing all of them and hands that on; a session with
#      no fleet-orch beside it (FLEET_MCP_ORCH unset) gets the dispatch group listed on
#      `fleet` (issue #4703); --mount codex
#      --group orch derives from conf/mcp-orch.json and no plugin registers the server;
#      --bridge-seat is 0 in any fleet pane, never by role or @agent_spawn (#3118, #4703)
#   Q2 the dispatch group ships with the core (issue #4334); @agent_spawn gates nothing
#      (issue #4703): unset / 0 / 1 ⇒ --bridge-seat 0; the spawn tool hands back the
#      spawner's cap (2) and dedup (3) exits
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
SUT="$BIN/fleet-mcp.py"
[ -f "$SUT" ] || { echo "selftest: fleet-mcp.py missing" >&2; exit 2; }
[ -f "$BIN/../conf/mcp-worker.json" ] || { echo "selftest: conf/mcp-worker.json missing" >&2; exit 2; }
[ -f "$BIN/../conf/mcp-orch.json" ] || { echo "selftest: conf/mcp-orch.json missing" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-mcp.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/conf"
cp "$SUT" "$WORK/bin/fleet-mcp.py"
cp "$BIN/../conf/mcp-worker.json" "$WORK/conf/mcp-worker.json"
cp "$BIN/../conf/mcp-orch.json" "$WORK/conf/mcp-orch.json"
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
fake fleet-report-parent.sh 'echo "RECORDED: own result; RETIRED: Parent delivery"; exit 0'
fake set-claude-state.sh 'exit 0'
fakein fleet-handoff-file.sh 'echo "/h/$1"; [ "$1" = check ] && exit 3; exit 0'
fake fleet-pr-verdict.sh 'echo PENDING; exit 1'
fakein fleet-task-record.sh 'echo T7'
fake fleet-pr-merge.sh 'echo MERGED'
# the rest of a worker skill (issue #1811)
fake fleet-brief.sh 'echo "===== fleet ====="'
fake fleet-compact-resume.sh 'echo map'
fake fleet-context.sh 'echo "ctx 41% OK"'
fake fleet-transfer.sh 'echo /req/1'
fake fleet-client-where.sh 'echo "mac-b iTerm2"; exit 3'
fake fleet-show.sh 'echo "saved:/Users/p/Downloads/a.png"'
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
    *'#{@issue}'*) [ -n "${FAKE_NOISSUE:-}" ] || printf '1807\n' ;;
    *'#{@task}'*) printf '%s\n' "${FAKE_TASK:-}" ;;
    *'#{@agent_spawn}'*) printf '%s\n' "${FAKE_SPAWN:-}" ;;
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
# The dispatch group counts as mounted (FLEET_MCP_ORCH=1) unless FAKE_ORCH says
# otherwise; Claude Code's settings are the sandbox's, never the operator's.
mkdir -p "$WORK/claude"
serve() {
  out=$1; shift
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u CCQUOTA_HUB_URL -u CCQUOTA_URL -u FLEET_WORKER_CRED -u FLEET_MCP_EXEC \
    PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 CLAUDE_CONFIG_DIR="$WORK/claude" FLEET_MCP_ORCH="${FAKE_ORCH-1}" \
    python3 "$WORK/bin/fleet-mcp.py" "$@" > "$out"
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
assert set(tools) == {"status", "repos", "agents",
                      "ask", "handoff", "pr_verdict", "pr_merge",
                      "brief", "context", "transfer", "where", "show", "open",
                      "set_reap", "preview", "schedule", "dispatch"}, sorted(tools)
schema=tools["schedule"]["inputSchema"]
assert schema["properties"]["agent"]["enum"] == ["", "claude", "codex"]
assert not ({"login","owner","env","exec","credentials"} & set(schema["properties"]))
assert set(schema["properties"]["action"]["enum"]) == {"create","list","update","pause","resume","delete","run-now","runs"}
for t in tools.values():
    assert t["inputSchema"]["additionalProperties"] is False, t
    assert t["description"], t
assert tools["ask"]["inputSchema"]["required"] == ["question"]
for n in ("handoff",):
    assert len(tools[n]["inputSchema"]["required"]) == 1, n
for n in ("pr_verdict", "pr_merge"):       # pr is optional since #3602 (FLEET_LAND=fleet)
    assert "required" not in tools[n]["inputSchema"], n
    assert tools[n]["inputSchema"]["properties"]["pr"]["minimum"] == 1, n
PY
ok "A server \`fleet\`, the seventeen core tools, every schema closed"

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
  call 21 whats_new '{}'
} | serve "$WORK/b"
python3 - "$WORK/b" <<'PY' || fail "B: a bad call was not refused with its reason" "$(cat "$WORK/b")"
import json, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
want = {10: 'unknown argument "force"', 11: "must be an integer", 12: 'missing required argument "issue"',
        13: "≤ 570", 14: "owner/name", 15: "not hosted by this fleet", 16: "RETIRED",
        17: "takes no arguments", 18: "agent:<name> or fid:<uuid>", 19: "unknown tool",
        20: "must be an integer", 21: "unknown tool"}
for i, why in want.items():
    res = rows[i]["result"]
    assert res.get("isError") is True, (i, res)
    text = res["content"][0]["text"]
    assert why in text and "Nothing ran." in text, (i, text)
PY
# The repo check READS fleet-repo.sh list; nothing else may have run.
ran=$(grep -v '^fleet-repo.sh list$' "$LOG")
[ -z "$ran" ] || fail "B: a refused call ran a script" "$ran"
ok "B unknown arg · wrong type · missing · out of range · bad/unhosted repo · unknown tool · a removed tool: refused, nothing ran"

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
    if i in (31, 35, 37):
        assert r.get("isError") and "RETIRED" in r["content"][0]["text"], (i, r)
    else:
        assert not r.get("isError"), (i, r)
st = rows[30]["structuredContent"]
assert st["window"].startswith("window issue-1807 · issue=1807"), st
assert st["children"]["exit"] == 0 and st["children"]["stdout"] == "", st
assert st["repos"] == ["acme/app", "acme/lib"], st
assert "acme/lib" in rows[30]["content"][0]["text"]
assert rows[31]["isError"]
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
assert rows[35]["isError"]
assert rows[36]["structuredContent"]["receipt"] == "sent -> issue:99 (hello child)", rows[36]
assert rows[37]["isError"] and "PARENT_RETIRED" in rows[37]["content"][0]["text"], rows[37]
PY
grep -qx 'dash-issue-session.sh 12 --repo acme/lib' "$LOG" || fail "C: spawn ran the wrong argv" "$(cat "$LOG")"
! grep -q '^fleet-await.sh' "$LOG" || fail 'C: retired await ran a script'
: # child classification is historical; the retired children handler runs nothing
grep -qx 'fleet-peer-send.sh issue:99 -' "$LOG" && ! grep -q '^fleet-peer-send.sh @77 ' "$LOG" \
  || fail "C: send ran the wrong argv" "$(cat "$LOG")"
[ "$(grep -c '^dash-issue-session.sh' "$LOG")" = 1 ] && [ "$(grep -c '^fleet-await.sh' "$LOG")" = 0 ] \
  || fail "C: a write tool ran more than once" "$(cat "$LOG")"
ok "C status/repos/agents/spawn/send work; legacy children/await refuse without executing"

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
assert len(rows[1]["tools"]) == 17, rows[1]
assert rows[40]["structuredContent"]["exit"] == 2 and not rows[40].get("isError"), rows[40]
assert rows[41]["isError"] and "RETIRED" in rows[41]["content"][0]["text"], rows[41]
PY
! grep -q '^fleet-await.sh' "$LOG" || fail 'D: retired await ran a script'
ok "D no hub configured: seventeen core tools listed; spawn works and legacy await refuses immediately"

# --- F: the Codex mount, from the one definition ------------------------------
m=$(python3 "$WORK/bin/fleet-mcp.py" --mount codex) || fail "F: --mount codex failed"
case "$m" in
  'mcp_servers.fleet={command="bash",args=["-c",'*'fleet-mcp.py'*'],env_vars=["TMUX","TMUX_PANE",'*'"FLEET_WORKER_CRED","FLEET_MCP_BIN","FLEET_MCP_ORCH"],tool_timeout_sec=600}') : ;;
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
  call 56 comment '{"issue":5,"body":"x"}'
  call 59 evidence '{"action":"line"}'
  call 60 file_issue '{"title":"x"}'
  call 61 gh '{"kind":"pr","number":5}'
  call 64 handoff '{"action":"check"}'
  call 65 handoff '{"action":"find","slug":"x"}'
  call 66 handoff '{"action":"remove"}'
  call 67 pr_verdict '{"pr":12,"timeout":60}'
  call 68 pr_verdict '{"pr":12,"wait":true,"timeout":9999}'
  call 69 pr_merge '{"pr":12,"method":"rebase"}'
  call 70 pr_merge '{"pr":0}'
} | serve "$WORK/g"
python3 - "$WORK/g" <<'PY' || fail "G: a bad 报问记合 call was not refused with its reason" "$(cat "$WORK/g")"
import json, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
want = {50: "merged · blocked · failed · stopped · waiting", 51: "must be an integer", 52: "true or false",
        53: 'unknown argument "win"', 54: 'missing required argument "question"', 55: "question · permission",
        56: "unknown tool", 59: "unknown tool", 60: "unknown tool", 61: "unknown tool",
        64: "check needs doc", 65: "slug applies to path only",
        66: "path · find · repo · check", 67: "apply with wait only", 68: "≤ 570",
        69: 'unknown argument "method"', 70: "≥ 1"}
for i, why in want.items():
    res = rows[i]["result"]
    assert res.get("isError") is True, (i, res)
    text = res["content"][0]["text"]
    assert why in text and "Nothing ran." in text, (i, text)
PY
ran=$(grep -v '^fleet-repo.sh list$' "$LOG")
[ -z "$ran" ] || fail "G: a refused 报问记合 call ran a script" "$ran"
ok "G report · ask · handoff · pr_verdict · pr_merge: bad enum / combination / type refused; comment · evidence · file_issue · gh unknown (removed, #4898) — nothing ran"

# --- H: each new tool runs its script, argv exact, text on stdin --------------
: > "$LOG"
{
  call 80 report '{"state":"merged","pr":42,"summary":"landed it"}'
  call 81 ask '{"question":"which repo owns this?"}'
  call 82 ask '{"question":"push to prod?","kind":"permission","issue":77}'
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
    if i in (31, 35, 37):
        assert r.get("isError") and "RETIRED" in r["content"][0]["text"], (i, r)
    else:
        assert not r.get("isError"), (i, r)
def sc(i): return rows[i]["structuredContent"]
assert (sc(80)["command"], sc(80)["exit"]) == ("fleet-report-parent.sh", 0), sc(80)     # queued is data
assert rows[80]["content"][0]["text"].startswith("exit 0 · fleet-report-parent.sh\nRECORDED"), rows[80]
a = sc(81)
assert (a["command"], a["exit"]) == ("ask", 0), a          # no record: no script, no GitHub comment
assert a["body"] == "⛔ blocked: which repo owns this?", a
assert (a["state"]["command"], a["state"]["exit"]) == ("set-claude-state.sh", 0), a
assert "set-claude-state.sh" in rows[81]["content"][0]["text"], rows[81]
assert "parent" not in a
assert sc(82)["body"] == "⛔ blocked — needs authorization: push to prod?", sc(82)
assert sc(91)["exit"] == 3, sc(91)                                                     # check findings = data
assert (sc(92)["exit"], sc(92)["stdout"]) == (1, "PENDING\n"), sc(92)
assert sc(94)["stdout"] == "MERGED\n", sc(94)
PY
cat > "$WORK/h.want" <<'EOF'
fleet-report-parent.sh --state merged --pr 42 --summary landed it
set-claude-state.sh blocked
set-claude-state.sh blocked
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
ok "H report · ask · handoff · pr_verdict · pr_merge: exact argv, text on stdin, exit passes through; ask writes no comment"

# --- I: script ≡ tool, through the REAL scripts --------------------------------
# A second sandbox with the real fleet-report-parent.sh and its libraries.
R="$WORK/real"; mkdir -p "$R/bin" "$R/conf" "$R/gh"
for f in fleet-mcp.py fleet-report-parent.sh fleet_report_clip.py fleet-lib.sh fleet-client-core.sh fleet-agent-adapter.sh; do
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
  env -u TMUX -u TMUX_PANE -u FLEET_WORKER_CRED -u FLEET_WORKER_ASSERT -u CCQUOTA_FLEET -u FLEET_HUB_URL -u FLEET_REPO -u CF_REPO \
    FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$R/conf" GH_LOG="$log" PATH="$R/gh:$PATH" "$@"
}
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
tmux -S "$SOCK" set-window-option -t tf:issue-1808 @fleet_id 12345678-1234-4234-8234-123456789012
CP=$(tmux -S "$SOCK" display-message -p -t tf:issue-1808 '#{pane_id}')
# real() unsets TMUX; this leg puts the isolated pane back.
hand=$(real /dev/null sh -c 'TMUX=$0 TMUX_PANE=$1; export TMUX TMUX_PANE; shift 2; exec "$@"' \
  "$SOCK,1,0" "$CP" bash "$R/bin/fleet-report-parent.sh" --state blocked --summary 'need a token' --dry-run 2>&1; echo "rc=$?")
case "$hand" in *'RETIRED: Parent reports are disabled; would save own result blocked.'*) : ;;
  *) fail "I: the real report dry run did not resolve the parent" "$hand" ;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report","arguments":{"state":"blocked","summary":"need a token","dry_run":true}}}' \
  | real /dev/null sh -c 'TMUX=$0 TMUX_PANE=$1; export TMUX TMUX_PANE; shift 2; exec "$@"' \
      "$SOCK,1,0" "$CP" python3 "$R/bin/fleet-mcp.py" > "$R/report.out"
tool=$(python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read())["result"]["structuredContent"]; print(d["stdout"]+d["stderr"]+"rc=%d" % d["exit"])' "$R/report.out")
[ "$hand" = "$tool" ] || fail "I: report --dry-run differs between the script and the tool" "by hand: $hand
by tool: $tool $(cat "$R/report.out")"
ok "I the same inputs: real result --dry-run (isolated tmux, no parent delivery) prints the same result by hand and by tool"
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
# Alter a signed byte, not Base64 padding bits (xw -> xx decodes identically).
TAMPERED=$(py 'head, sig = sys.argv[1].rsplit(".", 1)
raw = m.b64d(sig); changed = bytes([raw[0] ^ 1]) + raw[1:]
assert changed != raw
print(head + "." + m.b64e(changed))' "$CRED")
call 80 spawn '{"issue":5}' | CRED="$TAMPERED" gsrv "$G/r"; refused "a tampered signature" "signature"
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
[ "$(grep -c ' none$' "$K/asserts")" = 2 ] || fail "K: with no hub a script was handed an assertion" "$(cat "$K/asserts")"
[ ! -s "$K/net" ] || fail "K: with no hub something opened the network" "$(cat "$K/net")"
grep -q 'hub=' "$G/calls.log" && fail "K: with no hub the call log says an assertion went out" "$(cat "$G/calls.log")"
ok "K no hub: spawn/send run with no assertion and not one network request (server, scripts, curl, ccquota)"

# The fleet runs with the hub but this node has no token: still nothing.
: > "$K/asserts"
kcalls | ksrv "$K/t" 1
[ "$(grep -c ' none$' "$K/asserts")" = 2 ] || fail "K: no node token, yet an assertion" "$(cat "$K/asserts")"
ok "K hub on, no node token: no assertion"

# Hub on + node token: each of the three gets one, signed for THIS node, naming the session.
printf 'CCQUOTA_TOKEN=ccq_selftest\nCCQUOTA_HUB_URL=http://127.0.0.1:9\n' > "$G/conf/node.env"
: > "$K/asserts"; : > "$K/net"; : > "$G/calls.log"
kcalls | ksrv "$K/h" 1
python3 - "$K/asserts" "$FID" <<'PY2' || fail "K: the assertion is wrong" "$(cat "$K/asserts")"
import base64, hashlib, hmac, json, sys, time
rows = [l.split(" ", 1) for l in open(sys.argv[1]).read().splitlines()]
assert [r[0] for r in rows] == ["dash-issue-session.sh", "fleet-peer-send.sh"], rows
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
[ "$(grep -c 'via=cred .* hub=asserted' "$G/calls.log")" = 2 ] || fail "K: the call log does not say an assertion went out" "$(cat "$G/calls.log")"
ok "K hub on: spawn/send each handed an assertion — HMAC(HashToken(node token)), the session's worker_id/key/repo/issue/origin, 10 min (a message: 24h)"

# No credential (or one that does not hold): never an assertion, even with the hub on.
: > "$K/asserts"
kcalls | CRED='' ksrv "$K/n" 1
[ "$(grep -c ' none$' "$K/asserts")" = 2 ] || fail "K: a call with no credential was handed an assertion" "$(cat "$K/asserts")"
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
  call 100 brief '{"kind":"resume","repo":"acme/app"}'
  call 101 brief '{"kind":"later"}'
  call 104 transfer '{"action":"arm","to":"codex"}'
  call 105 transfer '{"action":"check","to":"codex","handoff":"/n.md"}'
  call 106 transfer '{"action":"arm","to":"gemini","handoff":"/n.md"}'
  call 107 handoff '{"action":"arm"}'
  call 108 handoff '{"action":"arm","doc":"/d.md","issue":5}'
  call 109 handoff '{"action":"arm","doc":"/d.md","slug":"x"}'
  call 110 handoff '{"action":"path","repo":"acme/app"}'
  call 111 brief '{"repo":"acme/zzz"}'
  call 112 show '{"inline":true}'
  call 113 open '{"target":""}'
} | serve "$WORK/j1"
python3 - "$WORK/j1" <<'PY' || fail "L: a C9 refusal is wrong" "$(cat "$WORK/j1")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
want = {100: "resume takes no repo", 101: "must be one of", 104: "arm needs handoff", 105: "check takes no handoff", 106: "must be one of",
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
  call 123 brief '{"kind":"claim"}'
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
    if i in (31, 35, 37):
        assert r.get("isError") and "RETIRED" in r["content"][0]["text"], (i, r)
    else:
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
fleet-brief.sh
fleet-repo.sh list
fleet-brief.sh --repo acme/lib
fleet-compact-resume.sh --brief
fleet-brief.sh
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
ok "L brief · context · transfer · where · show · open · handoff arm: refusals run nothing, exact argv, arm detaches"

# --- M: a new version, taken between calls (issue #1898) --------------------------
M="$WORK/reload"; mkdir -p "$M/tmp"
mkver() { # mkver <name> <context-script body> [python appended to fleet-mcp.py]
  mkdir -p "$M/$1/logs"; cp -R "$WORK/bin" "$M/$1/bin"
  printf '#!/bin/sh\n%s\n' "$2" > "$M/$1/bin/fleet-context.sh"; chmod +x "$M/$1/bin/fleet-context.sh"
  [ -n "${3:-}" ] && python3 - "$M/$1/bin/fleet-mcp.py" "$3" <<'PYX'
import sys
p, extra = sys.argv[1], sys.argv[2]
s = open(p).read()
anchor = "\n# Two groups (issue #3113)"
assert anchor in s
open(p, "w").write(s.replace(anchor, "\n" + extra + "\n" + anchor, 1))
PYX
  return 0
}
mkver v1 'sleep 2; echo v1-context'
mkver v2 'echo "v2-context exec=${FLEET_MCP_EXEC:-none}"' 'TOOLS["zz_new"] = (tool_context, dict(TOOLS["context"][1]))'
mkver v3 'echo v3-context' 'this is not python ('
mkver v4 'echo v4-context' 'TOOLS["zz_quiet"] = (tool_context, dict(TOOLS["context"][1]))'
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
check("zz_new" not in first and "status" in first, "v1 lists %s" % first)
if mode == "off":
    switch("v2"); call(3, "context"); m = get()
    check(m.get("id") == 3 and "v1-context" in text(m), "with FLEET_MCP_RELOAD=0 the call left v1: %s" % m)
    req(4, "tools/list"); m = get(); check(names(m) == first, "with FLEET_MCP_RELOAD=0 the list changed: %s" % names(m))
    print("off-ok"); sys.exit(0)
# a call in flight when the link moves: it finishes on v1, the next request execs v2
call(3, "context"); time.sleep(0.6); switch("v2"); call(4, "context")
m = get(); check(m.get("id") == 3 and "v1-context" in text(m), "the in-flight call was not finished by v1: %s" % m)
m = get(); check(m.get("method") == "notifications/tools/list_changed", "no list_changed after the switch: %s" % m)
m = get(); check(m.get("id") == 4 and "v2-context exec=none" in text(m), "the queued call was not served by v2 (or the handover leaked): %s" % m)
req(5, "tools/list"); m = get(); check("zz_new" in names(m), "v2's new tool is not listed: %s" % names(m))
call(6, "zz_new"); m = get(); check(m.get("id") == 6 and not m["result"].get("isError"), "the new tool does not run: %s" % m)
check(proc.poll() is None, "the server process ended")
# a broken new version: refused, v2 keeps serving, no list_changed
switch("v3"); call(7, "context"); m = get()
check(m.get("id") == 7 and "v2-context" in text(m), "a broken version was not refused: %s" % m)
# a quiet client: the poll takes the new version with nothing asked
switch("v4"); m = get(10)
check(m.get("method") == "notifications/tools/list_changed", "a quiet server did not reload on the poll: %s" % m)
req(8, "tools/list"); m = get(); check("zz_quiet" in names(m) and "zz_new" not in names(m), "v4's list is wrong: %s" % names(m))
call(9, "context"); m = get(); check("v4-context" in text(m), "v4 does not serve: %s" % m)
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
[ "$(grep -c 'tool=context via=cred .*verdict=exit=0' "$M/calls.log")" = 4 ] && grep -q 'tool=zz_new via=cred .*verdict=exit=0' "$M/calls.log" \
  || fail "M: the credential did not hold across the exec" "$(cat "$M/calls.log")"
[ -z "$(ls -A "$M/tmp")" ] || fail "M: the carry file was left behind" "$(ls -la "$M/tmp")"
grep -rqF "$CRED" "$M/calls.log" "$M/tmp" && fail "M: the credential leaked into the call log"
rm -f "$M/home"; ln -s "$M/v1" "$M/home"
out=$(DRIVE=off FLEET_MCP_RELOAD=0 mrun "$M/off.log") && [ "$out" = off-ok ] || fail "M: FLEET_MCP_RELOAD=0 still reloaded" "$out"
grep -q 'tool=(reload)' "$M/off.log" && fail "M: FLEET_MCP_RELOAD=0 logged a reload" "$(cat "$M/off.log")"
ok "M a new version between calls: in-flight call finishes on the old, exec keeps pid + connection + credential, list_changed, new tool listed; broken version refused; quiet poll; off switch"

# --- M2: launched by a release's own path, it still follows the link (T598) --------
# A window a tool call spawned inherits its parent server's RESOLVED path, so its own
# server was launched as <root>/<sha>/bin/fleet-mcp.py: it never saw that file change
# and kept that release's scripts (EPIC T497 C19: a driver opened between two releases
# dispatched through a half-switched road). Such a server watches <root>/current (a
# managed machine) or ~/.claude/fleet beside fleet.versions/ (#1894) instead.
cat > "$M/drive2.py" <<'PYX'
import json, os, queue, subprocess, sys, threading
link, cmd = sys.argv[1], sys.argv[2:]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
inbox = queue.Queue()
threading.Thread(target=lambda: [inbox.put(json.loads(l)) for l in proc.stdout], daemon=True).start()
def send(i, method, params=None):
    proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}}) + "\n").encode())
    proc.stdin.flush()
def answer(i):
    seen = []
    while True:
        try:
            m = inbox.get(timeout=15)
        except queue.Empty:
            sys.exit("M2: no answer to %d (saw %s)" % (i, seen))
        if m.get("id") == i:
            return m["result"]["content"][0]["text"] if "result" in m and "content" in m["result"] else m, seen
        seen.append(m.get("method"))
def switch(to):
    tmp = link + ".tmp"; os.symlink(to, tmp); os.replace(tmp, link)
send(1, "initialize", {"protocolVersion": "2025-06-18"}); answer(1)
send(2, "tools/call", {"name": "context", "arguments": {}}); text, seen = answer(2)
if "new-context" not in text or "notifications/tools/list_changed" not in seen:
    sys.exit("M2: launched by the old release's path, the call was not served by the live one: %r %s" % (text, seen))
switch(os.environ["M2_NEXT"])
send(3, "tools/call", {"name": "context", "arguments": {}}); text, seen = answer(3)
if "next-context" not in text:
    sys.exit("M2: the next release was not taken through the link: %r %s" % (text, seen))
print("ok"); proc.stdin.close(); proc.wait(10)
PYX
m2run() { # m2run <link> <server path> <next>
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u FLEET_WORKER_CRED PATH="$G/sbin:$PATH" TMUX=1 TMUX_PANE=%1 \
    FLEET_CONF_DIR="$G/conf" FLEET_MCP_LOG="$M/m2.log" FAKE_FID="$FID" FLEET_WORKER_CRED="$CRED" TMPDIR="$M/tmp" \
    FLEET_MCP_RELOAD_POLL_S=0.3 M2_NEXT="$3" python3 "$M/drive2.py" "$1" python3 "$2" 2>&1
}
for leg in managed versions; do
  if [ "$leg" = managed ]; then R="$M/root-$leg"; L="$R/current"; else R="$M/home-$leg/.claude/fleet.versions"; L="$M/home-$leg/.claude/fleet"; fi
  mkver "${R#"$M"/}/aaaaaaa1" 'echo old-context'
  mkver "${R#"$M"/}/bbbbbbb2" 'echo new-context'
  mkver "${R#"$M"/}/ccccccc3" 'echo next-context'
  ln -s "$R/bbbbbbb2" "$L"
  out=$(m2run "$L" "$R/aaaaaaa1/bin/fleet-mcp.py" "$R/ccccccc3") && [ "$out" = ok ] \
    || fail "M2 ($leg): a server launched by a release's own path stayed on it" "$out
$(cat "$M/m2.log" 2>/dev/null)"
done
# not a release tree (no version link beside it): launched as is, nothing followed
mkver plain 'echo plain-context'
out=$(python3 - "$M/plain/bin/fleet-mcp.py" "$M/root-managed/aaaaaaa1/bin/fleet-mcp.py" <<'PYX'
import importlib.util, os, sys
for p, want in ((sys.argv[1], sys.argv[1]), (sys.argv[2], sys.argv[2].rsplit("/aaaaaaa1/", 1)[0] + "/current/bin/fleet-mcp.py")):
    spec = importlib.util.spec_from_file_location("m", p); m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    got = m.follow_link(p)
    assert os.path.realpath(os.path.dirname(got)) == os.path.realpath(os.path.dirname(want)), (p, got, want)
print("ok")
PYX
)
[ "$out" = ok ] || fail "M2: follow_link mapped the wrong path" "$out"
ok "M2 launched by a release's own path (<root>/<sha>/bin, fleet.versions/<sha>/bin): the first call is served by the live release, the next switch is taken; a plain tree is left as is"

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
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | serve "$WORK/n.list.orch" --group orch
python3 - "$WORK/n.spec" "$WORK/n.list" "$WORK/n.list.orch" <<'PY2' || fail "N: --spec is not the tools/list entry, byte for byte" "$(cat "$WORK/n.spec")"
import json, sys
spec = json.load(open(sys.argv[1]))
listed = {t["name"]: t for f in sys.argv[2:4] for t in json.loads(open(f).readline())["result"]["tools"]}
assert [s["name"] for s in spec] == ["status", "spawn", "await"], spec
for s in spec:
    if s["name"] == "await":
        assert "await" not in listed and "RETIRED" in s["description"]
    else:
        assert s == listed[s["name"]], (s, listed[s["name"]])
    assert s["inputSchema"]["additionalProperties"] is False, s
PY2
cli "$WORK/n.bad" --spec status nope; rc=$?
[ "$rc" = 2 ] && grep -q 'unknown tool nope' "$WORK/n.bad.err" || fail "N: --spec of an unknown tool: exit $rc, want 2 naming it" "$(cat "$WORK/n.bad.err")"
cli "$WORK/n.bad" --spec; rc=$?
[ "$rc" = 2 ] || fail "N: a bare --spec exited $rc, want 2"
ok "N --spec preserves retired await schema; active status/spawn match the tool list; an unknown name exits 2"

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
[ "$rc" = 1 ] && grep -q RETIRED "$WORK/n.aw" || fail "N: await did not retire" "$(cat "$WORK/n.aw")"
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

# --- O: ask's hints, and nobody answers at a deadline (issue #4337) ------------
# suggest / default / due ⇒ plain lines under the question off THE string table,
# no fleet:ask marker anything acts on; no field ⇒ the bare question byte for byte,
# whoever holds what; class is accepted and changes nothing. The parent gets the
# question + the hints over send; a parent that cannot be told is said, not fatal.
cp "$BIN/fleet-ui-lang.sh" "$WORK/bin/"
SEND_OK='text=$(cat); printf "sent -> %s (%s)\n" "$1" "$text"'
fake fleet-peer-send.sh "$SEND_OK"   # leg K left its assertion recorder here
: > "$LOG"
{
  call 120 ask '{"question":"which repo owns this?"}'
  call 121 ask '{"question":"20 or 50?","suggest":"20","due":"90m","default":"20","class":"never:money"}'
} | FLEET_UI_LANG=zh serve "$WORK/o"
fake fleet-peer-send.sh 'cat >/dev/null; echo "fleet-peer-send: parent is not a live session" >&2; exit 1'
{ call 122 ask '{"question":"nobody?"}'; } | FLEET_UI_LANG=zh serve "$WORK/o2"
fake fleet-peer-send.sh "$SEND_OK"
python3 - "$WORK/o" "$WORK/o2" <<'PY' || fail "O: ask's hints / parent copy" "$(cat "$WORK/o" "$WORK/o2")"
import json, sys
rows = {}
for f in sys.argv[1:]:
    rows.update({r["id"]: r["result"] for r in (json.loads(l) for l in open(f) if l.strip())})
sc = lambda i: rows[i]["structuredContent"]
assert sc(120)["body"] == "⛔ blocked: which repo owns this?", sc(120)
b = sc(121)["body"]
assert b == "⛔ blocked: 20 or 50?\n\n- 建议：20\n- 没人答时：20（仅提示，不会自动执行）\n- 希望在此前答复：90m", b
assert "fleet:ask" not in b, b
assert "parent" not in sc(121) and "parent" not in sc(122)
assert sc(122)["exit"] == 0 and sc(122)["state"]["exit"] == 0, sc(122)
PY
rm -f "$WORK/bin/fleet-ui-lang.sh"
[ "$(grep -c '^fleet-peer-send.sh @77 -$' "$LOG")" = 0 ] || fail "O: ask must not send a parent copy" "$(cat "$LOG")"
ok "O ask: hints are plain lines (no marker, class ignored), no field ⇒ the bare question; the question waits on its own Task without a Parent copy"

# --- R: the hub task record (issue #3330) -------------------------------------
# ask in a window with a record ⇒ the question on the RECORD (no comment, issue
# #4898), red all the same, issue or not; neither ⇒ the red stamp and the parent's
# copy alone. task ⇒ fleet-task-record.sh dispatch, the words on stdin; await takes
# a T<n> instead of an issue (exactly one).
: > "$LOG"
{ call 130 ask '{"question":"which one?"}'; } | FAKE_NOISSUE=1 FAKE_TASK=T7 serve "$WORK/r1"
{ call 131 ask '{"question":"push?"}'; } | FAKE_TASK=T7 serve "$WORK/r2"
{ call 132 ask '{"question":"nobody?"}'; } | FAKE_NOISSUE=1 serve "$WORK/r3"
{
  call 133 task '{"title":"看看风扇","body":"为什么一直转","spawn":true}'
  call 134 await '{"task":"T7","timeout":30}'
  call 135 await '{"issue":3,"task":"T7"}'
  call 136 await '{}'
} | serve "$WORK/r4"
python3 - "$WORK/r1" "$WORK/r2" "$WORK/r3" "$WORK/r4" <<'PY' || fail "R: the task record's tools" "$(cat "$WORK/r1" "$WORK/r2" "$WORK/r3" "$WORK/r4")"
import json, sys
rows = {}
for f in sys.argv[1:]:
    rows.update({r["id"]: r["result"] for r in (json.loads(l) for l in open(f) if l.strip())})
sc = lambda i: rows[i]["structuredContent"]
assert (sc(130)["command"], sc(130)["task"], sc(130)["body"]) == ("fleet-task-record.sh", "T7", "⛔ blocked: which one?"), sc(130)
assert sc(130)["state"]["command"] == "set-claude-state.sh" and "issue" not in sc(130), sc(130)
assert (sc(131)["command"], sc(131)["task"]) == ("fleet-task-record.sh", "T7"), sc(131)
assert (sc(132)["command"], sc(132)["exit"]) == ("ask", 0) and "task" not in sc(132), sc(132)
assert sc(133)["stdout"] == "T7\n", sc(133)
for i in (134, 135, 136):
    assert rows[i].get("isError") and "RETIRED" in rows[i]["content"][0]["text"], rows[i]
PY
cat > "$WORK/r.want" <<'EOF'
fleet-task-record.sh set T7 --asked ⛔ blocked: which one?
set-claude-state.sh blocked
fleet-task-record.sh set T7 --asked ⛔ blocked: push?
set-claude-state.sh blocked
set-claude-state.sh blocked
fleet-task-record.sh dispatch --title 看看风扇 --body-file - --spawn
<<<为什么一直转>
EOF
diff "$WORK/r.want" "$LOG" > "$WORK/r.diff" || fail "R: the task record's tools ran the wrong argv" "$(cat "$WORK/r.diff")"
ok "R ask → the record, else the red stamp alone (no comment); task → dispatch, words on stdin; legacy await refused"

# --- R2: one code (EPIC T644 C3) ----------------------------------------------
# task answers the task's code as `id` (stdout: code, then T<n>), T<n> only the
# alias; await takes it as task (code, #code, ID or T<n> — fleet-await.sh --task),
# and as id when no window's ID here answers to it; a code a window's ID does answer
# to stays the ID road. The schema says codes; a non-reference is refused.
cp "$BIN/fleet_id.py" "$WORK/bin/fleet_id.py"
export FLEET_ID_DIR="$WORK/ids"; mkdir -p "$FLEET_ID_DIR"
LFID=3fa85f64-5717-4562-b3fc-2c963f66afa6
python3 - "$WORK/bin" "$LFID" <<'PY' || fail "R2: a local ID for the ID road"
import sys; sys.path.insert(0, sys.argv[1]); import fleet_id
fleet_id.append(sys.argv[2], {"ev": "opened", "short": fleet_id.short_for(sys.argv[2], [])})
PY
LIDC=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_id; print(fleet_id.encode(sys.argv[2])[:4])' "$WORK/bin" "$LFID")
fakein fleet-task-record.sh 'printf "K7W0\nT7\n"'
: > "$LOG"
{
  call 140 task '{"title":"看看风扇"}'
  call 141 await '{"task":"K7W0","timeout":30}'
  call 142 await '{"task":"#k7","timeout":30}'
  call 143 await '{"id":"K7W0","timeout":30}'
  call 144 await '{"id":"'"$LIDC"'","timeout":30}'
  call 145 await '{"task":"K;7"}'
} | serve "$WORK/r5"
python3 - "$WORK/r5" "$WORK/bin/fleet-mcp.py" <<'PY' || fail "R2: one code" "$(cat "$WORK/r5")"
import importlib.util, json, re, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
t = rows[140]["result"]["structuredContent"]
assert (t["id"], t["short"], t["alias"], t["task"]) == ("K7W0", "K7W0", "T7", "T7") and "session_id" not in t, t
assert rows[145].get("error") or rows[145]["result"].get("isError"), rows[145]
spec = importlib.util.spec_from_file_location("m", sys.argv[2])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
pat = m.TASK_REF["pattern"]
for good in ("K7W0", "#k7", "T7", "3fa85f64-5717-4562-b3fc-2c963f66afa6"):
    assert re.match(pat, good), good
for bad in ("7", "K;7", "T-", ""):
    assert not re.match(pat, bad), bad
assert "T<n>" in m.TASK_REF["description"] and "code" in m.TASK_REF["description"]
PY
printf '%s\n' 'fleet-task-record.sh dispatch --title 看看风扇 --body-file -' '<<<>' > "$WORK/r5.want"
diff "$WORK/r5.want" "$LOG" > "$WORK/r5.diff" || fail "R2: the argv" "$(cat "$WORK/r5.diff")"
rm -f "$WORK/bin/fleet_id.py"; unset FLEET_ID_DIR
fakein fleet-task-record.sh 'echo T7'
ok "R2 one code: task answers its code as id (T<n> the alias); legacy await task/id refuse without running a script"

# --- P: any seat spawns, a worker's too (issue #4591 lifted #2960) ----------
# Even a lib whose fleet_spawn_refused still refused (an older one) gates nothing:
# the tool no longer asks it.
cat >> "$WORK/bin/fleet-lib.sh" <<'SH'
fleet_spawn_refused() { [ -n "${FAKE_WORKER_SEAT:-}" ]; }
SH
: > "$LOG"
call 130 spawn '{"issue":5}' | FAKE_WORKER_SEAT=1 serve "$WORK/p1"
call 131 spawn '{"issue":5}' | serve "$WORK/p2"
python3 - "$WORK/p1" "$WORK/p2" <<'PY' || fail "P: spawn from a worker seat" "$(cat "$WORK/p1" "$WORK/p2")"
import json, sys
for f in sys.argv[1:]:
    r = [json.loads(l) for l in open(f) if l.strip()][0]["result"]
    assert not r.get("isError") and r["structuredContent"]["command"] == "dash-issue-session.sh", r
PY
[ "$(grep -c '^dash-issue-session.sh' "$LOG")" = 2 ] || fail "P: both spawns ran their script" "$(cat "$LOG")"
ok "P spawn: a worker seat and any other run dash-issue-session.sh (no seat gate)"

# --- Q: two groups (issue #3113, EPIC #3111 C2) ------------------------------
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | serve "$WORK/q1" --group orch
python3 - "$WORK/q1" <<'PY' || fail "Q: --group orch is not the dispatch group" "$(cat "$WORK/q1")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert rows[1]["serverInfo"]["name"] == "fleet-orch", rows[1]
tools = {t["name"]: t for t in rows[2]["tools"]}
assert sorted(tools) == ["answer_dialog", "clear", "send", "spawn", "task"], sorted(tools)
assert tools["clear"]["inputSchema"]["required"] == ["id"]   # T592
assert tools["task"]["inputSchema"]["required"] == ["title"]   # issue #3330
assert "await" not in tools and "children" not in tools
assert tools["spawn"]["inputSchema"]["required"] == ["issue"]
assert tools["send"]["inputSchema"]["required"] == ["to", "text"]
for t in tools.values():
    assert t["inputSchema"]["additionalProperties"] is False, t
PY
cli "$WORK/q.l0" --list && cli "$WORK/q.l1" --group orch --list || fail "Q: --list exited non-zero" "$(cat "$WORK/q.l0.err" "$WORK/q.l1.err")"
[ "$(wc -l < "$WORK/q.l0" | tr -d ' ')" = 17 ] && ! grep -Eqx 'spawn|await|children|answer_dialog|send|task|clear' "$WORK/q.l0" \
  && [ "$(sort "$WORK/q.l1" | tr '\n' ' ')" = "answer_dialog clear send spawn task " ] \
  || fail "Q: --list is not each server's list" "$(cat "$WORK/q.l0"; echo ---; cat "$WORK/q.l1")"
cli "$WORK/q.bad" --group zz --list && fail "Q: --group zz was accepted"
# An old session (its list had spawn) calls it on `fleet`: answered, logged road=legacy.
: > "$LOG"; : > "$WORK/q.log"
{ call 140 spawn '{"issue":8}'; call 141 children '{}'; call 142 status '{}'; } | FLEET_MCP_LOG="$WORK/q.log" serve "$WORK/q2"
python3 - "$WORK/q2" <<'PY' || fail "Q: fleet no longer answers a dispatch-group call" "$(cat "$WORK/q2")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert rows[140]["structuredContent"]["command"] == "dash-issue-session.sh" and not rows[140].get("isError"), rows[140]
assert rows[141].get("isError") and "RETIRED" in rows[141]["content"][0]["text"], rows[141]
PY
grep -qx 'dash-issue-session.sh 8' "$LOG" || fail "Q: the legacy spawn did not run its script" "$(cat "$LOG")"
grep -q 'tool=spawn .*road=legacy' "$WORK/q.log" && grep -q 'tool=children .*road=legacy' "$WORK/q.log" \
  && ! grep -q 'tool=status .*road=legacy' "$WORK/q.log" \
  || fail "Q: the call log does not mark the dispatch-group calls on fleet road=legacy (and only them)" "$(cat "$WORK/q.log")"
# The same call on fleet-orch is its own tool: no legacy mark.
: > "$WORK/q.log"
call 143 spawn '{"issue":8}' | FLEET_MCP_LOG="$WORK/q.log" serve "$WORK/q3" --group orch
grep -q 'tool=spawn ' "$WORK/q.log" && ! grep -q 'road=legacy' "$WORK/q.log" || fail "Q: fleet-orch's own spawn was logged legacy" "$(cat "$WORK/q.log")"
# A takeover (#1898) from a pre-group version: its handover has no "list" — every tool
# stays listed (and the next handover says so); one from this version lists the core.
: > "$WORK/q4"
for st in '{"from":"a","to":"b"}' '{"from":"a","to":"b","list":"group"}' '{"from":"a","to":"b","list":"all"}'; do
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u FLEET_WORKER_CRED PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 \
      FLEET_MCP_ORCH=1 FLEET_MCP_EXEC="$st" FLEET_MCP_LOG="$WORK/q.rl.log" python3 "$WORK/bin/fleet-mcp.py" >> "$WORK/q4"
done
# …and a session launched before #4703 with no fleet-orch beside it (FLEET_MCP_ORCH
# unset): after this version's takeover `fleet` lists the dispatch group too, so it
# spawns without a reopen (issue #4703).
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u FLEET_WORKER_CRED -u FLEET_MCP_ORCH PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 \
    FLEET_MCP_EXEC='{"from":"a","to":"b","list":"group"}' FLEET_MCP_LOG="$WORK/q.rl.log" python3 "$WORK/bin/fleet-mcp.py" >> "$WORK/q4"
python3 - "$WORK/q4" <<'PY' || fail "Q: a takeover from a pre-group server dropped tools from its session's list" "$(cat "$WORK/q4")"
import json, sys
lists = [r["result"]["tools"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if "id" in r]
assert [len(x) for x in lists] == [22, 17, 22, 22], [len(x) for x in lists]   # + task (#3330), − #4904's four, − #4898's four, + clear (T592)
assert "spawn" in {t["name"] for t in lists[0]}
names = {t["name"] for t in lists[3]}
assert {"spawn", "answer_dialog", "send", "task", "clear"} <= names, sorted(names)
PY
grep -q '"list": "all" if SERVING\["list_all"\]' "$WORK/bin/fleet-mcp.py" \
  && grep -q 'SELF\] + sys.argv\[1:\]' "$WORK/bin/fleet-mcp.py" \
  || fail "Q: the handover no longer carries the list mode / the server's --group"
# The Codex mount is the one server, and no plugin registers it (issue #4334).
m=$(python3 "$WORK/bin/fleet-mcp.py" --mount codex --group orch) || fail "Q: --mount codex --group orch failed"
case "$m" in
  'mcp_servers.fleet-orch={command="bash",args=["-c",'*'fleet-mcp.py'*'--group orch'*'],env_vars=['*'"FLEET_MCP_ORCH"],tool_timeout_sec=600}') : ;;
  *) fail "Q: the Codex mount of the dispatch group is wrong" "$m" ;;
esac
# (no plugin registers the dispatch group — it ships with the core, #4334: conf/gone.list)
python3 - "$BIN/../conf/mcp-worker.json" "$BIN/../conf/mcp-orch.json" <<'PY' || fail "Q: the two configs do not name the two servers"
import json, sys
w, o = (json.load(open(f))["mcpServers"] for f in sys.argv[1:3])
assert set(w) == {"fleet"} and set(o) == {"fleet-orch"}, (w, o)
assert "--group orch" in " ".join(o["fleet-orch"]["args"]) and "--group" not in " ".join(w["fleet"]["args"])
PY
# no seat by role any more (issue #3118): a name is ignored, outside tmux nothing is one
! env -u TMUX python3 "$WORK/bin/fleet-mcp.py" --bridge-seat epic-driver \
  && ! env -u TMUX python3 "$WORK/bin/fleet-mcp.py" --bridge-seat \
  || fail "Q: --bridge-seat answers outside tmux"
ok "Q fleet-orch lists the dispatch group; fleet answers it road=legacy; a pre-group takeover keeps them all; a group-less session sees it on fleet; one server definition, no plugin's"

# --- Q2: the dispatch group ships with the core (issue #4334) -------------------
# @agent_spawn gates nothing (issue #4703, after #4591): unset, 0 or 1 ⇒ --bridge-seat 0
# the spawn tool hands the spawner's own refusals back — at the session cap it exits 2,
# an issue closed or already carrying a PR 3 — so those stay the only bounds.
rm -f "$WORK/claude/settings.json"
seat() { env PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 FAKE_SPAWN="$1" python3 "$WORK/bin/fleet-mcp.py" --bridge-seat; }
seat 1 && seat '' && seat 0 || fail "Q2: --bridge-seat still follows @agent_spawn"
ok "Q2 @agent_spawn unset / 0 / 1 ⇒ the session may spawn (--bridge-seat)"
for rc in 2 3; do
  fake dash-issue-session.sh "echo refused >&2; exit $rc"
  call 163 spawn '{"issue":7}' | FAKE_ORCH='' FAKE_SPAWN=0 serve "$WORK/q.rc$rc" --group orch
  python3 - "$WORK/q.rc$rc" "$rc" <<'PY' || fail "Q2: spawn did not hand back the spawner's exit $rc" "$(cat "$WORK/q.rc$rc")"
import json, sys
r = json.loads(open(sys.argv[1]).readline())["result"]
assert r["structuredContent"]["exit"] == int(sys.argv[2]), r
PY
done
ok "Q2 spawn hands back the cap (exit 2) and the dedup (exit 3) as the spawner said"
# …and the spawners of a session the person opens (no agent file, no issue) stamp it
# BEFORE the launch: dash-raw-session.sh, fleet-restore.sh.
for f in dash-raw-session.sh fleet-restore.sh; do
  grep -q 'fleet_win_stamp_cmd @agent_spawn 1' "$BIN/$f" || fail "Q2: $f no longer stamps @agent_spawn 1 before the launch"
done
grep -q 'stamp_option @agent_spawn 1' "$BIN/dash-raw-session.sh" || fail "Q2: a scratch window keeps no @agent_spawn"
ok "Q2 the person's no-issue sessions are stamped @agent_spawn 1 before their launcher mounts the group"

# --- S: a fleet of two repos (issue #4761) -------------------------------------
cp "$WORK/bin/fleet-lib.sh" "$WORK/lib.keep"
cat >> "$WORK/bin/fleet-lib.sh" <<'SH'
fleet_repos() { printf 'acme/app\n'; [ -n "${FAKE_ONE_REPO:-}" ] || printf 'acme/lib\n'; }
fleet_slug() { printf '%s' "${1//\//-}"; }
fleet_target_repo() { [ -n "${FAKE_CALLER_REPO:-}" ] || return 4; printf '%s\n' "$FAKE_CALLER_REPO"; }
SH
FID=0f1e2d3c-4b5a-4697-8a8b-9c0d1e2f3a4b
: > "$LOG"
{
  call 170 send '{"to":"issue:99","text":"a"}'
  call 171 send '{"to":"acme-lib:issue-99","text":"b"}'
  call 172 send '{"to":"issue:99","repo":"acme/lib","text":"c"}'
  call 173 send '{"to":"fid:'"$FID"'","text":"d"}'
  call 174 send '{"to":"'"$FID"'","text":"e"}'
  call 175 send '{"to":"scratch-3","text":"f"}'
  call 176 spawn '{"issue":5}'
  call 177 await '{"issue":5,"timeout":5}'
  call 178 send '{"to":"nope-repo:issue-1","text":"x"}'
  call 179 send '{"to":"acme-lib:issue-99","repo":"acme/app","text":"x"}'
  call 180 send '{"to":"agent:steward","repo":"acme/app","text":"x"}'
} | FAKE_CALLER_REPO=acme/app serve "$WORK/s1"
python3 - "$WORK/s1" <<'PY' || fail "S: a two-repo send / spawn / await answered wrong" "$(cat "$WORK/s1")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert rows[177].get("isError") and "RETIRED" in rows[177]["content"][0]["text"]
for i in range(170, 177):
    assert not rows[i].get("isError"), (i, rows[i])
for i, why in {178: "names no repo this fleet hosts", 179: "but repo is", 180: "issue:<N> / scratch-<N> target only"}.items():
    assert rows[i].get("isError") and why in rows[i]["content"][0]["text"], (i, rows[i])
PY
want=$(cat <<EOF
fleet-peer-send.sh --repo acme/app issue:99 -
fleet-peer-send.sh --repo acme/lib issue-99 -
fleet-peer-send.sh --repo acme/lib issue:99 -
fleet-peer-send.sh wid:$FID -
fleet-peer-send.sh wid:$FID -
fleet-peer-send.sh scratch-3 -
dash-issue-session.sh 5 --repo acme/app
EOF
)
got=$(grep -v '^fleet-repo.sh list$' "$LOG")
[ "$got" = "$want" ] || fail "S: the scripts ran with the wrong argv" "$(printf 'want:\n%s\ngot:\n%s\n' "$want" "$got")"
ok "S two repos: issue:<N> takes repo, a <slug>: key, else the caller's repo; fid:<uuid> → wid:; spawn takes the caller's repo; legacy await refuses"
# A caller with no repo of its own, or a fleet of one repo: no --repo is invented.
for leg in norepo onerepo; do
  : > "$LOG"
  { call 181 send '{"to":"issue:99","text":"a"}'; call 182 spawn '{"issue":5}'; } \
    | if [ "$leg" = onerepo ]; then FAKE_ONE_REPO=1 FAKE_CALLER_REPO=acme/app serve "$WORK/s2"; else serve "$WORK/s2"; fi
  got=$(grep -v '^fleet-repo.sh list$' "$LOG")
  [ "$got" = "$(printf 'fleet-peer-send.sh issue:99 -\ndash-issue-session.sh 5')" ] \
    || fail "S: $leg handed the script a repo it did not ask for" "$got"
done
ok "S a caller with no repo, or a one-repo fleet: the scripts get no --repo (their own rule, byte for byte)"
cp "$WORK/lib.keep" "$WORK/bin/fleet-lib.sh"

printf 'fleet-mcp-selftest: %d passed\n' "$pass"
