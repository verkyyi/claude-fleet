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
// the digest of the Go source it compiled (cmd/ccquota-srcdigest at docker
// build, -X main.SrcDigest), the hub computes the same digest from the commit
// it is building, and a release whose two differ is not built.
//
// The digest is over tokenledger/'s build inputs: go.mod, go.sum and every
// regular file under cmd/ and internal/ (embedded files too — schema.sql),
// less tests (*_test.go, testdata/), Markdown and the client's file list and
// pack (internal/api/fleetclient/manifest and pack/: the client follows stable,
// not the image — claude-fleet#1805 — and pack/ is gitignored, packed before a
// build; a new client file must not hold stable for a hub redeploy).
// sha256 over "<path>\x00<sha256 hex of the file>\n" per file, paths relative
// to tokenledger/, sorted bytewise. No such file ⇒ "". bin/fleet-stable.sh
// computes the same from git (bin/fleet-src-digest.py, its ccquota gate);
// bin/fleet-src-digest-selftest.sh holds it to srcdigest_test.go's vector.

// SourcePrefix is the Go module's directory in the repo.
const SourcePrefix = "tokenledger/"

// SourceInput: is p (relative to tokenledger/) one of the digest's inputs?
func SourceInput(p string) bool {
	if p == "go.mod" || p == "go.sum" {
		return true
	}
	if !strings.HasPrefix(p, "cmd/") && !strings.HasPrefix(p, "internal/") {
		return false
	}
	if strings.HasSuffix(p, "_test.go") || strings.HasSuffix(p, ".md") ||
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

// SourceDigest: the digest of a commit's files (repo-relative paths), "" when
// it has no Go source.
func SourceDigest(files map[string][]byte) string {
	rel := map[string][]byte{}
	for p, b := range files {
		if r, ok := strings.CutPrefix(p, SourcePrefix); ok && SourceInput(r) {
			rel[r] = b
		}
	}
	return sourceDigest(rel)
}

// SourceDigestDir: the same digest of a tokenledger/ checkout on disk (the
// docker build's context). Only regular files count, as in git's tree.
func SourceDigestDir(dir string) (string, error) {
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
		if !SourceInput(r) {
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
