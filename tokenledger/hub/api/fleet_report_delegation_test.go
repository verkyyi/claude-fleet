package api

import (
	"encoding/json"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestReportDelegationEnvelope(t *testing.T) {
	fleet := "11111111-1111-4111-8111-111111111111/"
	child := fleet + "22222222-2222-4222-8222-222222222222"
	parent := fleet + "33333333-3333-4333-8333-333333333333"
	target := fleet + "44444444-4444-4444-8444-444444444444"
	grant := "55555555-5555-4555-8555-555555555555"
	for _, tc := range []struct {
		name, kind, from, to, rid, hopTarget string
		ok                                   bool
	}{
		{"valid", control.RelayChildReport, child, target, child + "#event", target, true},
		{"message cannot retain", control.RelayMessage, child, target, child + "#event", target, false},
		{"wrong reporter", control.RelayChildReport, parent, target, child + "#event", target, false},
		{"wrong recipient", control.RelayChildReport, child, parent, child + "#event", target, false},
		{"wrong id", control.RelayChildReport, child, target, child + "#other", target, false},
		{"cycle", control.RelayChildReport, child, target, child + "#event", parent, false},
		{"self", control.RelayChildReport, child, target, child + "#event", child, false},
		{"key alias", control.RelayChildReport, child, target, child + "#event", fleet + "scratch-1", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload, _ := json.Marshal(map[string]any{"rid": tc.rid, "report_delegation": map[string]any{
				"reporter": child, "original_parent": parent, "target": target,
				"chain": []map[string]string{{"id": grant, "parent": parent, "target": tc.hopTarget}},
			}})
			var obj map[string]json.RawMessage
			_ = json.Unmarshal(payload, &obj)
			err := checkReportDelegation(control.Relay{ID: child + "#event", Kind: tc.kind, From: tc.from, To: tc.to}, obj)
			if (err == nil) != tc.ok {
				t.Fatalf("got %v, want ok=%v", err, tc.ok)
			}
		})
	}
}
