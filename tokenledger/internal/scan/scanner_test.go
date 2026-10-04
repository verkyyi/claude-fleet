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
	if err := s.Commit(); err != nil {
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
	if err := s.Commit(); err != nil {
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
	if err := s.Commit(); err != nil {
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
	if err := s1.Commit(); err != nil {
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
	if err := s.Commit(); err != nil {
		t.Fatal(err)
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

// Regression: Scan used to persist the cursor itself, so a caller that failed
// to hand the events off lost them permanently. The position now only moves on
// an explicit Commit.
func TestScanner_UncommittedScanIsRepeated(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "projects")
	cursor := filepath.Join(dir, "cursor.json")
	writeFile(t, filepath.Join(root, "proj-a", "sess1.jsonl"), line("u1", 10), line("u2", 20))

	s1 := NewScanner(root, cursor)
	evs, err := s1.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 {
		t.Fatalf("first scan returned %d events, want 2", len(evs))
	}
	// Deliberately do NOT commit: this stands in for "the hub was down".

	s2 := NewScanner(root, cursor)
	evs, err = s2.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 {
		t.Fatalf("after an uncommitted scan, a fresh scanner returned %d events, want 2 — the batch was lost", len(evs))
	}

	if err := s2.Commit(); err != nil {
		t.Fatal(err)
	}
	s3 := NewScanner(root, cursor)
	evs, err = s3.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 0 {
		t.Fatalf("after Commit a fresh scanner returned %d events, want 0", len(evs))
	}
}

// The pre-filter that makes a fast scan interval affordable.
//
// Verifying an unchanged cursor means opening the file and hashing its prefix.
// On a machine with 25,164 transcripts a cycle in which nothing had changed
// cost 755ms of pure I/O to conclude that nothing had changed; skipping on
// size+mtime from the directory walk took it to 134ms.
func TestScan_SkipsUnchangedTranscripts(t *testing.T) {
	root := t.TempDir()
	cursorPath := filepath.Join(t.TempDir(), "cursor.json")
	path := filepath.Join(root, "a.jsonl")
	writeFile(t, path, line("a", 10), line("b", 20))

	s := NewScanner(root, cursorPath)
	if _, err := s.Scan(); err != nil {
		t.Fatal(err)
	}
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}

	s2 := NewScanner(root, cursorPath)
	evs, err := s2.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 0 {
		t.Errorf("re-scanned an unchanged file and produced %d events", len(evs))
	}
	if s2.Skipped() != 1 {
		t.Errorf("skipped %d files, want 1 — the pre-filter did not engage", s2.Skipped())
	}
}

// The control, and the only one that really matters: a file that HAS grown must
// never be skipped. A pre-filter that skipped everything would satisfy the test
// above while silently ending data collection.
func TestScan_NeverSkipsAnAppendedTranscript(t *testing.T) {
	root := t.TempDir()
	cursorPath := filepath.Join(t.TempDir(), "cursor.json")
	path := filepath.Join(root, "a.jsonl")
	writeFile(t, path, line("a", 10))

	s := NewScanner(root, cursorPath)
	if _, err := s.Scan(); err != nil {
		t.Fatal(err)
	}
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}

	appendLines(t, path, line("c", 30), line("d", 40), line("e", 50))

	s2 := NewScanner(root, cursorPath)
	evs, err := s2.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 3 {
		t.Fatalf("got %d events after appending 3; the pre-filter swallowed new work", len(evs))
	}
	if s2.Skipped() != 0 {
		t.Errorf("skipped %d files, want 0", s2.Skipped())
	}
}

// Either half changing is enough to force a real look. Size is the reliable
// signal for an append; mtime catches a rewrite that happens to land on the
// same length.
func TestScan_EitherSizeOrMtimeChangeForcesARescan(t *testing.T) {
	for _, tc := range []struct {
		name  string
		touch func(t *testing.T, path string, st fileState) fileState
	}{
		{"size differs", func(t *testing.T, _ string, st fileState) fileState {
			st.Size--
			return st
		}},
		{"mtime differs", func(t *testing.T, _ string, st fileState) fileState {
			st.ModTimeNano--
			return st
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			cursorPath := filepath.Join(t.TempDir(), "cursor.json")
			path := filepath.Join(root, "a.jsonl")
			writeFile(t, path, line("a", 10), line("b", 20))

			s := NewScanner(root, cursorPath)
			if _, err := s.Scan(); err != nil {
				t.Fatal(err)
			}
			if err := s.Commit(); err != nil {
				t.Fatal(err)
			}

			s2 := NewScanner(root, cursorPath)
			st := s2.cursor.Files[path]
			s2.cursor.Files[path] = tc.touch(t, path, st)

			if _, err := s2.Scan(); err != nil {
				t.Fatal(err)
			}
			if s2.Skipped() != 0 {
				t.Errorf("skipped a file whose %s; the cursor must be re-verified", tc.name)
			}
		})
	}
}

// A cursor written before mtimes were recorded must not be treated as "matches
// nothing changed" — ModTimeNano is zero there, which would collide with a real
// file only if its mtime were the unix epoch.
func TestScan_CursorWithoutAnMtimeIsNotSkipped(t *testing.T) {
	root := t.TempDir()
	cursorPath := filepath.Join(t.TempDir(), "cursor.json")
	path := filepath.Join(root, "a.jsonl")
	writeFile(t, path, line("a", 10), line("b", 20))

	s := NewScanner(root, cursorPath)
	if _, err := s.Scan(); err != nil {
		t.Fatal(err)
	}
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}

	s2 := NewScanner(root, cursorPath)
	st := s2.cursor.Files[path]
	st.ModTimeNano = 0 // as an older ccquota would have left it
	s2.cursor.Files[path] = st

	if _, err := s2.Scan(); err != nil {
		t.Fatal(err)
	}
	if s2.Skipped() != 0 {
		t.Error("an mtime-less cursor entry was treated as unchanged")
	}
}
