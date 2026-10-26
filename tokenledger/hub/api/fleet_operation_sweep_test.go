package api

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestOperationSweepSettlesWithoutCaller(t *testing.T) {
	h := newFleetHarness(t)
	node := connectFakeNode(t, h, "mac-d", true)
	fleet := fakeFleet(t, machineA, "live", "", "", 1)
	node.serve(func(method string, params json.RawMessage) (any, *control.Error) {
		if method != "operation_get" {
			return nil, &control.Error{Code: "INVALID_ARGUMENT", Message: "unexpected"}
		}
		var p map[string]string
		_ = json.Unmarshal(params, &p)
		return map[string]any{"operation_id": p["operation_id"], "fleet_id": fleet.FleetID, "action": "worker_message", "status": "succeeded", "result": map[string]bool{"ok": true}}, nil
	})
	node.beat("mac-d", "alice", machineA, fleet)
	waitFor(t, 3*time.Second, "fleet", func() bool { _, err := h.srv.Store.Fleet(fleet.FleetID); return err == nil })
	now := time.Now()
	for _, id := range []string{"abandoned", "expired"} {
		created := now.Add(-time.Hour)
		if id == "expired" {
			created = now.Add(-25 * time.Hour)
		}
		if err := h.srv.Store.InsertFleetOperation(store.FleetOperation{ID: id, FleetID: fleet.FleetID, Action: "worker_message", Request: "{}", Actor: "alice", Idem: id, Status: "accepted", Created: created, Updated: created}); err != nil {
			t.Fatal(err)
		}
	}
	h.srv.operationSweep(context.Background(), now)
	for id, want := range map[string]string{"abandoned": "succeeded", "expired": "expired"} {
		op, err := h.srv.Store.FleetOperation(id)
		if err != nil || op.Status != want {
			t.Fatalf("%s: %+v %v", id, op, err)
		}
	}
}
