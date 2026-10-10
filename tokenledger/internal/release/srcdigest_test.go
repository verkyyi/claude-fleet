package release

import (
	"os"
	"path/filepath"
	"testing"
)

// sourceDigestVector: one commit's files and the digest they make. bin/fleet-stable.sh's
// ccquota gate computes the same from git — fleet-src-digest-selftest.sh holds it
// to this very value (claude-fleet#2930), so the two can never drift apart.
var sourceDigestVector = map[string]string{
	"tokenledger/go.mod":                                  "module x\n",
	"tokenledger/go.sum":                                  "",
	"tokenledger/cmd/ccquota/main.go":                     "package main\n",
	"tokenledger/internal/store/schema.sql":               "create table t (x);\n",
	"tokenledger/internal/store/store_test.go":            "package store\n",
	"tokenledger/internal/x/testdata/a.json":              "{}\n",
	"tokenledger/internal/x/README.md":                    "# x\n",
	"tokenledger/internal/api/fleetclient/manifest":       "bin/fleet\n",
	"tokenledger/internal/api/fleetclient/pack/bin/fleet": "#!/bin/sh\n",
	"tokenledger/README.md":                               "# t\n",
	"tokenledger/web/src/app.ts":                          "x\n",
	"bin/fleet":                                           "#!/bin/sh\n",
}

const sourceDigestWant = "98b57ee06907b504832054f38880d92c9bb273dcaa16f70f89964524731bd3a8"

func vectorFiles() map[string][]byte {
	out := map[string][]byte{}
	for p, s := range sourceDigestVector {
		out[p] = []byte(s)
	}
	return out
}

func TestSourceDigestVector(t *testing.T) {
	got := SourceDigest(vectorFiles())
	if got != sourceDigestWant {
		t.Fatalf("SourceDigest(vector) = %s, want %s", got, sourceDigestWant)
	}
	// only the inputs count: dropping every non-input changes nothing
	only := map[string][]byte{}
	for p, b := range vectorFiles() {
		switch p {
		case "tokenledger/go.mod", "tokenledger/go.sum", "tokenledger/cmd/ccquota/main.go", "tokenledger/internal/store/schema.sql":
			only[p] = b
		}
	}
	if SourceDigest(only) != got {
		t.Fatal("a file that is not a build input moved the digest")
	}
	// one byte of Go source moves it
	only["tokenledger/cmd/ccquota/main.go"] = []byte("package main \n")
	if SourceDigest(only) == got {
		t.Fatal("a source edit did not move the digest")
	}
	if SourceDigest(map[string][]byte{"bin/fleet": nil}) != "" {
		t.Fatal("a commit with no Go source has a digest")
	}
}

// The docker build's side (a checkout on disk) and the hub's (a commit's
// files) agree.
func TestSourceDigestDirMatches(t *testing.T) {
	root := t.TempDir()
	for p, s := range sourceDigestVector {
		if r, ok := cutPrefix(p, SourcePrefix); ok {
			f := filepath.Join(root, filepath.FromSlash(r))
			if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(f, []byte(s), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := os.Symlink("main.go", filepath.Join(root, "cmd", "ccquota", "link.go")); err != nil {
		t.Fatal(err)
	}
	got, err := SourceDigestDir(root)
	if err != nil || got != sourceDigestWant {
		t.Fatalf("SourceDigestDir = %s %v, want %s", got, err, sourceDigestWant)
	}
}

func cutPrefix(s, p string) (string, bool) {
	if len(s) >= len(p) && s[:len(p)] == p {
		return s[len(p):], true
	}
	return s, false
}
