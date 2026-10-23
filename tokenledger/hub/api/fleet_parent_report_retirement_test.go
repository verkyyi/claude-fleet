package api

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestParentReportRetiredAtIngress(t *testing.T) {
	h := newFleetHarness(t)
	for i, payload := range []string{`{"state":"MERGED"}`, `{"task_report":true}`, `{"report_delegation":{"target":"old-parent"}}`} {
		r := control.Relay{ID: fmt.Sprintf("%s/issue-1#retired%d", wrFleetM4, i), Kind: control.RelayChildReport, From: wrFleetM4 + "/issue-1", To: wrFleetM5 + "/issue-2", Payload: json.RawMessage(payload)}
		m, _ := control.New(control.TypeRelay, r)
		_, err := h.srv.checkRelay(store.Endpoint{ID: "old-node"}, m)
		if err == nil || errorObject(err)["code"] != "PARENT_REPORT_RETIRED" {
			t.Fatalf("report accepted or wrong refusal: %v", err)
		}
		if _, err := h.srv.Store.FleetRelay(r.ID); err == nil {
			t.Fatal("retired report stored")
		}
	}
}

func TestParentReportBacklogRetiredOffline(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	for i, payload := range []string{`{"state":"MERGED"}`, `{"task_report":true}`, `{"report_delegation":{"target":"old-parent"}}`} {
		r := store.FleetRelay{ID: fmt.Sprintf("old-%d", i), Kind: control.RelayChildReport, FromWID: wrFleetM4 + "/issue-1", ToWID: wrFleetM5 + "/issue-2", FromEndpoint: "from", TargetEndpoint: "offline", Payload: payload, Created: now.Add(-30 * 24 * time.Hour)}
		if _, err := h.srv.Store.InsertFleetRelay(r); err != nil {
			t.Fatal(err)
		}
		if i == 1 {
			if err := h.srv.Store.MarkFleetRelaySent(r.ID, now); err != nil {
				t.Fatal(err)
			}
		}
	}
	historical := store.FleetRelay{ID: "history", Kind: control.RelayChildReport, TargetEndpoint: "offline", Payload: `{"summary":"kept"}`, Created: now}
	if _, err := h.srv.Store.InsertFleetRelay(historical); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.FinishFleetRelay(historical.ID, store.RelayDelivered, "old receipt", now); err != nil {
		t.Fatal(err)
	}
	h.srv.dispatchRelays("offline")
	h.srv.dispatchRelays("offline")
	for i := 0; i < 3; i++ {
		r, err := h.srv.Store.FleetRelay(fmt.Sprintf("old-%d", i))
		attempts := 0
		if i == 1 {
			attempts = 1
		}
		if err != nil || r.Status != store.RelayFailed || !strings.Contains(r.Detail, "PARENT_REPORT_RETIRED") || r.Attempts != attempts || r.Payload == "" {
			t.Fatalf("backlog %d: %+v %v", i, r, err)
		}
	}
	r, err := h.srv.Store.FleetRelay("history")
	if err != nil || r.Status != store.RelayDelivered || r.Detail != "old receipt" || r.Payload != historical.Payload {
		t.Fatalf("history changed: %+v %v", r, err)
	}
}

func TestParentReportLateResultRetired(t *testing.T) {
	for _, res := range []control.RelayResult{{OK: true}, {Retry: true}, {Detail: "old failure"}} {
		h := newFleetHarness(t)
		r := store.FleetRelay{ID: "inflight", Kind: control.RelayChildReport, TargetEndpoint: "old-node", Created: time.Now(), Payload: `{}`}
		if _, err := h.srv.Store.InsertFleetRelay(r); err != nil {
			t.Fatal(err)
		}
		res.ID = r.ID
		m, _ := control.New(control.TypeRelayResult, res)
		h.srv.relayResult("old-node", m)
		got, err := h.srv.Store.FleetRelay(r.ID)
		if err != nil || got.Status != store.RelayFailed || !strings.Contains(got.Detail, "PARENT_REPORT_RETIRED") {
			t.Fatalf("late result: %+v %v", got, err)
		}
	}
}
