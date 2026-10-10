#!/usr/bin/env python3
"""fleet_needs_detail.py — the question's own words, for a session waiting on you
(issue #1951, EPIC #1949 C2).

A `needs` alert row carries `detail` = what the session is asking, cut to 120
characters, so the client's bar and its macOS notification can say WHO asks WHAT
without opening the session. ONE rule for both agents:

  Claude Code   an AskUserQuestion's first question; a permission dialog's tool
                and what it would run (`Bash: git push`) — off the PreToolUse
                payload (bin/set-claude-state.sh `busy`, the mod's `ask`) or the
                transcript's open tool_use (the Notification's `needs`)
  Codex         the app-server's request_user_input question, an approval's
                command (bin/fleet-codex-attention.py)

    fleet_needs_detail.py payload          a hook's JSON on stdin → the detail
    fleet_needs_detail.py transcript <f>   the newest tool_use without a result → the detail
    fleet_needs_detail.py dialog <f>       the open AskUserQuestion as JSON + its `fp` (issue #2958)

Prints one line (nothing when there is nothing to say), always exits 0: a
missing detail never costs the state it describes.
"""
import json
import re
import sys

CAP = 120
# what a permission dialog would do, in the order a person reads it
KEYS = ("command", "cmd", "file_path", "path", "url", "pattern", "message", "reason", "prompt", "description")


def clean(text, cap=CAP):
    """One line, no control characters, at most `cap` characters (… when cut)."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= cap else text[:cap - 1].rstrip() + "…"


def first_question(inp):
    qs = inp.get("questions") if isinstance(inp, dict) else None
    if isinstance(qs, list):
        for q in qs:
            if isinstance(q, dict):
                text = q.get("question") or q.get("header") or q.get("prompt")
                if isinstance(text, str) and text.strip():
                    return text
    return ""


def detail(tool, inp):
    """The detail of one pending call: `tool` (a name, '' for Codex's own), `inp`
    its arguments / the request's params."""
    q = first_question(inp)
    if q:
        return clean(q)
    what = ""
    if isinstance(inp, dict):
        for k in KEYS:
            v = inp.get(k)
            if isinstance(v, list):
                v = " ".join(str(x) for x in v)
            if isinstance(v, str) and v.strip():
                what = v
                break
    if tool and tool != "AskUserQuestion":
        return clean("%s: %s" % (tool, what) if what else tool)
    return clean(what)


def from_payload(text):
    try:
        d = json.loads(text)
    except ValueError:
        return ""
    if not isinstance(d, dict):
        return ""
    return detail(d.get("tool_name") or "", d.get("tool_input") or {})


def from_transcript(path):
    """The rule of bin/fleet-pending-tool.sh: the newest tool_use with no result."""
    uses, done, order = {}, set(), []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"tool_use"' not in line and "tool_result" not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                m = o.get("message") if isinstance(o, dict) else None
                content = m.get("content") if isinstance(m, dict) else None
                if not isinstance(content, list):
                    continue
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") == "tool_use":
                        uses[c.get("id")] = (c.get("name") or "", c.get("input") or {})
                        order.append(c.get("id"))
                    elif c.get("type") == "tool_result":
                        done.add(c.get("tool_use_id"))
    except OSError:
        return ""
    tuid = next((i for i in reversed(order) if i not in done and i is not None), None)
    return detail(*uses[tuid]) if tuid is not None else ""


# ---- the open dialog itself (issue #2958) ---------------------------------------
# The steward's decision row and the guarded answer channel
# (bin/fleet_dialog_answer.py) read the SAME thing: the newest AskUserQuestion with
# no result — its tool_use_id, every question with its options' labels — and name
# it by a fingerprint, so an answer is only ever pressed into the dialog the row
# was written about. fleet-answer.sh's pending gate is the same rule.

def pending_dialog(path):
    """{tool_use_id, questions: [{question, header, multiSelect, options: [label]}]}
    of the open AskUserQuestion in the transcript at `path`, or None."""
    uses, done, order = {}, set(), []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "AskUserQuestion" not in line and "tool_result" not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                m = o.get("message") if isinstance(o, dict) else None
                content = m.get("content") if isinstance(m, dict) else None
                if not isinstance(content, list):
                    continue
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") == "tool_use" and c.get("name") == "AskUserQuestion":
                        uses[c.get("id")] = c.get("input") or {}
                        order.append(c.get("id"))
                    elif c.get("type") == "tool_result":
                        done.add(c.get("tool_use_id"))
    except OSError:
        return None
    tuid = next((i for i in reversed(order) if i not in done and i is not None), None)
    if tuid is None:
        return None
    qs = []
    for q in (uses[tuid].get("questions") or []):
        if not isinstance(q, dict):
            return None
        opts = [o.get("label") for o in (q.get("options") or []) if isinstance(o, dict)]
        if not opts or not all(isinstance(x, str) for x in opts):
            return None
        qs.append({"question": str(q.get("question") or ""), "header": str(q.get("header") or ""),
                   "multiSelect": bool(q.get("multiSelect")), "options": opts})
    return {"tool_use_id": tuid, "questions": qs} if qs else None


def dialog_fp(d):
    """The dialog's name: its tool_use_id + every question and label, verbatim."""
    import hashlib
    body = json.dumps([d.get("tool_use_id"), [[q["question"], q["options"]] for q in d.get("questions") or []]],
                      ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(body.encode("utf-8")).hexdigest()[:16]


def main(argv):
    try:
        if argv[:1] == ["payload"]:
            out = from_payload(sys.stdin.read())
        elif argv[:1] == ["transcript"] and len(argv) > 1:
            out = from_transcript(argv[1])
        elif argv[:1] == ["dialog"] and len(argv) > 1:
            d = pending_dialog(argv[1])
            if d is None:
                return 1
            d["fp"] = dialog_fp(d)
            out = json.dumps(d, ensure_ascii=False)
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 0
    except Exception:  # never the caller's failure
        out = ""
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
