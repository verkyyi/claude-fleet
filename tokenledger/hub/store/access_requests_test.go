package store

import (
	"errors"
	"sync"
	"testing"
	"time"
)

// claude-fleet#4051: one pending request per (kind, subject), even when two
// submits race (BREAK-IT apply-flood); a refusal's cooldown holds; a
// withdrawal frees the way at once.
func TestAccessRequestsOnePending(t *testing.T) {
	s := newStore(t)
	q := s.Requests()
	now := time.Unix(1_800_000_000, 0)
	var wg sync.WaitGroup
	errs := make([]error, 8)
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = q.Create(AccessRequest{ID: "r" + string(rune('a'+i)), Kind: IdentityGitHub, Subject: "42",
				Use: "something to do", CreatedAt: now})
		}(i)
	}
	wg.Wait()
	ok := 0
	for _, err := range errs {
		switch {
		case err == nil:
			ok++
		case !errors.Is(err, ErrRequestPending):
			t.Fatalf("a racing submit failed otherwise: %v", err)
		}
	}
	rs, err := q.ByIdentity(IdentityGitHub, "42")
	if err != nil {
		t.Fatal(err)
	}
	if ok != 1 || len(rs) != 1 || rs[0].State != RequestPending {
		t.Fatalf("8 racing submits: %d accepted, %d stored; want 1 and 1", ok, len(rs))
	}
	// Another identity is not held by it.
	if _, err := q.Create(AccessRequest{ID: "other", Kind: IdentityEmail, Subject: "a@b.c", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if n, _ := q.List(RequestPending, 0); len(n) != 2 {
		t.Fatalf("pending = %d; want 2", len(n))
	}

	// Rejected with a cooldown: refused until it ends.
	until := now.Add(30 * 24 * time.Hour)
	d, err := q.Decide(rs[0].ID, RequestRejected, "not yet", until, "gh:1", now)
	if err != nil || d.State != RequestRejected || d.Reason != "not yet" || !d.CooldownUntil.Equal(until) {
		t.Fatalf("decide = %+v, %v", d, err)
	}
	if _, err := q.Decide(rs[0].ID, RequestApproved, "", time.Time{}, "gh:1", now); !errors.Is(err, ErrRequestNotPending) {
		t.Fatalf("deciding twice = %v; want ErrRequestNotPending", err)
	}
	var cool *CooldownError
	if _, err := q.Create(AccessRequest{ID: "again", Kind: IdentityGitHub, Subject: "42", CreatedAt: now.Add(time.Hour)}); !errors.As(err, &cool) || !cool.Until.Equal(until) {
		t.Fatalf("inside the cooldown = %v", err)
	}
	r2, err := q.Create(AccessRequest{ID: "after", Kind: IdentityGitHub, Subject: "42", CreatedAt: until.Add(time.Second)})
	if err != nil {
		t.Fatalf("after the cooldown = %v", err)
	}

	// Withdraw: only its own person, only once; then a new one at once.
	if _, err := q.Withdraw(r2.ID, IdentityEmail, "a@b.c", now); !errors.Is(err, ErrRequestNotFound) {
		t.Fatalf("another identity withdrew it: %v", err)
	}
	if w, err := q.Withdraw(r2.ID, IdentityGitHub, "42", now); err != nil || w.State != RequestWithdrawn {
		t.Fatalf("withdraw = %+v, %v", w, err)
	}
	if _, err := q.Edit(r2.ID, IdentityGitHub, "42", RequestEdit{Use: "x"}); !errors.Is(err, ErrRequestNotPending) {
		t.Fatalf("editing a withdrawn request = %v", err)
	}
	if _, err := q.Create(AccessRequest{ID: "anew", Kind: IdentityGitHub, Subject: "42", CreatedAt: until.Add(time.Minute)}); err != nil {
		t.Fatalf("after withdrawing = %v", err)
	}
	if n, err := q.SubmittedFrom("", until); err != nil || n != 2 {
		t.Fatalf("SubmittedFrom = %d, %v", n, err)
	}
}
