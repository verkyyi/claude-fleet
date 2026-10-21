#!/usr/bin/env python3
"""fleet_local_refs.py — the local files a task's words name travel WITH it (T793).

A task's session is placed on whichever of the person's machines has room (T742),
so a body that says 「细节（必读）~/fleet-drafts/t696/members/C3.md」 hands the
session a file only the dispatching machine has (EPIC B2VA: 15 of 18 members on
another machine, each asking its driver to paste the file by hand). The ONE rule,
used by `fleet-task-record.sh dispatch` (every `task` tool call) and
`fleet-epic-tick.py` (each member's body):

  a path the words name — `~/…`, `$HOME/…`, `/Users/<u>/…`, `/home/<u>/…`, or a
  Claude scratchpad `/tmp/claude-<uid>/…` — that is a text file (.md · .markdown
  · .txt) under this login's home (or its scratchpad), outside any git checkout
  (a repo file reaches every machine through the repo) and with no hidden path
  component (never ~/.ssh, ~/.claude, ~/.config …), is CARRIED: appended to the
  body verbatim as

      <!-- fleet:carried ~/fleet-drafts/t696/sections.md -->
      ### 附：~/fleet-drafts/t696/sections.md（随单带上的本机文件，原文）
      …the file…
      <!-- /fleet:carried -->

  once (a path already carried is not carried again), while the body stays within
  BUDGET bytes (UTF-8; the hub reads 16 KB with its envelope). A named text file
  that cannot be carried — not on this machine, too big for what is left, not
  readable — is listed as MISSING with why, and the body gets one line saying so,
  so the session asks rather than guesses. Anything else the words name (a
  script, a directory, a repo path) is left alone.

  fleet_local_refs.py carry [--budget N] [--from FILE]  < body  > body
      stderr: one `uncarried <path> · <why>` line per file not carried; exit 0
  fleet_local_refs.py refs < text                      → one named path a line

`--from FILE` is a text whose carried blocks are taken as already read (a member's
body built on another machine than the plan: its charter carried the files).
FLEET_CARRY_LOCAL=0 turns carrying off (the body passes through untouched).
"""
import argparse
import os
import re
import sys

BUDGET = 13000
SUFFIX = (".md", ".markdown", ".txt")
# a path as words write it; a path ends at whitespace, quotes, brackets or CJK punctuation
PATH = re.compile(r"(?<![\w/.~$-])((?:~|\$HOME|\$\{HOME\})/[^\s`'\"<>()（）「」『』【】，。；：、！？]+"
                  r"|/(?:Users|home)/[^\s/`'\"<>()（）「」『』【】，。；：、！？]+/[^\s`'\"<>()（）「」『』【】，。；：、！？]+"
                  r"|/(?:private/)?tmp/claude-[0-9]+/[^\s`'\"<>()（）「」『』【】，。；：、！？]+)")
TRAIL = ".,:;!?)]}"
BLOCK = re.compile(r"<!-- fleet:carried (\S+) -->\n### [^\n]*\n(.*?)\n<!-- /fleet:carried -->", re.S)
NOTE = "（以下本机文件没能随单带上，向派你的会话要原文，别猜：%s）"


def refs(text):
    """Every path the words name, in order, once — carried blocks' own text skipped."""
    seen, out = set(), []
    for m in PATH.finditer(BLOCK.sub("", text)):
        p = m.group(1).rstrip(TRAIL)
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def carried(text):
    """{path as written: content} of the blocks a text already carries."""
    return {m.group(1): m.group(2) for m in BLOCK.finditer(text)}


def _home():
    return os.path.realpath(os.path.expanduser("~"))


def _expand(p):
    for pre in ("$HOME/", "${HOME}/"):
        if p.startswith(pre):
            return os.path.join(os.path.expanduser("~"), p[len(pre):])
    return os.path.expanduser(p)


def _in_repo(path, root):
    d = os.path.dirname(path)
    while d.startswith(root) and d != root:
        if os.path.exists(os.path.join(d, ".git")):
            return True
        d = os.path.dirname(d)
    return False


def judge(p):
    """(kind, content|why): kind 'carry' with the file's text, 'missing' with why,
    or 'skip' (not a file this rule is about)."""
    if not p.lower().endswith(SUFFIX):
        return "skip", ""
    raw = _expand(p)
    home = _home()
    scratch = re.match(r"^/(?:private/)?tmp/claude-([0-9]+)/", raw)
    if scratch:
        root = os.path.realpath(raw[:scratch.end() - 1])
    else:
        root = home
    full = os.path.realpath(raw)
    if not (full == root or full.startswith(root + os.sep)):
        # another login's home, or a link out of it: never read, never claimed
        return ("missing", "不在这台机器") if not os.path.exists(raw) else ("skip", "")
    rel = os.path.relpath(full, root)
    if any(part.startswith(".") for part in rel.split(os.sep)):
        return "skip", ""
    if not os.path.exists(full):
        return "missing", "不在这台机器"
    if not os.path.isfile(full):
        return "skip", ""
    if _in_repo(full, root):
        return "skip", ""
    try:
        with open(full, "rb") as f:
            data = f.read(1 << 20)
        return "carry", data.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return "missing", "读不出来"


def carry(body, budget=BUDGET, have=None):
    """(new body, [(path, why)] not carried)."""
    if os.environ.get("FLEET_CARRY_LOCAL", "1") == "0":
        return body, []
    have = dict(have or {})
    done = carried(body)
    out, missing = body.rstrip("\n"), []
    for p in refs(body):
        if p in done:
            continue
        kind, got = ("carry", have[p]) if p in have else judge(p)
        if kind == "skip":
            continue
        if kind == "missing":
            missing.append((p, got))
            continue
        block = "\n\n<!-- fleet:carried %s -->\n### 附：%s（随单带上的本机文件，原文）\n%s\n<!-- /fleet:carried -->" % (
            p, p, got.rstrip("\n"))
        # leave room for the note that names what could not come
        if len((out + block).encode("utf-8")) + 400 > budget:
            missing.append((p, "放不下（单子只有 %d 字节）" % budget))
            continue
        out += block
        done[p] = got
    if out == body.rstrip("\n") and not missing:
        return body, []   # nothing named: the words pass byte for byte
    if missing:
        out += "\n\n" + NOTE % "；".join("%s（%s）" % m for m in missing)
    return out + "\n", missing


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet_local_refs.py", description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("carry", "refs"))
    ap.add_argument("--budget", type=int, default=BUDGET)
    ap.add_argument("--from", dest="src", default="")
    a = ap.parse_args(argv)
    text = sys.stdin.read()
    if a.action == "refs":
        for p in refs(text):
            print(p)
        return 0
    have = {}
    if a.src:
        try:
            with open(a.src, encoding="utf-8") as f:
                have = carried(f.read())
        except OSError:
            pass
    body, missing = carry(text, a.budget, have)
    sys.stdout.write(body)
    for p, why in missing:
        print("uncarried %s · %s" % (p, why), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
