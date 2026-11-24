#!/usr/bin/env python3
"""fleet_task_notify.py — a task session's turn, written to its own ID ledger (task T9AQ).

    fleet_task_notify.py turn --pane %P --state done|needs [--transcript F] [--socket S]
    fleet_task_notify.py settle --pane %P [--socket S]   a Stop that wrote `looping`: re-ask
                                                    every 5 s for FLEET_TASK_NOTIFY_SETTLE (120) s
    fleet_task_notify.py summary <transcript>      → the last reply's (uuid, text), for tests

set-claude-state.sh runs `turn` in the background after it writes `done` or
`needs` on a window that carries a hub task (@task); fleet_window_reeval
(fleet-lib.sh) runs it when a stale `looping` it re-asks turns out `done` — a turn
that ended while a background job's last word was still settling. It reads the reply the turn
ended on — the transcript's last assistant text (Claude), else the agent's own
OSC 7501 words (@agent_status, Codex) or the open dialog's question
(@claude_needs_detail) — and appends ONE event to the window's ID ledger:

    {"ev":"turn","state":"done|waiting","summary":…,"pr":"o/n#N","artifacts":[…],"mark":…}

then hands the ledger to `fleet-id.sh push`. The hub writes the record's note / pr
and sends the task's dispatcher ONE ordinary message per state
(tokenledger/hub/store/fleet_task_notice.go) — no parent, no await. `mark` names the
reply (its transcript uuid, else a hash of the words), so the Stop hook and the
agent's own report saying the same turn are one event; a window remembers the
last mark it wrote (@task_notify_mark) and writes nothing twice. A window with no
@task, a test's pane or FLEET_TASK_NOTIFY=0 writes nothing.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

BIN = os.path.dirname(os.path.abspath(__file__))
SUMMARY_MAX = 600
TAIL = 1 << 20
FMT = "\t".join(["#{@fleet_id}", "#{@task}", "#{@cc_session_id}", "#{@claude_needs_detail}",
                 "#{@agent_status}", "#{@pr_num}", "#{@repo}", "#{@task_notify_mark}", "#{@claude_state}"])
URL_RE = re.compile(r"https?://[^\s<>()\"'`，。、）]+")
PATH_RE = re.compile(r"(?:~|/(?:Users|home|tmp|private))/[^\s\"'`，。、）:]+\.(?:md|html|pdf|png|jpg|csv|json|txt)")
PR_URL_RE = re.compile(r"github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([1-9][0-9]{0,9})")
PR_WORD_RE = re.compile(r"\bPR\s*#([1-9][0-9]{0,9})\b")


SOCKET = []


def tmux(*a):
    try:
        return subprocess.run(["tmux"] + SOCKET + list(a), capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def last_reply(path):
    """(uuid, text) of the transcript's newest assistant line that says something."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - TAIL))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return "", ""
    for line in reversed(lines):
        if '"assistant"' not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("type") != "assistant":
            continue
        content = (d.get("message") or {}).get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = "\n".join(c.get("text", "") for c in content
                             if isinstance(c, dict) and c.get("type") == "text" and isinstance(c.get("text"), str))
        else:
            text = ""
        if text.strip():
            return str(d.get("uuid") or ""), text.strip()
    return "", ""


def transcript_for(sid):
    if not re.match(r"^[0-9a-fA-F-]{8,64}$", sid or ""):
        return ""
    root = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    try:
        for d in os.listdir(root):
            f = os.path.join(root, d, sid + ".jsonl")
            if os.path.isfile(f):
                return f
    except OSError:
        pass
    return ""


def artifacts_of(text):
    out = []
    for m in URL_RE.findall(text) + PATH_RE.findall(text):
        m = m.rstrip(".,;)")
        if m not in out and len(out) < 5:
            out.append(m[:300])
    return out


def pr_of(text, pr_num, repo):
    m = PR_URL_RE.search(text)
    if m:
        return "%s#%s" % (m.group(1), m.group(2))
    n = pr_num if re.match(r"^[1-9][0-9]{0,9}$", pr_num or "") else ""
    if not n:
        m = PR_WORD_RE.search(text)
        n = m.group(1) if m else ""
    if n and re.match(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", repo or ""):
        return "%s#%s" % (repo, n)
    return ""


def turn(pane, state, transcript):
    if os.environ.get("FLEET_TASK_NOTIFY", "1") == "0" or not pane:
        return 0
    row = tmux("display-message", "-p", "-t", pane, FMT).rstrip("\n").split("\t")
    if len(row) < 9:
        return 0
    fid, task, sid, needs_detail, agent_status, pr_num, repo, last_mark, cur = row[:9]
    if not task or not re.match(r"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", fid):
        return 0
    status = {"done": "done", "needs": "waiting"}.get(state, "")
    if not status:
        return 0
    if not transcript or not os.path.isfile(transcript):
        transcript = transcript_for(sid)
    uid, text = last_reply(transcript) if transcript else ("", "")
    try:
        said = json.loads(agent_status) if agent_status else {}
    except ValueError:
        said = {}
    if status == "waiting" and needs_detail.strip():
        text = needs_detail.strip() + ("\n\n" + text if text and needs_detail.strip() not in text else "")
    if not text:
        text = str(said.get("msg") or "") if isinstance(said, dict) else ""
    if status == "done" and not text.strip():
        return 0  # no reply yet: the agent's startup idle (OSC 7501) is not a finished task
    mark = hashlib.sha1(("%s|%s|%s" % (status, uid, text if not uid else "")).encode("utf-8")).hexdigest()[:16]
    if mark == last_mark:
        return 0  # this turn's word is already written
    ev = {"ev": "turn", "state": status, "summary": text[:SUMMARY_MAX], "mark": mark,
          "artifacts": artifacts_of(text)}
    pr = pr_of(text, pr_num, repo)
    if pr:
        ev["pr"] = pr
    sys.path.insert(0, BIN)
    import fleet_id
    fleet_id.append(fid, ev)
    tmux("set-window-option", "-t", pane, "@task_notify_mark", mark)
    fleet_id.push_later(fid)
    return 0


def settle(pane, secs=None):
    """A task window's Stop wrote `looping` (a wait the turn left behind — often a
    background job's last word still settling). Re-ask it (fleet_window_reeval) a
    few times; once it reads `done`, the re-ask's own hook writes the turn."""
    import time
    if not pane or os.environ.get("FLEET_TASK_NOTIFY", "1") == "0":
        return 0
    if not tmux("display-message", "-p", "-t", pane, "#{@task}").strip():
        return 0
    try:
        secs = int(os.environ.get("FLEET_TASK_NOTIFY_SETTLE", "120")) if secs is None else secs
    except ValueError:
        secs = 120
    end = time.time() + max(0, secs)
    while time.time() < end:
        time.sleep(5)
        if tmux("display-message", "-p", "-t", pane, "#{@claude_state}").strip() != "looping":
            return 0   # a prompt, a new Stop or another re-ask decided it
        sock = SOCKET[1] if SOCKET else ""
        r = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_window_reeval "$2" "$3"', "-", BIN,
                            os.path.basename(sock) if sock else "", pane],
                           capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and "-> done" in r.stdout:
            return 0
    return 0


def main(argv):
    if argv[:1] == ["summary"] and len(argv) == 2:
        uid, text = last_reply(argv[1])
        print(json.dumps({"uuid": uid, "text": text, "artifacts": artifacts_of(text)}, ensure_ascii=False))
        return 0
    if argv[:1] not in (["turn"], ["settle"]):
        sys.stderr.write(__doc__)
        return 2
    opts = {"--pane": "", "--state": "", "--transcript": "", "--socket": ""}
    it = iter(argv[1:])
    for a in it:
        if a in opts:
            opts[a] = next(it, "")
        else:
            sys.stderr.write("unknown option %s\n" % a)
            return 2
    if opts["--socket"]:
        SOCKET[:] = ["-S", opts["--socket"]]   # a daemon's call (fleet_window_reeval): no $TMUX
    if argv[0] == "settle":
        return settle(opts["--pane"])
    return turn(opts["--pane"], opts["--state"], opts["--transcript"])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # a hook's side errand never breaks the hook
        sys.stderr.write("fleet_task_notify: %s\n" % e)
        sys.exit(0)
