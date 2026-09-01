package spool

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type payload struct {
	N    int    `json:"n"`
	Blob string `json:"blob"`
}

func newSpool(t *testing.T, maxBytes int64) *Spool {
	t.Helper()
	s, err := New(filepath.Join(t.TempDir(), "spool"), maxBytes)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestEnqueuePeekAck(t *testing.T) {
	s := newSpool(t, 0)
	if err := s.Enqueue(payload{N: 1}); err != nil {
		t.Fatal(err)
	}

	var got payload
	ack, ok, err := s.Peek(&got)
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if got.N != 1 {
		t.Fatalf("N = %d, want 1", got.N)
	}

	// Until acked, the entry stays queued — a delivery that fails halfway must
	// be retried, not lost.
	if n, _ := s.Len(); n != 1 {
		t.Fatalf("queued = %d before ack, want 1", n)
	}
	if err := ack(); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.Len(); n != 0 {
		t.Fatalf("queued = %d after ack, want 0", n)
	}
}

func TestPeek_EmptyQueue(t *testing.T) {
	s := newSpool(t, 0)
	var got payload
	_, ok, err := s.Peek(&got)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("ok = true on an empty queue")
	}
}

func TestPeek_ReturnsOldestFirst(t *testing.T) {
	s := newSpool(t, 0)
	for i := 1; i <= 3; i++ {
		if err := s.Enqueue(payload{N: i}); err != nil {
			t.Fatal(err)
		}
	}
	for want := 1; want <= 3; want++ {
		var got payload
		ack, ok, err := s.Peek(&got)
		if err != nil || !ok {
			t.Fatalf("ok=%v err=%v", ok, err)
		}
		if got.N != want {
			t.Fatalf("N = %d, want %d — the queue is not FIFO", got.N, want)
		}
		if err := ack(); err != nil {
			t.Fatal(err)
		}
	}
}

// A hub that has been gone for a month must not fill the endpoint's disk — but
// the queue refuses new work rather than discarding accepted work, because the
// caller has already moved its scan position past anything it handed over.
func TestEnqueue_RefusesPastTheCapAndKeepsWhatItAccepted(t *testing.T) {
	const cap = 4096
	s := newSpool(t, cap)

	big := strings.Repeat("x", 1000)
	accepted := 0
	var lastErr error
	for i := 1; i <= 20; i++ {
		if err := s.Enqueue(payload{N: i, Blob: big}); err != nil {
			lastErr = err
			break
		}
		accepted++
	}

	if lastErr == nil {
		t.Fatal("the queue accepted 20 oversized batches without ever hitting its cap")
	}
	if !errors.Is(lastErr, ErrFull) {
		t.Errorf("err = %v, want ErrFull so the caller knows to hold its cursor", lastErr)
	}
	if accepted == 0 {
		t.Fatal("nothing was accepted at all")
	}

	total, err := s.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	if total > cap {
		t.Fatalf("spool grew to %d bytes, past its %d cap", total, cap)
	}

	// Everything accepted is still there, in order, starting from the FIRST.
	// The evicting version used to answer N=15 here.
	var got payload
	if _, ok, err := s.Peek(&got); err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if got.N != 1 {
		t.Errorf("oldest queued batch is N=%d, want 1 — accepted work was discarded", got.N)
	}
	if n, _ := s.Len(); n != accepted {
		t.Errorf("queued %d batches, accepted %d — some were dropped after acceptance", n, accepted)
	}
}

// Once the backlog drains, the queue takes work again.
func TestEnqueue_RecoversAfterDraining(t *testing.T) {
	s := newSpool(t, 4096)
	big := strings.Repeat("x", 1000)
	for i := 1; ; i++ {
		if err := s.Enqueue(payload{N: i, Blob: big}); err != nil {
			break
		}
	}
	var got payload
	ack, ok, err := s.Peek(&got)
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if err := ack(); err != nil {
		t.Fatal(err)
	}
	if err := s.Enqueue(payload{N: 99, Blob: big}); err != nil {
		t.Fatalf("the queue stayed full after a batch was acked: %v", err)
	}
}

func TestSpool_SurvivesRestart(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "spool")
	s1, err := New(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := s1.Enqueue(payload{N: 42}); err != nil {
		t.Fatal(err)
	}

	s2, err := New(dir, 0) // fresh process
	if err != nil {
		t.Fatal(err)
	}
	var got payload
	_, ok, err := s2.Peek(&got)
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if got.N != 42 {
		t.Fatalf("N = %d, want 42", got.N)
	}
}

// A corrupt entry must not wedge the queue forever behind it.
func TestPeek_SkipsAndDropsCorruptEntries(t *testing.T) {
	s := newSpool(t, 0)
	if err := s.Enqueue(payload{N: 1}); err != nil {
		t.Fatal(err)
	}
	// Overwrite the queued file with garbage.
	des, _ := os.ReadDir(s.dir)
	if len(des) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(des))
	}
	if err := os.WriteFile(filepath.Join(s.dir, des[0].Name()), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Enqueue(payload{N: 2}); err != nil {
		t.Fatal(err)
	}

	var got payload
	_, ok, err := s.Peek(&got)
	if err != nil {
		t.Fatalf("a corrupt entry must not fail the whole queue: %v", err)
	}
	if !ok || got.N != 2 {
		t.Fatalf("ok=%v N=%d, want the next good batch", ok, got.N)
	}
	if n, _ := s.Len(); n != 1 {
		t.Errorf("queued = %d, want 1 — the corrupt entry should have been dropped", n)
	}
}

// A crash mid-write leaves a .tmp file; it must never be picked up as a batch.
func TestPeek_IgnoresPartialWrites(t *testing.T) {
	s := newSpool(t, 0)
	if err := os.WriteFile(filepath.Join(s.dir, "123"+ext+".tmp"), []byte(`{"n":9}`), 0o600); err != nil {
		t.Fatal(err)
	}
	var got payload
	_, ok, _ := s.Peek(&got)
	if ok {
		t.Fatal("a .tmp file was treated as a committed batch")
	}
}

// Regression: a batch bigger than the whole cap used to be written, instantly
// evicted, and reported as success. On a busy machine that silently threw away
// the entire first scan.
func TestEnqueue_OversizedBatchIsRefusedNotSilentlyDropped(t *testing.T) {
	s := newSpool(t, 1024)

	err := s.Enqueue(payload{N: 1, Blob: strings.Repeat("x", 4096)})
	if err == nil {
		t.Fatal("an oversized batch was accepted; it would have vanished on eviction")
	}
	if !errors.Is(err, ErrFull) {
		t.Errorf("err = %v, want ErrFull", err)
	}
	if n, _ := s.Len(); n != 0 {
		t.Errorf("queued = %d, want 0", n)
	}
	// The temp file must be cleaned up, not left to accumulate.
	des, _ := os.ReadDir(s.dir)
	if len(des) != 0 {
		t.Errorf("left %d files behind after refusing the batch", len(des))
	}
}
