package main

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// seedTestDB enrolls ep-1 (token hash "hash-1") and gives it an event.
func seedTestDB(t *testing.T, path string) {
	t.Helper()
	st, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	id := model.Identity{AccountUUID: "acct-1", Email: "a@example.com", Hostname: "h1"}
	if err := st.UpsertAccount(id, "max", "tier"); err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("ep-1", "ep-1", "hash-1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.TouchEndpoint("ep-1", id, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	cost := 1.5
	if _, _, err := st.InsertEvents([]model.UsageEvent{{
		AccountUUID: "acct-1", EndpointID: "ep-1", MessageUUID: "m1",
		TS: time.Now().UTC().Add(-time.Hour), Model: "claude-opus-5",
		InputTokens: 1000, OutputTokens: 2000, CostUSD: &cost,
		CWD: "/w", OSUser: "alice",
	}}); err != nil {
		t.Fatal(err)
	}
}
