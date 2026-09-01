package scan

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/verkyyi/ccquota/internal/model"
)

// maxLineBytes caps a single transcript line. Real lines can reach a few MB
// when a tool result is large; anything past this is treated as corrupt rather
// than read into memory.
const maxLineBytes = 32 << 20

// Scanner walks a Claude Code projects directory and yields the usage events
// it has not yielded before.
//
// It is incremental by design: an agent polls it on a timer, and each call
// costs a stat per transcript plus a read of whatever was appended since. The
// first call on a busy machine is the expensive one.
type Scanner struct {
	root   string
	cursor *cursor

	// Errs collects non-fatal problems from the last Scan — an unreadable
	// transcript, a corrupt line. Scan keeps going and reports these rather
	// than failing the whole pass, because one bad file must not stop an
	// agent from shipping the other nine hundred.
	Errs []error
}

// NewScanner returns a Scanner over root (typically ~/.claude/projects),
// persisting its position to cursorPath.
func NewScanner(root, cursorPath string) *Scanner {
	return &Scanner{root: root, cursor: loadCursor(cursorPath)}
}

// Scan returns events appended since the last COMMITTED position.
//
// The caller must call Commit once the events are safely handed off; until
// then a repeated Scan returns them again.
//
// Events carry no AccountUUID or EndpointID: the transcripts do not record
// them. The caller stamps identity — see internal/identity and spec §10.2 for
// why that seam exists.
func (s *Scanner) Scan() ([]model.UsageEvent, error) {
	s.Errs = nil

	files, err := s.transcripts()
	if err != nil {
		return nil, err
	}

	var out []model.UsageEvent
	// A fork copies earlier entries into a new session file. Those repeat the
	// same uuid because they are the same API call, so collapse them within
	// the pass; the hub's UNIQUE constraint covers the cross-pass case.
	seen := make(map[string]struct{})

	for _, path := range files {
		evs, err := s.scanFile(path, seen)
		if err != nil {
			s.Errs = append(s.Errs, err)
			continue
		}
		out = append(out, evs...)
	}

	return out, nil
}

// Commit persists the position reached by the last Scan.
//
// It is separate from Scan on purpose. If the caller fails to hand the events
// off — the hub is down, the queue is full — the cursor must NOT have moved,
// or that batch is gone with nothing to show for it. Commit is what says "these
// are safely somewhere else now"; re-reading and re-sending is free because
// the hub dedups.
func (s *Scanner) Commit() error {
	return s.cursor.save()
}

// transcripts lists *.jsonl under root, sorted for deterministic ordering.
func (s *Scanner) transcripts() ([]string, error) {
	var out []string
	err := filepath.WalkDir(s.root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// An unreadable subdirectory should not abort the walk.
			s.Errs = append(s.Errs, err)
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil
		}
		out = append(out, path)
		return nil
	})
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("walk %s: %w", s.root, err)
	}
	sort.Strings(out)
	return out, nil
}

func (s *Scanner) scanFile(path string, seen map[string]struct{}) ([]model.UsageEvent, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat %s: %w", path, err)
	}
	size := fi.Size()

	st, known := s.cursor.Files[path]
	start := st.Offset

	switch {
	case !known:
		start = 0
	case size < st.Offset, size < st.HeadLen:
		// Truncated or rewritten shorter. Resuming from the old offset would
		// read past EOF and silently skip everything new.
		start = 0
	default:
		// Verify the recorded prefix still matches before trusting the offset.
		h, err := hashPrefix(f, st.HeadLen)
		if err != nil {
			return nil, fmt.Errorf("fingerprint %s: %w", path, err)
		}
		if h != st.HeadHash {
			start = 0 // same path, different document
		} else if size == st.Offset {
			// Nothing appended. Re-anchor anyway: the fingerprint window grows
			// with the file until it reaches headSample, which is safe now
			// that the existing prefix has been verified.
			if err := s.reanchor(path, f, size, st.Offset); err != nil {
				return nil, err
			}
			return nil, nil
		}
	}

	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return nil, fmt.Errorf("seek %s: %w", path, err)
	}

	evs, consumed, errs := s.readLines(f, path)
	s.Errs = append(s.Errs, errs...)

	if err := s.reanchor(path, f, size, start+consumed); err != nil {
		return nil, err
	}

	// Dedup after the offset is recorded: a uuid already seen this pass is
	// still consumed, it just is not emitted twice.
	out := evs[:0]
	for _, ev := range evs {
		if _, dup := seen[ev.MessageUUID]; dup {
			continue
		}
		seen[ev.MessageUUID] = struct{}{}
		out = append(out, ev)
	}
	return out, nil
}

// readLines consumes whole lines only, returning how many bytes were consumed
// so a partial trailing line is re-read next pass rather than lost or
// half-parsed.
func (s *Scanner) readLines(r io.Reader, path string) (evs []model.UsageEvent, consumed int64, errs []error) {
	br := bufio.NewReaderSize(r, 256<<10)
	for {
		line, err := br.ReadBytes('\n')
		if err != nil {
			// No trailing newline means the writer is mid-append. Leave the
			// bytes unconsumed; they will be complete on a later pass.
			if errors.Is(err, io.EOF) {
				return evs, consumed, errs
			}
			errs = append(errs, fmt.Errorf("read %s: %w", path, err))
			return evs, consumed, errs
		}
		if len(line) > maxLineBytes {
			errs = append(errs, fmt.Errorf("%s: line exceeds %d bytes, skipped", path, maxLineBytes))
			consumed += int64(len(line))
			continue
		}
		consumed += int64(len(line))

		ev, ok, perr := ParseLine(line)
		if perr != nil {
			errs = append(errs, fmt.Errorf("%s: %w", path, perr))
			continue
		}
		if ok {
			// Which file a turn came from is how a per-session account stamp
			// is matched back to it; the transcript itself names no account.
			ev.TranscriptPath = path
			evs = append(evs, *ev)
		}
	}
}

// reanchor records the position and refreshes the fingerprint window.
func (s *Scanner) reanchor(path string, f *os.File, size, offset int64) error {
	hash, length, err := anchor(f, size)
	if err != nil {
		return fmt.Errorf("fingerprint %s: %w", path, err)
	}
	s.cursor.Files[path] = fileState{
		Offset:   offset,
		Size:     size,
		HeadHash: hash,
		HeadLen:  length,
	}
	return nil
}
