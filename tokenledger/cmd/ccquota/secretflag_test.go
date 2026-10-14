package main

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

const leakyToken = "ccq_SECRET_must_not_print_0123456789"

// claude-fleet#1508: -h printed the env-supplied enrollment token as the
// -token default. With CCQUOTA_TOKEN set, no subcommand's help may carry it.
func TestTokenFlagHelpIsRedacted(t *testing.T) {
	t.Setenv("CCQUOTA_TOKEN", leakyToken)
	t.Setenv("CCQUOTA_HUB_URL", "http://127.0.0.1:1")
	cases := map[string]func(*bytes.Buffer) (int, error){
		"place": func(e *bytes.Buffer) (int, error) { return place([]string{"-h"}, &bytes.Buffer{}, e) },
		"lease": func(e *bytes.Buffer) (int, error) { return lease([]string{"acquire", "-h"}, &bytes.Buffer{}, e) },
		"move":  func(e *bytes.Buffer) (int, error) { return move([]string{"plan", "-h"}, &bytes.Buffer{}, e) },
	}
	for name, run := range cases {
		var errb bytes.Buffer
		_, _ = run(&errb)
		out := errb.String()
		if strings.Contains(out, leakyToken) || strings.Contains(out, "ccq_") {
			t.Errorf("%s -h leaked the token:\n%s", name, out)
		}
		if !strings.Contains(out, "(default: $CCQUOTA_TOKEN)") {
			t.Errorf("%s -h: want the env var named as the default, got:\n%s", name, out)
		}
		if !strings.Contains(out, "(default \"http://127.0.0.1:1\")") {
			t.Errorf("%s -h: -hub default should still print, got:\n%s", name, out)
		}
	}
}

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
		tok := secretEnvFlag(fs, "token", "CCQUOTA_VIEWER_TOKEN", "viewer `token`")
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

// Every credential flag goes through secretEnvFlag: a bare
// fs.String(…, os.Getenv("…TOKEN"), …) anywhere in ccquota is the #1508 leak.
func TestNoTokenFlagDefaultsFromEnv(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	bad := regexp.MustCompile(`fs\.String\([^)]*os\.Getenv\("[A-Z_]*(TOKEN|SECRET|KEY)"\)`)
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(src), "\n") {
			if bad.MatchString(line) {
				t.Errorf("%s:%d: credential flag default printed by -h; use secretEnvFlag: %s", f, i+1, strings.TrimSpace(line))
			}
		}
	}
}

// claude-fleet#1971: the separated launcher passes the node token down a pipe.
func TestTokenFromFD(t *testing.T) {
	if tok, err := tokenFromFD(""); tok != "" || err != nil {
		t.Fatalf("empty fd = %q, %v", tok, err)
	}
	if _, err := tokenFromFD("1"); err == nil {
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
	tok, err := tokenFromFD(strconv.Itoa(fd))
	if err != nil || tok != "ccq_piped" {
		t.Fatalf("token = %q, %v", tok, err)
	}
}

// claude-fleet#3724: the admin seat's token file — root's, its group reads it.
func TestTokenFromFile(t *testing.T) {
	if tok, err := tokenFromFile(""); tok != "" || err != nil {
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
	if tok, err := tokenFromFile(p); err != nil || tok != "ccq_seat" {
		t.Fatalf("token = %q, %v", tok, err)
	}
	for _, mode := range []os.FileMode{0o644, 0o660, 0o642} {
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}
		if _, err := tokenFromFile(p); err == nil {
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
	if _, err := tokenFromFile(link); err == nil {
		t.Fatal("a link accepted")
	}
}
