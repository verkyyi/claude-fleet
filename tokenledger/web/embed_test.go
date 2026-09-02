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

// The landing view groups by TEAM when teams are configured.
//
// This is not cosmetic. Read as a per-person performance ranking, an internal
// board makes people avoid the tool or pad their usage, and either destroys
// the cost data it exists to provide. Putting the team card first, and never
// numbering rows, is the design against that -- so it is asserted rather than
// left to the next person editing the file.
func TestDashboard_TeamCardLeadsAndNothingIsRanked(t *testing.T) {
	b, err := fs.ReadFile(Assets(), "index.html")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)

	team := strings.Index(src, "teamCard(d.byTeam)")
	user := strings.Index(src, "userCard(d.byUser)")
	if team < 0 {
		t.Fatal("the dashboard does not render a team card")
	}
	if user < 0 {
		t.Fatal("the dashboard does not render a user card")
	}
	if team > user {
		t.Error("the user card is rendered before the team card; the landing view is a per-person ranking")
	}
	for _, forbidden := range []string{"podium", "${i + 1}.", "${idx + 1}."} {
		if strings.Contains(src, forbidden) {
			t.Errorf("the dashboard renders a rank marker (%q)", forbidden)
		}
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
