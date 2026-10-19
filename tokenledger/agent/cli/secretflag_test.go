package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
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
