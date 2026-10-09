#!/usr/bin/env python3
"""fleet_sample.py — one member of each finished batch, its evidence pasted into
the day's decision sheet (issue #2678, EPIC #2668 R2). The person no longer
watches the workers, so 「做完了」 is one sentence; a sample is the thing itself.

The steward's beat (fleet_steward.collect, after the followup pass) runs beat():

  1. a batch has FINISHED when the followup pass saw its EPIC closed
     (st.d["todo"]["epics"][ref]["closed"], bin/fleet_followup.py) — the same
     judgment, never a second one;
  2. for each finished batch not sampled yet: `fleet-evidence.sh export --epic N
     --repo R <steward/samples/<owner-name.N>>` (the files copied beside the
     sheet, so a later evidence sweep never takes the picture away), and ONE
     member drawn at random among those with an `after` capture
     (random.Random(<ref>): another batch draws another member, a re-run the same);
     none has one ⇒ the sample says so (an honest gap, never a staged picture);
     an export that cannot run is retried next beat (FLEET_STEWARD_SAMPLE_TRIES, 3);
  3. the sample waits in st.d["samples"]["items"] with `shown: ""` until a sheet
     carries it; every sheet of that day carries that day's samples
     (fleet_decision.render's read-only `samples` area — no row, no decide count).

A new sample makes the beat post the sheet itself (fleet_steward.post_sheet), so
it reaches the person on the beat after the batch closed with no model turn.

Seam (selftest): FLEET_STEWARD_EVIDENCE_CMD (argv + export --epic N --repo R
--session S <dest>: prints fleet-evidence.sh's export rows).
"""
import os
import random
import subprocess
from pathlib import Path

BIN = Path(__file__).resolve().parent
TEXT_EXT = (".txt", ".log", ".out", ".md", ".json", ".tsv", ".csv")
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")


def book(st):
    s = st.d.setdefault("samples", {})
    s.setdefault("items", [])
    s.setdefault("epics", {})
    return s


def export(sess, ref, dest):
    """fleet-evidence.sh export rows: [(member, stage, ts, abs path, note)]."""
    repo, _, n = ref.partition("#")
    argv = ["export", "--epic", n, "--repo", repo, "--session", sess, str(dest)]
    cmd = os.environ.get("FLEET_STEWARD_EVIDENCE_CMD")
    argv = (cmd.split() + argv) if cmd else ["bash", str(BIN / "fleet-evidence.sh")] + argv
    r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:200])
    rows = []
    for line in r.stdout.splitlines():
        if not line or line.startswith("#"):
            continue
        f = (line.split("\t") + [""] * 5)[:5]
        rows.append((f[0], f[1], f[2], str(Path(dest) / f[3]) if f[3] else "", f[4]))
    return rows


def draw(ref, rows):
    """One member with an `after` capture, at random (seeded by the batch)."""
    after = {}
    for m, stage, ts, p, note in rows:
        if stage == "after" and p:
            after.setdefault(m, []).append((ts, p, note))
    if not after:
        return None
    m = random.Random(ref).choice(sorted(after))
    ts, p, note = sorted(after[m])[-1]          # the member's newest after
    return {"member": m, "ts": ts, "path": p, "note": note}


def excerpt(path, lines=8):
    """A text capture's first lines (the sheet shows them); "" for anything else."""
    if not path.lower().endswith(TEXT_EXT):
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            out = [fh.readline().rstrip("\n") for _ in range(lines)]
    except OSError:
        return ""
    return "\n".join(x[:160] for x in out).rstrip()


def beat(fs, sess, st, now, day, delta):
    """Draw a sample for every batch that finished and has none yet."""
    s = book(st)
    epics = (st.d.get("todo") or {}).get("epics") or {}
    tries = fs.env_int("FLEET_STEWARD_SAMPLE_TRIES", 3)
    root = fs.conf_dir() / "fleets" / sess / "steward" / "samples"
    new = []
    for ref, e in sorted(epics.items()):
        if not e.get("closed") or "#" not in ref:
            continue
        rec = s["epics"].setdefault(ref, {"state": "pending", "tries": 0})
        if rec["state"] != "pending":
            continue
        dest = root / ref.replace("/", "-").replace("#", ".")
        try:
            rows = export(sess, ref, dest)
        except (RuntimeError, OSError, subprocess.SubprocessError) as err:
            rec["tries"] += 1
            rec["why"] = str(err)
            if rec["tries"] >= tries:
                rec["state"] = "failed"
            continue
        got = draw(ref, rows)
        item = {"epic": ref, "at": now, "day": day, "shown": "",
                "members": len({r[0] for r in rows})}
        if got:
            item.update(got, kind="image" if got["path"].lower().endswith(IMAGE_EXT) else "file",
                        text=excerpt(got["path"]))
        else:
            item["none"] = True
        s["items"].append(item)
        rec["state"] = "drawn"
        new.append(ref)
    delta["samples"] = new
    return new


def for_sheet(st, day):
    """The samples a sheet of `day` carries: that day's, and any never shown."""
    return [i for i in book(st)["items"] if i.get("day") == day or not i.get("shown")]


def shown(st, items, sheet_id):
    for i in items:
        i["shown"] = i.get("shown") or sheet_id
