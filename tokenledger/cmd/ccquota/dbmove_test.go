package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ccquota db (claude-fleet#2122): the argument handling. The move itself is
// tested on the Postgres leg in internal/store (dbmove_test.go).
func TestDBCommandRefusesBeforeTouchingAnything(t *testing.T) {
	t.Setenv("CCQUOTA_DB_URL", "")
	dir := t.TempDir()
	missing := filepath.Join(dir, "nope.db")
	var out bytes.Buffer
	for _, c := range []struct {
		args []string
		want string
	}{
		{nil, "migrate | verify"},
		{[]string{"copy"}, "unknown command"},
		{[]string{"migrate", "--from", missing}, "no target"},
		{[]string{"migrate", "--from", "sqlite://" + missing, "--to", "postgres://u:secret@127.0.0.1:1/x"}, "no such file"},
		{[]string{"verify", "--from", missing, "--to", "mysql://x"}, "postgres://"},
	} {
		err := runDBTo(c.args, &out)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("ccquota db %v = %v, want %q", c.args, err, c.want)
		}
		if err != nil && strings.Contains(err.Error(), "secret") {
			t.Errorf("ccquota db %v printed the password: %v", c.args, err)
		}
	}
	if _, err := os.Stat(missing); err == nil {
		t.Error("a refused move created the source file")
	}
}
