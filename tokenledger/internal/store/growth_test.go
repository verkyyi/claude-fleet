package store

import "testing"

// A reader is born with its kind. The self-marking path the shippers use runs
// after a successful push, and a read-only credential never pushes — so an
// enrollment that has to be authorised before it ever speaks cannot get its
// kind that way. (#7217)
func TestEnrollKindAndEndpointKind(t *testing.T) {
	s := newStore(t)

	if err := s.Enroll("ep-plain", "laptop", "h-plain"); err != nil {
		t.Fatal(err)
	}
	if err := s.EnrollKind("ep-reader", "monday-brief", "h-reader", "growth_reader"); err != nil {
		t.Fatal(err)
	}

	// The default has to stay "agent": every stale-agent surface filters on it,
	// and an enrollment born into some other kind would drop out of the roster
	// silently.
	if got, err := s.EndpointKind("ep-plain"); err != nil || got != "agent" {
		t.Fatalf("plain Enroll kind = %q, %v; want \"agent\", nil", got, err)
	}
	if got, err := s.EndpointKind("ep-reader"); err != nil || got != "growth_reader" {
		t.Fatalf("EnrollKind kind = %q, %v; want \"growth_reader\", nil", got, err)
	}

	// An id nobody enrolled is an error, not an empty string: an authorisation
	// gate that read "" for a missing row would compare it against its
	// allowlist and fall through to a deny — correct by accident, and one
	// refactor away from being correct no longer.
	if _, err := s.EndpointKind("ep-nope"); err == nil {
		t.Error("EndpointKind on a missing endpoint returned nil error")
	}
}
