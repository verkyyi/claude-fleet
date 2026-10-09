#!/usr/bin/env bash
# fleet-whats-new.sh — what changed in the fleet, for a session that is still
# working (issue #1897, EPIC #1906 C4).
#
#   fleet-whats-new.sh <old> <new>     the brief: ≤ 5 lines, only what touches a
#                                      working session (tools · worker skills ·
#                                      guards), the rest one 「另有 N 项内部改动」
#   fleet-whats-new.sh --full [<old> [<new>]]
#                                      every relevant change, no line cap; with no
#                                      <old>, THIS session's launch version
#                                      (@agent_ver) → the current one (fleet.whats_new)
#   fleet-whats-new.sh --hook          UserPromptSubmit (Claude + Codex): once per
#                                      session per version, the brief as
#                                      hookSpecificOutput.additionalContext
#
# The current version is the `ver` line of agent-cfg.expected (issue #1895, C2:
# the sha ~/.claude/fleet points at); a session's own is @agent_ver, stamped by
# its launcher. The hook tells a session once per version and stamps @ver_told
# with what it told; the next move is told from @ver_told. A session with
# neither stamp (launched before #1895) is baselined silently — nothing to diff
# from. No `ver` line expected (no versioned install), no pane, or the same
# version ⇒ the hook prints nothing: byte for byte as before. FLEET_WHATS_NEW=0
# turns the hook off. Only at a turn boundary: UserPromptSubmit is the one place
# it runs, so nothing in a running turn is interrupted.
#
# Exit: 0 printed · 1 nothing to say (same version / no version) · 2 usage.
# --hook always exits 0 — a prompt is never blocked by it.

BIN=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$BIN/.." && pwd -P)

exp_ver() {
  local f="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/agent-cfg.expected" k v _r
  [ -f "$f" ] || return 0
  while read -r k v _r; do [ "$k" = ver ] && { printf '%s' "$v"; return 0; }; done < "$f"
  return 0
}

# summarize <mode> <old> <new> — the text, from the install's own git history.
summarize() {
  python3 - "$1" "$2" "$3" "${FLEET_WHATS_NEW_REPO:-$ROOT}" <<'PY'
import os, re, subprocess, sys

mode, old, new, repo = sys.argv[1:5]
MAX_ITEMS = 3                      # header + 3 + tail = 5 lines (EPIC #1906 rule 5)


def git(*a):
    r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def short(s):
    return s[:7]


def commit_ok(s):
    return bool(s) and git("rev-parse", "--verify", "-q", s + "^{commit}") is not None


head = "fleet 已从 %s 更新到 %s" % (short(old), short(new))
if not (commit_ok(old) and commit_ok(new)):
    print(head + "（这台机器看不到变化明细）。")
    sys.exit(0)
if git("merge-base", "--is-ancestor", new, old) is not None and git("rev-parse", old) != git("rev-parse", new):
    n = len((git("rev-list", "--no-merges", "%s..%s" % (new, old)) or "").split())
    print("fleet 已从 %s 退回到 %s（撤下 %d 项改动），按退回后的写法做。" % (short(old), short(new), n))
    sys.exit(0)


def tools(ref):
    """The fleet tool service's tool names at <ref>: the TOOLS table's keys."""
    src = git("show", "%s:bin/fleet-mcp.py" % ref) or ""
    m = re.search(r"^TOOLS = \{\n(.*?)^\}", src, re.S | re.M)
    return set(re.findall(r'^    "(\w+)": \(tool_', m.group(1), re.M)) if m else set()


def worker_skill(path):
    """/name of a worker-owned skill or command file, else None."""
    if path.startswith("commands/") and path.endswith(".md"):
        name = "/" + os.path.basename(path)[:-3]
    else:
        m = re.match(r"skills/([^/]+)/SKILL\.md$", path)
        if not m:
            return None
        name = m.group(1)
    body = git("show", "%s:%s" % (new, path)) or git("show", "%s:%s" % (old, path)) or ""
    return name if "owner: worker" in body else None


GUARD = re.compile(r"^(hooks/[\w-]*guard\.py|bin/tmux-shim/|hooks/settings-hooks\.json$|hooks/codex-map\.json$)")


def clean(subject):
    subject = re.sub(r"(\s*\(#\d+\))+\s*$", "", subject).strip()
    return subject if len(subject) <= 48 or mode == "full" else subject[:47] + "…"


lines = []
t_old, t_new = tools(old), tools(new)
added, gone = sorted(t_new - t_old), sorted(t_old - t_new)


def names(ts):
    shown = ts if mode == "full" or len(ts) <= 4 else ts[:4]
    return "、".join("fleet." + t for t in shown) + ("" if shown is ts else " 等 %d 个" % len(ts))


if added:
    lines.append("新工具 " + names(added))
if gone:
    lines.append("工具已下线：" + names(gone))

log = git("log", "--no-merges", "--format=\x1e%h\x1f%s", "--name-only", "%s..%s" % (old, new)) or ""
internal = 0
for rec in log.split("\x1e")[1:]:
    first, _, files = rec.partition("\n")
    sha, _, subject = first.partition("\x1f")
    files = [f for f in files.split("\n") if f]
    skills = sorted({s for s in (worker_skill(f) for f in files) if s})
    tag = sha if mode == "full" else ""
    if skills:
        lines.append("技能 %s：%s%s" % ("、".join(skills), clean(subject), " " + tag if tag else ""))
    elif "bin/fleet-mcp.py" in files and tools(sha + "^") != tools(sha):
        pass                        # a tool added / retired: said in the tool line above
    elif "docs/FLEET-MCP.md" in files:
        lines.append("工具：%s%s" % (clean(subject), " " + tag if tag else ""))
    elif any(GUARD.match(f) for f in files):
        lines.append("守卫：%s%s" % (clean(subject), " " + tag if tag else ""))
    else:
        internal += 1

if not lines:
    print("%s，没有影响执行会话的改动（%d 项内部改动）。" % (head, internal))
    sys.exit(0)
over = 0
if mode != "full" and len(lines) > MAX_ITEMS:
    over, lines = len(lines) - MAX_ITEMS, lines[:MAX_ITEMS]
print(head + "，和你有关的：")
for l in lines:
    print("· " + l)
tail = []
if over:
    tail.append("%d 项和你有关（fleet.whats_new 看全部）" % over)
if internal:
    tail.append("%d 项内部改动" % internal)
if tail:
    print("另有 " + "、".join(tail) + "。")
PY
}

hook() {
  [ "${FLEET_WHATS_NEW:-1}" != 0 ] || return 0
  [ -n "${TMUX_PANE:-}" ] || return 0          # our own pane, never "the one in view"
  local cur o av told from text
  cur=$(exp_ver); [ -n "$cur" ] || return 0     # no versioned install: nothing, as before
  o=$(tmux display-message -p -t "$TMUX_PANE" '#{@agent_ver}|#{@ver_told}' 2>/dev/null) || return 0
  av=${o%%|*}; told=${o#*|}
  from=${told:-$av}
  if [ -z "$from" ]; then                       # launched before #1895: baseline, say nothing
    tmux set-option -w -t "$TMUX_PANE" @ver_told "$cur" 2>/dev/null
    return 0
  fi
  [ "$from" != "$cur" ] || return 0
  text=$(summarize brief "$from" "$cur" 2>/dev/null)
  [ -n "$text" ] || return 0
  tmux set-option -w -t "$TMUX_PANE" @ver_told "$cur" 2>/dev/null || return 0
  [ -d "$ROOT/logs" ] && printf '%s %s %s→%s\n' "$(date -u +%FT%TZ)" "$TMUX_PANE" "$from" "$cur" \
    >> "$ROOT/logs/whats-new.log" 2>/dev/null
  printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": sys.stdin.read()}}, ensure_ascii=False))'
}

case "${1:-}" in
  --hook)
    cat >/dev/null 2>&1      # the hook's stdin JSON: read, unused
    hook; exit 0 ;;
  --full)
    shift
    old=${1:-}; new=${2:-}
    [ -n "$new" ] || new=$(exp_ver)
    if [ -z "$old" ] && [ -n "${TMUX_PANE:-}" ]; then
      old=$(tmux display-message -p -t "$TMUX_PANE" '#{@agent_ver}' 2>/dev/null)
    fi
    if [ -z "$old" ] || [ -z "$new" ]; then
      echo "fleet-whats-new: no version to compare (this session's @agent_ver / the expected ver) — pass <old> <new>" >&2
      exit 1
    fi
    if [ "$old" = "$new" ]; then echo "fleet 是最新的（${new}），这个会话启动后没有换过版。"; exit 1; fi
    summarize full "$old" "$new"; exit 0 ;;
  -h|--help|'')
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] && exit 0; exit 2 ;;
  -*)
    echo "fleet-whats-new: unknown option $1" >&2; exit 2 ;;
  *)
    [ $# -eq 2 ] || { echo "usage: fleet-whats-new.sh <old> <new>" >&2; exit 2; }
    [ "$1" != "$2" ] || exit 1
    summarize brief "$1" "$2"; exit 0 ;;
esac
