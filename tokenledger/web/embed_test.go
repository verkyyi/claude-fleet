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
	for _, want := range []string{"<title>ccquota</title>", `href="styles.css"`, `src="app.js"`} {
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

// The landing view groups by TEAM when teams are configured, and never
// numbers a row.
//
// This is not cosmetic. Read as a per-person performance ranking, an internal
// board makes people avoid the tool or pad their usage, and either destroys
// the cost data it exists to provide.
//
// Before Task 11, "team leads user" was checkable as raw markup order:
// teamCard(d.byTeam) had to appear before userCard(d.byUser) in the one
// index.html that rendered both, unconditionally, on every load. The
// module-shell redesign moves that breakdown into the Review view (state.js's
// GROUPS = the dimensions a "breakdown" card can show; team is one of them),
// where g1/g2 pick which dimension each of the two breakdown cards shows via
// a segmented control the viewer operates — there is no longer a fixed
// "teamCard" / "userCard" pair in a hardcoded order for a byte offset to
// compare. web/dist/review.js is a placeholder until Task 12 (see
// task-12-brief.md); once it renders the real breakdown cards, the ordering
// half of this test's intent belongs back there, keyed to the DEFAULTS in
// lib/state.js rather than to source order in one file. Until then, the
// still-checkable, still-permanent half — nothing in the dashboard renders a
// rank marker — is asserted against every embedded module, which is a
// strictly wider net than the single file the old check swept.
func TestDashboard_TeamCardLeadsAndNothingIsRanked(t *testing.T) {
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
