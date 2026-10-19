package store

import (
	"strings"
	"testing"
	"time"
)

// A hub whose fleet_credentials table predates kind / secret_expires_at
// (claude-fleet#1463) gets the columns on open, and its existing rows read as
// kind "" — the provider's original kind.
func TestFleetCredsColumnsAddedToOldTable(t *testing.T) {
	s := newStore(t)
	old := strings.Replace(fleetCredsSchema, "  kind             TEXT NOT NULL DEFAULT '',\n  secret_expires_at TEXT,\n", "", 1)
	if old == fleetCredsSchema {
		t.Fatal("test no longer strips the new columns from the schema")
	}
	if _, err := s.write.Exec(s.d.ddl(old)); err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 10, 4, 0, 0, 0, 0, time.UTC)
	if _, err := s.write.Exec(`INSERT INTO fleet_credentials (principal_id, provider, account, secret_sealed, created_at, updated_at)
		VALUES ('gh:1001', 'claude', 'main', ?, ?, ?)`, []byte{1}, fmtTime(at), fmtTime(at)); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureNodes(); err != nil {
		t.Fatalf("second ensure: %v", err)
	}
	rows, err := s.Credentials("")
	if err != nil || len(rows) != 1 || rows[0].Kind != "" || rows[0].SecretExpiresAt != nil {
		t.Fatalf("old row = %+v, %v", rows, err)
	}
	exp := at.Add(365 * 24 * time.Hour)
	if err := s.PutCredential(PoolPrincipal, "claude", "icloud", []byte{2}, "setup_token", &exp, at); err != nil {
		t.Fatal(err)
	}
	c, err := s.Credential(PoolPrincipal, "claude", "icloud")
	if err != nil || c.Kind != "setup_token" || c.SecretExpiresAt == nil || !c.SecretExpiresAt.Equal(exp) {
		t.Fatalf("pool row = %+v, %v", c, err)
	}
	// Replacing it with a refresh token clears the expiry with the kind.
	if err := s.PutCredential(PoolPrincipal, "claude", "icloud", []byte{3}, "refresh_token", nil, at); err != nil {
		t.Fatal(err)
	}
	if c, _ = s.Credential(PoolPrincipal, "claude", "icloud"); c.Kind != "refresh_token" || c.SecretExpiresAt != nil || c.Version != 2 {
		t.Fatalf("replaced row = %+v", c)
	}
}

// "pool" is the shared-pool credential sentinel, never a person.
func TestPoolPrincipalIsReserved(t *testing.T) {
	s := newStore(t)
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AdoptPrincipal(PoolPrincipal, "pool", "Pool", time.Now()); err == nil || !strings.Contains(err.Error(), "reserved") {
		t.Fatalf("adopting %q: %v", PoolPrincipal, err)
	}
	if _, err := s.EnsurePrincipal(PoolPrincipal, "Pool", 16, func(string) bool { return true }, time.Now()); err == nil {
		t.Fatalf("ensuring %q succeeded", PoolPrincipal)
	}
}
