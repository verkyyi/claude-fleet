package store

import (
	"path/filepath"
	"testing"
	"time"
)

// The link-ownership table (claude-fleet#2124): a late drop never deletes the
// newer link's row, and a replica's start clears only its own.
func TestFleetNodeConnsOwnership(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.NodeConns(); err == nil {
		t.Fatal("fleet_node_conns exists before EnsureFleetNodeConns; a single hub must never get it")
	}
	if err := s.EnsureFleetNodeConns(); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureFleetNodeConns(); err != nil {
		t.Fatalf("second ensure: %v", err)
	}
	now := time.Now()
	claim := func(ep, replica, epoch string, caps ...string) {
		t.Helper()
		if err := s.ClaimNodeConn(NodeConn{EndpointID: ep, Replica: replica, URL: "http://" + replica + ":8787",
			Epoch: epoch, Admin: replica == "a", Caps: caps, ConnectedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	owner := func(ep string) string {
		t.Helper()
		c, ok, err := s.NodeConnOf(ep)
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			return ""
		}
		return c.Replica + "/" + c.Epoch
	}

	claim("ep_m4", "a", "e1", "read", "write")
	c, _, _ := s.NodeConnOf("ep_m4")
	if !c.Admin || !c.HasCap("write") || c.HasCap("move") || c.URL != "http://a:8787" {
		t.Fatalf("row read back as %+v", c)
	}
	// m4 reconnects to b before a notices its old link die.
	claim("ep_m4", "b", "e2")
	if err := s.ReleaseNodeConn("ep_m4", "a", "e1"); err != nil {
		t.Fatal(err)
	}
	if got := owner("ep_m4"); got != "b/e2" {
		t.Fatalf("a late drop on a deleted b's row: owner %q", got)
	}
	if c, _, _ := s.NodeConnOf("ep_m4"); len(c.Caps) != 0 || c.Admin {
		t.Fatalf("the newer hello's caps did not replace the old: %+v", c)
	}
	if err := s.ReleaseNodeConn("ep_m4", "b", "e2"); err != nil {
		t.Fatal(err)
	}
	if got := owner("ep_m4"); got != "" {
		t.Fatalf("own drop left %q", got)
	}

	claim("ep_m4", "a", "e3")
	claim("ep_m5", "b", "e4")
	if n, err := s.ReleaseReplicaConns("a"); err != nil || n != 1 {
		t.Fatalf("ReleaseReplicaConns(a) = %d, %v; want 1", n, err)
	}
	rows, _ := s.NodeConns()
	if len(rows) != 1 || rows[0].EndpointID != "ep_m5" {
		t.Fatalf("after a's start: %+v; want only b's ep_m5", rows)
	}
}
