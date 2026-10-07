package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// untar is a bundle's files: name → (bytes, mode).
func untar(t *testing.T, b []byte) (map[string]string, map[string]int64) {
	t.Helper()
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(zr)
	files, modes := map[string]string{}, map[string]int64{}
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		c, _ := io.ReadAll(tr)
		files[hd.Name], modes[hd.Name] = string(c), hd.Mode
	}
	return files, modes
}

func checkSum(t *testing.T, what, sha string, body string) {
	t.Helper()
	sum := sha256.Sum256([]byte(body))
	if sha != hex.EncodeToString(sum[:]) {
		t.Fatalf("%s: X-Ccquota-Sha256 %q does not match the body", what, sha)
	}
}

// claude-fleet#2260: the image's whole client in one download — the manifest
// and every file it lists, byte for byte what /install/<path> serves, bin/
// executable; the static tmux only for a platform this build packed.
func TestImageBundle(t *testing.T) {
	needPacked(t)
	h, _ := certHarness(t)
	resp, body := getBody(t, h.http.URL+"/install/"+bundleName+"?os=Plan9&arch=mips")
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "application/gzip" {
		t.Fatalf("bundle: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	checkSum(t, "bundle", resp.Header.Get("X-Ccquota-Sha256"), body)
	files, modes := untar(t, []byte(body))
	m, _ := fleetclient.Files.ReadFile(fleetclient.ManifestName)
	if files[fleetclient.ManifestName] != string(m) {
		t.Fatal("the bundle's manifest is not the build's")
	}
	for _, n := range fleetclient.Names {
		want, _ := fleetclient.Files.ReadFile(n)
		if files[n] != string(want) {
			t.Fatalf("%s differs from /install/%s", n, n)
		}
	}
	if modes["bin/fleet"] != 0o755 {
		t.Errorf("bin/fleet mode %o", modes["bin/fleet"])
	}
	if _, ok := files[fleetclient.Installer]; ok {
		t.Error("the installer template is never a download")
	}
	if _, ok := files["vendor/tmux"]; ok {
		t.Error("no tmux for a platform nobody packs")
	}
	if len(files) != len(fleetclient.Names)+1 {
		t.Errorf("bundle has %d entries, want the manifest + %d files", len(files), len(fleetclient.Names))
	}
	if tm := fleetclient.VendorTmux("macos-arm64"); tm != nil {
		_, body := getBody(t, h.http.URL+"/install/"+bundleName+"?os=Darwin&arch=arm64")
		files, modes := untar(t, []byte(body))
		if files["vendor/tmux"] != string(tm) || modes["vendor/tmux"] != 0o755 {
			t.Fatal("the packed tmux did not ride along for macos-arm64")
		}
	}
}

// stable's client at a seen sha, through this hub; an unseen sha is a 404.
func TestStableBundle(t *testing.T) {
	h, _ := stableRig(t)
	resp, body := getBody(t, h.http.URL+"/install/stable/"+shaA+"/"+bundleName+"?os=linux&arch=amd64")
	if resp.StatusCode != 200 {
		t.Fatalf("stable bundle: %d %s", resp.StatusCode, body)
	}
	checkSum(t, "stable bundle", resp.Header.Get("X-Ccquota-Sha256"), body)
	files, modes := untar(t, []byte(body))
	if files["manifest"] != "bin/fleet-install.sh installer\nbin/fleet\n" || files["bin/fleet"] != "#!/bin/sh\necho A\n" || modes["bin/fleet"] != 0o755 {
		t.Fatalf("stable bundle files: %v", files)
	}
	if _, ok := files["bin/fleet-install.sh"]; ok {
		t.Error("the installer is not in the bundle")
	}
	if resp, _ := getBody(t, h.http.URL+"/install/stable/"+shaB+"/"+bundleName); resp.StatusCode != 404 {
		t.Errorf("an unseen sha's bundle: %d, want 404", resp.StatusCode)
	}
}

// a stable file out of reach: 502, so the installer falls back to file by file
func TestStableBundleUnreachable(t *testing.T) {
	h, g := stableRig(t)
	g.mu.Lock()
	delete(g.files, shaA+"/bin/fleet")
	g.mu.Unlock()
	if resp, _ := getBody(t, h.http.URL+"/install/stable/"+shaA+"/"+bundleName); resp.StatusCode != 502 {
		t.Fatalf("a bundle missing a file: %d, want 502", resp.StatusCode)
	}
}
