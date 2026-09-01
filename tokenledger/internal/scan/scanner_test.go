package scan

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// line builds a minimal billable assistant entry with a given uuid.
func line(uuid string, out int64) string {
	return fmt.Sprintf(
		`{"type":"assistant","uuid":%q,"sessionId":"s1","timestamp":"2026-08-31T00:00:00Z","cwd":"/w","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"output_tokens":%d}}}`,
		uuid, out)
}

func writeFile(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	var buf []byte
	for _, l := range lines {
		buf = append(buf, l...)
		buf = append(buf, '\n')
	}
	if err := os.WriteFile(path, buf, 0o644); err != nil {
		t.Fatal(err)
	}
}

func appendLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, l := range lines {
		if _, err := f.WriteString(l + "\n"); err != nil {
			t.Fatal(err)
		}
	}
}

func newTestScanner(t *testing.T) (*Scanner, string) {
	t.Helper()
	dir := t.TempDir()
	root := filepath.Join(dir, "projects")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	return NewScanner(root, filepath.Join(dir, "cursor.json")), root
}

func TestScanner_FirstScanReadsEverything(t *testing.T) {
	s, root := newTestScanner(t)
	writeFile(t, filepath.Join(root, "proj-a", "sess1.jsonl"), line("u1", 10), line("u2", 20))

	evs, err := s.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 {
		t.Fatalf("got %d events, want 2", len(evs))
	}
}

// The property that makes an agent safe to run on a timer: re-running against
// unchanged files must produce nothing, or every poll re-sends the world.
func TestScanner_RescanIsNoOp(t *testing.T) {
	s, root := newTestScanner(t)
	writeFile(t, filepath.Join(root, "proj-a", "sess1.jsonl"), line("u1", 10))

	if _, err := s.Scan(); err != nil {
		t.Fatal(err)
	}
	evs, err := s.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 0 {
		t.Fatalf("second scan returned %d events, want 0", len(evs))
	}
}

func TestScanner_AppendReadsOnlyNewBytes(t *testing.T) {
	s, root := newTestScanner(t)
	p := filepath.Join(root, "proj-a", "sess1.jsonl")
	writeFile(t, p, line("u1", 10))
	if _, err := s.Scan(); err != nil {
		t.Fatal(err)
	}

	appendLines(t, p, line("u2", 20), line("u3", 30))
	evs, err := s.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 {
		t.Fatalf("got %d events, want 2 (only the appended ones)", len(evs))
	}
	if evs[0].MessageUUID != "u2" || evs[1].MessageUUID != "u3" {
		t.Errorf("got %q,%q want u2,u3", evs[0].MessageUUID, evs[1].MessageUUID)
	}
}

// A truncated file means the session was reset or replaced. Reading from the
// stale offset would skip the new content entirely — silently.
func TestScanner_TruncationForcesFullRescan(t *testing.T) {
	s, root := newTestScanner(t)
	p := filepath.Join(root, "proj-a", "sess1.jsonl")
	writeFile(t, p, line("u1", 10), line("u2", 20), line("u3", 30))
	if _, err := s.Scan(); err != nil {
		t.Fatal(err)
	}

	writeFile(t, p, line("v1", 5)) // shorter than before
	evs, err := s.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 1 || evs[0].MessageUUID != "v1" {
		t.Fatalf("got %d events (%v), want 1 (v1)", len(evs), uuids(evs))
	}
}

// The cursor must survive process restart; an agent restarted by systemd every
// deploy would otherwise re-ship its whole history each time.
func TestScanner_CursorPersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "projects")
	cursor := filepath.Join(dir, "cursor.json")
	writeFile(t, filepath.Join(root, "proj-a", "sess1.jsonl"), line("u1", 10))

	s1 := NewScanner(root, cursor)
	if _, err := s1.Scan(); err != nil {
		t.Fatal(err)
	}

	s2 := NewScanner(root, cursor) // fresh process
	evs, err := s2.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 0 {
		t.Fatalf("restarted scanner returned %d events, want 0", len(evs))
	}
}

// Forking a conversation copies earlier entries into a new file. The same API
// call must not be counted twice — dedup is by uuid, within one scan too.
func TestScanner_DuplicateUUIDsAcrossFilesCollapse(t *testing.T) {
	s, root := newTestScanner(t)
	writeFile(t, filepath.Join(root, "proj-a", "sess1.jsonl"), line("shared", 10), line("only1", 20))
	writeFile(t, filepath.Join(root, "proj-a", "sess2.jsonl"), line("shared", 10), line("only2", 30))

	evs, err := s.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 3 {
		t.Fatalf("got %d events (%v), want 3 — the shared uuid must collapse", len(evs), uuids(evs))
	}
}

func TestScanner_IgnoresNonJSONL(t *testing.T) {
	s, root := newTestScanner(t)
	writeFile(t, filepath.Join(root, "proj-a", "notes.md"), "not json")
	writeFile(t, filepath.Join(root, "proj-a", "sess1.jsonl"), line("u1", 10))

	evs, err := s.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 1 {
		t.Fatalf("got %d events, want 1", len(evs))
	}
}

// A partial line at the tail is normal: Claude Code may be mid-write. The
// scanner must stop at the last complete line and resume from there, not error
// out and not skip the line once it lands.
func TestScanner_PartialTrailingLineIsRetried(t *testing.T) {
	s, root := newTestScanner(t)
	p := filepath.Join(root, "proj-a", "sess1.jsonl")
	writeFile(t, p, line("u1", 10))

	// Append a truncated line with no newline terminator.
	f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	partial := line("u2", 20)
	if _, err := f.WriteString(partial[:len(partial)/2]); err != nil {
		t.Fatal(err)
	}
	f.Close()

	evs, err := s.Scan()
	if err != nil {
		t.Fatalf("a partial trailing write must not be an error: %v", err)
	}
	if len(evs) != 1 {
		t.Fatalf("got %d events, want 1 (the complete line only)", len(evs))
	}

	// Now the rest of the line arrives.
	appendLines(t, p, partial[len(partial)/2:])
	evs, err = s.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 1 || evs[0].MessageUUID != "u2" {
		t.Fatalf("got %d events (%v), want 1 (u2) once the write completed", len(evs), uuids(evs))
	}
}

func uuids(evs []model.UsageEvent) []string {
	out := make([]string, len(evs))
	for i, e := range evs {
		out[i] = e.MessageUUID
	}
	return out
}
