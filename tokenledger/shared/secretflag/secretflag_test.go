package secretflag

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

const leakyToken = "ccq_SECRET_must_not_print_0123456789"

// The redaction is display-only: the env value is still the default, and an
// explicit flag (even an empty one) still wins over it.
func TestSecretEnvFlagKeepsSemantics(t *testing.T) {
	t.Setenv("CCQUOTA_VIEWER_TOKEN", leakyToken)
	for _, tc := range []struct {
		args []string
		want string
	}{
		{nil, leakyToken},
		{[]string{"-token", "other"}, "other"},
		{[]string{"-token="}, ""},
	} {
		fs := flag.NewFlagSet("t", flag.ContinueOnError)
		var help bytes.Buffer
		fs.SetOutput(&help)
		tok := EnvFlag(fs, "token", "CCQUOTA_VIEWER_TOKEN", "viewer `token`")
		if err := fs.Parse(tc.args); err != nil {
			t.Fatal(err)
		}
		if *tok != tc.want {
			t.Errorf("args %q: token = %q, want %q", tc.args, *tok, tc.want)
		}
		fs.PrintDefaults()
		if got := help.String(); strings.Contains(got, leakyToken) || !strings.Contains(got, "-token token") {
			t.Errorf("PrintDefaults = %q", got)
		}
	}
}

// claude-fleet#1971: the separated launcher passes the node token down a pipe.
func TestTokenFromFD(t *testing.T) {
	if tok, err := FromFD(""); tok != "" || err != nil {
		t.Fatalf("empty fd = %q, %v", tok, err)
	}
	if _, err := FromFD("1"); err == nil {
		t.Fatal("stdout accepted as a token fd")
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	w.Write([]byte("ccq_piped\n"))
	w.Close()
	// tokenFromFD closes the fd it is given: hand it a dup, never r's own —
	// r's finalizer would close that number again, by then another test's file
	fd, err := syscall.Dup(int(r.Fd()))
	r.Close()
	if err != nil {
		t.Fatal(err)
	}
	tok, err := FromFD(strconv.Itoa(fd))
	if err != nil || tok != "ccq_piped" {
		t.Fatalf("token = %q, %v", tok, err)
	}
}

// claude-fleet#3724: the admin seat's token file — root's, its group reads it.
func TestTokenFromFile(t *testing.T) {
	if tok, err := FromFile(""); tok != "" || err != nil {
		t.Fatalf("empty path = %q, %v", tok, err)
	}
	dir := t.TempDir()
	p := filepath.Join(dir, "agent.token")
	if err := os.WriteFile(p, []byte("ccq_seat\nignored\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, 0o640); err != nil {
		t.Fatal(err)
	}
	if tok, err := FromFile(p); err != nil || tok != "ccq_seat" {
		t.Fatalf("token = %q, %v", tok, err)
	}
	for _, mode := range []os.FileMode{0o644, 0o660, 0o642} {
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}
		if _, err := FromFile(p); err == nil {
			t.Fatalf("mode %v accepted", mode)
		}
	}
	if err := os.Chmod(p, 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(p, link); err != nil {
		t.Fatal(err)
	}
	if _, err := FromFile(link); err == nil {
		t.Fatal("a link accepted")
	}
}
