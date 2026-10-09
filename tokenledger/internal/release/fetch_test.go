package release

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// A hub serving one release from disk (Range, like http.ServeContent on the
// real hub), with a hook to throttle or cut an artifact (claude-fleet#2701).
type fakeHub struct {
	dir  string // the release dir (<sha>/…)
	pub  ed25519.PublicKey
	srv  *httptest.Server
	mu   sync.Mutex
	hits map[string][]string // artifact → the Range header of every request
	// art, when set, serves an artifact instead of ServeFile
	art func(w http.ResponseWriter, r *http.Request, name string, b []byte) bool
}

func newFakeHub(t *testing.T, artifacts map[string][]byte, releaseJSON string) *fakeHub {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	src := t.TempDir()
	arts := map[string]string{}
	for n, b := range artifacts {
		p := filepath.Join(src, n)
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		arts[n] = p
	}
	files := map[string][]byte{"bin/x": []byte("#!/bin/sh\n")}
	if releaseJSON != "" {
		files[ReleaseJSON] = []byte(releaseJSON)
	}
	dir := filepath.Join(t.TempDir(), sha)
	if _, err := Build(dir, "o/r", sha, files, arts, key, time.Unix(1e9, 0)); err != nil {
		t.Fatal(err)
	}
	h := &fakeHub{dir: dir, pub: pub, hits: map[string][]string{}}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rest := strings.TrimPrefix(r.URL.Path, Path+sha)
		rest = strings.TrimPrefix(rest, "/")
		if rest == "" {
			rest = ManifestName
		}
		if n, ok := strings.CutPrefix(rest, ArtifactDir+"/"); ok {
			h.mu.Lock()
			h.hits[n] = append(h.hits[n], r.Header.Get("Range"))
			h.mu.Unlock()
			if h.art != nil && h.art(w, r, n, artifacts[n]) {
				return
			}
		}
		http.ServeFile(w, r, filepath.Join(dir, rest))
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *fakeHub) fetcher() *Fetcher {
	return &Fetcher{Hub: h.srv.URL, Key: h.pub, Stall: 300 * time.Millisecond}
}

func (h *fakeHub) ranges(n string) []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.hits[n]...)
}

func blob(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

func checkFetched(t *testing.T, dest string, want map[string][]byte) {
	t.Helper()
	for n, b := range want {
		got, err := os.ReadFile(filepath.Join(dest, ".release", ArtifactDir, n))
		if err != nil || !bytes.Equal(got, b) {
			t.Fatalf("%s: not the artifact (%v)", n, err)
		}
	}
}

// A connection that goes quiet half way is cut after Stall — not after a
// whole-body deadline — and the same run goes on from the byte it reached.
func TestFetchResumesAfterStall(t *testing.T) {
	big := blob(1 << 20)
	h := newFakeHub(t, map[string][]byte{"big": big}, "")
	first := true
	h.art = func(w http.ResponseWriter, r *http.Request, n string, b []byte) bool {
		if !first {
			return false
		}
		first = false
		w.Header().Set("Content-Length", "1048576")
		_, _ = w.Write(b[:400_000])
		w.(http.Flusher).Flush()
		<-r.Context().Done() // silent until the client gives up
		return true
	}
	var log bytes.Buffer
	f := h.fetcher()
	f.Progress = &log
	dest := filepath.Join(t.TempDir(), "r")
	if _, err := f.Fetch(context.Background(), sha, dest, true); err != nil {
		t.Fatalf("%v\n%s", err, log.String())
	}
	checkFetched(t, dest, map[string][]byte{"big": big})
	if got := h.ranges("big"); len(got) != 2 || got[0] != "" || got[1] != "bytes=400000-" {
		t.Fatalf("requests %q, want a whole one then a Range from 400000", got)
	}
	if !strings.Contains(log.String(), "no bytes for 300ms") || !strings.Contains(log.String(), "resuming at") {
		t.Fatalf("progress does not say what happened:\n%s", log.String())
	}
	if _, err := os.Stat(dest + ".dl"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the default cache was left behind")
	}
}

// A run killed half way leaves its bytes in the cache; the next run asks only
// for the rest. Nothing half-done appears at dest.
func TestFetchResumesAcrossRuns(t *testing.T) {
	a, b := blob(300_000), blob(500_000)
	h := newFakeHub(t, map[string][]byte{"a": a, "b": b}, "")
	cut := true
	h.art = func(w http.ResponseWriter, r *http.Request, n string, body []byte) bool {
		if n != "b" || !cut {
			return false
		}
		cut = false
		w.Header().Set("Content-Length", "500000")
		_, _ = w.Write(body[:123_456])
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		return true
	}
	cache := t.TempDir()
	dest := filepath.Join(t.TempDir(), "r")
	f := h.fetcher()
	f.Cache, f.Stall = cache, time.Minute
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if _, err := f.Fetch(ctx, sha, dest, true); err == nil {
		t.Fatal("a killed run said it finished")
	}
	if _, err := os.Stat(dest); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a killed run left dest")
	}
	f2 := h.fetcher()
	f2.Cache = cache
	if _, err := f2.Fetch(context.Background(), sha, dest, true); err != nil {
		t.Fatal(err)
	}
	checkFetched(t, dest, map[string][]byte{"a": a, "b": b})
	if got := h.ranges("a"); len(got) != 1 {
		t.Fatalf("a: %q — a finished artifact was fetched again", got)
	}
	if got := h.ranges("b"); len(got) != 2 || got[1] != "bytes=123456-" {
		t.Fatalf("b: %q, want the second run to resume at 123456", got)
	}
}

// --pinned: only what release.json pins for the platform, not every file the
// hub carries (old versions, other platforms).
func TestFetchPinnedOnly(t *testing.T) {
	rj := `{"components":{"claude":{"version":"2.1.2","artifact":"claude-{version}-{os}-{arch}"},
	"ccquota":{"artifact":"ccquota-{os}-{arch}"}}}`
	arts := map[string][]byte{
		"claude-2.1.2-darwin-arm64": blob(1000), "ccquota-darwin-arm64": blob(1000),
		"claude-2.1.1-darwin-arm64": blob(1000), "claude-2.1.2-linux-amd64": blob(1000), "ccquota-linux-amd64": blob(1000),
	}
	h := newFakeHub(t, arts, rj)
	f := h.fetcher()
	f.Platforms = []string{"darwin-arm64"}
	dest := filepath.Join(t.TempDir(), "r")
	if _, err := f.Fetch(context.Background(), sha, dest, true); err != nil {
		t.Fatal(err)
	}
	ents, _ := os.ReadDir(filepath.Join(dest, ".release", ArtifactDir))
	var got []string
	for _, e := range ents {
		got = append(got, e.Name())
	}
	if strings.Join(got, ",") != "ccquota-darwin-arm64,claude-2.1.2-darwin-arm64" {
		t.Fatalf("fetched %v", got)
	}
	if _, err := VerifyDir(h.pub, dest); err != nil {
		t.Fatalf("a pinned fetch does not verify: %v", err)
	}
}

// An artifact already in the cache (seeded from the machine's last release)
// is not fetched again; a cached file with the wrong bytes is.
func TestFetchCachedNotRefetched(t *testing.T) {
	a, b := blob(2000), blob(3000)
	h := newFakeHub(t, map[string][]byte{"a": a, "b": b}, "")
	cache := t.TempDir()
	m, _, _, err := h.fetcher().Manifest(context.Background(), sha)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range m.Artifacts {
		body := a
		if x.Name == "b" {
			body = blob(3000) // same size, wrong bytes
		}
		if err := os.WriteFile(filepath.Join(cache, x.SHA256), body, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f := h.fetcher()
	f.Cache = cache
	dest := filepath.Join(t.TempDir(), "r")
	if _, err := f.Fetch(context.Background(), sha, dest, true); err != nil {
		t.Fatal(err)
	}
	checkFetched(t, dest, map[string][]byte{"a": a, "b": b})
	if n := len(h.ranges("a")); n != 0 {
		t.Fatalf("a was fetched %d times though cached", n)
	}
	if n := len(h.ranges("b")); n != 1 {
		t.Fatalf("b (bad cache) fetched %d times, want 1", n)
	}
}

// A slow hub (issue #2701 saw ~1 MB/s) never hits a deadline while bytes keep
// coming: the run takes many times Stall and still lands.
func TestFetchSlowButSteady(t *testing.T) {
	big := blob(256 << 10)
	h := newFakeHub(t, map[string][]byte{"big": big}, "")
	h.art = func(w http.ResponseWriter, r *http.Request, n string, b []byte) bool {
		w.Header().Set("Content-Length", "262144")
		for i := 0; i < len(b); i += 16 << 10 {
			_, _ = w.Write(b[i : i+16<<10])
			w.(http.Flusher).Flush()
			time.Sleep(60 * time.Millisecond) // ~1 s in all, Stall is 300ms
		}
		return true
	}
	dest := filepath.Join(t.TempDir(), "r")
	start := time.Now()
	if _, err := h.fetcher().Fetch(context.Background(), sha, dest, true); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) < 3*300*time.Millisecond {
		t.Fatal("the throttle did not throttle")
	}
	checkFetched(t, dest, map[string][]byte{"big": big})
}
