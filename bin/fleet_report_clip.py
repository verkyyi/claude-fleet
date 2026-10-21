#!/usr/bin/env python3
"""fleet_report_clip.py — a child report's summary, cut to the envelope (T803).

    fleet_report_clip.py <code> < summary      → the envelope's summary lines

The envelope carries ≤3 lines of ≤200 CHARACTERS each (never bytes: macOS `cut -c`
counts bytes in some locales, so a Chinese line kept ~65 characters and could end on
half a character). A line too long is cut at the last sentence end in its second half,
else the last separator there, else at 199 characters, and ends with `…`. Anything cut — a long
line or a 4th line — names where the whole text is: `（全文：fleet-id.sh get <code>）`
on the last line, when <code> is the session's ID code (its result carries the full
summary); an empty <code> adds nothing. `<` / `>` are dropped: a summary is model
text and must not close the envelope it rides inside.
"""
import sys

WIDTH = 200
STRONG = "。！？；;!?"            # a sentence ends here
WEAK = "，,、·)）】」 ."            # a phrase does


def clip_line(line):
    if len(line) <= WIDTH:
        return line, False
    cut = -1
    for marks in (STRONG, WEAK):
        for i in range(WIDTH - 2, WIDTH // 2 - 1, -1):
            if line[i] in marks:
                cut = i + 1
                break
        if cut > 0:
            break
    if cut < 0:
        cut = WIDTH - 1
    return line[:cut].rstrip() + "…", True


def clip(text, code=""):
    text = text.replace("<", "").replace(">", "")
    lines = text.split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    cut = len(lines) > 3
    out = []
    for ln in lines[:3]:
        c, was = clip_line(ln)
        cut = cut or was
        out.append(c)
    if cut and code and out:
        out[-1] += "（全文：fleet-id.sh get %s）" % code
    return "\n".join(out)


if __name__ == "__main__":
    data = sys.stdin.buffer.read().decode("utf-8", "replace")
    sys.stdout.write(clip(data, sys.argv[1] if len(sys.argv) > 1 else ""))
