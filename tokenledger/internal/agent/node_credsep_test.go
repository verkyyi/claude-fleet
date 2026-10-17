package agent

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// fakeCredsep writes a fleet-credsep.sh under home that exits status / check
// with the given codes and has no judge verb — a script older than #4622.
func fakeCredsep(t *testing.T, home string, status, check int) {
	t.Helper()
	writeCredsep(t, home, "case \"$1\" in status) exit "+strconv.Itoa(status)+" ;; check) exit "+strconv.Itoa(check)+" ;; esac\nexit 2\n")
}

func writeCredsep(t *testing.T, home, body string) {
	t.Helper()
	p := filepath.Join(home, credsepScript)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("#!/bin/bash\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// A script older than judge is asked the old way: status + check.
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
			if got, why := credsepJudge(ctx, home); got != tc.want || why != "" {
				t.Fatalf("credsepJudge = %q, %q; want %q and no why", got, why, tc.want)
			}
		})
	}
}

// claude-fleet#4622: judge is the word. A tenant whose check WARNs on a key
// the shared proxy ignored (exit 1) but whose judge says separated is
// separated — the old way read it as not and the hub refused every lease.
func TestCredsepJudgeVerb(t *testing.T) {
	ctx := context.Background()
	for _, tc := range []struct {
		name, body, want, why string
	}{
		{"tenant with a check WARN", "case \"$1\" in judge) echo 'separated — /var/db/fleet-cred/u unreadable here'; exit 0 ;; status) exit 0 ;; check) exit 1 ;; esac\nexit 2\n",
			control.CredsepSeparated, "separated — /var/db/fleet-cred/u unreadable here"},
		{"a leak", "case \"$1\" in judge) echo 'not — credentials readable at login paths: x'; echo more; exit 3 ;; esac\nexit 0\n",
			control.CredsepNot, "not — credentials readable at login paths: x"},
		{"judge broke", "case \"$1\" in judge) exit 1 ;; esac\nexit 0\n", control.CredsepUnknown, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			writeCredsep(t, home, tc.body)
			if got, why := credsepJudge(ctx, home); got != tc.want || why != tc.why {
				t.Fatalf("credsepJudge = %q, %q; want %q, %q", got, why, tc.want, tc.why)
			}
		})
	}
	if got := credsepLine(strings.Repeat("é", 300)); len([]rune(got)) != credsepWhyMax {
		t.Fatalf("why not bounded: %d runes", len([]rune(got)))
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

// cred_served (claude-fleet#4247) is `fleet-credsep.sh served`: 0 yes, 3 no,
// anything else — cannot tell, or a script older than the verb (exit 2) —
// unsaid, so the hub holds nothing on it.
func TestCredsepServed(t *testing.T) {
	ctx := context.Background()
	if got := credsepServed(ctx, t.TempDir()); got != nil {
		t.Fatalf("no claude-fleet: served = %v; want unsaid", *got)
	}
	home := t.TempDir()
	fakeCredsep(t, home, 0, 0) // no served verb: exits 2
	if got := credsepServed(ctx, home); got != nil {
		t.Fatalf("script older than the verb: served = %v; want unsaid", *got)
	}
	p := filepath.Join(home, credsepScript)
	for _, tc := range []struct {
		rc   int
		want string
	}{{0, "true"}, {3, "false"}, {2, "unsaid"}} {
		body := "#!/bin/bash\ncase \"$1\" in served) exit " + strconv.Itoa(tc.rc) + " ;; esac\nexit 0\n"
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
		got := "unsaid"
		if v := credsepServed(ctx, home); v != nil {
			got = strconv.FormatBool(*v)
		}
		if got != tc.want {
			t.Fatalf("served exit %d = %s; want %s", tc.rc, got, tc.want)
		}
	}
	// The probe carries it beside the word.
	var pr credsepProbe
	pr.reading(ctx, home, time.Now())
	if pr.served != nil {
		t.Fatalf("probe served = %v after exit 2; want unsaid", *pr.served)
	}
}
