package main

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/codex"
)

func TestCodexLauncherWorkingDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("executable fixture requires /bin/sh")
	}
	for _, tc := range []struct {
		name     string
		args     []string
		child    []string
		login    bool
		relative bool
	}{
		{"browser login", []string{"login", "personal"}, []string{"login"}, true, false},
		{"device login", []string{"login", "personal", "--device-auth"}, []string{"login", "--device-auth"}, true, false},
		{"relative executable login", []string{"login", "personal", "--device-auth"}, []string{"login", "--device-auth"}, true, true},
		{"project run", []string{"run", "personal", "--", "exec", "review this change"}, []string{"exec", "review this change"}, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			userHome := filepath.Join(root, "target-user")
			project := filepath.Join(root, "caller-project")
			if err := os.MkdirAll(project, 0700); err != nil {
				t.Fatal(err)
			}
			profile, err := codex.AddProfile(userHome, "personal", filepath.Join(userHome, ".codex"))
			if err != nil {
				t.Fatal(err)
			}
			// Reproduce sudo -H: the target HOME differs from the inherited cwd.
			t.Chdir(project)
			t.Setenv("HOME", userHome)
			t.Setenv("CODEX_HOME", "")
			t.Setenv("CCQUOTA_CODEX_HOMES", "")
			output := filepath.Join(root, "child-context")
			t.Setenv("CCQUOTA_TEST_CODEX_OUTPUT", output)
			binary := filepath.Join(root, "codex")
			if err := os.WriteFile(binary, []byte(`#!/bin/sh
{
  pwd -P
  printf '%s\n' "$HOME" "$CODEX_HOME" "$PWD" "$@"
} > "$CCQUOTA_TEST_CODEX_OUTPUT"
`), 0700); err != nil {
				t.Fatal(err)
			}
			if tc.relative {
				binary = filepath.Join("..", "codex")
			}
			args := append([]string{"--codex-bin", binary}, tc.args...)
			if err := runCodex(args); err != nil {
				t.Fatal(err)
			}
			b, err := os.ReadFile(output)
			if err != nil {
				t.Fatal(err)
			}
			wantDir := project
			if tc.login {
				wantDir = profile.Home
			}
			want := append([]string{wantDir, userHome, profile.Home, wantDir, "-c", `cli_auth_credentials_store="file"`}, tc.child...)
			if got := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n"); !reflect.DeepEqual(got, want) {
				t.Fatalf("child context = %q; want %q", got, want)
			}
		})
	}
}
