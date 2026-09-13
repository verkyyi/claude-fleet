package web

import (
	"io/fs"
	"strings"
	"testing"
)

// The dashboard is embedded, so a missing web/dist is not a cosmetic problem:
// go:embed fails the BUILD. An unanchored `dist/` in .gitignore once kept the
// whole directory out of every commit, and a fresh clone could not compile.
//
// As of the Task 11 module-shell redesign, index.html is a thin shell (no
// inline <style>/<script>) that loads styles.css and the ES modules that hold
// the actual dashboard, so the placeholder-size and content-anchor checks
// this test used to make against index.html alone now apply to that whole
// module set instead.
func TestAssets_DashboardIsEmbedded(t *testing.T) {
	assets := Assets()
	if assets == nil {
		t.Fatal("no dashboard embedded: web/dist/index.html is missing from this checkout")
	}
	b, err := fs.ReadFile(assets, "index.html")
	if err != nil {
		t.Fatalf("index.html unreadable: %v", err)
	}
	// A couple of anchors, so an empty or truncated shell cannot pass.
	//
	// The title anchor is deliberately NOT the product name. It was
	// "<title>ccquota</title>", and renaming the product to TokenLedger broke
	// this test — an anchor whose job is "the shell is not truncated" should not
	// also be an assertion about branding, or every rename is a red build.
	// `<title>` alone still proves the head survived.
	for _, want := range []string{"<title>", `href="styles.css"`, `src="app.js"`} {
		if !strings.Contains(string(b), want) {
			t.Errorf("index.html shell is missing %q", want)
		}
	}
	// Every module the shell depends on must actually be embedded, and none
	// of them may be a truncated placeholder.
	minBytes := map[string]int64{
		"styles.css": 4096, "app.js": 1024, "scope.js": 1024,
		"charts.js": 4096, "now.js": 4096,
		"lib/dom.js": 512, "lib/state.js": 512,
	}
	for name, min := range minBytes {
		st, err := fs.Stat(assets, name)
		if err != nil {
			t.Errorf("%s is not embedded: %v", name, err)
			continue
		}
		if st.Size() < min {
			t.Errorf("%s is %d bytes; that is a placeholder, not the real module", name, st.Size())
		}
	}
	// The "am I about to hit the wall" gauge and its account-spanning shape
	// used to be right there in index.html; both now live in now.js's
	// wallCard.
	nowJS, err := fs.ReadFile(assets, "now.js")
	if err != nil {
		t.Fatalf("now.js unreadable: %v", err)
	}
	for _, want := range []string{"/v1/limits", "per_account"} {
		if !strings.Contains(string(nowJS), want) {
			t.Errorf("now.js is missing %q", want)
		}
	}
}

// Nothing in the dashboard numbers a row (no "1.", no podium).
//
// This is not cosmetic. Read as a per-person performance ranking, an internal
// board makes people avoid the tool or pad their usage, and either destroys
// the cost data it exists to provide.
//
// Before Task 11, this test also asserted markup order: the one index.html
// that rendered both a team and a user breakdown card, unconditionally, had
// to put teamCard(d.byTeam) before userCard(d.byUser). The module-shell
// redesign moved that breakdown into the Review view (lib/state.js's GROUPS
// — the dimensions a "breakdown" card can show, team among them), where g1/g2
// pick which dimension each of the two breakdown cards shows via a segmented
// control the viewer operates: there is no longer a fixed "teamCard" /
// "userCard" pair in a hardcoded order for a byte offset to compare, so that
// half of the check was retired (task-11-report.md has the detail; an
// equivalent for Review's breakdown cards, if wanted, is a new test keyed to
// lib/state.js's DEFAULTS, not to source order in one file). What remains —
// and is a strictly wider net than the single file the original check swept
// — is this: no rank marker in any embedded module.
func TestDashboard_NothingIsRanked(t *testing.T) {
	assets := Assets()
	forbidden := []string{"podium", "${i + 1}.", "${idx + 1}."}
	err := fs.WalkDir(assets, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".js") {
			return err
		}
		b, err := fs.ReadFile(assets, path)
		if err != nil {
			return err
		}
		src := string(b)
		for _, f := range forbidden {
			if strings.Contains(src, f) {
				t.Errorf("%s renders a rank marker (%q)", path, f)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestAssets_UserPageIsEmbedded(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "user.html")
	if err != nil {
		t.Fatalf("user.html unreadable: %v", err)
	}
	if len(b) < 1024 {
		t.Fatalf("user.html is %d bytes; that is a placeholder", len(b))
	}
	for _, want := range []string{"/v1/user", "os_user"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("user page is missing %q", want)
		}
	}
}
