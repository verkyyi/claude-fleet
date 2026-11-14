package agent

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

// A capped watch set adds at most its limit, however many directories the
// login makes; an uncapped one adds them all.
func TestWatchSetCap(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 12; i++ {
		if err := os.MkdirAll(filepath.Join(root, "p"+strconv.Itoa(i), "sub"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct{ limit, want int }{{5, 5}, {0, 25}} {
		w, err := fsnotify.NewWatcher()
		if err != nil {
			t.Skip(err)
		}
		s := &watchSet{w: w, limit: tc.limit, who: "grace"}
		got := s.tree(root)
		got += s.tree(filepath.Join(root, "p0")) // a later Create: still capped
		w.Close()
		if tc.limit > 0 && (got != tc.want || !s.full) {
			t.Fatalf("limit %d: added %d (full %v)", tc.limit, got, s.full)
		}
		if tc.limit == 0 && got < tc.want {
			t.Fatalf("uncapped: added %d; want ≥ %d", got, tc.want)
		}
	}
}

// Where a watch costs a descriptor per file (kqueue), a machine tenant's
// transcripts are not watched at all — the scan interval collects them; where
// it costs one per directory (inotify) the tenant's watch is capped; a plain
// agent watches everything either way.
func TestWatchPolicy(t *testing.T) {
	old := watchPerFileFD
	t.Cleanup(func() { watchPerFileFD = old })
	tenant := &Agent{cfg: Config{RunAs: &RunAs{Login: "grace", Home: t.TempDir()}}}
	plain := &Agent{cfg: Config{}}
	for _, tc := range []struct {
		perFile bool
		a       *Agent
		on      bool
		limit   int
	}{
		{true, tenant, false, 0},
		{false, tenant, true, machineWatchMax},
		{true, plain, true, 0},
		{false, plain, true, 0},
	} {
		watchPerFileFD = tc.perFile
		if on, limit := tc.a.watchPolicy(); on != tc.on || limit != tc.limit {
			t.Errorf("perFile %v tenant %v: on %v limit %d; want %v %d", tc.perFile, tc.a.cfg.RunAs != nil, on, limit, tc.on, tc.limit)
		}
	}
	for goos, want := range map[string]bool{"darwin": true, "freebsd": true, "openbsd": true, "netbsd": true, "dragonfly": true, "linux": false, "windows": false} {
		if kqueueGOOS(goos) != want {
			t.Errorf("%s: per-file %v", goos, !want)
		}
	}
	// a tenant off the watch returns at once, holding no watcher
	watchPerFileFD = true
	done := make(chan struct{})
	go func() { tenant.watchTranscripts(context.Background(), []string{t.TempDir()}, func() {}); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a tenant on a per-file platform still watches")
	}
}
