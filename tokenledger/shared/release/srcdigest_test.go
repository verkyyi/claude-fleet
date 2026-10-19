package release

import (
	"os"
	"path/filepath"
	"testing"
)

// sourceDigestVector: one commit's files and the digest they make. bin/fleet-stable.sh's
// ccquota gate computes the same from git — fleet-src-digest-selftest.sh holds it
// to this very value (claude-fleet#2930), so the two can never drift apart.
// sourceDigestWant is the node's (shared/ + agent/, claude-fleet#4813),
// imageSourceDigestWant the hub image's (the whole tree — the old algorithm).
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
	"tokenledger/go.work":                                 "go 1.25.0\n",
	"tokenledger/shared/go.mod":                           "module y\n",
	"tokenledger/shared/release/r.go":                     "package release\n",
	"tokenledger/shared/release/r_test.go":                "package release\n",
	"tokenledger/agent/go.mod":                            "module z\n",
	"tokenledger/agent/cli/run.go":                        "package cli\n",
	"tokenledger/agent/cli/run_test.go":                   "package cli\n",
	"tokenledger/README.md":                               "# t\n",
	"tokenledger/web/src/app.ts":                          "x\n",
	"bin/fleet":                                           "#!/bin/sh\n",
}

const sourceDigestWant = "a4d9ff221d9360909b588647a6377eb906d3641e57b11d375d840c341ee1a70a"

const imageSourceDigestWant = "660f7fb7211bb0d661d9a18f10e823bab8657938ff32498bb511d13897a53b00"

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
	// only the node's inputs count: dropping everything else changes nothing —
	// the hub's cmd/ and internal/ and the root go.mod included (#4813)
	only := map[string][]byte{}
	for p, b := range vectorFiles() {
		switch p {
		case "tokenledger/shared/go.mod", "tokenledger/shared/release/r.go",
			"tokenledger/agent/go.mod", "tokenledger/agent/cli/run.go":
			only[p] = b
		}
	}
	if SourceDigest(only) != got {
		t.Fatal("a file that is not a node build input moved the digest")
	}
	// one byte of the shared module (#4811): a node built from an older
	// shared/ is a stale ccquota
	only["tokenledger/shared/release/r.go"] = []byte("package release \n")
	if SourceDigest(only) == got {
		t.Fatal("an edit under shared/ did not move the digest")
	}
	// and of the node's own module (#4812)
	only["tokenledger/shared/release/r.go"] = []byte("package release\n")
	only["tokenledger/agent/cli/run.go"] = []byte("package cli \n")
	if SourceDigest(only) == got {
		t.Fatal("an edit under agent/ did not move the digest")
	}
	if SourceDigest(map[string][]byte{"bin/fleet": nil, "tokenledger/cmd/ccquota/main.go": nil}) != "" {
		t.Fatal("a commit with no node source has a digest")
	}
}

// TestImageSourceDigest: the hub image's digest is the whole tree's — what the
// train reads to redeploy the hub, and what an image from before #4813 stamped.
func TestImageSourceDigest(t *testing.T) {
	got := ImageSourceDigest(vectorFiles())
	if got != imageSourceDigestWant {
		t.Fatalf("ImageSourceDigest(vector) = %s, want %s", got, imageSourceDigestWant)
	}
	if got == SourceDigest(vectorFiles()) {
		t.Fatal("the image's digest is the node's")
	}
	only := map[string][]byte{}
	for p, b := range vectorFiles() {
		switch p {
		case "tokenledger/go.mod", "tokenledger/go.sum", "tokenledger/cmd/ccquota/main.go", "tokenledger/internal/store/schema.sql",
			"tokenledger/shared/go.mod", "tokenledger/shared/release/r.go",
			"tokenledger/agent/go.mod", "tokenledger/agent/cli/run.go":
			only[p] = b
		}
	}
	if ImageSourceDigest(only) != got {
		t.Fatal("a file that is not an image build input moved the digest")
	}
	// a hub-only edit moves the image's digest and not the node's
	node := SourceDigest(only)
	only["tokenledger/cmd/ccquota/main.go"] = []byte("package main \n")
	if ImageSourceDigest(only) == got {
		t.Fatal("a hub source edit did not move the image's digest")
	}
	if SourceDigest(only) != node {
		t.Fatal("a hub-only edit moved the node's digest")
	}
	if ImageSourceDigest(map[string][]byte{"bin/fleet": nil}) != "" {
		t.Fatal("a commit with no Go source has an image digest")
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
	got, err = ImageSourceDigestDir(root)
	if err != nil || got != imageSourceDigestWant {
		t.Fatalf("ImageSourceDigestDir = %s %v, want %s", got, err, imageSourceDigestWant)
	}
}

func cutPrefix(s, p string) (string, bool) {
	if len(s) >= len(p) && s[:len(p)] == p {
		return s[len(p):], true
	}
	return s, false
}
