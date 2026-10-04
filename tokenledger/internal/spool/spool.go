// Package spool is a bounded on-disk queue of pending pushes.
//
// It is a BUFFER, not the system of record. The transcripts under
// ~/.claude/projects are the durable copy and they are never deleted by
// ccquota, so anything the spool cannot hold is still on disk and can be read
// again.
//
// That is why a full spool REFUSES new batches instead of evicting old ones.
// Evicting looks kinder and is much worse: the caller has already advanced its
// scan position by then, so the evicted batch is gone for good. Refusing lets
// the caller leave its cursor where it is and re-read later — costing a rescan
// and losing nothing. Measured on a real machine, the evicting version silently
// dropped 46% of a first scan when the hub happened to be down.
package spool

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// DefaultMaxBytes caps the queue.
const DefaultMaxBytes int64 = 64 << 20

// ErrFull means the queue is at its cap. The caller must NOT treat the batch as
// delivered: leave the scan position untouched and try again once the hub has
// drained some of the backlog.
var ErrFull = errors.New("spool is full")

// Spool is a directory of pending batches.
type Spool struct {
	dir      string
	maxBytes int64
	mu       sync.Mutex
}

// New returns a Spool rooted at dir, creating it if needed.
func New(dir string, maxBytes int64) (*Spool, error) {
	if maxBytes <= 0 {
		maxBytes = DefaultMaxBytes
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create spool dir: %w", err)
	}
	return &Spool{dir: dir, maxBytes: maxBytes}, nil
}

const ext = ".batch.json"

// Enqueue writes a batch to disk, or returns ErrFull if it will not fit.
//
// It never evicts. See the package comment: the caller's scan position is the
// only thing standing between a refused batch and lost data.
func (s *Spool) Enqueue(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("encode batch: %w", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if int64(len(b)) > s.maxBytes {
		return fmt.Errorf("%w: batch is %d bytes, larger than the whole %d-byte cap; raise --spool-mb",
			ErrFull, len(b), s.maxBytes)
	}
	_, total, err := s.listLocked()
	if err != nil {
		return err
	}
	if total+int64(len(b)) > s.maxBytes {
		return fmt.Errorf("%w: %d queued bytes + %d would pass the %d-byte cap",
			ErrFull, total, len(b), s.maxBytes)
	}

	// Written to a temp name then renamed, so a crash mid-write cannot leave a
	// half-batch that later fails to parse and blocks the queue forever.
	name := fmt.Sprintf("%d-%09d%s", time.Now().UTC().UnixNano(), os.Getpid(), ext)
	tmp := filepath.Join(s.dir, name+".tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("write spool entry: %w", err)
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, name)); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("commit spool entry: %w", err)
	}
	return nil
}

// entry is one queued file.
type entry struct {
	name string
	size int64
}

func (s *Spool) listLocked() ([]entry, int64, error) {
	des, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, 0, fmt.Errorf("read spool dir: %w", err)
	}
	var out []entry
	var total int64
	for _, de := range des {
		if de.IsDir() || !strings.HasSuffix(de.Name(), ext) {
			continue
		}
		fi, err := de.Info()
		if err != nil {
			continue
		}
		out = append(out, entry{name: de.Name(), size: fi.Size()})
		total += fi.Size()
	}
	// Names begin with a zero-padded nanosecond timestamp, so lexical order is
	// chronological order.
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out, total, nil
}

// Peek returns the oldest queued batch decoded into v, along with a handle to
// remove it once it has been delivered.
//
// ok is false when the queue is empty. A batch is only removed on an explicit
// Ack, so a delivery that fails halfway is retried rather than lost.
func (s *Spool) Peek(v any) (ack func() error, ok bool, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	entries, _, err := s.listLocked()
	if err != nil {
		return nil, false, err
	}
	for _, e := range entries {
		path := filepath.Join(s.dir, e.name)
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, false, fmt.Errorf("read spool entry: %w", err)
		}
		if err := json.Unmarshal(b, v); err != nil {
			// A corrupt entry would otherwise wedge the queue permanently.
			// Drop it and move on; the events it held are re-derivable by
			// resetting the scanner cursor, and blocking forever is worse.
			os.Remove(path)
			continue
		}
		return func() error {
			s.mu.Lock()
			defer s.mu.Unlock()
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("ack spool entry: %w", err)
			}
			return nil
		}, true, nil
	}
	return nil, false, nil
}

// Len reports how many batches are queued.
func (s *Spool) Len() (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, _, err := s.listLocked()
	return len(entries), err
}

// Bytes reports the queue's size on disk.
func (s *Spool) Bytes() (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, total, err := s.listLocked()
	return total, err
}
