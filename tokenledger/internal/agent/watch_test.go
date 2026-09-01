package agent

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// The point of the watch: a transcript being written is the signal, rather than
// waiting up to a whole interval to discover it.
func TestWatchTranscripts_FiresOnAWrite(t *testing.T) {
	root := t.TempDir()
	a := &Agent{cfg: Config{ScanInterval: time.Hour}}

	var fired atomic.Int64
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go a.watchTranscripts(ctx, root, func() { fired.Add(1) })
	time.Sleep(150 * time.Millisecond) // let the watch establish

	if err := os.WriteFile(filepath.Join(root, "s.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && fired.Load() == 0 {
		time.Sleep(20 * time.Millisecond)
	}
	if fired.Load() == 0 {
		t.Fatal("a transcript was written and no scan was triggered; the agent " +
			"would have waited for the interval")
	}
}

// Claude Code appends many times while a turn streams. Scanning per append
// would run the cycle dozens of times a second and find the same partial line.
func TestWatchTranscripts_DebouncesABurst(t *testing.T) {
	root := t.TempDir()
	a := &Agent{cfg: Config{ScanInterval: time.Hour}}

	var fired atomic.Int64
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go a.watchTranscripts(ctx, root, func() { fired.Add(1) })
	time.Sleep(150 * time.Millisecond)

	path := filepath.Join(root, "s.jsonl")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 40; i++ {
		if _, err := f.WriteString("{}\n"); err != nil {
			t.Fatal(err)
		}
		_ = f.Sync()
		time.Sleep(5 * time.Millisecond)
	}
	f.Close()

	time.Sleep(watchDebounce + 900*time.Millisecond)
	if n := fired.Load(); n == 0 {
		t.Fatal("40 appends triggered no scan at all")
	} else if n > 3 {
		t.Errorf("40 appends triggered %d scans; the debounce is not collapsing the burst", n)
	}
}

// A project directory created after the agent started must still be watched, or
// every new worktree silently falls back to the interval.
func TestWatchTranscripts_PicksUpANewProjectDirectory(t *testing.T) {
	root := t.TempDir()
	a := &Agent{cfg: Config{ScanInterval: time.Hour}}

	var fired atomic.Int64
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go a.watchTranscripts(ctx, root, func() { fired.Add(1) })
	time.Sleep(150 * time.Millisecond)

	sub := filepath.Join(root, "-new-project")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond) // the watch on sub is added on Create
	fired.Store(0)

	if err := os.WriteFile(filepath.Join(sub, "s.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && fired.Load() == 0 {
		time.Sleep(20 * time.Millisecond)
	}
	if fired.Load() == 0 {
		t.Fatal("a transcript in a directory created after startup triggered nothing")
	}
}

// The watch must never be load-bearing on its own: a missing root is normal on
// a machine that has not run Claude Code yet, and must not stop the agent.
func TestWatchTranscripts_SurvivesAMissingRoot(t *testing.T) {
	a := &Agent{cfg: Config{ScanInterval: time.Hour}}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	done := make(chan struct{})
	go func() {
		a.watchTranscripts(ctx, filepath.Join(t.TempDir(), "does-not-exist"), func() {})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("the watcher hung on a missing root")
	}
}
