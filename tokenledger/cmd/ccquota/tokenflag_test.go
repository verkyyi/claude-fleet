package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Every credential flag goes through secretEnvFlag: a bare
// fs.String(…, os.Getenv("…TOKEN"), …) anywhere in ccquota is the #1508 leak
// (agent/cli holds the node's commands to the same rule).
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
