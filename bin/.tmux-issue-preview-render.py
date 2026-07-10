#!/usr/bin/env python3
# .tmux-issue-preview-render.py — render one GitHub issue (raw `gh issue view`
# JSON on stdin) into the coloured, WIDTH-WRAPPED text the backlog panel shows
# in its fzf --preview. Kept as a helper so tmux-issue-preview.sh only has to
# fetch+cache the JSON; all formatting (and the word-wrap that kills fzf's
# mid-word wrap marker) lives here and re-flows to $FZF_PREVIEW_COLUMNS.
import json
import os
import re
import sys
import textwrap

# preview pane inner width (fzf exports this per render; excludes the border)
try:
    W = int(os.environ.get("FZF_PREVIEW_COLUMNS", "60"))
except ValueError:
    W = 60
W = max(20, W)                       # never wrap absurdly narrow

# 24-bit theme (matches the rest of the dash)
IN, GY, TX = "187;154;247", "86;95;137", "169;177;214"
GN, RD, CY, YE = "158;206;106", "247;118;142", "125;207;255", "224;175;104"
R = "\033[0m"
B = "\033[1m"


def c(rgb, s):
    return "\033[38;2;{}m{}{}".format(rgb, s, R)


_LIST = re.compile(r"([-*+]\s+|\d+\.\s+)")


def wrap_block(text):
    """Word-wrap a prose block to W, preserving indentation and giving list
    items a hanging indent; long unbreakable tokens (URLs) are hard-broken by US
    so they never overflow the pane (which is what made fzf draw its marker).
    Runs of blank lines collapse to a single one."""
    out = []
    for raw in (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = raw.rstrip()
        if not line.strip():
            out.append("")
            continue
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        m = _LIST.match(stripped)
        subseq = indent + (" " * len(m.group(1)) if m else "")
        out.extend(
            textwrap.wrap(
                stripped,
                width=W,
                initial_indent=indent,
                subsequent_indent=subseq,
                break_long_words=True,
                break_on_hyphens=False,
            )
            or [""]
        )
    # collapse 2+ consecutive blanks → 1
    collapsed, prev_blank = [], False
    for ln in out:
        blank = ln == ""
        if blank and prev_blank:
            continue
        collapsed.append(ln)
        prev_blank = blank
    while collapsed and collapsed[-1] == "":
        collapsed.pop()
    return collapsed


def main():
    try:
        d = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print(c(GY, "  (could not parse issue)"))
        return

    state = d.get("state", "")
    st = c(GN, "● OPEN") if state == "OPEN" else c(RD, "✖ CLOSED")
    labels = [x.get("name", "") for x in (d.get("labels") or [])]
    lb = c(CY, ", ".join(labels)) if labels else c(GY, "·")
    ms = (d.get("milestone") or {}).get("title") or "·"
    asg = [x.get("login", "") for x in (d.get("assignees") or [])]
    asg = ", ".join(asg) if asg else "·"

    lines = ["{}  {}".format(c(YE, "#" + str(d.get("number", ""))), st)]
    # title can be long — wrap it so it never overflows (else fzf marks it too)
    for tl in (wrap_block(d.get("title", "")) or [""]):
        lines.append(B + c(TX, tl))
    lines.append("")
    lines.append(c(GY, "labels    ") + lb)
    # milestone + assignee: one line when it fits the pane, else split so neither
    # overflows (the combined line is a common width offender)
    if len("milestone " + ms + "    assignee " + asg) <= W:
        lines.append(c(GY, "milestone ") + c(TX, ms) + "    " + c(GY, "assignee ") + c(TX, asg))
    else:
        lines.append(c(GY, "milestone ") + c(TX, ms))
        lines.append(c(GY, "assignee  ") + c(TX, asg))
    lines.append(c(GY, "─" * min(W, 80)))

    body = d.get("body") or ""
    lines += wrap_block(body) if body.strip() else [c(GY, "(no description)")]

    comments = d.get("comments") or []
    lines += ["", c(IN, "── comments ({}) ──".format(len(comments)))]
    for cm in comments[-5:]:
        author = (cm.get("author") or {}).get("login", "?")
        date = (cm.get("createdAt") or "")[:10]
        lines += ["", c(CY, "@" + author) + " " + c(GY, date)]
        lines += wrap_block(cm.get("body") or "")

    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
