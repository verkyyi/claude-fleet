package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

const shaC = "cccccccccccccccccccccccccccccccccccccccc"

// claude-fleet#2771: a commit carrying conf/release-tree.list is released as
// the whole install it names — .claude-plugin/ and extras/ too — and what a
// machine unpacks is the commit's tree file for file, but for what the list
// leaves out.
func TestReleaseTreeIsTheWholeInstall(t *testing.T) {
	r := newReleaseRig(t)
	list, err := os.ReadFile(filepath.Join("..", "..", "..", release.TreeListPath))
	if err != nil {
		t.Skip("not in the claude-fleet checkout:", err)
	}
	tree := map[string]string{
		StableManifestPath:                     "bin/fleet\n",
		release.TreeListPath:                   string(list),
		"bin/fleet":                            "#!/bin/sh\necho C\n",
		"conf/tmux-shell.conf":                 "set -g mouse on\n",
		".claude-plugin/plugin.json":           `{"name":"fleet"}`,
		".claude-plugin/marketplace.json":      `{}`,
		"extras/iterm2/install.sh":             "#!/bin/sh\n",
		"extras/laptop-url-opener.sh":          "#!/bin/sh\n",
		"mod/fleet/.claude-plugin/plugin.json": `{}`,
		"release.json":                         `{"schema":1}`,
		"README.md":                            "# r\n",
		"tokenledger/go.mod":                   "module x\n",
		"deploy/k8s/x.yaml":                    "x: 1\n",
		".github/workflows/ci.yml":             "on: push\n",
		".gitignore":                           "*.o\n",
	}
	for p, b := range tree {
		r.g.files[shaC+"/"+p] = b
	}
	r.g.stable = shaC
	must(t, os.WriteFile(filepath.Join(r.inst, "claude-code-2.1.0-darwin-arm64"), []byte("CLAUDE"), 0o644))
	built := make(chan struct{}, 1)
	r.rs.Source.OnStable = func(sha string) { r.rs.OnStable(sha); built <- struct{}{} }
	must(t, r.rs.Source.Refresh(context.Background()))
	select {
	case <-built:
	case <-time.After(10 * time.Second):
		t.Fatal("no release built")
	}
	dest := filepath.Join(t.TempDir(), "rt")
	m, err := r.fetch.Fetch(context.Background(), "stable", dest, true)
	if err != nil {
		t.Fatal(err)
	}
	if m.SHA != shaC || m.Seq != 1 || m.Prev != "" {
		t.Fatalf("stable = %s seq %d prev %q", m.SHA, m.Seq, m.Prev)
	}
	got := map[string]string{}
	must(t, filepath.WalkDir(dest, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(dest, p)
		if !strings.HasPrefix(rel, ".release/") {
			b, _ := os.ReadFile(p)
			got[filepath.ToSlash(rel)] = string(b)
		}
		return nil
	}))
	for p, b := range tree {
		out := strings.HasPrefix(p, "tokenledger/") && p != StableManifestPath ||
			strings.HasPrefix(p, "deploy/") || strings.HasPrefix(p, ".github/") || p == ".gitignore"
		if g, ok := got[p]; out && ok {
			t.Errorf("%s is excluded by the list, but was shipped", p)
		} else if !out && g != b {
			t.Errorf("%s = %q, want %q", p, g, b)
		}
		delete(got, p)
	}
	for p := range got {
		t.Errorf("%s shipped, but is not in the commit", p)
	}
}

// promote seals every stable move: prev = the stable it replaced, seq + 1,
// under the signature — one changed byte and the manifest no longer verifies.
func TestReleaseSealSigned(t *testing.T) {
	r := newReleaseRig(t)
	r.rs.Source = nil // promote from what is on disk; no background lookups
	ctx := context.Background()
	files := map[string][]byte{"bin/x": []byte("x")}
	for _, sha := range []string{shaA, shaB} {
		must(t, r.rs.publish(sha, files, nil, time.Now(), release.Seal{}))
	}
	must(t, r.rs.promote(ctx, shaA))
	must(t, r.rs.promote(ctx, shaB))
	must(t, r.rs.promote(ctx, shaB)) // again: a no-op, never seq 3
	resp, body := getBody(t, r.hub.URL+release.Path+"stable")
	if resp.StatusCode != 200 {
		t.Fatalf("GET stable: %d", resp.StatusCode)
	}
	sig := resp.Header.Get("X-Ccquota-Release-Signature")
	m, err := release.Verify(r.pub, []byte(body), sig)
	if err != nil {
		t.Fatal(err)
	}
	if m.SHA != shaB || m.Prev != shaA || m.Seq != 2 {
		t.Fatalf("stable %s prev %s seq %d, want %s prev %s seq 2", m.SHA[:7], m.Prev, m.Seq, shaB[:7], shaA)
	}
	if p := r.rs.stable(); p.SHA != shaB || p.Seq != 2 {
		t.Fatalf("pointer = %+v", p)
	}
	for _, edit := range [][2]string{{`"seq": 2`, `"seq": 3`}, {shaA, shaC}} {
		bad := strings.Replace(body, edit[0], edit[1], 1)
		if bad == body {
			t.Fatalf("no %q in the manifest", edit[0])
		}
		if _, err := release.Verify(r.pub, []byte(bad), sig); err == nil {
			t.Errorf("%s → %s still verifies", edit[0], edit[1])
		}
	}
	// a rollback is a new move, never a step back: A again is seq 3, prev B
	must(t, r.rs.promote(ctx, shaA))
	if m := r.rs.manifest(shaA); m.Seq != 3 || m.Prev != shaB {
		t.Fatalf("rollback: seq %d prev %s", m.Seq, m.Prev)
	}
	if c := r.rs.chain(shaA); len(c) != 2 || c[0] != shaA || c[1] != shaB {
		t.Fatalf("chain after rollback = %v", c)
	}
}

// Prune keeps the newest Keep links of the stable chain as one run: every kept
// link's prev is still there but the oldest's, however many newer non-stable
// builds come after them.
func TestReleasePrunePrevChainUnbroken(t *testing.T) {
	r := newReleaseRig(t)
	r.rs.Source = nil
	r.rs.Keep = 100
	ctx := context.Background()
	files := map[string][]byte{"bin/x": []byte("x")}
	var chain []string
	for i := 0; i < 6; i++ {
		sha := fmt.Sprintf("%040x", 0xc0+i)
		chain = append(chain, sha)
		must(t, r.rs.publish(sha, files, nil, time.Now().Add(-time.Duration(20-i)*time.Hour), release.Seal{}))
		must(t, r.rs.promote(ctx, sha))
	}
	for i := 0; i < 4; i++ { // newer builds stable never named
		must(t, r.rs.publish(fmt.Sprintf("%040x", 0xe0+i), files, nil, time.Now(), release.Seal{}))
	}
	// built, then made stable once the store is full: the build promote
	// waits on is never pruned before the pointer reaches it
	next := fmt.Sprintf("%040x", 0xd0)
	must(t, r.rs.publish(next, files, nil, time.Now().Add(-30*time.Hour), release.Seal{}))
	r.rs.Keep = 3
	must(t, r.rs.promote(ctx, next))
	chain = append(chain, next)
	r.rs.prune()
	got := r.rs.chain(r.rs.StableSHA())
	if len(got) != 3 || got[0] != chain[6] || got[2] != chain[4] {
		t.Fatalf("chain = %v", got)
	}
	for _, sha := range got[:len(got)-1] {
		if p := r.rs.manifest(sha).Prev; !r.rs.Has(p) {
			t.Errorf("%s's prev %s was pruned", sha[:7], p[:7])
		}
	}
	ents, _ := os.ReadDir(r.rs.Dir)
	n := 0
	for _, e := range ents {
		if e.IsDir() && release.ValidSHA(e.Name()) {
			n++
		}
	}
	if n != 3 {
		t.Errorf("%d releases kept, want 3", n)
	}
}

// No signing key ⇒ no store ⇒ every release route 404s, stable included: the
// hub exactly as before (claude-fleet#2771).
func TestReleaseTreeOffAddsNothing(t *testing.T) {
	s := &Server{}
	for _, p := range []string{"key", "artifacts", "stable", shaA, shaA + "/" + release.TreeName, shaA + "/" + release.SigName} {
		rec := httptest.NewRecorder()
		s.handleRelease(rec, httptest.NewRequest(http.MethodGet, release.Path+p, nil))
		if rec.Code != http.StatusNotFound || !bytes.Contains(rec.Body.Bytes(), []byte("404")) {
			t.Errorf("no store: GET %s = %d", p, rec.Code)
		}
	}
	var none stablePointer
	if b, _ := json.Marshal(none); string(b) != `{"sha":"","seq":0}` {
		t.Errorf("pointer zero = %s", b)
	}
}
