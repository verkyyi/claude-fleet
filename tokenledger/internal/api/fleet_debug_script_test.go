package api

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// repoRead reads a file from the repo this package sits in (../../../).
func repoRead(p string) ([]byte, error) {
	return os.ReadFile(filepath.Join("..", "..", "..", filepath.FromSlash(p)))
}

// The repo's own bin/fleet-debug splices into a script sh can parse, with the
// hub, the version and every kit file in it and no marker left
// (claude-fleet#2892).
func TestDebugScriptSplicesTheKit(t *testing.T) {
	body, err := buildDebugScript(repoRead, "https://hub.example", "abc123")
	if err != nil {
		t.Fatal(err)
	}
	s := string(body)
	// a marker LINE left is a file not spliced (the script's own check for
	// one, mid-line, stays)
	if strings.Contains(s, "\n"+debugEmbMarker) || strings.Contains(s, debugVersionPlaceholder) {
		t.Fatal("a placeholder survived the splice")
	}
	if !strings.Contains(s, "HUB_BAKED='https://hub.example'") || !strings.Contains(s, "# fleet-debug-version: abc123") {
		t.Fatal("hub or version not filled")
	}
	for _, p := range debugScriptKit {
		f, _ := repoRead(p)
		if !strings.Contains(s, string(f)) {
			t.Fatalf("%s is not in the served script whole", p)
		}
	}
	tmp := filepath.Join(t.TempDir(), "fleet-debug")
	if err := os.WriteFile(tmp, body, 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("sh", "-n", tmp).CombinedOutput(); err != nil {
		t.Fatalf("sh -n: %v %s", err, out)
	}
	if out, err := exec.Command("sh", tmp, "version").CombinedOutput(); err != nil || strings.TrimSpace(string(out)) != "fleet-debug abc123" {
		t.Fatalf("version = %q %v", out, err)
	}
}

// A kit file that is missing, or one that would end its heredoc early, is an
// error — never a half-spliced script.
func TestDebugScriptRefusesAHalfSplice(t *testing.T) {
	missing := func(p string) ([]byte, error) {
		if p == "conf/secret-shapes.list" {
			return nil, errors.New("not there")
		}
		return repoRead(p)
	}
	if _, err := buildDebugScript(missing, "h", "v"); err == nil {
		t.Fatal("a missing shape table spliced anyway")
	}
	early := func(p string) ([]byte, error) {
		if p == "conf/debug-collect.list" {
			return []byte("a\n" + debugEmbDelim + "_4\nrm -rf ~\n"), nil
		}
		return repoRead(p)
	}
	if _, err := buildDebugScript(early, "h", "v"); err == nil {
		t.Fatal("a file that ends its heredoc spliced anyway")
	}
}

// GET /debug serves the image's client copy, /debug.sha256 its checksum.
func TestDebugScriptServed(t *testing.T) {
	needPacked(t)
	h, _, _ := debugHarness(t)
	resp, err := http.Get(h.http.URL + DebugScriptPath)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(string(body), "#!") || strings.Contains(string(body), "\n"+debugEmbMarker) {
		t.Fatalf("/debug = %d %.80q", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "HUB_BAKED='"+h.http.URL+"'") {
		t.Fatal("/debug does not name this hub")
	}
	sum := sha256.Sum256(body)
	resp, err = http.Get(h.http.URL + DebugScriptSumPath)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(b) != hex.EncodeToString(sum[:])+"  fleet-debug\n" {
		t.Fatalf("/debug.sha256 = %q", b)
	}
}
