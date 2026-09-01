package web

import (
	"io/fs"
	"strings"
	"testing"
)

// The dashboard is embedded, so a missing web/dist is not a cosmetic problem:
// go:embed fails the BUILD. An unanchored `dist/` in .gitignore once kept the
// whole directory out of every commit, and a fresh clone could not compile.
func TestAssets_DashboardIsEmbedded(t *testing.T) {
	assets := Assets()
	if assets == nil {
		t.Fatal("no dashboard embedded: web/dist/index.html is missing from this checkout")
	}
	b, err := fs.ReadFile(assets, "index.html")
	if err != nil {
		t.Fatalf("index.html unreadable: %v", err)
	}
	if len(b) < 4096 {
		t.Fatalf("index.html is %d bytes; that is a placeholder, not the dashboard", len(b))
	}
	// A couple of anchors, so an empty or truncated file cannot pass.
	for _, want := range []string{"<title>ccquota</title>", "/v1/limits", "per_account"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("embedded dashboard is missing %q", want)
		}
	}
}
