package store

import (
	"database/sql"
	"errors"
	"testing"
	"time"
)

// A move bundle past FleetMoveTTL is never handed out, even before the sweep
// deletes it; the sweep then forgets it while a fresh one stays.
func TestFleetMoveBundleExpires(t *testing.T) {
	s := newStore(t)
	if err := s.ensureFleetMoves(); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	old := FleetMove{ID: "op_old", FromEndpoint: "ep_a", SHA256: "x", Size: 3, Created: now.Add(-FleetMoveTTL - time.Minute)}
	fresh := FleetMove{ID: "op_new", FromEndpoint: "ep_a", SHA256: "y", Size: 3, Created: now.Add(-time.Hour)}
	for _, m := range []FleetMove{old, fresh} {
		if err := s.InsertFleetMoveBundle(m, []byte("abc")); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := s.FleetMoveBundle(old.ID, now); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("expired bundle read = %v; want sql.ErrNoRows", err)
	}
	if b, m, err := s.FleetMoveBundle(fresh.ID, now); err != nil || string(b) != "abc" || m.ID != fresh.ID {
		t.Errorf("fresh bundle read = %q %v %v; want its bytes", b, m.ID, err)
	}
	n, err := s.ExpireFleetMoves(FleetMoveTTL, now)
	if err != nil || n != 1 {
		t.Fatalf("expire = %d %v; want 1", n, err)
	}
	if _, err := s.FleetMove(old.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("expired row after the sweep = %v; want gone", err)
	}
	if _, err := s.FleetMove(fresh.ID); err != nil {
		t.Errorf("fresh row after the sweep = %v; want kept", err)
	}
}
