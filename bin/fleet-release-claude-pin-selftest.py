#!/usr/bin/env python3
# fleet-release-claude-pin-selftest.py — the daily Claude Code pin bump's choices
# (bin/fleet-release-claude-pin.py, .github/workflows/claude-pin.yml): which
# version, when to wait, when to hold, what to do with the one open PR, and the
# edit itself. No network: the module's fetch is a fake registry + hub.
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""Cases:

  A  latest == the pin ⇒ "already current (<pin>)"; latest below it ⇒ the same,
     never a downgrade
  B  the newest is younger than the soak ⇒ the highest soaked one above the pin;
     nothing soaked ⇒ soak (pin stays)
  C  a new major is held without the opt-in (a same-major patch below it still
     goes); --allow-major takes it; prereleases and deprecated versions are skipped
  D  a platform package missing on npmmirror ⇒ the next whole one; none whole ⇒
     blocked, naming the package
  E  the hub: not fetchable ⇒ blocked; unreachable ⇒ a note, still a bump
  F  the one PR: open · keep · update · close (pin reached / npm pulled it)
  G  bump rewrites release.json and the §7 example, one line each (and the repo's
     own two files carry exactly one each); refuses a downgrade, a no-op and a doc
     that is not exactly one pin line
  H  changelog keeps old < v <= new, newest first, and cuts at --max-chars
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("claude_pin", os.path.join(HERE, "fleet-release-claude-pin.py"))
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)

NOW = 1_800_000_000.0
H = 3600.0
NPM, MIRROR, HUB = "https://npm.test", "https://mirror.test", "https://hub.test"
SUFFIXES = ("darwin-arm64", "linux-x64", "linux-arm64")


def iso(epoch):
    import time
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(epoch))


class Fake:
    """A registry document + per-registry platform packages + a hub answer."""

    def __init__(self, versions, latest, missing=(), hub=None, deprecated=()):
        # versions: {ver: hours ago}
        self.doc = {"dist-tags": {"latest": latest},
                    "versions": {v: ({"deprecated": "x"} if v in deprecated else {}) for v in versions},
                    "time": {v: iso(NOW - h * H) for v, h in versions.items()}}
        self.missing = set(missing)  # {(registry, suffix, ver)}
        self.hub = hub  # None = unreachable; else a callable(want list) -> dict
        self.urls = []

    def __call__(self, url, timeout=20):
        self.urls.append(url)
        if url == "%s/%s" % (NPM, pin.PKG):
            return 200, json.dumps(self.doc).encode()
        for reg in (NPM, MIRROR):
            for s in SUFFIXES:
                pre = "%s/%s-%s/" % (reg, pin.PKG, s)
                if url.startswith(pre):
                    v = url[len(pre):]
                    if (reg, s, v) in self.missing or v not in self.doc["versions"]:
                        return 404, b""
                    return 200, json.dumps({"version": v, "dist": {"integrity": "sha512-x"}}).encode()
        if url.startswith(HUB + "/v1/fleet/release/artifacts?want="):
            if self.hub is None:
                return 0, b""
            want = url.split("want=", 1)[1].split(",")
            return 200, json.dumps(self.hub(want)).encode()
        return 404, b""


def all_fetchable(want):
    return {"artifacts": [], "fetchable": want, "platforms": ["darwin-arm64", "linux-amd64"]}


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)
        self.rel = os.path.join(self.d, "release.json")
        self.write_pin("2.1.322")
        self._fetch = pin.fetch
        self.addCleanup(setattr, pin, "fetch", self._fetch)
        os.environ.pop("GITHUB_OUTPUT", None)

    def write_pin(self, v):
        with open(self.rel, "w") as f:
            json.dump({"schema": 1, "components": {"claude": {"version": v, "artifact": "claude-{version}-{os}-{arch}"}}}, f)

    def plan(self, fake, *extra):
        pin.fetch = fake
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            pin.main(["plan", "--release", self.rel, "--npm", NPM, "--mirror", MIRROR, "--hub", HUB,
                      "--now", str(NOW)] + list(extra))
        return dict(line.split("=", 1) for line in out.getvalue().splitlines())


class A_Current(Base):
    def test_equal(self):
        r = self.plan(Fake({"2.1.321": 50, "2.1.322": 40}, "2.1.322", hub=all_fetchable))
        self.assertEqual((r["action"], r["reason"], r["target"], r["pr_action"]),
                         ("current", "already current (2.1.322)", "", "none"))

    def test_latest_below_pin_never_downgrades(self):
        r = self.plan(Fake({"2.1.300": 500, "2.1.322": 40}, "2.1.300", hub=all_fetchable))
        self.assertEqual((r["action"], r["target"]), ("current", ""))

    def test_github_output(self):
        go = os.path.join(self.d, "out")
        os.environ["GITHUB_OUTPUT"] = go
        self.addCleanup(os.environ.pop, "GITHUB_OUTPUT", None)
        self.plan(Fake({"2.1.322": 40}, "2.1.322"))
        with open(go) as f:
            self.assertIn("action=current\n", f.read())


class B_Soak(Base):
    def test_newest_soaking_takes_the_one_before(self):
        r = self.plan(Fake({"2.1.322": 99, "2.1.323": 30, "2.1.325": 5}, "2.1.325", hub=all_fetchable))
        self.assertEqual((r["action"], r["target"], r["pr_action"]), ("bump", "2.1.323", "open"))
        self.assertIn("2.1.322 → 2.1.323 (npm latest 2.1.325)", r["reason"])

    def test_nothing_soaked(self):
        r = self.plan(Fake({"2.1.322": 99, "2.1.323": 23.9}, "2.1.323", hub=all_fetchable))
        self.assertEqual((r["action"], r["target"]), ("soak", ""))
        self.assertIn("soaking", r["reason"])

    def test_soak_hours(self):
        r = self.plan(Fake({"2.1.322": 99, "2.1.323": 2}, "2.1.323", hub=all_fetchable), "--soak-hours", "1")
        self.assertEqual(r["target"], "2.1.323")

    def test_no_package_fetch_for_a_soaking_version(self):
        f = Fake({"2.1.322": 99, "2.1.323": 3}, "2.1.323", hub=all_fetchable)
        self.plan(f)
        self.assertEqual([u for u in f.urls if "2.1.323" in u], [])


class C_Major(Base):
    def test_major_held_without_opt_in(self):
        r = self.plan(Fake({"2.1.322": 99, "3.0.0": 48}, "3.0.0", hub=all_fetchable))
        self.assertEqual((r["action"], r["target"]), ("hold", ""))
        self.assertIn("opt-in", r["reason"])

    def test_same_major_below_a_new_major_still_goes(self):
        r = self.plan(Fake({"2.1.322": 99, "2.1.330": 48, "3.0.0": 48}, "3.0.0", hub=all_fetchable))
        self.assertEqual((r["action"], r["target"]), ("bump", "2.1.330"))

    def test_allow_major(self):
        r = self.plan(Fake({"2.1.322": 99, "3.0.0": 48}, "3.0.0", hub=all_fetchable), "--allow-major")
        self.assertEqual((r["action"], r["target"]), ("bump", "3.0.0"))

    def test_prerelease_and_deprecated_skipped(self):
        f = Fake({"2.1.322": 99, "2.1.323": 60, "2.1.324": 50, "2.2.0-beta.1": 48}, "2.1.324",
                 hub=all_fetchable, deprecated={"2.1.324"})
        r = self.plan(f)
        self.assertEqual(r["target"], "2.1.323")


class D_Packages(Base):
    def test_mirror_missing_falls_back(self):
        f = Fake({"2.1.322": 99, "2.1.323": 60, "2.1.324": 48}, "2.1.324", hub=all_fetchable,
                 missing={(MIRROR, "linux-arm64", "2.1.324")})
        r = self.plan(f)
        self.assertEqual((r["action"], r["target"]), ("bump", "2.1.323"))
        self.assertIn("claude-code-linux-arm64@2.1.324 missing on mirror.test", r["reason"])

    def test_none_whole_is_blocked(self):
        f = Fake({"2.1.322": 99, "2.1.323": 48}, "2.1.323", hub=all_fetchable,
                 missing={(NPM, "darwin-arm64", "2.1.323")})
        r = self.plan(f)
        self.assertEqual((r["action"], r["target"], r["pr_action"]), ("blocked", "", "none"))
        self.assertIn("claude-code-darwin-arm64@2.1.323 missing on npm.test", r["reason"])


class E_Hub(Base):
    def test_not_fetchable_blocks(self):
        hub = lambda want: {"artifacts": [want[0]], "fetchable": [want[1]]}  # noqa: E731
        r = self.plan(Fake({"2.1.322": 99, "2.1.323": 48}, "2.1.323", hub=hub))
        self.assertEqual(r["action"], "blocked")
        self.assertIn("claude-2.1.323-linux-arm64", r["reason"])

    def test_carried_counts(self):
        hub = lambda want: {"artifacts": want[:2], "fetchable": want[2:]}  # noqa: E731
        r = self.plan(Fake({"2.1.322": 99, "2.1.323": 48}, "2.1.323", hub=hub))
        self.assertEqual(r["target"], "2.1.323")
        self.assertIn("hub: all three", r["notes"])

    def test_unreachable_is_a_note(self):
        r = self.plan(Fake({"2.1.322": 99, "2.1.323": 48}, "2.1.323", hub=None))
        self.assertEqual((r["action"], r["target"]), ("bump", "2.1.323"))
        self.assertIn("unreadable", r["notes"])

    def test_npm_unreachable_dies(self):
        pin.fetch = lambda url, timeout=20: (0, b"")
        with self.assertRaises(SystemExit) as e, contextlib.redirect_stderr(io.StringIO()):
            pin.main(["plan", "--release", self.rel, "--npm", NPM, "--hub", ""])
        self.assertEqual(e.exception.code, 2)


class F_PR(Base):
    def test_table(self):
        pa = pin.pr_action
        self.assertEqual(pa("bump", "2.1.323", "2.1.322", "2.1.323", ""), "open")
        self.assertEqual(pa("current", "", "2.1.322", "2.1.322", ""), "none")
        self.assertEqual(pa("bump", "2.1.323", "2.1.322", "2.1.323", "2.1.323"), "keep")
        self.assertEqual(pa("bump", "2.1.325", "2.1.322", "2.1.325", "2.1.323"), "update")
        self.assertEqual(pa("current", "", "2.1.323", "2.1.323", "2.1.323"), "close")
        self.assertEqual(pa("soak", "", "2.1.322", "2.1.330", "2.1.323"), "keep")
        self.assertEqual(pa("blocked", "", "2.1.322", "2.1.330", "2.1.323"), "keep")
        self.assertEqual(pa("soak", "", "2.1.322", "2.1.323", "2.1.325"), "close")

    def test_open_pr_in_plan(self):
        r = self.plan(Fake({"2.1.322": 99, "2.1.323": 48}, "2.1.323", hub=all_fetchable), "--open-pr", "2.1.323")
        self.assertEqual(r["pr_action"], "keep")


class G_Bump(Base):
    def setUp(self):
        super().setUp()
        self.doc = os.path.join(self.d, "MANAGED-NODE.md")
        with open(self.doc, "w") as f:
            f.write('x\n  "components": {"claude": "2.1.3"}\n    "claude":     {"version": "2.1.322", "artifact": "a"},\ny\n')

    def bump(self, to):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            pin.main(["bump", "--to", to, "--release", self.rel, "--doc", self.doc])
        return out.getvalue().strip()

    def test_edits_both(self):
        self.assertEqual(self.bump("2.1.330"), "2.1.322")
        self.assertEqual(pin.read_pin(self.rel), "2.1.330")
        with open(self.doc) as f:
            text = f.read()
        self.assertIn('"claude":     {"version": "2.1.330", "artifact": "a"}', text)
        self.assertIn('"claude": "2.1.3"', text)  # the §3 sample is not the pin

    def test_the_repo_files_have_one_pin_line_each(self):
        # the workflow bumps the real release.json + MANAGED-NODE.md: a second
        # example of the pin line there would stop every automatic bump
        root = os.path.dirname(HERE)
        for rel in ("release.json", os.path.join("docs", "dev", "MANAGED-NODE.md")):
            with open(os.path.join(root, rel)) as f:
                self.assertEqual(len(pin.PIN_RE.findall(f.read())), 1, rel)

    def test_refuses(self):
        for to in ("2.1.322", "2.1.300", "2.1"):
            with self.assertRaises(SystemExit):
                self.bump(to)
        self.assertEqual(pin.read_pin(self.rel), "2.1.322")
        with open(self.doc, "w") as f:
            f.write("no pin here\n")
        with self.assertRaises(SystemExit):
            self.bump("2.1.330")


class H_Changelog(Base):
    def run_cl(self, *args):
        p = os.path.join(self.d, "CHANGELOG.md")
        with open(p, "w") as f:
            f.write("# Changelog\n\n## 2.1.325\n\n- five\n\n## 2.1.324\n\n- four\n- four b\n\n"
                    "## 2.1.323\n\n- three\n\n## 2.1.322\n\n- two\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            pin.main(["changelog", "--file", p] + list(args))
        return out.getvalue()

    def test_range(self):
        self.assertEqual(self.run_cl("--from", "2.1.322", "--to", "2.1.324"),
                         "### 2.1.324\n- four\n- four b\n### 2.1.323\n- three\n")

    def test_empty_and_cut(self):
        self.assertIn("no CHANGELOG.md section", self.run_cl("--from", "2.1.330", "--to", "2.1.331"))
        self.assertIn("cut at 20 characters", self.run_cl("--from", "2.1.322", "--to", "2.1.325", "--max-chars", "20"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
