package api

import (
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// openTestStore is a fresh store for one test, closed at cleanup — a copy of
// one migrated template per test binary (hub/store/storetest, claude-fleet#2574).
func openTestStore(t testing.TB) *store.Store { return storetest.Open(t) }

// openFleetTestStore is openTestStore with the fleet registry applied
// (store.EnsureNodes), from a template of its own (claude-fleet#4794).
func openFleetTestStore(t testing.TB) *store.Store { return storetest.OpenFleet(t) }
