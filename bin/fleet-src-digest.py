#!/usr/bin/env python3
"""fleet-src-digest.py [--image] <git dir> <rev> — the digest of the Go source a
commit's ccquota is built from (issue #2930), read from git: the same value
tokenledger/shared/release/srcdigest.go computes from the commit's files (the
hub, building a release) and from a checkout (the Dockerfile, stamping
-X main.SrcDigest). bin/fleet-stable.sh's ccquota gate holds the target to the
hub's dist binaries with it. Prints the hex digest, or nothing when the commit
has no such source; exit 2 when git cannot read the commit.

Two digests (issue #4813; KEEP IN STEP with release.SourceInput /
ImageSourceInput — fleet-src-digest-selftest.sh pins both to one vector), both
under tokenledger/ less *_test.go, testdata/, *.md,
hub/api/fleetclient/manifest and hub/api/fleetclient/pack/ (internal/ before #4814):
  (default) the NODE's — every regular file under shared/ (#4811) and agent/
            (#4812): what a release's ccquota-<os>-<arch> are built from
  --image   the hub IMAGE's — everything under hub/ (less hub/web/ and
            hub/apitest/, #4814), shared/ and agent/, and the hub's paths
            before it was a module (go.mod, go.sum, cmd/, internal/): what
            fleet-train-hub.sh reads to
            redeploy the hub, and the digest an image from before #4813 stamped
            (compat-1v: 下一批删 — the stable gate accepts it for one version)
sha256 over "<path>\\0<sha256 hex>\\n" per file, paths relative to
tokenledger/, sorted.
"""
import hashlib
import subprocess
import sys

PREFIX = "tokenledger/"


def source_input(p):
    """The node's inputs (release.SourceInput)."""
    return (p.startswith("shared/") or p.startswith("agent/")) and build_file(p)


def image_source_input(p):
    """The hub image's inputs (release.ImageSourceInput)."""
    if p in ("go.mod", "go.sum"):
        return True
    if p.startswith("hub/web/") or p.startswith("hub/apitest/"):
        return False
    if not (p.startswith("hub/") or p.startswith("cmd/") or p.startswith("internal/")
            or p.startswith("shared/") or p.startswith("agent/")):
        return False
    return build_file(p)


def build_file(p):
    if p.endswith("_test.go") or p.endswith(".md") \
            or p in ("hub/api/fleetclient/manifest", "internal/api/fleetclient/manifest") \
            or p.startswith("hub/api/fleetclient/pack/") or p.startswith("internal/api/fleetclient/pack/"):
        return False
    return "testdata" not in p.split("/")


def digest(files):
    """files: {path relative to tokenledger/: bytes} → hex, "" when none."""
    if not files:
        return ""
    h = hashlib.sha256()
    for p in sorted(files, key=lambda s: s.encode()):
        h.update(("%s\0%s\n" % (p, hashlib.sha256(files[p]).hexdigest())).encode())
    return h.hexdigest()


def from_git(gitdir, rev, inputs=source_input):
    ls = subprocess.run(["git", "-C", gitdir, "ls-tree", "-r", "-z", "--full-tree", rev, "--", PREFIX],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    want = []
    for ent in ls.split(b"\0"):
        if not ent:
            continue
        meta, path = ent.split(b"\t", 1)
        mode, kind, oid = meta.split()
        rel = path.decode()[len(PREFIX):]
        if kind == b"blob" and mode in (b"100644", b"100755") and inputs(rel):
            want.append((rel, oid))
    if not want:
        return ""
    out = subprocess.run(["git", "-C", gitdir, "cat-file", "--batch"],
                         input=b"".join(oid + b"\n" for _, oid in want),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    files, i = {}, 0
    for rel, _ in want:
        nl = out.index(b"\n", i)
        size = int(out[i:nl].split()[2])
        files[rel] = out[nl + 1:nl + 1 + size]
        i = nl + 1 + size + 1
    return digest(files)


def main(argv):
    inputs = source_input
    if len(argv) > 1 and argv[1] == "--image":
        inputs, argv = image_source_input, argv[:1] + argv[2:]
    if len(argv) != 3:
        sys.stderr.write("usage: fleet-src-digest.py [--image] <git dir> <rev>\n")
        return 2
    try:
        print(from_git(argv[1], argv[2], inputs))
    except (subprocess.CalledProcessError, OSError, ValueError, IndexError) as e:
        sys.stderr.write("fleet-src-digest: cannot read %s: %s\n" % (argv[2], e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
