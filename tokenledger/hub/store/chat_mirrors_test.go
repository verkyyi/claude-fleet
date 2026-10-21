package store

import (
	"testing"
	"time"
)

// Two reads of one person finish out of order (two replicas, task Y393): the
// copy keeps the answer the home gave last, never the one that ended last.
func TestChatMirrorKeepsNewest(t *testing.T) {
	s := newStore(t)
	if err := s.ensureFleetTrials(); err != nil {
		t.Fatal(err)
	}
	t0 := time.Unix(1_800_000_000, 0)
	exp := t0.Add(24 * time.Hour)
	if err := s.PutChatMirror("p1", []byte("new"), exp, t0.Add(5*time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := s.PutChatMirror("p1", []byte("old"), exp, t0); err != nil {
		t.Fatal(err)
	}
	c, err := s.ChatMirror("p1", t0)
	if err != nil || c == nil || string(c.Sealed) != "new" || !c.UpdatedAt.Equal(t0.Add(5*time.Second)) {
		t.Fatalf("an older answer replaced the newer copy: %+v %v", c, err)
	}
	if err := s.PutChatMirror("p1", []byte("newer"), exp, t0.Add(9*time.Second)); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.ChatMirror("p1", t0); c == nil || string(c.Sealed) != "newer" {
		t.Fatalf("a newer answer did not replace the copy: %+v", c)
	}
}
