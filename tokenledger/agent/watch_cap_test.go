package agent

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"

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
