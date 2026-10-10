#!/usr/bin/env python3
"""fleet_dialog_answer.py — the ONE guarded road for answering a session's open
choice dialog (AskUserQuestion) on the person's behalf (issue #2958). Run as
bin/fleet-dialog-answer.sh; the `answer_dialog` fleet tool runs it.

    fleet-dialog-answer.sh <@window|%pane> --fp FP --pick [Q=]LABEL …
                           [--by person|steward|default] [--basis TEXT]
                           [--issue owner/name#N] [--session S] [-L SOCK] [--dry-run]

A peer message waits behind an open dialog (it is mid-turn), and a raw
`tmux send-keys` into a fleet window is refused by hooks/bash-guard.py — so before
this nobody but the person at the keyboard could answer one, and a batch driver
that asked from inside a /loop wake sat seven hours unseen. This is the single
opening: it reads before it presses, presses through bin/fleet-answer.sh (whose
label gate, read-back submit and transcript confirmation are the keystroke rail),
and checks after — never a second press.

  1. only a window that waits on its person (@claude_state needs, @claude_needs
     ask) and only an AskUserQuestion — fixed options; a free-text box, the
     dialog's own 「Other / Type something」, is never answered (no such label);
  2. read: the transcript's open dialog (fleet_needs_detail.pending_dialog — the
     same read the steward's decision row came from) must carry the caller's
     fingerprint `--fp` (dialog_fp: its tool_use_id + every question and label,
     verbatim) and every `--pick` must be one of its labels, verbatim, one pick a
     question (several only for a multiSelect) — else refused: it changed or it
     was answered;
  3. a person at it is never typed over: a client on this window with a keypress
     within FLEET_HANDOFF_DEFER_SECS (30), or a draft in the input box, refuses —
     try again later;
  4. press once (fleet-answer.sh --answer … --transcript <the same file>), which
     confirms by the tool_result landing; unconfirmed is a failure, not a retry;
  5. the trail: one line in the steward's decision-<day>.md and one record-only
     comment on the batch's issue (--issue, else the window's @epic, else its
     @repo#@issue) — who answered, on what basis, what was chosen.

Exit: 0 answered and confirmed · 1 no such window / transcript · 2 usage ·
3 refused, nothing sent (not waiting · no dialog · fingerprint or label differs) ·
4 pressed but never confirmed (left for a person; never pressed again) ·
5 a person is typing there (nothing sent).

Seams (selftest): FLEET_DIALOG_PROJECTS (the transcripts' root, default
~/.claude/projects), FLEET_DIALOG_ANSWER_CMD (argv run instead of fleet-answer.sh),
fleet_decision.py's FLEET_DECISION_POST_CMD for the issue comment.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_needs_detail as nd  # noqa: E402

RULE_RE = re.compile(r"^\s*[─━]{8,}\s*$")
PROMPT_RE = re.compile(r"^\s*[❯>]\s?(.*)$")
OPTION_ROW_RE = re.compile(r"^\s*[❯>]?\s*\d+\.\s")


class Refuse(Exception):
    def __init__(self, rc, msg):
        Exception.__init__(self, msg)
        self.rc = rc


def tmux_argv(sock):
    return ["tmux", "-L", sock] if sock else ["tmux"]


def tm(sock, *args):
    r = subprocess.run(tmux_argv(sock) + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       universal_newlines=True, timeout=20)
    return r.returncode, r.stdout


def lib(snippet, *args):
    r = subprocess.run(["bash", "-c", '. "$0/fleet-lib.sh" >/dev/null 2>&1; ' + snippet, str(BIN)] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
    return r.stdout.strip()


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet"))


FIELDS = ("window_id", "pane_id", "state", "needs", "sid", "agent", "name", "epic", "issue", "repo", "session")


def window(sock, target):
    fmt = "|".join(("#{window_id}", "#{pane_id}", "#{@claude_state}", "#{@claude_needs}", "#{@cc_session_id}",
                    "#{@cc_agent}", "#{window_name}", "#{@epic}", "#{@issue}", "#{@repo}",
                    "#{?#{session_group},#{session_group},#{session_name}}"))
    rc, out = tm(sock, "display-message", "-p", "-t", target, fmt)
    parts = out.rstrip("\n").split("|")
    if rc != 0 or len(parts) != len(FIELDS) or not parts[0]:
        return None
    return dict(zip(FIELDS, parts))


def transcript(w):
    root = os.environ.get("FLEET_DIALOG_PROJECTS") or str(Path.home() / ".claude" / "projects")
    if not w["sid"]:
        return None
    hits = sorted(glob.glob(os.path.join(root, "*", w["sid"] + ".jsonl")))
    return hits[0] if hits else None


def typing(sock, w):
    """Why a person is at it ('' = nobody): a recent keypress on this window, or a
    draft in its input box."""
    try:
        defer = int(os.environ.get("FLEET_HANDOFF_DEFER_SECS") or 30)
    except ValueError:
        defer = 30
    if defer > 0:
        _, out = tm(sock, "list-clients", "-F", "#{client_activity} #{window_id}")
        now = int(dt.datetime.now().timestamp())
        for line in out.splitlines():
            act, _, wid = line.partition(" ")
            if wid == w["window_id"] and act.isdigit() and now - int(act) <= defer:
                return "a keypress %ds ago" % (now - int(act))
    _, screen = tm(sock, "capture-pane", "-p", "-t", w["pane_id"])
    lines = screen.splitlines()
    for i in range(len(lines) - 1):
        if RULE_RE.match(lines[i]) and not OPTION_ROW_RE.match(lines[i + 1]):
            m = PROMPT_RE.match(lines[i + 1])
            if m and m.group(1).strip():
                return "a draft in the input box"
    return ""


def resolve_picks(d, picks):
    """[[label, …] per question] → [`i[,j]` per question] (1-based), or Refuse."""
    qs = d["questions"]
    want = [[] for _ in qs]
    for p in picks:
        if len(qs) == 1:
            qi, label = 0, p
            m = re.match(r"^1=(.*)$", p, re.S)
            if p not in qs[0]["options"] and m:
                label = m.group(1)
        else:
            m = re.match(r"^(\d+)=(.*)$", p, re.S)
            if not m:
                raise Refuse(2, "%d questions: say which one each pick answers (N=<label>)" % len(qs))
            qi, label = int(m.group(1)) - 1, m.group(2)
        if not 0 <= qi < len(qs):
            raise Refuse(2, "no question %d (the dialog has %d)" % (qi + 1, len(qs)))
        want[qi].append(label)
    out = []
    for qi, (q, labels) in enumerate(zip(qs, want)):
        if not labels:
            raise Refuse(2, "question %d (%s) has no pick" % (qi + 1, q["question"][:60]))
        if len(labels) > 1 and not q["multiSelect"]:
            raise Refuse(2, "question %d is single-select — %d picks" % (qi + 1, len(labels)))
        idx = []
        for label in labels:
            if label not in q["options"]:
                raise Refuse(3, "question %d has no option %r — it changed, or that is a free-text answer "
                                "(never answered here)" % (qi + 1, label))
            idx.append(str(q["options"].index(label) + 1))
        out.append(",".join(idx))
    return out, want


def issue_ref(a, w):
    for ref in (a.issue, w["epic"], ("%s#%s" % (w["repo"], w["issue"])) if w["repo"] and w["issue"].isdigit() else ""):
        m = re.match(r"^([^\s#]+/[^\s#]+)#(\d+)$", ref or "")
        if m:
            return m.group(1), m.group(2)
    return None


def trail(a, w, d, want, verdict):
    who = {"person": "人在决定单上答", "steward": "管家按章程代答", "default": "到点按默认"}.get(a.by, a.by)
    chosen = " / ".join("、".join(ls) for ls in want)
    q = " / ".join(x["question"] for x in d["questions"])
    line = "- %s 代答选择框 · %s（%s）· 窗口 %s · 问「%s」→ 选「%s」%s · %s" % (
        dt.datetime.now().strftime("%H:%M"), who, a.basis or "—", w["name"] or w["window_id"], q, chosen,
        "" if verdict == "answered" else "（按了未确认）", "fp=" + a.fp)
    sess = a.session or w["session"]
    if sess:
        p = conf_dir() / "fleets" / sess / "steward"
        try:
            p.mkdir(parents=True, exist_ok=True)
            with open(str(p / ("decision-%s.md" % dt.date.today().isoformat())), "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass
    ref = issue_ref(a, w)
    if ref:
        import fleet_decision as fd
        body = "\n".join([line.lstrip("- "), "",
                          "<!-- fleet:dialog-answer by=%s fp=%s verdict=%s -->" % (a.by, a.fp, verdict)])
        try:
            fd.post(ref[0], ref[1], body, "note")
        except Exception as e:  # the answer stands even if its record could not be posted
            sys.stderr.write("fleet-dialog-answer: trail comment on %s#%s failed: %s\n" % (ref[0], ref[1], e))
    return line


def run(a):
    sock = a.L
    if not sock and not os.environ.get("TMUX"):
        sess = a.session or lib("fleet_current_session")
        sock = lib('fleet_socket "$1"', sess) if sess else ""
    w = window(sock, a.target)
    if w is None:
        raise Refuse(1, "no live window %s" % a.target)
    if w["agent"] == "codex":
        raise Refuse(3, "%s is a Codex session — its questions are answered through fleet-answer.sh" % a.target)
    if (w["state"], w["needs"]) != ("needs", "ask"):
        raise Refuse(3, "%s is not waiting on a choice dialog (state %s/%s)" % (a.target, w["state"], w["needs"]))
    tp = a.transcript or transcript(w)
    if not tp or not os.path.isfile(tp):
        raise Refuse(1, "no transcript for %s (session %s)" % (a.target, w["sid"] or "?"))
    d = nd.pending_dialog(tp)
    if d is None:
        raise Refuse(3, "%s has no open choice dialog — it was answered" % a.target)
    fp = nd.dialog_fp(d)
    if fp != a.fp:
        raise Refuse(3, "the dialog on %s changed (fingerprint %s, asked about %s) — read it again" % (a.target, fp, a.fp))
    idx, want = resolve_picks(d, a.pick)
    why = typing(sock, w)
    if why:
        raise Refuse(5, "a person is at %s (%s) — not typed over; try again later" % (a.target, why))
    argv = (os.environ["FLEET_DIALOG_ANSWER_CMD"].split() if os.environ.get("FLEET_DIALOG_ANSWER_CMD")
            else ["bash", str(BIN / "fleet-answer.sh")])
    argv += (["-L", sock] if sock else []) + ["--transcript", tp] + (["--dry-run"] if a.dry_run else []) \
        + ["--answer", w["pane_id"]] + idx
    r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                       timeout=int(os.environ.get("FLEET_ANSWER_TIMEOUT") or 45) + 30)
    if a.dry_run:
        print(r.stdout.strip())
        return r.returncode
    if r.returncode == 0:
        print("answered %s: %s · %s" % (a.target, trail(a, w, d, want, "answered").split(" · ", 1)[1], r.stdout.strip()))
        return 0
    if r.returncode == 4:
        trail(a, w, d, want, "unconfirmed")
        raise Refuse(4, "pressed on %s but the answer never showed in the transcript — left for a person, "
                        "not pressed again: %s" % (a.target, r.stderr.strip()))
    raise Refuse(r.returncode if r.returncode in (1, 2, 3) else 1,
                 "fleet-answer.sh refused (%d): %s" % (r.returncode, r.stderr.strip()))


def main(argv=None):
    p = argparse.ArgumentParser(prog="fleet-dialog-answer.sh", description=__doc__.split("\n\n")[0])
    p.add_argument("target")
    p.add_argument("--fp", required=True)
    p.add_argument("--pick", action="append", required=True)
    p.add_argument("--by", default="person", choices=("person", "steward", "default"))
    p.add_argument("--basis", default="")
    p.add_argument("--issue", default="")
    p.add_argument("--session", default="")
    p.add_argument("--transcript", default="")
    p.add_argument("-L", default="")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    if not re.match(r"^[@%][0-9]+$", a.target):
        sys.stderr.write("fleet-dialog-answer: %r is not a window address (@<id> / %%<pane>)\n" % a.target)
        return 2
    try:
        return run(a)
    except Refuse as e:
        sys.stderr.write("fleet-dialog-answer: %s\n" % e)
        return e.rc


if __name__ == "__main__":
    sys.exit(main())
