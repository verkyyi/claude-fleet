#!/usr/bin/env python3
"""classify-shadow-report.py — what a week of CLASSIFY_BACKEND=shadow says (issue #1229).

Reads logs/classify-shadow.ndjson (one row per classifier call: haiku's verdict, Jev's
verdict + confidence, the capture hash, the capture text on a disagreement) and prints,
in the same terms ~/tools/jev-eval/screen-bench.py used for the 39-screen experiment:

  * agreement haiku==jev, raw label and fleet-state (WAITING/ERROR both map to `needs`)
  * per-confidence bucket: rows, agreement — and ACCURACY per side once a labels file
    exists (the decision in the issue is "≥0.95 on the conf≥0.7 subset")
  * WORKING reads per side — every row here is a quiet (done|needs|looping) window, so
    a WORKING verdict is a misread by construction (issue #846)
  * Jev availability + latency p50/p95, haiku latency
  * the disagreement list, oldest first, with the last lines of each capture

Usage: classify-shadow-report.py [--labels FILE] [--min-conf 0.7] [--dump FILE] [NDJSON]
  --dump FILE   write the disagreement rows (with captures) as a JSON list; hand-label
                by adding "label": "STOPPED|WAITING|LOOPING|WORKING|ERROR" to each and
                feed the same file back with --labels.
  --labels FILE JSON: either {"<hash>": "<LABEL>", ...} or a list of {"hash":…,"label":…}
                (rows without a label are ignored).
"""
import json, os, sys, collections

FLEET = {"WAITING": "needs", "ERROR": "needs", "LOOPING": "looping", "STOPPED": "done", "WORKING": "working"}

def pct(a, b): return "%5.1f%%" % (100.0 * a / b) if b else "    -"
def p(xs, q):
    xs = sorted(x for x in xs if x is not None)
    return xs[min(len(xs) - 1, int(len(xs) * q))] if xs else None

def main(argv):
    labels_f = dump_f = None; min_conf = 0.7; path = None
    it = iter(argv)
    for a in it:
        if a == "--labels": labels_f = next(it)
        elif a == "--dump": dump_f = next(it)
        elif a == "--min-conf": min_conf = float(next(it))
        elif a in ("-h", "--help"): print(__doc__); return 0
        else: path = a
    if path is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "logs", "classify-shadow.ndjson")
    try:
        rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    except FileNotFoundError:
        print("no shadow log at %s — run with CLASSIFY_BACKEND=shadow first" % path); return 1
    labels = {}
    if labels_f:
        d = json.load(open(labels_f, encoding="utf-8"))
        items = d.items() if isinstance(d, dict) else ((r.get("hash"), r.get("label")) for r in d)
        labels = {h: str(l).upper() for h, l in items if h and l}

    both = [r for r in rows if r.get("haiku") and r.get("jev")]
    n = len(rows)
    print("rows=%d  both-verdicts=%d  jev-missing=%d  haiku-missing=%d  span=%s .. %s" % (
        n, len(both), sum(1 for r in rows if not r.get("jev")), sum(1 for r in rows if not r.get("haiku")),
        rows[0]["ts"] if rows else "-", rows[-1]["ts"] if rows else "-"))
    if not both:
        return 0
    agree_raw = sum(1 for r in both if r["haiku"] == r["jev"])
    agree_state = sum(1 for r in both if FLEET.get(r["haiku"]) == FLEET.get(r["jev"]))
    print("agreement  raw=%s  fleet-state=%s   (n=%d)" % (pct(agree_raw, len(both)), pct(agree_state, len(both)), len(both)))
    errs = collections.Counter((r.get("jev_err") or "").split(" ")[0] for r in rows if not r.get("jev"))
    if errs: print("jev unavailable:", dict(errs))
    jl = [r.get("jev_ms") for r in rows if r.get("jev_ms") is not None]
    hl = [r.get("haiku_s") for r in rows if r.get("haiku")]
    print("latency    jev p50=%sms p95=%sms   haiku p50=%ss p95=%ss" % (p(jl, .5), p(jl, .95), p(hl, .5), p(hl, .95)))
    wk_h = sum(1 for r in rows if r.get("haiku") == "WORKING"); wk_j = sum(1 for r in rows if r.get("jev") == "WORKING")
    print("WORKING misreads (quiet windows, #846):  haiku=%d  jev=%d" % (wk_h, wk_j))
    print("haiku labels:", dict(collections.Counter(r["haiku"] for r in rows if r.get("haiku"))))
    print("jev labels:  ", dict(collections.Counter(r["jev"] for r in rows if r.get("jev"))))
    print("jev→haiku confusion:", dict(collections.Counter((r["jev"], r["haiku"]) for r in both if r["haiku"] != r["jev"])))

    buckets = [(0.0, 0.5), (0.5, min_conf), (min_conf, 0.9), (0.9, 1.01)]
    print("\nconfidence   rows  agree   " + ("jev-acc  haiku-acc  labelled" if labels else "(no --labels: accuracy needs hand labels)"))
    for lo, hi in buckets:
        b = [r for r in both if r.get("conf") is not None and lo <= r["conf"] < hi]
        line = "[%.2f,%.2f)  %5d  %s" % (lo, hi, len(b), pct(sum(1 for r in b if r["haiku"] == r["jev"]), len(b)))
        if labels:
            lb = [r for r in b if r["hash"] in labels]
            line += "  %s  %s  %6d" % (pct(sum(1 for r in lb if r["jev"] == labels[r["hash"]]), len(lb)),
                                       pct(sum(1 for r in lb if r["haiku"] == labels[r["hash"]]), len(lb)), len(lb))
        print(line)
    if labels:
        hi = [r for r in both if r.get("conf") is not None and r["conf"] >= min_conf and r["hash"] in labels]
        print("\nconf>=%.2f labelled subset: n=%d  jev-acc=%s  haiku-acc=%s  (issue #1229 asks >=95%% for jev)" % (
            min_conf, len(hi), pct(sum(1 for r in hi if r["jev"] == labels[r["hash"]]), len(hi)),
            pct(sum(1 for r in hi if r["haiku"] == labels[r["hash"]]), len(hi))))

    dis = [r for r in both if r["haiku"] != r["jev"]]
    if dump_f:
        json.dump(dis, open(dump_f, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print("\n%d disagreements → %s (add \"label\": … to each, then --labels %s)" % (len(dis), dump_f, dump_f))
    print("\n%d disagreements:" % len(dis))
    for r in dis:
        tail = "\n".join((r.get("capture") or "").splitlines()[-6:])
        print("-- %s %s hook=%s haiku=%s jev=%s conf=%s hash=%s%s\n%s" % (
            r["ts"], r["window"], r.get("hook_state"), r["haiku"], r["jev"], r.get("conf"), r["hash"],
            "  label=" + labels[r["hash"]] if r["hash"] in labels else "", tail))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
