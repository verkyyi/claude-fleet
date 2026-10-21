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

// A person's two conversations (task R9A2) are two copies: neither replaces the
// other, each keeps the newer-wins rule, the switch deletes both.
func TestChatMirrorPerProvider(t *testing.T) {
	s := newStore(t)
	if err := s.ensureFleetTrials(); err != nil {
		t.Fatal(err)
	}
	t0 := time.Unix(1_800_000_000, 0)
	exp := t0.Add(time.Hour)
	if err := s.PutChatMirrorOf("p1", "claude", []byte("claude"), exp, t0); err != nil {
		t.Fatal(err)
	}
	if err := s.PutChatMirrorOf("p1", "codex", []byte("codex"), exp, t0.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := s.PutChatMirrorOf("p1", "codex", []byte("codex-old"), exp, t0); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.ChatMirror("p1", t0); c == nil || string(c.Sealed) != "claude" {
		t.Fatalf("claude copy = %+v", c)
	}
	if c, _ := s.ChatMirrorOf("p1", "codex", t0); c == nil || string(c.Sealed) != "codex" {
		t.Fatalf("codex copy = %+v (the older answer must not replace it)", c)
	}
	if err := s.SetChatMirrorOff("p1", true, t0); err != nil {
		t.Fatal(err)
	}
	for _, p := range ChatMirrorProviders {
		if c, _ := s.ChatMirrorOf("p1", p, t0); c != nil {
			t.Fatalf("%s copy kept after the switch went off", p)
		}
	}
}
