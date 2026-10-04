package codex

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNamedProfilesIsolateHomesAndKeepExistingIdentity(t *testing.T) {
	home := t.TempDir()
	original := filepath.Join(home, ".codex")
	if _, err := AddProfile(home, "personal", original); err != nil {
		t.Fatal(err)
	}
	work, err := AddProfile(home, "work", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := UseProfile(home, "work"); err != nil {
		t.Fatal(err)
	}
	ps, err := Profiles(home, original, original)
	if err != nil || len(ps) != 2 {
		t.Fatal("duplicate profile directory", err)
	}
	if ps[0].Name != "personal" || ps[0].Default || !ps[1].Default {
		t.Fatalf("default/name selection wrong: %+v", ps)
	}
	selected, err := SelectProfile(home, original, "")
	if err != nil || selected.Home != work.Home {
		t.Fatal("wrong launch profile")
	}
	if selected.Home == original {
		t.Fatal("independent account overwrites existing login")
	}
	if _, err := AddProfile(home, "personal", work.Home); err == nil {
		t.Fatal("existing registration redirected")
	}
	if _, err := AddProfile(home, "../../bad", ""); err == nil {
		t.Fatal("unsafe name accepted")
	}
	if err := UseProfile(home, "missing"); err == nil {
		t.Fatal("missing default accepted")
	}
	link := filepath.Join(home, "alias")
	if os.Symlink(original, link) == nil {
		ps, err = Profiles(home, original, link)
		if err != nil || len(ps) != 2 {
			t.Fatal("symlink collected twice")
		}
	}
}

func TestLoginObservationDoesNotFollowChangedCredentials(t *testing.T) {
	home := t.TempDir()
	writeTestLogin(t, home, "one", time.Now().Add(time.Hour))
	if err := RecordLogin(home); err != nil {
		t.Fatal(err)
	}
	a, _ := ReadAuth(home)
	at := LoginObservedAt(home, a)
	if at.IsZero() || at.After(time.Now()) {
		t.Fatal("managed login boundary unavailable")
	}
	writeTestLogin(t, home, "two", time.Now().Add(time.Hour))
	b, _ := ReadAuth(home)
	if !LoginObservedAt(home, b).IsZero() {
		t.Fatal("new credentials inherited another login's boundary")
	}
}
