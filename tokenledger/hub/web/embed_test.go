package web

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// web/dist is embedded, so a missing one is not a cosmetic problem: go:embed
// fails the BUILD. An unanchored `dist/` in .gitignore once kept the whole
// directory out of every commit, and a fresh clone could not compile.

// distIcons is all web/dist holds since the old console went
// (claude-fleet#3939): the tab icons, for a hub whose site is off.
var distIcons = map[string]string{
	"favicon.svg":          "extras/fleet-theme/logo.svg",
	"favicon.ico":          "site/assets/favicon.ico",
	"apple-touch-icon.png": "site/assets/apple-touch-icon.png",
}

// The old console is gone, not hidden (claude-fleet#3939): no page, script or
// stylesheet of it is in the build — the console is web/console's.
func TestAssets_OldConsoleIsGone(t *testing.T) {
	assets := Assets()
	if assets == nil {
		t.Fatal("no web/dist embedded: web/dist/favicon.svg is missing from this checkout")
	}
	var extra []string
	err := fs.WalkDir(assets, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		// chat/ is gitignored: an old checkout's web-chat build, never packed again
		if _, ok := distIcons[p]; !ok && !strings.HasPrefix(p, "chat/") {
			extra = append(extra, p)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(extra)
	if len(extra) > 0 {
		t.Errorf("web/dist holds more than the tab icons: %v — the old console was taken down (claude-fleet#3939)", extra)
	}
}

// The tab icon is the site's logo, one source -- extras/fleet-theme/logo.svg,
// site/assets for its PNG / ICO renderings (claude-fleet#3946): web/dist
// carries copies of the three files, byte for byte.
func TestAssets_IconIsTheSiteLogo(t *testing.T) {
	assets := Assets()
	if assets == nil {
		t.Fatal("no web/dist embedded")
	}
	for copyName, src := range distIcons {
		want, err := os.ReadFile(filepath.Join("..", "..", "..", filepath.FromSlash(src)))
		if err != nil {
			t.Fatalf("%s: %v", src, err)
		}
		got, err := fs.ReadFile(assets, copyName)
		if err != nil {
			t.Fatalf("%s unreadable: %v", copyName, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("web/dist/%s is not %s: cp %s tokenledger/hub/web/dist/%s", copyName, src, src, copyName)
		}
	}
}
