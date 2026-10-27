package store

import (
	"testing"
	"time"
)

func TestSessionCredTenantMigration(t *testing.T) {
	s := newStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	// Recreate the old schema, including a live legacy pass, then migrate twice.
	if _, err := s.write.Exec(`DROP TABLE IF EXISTS fleet_session_creds`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(s.d.ddl(fleetSessionCredsSchema)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(`INSERT INTO fleet_session_creds
  (id,principal_id,worker_id,machine,endpoint_id,providers,issued_at,expires_at)
  VALUES ('old','svc:example','svc-standing/example','svc-standing','','codex',?,?)`, now.Format(sessRFC), now.Add(time.Hour).Format(sessRFC)); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := s.ensureFleetSessionCreds(); err != nil {
			t.Fatal(err)
		}
	}
	old, err := s.SessionCredByID("old")
	if err != nil || old.Tenant != "" {
		t.Fatalf("old: %+v %v", old, err)
	}
	old.ID, old.Tenant = "new", "app-a"
	if err := s.AddSessionCred(old); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.RenewSessionCred("new", now.Add(2*time.Hour), now, now); err != nil || !ok {
		t.Fatalf("renew: %t %v", ok, err)
	}
	got, err := s.SessionCredByID("new")
	if err != nil || got.Tenant != "app-a" {
		t.Fatalf("tenant: %+v %v", got, err)
	}
	rows, err := s.SessionCredsForWorker(old.WorkerID, now)
	if err != nil || len(rows) != 2 {
		t.Fatalf("list: %+v %v", rows, err)
	}
}
