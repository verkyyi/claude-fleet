package release

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The Go source a ccquota binary was built from (claude-fleet#2930).
//
// A release's ccquota-<os>-<arch> come from the hub image's dist dir — built
// when the IMAGE was, not from the release's commit. So a release could carry
// a new runtime and an old ccquota (2026-10-10: 003e89bb shipped prod-343c92b,
// #2918's Go half reached no machine). The image now stamps every binary with
// the digest of the Go source it compiled (shared/cmd/ccquota-srcdigest at docker
// build, -X main.SrcDigest), the hub computes the same digest from the commit
// it is building, and a release whose two differ is not built.
//
// Two digests (claude-fleet#4813, EPIC #4810 C3):
//
//   - the NODE's source — SourceDigest: what a release's ccquota-<os>-<arch> are
//     compiled from since they are built from the node's own module
//     (agent/cmd/ccquota): every regular file under shared/ (the module both the
//     hub and the node build in, #4811) and agent/ (the node's, #4812), their
//     go.mod and go.sum with them. The Dockerfile stamps it into every binary,
//     the hub's 422 and the manifest's ccquota_src compare it, and so do
//     fleet-stable.sh's ccquota gate and a managed machine's ccquota row. A
//     change to the hub alone does not move it — stable need not wait for a hub
//     image no machine runs.
//   - the hub IMAGE's — ImageSourceDigest: everything under hub/ (the hub's
//     module since claude-fleet#4814; not hub/web/, which was never an input,
//     nor hub/apitest/, the e2e tests' harness no build links), shared/ and
//     agent/ — what the image compiles — and the paths the hub had before it
//     was a module (tokenledger/'s go.mod, go.sum, cmd/, internal/), so an
//     older commit hashes as it always did. bin/fleet-train-hub.sh reads it to decide whether a train
//     redeploys the hub.
//
// Both leave out tests (*_test.go, testdata/), Markdown and the client's file
// list and pack (hub/api/fleetclient/manifest and pack/, internal/ before #4814: the client follows
// stable, not the image — claude-fleet#1805 — and pack/ is gitignored, packed
// before a build; a new client file must not hold stable for a hub redeploy);
// go.work is a developer's convenience the image builds without (GOWORK=off).
// sha256 over "<path>\x00<sha256 hex of the file>\n" per file, paths relative
// to tokenledger/, sorted bytewise. No such file ⇒ "". bin/fleet-src-digest.py
// computes both from git (node; --image); bin/fleet-src-digest-selftest.sh holds
// it to srcdigest_test.go's vector.

// SourcePrefix is the Go module's directory in the repo.
const SourcePrefix = "tokenledger/"

// SourceInput: is p (relative to tokenledger/) one of the NODE's inputs?
func SourceInput(p string) bool {
	if !strings.HasPrefix(p, "shared/") && !strings.HasPrefix(p, "agent/") {
		return false
	}
	return buildFile(p)
}

// ImageSourceInput: is p (relative to tokenledger/) one of the hub image's inputs?
func ImageSourceInput(p string) bool {
	if p == "go.mod" || p == "go.sum" {
		return true
	}
	if strings.HasPrefix(p, "hub/web/") || strings.HasPrefix(p, "hub/apitest/") {
		return false
	}
	if !strings.HasPrefix(p, "hub/") && !strings.HasPrefix(p, "cmd/") && !strings.HasPrefix(p, "internal/") &&
		!strings.HasPrefix(p, "shared/") && !strings.HasPrefix(p, "agent/") {
		return false
	}
	return buildFile(p)
}

// buildFile: not a test, a doc or the client's list / pack.
func buildFile(p string) bool {
	if strings.HasSuffix(p, "_test.go") || strings.HasSuffix(p, ".md") ||
		p == "hub/api/fleetclient/manifest" || strings.HasPrefix(p, "hub/api/fleetclient/pack/") ||
		p == "internal/api/fleetclient/manifest" || strings.HasPrefix(p, "internal/api/fleetclient/pack/") {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "testdata" {
			return false
		}
	}
	return true
}

// SourceDigest: the node's digest of a commit's files (repo-relative paths), ""
// when it has no node source.
func SourceDigest(files map[string][]byte) string { return digestOf(files, SourceInput) }

// ImageSourceDigest: the hub image's digest of a commit's files.
func ImageSourceDigest(files map[string][]byte) string { return digestOf(files, ImageSourceInput) }

// SourceDigestDir: the node's digest of a tokenledger/ checkout on disk (the
// docker build's context). Only regular files count, as in git's tree.
func SourceDigestDir(dir string) (string, error) { return digestDir(dir, SourceInput) }

// ImageSourceDigestDir: the hub image's digest of a checkout on disk.
func ImageSourceDigestDir(dir string) (string, error) { return digestDir(dir, ImageSourceInput) }

func digestOf(files map[string][]byte, input func(string) bool) string {
	rel := map[string][]byte{}
	for p, b := range files {
		if r, ok := strings.CutPrefix(p, SourcePrefix); ok && input(r) {
			rel[r] = b
		}
	}
	return sourceDigest(rel)
}

func digestDir(dir string, input func(string) bool) (string, error) {
	rel := map[string][]byte{}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.Type().IsRegular() {
			return nil
		}
		r, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		r = filepath.ToSlash(r)
		if !input(r) {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel[r] = b
		return nil
	})
	if err != nil {
		return "", err
	}
	return sourceDigest(rel), nil
}

func sourceDigest(rel map[string][]byte) string {
	if len(rel) == 0 {
		return ""
	}
	names := make([]string, 0, len(rel))
	for p := range rel {
		names = append(names, p)
	}
	sort.Strings(names)
	h := sha256.New()
	for _, p := range names {
		s := sha256.Sum256(rel[p])
		h.Write([]byte(p + "\x00" + hex.EncodeToString(s[:]) + "\n"))
	}
	return hex.EncodeToString(h.Sum(nil))
}
