package scan

import (
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
)

// fileState is what the scanner remembers about one transcript between runs.
type fileState struct {
	// Offset is the byte position just past the last COMPLETE line consumed.
	// A partial trailing line leaves Offset before it, so the next scan picks
	// it up once the writer finishes.
	Offset int64 `json:"offset"`
	Size   int64 `json:"size"`

	// HeadHash/HeadLen fingerprint the file's first HeadLen bytes. Offsets are
	// only meaningful against the same document: if a session file is replaced
	// by a longer, different one, size alone still looks like an append and the
	// scanner would resume reading from the middle of unrelated content.
	//
	// HeadLen is recorded rather than assumed because transcripts start small.
	// Hashing a fixed 512-byte window would make the fingerprint of a 200-byte
	// file change every time a line is appended, and every append would then
	// look like a replacement and force a full rescan.
	HeadHash uint64 `json:"head_hash"`
	HeadLen  int64  `json:"head_len"`

	// ModTimeNano is the file's modification time when Offset was recorded.
	//
	// Purely an optimisation, and only ever used to skip work: together with
	// Size it answers "has anything been appended?" from the directory walk
	// alone, without opening the file or hashing its prefix. On a machine with
	// 25,164 transcripts, a cycle in which nothing had changed cost 755ms of
	// pure I/O to re-verify cursors that were all still valid — affordable
	// once a minute, not once every few seconds.
	//
	// It is never trusted to decide WHERE to resume; that is still Offset,
	// verified against HeadHash. A file whose size and mtime both match cannot
	// have been appended to, because an append changes both.
	ModTimeNano int64 `json:"mod_time_nano,omitempty"`
}

// cursor is the persisted map of transcript path -> position.
type cursor struct {
	path  string
	Files map[string]fileState `json:"files"`
}

// headSample is the largest prefix used as a fingerprint.
const headSample = 512

func loadCursor(path string) *cursor {
	c := &cursor{path: path, Files: map[string]fileState{}}
	b, err := os.ReadFile(path)
	if err != nil {
		return c // absent or unreadable: start clean, a full rescan is safe
	}
	var onDisk struct {
		Files map[string]fileState `json:"files"`
	}
	if err := json.Unmarshal(b, &onDisk); err != nil {
		return c // corrupt: same, rather than wedging the agent forever
	}
	if onDisk.Files != nil {
		c.Files = onDisk.Files
	}
	return c
}

// save writes the cursor atomically. A half-written cursor would be worse than
// no cursor: it could park an offset past real data and silently drop events.
func (c *cursor) save() error {
	if err := os.MkdirAll(filepath.Dir(c.path), 0o755); err != nil {
		return fmt.Errorf("create cursor dir: %w", err)
	}
	b, err := json.Marshal(struct {
		Files map[string]fileState `json:"files"`
	}{Files: c.Files})
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("write cursor: %w", err)
	}
	if err := os.Rename(tmp, c.path); err != nil {
		return fmt.Errorf("commit cursor: %w", err)
	}
	return nil
}

// hashPrefix fingerprints exactly the first n bytes of f. A short read is not
// an error: it means the file shrank, which the caller treats as a rewrite.
func hashPrefix(f *os.File, n int64) (uint64, error) {
	h := fnv.New64a()
	if n <= 0 {
		return h.Sum64(), nil
	}
	buf := make([]byte, n)
	read, err := f.ReadAt(buf, 0)
	if err != nil && !errors.Is(err, io.EOF) {
		return 0, err
	}
	h.Write(buf[:read])
	return h.Sum64(), nil
}

// anchor computes the fingerprint to store for a file of the given size.
func anchor(f *os.File, size int64) (hash uint64, length int64, err error) {
	length = size
	if length > headSample {
		length = headSample
	}
	hash, err = hashPrefix(f, length)
	return hash, length, err
}
