package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// countingGitHub is a GitHub stand-in that counts every request it gets.
func countingGitHub(t *testing.T, g *fakeGitHub) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	n := new(atomic.Int64)
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		g.ServeHTTP(w, r)
	}))
	t.Cleanup(s.Close)
	return s, n
}

// claude-fleet#4847 ②: the hub knows stable, its cache is cold (just
// restarted) and GitHub answers nothing but connection errors — /version names
// no client_url and /install is the image's own installer, at once: never a
// client sent to a URL that 502s, never a 90 + 15 s wait first.
func TestStableKnownColdCacheGitHubGoneServesImage(t *testing.T) {
	needPacked(t)
	h, _ := certHarness(t)
	g := &fakeGitHub{stable: shaA, files: map[string]string{
		shaA + "/" + StableManifestPath: "bin/fleet-install.sh installer\n",
		shaA + "/bin/fleet-install.sh":  "#!/bin/sh\n# " + stableAwareMark + "\n",
	}}
	gh := httptest.NewServer(g)
	h.srv.Stable = &StableSource{Repo: "o/r", APIBase: gh.URL, RawBase: gh.URL}
	must(t, h.srv.Stable.Refresh(context.Background()))
	gh.Close() // GitHub: connection refused from here on

	start := time.Now()
	var v map[string]any
	_, body := getBody(t, h.http.URL+"/version")
	must(t, json.Unmarshal([]byte(body), &v))
	if _, ok := v["client_url"]; ok {
		t.Fatalf("/version announces client_url with the files out of reach: %v", v)
	}
	if v["client_version"] != fleetclient.Version || v["stable_source"] != stableSrcImage {
		t.Fatalf("/version = %v, want the image's client", v)
	}
	if p, _ := v["stable_problem"].(string); !strings.Contains(p, shaA[:7]) {
		t.Errorf("stable_problem %q does not say the known stable is not here", p)
	}
	resp, inst := getBody(t, h.http.URL+"/install")
	img, _ := fleetclient.Files.ReadFile(fleetclient.Installer)
	want := strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(string(img), fleetclient.HubPlaceholder, h.http.URL), DebugPlaceholder, ""), InvitePlaceholder, "")
	if resp.StatusCode != 200 || inst != want {
		t.Fatalf("/install: %d %.80q, want the image's installer", resp.StatusCode, inst)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("/version + /install took %s with GitHub gone, want no wait", d)
	}
}

// upstreamRig: an upstream hub that signs its releases (the rig's), stable at
// shaA, and a self-hosted hub that follows it — a release store with no key of
// its own, the upstream's key as its root, no GitHub at all.
type upstreamRig struct {
	up   *releaseRig
	down *ReleaseStore
	src  *StableSource
	hub  *httptest.Server
}

func newUpstreamRig(t *testing.T) *upstreamRig {
	t.Helper()
	u := &upstreamRig{up: newReleaseRig(t)}
	must(t, u.up.rs.promote(context.Background(), shaA))
	u.src = &StableSource{Offline: true, Upstream: u.up.hub.URL}
	u.down = &ReleaseStore{Dir: t.TempDir(), Root: u.up.pub, Repo: "o/r", Source: u.src}
	u.src.Local = u.down
	u.hub = releaseHub(t, u.down)
	return u
}

// claude-fleet#4847 ③: a self-hosted hub takes its stable from the upstream
// hub — signed, checked against its root, kept whole — and serves it to its
// own machines exactly as the upstream does.
func TestUpstreamHubMirrorsStable(t *testing.T) {
	u := newUpstreamRig(t)
	if got := u.src.Commit(); got != "" {
		t.Fatalf("before any look: Commit = %q", got)
	}
	must(t, u.src.Refresh(context.Background()))
	if sha, on := u.down.PublishedStable(); !on || sha != shaA {
		t.Fatalf("after the mirror: stable %q published %v", sha, on)
	}
	if got := u.src.Commit(); got != shaA || u.src.Source() != stableSrcUpstream || u.src.Problem() != "" {
		t.Fatalf("Commit %q source %q problem %q", got, u.src.Source(), u.src.Problem())
	}
	if !u.src.Ready(shaA) {
		t.Fatal("a mirrored stable is not ready to serve")
	}
	if b, err := u.src.File(context.Background(), shaA, "bin/fleet"); err != nil || string(b) != "#!/bin/sh\necho A\n" {
		t.Fatalf("client file from the mirror: %q %v", b, err)
	}
	// a machine pinned to the same root takes it from the self-hosted hub, artifacts and all
	f := &release.Fetcher{Hub: u.hub.URL, Key: u.up.pub}
	m, err := f.Fetch(context.Background(), "stable", filepath.Join(t.TempDir(), "rt"), true)
	if err != nil {
		t.Fatalf("fetch from the mirror: %v", err)
	}
	if m.SHA != shaA || m.Seq != 1 || len(m.Artifacts) != 4 {
		t.Fatalf("mirrored manifest sha %s seq %d artifacts %d", m.SHA, m.Seq, len(m.Artifacts))
	}

	// the same look again: nothing to do
	u.src.mu.Lock()
	u.src.at = time.Time{}
	u.src.mu.Unlock()
	must(t, u.src.Refresh(context.Background()))

	// the upstream moves: the next look follows, one past
	u.up.g.mu.Lock()
	u.up.g.files[shaB+"/tokenledger/go.mod"] = "module x\n"
	u.up.g.mu.Unlock()
	must(t, u.up.rs.promote(context.Background(), shaB))
	must(t, u.src.Refresh(context.Background()))
	if p := u.down.stable(); p.SHA != shaB || p.Seq != 2 {
		t.Fatalf("after the upstream moved: %+v", p)
	}
}

// A release the store's root does not vouch for is refused, said in
// stable_problem, and this hub's stable stays where it was.
func TestUpstreamHubWrongKeyRefused(t *testing.T) {
	u := newUpstreamRig(t)
	other, _, err := ed25519.GenerateKey(rand.Reader)
	must(t, err)
	u.down.Root = other
	if err := u.src.Refresh(context.Background()); err == nil {
		t.Fatal("a release signed by another key was taken")
	}
	if _, on := u.down.PublishedStable(); on || u.down.Has(shaA) {
		t.Fatal("a refused release landed in the store")
	}
	if p := u.src.Problem(); !strings.Contains(p, "upstream") {
		t.Fatalf("stable_problem %q does not name the upstream", p)
	}
	if u.src.Commit() != "" {
		t.Fatal("a refused upstream still hands out a stable")
	}
}

// claude-fleet#4847 ③: once the release store holds stable, the GitHub source
// is never called — not for the stable, not for a file, not to build.
func TestReleaseStoreNeverAsksGitHub(t *testing.T) {
	u := newUpstreamRig(t)
	must(t, u.src.Refresh(context.Background()))
	gh, calls := countingGitHub(t, &fakeGitHub{stable: shaB, tarball: true})
	s := &StableSource{Repo: "o/r", APIBase: gh.URL, RawBase: gh.URL, Local: u.down}
	u.down.Source = s
	for i := 0; i < 3; i++ {
		if got := s.Commit(); got != shaA {
			t.Fatalf("Commit = %q, want the store's %s", got, shaA)
		}
		if !s.Ready(shaA) || !s.Seen(shaA) {
			t.Fatal("the store's stable is not ready / seen")
		}
		if _, err := s.File(context.Background(), shaA, "bin/fleet"); err != nil {
			t.Fatal(err)
		}
	}
	time.Sleep(50 * time.Millisecond) // a background lookup would have landed
	if n := calls.Load(); n != 0 {
		t.Fatalf("GitHub was asked %d times with a release store holding stable", n)
	}
	if s.Source() != stableSrcRelease {
		t.Errorf("Source = %q, want release", s.Source())
	}
}

// A hub configured with no GitHub source, no upstream and no store: the
// image's client, and nothing asks GitHub (the default since claude-fleet#4847).
func TestStableOfflineAsksNothing(t *testing.T) {
	gh, calls := countingGitHub(t, &fakeGitHub{stable: shaA, tarball: true})
	s := &StableSource{APIBase: gh.URL, RawBase: gh.URL, Offline: true}
	if s.Commit() != "" || s.Ready(shaA) || s.Source() != stableSrcImage {
		t.Fatal("an offline source hands out a stable")
	}
	if _, err := s.Tree(context.Background(), shaA, releasePathSafe); err == nil {
		t.Fatal("an offline source built a tree")
	}
	time.Sleep(50 * time.Millisecond)
	if n := calls.Load(); n != 0 {
		t.Fatalf("GitHub was asked %d times", n)
	}
}
