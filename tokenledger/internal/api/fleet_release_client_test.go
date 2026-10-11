package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// claude-fleet#3162: a client takes a release with no ccquota — the repo's
// bin/fleet-release-fetch.py (python3's standard library + the system's
// ssh-keygen) against this hub's real handler. Skipped without either tool.
func clientFetch(t *testing.T, hub, pubFile, sha, dest string) (string, error) {
	t.Helper()
	for _, c := range []string{"python3", "ssh-keygen"} {
		if _, err := exec.LookPath(c); err != nil {
			t.Skip("no " + c)
		}
	}
	script, _ := filepath.Abs("../../../bin/fleet-release-fetch.py")
	if _, err := os.Stat(script); err != nil {
		t.Skip("no bin/fleet-release-fetch.py beside tokenledger/")
	}
	out, err := exec.Command("python3", script, "--hub", hub, "--pubkey", pubFile, "--timeout", "20", sha, dest).CombinedOutput()
	return string(out), err
}

func pinKey(t *testing.T, pub ed25519.PublicKey) string {
	t.Helper()
	f := filepath.Join(t.TempDir(), "release.pub")
	must(t, os.WriteFile(f, []byte(release.FormatPublicKey(pub)+"\n"), 0o644))
	return f
}

func builtRig(t *testing.T) *releaseRig {
	t.Helper()
	r := newReleaseRig(t)
	must(t, r.rs.Source.Refresh(context.Background()))
	must(t, r.rs.Ensure(context.Background(), shaA))
	return r
}

func TestClientFetchesWithoutCCQuota(t *testing.T) {
	r := builtRig(t)
	pub := pinKey(t, r.pub)
	dest := filepath.Join(t.TempDir(), "rt")
	out, err := clientFetch(t, r.hub.URL, pub, shaA, dest)
	if err != nil {
		t.Fatalf("fetch: %v\n%s", err, out)
	}
	if !strings.Contains(out, "verified (sshsig)") || !strings.Contains(out, shaA) {
		t.Fatalf("not checked with ssh-keygen: %s", out)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "bin/fleet")); string(b) != "#!/bin/sh\necho A\n" {
		t.Fatalf("bin/fleet = %q", b)
	}
	// what ccquota release fetch leaves, so the same import reads it
	if _, err := release.VerifyDir(r.pub, dest); err != nil {
		t.Fatalf("the client's tree does not verify as a release dir: %v", err)
	}
	// the served SSHSIG endpoint verifies too
	if resp, body := getBody(t, r.hub.URL+release.Path+shaA+"/"+release.SSHSigName); resp.StatusCode != 200 ||
		!strings.HasPrefix(body, "-----BEGIN SSH SIGNATURE-----") {
		t.Fatalf("manifest.sshsig: %d %q", resp.StatusCode, body)
	}

	// another key pinned: refused, nothing left
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	dest2 := filepath.Join(t.TempDir(), "rt")
	if out, err := clientFetch(t, r.hub.URL, pinKey(t, other), shaA, dest2); err == nil ||
		!strings.Contains(out, "does not match the pinned key") {
		t.Fatalf("a release signed by another key was taken: %v %s", err, out)
	}
	if _, err := os.Stat(dest2); err == nil {
		t.Fatal("a refused release left a tree")
	}
}

// A hub from before SSHSIG: the client checks the base64 ed25519 signature
// itself — still no ccquota.
func TestClientFetchesFromAnOldHub(t *testing.T) {
	r := builtRig(t)
	old := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		if strings.HasSuffix(q.URL.Path, "/"+release.SSHSigName) {
			http.NotFound(w, q)
			return
		}
		rec := httptest.NewRecorder()
		(&Server{Releases: r.rs}).handleRelease(rec, q)
		for k, v := range rec.Header() {
			if k != release.SSHSigHeader {
				w.Header()[k] = v
			}
		}
		w.WriteHeader(rec.Code)
		_, _ = w.Write(rec.Body.Bytes())
	}))
	defer old.Close()
	dest := filepath.Join(t.TempDir(), "rt")
	out, err := clientFetch(t, old.URL, pinKey(t, r.pub), shaA, dest)
	if err != nil || !strings.Contains(out, "verified (ed25519)") {
		t.Fatalf("old hub: %v\n%s", err, out)
	}
}

// A new signing key is taken only when the pinned one vouches for it.
func TestClientTakesAnEndorsedKey(t *testing.T) {
	r := builtRig(t)
	oldPub, oldKey := r.pub, r.key
	pub := pinKey(t, oldPub)
	newPub, newKey, _ := ed25519.GenerateKey(rand.Reader)

	// the hub re-signs with the new key; no endorsement yet → refused, pin kept
	fresh := &ReleaseStore{Dir: t.TempDir(), Key: newKey, Repo: "o/r", Source: r.rs.Source,
		DistDir: r.dist, DistSrc: rigSrc, ArtifactsDir: r.inst, NPMRegistries: r.rs.NPMRegistries}
	must(t, fresh.Ensure(context.Background(), shaA))
	hub := releaseHub(t, fresh)
	if resp, _ := getBody(t, hub.URL+release.Path+release.EndorsementRel); resp.StatusCode != 404 {
		t.Fatalf("key-endorsement with no previous key: %d, want 404", resp.StatusCode)
	}
	if out, err := clientFetch(t, hub.URL, pub, shaA, filepath.Join(t.TempDir(), "rt")); err == nil {
		t.Fatalf("an unvouched new key was taken: %s", out)
	}
	if b, _ := os.ReadFile(pub); strings.TrimSpace(string(b)) != release.FormatPublicKey(oldPub) {
		t.Fatalf("the pin moved without an endorsement: %q", b)
	}

	// a stranger's endorsement: refused
	_, stranger, _ := ed25519.GenerateKey(rand.Reader)
	fresh.PrevKey = stranger
	if out, err := clientFetch(t, hub.URL, pub, shaA, filepath.Join(t.TempDir(), "rt")); err == nil {
		t.Fatalf("a key vouched for by a stranger was taken: %s", out)
	}

	// the old key vouches → taken, re-pinned, the old kept
	fresh.PrevKey = oldKey
	dest := filepath.Join(t.TempDir(), "rt")
	out, err := clientFetch(t, hub.URL, pub, shaA, dest)
	if err != nil || !strings.Contains(out, "re-pinned") {
		t.Fatalf("an endorsed key: %v\n%s", err, out)
	}
	if b, _ := os.ReadFile(pub); strings.TrimSpace(string(b)) != release.FormatPublicKey(newPub) {
		t.Fatalf("not re-pinned: %q", b)
	}
	if b, _ := os.ReadFile(pub + ".prev"); strings.TrimSpace(string(b)) != release.FormatPublicKey(oldPub) {
		t.Fatalf("the old key not kept: %q", b)
	}
}
