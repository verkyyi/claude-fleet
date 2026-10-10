package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// releaseRig: a fake GitHub (tarballs on, raw host down — the hub's cluster
// in China), a stable source, a release store on a temp dir with a dist dir
// and a pinned-installers dir, and a hub serving /v1/fleet/release/.
type releaseRig struct {
	g     *fakeGitHub
	gh    *httptest.Server
	rs    *ReleaseStore
	hub   *httptest.Server
	pub   ed25519.PublicKey
	key   ed25519.PrivateKey
	dir   string
	dist  string
	inst  string
	npm   *fakeNPM
	fetch *release.Fetcher
}

func newReleaseRig(t *testing.T) *releaseRig {
	t.Helper()
	r := &releaseRig{}
	r.g = &fakeGitHub{stable: shaA, tarball: true, rawDown: true, files: map[string]string{
		shaA + "/" + StableManifestPath:    "bin/fleet\n",
		shaA + "/bin/fleet":                "#!/bin/sh\necho A\n",
		shaA + "/bin/fleet-lib.sh":         "fleet_x() { :; }\n",
		shaA + "/conf/tmux-shell.conf":     "set -g mouse on\n",
		shaA + "/skills/x/SKILL.md":        "# x\n",
		shaA + "/docs/BREAK-IT.md":         "# rows\n",
		shaA + "/tokenledger/go.mod":       "module x\n",
		shaA + "/.github/workflows/ci.yml": "on: push\n",
		shaB + "/" + StableManifestPath:    "bin/fleet\n",
		shaB + "/bin/fleet":                "#!/bin/sh\necho B\n",
	}}
	r.gh = httptest.NewServer(r.g)
	t.Cleanup(r.gh.Close)
	var err error
	r.pub, r.key, err = ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	r.dir, r.dist, r.inst = t.TempDir(), t.TempDir(), t.TempDir()
	must(t, os.WriteFile(filepath.Join(r.dist, "ccquota-darwin-arm64"), []byte("\x7fBIN darwin"), 0o755))
	must(t, os.WriteFile(filepath.Join(r.dist, "ccquota-linux-amd64"), []byte("\x7fBIN linux"), 0o755))
	must(t, os.WriteFile(filepath.Join(r.dist, "README"), []byte("not a binary"), 0o644))
	must(t, os.WriteFile(filepath.Join(r.inst, "claude-code-2.1.0-darwin-arm64"), []byte("CLAUDE"), 0o644))
	must(t, os.WriteFile(filepath.Join(r.inst, "codex-0.50.0-darwin-arm64.tar.gz"), []byte("CODEX"), 0o644))
	src := &StableSource{Repo: "o/r", APIBase: r.gh.URL, RawBase: r.gh.URL}
	r.rs = &ReleaseStore{Dir: r.dir, Key: r.key, Repo: "o/r", Source: src, DistDir: r.dist, ArtifactsDir: r.inst}
	r.npm = newFakeNPM(t)
	r.rs.NPMRegistries = []string{r.npm.srv.URL} // never the real npm
	r.hub = releaseHub(t, r.rs)
	r.fetch = &release.Fetcher{Hub: r.hub.URL, Key: r.pub}
	return r
}

func releaseHub(t *testing.T, rs *ReleaseStore) *httptest.Server {
	t.Helper()
	s := &Server{Releases: rs}
	mux := http.NewServeMux()
	mux.HandleFunc(release.Path, s.handleRelease)
	h := httptest.NewServer(mux)
	t.Cleanup(h.Close)
	return h
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// claude-fleet#2335: stable moves → the hub builds, signs and keeps the
// release; a machine fetches it from the hub and gets every runtime file,
// binary and installer — and nothing that is not runtime.
func TestReleaseBuiltOnStableAndFetched(t *testing.T) {
	r := newReleaseRig(t)
	built := make(chan string, 1)
	r.rs.Source.OnStable = func(sha string) { r.rs.OnStable(sha); built <- sha }
	must(t, r.rs.Source.Refresh(context.Background()))
	select {
	case sha := <-built:
		if sha != shaA {
			t.Fatalf("built %s, want %s", sha, shaA)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("stable moved but no release was built")
	}
	if !r.rs.Has(shaA) {
		t.Fatal("release not on disk")
	}

	resp, body := getBody(t, r.hub.URL+release.Path+"stable")
	if resp.StatusCode != 200 {
		t.Fatalf("GET stable: %d %s", resp.StatusCode, body)
	}
	var m release.Manifest
	must(t, json.Unmarshal([]byte(body), &m))
	if m.SHA != shaA || len(m.Files) == 0 || len(m.Artifacts) != 4 {
		t.Fatalf("manifest sha %s files %d artifacts %v", m.SHA, len(m.Files), m.Artifacts)
	}
	if resp.Header.Get("X-Ccquota-Release-Signature") == "" {
		t.Error("manifest served without its signature header")
	}
	if _, err := release.Verify(r.pub, []byte(body), resp.Header.Get("X-Ccquota-Release-Signature")); err != nil {
		t.Fatalf("served manifest does not verify: %v", err)
	}
	_, keyLine := getBody(t, r.hub.URL+release.KeyPath)
	if k, err := release.ParsePublicKey([]byte(keyLine)); err != nil || !k.Equal(r.pub) {
		t.Fatalf("/key = %q (%v)", keyLine, err)
	}

	dest := filepath.Join(t.TempDir(), "rt")
	got, err := r.fetch.Fetch(context.Background(), "stable", dest, true)
	if err != nil {
		t.Fatal(err)
	}
	if got.SHA != shaA {
		t.Fatalf("fetched %s", got.SHA)
	}
	for p, want := range map[string]string{
		"bin/fleet":                               "#!/bin/sh\necho A\n",
		"conf/tmux-shell.conf":                    "set -g mouse on\n",
		"skills/x/SKILL.md":                       "# x\n",
		"docs/BREAK-IT.md":                        "# rows\n",
		"README.md":                               "not a client file\n",
		".release/" + release.SigName:             "",
		".release/artifacts/ccquota-darwin-arm64": "\x7fBIN darwin",
		".release/artifacts/claude-code-2.1.0-darwin-arm64":   "CLAUDE",
		".release/artifacts/codex-0.50.0-darwin-arm64.tar.gz": "CODEX",
	} {
		b, err := os.ReadFile(filepath.Join(dest, p))
		if err != nil {
			t.Errorf("%s missing: %v", p, err)
		} else if want != "" && string(b) != want {
			t.Errorf("%s = %q, want %q", p, b, want)
		}
	}
	if st, err := os.Stat(filepath.Join(dest, "bin/fleet")); err != nil || st.Mode().Perm()&0o100 == 0 {
		t.Errorf("bin/fleet not executable: %v", err)
	}
	for _, p := range []string{"tokenledger/go.mod", ".github/workflows/ci.yml", ".release/artifacts/README"} {
		if _, err := os.Stat(filepath.Join(dest, p)); err == nil {
			t.Errorf("%s is not runtime, but was shipped", p)
		}
	}
	if _, err := release.VerifyDir(r.pub, dest); err != nil {
		t.Fatalf("installed release does not verify: %v", err)
	}
}

// The completion test: GitHub out of reach, a machine still updates — from
// the hub's store, even across a hub restart (a fresh source that never saw
// stable).
func TestReleaseFetchWithGitHubDown(t *testing.T) {
	r := newReleaseRig(t)
	must(t, r.rs.Source.Refresh(context.Background()))
	must(t, r.rs.Ensure(context.Background(), shaA))
	r.g.mu.Lock()
	r.g.down = true
	r.g.mu.Unlock()
	r.gh.Close()

	restarted := &ReleaseStore{Dir: r.dir, Key: r.key, Repo: "o/r",
		Source: &StableSource{Repo: "o/r", APIBase: r.gh.URL, RawBase: r.gh.URL}}
	hub := releaseHub(t, restarted)
	f := &release.Fetcher{Hub: hub.URL, Key: r.pub}
	dest := filepath.Join(t.TempDir(), "rt")
	if _, err := f.Fetch(context.Background(), shaA, dest, true); err != nil {
		t.Fatalf("GitHub down: fetch from the hub failed: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "bin/fleet")); string(b) != "#!/bin/sh\necho A\n" {
		t.Fatalf("bin/fleet = %q", b)
	}
	// a sha neither stored nor seen: 404, never a build attempt
	if resp, _ := getBody(t, hub.URL+release.Path+shaB); resp.StatusCode != 404 {
		t.Fatalf("unseen sha: %d, want 404", resp.StatusCode)
	}
}

// Any tampered byte — a runtime file, an artifact, the manifest, the
// signature, a different key — refuses the release and leaves nothing.
func TestReleaseTamperRefused(t *testing.T) {
	r := newReleaseRig(t)
	must(t, r.rs.Source.Refresh(context.Background()))
	must(t, r.rs.Ensure(context.Background(), shaA))
	base := r.rs.dir(shaA)
	snapshot := map[string][]byte{}
	for _, n := range []string{release.ManifestName, release.SigName, release.TreeName, "artifacts/claude-code-2.1.0-darwin-arm64"} {
		b, err := os.ReadFile(filepath.Join(base, n))
		must(t, err)
		snapshot[n] = b
	}
	restore := func() {
		for n, b := range snapshot {
			must(t, os.WriteFile(filepath.Join(base, n), b, 0o644))
		}
	}
	try := func(name string, f *release.Fetcher, artifacts bool, wantErr string) {
		t.Helper()
		dest := filepath.Join(t.TempDir(), "rt")
		_, err := f.Fetch(context.Background(), shaA, dest, artifacts)
		if err == nil || !strings.Contains(err.Error(), wantErr) {
			t.Errorf("%s: err %v, want %q", name, err, wantErr)
		}
		for _, p := range []string{dest, dest + ".partial"} {
			if _, err := os.Stat(p); err == nil {
				t.Errorf("%s: %s left behind", name, p)
			}
		}
		restore()
	}

	// a runtime file changed inside the tree (manifest + tree digest re-signed
	// by nobody): the tree digest no longer matches
	tree := snapshot[release.TreeName]
	bad := append([]byte{}, tree...)
	bad[len(bad)/2] ^= 0xff
	must(t, os.WriteFile(filepath.Join(base, release.TreeName), bad, 0o644))
	try("tree", r.fetch, false, "digest")

	must(t, os.WriteFile(filepath.Join(base, "artifacts/claude-code-2.1.0-darwin-arm64"), []byte("EVIL!!"), 0o644))
	try("artifact", r.fetch, true, "digest")

	mb := strings.Replace(string(snapshot[release.ManifestName]), `"repo": "o/r"`, `"repo": "x/y"`, 1)
	must(t, os.WriteFile(filepath.Join(base, release.ManifestName), []byte(mb), 0o644))
	try("manifest", r.fetch, false, "signature")

	must(t, os.WriteFile(filepath.Join(base, release.SigName), []byte("AAAA\n"), 0o644))
	try("signature", r.fetch, false, "signature")

	other, _, _ := ed25519.GenerateKey(rand.Reader)
	try("another key", &release.Fetcher{Hub: r.hub.URL, Key: other}, false, "signature")

	// untampered: it still installs
	if _, err := r.fetch.Fetch(context.Background(), shaA, filepath.Join(t.TempDir(), "rt"), true); err != nil {
		t.Fatalf("untouched release refused: %v", err)
	}
}

// A file changed AFTER install is caught by `ccquota release verify --dir`.
func TestReleaseVerifyDirCatchesEdit(t *testing.T) {
	r := newReleaseRig(t)
	must(t, r.rs.Source.Refresh(context.Background()))
	dest := filepath.Join(t.TempDir(), "rt")
	if _, err := r.fetch.Fetch(context.Background(), shaA, dest, false); err != nil {
		t.Fatal(err)
	}
	must(t, os.WriteFile(filepath.Join(dest, "bin/fleet"), []byte("#!/bin/sh\nrm -rf /\n"), 0o755))
	if _, err := release.VerifyDir(r.pub, dest); err == nil || !strings.Contains(err.Error(), "bin/fleet") {
		t.Fatalf("edited file not caught: %v", err)
	}
}

// The store keeps the newest ReleaseKeep and never the current stable.
func TestReleasePruneKeepsNewestAndStable(t *testing.T) {
	r := newReleaseRig(t)
	r.rs.Keep = 3
	must(t, r.rs.Source.Refresh(context.Background())) // stable = shaA
	files := map[string][]byte{"bin/x": []byte("x")}
	mk := func(sha string, age time.Duration) {
		must(t, r.rs.publish(sha, files, nil, time.Now().Add(-age), release.Seal{}))
	}
	mk(shaA, 100*time.Hour) // the oldest — but stable
	var shas []string
	for i := 0; i < 5; i++ {
		sha := fmt.Sprintf("%040d", i+1)
		shas = append(shas, sha)
		mk(sha, time.Duration(5-i)*time.Hour)
	}
	r.rs.prune()
	if !r.rs.Has(shaA) {
		t.Error("the current stable was pruned")
	}
	for i, sha := range shas {
		if want := i >= 2; r.rs.Has(sha) != want {
			t.Errorf("release %d kept=%v, want %v", i, r.rs.Has(sha), want)
		}
	}
}

// No store: every release route is a 404 — the hub as before.
func TestReleaseOffIs404(t *testing.T) {
	s := &Server{}
	rec := httptest.NewRecorder()
	s.handleRelease(rec, httptest.NewRequest(http.MethodGet, release.Path+"key", nil))
	if rec.Code != 404 {
		t.Fatalf("no store: %d", rec.Code)
	}
}

func TestReleasePathOK(t *testing.T) {
	for p, want := range map[string]bool{
		"bin/fleet": true, "conf/a": true, "docs/x.md": true, "README.md": true, "LICENSE": true,
		StableManifestPath: true, "tokenledger/go.mod": false, ".github/x": false, ".gitignore": false,
		"deploy/k8s/x": false, "bin/../x": false, "": false,
	} {
		if releasePathOK(p) != want {
			t.Errorf("releasePathOK(%q) = %v", p, !want)
		}
	}
}

// claude-fleet#2366: the volume is an OSS bucket shared by two replicas. Both
// build the same stable at once: each build stays whole in its own directory,
// current names one of them, and the release fetches. A build with no current
// (a replica that died mid-write) is never served, and is pruned once stale.
func TestReleaseTwoReplicasOneVolume(t *testing.T) {
	r := newReleaseRig(t)
	must(t, r.rs.Source.Refresh(context.Background()))
	other := &ReleaseStore{Dir: r.dir, Key: r.key, Repo: "o/r", Source: r.rs.Source, DistDir: r.dist, ArtifactsDir: r.inst}
	files := map[string][]byte{StableManifestPath: []byte("bin/fleet\n"), "bin/fleet": []byte("#!/bin/sh\necho A\n")}
	errs := make(chan error, 2)
	for i, s := range []*ReleaseStore{r.rs, other} {
		go func(s *ReleaseStore, n int) {
			arts := s.artifacts()
			if n == 1 { // a replica on another image: different binaries
				arts = map[string]string{}
			}
			errs <- s.publish(shaA, files, arts, time.Now(), release.Seal{})
		}(s, i)
	}
	must(t, <-errs)
	must(t, <-errs)
	if _, err := r.fetch.Fetch(context.Background(), shaA, filepath.Join(t.TempDir(), "rt"), true); err != nil {
		t.Fatalf("after a race: %v", err)
	}
	bs, _ := os.ReadDir(filepath.Join(r.dir, shaA))
	builds := 0
	for _, b := range bs {
		if buildIDRe.MatchString(b.Name()) {
			builds++
		}
	}
	if builds != 2 {
		t.Fatalf("%d builds on the volume, want both kept until stale", builds)
	}

	// a half-written build of shaB with no current: not served
	half := filepath.Join(r.dir, shaB, fmt.Sprintf("b%d-%012x", time.Now().Add(-time.Hour).Unix(), 1))
	must(t, os.MkdirAll(half, 0o755))
	must(t, os.WriteFile(filepath.Join(half, release.TreeName), []byte("partial"), 0o644))
	if r.rs.Has(shaB) {
		t.Fatal("a build with no current counts as a release")
	}
	// a stale losing build of shaA goes; the served one stays
	served := r.rs.dir(shaA)
	loser := filepath.Join(r.dir, shaA, fmt.Sprintf("b%d-%012x", time.Now().Add(-time.Hour).Unix(), 2))
	must(t, os.MkdirAll(loser, 0o755))
	r.rs.prune()
	if _, err := os.Stat(loser); err == nil {
		t.Error("a stale build current does not name was kept")
	}
	if r.rs.dir(shaA) != served || !r.rs.Has(shaA) {
		t.Error("the served build was pruned")
	}
}

// claude-fleet#2398: production's layout — the pinned installers under
// pinned/ on the release volume itself (CCQUOTA_FLEET_RELEASE_DIR=/releases,
// CCQUOTA_FLEET_RELEASE_ARTIFACTS=/releases/pinned). A stable built after they
// land carries all three release.json names; a release already built is never
// rebuilt (they reach the NEXT stable move, not the one on disk); prune never
// touches pinned/.
func TestReleasePinnedArtifactsOnTheReleaseVolume(t *testing.T) {
	r := newReleaseRig(t)
	vol := t.TempDir()
	pinned := filepath.Join(vol, "pinned")
	must(t, os.MkdirAll(pinned, 0o755))
	r.rs.Dir, r.rs.ArtifactsDir = vol, pinned

	// a release built before the files land: no installers, and it stays so
	files := map[string][]byte{"bin/x": []byte("x")}
	must(t, r.rs.publish(shaB, files, r.rs.artifacts(), time.Now().Add(-time.Hour), release.Seal{}))

	names := []string{"claude-2.1.293-darwin-arm64", "codex-0.154.0-darwin-arm64", "tmux-3.7c-darwin-arm64"}
	for _, n := range names {
		must(t, os.WriteFile(filepath.Join(pinned, n), []byte(n), 0o755))
	}
	must(t, r.rs.Source.Refresh(context.Background())) // stable = shaA
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	must(t, r.rs.Ensure(ctx, shaA))
	must(t, r.rs.Ensure(ctx, shaB)) // on disk: not rebuilt

	have := func(sha string) map[string]bool {
		resp, body := getBody(t, r.hub.URL+release.Path+sha)
		if resp.StatusCode != 200 {
			t.Fatalf("GET %s: %d %s", sha[:7], resp.StatusCode, body)
		}
		var m release.Manifest
		must(t, json.Unmarshal([]byte(body), &m))
		out := map[string]bool{}
		for _, a := range m.Artifacts {
			out[a.Name] = true
		}
		return out
	}
	a, b := have(shaA), have(shaB)
	for _, n := range names {
		if !a[n] {
			t.Errorf("stable %s lacks %s: %v", shaA[:7], n, a)
		}
		if b[n] {
			t.Errorf("release %s, built before the files landed, was rebuilt with %s", shaB[:7], n)
		}
	}

	r.rs.Keep = 1
	r.rs.prune() // shaB goes, stable and pinned/ stay
	if r.rs.Has(shaB) || !r.rs.Has(shaA) {
		t.Errorf("prune: shaB kept=%v shaA kept=%v", r.rs.Has(shaB), r.rs.Has(shaA))
	}
	for _, n := range names {
		if _, err := os.Stat(filepath.Join(pinned, n)); err != nil {
			t.Errorf("prune touched pinned/%s: %v", n, err)
		}
	}
}

// claude-fleet#2631: release.json pins a Claude Code version whose artifact is
// not in CCQUOTA_FLEET_RELEASE_ARTIFACTS. The build is refused (named, nothing
// kept), /artifacts says what a build would carry — what fleet-stable.sh move
// checks first — and once the file lands the next request builds the whole
// release, no second stable move needed. A tree with no release.json pins
// nothing (every other test here).
func TestReleaseBuildRefusesMissingPinned(t *testing.T) {
	r := newReleaseRig(t)
	r.g.files[shaA+"/"+release.ReleaseJSON] = `{"schema":1,"components":{` +
		`"ccquota":{"artifact":"ccquota-{os}-{arch}"},` +
		`"claude":{"version":"9.9.9","artifact":"claude-{version}-{os}-{arch}"},` +
		`"codex":{"version":"0.1.0","artifact":"codex-{version}-{os}-{arch}"},` +
		`"tmux":{"version":"3.7c","artifact":"tmux-{version}-{os}-{arch}"},` +
		`"supervisor":{"script":"bin/fleet-node-update.py"}}}`
	must(t, os.WriteFile(filepath.Join(r.inst, "codex-0.1.0-darwin-arm64"), []byte("CODEX"), 0o755))
	must(t, os.WriteFile(filepath.Join(r.inst, "tmux-3.7c-darwin-arm64"), []byte("TMUX"), 0o755))
	must(t, r.rs.Source.Refresh(context.Background()))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	err := r.rs.Ensure(ctx, shaA)
	if err == nil || !strings.Contains(err.Error(), "claude-9.9.9-darwin-arm64") {
		t.Fatalf("Ensure = %v, want a refusal naming claude-9.9.9-darwin-arm64", err)
	}
	if r.rs.Has(shaA) {
		t.Fatal("a release missing a pinned artifact was kept")
	}
	resp, body := getBody(t, r.hub.URL+release.Path+"stable")
	if resp.StatusCode != http.StatusBadGateway || !strings.Contains(body, "claude-9.9.9-darwin-arm64") {
		t.Fatalf("GET stable: %d %s", resp.StatusCode, body)
	}

	listed := func() []string {
		resp, body := getBody(t, r.hub.URL+release.Path+"artifacts")
		if resp.StatusCode != 200 || resp.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("GET artifacts: %d %q %s", resp.StatusCode, resp.Header.Get("Cache-Control"), body)
		}
		var v struct {
			Artifacts []string `json:"artifacts"`
			Platforms []string `json:"platforms"`
		}
		must(t, json.Unmarshal([]byte(body), &v))
		if strings.Join(v.Platforms, ",") != "darwin-arm64" {
			t.Errorf("platforms %v", v.Platforms)
		}
		return v.Artifacts
	}
	if got := strings.Join(listed(), " "); strings.Contains(got, "claude-9.9.9") || !strings.Contains(got, "ccquota-darwin-arm64") || strings.Contains(got, "README") {
		t.Fatalf("artifacts before the upload: %s", got)
	}

	must(t, os.WriteFile(filepath.Join(r.inst, "claude-9.9.9-darwin-arm64"), []byte("CLAUDE"), 0o755))
	if got := strings.Join(listed(), " "); !strings.Contains(got, "claude-9.9.9-darwin-arm64") {
		t.Fatalf("artifacts after the upload: %s", got)
	}
	resp, body = getBody(t, r.hub.URL+release.Path+"stable")
	if resp.StatusCode != 200 {
		t.Fatalf("GET stable after the upload: %d %s", resp.StatusCode, body)
	}
	var m release.Manifest
	must(t, json.Unmarshal([]byte(body), &m))
	have := map[string]bool{}
	for _, a := range m.Artifacts {
		have[a.Name] = true
	}
	for _, n := range []string{"ccquota-darwin-arm64", "claude-9.9.9-darwin-arm64", "codex-0.1.0-darwin-arm64", "tmux-3.7c-darwin-arm64"} {
		if !have[n] {
			t.Errorf("the rebuilt release lacks %s: %v", n, m.Artifacts)
		}
	}
}

// fakeNPM: a registry holding the packages a test puts in it (none: 404).
type fakeNPM struct {
	srv  *httptest.Server
	mu   sync.Mutex
	meta map[string]string // "/@anthropic-ai%2f<pkg>/<ver>" → JSON
	tgz  map[string][]byte // "/@anthropic-ai/<pkg>/-/<pkg>-<ver>.tgz" → bytes
	hits map[string]int
}

func newFakeNPM(t *testing.T) *fakeNPM {
	t.Helper()
	f := &fakeNPM{meta: map[string]string{}, tgz: map[string][]byte{}, hits: map[string]int{}}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		p := r.URL.EscapedPath()
		f.hits[p]++
		if m, ok := f.meta[p]; ok {
			_, _ = w.Write([]byte(m))
			return
		}
		if b, ok := f.tgz[p]; ok {
			_, _ = w.Write(b)
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

// put publishes <pkg>@<ver> holding package/claude = bin; integrity as npm
// computes it unless lie.
func (f *fakeNPM) put(t *testing.T, pkg, ver string, bin []byte, lie bool) {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, e := range []struct {
		name string
		b    []byte
	}{{"package/package.json", []byte(`{}`)}, {"package/claude", bin}} {
		must(t, tw.WriteHeader(&tar.Header{Name: e.name, Mode: 0o755, Size: int64(len(e.b)), Typeflag: tar.TypeReg}))
		_, err := tw.Write(e.b)
		must(t, err)
	}
	must(t, tw.Close())
	must(t, gz.Close())
	sum := sha512.Sum512(buf.Bytes())
	if lie {
		sum[0] ^= 1
	}
	tp := "/@anthropic-ai/" + pkg + "/-/" + pkg + "-" + ver + ".tgz"
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tgz[tp] = buf.Bytes()
	f.meta["/@anthropic-ai%2f"+pkg+"/"+ver] = `{"dist":{"integrity":"sha512-` + base64.StdEncoding.EncodeToString(sum[:]) +
		`","tarball":"` + f.srv.URL + tp + `"}}`
}

// claude-fleet#2631: the Claude Code release.json pins is the hub's to fetch.
// A build that lacks it takes Anthropic's npm package for the platform, checks
// it against the registry's sha512 integrity, and signs it into the release;
// /artifacts?want= names it fetchable before any build; a tarball that does not
// match is never kept, and the build is refused as before.
func TestReleaseFetchesPinnedClaude(t *testing.T) {
	r := newReleaseRig(t)
	r.g.files[shaA+"/"+release.ReleaseJSON] = `{"schema":1,"components":{` +
		`"ccquota":{"artifact":"ccquota-{os}-{arch}"},` +
		`"claude":{"version":"9.9.9","artifact":"claude-{version}-{os}-{arch}"},` +
		`"codex":{"version":"0.1.0","artifact":"codex-{version}-{os}-{arch}"},` +
		`"tmux":{"version":"3.7c","artifact":"tmux-{version}-{os}-{arch}"},` +
		`"supervisor":{"script":"bin/fleet-node-update.py"}}}`
	must(t, os.WriteFile(filepath.Join(r.inst, "codex-0.1.0-darwin-arm64"), []byte("CODEX"), 0o755))
	must(t, os.WriteFile(filepath.Join(r.inst, "tmux-3.7c-darwin-arm64"), []byte("TMUX"), 0o755))
	must(t, r.rs.Source.Refresh(context.Background()))

	// a tarball that does not match its integrity: refused, nothing left behind
	r.npm.put(t, "claude-code-darwin-arm64", "9.9.9", []byte("EVIL"), true)
	resp, body := getBody(t, r.hub.URL+release.Path+"stable")
	if resp.StatusCode != http.StatusBadGateway || !strings.Contains(body, "claude-9.9.9-darwin-arm64") {
		t.Fatalf("GET stable with a lying tarball: %d %s", resp.StatusCode, body)
	}
	ents, _ := os.ReadDir(r.inst)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "claude-9") || strings.HasPrefix(e.Name(), ".") {
			t.Errorf("a refused fetch left %s", e.Name())
		}
	}

	r.npm.put(t, "claude-code-darwin-arm64", "9.9.9", []byte("\xcf\xfa\xed\xfe CLAUDE 9.9.9"), false)
	resp, body = getBody(t, r.hub.URL+release.Path+"artifacts?want=claude-9.9.9-darwin-arm64,claude-8.8.8-darwin-arm64,tmux-3.7c-darwin-arm64,../x")
	var v struct {
		Fetchable []string `json:"fetchable"`
	}
	must(t, json.Unmarshal([]byte(body), &v))
	if resp.StatusCode != 200 || strings.Join(v.Fetchable, " ") != "claude-9.9.9-darwin-arm64" {
		t.Fatalf("artifacts?want: %d fetchable=%v %s", resp.StatusCode, v.Fetchable, body)
	}

	resp, body = getBody(t, r.hub.URL+release.Path+"stable")
	if resp.StatusCode != 200 {
		t.Fatalf("GET stable: %d %s", resp.StatusCode, body)
	}
	got, err := os.ReadFile(filepath.Join(r.inst, "claude-9.9.9-darwin-arm64"))
	if err != nil || string(got) != "\xcf\xfa\xed\xfe CLAUDE 9.9.9" {
		t.Fatalf("fetched artifact = %q, %v", got, err)
	}
	if st, _ := os.Stat(filepath.Join(r.inst, "claude-9.9.9-darwin-arm64")); st.Mode().Perm() != 0o755 {
		t.Errorf("fetched artifact mode %v", st.Mode())
	}
	dest := filepath.Join(t.TempDir(), "rt")
	m, err := r.fetch.Fetch(context.Background(), "stable", dest, true)
	if err != nil {
		t.Fatalf("a machine's fetch of the release: %v", err)
	}
	found := false
	for _, a := range m.Artifacts {
		found = found || a.Name == "claude-9.9.9-darwin-arm64"
	}
	if !found {
		t.Fatalf("the release does not carry the fetched claude: %v", m.Artifacts)
	}
}

func TestClaudeNPM(t *testing.T) {
	for in, want := range map[string]string{
		"claude-2.1.295-darwin-arm64":     "claude-code-darwin-arm64@2.1.295",
		"claude-2.1.295-linux-amd64":      "claude-code-linux-x64@2.1.295",
		"claude-2.2.0-beta.1-linux-arm64": "claude-code-linux-arm64@2.2.0-beta.1",
		"codex-0.154.0-darwin-arm64":      "",
		"claude-2.1.295-windows-amd64":    "",
	} {
		pkg, ver, ok := claudeNPM(in)
		got := ""
		if ok {
			got = pkg + "@" + ver
		}
		if got != want {
			t.Errorf("claudeNPM(%s) = %q, want %q", in, got, want)
		}
	}
}

// claude-fleet#2631: a release already on disk that lacks a pinned artifact
// (built by a hub before it could fetch Claude Code — be5a58d on 2026-10-09)
// is rebuilt once the hub can supply it, on the next manifest request, without
// a stable move; a whole one is never re-read, and a lacking one the hub cannot
// help is served as it is.
func TestReleaseHealsLackingPinned(t *testing.T) {
	r := newReleaseRig(t)
	rj := `{"schema":1,"components":{` +
		`"ccquota":{"artifact":"ccquota-{os}-{arch}"},` +
		`"claude":{"version":"9.9.9","artifact":"claude-{version}-{os}-{arch}"},` +
		`"codex":{"version":"0.1.0","artifact":"codex-{version}-{os}-{arch}"},` +
		`"tmux":{"version":"3.7c","artifact":"tmux-{version}-{os}-{arch}"},` +
		`"supervisor":{"script":"bin/fleet-node-update.py"}}}`
	r.g.files[shaA+"/"+release.ReleaseJSON] = rj
	must(t, os.WriteFile(filepath.Join(r.inst, "codex-0.1.0-darwin-arm64"), []byte("CODEX"), 0o755))
	must(t, os.WriteFile(filepath.Join(r.inst, "tmux-3.7c-darwin-arm64"), []byte("TMUX"), 0o755))
	must(t, r.rs.Source.Refresh(context.Background()))
	// what the old hub left: shaA signed without claude
	files := map[string][]byte{"bin/fleet": []byte("#!/bin/sh\n"), release.ReleaseJSON: []byte(rj)}
	must(t, r.rs.publish(shaA, files, r.rs.artifacts(), time.Now().Add(-time.Hour), release.Seal{}))

	carries := func() bool {
		t.Helper()
		resp, body := getBody(t, r.hub.URL+release.Path+"stable")
		if resp.StatusCode != 200 {
			t.Fatalf("GET stable: %d %s", resp.StatusCode, body)
		}
		var m release.Manifest
		must(t, json.Unmarshal([]byte(body), &m))
		for _, a := range m.Artifacts {
			if a.Name == "claude-9.9.9-darwin-arm64" {
				return true
			}
		}
		return false
	}
	// npm has no such version: served as it is, and not retried at once
	if carries() {
		t.Fatal("claude appeared from nowhere")
	}
	r.npm.put(t, "claude-code-darwin-arm64", "9.9.9", []byte("CLAUDE 9.9.9"), false)
	if carries() {
		t.Fatal("healed again inside releaseHealEvery")
	}
	r.rs.mu.Lock()
	r.rs.healTried[shaA] = time.Now().Add(-2 * releaseHealEvery)
	r.rs.mu.Unlock()
	if !carries() {
		t.Fatal("a release lacking a fetchable pin was not healed")
	}
	if _, err := r.fetch.Fetch(context.Background(), "stable", filepath.Join(t.TempDir(), "rt"), true); err != nil {
		t.Fatalf("a machine's fetch of the healed release: %v", err)
	}
	// whole now: never looked at again
	r.rs.mu.Lock()
	r.rs.healTried[shaA] = time.Time{}
	r.rs.mu.Unlock()
	before := r.npm.hits["/@anthropic-ai%2fclaude-code-darwin-arm64/9.9.9"]
	carries()
	carries()
	if r.npm.hits["/@anthropic-ai%2fclaude-code-darwin-arm64/9.9.9"] != before {
		t.Error("a whole release was rebuilt again")
	}
}
