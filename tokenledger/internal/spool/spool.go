// Package spool is a bounded on-disk queue of pending pushes.
//
// An endpoint on a flaky link, or one whose hub is being redeployed, must not
// lose the usage it collected in the meantime. It must also not fill the disk
// of a server whose hub has been gone for a month, so the queue has a hard
// cap and drops its OLDEST entries first: recent usage is what the dashboard
// is for, and a month-old batch has already been superseded by the account
// totals Anthropic reports.
package spool

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// DefaultMaxBytes caps the queue.
const DefaultMaxBytes int64 = 64 << 20

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

// Enqueue writes a batch to disk, evicting the oldest entries if the cap would
// be exceeded.
func (s *Spool) Enqueue(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("encode batch: %w", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Written to a temp name then renamed, so a crash mid-write cannot leave a
	// half-batch that later fails to parse and blocks the queue forever.
	name := fmt.Sprintf("%d-%09d%s", time.Now().UTC().UnixNano(), os.Getpid(), ext)
	tmp := filepath.Join(s.dir, name+".tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("write spool entry: %w", err)
	}
	// A single entry larger than the whole cap would be evicted the instant it
	// lands, so refuse it up front. Silently accepting and then dropping it is
	// how a first scan on a busy machine disappears without an error.
	if int64(len(b)) > s.maxBytes {
		os.Remove(tmp)
		return fmt.Errorf("batch is %d bytes, larger than the %d-byte spool cap: split it or raise --spool-mb",
			len(b), s.maxBytes)
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, name)); err != nil {
		return fmt.Errorf("commit spool entry: %w", err)
	}
	return s.evictLocked()
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

func (s *Spool) evictLocked() error {
	entries, total, err := s.listLocked()
	if err != nil {
		return err
	}
	for total > s.maxBytes && len(entries) > 0 {
		oldest := entries[0]
		if err := os.Remove(filepath.Join(s.dir, oldest.name)); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("evict spool entry: %w", err)
		}
		log.Printf("spool full (%d bytes > %d cap): dropped the oldest queued batch", total, s.maxBytes)
		total -= oldest.size
		entries = entries[1:]
	}
	return nil
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
