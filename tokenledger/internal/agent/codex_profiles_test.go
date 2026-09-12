package agent

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/codex"
)

func TestAgentDiscoversNamedProfilesWithoutResettingExistingScanner(t *testing.T) {
	c := newCollector(t)
	home := codexHome(t, 2)
	a, err := New(Config{HubURL: c.srv.URL, Token: "test", Home: home, Sources: "codex", StateDir: t.TempDir(), Once: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := a.cycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	first := a.codexProfileSnapshot()[0]
	if _, err := codex.AddProfile(home, "personal", filepath.Join(home, ".codex")); err != nil {
		t.Fatal(err)
	}
	if _, err := codex.AddProfile(home, "work", ""); err != nil {
		t.Fatal(err)
	}
	if err := codex.UseProfile(home, "work"); err != nil {
		t.Fatal(err)
	}
	if err := a.cycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	profiles := a.codexProfileSnapshot()
	if len(profiles) != 2 || profiles[0] != first || profiles[0].name != "personal" || profiles[0].selected || !profiles[1].selected {
		t.Fatal("profile discovery lost cursor or selection")
	}
	if c.count() != 2 {
		t.Fatal("existing usage replayed during profile rename")
	}
}
