#!/usr/bin/env python3
"""docs-faq.py — the FAQ's one source, read off docs/public/<lang>/faq.md (issue #3582,
EPIC #3569 C12).

faq.md is the ONLY place a question is written (共同约定 4): the site's FAQ block
and its FAQPage JSON-LD (C14), llms.txt (C15) and the docs build's faq.json are
generated from it, never typed twice. The page's shape:

    ## <group>
    ### <question>
    <!-- faq: site -->          optional — this one is on the site's front page too
    <answer: one paragraph for a site question, any Markdown otherwise>

  (every command takes --src <dir>, the docs/public tree to read; default the repo's)

  json   [--lang zh|en] [--site] [--root R]
                     {"lang", "source", "items": [{group, q, a, a_md, site}]} — `a` is
                     the answer as plain text (code / links / bold unwrapped), `a_md`
                     its Markdown; --site keeps the site questions only
  check  [--lang zh|en] [--root R]
                     every question has an answer, none is asked twice, every site
                     answer is one paragraph; exit 1 + one line per gap
  check-html <file.html> [--lang zh|en] [--root R]
                     every site question and its answer appear word for word in the
                     page's text (the site build's own check, C14); exit 1 + one line
                     per missing item
"""
import html
import json
import os
import re
import sys

SITE = re.compile(r"<!--\s*faq:\s*site\s*-->")


def root_of(args):
    if "--root" in args:
        return args[args.index("--root") + 1]
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def opt(args, name, default):
    return args[args.index(name) + 1] if name in args else default


def plain(md):
    s = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    s = re.sub(r"\[([^\]]+)\]\([^)\s]+\)", r"\1", s)
    s = re.sub(r"`([^`]+)`", r"\1", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
    return re.sub(r"\s+", " ", s).strip()


def parse(path):
    items, group, cur = [], "", None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        m = re.match(r"^(#{2,3})\s+(.+?)\s*$", line)
        if m:
            if cur:
                items.append(cur)
            cur = None
            if len(m.group(1)) == 2:
                group = m.group(2)
            else:
                cur = {"group": group, "q": m.group(2), "md": [], "site": False}
            continue
        if cur is None:
            continue
        if SITE.search(line):
            cur["site"] = True
            continue
        cur["md"].append(line)
    if cur:
        items.append(cur)
    for it in items:
        it["a_md"] = "\n".join(it.pop("md")).strip()
        it["a"] = plain(it["a_md"])
    return items


def page_text(path):
    s = open(path, encoding="utf-8").read()
    s = re.sub(r"<(script|style)\b.*?</\1>", " ", s, flags=re.S | re.I)
    s = html.unescape(re.sub(r"<[^>]+>", "", s))
    return re.sub(r"\s+", " ", s)


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    cmd, args = argv[0], argv[1:]
    lang = opt(args, "--lang", "zh")
    root = root_of(args)
    src = os.path.join(opt(args, "--src", os.path.join(root, "docs", "public")), lang, "faq.md")
    if not os.path.isfile(src):
        sys.stderr.write("docs-faq: no %s\n" % src)
        return 2
    items = parse(src)
    if cmd == "json":
        keep = [it for it in items if it["site"]] if "--site" in args else items
        out = {"lang": lang, "source": "docs/public/%s/faq.md" % lang,
               "items": [{k: it[k] for k in ("group", "q", "a", "a_md", "site")} for it in keep]}
        json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
        sys.stdout.write("\n")
        return 0
    if cmd == "check":
        bad, seen = [], set()
        for it in items:
            if not it["a"]:
                bad.append("question has no answer: %s" % it["q"])
            if it["q"] in seen:
                bad.append("question asked twice: %s" % it["q"])
            seen.add(it["q"])
            if it["site"] and "\n\n" in it["a_md"]:
                bad.append("site answer is more than one paragraph: %s" % it["q"])
        if not any(it["site"] for it in items):
            bad.append("no question is marked <!-- faq: site -->")
        for b in bad:
            print(b)
        return 1 if bad else 0
    if cmd == "check-html":
        if not args or args[0].startswith("--"):
            sys.stderr.write("usage: docs-faq.py check-html <file.html> [--lang zh|en]\n")
            return 2
        text = page_text(args[0])
        bad = []
        for it in items:
            if not it["site"]:
                continue
            for part in ("q", "a"):
                if it[part] not in text:
                    bad.append("%s not on the page word for word: %s" % ("question" if part == "q" else "answer", it[part]))
        for b in bad:
            print(b)
        return 1 if bad else 0
    sys.stderr.write("docs-faq: unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
