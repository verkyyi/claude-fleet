package api

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/web"
)

// AppIconV is the icon's own version (a new logo is a new icon URL, so Safari's
// favicon cache lets the old one go): the first 8 hex of the embedded
// favicon.svg's sha256 — itself a copy of extras/fleet-theme/logo.svg.
func TestAppIconVersion(t *testing.T) {
	assets := web.Assets()
	if assets == nil {
		t.Skip("no web/dist embedded")
	}
	b, err := fs.ReadFile(assets, "favicon.svg")
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	if want := hex.EncodeToString(sum[:])[:8]; AppIconV != want {
		t.Fatalf("AppIconV = %q, the icon's sha256 starts %q — set AppIconV in site_serve.go", AppIconV, want)
	}
	for _, page := range []string{entryHead} {
		for _, p := range appIconPaths {
			if !strings.Contains(page, `href="`+p+`?v=`+AppIconV+`"`) {
				t.Errorf("a way-in page names %s without ?v=%s", p, AppIconV)
			}
		}
	}
}
