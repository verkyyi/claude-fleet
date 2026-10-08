package agent

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// fakeCredsep writes a fleet-credsep.sh under home that exits status / check
// with the given codes.
func fakeCredsep(t *testing.T, home string, status, check int) {
	t.Helper()
	p := filepath.Join(home, credsepScript)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "#!/bin/bash\ncase \"$1\" in status) exit " + strconv.Itoa(status) + " ;; check) exit " + strconv.Itoa(check) + " ;; esac\nexit 2\n"
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestCredsepJudge(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name          string
		script        bool
		status, check int
		want          string
	}{
		{"no claude-fleet", false, 0, 0, control.CredsepUnknown},
		{"separated, check passes", true, 0, 0, control.CredsepSeparated},
		{"separated, check warns", true, 0, 1, control.CredsepNot},
		{"not separated", true, 3, 0, control.CredsepNot},
		{"status broke", true, 2, 0, control.CredsepUnknown},
		{"check broke", true, 0, 2, control.CredsepUnknown},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			if tc.script {
				fakeCredsep(t, home, tc.status, tc.check)
			}
			if got := credsepJudge(ctx, home); got != tc.want {
				t.Fatalf("credsepJudge = %q; want %q", got, tc.want)
			}
		})
	}
}

// The verdict is cached: the scripts run at most once per credsepInterval.
func TestCredsepProbeCaches(t *testing.T) {
	home := t.TempDir()
	fakeCredsep(t, home, 3, 0)
	var p credsepProbe
	now := time.Now()
	if got := p.reading(context.Background(), home, now); got != control.CredsepNot {
		t.Fatalf("first = %q", got)
	}
	fakeCredsep(t, home, 0, 0)
	if got := p.reading(context.Background(), home, now.Add(time.Minute)); got != control.CredsepNot {
		t.Fatalf("within the interval = %q; want the cached not", got)
	}
	if got := p.reading(context.Background(), home, now.Add(credsepInterval+time.Second)); got != control.CredsepSeparated {
		t.Fatalf("after the interval = %q", got)
	}
}
