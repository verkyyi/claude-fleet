package api

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// claude-fleet#4011: a hub in China lists npmmirror first in
// CCQUOTA_FLEET_RELEASE_NPM. The source changes, the sha512 check does not:
// a source whose package does not match its integrity gives way to the next,
// and when none matches the fetch fails and nothing is kept.

const npmTestPkg, npmTestVer, npmTestName = "claude-code-darwin-arm64", "9.9.9", "claude-9.9.9-darwin-arm64"

func npmTestStore(t *testing.T, regs ...string) *ReleaseStore {
	t.Helper()
	return &ReleaseStore{ArtifactsDir: t.TempDir(), NPMRegistries: regs}
}

func npmTestHits(f *fakeNPM) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.hits {
		n += c
	}
	return n
}

func npmTestHit(f *fakeNPM, path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[path]
}

func npmTestKept(t *testing.T, rs *ReleaseStore) string {
	t.Helper()
	ents, _ := os.ReadDir(rs.ArtifactsDir)
	for _, e := range ents {
		if e.Name() != npmTestName {
			t.Errorf("a fetch left %s behind", e.Name())
		}
	}
	b, err := os.ReadFile(filepath.Join(rs.ArtifactsDir, npmTestName))
	if err != nil {
		return ""
	}
	return string(b)
}

// The mirror listed first is the one fetched from; npm is never asked.
func TestReleaseNPMMirrorFirst(t *testing.T) {
	mirror, npm := newFakeNPM(t), newFakeNPM(t)
	mirror.put(t, npmTestPkg, npmTestVer, []byte("CLAUDE"), false)
	npm.put(t, npmTestPkg, npmTestVer, []byte("CLAUDE"), false)
	rs := npmTestStore(t, mirror.srv.URL, npm.srv.URL)
	if err := rs.fetchClaude(context.Background(), npmTestName); err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if got := npmTestKept(t, rs); got != "CLAUDE" {
		t.Fatalf("kept %q", got)
	}
	tp := "/@anthropic-ai/" + npmTestPkg + "/-/" + npmTestPkg + "-" + npmTestVer + ".tgz"
	if n := npmTestHit(mirror, tp); n != 1 {
		t.Errorf("mirror tarball hits = %d, want 1", n)
	}
	if n := npmTestHits(npm); n != 0 {
		t.Errorf("npm asked %d times with the mirror first and good", n)
	}
}

// The mirror's tarball does not match: the next source's tarball does.
func TestReleaseNPMMirrorTarballBad(t *testing.T) {
	mirror, npm := newFakeNPM(t), newFakeNPM(t)
	mirror.put(t, npmTestPkg, npmTestVer, []byte("CLAUDE"), false)
	npm.put(t, npmTestPkg, npmTestVer, []byte("CLAUDE"), false)
	mirror.mu.Lock()
	for k := range mirror.tgz {
		mirror.tgz[k] = []byte("not the package")
	}
	mirror.mu.Unlock()
	rs := npmTestStore(t, mirror.srv.URL, npm.srv.URL)
	if err := rs.fetchClaude(context.Background(), npmTestName); err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if got := npmTestKept(t, rs); got != "CLAUDE" {
		t.Fatalf("kept %q", got)
	}
}

// The mirror's integrity itself is wrong (no tarball matches it): the next
// source's metadata is asked, and its own integrity is what the bytes meet.
func TestReleaseNPMMirrorIntegrityBad(t *testing.T) {
	mirror, npm := newFakeNPM(t), newFakeNPM(t)
	mirror.put(t, npmTestPkg, npmTestVer, []byte("CLAUDE"), true)
	npm.put(t, npmTestPkg, npmTestVer, []byte("CLAUDE"), false)
	rs := npmTestStore(t, mirror.srv.URL, npm.srv.URL)
	if err := rs.fetchClaude(context.Background(), npmTestName); err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if got := npmTestKept(t, rs); got != "CLAUDE" {
		t.Fatalf("kept %q", got)
	}
	if npmTestHit(npm, "/@anthropic-ai%2f"+npmTestPkg+"/"+npmTestVer) != 1 {
		t.Errorf("npm's metadata was not asked after the mirror's integrity failed")
	}
}

// No source's package matches: an error, and nothing kept.
func TestReleaseNPMAllBad(t *testing.T) {
	mirror, npm := newFakeNPM(t), newFakeNPM(t)
	mirror.put(t, npmTestPkg, npmTestVer, []byte("EVIL"), true)
	npm.put(t, npmTestPkg, npmTestVer, []byte("EVIL"), true)
	rs := npmTestStore(t, mirror.srv.URL, npm.srv.URL)
	err := rs.fetchClaude(context.Background(), npmTestName)
	if err == nil || !strings.Contains(err.Error(), "sha512 does not match") {
		t.Fatalf("fetch with every source lying: %v", err)
	}
	if got := npmTestKept(t, rs); got != "" {
		t.Fatalf("kept %q from lying sources", got)
	}
}

// urlRecorder answers 404 to everything and remembers what was asked.
type urlRecorder struct {
	mu   sync.Mutex
	urls []string
}

func (u *urlRecorder) RoundTrip(r *http.Request) (*http.Response, error) {
	u.mu.Lock()
	u.urls = append(u.urls, r.URL.String())
	u.mu.Unlock()
	return &http.Response{StatusCode: http.StatusNotFound, Body: http.NoBody, Request: r}, nil
}

// No CCQUOTA_FLEET_RELEASE_NPM: the same URLs, in the same order, as before
// #4011 — npm's own registry, then npmmirror.
func TestReleaseNPMUnsetSameURLs(t *testing.T) {
	rec := &urlRecorder{}
	rs := &ReleaseStore{ArtifactsDir: t.TempDir(), Client: &http.Client{Transport: rec}}
	if err := rs.fetchClaude(context.Background(), npmTestName); err == nil {
		t.Fatal("fetch from 404s succeeded")
	}
	want := []string{
		"https://registry.npmjs.org/@anthropic-ai%2fclaude-code-darwin-arm64/9.9.9",
		"https://registry.npmmirror.com/@anthropic-ai%2fclaude-code-darwin-arm64/9.9.9",
	}
	if strings.Join(rec.urls, " ") != strings.Join(want, " ") {
		t.Fatalf("asked %v, want %v", rec.urls, want)
	}
}
