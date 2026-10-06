package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// fakeGitHub answers /repos/<repo>/commits/stable (the sha) and
// /<repo>/<sha>/<path> (raw files) from a map; counts every raw fetch.
type fakeGitHub struct {
	mu     sync.Mutex
	stable string
	files  map[string]string // "<sha>/<path>" → body
	raw    int
	down   bool
	// codeload (claude-fleet#1901): "<sha>" → a tar.gz of files[<sha>/…];
	// served only when tarball is on. rawDown resets the raw host, as the
	// hub's cluster in China sees raw.githubusercontent.com.
	tarball bool
	tars    int
	rawDown bool
}

func (g *fakeGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.down {
		http.Error(w, "down", http.StatusBadGateway)
		return
	}
	if r.URL.Path == "/repos/o/r/commits/stable" {
		if r.Header.Get("Accept") != "application/vnd.github.sha" {
			http.Error(w, "want the sha media type", http.StatusBadRequest)
			return
		}
		_, _ = io.WriteString(w, g.stable)
		return
	}
	key := strings.TrimPrefix(r.URL.Path, "/o/r/")
	if sha, ok := strings.CutPrefix(key, "tar.gz/"); ok {
		if !g.tarball {
			http.NotFound(w, r)
			return
		}
		g.tars++
		_, _ = w.Write(g.tarOf(sha))
		return
	}
	if g.rawDown {
		http.Error(w, "reset", http.StatusBadGateway)
		return
	}
	if b, ok := g.files[key]; ok {
		g.raw++
		_, _ = io.WriteString(w, b)
		return
	}
	http.NotFound(w, r)
}

// tarOf is codeload's tar.gz of sha: every file under <repo>-<sha>/, plus a
// directory entry and a non-client file, as the real one has.
func (g *fakeGitHub) tarOf(sha string) []byte {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	top := "r-" + sha + "/"
	_ = tw.WriteHeader(&tar.Header{Name: top, Typeflag: tar.TypeDir, Mode: 0o755})
	add := func(p, body string) {
		_ = tw.WriteHeader(&tar.Header{Name: top + p, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(body))})
		_, _ = tw.Write([]byte(body))
	}
	add("README.md", "not a client file\n")
	for k, v := range g.files {
		if p, ok := strings.CutPrefix(k, sha+"/"); ok {
			add(p, v)
		}
	}
	_ = tw.Close()
	_ = zw.Close()
	return buf.Bytes()
}

const (
	shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

func stableRig(t *testing.T) (*harness, *fakeGitHub) {
	t.Helper()
	h, _ := certHarness(t)
	g := &fakeGitHub{stable: shaA, files: map[string]string{
		shaA + "/" + StableManifestPath: "bin/fleet-install.sh installer\nbin/fleet\n",
		shaA + "/bin/fleet-install.sh":  "#!/bin/sh\n# " + stableAwareMark + "\nPRE_HUB=\"${FLEET_HUB_URL:-" + fleetclient.HubPlaceholder + "}\"\n",
		shaA + "/bin/fleet":             "#!/bin/sh\necho A\n",
		shaB + "/" + StableManifestPath: "bin/fleet-install.sh installer\nbin/fleet\n",
		shaB + "/bin/fleet-install.sh":  "#!/bin/sh\n# an installer from before #1805\n",
		shaB + "/bin/fleet":             "#!/bin/sh\necho B\n",
	}}
	gh := httptest.NewServer(g)
	t.Cleanup(gh.Close)
	h.srv.Stable = &StableSource{Repo: "o/r", APIBase: gh.URL, RawBase: gh.URL}
	if err := h.srv.Stable.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	return h, g
}

func getBody(t *testing.T, url string) (*http.Response, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

// claude-fleet#1805: /version hands out stable, not the image — moving
// stable moves client_version with no redeploy.
func TestVersionFollowsStable(t *testing.T) {
	h, g := stableRig(t)
	var v map[string]any
	_, body := getBody(t, h.http.URL+"/version")
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		t.Fatal(err)
	}
	if v["client_version"] != shaA || v["stable"] != shaA || v["client_url"] != h.http.URL+"/install/stable/"+shaA {
		t.Fatalf("/version = %v, want stable %s and its url", v, shaA)
	}
	if v["client_compat"] != float64(fleetclient.Compat) {
		t.Errorf("compat is the hub's own, got %v", v["client_compat"])
	}
	g.mu.Lock()
	g.stable = shaB
	g.mu.Unlock()
	if err := h.srv.Stable.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	_, body = getBody(t, h.http.URL+"/version")
	_ = json.Unmarshal([]byte(body), &v)
	if v["client_version"] != shaB {
		t.Fatalf("stable moved, /version still %v", v["client_version"])
	}
	// GitHub gone: the last stable is kept, never the image's digest
	g.mu.Lock()
	g.down = true
	g.mu.Unlock()
	if err := h.srv.Stable.Refresh(context.Background()); err == nil {
		t.Fatal("a failed lookup must say so")
	}
	_, body = getBody(t, h.http.URL+"/version")
	_ = json.Unmarshal([]byte(body), &v)
	if v["client_version"] != shaB {
		t.Fatalf("GitHub down: /version %v, want the last known %s", v["client_version"], shaB)
	}
}

// No StableSource, or one that never answered: /version is the image's, as
// before (degenerate).
func TestVersionWithoutStableIsTheImages(t *testing.T) {
	h, _ := certHarness(t)
	for _, src := range []*StableSource{nil, {Repo: "o/r", APIBase: "http://127.0.0.1:1", RawBase: "http://127.0.0.1:1"}} {
		h.srv.Stable = src
		var v map[string]any
		_, body := getBody(t, h.http.URL+"/version")
		if err := json.Unmarshal([]byte(body), &v); err != nil {
			t.Fatal(err)
		}
		if v["client_version"] != fleetclient.Version {
			t.Errorf("client_version = %v, want the image's %q", v["client_version"], fleetclient.Version)
		}
		if _, ok := v["stable"]; ok {
			t.Errorf("stable reported with no stable known: %v", v)
		}
		if _, ok := v["client_url"]; ok {
			t.Errorf("client_url reported with no stable known: %v", v)
		}
	}
}

// /install/stable/<sha>/<path>: a seen sha, a client path, its SHA-256 —
// fetched once; anything else is a 404, never an open proxy.
func TestStableFilesProxied(t *testing.T) {
	h, g := stableRig(t)
	for i := 0; i < 2; i++ {
		resp, body := getBody(t, h.http.URL+"/install/stable/"+shaA+"/bin/fleet")
		sum := sha256.Sum256([]byte(body))
		if resp.StatusCode != 200 || body != "#!/bin/sh\necho A\n" || resp.Header.Get("X-Ccquota-Sha256") != hex.EncodeToString(sum[:]) {
			t.Fatalf("stable file: %d %q sha %q", resp.StatusCode, body, resp.Header.Get("X-Ccquota-Sha256"))
		}
	}
	if g.raw != 1 {
		t.Errorf("raw fetches = %d, want 1 (a commit's bytes are kept)", g.raw)
	}
	resp, _ := getBody(t, h.http.URL+"/install/stable/"+shaA+"/"+StableManifestPath)
	if resp.StatusCode != 200 {
		t.Errorf("the manifest: %d", resp.StatusCode)
	}
	for _, p := range []string{
		"/install/stable/" + shaB + "/bin/fleet",      // never seen as stable
		"/install/stable/" + shaA + "/README.md",      // not a client path
		"/install/stable/" + shaA + "/bin/../go.mod",  // climbs
		"/install/stable/" + shaA[:7] + "/bin/fleet",  // not a full sha
		"/install/stable/" + shaA + "/bin/nothing.sh", // not in the commit
	} {
		if resp, _ := getBody(t, h.http.URL+p); resp.StatusCode != 404 {
			t.Errorf("%s: %d, want 404", p, resp.StatusCode)
		}
	}
	h.srv.Stable = nil
	if resp, _ := getBody(t, h.http.URL+"/install/stable/"+shaA+"/bin/fleet"); resp.StatusCode != 404 {
		t.Errorf("no stable source: %d, want 404", resp.StatusCode)
	}
}

// /install: stable's installer when it carries the mark (with this hub's
// address), the image's when stable's predates #1805.
func TestInstallServesStablesInstaller(t *testing.T) {
	h, g := stableRig(t)
	resp, body := getBody(t, h.http.URL+"/install")
	if resp.StatusCode != 200 || !strings.Contains(body, stableAwareMark) || !strings.Contains(body, h.http.URL) ||
		strings.Contains(body, fleetclient.HubPlaceholder) {
		t.Fatalf("/install with an aware stable: %d %q", resp.StatusCode, body)
	}
	g.mu.Lock()
	g.stable = shaB
	g.mu.Unlock()
	if err := h.srv.Stable.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	needPacked(t)
	resp, body = getBody(t, h.http.URL+"/install")
	img, _ := fleetclient.Files.ReadFile(fleetclient.Installer)
	if resp.StatusCode != 200 || body != strings.ReplaceAll(string(img), fleetclient.HubPlaceholder, h.http.URL) {
		t.Fatalf("/install with an older stable must be the image's installer: %d %.80q", resp.StatusCode, body)
	}
}

func TestStablePathOK(t *testing.T) {
	for p, want := range map[string]bool{
		"bin/fleet": true, "conf/tmux-shell.conf": true, "mod/fleet/.claude-plugin/plugin.json": true,
		StableManifestPath: true, "": false, "bin/": false, "../x": false, "bin/a/../../x": false,
		"tokenledger/go.mod": false, "/bin/fleet": false, "bin//fleet": false, "bin/a%2e": false,
	} {
		if got := stablePathOK(p); got != want {
			t.Errorf("stablePathOK(%q) = %v, want %v", p, got, want)
		}
	}
}

// claude-fleet#1901: from the hub's cluster the raw host is reset while
// codeload answers — the commit comes in ONE tarball and every file is served
// from it; a path the commit lacks is a 404, with no raw request at all.
func TestStableFilesFromTarball(t *testing.T) {
	h, g := stableRig(t)
	g.mu.Lock()
	g.tarball, g.rawDown = true, true
	g.mu.Unlock()
	for _, p := range []string{"bin/fleet", "bin/fleet-install.sh", StableManifestPath, "bin/fleet"} {
		resp, body := getBody(t, h.http.URL+"/install/stable/"+shaA+"/"+p)
		want := g.files[shaA+"/"+p]
		sum := sha256.Sum256([]byte(body))
		if resp.StatusCode != 200 || body != want || resp.Header.Get("X-Ccquota-Sha256") != hex.EncodeToString(sum[:]) {
			t.Fatalf("%s: %d %q", p, resp.StatusCode, body)
		}
	}
	for _, p := range []string{"bin/nothing.sh", "README.md"} {
		if resp, _ := getBody(t, h.http.URL+"/install/stable/"+shaA+"/"+p); resp.StatusCode != 404 {
			t.Errorf("%s: %d, want 404", p, resp.StatusCode)
		}
	}
	if g.tars != 1 || g.raw != 0 {
		t.Errorf("tarballs = %d raw = %d, want 1 and 0 (one download serves the commit)", g.tars, g.raw)
	}
	// stable's installer comes out of the same tarball
	resp, body := getBody(t, h.http.URL+"/install")
	if resp.StatusCode != 200 || !strings.Contains(body, stableAwareMark) {
		t.Errorf("/install with the raw host down: %d %q", resp.StatusCode, firstLine(body))
	}
}

// No tarball (codeload down): file by file from the raw host, as before, and
// the failed tarball is not asked again within the TTL.
func TestStableTarballDownFallsBackToRaw(t *testing.T) {
	h, g := stableRig(t)
	for _, p := range []string{"bin/fleet", "bin/fleet-install.sh"} {
		if resp, _ := getBody(t, h.http.URL+"/install/stable/"+shaA+"/"+p); resp.StatusCode != 200 {
			t.Fatalf("%s: %d", p, resp.StatusCode)
		}
	}
	if g.raw != 2 || g.tars != 0 {
		t.Errorf("raw = %d tarballs = %d, want 2 and 0", g.raw, g.tars)
	}
	h.srv.Stable.mu.Lock()
	n := len(h.srv.Stable.tarFail)
	h.srv.Stable.mu.Unlock()
	if n != 1 {
		t.Errorf("tarball failures remembered = %d, want 1 (asked once per TTL)", n)
	}
}
