package main

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestRunSvcScopes(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedTestDB(t, db)
	run := func(args ...string) error { return runSvc(append(args, "--db", db)) }
	if err := run("create", "example", "--scopes", "templates:write,runs:read"); err != nil {
		t.Fatal(err)
	}
	if err := run("disable", "example"); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"scopes", "example"}, {"scopes", "example", "--scopes", "admin"}, {"scopes", "missing", "--scopes", "runs:read"}} {
		if err := run(args...); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
	if err := run("scopes", "example", "--scopes", "runs:read,runs:write,runs:read"); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	p, err := st.SvcPrincipal("example")
	if err != nil || strings.Join(p.Scopes, ",") != "runs:write,runs:read" || p.Enabled {
		t.Fatalf("principal: %+v %v", p, err)
	}
	if err := run("scopes", "svc:example", "--scopes="); err != nil {
		t.Fatal(err)
	}
	p, err = st.SvcPrincipal("example")
	if err != nil || len(p.Scopes) != 0 || p.Enabled {
		t.Fatalf("clear: %+v %v", p, err)
	}
	audits, err := st.HubAuditLog(100)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, a := range audits {
		if a.Action == "svc.scopes" {
			count++
			if a.Target != "svc:example" || a.Outcome != "ok" || !strings.HasPrefix(a.Actor, "cli:") || !strings.HasPrefix(a.Detail, "scopes=") {
				t.Fatalf("audit: %+v", a)
			}
		}
	}
	if count != 2 {
		t.Fatalf("audits = %d, want 2", count)
	}
}
