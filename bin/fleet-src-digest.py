#!/usr/bin/env python3
"""fleet-src-digest.py <git dir> <rev> — the digest of the Go source a commit's
ccquota is built from (issue #2930), read from git: the same value
tokenledger/internal/release/srcdigest.go computes from the commit's files (the
hub, building a release) and from a checkout (the Dockerfile, stamping
-X main.SrcDigest). bin/fleet-stable.sh's ccquota gate holds the target to the
hub's dist binaries with it. Prints the hex digest, or nothing when the commit
has no Go source; exit 2 when git cannot read the commit.

The inputs (KEEP IN STEP with release.SourceInput — fleet-src-digest-selftest.sh
pins both to one vector): under tokenledger/, go.mod, go.sum and every regular
file under cmd/ and internal/, less *_test.go, testdata/, *.md,
internal/api/fleetclient/manifest and internal/api/fleetclient/pack/. sha256
over "<path>\\0<sha256 hex>\\n" per file, paths relative to tokenledger/, sorted.
"""
import hashlib
import subprocess
import sys

PREFIX = "tokenledger/"


def source_input(p):
    if p in ("go.mod", "go.sum"):
        return True
    if not (p.startswith("cmd/") or p.startswith("internal/")):
        return False
    if p.endswith("_test.go") or p.endswith(".md") or p == "internal/api/fleetclient/manifest" \
            or p.startswith("internal/api/fleetclient/pack/"):
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


def from_git(gitdir, rev):
    ls = subprocess.run(["git", "-C", gitdir, "ls-tree", "-r", "-z", "--full-tree", rev, "--", PREFIX],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    want = []
    for ent in ls.split(b"\0"):
        if not ent:
            continue
        meta, path = ent.split(b"\t", 1)
        mode, kind, oid = meta.split()
        rel = path.decode()[len(PREFIX):]
        if kind == b"blob" and mode in (b"100644", b"100755") and source_input(rel):
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
    if len(argv) != 3:
        sys.stderr.write("usage: fleet-src-digest.py <git dir> <rev>\n")
        return 2
    try:
        print(from_git(argv[1], argv[2]))
    except (subprocess.CalledProcessError, OSError, ValueError, IndexError) as e:
        sys.stderr.write("fleet-src-digest: cannot read %s: %s\n" % (argv[2], e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
