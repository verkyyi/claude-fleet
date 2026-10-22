package store

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestCodexContinuationStore(t *testing.T) {
	s := newStore(t)
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2030, 1, 2, 0, 0, 0, 0, time.UTC)
	a := CodexAffinity{Owner: "person", Account: "a", CredentialID: "id-a"}
	b := CodexAffinity{Owner: "person", Account: "b", CredentialID: "id-b"}
	var bulk []string
	for i := 0; i < 300; i++ {
		bulk = append(bulk, fmt.Sprintf("bulk-%d", i))
	}
	if err := s.RecordCodexAffinity("bulk-worker", bulk, a, now); err != nil {
		t.Fatal(err)
	}
	if got, err := s.CodexAffinityFor("bulk-worker", bulk, now); err != nil || got != a {
		t.Fatalf("bulk: %+v %v", got, err)
	}
	if err := s.RecordCodexAffinity("worker", []string{"ref-a"}, a, now); err != nil {
		t.Fatal(err)
	}
	// Open(path) is remapped by the PostgreSQL fixture to a database per path.
	// Reopen this exact backend, not a new fixture named after its DSN.
	reopened, err := openStore(s.d, s.src, "codex-affinity-reopen")
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if got, err := reopened.CodexAffinityFor("worker", []string{"ref-a"}, now); err != nil || got != a {
		t.Fatalf("%+v %v", got, err)
	}
	for _, tc := range []struct {
		worker string
		refs   []string
		at     time.Time
	}{
		{"other", []string{"ref-a"}, now}, {"worker", []string{"unknown"}, now},
		{"worker", []string{"ref-a"}, now.Add(30 * 24 * time.Hour)},
	} {
		if _, err := s.CodexAffinityFor(tc.worker, tc.refs, tc.at); err == nil {
			t.Fatal("unknown/expired/cross-worker reference accepted")
		}
	}
	if err := s.RecordCodexAffinity("worker", []string{"ref-b"}, b, now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CodexAffinityFor("worker", []string{"ref-a", "ref-b"}, now); err == nil {
		t.Fatal("mixed identities accepted")
	}
	var wg sync.WaitGroup
	for _, a := range []CodexAffinity{a, b} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := s.RecordCodexAffinity("worker", []string{"race"}, a, now); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if _, err := s.CodexAffinityFor("worker", []string{"race"}, now); err == nil {
		t.Fatal("conflicting concurrent writers reassigned a reference")
	}
	// Expiry cannot make a reference reusable by a different credential.
	if err := s.RecordCodexAffinity("worker", []string{"ref-a"}, b, now.Add(31*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CodexAffinityFor("worker", []string{"ref-a"}, now.Add(31*24*time.Hour)); err == nil {
		t.Fatal("expired source was reassigned")
	}
	// A later same-identity update may extend retention, never clear ambiguity.
	if err := s.RecordCodexAffinity("worker", []string{"race"}, a, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CodexAffinityFor("worker", []string{"race"}, now); err == nil {
		t.Fatal("conflict was forgotten")
	}
}
