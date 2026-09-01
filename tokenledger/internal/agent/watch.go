package agent

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/fsnotify/fsnotify"
)

// watchDebounce is how long to wait after a write before scanning.
//
// Claude Code appends to a transcript many times while a turn streams, and each
// append is an event. Scanning per event would run the cycle dozens of times a
// second for no extra information — the scan is incremental and would find the
// same partial line. Waiting for a short quiet period collapses a burst into
// one cycle.
const watchDebounce = 700 * time.Millisecond

// watchTranscripts scans as soon as a transcript is written, instead of waiting
// for the next tick.
//
// The timer loop remains and is not optional. A watch can miss events — an
// inotify queue overflows, a network filesystem reports nothing, a new project
// directory appears before the watch covers it — and a missed event under a
// watch-only design does not degrade collection, it ENDS it, silently, for that
// file. The watch makes the common case fast; the timer makes every case
// eventually correct.
//
// Failing to start is not an error worth stopping for: the agent simply falls
// back to the interval it already had.
func (a *Agent) watchTranscripts(ctx context.Context, root string, trigger func()) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("transcript watch unavailable (%v); falling back to the %s scan interval",
			err, a.cfg.ScanInterval)
		return
	}
	defer w.Close()

	added := watchTree(w, root)
	log.Printf("watching %d transcript directories; scanning within %s of a write",
		added, watchDebounce)

	var timer *time.Timer
	var fire <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			return

		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			// A new project directory needs its own watch, and the file that
			// caused it may already exist inside.
			if ev.Op&fsnotify.Create != 0 {
				if fi, err := os.Stat(ev.Name); err == nil && fi.IsDir() {
					watchTree(w, ev.Name)
				}
			}
			if filepath.Ext(ev.Name) != ".jsonl" && ev.Op&fsnotify.Create == 0 {
				continue
			}
			if timer == nil {
				timer = time.NewTimer(watchDebounce)
				fire = timer.C
			} else {
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				timer.Reset(watchDebounce)
			}

		case <-fire:
			timer, fire = nil, nil
			trigger()

		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			// Includes queue overflow, which is exactly the case the timer
			// exists to cover. Say so rather than pretending the watch is
			// still complete.
			log.Printf("transcript watch error (%v); the %s scan interval still covers this",
				err, a.cfg.ScanInterval)
		}
	}
}

// watchTree adds root and its subdirectories to the watcher, returning how many
// were added. Per-directory, because that is what the kernel interfaces take.
func watchTree(w *fsnotify.Watcher, root string) int {
	n := 0
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil //nolint:nilerr // an unreadable subtree is the timer's problem
		}
		if w.Add(path) == nil {
			n++
		}
		return nil
	})
	return n
}
